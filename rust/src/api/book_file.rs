use std::collections::HashMap;
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{anyhow, Context, Result};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use chardetng::EncodingDetector;
use encoding_rs::{Encoding, UTF_8, WINDOWS_1252};
use once_cell::sync::Lazy;
use regex::Regex;
use scraper::{Html, Selector};
use serde::{Deserialize, Serialize};
use zip::ZipArchive;

static CHAPTER_REGEXES: Lazy<Vec<Regex>> = Lazy::new(|| {
    vec![
        Regex::new(
            r"(?m)^\s*第\s*[零〇一二三四五六七八九十百千万0-9]+\s*[章卷节集回部篇]\s*[^\n]{0,80}$",
        )
        .unwrap(),
        Regex::new(r"(?im)^\s*chapter\s+[ivxlcdm0-9]+[\.:\s][^\n]{0,80}$").unwrap(),
        Regex::new(r"(?m)^\s*(楔子|序章|序言|序|前言|后记|番外|尾声|引子|终章)[^\n]{0,40}$")
            .unwrap(),
        Regex::new(r"(?m)^\s*\(?[0-9]{1,4}[).、]\s*[^\n]{1,80}$").unwrap(),
    ]
});

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookChapter {
    pub title: String,
    pub start: u64,
    pub end: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookMeta {
    pub locator: String,
    pub title: String,
    pub author: String,
    pub format: String,
    pub encoding: String,
    pub size_bytes: u64,
    pub cover_data_url: Option<String>,
    pub chapters: Vec<BookChapter>,
}

#[derive(Clone)]
struct ParsedBook {
    title: String,
    author: String,
    format: String,
    encoding: String,
    text: String,
    cover_data_url: Option<String>,
    chapters: Option<Vec<BookChapter>>,
}

static TXT_CACHE: Lazy<Mutex<HashMap<String, ParsedBook>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

#[flutter_rust_bridge::frb(sync)]
pub fn open_book_file(path: String) -> Result<BookMeta> {
    let p = PathBuf::from(&path);
    if !p.exists() {
        return Err(anyhow!("文件不存在: {path}"));
    }
    let title = p
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("未命名")
        .to_string();
    if extension(&path, &title).as_deref() == Some("txt") {
        if let Some(parsed) = cached_txt(&path) {
            return Ok(meta_from_parsed(
                path,
                title,
                std::fs::metadata(&p)?.len(),
                parsed,
            ));
        }
    }
    let bytes = std::fs::read(&p)?;
    let locator = path;
    let parsed = parse_book(&locator, &title, &bytes)?;
    Ok(meta_from_parsed(locator, title, bytes.len() as u64, parsed))
}

#[flutter_rust_bridge::frb(sync)]
pub fn open_book_bytes(locator: String, title: String, bytes: Vec<u8>) -> Result<BookMeta> {
    let parsed = parse_book(&locator, &title, &bytes)?;
    Ok(meta_from_parsed(locator, title, bytes.len() as u64, parsed))
}

#[flutter_rust_bridge::frb(sync)]
pub fn read_book_chapter_file(path: String, start: u64, end: u64) -> Result<String> {
    if extension(&path, &path).as_deref() == Some("txt") {
        if let Some(parsed) = cached_txt(&path) {
            return Ok(read_text_range(&parsed.text, start, end));
        }
    }
    let bytes = std::fs::read(&path)?;
    read_book_chapter_bytes(path, String::new(), bytes, start, end)
}

#[flutter_rust_bridge::frb(sync)]
pub fn read_book_chapter_bytes(
    locator: String,
    title: String,
    bytes: Vec<u8>,
    start: u64,
    end: u64,
) -> Result<String> {
    if extension(&locator, &title).as_deref() == Some("txt") {
        if let Some(parsed) = cached_txt(&locator) {
            return Ok(read_text_range(&parsed.text, start, end));
        }
    }
    let parsed = parse_book(&locator, &title, &bytes)?;
    Ok(read_text_range(&parsed.text, start, end))
}

fn meta_from_parsed(
    locator: String,
    title: String,
    size_bytes: u64,
    parsed: ParsedBook,
) -> BookMeta {
    let chapters = parsed
        .chapters
        .unwrap_or_else(|| parse_chapters(&parsed.text));
    BookMeta {
        locator,
        title: fallback_title(&parsed.title, &title),
        author: parsed.author,
        format: parsed.format,
        encoding: parsed.encoding,
        size_bytes,
        cover_data_url: parsed.cover_data_url,
        chapters,
    }
}

fn cached_txt(locator: &str) -> Option<ParsedBook> {
    TXT_CACHE
        .lock()
        .ok()
        .and_then(|cache| cache.get(locator).cloned())
}

fn store_txt(locator: &str, parsed: &ParsedBook) {
    if parsed.format != "txt" {
        return;
    }
    if let Ok(mut cache) = TXT_CACHE.lock() {
        cache.insert(locator.to_string(), parsed.clone());
    }
}

fn parse_book(locator: &str, title: &str, bytes: &[u8]) -> Result<ParsedBook> {
    let ext = extension(locator, title);
    match ext.as_deref() {
        Some("epub") => parse_epub(bytes, title),
        Some("mobi") | Some("azw") | Some("azw3") | Some("prc") => {
            parse_mobi(bytes, title, ext.as_deref().unwrap_or("mobi"))
        }
        Some("txt") | None => {
            if let Some(parsed) = cached_txt(locator) {
                Ok(parsed)
            } else {
                let parsed = parse_txt(bytes, title);
                store_txt(locator, &parsed);
                Ok(parsed)
            }
        }
        Some(other) => Err(anyhow!("暂不支持的文件格式: {other}")),
    }
}

fn extension(locator: &str, title: &str) -> Option<String> {
    Path::new(title)
        .extension()
        .or_else(|| Path::new(locator).extension())
        .and_then(|s| s.to_str())
        .map(|s| s.trim_start_matches('.').to_ascii_lowercase())
}

fn fallback_title(primary: &str, fallback: &str) -> String {
    if primary.trim().is_empty() {
        let stem = Path::new(fallback)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("未命名");
        if stem.trim().is_empty() {
            "未命名".to_string()
        } else {
            stem.trim().to_string()
        }
    } else {
        primary.trim().to_string()
    }
}

fn parse_txt(bytes: &[u8], title: &str) -> ParsedBook {
    let enc = detect_encoding(bytes);
    let (cow, _, _) = enc.decode(bytes);
    ParsedBook {
        title: fallback_title("", title),
        author: String::new(),
        format: "txt".to_string(),
        encoding: enc.name().to_string(),
        text: normalize_text(&cow),
        cover_data_url: None,
        chapters: None,
    }
}

fn detect_encoding(bytes: &[u8]) -> &'static Encoding {
    let mut det = EncodingDetector::new(chardetng::Iso2022JpDetection::Allow);
    det.feed(bytes, true);
    det.guess(None, chardetng::Utf8Detection::Allow)
}

