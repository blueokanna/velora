use std::cmp::Ordering;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Cursor, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};
use base64::engine::general_purpose::{STANDARD as BASE64, URL_SAFE_NO_PAD as BASE64_URL};
use base64::Engine;
use chardetng::EncodingDetector;
use encoding_rs::{Encoding, UTF_16BE, UTF_16LE, UTF_8, WINDOWS_1252};
use memmap2::MmapOptions;
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

#[derive(Clone, Copy)]
struct TxtFileInfo {
    size_bytes: u64,
    modified: Option<SystemTime>,
    encoding: &'static Encoding,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TxtPageBreakCache {
    pub base_page_index: u32,
    pub start_offset: u64,
    pub page_ends: Vec<u64>,
    pub next_offset: u64,
    pub has_more: bool,
    pub last_page_index: u32,
    #[serde(default)]
    pub touched_at_millis: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TxtLayoutTelemetry {
    #[serde(default)]
    pub hot_read_count: u64,
    #[serde(default)]
    pub hot_hit_count: u64,
    #[serde(default)]
    pub hot_miss_count: u64,
    #[serde(default)]
    pub average_jump_gap_pages: u32,
    #[serde(default)]
    pub max_jump_gap_pages: u32,
    #[serde(default)]
    pub bind_sample_count: u64,
    #[serde(default)]
    pub average_bind_micros: u64,
    #[serde(default)]
    pub max_bind_micros: u64,
    #[serde(default)]
    pub layout_sample_count: u64,
    #[serde(default)]
    pub average_layout_micros: u64,
    #[serde(default)]
    pub max_layout_micros: u64,
    #[serde(default)]
    pub prebind_request_count: u64,
    #[serde(default)]
    pub prebind_hit_count: u64,
    #[serde(default)]
    pub visible_prebound_bind_sample_count: u64,
    #[serde(default)]
    pub average_visible_prebound_bind_micros: u64,
    #[serde(default)]
    pub max_visible_prebound_bind_micros: u64,
    #[serde(default)]
    pub visible_prebound_layout_sample_count: u64,
    #[serde(default)]
    pub average_visible_prebound_layout_micros: u64,
    #[serde(default)]
    pub max_visible_prebound_layout_micros: u64,
    #[serde(default)]
    pub background_prebind_bind_sample_count: u64,
    #[serde(default)]
    pub average_background_prebind_bind_micros: u64,
    #[serde(default)]
    pub max_background_prebind_bind_micros: u64,
    #[serde(default)]
    pub background_prebind_layout_sample_count: u64,
    #[serde(default)]
    pub average_background_prebind_layout_micros: u64,
    #[serde(default)]
    pub max_background_prebind_layout_micros: u64,
    #[serde(default = "default_hot_window_size")]
    pub adaptive_window_size: u32,
    #[serde(default = "default_hot_window_retention")]
    pub adaptive_retention_limit: u32,
    pub updated_at_millis: Option<u64>,
}

impl Default for TxtLayoutTelemetry {
    fn default() -> Self {
        Self {
            hot_read_count: 0,
            hot_hit_count: 0,
            hot_miss_count: 0,
            average_jump_gap_pages: 0,
            max_jump_gap_pages: 0,
            bind_sample_count: 0,
            average_bind_micros: 0,
            max_bind_micros: 0,
            layout_sample_count: 0,
            average_layout_micros: 0,
            max_layout_micros: 0,
            prebind_request_count: 0,
            prebind_hit_count: 0,
            visible_prebound_bind_sample_count: 0,
            average_visible_prebound_bind_micros: 0,
            max_visible_prebound_bind_micros: 0,
            visible_prebound_layout_sample_count: 0,
            average_visible_prebound_layout_micros: 0,
            max_visible_prebound_layout_micros: 0,
            background_prebind_bind_sample_count: 0,
            average_background_prebind_bind_micros: 0,
            max_background_prebind_bind_micros: 0,
            background_prebind_layout_sample_count: 0,
            average_background_prebind_layout_micros: 0,
            max_background_prebind_layout_micros: 0,
            adaptive_window_size: default_hot_window_size(),
            adaptive_retention_limit: default_hot_window_retention(),
            updated_at_millis: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TxtPageCacheSelection {
    pub cache: TxtPageBreakCache,
    pub used_hot_window: bool,
    pub restored_first_page_index: u32,
    pub restored_last_page_index: u32,
    pub adaptive_window_size: u32,
    pub adaptive_retention_limit: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TxtLayoutFeedbackInput {
    pub target_page_index: u32,
    pub restored_first_page_index: u32,
    pub restored_last_page_index: u32,
    pub used_hot_window: bool,
    pub record_restore_event: bool,
    pub bind_total_micros: u64,
    pub bind_sample_count: u32,
    pub bind_max_micros: u64,
    pub layout_total_micros: u64,
    pub layout_sample_count: u32,
    pub layout_max_micros: u64,
    pub prebind_request_count: u32,
    pub prebind_hit_count: u32,
    pub visible_prebound_bind_total_micros: u64,
    pub visible_prebound_bind_sample_count: u32,
    pub visible_prebound_bind_max_micros: u64,
    pub visible_prebound_layout_total_micros: u64,
    pub visible_prebound_layout_sample_count: u32,
    pub visible_prebound_layout_max_micros: u64,
    pub background_prebind_bind_total_micros: u64,
    pub background_prebind_bind_sample_count: u32,
    pub background_prebind_bind_max_micros: u64,
    pub background_prebind_layout_total_micros: u64,
    pub background_prebind_layout_sample_count: u32,
    pub background_prebind_layout_max_micros: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TxtLayoutCache {
    #[serde(default)]
    pub chapters: HashMap<String, TxtPageBreakCache>,
    #[serde(default)]
    pub hot_windows: HashMap<String, Vec<TxtPageBreakCache>>,
    #[serde(default)]
    pub telemetry: TxtLayoutTelemetry,
    pub updated_at_millis: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct TxtIndexCache {
    schema_version: u32,
    size_bytes: u64,
    modified_at_millis: Option<u64>,
    encoding: String,
    chapters: Vec<BookChapter>,
    #[serde(default)]
    layouts: HashMap<String, TxtLayoutCache>,
}

static TXT_CACHE: Lazy<Mutex<HashMap<String, ParsedBook>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

static TXT_FILE_INFO_CACHE: Lazy<Mutex<HashMap<String, TxtFileInfo>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

const TXT_ENCODING_SAMPLE_BYTES: u64 = 256 * 1024;
const TXT_SPARSE_ANCHOR_BYTES: u64 = 64 * 1024;
const TXT_MMAP_GRANULARITY: u64 = 64 * 1024;
const TXT_INDEX_CACHE_SCHEMA_VERSION: u32 = 3;
const MAX_COMIC_PAGE_BYTES: u64 = 64 * 1024 * 1024;

fn default_hot_window_size() -> u32 {
    18
}

fn default_hot_window_retention() -> u32 {
    12
}

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
        return open_txt_file_meta(&p, path, title);
    }
    if extension(&path, &title)
        .as_deref()
        .is_some_and(is_audio_extension)
    {
        return Ok(audio_book_meta(path, title, std::fs::metadata(&p)?.len()));
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
    match extension(&path, &path).as_deref() {
        Some("txt") => return read_txt_chapter_file(Path::new(&path), start, end),
        Some("cbz" | "zip") => {
            let file = File::open(&path).with_context(|| format!("无法打开漫画文件: {path}"))?;
            let mut archive = ZipArchive::new(file).context("漫画压缩包结构无效")?;
            return comic_entry_data_url(&mut archive, start as usize);
        }
        _ => {}
    }
    let bytes = std::fs::read(&path)?;
    read_book_chapter_bytes(path, String::new(), bytes, start, end)
}

#[flutter_rust_bridge::frb(sync)]
pub fn read_txt_page_cache(
    path: String,
    layout_key: String,
    chapter_index: u32,
    target_page_index: u32,
    text_length: u64,
) -> Result<Option<TxtPageCacheSelection>> {
    let path = PathBuf::from(path);
    if !path.exists() {
        return Ok(None);
    }
    let metadata = fs::metadata(&path)?;
    let size_bytes = metadata.len();
    let modified = metadata.modified().ok();
    let Some(cache) = load_txt_index_cache(&path, size_bytes, modified)? else {
        return Ok(None);
    };
    let Some(layout) = cache.layouts.get(&layout_key) else {
        return Ok(None);
    };
    let chapter_key = chapter_index.to_string();
    let Some(selection) = select_txt_page_cache(layout, &chapter_key, target_page_index) else {
        return Ok(None);
    };
    let entry = selection.cache.clone();
    if !validate_txt_page_cache(&entry, text_length) {
        return Ok(None);
    }
    Ok(Some(TxtPageCacheSelection {
        restored_first_page_index: entry.base_page_index,
        restored_last_page_index: entry
            .base_page_index
            .saturating_add(entry.page_ends.len().saturating_sub(1) as u32),
        adaptive_window_size: layout.telemetry.adaptive_window_size,
        adaptive_retention_limit: layout.telemetry.adaptive_retention_limit,
        used_hot_window: selection.used_hot_window,
        cache: entry,
    }))
}

#[flutter_rust_bridge::frb(sync)]
pub fn write_txt_page_cache(
    path: String,
    layout_key: String,
    chapter_index: u32,
    base_page_index: u32,
    start_offset: u64,
    page_ends: Vec<u64>,
    next_offset: u64,
    has_more: bool,
    last_page_index: u32,
) -> Result<()> {
    if page_ends.is_empty() {
        return Ok(());
    }
    let path = PathBuf::from(path);
    if !path.exists() {
        return Ok(());
    }
    let metadata = fs::metadata(&path)?;
    let size_bytes = metadata.len();
    let modified = metadata.modified().ok();
    let text_length = page_ends.last().copied().unwrap_or(0);
    let entry = TxtPageBreakCache {
        base_page_index,
        start_offset,
        page_ends,
        next_offset,
        has_more,
        last_page_index,
        touched_at_millis: modified_millis(Some(SystemTime::now())),
    };
    if !validate_txt_page_cache(&entry, text_length) {
        return Ok(());
    }
    let mut cache = ensure_txt_index_cache(&path, size_bytes, modified)?;
    let layout = cache.layouts.entry(layout_key).or_default();
    let chapter_key = chapter_index.to_string();
    if entry.base_page_index == 0 && entry.start_offset == 0 {
        layout.chapters.insert(chapter_key.clone(), entry.clone());
        layout.hot_windows.insert(
            chapter_key,
            build_hot_page_windows(&entry, layout.telemetry.adaptive_window_size as usize),
        );
    } else {
        merge_hot_window(layout, chapter_key, entry);
    }
    layout.updated_at_millis = modified_millis(Some(SystemTime::now()));
    save_txt_index_cache_record(&path, &cache)
}

#[flutter_rust_bridge::frb(sync)]
pub fn report_txt_layout_feedback(
    path: String,
    layout_key: String,
    chapter_index: u32,
    feedback: TxtLayoutFeedbackInput,
) -> Result<()> {
    let path = PathBuf::from(path);
    if !path.exists() {
        return Ok(());
    }
    let metadata = fs::metadata(&path)?;
    let size_bytes = metadata.len();
    let modified = metadata.modified().ok();
    let mut cache = ensure_txt_index_cache(&path, size_bytes, modified)?;
    let Some(layout) = cache.layouts.get_mut(&layout_key) else {
        return Ok(());
    };
    apply_layout_feedback(layout, &chapter_index.to_string(), &feedback);
    layout.updated_at_millis = modified_millis(Some(SystemTime::now()));
    save_txt_index_cache_record(&path, &cache)
}

#[flutter_rust_bridge::frb(sync)]
pub fn read_txt_layout_telemetry(
    path: String,
    layout_key: String,
) -> Result<Option<TxtLayoutTelemetry>> {
    let path = PathBuf::from(path);
    if !path.exists() {
        return Ok(None);
    }
    let metadata = fs::metadata(&path)?;
    let size_bytes = metadata.len();
    let modified = metadata.modified().ok();
    let Some(cache) = load_txt_index_cache(&path, size_bytes, modified)? else {
        return Ok(None);
    };
    Ok(cache
        .layouts
        .get(&layout_key)
        .map(|layout| layout.telemetry.clone()))
}

#[flutter_rust_bridge::frb(sync)]
pub fn read_book_chapter_bytes(
    locator: String,
    title: String,
    bytes: Vec<u8>,
    start: u64,
    end: u64,
) -> Result<String> {
    let ext = extension(&locator, &title);
    if ext.as_deref() == Some("txt") {
        if let Some(parsed) = cached_txt(&locator) {
            return Ok(read_text_range(&parsed.text, start, end));
        }
    }
    if matches!(ext.as_deref(), Some("cbz" | "zip")) {
        let mut archive = ZipArchive::new(Cursor::new(bytes)).context("漫画压缩包结构无效")?;
        return comic_entry_data_url(&mut archive, start as usize);
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
        Some("md") | Some("markdown") => Ok(parse_markdown(bytes, title)),
        Some("cbz") | Some("zip") => parse_cbz(bytes, title),
        Some(ext) if is_audio_extension(ext) => Ok(parse_audio(title, ext)),
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

fn is_audio_extension(ext: &str) -> bool {
    matches!(ext, "mp3" | "m4a" | "aac" | "ogg" | "opus" | "wav" | "flac")
}

fn audio_book_meta(locator: String, title: String, size_bytes: u64) -> BookMeta {
    let ext = extension(&locator, &title).unwrap_or_else(|| "audio".to_string());
    BookMeta {
        locator,
        title: fallback_title("", &title),
        author: String::new(),
        format: ext,
        encoding: "binary".to_string(),
        size_bytes,
        cover_data_url: None,
        chapters: vec![BookChapter {
            title: fallback_title("", &title),
            start: 0,
            end: 0,
        }],
    }
}

fn parse_audio(title: &str, format: &str) -> ParsedBook {
    ParsedBook {
        title: fallback_title("", title),
        author: String::new(),
        format: format.to_string(),
        encoding: "binary".to_string(),
        text: String::new(),
        cover_data_url: None,
        chapters: Some(vec![BookChapter {
            title: fallback_title("", title),
            start: 0,
            end: 0,
        }]),
    }
}

fn parse_markdown(bytes: &[u8], title: &str) -> ParsedBook {
    let encoding = detect_encoding(bytes);
    let text = decode_bytes_with_encoding(encoding, bytes)
        .trim_start_matches('\u{feff}')
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    let (front_title, author) = markdown_front_matter(&text);
    let (heading_title, chapters) = markdown_chapters(&text);
    ParsedBook {
        title: front_title
            .or(heading_title)
            .unwrap_or_else(|| fallback_title("", title)),
        author: author.unwrap_or_default(),
        format: "markdown".to_string(),
        encoding: encoding.name().to_string(),
        text,
        cover_data_url: None,
        chapters: Some(chapters),
    }
}

fn markdown_front_matter(text: &str) -> (Option<String>, Option<String>) {
    if !text.starts_with("---\n") {
        return (None, None);
    }
    let Some(end) = text[4..].find("\n---\n") else {
        return (None, None);
    };
    let mut title = None;
    let mut author = None;
    for line in text[4..4 + end].lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim().trim_matches(['\'', '"']);
        match key.trim().to_ascii_lowercase().as_str() {
            "title" if !value.is_empty() => title = Some(value.to_string()),
            "author" if !value.is_empty() => author = Some(value.to_string()),
            _ => {}
        }
    }
    (title, author)
}

fn markdown_chapters(text: &str) -> (Option<String>, Vec<BookChapter>) {
    let mut headings = Vec::<(usize, String, usize)>::new();
    let mut offset = 0usize;
    let mut fence: Option<&str> = None;
    for line in text.split_inclusive('\n') {
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") {
            fence = if fence == Some("```") {
                None
            } else if fence.is_none() {
                Some("```")
            } else {
                fence
            };
        } else if trimmed.starts_with("~~~") {
            fence = if fence == Some("~~~") {
                None
            } else if fence.is_none() {
                Some("~~~")
            } else {
                fence
            };
        } else if fence.is_none() {
            let hashes = trimmed.chars().take_while(|ch| *ch == '#').count();
            if (1..=2).contains(&hashes)
                && trimmed.chars().nth(hashes).is_some_and(char::is_whitespace)
            {
                let heading = trimmed[hashes..].trim().trim_end_matches('#').trim();
                if !heading.is_empty() {
                    headings.push((
                        offset + (line.len() - trimmed.len()),
                        heading.to_string(),
                        hashes,
                    ));
                }
            }
        }
        offset += line.len();
    }
    let document_title = headings
        .iter()
        .find(|(_, _, level)| *level == 1)
        .map(|(_, heading, _)| heading.clone());
    if headings.is_empty() {
        return (
            document_title.clone(),
            vec![BookChapter {
                title: document_title.clone().unwrap_or_else(|| "正文".to_string()),
                start: 0,
                end: text.len() as u64,
            }],
        );
    }
    let mut chapters = Vec::new();
    if headings[0].0 > 0 && !text[..headings[0].0].trim().is_empty() {
        chapters.push(BookChapter {
            title: "前言".to_string(),
            start: 0,
            end: headings[0].0 as u64,
        });
    }
    for (index, (start, heading, _)) in headings.iter().enumerate() {
        chapters.push(BookChapter {
            title: heading.clone(),
            start: *start as u64,
            end: headings
                .get(index + 1)
                .map(|(next, _, _)| *next)
                .unwrap_or(text.len()) as u64,
        });
    }
    (document_title, chapters)
}

fn parse_cbz(bytes: &[u8], title: &str) -> Result<ParsedBook> {
    let mut archive = ZipArchive::new(Cursor::new(bytes)).context("漫画压缩包结构无效")?;
    let mut images = Vec::<(usize, String)>::new();
    for index in 0..archive.len() {
        let file = archive.by_index(index)?;
        if !file.is_dir() && is_comic_image(file.name()) {
            if file.size() > MAX_COMIC_PAGE_BYTES {
                return Err(anyhow!("漫画页超过 64MB 安全上限: {}", file.name()));
            }
            images.push((index, file.name().replace('\\', "/")));
        }
    }
    if images.is_empty() {
        return Err(anyhow!("压缩包中没有可阅读的漫画图片"));
    }
    images.sort_by(|left, right| natural_path_cmp(&left.1, &right.1));
    let cover_data_url = {
        let bytes = read_comic_entry(&mut archive, images[0].0)?;
        if bytes.len() <= 2 * 1024 * 1024 {
            Some(format!(
                "data:{};base64,{}",
                mime_from_path(&images[0].1),
                BASE64.encode(bytes)
            ))
        } else {
            None
        }
    };
    let chapters = images
        .iter()
        .enumerate()
        .map(|(page, (entry_index, name))| BookChapter {
            title: Path::new(name)
                .file_stem()
                .and_then(|value| value.to_str())
                .map(str::to_string)
                .unwrap_or_else(|| format!("第 {} 页", page + 1)),
            start: *entry_index as u64,
            end: (*entry_index + 1) as u64,
        })
        .collect();
    Ok(ParsedBook {
        title: fallback_title("", title),
        author: String::new(),
        format: "cbz".to_string(),
        encoding: "binary".to_string(),
        text: String::new(),
        cover_data_url,
        chapters: Some(chapters),
    })
}

fn read_comic_entry<R: Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    entry_index: usize,
) -> Result<Vec<u8>> {
    let mut file = archive.by_index(entry_index).context("漫画页索引无效")?;
    if file.is_dir() || !is_comic_image(file.name()) {
        return Err(anyhow!("压缩包条目不是受支持的漫画图片"));
    }
    if file.size() > MAX_COMIC_PAGE_BYTES {
        return Err(anyhow!("漫画页超过 64MB 安全上限"));
    }
    let mut bytes = Vec::with_capacity(file.size().min(MAX_COMIC_PAGE_BYTES) as usize);
    file.read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn comic_entry_data_url<R: Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    entry_index: usize,
) -> Result<String> {
    let path = archive
        .by_index(entry_index)
        .context("漫画页索引无效")?
        .name()
        .to_string();
    let bytes = read_comic_entry(archive, entry_index)?;
    Ok(format!(
        "data:{};base64,{}",
        mime_from_path(&path),
        BASE64.encode(bytes)
    ))
}

fn is_comic_image(path: &str) -> bool {
    matches!(
        Path::new(path)
            .extension()
            .and_then(|value| value.to_str())
            .map(|value| value.to_ascii_lowercase())
            .as_deref(),
        Some("jpg" | "jpeg" | "png" | "webp" | "gif")
    )
}

fn natural_path_cmp(left: &str, right: &str) -> Ordering {
    let mut left_parts = natural_parts(left).into_iter();
    let mut right_parts = natural_parts(right).into_iter();
    loop {
        match (left_parts.next(), right_parts.next()) {
            (Some(NaturalPart::Number(a)), Some(NaturalPart::Number(b))) => match a.cmp(&b) {
                Ordering::Equal => {}
                order => return order,
            },
            (Some(NaturalPart::Text(a)), Some(NaturalPart::Text(b))) => match a.cmp(&b) {
                Ordering::Equal => {}
                order => return order,
            },
            (Some(NaturalPart::Number(_)), Some(NaturalPart::Text(_))) => return Ordering::Less,
            (Some(NaturalPart::Text(_)), Some(NaturalPart::Number(_))) => return Ordering::Greater,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (None, None) => return left.to_ascii_lowercase().cmp(&right.to_ascii_lowercase()),
        }
    }
}

enum NaturalPart {
    Number(u64),
    Text(String),
}

fn natural_parts(value: &str) -> Vec<NaturalPart> {
    let mut parts = Vec::new();
    let mut buffer = String::new();
    let mut numeric: Option<bool> = None;
    for ch in value.chars() {
        let is_numeric = ch.is_ascii_digit();
        if numeric.is_some_and(|current| current != is_numeric) {
            parts.push(if numeric == Some(true) {
                NaturalPart::Number(buffer.parse().unwrap_or(u64::MAX))
            } else {
                NaturalPart::Text(buffer.to_ascii_lowercase())
            });
            buffer.clear();
        }
        numeric = Some(is_numeric);
        buffer.push(ch);
    }
    if !buffer.is_empty() {
        parts.push(if numeric == Some(true) {
            NaturalPart::Number(buffer.parse().unwrap_or(u64::MAX))
        } else {
            NaturalPart::Text(buffer.to_ascii_lowercase())
        });
    }
    parts
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

fn open_txt_file_meta(path: &Path, locator: String, title: String) -> Result<BookMeta> {
    let metadata = std::fs::metadata(path)?;
    let size_bytes = metadata.len();
    let modified = metadata.modified().ok();
    let cache = ensure_txt_index_cache(path, size_bytes, modified)?;
    let encoding = Encoding::for_label(cache.encoding.as_bytes()).unwrap_or(UTF_8);
    Ok(BookMeta {
        locator,
        title: fallback_title("", &title),
        author: String::new(),
        format: "txt".to_string(),
        encoding: encoding.name().to_string(),
        size_bytes,
        cover_data_url: None,
        chapters: cache.chapters,
    })
}

fn ensure_txt_index_cache(
    path: &Path,
    size_bytes: u64,
    modified: Option<SystemTime>,
) -> Result<TxtIndexCache> {
    if let Some(cache) = load_txt_index_cache(path, size_bytes, modified)? {
        let encoding = Encoding::for_label(cache.encoding.as_bytes()).unwrap_or(UTF_8);
        store_txt_file_info(path, size_bytes, modified, encoding);
        return Ok(cache);
    }
    let encoding = detect_file_encoding(path)?;
    let chapters = scan_txt_file_chapters(path, size_bytes, encoding)?;
    store_txt_file_info(path, size_bytes, modified, encoding);
    let cache = TxtIndexCache {
        schema_version: TXT_INDEX_CACHE_SCHEMA_VERSION,
        size_bytes,
        modified_at_millis: modified_millis(modified),
        encoding: encoding.name().to_string(),
        chapters,
        layouts: HashMap::new(),
    };
    let _ = save_txt_index_cache_record(path, &cache);
    Ok(cache)
}

fn load_txt_index_cache(
    path: &Path,
    size_bytes: u64,
    modified: Option<SystemTime>,
) -> Result<Option<TxtIndexCache>> {
    let expected_modified = modified_millis(modified);
    for cache_path in txt_index_cache_candidates(path) {
        let bytes = match fs::read(&cache_path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => continue,
        };
        let cache = match serde_json::from_slice::<TxtIndexCache>(&bytes) {
            Ok(cache) => cache,
            Err(_) => continue,
        };
        if cache.schema_version == 0
            || cache.schema_version > TXT_INDEX_CACHE_SCHEMA_VERSION
            || cache.size_bytes != size_bytes
            || cache.modified_at_millis != expected_modified
            || cache.chapters.is_empty()
        {
            continue;
        }
        return Ok(Some(cache));
    }
    Ok(None)
}

fn save_txt_index_cache_record(path: &Path, cache: &TxtIndexCache) -> Result<()> {
    if cache.chapters.is_empty() {
        return Ok(());
    }
    let payload = serde_json::to_vec(cache)?;
    for cache_path in txt_index_cache_candidates(path) {
        let Some(parent) = cache_path.parent() else {
            continue;
        };
        if fs::create_dir_all(parent).is_err() {
            continue;
        }
        let tmp = cache_path.with_extension("tmp");
        if let Ok(mut file) = File::create(&tmp) {
            if file.write_all(&payload).is_ok() && file.flush().is_ok() {
                if cache_path.exists() {
                    let _ = fs::remove_file(&cache_path);
                }
                if fs::rename(&tmp, &cache_path).is_ok() {
                    return Ok(());
                }
            }
        }
        let _ = fs::remove_file(&tmp);
    }
    Ok(())
}

fn validate_txt_page_cache(cache: &TxtPageBreakCache, text_length: u64) -> bool {
    if cache.page_ends.is_empty() {
        return false;
    }
    let end_page_index = cache.base_page_index as usize + cache.page_ends.len() - 1;
    if (cache.last_page_index as usize) < (cache.base_page_index as usize)
        || (cache.last_page_index as usize) > end_page_index
    {
        return false;
    }
    let mut previous = cache.start_offset;
    for &end in &cache.page_ends {
        if end <= previous || end > text_length {
            return false;
        }
        previous = end;
    }
    if cache.next_offset < previous || cache.next_offset > text_length {
        return false;
    }
    true
}

struct SelectedTxtPageCache<'a> {
    cache: &'a TxtPageBreakCache,
    used_hot_window: bool,
}

fn select_txt_page_cache<'a>(
    layout: &'a TxtLayoutCache,
    chapter_key: &str,
    target_page_index: u32,
) -> Option<SelectedTxtPageCache<'a>> {
    let full = layout.chapters.get(chapter_key)?;
    if full.page_ends.len() <= 192 || target_page_index <= 24 {
        return Some(SelectedTxtPageCache {
            cache: full,
            used_hot_window: false,
        });
    }
    let windows = layout.hot_windows.get(chapter_key)?;
    windows
        .iter()
        .filter(|window| {
            let start = window.base_page_index;
            let end = start.saturating_add(window.page_ends.len().saturating_sub(1) as u32);
            target_page_index >= start.saturating_sub(8)
                && target_page_index <= end.saturating_add(8)
        })
        .min_by_key(|window| {
            let start = window.base_page_index;
            let end = start.saturating_add(window.page_ends.len().saturating_sub(1) as u32);
            if target_page_index < start {
                start - target_page_index
            } else if target_page_index > end {
                target_page_index - end
            } else {
                0
            }
        })
        .map(|window| SelectedTxtPageCache {
            cache: window,
            used_hot_window: true,
        })
        .or(Some(SelectedTxtPageCache {
            cache: full,
            used_hot_window: false,
        }))
}

fn build_hot_page_windows(full: &TxtPageBreakCache, window_size: usize) -> Vec<TxtPageBreakCache> {
    const TIERS: &[usize] = &[24, 48, 96, 192];
    let clamped_window_size = window_size.clamp(12, 40);
    if full.page_ends.len() <= clamped_window_size * 2 {
        return Vec::new();
    }
    let mut windows = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for &step in TIERS {
        let mut anchor = step;
        while anchor < full.page_ends.len() {
            push_hot_page_window(full, anchor, clamped_window_size, &mut seen, &mut windows);
            anchor += step;
        }
    }
    push_hot_page_window(
        full,
        full.last_page_index
            .min((full.page_ends.len().saturating_sub(1)) as u32) as usize,
        clamped_window_size,
        &mut seen,
        &mut windows,
    );
    windows
}

fn push_hot_page_window(
    full: &TxtPageBreakCache,
    anchor_page: usize,
    window_size: usize,
    seen: &mut std::collections::HashSet<usize>,
    out: &mut Vec<TxtPageBreakCache>,
) {
    if full.page_ends.is_empty() {
        return;
    }
    let total = full.page_ends.len();
    let anchor = anchor_page.min(total - 1);
    let half = window_size / 2;
    let start_page = anchor.saturating_sub(half);
    let end_page = (start_page + window_size).min(total);
    if !seen.insert(start_page) {
        return;
    }
    let start_offset = if start_page == 0 {
        0
    } else {
        full.page_ends[start_page - 1]
    };
    let page_ends = full.page_ends[start_page..end_page].to_vec();
    let absolute_last_index = full.base_page_index + anchor as u32;
    let next_offset = if end_page >= total {
        full.next_offset
    } else {
        full.page_ends[end_page - 1]
    };
    out.push(TxtPageBreakCache {
        base_page_index: full.base_page_index + start_page as u32,
        start_offset,
        page_ends,
        next_offset,
        has_more: full.has_more || end_page < total,
        last_page_index: absolute_last_index,
        touched_at_millis: full.touched_at_millis,
    });
}

fn merge_hot_window(layout: &mut TxtLayoutCache, chapter_key: String, entry: TxtPageBreakCache) {
    let windows = layout.hot_windows.entry(chapter_key).or_default();
    windows.retain(|window| {
        window.base_page_index != entry.base_page_index
            || window.page_ends.len() != entry.page_ends.len()
    });
    windows.push(entry);
    windows.sort_by_key(|window| {
        (
            window.touched_at_millis.unwrap_or(0),
            window.last_page_index,
        )
    });
    let retention_limit = layout.telemetry.adaptive_retention_limit.max(4) as usize;
    if windows.len() > retention_limit {
        let keep_from = windows.len() - retention_limit;
        windows.drain(0..keep_from);
    }
}

fn apply_layout_feedback(
    layout: &mut TxtLayoutCache,
    chapter_key: &str,
    feedback: &TxtLayoutFeedbackInput,
) {
    let telemetry = &mut layout.telemetry;
    if feedback.record_restore_event {
        let gap_pages = target_gap_pages(feedback);
        let hot_hit = feedback.used_hot_window && gap_pages == 0;
        telemetry.hot_read_count = telemetry.hot_read_count.saturating_add(1);
        if hot_hit {
            telemetry.hot_hit_count = telemetry.hot_hit_count.saturating_add(1);
        } else {
            telemetry.hot_miss_count = telemetry.hot_miss_count.saturating_add(1);
        }
        telemetry.average_jump_gap_pages = blend_u32_average(
            telemetry.average_jump_gap_pages,
            telemetry.hot_read_count.saturating_sub(1),
            gap_pages,
            1,
        );
        telemetry.max_jump_gap_pages = telemetry.max_jump_gap_pages.max(gap_pages);
    }
    telemetry.average_bind_micros = blend_u64_average(
        telemetry.average_bind_micros,
        telemetry.bind_sample_count,
        feedback.bind_total_micros,
        feedback.bind_sample_count as u64,
    );
    telemetry.bind_sample_count = telemetry
        .bind_sample_count
        .saturating_add(feedback.bind_sample_count as u64);
    telemetry.max_bind_micros = telemetry.max_bind_micros.max(feedback.bind_max_micros);
    telemetry.average_layout_micros = blend_u64_average(
        telemetry.average_layout_micros,
        telemetry.layout_sample_count,
        feedback.layout_total_micros,
        feedback.layout_sample_count as u64,
    );
    telemetry.layout_sample_count = telemetry
        .layout_sample_count
        .saturating_add(feedback.layout_sample_count as u64);
    telemetry.max_layout_micros = telemetry.max_layout_micros.max(feedback.layout_max_micros);
    telemetry.prebind_request_count = telemetry
        .prebind_request_count
        .saturating_add(feedback.prebind_request_count as u64);
    telemetry.prebind_hit_count = telemetry
        .prebind_hit_count
        .saturating_add(feedback.prebind_hit_count as u64);
    telemetry.average_visible_prebound_bind_micros = blend_u64_average(
        telemetry.average_visible_prebound_bind_micros,
        telemetry.visible_prebound_bind_sample_count,
        feedback.visible_prebound_bind_total_micros,
        feedback.visible_prebound_bind_sample_count as u64,
    );
    telemetry.visible_prebound_bind_sample_count = telemetry
        .visible_prebound_bind_sample_count
        .saturating_add(feedback.visible_prebound_bind_sample_count as u64);
    telemetry.max_visible_prebound_bind_micros = telemetry
        .max_visible_prebound_bind_micros
        .max(feedback.visible_prebound_bind_max_micros);
    telemetry.average_visible_prebound_layout_micros = blend_u64_average(
        telemetry.average_visible_prebound_layout_micros,
        telemetry.visible_prebound_layout_sample_count,
        feedback.visible_prebound_layout_total_micros,
        feedback.visible_prebound_layout_sample_count as u64,
    );
    telemetry.visible_prebound_layout_sample_count = telemetry
        .visible_prebound_layout_sample_count
        .saturating_add(feedback.visible_prebound_layout_sample_count as u64);
    telemetry.max_visible_prebound_layout_micros = telemetry
        .max_visible_prebound_layout_micros
        .max(feedback.visible_prebound_layout_max_micros);
    telemetry.average_background_prebind_bind_micros = blend_u64_average(
        telemetry.average_background_prebind_bind_micros,
        telemetry.background_prebind_bind_sample_count,
        feedback.background_prebind_bind_total_micros,
        feedback.background_prebind_bind_sample_count as u64,
    );
    telemetry.background_prebind_bind_sample_count = telemetry
        .background_prebind_bind_sample_count
        .saturating_add(feedback.background_prebind_bind_sample_count as u64);
    telemetry.max_background_prebind_bind_micros = telemetry
        .max_background_prebind_bind_micros
        .max(feedback.background_prebind_bind_max_micros);
    telemetry.average_background_prebind_layout_micros = blend_u64_average(
        telemetry.average_background_prebind_layout_micros,
        telemetry.background_prebind_layout_sample_count,
        feedback.background_prebind_layout_total_micros,
        feedback.background_prebind_layout_sample_count as u64,
    );
    telemetry.background_prebind_layout_sample_count = telemetry
        .background_prebind_layout_sample_count
        .saturating_add(feedback.background_prebind_layout_sample_count as u64);
    telemetry.max_background_prebind_layout_micros = telemetry
        .max_background_prebind_layout_micros
        .max(feedback.background_prebind_layout_max_micros);
    telemetry.updated_at_millis = modified_millis(Some(SystemTime::now()));
    retune_hot_window_policy(telemetry);
    if feedback.record_restore_event && feedback.used_hot_window {
        touch_hot_window(
            layout,
            chapter_key,
            feedback.restored_first_page_index,
            feedback.restored_last_page_index,
        );
    }
}

fn target_gap_pages(feedback: &TxtLayoutFeedbackInput) -> u32 {
    if feedback.target_page_index < feedback.restored_first_page_index {
        feedback.restored_first_page_index - feedback.target_page_index
    } else {
        feedback
            .target_page_index
            .saturating_sub(feedback.restored_last_page_index)
    }
}

fn blend_u32_average(current: u32, current_samples: u64, new_total: u32, new_samples: u64) -> u32 {
    if new_samples == 0 {
        return current;
    }
    let total = (current as u128 * current_samples as u128) + new_total as u128;
    let samples = current_samples as u128 + new_samples as u128;
    (total / samples) as u32
}

fn blend_u64_average(current: u64, current_samples: u64, new_total: u64, new_samples: u64) -> u64 {
    if new_samples == 0 {
        return current;
    }
    let total = (current as u128 * current_samples as u128) + new_total as u128;
    let samples = current_samples as u128 + new_samples as u128;
    (total / samples) as u64
}

fn retune_hot_window_policy(telemetry: &mut TxtLayoutTelemetry) {
    let hit_rate = if telemetry.hot_read_count == 0 {
        0.0
    } else {
        telemetry.hot_hit_count as f64 / telemetry.hot_read_count as f64
    };
    let prebind_hit_rate = if telemetry.prebind_request_count == 0 {
        1.0
    } else {
        telemetry.prebind_hit_count as f64 / telemetry.prebind_request_count as f64
    };
    let mut window_size = default_hot_window_size();
    let mut retention = default_hot_window_retention();
    if hit_rate < 0.45 || telemetry.average_jump_gap_pages >= 6 {
        window_size = window_size.saturating_add(6);
        retention = retention.saturating_add(3);
    }
    if hit_rate < 0.28 || telemetry.average_jump_gap_pages >= 12 {
        window_size = window_size.saturating_add(8);
        retention = retention.saturating_add(4);
    }
    if telemetry.average_visible_prebound_layout_micros > 0
        && telemetry.average_visible_prebound_layout_micros >= 900
    {
        window_size = window_size.saturating_add(4);
    }
    if telemetry.average_layout_micros >= 1800 {
        window_size = window_size.saturating_add(4);
        retention = retention.saturating_add(2);
    }
    if telemetry.average_bind_micros >= 1200 || prebind_hit_rate < 0.5 {
        retention = retention.saturating_add(2);
    }
    if telemetry.average_background_prebind_bind_micros >= 1600
        || telemetry.average_background_prebind_layout_micros >= 1800
    {
        retention = retention.saturating_sub(1);
    }
    if hit_rate > 0.82
        && telemetry.average_jump_gap_pages <= 2
        && telemetry.average_layout_micros < 900
        && prebind_hit_rate >= 0.75
    {
        window_size = window_size.saturating_sub(4);
        retention = retention.saturating_sub(2);
    }
    telemetry.adaptive_window_size = window_size.clamp(12, 40);
    telemetry.adaptive_retention_limit = retention.clamp(6, 24);
}

fn touch_hot_window(
    layout: &mut TxtLayoutCache,
    chapter_key: &str,
    restored_first_page_index: u32,
    restored_last_page_index: u32,
) {
    let Some(windows) = layout.hot_windows.get_mut(chapter_key) else {
        return;
    };
    let now = modified_millis(Some(SystemTime::now()));
    for window in windows.iter_mut() {
        let start = window.base_page_index;
        let end = start.saturating_add(window.page_ends.len().saturating_sub(1) as u32);
        if start == restored_first_page_index && end == restored_last_page_index {
            window.touched_at_millis = now;
        }
    }
    windows.sort_by_key(|window| {
        (
            window.touched_at_millis.unwrap_or(0),
            window.last_page_index,
        )
    });
    let retention_limit = layout.telemetry.adaptive_retention_limit.max(4) as usize;
    if windows.len() > retention_limit {
        let keep_from = windows.len() - retention_limit;
        windows.drain(0..keep_from);
    }
}

fn txt_index_cache_candidates(path: &Path) -> Vec<PathBuf> {
    let file_name = format!("{}.json", txt_index_cache_key(path));
    let mut candidates = Vec::with_capacity(2);
    if let Some(parent) = path.parent() {
        candidates.push(parent.join(".velora_cache").join(&file_name));
    }
    candidates.push(
        std::env::temp_dir()
            .join("velora")
            .join("txt_index")
            .join(file_name),
    );
    candidates
}

fn txt_index_cache_key(path: &Path) -> String {
    let source = path
        .canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .into_owned();
    BASE64_URL.encode(source.as_bytes())
}

fn modified_millis(modified: Option<SystemTime>) -> Option<u64> {
    modified.and_then(|value| {
        value
            .duration_since(UNIX_EPOCH)
            .ok()
            .map(|duration| duration.as_millis().min(u64::MAX as u128) as u64)
    })
}

fn store_txt_file_info(
    path: &Path,
    size_bytes: u64,
    modified: Option<SystemTime>,
    encoding: &'static Encoding,
) {
    if let Some(key) = path.to_str() {
        if let Ok(mut cache) = TXT_FILE_INFO_CACHE.lock() {
            cache.insert(
                key.to_string(),
                TxtFileInfo {
                    size_bytes,
                    modified,
                    encoding,
                },
            );
        }
    }
}

fn cached_txt_file_encoding(
    path: &Path,
    size_bytes: u64,
    modified: Option<SystemTime>,
) -> Option<&'static Encoding> {
    let key = path.to_str()?;
    TXT_FILE_INFO_CACHE.lock().ok().and_then(|cache| {
        cache.get(key).and_then(|info| {
            if info.size_bytes == size_bytes && info.modified == modified {
                Some(info.encoding)
            } else {
                None
            }
        })
    })
}

fn detect_file_encoding(path: &Path) -> Result<&'static Encoding> {
    let size_bytes = std::fs::metadata(path)?.len();
    let sample = read_file_window(path, 0, TXT_ENCODING_SAMPLE_BYTES.min(size_bytes))?;
    Ok(if sample.is_empty() {
        UTF_8
    } else {
        detect_encoding(&sample)
    })
}

fn scan_txt_file_chapters(
    path: &Path,
    size_bytes: u64,
    encoding: &'static Encoding,
) -> Result<Vec<BookChapter>> {
    if size_bytes == 0 {
        return Ok(Vec::new());
    }
    let mut reader = std::io::BufReader::new(File::open(path)?);
    let mut line = Vec::new();
    let mut offset = 0u64;
    let mut hits = Vec::<(u64, String)>::new();
    let mut fallback_starts = vec![0u64];

    loop {
        let line_start = offset;
        let read = std::io::BufRead::read_until(&mut reader, b'\n', &mut line)?;
        if read == 0 {
            break;
        }
        if line_start > *fallback_starts.last().unwrap_or(&0)
            && line_start - *fallback_starts.last().unwrap_or(&0) >= TXT_SPARSE_ANCHOR_BYTES
        {
            fallback_starts.push(line_start);
        }
        let decoded = decode_bytes_with_encoding(encoding, &line);
        let candidate = normalize_inline(
            decoded.trim_matches(|ch: char| matches!(ch, '\u{feff}' | '\r' | '\n')),
        );
        if !candidate.is_empty()
            && candidate.chars().count() <= 80
            && CHAPTER_REGEXES.iter().any(|re| re.is_match(&candidate))
            && hits.last().map(|hit| hit.0) != Some(line_start)
        {
            hits.push((line_start, candidate));
        }
        offset += read as u64;
        line.clear();
    }

    Ok(if hits.is_empty() {
        split_sparse_ranges(size_bytes, fallback_starts)
    } else {
        split_detected_chapters(size_bytes, &hits, &fallback_starts)
    })
}

fn split_sparse_ranges(size_bytes: u64, fallback_starts: Vec<u64>) -> Vec<BookChapter> {
    if size_bytes == 0 {
        return Vec::new();
    }
    let mut starts = fallback_starts
        .into_iter()
        .filter(|offset| *offset < size_bytes)
        .collect::<Vec<_>>();
    if starts.is_empty() {
        starts.push(0);
    }
    starts.sort_unstable();
    starts.dedup();
    starts
        .iter()
        .enumerate()
        .map(|(index, start)| BookChapter {
            title: format!("片段 {}", index + 1),
            start: *start,
            end: starts.get(index + 1).copied().unwrap_or(size_bytes),
        })
        .collect()
}

fn split_detected_chapters(
    size_bytes: u64,
    hits: &[(u64, String)],
    fallback_starts: &[u64],
) -> Vec<BookChapter> {
    let mut chapters = Vec::new();
    for (index, (start, title)) in hits.iter().enumerate() {
        let end = hits.get(index + 1).map(|next| next.0).unwrap_or(size_bytes);
        if end <= *start {
            continue;
        }
        let mut anchors = Vec::new();
        anchors.push(*start);
        anchors.extend(
            fallback_starts
                .iter()
                .copied()
                .filter(|anchor| *anchor > *start && *anchor < end),
        );
        anchors.sort_unstable();
        anchors.dedup();
        for (part_index, part_start) in anchors.iter().enumerate() {
            let part_end = anchors.get(part_index + 1).copied().unwrap_or(end);
            chapters.push(BookChapter {
                title: if part_index == 0 {
                    title.clone()
                } else {
                    format!("{} · {}", title, part_index + 1)
                },
                start: *part_start,
                end: part_end,
            });
        }
    }
    chapters
}

fn read_txt_chapter_file(path: &Path, start: u64, end: u64) -> Result<String> {
    let metadata = std::fs::metadata(path)?;
    let size_bytes = metadata.len();
    let modified = metadata.modified().ok();
    let start = start.min(size_bytes);
    let end = end.min(size_bytes);
    if start >= end {
        return Ok(String::new());
    }
    let bytes = read_file_window(path, start, end)?;
    let encoding = if let Some(encoding) = cached_txt_file_encoding(path, size_bytes, modified) {
        encoding
    } else {
        let encoding = detect_file_encoding(path)?;
        store_txt_file_info(path, size_bytes, modified, encoding);
        encoding
    };
    let text = decode_bytes_with_encoding(encoding, &bytes);
    Ok(normalize_text(&text))
}

fn read_file_window(path: &Path, start: u64, end: u64) -> Result<Vec<u8>> {
    if start >= end {
        return Ok(Vec::new());
    }
    read_mmap_window(path, start, end).or_else(|_| read_seek_window(path, start, end))
}

fn read_mmap_window(path: &Path, start: u64, end: u64) -> Result<Vec<u8>> {
    let file = File::open(path)?;
    let aligned = start - (start % TXT_MMAP_GRANULARITY);
    let prefix = (start - aligned) as usize;
    let len = (end - aligned) as usize;
    let map = unsafe { MmapOptions::new().offset(aligned).len(len).map(&file)? };
    Ok(map[prefix..prefix + (end - start) as usize].to_vec())
}

fn read_seek_window(path: &Path, start: u64, end: u64) -> Result<Vec<u8>> {
    let mut file = File::open(path)?;
    std::io::Seek::seek(&mut file, std::io::SeekFrom::Start(start))?;
    let mut bytes = Vec::with_capacity((end - start).min(256 * 1024) as usize);
    file.take(end - start).read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn decode_bytes_with_encoding(encoding: &'static Encoding, bytes: &[u8]) -> String {
    if encoding == UTF_16LE || encoding == UTF_16BE {
        let raw = if bytes.len() >= 2
            && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))
        {
            &bytes[2..]
        } else {
            bytes
        };
        let mut units = Vec::with_capacity(raw.len() / 2);
        for chunk in raw.chunks_exact(2) {
            let value = if encoding == UTF_16LE {
                u16::from_le_bytes([chunk[0], chunk[1]])
            } else {
                u16::from_be_bytes([chunk[0], chunk[1]])
            };
            units.push(value);
        }
        return String::from_utf16_lossy(&units);
    }
    let (cow, _, _) = encoding.decode(bytes);
    cow.into_owned()
}

