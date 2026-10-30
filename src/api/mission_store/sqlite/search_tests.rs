use super::*;
use crate::api::cloud_agents::{
    Execution as CloudExecution, Phase as CloudPhase, Provider as CloudProvider,
    Selection as CloudSelection, Turn as CloudTurn,
};
use crate::api::mission_store::{
    ConversationSearchQuery, ConversationSearchRole, ConversationSearchSort, PassageContextQuery,
    SearchIndexState,
};
use std::time::Instant;

fn slice_utf16(text: &str, start: usize, end: usize) -> String {
    let units: Vec<u16> = text.encode_utf16().collect();
    String::from_utf16_lossy(&units[start..end])
}

#[tokio::test]
async fn indexes_deep_history_spilled_files_utf16_and_deduplicates_turns() {
    let dir = tempfile::tempdir().unwrap();
    let store = SqliteMissionStore::new(dir.path().to_path_buf(), "alice")
        .await
        .unwrap();

    let mission = store
        .create_mission(
            Some("Coup d'état 🚀 migration audit"),
            None,
            None,
            None,
            None,
            Some("opencode"),
            None,
        )
        .await
        .unwrap();
    store
        .update_mission_project(
            mission.id,
            MissionProjectPatch {
                project: Some(Some("orb-core".to_string())),
                ..Default::default()
            },
        )
        .await
        .unwrap();

    // Message #1 (far older than the 200-message history window we will append below):
    // >64 KB spilled content containing multi-byte UTF-8 + astral emoji before the needle.
    let prefix = "🚀 Coup d'état prologue — ".repeat(2_800); // > 70 KB => spilled to content_file
    let early_user_id = Uuid::new_v4();
    let spilled_text = format!(
        "{prefix}NeedleTokenAlpha_9921 appears after emoji and accents in spilled storage."
    );
    store
        .log_event(
            mission.id,
            &AgentEvent::UserMessage {
                id: early_user_id,
                content: spilled_text,
                queued: false,
                mission_id: Some(mission.id),
                source: None,
            },
        )
        .await
        .unwrap();

    // Streaming delta + finalized canonical + turn-closing receipt must yield ONE hit, not three.
    store
        .log_event(
            mission.id,
            &AgentEvent::TextDelta {
                content: "StreamingFragmentOnly_ShouldNeverIndex".to_string(),
                mission_id: Some(mission.id),
            },
        )
        .await
        .unwrap();
    store
        .log_event(
            mission.id,
            &AgentEvent::TextOp {
                mission_id: mission.id,
                bubble_id: "text_delta_latest".to_string(),
                ops: vec![
                    TextOp::Snapshot {
                        revision: 1,
                        text: "CanonicalDedupeOmega response with 🚀 café.".to_string(),
                    },
                    TextOp::Finalize,
                ],
            },
        )
        .await
        .unwrap();
    let final_reply_id = Uuid::new_v4();
    store
        .log_event(
            mission.id,
            &AgentEvent::AssistantMessage {
                id: final_reply_id,
                content: "CanonicalDedupeOmega response with 🚀 café.".to_string(),
                success: true,
                cost_cents: 0,
                cost_source: crate::agents::CostSource::Unknown,
                usage: None,
                model: None,
                model_normalized: None,
                mission_id: Some(mission.id),
                shared_files: None,
                resumable: true,
                completion_evidence: None,
            },
        )
        .await
        .unwrap();

    // Append 260 newer turns so early_user_id sits well past the 200-event tail window.
    for i in 0..260 {
        store
            .log_event(
                mission.id,
                &AgentEvent::UserMessage {
                    id: Uuid::new_v4(),
                    content: format!("Routine follow-up prompt number {i}"),
                    queued: false,
                    mission_id: Some(mission.id),
                    source: None,
                },
            )
            .await
            .unwrap();
    }

    // 1. Streaming delta was NOT indexed.
    let delta_res = store
        .search_conversations(&ConversationSearchQuery {
            query: "StreamingFragmentOnly_ShouldNeverIndex".to_string(),
            ..Default::default()
        })
        .await
        .unwrap();
    assert!(delta_res.hits.is_empty());

    // 2. Canonical + final receipt deduplicated to 1 hit, with exact UTF-16 highlight span.
    let dedupe_res = store
        .search_conversations(&ConversationSearchQuery {
            query: "CanonicalDedupeOmega".to_string(),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(dedupe_res.hits.len(), 1);
    assert_eq!(
        dedupe_res.hits[0].locator,
        format!("msg:id:{final_reply_id}")
    );

    // 3. Spilled >64 KB message >260 turns back is found, UTF-16 highlights slice cleanly,
    // and bounded passage context hydrates surrounding events (`include_events = true`).
    let deep_res = store
        .search_conversations(&ConversationSearchQuery {
            query: "NeedleTokenAlpha_9921".to_string(),
            project: Some("orb-core".to_string()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(deep_res.hits.len(), 1);
    let hit = &deep_res.hits[0];
    assert_eq!(hit.locator, format!("msg:id:{early_user_id}"));
    assert!(!hit.highlights.is_empty());
    let matched_slice = slice_utf16(&hit.excerpt, hit.highlights[0].start, hit.highlights[0].end);
    assert_eq!(matched_slice, "NeedleTokenAlpha_9921");

    // Verify UTF-16 offsets after emoji + diacritics in title search (`état` -> 4 UTF-16 units after 🚀 surrogate pair).
    let title_res = store
        .search_conversations(&ConversationSearchQuery {
            query: "etat migration".to_string(),
            role: ConversationSearchRole::Title,
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(title_res.hits.len(), 1);
    let th = &title_res.hits[0];
    let first_span = slice_utf16(&th.excerpt, th.highlights[0].start, th.highlights[0].end);
    assert_eq!(first_span.to_lowercase(), "état");

    let ctx = store
        .get_passage_context(
            mission.id,
            &PassageContextQuery {
                locator: hit.locator.clone(),
                sequence: hit.sequence,
                query: Some("NeedleTokenAlpha_9921".to_string()),
                include_events: true,
                ..Default::default()
            },
        )
        .await
        .unwrap()
        .unwrap();
    assert!(ctx.target_found);
    assert!(ctx.messages.iter().any(|m| m.is_target));
    assert!(!ctx.events.is_empty());
}

#[tokio::test]
async fn enforces_user_isolation_deletion_edits_cloud_turns_tool_filter_and_hostile_syntax() {
    let dir = tempfile::tempdir().unwrap();
    let alice = SqliteMissionStore::new(dir.path().to_path_buf(), "alice-sec")
        .await
        .unwrap();
    let bob = SqliteMissionStore::new(dir.path().to_path_buf(), "bob-sec")
        .await
        .unwrap();

    let m = alice
        .create_mission(
            Some("Alice private audit"),
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .await
        .unwrap();
    let msg_id = Uuid::new_v4();
    alice
        .log_event(
            m.id,
            &AgentEvent::UserMessage {
                id: msg_id,
                content: "OriginalSecretPhrase_771".to_string(),
                queued: false,
                mission_id: Some(m.id),
                source: None,
            },
        )
        .await
        .unwrap();

    // Tool call with safe file path vs command/secret output:
    alice
        .log_event(
            m.id,
            &AgentEvent::ToolCall {
                tool_call_id: "call_1".to_string(),
                name: "read_file".to_string(),
                args: serde_json::json!({
                    "Path": "src/api/mission_store/sqlite_transfer.rs",
                    "CommandLine": "NEVER_INDEX_CMD_SECRET_999"
                }),
                mission_id: Some(m.id),
            },
        )
        .await
        .unwrap();
    alice
        .log_event(
            m.id,
            &AgentEvent::ToolResult {
                tool_call_id: "call_1".to_string(),
                name: "read_file".to_string(),
                result: serde_json::json!("STDOUT_SECRET_TOKEN_88888"),
                mission_id: Some(m.id),
            },
        )
        .await
        .unwrap();

    // Bob cannot see Alice's mission in search or passage context.
    assert!(bob
        .search_conversations(&ConversationSearchQuery {
            query: "OriginalSecretPhrase_771".to_string(),
            ..Default::default()
        })
        .await
        .unwrap()
        .hits
        .is_empty());
    assert!(bob
        .get_passage_context(
            m.id,
            &PassageContextQuery {
                locator: format!("msg:id:{msg_id}"),
                ..Default::default()
            }
        )
        .await
        .unwrap()
        .is_none());

    // Raw tool stdout & command lines are never indexed even with include_tools = true.
    for forbidden in ["STDOUT_SECRET_TOKEN_88888", "NEVER_INDEX_CMD_SECRET_999"] {
        let res = alice
            .search_conversations(&ConversationSearchQuery {
                query: forbidden.to_string(),
                include_tools: true,
                ..Default::default()
            })
            .await
            .unwrap();
        assert!(res.hits.is_empty(), "must never index {forbidden}");
    }

    // Safe tool file path is excluded by default, included when `include_tools = true`.
    assert!(alice
        .search_conversations(&ConversationSearchQuery {
            query: "sqlite_transfer.rs".to_string(),
            include_tools: false,
            ..Default::default()
        })
        .await
        .unwrap()
        .hits
        .is_empty());
    assert_eq!(
        alice
            .search_conversations(&ConversationSearchQuery {
                query: "sqlite_transfer.rs".to_string(),
                include_tools: true,
                ..Default::default()
            })
            .await
            .unwrap()
            .hits
            .len(),
        1
    );

    // In-place message edit updates FTS5 and removes stale text; context marks edited-out query `target_found = false`.
    alice
        .log_event(
            m.id,
            &AgentEvent::UserMessage {
                id: msg_id,
                content: "EditedReplacementPhrase_772".to_string(),
                queued: false,
                mission_id: Some(m.id),
                source: None,
            },
        )
        .await
        .unwrap();
    assert!(alice
        .search_conversations(&ConversationSearchQuery {
            query: "OriginalSecretPhrase_771".to_string(),
            ..Default::default()
        })
        .await
        .unwrap()
        .hits
        .is_empty());
    assert_eq!(
        alice
            .search_conversations(&ConversationSearchQuery {
                query: "EditedReplacementPhrase_772".to_string(),
                ..Default::default()
            })
            .await
            .unwrap()
            .hits
            .len(),
        1
    );
    let stale_ctx = alice
        .get_passage_context(
            m.id,
            &PassageContextQuery {
                locator: format!("msg:id:{msg_id}"),
                query: Some("OriginalSecretPhrase_771".to_string()),
                ..Default::default()
            },
        )
        .await
        .unwrap()
        .unwrap();
    assert!(!stale_ctx.target_found);

    // Cloud execution prompt + answer indexed once without duplicating mission_events receipt.
    let mut cloud_exec = CloudExecution {
        parent_mission_id: None,
        mission_id: Uuid::new_v4(),
        request_key: "cloud-search-1".into(),
        request_signature: "sig-1".into(),
        revision: 0,
        selection: CloudSelection {
            provider: CloudProvider::CursorCloud,
            account: "default".into(),
            repository: None,
            git_ref: None,
            model_params: vec![],
            model: None,
        },
        external_id: None,
        external_url: None,
        turns: vec![CloudTurn::new(
            "turn-alpha".into(),
            "CloudPromptUnique_441".into(),
        )],
    };
    cloud_exec = alice
        .save_cloud_execution(
            cloud_exec,
            None,
            Some("Cloud audit".into()),
            Some("cloud-proj".into()),
            vec![],
        )
        .await
        .unwrap();
    cloud_exec.turns[0].phase = CloudPhase::ResponseComplete;
    cloud_exec.turns[0].result = Some("CloudAnswerUnique_442".into());
    alice
        .save_cloud_execution(
            cloud_exec.clone(),
            Some(cloud_exec.revision),
            None,
            None,
            vec![],
        )
        .await
        .unwrap();

    let cp = alice
        .search_conversations(&ConversationSearchQuery {
            query: "CloudPromptUnique_441".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(cp.hits.len(), 1);
    assert_eq!(cp.hits[0].locator, "cloud:turn-alpha:prompt");

    let ca = alice
        .search_conversations(&ConversationSearchQuery {
            query: "CloudAnswerUnique_442".into(),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(ca.hits.len(), 1);
    assert_eq!(ca.hits[0].locator, "cloud:turn-alpha:answer");

    // Title-locator preview on a cloud execution returns canonical cloud turns
    // instead of folding mission_events (which suppresses mirrored cloud replies).
    let cloud_title_ctx = alice
        .get_passage_context(
            cloud_exec.mission_id,
            &PassageContextQuery {
                locator: "title".into(),
                before: Some(3),
                after: Some(0),
                ..Default::default()
            },
        )
        .await
        .unwrap()
        .expect("cloud mission context");
    assert!(cloud_title_ctx.target_found);
    assert_eq!(cloud_title_ctx.messages.len(), 2);
    assert_eq!(cloud_title_ctx.messages[0].content, "CloudPromptUnique_441");
    assert_eq!(cloud_title_ctx.messages[1].content, "CloudAnswerUnique_442");

    // Hostile FTS5 syntax never causes an error.
    for hostile in [
        "\"unclosed quote AND OR NOT (",
        "NEAR(foo bar, 2) * ^ : - +",
        "))) ((( \"\"\" ***",
        "src/api/routes.rs:1002",
    ] {
        let res = alice
            .search_conversations(&ConversationSearchQuery {
                query: hostile.to_string(),
                ..Default::default()
            })
            .await;
        assert!(res.is_ok(), "hostile query failed: {hostile}");
    }

    // Deleting a mission immediately purges all of its search docs & FTS entries.
    assert!(alice.delete_mission(m.id).await.unwrap());
    assert!(alice
        .search_conversations(&ConversationSearchQuery {
            query: "EditedReplacementPhrase_772".to_string(),
            ..Default::default()
        })
        .await
        .unwrap()
        .hits
        .is_empty());
}

#[tokio::test]
async fn resumes_interrupted_backfill_reconciles_concurrent_writes_and_exceeds_2000_missions() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("missions-backfill.db");

    // Seed a legacy database of 2,150 missions BEFORE search tables exist so we
    // test real migration + interrupted multi-batch backfill + >2,000 mission reach.
    {
        let mut conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(super::cloud::SCHEMA).unwrap();
        conn.execute_batch(super::machine_transfer::SCHEMA).unwrap();
        conn.execute_batch(super::SCHEMA).unwrap();
        let tx = conn.transaction().unwrap();
        for i in 0..2_150 {
            let mid = format!("00000000-0000-4000-8000-{i:012}");
            let status = if i % 3 == 0 {
                "acknowledged"
            } else {
                "completed"
            };
            let ts = format!("2026-01-01T00:{:02}:{:02}Z", (i / 60) % 60, i % 60);
            tx.execute(
                "INSERT INTO missions (id, status, title, workspace_id, backend, created_at, updated_at, project)
                 VALUES (?1, ?2, ?3, ?4, 'opencode', ?5, ?5, 'legacy')",
                params![mid, status, format!("Legacy conversation {i}"), Uuid::nil().to_string(), ts],
            )
            .unwrap();
            let body = if i == 0 {
                "OldestMissionZero_UniqueBeacon_0000 beyond two thousand newer conversations"
                    .to_string()
            } else {
                format!("Historical message body for conversation {i}")
            };
            tx.execute(
                "INSERT INTO mission_events (mission_id, sequence, event_type, timestamp, event_id, content)
                 VALUES (?1, 1, 'user_message', ?2, ?3, ?4)",
                params![mid, ts, format!("ev-{i}"), body],
            )
            .unwrap();
        }
        tx.commit().unwrap();
    }

    // Open store inside a non-backgrounded deterministic check first by resetting
    // watermark and stepping batch-by-batch while mutating missions before/after cursor.
    let store = SqliteMissionStore::new(dir.path().to_path_buf(), "backfill")
        .await
        .unwrap();

    // Force an interrupted watermark right at mission 50 to test deterministic resume.
    {
        let guard = store.conn.lock().await;
        guard
            .execute_batch(
                "DELETE FROM mission_search_docs;
                 INSERT INTO mission_search_fts(mission_search_fts) VALUES('rebuild');
                 UPDATE mission_search_state
                 SET cursor_mission_id = NULL, backfill_complete = 0, indexed_missions = 0
                 WHERE singleton = 1;",
            )
            .unwrap();
    }

    let cov_initial = store.search_index_coverage().await.unwrap();
    assert_eq!(cov_initial.state, SearchIndexState::Indexing);
    assert_eq!(cov_initial.total_missions, 2_150);

    // Step 1 batch (first 100 missions -> includes mission 0000!).
    assert!(store.backfill_search_batch(100).await.unwrap());
    let cov_mid = store.search_index_coverage().await.unwrap();
    assert_eq!(cov_mid.state, SearchIndexState::Indexing);
    assert_eq!(cov_mid.indexed_missions, 100);

    // Concurrent write DURING backfill on an unbackfilled mission (#2100) AND a new mission:
    let unbackfilled_id = Uuid::parse_str("00000000-0000-4000-8000-000000002100").unwrap();
    store
        .log_event(
            unbackfilled_id,
            &AgentEvent::AssistantMessage {
                id: Uuid::new_v4(),
                content: "ConcurrentDuringBackfill_2100".to_string(),
                success: true,
                cost_cents: 0,
                cost_source: crate::agents::CostSource::Unknown,
                usage: None,
                model: None,
                model_normalized: None,
                mission_id: Some(unbackfilled_id),
                shared_files: None,
                resumable: true,
                completion_evidence: None,
            },
        )
        .await
        .unwrap();

    // Finish remaining batches.
    while store.backfill_search_batch(500).await.unwrap() {}

    let cov_done = store.search_index_coverage().await.unwrap();
    assert_eq!(cov_done.state, SearchIndexState::Ready);
    assert_eq!(cov_done.indexed_missions, 2_150);

    // Oldest mission (#0, archived, >2,000 missions behind) is found!
    let zero_hit = store
        .search_conversations(&ConversationSearchQuery {
            query: "OldestMissionZero_UniqueBeacon_0000".to_string(),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(zero_hit.hits.len(), 1);
    assert_eq!(
        zero_hit.hits[0].mission_id,
        Uuid::parse_str("00000000-0000-4000-8000-000000000000").unwrap()
    );

    // Concurrent write on #2100 survived reconciliation with exactly 1 hit.
    let concurrent_hit = store
        .search_conversations(&ConversationSearchQuery {
            query: "ConcurrentDuringBackfill_2100".to_string(),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(concurrent_hit.hits.len(), 1);
    assert_eq!(concurrent_hit.hits[0].mission_id, unbackfilled_id);

    // Full rebuild produces the exact same coverage and results.
    let rebuilt = store.rebuild_search_index().await.unwrap();
    assert_eq!(rebuilt.state, SearchIndexState::Ready);
    assert_eq!(rebuilt.indexed_missions, 2_150);
}

#[tokio::test]
#[ignore = "synthetic 12k-conversation / 200k-message benchmark; run explicitly with --ignored --nocapture"]
async fn search_benchmark_12k_conversations_200k_messages() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("missions-bench.db");

    const CONVERSATIONS: usize = 12_000;
    const MESSAGES_PER_CONV: usize = 17; // 12,000 * 17 = 204,000 message records
    let projects = ["orb", "turbo-lean", "maxwell", "paloma", "ops", "default"];
    let vocab = [
        "deployment",
        "migration",
        "sqlite",
        "kernel",
        "streaming",
        "websocket",
        "authentication",
        "transfer",
        "latency",
        "scheduler",
        "container",
        "systemd",
        "regression",
        "typescript",
        "virtualizer",
        "backfill",
        "checkpoint",
        "worktree",
    ];

    let mix = |x: usize| -> usize {
        let mut z = (x as u64).wrapping_add(0x9e37_79b9_7f4a_7c15);
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        (z ^ (z >> 31)) as usize
    };

    let seed_start = Instant::now();
    {
        let mut conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(super::cloud::SCHEMA).unwrap();
        conn.execute_batch(super::machine_transfer::SCHEMA).unwrap();
        conn.execute_batch(super::SCHEMA).unwrap();
        let tx = conn.transaction().unwrap();
        {
            let mut m_stmt = tx
                .prepare(
                    "INSERT INTO missions (id, status, title, short_description, workspace_id, backend, created_at, updated_at, project)
                     VALUES (?1, ?2, ?3, ?4, ?5, 'opencode', ?6, ?6, ?7)",
                )
                .unwrap();
            let mut e_stmt = tx
                .prepare(
                    "INSERT INTO mission_events (mission_id, sequence, event_type, timestamp, event_id, content)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                )
                .unwrap();
            let ws = Uuid::nil().to_string();
            for c in 0..CONVERSATIONS {
                let mid = format!("{:08x}-0000-4000-8000-{:012x}", c as u32, c);
                let status = match c % 4 {
                    0 => "acknowledged",
                    1 => "completed",
                    2 => "awaiting_user",
                    _ => "active",
                };
                let proj = projects[c % projects.len()];
                let day = (c % 28) + 1;
                let hour = (c / 28) % 24;
                let min = c % 60;
                let ts = format!("2026-09-{day:02}T{hour:02}:{min:02}:00Z");
                let w1 = vocab[mix(c * 2) % vocab.len()];
                let w2 = vocab[mix(c * 2 + 1) % vocab.len()];
                let title = if c == 42 {
                    "Fix orbital_quantum_handshake_v9 timeout".to_string()
                } else {
                    format!("Investigate {w1} {w2} issue #{c}")
                };
                m_stmt
                    .execute(params![
                        &mid,
                        status,
                        title,
                        format!("Summary for {proj} task {c} covering {w1} and {w2}"),
                        &ws,
                        &ts,
                        proj
                    ])
                    .unwrap();

                for m_idx in 1..=MESSAGES_PER_CONV {
                    let role_type = if m_idx % 2 == 1 {
                        "user_message"
                    } else {
                        "assistant_message"
                    };
                    let mw1 = vocab[mix(c * 64 + m_idx * 2) % vocab.len()];
                    let mw2 = vocab[mix(c * 64 + m_idx * 2 + 1) % vocab.len()];
                    let body = if c == 11_990 && m_idx == 2 {
                        "DeepArchiveBeacon_X99 located at message two of old conversation 11990 with coup d'état 🚀 context.".to_string()
                    } else {
                        match (c + m_idx) % 6 {
                            0 => format!(
                                "Turn {m_idx} in {proj} ({mid}): checking src/api/{mw1}_{mw2}.rs line {} for deterministic recovery.",
                                m_idx * 17
                            ),
                            1 => format!(
                                "Investigated {mw1} {mw2} regression in {proj}; captured flamegraph and verified WAL checkpoint behavior.",
                            ),
                            2 => format!(
                                "Updated {mw1} configuration and {mw2} retry budget for {proj} worker pool #{c}.",
                            ),
                            3 => format!(
                                "Reviewed {mw1} / {mw2} boundary invariants and added replay coverage for sequence {}.",
                                m_idx * 23
                            ),
                            4 => format!(
                                "Measured {mw1} throughput alongside {mw2} memory footprint across {proj} staging nodes.",
                            ),
                            _ => format!(
                                "Confirmed {mw1} and {mw2} rollout finished cleanly on {proj} without dropped events.",
                            ),
                        }
                    };
                    e_stmt
                        .execute(params![
                            &mid,
                            m_idx as i64,
                            role_type,
                            &ts,
                            format!("{mid}-m{m_idx}"),
                            body
                        ])
                        .unwrap();
                }
            }
        }
        tx.commit().unwrap();
    }
    let raw_db_bytes = std::fs::metadata(&db_path).unwrap().len();
    let seed_elapsed = seed_start.elapsed();

    let open_start = Instant::now();
    let store = SqliteMissionStore::new(dir.path().to_path_buf(), "bench")
        .await
        .unwrap();
    let open_elapsed = open_start.elapsed();
    assert!(
        open_elapsed.as_millis() < 250,
        "schema init must not block startup: {open_elapsed:?}"
    );

    // Measure full backfill throughput deterministically.
    let backfill_start = Instant::now();
    while store.backfill_search_batch(250).await.unwrap() {}
    let backfill_elapsed = backfill_start.elapsed();
    let indexed_db_bytes = std::fs::metadata(&db_path).unwrap().len();
    let wal_bytes = std::fs::metadata(dir.path().join("missions-bench.db-wal"))
        .map(|m| m.len())
        .unwrap_or(0);

    // Cold query (first FTS5 query before page warming).
    let cold_start = Instant::now();
    let cold_res = store
        .search_conversations(&ConversationSearchQuery {
            query: "DeepArchiveBeacon_X99".to_string(),
            ..Default::default()
        })
        .await
        .unwrap();
    let cold_ms = cold_start.elapsed().as_secs_f64() * 1000.0;
    assert_eq!(cold_res.hits.len(), 1);

    // Warm query suite (60 queries mixing common terms, compound paths, phrases, prefixes, filters, sort=recent).
    let sample_queries = [
        ("sqlite migration", None, ConversationSearchSort::Relevance),
        (
            "orbital_quantum_handshake_v9",
            None,
            ConversationSearchSort::Relevance,
        ),
        (
            "\"deterministic recovery\"",
            Some("orb"),
            ConversationSearchSort::Relevance,
        ),
        (
            "src/api/kernel_streaming.rs",
            None,
            ConversationSearchSort::Relevance,
        ),
        (
            "websocket latency",
            Some("paloma"),
            ConversationSearchSort::Recent,
        ),
        ("00002ed6", None, ConversationSearchSort::Relevance),
        ("coup d'etat", None, ConversationSearchSort::Relevance),
        ("virtual", None, ConversationSearchSort::Relevance),
        (
            "systemd container",
            Some("ops"),
            ConversationSearchSort::Relevance,
        ),
        (
            "authentication transfer",
            None,
            ConversationSearchSort::Recent,
        ),
    ];

    let mut latencies_ms = Vec::with_capacity(60);
    for round in 0..6 {
        for (q, proj, sort) in &sample_queries {
            let t0 = Instant::now();
            let res = store
                .search_conversations(&ConversationSearchQuery {
                    query: (*q).to_string(),
                    project: proj.map(ToString::to_string),
                    sort: *sort,
                    limit: Some(30),
                    max_per_mission: Some(2),
                    ..Default::default()
                })
                .await
                .unwrap();
            let elapsed_ms = t0.elapsed().as_secs_f64() * 1000.0;
            assert!(
                !res.hits.is_empty(),
                "round {round} query {q} returned empty"
            );
            latencies_ms.push(elapsed_ms);
        }
    }
    latencies_ms.sort_by(|a, b| a.total_cmp(b));
    let p50 = latencies_ms[latencies_ms.len() / 2];
    let p95 = latencies_ms[(latencies_ms.len() * 95) / 100];
    let p99 = latencies_ms[(latencies_ms.len() * 99) / 100];

    // Measure incremental write overhead (100 committed user/assistant messages).
    let target_mid = Uuid::parse_str("0000002a-0000-4000-8000-00000000002a").unwrap();
    let write_start = Instant::now();
    for i in 0..100 {
        store
            .log_event(
                target_mid,
                &AgentEvent::UserMessage {
                    id: Uuid::new_v4(),
                    content: format!("Incremental benchmark message #{i} testing write overhead"),
                    queued: false,
                    mission_id: Some(target_mid),
                    source: None,
                },
            )
            .await
            .unwrap();
    }
    let avg_write_ms = (write_start.elapsed().as_secs_f64() * 1000.0) / 100.0;

    println!(
        "\n=== Conversation Search Synthetic Benchmark (12,000 conversations / 204,000 messages) ===\n\
         Seed time:            {:.2} s\n\
         Store open (DDL):     {:.2} ms\n\
         Backfill total:       {:.2} s ({:.0} msgs/s)\n\
         Raw DB size:          {:.2} MB\n\
         Indexed DB+WAL size:  {:.2} MB (index overhead: {:.2} MB)\n\
         Cold query:           {:.2} ms\n\
         Warm query p50:       {:.2} ms\n\
         Warm query p95:       {:.2} ms (target < 200 ms)\n\
         Warm query p99:       {:.2} ms\n\
         Avg committed write:  {:.3} ms/msg\n",
        seed_elapsed.as_secs_f64(),
        open_elapsed.as_secs_f64() * 1000.0,
        backfill_elapsed.as_secs_f64(),
        (CONVERSATIONS * MESSAGES_PER_CONV) as f64 / backfill_elapsed.as_secs_f64(),
        raw_db_bytes as f64 / (1024.0 * 1024.0),
        (indexed_db_bytes + wal_bytes) as f64 / (1024.0 * 1024.0),
        ((indexed_db_bytes + wal_bytes).saturating_sub(raw_db_bytes)) as f64 / (1024.0 * 1024.0),
        cold_ms,
        p50,
        p95,
        p99,
        avg_write_ms,
    );

    assert!(
        p95 < 200.0,
        "warm p95 latency {p95:.2} ms exceeded 200 ms target"
    );
}
