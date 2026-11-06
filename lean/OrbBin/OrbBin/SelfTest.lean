/-
  OrbBin.SelfTest: End-to-End Verification Suite (`orb-bin-test`) for Wave 1 Companion Binaries.
-/
import OrbBin.Spec
import OrbBin.MutantSuite
import OrbBin.PosixExt
import OrbBin.Json
import OrbBin.HttpClient
import OrbBin.McpCatalog
import OrbBin.StdioMcpServer
import OrbBin.FidoAgentProxyMain
import OrbBin.PrivdShared
import OrbBin.MeshCli
import OrbBin.PalomaCtlMain
import OrbBin.SandboxedMcpMain
import OrbBin.WorkspaceMcpMain
import OrbBin.DesktopMcpMain
import OrbBin.AutomationMcpMain

namespace OrbBin.SelfTest

open OrbBin.Spec
open OrbBin.PosixExt
open OrbBin.Json
open OrbBin.HttpClient
open OrbBin.StdioMcpServer
open OrbBin.FidoAgentProxy
open OrbBin.PrivdShared
open OrbBin.MeshCli
open OrbBin.PalomaCtl
open OrbBin.SandboxedMcp

private def assertEq {α : Type} [BEq α] [Repr α] (label : String) (got expected : α) : IO Unit := do
  if got != expected then
    throw <| IO.userError s!"FAIL [{label}]: got {repr got}, expected {repr expected}"
  IO.println s!"  [OK] {label}"

private def isErr {ε α : Type} : Except ε α → Bool
  | .error _ => true
  | .ok _ => false

private def assertTrue (label : String) (cond : Bool) : IO Unit := do
  if !cond then
    throw <| IO.userError s!"FAIL [{label}]: expected true"
  IO.println s!"  [OK] {label}"