fn parse_txt(bytes: &[u8], title: &str) -> ParsedBook {
    let enc = detect_encoding(bytes);
    ParsedBook {
        title: fallback_title("", title),
        author: String::new(),
        format: "txt".to_string(),
        encoding: enc.name().to_string(),
        text: normalize_text(&decode_bytes_with_encoding(enc, bytes)),
        cover_data_url: None,
        chapters: None,
    }
}

fn detect_encoding(bytes: &[u8]) -> &'static Encoding {
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return UTF_8;
    }
    if bytes.starts_with(&[0xFF, 0xFE]) {
        return UTF_16LE;
    }
    if bytes.starts_with(&[0xFE, 0xFF]) {
        return UTF_16BE;
    }
    if std::str::from_utf8(bytes).is_ok() {
        return UTF_8;
    }
    let mut det = EncodingDetector::new(chardetng::Iso2022JpDetection::Allow);
    det.feed(bytes, true);
    choose_best_text_encoding(bytes, det.guess(None, chardetng::Utf8Detection::Allow))
}

fn choose_best_text_encoding(bytes: &[u8], guessed: &'static Encoding) -> &'static Encoding {
    let mut candidates = Vec::<&'static Encoding>::new();
    let mut push = |encoding: Option<&'static Encoding>| {
        if let Some(encoding) = encoding {
            if !candidates.contains(&encoding) {
                candidates.push(encoding);
            }
        }
    };
    push(Some(guessed));
    push(Some(UTF_8));
    push(Encoding::for_label(b"gb18030"));
    push(Encoding::for_label(b"gbk"));
    push(Encoding::for_label(b"big5"));
    push(Encoding::for_label(b"shift_jis"));
    if guessed != WINDOWS_1252 {
        return best_scored_encoding(bytes, &candidates).unwrap_or(guessed);
    }
    best_scored_encoding(bytes, &candidates).unwrap_or(guessed)
}

