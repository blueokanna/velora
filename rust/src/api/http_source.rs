use std::time::Duration;

use anyhow::{anyhow, Result};
use encoding_rs::Encoding;
use once_cell::sync::Lazy;
use reqwest::{Client, Method};
use serde::{Deserialize, Serialize};
use tokio_util::sync::CancellationToken;

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

pub(crate) struct FetchOnceResponse {
    pub response: HttpResponse,
    pub retry_after: Option<String>,
}

#[derive(Debug)]
pub(crate) enum FetchOnceError {
    Cancelled,
    Request(reqwest::Error),
}

pub(crate) async fn fetch_once(
    url: &str,
    headers: &[(String, String)],
    request_timeout: Duration,
    cancellation: Option<&CancellationToken>,
) -> std::result::Result<FetchOnceResponse, FetchOnceError> {
    fetch_once_with_options(url, headers, request_timeout, cancellation, "GET", None).await
}

pub(crate) async fn fetch_once_with_options(
    url: &str,
    headers: &[(String, String)],
    request_timeout: Duration,
    cancellation: Option<&CancellationToken>,
    method: &str,
    body: Option<&str>,
) -> std::result::Result<FetchOnceResponse, FetchOnceError> {
    let method =
        Method::from_bytes(method.trim().to_ascii_uppercase().as_bytes()).unwrap_or(Method::GET);
    let mut req = CLIENT.request(method, url).timeout(request_timeout);
    for (key, value) in headers {
        req = req.header(key.as_str(), value.as_str());
    }
    if let Some(body) = body {
        if !headers
            .iter()
            .any(|(key, _)| key.eq_ignore_ascii_case("content-type"))
        {
            req = req.header(
                reqwest::header::CONTENT_TYPE,
                "application/x-www-form-urlencoded; charset=UTF-8",
            );
        }
        req = req.body(body.to_string());
    }

    let response = match cancellation {
        Some(token) => tokio::select! {
            _ = token.cancelled() => return Err(FetchOnceError::Cancelled),
            result = req.send() => result.map_err(FetchOnceError::Request)?,
        },
        None => req.send().await.map_err(FetchOnceError::Request)?,
    };
    let status = response.status().as_u16();
    let final_url = response.url().to_string();
    let retry_after = response
        .headers()
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);

    let ct_charset = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| {
            value
                .split(';')
                .filter_map(|part| part.split_once('='))
                .find(|(key, _)| key.trim().eq_ignore_ascii_case("charset"))
                .map(|(_, value)| value.trim().trim_matches('"').to_string())
        });
    let bytes = match cancellation {
        Some(token) => tokio::select! {
            _ = token.cancelled() => return Err(FetchOnceError::Cancelled),
            result = response.bytes() => result.map_err(FetchOnceError::Request)?,
        },
        None => response.bytes().await.map_err(FetchOnceError::Request)?,
    };
    let encoding = ct_charset
        .as_deref()
        .and_then(|name| Encoding::for_label(name.as_bytes()))
        .unwrap_or_else(|| {
            let mut detector =
                chardetng::EncodingDetector::new(chardetng::Iso2022JpDetection::Allow);
            detector.feed(&bytes, true);
            detector.guess(None, chardetng::Utf8Detection::Allow)
        });
    let (body, _, _) = encoding.decode(&bytes);
    Ok(FetchOnceResponse {
        response: HttpResponse {
            status,
            body: body.into_owned(),
            encoding: encoding.name().to_string(),
            url: final_url,
        },
        retry_after,
    })
}

pub async fn fetch_url(url: String, headers: Vec<(String, String)>) -> Result<HttpResponse> {
    fetch_once(&url, &headers, Duration::from_secs(20), None)
        .await
        .map(|result| result.response)
        .map_err(|error| match error {
            FetchOnceError::Cancelled => anyhow!("请求已取消"),
            FetchOnceError::Request(error) => anyhow!("请求失败: {error}"),
        })
}

pub fn http_get(url: String, headers: Vec<(String, String)>) -> Result<HttpResponse> {
    rt().block_on(fetch_url(url, headers))
}
