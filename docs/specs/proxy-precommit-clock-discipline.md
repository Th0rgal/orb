# Proxy pre-commit clock discipline & harness header timeout hierarchy

Defines the pre-commitment timeout hierarchy, two-clock (`ClockDiscipline`) SSE
peek invariant, and OpenCode provider header-timeout contract for Core's
inference proxy (`POST /v1/chat/completions`, `src/api/proxy.rs`,
`src/api/proxy_reliability.rs`).

## Background

During mission `9508c505-1a9a-48a5-b265-7c4816a8b124` (`builtin/private` ->
`spark/qwen3.8-flash-next` on `dgx-spark`), OpenCode stalled for over 30 minutes
without advancing a single turn even though no shell command was running:

1. `dgx-spark`'s router serializes concurrent GPU turns behind an inference
   queue. When contended for more than 5 s, it flushes `HTTP 200
   text/event-stream` immediately and emits `: keepalive\n\n` every 10 s while
   waiting for the GPU lock and during prompt prefill.
2. Core's `/v1/chat/completions` router calls `open_sse_with_retry` ->
   `peek_openai_sse_stream_within` **before** returning downstream HTTP 200
   headers so pre-first-chunk errors, empty completions, and safety-filter
   refusals can retry or fail over cleanly across chain entries.
3. Inside `peek_openai_sse_stream_within` (and `peek_google_sse_stream_within`),
   `tokio::time::timeout(idle, stream.next())` bounded only **per-chunk
   transport silence**. Every 10 s `: keepalive\n\n` comment satisfied
   `stream.next()`, was ignored as a non-`data:` line, and reset the `idle`
   timer indefinitely.
4. Because Core had not yet returned HTTP 200 response headers to OpenCode,
   `client_stream_response`'s downstream 15 s `: keepalive\n\n` pump was not
   active yet. OpenCode's `@ai-sdk/openai-compatible` client hit its default
   300,000 ms (`5m`) fetch header timeout
   (`ProviderHeaderTimeoutError: Provider response headers timed out after
   300000ms`), aborted the socket, forfeited its queued turn on `dgx-spark`,
   and re-entered at the tail of the queue on retry.
5. Conversely, on multi-entry cloud chains (`builtin/smart`), an upstream that
   hung while emitting `: keepalive\n\n` heartbeats before any token could wedge
   `peek_*_sse_stream_within` indefinitely and block chain failover.

## 1. Two-clock pre-first-chunk peek discipline (`ClockDiscipline`)

Before a stream commits output (`CannedFilterPeek::SafeOutput` or a valid
`length` finish), `peek_openai_sse_stream_within_deadlines` and
`peek_google_sse_stream_within_deadlines` enforce two independent clocks
(`FirstTokenDeadlines { transport_idle, semantic_total }`):

1. **Per-chunk transport idle clock (`transport_idle`)**:
   - Resets whenever any upstream chunk arrives (including `: keepalive\n\n`
     comments, role-only envelopes, or reasoning/thought chunks).
   - Catches dead TCP connections and silent upstream stalls within
     `first_token_timeout_for_prompt` (`45s` standard cloud, `90s` Cloudflare
     thinking / fleet cliff, up to `240s` direct Gemini thinking or large custom
     fleet prefill).
2. **Monotone semantic first-output clock (`semantic_total`)**:
   - Starts once when `peek_*_sse_stream_within_deadlines` opens the stream and
     **never** resets on `: keepalive\n\n` comments, whitespace, or role-only
     frames.
   - Checked via the formally verified `orb_stream_deadlines` C-ABI gate
     (`Orb.Kernel.streamDeadlines`, `ClockDiscipline`: heartbeat frames never
     extend semantic progress deadlines).
   - Before each `stream.next().await`, the wait duration is bounded by
     `min(transport_idle, remaining_semantic_budget)`. When
     `stream_deadlines` reports `upstream_stalled` on `semantic_started.elapsed()`,
     the peek fails with `CooldownReason::Timeout` (`no content within Ns before
     the first chunk (keepalive-only or non-committing stream)`).

## 2. Cloud failover vs. private GPU fleet queue budgets

`semantic_first_token_timeout_for_prompt(provider, model, via_cloudflare,
estimated_prompt_tokens)` partitions cloud endpoints from direct private GPU
fleet queues:

