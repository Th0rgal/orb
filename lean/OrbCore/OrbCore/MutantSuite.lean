/-
  OrbCore.MutantSuite: Adversarial Mutant Kills (`5/5` domain gates covered, `0 sorryAx`)
  for Wave 4 `OrbCore.Spec`.
-/
import OrbCore.Spec

namespace OrbCore.MutantSuite

open OrbCore.Spec

/-- Mutant 1: Allows `DEV_MODE=true` on a non-loopback `0.0.0.0` host even when
    `allowInsecureRemoteDevAuth == 0`! -/
def verifyCoreStartupConfigMutantRemoteDev
    (devMode isLoopbackHost allowInsecureRemoteDevAuth isPlaceholderSecret : UInt8)
    (jwtSecretLen : UInt32) (passwordConfigured : UInt8) : UInt8 :=
  if devMode ≤ 1 && isLoopbackHost ≤ 1 && allowInsecureRemoteDevAuth ≤ 1 &&
     isPlaceholderSecret ≤ 1 && passwordConfigured ≤ 1 &&
     ((devMode == 0 && jwtSecretLen ≥ 32 && jwtSecretLen ≤ 4096 &&
       isPlaceholderSecret == 0 && passwordConfigured == 1) ||
      devMode == 1) then 1 else 0

/-- Mutant 2: Accepts `/api/console/ws` upgrade when `hasJwtSubproto == 1` even when
    an invalid `Authorization: Bearer` header (`hasBearerHeader == 1 && bearerVerified == 0`) is attached! -/
def verifyConsoleWsAuthMutantConflictingBearer
    (hasJwtSubproto jwtVerified hasBearerHeader bearerVerified : UInt8)
    (nowEpochSec expEpochSec : UInt64) : UInt8 :=
  if hasJwtSubproto ≤ 1 && jwtVerified ≤ 1 && hasBearerHeader ≤ 1 && bearerVerified ≤ 1 &&
     nowEpochSec < expEpochSec &&
     ((hasJwtSubproto == 1 && jwtVerified == 1) ||
      (hasBearerHeader == 1 && bearerVerified == 1)) then 1 else 0

/-- Mutant 3: Admits a concurrent machine transfer even when `activeTransferExists == 1`! -/
def verifyTransferFenceMutantIgnoreActive
    (activeTransferExists nonTerminalRunExists workspaceContended statusMovable : UInt8)
    (storedGeneration expectedGeneration : UInt64) : UInt8 :=
  if activeTransferExists ≤ 1 && nonTerminalRunExists == 0 && workspaceContended == 0 &&
     statusMovable == 1 && storedGeneration == expectedGeneration &&
     storedGeneration < 0xFFFFFFFFFFFFFFFF then 1 else 0

/-- Mutant 4: Fails over `/v1/*` upstream stream even after response headers
    have already been committed (`headersCommitted == 1`)! -/
def verifyProxyFailoverStepMutantCommitted
    (attemptIdx chainLen : UInt8) (upstreamStatus : UInt32) (headersCommitted : UInt8) : UInt8 :=
  if chainLen ≥ 1 && chainLen ≤ 16 &&
     attemptIdx < 16 && attemptIdx + 1 < chainLen &&
     headersCommitted ≤ 1 &&
     (upstreamStatus == 429 || (upstreamStatus ≥ 500 && upstreamStatus ≤ 599)) then 1 else 0

/-- Mutant 5: Admits path-traversal characters (`hasPathTraversal == 1`) in `sandboxed-sh deploy --service`! -/
def verifyDeployUnitNameMutantTraversal
    (unitCode hasPathTraversal : UInt8) (unitLen : UInt32) : UInt8 :=
  if hasPathTraversal ≤ 1 &&
     ((unitCode == 1 && unitLen ≥ 8 && unitLen ≤ 20) ||
      (unitCode == 2 && unitLen ≥ 8 && unitLen ≤ 22) ||
      (unitCode == 3 && unitLen ≥ 9 && unitLen ≤ 17)) then 1 else 0

/-- Theorem 1: `verifyCoreStartupConfig` kills the non-loopback `DEV_MODE=true` remote exposure mutant
    AND agrees on valid production config. -/
