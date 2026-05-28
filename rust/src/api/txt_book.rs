use std::path::PathBuf;
use std::sync::OnceLock;

use anyhow::{anyhow, Result};
use chardetng::EncodingDetector;
use encoding_rs::Encoding;
use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};

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
pub struct ChapterIndex {
    pub title: String,
    pub start: u64,
    pub end: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TxtBookMeta {
    pub path: String,
    pub title: String,
    pub encoding: String,
    pub size_bytes: u64,
    pub chapters: Vec<ChapterIndex>,
}

static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
pub(crate) fn rt() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("无法初始化 tokio 运行时")
    })
}

fn detect_encoding(bytes: &[u8]) -> &'static Encoding {
    let mut det = EncodingDetector::new(chardetng::Iso2022JpDetection::Allow);
    det.feed(bytes, true);
    det.guess(None, chardetng::Utf8Detection::Allow)
}

fn decode_all(bytes: &[u8]) -> (String, &'static Encoding) {
    let enc = detect_encoding(bytes);
    let (cow, _, _) = enc.decode(bytes);
    (cow.into_owned(), enc)
}

fn meta_from_bytes(locator: String, title: String, bytes: &[u8]) -> TxtBookMeta {
    let size = bytes.len() as u64;
    let (text, enc) = decode_all(bytes);
    let chapters = parse_chapters(&text);
    TxtBookMeta {
        path: locator,
        title,
        encoding: enc.name().to_string(),
        size_bytes: size,
        chapters,
    }
}

fn parse_chapters(text: &str) -> Vec<ChapterIndex> {
    let mut hits: Vec<(usize, &str)> = Vec::new();

    for re in CHAPTER_REGEXES.iter() {
        for m in re.find_iter(text) {
            let line = m.as_str().trim();
            if line.is_empty() || line.chars().count() > 80 {
                continue;
            }
            hits.push((m.start(), line));
        }
    }

    hits.sort_by_key(|h| h.0);
    hits.dedup_by_key(|h| h.0);

    if hits.is_empty() {
        let mut chapters = Vec::new();
        let total_bytes = text.len();
        let mut start = 0usize;
        let mut idx = 1;
        while start < total_bytes {
            let mut end = (start + 8000).min(total_bytes);
            while end < total_bytes && !text.is_char_boundary(end) {
                end += 1;
            }
            chapters.push(ChapterIndex {
                title: format!("片段 {}", idx),
                start: start as u64,
                end: end as u64,
            });
            start = end;
            idx += 1;
        }
        return chapters;
    }

    let mut chapters = Vec::with_capacity(hits.len());
    for (i, (off, title)) in hits.iter().enumerate() {
        let next = hits.get(i + 1).map(|h| h.0).unwrap_or(text.len());
        chapters.push(ChapterIndex {
            title: title.to_string(),
            start: *off as u64,
            end: next as u64,
        });
    }
    chapters
}

#[flutter_rust_bridge::frb(sync)]
pub fn open_txt_book(path: String) -> Result<TxtBookMeta> {
    let p = PathBuf::from(&path);
    if !p.exists() {
        return Err(anyhow!("文件不存在: {}", path));
    }
    let bytes = std::fs::read(&p)?;
    let title = p
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("未命名")
        .to_string();
    Ok(meta_from_bytes(path, title, &bytes))
}

#[flutter_rust_bridge::frb(sync)]
pub fn open_txt_bytes(locator: String, title: String, bytes: Vec<u8>) -> Result<TxtBookMeta> {
    let clean_title = if title.trim().is_empty() {
        "未命名".to_string()
    } else {
        title.trim().to_string()
    };
    Ok(meta_from_bytes(locator, clean_title, &bytes))
}

#[flutter_rust_bridge::frb(sync)]
pub fn read_chapter(path: String, start: u64, end: u64) -> Result<String> {
    let bytes = std::fs::read(&path)?;
    let (text, _) = decode_all(&bytes);
    Ok(read_text_range(&text, start, end))
}

#[flutter_rust_bridge::frb(sync)]
pub fn read_chapter_bytes(bytes: Vec<u8>, start: u64, end: u64) -> Result<String> {
    let (text, _) = decode_all(&bytes);
    Ok(read_text_range(&text, start, end))
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

#[flutter_rust_bridge::frb(sync)]
pub fn estimate_word_count(text: String) -> u32 {
    text.chars()
        .filter(|c| !c.is_whitespace() && *c != '\u{3000}')
        .count() as u32
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchHit {
    pub offset: u64,
    pub preview: String,
}

#[flutter_rust_bridge::frb(sync)]
pub fn search_in_book(path: String, keyword: String, max_hits: u32) -> Result<Vec<SearchHit>> {
    if keyword.trim().is_empty() {
        return Ok(vec![]);
    }
    let bytes = std::fs::read(&path)?;
    let (text, _) = decode_all(&bytes);
    let mut results = Vec::new();
    let kw = keyword.as_str();
    let mut idx = 0;
    while let Some(pos) = text[idx..].find(kw) {
        let abs = idx + pos;
        let s = abs.saturating_sub(20);
        let e = (abs + kw.len() + 20).min(text.len());
        let mut a = s;
        while a < text.len() && !text.is_char_boundary(a) {
            a += 1;
        }
        let mut b = e;
        while b < text.len() && !text.is_char_boundary(b) {
            b += 1;
        }
        results.push(SearchHit {
            offset: abs as u64,
            preview: text[a..b].replace('\n', " "),
        });
        if results.len() >= max_hits as usize {
            break;
        }
        idx = abs + kw.len();
    }
    Ok(results)
}
