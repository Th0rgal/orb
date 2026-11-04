//! Local loopback HTTP transport (`127.0.0.1:<ephemeral>`) for Orb desktop.
//!
//! `WKWebView` shares a single HTTP/2 socket, blocks on macOS `mDNSResponder` /
//! Tailscale `MagicDNS` stalls ("TypeError: Load failed"), and sends cross-origin
//! `OPTIONS` preflights on every authenticated request. Forwarding webview API
//! traffic through a per-process `127.0.0.1` bridge moves network transport onto
//! Rust's `reqwest` + `rustls` pool with:
//! 1. Instant (`0 ms`) local `OPTIONS` preflight handling.
//! 2. Encrypted DNS-over-HTTPS (DoH) fallback (`1.1.1.1` / `8.8.8.8` over direct IP
//!    TLS, zero OS DNS dependency) + last-known-good DNS resolution persisted in
//!    `~/.orb/dns-cache.json` while full TLS SNI and certificate verification
//!    remain enforced for the target hostname.
//! 3. HTTP/2 keepalive PING frames + adaptive flow-control windows so dead NAT /
//!    Wi-Fi sockets are recycled within seconds.
//! 4. Ordered 3-way multi-path failover (`orbcore.thomas.md` <->
//!    `agent-backend.nico-best-pc-ever.ovh` <-> `agent-backend.thomas.md`),
//!    including safe retry & failover for mutating writes carrying `Idempotency-Key`.

use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Write;
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const ORBCORE_DIRECT_URL: &str = "https://orbcore.thomas.md";
const DEFAULT_FALLBACK_URL: &str = "https://agent-backend.thomas.md";
const KNOWN_DIRECT_URL: &str = "https://agent-backend.nico-best-pc-ever.ovh";
const DNS_TIMEOUT: Duration = Duration::from_millis(2_500);
const DOH_TIMEOUT: Duration = Duration::from_millis(2_200);
const ORB_DESKTOP_USER_AGENT: &str = concat!("Orb/", env!("CARGO_PKG_VERSION"));
const ENDPOINT_COOLDOWN: Duration = Duration::from_secs(20);
const MAX_REQUEST_HEADER_BYTES: usize = 64 * 1024;
const MAX_REQUEST_BODY_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Serialize, Deserialize)]
pub struct TransportBridgeInfo {
    /// Base URL including the per-launch secret prefix, e.g.
    /// `http://127.0.0.1:54321/__orb_tx/<token>` (no trailing slash).
    pub proxy_base_url: String,
    pub configured_target: String,
    pub candidates: Vec<String>,
}

#[derive(Default, Serialize, Deserialize)]
struct PersistedDnsCache {
    hosts: HashMap<String, Vec<IpAddr>>,
}

#[derive(Deserialize)]
struct DohAnswerRecord {
    #[serde(rename = "type")]
    record_type: u16,
    data: String,
}

#[derive(Deserialize)]
struct DohResponse {
    #[serde(rename = "Status", default)]
    status: u16,
    #[serde(rename = "Answer", default)]
    answer: Vec<DohAnswerRecord>,
}

fn parse_doh_json_ips(raw: &[u8]) -> Vec<IpAddr> {
    let Ok(parsed) = serde_json::from_slice::<DohResponse>(raw) else {
        return Vec::new();
    };
    if parsed.status != 0 {
        return Vec::new();
    }
    let mut ips = Vec::new();
    for ans in parsed.answer {
        // 1 = A (IPv4), 28 = AAAA (IPv6)
        if matches!(ans.record_type, 1 | 28) {
            if let Ok(ip) = ans.data.trim().parse::<IpAddr>() {
                if !ips.contains(&ip) {
                    ips.push(ip);
                }
            }
        }
    }
    ips
}

fn doh_http_client() -> Option<&'static reqwest::Client> {
    static CLIENT: OnceLock<Option<reqwest::Client>> = OnceLock::new();
    CLIENT
        .get_or_init(|| {
            reqwest::Client::builder()
                .connect_timeout(Duration::from_millis(1_500))
                .timeout(DOH_TIMEOUT)
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .ok()
        })
        .as_ref()
}

fn should_skip_doh(host: &str) -> bool {
    cfg!(test)
        || host.eq_ignore_ascii_case("localhost")
        || host.ends_with(".local")
        || host.ends_with(".invalid")
        || host.ends_with(".localhost")
        || host.ends_with(".ts.net")
}

