# Automatic deployment to dev

The operator installs `scripts/ops/orb-dev-autodeploy` and its systemd timer on
agent-core. Each tick fetches only the reviewed Orb repository’s master,
resolves a full commit SHA, checks dev’s reported build and submits
`orb-deploy --detach SHA --dev-only` when needed. No webhook secret, GitHub
write credential, provider key or long-lived admin token is required.

`orb-deploy` remains the owner of checkout, CI-parity build, full Core self-test,
installation and health verification. The timer waits while that deployment
unit is active, including an operator’s intentional production promotion.
A newer master observed after a build is deployed next; superseded heads may
be coalesced, so all merged changes arrive in the latest master build. Failed
builds or health checks are retried on the next tick. Nothing promotes prod.
The timer is host automation, not a standing mission grant.

Operator installation, after reviewing the tested commit in the existing build
checkout:

```sh
install -m 0755 scripts/ops/orb-deploy /usr/local/sbin/orb-deploy
install -m 0755 scripts/ops/orb-dev-autodeploy /usr/local/sbin/orb-dev-autodeploy
install -m 0644 deploy/systemd/orb-dev-autodeploy.service /etc/systemd/system/
install -m 0644 deploy/systemd/orb-dev-autodeploy.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now orb-dev-autodeploy.timer
systemctl list-timers orb-dev-autodeploy.timer
journalctl -u orb-dev-autodeploy.service -n 20 --no-pager
```

This installs and enables only dev automation. It does not restart either Core
instance. To stop automatic dev deployment, disable the timer. Live master-to-dev
acceptance still requires observing a new master SHA on dev’s health endpoint.