fn best_scored_encoding(
    bytes: &[u8],
    candidates: &[&'static Encoding],
) -> Option<&'static Encoding> {
    let mut best = None;
    let mut best_score = i64::MIN;
    for &encoding in candidates {
        let (decoded, _, had_errors) = encoding.decode(bytes);
        let score = score_decoded_text(decoded.as_ref(), had_errors, encoding);
        if score > best_score {
            best_score = score;
            best = Some(encoding);
        }
    }
    best
}

fn score_decoded_text(text: &str, had_errors: bool, encoding: &'static Encoding) -> i64 {
    let mut score = if had_errors { -1200 } else { 320 };
    let mut cjk_count = 0i64;
    let mut printable_count = 0i64;
    let mut suspicious_latin_count = 0i64;
    let mut replacement_count = 0i64;
    let mut control_count = 0i64;
    let mut common_simplified_count = 0i64;
    for ch in text.chars().take(16_384) {
        match ch {
            '\u{fffd}' => replacement_count += 1,
            '\n' | '\r' | '\t' => printable_count += 1,
            _ if ch.is_control() => control_count += 1,
            _ if is_east_asian_text(ch) => {
                cjk_count += 1;
                printable_count += 1;
                if matches!(
                    ch,
                    '的' | '一' | '是' | '了' | '我' | '你' | '他' | '章' | '第' | '个'
                ) {
                    common_simplified_count += 1;
                }
            }
            _ if ch.is_ascii_graphic() || ch == ' ' => printable_count += 1,
            _ if is_suspicious_mojibake_latin(ch) => {
                suspicious_latin_count += 1;
                printable_count += 1;
            }
            _ => printable_count += 1,
        }
    }
    score -= replacement_count * 180;
    score -= control_count * 80;
    score += cjk_count * 18;
    score += common_simplified_count * 60;
    score += printable_count;
    let chapter_hits = CHAPTER_REGEXES
        .iter()
        .map(|regex| regex.find_iter(text).take(8).count() as i64)
        .sum::<i64>();
    score += chapter_hits * 900;
    if cjk_count == 0 && suspicious_latin_count > 24 {
        score -= suspicious_latin_count * 22;
    }
    if cjk_count > 0 && encoding == WINDOWS_1252 {
        score -= 600;
    }
    if cjk_count == 0 && suspicious_latin_count > printable_count / 3 {
        score -= 900;
    }
    score
}

