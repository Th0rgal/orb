//! Experimental user-scoped Grok Bot protocol, pinned to the validated desktop contract.
//! No administrator methods; one Bot per mission on the account's shared computer.
use super::*;
use crate::api::mission_store::MissionStore;
use base64::Engine;
use serde_json::json;
use std::{sync::Arc, time::Duration};

pub struct Grok {
    client: reqwest::Client,
    token: String,
}
impl Grok {
    pub fn from_account(account: &str) -> Result<Self, String> {
        if account != "grok-default" {
            return Err("reconnect_required".into());
        }
        let path = std::env::var("GROK_BOT_CREDENTIAL_FILE").map_err(|_| "reconnect_required")?;
        let bytes = std::fs::read(path).map_err(|_| "reconnect_required")?;
        let data: Value = serde_json::from_slice(&bytes).map_err(|_| "reconnect_required")?;
        let token = data["access_token"]
            .as_str()
            .filter(|v| !v.is_empty())
            .ok_or("reconnect_required")?
            .to_owned();
        Ok(Self {
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(30))
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .map_err(|_| "transport_uncertain")?,
            token,
        })
    }
    pub(super) async fn dashboard_usage(&self, method: &str) -> Result<Value, String> {
        // Read-only account methods observed in the installed Grok Bot client.
        if !matches!(
            method,
            "GetMe" | "GetSandUsageStatus" | "GetCurrentPeriodUsage"
        ) {
            return Err("unsupported_usage_method".into());
        }
        let response = self
            .client
            .post(format!(
                "https://api2.cursor.sh/aiserver.v1.DashboardService/{method}"
            ))
            .bearer_auth(&self.token)
            .header("Connect-Protocol-Version", "1")
            .header("x-cursor-client-type", "sand")
            .header("x-cursor-client-version", "0.58.0")
            .header("x-sand-box-namespace", "prod")
            .timeout(Duration::from_secs(10))
            .json(&json!({}))
            .send()
            .await
            .map_err(|_| "usage_unavailable")?;
        if !response.status().is_success() {
            return Err("usage_unavailable".into());
        }
        response
            .json()
            .await
            .map_err(|_| "incompatible_response".into())
    }

    fn request(&self, method: &str) -> reqwest::RequestBuilder {
        self.client
            .post(format!(
                "https://api2.cursor.sh/aiserver.v1.GrokBotService/{method}"
            ))
            .bearer_auth(&self.token)
            .header("Connect-Protocol-Version", "1")
            .header("x-cursor-client-type", "sand")
            .header("x-cursor-client-version", "0.58.0")
            .header("x-cursor-client-os", "darwin")
            .header("x-sand-box-namespace", "prod")
            .header("x-ghost-mode", "true")
    }
    async fn call(&self, method: &str, body: Value) -> Result<Value, String> {
        let response = self
            .request(method)
            .json(&body)
            .send()
            .await
            .map_err(|_| "transport_uncertain")?;
        if !response.status().is_success() {
            return Err(match response.status().as_u16() {
                401 | 403 => "reconnect_required",
                429 => "quota_exhausted",
                400 | 404 | 422 => "incompatible_response",
                _ => "transport_uncertain",
            }
            .into());
        }
        response
            .json()
            .await
            .map_err(|_| "incompatible_response".into())
    }
    async fn is_running(&self, agent: &str) -> Result<bool, String> {
        use futures::TryStreamExt;
        let body = serde_json::to_vec(&json!({
            "cursors":[{"agentId":agent,"generation":0,"afterUpdatedSeq":"0"}],
            "includeUnlistedAgents":false,"inlineBodyMaxBytes":0
        }))
        .map_err(|_| "incompatible_response")?;
        let mut envelope = vec![0];
        envelope.extend_from_slice(&(body.len() as u32).to_be_bytes());
        envelope.extend(body);
        tokio::time::timeout(Duration::from_secs(10), async {
            let response = self
                .request("WatchGrokBotTranscripts")
                .header("Content-Type", "application/connect+json")
                .body(envelope)
                .send()
                .await
                .map_err(|_| "transport_uncertain")?;
            if !response.status().is_success() {
                return Err(match response.status().as_u16() {
                    401 | 403 => "reconnect_required",
                    429 => "quota_exhausted",
                    400 | 404 | 422 => "incompatible_response",
                    _ => "transport_uncertain",
                }
                .into());
            }
            let stream = response.bytes_stream().map_err(std::io::Error::other);
            read_live_snapshot(tokio_util::io::StreamReader::new(stream), agent).await
        })
        .await
        .map_err(|_| "transport_uncertain".to_string())?
    }
    async fn agents(&self) -> Result<Value, String> {
        self.call("ListGrokBotAgents", json!({})).await
    }
    async fn entries(&self, agent: &str) -> Result<Vec<Value>, String> {
        let mut result = Vec::new();
        let mut before: Option<String> = None;
        for _ in 0..20 {
            let mut request = json!({"agentId":agent,"limit":100});
            if let Some(value) = &before {
                request["beforeSeq"] = json!(value);
            }
            let page = self.call("ListGrokBotTranscriptEntries", request).await?;
            let rows = page
                .get("entries")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            if rows.is_empty() {
                return Ok(result);
            }
            let next = rows
                .iter()
                .filter_map(|v| v["seq"].as_str()?.parse::<u64>().ok())
                .min()
                .ok_or("incompatible_response")?
                .to_string();
            if before.as_ref() == Some(&next) {
                return Err("incompatible_response".into());
            }
            for row in &rows {
                let encoded = row["body"].as_str().ok_or("incompatible_response")?;
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(encoded)
                    .map_err(|_| "incompatible_response")?;
                result.push(serde_json::from_slice(&bytes).map_err(|_| "incompatible_response")?);
            }
            if rows.len() < 100 {
                return Ok(result);
            }
            before = Some(next);
        }
        Err("incompatible_response".into())
    }
}

