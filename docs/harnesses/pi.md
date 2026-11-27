# Pi Harness Integration (`pi`)

Pi (`@mariozechner/pi-coding-agent`) is Orb's FV-first coding harness successor to OpenCode, built around **"Lean Decides, Thin Shell Does"**:

- **Lean 4 owns all critical state & policy**:
  - `Orb.Kernel.PiRpcSession` / `Orb.Kernel.piRpcStep` (`lean/Orb/Kernel.lean`, proved in `lean/Orb/Spec.lean`): RPC session lifecycle, mutually exclusive immediate vs. queued `set_model`, `StickyFence` on `aborted`/`closed`, and RPC `id`-correlated rollback on `set_model` rejection.
  - `Orb.Kernel.PiMcpPolicyInput` / `Orb.Kernel.piMcpConfigGate` + `Orb.Kernel.piSessionRelPathSafe`: secrets never in `argv`, `0700` per-mission `PI_CODING_AGENT_DIR`, `0600` config files, confined `.jsonl` session paths (zero `..`), read-only/plan mutation blocking.
  - `OrbNode.PiRpc` (`sandboxed-node pi-rpc`): pure-Lean subprocess driver piloting `pi --mode rpc --session <mission.jsonl>` over strict LF-delimited JSONL (`stdin`/`stdout`), applying `piRpcStep`, and cleanly terminating the process group and any child `turbo-lean mcp` stdio process on exit/abort.
  - `OrbCore.Harness.stepPiJsonLine`: JSONL normalization into `AgentEvent` with strict `Thinking` vs. `TextDelta` separation, `toolCallId` correlation (including `sandboxed__*` and `turbo_lean__*`), and fail-closed `TurnResult(isError := true, ...)` on RPC/process errors.
- **Minimal Pi TypeScript extension (`pi/orb-extension/index.ts`)**:
  - Zero domain state; bridges the two MCP servers into Pi's tool registry:
    1. `sandboxed` over **Streamable HTTP** (`SANDBOXED_MCP_URL` + `Authorization: Bearer $SANDBOXED_MCP_TOKEN`, tools prefixed `sandboxed__*`).
    2. `turbo-lean` over **stdio** (`turbo-lean mcp`, tools prefixed `turbo_lean__*`, auto-enabled when `turbo-lean` is available on `PATH`).
  - Enables Pi's built-in read-only search tools (`grep`, `find`, `ls`) alongside `read`/`bash`/`edit`/`write` (or read-only subset `read`/`grep`/`find`/`ls` in `/plan` or `readonly` mode).
  - Applies Orb policy guards: blocks mutating tools (`write`, `edit`, non-readonly `bash`) in `readonly`/`plan` mode, and guards raw `lake build` invocations in Lean workspaces unless `SANDBOXED_ALLOW_RAW_LAKE=1` is set (directing agents to `turbo-lean` / `turbo_lean__*` MCP tools).

## Skills & Context Parity

- `OrbCore.Skills.nativeDirectory "pi"` maps to `.pi/skills`.
- Pi natively discovers `.pi/skills/<name>/SKILL.md`, `.agents/skills/<name>/SKILL.md`, `AGENTS.md`, and `CLAUDE.md`, and expands `/skill:<name>` commands directly in RPC mode.
- OrbCore's `remoteInstallPrelude` stages all delivered Library + project-context skills (including companion `references/**` files) into `.pi/skills/<name>/` before launching `pi`.

## Full-Catalog `models.json` & Mid-Session Model Switching

For every remote or proxied Pi mission, OrbCore stages a per-mission `PI_CODING_AGENT_DIR` (`0700`) containing:

- `models.json` (`0600`): registers provider `"orb"` (`api: "openai-completions"`, `baseUrl: "{proxyBase}/v1"`, `apiKey: "SANDBOXED_PROXY_API_KEY"`, `authHeader: true`) listing **the entire Orb Core routable model catalog** (all routing chains `builtin/*` + curated provider models + user-configured models), not only the initial model.
  - Because Pi reads the environment variable named by `apiKey` (`"SANDBOXED_PROXY_API_KEY"`), no secret token is written to `argv` or stored in plaintext in `models.json`.
  - Because every routable Orb model is registered in `models.json`, mid-session model switching (`PATCH /api/control/missions/:id/settings` with `model_override` / `model_effort`, or RPC `{"type":"set_model","provider":"orb","modelId":"..."}`) works cleanly against the exact same persistent JSONL session file (`--session <mission_dir>/session.jsonl`).
