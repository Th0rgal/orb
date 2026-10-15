//! Client link uplink: streams local runs to Core over one WebSocket so other
//! clients (iOS, dashboard, another Orb) can follow them live.
//!
//! Reliability model:
//! - every event is appended to a per-mission journal on disk (fsynced per
//!   batch) before it is sent, with a sequence number that is contiguous per
//!   (mission, computer) across runs;
//! - Core persists before it acknowledges, and keeps the same cursor, so after
//!   any disconnect or crash Orb asks for the cursor and replays the rest;
//! - acknowledged entries are compacted away.
//!
//! The protocol is defined by Core in `src/api/control/client_link.rs`.
//! Disabled unless `ORB_CLIENT_LINK=1` or `~/.orb/client-link/enabled` exists.
use crate::local_stream::{Activity, Event};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::Notify;
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message};

/// Appended text is coalesced for this long before it becomes one event.
const COALESCE: Duration = Duration::from_millis(250);
/// Unacknowledged events in flight per mission.
const WINDOW: u64 = 256;
const UNSUPPORTED: &str = "Client link requires";

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".orb/client-link"))
}

pub fn enabled() -> bool {
    std::env::var("ORB_CLIENT_LINK").is_ok_and(|v| v == "1")
        || home().is_some_and(|h| h.join("enabled").exists())
}

/// True once Core has accepted the link for this API in this session. Only
/// then does the webview stop posting the assistant transcript itself (the
/// journal delivers it instead, so the two never duplicate or both go missing).
#[tauri::command]
pub fn client_link_active(api_url: String) -> bool {
    enabled()
        && accounts()
            .lock()
            .ok()
            .and_then(|map| map.get(api_url.trim_end_matches('/')).cloned())
            .is_some_and(|acc| acc.accepted.load(std::sync::atomic::Ordering::SeqCst))
}

// === Journal ===

/// Unacknowledged events of one mission, mirrored on disk.
struct Journal {
    dir: PathBuf,
    mission: String,
    acked: u64,
    next: u64,
    pending: BTreeMap<u64, Value>,
}

impl Journal {
    fn log_path(&self) -> PathBuf {
        self.dir.join(format!("{}.jsonl", self.mission))
    }
    fn ack_path(&self) -> PathBuf {
        self.dir.join(format!("{}.acked", self.mission))
    }

    fn load(dir: &Path, mission: &str) -> Self {
        let mut j = Journal {
            dir: dir.into(),
            mission: mission.into(),
            acked: 0,
            next: 1,
            pending: BTreeMap::new(),
        };
        j.acked = std::fs::read_to_string(j.ack_path())
            .ok()
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(0);
        let mut last = j.acked;
        if let Ok(text) = std::fs::read_to_string(j.log_path()) {
            // A torn final line (crash mid-write) is ignored: it was never sent.
            for line in text.lines() {
                let Ok(frame) = serde_json::from_str::<Value>(line) else {
                    continue;
                };
                let Some(seq) = frame["seq"].as_u64() else {
                    continue;
                };
                last = last.max(seq);
                if seq > j.acked {
                    j.pending.insert(seq, frame);
                }
            }
        }
        j.next = last + 1;
        j
    }

    /// Append a batch durably; returns the assigned sequences.
    fn append(&mut self, frames: Vec<Value>) -> std::io::Result<()> {
        if frames.is_empty() {
            return Ok(());
        }
        std::fs::create_dir_all(&self.dir)?;
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.log_path())?;
        let mut buf = Vec::new();
        let mut staged = Vec::new();
        for mut frame in frames {
            let seq = self.next;
            self.next += 1;
            frame["seq"] = json!(seq);
            serde_json::to_writer(&mut buf, &frame)?;
            buf.push(b'\n');
            staged.push((seq, frame));
        }
        file.write_all(&buf)?;
        file.sync_data()?;
        self.pending.extend(staged);
        Ok(())
    }

    fn ack(&mut self, seq: u64) -> std::io::Result<()> {
        if seq <= self.acked {
            return Ok(());
        }
        self.acked = seq;
        // Core may know more than a lost local journal; never reuse a number.
        self.next = self.next.max(seq + 1);
        self.pending = self.pending.split_off(&(seq + 1));
        let tmp = self.dir.join(format!("{}.acked.tmp", self.mission));
        std::fs::write(&tmp, seq.to_string())?;
        std::fs::rename(&tmp, self.ack_path())?;
        if self.pending.is_empty() {
            // Everything is on Core: the log can restart empty.
            let _ = std::fs::remove_file(self.log_path());
        }
        Ok(())
    }
}