| Route class | `transport_idle` | `semantic_total` | Rationale |
| --- | --- | --- | --- |
| Standard cloud providers (`ProviderType != Custom`) | `first_token_timeout_for_prompt` (`45s` / `90s` / `240s`) | Equals `transport_idle` | Hung cloud upstreams emitting `: keepalive` fail over promptly to the next chain entry |
| Cloudflare-proxied custom endpoints (`via_cloudflare = true`) | `<= 90s` (`PROXY_CLOUDFLARE_MAX_PREFILL_SECS`) | Equals `transport_idle` (`<= 90s`) | Must stay strictly below Cloudflare's 100 s origin-header cliff |
| Direct custom/private GPU fleet (`ProviderType::Custom`, `!via_cloudflare`, e.g. `spark` / `dgx-spark`) | `first_token_timeout_for_prompt` (`45s`..`240s`) | `max(transport_idle, PROXY_FLEET_SEMANTIC_FIRST_TOKEN_SECS)` (default `600s`) | Serialized single-GPU / multi-mission queues emit `: keepalive` every 10 s while queued + prefilling; `transport_idle` still catches dead sockets in `<= 240s`, while `600s` preserves queue turns across 2–3 concurrent missions |

## 3. Single-attempt cap on exhausted semantic deadlines

`open_sse_with_retry` retries transient pre-first-byte failures (such as quick
upstream resets, empty `finish_reason=stop`, or fast socket timeouts) up to
`RetryPolicy::max_retries` (default `2`).

However, when a single peek attempt already spent `>= semantic_total` and failed
with `CooldownReason::Timeout`, repeating `reopen` on the **same** entry would:

- multiply wall-clock wait by `1 + max_retries` (up to `3 * 600s = 1800s`,
  exceeding downstream client timeouts), and
- drop and re-enqueue behind contended GPU locks repeatedly.

Therefore, `open_sse_with_retry` does **not** perform same-entry retries when
`*reason == CooldownReason::Timeout && attempt_elapsed >= deadlines.semantic_total`:
multi-entry chains advance immediately to the next healthy entry, and
single-entry chains return a clean timeout response within budget.

## 4. Client-vs-proxy timeout hierarchy (`OPENCODE_PROXY_PROVIDER_TIMEOUT_MS`)

OpenCode's `@ai-sdk/openai-compatible` (and `@ai-sdk/*` providers configured in
`opencode.json`) defaults `options.timeout` to `300_000` ms (`5m`). Any Core
route whose legitimate pre-first-token queue + prefill + waterfall failover
exceeds `300s` would otherwise be blind-aborted by OpenCode before Core can
complete failover or receive the queued first token.

All Orb-managed OpenCode provider definitions set
`"timeout": 900000` (`OPENCODE_PROXY_PROVIDER_TIMEOUT_MS`, 15 minutes):

- Remote node OpenCode (`remote_opencode_config` in `src/api/control/remote_plan.rs`)
- Host/container mission runner (`ensure_opencode_provider_for_model`,
  `cli_proxy_opencode_provider_definition`, and
  `custom_opencode_provider_definition` in `src/api/mission_runner.rs`)
- Workspace custom/Kimi provider generation (`src/workspace/config.rs`)
- Desktop local-agent routed OpenCode (`configuration` in
  `orb/src-tauri/src/routed_opencode.rs`)

This establishes a strict ordering:

```text
Cloudflare cliff (90s, when applicable)
  < Direct custom fleet transport_idle (45s..240s)
  < Direct custom fleet semantic_total (600s)
  < OpenCode provider header/fetch timeout (900s)
```

Core — never an uncoordinated client fetch timer — is the single authority for
pre-commitment timeouts, retries, and provider failover.

## 5. Native Lean streamed proxy idle-timeout budget & post-head keep-alive limit

In `lean/OrbCore/OrbCore/Proxy.lean` (`StreamLimits`), streamed `/v1/*` calls
enforce three injectable millisecond limits (`upstreamIdleLimitMs = 600000`,
`upstreamTotalLimitMs = 3600000`, `upstreamStreamPreHeadBudgetMs = 1200000`):
before the upstream response head arrives, each attempt gets
`min(idleMs, remaining preHeadBudgetMs)` and a single idle-out attempt is
recorded as `"upstream_idle_timeout"` rather than `"transport_error"`; once the
20-minute cross-attempt pre-head budget is spent, failover stops and Core
replies `504` (`{"error":"upstream_idle_timeout"}`,
`X-Orb-Exhaustion-Class: upstream_idle_timeout`). After the upstream `2xx` head
is committed, an idle/total timeout closes the downstream chunked stream without
the terminating `0\r\n\r\n` chunk and records `status = "upstream_idle_timeout"`
in `proxy_outcomes` (`proxy_usage` has no failure-reason column). Known limit:
`openTlsUpstreamReader` and `openLoopbackUpstreamReader` do not parse stream
dialects, so any post-head upstream byte (including SSE `: keepalive\n\n`
lines) resets the per-read `idleMs` timer and only `totalMs` (60 minutes in
production) bounds a keep-alive-only stream.
