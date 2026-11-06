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

  try IO.FS.removeDirAll tmpDir catch _ => pure ()
  IO.println "=== ALL ORB-BIN WAVE 1 SELF-TESTS PASSED ==="
  return 0

end OrbBin.SelfTest
