namespace OrbBin.WorkspaceFilePolicy

/-- Credential files and private directories excluded from both workspace file browsers. -/
def privateNames : Array String := #[
  ".env", ".ssh", ".aws", ".gnupg", ".git", "credentials.json",
  ".credentials.json", "auth.json", "antigravity-oauth-token",
  "id_rsa", "id_ed25519", ".git-credentials"
]

def deniedSegment (raw : String) : Bool :=
  let name := raw.toLower
  privateNames.contains name || name.startsWith ".env." || name.endsWith ".pem" || name.endsWith ".key"

end OrbBin.WorkspaceFilePolicy