async fn resolve_via_doh(host: &str) -> Vec<IpAddr> {
    if should_skip_doh(host) {
        return Vec::new();
    }
    let Some(client) = doh_http_client() else {
        return Vec::new();
    };
    let clean = host.trim_end_matches('.');
    // Query Cloudflare (1.1.1.1) and Google (8.8.8.8) directly by IP literal so
    // resolution succeeds even when local mDNSResponder / MagicDNS is wedged.
    for base in ["https://1.1.1.1/dns-query", "https://8.8.8.8/resolve"] {
        let mut combined = Vec::new();
        for qtype in ["A", "AAAA"] {
            let res = client
                .get(base)
                .query(&[("name", clean), ("type", qtype)])
                .header("Accept", "application/dns-json")
                .send()
                .await;
            if let Ok(resp) = res {
                if resp.status().is_success() {
                    if let Ok(bytes) = resp.bytes().await {
                        for ip in parse_doh_json_ips(&bytes) {
                            if !combined.contains(&ip) {
                                combined.push(ip);
                            }
                        }
                    }
                }
            }
        }
        if !combined.is_empty() {
            return combined;
        }
    }
    Vec::new()
}

pub struct ResilientDnsResolver {
    cache_path: Option<PathBuf>,
    memory: Mutex<HashMap<String, Vec<IpAddr>>>,
}

impl ResilientDnsResolver {
    pub fn global() -> Arc<Self> {
        static INSTANCE: OnceLock<Arc<ResilientDnsResolver>> = OnceLock::new();
        INSTANCE
            .get_or_init(|| {
                let cache_path = if cfg!(test) {
                    None
                } else {
                    std::env::var_os("HOME")
                        .map(|h| PathBuf::from(h).join(".orb").join("dns-cache.json"))
                };
                Arc::new(Self::new(cache_path))
            })
            .clone()
    }

    pub fn new(cache_path: Option<PathBuf>) -> Self {
        let initial = cache_path
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice::<PersistedDnsCache>(&b).ok())
            .map(|c| c.hosts)
            .unwrap_or_default();
        Self {
            cache_path,
            memory: Mutex::new(initial),
        }
    }

    #[cfg(test)]
    pub fn seed(&self, host: &str, ips: Vec<IpAddr>) {
        self.record(host, &ips);
    }

    fn cached(&self, host: &str) -> Option<Vec<IpAddr>> {
        let key = host.trim_end_matches('.').to_ascii_lowercase();
        self.memory
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&key)
            .cloned()
            .filter(|ips| !ips.is_empty())
    }

    fn record(&self, host: &str, ips: &[IpAddr]) {
        if ips.is_empty() {
            return;
        }
        let key = host.trim_end_matches('.').to_ascii_lowercase();
        let snapshot = {
            let mut guard = self.memory.lock().unwrap_or_else(|e| e.into_inner());
            if guard.get(&key).is_some_and(|existing| existing == ips) {
                return;
            }
            guard.insert(key, ips.to_vec());
            guard.clone()
        };
        let Some(path) = self.cache_path.clone() else {
            return;
        };
        // Persist best-effort off the async path.
        std::thread::spawn(move || {
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let tmp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
            if let Ok(bytes) = serde_json::to_vec(&PersistedDnsCache { hosts: snapshot }) {
                if let Ok(mut file) = std::fs::File::create(&tmp) {
                    if file.write_all(&bytes).is_ok() {
                        let _ = std::fs::rename(&tmp, &path);
                        return;
                    }
                }
            }
            let _ = std::fs::remove_file(&tmp);
        });
    }
}

impl Resolve for ResilientDnsResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_string();
        let memory_fallback = self.cached(&host);
        let persist_global = self.cache_path.is_some();
        Box::pin(async move {
            if let Ok(ip) = host.parse::<IpAddr>() {
                let addrs: Addrs = Box::new(std::iter::once(SocketAddr::new(ip, 0)));
                return Ok(addrs);
            }
            let lookup =
                tokio::time::timeout(DNS_TIMEOUT, tokio::net::lookup_host((host.as_str(), 0)))
                    .await;
            if let Ok(Ok(iter)) = lookup {
                let mut ips = Vec::new();
                for addr in iter {
                    if !ips.contains(&addr.ip()) {
                        ips.push(addr.ip());
                    }
                }
                if !ips.is_empty() {
                    if persist_global {
                        Self::global().record(&host, &ips);
                    }
                    let addrs: Addrs = Box::new(ips.into_iter().map(|ip| SocketAddr::new(ip, 0)));
                    return Ok(addrs);
                }
            }
            // Encrypted DNS-over-HTTPS fallback over direct IP (1.1.1.1 / 8.8.8.8)
            // when system DNS stalls or returns NXDOMAIN/SERVFAIL.
            let doh_ips = resolve_via_doh(&host).await;
            if !doh_ips.is_empty() {
                if persist_global {
                    Self::global().record(&host, &doh_ips);
                }
                let addrs: Addrs = Box::new(doh_ips.into_iter().map(|ip| SocketAddr::new(ip, 0)));
                return Ok(addrs);
            }
            if let Some(cached_ips) = memory_fallback {
                let addrs: Addrs =
                    Box::new(cached_ips.into_iter().map(|ip| SocketAddr::new(ip, 0)));
                return Ok(addrs);
            }
            let err: Box<dyn std::error::Error + Send + Sync> = Box::new(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                format!("DNS resolution failed for {host}"),
            ));
            Err(err)
        })
    }
}