theorem core_startup_kills_remote_dev_mutant :
    verifyCoreStartupConfig 1 0 0 0 64 1 ≠
      verifyCoreStartupConfigMutantRemoteDev 1 0 0 0 64 1 ∧
    verifyCoreStartupConfig 0 0 0 0 64 1 =
      verifyCoreStartupConfigMutantRemoteDev 0 0 0 0 64 1 := by
  decide

/-- Theorem 2: `verifyConsoleWsAuth` kills the conflicting-unverified-bearer WebSocket mutant
    AND agrees on valid authenticated upgrades. -/
theorem console_ws_auth_kills_conflicting_bearer_mutant :
    verifyConsoleWsAuth 1 1 1 0 1700000000 1700003600 ≠
      verifyConsoleWsAuthMutantConflictingBearer 1 1 1 0 1700000000 1700003600 ∧
    verifyConsoleWsAuth 1 1 0 0 1700000000 1700003600 =
      verifyConsoleWsAuthMutantConflictingBearer 1 1 0 0 1700000000 1700003600 := by
  decide

/-- Theorem 3: `verifyTransferFence` kills the concurrent-active-transfer mutant
    AND agrees when all contention fences are clear. -/
theorem transfer_fence_kills_active_transfer_mutant :
    verifyTransferFence 1 0 0 1 4 4 ≠
      verifyTransferFenceMutantIgnoreActive 1 0 0 1 4 4 ∧
    verifyTransferFence 0 0 0 1 4 4 =
      verifyTransferFenceMutantIgnoreActive 0 0 0 1 4 4 := by
  decide

/-- Theorem 4: `verifyProxyFailoverStep` kills the mid-stream committed-headers failover mutant
    AND agrees when `headersCommitted == 0`. -/
theorem proxy_failover_kills_committed_headers_mutant :
    verifyProxyFailoverStep 0 3 503 1 ≠
      verifyProxyFailoverStepMutantCommitted 0 3 503 1 ∧
    verifyProxyFailoverStep 0 3 503 0 =
      verifyProxyFailoverStepMutantCommitted 0 3 503 0 := by
  decide

/-- Theorem 5: `verifyDeployUnitName` kills the path-traversal mutant
    AND agrees on valid unit names without traversal. -/
theorem deploy_unit_kills_traversal_mutant :
    verifyDeployUnitName 1 1 12 ≠
      verifyDeployUnitNameMutantTraversal 1 1 12 ∧
    verifyDeployUnitName 1 0 12 =
      verifyDeployUnitNameMutantTraversal 1 0 12 := by
  decide

/-- Mutant 6: Ignores per-model concurrency cap (`modelConcCap`) whenever account concurrency is uncapped (`acctConcCap == 0`)! -/
def verifyProviderPacingAdmissionMutantIgnoreModelConc
    (acctRpmCap acctConcCap modelRpmCap modelConcCap : UInt32)
    (acctRpmUsed acctInflight modelRpmUsed modelInflight : UInt32) : UInt8 :=
  if singleCapAdmitted acctRpmCap 100000 acctRpmUsed &&
     singleCapAdmitted acctConcCap 1024 acctInflight &&
     singleCapAdmitted modelRpmCap 100000 modelRpmUsed &&
     (acctConcCap == 0 || singleCapAdmitted modelConcCap 1024 modelInflight) then 1 else 0

/-- Theorem 6: `verifyProviderPacingAdmission` kills the per-model concurrency bypass mutant
    AND agrees when per-model in-flight load has headroom (`1 < 2`). -/
theorem provider_pacing_kills_model_concurrency_mutant :
    verifyProviderPacingAdmission 300 0 0 2 2 2 2 2 ≠
      verifyProviderPacingAdmissionMutantIgnoreModelConc 300 0 0 2 2 2 2 2 ∧
    verifyProviderPacingAdmission 300 0 0 2 2 1 2 1 =
      verifyProviderPacingAdmissionMutantIgnoreModelConc 300 0 0 2 2 1 2 1 := by
  decide

end OrbCore.MutantSuite
