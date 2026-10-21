//! Global control session API (interactive, queued).
//!
//! This module implements a single global "control session" that:
//! - accepts user messages at any time (queued FIFO)
//! - runs a persistent root-agent conversation sequentially
//! - streams structured events via SSE (Tool UI friendly)
//! - supports frontend/interactive tools by accepting tool results
//! - supports persistent missions (goal-oriented sessions)

pub(crate) mod btw_context;
mod callback_parent;
pub mod client_link;
pub(crate) mod client_placement;
pub(crate) mod continuations;
pub mod cyber;
pub(crate) mod deferred_messages;
pub(crate) mod dispatch_admission;
#[cfg(test)]
pub(crate) mod dispatch_admission_tests;
pub(crate) mod execution_ownership;
pub mod fork;
pub(crate) mod host_goal;
pub(crate) mod machine_transfer;
mod rebalance;
mod remote_failure;
pub(crate) mod remote_grok;
pub use rebalance::spawn_queued_job_rebalancer;
#[cfg(test)]
mod campaign_guard_tests;
mod control_queue;
#[cfg(test)]
mod event_page_cursor_tests;
#[cfg(test)]
mod health_verdict_tests;
#[cfg(test)]
mod inherited_track_tests;
mod remote_queue;
#[cfg(test)]
mod remote_skill_prefix_tests;
pub mod speed;
pub mod speed_proxy;
#[cfg(test)]
mod speed_tests;
#[cfg(test)]
mod stall_guard_tests;
#[cfg(test)]
mod stream_kinds_tests;
pub(crate) use control_queue::*;
mod mission_metadata;
pub(crate) use mission_metadata::*;
mod goal;
pub(crate) use goal::*;
mod http_util;
pub(crate) use http_util::*;
mod types;
pub use types::*;
mod hub;
pub use hub::*;
mod message_handlers;
pub use message_handlers::*;
mod board_http;
pub use board_http::*;
mod mission_list;
pub use mission_list::*;
mod search;
pub use search::*;
mod mission_read;
pub use mission_read::*;
mod mission_create;
pub use mission_create::*;
mod disk_admission;
pub(crate) use disk_admission::*;
mod writer_lease;
pub(crate) use writer_lease::*;
mod remote_plan;
pub(crate) use remote_plan::*;
mod remote_wake;
pub(crate) use remote_wake::*;
mod remote_jobs;
pub use remote_jobs::*;
mod mission_settings;
pub use mission_settings::*;
mod mission_status;
pub use mission_status::*;
mod mission_events;
pub use mission_events::*;
mod mission_lifecycle;
pub use mission_lifecycle::*;
mod streaming;
pub use streaming::*;
mod webhook_forwarder;
use webhook_forwarder::*;
mod automation_scheduler;
use automation_scheduler::*;
mod terminal;
use terminal::*;
mod actor;
use actor::*;
mod automation_http;
pub use automation_http::*;
mod import_export;
pub use import_export::*;
mod webhooks;
pub use webhooks::*;
mod telegram_http;
pub use telegram_http::*;
#[cfg(test)]
mod tests;
pub(crate) mod usage_limit_wait;
#[cfg(test)]
mod vibe_plan_tests;
pub(crate) mod worker_location;
#[cfg(test)]
use dispatch_admission::admit_dispatch;
pub use dispatch_admission::DispatchAdmission;
pub(super) use dispatch_admission::DISPATCH_ADMISSION;

use std::collections::{HashMap, HashSet, VecDeque};
use std::convert::Infallible;
use std::hash::{Hash, Hasher};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

// Control event/command types (Phase 6 of the decomposition).
pub mod board;
pub mod events;
pub use events::*;

use axum::{
    body::Bytes,
    extract::{
        ws::{Message as WsMessage, WebSocket, WebSocketUpgrade},
        Extension, Path, Query, State,
    },
    http::{header, HeaderMap, StatusCode},
    response::{
        sse::{Event, Sse},
        IntoResponse, Response,
    },
    Json,
};
use futures::{stream::Stream, SinkExt, StreamExt};
use serde::Deserializer;
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, mpsc, oneshot, Mutex, RwLock};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

#[allow(unused_imports)]
use super::supervision::{
    ack_promotion_loop, background_task_autoresume_loop, cleanup_stale_active_missions_once,
    recover_server_shutdown_missions, reset_waiting_background_on_boot, stale_mission_cleanup_loop,
    stuck_mission_watchdog_loop, watchdog_skips_control_owned_mission,
};
use crate::agents::{AgentContext, AgentRef, TerminalReason};
use crate::config::Config;
use crate::mcp::McpRegistry;
use crate::secrets::SecretsStore;
use crate::util::{build_history_context, internal_error};
use crate::workspace;
use crate::workspace_exec::WorkspaceExec;

use super::auth::AuthUser;
use super::desktop;
use super::library::SharedLibrary;
use super::mission_store::{
    self, create_mission_store, now_string, AwaitingKind, BoardTask, BoardTaskStatus, Mission,
    MissionExecutionState, MissionHistoryEntry, MissionRun, MissionStore, MissionStoreType,
    MissionToolExecution, MissionToolExecutionState, NewBoardTask,
};
use super::routes::AppState;

/// Most events the event logger writes in one SQLite transaction.
const EVENT_LOG_BATCH: usize = 512;

pub(crate) const SERVER_SHUTDOWN_AUTO_RESUME_MAX_AGE_HOURS: u64 = 48;
const INTERRUPTED_RESUME_PROMPT: &str =
    "[Resume interrupted work] Continue the existing task from its current state. Check the workspace and any background jobs before taking action. Do not redo completed work or duplicate running jobs; preserve the original objective, deadline, and any later user instructions.";