/// Shared `reqwest::Client` builder wired with `ResilientDnsResolver`, HTTP/2
/// keepalive PING frames, TCP keepalive, and rustls connection pooling so Tauri
/// workers (`project_context`, `local_origin`) inherit the same DNS & socket immunity.
pub fn resilient_client_builder() -> reqwest::ClientBuilder {
    reqwest::Client::builder()
        .user_agent(ORB_DESKTOP_USER_AGENT)
        .dns_resolver(ResilientDnsResolver::global())
        .tcp_keepalive(Duration::from_secs(20))
        .http2_adaptive_window(true)
        .http2_keep_alive_interval(Duration::from_secs(10))
        .http2_keep_alive_timeout(Duration::from_secs(4))
        .http2_keep_alive_while_idle(true)
        .pool_idle_timeout(Duration::from_secs(90))
}

pub fn normalize_base_url(raw: &str) -> String {
    raw.trim().trim_end_matches('/').to_string()
}

/// Ordered candidate origins for a configured primary URL.
/// Pairs the two direct origin hosts (`orbcore.thomas.md` on Cloudflare Anycast DNS
/// and `agent-backend.nico-best-pc-ever.ovh` on OVH DNS) with the Cloudflare edge
/// (`agent-backend.thomas.md`) as a 3-way circuit-breaker ring.
pub fn candidate_endpoints(primary: &str) -> Vec<String> {
    let clean = normalize_base_url(primary);
    if clean.is_empty() {
        return Vec::new();
    }
    let lower = clean.to_ascii_lowercase();
    if lower == ORBCORE_DIRECT_URL {
        return vec![
            clean,
            KNOWN_DIRECT_URL.to_string(),
            DEFAULT_FALLBACK_URL.to_string(),
        ];
    }
    if lower == KNOWN_DIRECT_URL {
        return vec![
            clean,
            ORBCORE_DIRECT_URL.to_string(),
            DEFAULT_FALLBACK_URL.to_string(),
        ];
    }
    if lower == DEFAULT_FALLBACK_URL {
        return vec![
            clean,
            ORBCORE_DIRECT_URL.to_string(),
            KNOWN_DIRECT_URL.to_string(),
        ];
    }
    let mut out = vec![clean.clone()];
    if lower.ends_with(".thomas.md") {
        out.push(ORBCORE_DIRECT_URL.to_string());
        out.push(DEFAULT_FALLBACK_URL.to_string());
    }
    out
}

fn is_failover_status(status: u16) -> bool {
    matches!(status, 502..=504 | 520..=529)
}

fn is_idempotent_request(method: &str, headers: &[(String, String)]) -> bool {
    if matches!(method, "GET" | "HEAD" | "OPTIONS") {
        return true;
    }
    headers
        .iter()
        .any(|(k, v)| k.eq_ignore_ascii_case("idempotency-key") && !v.trim().is_empty())
}

struct BridgeConfig {
    primary: String,
    candidates: Vec<String>,
    cooldowns: HashMap<String, Instant>,
}

struct BridgeRuntime {
    port: u16,
    secret_prefix: String,
    api_client: reqwest::Client,
    stream_client: reqwest::Client,
    config: RwLock<BridgeConfig>,
}

impl BridgeRuntime {
    fn ordered_candidates(&self, explicit_target: Option<&str>) -> Vec<String> {
        let now = Instant::now();
        let guard = self.config.read().unwrap_or_else(|e| e.into_inner());
        let base_list = match explicit_target {
            Some(target) if !target.trim().is_empty() => candidate_endpoints(target),
            _ => guard.candidates.clone(),
        };
        if base_list.len() <= 1 {
            return base_list;
        }
        let mut healthy = Vec::with_capacity(base_list.len());
        let mut cooling = Vec::new();
        for url in base_list {
            if guard.cooldowns.get(&url).is_some_and(|until| *until > now) {
                cooling.push(url);
            } else {
                healthy.push(url);
            }
        }
        healthy.extend(cooling);
        healthy
    }

    fn mark_healthy(&self, endpoint: &str) {
        let mut guard = self.config.write().unwrap_or_else(|e| e.into_inner());
        guard.cooldowns.remove(endpoint);
    }

    fn mark_unhealthy(&self, endpoint: &str) {
        let mut guard = self.config.write().unwrap_or_else(|e| e.into_inner());
        guard
            .cooldowns
            .insert(endpoint.to_string(), Instant::now() + ENDPOINT_COOLDOWN);
    }

    fn configure(&self, api_url: &str) -> TransportBridgeInfo {
        let clean = normalize_base_url(api_url);
        let candidates = candidate_endpoints(&clean);
        {
            let mut guard = self.config.write().unwrap_or_else(|e| e.into_inner());
            if guard.primary != clean {
                guard.primary = clean.clone();
                guard.candidates = candidates.clone();
                guard.cooldowns.clear();
            }
        }
        TransportBridgeInfo {
            proxy_base_url: format!("http://127.0.0.1:{}{}", self.port, self.secret_prefix),
            configured_target: clean,
            candidates,
        }
    }
}

