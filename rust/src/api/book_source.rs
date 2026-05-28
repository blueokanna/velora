use anyhow::{anyhow, Context, Result};
use scraper::{Html, Selector};
use serde::{Deserialize, Serialize};

use crate::api::http_source::http_get;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookSource {
    pub name: String,
    pub url: String,
    pub enabled: bool,
    pub search_url: String,
    pub search_list: String,
    pub search_name: String,
    pub search_author: String,
    pub search_book_url: String,
    pub book_info_name: String,
    pub book_info_author: String,
    pub book_info_intro: String,
    pub book_info_toc_url: String,
    pub toc_list: String,
    pub toc_name: String,
    pub toc_url: String,
    pub content_selector: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    pub name: String,
    pub author: String,
    pub book_url: String,
    pub source_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookDetail {
    pub name: String,
    pub author: String,
    pub intro: String,
    pub toc_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TocEntry {
    pub title: String,
    pub url: String,
}

fn select_text(doc: &Html, sel: &str) -> String {
    if sel.is_empty() {
        return String::new();
    }
    Selector::parse(sel)
        .ok()
        .and_then(|s| {
            doc.select(&s)
                .next()
                .map(|e| e.text().collect::<String>().trim().to_string())
        })
        .unwrap_or_default()
}

fn select_attr(doc: &Html, sel: &str, attr: &str) -> String {
    if sel.is_empty() {
        return String::new();
    }
    Selector::parse(sel)
        .ok()
        .and_then(|s| {
            doc.select(&s)
                .next()
                .and_then(|e| e.value().attr(attr).map(|v| v.to_string()))
        })
        .unwrap_or_default()
}

fn absolute_url(base: &str, href: &str) -> String {
    if href.is_empty() {
        return String::new();
    }
    if let Ok(b) = url::Url::parse(base) {
        if let Ok(u) = b.join(href) {
            return u.to_string();
        }
    }
    href.to_string()
}

#[flutter_rust_bridge::frb(sync)]
pub fn source_search(source_json: String, keyword: String) -> Result<Vec<SearchResult>> {
    let src: BookSource = serde_json::from_str(&source_json).context("书源 JSON 解析失败")?;
    if !src.enabled {
        return Err(anyhow!("书源已禁用: {}", src.name));
    }
    let url = src.search_url.replace("{key}", &urlencoding_lite(&keyword));
    let resp = http_get(url.clone(), vec![])?;
    let doc = Html::parse_document(&resp.body);
    let list_sel =
        Selector::parse(&src.search_list).map_err(|e| anyhow!("搜索列表选择器无效: {e:?}"))?;
    let mut out = Vec::new();
    for el in doc.select(&list_sel) {
        let html_str = el.html();
        let sub = Html::parse_fragment(&html_str);
        let name = select_text(&sub, &src.search_name);
        let author = select_text(&sub, &src.search_author);
        let book_url_raw = select_attr(&sub, &src.search_book_url, "href");
        let book_url = absolute_url(&resp.url, &book_url_raw);
        if name.is_empty() || book_url.is_empty() {
            continue;
        }
        out.push(SearchResult {
            name,
            author,
            book_url,
            source_name: src.name.clone(),
        });
    }
    Ok(out)
}

#[flutter_rust_bridge::frb(sync)]
pub fn source_book_detail(source_json: String, book_url: String) -> Result<BookDetail> {
    let src: BookSource = serde_json::from_str(&source_json).context("书源 JSON 解析失败")?;
    let resp = http_get(book_url.clone(), vec![])?;
    let doc = Html::parse_document(&resp.body);
    let name = select_text(&doc, &src.book_info_name);
    let author = select_text(&doc, &src.book_info_author);
    let intro = select_text(&doc, &src.book_info_intro);
    let toc_raw = select_attr(&doc, &src.book_info_toc_url, "href");
    let toc_url = if toc_raw.is_empty() {
        book_url.clone()
    } else {
        absolute_url(&resp.url, &toc_raw)
    };
    Ok(BookDetail {
        name,
        author,
        intro,
        toc_url,
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn source_toc(source_json: String, toc_url: String) -> Result<Vec<TocEntry>> {
    let src: BookSource = serde_json::from_str(&source_json).context("书源 JSON 解析失败")?;
    let resp = http_get(toc_url, vec![])?;
    let doc = Html::parse_document(&resp.body);
    let list_sel =
        Selector::parse(&src.toc_list).map_err(|e| anyhow!("目录列表选择器无效: {e:?}"))?;
    let mut out = Vec::new();
    for el in doc.select(&list_sel) {
        let html_str = el.html();
        let sub = Html::parse_fragment(&html_str);
        let title = select_text(&sub, &src.toc_name);
        let href = select_attr(&sub, &src.toc_url, "href");
        if title.is_empty() || href.is_empty() {
            continue;
        }
        out.push(TocEntry {
            title,
            url: absolute_url(&resp.url, &href),
        });
    }
    Ok(out)
}

#[flutter_rust_bridge::frb(sync)]
pub fn source_chapter_content(source_json: String, chapter_url: String) -> Result<String> {
    let src: BookSource = serde_json::from_str(&source_json).context("书源 JSON 解析失败")?;
    let resp = http_get(chapter_url, vec![])?;
    let doc = Html::parse_document(&resp.body);
    let sel =
        Selector::parse(&src.content_selector).map_err(|e| anyhow!("正文选择器无效: {e:?}"))?;
    let mut parts = Vec::new();
    for el in doc.select(&sel) {
        parts.push(el.text().collect::<Vec<_>>().join("\n"));
    }
    let cleaned = parts.join("\n\n").replace("\u{a0}", " ");
    Ok(cleaned)
}

fn urlencoding_lite(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}
