namespace Orb.AccountVpn

/-- The observer decodes addresses to network-order numbers and normalizes
IPv4-mapped IPv6 to v4 before admission. -/
inductive ExitAddress where
  | v4 (address : UInt32)
  | v6 (high low : UInt64)
  deriving DecidableEq, Repr

/-- Provider account types that share an upstream identity namespace compete for exits. -/
def canonicalCategory (provider : String) : String :=
  match provider.trimAscii.toString.toLower with
  | "openai" | "chatgpt" | "codex" => "openai"
  | "anthropic" | "claude" => "anthropic"
  | "google" | "gemini" | "antigravity" | "gemini-cli" => "google"
  | "grok" | "xai" => "xai"
  | "meta" | "muse-code" => "meta"
  | other => other

structure Binding where
  account : String
  category : String
  country : String
  exits : List ExitAddress
  deriving DecidableEq, Repr

/-- A route is exclusive within its provider category at every exit address. -/
def Compatible (a b : Binding) : Prop :=
  a.account ≠ b.account ∧
    (a.category = b.category → ∀ ip ∈ a.exits, ip ∉ b.exits)

instance (a b : Binding) : Decidable (Compatible a b) := by
  unfold Compatible
  infer_instance

/-- Input rows are currently admitted routes. The caller atomically installs
the result; a replacement first drains the old route and its open connections. -/
def admit (requestedCountry : String) (candidate : Binding)
    (ready : List Binding) : Option (List Binding) :=
  if candidate.account ≠ "" ∧ candidate.category ≠ "" ∧ requestedCountry ≠ "" ∧
     candidate.country = requestedCountry ∧ candidate.exits ≠ [] ∧
     ∀ existing ∈ ready, Compatible candidate existing then
    some (candidate :: ready)
  else none

theorem admission_preserves_isolation {requested : String} {candidate : Binding} {ready next : List Binding}
    (before : ready.Pairwise Compatible)
    (step : admit requested candidate ready = some next) :
    next.Pairwise Compatible := by
  unfold admit at step
  split at step
  next h =>
    cases step
    exact List.pairwise_cons.mpr ⟨h.2.2.2.2.2, before⟩
  next => contradiction

theorem admission_country_and_evidence {requested : String} {candidate : Binding} {ready next : List Binding}
    (step : admit requested candidate ready = some next) :
    candidate.country = requested ∧ candidate.exits ≠ [] := by
  unfold admit at step
  split at step
  next h => exact ⟨h.2.2.2.1, h.2.2.2.2.1⟩
  next => contradiction

/-- Even when different servers or provider aliases were selected, one shared
address is sufficient to refuse the whole candidate. -/
theorem shared_exit_rejects_admission {requested : String} {candidate existing : Binding}
    {ready : List Binding} {ip : ExitAddress} (live : existing ∈ ready)
    (sameCategory : candidate.category = existing.category)
    (candidateExit : ip ∈ candidate.exits) (existingExit : ip ∈ existing.exits) :
    admit requested candidate ready = none := by
  unfold admit
  split
  next h => exact False.elim ((h.2.2.2.2.2 existing live).2 sameCategory ip candidateExit existingExit)
  next => rfl

/-- A healthy candidate may reuse every address of an occupied tunnel when
the other accounts belong to different canonical categories. -/
theorem other_categories_allow_sharing {candidate : Binding} {ready : List Binding}
    (account : candidate.account ≠ "") (category : candidate.category ≠ "")
    (country : candidate.country ≠ "") (observed : candidate.exits ≠ [])
    (others : ∀ b ∈ ready, candidate.account ≠ b.account ∧ candidate.category ≠ b.category) :
    admit candidate.country candidate ready = some (candidate :: ready) := by
  unfold admit
  apply ite_eq_left
  refine ⟨account, category, country, rfl, observed, ?_⟩
  intro b hb
  obtain ⟨distinct, different⟩ := others b hb
  exact ⟨distinct, fun same => False.elim (different same)⟩