static BRIDGE: OnceLock<Result<Arc<BridgeRuntime>, String>> = OnceLock::new();

fn ensure_bridge() -> Result<Arc<BridgeRuntime>, String> {
    BRIDGE
        .get_or_init(|| start_bridge_with_resolver(ResilientDnsResolver::global()))
        .clone()
}

fn start_bridge_with_resolver(
    resolver: Arc<ResilientDnsResolver>,
) -> Result<Arc<BridgeRuntime>, String> {
    let std_listener = std::net::TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    std_listener
        .set_nonblocking(true)
        .map_err(|e| e.to_string())?;
    let port = std_listener.local_addr().map_err(|e| e.to_string())?.port();
    let secret_prefix = format!("/__orb_tx/{}", uuid::Uuid::new_v4());

    let api_client = reqwest::Client::builder()
        .user_agent(ORB_DESKTOP_USER_AGENT)
        .dns_resolver(resolver.clone())
        .connect_timeout(Duration::from_secs(6))
        .timeout(Duration::from_secs(35))
        .tcp_keepalive(Duration::from_secs(20))
        .http2_adaptive_window(true)
        .http2_keep_alive_interval(Duration::from_secs(10))
        .http2_keep_alive_timeout(Duration::from_secs(4))
        .http2_keep_alive_while_idle(true)
        .pool_idle_timeout(Duration::from_secs(90))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())?;

    let stream_client = reqwest::Client::builder()
        .user_agent(ORB_DESKTOP_USER_AGENT)
        .dns_resolver(resolver)
        .no_gzip()
        .connect_timeout(Duration::from_secs(8))
        .tcp_keepalive(Duration::from_secs(15))
        .http2_adaptive_window(true)
        .http2_keep_alive_interval(Duration::from_secs(10))
        .http2_keep_alive_timeout(Duration::from_secs(4))
        .http2_keep_alive_while_idle(true)
        .pool_idle_timeout(Duration::from_secs(90))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| e.to_string())?;

    let initial_url = ORBCORE_DIRECT_URL.to_string();
    let runtime = Arc::new(BridgeRuntime {
        port,
        secret_prefix,
        api_client,
        stream_client,
        config: RwLock::new(BridgeConfig {
            candidates: candidate_endpoints(&initial_url),
            primary: initial_url,
            cooldowns: HashMap::new(),
        }),
    });

    let listener_runtime = runtime.clone();
    tauri::async_runtime::spawn(async move {
        let Ok(listener) = TcpListener::from_std(std_listener) else {
            return;
        };
        accept_loop(listener, listener_runtime).await;
    });

    Ok(runtime)
}

async fn accept_loop(listener: TcpListener, runtime: Arc<BridgeRuntime>) {
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            tokio::time::sleep(Duration::from_millis(25)).await;
            continue;
        };
        let _ = stream.set_nodelay(true);
        let rt = runtime.clone();
        tokio::spawn(async move {
            let _ = handle_connection(stream, rt).await;
        });
    }
}

struct ParsedHttpRequest {
    method: String,
    target: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

async fn read_http_request(stream: &mut TcpStream) -> Result<Option<ParsedHttpRequest>, String> {
    let mut buf = Vec::with_capacity(4096);
    let mut scratch = [0u8; 4096];
    let header_end = loop {
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos;
        }
        if buf.len() >= MAX_REQUEST_HEADER_BYTES {
            return Err("request headers too large".into());
        }
        let n = stream.read(&mut scratch).await.map_err(|e| e.to_string())?;
        if n == 0 {
            if buf.is_empty() {
                return Ok(None);
            }
            return Err("unexpected EOF reading request headers".into());
        }
        buf.extend_from_slice(&scratch[..n]);
    };

    let header_text = std::str::from_utf8(&buf[..header_end]).map_err(|e| e.to_string())?;
    let mut lines = header_text.split("\r\n");
    let request_line = lines.next().ok_or("missing request line")?;
    let mut parts = request_line.split_whitespace();
    let method = parts.next().ok_or("missing method")?.to_ascii_uppercase();
    let target = parts.next().ok_or("missing request target")?.to_string();

    let mut headers = Vec::new();
    let mut content_length = 0usize;
    let mut is_chunked = false;
    for line in lines {
        if let Some((name, val)) = line.split_once(':') {
            let clean_name = name.trim().to_string();
            let clean_val = val.trim().to_string();
            if clean_name.eq_ignore_ascii_case("content-length") {
                content_length = clean_val
                    .parse::<usize>()
                    .map_err(|_| "invalid content-length")?;
                if content_length > MAX_REQUEST_BODY_BYTES {
                    return Err("request body exceeds limit".into());
                }
            } else if clean_name.eq_ignore_ascii_case("transfer-encoding")
                && clean_val.to_ascii_lowercase().contains("chunked")
            {
                is_chunked = true;
            }
            headers.push((clean_name, clean_val));
        }
    }

