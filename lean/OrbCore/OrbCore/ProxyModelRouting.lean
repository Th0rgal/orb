/-
  Model-name admission from the retired Rust proxy. Persisted ids are open-ended;
  display names are not aliases. These pure rules do not attest credentials,
  protocol support, account health, or successful provider execution.
-/
import OrbCore.Proxy

namespace OrbCore.ProxyModelRouting
open OrbCore.Proxy OrbBin.Json

/-- Exact id wins, then one exact lowercase `builtin/` compatibility spelling.
    Do not trim, case-fold, match display names, or discard arbitrary namespaces. -/
def storedChain? (chains : Array RoutingChain) (requested : String) : Option RoutingChain :=
  (chains.find? (fun c => c.id == requested)).orElse fun _ =>
    let candidate :=
      if requested.startsWith "builtin/" && requested.length > 8 then
        (requested.drop 8).toString
      else s!"builtin/{requested}"
    chains.find? (fun c => c.id == candidate)

/-- Provider aliases are protocol identifiers, not CLIProxy auth-file aliases. -/
def providerId? (providerPrefix : String) : Option String :=
  match providerPrefix with
  | "codex" => some "openai"
  | "gemini" => some "google"
  | "meta" => some "muse"
  | "anthropic" | "openai" | "google" | "antigravity" | "amazon-bedrock"
  | "azure" | "open-router" | "mistral" | "groq" | "xai" | "deep-infra"
  | "cerebras" | "cohere" | "together-ai" | "perplexity" | "github-copilot"
  | "zai" | "minimax" | "muse" | "muse-code" | "kimi" | "custom" => some providerPrefix
  | _ => none

def customProviderName (name : String) : String :=
  String.ofList ((name.toList.filter (fun c => c.isAlphanum || c == '_' || c == '-')).map
    (fun c => if c == '-' then '_' else c.toLower))

private def googleModel (model : String) : String :=
  match model.trimAscii.toString with
  | "agy-demo" | "gemini-4-argon-eap" => "gemini-4-argon"
  | other => other

/-- Return the provider and concrete model, retaining everything after the first
    slash. Custom names require an advertised exact model. Bare gpt/claude are
    native-protocol conveniences, not chat-completion aliases. -/
def directEntry? (requested _path : String)
    (customModels : Array (String × String) := #[])
    (kimiModels : Array String := #["kimi-for-coding", "kimi-for-coding-highspeed", "k3", "k3-256k"]) :
    Option (String × String) := Id.run do
  match requested.splitOn "/" with
  | providerPrefix :: rest@(_ :: _) =>
    let model := String.intercalate "/" rest
    if providerPrefix.isEmpty || model.isEmpty then return none
    if let some provider := providerId? providerPrefix then
      return some (provider, if provider == "google" then googleModel model else model)
    if customModels.contains (providerPrefix, model) then return some (providerPrefix, model)
    return none
  | _ =>
    -- A bare id is owned by its model family's provider on every protocol
    -- (wider than Rust, which limited bare claude/gpt to their native routes).
    for (family, owner) in #[("claude-", "anthropic"), ("gpt-", "openai"), ("MiniMax-", "minimax"),
        ("glm-", "zai"), ("grok-", "xai"), ("muse-", "muse")] do
      if requested.startsWith family then return some (owner, requested)
    let model := requested.trimAscii.toString
    if model.isEmpty then return none
    if kimiModels.contains model || model.startsWith "k3-" || model.startsWith "kimi-for-coding" then
      return some ("kimi", model)
    if model.startsWith "gemini-" || model == "agy-demo" then
      return some ("google", googleModel model)
    return none

/-- Fresh-store definitions only. Never replace a persisted definition, and never
    guess targets for user-configured reviewer/scout/MiniMax-M3 aliases. -/
def stockChains : Array (String × String × Array (String × String)) := #[
  ("builtin/smart", "Smart (Default)", #[
    ("minimax", "MiniMax-M3"), ("zai", "glm-5.3"), ("muse", "muse-spark-1.3-contributor")]),
  ("builtin/cheap", "Cheap", #[("zai", "glm-4.7")]),
  ("builtin/fast", "Fast", #[("zai", "glm-5-turbo")]),
  ("builtin/assistant", "Assistant (Hermes)", #[
    ("google", "gemini-4-carbon-eap"), ("minimax", "MiniMax-M3"), ("cerebras", "zai-glm-4.7")]),
  ("google-opus", "Google Opus 5.5 (Antigravity Only)", #[
    ("antigravity", "claude-opus-5-5-high"), ("antigravity", "claude-opus-5-5-medium"),
    ("antigravity", "claude-opus-4-6-thinking"), ("antigravity", "agy-model-high"),
    ("google", "gemini-4-carbon-eap")]),
  ("google-sonnet", "Google Sonnet 5.5 (Antigravity Only)", #[
    ("antigravity", "claude-sonnet-5-5-high"), ("antigravity", "claude-sonnet-5-5-medium"),
    ("antigravity", "claude-sonnet-4-6"), ("antigravity", "agy-model-high"),
    ("google", "gemini-4-carbon-eap")])
]

def entriesJson (entries : Array (String × String)) : String :=
  renderCompact (.arr (entries.map fun (provider, model) => .obj #[
    ("provider_id", .str provider), ("model_id", .str model)]))

def unknownModelBody (requested : String) : String :=
  renderCompact (.obj #[("error", .obj #[
    ("message", .str s!"Model '{requested}' is not a known chain or a 'provider/model' id. List chains at /api/model-routing/chains and supported models at /api/providers/catalog."),
    ("type", .str "invalid_request_error"), ("code", .str "model_not_found")])])

/-- Normalize a `consult_model` name to a routable `<provider>/<model>` id.
    Short Claude aliases (`fable-5.2`) expand to the Anthropic id. Anything that
    cannot be routed is rejected by the caller with the name, never accepted. -/
def consultModel? (raw : String) : Option String :=
  let m := raw.trimAscii.toString
  if m.isEmpty then none
  else if m.startsWith "builtin/" && m.length > 8 then some m
  else if (m.splitOn "/").length > 1 then (directEntry? m "").map (fun _ => m)
  else if m.startsWith "fable-" || m.startsWith "opus-" || m.startsWith "sonnet-" || m.startsWith "haiku-" then
    some s!"anthropic/claude-{m.replace "." "-"}"
  else (directEntry? m "").map (fun (provider, model) => s!"{provider}/{model}")

def noProviderBody (requested : String) : String :=
  renderCompact (.obj #[("error", .obj #[
    ("message", .str s!"No configured provider account can serve model '{requested}'. It was not rerouted to another model."),
    ("type", .str "service_unavailable"), ("code", .str "no_provider_for_model")])])

end OrbCore.ProxyModelRouting
