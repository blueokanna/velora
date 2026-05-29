use anyhow::{anyhow, Context, Result};
use regex::Regex;
use scraper::{Html, Selector};
use serde::{Deserialize, Serialize};
use serde_json::Value;

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

#[derive(Clone, Debug)]
enum ExtractMode {
    Text,
    TextNodes,
    Html,
    Attr(String),
    ResourceUrl,
}

#[derive(Clone, Debug)]
struct ParsedQuery {
    selector: Option<String>,
    text_equals: Option<String>,
    mode: Option<ExtractMode>,
    cleanup: Option<(String, String)>,
}

#[derive(Clone, Debug)]
struct RegexRow {
    groups: Vec<String>,
}

#[derive(Clone, Debug)]
enum JsonPathPart {
    Key(String),
    Index(usize),
    Wildcard,
}

fn normalize_rule(rule: &str) -> ParsedQuery {
    let (core, cleanup) = split_cleanup(rule);
    let trimmed = core.trim();
    if trimmed.is_empty() {
        return ParsedQuery {
            selector: None,
            text_equals: None,
            mode: None,
            cleanup,
        };
    }
    if let Some(xpath) = parse_xpath_like_rule(trimmed) {
        return ParsedQuery {
            selector: xpath.selector,
            text_equals: xpath.text_equals,
            mode: xpath.mode,
            cleanup,
        };
    }

    let body = trimmed.strip_prefix("@css:").unwrap_or(trimmed).trim();
    if body.eq_ignore_ascii_case("text") {
        return ParsedQuery {
            selector: None,
            text_equals: None,
            mode: Some(ExtractMode::Text),
            cleanup,
        };
    }
    if body.eq_ignore_ascii_case("textNodes") {
        return ParsedQuery {
            selector: None,
            text_equals: None,
            mode: Some(ExtractMode::TextNodes),
            cleanup,
        };
    }
    if body.eq_ignore_ascii_case("all") {
        return ParsedQuery {
            selector: None,
            text_equals: None,
            mode: Some(ExtractMode::TextNodes),
            cleanup,
        };
    }

    let (selector_part, mode) = split_selector_mode(body);
    ParsedQuery {
        selector: selector_part.map(|item| normalize_css_selector(&item)),
        text_equals: None,
        mode,
        cleanup,
    }
}

fn split_cleanup(rule: &str) -> (String, Option<(String, String)>) {
    if let Some(index) = rule.find("##") {
        let core = rule[..index].trim().to_string();
        let mut rest = rule[index + 2..].trim().to_string();
        if rest.ends_with("###") {
            rest.truncate(rest.len().saturating_sub(3));
        }
        if let Some(replacement_index) = rest.find("##") {
            let pattern = rest[..replacement_index].trim().to_string();
            let replacement = rest[replacement_index + 2..].trim().to_string();
            return (core, Some((pattern, replacement)));
        }
        return (core, Some((rest.trim().to_string(), String::new())));
    }
    (rule.trim().to_string(), None)
}

fn split_selector_mode(rule: &str) -> (Option<String>, Option<ExtractMode>) {
    if let Some(index) = rule.rfind('@') {
        let selector = rule[..index].trim();
        let suffix = rule[index + 1..].trim();
        let mode = match suffix.to_ascii_lowercase().as_str() {
            "text" => Some(ExtractMode::Text),
            "textnodes" => Some(ExtractMode::TextNodes),
            "html" => Some(ExtractMode::Html),
            "src" | "href" | "content" | "data-src" | "data-original" | "data-lazy-src" => {
                Some(ExtractMode::Attr(suffix.to_string()))
            }
            _ => Some(ExtractMode::Attr(suffix.to_string())),
        };
        let selector = if selector.is_empty() {
            None
        } else {
            Some(selector.to_string())
        };
        return (selector, mode);
    }
    let selector = if rule.trim().is_empty() {
        None
    } else {
        Some(rule.trim().to_string())
    };
    (selector, None)
}

#[derive(Clone, Debug)]
struct XPathLikeQuery {
    selector: Option<String>,
    text_equals: Option<String>,
    mode: Option<ExtractMode>,
}