    let body_start = header_end + 4;
    let mut body = Vec::new();
    if is_chunked {
        return Err("chunked request bodies are not supported".into());
    }
    if content_length > 0 {
        let already = buf.len().saturating_sub(body_start);
        let take = already.min(content_length);
        body.extend_from_slice(&buf[body_start..body_start + take]);
        if body.len() < content_length {
            let remaining = content_length - body.len();
            let prev = body.len();
            body.resize(content_length, 0);
            stream
                .read_exact(&mut body[prev..prev + remaining])
                .await
                .map_err(|e| e.to_string())?;
        }
    }

    Ok(Some(ParsedHttpRequest {
        method,
        target,
        headers,
        body,
    }))
}

fn cors_headers(req_headers: &[(String, String)]) -> String {
    let origin = req_headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("origin"))
        .map(|(_, v)| v.as_str())
        .unwrap_or("*");
    let req_allow_headers = req_headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("access-control-request-headers"))
        .map(|(_, v)| v.as_str())
        .unwrap_or(
            "Authorization, Content-Type, Accept, Cache-Control, Last-Event-ID, Idempotency-Key, X-Orb-Target, X-Paloma-Approval",
        );
    format!(
        "Access-Control-Allow-Origin: {origin}\r\n\
         Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS\r\n\
         Access-Control-Allow-Headers: {req_allow_headers}\r\n\
         Access-Control-Expose-Headers: X-Orb-Events-Protocol, X-Has-More, X-Next-Cursor, X-Page-Max-Sequence, X-Max-Sequence, X-Orb-Upstream, X-Orb-Idempotent-Replay, Content-Type\r\n\
         Access-Control-Max-Age: 86400\r\n\
         Vary: Origin\r\n"
    )
}

async fn write_simple_response(
    stream: &mut TcpStream,
    status_line: &str,
    cors: &str,
    content_type: &str,
    body: &[u8],
) -> Result<(), String> {
    let head = format!(
        "HTTP/1.1 {status_line}\r\n\
         {cors}\
         Content-Type: {content_type}\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\r\n",
        body.len()
    );
    stream
        .write_all(head.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    if !body.is_empty() {
        stream.write_all(body).await.map_err(|e| e.to_string())?;
    }
    let _ = stream.shutdown().await;
    Ok(())
}

fn should_strip_request_header(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    matches!(
        lower.as_str(),
        "host"
            | "connection"
            | "keep-alive"
            | "proxy-authenticate"
            | "proxy-authorization"
            | "te"
            | "trailer"
            | "transfer-encoding"
            | "upgrade"
            | "content-length"
            | "accept-encoding"
            | "origin"
            | "referer"
            | "x-orb-target"
    ) || lower.starts_with("sec-")
}

fn should_strip_response_header(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    matches!(
        lower.as_str(),
        "connection"
            | "keep-alive"
            | "transfer-encoding"
            | "content-length"
            | "content-encoding"
            | "alt-svc"
    ) || lower.starts_with("access-control-")
}

fn is_streaming_request(path: &str, headers: &[(String, String)]) -> bool {
    if path.starts_with("/api/control/stream") || path.contains("/context/stream") {
        return true;
    }
    headers.iter().any(|(k, v)| {
        k.eq_ignore_ascii_case("accept") && v.to_ascii_lowercase().contains("text/event-stream")
    })
}

async fn handle_connection(
    mut stream: TcpStream,
    runtime: Arc<BridgeRuntime>,
) -> Result<(), String> {
    let Some(req) = read_http_request(&mut stream).await? else {
        return Ok(());
    };
    let cors = cors_headers(&req.headers);

    if req.method == "OPTIONS" {
        return write_simple_response(&mut stream, "204 No Content", &cors, "text/plain", b"")
            .await;
    }

    let Some(forward_path) = req.target.strip_prefix(&runtime.secret_prefix) else {
        return write_simple_response(
            &mut stream,
            "403 Forbidden",
            &cors,
            "application/json",
            br#"{"error":"invalid bridge token"}"#,
        )
        .await;
    };
    let forward_path = if forward_path.is_empty() {
        "/"
    } else if forward_path.starts_with('/') {
        forward_path
    } else {
        return write_simple_response(
            &mut stream,
            "400 Bad Request",
            &cors,
            "application/json",
            br#"{"error":"invalid forward path"}"#,
        )
        .await;
    };

    let explicit_target = req
        .headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("x-orb-target"))
        .map(|(_, v)| v.as_str());
    let candidates = runtime.ordered_candidates(explicit_target);
    if candidates.is_empty() {
        return write_simple_response(
            &mut stream,
            "503 Service Unavailable",
            &cors,
            "application/json",
            br#"{"error":"no upstream configured"}"#,
        )
        .await;
    }

    let streaming = is_streaming_request(forward_path, &req.headers);
    let client = if streaming {
        &runtime.stream_client
    } else {
        &runtime.api_client
    };
    let method = reqwest::Method::from_bytes(req.method.as_bytes()).map_err(|e| e.to_string())?;
    let idempotent = is_idempotent_request(&req.method, &req.headers);

    let mut last_transport_err: Option<String> = None;
    let mut fallback_response: Option<(String, reqwest::Response)> = None;

    for (idx, base) in candidates.iter().enumerate() {
        let is_last = idx + 1 == candidates.len();
        let url = format!("{base}{forward_path}");
        let build_req = || {
            let mut b = client.request(method.clone(), &url);
            for (k, v) in &req.headers {
                if !should_strip_request_header(k) {
                    b = b.header(k.as_str(), v.as_str());
                }
            }
            if !req.body.is_empty() {
                b = b.body(req.body.clone());
            }
            b
        };

        // For idempotent requests (GET/HEAD or writes carrying Idempotency-Key),
        // perform 1 fast retry on immediate connect/socket reset before cooling down.
        let mut send_res = build_req().send().await;
        if send_res.is_err() && idempotent && !streaming {
            tokio::time::sleep(Duration::from_millis(180)).await;
            send_res = build_req().send().await;
        }

        match send_res {
            Ok(resp) => {
                let status = resp.status().as_u16();
                if is_failover_status(status)
                    && !is_last
                    && (idempotent || status == 502 || status == 503)
                {
                    runtime.mark_unhealthy(base);
                    fallback_response = Some((base.clone(), resp));
                    continue;
                }
                if !is_failover_status(status) {
                    runtime.mark_healthy(base);
                }
                return relay_upstream_response(&mut stream, resp, base, &cors, streaming).await;
            }
            Err(err) => {
                runtime.mark_unhealthy(base);
                last_transport_err = Some(err.to_string());
                // Non-idempotent requests without Idempotency-Key fail over ONLY
                // when connect() failed before bytes were committed.
                if !idempotent && !err.is_connect() {
                    break;
                }
            }
        }
    }

    if let Some((base, resp)) = fallback_response {
        return relay_upstream_response(&mut stream, resp, &base, &cors, streaming).await;
    }

    let detail = last_transport_err.unwrap_or_else(|| "upstream unreachable".to_string());
    let payload = serde_json::json!({
        "error": "upstream_unreachable",
        "message": format!("Load failed ({detail})"),
    });
    let bytes = serde_json::to_vec(&payload).unwrap_or_default();
    write_simple_response(
        &mut stream,
        "502 Bad Gateway",
        &cors,
        "application/json",
        &bytes,
    )
    .await
}