/// Connect streaming JSON envelopes from the pinned desktop protocol. A message
/// is not a turn boundary: Grok sends progress messages while tools still run.
async fn read_live_snapshot<R: tokio::io::AsyncRead + Unpin>(
    mut input: R,
    agent: &str,
) -> Result<bool, String> {
    use tokio::io::AsyncReadExt;
    let mut total = 0usize;
    for _ in 0..16 {
        let mut header = [0; 5];
        input
            .read_exact(&mut header)
            .await
            .map_err(|_| "transport_uncertain")?;
        let size = u32::from_be_bytes(header[1..].try_into().unwrap()) as usize;
        total = total.saturating_add(size);
        if size > 1024 * 1024 || total > 2 * 1024 * 1024 || header[0] & !2 != 0 {
            return Err("incompatible_response".into());
        }
        if header[0] & 2 != 0 {
            return Err("transport_uncertain".into());
        }
        let mut body = vec![0; size];
        input
            .read_exact(&mut body)
            .await
            .map_err(|_| "transport_uncertain")?;
        let frame: Value = serde_json::from_slice(&body).map_err(|_| "incompatible_response")?;
        let Some(state) = frame.get("agentState") else {
            continue;
        };
        if state["snapshot"] != true {
            continue;
        }
        // The snapshot contains live agents only. Protobuf JSON omits an empty
        // repeated `live` field; that is a valid idle snapshot, not an EOF.
        let live = match state.get("live") {
            None => &[][..],
            Some(value) => value.as_array().ok_or("incompatible_response")?.as_slice(),
        };
        let mut running = false;
        for entry in live {
            let id = entry["agentId"]
                .as_str()
                .filter(|v| !v.is_empty())
                .ok_or("incompatible_response")?;
            if id != agent {
                continue;
            }
            for field in [
                "isRunning",
                "isComposingMessage",
                "isRetrying",
                "hasRunningSubagents",
            ] {
                if let Some(value) = entry.get(field) {
                    running |= value.as_bool().ok_or("incompatible_response")?;
                }
            }
        }
        return Ok(running);
    }
    Err("transport_uncertain".into())
}
fn response_for(entries: &[Value], nonce: &str) -> Result<Option<String>, String> {
    let Some(echo) = entries.iter().find(|row| {
        row["kind"] == "message" && row["role"] == "user" && row["clientNonce"] == nonce
    }) else {
        return Ok(None);
    };
    let request = echo["requestId"].as_str().ok_or("incompatible_response")?;
    let mut responses = entries
        .iter()
        .filter(|row| row["kind"] == "send-message" && row["requestId"] == request)
        .collect::<Vec<_>>();
    responses.sort_by_key(|row| row["timestampMs"].as_u64().unwrap_or(0));
    let mut text = Vec::new();
    for row in responses {
        if row["message"]["type"] != "text" {
            return Err("incompatible_response".into());
        }
        text.push(
            row["message"]["content"]
                .as_str()
                .ok_or("incompatible_response")?,
        );
    }
    Ok((!text.is_empty()).then(|| text.join("\n\n")))
}

