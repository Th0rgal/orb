import LeanSys.Auth

namespace OrbCore.ProviderUsageAndLogin

structure CliAuthFileInfo where
  fileName    : String
  fullPath    : String
  authType    : String
  email       : String
  accessToken : String
  accountId   : String
  prefixId    : String
  disabled    : Bool
  mtimeSec    : UInt64
  nativeOnly : Bool := false
  fingerprint : UInt64 := 0
  deviceToken : String := ""
  deriving Repr, Inhabited

def authTypeToProviderType (authType : String) : String :=
  match authType.toLower with
  | "codex" => "openai"
  | "claude" => "anthropic"
  | "meta" => "muse-code"
  | other => other

def providerTypeMatchesAuthType (provType authType : String) : Bool :=
  match provType.toLower, authType.toLower with
  | "anthropic", "claude" | "anthropic", "anthropic" => true
  | "openai", "codex" | "openai", "openai" => true
  | "antigravity", "antigravity" => true
  | "kimi", "kimi" => true
  | "xai", "xai" => true
  | "muse-code", "meta" | "muse-code", "muse-code" => true
  | p, a => !p.isEmpty && p == a

private def idWithoutHyphens (id : String) : String :=
  String.ofList (id.toList.filter (· != '-'))

/-- An unmatched login keeps the same identifier when another login joins,
departs, refreshes, or changes its display label. -/
private def fileDigest (file : String) := LeanSys.Auth.bytesToHexLower (LeanSys.Auth.sha256Bytes file.toUTF8)

def fileAccountId (provider file : String) : String := s!"cliproxyapi:{provider}:{fileDigest file}"

def authFileMatchesRowId (f : CliAuthFileInfo) (id : String) (member : Bool := false) : Bool :=
  !id.isEmpty && (
    let fileId := fileAccountId (authTypeToProviderType f.authType) f.fileName
    if member then f.prefixId == id || id == fileId else
      f.prefixId == id || f.accountId == id || id == fileId ||
      (!f.authType.isEmpty && f.prefixId == s!"orb-{f.authType}-{idWithoutHyphens id}") ||
      (!f.authType.isEmpty && f.fileName == s!"{f.authType}-sandboxed-{id}.json"))

/-- Sidecar model namespace for an OAuth file that originally had no prefix. -/
def vpnModelPrefix (file : String) : String := "orb-vpn-" ++ fileDigest file

/-- Explicit metadata must resolve uniquely. In particular a stale filename
or conflicting identity hints must never select the first login of the type. -/
def matchCredential? (files : Array CliAuthFileInfo) (account : String) (member : Bool)
    (file refreshFile linkedId email : String) (legacySingleton : Bool) : Option CliAuthFileInfo := Id.run do
  if account.isEmpty then return none
  let named := if !file.isEmpty then file else if refreshFile.endsWith ".json" then refreshFile else ""
  let own := files.filter (fun f => authFileMatchesRowId f account member)
  let mut possible := if own.isEmpty then files else own
  if member then possible := own
  else
    if !named.isEmpty then
      let byName := possible.filter (fun f => f.fileName == named)
      if !byName.isEmpty then possible := byName
      else if own.isEmpty && linkedId.isEmpty && email.isEmpty then return none
    if !linkedId.isEmpty then possible := possible.filter (fun f => authFileMatchesRowId f linkedId false)
    if !email.isEmpty then possible := possible.filter (fun f => f.email.toLower == email.toLower)
    if own.isEmpty && named.isEmpty && linkedId.isEmpty && email.isEmpty && !legacySingleton then return none
  if possible.size == 1 then return possible[0]? else return none

end OrbCore.ProviderUsageAndLogin
