//! Hermes sees the coordinator profile of the canonical MCP registry.
//! No hand-maintained copy of tool names is permitted in client configuration.
pub fn coordinator_tools() -> Vec<String> {
    crate::control_mcp::catalog(crate::control_mcp::Role::Coordinator)
        .into_iter()
        .map(|tool| tool.name)
        .collect()
}
pub fn yaml_include_items(indent: &str) -> String {
    coordinator_tools()
        .iter()
        .map(|tool| format!("{indent}- {tool}"))
        .collect::<Vec<_>>()
        .join("\n")
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn generated_names_are_unique_and_include_cloud() {
        let names = coordinator_tools();
        let unique = names.iter().collect::<std::collections::HashSet<_>>();
        assert_eq!(unique.len(), names.len());
        assert!(names.iter().any(|s| s == "list_cloud_accounts"));
        assert!(names.iter().any(|s| s == "get_action"));
        assert!(!names.iter().any(|s| s == "deploy_sandboxed_sh"));
    }
}
