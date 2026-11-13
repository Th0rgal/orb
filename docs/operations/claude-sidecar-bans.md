# Claude logins banned by the sidecar

Claude subscriptions are served through the CLIProxyAPI sidecar on agent-core
(`cli-proxy-api.service`, loopback `:8317`). The sidecar keeps its own list of
logins and can refuse to use one for a while ("cooldown"). Core does not see
that state.

## What happened on 13 November 2026

| Time (UTC) | Event |
| --- | --- |
| 03:45:07 | Anthropic answers one 429 `rate_limit_error` to a Fable request during a burst (15 requests a minute). The sidecar takes the weekly reset (18 Nov 15:00) as the wait and bans the whole login for 131 h: Fable, Opus and Haiku. The account is at 8% weekly use. |
| 03:45 on | The second Claude login has an expired refresh token, so no login is left. Every Claude request returns 503. Core adds its own 40-minute cooldown after each one. |
| 11:41 | A `genius` chain with Fable as its only target is created; missions on it hang at "Starting OpenCode…" with no error. |
| 12:05 | Fallbacks added to `genius`. |
| 13:20 | Second login reconnected. |
| 13:28 | Ban released by hand; the banned login answers Fable and Opus with 200, so the ban was wrong. |

## What now prevents it

- `orb-sidecar-guard` (timer, every 5 minutes) releases a Claude login whose
  ban is longer than six hours. Anthropic's short window is five hours, so a
  longer ban is right only when the weekly limit is spent, and then the next
  request is refused again. After three releases in six hours the guard leaves
  the login banned.
- `orb-monitor` reports `claude-banned:<login>` for a ban over five hours and
  `claude:none` when no Claude login can serve. Both arrive in the Orb Inbox
  within five minutes.
- Chains meant for unattended work need more than one target.

Still open in Core (tracked in `docs/plans/orb-consolidation-2026-11.md`,
track H): the provider card does not show sidecar bans, the health "clear"
route does not clear Core's own cooldown, and a completed login does not
refresh the cached "rejected" state.

## By hand

```bash
orb-sidecar-guard --print            # what it would release, changes nothing
journalctl -u orb-sidecar-guard -n 20
cat /var/lib/orb-sidecar-guard/state.json
```

To stop the guard: `systemctl disable --now orb-sidecar-guard.timer`.

Install (operator, from a checkout of the deployed commit):

```bash
install -m 755 scripts/ops/orb-sidecar-guard /usr/local/sbin/orb-sidecar-guard
install -m 755 scripts/ops/orb-monitor /usr/local/sbin/orb-monitor
install -m 644 deploy/systemd/orb-sidecar-guard.service deploy/systemd/orb-sidecar-guard.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now orb-sidecar-guard.timer
```