fn parse_xpath_like_rule(rule: &str) -> Option<XPathLikeQuery> {
    let trimmed = rule.trim();
    if !(trimmed.starts_with("//") || trimmed.starts_with("./") || trimmed.starts_with("/*")) {
        return None;
    }
    let segments = split_xpath_segments(trimmed)?;
    let mut selector_parts = Vec::new();
    let mut text_equals = None;
    let mut mode = None;

    for segment in segments {
        let converted = convert_xpath_segment(&segment.raw)?;
        if let Some(filter) = converted.text_equals {
            text_equals = Some(filter);
        }
        if converted.is_extractor {
            mode = converted.mode;
            continue;
        }
        let css = converted.css?;
        if selector_parts.is_empty() {
            selector_parts.push(css);
        } else if segment.descendant {
            selector_parts.push(format!(" {}", css));
        } else {
            selector_parts.push(format!(" > {}", css));
        }
    }

    Some(XPathLikeQuery {
        selector: if selector_parts.is_empty() {
            None
        } else {
            Some(selector_parts.join(""))
        },
        text_equals,
        mode,
    })
}

#[derive(Clone, Debug)]
struct XPathSegment {
    descendant: bool,
    raw: String,
}

fn split_xpath_segments(rule: &str) -> Option<Vec<XPathSegment>> {
    let mut chars = rule.chars().peekable();
    let mut current = String::new();
    let mut bracket_depth: usize = 0;
    let mut descendant = false;
    let mut segments = Vec::new();

    while let Some(ch) = chars.next() {
        if ch == '[' {
            bracket_depth += 1;
            current.push(ch);
            continue;
        }
        if ch == ']' {
            bracket_depth = bracket_depth.saturating_sub(1);
            current.push(ch);
            continue;
        }
        if ch == '/' && bracket_depth == 0 {
            if !current.trim().is_empty() {
                segments.push(XPathSegment {
                    descendant,
                    raw: current.trim().to_string(),
                });
                current.clear();
            }
            descendant = matches!(chars.peek(), Some('/'));
            if descendant {
                chars.next();
            }
            continue;
        }
        current.push(ch);
    }

    if !current.trim().is_empty() {
        segments.push(XPathSegment {
            descendant,
            raw: current.trim().to_string(),
        });
    }
    if segments.is_empty() {
        return None;
    }
    Some(segments)
}

#[derive(Clone, Debug)]
struct ConvertedXPathSegment {
    css: Option<String>,
    text_equals: Option<String>,
    mode: Option<ExtractMode>,
    is_extractor: bool,
}