struct Account {
    dir: PathBuf,
    token: Mutex<String>,
    client_id: String,
    journals: Mutex<HashMap<String, Journal>>,
    wake: Notify,
    accepted: std::sync::atomic::AtomicBool,
}

fn accounts() -> &'static Mutex<HashMap<String, Arc<Account>>> {
    static A: OnceLock<Mutex<HashMap<String, Arc<Account>>>> = OnceLock::new();
    A.get_or_init(Default::default)
}

/// One uplink per Core: (re)used by every attached run, carrying the newest
/// token. Leftover journals from a previous session are loaded for replay.
fn account(api_url: &str, token: &str, client_id: &str) -> Option<Arc<Account>> {
    let api = api_url.trim_end_matches('/').to_string();
    let mut map = accounts().lock().ok()?;
    if let Some(acc) = map.get(&api) {
        *acc.token.lock().ok()? = token.into();
        return Some(acc.clone());
    }
    let dir = home()?.join(crate::project_context_store::digest(api.as_bytes()));
    let mut journals = HashMap::new();
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if let Some(mission) = name.strip_suffix(".jsonl") {
                let j = Journal::load(&dir, mission);
                if !j.pending.is_empty() {
                    journals.insert(mission.to_string(), j);
                }
            }
        }
    }
    let acc = Arc::new(Account {
        dir,
        token: Mutex::new(token.into()),
        client_id: client_id.into(),
        journals: Mutex::new(journals),
        wake: Notify::new(),
        accepted: Default::default(),
    });
    map.insert(api.clone(), acc.clone());
    let task = acc.clone();
    tauri::async_runtime::spawn(async move { uplink(api, task).await });
    Some(acc)
}

impl Account {
    fn append(&self, mission: &str, frames: Vec<Value>) {
        if frames.is_empty() {
            return;
        }
        let Ok(mut journals) = self.journals.lock() else {
            return;
        };
        let journal = journals
            .entry(mission.to_string())
            .or_insert_with(|| Journal::load(&self.dir, mission));
        if let Err(error) = journal.append(frames) {
            eprintln!("[client-link] journal write failed for {mission}: {error}");
        }
        drop(journals);
        self.wake.notify_one();
    }
}

// === Conversion: local output → Core client events ===

/// Turns one run's output stream into Core client events.
struct Converter {
    bubble: String,
    text: String,
    revision: u64,
    pending: String,
    activities: HashMap<String, bool>,
}

impl Converter {
    fn new(run_id: &str) -> Self {
        Converter {
            bubble: format!("orb:{run_id}"),
            text: String::new(),
            revision: 0,
            pending: String::new(),
            activities: HashMap::new(),
        }
    }

    fn flush(&mut self, out: &mut Vec<Value>) {
        if self.pending.is_empty() {
            return;
        }
        let pos = self.text.chars().count();
        let text = std::mem::take(&mut self.pending);
        self.text.push_str(&text);
        out.push(json!({"type":"text_op","bubble_id":self.bubble,"ops":[{"type":"insert","pos":pos,"text":text}]}));
    }

    fn activities(&mut self, list: &[Activity], out: &mut Vec<Value>) {
        for a in list {
            let id = a.tool_use_id.clone().unwrap_or_else(|| a.id.clone());
            let seen = self.activities.get(&id).copied();
            if seen.is_none() {
                out.push(json!({"type":"tool_call","tool_call_id":id,"name":a.kind,"args":{"label":a.label,"detail":a.detail,"background":a.background}}));
            }
            if a.done && seen != Some(true) {
                out.push(json!({"type":"tool_result","tool_call_id":id,"name":a.kind,"result":{"status":a.status,"failed":a.failed,"detail":a.detail}}));
            }
            self.activities.insert(id, a.done);
        }
    }