fn parse_epub(bytes: &[u8], fallback: &str) -> Result<ParsedBook> {
    let cursor = Cursor::new(bytes);
    let mut archive = ZipArchive::new(cursor).context("EPUB 文件结构无效")?;
    let container = read_zip_string(&mut archive, "META-INF/container.xml")
        .context("EPUB 缺少 container.xml")?;
    let container_doc =
        roxmltree::Document::parse(&container).context("EPUB container.xml 解析失败")?;
    let opf_path = container_doc
        .descendants()
        .find(|node| node.has_tag_name("rootfile"))
        .and_then(|node| node.attribute("full-path"))
        .ok_or_else(|| anyhow!("EPUB 缺少 OPF 路径"))?
        .to_string();
    let opf = read_zip_string(&mut archive, &opf_path).context("EPUB OPF 读取失败")?;
    let opf_doc = roxmltree::Document::parse(&opf).context("EPUB OPF 解析失败")?;
    let title = opf_doc
        .descendants()
        .find(|node| node.tag_name().name() == "title")
        .and_then(|node| node.text())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(fallback)
        .to_string();
    let author = opf_doc
        .descendants()
        .find(|node| node.tag_name().name() == "creator")
        .and_then(|node| node.text())
        .map(str::trim)
        .unwrap_or("")
        .to_string();
    let base = opf_path
        .rsplit_once('/')
        .map(|(base, _)| base)
        .unwrap_or("");
    let mut manifest = HashMap::<String, EpubManifestItem>::new();
    for item in opf_doc
        .descendants()
        .filter(|node| node.has_tag_name("item"))
    {
        if let (Some(id), Some(href)) = (item.attribute("id"), item.attribute("href")) {
            manifest.insert(
                id.to_string(),
                EpubManifestItem {
                    href: href.to_string(),
                    path: join_epub_path(base, href),
                    media_type: item.attribute("media-type").unwrap_or("").to_string(),
                    properties: item.attribute("properties").unwrap_or("").to_string(),
                },
            );
        }
    }
    let cover_data_url = extract_epub_cover(&mut archive, &opf_doc, &manifest);
    let mut text = String::new();
    let mut chapters = Vec::new();
    let mut index = 1usize;
    for itemref in opf_doc
        .descendants()
        .filter(|node| node.has_tag_name("itemref"))
    {
        let Some(idref) = itemref.attribute("idref") else {
            continue;
        };
        let Some(item) = manifest.get(idref) else {
            continue;
        };
        let Ok(xhtml) = read_zip_string(&mut archive, &item.path) else {
            continue;
        };
        let heading = html_title(&xhtml).unwrap_or_else(|| format!("第 {index} 章"));
        let mut body = html_to_text(&xhtml);
        if body == heading {
            body.clear();
        } else if body.starts_with(&format!("{heading}\n")) {
            body = body[heading.len()..].trim_start().to_string();
        }
        if body.trim().is_empty() {
            continue;
        }
        if !text.is_empty() {
            text.push_str("\n\n");
        }
        let start = text.len();
        text.push_str(&heading);
        text.push_str("\n\n");
        text.push_str(&body);
        let end = text.len();
        chapters.push(BookChapter {
            title: heading,
            start: start as u64,
            end: end as u64,
        });
        index += 1;
    }
    if text.trim().is_empty() {
        return Err(anyhow!("EPUB 没有可阅读正文"));
    }
    Ok(ParsedBook {
        title,
        author,
        format: "epub".to_string(),
        encoding: "UTF-8".to_string(),
        text,
        cover_data_url,
        chapters: Some(chapters),
    })
}

