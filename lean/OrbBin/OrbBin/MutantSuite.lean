/-
  OrbBin.MutantSuite: Realistic Semantic Mutants Killed by `OrbBin.Spec` (`0 import Lean`, `0 sorryAx`).
-/
import OrbBin.Spec

namespace OrbBin.MutantSuite

open OrbBin.Spec

/-- Mutant 1 (`fido-agent-proxy`): Weakens the FIDO Touch approval check on
    `sk-ssh-ed25519@openssh.com` `SSH_AGENTC_SIGN_REQUEST` (`msgType == 13 && isSkKey == 1`)
    from `fidoApproved == 1` to `fidoApproved ≤ 1` (admitting unapproved `0`). -/
@[inline]
def m1_fido_allowUnapprovedSkSign
    (frameLen : UInt32) (msgType isSkKey fidoApproved hasUpstream : UInt8) : UInt8 :=
  let frameOk := 1 ≤ frameLen && frameLen ≤ 262144
  let upstreamOk := hasUpstream == 1
  let signOk :=
    if msgType == 13 && isSkKey == 1 then fidoApproved ≤ 1
    else true
  if frameOk && upstreamOk && signOk then 1 else 0

theorem kill_m1_fido_allowUnapprovedSkSign :
    m1_fido_allowUnapprovedSkSign 128 13 1 0 1 ≠
      verifySshSignForward 128 13 1 0 1 := by
  decide

/-- Mutant 2 (`sandboxed-mcp`): Weakens `hasMcp1Prefix == 1` to `hasMcp1Prefix ≤ 1`,
    persisting an unscoped owner login token (`hasMcp1Prefix == 0`) into the renewable credential file. -/
@[inline]
def m2_mcp_persistOwnerToken
    (hasMcp1Prefix dirIsPrivate dirNotSymlink fileModeIs0600 safeEnvName : UInt8) : UInt8 :=
  if hasMcp1Prefix ≤ 1 && dirIsPrivate == 1 && dirNotSymlink == 1 &&
     fileModeIs0600 == 1 && safeEnvName == 1 then 1 else 0

theorem kill_m2_mcp_persistOwnerToken :
    m2_mcp_persistOwnerToken 0 1 1 1 1 ≠
      verifyMcpSecretPersistence 0 1 1 1 1 := by
  decide

/-- Mutant 3 (`sandboxed-mcp` stdio JSON-RPC): Admits an unbounded `> 1 MiB` JSON-RPC line
    instead of draining and returning `-32600` (`MAX_STDIO_FRAME_BYTES = 1048576`). -/
@[inline]
def m3_jsonrpc_acceptOversizeFrame
    (lineBytes : UInt64) (nonEmptyTrim : UInt8) (inFlight maxInFlight : UInt32) : UInt8 :=
  if 1 ≤ lineBytes && nonEmptyTrim == 1 &&
     1 ≤ maxInFlight && maxInFlight ≤ 64 && inFlight < maxInFlight then 1 else 0

theorem kill_m3_jsonrpc_acceptOversizeFrame :
    m3_jsonrpc_acceptOversizeFrame 1048577 1 0 8 ≠
      verifyStdioJsonRpcFrame 1048577 1 0 8 := by
  decide

end OrbBin.MutantSuite
