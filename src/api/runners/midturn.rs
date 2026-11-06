use std::time::Duration;

use tokio::sync::broadcast;
use uuid::Uuid;

use crate::api::control::AgentEvent;

pub(crate) const MID_TURN_POLL: Duration = Duration::from_secs(5);

pub(crate) async fn drain_and_inject<F, Fut>(
    mission_id: Uuid,
    events_tx: &broadcast::Sender<AgentEvent>,
    inject: F,
) where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let store = match crate::api::ask::ask_store_for_midturn().await {
        Ok(store) => store,
        Err(error) => {
            tracing::warn!(mission_id = %mission_id, "Failed to open Ask store for mid-turn injection: {error}");
            return;
        }
    };
    drain_and_inject_from_store(store, mission_id, events_tx, inject).await;
}

#[cfg(test)]
async fn drain_and_inject_with_cell<F, Fut>(
    cell: &tokio::sync::OnceCell<std::sync::Arc<crate::api::ask::AskStore>>,
    working_dir: &std::path::Path,
    mission_id: Uuid,
    events_tx: &broadcast::Sender<AgentEvent>,
    inject: F,
) where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let store = crate::api::ask::ask_store_in_cell(cell, working_dir, None)
        .await
        .unwrap();
    drain_and_inject_from_store(store, mission_id, events_tx, inject).await;
}