async fn relay_upstream_response(
    stream: &mut TcpStream,
    mut resp: reqwest::Response,
    upstream_base: &str,
    cors: &str,
    streaming: bool,
) -> Result<(), String> {
    let status = resp.status();
    let reason = status.canonical_reason().unwrap_or("OK");
    let mut forwarded_headers = String::new();
    for (name, value) in resp.headers() {
        let key = name.as_str();
        if should_strip_response_header(key) {
            continue;
        }
        if let Ok(val_str) = value.to_str() {
            if !val_str.contains(['\r', '\n']) {
                forwarded_headers.push_str(key);
                forwarded_headers.push_str(": ");
                forwarded_headers.push_str(val_str);
                forwarded_headers.push_str("\r\n");
            }
        }
    }
    forwarded_headers.push_str(&format!("X-Orb-Upstream: {upstream_base}\r\n"));

    if streaming {
        let head = format!(
            "HTTP/1.1 {} {reason}\r\n\
             {cors}\
             {forwarded_headers}\
             Cache-Control: no-cache\r\n\
             Connection: close\r\n\r\n",
            status.as_u16()
        );
        stream
            .write_all(head.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        stream.flush().await.map_err(|e| e.to_string())?;
        while let Some(chunk) = resp.chunk().await.map_err(|e| e.to_string())? {
            if chunk.is_empty() {
                continue;
            }
            stream.write_all(&chunk).await.map_err(|e| e.to_string())?;
            stream.flush().await.map_err(|e| e.to_string())?;
        }
        let _ = stream.shutdown().await;
        return Ok(());
    }

    let body = resp.bytes().await.map_err(|e| e.to_string())?;
    let head = format!(
        "HTTP/1.1 {} {reason}\r\n\
         {cors}\
         {forwarded_headers}\
         Content-Length: {}\r\n\
         Connection: close\r\n\r\n",
        status.as_u16(),
        body.len()
    );
    stream
        .write_all(head.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    if !body.is_empty() {
        stream.write_all(&body).await.map_err(|e| e.to_string())?;
    }
    let _ = stream.shutdown().await;
    Ok(())
}

#[tauri::command]
pub fn transport_bridge_configure(api_url: String) -> Result<TransportBridgeInfo, String> {
    let bridge = ensure_bridge()?;
    Ok(bridge.configure(&api_url))
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn spawn_mock_upstream(
        handler: impl Fn(String) -> (u16, &'static str, String) + Send + Sync + 'static,
    ) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let handler = Arc::new(handler);
        tokio::spawn(async move {
            while let Ok((mut sock, _)) = listener.accept().await {
                let h = handler.clone();
                tokio::spawn(async move {
                    let mut buf = [0u8; 4096];
                    let n = sock.read(&mut buf).await.unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]).into_owned();
                    let (code, reason, body) = h(req);
                    let resp = format!(
                        "HTTP/1.1 {code} {reason}\r\nContent-Type: application/json\r\nX-Orb-Events-Protocol: 1\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = sock.write_all(resp.as_bytes()).await;
                    let _ = sock.shutdown().await;
                });
            }
        });
        format!("http://127.0.0.1:{}", addr.port())
    }

    fn spawn_test_bridge(resolver: Arc<ResilientDnsResolver>) -> Arc<BridgeRuntime> {
        let std_listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        std_listener.set_nonblocking(true).unwrap();
        let port = std_listener.local_addr().unwrap().port();
        let secret_prefix = format!("/__orb_tx/{}", uuid::Uuid::new_v4());
        let api_client = reqwest::Client::builder()
            .user_agent(ORB_DESKTOP_USER_AGENT)
            .dns_resolver(resolver.clone())
            .connect_timeout(Duration::from_millis(500))
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap();
        let stream_client = reqwest::Client::builder()
            .user_agent(ORB_DESKTOP_USER_AGENT)
            .dns_resolver(resolver)
            .no_gzip()
            .connect_timeout(Duration::from_millis(500))
            .build()
            .unwrap();
        let rt = Arc::new(BridgeRuntime {
            port,
            secret_prefix,
            api_client,
            stream_client,
            config: RwLock::new(BridgeConfig {
                primary: String::new(),
                candidates: Vec::new(),
                cooldowns: HashMap::new(),
            }),
        });
        let listener_rt = rt.clone();
        tokio::spawn(async move {
            let listener = TcpListener::from_std(std_listener).unwrap();
            accept_loop(listener, listener_rt).await;
        });
        rt
    }

    #[test]
    fn candidate_endpoints_form_three_way_failover_ring() {
        assert_eq!(
            candidate_endpoints("https://orbcore.thomas.md/"),
            vec![
                "https://orbcore.thomas.md",
                "https://agent-backend.nico-best-pc-ever.ovh",
                "https://agent-backend.thomas.md",
            ]
        );
        assert_eq!(
            candidate_endpoints("https://agent-backend.nico-best-pc-ever.ovh/"),
            vec![
                "https://agent-backend.nico-best-pc-ever.ovh",
                "https://orbcore.thomas.md",
                "https://agent-backend.thomas.md",
            ]
        );
        assert_eq!(
            candidate_endpoints("https://agent-backend.thomas.md"),
            vec![
                "https://agent-backend.thomas.md",
                "https://orbcore.thomas.md",
                "https://agent-backend.nico-best-pc-ever.ovh",
            ]
        );
    }

    #[test]
    fn doh_json_parser_extracts_ipv4_and_ipv6_records() {
        let sample = br#"{
            "Status": 0,
            "Answer": [
                {"name": "orbcore.thomas.md.", "type": 5, "TTL": 120, "data": "alias.example."},
                {"name": "orbcore.thomas.md.", "type": 1, "TTL": 120, "data": "65.109.98.246"},
                {"name": "orbcore.thomas.md.", "type": 28, "TTL": 120, "data": "2a01:4f9:3080:19d7::2"}
            ]
        }"#;
        let ips = parse_doh_json_ips(sample);
        assert_eq!(
            ips,
            vec![
                "65.109.98.246".parse::<IpAddr>().unwrap(),
                "2a01:4f9:3080:19d7::2".parse::<IpAddr>().unwrap(),
            ]
        );
    }

    #[tokio::test]
    async fn bridge_handles_options_preflight_locally_and_forwards_headers() {
        let upstream = spawn_mock_upstream(|req| {
            let has_auth = req
                .to_ascii_lowercase()
                .contains("authorization: bearer secret-jwt");
            (200, "OK", format!(r#"{{"auth":{has_auth}}}"#))
        })
        .await;
        let bridge = spawn_test_bridge(Arc::new(ResilientDnsResolver::new(None)));
        let info = bridge.configure(&upstream);
        let client = reqwest::Client::new();

        let preflight = client
            .request(
                reqwest::Method::OPTIONS,
                format!("{}/api/health", info.proxy_base_url),
            )
            .header("Origin", "tauri://localhost")
            .send()
            .await
            .unwrap();
        assert_eq!(preflight.status(), 204);
        assert_eq!(
            preflight
                .headers()
                .get("access-control-allow-origin")
                .unwrap(),
            "tauri://localhost"
        );

        let res = client
            .get(format!("{}/api/health", info.proxy_base_url))
            .header("Authorization", "Bearer secret-jwt")
            .send()
            .await
            .unwrap();
        assert_eq!(res.status(), 200);
        assert_eq!(res.headers().get("x-orb-events-protocol").unwrap(), "1");
        let body: serde_json::Value = res.json().await.unwrap();
        assert_eq!(body["auth"], true);
    }

    #[tokio::test]
    async fn bridge_fails_over_idempotent_post_across_504_upstream() {
        let broken =
            spawn_mock_upstream(|_| (504, "Gateway Timeout", r#"{"err":504}"#.into())).await;
        let healthy = spawn_mock_upstream(|req| {
            let has_idem = req
                .to_ascii_lowercase()
                .contains("idempotency-key: idem-77");
            (200, "OK", format!(r#"{{"idem":{has_idem}}}"#))
        })
        .await;
        let bridge = spawn_test_bridge(Arc::new(ResilientDnsResolver::new(None)));
        {
            let mut guard = bridge.config.write().unwrap();
            guard.primary = broken.clone();
            guard.candidates = vec![broken, healthy.clone()];
        }
        let base = format!("http://127.0.0.1:{}{}", bridge.port, bridge.secret_prefix);
        let res = reqwest::Client::new()
            .post(format!("{base}/api/control/message"))
            .header("Idempotency-Key", "idem-77")
            .header("Content-Type", "application/json")
            .body(r#"{"content":"ping"}"#)
            .send()
            .await
            .unwrap();
        assert_eq!(res.status(), 200);
        assert_eq!(res.headers().get("x-orb-upstream").unwrap(), &healthy);
        let body: serde_json::Value = res.json().await.unwrap();
        assert_eq!(body["idem"], true);
    }

    #[tokio::test]
    async fn resilient_dns_falls_back_to_last_known_good_ip_when_lookup_fails() {
        let upstream = spawn_mock_upstream(|_| (200, "OK", r#"{"dns":"cached"}"#.into())).await;
        let port: u16 = upstream.rsplit(':').next().unwrap().parse().unwrap();
        let resolver = Arc::new(ResilientDnsResolver::new(None));
        resolver.seed(
            "unresolvable-orb-test.invalid",
            vec!["127.0.0.1".parse().unwrap()],
        );

        let bridge = spawn_test_bridge(resolver);
        let info = bridge.configure(&format!("http://unresolvable-orb-test.invalid:{port}"));
        let res = reqwest::Client::new()
            .get(format!("{}/api/health", info.proxy_base_url))
            .send()
            .await
            .unwrap();
        assert_eq!(res.status(), 200);
        let json: serde_json::Value = res.json().await.unwrap();
        assert_eq!(json["dns"], "cached");
    }

    #[test]
    fn tauri_permission_manifest_allows_transport_bridge_configure() {
        let manifest = include_str!("../permissions/local-agents.toml");
        assert!(
            manifest.contains("\"transport_bridge_configure\""),
            "orb/src-tauri/permissions/local-agents.toml must list transport_bridge_configure in commands.allow"
        );
    }

    #[tokio::test]
    async fn bridge_decompresses_gzip_upstream_and_sends_orb_user_agent() {
        use std::io::Write as _;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let Ok((mut sock, _)) = listener.accept().await else {
                return;
            };
            let mut buf = vec![0u8; 8192];
            let n = sock.read(&mut buf).await.unwrap_or(0);
            let raw = String::from_utf8_lossy(&buf[..n]).to_string();
            let lower = raw.to_ascii_lowercase();
            let accepted_gzip = lower.contains("accept-encoding:") && lower.contains("gzip");
            let has_ua = lower.contains("user-agent: orb/");
            let json = format!(r#"{{"gzip":{accepted_gzip},"ua":{has_ua}}}"#);
            let mut encoder =
                flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
            encoder.write_all(json.as_bytes()).unwrap();
            let compressed = encoder.finish().unwrap();
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                compressed.len()
            );
            let _ = sock.write_all(head.as_bytes()).await;
            let _ = sock.write_all(&compressed).await;
            let _ = sock.shutdown().await;
        });

        let bridge = spawn_test_bridge(Arc::new(ResilientDnsResolver::new(None)));
        let info = bridge.configure(&format!("http://127.0.0.1:{}", addr.port()));
        let res = reqwest::Client::builder()
            .no_gzip()
            .build()
            .unwrap()
            .get(format!("{}/api/health", info.proxy_base_url))
            .header("Accept-Encoding", "identity")
            .send()
            .await
            .unwrap();
        assert_eq!(res.status(), 200);
        assert!(res.headers().get("content-encoding").is_none());
        let body: serde_json::Value = res.json().await.unwrap();
        assert_eq!(body["gzip"], true);
        assert_eq!(body["ua"], true);
    }
}
