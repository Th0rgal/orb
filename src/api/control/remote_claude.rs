//! Claude stream-json events from a node. User/tool payloads are never prose.
use super::{append_bounded, GrokStream, StreamUpdate};
use serde_json::{json, Value};

impl GrokStream {
    pub(super) fn feed_claude(&mut self, value: &Value, updates: &mut Vec<StreamUpdate>) {
        self.snapshot_pending(updates);
        self.json_events += 1;
        if let Some(session) = value["session_id"].as_str() {
            if self.session_id.as_deref() != Some(session) {
                self.session_id = Some(session.into());
                updates.push(StreamUpdate::SessionId(session.into()));
            }
        }
        match value["type"].as_str() {
            Some("stream_event") => {
                let event = &value["event"];
                match event["type"].as_str() {
                    Some("message_start") => {
                        self.claude_message_streamed = false;
                        self.claude_boundary = !self.text.is_empty();
                        self.thinking.clear();
                    }
                    Some("content_block_start") if event["content_block"]["type"] == "text" => {
                        self.claude_boundary = !self.text.is_empty();
                    }
                    Some("content_block_delta") => {
                        let delta = &event["delta"];
                        if delta["type"] == "text_delta" {
                            if let Some(text) = delta["text"].as_str().filter(|s| !s.is_empty()) {
                                if self.claude_boundary {
                                    append_bounded(&mut self.text, "\n\n");
                                }
                                self.claude_boundary = false;
                                self.claude_message_streamed = true;
                                self.progress = true;
                                append_bounded(&mut self.text, text);
                                updates.push(StreamUpdate::TextSnapshot(self.text.clone()));
                            }
                        } else if delta["type"] == "thinking_delta" {
                            if let Some(text) = delta["thinking"].as_str() {
                                self.progress = true;
                                append_bounded(&mut self.thinking, text);
                                updates.push(StreamUpdate::ThinkingSnapshot(self.thinking.clone()));
                            }
                        }
                    }
                    _ => {}
                }
            }
            Some("assistant") => {
                self.progress = true;
                if let Some(model) = value["message"]["model"].as_str() {
                    self.model = Some(model.into());
                }
                if let Some(blocks) = value["message"]["content"].as_array() {
                    for block in blocks {
                        match block["type"].as_str() {
                            Some("text") if !self.claude_message_streamed => {
                                if let Some(text) = block["text"].as_str().filter(|s| !s.is_empty()) {
                                    if !self.text.is_empty() { append_bounded(&mut self.text, "\n\n"); }
                                    append_bounded(&mut self.text, text);
                                    updates.push(StreamUpdate::TextSnapshot(self.text.clone()));
                                }
                            }
                            Some("tool_use") => updates.push(StreamUpdate::Tool {
                                update: json!({"toolCallId":block["id"],"name":block["name"],"rawInput":block["input"]}), completed:false,
                            }),
                            _ => {}
                        }
                    }
                }
                // CLI versions without partial events still emit distinct assistant messages.
                self.claude_message_streamed = false;
            }
            Some("user") => {
                if let Some(blocks) = value["message"]["content"].as_array() {
                    for block in blocks.iter().filter(|b| b["type"] == "tool_result") {
                        self.progress = true;
                        updates.push(StreamUpdate::Tool { update: json!({
                            "toolCallId":block["tool_use_id"], "output":block["content"],
                            "status":if block["is_error"] == true { "failed" } else { "completed" }
                        }), completed:true });
                    }
                }
            }
            Some("result") => {
                self.ended = true;
                self.progress = true;
                if value["is_error"] == true
                    || value["subtype"].as_str().is_some_and(|s| s != "success")
                {
                    let error = value["result"]
                        .as_str()
                        .map(str::to_string)
                        .unwrap_or_else(|| format!("Claude failed: {}", value["errors"]));
                    self.error = Some(error.clone());
                    updates.push(StreamUpdate::Error(error));
                } else {
                    self.stop_reason = Some("end_turn".into());
                    // Result repeats the final assistant message; only use it as a fallback.
                    if self.text.is_empty() {
                        if let Some(text) = value["result"].as_str() {
                            append_bounded(&mut self.text, text);
                            updates.push(StreamUpdate::TextSnapshot(self.text.clone()));
                        }
                    }
                }
                updates.push(StreamUpdate::End);
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn feed(stream: &mut GrokStream, value: Value) -> Vec<StreamUpdate> {
        stream.feed(&format!("{value}\n"))
    }
    #[test]
    fn claude_streams_before_result_without_repeating_snapshots_or_tool_output() {
        let mut s = GrokStream {
            claude: true,
            ..Default::default()
        };
        feed(&mut s, json!({"type":"system","session_id":"session"}));
        feed(
            &mut s,
            json!({"type":"stream_event","event":{"type":"message_start"}}),
        );
        let out = feed(
            &mut s,
            json!({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Bonjour"}}}),
        );
        assert!(out.contains(&StreamUpdate::TextSnapshot("Bonjour".into())));
        assert!(!s.ended);
        let out = feed(
            &mut s,
            json!({"type":"assistant","message":{"content":[{"type":"text","text":"Bonjour"},{"type":"tool_use","id":"t","name":"Bash","input":{"command":"true"}}]}}),
        );
        assert!(out.iter().any(|u| matches!(
            u,
            StreamUpdate::Tool {
                completed: false,
                ..
            }
        )));
        let out = feed(
            &mut s,
            json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"private tool output"}]}}),
        );
        assert!(out.iter().any(|u| matches!(
            u,
            StreamUpdate::Tool {
                completed: true,
                ..
            }
        )));
        feed(
            &mut s,
            json!({"type":"stream_event","event":{"type":"message_start"}}),
        );
        feed(
            &mut s,
            json!({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Fini"}}}),
        );
        feed(
            &mut s,
            json!({"type":"assistant","message":{"content":[{"type":"text","text":"Fini"}]}}),
        );
        feed(
            &mut s,
            json!({"type":"result","subtype":"success","result":"Fini"}),
        );
        assert_eq!(s.text, "Bonjour\n\nFini");
        assert!(s.ended);
        assert_eq!(s.session_id.as_deref(), Some("session"));
    }
    #[test]
    fn claude_handles_full_messages_and_error_results() {
        let mut s = GrokStream {
            claude: true,
            ..Default::default()
        };
        for text in ["First", "Second"] {
            feed(
                &mut s,
                json!({"type":"assistant","message":{"content":[{"type":"text","text":text}]}}),
            );
        }
        feed(
            &mut s,
            json!({"type":"result","subtype":"error_during_execution","is_error":true,"errors":["denied"]}),
        );
        assert_eq!(s.text, "First\n\nSecond");
        assert!(s.error.as_deref().unwrap().contains("denied"));
    }
}

#[cfg(test)]
mod observer_tests {
    use super::super::*;
    use crate::api::mission_store::{MissionStore, SqliteMissionStore};
    use std::sync::Arc;
    #[tokio::test]
    async fn claude_observer_attaches_and_requires_terminal_result() {
        let dir = tempfile::tempdir().unwrap();
        let store: Arc<dyn MissionStore> = Arc::new(
            SqliteMissionStore::new(dir.path().join("missions"), "claude-stream")
                .await
                .unwrap(),
        );
        let mission = store
            .create_mission(
                Some("stream"),
                None,
                None,
                None,
                None,
                Some("claudecode"),
                None,
            )
            .await
            .unwrap();
        let owner = RemoteMissionOwner {
            mission_store: store,
            events_tx: None,
        };
        let job_id = Uuid::new_v4();
        let mut observer = NativeGrokObserver::attach(&owner, "spark", mission.id, job_id)
            .await
            .unwrap();
        observer.streaming = LogStreaming::Supported;
        let status:NodeJobStatus=serde_json::from_value(serde_json::json!({"job_id":job_id,"mission_id":mission.id,"state":"succeeded","exit_code":0,"created_at":"2026-09-28T00:00:00Z"})).unwrap();
        assert!(!observer.verdict(&status, "spark").await.success);
        observer
            .stream
            .feed("{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"Done\"}\n");
        let verdict = observer.verdict(&status, "spark").await;
        assert!(verdict.success);
        assert_eq!(verdict.content, "Done");
    }
}