def runAllTests : IO UInt32 := do
  IO.println "=== OrbBin Wave 1 Companion Binaries Self-Test ==="

  -- 1. Spec gates & framing
  assertEq "verifySshSignForward blocks unapproved SK sign"
    (verifySshSignForward 64 13 1 0 1) 0
  assertEq "verifySshSignForward admits approved SK sign"
    (verifySshSignForward 64 13 1 1 1) 1
  assertEq "verifySshSignForward admits non-SK sign without FIDO"
    (verifySshSignForward 64 13 0 0 1) 1
  assertEq "verifyMcpSecretPersistence rejects non-mcp1 token"
    (verifyMcpSecretPersistence 0 1 1 1 1) 0
  assertEq "verifyMcpSecretPersistence admits private 0600 mcp1"
    (verifyMcpSecretPersistence 1 1 1 1 1) 1
  assertEq "verifyStdioJsonRpcFrame rejects >1 MiB line"
    (verifyStdioJsonRpcFrame 1048577 1 0 8) 0
  assertEq "verifyStdioJsonRpcFrame rejects 9th concurrent slot"
    (verifyStdioJsonRpcFrame 128 1 8 8) 0
  assertEq "verifyStdioJsonRpcFrame admits valid frame"
    (verifyStdioJsonRpcFrame 128 1 7 8) 1

  -- 2. Base64, UUID v4, private 0700/0600 atomic files
  let sample := "mcp1.session-test-payload!@#".toUTF8
  let b64Std := base64Encode sample false true
  assertTrue "Base64 std round-trip" (base64Decode? b64Std == some sample)
  let b64Url := base64Encode sample true false
  assertTrue "Base64 URL-safe nopad round-trip" (base64Decode? b64Url == some sample)
  let u1 ← newUuidV4
  assertTrue "UUID v4 canonical parse" (parseUuidCanonical? u1 == some u1)

  let tmpDir := System.FilePath.mk "/tmp" / s!"orb-bin-selftest-{u1}"
  let dirRes ← ensurePrivateDir0700 tmpDir
  assertTrue "ensurePrivateDir0700 succeeds" dirRes.isOk
  let stDir ← statPath tmpDir.toString
  assertTrue "tmpDir mode is 0700" (stDir.exists_ && stDir.isDir && (stDir.mode &&& 0o777) == 0o700)
  let secFile := tmpDir / "credential"
  let wrRes ← persistScopedCredential secFile "mcp1.valid-token"
  assertTrue "persistScopedCredential accepts mcp1.*" wrRes.isOk
  let wrBad ← persistScopedCredential secFile "owner-jwt-token"
  assertTrue "persistScopedCredential rejects non-mcp1.*" (isErr wrBad)
  let stFile ← statPath secFile.toString
  assertTrue "credential mode is 0600" (stFile.exists_ && stFile.isReg && (stFile.mode &&& 0o777) == 0o600)

  -- 3. RFC 8259 JSON parser & escape round-trip
  let complexJson := "{\"a\":123,\"b\":[true,false,null,\"hello\\n\\\"world\\\"\\u0041\"],\"nested\":{\"k\":-42}}"
  match Json.parse complexJson with
  | .error e => throw <| IO.userError s!"JSON parse failed: {e}"
  | .ok parsed =>
    assertEq "JSON field a" (parsed.fieldNat? "a") (some 123)
    let reparsed := Json.parse (renderCompact parsed)
    match reparsed with
    | .ok rp => assertEq "JSON renderCompact round-trip" rp parsed
    | .error e => throw <| IO.userError s!"JSON reparse failed: {e}"

  -- 4. SSH SK sign request parser (`fido-agent-proxy`)
  let ktBytes := "sk-ssh-ed25519@openssh.com".toUTF8
  let mkSshStr := fun (bs : ByteArray) =>
    let n := bs.size.toUInt32
    ByteArray.mk #[((n >>> 24) &&& 0xFF).toUInt8, ((n >>> 16) &&& 0xFF).toUInt8, ((n >>> 8) &&& 0xFF).toUInt8, (n &&& 0xFF).toUInt8] ++ bs
  let keyBlob := mkSshStr ktBytes ++ mkSshStr (ByteArray.mk #[1, 2, 3, 4])
  let signPayload := ByteArray.mk #[13] ++ mkSshStr keyBlob ++ mkSshStr "challenge".toUTF8 ++ ByteArray.mk #[0, 0, 0, 0]
  match parseSignRequestKeyInfo? signPayload with
  | none => throw <| IO.userError "Failed parsing SSH_AGENTC_SIGN_REQUEST"
  | some (kt, fp) =>
    assertEq "Parsed SK key type" kt "sk-ssh-ed25519@openssh.com"
    assertTrue "Parsed SK fingerprint prefix" (fp.startsWith "SHA256:")
    assertTrue "isSkKeyType true" (isSkKeyType kt)

  -- 5. `orb-privd` / `orb-sudo` policy & `Orb.Kernel.privdCommandStep`
  assertTrue "isStrictSemver accepts 1.3.0" (isStrictSemver "1.3.0")
  assertTrue "isStrictSemver rejects 1.3.0-beta;rm" (!isStrictSemver "1.3.0-beta;rm")
  assertEq "hasUnsafeClientEnv blocks LD_PRELOAD"
    (hasUnsafeClientEnv #[("LD_PRELOAD", "/tmp/evil.so")]) 1
  assertEq "hasUnsafeClientEnv allows LANG"
    (hasUnsafeClientEnv #[("LANG", "C.UTF-8")]) 0
  assertEq "checkScopeRestrictions ops_read journalctl == 1793"
    (← checkScopeRestrictions "ops_read" #[] #["journalctl", "-u", "orb-core", "-n", "20", "--no-pager"] (some "/var/log")).toOption
    (some 1793)
  assertEq "checkScopeRestrictions service_deploy systemctl == 1794"
    (← checkScopeRestrictions "service_deploy" #["orb-core"] #["systemctl", "restart", "orb-core.service"] (some "/root")).toOption
    (some 1794)
  assertTrue "checkScopeRestrictions rejects metachar"
    (isErr (← checkScopeRestrictions "ops_read" #[] #["ps; id"] (some "/root")))
  assertTrue "checkScopeRestrictions rejects cwd traversal"
    (isErr (← checkScopeRestrictions "root_exec" #[] #["id"] (some "/var/lib/../../etc")))
  assertTrue "checkScopeRestrictions rejects wrong deploy unit"
    (isErr (← checkScopeRestrictions "service_deploy" #["orb-core"] #["systemctl", "restart", "postgres.service"] (some "/root")))
  assertTrue "checkScopeRestrictions rejects untrusted exe path"
    (isErr (← checkScopeRestrictions "ops_read" #[] #["/attacker-controlled/ps"] (some "/root")))

  -- 6. `palomactl` diagnostic clustering & PR gate recommendation
  let clustered := clusterDiagnostics "Foo.lean:12:4: error: type mismatch\nFoo.lean:99:1: error: type mismatch\nBar.lean:3:2: warning: unused\n"
  match clustered.asArr? with
  | none => throw <| IO.userError "clusterDiagnostics expected JSON array"
  | some clsArr =>
    assertEq "clusterDiagnostics unique_clusters" clsArr.size 2
    assertEq "clusterDiagnostics top count" (clsArr[0]!.fieldNat? "count") (some 2)
  assertEq "prGateRecommendation 8" (prGateRecommendation 8) "ready_for_review_or_merge"

  -- 7. `sandboxed-mcp` catalogue, overlays, ACP injection & Antigravity lock
  for (role, expectedMin) in [("executor", 40), ("coordinator", 70), ("operator", 85)] do
    let some catTxt := OrbBin.McpCatalog.catalogPrettyJsonForRole role
      | throw <| IO.userError s!"Missing catalog for {role}"
    match Json.parse catTxt with
    | .ok (.arr tools) =>
      assertTrue s!"Catalog {role} count ({tools.size} >= {expectedMin})" (tools.size ≥ expectedMin)
    | _ => throw <| IO.userError s!"Failed parsing catalog JSON for {role}"

  let srvDummy := JVal.obj #[("name", .str "sandboxed"), ("command", .str "/bin/sandboxed-mcp"), ("args", .arr #[]), ("env", .arr #[])]
  let acpNew := "{\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":\"/work\",\"mcpServers\":[{\"name\":\"other\"},{\"name\":\"sandboxed\",\"command\":\"stale\"}]}}".toUTF8
  match transformGrokAcpFrame acpNew srvDummy with
  | .error e => throw <| IO.userError s!"ACP frame transform failed: {e}"
  | .ok outBytes =>
    let .ok j := Json.parseBytes outBytes | throw <| IO.userError "ACP output invalid JSON"
    let some srvs := (j.fieldOrNull "params").fieldArr? "mcpServers" | throw <| IO.userError "missing mcpServers"
    assertEq "ACP preserved sibling + injected sandboxed" srvs.size 2
    assertEq "ACP first server is other" (srvs[0]!.fieldStr? "name") (some "other")
    assertEq "ACP second server is sandboxed" (srvs[1]!.fieldStr? "command") (some "/bin/sandboxed-mcp")

  let agyWs := tmpDir / "agy-ws"
  IO.FS.createDirAll (agyWs / ".agents")
  let origCfg := "{\"mcpServers\":{\"user\":{\"command\":\"user-server\"}}}".toUTF8
  IO.FS.writeBinFile (agyWs / ".agents" / "mcp_config.json") origCfg
  let agyInstallCfg := JVal.obj #[("mcpServers", .obj #[("sandboxed", .obj #[("command", .str "scoped-srv")])])]
  match (← installAntigravityOverlay agyWs agyInstallCfg) with
  | .error e => throw <| IO.userError s!"Antigravity overlay install failed: {e}"
  | .ok ov =>
    let secondAttempt ← installAntigravityOverlay agyWs agyInstallCfg
    assertTrue "Antigravity flock blocks concurrent run" (isErr secondAttempt)
    restoreAntigravityOverlay ov
    let restored ← IO.FS.readBinFile (agyWs / ".agents" / "mcp_config.json")
    assertTrue "Antigravity overlay restores exact original bytes" (restored == origCfg)

  -- 8. Companion MCP tool counts + HS256 JWT minting
  assertEq "workspace-mcp tool count" OrbBin.WorkspaceMcp.toolDefinitions.size 8
  assertEq "desktop-mcp tool count" OrbBin.DesktopMcp.toolDefinitions.size 9
  assertEq "automation-manager-mcp tool count" OrbBin.AutomationMcp.toolDefinitions.size 7
  let jwt ← OrbBin.AutomationMcp.mintServiceJwt "unit-test-secret"
  assertEq "HS256 JWT has 3 dot-separated segments" (jwt.splitOn ".").length 3

  -- 9. `palomactl` snapshot-directory models, RFC3339 validation & task-based `dispatch-plan`
  let snapDir := tmpDir / "snaps"
  IO.FS.createDirAll snapDir
  let snapBase := JVal.obj #[
    ("schema_version", .nat 1),
    ("provider_id", .str "openai"),
    ("access_profile", .str "api_key"),
    ("source", .str "curated"),
    ("completeness", .str "complete"),
    ("models", .arr #[
      .obj #[("id", .str "gpt-5"), ("name", .str "GPT-5")],
      .obj #[("id", .str "gpt-4o"), ("name", .str "GPT-4o")]
    ])
  ]
  IO.FS.writeFile (snapDir / "openai-api_key.json") (renderPretty snapBase ++ "\n")
  let loadedSnaps ← loadSnapshotDir snapDir
  assertTrue "loadSnapshotDir validates matching filename" loadedSnaps.isOk
  let snapPartial := JVal.obj #[
    ("schema_version", .nat 1),
    ("provider_id", .str "openai"),
    ("access_profile", .str "api_key"),
    ("source", .str "discovery"),
    ("observed_at", .str "2026-11-06T08:00:00Z"),
    ("completeness", .str "partial"),
    ("models", .arr #[
      .obj #[("id", .str "gpt-5-mini"), ("name", .str "GPT-5 Mini")]
    ])
  ]
  match mergeSnapshotJson snapBase snapPartial with
  | .error e => throw <| IO.userError s!"mergeSnapshotJson failed: {e}"
  | .ok mergedSnap =>
    assertEq "partial snapshot merge preserves existing + adds incoming"
      ((mergedSnap.fieldArr? "models").getD #[]).size 3
  let diffJ := snapshotDiffJson snapBase snapPartial
  assertEq "partial diff marks removals non-authoritative"
    (diffJ.fieldBool? "removals_authoritative") (some false)

  IO.FS.writeFile (snapDir / "mismatch-name.json") (renderPretty snapBase ++ "\n")
  let badSnapLoad ← loadSnapshotDir snapDir
  assertTrue "loadSnapshotDir rejects filename/provider mismatch" (isErr badSnapLoad)

  assertTrue "parseRfc3339Epoch? accepts UTC Z" (parseRfc3339Epoch? "2099-01-01T00:00:00Z").isSome
  assertTrue "parseRfc3339Epoch? accepts fractional UTC Z" (parseRfc3339Epoch? "2099-01-01T00:00:00.125Z").isSome
  assertTrue "parseRfc3339Epoch? accepts +02:00" (parseRfc3339Epoch? "2099-01-01T02:00:00+02:00").isSome
  assertTrue "parseRfc3339Epoch? rejects invalid timestamp" (parseRfc3339Epoch? "not-a-timestamp").isNone
  assertTrue "parseRfc3339Epoch? rejects non-digit fractional suffix" (parseRfc3339Epoch? "2099-01-01T00:00:00.garbageZ").isNone
  assertTrue "parseRfc3339Epoch? rejects empty fractional suffix" (parseRfc3339Epoch? "2099-01-01T00:00:00.Z").isNone
  assertTrue "parseRfc3339Epoch? rejects double dot fractional suffix" (parseRfc3339Epoch? "2099-01-01T00:00:00.1.2Z").isNone

  assertTrue "resolveTrustedBinary? resolves /bin/sh (even when symlinked)"
    (← resolveTrustedBinary? "/bin/sh").isSome
  assertTrue "resolveTrustedBinary? resolves bare sh"
    (← resolveTrustedBinary? "sh").isSome

  let palomaWs := tmpDir / "paloma-ws"
  IO.FS.createDirAll (palomaWs / ".paloma" / "fixtures")
  IO.FS.createDirAll (palomaWs / ".paloma" / "modes")
  IO.FS.createDirAll (palomaWs / ".paloma" / "projects")
  IO.FS.createDirAll (palomaWs / "docs")
  IO.FS.writeFile (palomaWs / ".paloma" / "modes" / "orb.json")
    "{\"project\":\"orb\",\"mode\":\"conservative\",\"until\":\"2099-01-01T00:00:00Z\"}\n"
  IO.FS.writeFile (palomaWs / ".paloma" / "fixtures" / "tasks.json")
    "[{\"id\":\"t-exp\",\"project\":\"orb\",\"status\":\"ready\",\"intent\":\"explore alternative proof\"},{\"id\":\"t-std\",\"project\":\"orb\",\"status\":\"ready\",\"intent\":\"fix bug\"}]\n"
  match (← buildDispatchPlanJson palomaWs "orb") with
  | .error e => throw <| IO.userError s!"buildDispatchPlanJson failed: {e}"
  | .ok plan =>
    let disp := (plan.fieldArr? "dispatch").getD #[]
    assertEq "conservative mode dispatches only 1 safe task" disp.size 1
    assertEq "conservative mode selects standard task over exploration"
      (disp[0]!.fieldStr? "task_id") (some "t-std")
    assertEq "conservative mode sets null reason when safe task is dispatched"
      (plan.field? "reason") (some .null)

  -- Local tracker doc scan + drift detection (`ShortMissionId`, `StaleMissionRef`, `LiveMismatch`, `PrListedOpenButMerged`)
  IO.FS.writeFile (palomaWs / ".paloma" / "fixtures" / "missions.json")
    "[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"status\":\"active\"}]\n"
  IO.FS.writeFile (palomaWs / ".paloma" / "fixtures" / "pr-lfglabs-dev__verity-103.json")
    "{\"state\":\"closed\",\"draft\":false,\"merged\":true,\"checks\":[]}\n"
  IO.FS.writeFile (palomaWs / ".paloma" / "projects" / "verity.md")
    "Repo: lfglabs-dev/verity\nmission abc1234\nmission: 22222222-2222-4222-8222-222222222222\nmission: 11111111-1111-4111-8111-111111111111\nstatus: blocked\nPR #103 open\n"
  IO.FS.writeFile (palomaWs / "docs" / "PALOMA_EXTRA.md")
    "- [x]UX1: wire feature\n"
  let localSt ← buildLocalState palomaWs
  let docArr := (localSt.fieldArr? "project_docs").getD #[]
  let driftArr := (localSt.fieldArr? "drift").getD #[]
  assertEq "scanProjectDocs finds .paloma/projects + docs/PALOMA_*.md" docArr.size 2
  assertTrue "detectLocalDrift finds short_mission_id"
    (driftArr.any (fun d => d.fieldStr? "kind" == some "short_mission_id"))
  assertTrue "detectLocalDrift finds stale_mission_ref"
    (driftArr.any (fun d => d.fieldStr? "kind" == some "stale_mission_ref"))
  assertTrue "detectLocalDrift finds live_mismatch"
    (driftArr.any (fun d => d.fieldStr? "kind" == some "live_mismatch"))
  assertTrue "detectLocalDrift finds pr_listed_open_but_merged"
    (driftArr.any (fun d => d.fieldStr? "kind" == some "pr_listed_open_but_merged"))
  let parsedChecklist := parseTrackerMarkdown "- [x] A1: ship feature\n- [ ] no code item here\n"
  assertEq "parseTrackerMarkdown item count" parsedChecklist.size 2
  assertEq "parseTrackerMarkdown normalizes code key" parsedChecklist[0]!.key "a1"
  assertEq "parseTrackerMarkdown derives title key" parsedChecklist[1]!.key "no-code-item-here"

  -- 10. `StdioMcpServer` cancel + reused ID ownership & 8-slot `inFlight` retention
  let inPath := tmpDir / "rpc-in.jsonl"
  let outPath := tmpDir / "rpc-out.jsonl"
  let rpcFrames :=
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"slow\"}\n" ++
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}\n" ++
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"fast\"}\n"
  IO.FS.writeFile inPath rpcFrames
  IO.FS.writeFile outPath ""
  let inFd ← match (← LeanSys.Posix.openFd inPath.toString 0 0 0) with
    | .ok fd => pure (Int32.ofBitVec (BitVec.ofNat 32 fd.raw.toNat))
    | .error e => throw <| IO.userError s!"open inPath: {e}"
  let outFd ← match (← LeanSys.Posix.openFd outPath.toString 4 0 0) with
    | .ok fd => pure (Int32.ofBitVec (BitVec.ofNat 32 fd.raw.toNat))
    | .error e => throw <| IO.userError s!"open outPath: {e}"
  serveFd inFd outFd (fun req cancelRef => do
    let m := (req.fieldStr? "method").getD ""
    let idv := req.fieldOrNull "id"
    if m == "slow" then
      IO.sleep 60
      let _ ← cancelRef.get
      return jsonRpcSuccess idv (.str "stale-slow")
    else
      IO.sleep 15
      return jsonRpcSuccess idv (.str "fresh-fast"))
  closeFdRaw inFd
  closeFdRaw outFd
  let outLines := ((← IO.FS.readFile outPath).splitOn "\n").filter (!·.trimAscii.toString.isEmpty)
  assertEq "cancel + reused ID emits exactly 2 responses (-32800 + fresh-fast)" outLines.length 2
  assertTrue "reused ID never emits stale-slow response" (!outLines.any (fun l => (l.splitOn "stale-slow").length > 1))
  assertTrue "reused ID emits fresh-fast response" (outLines.any (fun l => (l.splitOn "fresh-fast").length > 1))

  try IO.FS.removeDirAll tmpDir catch _ => pure ()
  IO.println "=== ALL ORB-BIN WAVE 1 SELF-TESTS PASSED ==="
  return 0

end OrbBin.SelfTest