fn convert_xpath_segment(segment: &str) -> Option<ConvertedXPathSegment> {
    let trimmed = segment.trim();
    if trimmed.eq("text()") {
        return Some(ConvertedXPathSegment {
            css: None,
            text_equals: None,
            mode: Some(ExtractMode::Text),
            is_extractor: true,
        });
    }
    if let Some(attr) = trimmed.strip_prefix('@') {
        return Some(ConvertedXPathSegment {
            css: None,
            text_equals: None,
            mode: Some(ExtractMode::Attr(attr.trim().to_string())),
            is_extractor: true,
        });
    }

    let mut raw_name = trimmed;
    let mut predicates = Vec::new();
    if let Some(index) = trimmed.find('[') {
        raw_name = trimmed[..index].trim();
        let mut rest = trimmed[index..].trim();
        while rest.starts_with('[') {
            let end = find_matching_bracket(rest)?;
            predicates.push(rest[1..end].trim().to_string());
            rest = rest[end + 1..].trim();
        }
        if !rest.is_empty() {
            return None;
        }
    }

    let mut css = if raw_name == "*" || raw_name.is_empty() {
        String::new()
    } else {
        raw_name.to_string()
    };
    let mut text_equals = None;
    for predicate in predicates {
        if let Ok(index) = predicate.parse::<usize>() {
            if index == 0 {
                return None;
            }
            css.push_str(&format!(":nth-of-type({index})"));
            continue;
        }
        if let Some(captures) = Regex::new(r#"^@([\w:-]+)\s*=\s*['\"]([^'\"]+)['\"]$"#)
            .ok()
            .and_then(|regex| regex.captures(&predicate))
        {
            let attr = captures.get(1)?.as_str();
            let value = captures.get(2)?.as_str();
            if attr == "id" && !value.is_empty() && css.is_empty() {
                css.push('#');
                css.push_str(value);
            } else {
                css.push_str(&format!("[{attr}=\"{value}\"]"));
            }
            continue;
        }
        if let Some(captures) = Regex::new(r#"^text\(\)\s*=\s*['\"]([^'\"]+)['\"]$"#)
            .ok()
            .and_then(|regex| regex.captures(&predicate))
        {
            text_equals = Some(captures.get(1)?.as_str().to_string());
            continue;
        }
        if predicate.contains("count(") || predicate.contains("position()") {
            continue;
        }
        return None;
    }

    Some(ConvertedXPathSegment {
        css: if css.is_empty() { Some("*".to_string()) } else { Some(css) },
        text_equals,
        mode: None,
        is_extractor: false,
    })
}

fn find_matching_bracket(value: &str) -> Option<usize> {
    let mut depth = 0usize;
    for (index, ch) in value.char_indices() {
        if ch == '[' {
            depth += 1;
        } else if ch == ']' {
            depth = depth.saturating_sub(1);
            if depth == 0 {
                return Some(index);
            }
        }
    }
    None
}

fn normalize_css_selector(selector: &str) -> String {
    let raw = selector.trim();
    let Ok(attr_regex) = Regex::new(r#"\[([A-Za-z0-9_:-]+)=([^\]"']+)\]"#) else {
        return raw.to_string();
    };
    let Ok(eq_regex) = Regex::new(r#":eq\((\d+)\)"#) else {
        return raw.to_string();
    };
    let normalized_attr = attr_regex
        .replace_all(raw, |caps: &regex::Captures| {
            let attr = caps.get(1).map(|item| item.as_str()).unwrap_or_default();
            let value = caps.get(2).map(|item| item.as_str()).unwrap_or_default();
            format!("[{attr}=\"{value}\"]")
        })
        .to_string();
    eq_regex
        .replace_all(&normalized_attr, |caps: &regex::Captures| {
            let index = caps
                .get(1)
                .and_then(|item| item.as_str().parse::<usize>().ok())
                .unwrap_or(0);
            format!(":nth-of-type({})", index + 1)
        })
        .to_string()
}

fn parse_selector(rule: &str) -> Result<(Selector, Option<String>)> {
    let parsed = normalize_rule(rule);
    let selector = parsed
        .selector
        .ok_or_else(|| anyhow!("选择器为空"))?;
    let selector = Selector::parse(&selector)
        .map_err(|e| anyhow!("选择器无效: {e:?}"))?;
    Ok((selector, parsed.text_equals))
}

fn text_matches(element_text: &str, expected: &Option<String>) -> bool {
    match expected {
        Some(value) => element_text.trim() == value.trim(),
        None => true,
    }
}

fn element_text(element: scraper::element_ref::ElementRef<'_>) -> String {
    element.text().collect::<Vec<_>>().join("\n").trim().to_string()
}

fn select_first_matching<'a>(
    doc: &'a Html,
    selector: &Selector,
    text_equals: &Option<String>,
) -> Option<scraper::element_ref::ElementRef<'a>> {
    doc.select(selector)
        .find(|element| text_matches(&element_text(*element), text_equals))
}

fn select_all_matching<'a>(
    doc: &'a Html,
    selector: &Selector,
    text_equals: &Option<String>,
) -> Vec<scraper::element_ref::ElementRef<'a>> {
    doc.select(selector)
        .filter(|element| text_matches(&element_text(*element), text_equals))
        .collect()
}

fn apply_cleanup(mut value: String, cleanup: &Option<(String, String)>) -> String {
    if let Some((pattern, replacement)) = cleanup {
        if !pattern.is_empty() {
            if let Ok(regex) = Regex::new(pattern) {
                value = regex.replace_all(&value, replacement.as_str()).to_string();
            }
        }
    }
    value.trim().to_string()
}

fn extract_raw_cleanup_value(raw_text: &str, cleanup: &Option<(String, String)>) -> String {
    let Some((pattern, replacement)) = cleanup else {
        return raw_text.trim().to_string();
    };
    if pattern.is_empty() {
        return raw_text.trim().to_string();
    }
    let Ok(regex) = Regex::new(pattern) else {
        return raw_text.trim().to_string();
    };
    let Some(captures) = regex.captures(raw_text) else {
        return String::new();
    };
    if replacement.is_empty() {
        return captures
            .get(0)
            .map(|item| item.as_str().trim().to_string())
            .unwrap_or_default();
    }
    let mut out = String::new();
    captures.expand(replacement, &mut out);
    out.trim().to_string()
}