#[derive(Clone)]
struct EpubManifestItem {
    href: String,
    path: String,
    media_type: String,
    properties: String,
}

fn extract_epub_cover<R: Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    opf_doc: &roxmltree::Document<'_>,
    manifest: &HashMap<String, EpubManifestItem>,
) -> Option<String> {
    let item = opf_doc
        .descendants()
        .find(|node| {
            node.has_tag_name("meta")
                && node.attribute("name") == Some("cover")
                && node.attribute("content").is_some()
        })
        .and_then(|node| node.attribute("content"))
        .and_then(|id| manifest.get(id))
        .or_else(|| {
            manifest.values().find(|item| {
                item.media_type.starts_with("image/")
                    && item
                        .properties
                        .split_whitespace()
                        .any(|value| value == "cover-image")
            })
        })
        .or_else(|| {
            manifest.values().find(|item| {
                item.media_type.starts_with("image/")
                    && item.href.to_ascii_lowercase().contains("cover")
            })
        })?;
    let bytes = read_zip_bytes(archive, &item.path).ok()?;
    if bytes.is_empty() || bytes.len() > 2 * 1024 * 1024 {
        return None;
    }
    let mime = if item.media_type.trim().is_empty() {
        mime_from_path(&item.path)
    } else {
        item.media_type.clone()
    };
    Some(format!("data:{mime};base64,{}", BASE64.encode(bytes)))
}

fn read_zip_string<R: Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    path: &str,
) -> Result<String> {
    let mut file = archive.by_name(path)?;
    let mut s = String::new();
    file.read_to_string(&mut s)?;
    Ok(s)
}

fn read_zip_bytes<R: Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    path: &str,
) -> Result<Vec<u8>> {
    let mut file = archive.by_name(path)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn join_epub_path(base: &str, href: &str) -> String {
    let href = href.split('#').next().unwrap_or(href);
    if base.is_empty() {
        href.to_string()
    } else {
        format!("{base}/{href}")
    }
}

fn mime_from_path(path: &str) -> String {
    match Path::new(path)
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.to_ascii_lowercase())
        .as_deref()
    {
        Some("png") => "image/png".to_string(),
        Some("gif") => "image/gif".to_string(),
        Some("webp") => "image/webp".to_string(),
        Some("svg") => "image/svg+xml".to_string(),
        _ => "image/jpeg".to_string(),
    }
}

fn html_title(html: &str) -> Option<String> {
    let doc = Html::parse_document(html);
    for selector in ["h1", "h2", "title"] {
        let sel = Selector::parse(selector).ok()?;
        if let Some(text) = doc
            .select(&sel)
            .next()
            .map(|node| normalize_inline(&node.text().collect::<Vec<_>>().join(" ")))
        {
            if !text.is_empty() {
                return Some(text);
            }
        }
    }
    None
}

