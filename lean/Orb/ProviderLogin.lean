namespace Orb.Kernel

/-- R32 reporting reason: 0 healthy/unknown, 1 refresh rejected, 2 disabled,
    3 expired, 4 quota with a reported reset. This projection has no recovery effects. -/
def providerLoginReason (refreshFailed disabled expired quotaWithReset : Bool) : UInt8 :=
  if disabled then 2 else if refreshFailed then 1 else if expired then 3
  else if quotaWithReset then 4 else 0

/-- Disabled credentials remain visible regardless of other observations. -/
theorem provider_login_disabled_is_reported (refreshFailed expired quota : Bool) :
    providerLoginReason refreshFailed true expired quota = 2 := by
  simp [providerLoginReason]

/-- A fresh healthy login clears every reporting reason. -/
theorem provider_login_fresh_clears : providerLoginReason false false false false = 0 := rfl

/-- Each refusal class is reported independently of transient overload. -/
theorem provider_login_refusal_classes :
    providerLoginReason true false false false = 1 ∧
    providerLoginReason false false true false = 3 ∧
    providerLoginReason false false false true = 4 := by decide

end Orb.Kernel
