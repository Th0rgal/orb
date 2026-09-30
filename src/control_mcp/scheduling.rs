//! Mission-bound durable wake-ups through the common authenticated MCP gateway.
use super::ToolDefinition;
use serde_json::{json, Value};

pub fn tools() -> Vec<ToolDefinition> {
    [false, true].into_iter().map(|job| {
        let mut properties = json!({
            "prompt":{"type":"string","minLength":1,"description":"Instruction to deliver on resumption."},
            "reason":{"type":"string","minLength":1,"description":"Short explanation shown in Orb."}
        });
        let field = if job { "job_id" } else { "delay_seconds" };
        properties[field] = if job { json!({"type":"string","format":"uuid"}) }
            else { json!({"type":"integer","minimum":60,"maximum":3600}) };
        ToolDefinition {
            name: if job { "schedule_job_wakeup" } else { "schedule_wakeup" }.into(),
            description: "Schedule one durable continuation of this authenticated mission. Core owns the timer and delivery; end your turn after confirming the action receipt. A time wake-up replaces this mission's previous time wake-up. Never also start a native timer for the same request.".into(),
            input_schema: json!({"type":"object","required":["prompt","reason",field],"properties":properties}),
        }
    }).collect()
}

pub fn body(name: &str, args: &Value) -> Result<Value, String> {
    let prompt = args["prompt"]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .ok_or("Missing wake-up prompt")?;
    let reason = args["reason"]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .ok_or("Missing wake-up reason")?;
    let key = args["idempotency_key"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("Missing wake-up identity")?;
    let job = name == "schedule_job_wakeup";
    let trigger = if job {
        let id = args["job_id"]
            .as_str()
            .and_then(|s| uuid::Uuid::parse_str(s).ok())
            .ok_or("Invalid job ID")?;
        json!({"type":"durable_job_terminal","job_id":id})
    } else {
        let delay = args["delay_seconds"]
            .as_u64()
            .filter(|d| (60..=3600).contains(d))
            .ok_or("Wake-up delay must be 60..3600 seconds")?;
        json!({"type":"interval","seconds":delay})
    };
    Ok(
        json!({"command_source":{"type":"inline","content":prompt},"trigger":trigger,
        "stop_policy":{"type":"after_first_fire"},"fresh_session":"keep","start_immediately":false,
        "variables":{"__wakeup_request_id":key,"__wakeup_reason":reason,"__wakeup_source":if job {"durable-job-terminal"} else {"automation-manager"}}}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn continuation_mcp_uses_scoped_identity_and_durable_one_shot() {
        for name in ["schedule_wakeup", "schedule_job_wakeup"] {
            let tool = super::super::registry()
                .into_iter()
                .find(|t| t.definition.name == name)
                .unwrap();
            assert!(tool.visible_to(super::super::Role::Executor));
            assert!(tool.mutation);
            assert!(tool.definition.input_schema["properties"]
                .get("mission_id")
                .is_none());
            assert!(tool.definition.input_schema["required"]
                .as_array()
                .unwrap()
                .contains(&json!("idempotency_key")));
        }
        let args = json!({"prompt":"Check result", "reason":"Test", "delay_seconds":60,"idempotency_key":"stable"});
        let value = body("schedule_wakeup", &args).unwrap();
        assert_eq!(value["variables"]["__wakeup_request_id"], "stable");
        assert_eq!(value["stop_policy"]["type"], "after_first_fire");
        assert!(body("schedule_wakeup", &json!({"delay_seconds":0})).is_err());
    }
}