fn html_to_text(html: &str) -> String {
    let doc = Html::parse_document(html);
    let body = Selector::parse("body")
        .ok()
        .and_then(|sel| doc.select(&sel).next());
    let raw = if let Some(body) = body {
        body.text().collect::<Vec<_>>().join("\n")
    } else {
        doc.root_element().text().collect::<Vec<_>>().join("\n")
    };
    normalize_text(&raw)
}

fn normalize_inline(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_string()
}

fn normalize_text(text: &str) -> String {
    let mut out = Vec::new();
    let mut blank = false;
    for line in text.replace('\u{a0}', " ").replace('\r', "\n").lines() {
        let clean = normalize_inline(line);
        if clean.is_empty() {
            if !blank && !out.is_empty() {
                out.push(String::new());
            }
            blank = true;
        } else {
            out.push(clean);
            blank = false;
        }
    }
    out.join("\n").trim().to_string()
}

fn parse_mobi(bytes: &[u8], fallback: &str, format: &str) -> Result<ParsedBook> {
    if bytes.len() < 86 {
        return Err(anyhow!("MOBI/AZW3 文件过小或已损坏"));
    }
    let record_count = be_u16(bytes, 76)? as usize;
    if record_count < 2 {
        return Err(anyhow!("MOBI/AZW3 缺少正文记录"));
    }
    let mut offsets = Vec::with_capacity(record_count);
    for index in 0..record_count {
        offsets.push(be_u32(bytes, 78 + index * 8)? as usize);
    }
    offsets.push(bytes.len());
    let first = offsets[0];
    if first + 16 > bytes.len() {
        return Err(anyhow!("MOBI/AZW3 头部损坏"));
    }
    let compression = be_u16(bytes, first)?;
    let text_records = be_u16(bytes, first + 8)? as usize;
    let encryption = be_u16(bytes, first + 12)?;
    if encryption != 0 {
        return Err(anyhow!("暂不支持加密或 DRM 保护的 MOBI/AZW3"));
    }
    let mobi = first + 16;
    if mobi + 132 > bytes.len() || bytes.get(mobi..mobi + 4) != Some(b"MOBI") {
        return Err(anyhow!("不是有效的 MOBI/AZW3 文件"));
    }
    let encoding_id = be_u32(bytes, mobi + 28).unwrap_or(65001);
    let title_offset = be_u32(bytes, mobi + 84).unwrap_or(0) as usize;
    let title_length = be_u32(bytes, mobi + 88).unwrap_or(0) as usize;
    let enc = mobi_encoding(encoding_id);
    let title = if title_offset > 0
        && title_length > 0
        && mobi + title_offset + title_length <= bytes.len()
    {
        let (cow, _, _) =
            enc.decode(&bytes[mobi + title_offset..mobi + title_offset + title_length]);
        normalize_inline(&cow)
    } else {
        fallback_title("", fallback)
    };
    let mut text_bytes = Vec::new();
    let count = text_records.min(record_count.saturating_sub(1));
    for idx in 0..count {
        let record = idx + 1;
        let start = offsets[record];
        let end = offsets[record + 1].min(bytes.len());
        if start >= end {
            continue;
        }
        match compression {
            1 => text_bytes.extend_from_slice(&bytes[start..end]),
            2 => text_bytes.extend(palmdoc_decompress(&bytes[start..end])?),
            17480 => return Err(anyhow!("暂不支持 HUFF/CDIC 压缩的 MOBI/AZW3")),
            other => return Err(anyhow!("暂不支持的 MOBI/AZW3 压缩方式: {other}")),
        }
    }
    let (cow, _, _) = enc.decode(&text_bytes);
    let decoded = cow.into_owned();
    let text = if decoded.contains('<') && decoded.contains('>') {
        html_to_text(&decoded)
    } else {
        normalize_text(&decoded)
    };
    if text.trim().is_empty() {
        return Err(anyhow!("MOBI/AZW3 没有可阅读正文"));
    }
    Ok(ParsedBook {
        title,
        author: String::new(),
        format: format.to_string(),
        encoding: enc.name().to_string(),
        text,
        cover_data_url: None,
        chapters: None,
    })
}

fn mobi_encoding(id: u32) -> &'static Encoding {
    match id {
        65001 => UTF_8,
        1252 => WINDOWS_1252,
        932 => Encoding::for_label(b"shift_jis").unwrap_or(UTF_8),
        936 => Encoding::for_label(b"gbk").unwrap_or(UTF_8),
        950 => Encoding::for_label(b"big5").unwrap_or(UTF_8),
        _ => UTF_8,
    }
}

