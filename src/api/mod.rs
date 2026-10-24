//! HTTP API for sandboxed.sh.
//!
//! ## Endpoints
//!
//! - `POST /api/task` - Submit a new task
//! - `GET /api/task/{id}` - Get task status and result
//! - `GET /api/task/{id}/stream` - Stream task progress via SSE
//! - `GET /api/health` - Health check
//! - `GET /api/providers` - List available providers
//! - `GET /api/mcp` - List all MCP servers
//! - `POST /api/mcp` - Add a new MCP server
//! - `DELETE /api/mcp/{id}` - Remove an MCP server
//! - `POST /api/mcp/{id}/enable` - Enable an MCP server
//! - `POST /api/mcp/{id}/disable` - Disable an MCP server
//! - `GET /api/tools` - List all tools (built-in + MCP)
//! - `POST /api/tools/{name}/toggle` - Enable/disable a tool

pub mod ai_providers;
pub(crate) mod antigravity_accounts;
pub(crate) mod antigravity_native;
pub(crate) mod antigravity_usage;
pub mod approval_flow;
pub mod approvals;
pub mod ask;
pub(crate) mod auth;
pub mod automation_variables;
pub mod backends;
pub mod bitwarden;
pub mod capabilities;
pub mod claudecode;
pub mod cli_proxy_accounts;
pub mod cli_proxy_login;
pub mod cloud_agents;
pub mod codex_usage;
mod console;
pub mod control;
pub mod control_metrics;
pub(crate) mod controller_honesty;
pub mod deferred_proxy;
pub mod desktop;
mod desktop_stream;
pub mod disk_watch;
pub mod durable_jobs;
pub mod evidence_watch;
pub mod fido;
pub mod fs;
mod github_auth;
pub mod github_integration;
pub(crate) mod grok_goal;
pub(crate) mod grok_tool_bridge;
pub mod hermes_control_route;
pub(crate) mod kimi_usage;
pub mod library;
pub mod managed_machines;
pub mod mcp;
pub mod metadata_llm;
pub(crate) mod minimax_usage;
pub mod mission_access;
pub mod mission_budget;
pub mod mission_horizon;
pub mod mission_payload;
pub mod mission_runner;
pub mod mission_store;
pub mod mission_workspace_gc;
pub(crate) mod mistral_login;
mod model_routing;
mod monitoring;
mod native_loop_observer;
pub mod oauth_owner;
pub mod oauth_reconcile;
pub mod opencode;
pub(crate) mod operator_attention;
pub mod paloma;
pub mod project_controller;
pub mod project_crons;
pub mod project_files;
pub mod project_health;
pub mod projects_overview;
pub mod projects_store;
mod provider_usage_cache;
pub(crate) mod providers;
pub(crate) mod proxy;
mod proxy_keys;
pub(crate) mod proxy_liveness;
pub(crate) mod proxy_reliability;
pub(crate) mod proxy_timing;
pub(crate) mod reconcile;
pub(crate) mod remote_build;
pub(crate) mod routes;
pub(crate) mod runners;
pub mod scope_reaper;
pub mod secret_broker;
pub mod secrets;
pub mod session_chain;
pub mod settings;
pub mod situation;
pub(crate) mod spark;
pub(crate) mod subscription_usage;
pub(crate) mod supervision;
pub mod system;
pub mod telegram;
pub mod track_leases;
pub mod track_repair;
pub mod tracker_import;
pub mod types;
pub(crate) mod uploads;
pub(crate) mod usage_attribution;
pub mod usage_optimize;
pub(crate) mod usage_summary;
pub mod validation;
pub mod voice;
pub mod webhook_markers;
pub mod workspaces;
pub mod writer_recycle;
pub(crate) mod xai_usage;

pub use routes::serve;
pub use types::*;

pub mod file_resources;

pub mod context_auth;

pub mod context_execution;

pub mod agent_software;