- `extensions/orb-extension/index.ts` (linked/staged from `pi/orb-extension/index.ts` or passed via `--extension`).

## Fleet Topology & Verification (`turbo-lean mcp` + `pi`)

### Live verification receipt — `uruk` (2026-11-27)

| Component | Host | Status (`evidence tier`) | Observed details |
| --- | --- | --- | --- |
| `turbo-lean` | `uruk` | Verified (`executable-reproduced`) | `/usr/local/bin/turbo-lean` (`turbo-lean 0.1.0`) |
| `turbo-lean mcp` | `uruk` | Verified (`executable-reproduced`) | JSON-RPC 2.0 `initialize` → `turbo-lean-mcp 0.5.0`; `tools/list` returns 6 tools: `turbo_agent_step`, `turbo_check_decl`, `turbo_fast_check`, `turbo_audit_spec`, `turbo_pr_verify`, `turbo_cluster_status` |
| Node / Bun runtime | `uruk` | Verified (`executable-reproduced`) | `node v22.21.0`, `npm 10.9.4`, `bun 1.3.5` |
| `pi` (`@mariozechner/pi-coding-agent`) | `uruk` | Not yet globally installed in `/usr/local/bin/pi`; npm package `0.73.1` verified (`executable-reproduced`) | Tested locally in isolated npm install (`pi --version` → `0.73.1`, `--mode rpc`, `--session`, `--extension`, `--model`, `--thinking`, `PI_CODING_AGENT_DIR`) |
| `ashur`, `dgx-spark` | fleet | Pending operator rollout (`blocked`: coding-only mission has no fleet SSH keys) | Provision via `scripts/update-node-harnesses.py --only pi` and verify `turbo-lean mcp` handshake below |

### Fleet rollout & verification commands (`uruk`, `ashur`, `dgx-spark`)

1. **Install/reconcile pinned `pi` (`0.73.1`) via the fleet harness updater (as root):**
   ```bash
   install -m 755 scripts/update-node-harnesses.py /usr/local/sbin/update-node-harnesses
   python3 /usr/local/sbin/update-node-harnesses --only pi --version 0.73.1
   ```
   This installs `@mariozechner/pi-coding-agent@0.73.1` into `/opt/sandboxed-tools/pi/0.73.1/`, probes `pi --version` and `pi --help` (`--mode`, `--session`, `--extension`, `--model`) as `sandboxed-node`, and atomically swaps `/usr/local/bin/pi`.

2. **Install/stage the Orb Pi extension on each node:**
   ```bash
   install -d -m 755 /opt/sandboxed-tools/pi-orb-extension
   install -m 644 pi/orb-extension/index.ts /opt/sandboxed-tools/pi-orb-extension/index.ts
   ```
   (OrbCore also falls back to `$ORB_PI_EXTENSION_PATH`, `/opt/sandboxed-tools/pi-orb-extension/index.ts`, or a mission-staged copy from Core.)

3. **Verify `turbo-lean mcp` JSON-RPC handshake on each build/FV node (`uruk`, `ashur`, `dgx-spark`):**
   ```bash
   printf '%s\n%s\n%s\n' \
     '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"orb-probe","version":"0.1.0"}}}' \
     '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
     '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
     | timeout 10 turbo-lean mcp
   ```
   Confirm `serverInfo.name == "turbo-lean-mcp"` and all 6 tools are returned.

4. **Build resource discipline when updating `turbo-lean` on any fleet host:**
   - Check active builds first: `pgrep -lx "lean|lake|turbo-lean"`.
   - Run one heavy build at a time with bounded parallelism (`--jobs 2`, `--max-memory-mb 6144`).

## Formal Specification & Audit

- Kernel definitions: `lean/Orb/Kernel.lean` (`PiRpcPhase`, `PiRpcSession`, `PiRpcEvent`, `PiRpcOutcome`, `piRpcStep`, `PiMcpPolicyInput`, `piMcpConfigGate`, `piSessionRelPathSafe`).
- Formal proofs & two-sided regressions: `lean/Orb/Spec.lean`.
- Human Spec Card: [`docs/spec-cards/pi-harness.md`](../spec-cards/pi-harness.md).
- Audit command: `turbo-lean --json audit-spec lean/Orb/Spec.lean`.
