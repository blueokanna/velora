use std::time::Duration;

use anyhow::{anyhow, Result};
use encoding_rs::Encoding;
use once_cell::sync::Lazy;
use reqwest::Client;
use serde::{Deserialize, Serialize};

use crate::api::txt_book::rt;

static CLIENT: Lazy<Client> = Lazy::new(|| {
    Client::builder()
        .user_agent("Velora/1.0 (Flutter; Rust)")
        .timeout(Duration::from_secs(20))
        .connect_timeout(Duration::from_secs(8))
        .pool_idle_timeout(Duration::from_secs(90))
        .pool_max_idle_per_host(8)
        .build()
        .expect("无法创建 HTTP 客户端")
});

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpResponse {
    pub status: u16,
    pub body: String,
    pub encoding: String,
    pub url: String,
}

pub async fn fetch_url(url: String, headers: Vec<(String, String)>) -> Result<HttpResponse> {
    let mut req = CLIENT.get(&url);
    for (k, v) in &headers {
        req = req.header(k.as_str(), v.as_str());
    }
    let resp = req.send().await.map_err(|e| anyhow!("请求失败: {e}"))?;
    let status = resp.status().as_u16();
    let final_url = resp.url().to_string();

    let ct_charset = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| {
            s.split(';')
                .filter_map(|kv| kv.split_once('='))
                .find(|(k, _)| k.trim().eq_ignore_ascii_case("charset"))
                .map(|(_, v)| v.trim().trim_matches('"').to_string())
        });

    let bytes = resp
        .bytes()
        .await
        .map_err(|e| anyhow!("读取响应失败: {e}"))?;
    let enc = ct_charset
        .as_deref()
        .and_then(|n| Encoding::for_label(n.as_bytes()))
        .unwrap_or_else(|| {
            let mut det = chardetng::EncodingDetector::new(chardetng::Iso2022JpDetection::Allow);
            det.feed(&bytes, true);
            det.guess(None, chardetng::Utf8Detection::Allow)
        });
    let (cow, _, _) = enc.decode(&bytes);
    Ok(HttpResponse {
        status,
        body: cow.into_owned(),
        encoding: enc.name().to_string(),
        url: final_url,
    })
}

pub fn http_get(url: String, headers: Vec<(String, String)>) -> Result<HttpResponse> {
    rt().block_on(fetch_url(url, headers))
}