fn extract_many_raw_cleanup_values(raw_text: &str, cleanup: &Option<(String, String)>) -> Vec<String> {
    let Some((pattern, replacement)) = cleanup else {
        return vec![raw_text.trim().to_string()];
    };
    if pattern.is_empty() {
        return vec![raw_text.trim().to_string()];
    }
    let Ok(regex) = Regex::new(pattern) else {
        return vec![raw_text.trim().to_string()];
    };
    let mut out = Vec::new();
    for captures in regex.captures_iter(raw_text) {
        let value = if replacement.is_empty() {
            captures
                .get(0)
                .map(|item| item.as_str().trim().to_string())
                .unwrap_or_default()
        } else {
            let mut buffer = String::new();
            captures.expand(replacement, &mut buffer);
            buffer.trim().to_string()
        };
        if !value.is_empty() {
            out.push(value);
        }
    }
    if out.is_empty() {
        return vec![String::new()];
    }
    out
}

fn extract_with_rule(
    doc: &Html,
    raw_text: &str,
    rule: &str,
    default_mode: ExtractMode,
    base_url: Option<&str>,
) -> String {
    let parsed = normalize_rule(rule);
    let uses_raw_cleanup = parsed.cleanup.is_some() && parsed.mode.is_none() && parsed.selector.is_none();
    let mode = parsed.mode.clone().unwrap_or(default_mode);
    let extracted = if let Some(selector_text) = parsed.selector {
        let Ok(selector) = Selector::parse(&selector_text) else {
            return String::new();
        };
        let Some(element) = select_first_matching(doc, &selector, &parsed.text_equals) else {
            return String::new();
        };
        extract_from_element(element, &mode, base_url)
    } else if uses_raw_cleanup {
        extract_raw_cleanup_value(raw_text, &parsed.cleanup)
    } else {
        extract_from_document(doc, &mode)
    };
    let value = if uses_raw_cleanup {
        extracted
    } else {
        apply_cleanup(extracted, &parsed.cleanup)
    };
    if uses_raw_cleanup && matches!(mode, ExtractMode::Attr(_) | ExtractMode::ResourceUrl) {
        if let Some(base) = base_url {
            return absolute_url(base, &value);
        }
    }
    value
}

fn extract_many_with_rule(
    doc: &Html,
    raw_text: &str,
    rule: &str,
    default_mode: ExtractMode,
    base_url: Option<&str>,
) -> Vec<String> {
    let parsed = normalize_rule(rule);
    let uses_raw_cleanup = parsed.cleanup.is_some() && parsed.mode.is_none() && parsed.selector.is_none();
    let mode = parsed.mode.clone().unwrap_or(default_mode);
    let values = if let Some(selector_text) = parsed.selector {
        let Ok(selector) = Selector::parse(&selector_text) else {
            return Vec::new();
        };
        select_all_matching(doc, &selector, &parsed.text_equals)
            .into_iter()
            .map(|element| extract_from_element(element, &mode, base_url))
            .collect::<Vec<_>>()
    } else if uses_raw_cleanup {
        extract_many_raw_cleanup_values(raw_text, &parsed.cleanup)
    } else {
        vec![extract_from_document(doc, &mode)]
    };
    values
        .into_iter()
        .map(|value| {
            if uses_raw_cleanup {
                value
            } else {
                apply_cleanup(value, &parsed.cleanup)
            }
        })
        .filter(|value| !value.is_empty())
        .collect()
}

fn looks_like_json_text(text: &str) -> bool {
    let trimmed = text.trim_start();
    trimmed.starts_with('{') || trimmed.starts_with('[')
}

fn parse_json_value(text: &str) -> Option<Value> {
    if !looks_like_json_text(text) {
        return None;
    }
    serde_json::from_str::<Value>(text).ok()
}

