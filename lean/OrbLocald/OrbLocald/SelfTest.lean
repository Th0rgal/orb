import OrbBin.Json
import OrbLocald

/-
  OrbLocald.SelfTest — Conformance & self-test runner for `lean/OrbLocald`.
-/

open OrbBin.Json
open OrbLocald.Spec
open OrbLocald.Rpc

private def assertEq {α : Type} [BEq α] [ToString α] (label : String) (got expected : α) : IO Bool := do
  if got == expected then
    return true
  else
    IO.eprintln s!"FAIL [{label}]: got {got}, expected {expected}"
    return false

private def assertTrue (label : String) (cond : Bool) : IO Bool := do
  if cond then return true
  else
    IO.eprintln s!"FAIL [{label}]"
    return false

def main : IO UInt32 := do
  let mut passed := 0
  let mut total := 0

  -- 1. Command table size (87 desktop commands + plugin:app|version = 88)
  total := total + 1
  if (← assertEq "desktop_command_count" supportedDesktopCommands.size 88) then passed := passed + 1

  -- 2. Loopback RPC auth gate (>= 32-byte non-placeholder secret + local Origin confinement)
  let validTok := "0123456789abcdef0123456789abcdef"
  total := total + 1
  if (← assertTrue "rpc_auth_loopback_ok" (checkRpcAuth "127.0.0.1" validTok validTok)) then passed := passed + 1
  total := total + 1
  if (← assertTrue "rpc_auth_reject_remote" (!(checkRpcAuth "10.0.0.5" validTok validTok))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "rpc_auth_reject_bad_token" (!(checkRpcAuth "127.0.0.1" "wrong-token-00000000000000000000" validTok))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "rpc_auth_reject_short_24b_default_token" (!(checkRpcAuth "127.0.0.1" "orb-locald-default-token" "orb-locald-default-token"))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "origin_allow_local_loopback" (isAllowedLocaldOrigin (some "http://127.0.0.1:19479"))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "origin_reject_remote_evil" (!(isAllowedLocaldOrigin (some "https://evil.example")))) then passed := passed + 1

  -- 3. Transport bridge 6 SSE stream shard ports & 3-way failover
  let stRef ← IO.mkRef ({ launchToken := validTok } : LocaldState)
  let txRes ← dispatchRpcCommand stRef "transport_bridge_configure" (.obj #[])
  total := total + 1
  match txRes with
  | .ok jv =>
    let shards := match jv.fieldArr? "stream_proxy_base_urls" with
      | some xs => xs.size
      | none => 0
    if (← assertEq "transport_6_sse_shards" shards 6) then passed := passed + 1
  | .error e =>
    IO.eprintln s!"FAIL [transport_bridge_configure]: {e}"

  total := total + 1
  if (← assertTrue "sse_shard_rejects_port_overflow_65532" (verifySseShardConfig 6 65532 == 0)) then passed := passed + 1

  total := total + 1
  if (← assertTrue "failover_get_allowed" (canFailoverRequest "GET" false 1 defaultFailoverOrigins)) then passed := passed + 1
  total := total + 1
  if (← assertTrue "failover_post_without_idem_blocked" (!(canFailoverRequest "POST" false 1 defaultFailoverOrigins))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "failover_post_with_idem_allowed" (canFailoverRequest "POST" true 2 defaultFailoverOrigins)) then passed := passed + 1

  -- 4. Channel subscribe / initial snapshot / unsubscribe / __orb_poll_events lifecycle
  let sub1 ← dispatchRpcCommand stRef "local_bindings_subscribe" (.obj #[])
  let sub2 ← dispatchRpcCommand stRef "local_interaction_subscribe" (.obj #[("id", .str "m1")])
  total := total + 1
  let okSubs := match sub1, sub2 with
    | .ok (.num "1"), .ok (.num "2") => true
    | _, _ => false
  if (← assertTrue "channel_subscribe_monotonic" okSubs) then passed := passed + 1

  -- Initial snapshots (`{"revision":0,"bindings":{}}` for 1, `null` for 2) are queued immediately!
  let polledInit ← dispatchRpcCommand stRef "__orb_poll_events" (.obj #[])
  let polledEmpty ← dispatchRpcCommand stRef "__orb_poll_events" (.obj #[])
  total := total + 1
  let pollOk := match polledInit, polledEmpty with
    | .ok (.arr #[_, _]), .ok (.arr #[]) => true
    | _, _ => false
  if (← assertTrue "channel_poll_events_initial_snapshots_and_drains_once" pollOk) then passed := passed + 1

  let _ ← dispatchRpcCommand stRef "local_bindings_unsubscribe" (.obj #[("token", JVal.nat 1)])
  let curSt ← stRef.get
  total := total + 1
  let activeCount := (curSt.subscriptions.filter (·.active)).size
  if (← assertEq "channel_unsubscribe_prunes" activeCount 1) then passed := passed + 1

  -- Origin CRLF reflection defense + approval_grace_until / set_approval_grace ({ secs }) contract
  total := total + 1
  if (← assertTrue "origin_reject_crlf_injection" (!(isAllowedLocaldOrigin (some "http://127.0.0.1:19479\r\nX-Injected: 1")))) then passed := passed + 1
  let _ ← dispatchRpcCommand stRef "set_approval_grace" (.obj #[("secs", JVal.nat 120)])
  let graceSt ← stRef.get
  let graceUntilRes ← dispatchRpcCommand stRef "approval_grace_until" (.obj #[])
  total := total + 1
  let graceOk := graceSt.approvalGraceSecs == 120 && (match graceUntilRes with | .ok (.num "0") => true | _ => false)
  if (← assertTrue "approval_grace_secs_and_until_contract" graceOk) then passed := passed + 1

  -- 5. Paloma Touch ID grace eligibility (strict canonical UUID + paloma-approval-v1 + non-empty summary)
  let goodPayload :=
    "paloma-approval-v1\n1700000000\nPOST /api/bitwarden/requests/550e8400-e29b-41d4-a716-446655440000/approve\nhost\nhash\nAllow secret FOO"
  let nonBwPayload :=
    "paloma-approval-v1\n1700000000\nPOST /api/privilege-access/550e8400-e29b-41d4-a716-446655440000/approve\nhost\nhash\nRoot shell"
  let badUuidPayload :=
    "paloma-approval-v1\n1700000000\nPOST /api/bitwarden/requests/zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz/approve\nhost\nhash\nAllow secret FOO"
  let badHeaderPayload :=
    "paloma-approval-v0\n1700000000\nPOST /api/bitwarden/requests/550e8400-e29b-41d4-a716-446655440000/approve\nhost\nhash\nAllow secret FOO"
  total := total + 1
  if (← assertTrue "paloma_grace_bitwarden_approve" (isPalomaPayloadGraceEligible goodPayload)) then passed := passed + 1
  total := total + 1
  if (← assertTrue "paloma_grace_rejects_priv" (!(isPalomaPayloadGraceEligible nonBwPayload))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "paloma_grace_rejects_non_hex_uuid" (!(isPalomaPayloadGraceEligible badUuidPayload))) then passed := passed + 1
  total := total + 1
  if (← assertTrue "paloma_grace_rejects_wrong_header" (!(isPalomaPayloadGraceEligible badHeaderPayload))) then passed := passed + 1

  -- 6. WebView init script exposes __ORB_DESKTOP__, __TAURI__, __TAURI_INTERNALS__, SSE /__orb_events, captured _fetch, and JSON-escapes token
  let js := renderWebviewInitScript 19479 (validTok ++ "\"quote")
  total := total + 1
  let hasGlobals :=
    (js.splitOn "__ORB_DESKTOP__").length > 1 &&
    (js.splitOn "__TAURI_INTERNALS__").length > 1 &&
    (js.splitOn "/__orb_events").length > 1 &&
    (js.splitOn "Channel").length > 1 &&
    (js.splitOn "const _fetch = window.fetch.bind(window);").length > 1 &&
    (js.splitOn "\\\"quote").length > 1
  if (← assertTrue "webview_init_script_globals_and_escaping" hasGlobals) then passed := passed + 1

  -- 7. Version RPC + CSPRNG UUIDv4 check
  let verRes ← dispatchRpcCommand stRef "plugin:app|version" (.obj #[])
  total := total + 1
  let verOk := match verRes with | .ok (.str "0.13.0") => true | _ => false
  if (← assertTrue "plugin_app_version_0_13_0" verOk) then passed := passed + 1

  let u1 ← randomUuidV4
  let u2 ← randomUuidV4
  total := total + 1
  if (← assertTrue "csprng_uuid_v4_canonical_and_distinct" (isCanonicalUuid u1 && isCanonicalUuid u2 && u1 != u2)) then passed := passed + 1

  -- 8. Streaming SSE response header parser preserves `\r\n\r\n`-delimited SSE events + split UTF-8 body tail
  let sseSample := ("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: {\"type\":\"ready\"}\r\n\r\n".toUTF8).push 0xE2
  total := total + 1
  let sseOk := match extractStreamingResponseHead? sseSample with
    | .ok (some (200, _, tail)) =>
      tail == (("data: {\"type\":\"ready\"}\r\n\r\n".toUTF8).push 0xE2)
    | _ => false
  if (← assertTrue "sse_streaming_head_preserves_crlf_frames_and_split_utf8" sseOk) then passed := passed + 1

  -- 9. Streaming header parser rejects colon-less header lines and non-chunked Transfer-Encoding
  let badColonHead := "HTTP/1.1 200 OK\r\nMalformedHeaderWithoutColon\r\n\r\n".toUTF8
  let badTeHead := "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".toUTF8
  total := total + 1
  if (← assertTrue "sse_streaming_head_rejects_colonless_and_bad_te"
      ((extractStreamingResponseHeadEx? badColonHead).isOk.not &&
       (extractStreamingResponseHeadEx? badTeHead).isOk.not)) then passed := passed + 1

  -- 10. Incremental HTTP/1.1 `Transfer-Encoding: chunked` decoder reassembles split SSE events 1-byte-at-a-time
  let rawChunkedSse := ("7;ext=1\r\ndata: {\r\n10\r\n\"ok\":true}\r\n\r\n:k\r\n0\r\nX-Trl: 1\r\n\r\n").toUTF8
  let chunkedRes : Except String (ByteArray × Bool) := Id.run do
    let mut st : ChunkedStreamState := .readSizeLine ByteArray.empty
    let mut acc := ByteArray.empty
    let mut done := false
    for i in [0:rawChunkedSse.size] do
      match stepChunkedStream st (rawChunkedSse.extract i (i + 1)) with
      | .error e => return .error e
      | .ok (dec, st', d) =>
        acc := acc ++ dec
        st := st'
        done := d
    return .ok (acc, done)
  total := total + 1
  let chunkedOk := match chunkedRes with
    | .ok (dec, true) => dec == "data: {\"ok\":true}\r\n\r\n:k".toUTF8
    | _ => false
  if (← assertTrue "chunked_sse_decoder_reassembles_split_events_and_trailers" chunkedOk) then passed := passed + 1

  total := total + 1
  let badChunkOk :=
    (stepChunkedStream (.readSizeLine ByteArray.empty) ("ZZ\r\n".toUTF8)).isOk.not &&
    (stepChunkedStream (.readSizeLine ByteArray.empty) ("0\r\n\n\r\n".toUTF8)).isOk.not &&
    (stepChunkedStream (.readSizeLine ByteArray.empty) ("0\r\n\nX-Ok: 1\r\n\r\n".toUTF8)).isOk.not &&
    (stepChunkedStream (.readSizeLine ByteArray.empty) ("0\r\nX-Ok: 1\n\r\n\r\n".toUTF8)).isOk.not &&
    (stepChunkedStream (.readSizeLine ByteArray.empty) ("0\r\nX-Ok : 1\r\n\r\n".toUTF8)).isOk.not
  if (← assertTrue "chunked_sse_decoder_rejects_bad_hex_and_bare_lf_trailers" badChunkOk) then passed := passed + 1

  -- 11. Bracketed IPv6 & IPv4/DNS `parseOriginHostPort`
  total := total + 1
  let ipv6Ok :=
    parseOriginHostPort "https://[::1]:8443/api/v1" == some (true, "::1", 8443, "/api/v1") &&
    parseOriginHostPort "https://[2001:db8::1]" == some (true, "2001:db8::1", 443, "") &&
    parseOriginHostPort "https://orbcore.thomas.md:9443/tx" == some (true, "orbcore.thomas.md", 9443, "/tx") &&
    (parseOriginHostPort "https://[:::]").isNone
  if (← assertTrue "parse_origin_host_port_supports_bracketed_ipv6" ipv6Ok) then passed := passed + 1

  -- 12. Optional unconfigured RPCs return `.null` (never `{ok: true}`) and unknown action commands fail cleanly
  let ctxFileRes ← dispatchRpcCommand stRef "project_context_file" (.obj #[("slug", .str "ethereum"), ("op", .str "list")])
  let ctxStatusRes ← dispatchRpcCommand stRef "project_context_status" (.obj #[("slug", .str "ethereum")])
  let unsupportedRes ← dispatchRpcCommand stRef "nonexistent_action_cmd" (.obj #[])
  total := total + 1
  let optionalNullOk :=
    (match ctxFileRes with | .ok .null => true | _ => false) &&
    (match ctxStatusRes with | .ok .null => true | _ => false) &&
    unsupportedRes.isOk.not
  if (← assertTrue "optional_project_context_rpcs_return_null_not_stub_obj" optionalNullOk) then passed := passed + 1

  -- 13. Persisted desktop connection (`0600`), diagnostics JSONL sink, machine identity string, and host metrics schema
  let tmpUuid ← randomUuidV4
  let tmpStateDir := s!"/tmp/orb-locald-selftest-{tmpUuid}"
  let stDiskRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := tmpStateDir, homeDir := tmpStateDir, hostOs := "macos" } : LocaldState)
  let initLoad ← dispatchRpcCommand stDiskRef "desktop_connection_load" (.obj #[])
  let _ ← dispatchRpcCommand stDiskRef "desktop_connection_save" (.obj #[("apiUrl", .str "https://orbcore.example:9443"), ("token", .str "tok-secret-123")])
  let savedLoad ← dispatchRpcCommand stDiskRef "desktop_connection_load" (.obj #[("ignore", .null)])
  let stReloadRef ← IO.mkRef ({ launchToken := validTok, orbStateDir := tmpStateDir, homeDir := tmpStateDir, hostOs := "macos" } : LocaldState)
  let diskLoad ← dispatchRpcCommand stReloadRef "desktop_connection_load" (.obj #[])
  total := total + 1
  let connOk :=
    (match initLoad with | .ok .null => true | _ => false) &&
    (match savedLoad with
     | .ok jv => jv.fieldStr? "api_url" == some "https://orbcore.example:9443" && jv.fieldStr? "token" == some "tok-secret-123"
     | _ => false) &&
    (match diskLoad with
     | .ok jv => jv.fieldStr? "api_url" == some "https://orbcore.example:9443" && jv.fieldStr? "token" == some "tok-secret-123"
     | _ => false)
  if (← assertTrue "desktop_connection_save_and_disk_reload" connOk) then passed := passed + 1

  let _ ← dispatchRpcCommand stDiskRef "diagnostics_append" (.obj #[
    ("lines", .arr #[.str "{\"ts\":1,\"kind\":\"ok\"}", .str "bad\nmultiline"])
  ])
  let logsDir := System.FilePath.mk tmpStateDir / "logs"
  let logEntries ← if (← logsDir.pathExists) then logsDir.readDir else pure #[]
  total := total + 1
  let mut diagOk := false
  if let #[firstLog] := logEntries then
    let content ← IO.FS.readFile firstLog.path
    diagOk := content == "{\"ts\":1,\"kind\":\"ok\"}\n"
  if (← assertTrue "diagnostics_append_writes_single_line_jsonl" diagOk) then passed := passed + 1

  let idRes1 ← dispatchRpcCommand stDiskRef "local_machine_identity" (.obj #[])
  let idRes2 ← dispatchRpcCommand stReloadRef "local_machine_identity" (.obj #[])
  let metricsRes ← dispatchRpcCommand stDiskRef "local_machine_metrics" (.obj #[])
  total := total + 1
  let idAndMetricsOk :=
    (match idRes1, idRes2 with
     | .ok (.str s1), .ok (.str s2) => !s1.isEmpty && s1 == s2
     | _, _ => false) &&
    (match metricsRes with
     | .ok jv =>
       (jv.fieldNat? "memory_total").isSome &&
       (jv.fieldNat? "memory_used").isSome &&
       (jv.fieldArr? "consumers").isSome
     | _ => false)
  if (← assertTrue "local_machine_identity_string_and_metrics_schema" idAndMetricsOk) then passed := passed + 1
  try IO.FS.removeDirAll tmpStateDir catch _ => pure ()

  IO.println s!"orb-locald-test: {passed}/{total} checks passed"
  return if passed == total then 0 else 1