    /// Returns true once the run is terminal.
    fn apply(&mut self, event: Event, out: &mut Vec<Value>) -> bool {
        if event.reset {
            self.pending.clear();
            if event.text != self.text {
                self.text = event.text;
                self.revision += 1;
                out.push(json!({"type":"text_op","bubble_id":self.bubble,"ops":[{"type":"snapshot","text":self.text,"revision":self.revision}]}));
            }
        } else {
            self.pending.push_str(&event.text);
        }
        if let Some(list) = &event.activities {
            self.flush(out);
            self.activities(list, out);
        }
        if let Some(state) = event.state {
            self.flush(out);
            self.activities(&state.activities, out);
            if let Some(error) = state.error.filter(|e| !e.trim().is_empty()) {
                out.push(json!({"type":"error","message":error,"resumable":state.retryable}));
            }
            out.push(json!({"type":"text_op","bubble_id":self.bubble,"ops":[{"type":"finalize"}]}));
            return true;
        }
        false
    }
}

/// Stream a freshly started local run to Core. Called once the native run is
/// running under a verified permit; a no-op unless the link is enabled.
pub fn attach(mission: &str, permit: &crate::transfers::Permit) {
    if !enabled() || permit.legacy {
        return;
    }
    let Some(acc) = account(&permit.api_url, &permit.token, &permit.client_id) else {
        return;
    };
    let (tx, rx) = std::sync::mpsc::channel::<Event>();
    if let Err(error) = crate::local_agents::subscribe_native(mission, tx) {
        eprintln!("[client-link] cannot follow {mission}: {error}");
        return;
    }
    let (mission, run_id, generation) = (
        mission.to_string(),
        permit.run_id.clone(),
        permit.generation,
    );
    std::thread::spawn(move || {
        let mut conv = Converter::new(&run_id);
        let frame = |event: Value| json!({"type":"event","mission_id":mission,"run_id":run_id,"generation":generation,"event":event});
        loop {
            let mut out = Vec::new();
            let mut idle = false;
            let done = match rx.recv_timeout(COALESCE) {
                Ok(event) => {
                    let mut done = conv.apply(event, &mut out);
                    // Drain whatever else is already queued into this batch.
                    while !done {
                        match rx.try_recv() {
                            Ok(event) => done = conv.apply(event, &mut out),
                            Err(_) => break,
                        }
                    }
                    done
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    idle = true;
                    false
                }
                // The run was dropped without a terminal state.
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => true,
            };
            // Text is coalesced until output pauses or grows large.
            if done || idle || conv.pending.len() > 4096 {
                conv.flush(&mut out);
            }
            acc.append(&mission, out.into_iter().map(frame).collect());
            if done {
                break;
            }
        }
    });
}

// === Uplink ===

async fn uplink(api: String, acc: Arc<Account>) {
    let mut backoff = Duration::from_secs(1);
    loop {
        match session(&api, &acc).await {
            Ok(Stop::Unsupported) => {
                acc.accepted
                    .store(false, std::sync::atomic::Ordering::SeqCst);
                eprintln!("[client-link] Core does not support the client link; uplink stopped");
                return;
            }
            Ok(Stop::Closed) => backoff = Duration::from_secs(1),
            Err(error) => eprintln!("[client-link] {error}"),
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(30));
    }
}

enum Stop {
    Closed,
    Unsupported,
}

fn ws_url(api: &str) -> String {
    let base = api
        .strip_prefix("https://")
        .map(|rest| format!("wss://{rest}"))
        .or_else(|| {
            api.strip_prefix("http://")
                .map(|rest| format!("ws://{rest}"))
        })
        .unwrap_or_else(|| api.to_string());
    format!("{base}/api/control/client-link")
}

