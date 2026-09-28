//! Validation for the explicitly supported JSON Schema vocabulary in our tool
//! registry. Unknown assertions fail the registry test rather than being ignored.
use serde_json::Value;

pub fn check_schema(schema: &Value) -> Result<(), String> {
    let map = schema.as_object().ok_or("Schema must be an object")?;
    for (key, value) in map {
        match key.as_str() {
            "type"
            | "enum"
            | "required"
            | "additionalProperties"
            | "minimum"
            | "maximum"
            | "minLength"
            | "maxLength"
            | "minItems"
            | "maxItems"
            | "format"
            | "description"
            | "title"
            | "default"
            | "$schema" => {}
            "properties" => {
                for child in value
                    .as_object()
                    .ok_or("properties must be an object")?
                    .values()
                {
                    check_schema(child)?
                }
            }
            "items" => check_schema(value)?,
            _ => return Err(format!("Unsupported schema keyword {key}")),
        }
    }
    Ok(())
}
fn is_type(value: &Value, kind: &str) -> bool {
    match kind {
        "object" => value.is_object(),
        "array" => value.is_array(),
        "string" => value.is_string(),
        "boolean" => value.is_boolean(),
        "null" => value.is_null(),
        "integer" => value.is_i64() || value.is_u64(),
        "number" => value.is_number(),
        _ => false,
    }
}
pub fn validate(schema: &Value, value: &Value) -> Result<(), String> {
    validate_at(schema, value, "arguments")
}
fn validate_at(schema: &Value, value: &Value, path: &str) -> Result<(), String> {
    if let Some(kind) = schema.get("type") {
        let matches = kind.as_str().is_some_and(|k| is_type(value, k))
            || kind.as_array().is_some_and(|ks| {
                ks.iter()
                    .filter_map(Value::as_str)
                    .any(|k| is_type(value, k))
            });
        if !matches {
            return Err(format!("{path}: incorrect type"));
        }
    }
    if let Some(variants) = schema.get("enum").and_then(Value::as_array) {
        if !variants.contains(value) {
            return Err(format!("{path}: value is not in the allowed enum"));
        }
    }
    if let Some(object) = value.as_object() {
        if let Some(required) = schema.get("required").and_then(Value::as_array) {
            for field in required.iter().filter_map(Value::as_str) {
                if !object.contains_key(field) {
                    return Err(format!("{path}.{field}: required"));
                }
            }
        }
        for (key, child) in object {
            if let Some(child_schema) = schema.get("properties").and_then(|p| p.get(key)) {
                validate_at(child_schema, child, &format!("{path}.{key}"))?
            } else if schema.get("additionalProperties") == Some(&Value::Bool(false)) {
                return Err(format!("{path}: unknown argument"));
            }
        }
    }
    if let Some(array) = value.as_array() {
        bounds(schema, array.len() as f64, "minItems", "maxItems", path)?;
        if let Some(items) = schema.get("items") {
            for (i, child) in array.iter().enumerate() {
                validate_at(items, child, &format!("{path}[{i}]"))?
            }
        }
    }
    if let Some(string) = value.as_str() {
        bounds(
            schema,
            string.chars().count() as f64,
            "minLength",
            "maxLength",
            path,
        )?;
        match schema.get("format").and_then(Value::as_str) {
            Some("uuid") if uuid::Uuid::parse_str(string).is_err() => {
                return Err(format!("{path}: invalid UUID"))
            }
            Some("date-time") if chrono::DateTime::parse_from_rfc3339(string).is_err() => {
                return Err(format!("{path}: invalid RFC3339 timestamp"))
            }
            _ => {}
        }
    }
    if let Some(number) = value.as_f64() {
        bounds(schema, number, "minimum", "maximum", path)?
    }
    Ok(())
}
fn bounds(schema: &Value, value: f64, min: &str, max: &str, path: &str) -> Result<(), String> {
    if schema
        .get(min)
        .and_then(Value::as_f64)
        .is_some_and(|n| value < n)
        || schema
            .get(max)
            .and_then(Value::as_f64)
            .is_some_and(|n| value > n)
    {
        return Err(format!("{path}: outside allowed bounds"));
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn registry_only_uses_supported_validation() {
        for t in super::super::registry() {
            check_schema(&t.definition.input_schema).unwrap();
        }
    }
    #[test]
    fn rejects_unknown_nested_and_invalid_types() {
        let s = json!({"type":"object","required":["provider"],"additionalProperties":false,"properties":{"provider":{"type":"string","enum":["chatgpt"]},"limit":{"type":"integer","minimum":1}}});
        assert!(validate(&s, &json!({"provider":"chatgpt"})).is_ok());
        for v in [
            json!({}),
            json!({"provider":"x"}),
            json!({"provider":"chatgpt","limit":0}),
            json!({"provider":"chatgpt","extra":true}),
        ] {
            assert!(validate(&s, &v).is_err())
        }
    }
}
