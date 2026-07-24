use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use chrono::{DateTime, Utc};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;

use crate::api::http_source::{fetch_once_with_options, FetchOnceError, HttpResponse};
use crate::api::txt_book::rt;

const MAX_OBSERVATIONS_PER_SOURCE: usize = 200;
const DEFAULT_RATE_LIMIT_COOLDOWN: Duration = Duration::from_secs(5 * 60);
const MAX_RATE_LIMIT_COOLDOWN: Duration = Duration::from_secs(30 * 60);
const TRANSIENT_CIRCUIT_COOLDOWN: Duration = Duration::from_secs(30);
const PARSER_CIRCUIT_COOLDOWN: Duration = Duration::from_secs(5 * 60);
const MAX_CONCURRENCY_PER_SOURCE: usize = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FailureKind {
    NetworkTransient,
    RateLimited,
    AuthDenied,
    ResourceGone,
    ParserBroken,
    InvalidContent,
    InvalidRule,
    HttpRejected,
    CircuitOpen,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SourceOperation {
    Search,
    BookDetail,
    Toc,
    Content,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CircuitState {
    Healthy,
    Degraded,
    OpenCircuit,
    HalfOpen,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceFailureInfo {
    pub kind: FailureKind,
    pub message: String,
    pub retry_after_ms: Option<u64>,
}

impl fmt::Display for SourceFailureInfo {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "[{:?}] {}", self.kind, self.message)
    }
}

impl std::error::Error for SourceFailureInfo {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceObservation {
    pub source_id: String,
    pub operation: SourceOperation,
    pub request_host: String,
    pub status_code: Option<u16>,
    pub latency_ms: u64,
    pub retry_count: u8,
    pub failure_kind: Option<FailureKind>,
    pub parsed_items: u32,
    pub text_length: u32,
    pub rule_version: u32,
    pub cache_hit: bool,
    pub timestamp_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceHealthSnapshot {
    pub source_id: String,
    pub circuit_state: CircuitState,
    pub cooldown_remaining_ms: u64,
    pub health_score: f64,
    pub recent_success_rate: f64,
    pub parser_valid_rate: f64,
    pub p50_latency_ms: u64,
    pub p95_latency_ms: u64,
    pub last_success_at_ms: Option<i64>,
    pub recent_failure_kind: Option<FailureKind>,
    pub observation_count: u32,
}

#[derive(Debug)]
struct HealthEntry {
    circuit_state: CircuitState,
    circuit_open_until: Option<Instant>,
    half_open_probe_in_flight: bool,
    consecutive_transport_failures: u8,
    consecutive_parser_failures: u8,
    observations: VecDeque<SourceObservation>,
}

impl HealthEntry {
    fn new() -> Self {
        Self {
            circuit_state: CircuitState::Healthy,
            circuit_open_until: None,
            half_open_probe_in_flight: false,
            consecutive_transport_failures: 0,
            consecutive_parser_failures: 0,
            observations: VecDeque::new(),
        }
    }
}

#[derive(Debug)]
pub(crate) struct FetchTrace {
    pub response: HttpResponse,
    pub source_id: String,
    pub operation: SourceOperation,
    pub request_host: String,
    pub latency_ms: u64,
    pub retry_count: u8,
    pub rule_version: u32,
}

static HEALTH: Lazy<Mutex<HashMap<String, HealthEntry>>> = Lazy::new(|| Mutex::new(HashMap::new()));
static SOURCE_LIMITERS: Lazy<Mutex<HashMap<String, Arc<Semaphore>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static CANCELLATIONS: Lazy<Mutex<HashMap<String, CancellationToken>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

fn timestamp_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

fn duration_ms(duration: Duration) -> u64 {
    duration.as_millis().min(u64::MAX as u128) as u64
}

fn request_timeout(operation: SourceOperation) -> Duration {
    match operation {
        SourceOperation::Content => Duration::from_secs(18),
        SourceOperation::Search | SourceOperation::BookDetail | SourceOperation::Toc => {
            Duration::from_secs(10)
        }
    }
}

fn request_host(url: &str) -> String {
    url::Url::parse(url)
        .ok()
        .and_then(|value| value.host_str().map(str::to_owned))
        .unwrap_or_default()
}

pub(crate) fn source_id(source_name: &str, source_url: &str) -> String {
    let name = source_name.trim();
    let host = request_host(source_url);
    match (name.is_empty(), host.is_empty()) {
        (false, false) => format!("{name}@{host}"),
        (false, true) => name.to_string(),
        (true, false) => host,
        (true, true) => "unknown-source".to_string(),
    }
}

pub(crate) fn failure(
    kind: FailureKind,
    message: impl Into<String>,
    retry_after: Option<Duration>,
) -> SourceFailureInfo {
    SourceFailureInfo {
        kind,
        message: message.into(),
        retry_after_ms: retry_after.map(duration_ms),
    }
}

fn cancellation_failure() -> SourceFailureInfo {
    failure(FailureKind::Cancelled, "请求已取消", None)
}

pub(crate) fn register_request(request_id: &str) -> Option<CancellationToken> {
    if request_id.trim().is_empty() {
        return None;
    }
    let token = CancellationToken::new();
    if let Ok(mut cancellations) = CANCELLATIONS.lock() {
        if let Some(previous) = cancellations.insert(request_id.to_string(), token.clone()) {
            previous.cancel();
        }
    }
    Some(token)
}

pub(crate) fn finish_request(request_id: &str) {
    if request_id.trim().is_empty() {
        return;
    }
    if let Ok(mut cancellations) = CANCELLATIONS.lock() {
        cancellations.remove(request_id);
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn cancel_source_request(request_id: String) -> bool {
    let Ok(mut cancellations) = CANCELLATIONS.lock() else {
        return false;
    };
    let Some(token) = cancellations.remove(&request_id) else {
        return false;
    };
    token.cancel();
    true
}

fn source_limiter(source_id: &str) -> Arc<Semaphore> {
    let Ok(mut limiters) = SOURCE_LIMITERS.lock() else {
        return Arc::new(Semaphore::new(MAX_CONCURRENCY_PER_SOURCE));
    };
    limiters
        .entry(source_id.to_string())
        .or_insert_with(|| Arc::new(Semaphore::new(MAX_CONCURRENCY_PER_SOURCE)))
        .clone()
}

fn circuit_gate(source_id: &str) -> Result<(), SourceFailureInfo> {
    let Ok(mut health) = HEALTH.lock() else {
        return Ok(());
    };
    let entry = health
        .entry(source_id.to_string())
        .or_insert_with(HealthEntry::new);
    if entry.circuit_state == CircuitState::OpenCircuit {
        if let Some(until) = entry.circuit_open_until {
            if until > Instant::now() {
                let remaining = until.saturating_duration_since(Instant::now());
                return Err(failure(
                    FailureKind::CircuitOpen,
                    "书源正在冷却，暂不发送请求",
                    Some(remaining),
                ));
            }
        }
        entry.circuit_state = CircuitState::HalfOpen;
        entry.circuit_open_until = None;
        entry.half_open_probe_in_flight = false;
    }
    if entry.circuit_state == CircuitState::HalfOpen {
        if entry.half_open_probe_in_flight {
            return Err(failure(
                FailureKind::CircuitOpen,
                "书源正在执行半开探测",
                Some(Duration::from_secs(1)),
            ));
        }
        entry.half_open_probe_in_flight = true;
    }
    Ok(())
}

fn open_circuit(entry: &mut HealthEntry, cooldown: Duration) {
    entry.circuit_state = CircuitState::OpenCircuit;
    entry.circuit_open_until = Some(Instant::now() + cooldown);
    entry.half_open_probe_in_flight = false;
}

fn push_observation(entry: &mut HealthEntry, observation: SourceObservation) {
    entry.observations.push_back(observation);
    while entry.observations.len() > MAX_OBSERVATIONS_PER_SOURCE {
        entry.observations.pop_front();
    }
}

fn record_observation(observation: SourceObservation, retry_after: Option<Duration>) {
    let Ok(mut health) = HEALTH.lock() else {
        return;
    };
    let entry = health
        .entry(observation.source_id.clone())
        .or_insert_with(HealthEntry::new);
    match observation.failure_kind {
        None => {
            if !observation.cache_hit {
                entry.consecutive_transport_failures = 0;
                entry.consecutive_parser_failures = 0;
                entry.circuit_state = CircuitState::Healthy;
                entry.circuit_open_until = None;
                entry.half_open_probe_in_flight = false;
            }
        }
        Some(FailureKind::NetworkTransient) => {
            entry.consecutive_transport_failures =
                entry.consecutive_transport_failures.saturating_add(1);
            entry.half_open_probe_in_flight = false;
            if entry.consecutive_transport_failures >= 3
                || entry.circuit_state == CircuitState::HalfOpen
            {
                open_circuit(entry, TRANSIENT_CIRCUIT_COOLDOWN);
            } else {
                entry.circuit_state = CircuitState::Degraded;
            }
        }
        Some(FailureKind::RateLimited) => {
            entry.consecutive_transport_failures =
                entry.consecutive_transport_failures.saturating_add(1);
            open_circuit(entry, retry_after.unwrap_or(DEFAULT_RATE_LIMIT_COOLDOWN));
        }
        Some(FailureKind::AuthDenied) => {
            open_circuit(entry, DEFAULT_RATE_LIMIT_COOLDOWN);
        }
        Some(FailureKind::ParserBroken | FailureKind::InvalidContent) => {
            entry.consecutive_parser_failures = entry.consecutive_parser_failures.saturating_add(1);
            entry.half_open_probe_in_flight = false;
            if entry.consecutive_parser_failures >= 5
                || entry.circuit_state == CircuitState::HalfOpen
            {
                open_circuit(entry, PARSER_CIRCUIT_COOLDOWN);
            } else if entry.consecutive_parser_failures >= 3 {
                entry.circuit_state = CircuitState::Degraded;
            }
        }
        Some(FailureKind::InvalidRule) => {
            entry.circuit_state = CircuitState::Degraded;
            entry.half_open_probe_in_flight = false;
        }
        Some(
            FailureKind::ResourceGone
            | FailureKind::HttpRejected
            | FailureKind::CircuitOpen
            | FailureKind::Cancelled,
        ) => {
            entry.half_open_probe_in_flight = false;
        }
    }
    push_observation(entry, observation);
}

fn trace_observation(
    trace: &FetchTrace,
    failure_kind: Option<FailureKind>,
    parsed_items: u32,
    text_length: u32,
    cache_hit: bool,
) -> SourceObservation {
    SourceObservation {
        source_id: trace.source_id.clone(),
        operation: trace.operation,
        request_host: trace.request_host.clone(),
        status_code: Some(trace.response.status),
        latency_ms: trace.latency_ms,
        retry_count: trace.retry_count,
        failure_kind,
        parsed_items,
        text_length,
        rule_version: trace.rule_version,
        cache_hit,
        timestamp_ms: timestamp_ms(),
    }
}

pub(crate) fn record_source_success(trace: &FetchTrace, parsed_items: usize, text_length: usize) {
    record_observation(
        trace_observation(
            trace,
            None,
            parsed_items.min(u32::MAX as usize) as u32,
            text_length.min(u32::MAX as usize) as u32,
            false,
        ),
        None,
    );
}

pub(crate) fn record_source_failure(trace: &FetchTrace, source_failure: &SourceFailureInfo) {
    record_observation(
        trace_observation(trace, Some(source_failure.kind), 0, 0, false),
        source_failure.retry_after_ms.map(Duration::from_millis),
    );
}

fn record_transport_failure(
    source_id: &str,
    operation: SourceOperation,
    host: &str,
    status_code: Option<u16>,
    latency: Duration,
    retry_count: u8,
    rule_version: u32,
    source_failure: &SourceFailureInfo,
) {
    record_observation(
        SourceObservation {
            source_id: source_id.to_string(),
            operation,
            request_host: host.to_string(),
            status_code,
            latency_ms: duration_ms(latency),
            retry_count,
            failure_kind: Some(source_failure.kind),
            parsed_items: 0,
            text_length: 0,
            rule_version,
            cache_hit: false,
            timestamp_ms: timestamp_ms(),
        },
        source_failure.retry_after_ms.map(Duration::from_millis),
    );
}

fn retry_after_duration(value: Option<&str>) -> Duration {
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        return DEFAULT_RATE_LIMIT_COOLDOWN;
    };
    let parsed = value
        .parse::<u64>()
        .ok()
        .map(Duration::from_secs)
        .or_else(|| {
            DateTime::parse_from_rfc2822(value).ok().map(|date| {
                let delta = date.with_timezone(&Utc) - Utc::now();
                Duration::from_millis(delta.num_milliseconds().max(1) as u64)
            })
        })
        .unwrap_or(DEFAULT_RATE_LIMIT_COOLDOWN);
    parsed.clamp(Duration::from_secs(1), MAX_RATE_LIMIT_COOLDOWN)
}

fn retry_delay(retry_number: u8) -> Duration {
    let base_ms = match retry_number {
        1 => 300,
        _ => 1_000,
    };
    let jitter = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_millis() as u64
        % 151;
    Duration::from_millis(base_ms + jitter)
}

async fn wait_for_retry(
    delay: Duration,
    cancellation: Option<&CancellationToken>,
) -> Result<(), SourceFailureInfo> {
    match cancellation {
        Some(token) => tokio::select! {
            _ = token.cancelled() => Err(cancellation_failure()),
            _ = tokio::time::sleep(delay) => Ok(()),
        },
        None => {
            tokio::time::sleep(delay).await;
            Ok(())
        }
    }
}

async fn fetch_for_source_async(
    source_name: &str,
    source_url: &str,
    operation: SourceOperation,
    url: &str,
    headers: &[(String, String)],
    method: &str,
    body: Option<&str>,
    rule_version: u32,
    cancellation: Option<&CancellationToken>,
) -> Result<FetchTrace, SourceFailureInfo> {
    let source_id = source_id(source_name, source_url);
    let host = request_host(url);
    if let Err(source_failure) = circuit_gate(&source_id) {
        record_transport_failure(
            &source_id,
            operation,
            &host,
            None,
            Duration::ZERO,
            0,
            rule_version,
            &source_failure,
        );
        return Err(source_failure);
    }
    let limiter = source_limiter(&source_id);
    let started = Instant::now();
    let permit_result = match cancellation {
        Some(token) => tokio::select! {
            _ = token.cancelled() => Err(cancellation_failure()),
            result = limiter.acquire_owned() => result.map_err(|_| {
                failure(FailureKind::NetworkTransient, "书源请求队列已关闭", None)
            }),
        },
        None => limiter
            .acquire_owned()
            .await
            .map_err(|_| failure(FailureKind::NetworkTransient, "书源请求队列已关闭", None)),
    };
    let permit = match permit_result {
        Ok(permit) => permit,
        Err(source_failure) => {
            record_transport_failure(
                &source_id,
                operation,
                &host,
                None,
                started.elapsed(),
                0,
                rule_version,
                &source_failure,
            );
            return Err(source_failure);
        }
    };
    let _permit = permit;
    let max_retries = 2u8;

    for attempt in 0..=max_retries {
        match fetch_once_with_options(
            url,
            headers,
            request_timeout(operation),
            cancellation,
            method,
            body,
        )
        .await
        {
            Ok(result) if (200..300).contains(&result.response.status) => {
                return Ok(FetchTrace {
                    response: result.response,
                    source_id,
                    operation,
                    request_host: host,
                    latency_ms: duration_ms(started.elapsed()),
                    retry_count: attempt,
                    rule_version,
                });
            }
            Ok(result) => {
                let status = result.response.status;
                let source_failure = match status {
                    401 | 403 => failure(
                        FailureKind::AuthDenied,
                        format!("源站拒绝访问（HTTP {status}）"),
                        None,
                    ),
                    404 | 410 => failure(
                        FailureKind::ResourceGone,
                        format!("资源不存在或已下架（HTTP {status}）"),
                        None,
                    ),
                    429 => {
                        let cooldown = retry_after_duration(result.retry_after.as_deref());
                        failure(
                            FailureKind::RateLimited,
                            "源站请求过于频繁，已进入冷却",
                            Some(cooldown),
                        )
                    }
                    500..=599 => failure(
                        FailureKind::NetworkTransient,
                        format!("源站暂时不可用（HTTP {status}）"),
                        None,
                    ),
                    _ => failure(
                        FailureKind::HttpRejected,
                        format!("源站返回不可用状态（HTTP {status}）"),
                        None,
                    ),
                };
                if source_failure.kind == FailureKind::NetworkTransient && attempt < max_retries {
                    if let Err(cancelled) =
                        wait_for_retry(retry_delay(attempt + 1), cancellation).await
                    {
                        record_transport_failure(
                            &source_id,
                            operation,
                            &host,
                            Some(status),
                            started.elapsed(),
                            attempt,
                            rule_version,
                            &cancelled,
                        );
                        return Err(cancelled);
                    }
                    continue;
                }
                record_transport_failure(
                    &source_id,
                    operation,
                    &host,
                    Some(status),
                    started.elapsed(),
                    attempt,
                    rule_version,
                    &source_failure,
                );
                return Err(source_failure);
            }
            Err(FetchOnceError::Cancelled) => {
                let source_failure = cancellation_failure();
                record_transport_failure(
                    &source_id,
                    operation,
                    &host,
                    None,
                    started.elapsed(),
                    attempt,
                    rule_version,
                    &source_failure,
                );
                return Err(source_failure);
            }
            Err(FetchOnceError::Request(error)) => {
                let detail = if error.is_timeout() {
                    "书源请求超时"
                } else if error.is_connect() {
                    "无法连接书源"
                } else {
                    "书源网络请求失败"
                };
                let source_failure = failure(FailureKind::NetworkTransient, detail, None);
                if attempt < max_retries {
                    if let Err(cancelled) =
                        wait_for_retry(retry_delay(attempt + 1), cancellation).await
                    {
                        record_transport_failure(
                            &source_id,
                            operation,
                            &host,
                            None,
                            started.elapsed(),
                            attempt,
                            rule_version,
                            &cancelled,
                        );
                        return Err(cancelled);
                    }
                    continue;
                }
                record_transport_failure(
                    &source_id,
                    operation,
                    &host,
                    None,
                    started.elapsed(),
                    attempt,
                    rule_version,
                    &source_failure,
                );
                return Err(source_failure);
            }
        }
    }
    unreachable!("请求重试循环必须返回")
}

#[cfg(test)]
pub(crate) fn fetch_for_source(
    source_name: &str,
    source_url: &str,
    operation: SourceOperation,
    url: &str,
    headers: &[(String, String)],
    rule_version: u32,
    cancellation: Option<&CancellationToken>,
) -> Result<FetchTrace, SourceFailureInfo> {
    rt().block_on(fetch_for_source_async(
        source_name,
        source_url,
        operation,
        url,
        headers,
        "GET",
        None,
        rule_version,
        cancellation,
    ))
}

pub(crate) fn fetch_for_source_request(
    source_name: &str,
    source_url: &str,
    operation: SourceOperation,
    url: &str,
    headers: &[(String, String)],
    method: &str,
    body: Option<&str>,
    rule_version: u32,
    cancellation: Option<&CancellationToken>,
) -> Result<FetchTrace, SourceFailureInfo> {
    rt().block_on(fetch_for_source_async(
        source_name,
        source_url,
        operation,
        url,
        headers,
        method,
        body,
        rule_version,
        cancellation,
    ))
}

fn percentile(sorted: &[u64], percentile: f64) -> u64 {
    if sorted.is_empty() {
        return 0;
    }
    let index = ((sorted.len() - 1) as f64 * percentile).round() as usize;
    sorted[index.min(sorted.len() - 1)]
}

fn snapshot_for(source_id: String, entry: &HealthEntry) -> SourceHealthSnapshot {
    let relevant: Vec<&SourceObservation> = entry
        .observations
        .iter()
        .filter(|item| !item.cache_hit && item.failure_kind != Some(FailureKind::Cancelled))
        .collect();
    let attempted: Vec<&SourceObservation> = relevant
        .into_iter()
        .filter(|item| item.failure_kind != Some(FailureKind::CircuitOpen))
        .collect();
    let successful = attempted
        .iter()
        .filter(|item| item.failure_kind.is_none())
        .count();
    let recent_success_rate = if attempted.is_empty() {
        0.0
    } else {
        successful as f64 / attempted.len() as f64
    };
    let parser_attempts: Vec<&SourceObservation> = attempted
        .iter()
        .copied()
        .filter(|item| {
            item.failure_kind.is_none()
                || matches!(
                    item.failure_kind,
                    Some(FailureKind::ParserBroken | FailureKind::InvalidContent)
                )
        })
        .collect();
    let parser_valid_rate = if parser_attempts.is_empty() {
        0.0
    } else {
        parser_attempts
            .iter()
            .filter(|item| item.failure_kind.is_none())
            .count() as f64
            / parser_attempts.len() as f64
    };
    let mut latencies: Vec<u64> = attempted
        .iter()
        .filter(|item| item.status_code.is_some())
        .map(|item| item.latency_ms)
        .collect();
    latencies.sort_unstable();
    let p50 = percentile(&latencies, 0.50);
    let p95 = percentile(&latencies, 0.95);
    let latency_score = if latencies.is_empty() {
        0.0
    } else {
        (1.0 - p95 as f64 / 10_000.0).clamp(0.0, 1.0)
    };
    let last_success_at_ms = entry
        .observations
        .iter()
        .rev()
        .find(|item| item.failure_kind.is_none() && !item.cache_hit)
        .map(|item| item.timestamp_ms);
    let freshness_score = last_success_at_ms
        .map(|value| timestamp_ms().saturating_sub(value))
        .map(|age| {
            if age <= 24 * 60 * 60 * 1_000 {
                1.0
            } else if age <= 7 * 24 * 60 * 60 * 1_000 {
                0.5
            } else {
                0.0
            }
        })
        .unwrap_or(0.0);
    let recent_failure_kind = entry
        .observations
        .iter()
        .rev()
        .find_map(|item| item.failure_kind);
    let cooldown_remaining_ms = entry
        .circuit_open_until
        .map(|until| duration_ms(until.saturating_duration_since(Instant::now())))
        .unwrap_or(0);
    SourceHealthSnapshot {
        source_id,
        circuit_state: entry.circuit_state,
        cooldown_remaining_ms,
        health_score: 0.45 * recent_success_rate
            + 0.25 * parser_valid_rate
            + 0.20 * latency_score
            + 0.10 * freshness_score,
        recent_success_rate,
        parser_valid_rate,
        p50_latency_ms: p50,
        p95_latency_ms: p95,
        last_success_at_ms,
        recent_failure_kind,
        observation_count: entry.observations.len().min(u32::MAX as usize) as u32,
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn source_health_snapshots() -> Vec<SourceHealthSnapshot> {
    let Ok(health) = HEALTH.lock() else {
        return Vec::new();
    };
    let mut snapshots: Vec<_> = health
        .iter()
        .map(|(source_id, entry)| snapshot_for(source_id.clone(), entry))
        .collect();
    snapshots.sort_by(|left, right| left.source_id.cmp(&right.source_id));
    snapshots
}

#[flutter_rust_bridge::frb(sync)]
pub fn source_recent_observations(source_id: Option<String>, limit: u32) -> Vec<SourceObservation> {
    let Ok(health) = HEALTH.lock() else {
        return Vec::new();
    };
    let mut observations: Vec<_> = health
        .iter()
        .filter(|(key, _)| source_id.as_ref().is_none_or(|value| value == *key))
        .flat_map(|(_, entry)| entry.observations.iter().cloned())
        .collect();
    observations.sort_by_key(|item| std::cmp::Reverse(item.timestamp_ms));
    observations.truncate(limit.min(1_000) as usize);
    observations
}

#[cfg(test)]
pub(crate) fn reset_runtime_for_tests() {
    if let Ok(mut health) = HEALTH.lock() {
        health.clear();
    }
    if let Ok(mut cancellations) = CANCELLATIONS.lock() {
        cancellations.clear();
    }
    if let Ok(mut limiters) = SOURCE_LIMITERS.lock() {
        limiters.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    static TEST_MUTEX: Mutex<()> = Mutex::new(());

    #[test]
    fn retry_after_supports_seconds_and_caps_long_values() {
        let _guard = TEST_MUTEX.lock().unwrap();
        assert_eq!(retry_after_duration(Some("12")), Duration::from_secs(12));
        assert_eq!(
            retry_after_duration(Some("999999")),
            MAX_RATE_LIMIT_COOLDOWN
        );
    }

    #[test]
    fn health_score_does_not_reward_missing_latency_samples() {
        let _guard = TEST_MUTEX.lock().unwrap();
        let snapshot = snapshot_for("new-source@example.com".to_string(), &HealthEntry::new());

        assert_eq!(snapshot.p95_latency_ms, 0);
        assert_eq!(snapshot.health_score, 0.0);
    }

    #[test]
    fn parser_failures_degrade_without_becoming_transport_failures() {
        let _guard = TEST_MUTEX.lock().unwrap();
        reset_runtime_for_tests();
        let trace = FetchTrace {
            response: HttpResponse {
                status: 200,
                body: String::new(),
                encoding: "UTF-8".to_string(),
                url: "https://example.com/search".to_string(),
            },
            source_id: "sample@example.com".to_string(),
            operation: SourceOperation::Search,
            request_host: "example.com".to_string(),
            latency_ms: 10,
            retry_count: 0,
            rule_version: 1,
        };
        let error = failure(FailureKind::ParserBroken, "empty", None);
        for _ in 0..3 {
            record_source_failure(&trace, &error);
        }
        let snapshots = source_health_snapshots();
        assert_eq!(snapshots.len(), 1);
        assert_eq!(snapshots[0].circuit_state, CircuitState::Degraded);
        assert_eq!(
            snapshots[0].recent_failure_kind,
            Some(FailureKind::ParserBroken)
        );
    }

    #[test]
    fn auth_denial_opens_circuit_without_retrying() {
        let _guard = TEST_MUTEX.lock().unwrap();
        reset_runtime_for_tests();
        let failure = failure(FailureKind::AuthDenied, "denied", None);
        record_transport_failure(
            "sample@example.com",
            SourceOperation::Content,
            "example.com",
            Some(403),
            Duration::from_millis(20),
            0,
            1,
            &failure,
        );
        let snapshots = source_health_snapshots();
        assert_eq!(snapshots[0].circuit_state, CircuitState::OpenCircuit);
        assert!(snapshots[0].cooldown_remaining_ms > 0);
    }

    #[test]
    fn gateway_retries_5xx_and_reports_retry_count() {
        let _guard = TEST_MUTEX.lock().unwrap();
        reset_runtime_for_tests();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            for attempt in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0u8; 1024];
                let _ = stream.read(&mut request);
                let (status, body) = if attempt < 2 {
                    ("503 Service Unavailable", "temporary")
                } else {
                    ("200 OK", "ready")
                };
                write!(
                    stream,
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        let url = format!("http://{address}/search");
        let trace = fetch_for_source(
            "retry-source",
            &url,
            SourceOperation::Search,
            &url,
            &[],
            2,
            None,
        )
        .unwrap();
        server.join().unwrap();
        assert_eq!(trace.response.status, 200);
        assert_eq!(trace.retry_count, 2);
        assert!(trace.latency_ms >= 1_300);
    }

    #[test]
    fn gateway_cancels_during_retry_backoff() {
        let _guard = TEST_MUTEX.lock().unwrap();
        reset_runtime_for_tests();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            write!(
                stream,
                "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 9\r\nConnection: close\r\n\r\ntemporary"
            )
            .unwrap();
        });
        let url = format!("http://{address}/content");
        let token = CancellationToken::new();
        let request_token = token.clone();
        let request_url = url.clone();
        let client = thread::spawn(move || {
            fetch_for_source(
                "cancel-source",
                &request_url,
                SourceOperation::Content,
                &request_url,
                &[],
                1,
                Some(&request_token),
            )
        });
        server.join().unwrap();
        thread::sleep(Duration::from_millis(50));
        token.cancel();
        let source_failure = client.join().unwrap().unwrap_err();
        assert_eq!(source_failure.kind, FailureKind::Cancelled);
        let snapshot = source_health_snapshots()
            .into_iter()
            .find(|item| item.source_id.starts_with("cancel-source@"))
            .unwrap();
        assert_ne!(snapshot.circuit_state, CircuitState::HalfOpen);
    }
}