pub async fn tick(store: &Arc<dyn MissionStore>, mut e: Execution) -> Result<(), String> {
    let Some(i) = e.turns.iter().position(|t| !t.phase.terminal()) else {
        return Ok(());
    };
    if e.turns[i].phase == Phase::Incompatible {
        return Ok(());
    }
    let result = advance(store, &mut e, i).await;
    if let Err(error) = result {
        if e.turns[i].phase != Phase::CancelRequested {
            e.turns[i].phase = match error.as_str() {
                "reconnect_required" => Phase::ReconnectRequired,
                "incompatible_response" => Phase::Incompatible,
                "quota_exhausted" => Phase::Failed,
                _ => {
                    if e.turns[i].phase == Phase::Submitting {
                        Phase::SubmissionUncertain
                    } else {
                        e.turns[i].phase
                    }
                }
            };
        }
        e.turns[i].detail = Some(error);
    }
    super::worker::receipt(store, e, i).await
}
async fn advance(store: &Arc<dyn MissionStore>, e: &mut Execution, i: usize) -> Result<(), String> {
    let adapter = Grok::from_account(&e.selection.account)?;
    if e.external_id.is_none() {
        let agent = e.mission_id.to_string();
        if e.turns[i].phase == Phase::Queued {
            e.turns[i].phase = Phase::Submitting;
            *e = super::worker::save(store, e.clone()).await?;
            let created=adapter.call("CreateGrokBotAgent",json!({"agentId":agent,"name":"Orb cloud agent","title":"Orb cloud agent","harness":2,"createIntent":1,"introductionSuppressed":true})).await?;
            if created["agent"]["agentId"] != agent {
                return Err("incompatible_response".into());
            }
        } else {
            let found = adapter.agents().await?;
            if !found["agents"]
                .as_array()
                .ok_or("incompatible_response")?
                .iter()
                .any(|a| a["agentId"] == agent)
            {
                e.turns[i].phase = if e.turns[i].detail.as_deref() == Some("reconnect_required") {
                    Phase::Queued
                } else {
                    Phase::SubmissionUncertain
                };
                return Ok(());
            }
        }
        e.external_id = Some(agent);
        e.turns[i].phase = Phase::Queued;
        *e = super::worker::save(store, e.clone()).await?;
    }
    let agent = e.external_id.clone().ok_or("incompatible_response")?;
    if e.turns[i].phase == Phase::Queued {
        e.turns[i].phase = Phase::Submitting;
        *e = super::worker::save(store, e.clone()).await?;
        let sent=adapter.call("SendGrokBotUserMessage",json!({"agentId":agent,"messageId":e.turns[i].key,"text":e.turns[i].prompt,"sentAtMs":chrono::Utc::now().timestamp_millis().to_string(),"source":1})).await?;
        match sent["delivery"].as_str() {
            Some(
                "GROK_BOT_USER_MESSAGE_DELIVERY_ACCEPTED_TEMPORAL"
                | "GROK_BOT_USER_MESSAGE_DELIVERY_ACCEPTED_BOX"
                | "GROK_BOT_USER_MESSAGE_DELIVERY_DUPLICATE",
            ) => {}
            Some("GROK_BOT_USER_MESSAGE_DELIVERY_REFUSED") => {
                e.turns[i].phase = Phase::Failed;
                e.turns[i].detail = Some("Provider refused this message".into());
                return Ok(());
            }
            _ => return Err("incompatible_response".into()),
        }
        e.turns[i].external_id = Some(e.turns[i].key.clone());
        e.turns[i].phase = Phase::Running;
        *e = super::worker::save(store, e.clone()).await?;
    }
    if matches!(
        e.turns[i].phase,
        Phase::Submitting | Phase::SubmissionUncertain | Phase::ReconnectRequired
    ) {
        let status = adapter
            .call(
                "GetGrokBotSendStatus",
                json!({"agentId":agent,"messageId":e.turns[i].key}),
            )
            .await?;
        if status["status"] == "GROK_BOT_SEND_STATUS_ACCEPTED" {
            e.turns[i].external_id = Some(e.turns[i].key.clone());
            e.turns[i].phase = Phase::Running;
        } else {
            e.turns[i].phase = if status["status"] == "GROK_BOT_SEND_STATUS_NOT_FOUND"
                && e.turns[i].detail.as_deref() == Some("reconnect_required")
            {
                Phase::Queued
            } else {
                Phase::SubmissionUncertain
            };
            return Ok(());
        }
    }
    if e.turns[i].phase == Phase::CancelRequested {
        let response = adapter
            .call(
                "InterruptGrokBotAgentRun",
                json!({"agentId":agent,"reason":"user_interrupt"}),
            )
            .await?;
        // First receipt records the request; a subsequent server reply confirms no active run.
        let active = cancellation_had_active_run(&response)?;
        if !active
            && e.turns[i].detail.as_deref()
                == Some("Cancellation sent; awaiting provider confirmation")
        {
            e.turns[i].phase = Phase::Cancelled;
            e.turns[i].detail = None;
        } else {
            e.turns[i].detail = Some("Cancellation sent; awaiting provider confirmation".into());
        }
        return Ok(());
    }
    let entries = adapter.entries(&agent).await?;
    if let Some(answer) = response_for(&entries, &e.turns[i].key)? {
        e.turns[i].result = Some(answer);
        if adapter.is_running(&agent).await? {
            e.turns[i].phase = Phase::Running;
            e.turns[i].detail = Some("Provider is still running; response is partial".into());
            return Ok(());
        }
        e.turns[i].phase = Phase::ResponseComplete;
        e.turns[i].detail = None;
        for row in entries.iter().filter(|row| row["requestId"].is_string()) {
            if let Some(id) = row["id"].as_str() {
                store
                    .append_cloud_event(
                        e.mission_id,
                        Event {
                            run_id: e.turns[i].key.clone(),
                            id: id.into(),
                            kind: row["kind"].as_str().unwrap_or("unknown").into(),
                            data: row.clone(),
                        },
                    )
                    .await?;
            }
        }
    }
    Ok(())
}