fn palmdoc_decompress(input: &[u8]) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(input.len() * 2);
    let mut index = 0usize;
    while index < input.len() {
        let byte = input[index];
        index += 1;
        match byte {
            0x00 => out.push(0),
            0x01..=0x08 => {
                let count = byte as usize;
                if index + count > input.len() {
                    return Err(anyhow!("PalmDOC 压缩数据损坏"));
                }
                out.extend_from_slice(&input[index..index + count]);
                index += count;
            }
            0x09..=0x7f => out.push(byte),
            0x80..=0xbf => {
                if index >= input.len() {
                    return Err(anyhow!("PalmDOC 回溯数据损坏"));
                }
                let next = input[index];
                index += 1;
                let distance = ((((byte as usize) & 0x3f) << 5) | ((next as usize) >> 3)) as usize;
                let length = ((next & 0x07) + 3) as usize;
                if distance == 0 || distance > out.len() {
                    return Err(anyhow!("PalmDOC 回溯距离无效"));
                }
                for _ in 0..length {
                    let value = out[out.len() - distance];
                    out.push(value);
                }
            }
            0xc0..=0xff => {
                out.push(b' ');
                out.push(byte ^ 0x80);
            }
        }
    }
    Ok(out)
}

fn be_u16(bytes: &[u8], offset: usize) -> Result<u16> {
    if offset + 2 > bytes.len() {
        return Err(anyhow!("文件结构损坏"));
    }
    Ok(u16::from_be_bytes([bytes[offset], bytes[offset + 1]]))
}

fn be_u32(bytes: &[u8], offset: usize) -> Result<u32> {
    if offset + 4 > bytes.len() {
        return Err(anyhow!("文件结构损坏"));
    }
    Ok(u32::from_be_bytes([
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
    ]))
}

fn parse_chapters(text: &str) -> Vec<BookChapter> {
    let mut hits: Vec<(usize, String)> = Vec::new();
    for re in CHAPTER_REGEXES.iter() {
        for m in re.find_iter(text) {
            let line = m.as_str().trim();
            if !line.is_empty() && line.chars().count() <= 80 {
                hits.push((m.start(), line.to_string()));
            }
        }
    }
    hits.sort_by_key(|hit| hit.0);
    hits.dedup_by_key(|hit| hit.0);
    if hits.is_empty() {
        return split_fallback(text);
    }
    hits.iter()
        .enumerate()
        .map(|(index, (offset, title))| BookChapter {
            title: title.clone(),
            start: *offset as u64,
            end: hits.get(index + 1).map(|hit| hit.0).unwrap_or(text.len()) as u64,
        })
        .collect()
}

fn split_fallback(text: &str) -> Vec<BookChapter> {
    let mut chapters = Vec::new();
    let mut start = 0usize;
    let mut index = 1usize;
    while start < text.len() {
        let mut end = (start + 8000).min(text.len());
        while end < text.len() && !text.is_char_boundary(end) {
            end += 1;
        }
        chapters.push(BookChapter {
            title: format!("片段 {index}"),
            start: start as u64,
            end: end as u64,
        });
        start = end;
        index += 1;
    }
    chapters
}

fn read_text_range(text: &str, start: u64, end: u64) -> String {
    let s = (start as usize).min(text.len());
    let e = (end as usize).min(text.len());
    if s >= e {
        return String::new();
    }
    let mut a = s;
    while a < text.len() && !text.is_char_boundary(a) {
        a += 1;
    }
    let mut b = e;
    while b < text.len() && !text.is_char_boundary(b) {
        b += 1;
    }
    text[a..b].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn txt_chapters_are_detected() {
        let bytes = "第1章 开始\n正文\n第2章 继续\n正文".as_bytes().to_vec();
        let meta =
            open_book_bytes("sample.txt".to_string(), "sample.txt".to_string(), bytes).unwrap();
        assert_eq!(meta.format, "txt");
        assert_eq!(meta.chapters.len(), 2);
        assert_eq!(meta.chapters[0].title, "第1章 开始");
    }

    #[test]
    fn palmdoc_literals_are_decompressed() {
        let data = palmdoc_decompress(&[5, b'H', b'e', b'l', b'l', b'o']).unwrap();
        assert_eq!(data, b"Hello");
    }
}