/-- Occupied includes external sessions. Pending counts Orb reservations
whose handshakes are not yet represented in the occupied snapshot. -/
def reserve (limit occupied pending : Nat) : Option Nat :=
  if occupied + pending < limit then some (pending + 1) else none

theorem reservation_within_budget {limit occupied pending after : Nat}
    (step : reserve limit occupied pending = some after) :
    occupied + after ≤ limit := by
  unfold reserve at step
  split at step
  next h =>
    cases step
    omega
  next => contradiction

theorem reservation_refused_iff_full (limit occupied pending : Nat) :
    reserve limit occupied pending = none ↔ limit ≤ occupied + pending := by
  unfold reserve
  split <;> simp_all

/-- Each observation certifies a running tunnel for the current transport
generation. The I/O owner expires it on reconnect, expiry, or endpoint change. -/
structure VerifiedTunnel where
  server : String
  country : String
  exits : List ExitAddress
  deriving DecidableEq, Repr

structure Request where
  account : String
  category : String
  country : String
  preferredServer : Option String := none
  deriving Repr

private def binding (req : Request) (t : VerifiedTunnel) : Binding :=
  ⟨req.account, req.category, t.country, t.exits⟩

/-- A saved server can be restarted even when a different server is already
running. Within each tier, shared transports precede new sessions. -/
def serverOrder {α : Type} (server : α → String) (preferred : Option String)
    (candidates : List α) : List α :=
  let (first, rest) := candidates.partition (fun t => some (server t) == preferred)
  first ++ rest

theorem saved_server_precedes_alternatives {α : Type} (server : α → String)
    (preferred : String) (candidates : List α) :
    ∃ pinned alternatives, serverOrder server (some preferred) candidates = pinned ++ alternatives ∧
      (∀ t ∈ candidates, t ∈ pinned ↔ server t = preferred) ∧
      (∀ t ∈ candidates, t ∈ alternatives ↔ server t ≠ preferred) := by
  unfold serverOrder
  simp only [List.partition_eq_filter_filter]
  refine ⟨_, _, rfl, ?_, ?_⟩
  · intro t ht
    simp [ht]
  · intro t ht
    simp [ht]

/-- Consider the persisted server first. Reordering preserves the relative
order of other servers, so a stable input inventory gives stable choices. -/
def choose (req : Request) (ready : List Binding) (healthy : List VerifiedTunnel) :
    Option VerifiedTunnel :=
  (serverOrder (·.server) req.preferredServer healthy).find? fun t =>
    (admit req.country (binding req t) ready).isSome

private def chatA : Request := ⟨"a", "openai", "NL", some "nl-west"⟩
private def west : VerifiedTunnel := ⟨"nl-west", "NL", [.v4 1, .v6 0 2]⟩
private def east : VerifiedTunnel := ⟨"nl-east", "NL", [.v4 3, .v6 0 4]⟩

-- A cold saved server precedes a warm alternative. The alternative remains
-- available when session capacity prevents restarting the saved server.
example : serverOrder Prod.fst (some "west")
    [("east", true), ("west", false), ("south", false)] =
    [("west", false), ("east", true), ("south", false)] := by decide

-- Persisted preference wins across reordered inventory.
example : choose chatA [] [east, west] = some west := by decide

-- Two distinct servers may have one observable exit in common (even only v6).
example : choose chatA [⟨"b", "openai", "NL", [.v6 0 2]⟩] [west, east] = some east := by decide

-- Compatible categories can share the preferred exit.
example : choose chatA [⟨"c", "anthropic", "NL", west.exits⟩] [west] = some west := by decide

-- A stale/missing observation, wrong country or occupied last slot cannot admit.
example : choose chatA [] [{west with exits := []}, {east with country := "US"}] = none := by decide
example : reserve 5 4 0 = some 1 ∧ reserve 5 4 1 = none := by decide

end Orb.AccountVpn
