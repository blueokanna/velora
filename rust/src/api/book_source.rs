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
    #[serde(default)]
    pub search_cover: String,
    pub book_info_name: String,
    pub book_info_author: String,
    pub book_info_intro: String,
    #[serde(default)]
    pub book_info_cover: String,
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
    pub cover_url: String,
    pub source_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookDetail {
    pub name: String,
    pub author: String,
    pub intro: String,
    pub cover_url: String,
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

fn select_resource_url(doc: &Html, sel: &str) -> String {
    for attr in ["src", "data-src", "data-original", "data-lazy-src", "href", "content"] {
        let value = select_attr(doc, sel, attr);
        if !value.is_empty() {
            return value;
        }
    }
    String::new()
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

#[flutter_rust_bridge::frb]
pub fn source_search(source_json: String, keyword: String) -> Result<Vec<SearchResult>> {
    let src: BookSource = serde_json::from_str(&source_json).context("书源 JSON 解析失败")?;
    if !src.enabled {
        return Err(anyhow!("书源已禁用: {}", src.name));
    }
    let url = render_search_url(&src, &keyword)?;
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
        let cover_raw = select_resource_url(&sub, &src.search_cover);
        let cover_url = absolute_url(&resp.url, &cover_raw);
        if name.is_empty() || book_url.is_empty() {
            continue;
        }
        out.push(SearchResult {
            name,
            author,
            book_url,
            cover_url,
            source_name: src.name.clone(),
        });
    }
    Ok(out)
}

fn render_search_url(src: &BookSource, keyword: &str) -> Result<String> {
    if src.search_url.trim().is_empty() {
        return Err(anyhow!("书源缺少 search_url: {}", src.name));
    }
    let encoded = urlencoding_lite(keyword);
    let mut rendered = src.search_url.clone();
    for (from, to) in [
        ("{{key}}", encoded.as_str()),
        ("{key}", encoded.as_str()),
        ("{{keyword}}", encoded.as_str()),
        ("{keyword}", encoded.as_str()),
        ("{{searchKey}}", encoded.as_str()),
        ("{searchKey}", encoded.as_str()),
        ("{{page}}", "1"),
        ("{page}", "1"),
        ("{{pageNo}}", "1"),
        ("{pageNo}", "1"),
    ] {
        rendered = rendered.replace(from, to);
    }
    Ok(absolute_url(&src.url, &rendered))
}

#[flutter_rust_bridge::frb]
pub fn source_book_detail(source_json: String, book_url: String) -> Result<BookDetail> {
    let src: BookSource = serde_json::from_str(&source_json).context("书源 JSON 解析失败")?;
    let resp = http_get(book_url.clone(), vec![])?;
    let doc = Html::parse_document(&resp.body);
    let name = select_text(&doc, &src.book_info_name);
    let author = select_text(&doc, &src.book_info_author);
    let intro = select_text(&doc, &src.book_info_intro);
    let cover_raw = select_resource_url(&doc, &src.book_info_cover);
    let cover_url = absolute_url(&resp.url, &cover_raw);
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
        cover_url,
        toc_url,
    })
}

#[flutter_rust_bridge::frb]
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

#[flutter_rust_bridge::frb]
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

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_source(search_url: &str) -> BookSource {
        BookSource {
            name: "sample".to_string(),
            url: "https://example.com/base/".to_string(),
            enabled: true,
            search_url: search_url.to_string(),
            search_list: ".book".to_string(),
            search_name: ".name".to_string(),
            search_author: ".author".to_string(),
            search_book_url: "a".to_string(),
            search_cover: String::new(),
            book_info_name: "h1".to_string(),
            book_info_author: ".author".to_string(),
            book_info_intro: ".intro".to_string(),
            book_info_cover: String::new(),
            book_info_toc_url: ".toc a".to_string(),
            toc_list: ".chapter".to_string(),
            toc_name: "a".to_string(),
            toc_url: "a".to_string(),
            content_selector: "#content".to_string(),
        }
    }

    #[test]
    fn render_search_url_supports_common_legado_placeholders() {
        let src = sample_source("/search?kw={{key}}&page={{page}}");
        let url = render_search_url(&src, "测试小说").unwrap();
        assert!(url.starts_with("https://example.com/search?kw=%"));
        assert!(url.ends_with("page=1"));
    }

    #[test]
    fn render_search_url_supports_keyword_aliases() {
        let src = sample_source("https://example.com/find?q={keyword}&p={pageNo}");
        let url = render_search_url(&src, "abc").unwrap();
        assert_eq!(url, "https://example.com/find?q=abc&p=1");
    }
}