fn parse_json_path(rule: &str) -> Vec<JsonPathPart> {
    let mut trimmed = rule.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    if let Some(rest) = trimmed.strip_prefix("$.") {
        trimmed = rest;
    } else if let Some(rest) = trimmed.strip_prefix('$') {
        trimmed = rest;
    }
    trimmed = trimmed.trim_start_matches('.');
    if trimmed.is_empty() {
        return Vec::new();
    }

    let mut parts = Vec::new();
    for segment in trimmed.split('.') {
        let segment = segment.trim();
        if segment.is_empty() {
            continue;
        }
        let mut rest = segment;
        while !rest.is_empty() {
            if let Some(index) = rest.find('[') {
                let key = rest[..index].trim();
                if !key.is_empty() {
                    parts.push(JsonPathPart::Key(key.to_string()));
                }
                let after = &rest[index + 1..];
                let Some(end) = after.find(']') else {
                    break;
                };
                let token = after[..end].trim();
                if token == "*" {
                    parts.push(JsonPathPart::Wildcard);
                } else if let Ok(value) = token.parse::<usize>() {
                    parts.push(JsonPathPart::Index(value));
                }
                rest = after[end + 1..].trim();
            } else {
                parts.push(JsonPathPart::Key(rest.to_string()));
                break;
            }
        }
    }
    parts
}

fn json_nodes_from_rule<'a>(value: &'a Value, rule: &str) -> Vec<&'a Value> {
    let path = parse_json_path(rule);
    if path.is_empty() {
        return vec![value];
    }
    let mut current = vec![value];
    for part in path {
        let mut next = Vec::new();
        for node in current {
            match part {
                JsonPathPart::Key(ref key) => match node {
                    Value::Object(map) => {
                        if let Some(found) = map.get(key) {
                            next.push(found);
                        }
                    }
                    Value::Array(list) => {
                        for item in list {
                            if let Value::Object(map) = item {
                                if let Some(found) = map.get(key) {
                                    next.push(found);
                                }
                            }
                        }
                    }
                    _ => {}
                },
                JsonPathPart::Index(index) => {
                    if let Value::Array(list) = node {
                        if let Some(found) = list.get(index) {
                            next.push(found);
                        }
                    }
                }
                JsonPathPart::Wildcard => match node {
                    Value::Array(list) => next.extend(list.iter()),
                    Value::Object(map) => next.extend(map.values()),
                    _ => {}
                },
            }
        }
        current = next;
        if current.is_empty() {
            break;
        }
    }
    current
}

fn json_list_from_rule<'a>(value: &'a Value, rule: &str) -> Vec<&'a Value> {
    let nodes = json_nodes_from_rule(value, rule);
    if nodes.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for node in nodes {
        if let Value::Array(list) = node {
            out.extend(list.iter());
        } else {
            out.push(node);
        }
    }
    out
}

fn json_scalar_to_string(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(text) => text.trim().to_string(),
        Value::Number(number) => number.to_string(),
        Value::Bool(boolean) => boolean.to_string(),
        Value::Array(list) => list
            .iter()
            .map(json_scalar_to_string)
            .filter(|item| !item.is_empty())
            .collect::<Vec<_>>()
            .join("\n")
            .trim()
            .to_string(),
        Value::Object(_) => serde_json::to_string(value).unwrap_or_default(),
    }
}

fn json_string_from_rule(value: &Value, rule: &str) -> String {
    let trimmed = rule.trim();
    if trimmed.is_empty() {
        return json_scalar_to_string(value);
    }
    let nodes = json_nodes_from_rule(value, trimmed);
    for node in nodes {
        let text = json_scalar_to_string(node);
        if !text.is_empty() {
            return text;
        }
    }
    String::new()
}

fn regex_rows_from_rule(text: &str, rule: &str) -> Result<Vec<RegexRow>> {
    let pattern = normalize_regex_list_rule(rule)
        .ok_or_else(|| anyhow!("规则不是正则列表格式"))?;
    let regex = Regex::new(&pattern).map_err(|error| anyhow!("正则规则无效: {error}"))?;
    let mut rows = Vec::new();
    for captures in regex.captures_iter(text) {
        let mut groups = Vec::new();
        for index in 0..captures.len() {
            groups.push(
                captures
                    .get(index)
                    .map(|item| item.as_str().to_string())
                    .unwrap_or_default(),
            );
        }
        rows.push(RegexRow { groups });
    }
    Ok(rows)
}

