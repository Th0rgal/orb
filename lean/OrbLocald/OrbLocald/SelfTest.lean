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

  -- 1. Command table size (88 desktop commands + plugin:app|version = 89)
  total := total + 1
  if (← assertEq "desktop_command_count" supportedDesktopCommands.size 89) then passed := passed + 1

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

  let txCustomRes ← dispatchRpcCommand stRef "transport_bridge_configure" (.obj #[("apiUrl", .str "https://agent-backend-dev.thomas.md/")])
  total := total + 1
  let txCustomOk := match txCustomRes with
    | .ok jv =>
      jv.fieldStr? "configured_target" == some "https://agent-backend-dev.thomas.md" &&
      (match jv.fieldArr? "failover_origins" with
       | some #[.str o0, .str o1, .str o2] =>
         o0 == "https://agent-backend-dev.thomas.md" &&
         o1 == "https://orbcore.thomas.md" &&
         o2 == "https://agent-backend.thomas.md"
       | _ => false)
    | .error _ => false
  if (← assertTrue "transport_bridge_configure_updates_target_and_candidates" txCustomOk) then passed := passed + 1

  total := total + 1
  if (← assertEq "candidate_origins_standalone" (candidateOriginsFor "https://custom-core.example.org/") #["https://custom-core.example.org"]) then passed := passed + 1

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
  let bioStatusRes ← dispatchRpcCommand stDiskRef "biometric_status" (.obj #[])
  total := total + 1
  let bioStatusOk := match bioStatusRes with
    | .ok jv =>
      jv.fieldBool? "available" == some true &&
      jv.fieldStr? "kind" == some "touch_id" &&
      jv.fieldStr? "label" == some "Touch ID"
    | _ => false
  if (← assertTrue "biometric_status_touch_id_schema" bioStatusOk) then passed := passed + 1

  -- 14. `#1497` + `#1553` local cyber capabilities, invocable skills precedence, and fail-closed launch gates
  let cyberCapRes ← dispatchRpcCommand stDiskRef "local_agents_cyber_capabilities" (.obj #[])
  total := total + 1
  let cyberCapOk := match cyberCapRes with | .ok (.num "2") => true | _ => false
  if (← assertTrue "local_agents_cyber_capabilities_supported_2" cyberCapOk) then passed := passed + 1

  let homeRoot := System.FilePath.mk tmpStateDir / "fake-home"
  let projRoot := System.FilePath.mk tmpStateDir / "fake-repo"
  IO.FS.createDirAll (homeRoot / ".codex" / "skills" / "shared-skill")
  IO.FS.createDirAll (homeRoot / ".codex" / "skills" / "global-only")
  IO.FS.createDirAll (projRoot / ".agents" / "skills" / "shared-skill")
  IO.FS.writeFile (homeRoot / ".codex" / "skills" / "shared-skill" / "SKILL.md") "Global fallback description.\n"
  IO.FS.writeFile (homeRoot / ".codex" / "skills" / "global-only" / "SKILL.md") "---\ndescription: \"Global helper\"\n---\nBody\n"
  IO.FS.writeFile (projRoot / ".agents" / "skills" / "shared-skill" / "SKILL.md") "---\ndescription: \"Project override\"\n---\nBody\n"

  let skillsFound ← invocableSkillsIn homeRoot projRoot "codex"
  total := total + 1
  let skillsPrecOk := match skillsFound with
    | .ok #[s0, s1] =>
      s0.name == "global-only" && s0.description == some "Global helper" &&
      s1.name == "shared-skill" && s1.description == some "Project override"
    | _ => false
  if (← assertTrue "invocable_skills_project_precedence_and_frontmatter" skillsPrecOk) then passed := passed + 1

  let selOk ← selectLocalSkillsIn homeRoot projRoot "codex" "please run /skill:shared-skill and /skill:shared-skill"
  let selMissing ← selectLocalSkillsIn homeRoot projRoot "codex" "run /skill:missing-skill"
  let selBadId ← selectLocalSkillsIn homeRoot projRoot "codex" "run /skill:../escape"
  total := total + 1
  let localSkillGateOk :=
    (match selOk with
      | .ok sel =>
        match sel with
        | #[("shared-skill", _, 2)] =>
          let dir := withLocalSkillDirective "please run /skill:shared-skill" sel
          (dir.splitOn "Selected skills (load before performing the current request):").length == 2 &&
          (dir.splitOn "SKILL.md").length == 2
        | _ => false
      | _ => false) &&
    selMissing.isOk.not &&
    selBadId.isOk.not
  if (← assertTrue "select_local_skills_dedups_and_rejects_missing_or_invalid" localSkillGateOk) then passed := passed + 1

  total := total + 1
  let localCodexGateOk :=
    (validateLocalCodexLaunch "/goal ship it" "gpt-6.1-sol" "automatic" false).isOk &&
    (validateLocalCodexLaunch "/goal ship it" "gpt-6.1-sol" "daybreak" false).isOk.not &&
    (validateLocalCodexLaunch "/goal" "gpt-6.1-sol" "automatic" false).isOk.not &&
    (validateLocalCodexLaunch "audit" "gpt-daybreak-blue-latest" "automatic" false).isOk.not &&
    (validateLocalCodexLaunch "audit" "gpt-6.1-sol" "daybreak" false).isOk
  if (← assertTrue "validate_local_codex_launch_gates_goal_and_cyber" localCodexGateOk) then passed := passed + 1

  -- 15. Persistent `orb-signer serve` protocol (`approval_sign` + `grace_until` reuse + `cancelled` code 2)
  let mockSignerPath := System.FilePath.mk tmpStateDir / "mock-orb-signer.sh"
  let countPath := System.FilePath.mk tmpStateDir / "mock-signer-spawns.txt"
  let mockScript :=
    "#!/bin/sh\n" ++
    "cmd=\"$1\"\n" ++
    "if [ \"$cmd\" = \"public\" ]; then echo '{\"public_key\":\"MOCK_PUB_KEY\"}'; exit 0; fi\n" ++
    "if [ \"$cmd\" = \"create\" ]; then echo '{\"public_key\":\"MOCK_CREATED_KEY\"}'; exit 0; fi\n" ++
    "if [ \"$cmd\" = \"serve\" ]; then\n" ++
    s!"  echo spawn >> \"{countPath}\"\n" ++
    "  while IFS= read -r line; do\n" ++
    "    if [ \"$line\" = \"Q0FOQ0VM\" ]; then\n" ++
    "      echo '{\"error\":\"User cancelled\",\"code\":\"2\"}'\n" ++
    "    else\n" ++
    "      echo '{\"signature\":\"MOCK_SIG_OK\",\"grace_until\":\"4102444800\"}'\n" ++
    "    fi\n" ++
    "  done\n" ++
    "  exit 0\n" ++
    "fi\n" ++
    "exit 1\n"
  IO.FS.writeFile mockSignerPath mockScript
  let _ ← OrbBin.PosixExt.chmod mockSignerPath.toString 0o700
  let stSignRef ← IO.mkRef ({
    launchToken := validTok,
    orbStateDir := tmpStateDir,
    homeDir := tmpStateDir,
    approvalKeyPath := (System.FilePath.mk tmpStateDir / "key.bin").toString,
    hostOs := "macos",
    signerBin? := some mockSignerPath.toString
  } : LocaldState)
  let signRes1 ← dispatchRpcCommand stSignRef "approval_sign" (.obj #[("payload", .str goodPayload)])
  let signRes2 ← dispatchRpcCommand stSignRef "approval_sign" (.obj #[("payload", .str goodPayload)])
  let graceAfterSign ← dispatchRpcCommand stSignRef "approval_grace_until" (.obj #[])
  let cancelRes ← dispatchRpcCommand stSignRef "approval_sign" (.obj #[("payload", .str "CANCEL")])
  let graceAfterCancel ← dispatchRpcCommand stSignRef "approval_grace_until" (.obj #[])
  let spawnLines ← if (← countPath.pathExists) then IO.FS.readFile countPath else pure ""
  let spawnCount := ((spawnLines.splitOn "\n").filter (fun s => !s.trimAscii.toString.isEmpty)).length
  let _ ← dispatchRpcCommand stSignRef "set_approval_grace" (.obj #[("secs", JVal.nat 0)])
  total := total + 1
  let signerServeOk :=
    (match signRes1, signRes2 with | .ok (.str "MOCK_SIG_OK"), .ok (.str "MOCK_SIG_OK") => true | _, _ => false) &&
    (match graceAfterSign with | .ok (.num "4102444800") => true | _ => false) &&
    (match cancelRes with | .error "cancelled" => true | _ => false) &&
    (match graceAfterCancel with | .ok (.num "0") => true | _ => false) &&
    spawnCount == 1
  if (← assertTrue "orb_signer_serve_reuses_persistent_helper_and_propagates_grace_and_cancel" signerServeOk) then passed := passed + 1

  try IO.FS.removeDirAll tmpStateDir catch _ => pure ()

  IO.println s!"orb-locald-test: {passed}/{total} checks passed"
  return if passed == total then 0 else 1
