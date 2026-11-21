# Provider login health (R32)

## Contract

Core owns the interpretation of CLIProxyAPI login health. A refresh-failed
(`invalid_refresh_token`), expired, or quota-exhausted login with a
reported reset is represented as `needs_reauth`, with the user-facing action
**Sign in again**. Desktop, iOS and Android Providers cards and mission errors
must preserve that classification rather than reporting generic overload.

A disabled sidecar login has account state `disabled`. Disabling it does not supply evidence of login rejection or require signing in again.

The kernel assigns a distinct login-unavailable reporting reason code. Login
failure is not a transient server failure. Health reporting records the
sidecar's reset in `parked_until`, without substituting a guessed one-hour
timeout or truncating a longer reset. No reset is reported when absent.
R32 changes no dispatch, cooldown, or recovery policy. In particular,
`orb-sidecar-guard` retains its existing behavior. Identity matching must not join ambiguous
accounts or reveal auth file names, email addresses or credential contents.

`orb-monitor` emits one change notification for the affected login-health
incident. Repeated polls of the same incident must not emit duplicate alerts.
A newly completed login clears the rejection and its reported parking state;
a failed or incomplete login does not. Health matching includes disabled
logins, but clearing a cooldown must never re-enable a disabled login.

## Acceptance replay

Use a shared fixture containing a refresh-failed login, a quota-exhausted login
with a reset and a disabled login. Named tests must verify:

1. Clients display **Sign in again** for a login requiring reauthentication and **Disabled** for an intentionally disabled account.
2. Mission failure exposes the same actionable classification.
3. Reported parking follows the sidecar reset exactly, including resets beyond an hour.
4. Repeated observations produce one monitor alert.
5. A fresh login clears rejection and parking without clearing other accounts.
6. Ordinary overload and ambiguous account matches do not become login failures.