fn normalize_regex_list_rule(rule: &str) -> Option<String> {
    let trimmed = rule.trim();
    if let Some(pattern) = trimmed.strip_prefix("-:") {
        return Some(pattern.trim().to_string());
    }
    if let Some(pattern) = trimmed.strip_prefix(':') {
        return Some(pattern.trim().to_string());
    }
    None
}

fn regex_value_from_rule(row: &RegexRow, rule: &str, base_url: Option<&str>) -> String {
    let (core, cleanup) = split_cleanup(rule);
    let trimmed = core.trim();
    let mut value = if let Some(group_text) = trimmed.strip_prefix('$') {
        group_text
            .parse::<usize>()
            .ok()
            .and_then(|index| row.groups.get(index).cloned())
            .unwrap_or_default()
    } else if trimmed.is_empty() {
        row.groups.get(0).cloned().unwrap_or_default()
    } else {
        trimmed.to_string()
    };
    value = apply_cleanup(value, &cleanup);
    if let Some(base) = base_url {
        absolute_url(base, &value)
    } else {
        value
    }
}

fn extract_from_document(doc: &Html, mode: &ExtractMode) -> String {
    match mode {
        ExtractMode::Text | ExtractMode::TextNodes => doc.root_element().text().collect::<Vec<_>>().join("\n"),
        ExtractMode::Html => doc.root_element().html(),
        ExtractMode::Attr(_) | ExtractMode::ResourceUrl => String::new(),
    }
}

