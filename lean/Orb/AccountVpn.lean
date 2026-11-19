namespace Orb.AccountVpn

/-- The observer decodes addresses to network-order numbers and normalizes
IPv4-mapped IPv6 to v4 before admission. -/
inductive ExitAddress where
  | v4 (address : UInt32)
  | v6 (high low : UInt64)
  deriving DecidableEq, Repr

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

/-- Consider the persisted server first. Reordering preserves the relative
order of other servers, so a stable input inventory gives stable choices. -/
def choose (req : Request) (ready : List Binding) (healthy : List VerifiedTunnel) :
    Option VerifiedTunnel :=
  let preferred := fun (t : VerifiedTunnel) => some t.server == req.preferredServer
  let (first, rest) := healthy.partition preferred
  (first ++ rest).find? fun t =>
    (admit req.country (binding req t) ready).isSome

private def chatA : Request := ⟨"a", "openai", "NL", some "nl-west"⟩
private def west : VerifiedTunnel := ⟨"nl-west", "NL", [.v4 1, .v6 0 2]⟩
private def east : VerifiedTunnel := ⟨"nl-east", "NL", [.v4 3, .v6 0 4]⟩

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