fn is_east_asian_text(ch: char) -> bool {
    matches!(
        ch as u32,
        0x2E80..=0x2FDF
            | 0x3040..=0x30FF
            | 0x3100..=0x312F
            | 0x31A0..=0x31BF
            | 0x3400..=0x4DBF
            | 0x4E00..=0x9FFF
            | 0xAC00..=0xD7AF
            | 0xF900..=0xFAFF
            | 0x20000..=0x2FA1F
    )
}

fn is_suspicious_mojibake_latin(ch: char) -> bool {
    matches!(ch as u32, 0x00C0..=0x024F)
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
    fn gb18030_text_prefers_cjk_decode_over_windows_1252() {
        let encoding = Encoding::for_label(b"gb18030").unwrap();
        let (encoded, _, _) = encoding.encode(
            "第一章 开始\n这是一个中文段落，用来验证编码探测。\n第二段依旧应该正常显示。\n",
        );
        let parsed = parse_txt(encoded.as_ref(), "sample.txt");
        assert!(parsed.text.contains("第一章 开始"));
        assert!(parsed.text.contains("中文段落"));
        assert!(
            parsed.encoding.eq_ignore_ascii_case("gb18030")
                || parsed.encoding.eq_ignore_ascii_case("gbk")
        );
    }

    #[test]
    fn utf16le_bom_is_detected_for_txt() {
        let mut bytes = vec![0xFF, 0xFE];
        bytes.extend(
            "第一章\n正文内容"
                .encode_utf16()
                .flat_map(|unit| unit.to_le_bytes()),
        );
        let parsed = parse_txt(&bytes, "sample.txt");
        assert!(parsed.text.contains("正文内容"));
        assert_eq!(parsed.encoding, UTF_16LE.name());
    }

    #[test]
    fn hot_window_feedback_expands_policy_on_gap_miss() {
        let mut layout = TxtLayoutCache::default();
        layout.hot_windows.insert(
            "0".to_string(),
            vec![TxtPageBreakCache {
                base_page_index: 32,
                start_offset: 3200,
                page_ends: vec![3300, 3400, 3500],
                next_offset: 3500,
                has_more: true,
                last_page_index: 34,
                touched_at_millis: Some(1),
            }],
        );
        apply_layout_feedback(
            &mut layout,
            "0",
            &TxtLayoutFeedbackInput {
                target_page_index: 52,
                restored_first_page_index: 32,
                restored_last_page_index: 34,
                used_hot_window: false,
                record_restore_event: true,
                bind_total_micros: 4800,
                bind_sample_count: 4,
                bind_max_micros: 1500,
                layout_total_micros: 9200,
                layout_sample_count: 4,
                layout_max_micros: 2600,
                prebind_request_count: 4,
                prebind_hit_count: 1,
                visible_prebound_bind_total_micros: 600,
                visible_prebound_bind_sample_count: 2,
                visible_prebound_bind_max_micros: 400,
                visible_prebound_layout_total_micros: 900,
                visible_prebound_layout_sample_count: 2,
                visible_prebound_layout_max_micros: 500,
                background_prebind_bind_total_micros: 1500,
                background_prebind_bind_sample_count: 2,
                background_prebind_bind_max_micros: 900,
                background_prebind_layout_total_micros: 2600,
                background_prebind_layout_sample_count: 2,
                background_prebind_layout_max_micros: 1500,
            },
        );
        assert!(layout.telemetry.adaptive_window_size >= 24);
        assert!(layout.telemetry.adaptive_retention_limit >= 15);
        assert_eq!(layout.telemetry.hot_miss_count, 1);
        assert_eq!(layout.telemetry.average_jump_gap_pages, 18);
        assert_eq!(layout.telemetry.visible_prebound_bind_sample_count, 2);
        assert_eq!(layout.telemetry.background_prebind_layout_sample_count, 2);
    }

    #[test]
    fn merge_hot_window_keeps_recent_windows() {
        let mut layout = TxtLayoutCache::default();
        layout.telemetry.adaptive_retention_limit = 4;
        merge_hot_window(
            &mut layout,
            "0".to_string(),
            TxtPageBreakCache {
                base_page_index: 0,
                start_offset: 0,
                page_ends: vec![100, 200],
                next_offset: 200,
                has_more: true,
                last_page_index: 1,
                touched_at_millis: Some(1),
            },
        );
        merge_hot_window(
            &mut layout,
            "0".to_string(),
            TxtPageBreakCache {
                base_page_index: 20,
                start_offset: 2000,
                page_ends: vec![2100, 2200],
                next_offset: 2200,
                has_more: true,
                last_page_index: 21,
                touched_at_millis: Some(2),
            },
        );
        merge_hot_window(
            &mut layout,
            "0".to_string(),
            TxtPageBreakCache {
                base_page_index: 40,
                start_offset: 4000,
                page_ends: vec![4100, 4200],
                next_offset: 4200,
                has_more: true,
                last_page_index: 41,
                touched_at_millis: Some(3),
            },
        );
        merge_hot_window(
            &mut layout,
            "0".to_string(),
            TxtPageBreakCache {
                base_page_index: 60,
                start_offset: 6000,
                page_ends: vec![6100, 6200],
                next_offset: 6200,
                has_more: true,
                last_page_index: 61,
                touched_at_millis: Some(4),
            },
        );
        merge_hot_window(
            &mut layout,
            "0".to_string(),
            TxtPageBreakCache {
                base_page_index: 80,
                start_offset: 8000,
                page_ends: vec![8100, 8200],
                next_offset: 8200,
                has_more: true,
                last_page_index: 81,
                touched_at_millis: Some(5),
            },
        );
        let kept = layout.hot_windows.get("0").unwrap();
        assert_eq!(kept.len(), 4);
        assert_eq!(kept[0].base_page_index, 20);
        assert_eq!(kept[1].base_page_index, 40);
        assert_eq!(kept[2].base_page_index, 60);
        assert_eq!(kept[3].base_page_index, 80);
    }

    #[test]
    fn palmdoc_literals_are_decompressed() {
        let data = palmdoc_decompress(&[5, b'H', b'e', b'l', b'l', b'o']).unwrap();
        assert_eq!(data, b"Hello");
    }
}