fn extract_from_element(
    element: scraper::element_ref::ElementRef<'_>,
    mode: &ExtractMode,
    base_url: Option<&str>,
) -> String {
    match mode {
        ExtractMode::Text | ExtractMode::TextNodes => element.text().collect::<Vec<_>>().join("\n"),
        ExtractMode::Html => element.html(),
        ExtractMode::Attr(attr) => {
            let value = element.value().attr(attr).unwrap_or_default().to_string();
            if let Some(base) = base_url {
                absolute_url(base, &value)
            } else {
                value
            }
        }
        ExtractMode::ResourceUrl => {
            for attr in ["src", "data-src", "data-original", "data-lazy-src", "href", "content"] {
                if let Some(value) = element.value().attr(attr) {
                    return if let Some(base) = base_url {
                        absolute_url(base, value)
                    } else {
                        value.to_string()
                    };
                }
            }
            String::new()
        }
    }
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
    if let Some(json) = parse_json_value(&resp.body) {
        let mut out = Vec::new();
        for item in json_list_from_rule(&json, &src.search_list) {
            let name = json_string_from_rule(item, &src.search_name);
            let author = json_string_from_rule(item, &src.search_author);
            let book_url = absolute_url(&resp.url, &json_string_from_rule(item, &src.search_book_url));
            let cover_url = absolute_url(&resp.url, &json_string_from_rule(item, &src.search_cover));
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
        return Ok(out);
    }
    if let Ok(rows) = regex_rows_from_rule(&resp.body, &src.search_list) {
        let mut out = Vec::new();
        for row in rows {
            let name = regex_value_from_rule(&row, &src.search_name, None);
            let author = regex_value_from_rule(&row, &src.search_author, None);
            let book_url = regex_value_from_rule(&row, &src.search_book_url, Some(&resp.url));
            let cover_url = regex_value_from_rule(&row, &src.search_cover, Some(&resp.url));
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
        if !out.is_empty() {
            return Ok(out);
        }
    }
    let doc = Html::parse_document(&resp.body);
    let (list_sel, text_equals) =
        parse_selector(&src.search_list).map_err(|e| anyhow!("搜索列表选择器无效: {e}"))?;
    let mut out = Vec::new();
    for el in select_all_matching(&doc, &list_sel, &text_equals) {
        let html_str = el.html();
        let sub = Html::parse_fragment(&html_str);
        let name = extract_with_rule(&sub, &html_str, &src.search_name, ExtractMode::Text, Some(&resp.url));
        let author = extract_with_rule(&sub, &html_str, &src.search_author, ExtractMode::Text, Some(&resp.url));
        let book_url = extract_with_rule(&sub, &html_str, &src.search_book_url, ExtractMode::Attr("href".to_string()), Some(&resp.url));
        let cover_url = extract_with_rule(&sub, &html_str, &src.search_cover, ExtractMode::ResourceUrl, Some(&resp.url));
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
    if let Some(json) = parse_json_value(&resp.body) {
        let name = json_string_from_rule(&json, &src.book_info_name);
        let author = json_string_from_rule(&json, &src.book_info_author);
        let intro = json_string_from_rule(&json, &src.book_info_intro);
        let cover_url = absolute_url(&resp.url, &json_string_from_rule(&json, &src.book_info_cover));
        let toc_value = json_string_from_rule(&json, &src.book_info_toc_url);
        let toc_url = if toc_value.is_empty() {
            book_url.clone()
        } else {
            absolute_url(&resp.url, &toc_value)
        };
        return Ok(BookDetail {
            name,
            author,
            intro,
            cover_url,
            toc_url,
        });
    }
    let doc = Html::parse_document(&resp.body);
    let name = extract_with_rule(&doc, &resp.body, &src.book_info_name, ExtractMode::Text, Some(&resp.url));
    let author = extract_with_rule(&doc, &resp.body, &src.book_info_author, ExtractMode::Text, Some(&resp.url));
    let intro = extract_with_rule(&doc, &resp.body, &src.book_info_intro, ExtractMode::TextNodes, Some(&resp.url));
    let cover_url = extract_with_rule(&doc, &resp.body, &src.book_info_cover, ExtractMode::ResourceUrl, Some(&resp.url));
    let toc_value = extract_with_rule(&doc, &resp.body, &src.book_info_toc_url, ExtractMode::Attr("href".to_string()), Some(&resp.url));
    let toc_url = if toc_value.is_empty() {
        book_url.clone()
    } else {
        toc_value
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
    if let Some(json) = parse_json_value(&resp.body) {
        let mut out = Vec::new();
        for item in json_list_from_rule(&json, &src.toc_list) {
            let title = json_string_from_rule(item, &src.toc_name);
            let href = absolute_url(&resp.url, &json_string_from_rule(item, &src.toc_url));
            if title.is_empty() || href.is_empty() {
                continue;
            }
            out.push(TocEntry { title, url: href });
        }
        return Ok(out);
    }
    if let Ok(rows) = regex_rows_from_rule(&resp.body, &src.toc_list) {
        let mut out = Vec::new();
        for row in rows {
            let title = regex_value_from_rule(&row, &src.toc_name, None);
            let href = regex_value_from_rule(&row, &src.toc_url, Some(&resp.url));
            if title.is_empty() || href.is_empty() {
                continue;
            }
            out.push(TocEntry { title, url: href });
        }
        if !out.is_empty() {
            return Ok(out);
        }
    }
    let doc = Html::parse_document(&resp.body);
    let (list_sel, text_equals) =
        parse_selector(&src.toc_list).map_err(|e| anyhow!("目录列表选择器无效: {e}"))?;
    let mut out = Vec::new();
    for el in select_all_matching(&doc, &list_sel, &text_equals) {
        let html_str = el.html();
        let sub = Html::parse_fragment(&html_str);
        let title = extract_with_rule(&sub, &html_str, &src.toc_name, ExtractMode::Text, Some(&resp.url));
        let href = extract_with_rule(&sub, &html_str, &src.toc_url, ExtractMode::Attr("href".to_string()), Some(&resp.url));
        if title.is_empty() || href.is_empty() {
            continue;
        }
        out.push(TocEntry {
            title,
            url: href,
        });
    }
    Ok(out)
}

#[flutter_rust_bridge::frb]
pub fn source_chapter_content(source_json: String, chapter_url: String) -> Result<String> {
    let src: BookSource = serde_json::from_str(&source_json).context("书源 JSON 解析失败")?;
    let resp = http_get(chapter_url, vec![])?;
    if let Some(json) = parse_json_value(&resp.body) {
        let content = json_string_from_rule(&json, &src.content_selector);
        if !content.is_empty() {
            return Ok(content.replace("\u{a0}", " ").trim().to_string());
        }
    }
    let doc = Html::parse_document(&resp.body);
    let parts = extract_many_with_rule(&doc, &resp.body, &src.content_selector, ExtractMode::TextNodes, Some(&resp.url));
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

    #[test]
    fn json_rule_helpers_support_common_yuedu_paths() {
        let value: Value = serde_json::from_str(
            r#"{"info":{"Datas":[{"title":"书A","author":"作者A","url":"/book/a"}]}}"#,
        )
        .unwrap();
        let list = json_list_from_rule(&value, "$.info.Datas");
        assert_eq!(list.len(), 1);
        assert_eq!(json_string_from_rule(list[0], "title"), "书A");
        assert_eq!(json_string_from_rule(list[0], "author"), "作者A");
        assert_eq!(json_string_from_rule(list[0], "url"), "/book/a");
    }

    #[test]
    fn regex_rule_helpers_support_capture_groups() {
        let rows = regex_rows_from_rule(
            r#"<li><a href="/chapter/1">第一章</a></li>"#,
            r#"-:<li><a href=\"([^\"]+)\">([^<]+)</a>"#,
        )
        .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(regex_value_from_rule(&rows[0], "$1", Some("https://example.com/book/")), "https://example.com/chapter/1");
        assert_eq!(regex_value_from_rule(&rows[0], "$2", None), "第一章");
    }

    #[test]
    fn extract_with_rule_supports_raw_html_regex_capture() {
        let html = r#"<html><head><meta property="og:image" content="/cover.jpg"></head><body></body></html>"#;
        let doc = Html::parse_document(html);
        let value = extract_with_rule(
            &doc,
            html,
            r#"##og:image\"[^\"]+\"([^\"]*)##$1###"#,
            ExtractMode::Text,
            Some("https://example.com/base/"),
        );
        assert_eq!(value, "/cover.jpg");
    }

    #[test]
    fn extract_with_rule_supports_legado_css_prefix_and_attr_extractors() {
        let doc = Html::parse_document(
            r#"<html><body><div class='book'><a class='name' href='/book/1'>测试书</a><img class='cover' data-src='/cover.jpg' /></div><meta property='og:image' content='/og.jpg' /></body></html>"#,
        );
        let raw = doc.root_element().html();
        assert_eq!(
            extract_with_rule(&doc, &raw, "@css:.name@text", ExtractMode::Text, Some("https://example.com/base/")),
            "测试书"
        );
        assert_eq!(
            extract_with_rule(&doc, &raw, ".name", ExtractMode::Attr("href".to_string()), Some("https://example.com/base/")),
            "https://example.com/book/1"
        );
        assert_eq!(
            extract_with_rule(&doc, &raw, "@css:[property=og:image]@content", ExtractMode::Text, Some("https://example.com/base/")),
            "https://example.com/og.jpg"
        );
        assert_eq!(
            extract_with_rule(&doc, &raw, "@css:.cover", ExtractMode::ResourceUrl, Some("https://example.com/base/")),
            "https://example.com/cover.jpg"
        );
    }

    #[test]
    fn parse_xpath_like_rule_supports_common_yuedu_subset() {
        let toc = parse_xpath_like_rule(r#"//*[@id="sitebox"]/dl"#).unwrap();
        assert_eq!(toc.selector.unwrap(), "#sitebox > dl");

        let title = parse_xpath_like_rule(r#"//h3/a/text()"#).unwrap();
        assert_eq!(title.selector.unwrap(), "h3 > a");
        assert!(matches!(title.mode, Some(ExtractMode::Text)));

        let author = parse_xpath_like_rule(r#"//*[@property="og:novel:author"]/@content"#).unwrap();
        assert_eq!(author.selector.unwrap(), r#"[property="og:novel:author"]"#);
        assert!(matches!(author.mode, Some(ExtractMode::Attr(ref attr)) if attr == "content"));
    }

    #[test]
    fn extract_with_rule_applies_cleanup_suffix() {
        let doc = Html::parse_document(r#"<html><body><div id='content'>正文内容 搜索一下 下载APP</div></body></html>"#);
        let raw = doc.root_element().html();
        let value = extract_with_rule(
            &doc,
            &raw,
            r#"@css:#content@text##搜索一下|下载APP"#,
            ExtractMode::Text,
            Some("https://example.com"),
        );
        assert_eq!(value, "正文内容");
    }
}