async fn session(api: &str, acc: &Arc<Account>) -> Result<Stop, String> {
    let token = acc.token.lock().map_err(|e| e.to_string())?.clone();
    let mut request = ws_url(api)
        .into_client_request()
        .map_err(|e| e.to_string())?;
    request.headers_mut().insert(
        "Authorization",
        format!("Bearer {token}")
            .parse()
            .map_err(|_| "invalid token header")?,
    );
    let (ws, _) = tokio_tungstenite::connect_async(request)
        .await
        .map_err(|e| format!("connect failed: {e}"))?;
    let (mut tx, mut rx) = ws.split();
    let send = |v: Value| Message::Text(v.to_string());
    tx.send(send(json!({"type":"hello","client_id":acc.client_id})))
        .await
        .map_err(|e| e.to_string())?;

    // Per mission: highest sequence sent in this session (None until Core
    // told us its cursor, so nothing is sent before we know where to resume).
    let mut sent: HashMap<String, Option<u64>> = HashMap::new();
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        // Ask for the cursor of every journal not yet known in this session,
        // then send whatever the window allows.
        let mut frames = Vec::new();
        if let Ok(journals) = acc.journals.lock() {
            for (mission, journal) in journals.iter() {
                match sent.get(mission).copied() {
                    None => {
                        if !journal.pending.is_empty() {
                            sent.insert(mission.clone(), None);
                            frames.push(json!({"type":"cursor","mission_id":mission}));
                        }
                    }
                    Some(None) => {}
                    Some(Some(high)) => {
                        let limit = journal.acked + WINDOW;
                        let mut last = high;
                        for (seq, frame) in journal.pending.range(high + 1..=limit) {
                            frames.push(frame.clone());
                            last = *seq;
                        }
                        sent.insert(mission.clone(), Some(last));
                    }
                }
            }
        }
        for frame in frames {
            tx.send(send(frame)).await.map_err(|e| e.to_string())?;
        }
        tokio::select! {
            _ = acc.wake.notified() => {}
            _ = tick.tick() => {}
            message = rx.next() => {
                let text = match message {
                    Some(Ok(Message::Text(text))) => text,
                    Some(Ok(Message::Ping(p))) => { let _ = tx.send(Message::Pong(p)).await; continue; }
                    Some(Ok(_)) => continue,
                    Some(Err(e)) => return Err(e.to_string()),
                    None => return Ok(Stop::Closed),
                };
                let reply: Value = serde_json::from_str(&text).unwrap_or_default();
                if reply["type"] == "welcome" {
                    acc.accepted.store(true, std::sync::atomic::Ordering::SeqCst);
                    continue;
                }
                let mission = reply["mission_id"].as_str().unwrap_or_default().to_string();
                let Ok(mut journals) = acc.journals.lock() else { continue };
                let reason = reply["reason"].as_str().unwrap_or_default();
                if reason.starts_with(UNSUPPORTED) {
                    return Ok(Stop::Unsupported);
                }
                let Some(journal) = journals.get_mut(&mission) else { continue };
                match reply["type"].as_str() {
                    // A refusal consumes its sequence on Core, like an ack.
                    Some("ack" | "rejected") => {
                        if reply["type"] == "rejected" {
                            eprintln!("[client-link] {mission}: Core refused event {}: {reason}", reply["seq"]);
                        }
                        if let Some(seq) = reply["seq"].as_u64() {
                            let _ = journal.ack(seq);
                        }
                    }
                    Some("cursor") => {
                        let last = reply["last_seq"].as_u64().unwrap_or(0);
                        let _ = journal.ack(last);
                        sent.insert(mission, Some(last.max(journal.acked)));
                    }
                    Some("gap") => {
                        let expected = reply["expected"].as_u64().unwrap_or(1);
                        let _ = journal.ack(expected.saturating_sub(1));
                        sent.insert(mission, Some(expected.saturating_sub(1)));
                    }
                    // Transient: resend from this sequence on the next tick.
                    Some("retry") => {
                        let seq = reply["seq"].as_u64().unwrap_or(0);
                        if seq == 0 {
                            // The cursor request itself failed: ask again.
                            sent.remove(&mission);
                            continue;
                        }
                        if let Some(Some(high)) = sent.get(&mission).copied() {
                            sent.insert(mission, Some(high.min(seq.saturating_sub(1))));
                        }
                    }
                    _ => {}
                }
            }
        }
        // Journals fully acknowledged by Core no longer need tracking.
        if let Ok(mut journals) = acc.journals.lock() {
            let idle: HashSet<String> = journals
                .iter()
                .filter(|(_, j)| j.pending.is_empty())
                .map(|(m, _)| m.clone())
                .collect();
            for mission in idle {
                journals.remove(&mission);
                sent.remove(&mission);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(text: &str, reset: bool) -> Event {
        Event {
            text: text.into(),
            reset,
            activities: None,
            state: None,
        }
    }

    #[test]
    fn journal_survives_restart_and_compacts_on_ack() {
        let dir = tempfile::tempdir().unwrap();
        let mut j = Journal::load(dir.path(), "m");
        j.append(vec![json!({"type":"event"}), json!({"type":"event"})])
            .unwrap();
        j.append(vec![json!({"type":"event"})]).unwrap();
        let reloaded = Journal::load(dir.path(), "m");
        assert_eq!(
            reloaded.pending.keys().copied().collect::<Vec<_>>(),
            [1, 2, 3]
        );
        assert_eq!(reloaded.next, 4);

        j.ack(2).unwrap();
        let reloaded = Journal::load(dir.path(), "m");
        assert_eq!(reloaded.pending.keys().copied().collect::<Vec<_>>(), [3]);

        // Fully acknowledged: the log is gone, numbering continues.
        j.ack(3).unwrap();
        let mut reloaded = Journal::load(dir.path(), "m");
        assert!(reloaded.pending.is_empty());
        assert_eq!(reloaded.next, 4);
        reloaded.append(vec![json!({"type":"event"})]).unwrap();
        assert_eq!(reloaded.pending.keys().copied().collect::<Vec<_>>(), [4]);
    }

    #[test]
    fn torn_last_line_is_ignored() {
        let dir = tempfile::tempdir().unwrap();
        let mut j = Journal::load(dir.path(), "m");
        j.append(vec![json!({"type":"event"})]).unwrap();
        let mut f = std::fs::OpenOptions::new()
            .append(true)
            .open(j.log_path())
            .unwrap();
        f.write_all(b"{\"seq\":2,\"ty").unwrap();
        let reloaded = Journal::load(dir.path(), "m");
        assert_eq!(reloaded.pending.len(), 1);
        assert_eq!(reloaded.next, 2);
    }

    #[test]
    fn converter_emits_text_ops_activities_and_finalize() {
        let mut c = Converter::new("run");
        let mut out = Vec::new();
        assert!(!c.apply(event("", true), &mut out));
        assert!(out.is_empty(), "an empty initial snapshot is not sent");
        c.apply(event("Hé", false), &mut out);
        c.apply(event("llo", false), &mut out);
        c.flush(&mut out);
        assert_eq!(out.len(), 1);
        assert_eq!(
            out[0]["ops"][0],
            json!({"type":"insert","pos":0,"text":"Héllo"})
        );
        c.apply(event(" world", false), &mut out);
        c.flush(&mut out);
        assert_eq!(out[1]["ops"][0]["pos"], 5, "positions count characters");

        let mut activity = Activity {
            id: "a1".into(),
            label: "Run tests".into(),
            done: false,
            failed: false,
            kind: "command".into(),
            background: false,
            tool_use_id: Some("tool-1".into()),
            detail: None,
            status: "running".into(),
            started_at: 0,
            updated_at: 0,
            finished_at: None,
            thinking_tokens: None,
        };
        let mut out = Vec::new();
        c.apply(
            Event {
                activities: Some(vec![activity.clone()]),
                ..event("", false)
            },
            &mut out,
        );
        assert_eq!(out[0]["type"], "tool_call");
        assert_eq!(out[0]["tool_call_id"], "tool-1");
        activity.done = true;
        activity.status = "completed".into();
        c.apply(
            Event {
                activities: Some(vec![activity.clone()]),
                ..event("", false)
            },
            &mut out,
        );
        assert_eq!(out.len(), 2, "no second tool_call for a known activity");
        assert_eq!(out[1]["type"], "tool_result");

        let mut out = Vec::new();
        let done = c.apply(
            Event {
                state: Some(crate::local_agents::PollState {
                    activities: vec![activity],
                    text: String::new(),
                    done: true,
                    exit_code: Some(1),
                    session_id: None,
                    error: Some("boom".into()),
                    retryable: true,
                    resumed: false,
                    waiting_since: None,
                }),
                ..event("!", false)
            },
            &mut out,
        );
        assert!(done);
        let types: Vec<_> = out.iter().map(|e| e["type"].as_str().unwrap()).collect();
        assert_eq!(types, ["text_op", "error", "text_op"]);
        assert_eq!(out[2]["ops"][0]["type"], "finalize");
    }

    /// Fake Core: acknowledges part of the stream, drops the connection, then
    /// reports a cursor beyond the last ack (an ack lost in flight). Orb must
    /// resend exactly the remainder.
    #[test]
    fn reconnect_replays_exactly_what_core_lacks() {
        use tokio_tungstenite::accept_async;
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let dir = tempfile::tempdir().unwrap();
            let acc = Arc::new(Account {
                dir: dir.path().into(),
                token: Mutex::new("t".into()),
                client_id: "c".into(),
                journals: Mutex::new(HashMap::new()),
                wake: Notify::new(),
                accepted: Default::default(),
            });
            acc.append(
                "m",
                (0..5)
                    .map(|i| json!({"type":"event","mission_id":"m","i":i}))
                    .collect(),
            );
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let api = format!("http://{}", listener.local_addr().unwrap());

            async fn next(
                ws: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
            ) -> Value {
                loop {
                    if let Message::Text(t) = ws.next().await.unwrap().unwrap() {
                        return serde_json::from_str(&t).unwrap();
                    }
                }
            }
            let server = tokio::spawn(async move {
                let mut received = Vec::new();
                for (cursor, ack_through) in [(0u64, 2u64), (3, 5)] {
                    let (tcp, _) = listener.accept().await.unwrap();
                    let mut ws = accept_async(tcp).await.unwrap();
                    assert_eq!(next(&mut ws).await["type"], "hello");
                    ws.send(Message::Text(
                        json!({"type":"welcome","client_id":"c"}).to_string(),
                    ))
                    .await
                    .unwrap();
                    assert_eq!(next(&mut ws).await["type"], "cursor");
                    ws.send(Message::Text(
                        json!({"type":"cursor","mission_id":"m","last_seq":cursor}).to_string(),
                    ))
                    .await
                    .unwrap();
                    let mut seen = Vec::new();
                    while seen.last().copied().unwrap_or(cursor) < 5 {
                        let frame = next(&mut ws).await;
                        seen.push(frame["seq"].as_u64().unwrap());
                    }
                    ws.send(Message::Text(
                        json!({"type":"ack","mission_id":"m","seq":ack_through}).to_string(),
                    ))
                    .await
                    .unwrap();
                    received.push(seen);
                    // Let the ack land before dropping the connection.
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    ws.close(None).await.ok();
                }
                received
            });
            for _ in 0..2 {
                let _ = tokio::time::timeout(Duration::from_secs(5), session(&api, &acc)).await;
            }
            let received = server.await.unwrap();
            assert_eq!(received, vec![vec![1, 2, 3, 4, 5], vec![4, 5]]);
            assert!(acc.accepted.load(std::sync::atomic::Ordering::SeqCst));
            let journal = Journal::load(dir.path(), "m");
            assert_eq!(journal.acked, 5);
            assert!(journal.pending.is_empty());
        });
    }

    #[test]
    fn websocket_url_follows_the_api_scheme() {
        assert_eq!(
            ws_url("https://agent-backend.thomas.md"),
            "wss://agent-backend.thomas.md/api/control/client-link"
        );
        assert_eq!(
            ws_url("http://127.0.0.1:3000"),
            "ws://127.0.0.1:3000/api/control/client-link"
        );
    }
}
