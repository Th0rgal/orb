# Persistent Session Design

## Problem
Claude CLI process exits prematurely when stdin is closed, causing `MessageComplete` to be sent while bash commands are still running.

## Root Cause
Current implementation:
1. Spawns new process per message
2. Writes message to stdin
3. **Closes stdin immediately** (line 131 in client.rs)
4. Claude CLI interprets closed stdin as "end of session"
5. Process exits after `stop_reason: "end_turn"`
6. `MessageComplete` sent while tools still running

## Solution: Persistent Sessions

### Architecture

**Key Principle**: One long-lived Claude CLI process per mission, stdin stays open.

```
Mission Start
    ↓
┌─────────────────────────────┐
│ init_persistent_session()   │
│ - Spawn Claude CLI process  │
│ - Keep stdin handle open    │
│ - Start event loop          │
└─────────────────────────────┘
    ↓
┌─────────────────────────────┐
│ send_message_streaming()    │
│ - Write to existing stdin   │
│ - Return event receiver     │
└─────────────────────────────┘
    ↓
┌─────────────────────────────┐
│ Events flow from process    │
│ - ToolCall → ToolResult     │
│ - MessageComplete           │
└─────────────────────────────┘
    ↓
┌─────────────────────────────┐
│ Next message (same process) │
│ - Write to stdin again      │
│ - Process still alive       │
└─────────────────────────────┘
    ↓
Mission End
    ↓
┌─────────────────────────────┐
│ close_persistent_session()  │
│ - Kill process              │
│ - Clean up resources        │
└─────────────────────────────┘
```

### Implementation Details

**PersistentSessionState**:
```rust
struct PersistentSessionState {
    stdin: Arc<RwLock<ChildStdin>>,
    event_rx: Arc<RwLock<mpsc::Receiver<ClaudeEvent>>>,
    process_handle: Arc<ProcessHandle>,
}
```

**Sequencing**: Mission runner ensures sequential message sends:
1. Wait for `MessageComplete` from previous message
2. Send next message to stdin
3. Wait for next `MessageComplete`

**No Multiplexing Required**: Events are naturally sequential per the Claude CLI protocol.

### Changes Required

1. **Backend Trait** (mod.rs):
   - Add `supports_persistent_sessions()` → bool
   - Add `init_persistent_session()` → JoinHandle
   - Add `close_persistent_session()` → Result

2. **ClaudeCodeClient** (client.rs):
   - Add `spawn_persistent_session()` → (rx, stdin, handle)
   - **DON'T close stdin**

3. **ClaudeCodeBackend** (claudecode/mod.rs):
   - Store persistent sessions in HashMap
   - Implement init/send/close methods

4. **MissionRunner** (mission_runner.rs):
   - Call `init_persistent_session()` at mission start
   - Reuse session for all messages
   - Call `close_persistent_session()` at mission end

### Migration Path

**Phase 1**: Implement persistent session support (backward compatible)
- Add methods to Backend trait with defaults
- Implement in ClaudeCodeBackend
- Old code continues using one-shot mode

**Phase 2**: Enable in MissionRunner
- Check `supports_persistent_sessions()`
- If true, use persistent mode
- If false, fallback to one-shot

**Phase 3**: Testing
- Unit tests for session lifecycle
- Integration tests with long-running commands
- Deploy to dev backend

## Expected Behavior After Fix

**Before** (broken):
```
User: "gh pr create && sleep 60 && gh pr checks 107"
Claude: "PR created. Now let me wait for CI checks to run."
[Bash tool called with sleep 60]
Claude CLI: *sends stop_reason: "end_turn"*
Claude CLI: *exits*
→ MessageComplete sent
→ Mission marked complete
→ Bash command killed!
```

**After** (fixed):
```
User: "gh pr create && sleep 60 && gh pr checks 107"
Claude: "PR created. Now let me wait for CI checks to run."
[Bash tool called with sleep 60]
Claude CLI: *sends stop_reason: "end_turn"*
Claude CLI: *stays alive (stdin still open)*
[Bash sleeps for 60 seconds]
[Bash completes]
[ToolResult sent back to Claude]
Claude: "Checks are passing..."
Claude CLI: *sends next stop_reason*
→ Eventually MessageComplete when truly done
```
