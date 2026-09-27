//! Pending native requests belong to the process, not the webview. Reloading
//! the UI can recover them; an answer can only be consumed once.
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{mpsc, Mutex, OnceLock};
use tauri::ipc::Channel;

#[derive(Clone, Serialize)]
pub struct Request {
    pub id: String,
    pub method: String,
    pub params: Value,
}
#[derive(Clone)]
pub struct Session {
    pub mission: String,
    generation: u64,
}
#[derive(Default)]
struct Store {
    sessions: HashMap<String, u64>,
    pending: HashMap<String, Pending>,
    subscribers: HashMap<String, HashMap<u64, Channel<Option<Request>>>>,
}
struct Pending {
    request: Request,
    reply: mpsc::Sender<Value>,
}
fn pending() -> &'static Mutex<Store> {
    static STORE: OnceLock<Mutex<Store>> = OnceLock::new();
    STORE.get_or_init(Default::default)
}
// Snapshot registration and publication share the store lock: a subscriber
// cannot miss a transition between its initial read and event registration.
impl Store {
    fn publish(&mut self, id: &str) {
        let request = self.pending.get(id).map(|p| p.request.clone());
        if let Some(subscribers) = self.subscribers.get_mut(id) {
            subscribers.retain(|_, channel| channel.send(request.clone()).is_ok());
            if subscribers.is_empty() {
                self.subscribers.remove(id);
            }
        }
    }
}
#[tauri::command]
pub fn local_interaction_subscribe(
    id: String,
    on_event: Channel<Option<Request>>,
) -> Result<u64, String> {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let token = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut store = pending().lock().map_err(|e| e.to_string())?;
    on_event
        .send(store.pending.get(&id).map(|p| p.request.clone()))
        .map_err(|e| e.to_string())?;
    store
        .subscribers
        .entry(id)
        .or_default()
        .insert(token, on_event);
    Ok(token)
}
#[tauri::command]
pub fn local_interaction_unsubscribe(id: String, token: u64) -> Result<(), String> {
    let mut store = pending().lock().map_err(|e| e.to_string())?;
    if let Some(subscribers) = store.subscribers.get_mut(&id) {
        subscribers.remove(&token);
        if subscribers.is_empty() {
            store.subscribers.remove(&id);
        }
    }
    Ok(())
}
#[tauri::command]
pub fn local_interaction(id: String) -> Result<Option<Request>, String> {
    Ok(pending()
        .lock()
        .map_err(|e| e.to_string())?
        .pending
        .get(&id)
        .map(|p| p.request.clone()))
}
#[tauri::command]
pub fn local_interaction_answer(
    id: String,
    request_id: String,
    answer: Value,
) -> Result<(), String> {
    let mut map = pending().lock().map_err(|e| e.to_string())?;
    let p = map
        .pending
        .get(&id)
        .ok_or("This request has expired. Resume the session to continue.")?;
    if p.request.id != request_id {
        return Err("This request has been replaced.".into());
    }
    if matches!(p.request.method.as_str(), "plan" | "permission") {
        match answer["action"].as_str() {
            Some("accept") => {}
            Some("revise")
                if p.request.method == "permission"
                    || answer["feedback"]
                        .as_str()
                        .is_some_and(|s| !s.trim().is_empty()) => {}
            _ => return Err("Choose an action and include your requested changes.".into()),
        }
    }
    p.reply
        .send(answer)
        .map_err(|_| "The session is no longer waiting.".to_string())?;
    map.pending.remove(&id);
    map.publish(&id);
    Ok(())
}
pub fn cancel(id: &str) {
    if let Ok(mut p) = pending().lock() {
        p.sessions.remove(id);
        if p.pending.remove(id).is_some() {
            p.publish(id);
        }
    }
}
pub fn begin(id: &str) -> Session {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let session = Session {
        mission: id.into(),
        generation: NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
    };
    let mut store = pending().lock().unwrap();
    if store.pending.remove(id).is_some() {
        store.publish(id);
    }
    store.sessions.insert(id.into(), session.generation);
    session
}
pub fn session(id: &str) -> Session {
    Session {
        mission: id.into(),
        generation: *pending()
            .lock()
            .unwrap()
            .sessions
            .get(id)
            .expect("run registered before spawn"),
    }
}
pub fn finish(session: &Session) {
    let mut store = pending().lock().unwrap();
    if store.sessions.get(&session.mission) == Some(&session.generation) {
        store.sessions.remove(&session.mission);
        if store.pending.remove(&session.mission).is_some() {
            store.publish(&session.mission);
        }
    }
}
pub fn ask(session: &Session, method: &str, params: Value) -> Result<Value, String> {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let (tx, rx) = mpsc::channel();
    let request = Request {
        id: format!(
            "{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ),
        method: method.into(),
        params,
    };
    {
        let mut store = pending().lock().map_err(|e| e.to_string())?;
        if store.sessions.get(&session.mission) != Some(&session.generation) {
            return Err("The request was cancelled.".into());
        }
        store
            .pending
            .insert(session.mission.clone(), Pending { request, reply: tx });
        store.publish(&session.mission);
    }
    rx.recv().map_err(|_| "The request was cancelled.".into())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn subscriber(id: &str) -> (u64, mpsc::Receiver<Value>) {
        let (tx, rx) = mpsc::channel();
        let channel = Channel::new(move |body| {
            if let tauri::ipc::InvokeResponseBody::Json(json) = body {
                tx.send(serde_json::from_str(&json).unwrap()).unwrap();
            }
            Ok(())
        });
        (local_interaction_subscribe(id.into(), channel).unwrap(), rx)
    }
    #[test]
    fn subscription_recovers_snapshot_publishes_transitions_and_unsubscribes() {
        let id = "subscription-test";
        let session = begin(id);
        let (token, events) = subscriber(id);
        assert_eq!(events.recv().unwrap(), Value::Null);
        let worker = std::thread::spawn(move || ask(&session, "questions", Value::Null));
        let request = events
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
        assert_eq!(request["method"], "questions");
        let (second, recovered) = subscriber(id);
        assert_eq!(recovered.recv().unwrap(), request);
        local_interaction_unsubscribe(id.into(), second).unwrap();
        local_interaction_answer(
            id.into(),
            request["id"].as_str().unwrap().into(),
            Value::Bool(true),
        )
        .unwrap();
        assert_eq!(worker.join().unwrap().unwrap(), Value::Bool(true));
        assert_eq!(events.recv().unwrap(), Value::Null);
        assert!(recovered.try_recv().is_err());
        local_interaction_unsubscribe(id.into(), token).unwrap();
        assert!(!pending().lock().unwrap().subscribers.contains_key(id));
        cancel(id);
    }
    #[test]
    fn subscription_observes_cancellation_and_replacement() {
        let id = "subscription-cancel-test";
        let session = begin(id);
        let (token, events) = subscriber(id);
        events.recv().unwrap();
        let old = session.clone();
        let worker = std::thread::spawn(move || ask(&session, "plan", Value::Null));
        events
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
        let next = begin(id);
        assert_eq!(events.recv().unwrap(), Value::Null);
        assert!(worker.join().unwrap().is_err());
        finish(&old);
        assert!(events.try_recv().is_err());
        let worker = std::thread::spawn(move || ask(&next, "plan", Value::Null));
        events
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
        cancel(id);
        assert_eq!(events.recv().unwrap(), Value::Null);
        assert!(worker.join().unwrap().is_err());
        local_interaction_unsubscribe(id.into(), token).unwrap();
    }
    #[test]
    fn answer_is_bound_and_consumed_once() {
        let (tx, rx) = mpsc::channel();
        pending().lock().unwrap().pending.insert(
            "test".into(),
            Pending {
                request: Request {
                    id: "r".into(),
                    method: "question".into(),
                    params: Value::Null,
                },
                reply: tx,
            },
        );
        assert!(local_interaction_answer("test".into(), "old".into(), Value::Null).is_err());
        local_interaction_answer("test".into(), "r".into(), Value::Bool(true)).unwrap();
        assert_eq!(rx.recv().unwrap(), Value::Bool(true));
        assert!(local_interaction_answer("test".into(), "r".into(), Value::Null).is_err());
    }
    #[test]
    fn stopping_a_run_prevents_late_requests_and_old_cleanup_cannot_cancel_new_run() {
        let old = begin("generation-test");
        cancel("generation-test");
        assert!(ask(&old, "plan", Value::Null).is_err());
        let current = begin("generation-test");
        finish(&old);
        assert_eq!(
            pending().lock().unwrap().sessions.get("generation-test"),
            Some(&current.generation)
        );
        finish(&current);
    }
    #[test]
    fn cancellation_unblocks_a_waiting_request() {
        let session = begin("cancel-test");
        let worker = std::thread::spawn(move || ask(&session, "plan", Value::Null));
        let end = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while local_interaction("cancel-test".into()).unwrap().is_none() {
            assert!(std::time::Instant::now() < end);
            std::thread::yield_now();
        }
        cancel("cancel-test");
        assert!(worker.join().unwrap().is_err());
        assert!(local_interaction("cancel-test".into()).unwrap().is_none());
    }
}

pub fn clear_subscriptions() {
    if let Ok(mut store) = pending().lock() {
        store.subscribers.clear();
    }
}
