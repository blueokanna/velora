use anyhow::{anyhow, Result};
use encoding_rs::Encoding;
use regex::Regex;
use scraper::{Html, Selector};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::api::source_runtime::{
    failure, fetch_for_source_request, finish_request, record_source_failure,
    record_source_success, register_request, FailureKind, FetchTrace, SourceFailureInfo,
    SourceOperation,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookSource {
    pub name: String,
    pub url: String,
    pub enabled: bool,
    #[serde(default)]
    pub book_source_type: u8,
    pub search_url: String,
    pub search_list: String,
    pub search_name: String,
    pub search_author: String,
    pub search_book_url: String,
    #[serde(default)]
    pub search_cover: String,
    #[serde(default)]
    pub book_info_init: String,
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
    #[serde(default = "default_rule_version", alias = "version")]
    pub rule_version: u32,
    #[serde(default)]
    pub validation: SourceValidation,
}

fn default_rule_version() -> u32 {
    1
}

fn default_min_text_chars() -> usize {
    100
}

fn default_deny_keywords() -> Vec<String> {
    [
        "验证码",
        "访问过于频繁",
        "访问频繁",
        "人机验证",
        "安全验证",
        "内容加载失败",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceValidation {
    #[serde(default = "default_min_text_chars")]
    pub min_text_chars: usize,
    #[serde(default = "default_deny_keywords")]
    pub deny_keywords: Vec<String>,
}

#[flutter_rust_bridge::frb(ignore)]
impl Default for SourceValidation {
    fn default() -> Self {
        Self {
            min_text_chars: default_min_text_chars(),
            deny_keywords: default_deny_keywords(),
        }
    }
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceSearchOutcome {
    pub results: Vec<SearchResult>,
    pub failure: Option<SourceFailureInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceBookDetailOutcome {
    pub detail: Option<BookDetail>,
    pub failure: Option<SourceFailureInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceTocOutcome {
    pub entries: Vec<TocEntry>,
    pub failure: Option<SourceFailureInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceContentOutcome {
    pub content: String,
    pub failure: Option<SourceFailureInfo>,
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
struct SourceRequest {
    url: String,
    method: String,
    body: Option<String>,
    headers: Vec<(String, String)>,
}

#[derive(Clone, Debug)]
enum JsonPathPart {
    Key(String),
    Index(usize),
    Wildcard,
}

fn normalize_rule(rule: &str) -> ParsedQuery {
    let static_rule = strip_script_sections(rule);
    let (core, cleanup) = split_cleanup(&static_rule);
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
    if body.eq_ignore_ascii_case("html") {
        return ParsedQuery {
            selector: None,
            text_equals: None,
            mode: Some(ExtractMode::Html),
            cleanup,
        };
    }
    if matches!(
        body.to_ascii_lowercase().as_str(),
        "src" | "href" | "content" | "onclick" | "data-src" | "data-original" | "data-lazy-src"
    ) {
        return ParsedQuery {
            selector: None,
            text_equals: None,
            mode: Some(ExtractMode::Attr(body.to_string())),
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

fn strip_script_sections(rule: &str) -> String {
    let without_blocks = Regex::new(r"(?is)<js>.*?</js>")
        .map(|regex| regex.replace_all(rule, "").to_string())
        .unwrap_or_else(|_| rule.to_string());
    let trimmed = without_blocks.trim();
    if trimmed.to_ascii_lowercase().starts_with("@js:") {
        return String::new();
    }
    if let Some(index) = trimmed.to_ascii_lowercase().find("@js:") {
        return trimmed[..index].trim().to_string();
    }
    trimmed.to_string()
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
        css: if css.is_empty() {
            Some("*".to_string())
        } else {
            Some(css)
        },
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
    let raw = raw.split("||").next().unwrap_or(raw).replace("&&", ",");
    let translated = raw
        .split(',')
        .map(normalize_legado_selector_chain)
        .filter(|item| !item.is_empty())
        .collect::<Vec<_>>()
        .join(", ");
    let Ok(attr_regex) = Regex::new(r#"\[([A-Za-z0-9_:-]+)=([^\]"']+)\]"#) else {
        return translated;
    };
    let Ok(eq_regex) = Regex::new(r#":eq\((\d+)\)"#) else {
        return raw.to_string();
    };
    let normalized_attr = attr_regex
        .replace_all(&translated, |caps: &regex::Captures| {
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

fn normalize_legado_selector_chain(raw: &str) -> String {
    raw.split('@')
        .map(str::trim)
        .filter(|segment| !segment.is_empty())
        .map(normalize_legado_selector_segment)
        .filter(|segment| !segment.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

fn normalize_legado_selector_segment(segment: &str) -> String {
    if let Some(value) = segment
        .trim()
        .strip_prefix("children[")
        .and_then(|value| value.strip_suffix(']'))
    {
        let child = value.parse::<usize>().unwrap_or(0) + 1;
        return format!("> *:nth-child({child})");
    }
    let (base, index) = split_legado_index(segment.trim());
    let mut selector = if let Some(value) = base.strip_prefix("class.") {
        format!(".{value}")
    } else if let Some(value) = base.strip_prefix("id.") {
        format!("#{value}")
    } else if let Some(value) = base.strip_prefix("tag.") {
        value.to_string()
    } else {
        base.to_string()
    };
    if let Some(index) = index {
        match index.as_str() {
            "0" => {}
            "-1" => selector.push_str(":last-of-type"),
            "!0" => selector.push_str(":not(:first-of-type)"),
            "!-1" => selector.push_str(":not(:last-of-type)"),
            value if value.starts_with('!') => {
                if let Ok(value) = value[1..].parse::<usize>() {
                    selector.push_str(&format!(":not(:nth-of-type({}))", value + 1));
                }
            }
            value => {
                if let Ok(value) = value.parse::<usize>() {
                    selector.push_str(&format!(":nth-of-type({})", value + 1));
                }
            }
        }
    }
    selector
}

fn split_legado_index(segment: &str) -> (&str, Option<String>) {
    let Ok(regex) = Regex::new(r"^(.*?)(?:\.(!?-?\d+|\d+:\d+)|\[(\d+)(?::\d+)?\]|(!-?\d+))$")
    else {
        return (segment, None);
    };
    let Some(captures) = regex.captures(segment) else {
        return (segment, None);
    };
    let base = captures.get(1).map(|item| item.as_str()).unwrap_or(segment);
    let raw_index = captures
        .get(2)
        .or_else(|| captures.get(3))
        .or_else(|| captures.get(4))
        .map(|item| item.as_str());
    let index = raw_index.map(|value| value.split(':').next().unwrap_or(value).to_string());
    (base, index)
}

fn parse_selector(rule: &str) -> Result<(Selector, Option<String>)> {
    let parsed = normalize_rule(rule);
    let selector = parsed.selector.ok_or_else(|| anyhow!("选择器为空"))?;
    let selector = Selector::parse(&selector).map_err(|e| anyhow!("选择器无效: {e:?}"))?;
    Ok((selector, parsed.text_equals))
}

fn text_matches(element_text: &str, expected: &Option<String>) -> bool {
    match expected {
        Some(value) => element_text.trim() == value.trim(),
        None => true,
    }
}

fn element_text(element: scraper::element_ref::ElementRef<'_>) -> String {
    element
        .text()
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
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

fn extract_many_raw_cleanup_values(
    raw_text: &str,
    cleanup: &Option<(String, String)>,
) -> Vec<String> {
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
    let uses_raw_cleanup =
        parsed.cleanup.is_some() && parsed.mode.is_none() && parsed.selector.is_none();
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
    let uses_raw_cleanup =
        parsed.cleanup.is_some() && parsed.mode.is_none() && parsed.selector.is_none();
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

fn json_nodes_from_single_rule<'a>(value: &'a Value, rule: &str) -> Vec<&'a Value> {
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

fn json_nodes_from_rule<'a>(value: &'a Value, rule: &str) -> Vec<&'a Value> {
    let normalized = strip_script_sections(rule);
    let normalized = split_cleanup(&normalized).0;
    let mut out = Vec::new();
    for union_part in normalized.split("&&") {
        for alternative in union_part.split("||") {
            let found = json_nodes_from_single_rule(value, alternative.trim());
            if !found.is_empty() {
                out.extend(found);
                break;
            }
        }
    }
    out
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
    let normalized = strip_script_sections(rule);
    let (core, cleanup) = split_cleanup(&normalized);
    let trimmed = core.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let rendered = if trimmed.contains("{{") {
        render_json_template(value, trimmed)
    } else {
        let nodes = json_nodes_from_rule(value, trimmed);
        let resolved = nodes
            .into_iter()
            .map(json_scalar_to_string)
            .find(|text| !text.is_empty())
            .unwrap_or_default();
        if resolved.is_empty() && looks_like_literal_json_rule(trimmed) {
            trimmed.to_string()
        } else {
            resolved
        }
    };
    apply_cleanup(rendered, &cleanup)
}

fn render_json_template(value: &Value, template: &str) -> String {
    let Ok(regex) = Regex::new(r"\{\{\s*([^{}]+?)\s*\}\}") else {
        return template.to_string();
    };
    regex
        .replace_all(template, |captures: &regex::Captures| {
            let path = captures
                .get(1)
                .map(|item| item.as_str())
                .unwrap_or_default();
            json_nodes_from_rule(value, path)
                .into_iter()
                .map(json_scalar_to_string)
                .find(|text| !text.is_empty())
                .unwrap_or_default()
        })
        .to_string()
}

fn looks_like_literal_json_rule(rule: &str) -> bool {
    rule.starts_with('/')
        || rule.starts_with("http://")
        || rule.starts_with("https://")
        || rule.starts_with("//")
}

fn regex_rows_from_rule(text: &str, rule: &str) -> Result<Vec<RegexRow>> {
    let pattern = normalize_regex_list_rule(rule).ok_or_else(|| anyhow!("规则不是正则列表格式"))?;
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
        ExtractMode::Text | ExtractMode::TextNodes => {
            doc.root_element().text().collect::<Vec<_>>().join("\n")
        }
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
        ExtractMode::Html => element.inner_html(),
        ExtractMode::Attr(attr) => {
            let value = element.value().attr(attr).unwrap_or_default().to_string();
            if let Some(base) = base_url {
                absolute_url(base, &value)
            } else {
                value
            }
        }
        ExtractMode::ResourceUrl => {
            for attr in [
                "src",
                "data-src",
                "data-original",
                "data-lazy-src",
                "href",
                "content",
            ] {
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
    let clean_base = base.split("##").next().unwrap_or(base).trim();
    if let Ok(b) = url::Url::parse(clean_base) {
        if let Ok(u) = b.join(href) {
            return u.to_string();
        }
    }
    href.to_string()
}

fn parse_source(source_json: &str) -> std::result::Result<BookSource, SourceFailureInfo> {
    serde_json::from_str(source_json).map_err(|error| {
        failure(
            FailureKind::InvalidRule,
            format!("书源 JSON 解析失败: {error}"),
            None,
        )
    })
}

fn source_fetch(
    src: &BookSource,
    operation: SourceOperation,
    url: &str,
    cancellation: Option<&tokio_util::sync::CancellationToken>,
) -> std::result::Result<FetchTrace, SourceFailureInfo> {
    let request = parse_source_request(url, &src.url)
        .map_err(|error| failure(FailureKind::InvalidRule, error.to_string(), None))?;
    fetch_for_source_request(
        &src.name,
        &src.url,
        operation,
        &request.url,
        &request.headers,
        &request.method,
        request.body.as_deref(),
        src.rule_version,
        cancellation,
    )
}

fn parse_source_request(raw: &str, base_url: &str) -> Result<SourceRequest> {
    let raw = strip_script_sections(raw);
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.to_ascii_lowercase().starts_with("@js:") {
        return Err(anyhow!("书源请求依赖不受支持的 JavaScript 规则"));
    }
    let (url_part, options) = split_request_options(trimmed);
    let url = absolute_url(base_url, url_part.trim());
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err(anyhow!("书源请求 URL 无效: {url_part}"));
    }
    let mut method = "GET".to_string();
    let mut body = None;
    let mut headers = Vec::new();
    if let Some(options) = options {
        if let Some(value) = loose_option_value(options, "method") {
            method = value.to_ascii_uppercase();
        }
        body = loose_option_value(options, "body");
        headers = loose_headers(options);
        if body.is_some() && method == "GET" {
            method = "POST".to_string();
        }
        if body.is_some()
            && !headers
                .iter()
                .any(|(key, _)| key.eq_ignore_ascii_case("content-type"))
        {
            let charset = loose_option_value(options, "charset")
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| "UTF-8".to_string());
            headers.push((
                "Content-Type".to_string(),
                format!("application/x-www-form-urlencoded; charset={charset}"),
            ));
        }
    }
    Ok(SourceRequest {
        url,
        method,
        body,
        headers,
    })
}

fn split_request_options(raw: &str) -> (&str, Option<&str>) {
    for (index, _) in raw.match_indices(',') {
        let rest = raw[index + 1..].trim_start();
        if rest.starts_with('{') {
            return (&raw[..index], Some(rest));
        }
    }
    (raw, None)
}

fn loose_option_value(options: &str, key: &str) -> Option<String> {
    let pattern = format!(
        r#"(?is)['"]{}['"]\s*:\s*['"]([^'"]*)['"]"#,
        regex::escape(key)
    );
    Regex::new(&pattern)
        .ok()?
        .captures(options)
        .and_then(|captures| captures.get(1))
        .map(|value| value.as_str().to_string())
}

fn loose_headers(options: &str) -> Vec<(String, String)> {
    let Some(block) = Regex::new(r#"(?is)['"]headers['"]\s*:\s*\{([^}]*)\}"#)
        .ok()
        .and_then(|regex| regex.captures(options))
        .and_then(|captures| captures.get(1))
        .map(|value| value.as_str())
    else {
        return Vec::new();
    };
    let Ok(pair_regex) = Regex::new(r#"['"]([^'"]+)['"]\s*:\s*['"]([^'"]*)['"]"#) else {
        return Vec::new();
    };
    pair_regex
        .captures_iter(block)
        .filter_map(|captures| {
            Some((
                captures.get(1)?.as_str().to_string(),
                captures.get(2)?.as_str().to_string(),
            ))
        })
        .collect()
}

fn blocked_response(src: &BookSource, text: &str) -> bool {
    default_deny_keywords()
        .iter()
        .chain(src.validation.deny_keywords.iter())
        .any(|keyword| !keyword.is_empty() && text.contains(keyword))
}

fn empty_parse_failure(src: &BookSource, body: &str, operation: &str) -> SourceFailureInfo {
    if blocked_response(src, body) {
        failure(
            FailureKind::AuthDenied,
            format!("{operation}响应包含验证码或访问限制页面"),
            None,
        )
    } else {
        failure(
            FailureKind::ParserBroken,
            format!("{operation}规则未解析出有效内容"),
            None,
        )
    }
}

fn validate_chapter_content(
    src: &BookSource,
    response_body: &str,
    content: &str,
) -> std::result::Result<usize, SourceFailureInfo> {
    if blocked_response(src, content)
        || (content.is_empty() && blocked_response(src, response_body))
    {
        return Err(failure(
            FailureKind::AuthDenied,
            "正文响应包含验证码或访问限制页面",
            None,
        ));
    }
    let non_whitespace_chars = content
        .chars()
        .filter(|value| !value.is_whitespace())
        .count();
    let minimum = src.validation.min_text_chars.max(1);
    if non_whitespace_chars < minimum {
        return Err(failure(
            FailureKind::InvalidContent,
            format!("正文有效字符不足（实际 {non_whitespace_chars}，要求至少 {minimum}）"),
            None,
        ));
    }
    Ok(non_whitespace_chars)
}

fn source_search_impl(
    source_json: &str,
    keyword: &str,
    cancellation: Option<&tokio_util::sync::CancellationToken>,
) -> std::result::Result<Vec<SearchResult>, SourceFailureInfo> {
    let src = parse_source(source_json)?;
    if !src.enabled {
        return Err(failure(
            FailureKind::InvalidRule,
            format!("书源已禁用: {}", src.name),
            None,
        ));
    }
    let url = render_search_request_rule(&src, keyword)
        .map_err(|error| failure(FailureKind::InvalidRule, error.to_string(), None))?;
    let trace = source_fetch(&src, SourceOperation::Search, &url, cancellation)?;
    let resp = &trace.response;
    let parsed_result = if let Some(json) = parse_json_value(&resp.body) {
        let mut out = Vec::new();
        for item in json_list_from_rule(&json, &src.search_list) {
            let name = json_string_from_rule(item, &src.search_name);
            let author = json_string_from_rule(item, &src.search_author);
            let book_url = absolute_url(
                &resp.url,
                &json_string_from_rule(item, &src.search_book_url),
            );
            let cover_url =
                absolute_url(&resp.url, &json_string_from_rule(item, &src.search_cover));
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
    } else if let Ok(rows) = regex_rows_from_rule(&resp.body, &src.search_list) {
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
            Ok(out)
        } else {
            parse_search_html(&src, resp)
        }
    } else {
        parse_search_html(&src, resp)
    };
    let parsed = match parsed_result {
        Ok(parsed) => parsed,
        Err(source_failure) => {
            record_source_failure(&trace, &source_failure);
            return Err(source_failure);
        }
    };
    if parsed.is_empty() {
        let source_failure = empty_parse_failure(&src, &resp.body, "搜索");
        record_source_failure(&trace, &source_failure);
        return Err(source_failure);
    }
    record_source_success(&trace, parsed.len(), 0);
    Ok(parsed)
}

fn parse_search_html(
    src: &BookSource,
    resp: &crate::api::http_source::HttpResponse,
) -> std::result::Result<Vec<SearchResult>, SourceFailureInfo> {
    let doc = Html::parse_document(&resp.body);
    let (list_sel, text_equals) = parse_selector(&src.search_list).map_err(|error| {
        failure(
            FailureKind::InvalidRule,
            format!("搜索列表选择器无效: {error}"),
            None,
        )
    })?;
    let mut out = Vec::new();
    for el in select_all_matching(&doc, &list_sel, &text_equals) {
        let html_str = el.html();
        let sub = Html::parse_fragment(&html_str);
        let name = extract_with_rule(
            &sub,
            &html_str,
            &src.search_name,
            ExtractMode::Text,
            Some(&resp.url),
        );
        let author = extract_with_rule(
            &sub,
            &html_str,
            &src.search_author,
            ExtractMode::Text,
            Some(&resp.url),
        );
        let book_url = extract_with_rule(
            &sub,
            &html_str,
            &src.search_book_url,
            ExtractMode::Attr("href".to_string()),
            Some(&resp.url),
        );
        let cover_url = extract_with_rule(
            &sub,
            &html_str,
            &src.search_cover,
            ExtractMode::ResourceUrl,
            Some(&resp.url),
        );
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

#[flutter_rust_bridge::frb]
pub fn source_search(source_json: String, keyword: String) -> Result<Vec<SearchResult>> {
    source_search_impl(&source_json, &keyword, None).map_err(anyhow::Error::new)
}

#[flutter_rust_bridge::frb]
pub fn source_search_reliable(
    source_json: String,
    keyword: String,
    request_id: String,
) -> SourceSearchOutcome {
    let cancellation = register_request(&request_id);
    let result = source_search_impl(&source_json, &keyword, cancellation.as_ref());
    finish_request(&request_id);
    match result {
        Ok(results) => SourceSearchOutcome {
            results,
            failure: None,
        },
        Err(source_failure) => SourceSearchOutcome {
            results: Vec::new(),
            failure: Some(source_failure),
        },
    }
}

#[cfg(test)]
fn render_search_url(src: &BookSource, keyword: &str) -> Result<String> {
    let rendered = render_search_request_rule(src, keyword)?;
    Ok(parse_source_request(&rendered, &src.url)?.url)
}

fn render_search_request_rule(src: &BookSource, keyword: &str) -> Result<String> {
    if src.search_url.trim().is_empty() {
        return Err(anyhow!("书源缺少 search_url: {}", src.name));
    }
    let encoded = encode_search_keyword(keyword, &src.search_url);
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
    Ok(rendered)
}

fn source_book_detail_impl(
    source_json: &str,
    book_url: &str,
    cancellation: Option<&tokio_util::sync::CancellationToken>,
) -> std::result::Result<BookDetail, SourceFailureInfo> {
    let src = parse_source(source_json)?;
    let trace = source_fetch(&src, SourceOperation::BookDetail, book_url, cancellation)?;
    let resp = &trace.response;
    let detail = if let Some(json) = parse_json_value(&resp.body) {
        let detail_root = if src.book_info_init.trim().is_empty() {
            &json
        } else {
            json_nodes_from_rule(&json, &src.book_info_init)
                .into_iter()
                .next()
                .unwrap_or(&json)
        };
        let name = json_string_from_rule(detail_root, &src.book_info_name);
        let author = json_string_from_rule(detail_root, &src.book_info_author);
        let intro = json_string_from_rule(detail_root, &src.book_info_intro);
        let cover_url = absolute_url(
            &resp.url,
            &json_string_from_rule(detail_root, &src.book_info_cover),
        );
        let toc_value = json_string_from_rule(detail_root, &src.book_info_toc_url);
        let toc_url = if toc_value.is_empty() {
            book_url.to_string()
        } else {
            absolute_url(&resp.url, &toc_value)
        };
        BookDetail {
            name,
            author,
            intro,
            cover_url,
            toc_url,
        }
    } else {
        let doc = Html::parse_document(&resp.body);
        let name = extract_with_rule(
            &doc,
            &resp.body,
            &src.book_info_name,
            ExtractMode::Text,
            Some(&resp.url),
        );
        let author = extract_with_rule(
            &doc,
            &resp.body,
            &src.book_info_author,
            ExtractMode::Text,
            Some(&resp.url),
        );
        let intro = extract_with_rule(
            &doc,
            &resp.body,
            &src.book_info_intro,
            ExtractMode::TextNodes,
            Some(&resp.url),
        );
        let cover_url = extract_with_rule(
            &doc,
            &resp.body,
            &src.book_info_cover,
            ExtractMode::ResourceUrl,
            Some(&resp.url),
        );
        let toc_value = extract_with_rule(
            &doc,
            &resp.body,
            &src.book_info_toc_url,
            ExtractMode::Attr("href".to_string()),
            Some(&resp.url),
        );
        let toc_url = if toc_value.is_empty() {
            book_url.to_string()
        } else {
            toc_value
        };
        BookDetail {
            name,
            author,
            intro,
            cover_url,
            toc_url,
        }
    };
    if detail.toc_url.trim().is_empty() {
        let source_failure = empty_parse_failure(&src, &resp.body, "详情");
        record_source_failure(&trace, &source_failure);
        return Err(source_failure);
    }
    record_source_success(&trace, 1, detail.intro.chars().count());
    Ok(detail)
}

#[flutter_rust_bridge::frb]
pub fn source_book_detail(source_json: String, book_url: String) -> Result<BookDetail> {
    source_book_detail_impl(&source_json, &book_url, None).map_err(anyhow::Error::new)
}

#[flutter_rust_bridge::frb]
pub fn source_book_detail_reliable(
    source_json: String,
    book_url: String,
    request_id: String,
) -> SourceBookDetailOutcome {
    let cancellation = register_request(&request_id);
    let result = source_book_detail_impl(&source_json, &book_url, cancellation.as_ref());
    finish_request(&request_id);
    match result {
        Ok(detail) => SourceBookDetailOutcome {
            detail: Some(detail),
            failure: None,
        },
        Err(source_failure) => SourceBookDetailOutcome {
            detail: None,
            failure: Some(source_failure),
        },
    }
}

fn source_toc_impl(
    source_json: &str,
    toc_url: &str,
    cancellation: Option<&tokio_util::sync::CancellationToken>,
) -> std::result::Result<Vec<TocEntry>, SourceFailureInfo> {
    let src = parse_source(source_json)?;
    let trace = source_fetch(&src, SourceOperation::Toc, toc_url, cancellation)?;
    let resp = &trace.response;
    let parsed_result = if let Some(json) = parse_json_value(&resp.body) {
        let mut out = Vec::new();
        for item in json_list_from_rule(&json, &src.toc_list) {
            let title = json_string_from_rule(item, &src.toc_name);
            let href = absolute_url(&resp.url, &json_string_from_rule(item, &src.toc_url));
            if title.is_empty() || href.is_empty() {
                continue;
            }
            out.push(TocEntry { title, url: href });
        }
        Ok(out)
    } else if let Ok(rows) = regex_rows_from_rule(&resp.body, &src.toc_list) {
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
            Ok(out)
        } else {
            parse_toc_html(&src, resp)
        }
    } else {
        parse_toc_html(&src, resp)
    };
    let parsed = match parsed_result {
        Ok(parsed) => parsed,
        Err(source_failure) => {
            record_source_failure(&trace, &source_failure);
            return Err(source_failure);
        }
    };
    if parsed.is_empty() {
        let source_failure = empty_parse_failure(&src, &resp.body, "目录");
        record_source_failure(&trace, &source_failure);
        return Err(source_failure);
    }
    record_source_success(&trace, parsed.len(), 0);
    Ok(parsed)
}

fn parse_toc_html(
    src: &BookSource,
    resp: &crate::api::http_source::HttpResponse,
) -> std::result::Result<Vec<TocEntry>, SourceFailureInfo> {
    let doc = Html::parse_document(&resp.body);
    let (list_sel, text_equals) = parse_selector(&src.toc_list).map_err(|error| {
        failure(
            FailureKind::InvalidRule,
            format!("目录列表选择器无效: {error}"),
            None,
        )
    })?;
    let mut out = Vec::new();
    for el in select_all_matching(&doc, &list_sel, &text_equals) {
        let html_str = el.html();
        let sub = Html::parse_fragment(&html_str);
        let title = extract_with_rule(
            &sub,
            &html_str,
            &src.toc_name,
            ExtractMode::Text,
            Some(&resp.url),
        );
        let href = extract_with_rule(
            &sub,
            &html_str,
            &src.toc_url,
            ExtractMode::Attr("href".to_string()),
            Some(&resp.url),
        );
        if title.is_empty() || href.is_empty() {
            continue;
        }
        out.push(TocEntry { title, url: href });
    }
    Ok(out)
}

#[flutter_rust_bridge::frb]
pub fn source_toc(source_json: String, toc_url: String) -> Result<Vec<TocEntry>> {
    source_toc_impl(&source_json, &toc_url, None).map_err(anyhow::Error::new)
}

#[flutter_rust_bridge::frb]
pub fn source_toc_reliable(
    source_json: String,
    toc_url: String,
    request_id: String,
) -> SourceTocOutcome {
    let cancellation = register_request(&request_id);
    let result = source_toc_impl(&source_json, &toc_url, cancellation.as_ref());
    finish_request(&request_id);
    match result {
        Ok(entries) => SourceTocOutcome {
            entries,
            failure: None,
        },
        Err(source_failure) => SourceTocOutcome {
            entries: Vec::new(),
            failure: Some(source_failure),
        },
    }
}

fn source_chapter_content_impl(
    source_json: &str,
    chapter_url: &str,
    cancellation: Option<&tokio_util::sync::CancellationToken>,
) -> std::result::Result<String, SourceFailureInfo> {
    let src = parse_source(source_json)?;
    let trace = source_fetch(&src, SourceOperation::Content, chapter_url, cancellation)?;
    let resp = &trace.response;
    let text_content = if let Some(json) = parse_json_value(&resp.body) {
        let content = json_string_from_rule(&json, &src.content_selector);
        if !content.is_empty() {
            normalize_chapter_text(&content)
        } else {
            String::new()
        }
    } else {
        let doc = Html::parse_document(&resp.body);
        let parts = extract_many_with_rule(
            &doc,
            &resp.body,
            &src.content_selector,
            ExtractMode::TextNodes,
            Some(&resp.url),
        );
        normalize_chapter_text(&parts.join("\n\n"))
    };
    let content = if matches!(src.book_source_type, 1 | 2) {
        let doc = Html::parse_document(&resp.body);
        let (images, audio) = extract_media_resources(
            &doc,
            &resp.body,
            &src.content_selector,
            &resp.url,
            src.book_source_type,
        );
        if images.is_empty() && audio.is_none() {
            let source_failure = empty_parse_failure(&src, &resp.body, "媒体正文");
            record_source_failure(&trace, &source_failure);
            return Err(source_failure);
        }
        format!(
            "velora-media-v1:{}",
            serde_json::json!({
                "images": images,
                "audio": audio,
                "text": text_content,
            })
        )
    } else {
        text_content
    };
    let non_whitespace_chars = if matches!(src.book_source_type, 1 | 2) {
        content
            .chars()
            .filter(|value| !value.is_whitespace())
            .count()
    } else {
        match validate_chapter_content(&src, &resp.body, &content) {
            Ok(length) => length,
            Err(source_failure) => {
                record_source_failure(&trace, &source_failure);
                return Err(source_failure);
            }
        }
    };
    record_source_success(&trace, 1, non_whitespace_chars);
    Ok(content)
}

fn extract_media_resources(
    doc: &Html,
    raw_text: &str,
    rule: &str,
    base_url: &str,
    source_type: u8,
) -> (Vec<String>, Option<String>) {
    let mut candidates = extract_many_with_rule(
        doc,
        raw_text,
        rule,
        ExtractMode::ResourceUrl,
        Some(base_url),
    );
    let parsed = normalize_rule(rule);
    if let Some(selector_text) = parsed.selector {
        if let (Ok(root_selector), Ok(media_selector)) = (
            Selector::parse(&selector_text),
            Selector::parse("img, audio, source, video"),
        ) {
            for root in select_all_matching(doc, &root_selector, &parsed.text_equals) {
                for media in root.select(&media_selector) {
                    let value =
                        extract_from_element(media, &ExtractMode::ResourceUrl, Some(base_url));
                    if !value.is_empty() {
                        candidates.push(value);
                    }
                }
            }
        }
    }
    if let Ok(url_regex) = Regex::new(r#"https?://[^\s<>"']+"#) {
        candidates.extend(
            url_regex
                .find_iter(raw_text)
                .map(|item| item.as_str().replace("\\/", "/")),
        );
    }
    let mut images = Vec::new();
    let mut audio = None;
    for value in candidates {
        let value = value.trim().trim_matches(['"', '\'', ',']).to_string();
        if value.is_empty() || !(value.starts_with("http") || value.starts_with("data:")) {
            continue;
        }
        let lower = value
            .split(['?', '#'])
            .next()
            .unwrap_or(&value)
            .to_ascii_lowercase();
        let is_audio = lower.starts_with("data:audio/")
            || [".mp3", ".m4a", ".aac", ".ogg", ".opus", ".wav", ".flac"]
                .iter()
                .any(|suffix| lower.ends_with(suffix));
        let is_image = lower.starts_with("data:image/")
            || [".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif"]
                .iter()
                .any(|suffix| lower.ends_with(suffix));
        if is_audio || (source_type == 1 && !is_image && audio.is_none()) {
            audio.get_or_insert(value);
        } else if is_image || source_type == 2 {
            if !images.contains(&value) {
                images.push(value);
            }
        }
    }
    (images, audio)
}

fn normalize_chapter_text(raw: &str) -> String {
    let normalized = raw.replace("\u{a0}", " ");
    if !(normalized.contains('<') && normalized.contains('>')) {
        return normalized.trim().to_string();
    }
    let fragment = Html::parse_fragment(&normalized);
    fragment
        .root_element()
        .text()
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n")
        .trim()
        .to_string()
}

#[flutter_rust_bridge::frb]
pub fn source_chapter_content(source_json: String, chapter_url: String) -> Result<String> {
    source_chapter_content_impl(&source_json, &chapter_url, None).map_err(anyhow::Error::new)
}

#[flutter_rust_bridge::frb]
pub fn source_chapter_content_reliable(
    source_json: String,
    chapter_url: String,
    request_id: String,
) -> SourceContentOutcome {
    let cancellation = register_request(&request_id);
    let result = source_chapter_content_impl(&source_json, &chapter_url, cancellation.as_ref());
    finish_request(&request_id);
    match result {
        Ok(content) => SourceContentOutcome {
            content,
            failure: None,
        },
        Err(source_failure) => SourceContentOutcome {
            content: String::new(),
            failure: Some(source_failure),
        },
    }
}

fn urlencoding_lite(s: &str) -> String {
    percent_encode_bytes(s.as_bytes())
}

fn encode_search_keyword(keyword: &str, request_rule: &str) -> String {
    let charset = split_request_options(request_rule)
        .1
        .and_then(|options| loose_option_value(options, "charset"));
    let Some(encoding) = charset
        .as_deref()
        .and_then(|value| Encoding::for_label(value.trim().as_bytes()))
    else {
        return urlencoding_lite(keyword);
    };
    let (encoded, _, _) = encoding.encode(keyword);
    percent_encode_bytes(encoded.as_ref())
}

fn percent_encode_bytes(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 3);
    for &b in bytes {
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
            book_source_type: 0,
            search_url: search_url.to_string(),
            search_list: ".book".to_string(),
            search_name: ".name".to_string(),
            search_author: ".author".to_string(),
            search_book_url: "a".to_string(),
            search_cover: String::new(),
            book_info_init: String::new(),
            book_info_name: "h1".to_string(),
            book_info_author: ".author".to_string(),
            book_info_intro: ".intro".to_string(),
            book_info_cover: String::new(),
            book_info_toc_url: ".toc a".to_string(),
            toc_list: ".chapter".to_string(),
            toc_name: "a".to_string(),
            toc_url: "a".to_string(),
            content_selector: "#content".to_string(),
            rule_version: 1,
            validation: SourceValidation::default(),
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
        assert_eq!(
            regex_value_from_rule(&rows[0], "$1", Some("https://example.com/book/")),
            "https://example.com/chapter/1"
        );
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
            extract_with_rule(
                &doc,
                &raw,
                "@css:.name@text",
                ExtractMode::Text,
                Some("https://example.com/base/")
            ),
            "测试书"
        );
        assert_eq!(
            extract_with_rule(
                &doc,
                &raw,
                ".name",
                ExtractMode::Attr("href".to_string()),
                Some("https://example.com/base/")
            ),
            "https://example.com/book/1"
        );
        assert_eq!(
            extract_with_rule(
                &doc,
                &raw,
                "@css:[property=og:image]@content",
                ExtractMode::Text,
                Some("https://example.com/base/")
            ),
            "https://example.com/og.jpg"
        );
        assert_eq!(
            extract_with_rule(
                &doc,
                &raw,
                "@css:.cover",
                ExtractMode::ResourceUrl,
                Some("https://example.com/base/")
            ),
            "https://example.com/cover.jpg"
        );
    }

    #[test]
    fn legado_selector_chains_support_xiu2_rule_shapes() {
        assert_eq!(normalize_css_selector("class.item"), ".item");
        assert_eq!(
            normalize_css_selector("id.newscontent.0@class.l.0@tag.li"),
            "#newscontent .l li"
        );
        assert_eq!(normalize_css_selector("tag.h3.0@tag.a.0"), "h3 a");
        assert_eq!(normalize_css_selector("tag.a.1"), "a:nth-of-type(2)");

        let html = r#"
          <div class="item">
            <a href="/book/1"><img src="/cover.jpg"></a>
            <h3><a href="/book/1">测试小说</a></h3>
            <p>分类</p><p>作者：测试作者</p>
          </div>
        "#;
        let doc = Html::parse_document(html);
        let (list, text_equals) = parse_selector("class.item").unwrap();
        let row = select_first_matching(&doc, &list, &text_equals).unwrap();
        let row_html = row.html();
        let fragment = Html::parse_fragment(&row_html);
        assert_eq!(
            extract_with_rule(
                &fragment,
                &row_html,
                "tag.h3.0@tag.a.0@text",
                ExtractMode::Text,
                Some("https://example.com")
            ),
            "测试小说"
        );
        assert_eq!(
            extract_with_rule(
                &fragment,
                &row_html,
                "tag.a.0@href",
                ExtractMode::Attr("href".to_string()),
                Some("https://example.com")
            ),
            "https://example.com/book/1"
        );
    }

    #[test]
    fn json_rules_render_templates_and_cleanup_suffixes() {
        let value: Value = serde_json::from_str(
            r#"{"data":{"book_id":42,"title":"《测试小说》","content":"<p>第一段</p><p>第二段</p>"}}"#,
        )
        .unwrap();
        let data = json_nodes_from_rule(&value, "$.data")
            .into_iter()
            .next()
            .unwrap();
        assert_eq!(
            json_string_from_rule(data, "/novels/api/book/{{$.book_id}}"),
            "/novels/api/book/42"
        );
        assert_eq!(json_string_from_rule(data, "$.title##《|》"), "测试小说");
        assert_eq!(
            normalize_chapter_text(&json_string_from_rule(&value, "{{$.data.content}}")),
            "第一段\n\n第二段"
        );
    }

    #[test]
    fn source_request_parses_legado_post_descriptor() {
        let src = sample_source(
            "/search,{'method':'POST','body':'keyword={{key}}','headers':{'Referer':'https://example.com/'}}",
        );
        let rendered = render_search_request_rule(&src, "测试小说").unwrap();
        let request = parse_source_request(&rendered, &src.url).unwrap();
        assert_eq!(request.url, "https://example.com/search");
        assert_eq!(request.method, "POST");
        assert!(request.body.unwrap().starts_with("keyword=%"));
        assert!(request
            .headers
            .contains(&("Referer".to_string(), "https://example.com/".to_string())));
        assert!(request.headers.contains(&(
            "Content-Type".to_string(),
            "application/x-www-form-urlencoded; charset=UTF-8".to_string()
        )));
    }

    #[test]
    fn search_request_honors_legacy_gbk_charset() {
        let src =
            sample_source("/search,{'charset':'gbk','method':'POST','body':'searchkey={{key}}'}");
        let rendered = render_search_request_rule(&src, "测试").unwrap();
        let request = parse_source_request(&rendered, &src.url).unwrap();
        assert_eq!(request.body.as_deref(), Some("searchkey=%B2%E2%CA%D4"));
        assert!(request.headers.contains(&(
            "Content-Type".to_string(),
            "application/x-www-form-urlencoded; charset=gbk".to_string()
        )));
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
        let doc = Html::parse_document(
            r#"<html><body><div id='content'>正文内容 搜索一下 下载APP</div></body></html>"#,
        );
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

    #[test]
    fn chapter_validation_rejects_short_and_verification_content() {
        let src = sample_source("/search?q={key}");
        let short = validate_chapter_content(&src, "<html></html>", "只有几个字")
            .expect_err("short content must fail");
        assert_eq!(short.kind, FailureKind::InvalidContent);

        let denied = validate_chapter_content(&src, "<html></html>", "请完成人机验证后继续")
            .expect_err("verification content must fail");
        assert_eq!(denied.kind, FailureKind::AuthDenied);
    }

    #[test]
    fn chapter_validation_honors_source_specific_minimum() {
        let mut src = sample_source("/search?q={key}");
        src.validation.min_text_chars = 4;
        assert_eq!(validate_chapter_content(&src, "", "短章节正文").unwrap(), 5);
    }

    #[test]
    fn media_rules_collect_comic_pages_and_optional_audio() {
        let raw = r#"<div class="comic"><img data-src="/p/2.jpg"><img src="/p/10.jpg"><audio><source src="/audio/chapter.mp3"></audio></div>"#;
        let doc = Html::parse_document(raw);
        let (images, audio) =
            extract_media_resources(&doc, raw, ".comic", "https://reader.example/chapter/1", 2);

        assert_eq!(images.len(), 2);
        assert_eq!(images[0], "https://reader.example/p/2.jpg");
        assert_eq!(images[1], "https://reader.example/p/10.jpg");
        assert_eq!(
            audio.as_deref(),
            Some("https://reader.example/audio/chapter.mp3")
        );
    }

    #[test]
    fn empty_parser_result_distinguishes_rule_breakage_from_access_denial() {
        let src = sample_source("/search?q={key}");
        assert_eq!(
            empty_parse_failure(&src, "<html><body></body></html>", "目录").kind,
            FailureKind::ParserBroken
        );
        assert_eq!(
            empty_parse_failure(&src, "访问过于频繁，请稍后再试", "目录").kind,
            FailureKind::AuthDenied
        );
    }
}
