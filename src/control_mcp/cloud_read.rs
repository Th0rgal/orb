//! Bounded cloud receipts: polling must not resend an ever-growing transcript.
use serde_json::{json, Value};

pub(super) fn page(mut execution: Value, arguments: &Value) -> Value {
    let limit = number(arguments, "limit", 1, 5).max(1);
    let text_offset = number(arguments, "text_offset", 0, usize::MAX);
    let text_limit = number(arguments, "text_limit", 4096, 8192).max(1);
    let include_prompt = arguments["include_prompt"].as_bool().unwrap_or(false);
    let turns = match execution["turns"].take() {
        Value::Array(turns) => turns,
        _ => Vec::new(),
    };
    let total = turns.len();
    // Polling without a cursor must describe the current turn, not a completed
    // first turn from earlier in this conversation.
    let offset = number(arguments, "offset", total.saturating_sub(limit), usize::MAX);
    let end = offset.saturating_add(limit).min(total);
    execution["turns"] = Value::Array(turns.into_iter().skip(offset).take(limit).map(|mut turn| {
        let mut slices = serde_json::Map::new();
        for field in ["prompt", "result", "detail"] {
            let value = turn[field].take();
            if field == "prompt" && !include_prompt {
                turn.as_object_mut().unwrap().remove(field);
                continue;
            }
            if let Some(text) = value.as_str() {
                let count = text.chars().count();
                let end = text_offset.saturating_add(text_limit).min(count);
                turn[field] = json!(text.chars().skip(text_offset).take(text_limit).collect::<String>());
                slices.insert(field.into(), json!({"offset":text_offset,"total_chars":count,"next_offset":(end<count).then_some(end)}));
            } else {
                turn[field] = value;
            }
        }
        // Provider-owned collections can contain whole files or conversations.
        // Poll receipts expose their counts, never copy them into model context.
        for field in ["artifacts", "branches"] {
            let count = turn[field].as_array().map_or(0, Vec::len);
            turn.as_object_mut().unwrap().remove(field);
            turn[format!("{field}_count")] = json!(count);
        }
        turn["text_slices"] = Value::Object(slices);
        turn
    }).collect());
    execution["page"] = json!({"offset":offset,"limit":limit,"total":total,"next_offset":(end<total).then_some(end)});
    execution
}

fn number(arguments: &Value, field: &str, default: usize, max: usize) -> usize {
    arguments[field]
        .as_u64()
        .and_then(|v| usize::try_from(v).ok())
        .unwrap_or(default)
        .min(max)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_poll_size_does_not_grow_with_conversation_history() {
        let turn = json!({"key":"one","prompt":"p".repeat(100_000),
            "result":"r".repeat(100_000),"detail":null,
            "artifacts":[{"content":"a".repeat(100_000)}],"branches":[]});
        let execution = json!({"turns":vec![turn;100]});
        let result = page(execution, &json!({"offset":99}));
        assert_eq!(result["page"]["total"], 100);
        assert!(serde_json::to_vec(&result).unwrap().len() < 5000);
        assert_eq!(
            result["turns"][0]["text_slices"]["result"]["total_chars"],
            100_000
        );
        assert_eq!(
            result["turns"][0]["text_slices"]["result"]["next_offset"],
            4096
        );
    }

    #[test]
    fn polling_pages_turns_without_repeating_prompts_or_provider_blobs() {
        let execution = json!({"revision":4,"external_id":"same-agent","turns":[
            {"key":"one","prompt":"private long prompt","result":"été🌍ok","detail":null,"phase":"succeeded","artifacts":[{"content":"huge"}],"branches":[]},
            {"key":"two","prompt":"followup","result":"done","artifacts":[],"branches":[]}
        ]});
        let latest = page(execution.clone(), &json!({}));
        assert_eq!(latest["turns"][0]["key"], "two");
        assert_eq!(latest["page"]["offset"], 1);
        let first = page(execution.clone(), &json!({"offset":0,"text_limit":3}));
        assert_eq!(first["turns"].as_array().unwrap().len(), 1);
        assert!(first["turns"][0].get("prompt").is_none());
        assert!(first["turns"][0].get("artifacts").is_none());
        assert_eq!(first["turns"][0]["artifacts_count"], 1);
        assert_eq!(first["turns"][0]["result"], "été");
        assert_eq!(first["turns"][0]["text_slices"]["result"]["next_offset"], 3);
        assert_eq!(first["page"]["next_offset"], 1);
        let rest = page(
            execution.clone(),
            &json!({"offset":0,"text_offset":3,"include_prompt":true}),
        );
        assert_eq!(rest["turns"][0]["result"], "🌍ok");
        assert!(rest["turns"][0]["text_slices"]["result"]["next_offset"].is_null());
        let second = page(execution.clone(), &json!({"offset":1}));
        assert_eq!(second["turns"][0]["key"], "two");
        assert!(second["page"]["next_offset"].is_null());
        let empty = page(execution, &json!({"offset":u64::MAX,"limit":u64::MAX}));
        assert!(empty["turns"].as_array().unwrap().is_empty());
        assert!(empty["page"]["next_offset"].is_null());
    }
}
