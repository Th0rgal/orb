//! Reverse relay for dial-out nodes.
//!
//! Managed nodes have no inbound path. Core's ordinary node client talks to
//! `http://127.0.0.1:<core>/api/managed-machines/relay/tunnel/<id>/<path>`;
//! the tunnel handler queues the request here and waits. The node long-polls
//! `/relay/poll`, replays each request against its own loopback listener and
//! posts the answer to `/relay/respond`. The node API is unchanged.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tokio::sync::{oneshot, Mutex, Notify};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelayRequest {
    pub id: String,
    pub method: String,
    /// Path and query, relative to the node root (e.g. `/jobs/<id>?x=1`).
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body_b64: String,
    /// Seconds the caller is willing to wait for the answer.
    pub timeout_secs: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelayResponse {
    pub id: String,
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body_b64: String,
}

#[derive(Default)]
struct Channel {
    queue: Mutex<VecDeque<RelayRequest>>,
    notify: Notify,
    waiters: Mutex<HashMap<String, oneshot::Sender<RelayResponse>>>,
    last_poll: Mutex<Option<Instant>>,
    closed: std::sync::atomic::AtomicBool,
}

#[derive(Default)]
pub struct RelayHub {
    channels: Mutex<HashMap<String, Arc<Channel>>>,
}

pub enum RelayError {
    NodeNotConnected,
    Timeout,
    Closed,
}

impl RelayHub {
    async fn channel(&self, machine_id: &str) -> Arc<Channel> {
        let mut map = self.channels.lock().await;
        Arc::clone(map.entry(machine_id.to_string()).or_default())
    }

    /// Whether the node polled within the last `within`.
    pub async fn connected(&self, machine_id: &str, within: Duration) -> bool {
        let ch = self.channel(machine_id).await;
        let last = *ch.last_poll.lock().await;
        last.is_some_and(|t| t.elapsed() < within)
    }

    /// Queue a request for the node and wait for its answer.
    pub async fn call(
        &self,
        machine_id: &str,
        mut request: RelayRequest,
        timeout: Duration,
    ) -> Result<RelayResponse, RelayError> {
        let ch = self.channel(machine_id).await;
        if ch.closed.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(RelayError::Closed);
        }
        // A node that has not polled for a while is treated as unreachable,
        // like a refused TCP connect: the request was never delivered.
        let last = *ch.last_poll.lock().await;
        if last.is_none_or(|t| t.elapsed() >= Duration::from_secs(90)) {
            return Err(RelayError::NodeNotConnected);
        }
        request.timeout_secs = timeout.as_secs();
        let (tx, rx) = oneshot::channel();
        ch.waiters.lock().await.insert(request.id.clone(), tx);
        let id = request.id.clone();
        ch.queue.lock().await.push_back(request);
        ch.notify.notify_waiters();
        ch.notify.notify_one();
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(resp)) => Ok(resp),
            Ok(Err(_)) => Err(RelayError::Closed),
            Err(_) => {
                ch.waiters.lock().await.remove(&id);
                Err(RelayError::Timeout)
            }
        }
    }

    /// Long-poll from the node: up to `max` queued requests, waiting at most
    /// `wait` for the first one.
    pub async fn poll(&self, machine_id: &str, wait: Duration, max: usize) -> Vec<RelayRequest> {
        let ch = self.channel(machine_id).await;
        *ch.last_poll.lock().await = Some(Instant::now());
        let deadline = tokio::time::Instant::now() + wait;
        loop {
            {
                let mut q = ch.queue.lock().await;
                if !q.is_empty() {
                    let n = q.len().min(max);
                    return q.drain(..n).collect();
                }
            }
            if ch.closed.load(std::sync::atomic::Ordering::SeqCst) {
                return Vec::new();
            }
            let notified = ch.notify.notified();
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                *ch.last_poll.lock().await = Some(Instant::now());
                return Vec::new();
            }
        }
    }

    pub async fn respond(&self, machine_id: &str, response: RelayResponse) -> bool {
        let ch = self.channel(machine_id).await;
        *ch.last_poll.lock().await = Some(Instant::now());
        let tx = ch.waiters.lock().await.remove(&response.id);
        match tx {
            Some(tx) => tx.send(response).is_ok(),
            None => false,
        }
    }

    pub async fn is_closed(&self, machine_id: &str) -> bool {
        self.channel(machine_id)
            .await
            .closed
            .load(std::sync::atomic::Ordering::SeqCst)
    }

    pub async fn close(&self, machine_id: &str) {
        let ch = self.channel(machine_id).await;
        ch.closed.store(true, std::sync::atomic::Ordering::SeqCst);
        ch.waiters.lock().await.clear();
        ch.queue.lock().await.clear();
        ch.notify.notify_waiters();
    }
}