// The injection closure is `async` and its `bool` MUST mean the note block was
// *actually accepted by the backend* — not merely queued for delivery. Backends
// whose delivery is deferred (e.g. Codex enqueues onto an inject channel that a
// driver task later turns into a `turn/start` RPC) must therefore await the real
// outcome before returning, so a failed RPC re-enqueues the notes here instead
// of silently dropping them after we already took them off the queue.
async fn drain_and_inject_from_store<F, Fut>(
    store: std::sync::Arc<crate::api::ask::AskStore>,
    mission_id: Uuid,
    events_tx: &broadcast::Sender<AgentEvent>,
    inject: F,
) where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let _delivery_guard = store.lock_operator_note_delivery(mission_id).await;
    let notes = match store.peek_unflushed_operator_notes(mission_id).await {
        Ok(notes) if !notes.is_empty() => notes,
        Ok(_) => return,
        Err(error) => {
            tracing::warn!(
                mission_id = %mission_id,
                "Failed to read operator notes for mid-turn injection: {error}"
            );
            return;
        }
    };

    let mut block = String::from("<operator-note>\n");
    for note in &notes {
        block.push_str(&note.body);
        block.push('\n');
    }
    block.push_str("</operator-note>");

    if inject(block.clone()).await {
        let note_ids: Vec<Uuid> = notes.iter().map(|note| note.id).collect();
        let flushed_at = chrono::Utc::now().to_rfc3339();
        if let Err(error) = store
            .mark_operator_notes_flushed(mission_id, &note_ids, &flushed_at)
            .await
        {
            tracing::error!(
                mission_id = %mission_id,
                "Failed to mark operator notes flushed after mid-turn injection: {error}"
            );
            return;
        }
        tracing::info!(
            mission_id = %mission_id,
            notes = notes.len(),
            "Injected operator notes mid-turn"
        );
        let _ = events_tx.send(AgentEvent::UserMessage {
            id: Uuid::new_v4(),
            content: block,
            queued: false,
            mission_id: Some(mission_id),
            source: None,
        });
        return;
    }

    tracing::warn!(
        mission_id = %mission_id,
        notes = notes.len(),
        "Mid-turn note injection failed; notes left pending for next delivery"
    );
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;
    use crate::api::ask::AskStore;

    async fn temp_store() -> Arc<AskStore> {
        let path = std::env::temp_dir().join(format!("midturn-{}.db", Uuid::new_v4()));
        Arc::new(AskStore::open(path).await.unwrap())
    }

    #[tokio::test]
    async fn drain_and_inject_emits_event_on_success_and_requeues_on_failure() {
        let mission_id = Uuid::new_v4();
        let store = temp_store().await;
        let (events_tx, mut events_rx) = broadcast::channel(8);
        store
            .enqueue_operator_note(mission_id, "first note", None)
            .await
            .unwrap();
        store
            .enqueue_operator_note(mission_id, "second note", None)
            .await
            .unwrap();

        let captured = Arc::new(Mutex::new(String::new()));
        let captured_for_inject = Arc::clone(&captured);
        drain_and_inject_from_store(Arc::clone(&store), mission_id, &events_tx, |block| {
            let captured_for_inject = Arc::clone(&captured_for_inject);
            async move {
                *captured_for_inject.lock().unwrap() = block.clone();
                true
            }
        })
        .await;

        let block = captured.lock().unwrap().clone();
        assert!(block.starts_with("<operator-note>"));
        assert!(block.contains("first note"));
        assert!(block.contains("second note"));
        assert!(matches!(
            events_rx.try_recv().unwrap(),
            AgentEvent::UserMessage { queued: false, .. }
        ));
        assert!(store
            .take_pending_operator_notes(mission_id)
            .await
            .unwrap()
            .is_empty());

        store
            .enqueue_operator_note(mission_id, "retry me", None)
            .await
            .unwrap();
        drain_and_inject_from_store(Arc::clone(&store), mission_id, &events_tx, |_| async {
            false
        })
        .await;

        let pending = store.take_pending_operator_notes(mission_id).await.unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].body, "retry me");
    }

    #[tokio::test]
    async fn pre_restart_operator_notes_drain_without_prior_ask_http_hit() {
        let working_dir = tempfile::tempdir().unwrap();
        let db_dir = working_dir.path().join(".sandboxed-sh/missions");
        tokio::fs::create_dir_all(&db_dir).await.unwrap();
        let db_path = db_dir.join("ask.db");
        let mission_id = Uuid::new_v4();

        {
            let before_restart = AskStore::open(db_path).await.unwrap();
            before_restart
                .enqueue_operator_note(mission_id, "note-one", None)
                .await
                .unwrap();
            before_restart
                .enqueue_operator_note(mission_id, "note-two", None)
                .await
                .unwrap();
        }

        let fresh_cell = tokio::sync::OnceCell::new();
        assert!(fresh_cell.get().is_none());
        let (events_tx, mut events_rx) = broadcast::channel(8);
        let delivered = Arc::new(Mutex::new(None));
        let delivered_clone = Arc::clone(&delivered);

        drain_and_inject_with_cell(
            &fresh_cell,
            working_dir.path(),
            mission_id,
            &events_tx,
            |block| {
                let delivered_clone = Arc::clone(&delivered_clone);
                async move {
                    *delivered_clone.lock().unwrap() = Some(block);
                    true
                }
            },
        )
        .await;

        assert_eq!(
            delivered.lock().unwrap().as_deref(),
            Some("<operator-note>\nnote-one\nnote-two\n</operator-note>")
        );
        assert!(events_rx.try_recv().is_ok());
        assert!(fresh_cell
            .get()
            .unwrap()
            .peek_unflushed_operator_notes(mission_id)
            .await
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn failed_midturn_rpc_preserves_note_uuids_and_timestamps_until_retry_succeeds() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("ask.db");
        let store = Arc::new(AskStore::open(db_path.clone()).await.unwrap());
        let mission_id = Uuid::new_v4();
        let id1 = Uuid::new_v4();
        let id2 = Uuid::new_v4();
        let ts1 = "2026-11-06T10:00:00Z";
        let ts2 = "2026-11-06T10:00:01Z";
        {
            let conn = rusqlite::Connection::open(&db_path).unwrap();
            for (id, body, ts) in [(id1, "first", ts1), (id2, "second", ts2)] {
                conn.execute(
                    "INSERT INTO operator_notes (id, mission_id, body, source_thread_id, created_at, flushed_at) \
                     VALUES (?1, ?2, ?3, NULL, ?4, NULL)",
                    rusqlite::params![id.to_string(), mission_id.to_string(), body, ts],
                )
                .unwrap();
            }
        }

        let (events_tx, mut events_rx) = broadcast::channel(8);
        drain_and_inject_from_store(Arc::clone(&store), mission_id, &events_tx, |_| async {
            false
        })
        .await;
        assert!(events_rx.try_recv().is_err());

        let pending = store
            .peek_unflushed_operator_notes(mission_id)
            .await
            .unwrap();
        assert_eq!(
            pending
                .iter()
                .map(|n| (n.id, n.body.as_str(), n.created_at.as_str()))
                .collect::<Vec<_>>(),
            vec![(id1, "first", ts1), (id2, "second", ts2)]
        );

        let delivered = Arc::new(Mutex::new(String::new()));
        let delivered_clone = Arc::clone(&delivered);
        drain_and_inject_from_store(Arc::clone(&store), mission_id, &events_tx, |block| {
            let delivered_clone = Arc::clone(&delivered_clone);
            async move {
                *delivered_clone.lock().unwrap() = block;
                true
            }
        })
        .await;
        assert_eq!(
            delivered.lock().unwrap().as_str(),
            "<operator-note>\nfirst\nsecond\n</operator-note>"
        );
        assert!(events_rx.try_recv().is_ok());

        let conn = rusqlite::Connection::open(&db_path).unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT id, created_at, flushed_at FROM operator_notes \
                 WHERE mission_id = ?1 ORDER BY created_at ASC",
            )
            .unwrap();
        let rows: Vec<(String, String, Option<String>)> = stmt
            .query_map([mission_id.to_string()], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].0, id1.to_string());
        assert_eq!(rows[0].1, ts1);
        assert!(rows[0].2.is_some());
        assert_eq!(rows[1].0, id2.to_string());
        assert_eq!(rows[1].1, ts2);
        assert!(rows[1].2.is_some());

        let third_called = Arc::new(Mutex::new(false));
        let third_called_clone = Arc::clone(&third_called);
        drain_and_inject_from_store(Arc::clone(&store), mission_id, &events_tx, |_| {
            let third_called_clone = Arc::clone(&third_called_clone);
            async move {
                *third_called_clone.lock().unwrap() = true;
                true
            }
        })
        .await;
        assert!(!*third_called.lock().unwrap());
    }

    #[tokio::test]
    async fn concurrent_midturn_inject_and_turn_prep_take_never_double_deliver() {
        let store = temp_store().await;
        let mission_id = Uuid::new_v4();
        store
            .enqueue_operator_note(mission_id, "initial-note", None)
            .await
            .unwrap();

        let (events_tx, mut events_rx) = broadcast::channel(8);
        let (inject_entered_tx, inject_entered_rx) = tokio::sync::oneshot::channel::<()>();
        let (allow_finish_tx, allow_finish_rx) = tokio::sync::oneshot::channel::<bool>();

        let store_for_midturn = Arc::clone(&store);
        let events_for_midturn = events_tx.clone();
        let midturn_delivered = Arc::new(Mutex::new(Vec::<String>::new()));
        let midturn_delivered_clone = Arc::clone(&midturn_delivered);
        let midturn_task = tokio::spawn(async move {
            drain_and_inject_from_store(
                store_for_midturn,
                mission_id,
                &events_for_midturn,
                |block| async move {
                    let _ = inject_entered_tx.send(());
                    let ok = allow_finish_rx.await.unwrap();
                    if ok {
                        midturn_delivered_clone.lock().unwrap().push(block);
                    }
                    ok
                },
            )
            .await;
        });

        inject_entered_rx.await.unwrap();

        let take = store.take_pending_operator_notes(mission_id);
        tokio::pin!(take);
        assert!(futures::poll!(&mut take).is_pending());

        store
            .enqueue_operator_note(mission_id, "late-note", None)
            .await
            .unwrap();

        allow_finish_tx.send(true).unwrap();
        midturn_task.await.unwrap();
        let taken = take.await.unwrap();

        let midturn_blocks = midturn_delivered.lock().unwrap().clone();
        assert_eq!(
            midturn_blocks,
            vec!["<operator-note>\ninitial-note\n</operator-note>".to_string()]
        );
        assert!(events_rx.try_recv().is_ok());
        assert_eq!(
            taken.iter().map(|n| n.body.as_str()).collect::<Vec<_>>(),
            vec!["late-note"]
        );
        assert!(store
            .take_pending_operator_notes(mission_id)
            .await
            .unwrap()
            .is_empty());

        store
            .enqueue_operator_note(mission_id, "preserved-on-fail", None)
            .await
            .unwrap();
        let (entered2_tx, entered2_rx) = tokio::sync::oneshot::channel::<()>();
        let (finish2_tx, finish2_rx) = tokio::sync::oneshot::channel::<bool>();
        let store_for_fail = Arc::clone(&store);
        let events_for_fail = events_tx.clone();
        let fail_task = tokio::spawn(async move {
            drain_and_inject_from_store(
                store_for_fail,
                mission_id,
                &events_for_fail,
                |_| async move {
                    let _ = entered2_tx.send(());
                    finish2_rx.await.unwrap()
                },
            )
            .await;
        });

        entered2_rx.await.unwrap();
        let take2 = store.take_pending_operator_notes(mission_id);
        tokio::pin!(take2);
        assert!(futures::poll!(&mut take2).is_pending());

        finish2_tx.send(false).unwrap();
        fail_task.await.unwrap();
        assert!(events_rx.try_recv().is_err());

        let taken_after_fail = take2.await.unwrap();
        assert_eq!(
            taken_after_fail
                .iter()
                .map(|n| n.body.as_str())
                .collect::<Vec<_>>(),
            vec!["preserved-on-fail"]
        );
        assert!(store
            .take_pending_operator_notes(mission_id)
            .await
            .unwrap()
            .is_empty());
        assert_eq!(store.delivery_locks_len(), 0);
    }

    #[tokio::test]
    async fn delivery_locks_evict_to_zero_after_concurrent_drain_and_take_across_missions() {
        let store = temp_store().await;
        let (events_tx, _events_rx) = broadcast::channel(64);
        let mut handles = Vec::new();
        for i in 0..16 {
            let mission_id = Uuid::new_v4();
            store
                .enqueue_operator_note(mission_id, &format!("note-{i}-a"), None)
                .await
                .unwrap();
            store
                .enqueue_operator_note(mission_id, &format!("note-{i}-b"), None)
                .await
                .unwrap();

            let s1 = Arc::clone(&store);
            let tx1 = events_tx.clone();
            handles.push(tokio::spawn(async move {
                drain_and_inject_from_store(s1, mission_id, &tx1, |_| async move {
                    tokio::task::yield_now().await;
                    i % 2 == 0
                })
                .await;
            }));

            let s2 = Arc::clone(&store);
            handles.push(tokio::spawn(async move {
                let _ = s2.take_pending_operator_notes(mission_id).await.unwrap();
            }));
        }

        for h in handles {
            h.await.unwrap();
        }

        assert_eq!(store.delivery_locks_len(), 0);
    }
}