fn cancellation_had_active_run(response: &Value) -> Result<bool, String> {
    // The pinned desktop protobuf schema declares a non-optional bool with
    // default false. Connect JSON legitimately omits it in an empty object.
    // Do not extend that default to malformed values or unrelated envelopes.
    if response.as_object().is_some_and(|object| object.is_empty()) {
        return Ok(false);
    }
    response
        .get("hadActiveRun")
        .and_then(Value::as_bool)
        .ok_or_else(|| "incompatible_response".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frames(values: &[Value]) -> Vec<u8> {
        let mut bytes = Vec::new();
        for value in values {
            let body = serde_json::to_vec(value).unwrap();
            bytes.push(0);
            bytes.extend_from_slice(&(body.len() as u32).to_be_bytes());
            bytes.extend(body);
        }
        bytes
    }

    #[tokio::test]
    async fn progress_messages_require_a_live_state_snapshot_before_completion() {
        for field in [
            "isRunning",
            "isComposingMessage",
            "isRetrying",
            "hasRunningSubagents",
        ] {
            let mut live = json!({"agentId":"ours"});
            live[field] = json!(true);
            let data = frames(&[
                json!({"connected":{"serverTimeMs":"123"}}),
                json!({"agentState":{"snapshot":true,"live":[live]}}),
            ]);
            assert_eq!(read_live_snapshot(data.as_slice(), "ours").await, Ok(true));
        }
        // A fresh, empty snapshot is how the pinned protocol reports idle.
        for state in [
            json!({"snapshot":true}),
            json!({"snapshot":true,"live":[{"agentId":"other","isRunning":true}]}),
        ] {
            let data = frames(&[json!({"agentState":state})]);
            assert_eq!(read_live_snapshot(data.as_slice(), "ours").await, Ok(false));
        }
    }

    #[tokio::test]
    async fn watch_transport_loss_and_deltas_never_imply_completion() {
        for data in [
            frames(&[json!({"connected":{}}), json!({"heartbeat":{}})]),
            frames(&[json!({"agentState":{"snapshot":false,"live":[]}})]),
            vec![2, 0, 0, 0, 0],
            vec![0, 0],
        ] {
            assert_eq!(
                read_live_snapshot(data.as_slice(), "ours").await,
                Err("transport_uncertain".into())
            );
        }
    }

    #[tokio::test]
    async fn watch_rejects_oversized_compressed_and_malformed_frames() {
        let mut oversized = vec![0];
        oversized.extend_from_slice(&(1024u32 * 1024 + 1).to_be_bytes());
        for data in [
            oversized,
            vec![1, 0, 0, 0, 0],
            frames(&[
                json!({"agentState":{"snapshot":true,"live":[{"agentId":"ours","isRunning":"false"}]}}),
            ]),
        ] {
            assert_eq!(
                read_live_snapshot(data.as_slice(), "ours").await,
                Err("incompatible_response".into())
            );
        }
    }

    #[test]
    fn cancellation_respects_the_pinned_protobuf_boolean_contract() {
        assert_eq!(
            cancellation_had_active_run(&json!({"hadActiveRun":false})),
            Ok(false)
        );
        assert_eq!(
            cancellation_had_active_run(&json!({"hadActiveRun":true})),
            Ok(true)
        );
        assert_eq!(cancellation_had_active_run(&json!({})), Ok(false));
        for response in [
            json!({"unexpected":"response"}),
            json!(null),
            json!({"hadActiveRun":null}),
            json!({"hadActiveRun":"false"}),
        ] {
            assert_eq!(
                cancellation_had_active_run(&response),
                Err("incompatible_response".into())
            );
        }
    }
    #[test]
    fn correlate_by_nonce_and_request_not_latest_message() {
        let rows = vec![
            json!({"kind":"message","role":"user","clientNonce":"a","requestId":"r"}),
            json!({"kind":"send-message","requestId":"other","message":{"type":"text","content":"wrong"}}),
            json!({"kind":"send-message","requestId":"r","message":{"type":"text","content":"**right**"}}),
        ];
        assert_eq!(response_for(&rows, "a").unwrap(), Some("**right**".into()));
        assert_eq!(response_for(&rows, "missing").unwrap(), None);
    }
    #[test]
    fn unknown_response_contract_is_not_silent_success() {
        let rows = vec![
            json!({"kind":"message","role":"user","clientNonce":"a","requestId":"r"}),
            json!({"kind":"send-message","requestId":"r","message":{"type":"future"}}),
        ];
        assert!(response_for(&rows, "a").is_err());
    }
}
