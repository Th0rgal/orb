/-
  OrbCore.MutantSuite: Adversarial Mutant Kills (`>= 3` domain mutants, `0 sorryAx`)
  for Wave 4 `OrbCore.Spec`.
-/
import OrbCore.Spec

namespace OrbCore.MutantSuite

open OrbCore.Spec

/-- Mutant 1: Allows `DEV_MODE=true` on a non-loopback `0.0.0.0` host even when `allowInsecureRemoteDevAuth == 0`! -/
def verifyCoreStartupConfigMutantRemoteDev
    (devMode isLoopbackHost allowInsecureRemoteDevAuth isPlaceholderSecret : UInt8)
    (jwtSecretLen : UInt32) (passwordConfigured : UInt8) : UInt8 :=
  if devMode ≤ 1 && isLoopbackHost ≤ 1 && allowInsecureRemoteDevAuth ≤ 1 &&
     isPlaceholderSecret ≤ 1 && passwordConfigured ≤ 1 &&
     ((devMode == 0 && jwtSecretLen ≥ 32 && jwtSecretLen ≤ 4096 &&
       isPlaceholderSecret == 0 && passwordConfigured == 1) ||
      devMode == 1) then 1 else 0

/-- Mutant 2: Accepts `/api/console/ws` upgrade when `hasJwtSubproto == 1` without verifying the JWT signature (`jwtVerified`)! -/
def verifyConsoleWsAuthMutantUnverifiedJwt
    (hasJwtSubproto jwtVerified hasBearerHeader bearerVerified : UInt8)
    (nowEpochSec expEpochSec : UInt64) : UInt8 :=
  if nowEpochSec < expEpochSec &&
     (hasJwtSubproto == 1 || jwtVerified == 1 ||
      (hasBearerHeader == 1 && bearerVerified == 1)) then 1 else 0

/-- Mutant 3: Fails over `/v1/*` upstream stream even after response headers have already been committed (`headersCommitted == 1`)! -/
def verifyProxyFailoverStepMutantCommitted
    (attemptIdx chainLen : UInt8) (upstreamStatus : UInt32) (headersCommitted : UInt8) : UInt8 :=
  if chainLen ≥ 1 && chainLen ≤ 16 &&
     attemptIdx + 1 < chainLen &&
     headersCommitted ≤ 1 &&
     (upstreamStatus == 429 || (upstreamStatus ≥ 500 && upstreamStatus ≤ 599)) then 1 else 0

/-- Theorem 1: `verifyCoreStartupConfig` kills the non-loopback `DEV_MODE=true` remote exposure mutant
    AND agrees on valid production config. -/
theorem core_startup_kills_remote_dev_mutant :
    verifyCoreStartupConfig 1 0 0 0 64 1 ≠
      verifyCoreStartupConfigMutantRemoteDev 1 0 0 0 64 1 ∧
    verifyCoreStartupConfig 0 0 0 0 64 1 =
      verifyCoreStartupConfigMutantRemoteDev 0 0 0 0 64 1 := by
  decide

/-- Theorem 2: `verifyConsoleWsAuth` kills the unverified `jwt.<token>` WebSocket subprotocol mutant
    AND agrees on valid authenticated upgrades. -/
theorem console_ws_auth_kills_unverified_jwt_mutant :
    verifyConsoleWsAuth 1 0 0 0 1700000000 1700003600 ≠
      verifyConsoleWsAuthMutantUnverifiedJwt 1 0 0 0 1700000000 1700003600 ∧
    verifyConsoleWsAuth 1 1 0 0 1700000000 1700003600 =
      verifyConsoleWsAuthMutantUnverifiedJwt 1 1 0 0 1700000000 1700003600 := by
  decide

/-- Theorem 3: `verifyProxyFailoverStep` kills the mid-stream committed-headers failover mutant
    AND agrees when `headersCommitted == 0`. -/
theorem proxy_failover_kills_committed_headers_mutant :
    verifyProxyFailoverStep 0 3 503 1 ≠
      verifyProxyFailoverStepMutantCommitted 0 3 503 1 ∧
    verifyProxyFailoverStep 0 3 503 0 =
      verifyProxyFailoverStepMutantCommitted 0 3 503 0 := by
  decide

end OrbCore.MutantSuite
