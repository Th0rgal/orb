# Antigravity Model-Compatible Account Selection and Node Profile Isolation

## Problem

Google Antigravity rolls EAP models out per Google account. In particular,
`Gemini 4 Carbon` (`agy-model` / `agy-model-{low,medium,high}`) is exposed only
to accounts enrolled in the Carbon EAP pool (`gemini-eap`), while a higher-priority
general Ultra account on the same Orb Core may offer `Claude Opus 5.5` and
`Gemini 4 Argon` (`agy-demo-*`) without Carbon.

Two failure modes caused native `agy` runs on `agy-model-*` to launch under an
incompatible Google account and fail immediately with
`model agy-model-low is not recognized as a known model`:

1. **Unverified accounts outranking positively entitled accounts (`choose_for_model`):**
   Candidate filtering treated missing `ai_providers.json` reconciliation,
   partial/missing `model-discovery.json` entries, and unprobed accounts as
   model-compatible (`!connection_lacks(...) == true`), then sorted by base
   priority. Any unprobed or unreconciled higher-priority account therefore
   preempted a lower-priority account with positive Carbon entitlement. In
   addition, when every candidate lacked the model, `choose_for_model` fell back
   to `eligible[0]` instead of failing closed.
2. **Shared mutable node and workspace credential clobbering:**
   `sandboxed-node` stored a single shared `managed-auth/antigravity/antigravity-oauth-token`
   symlinked into every job's `.gemini/antigravity-cli`, and Core projected the
   login early during preflight (`require_node_managed_auth`) while three paths
   overwrote that shared file with the general (`model = None`) account:
   `GET /api/providers/nodes/:node_id/antigravity/models`,
   `workspace_antigravity_models`, and periodic `refresh_and_sync`.

## Formal Kernel Contract (`orb_model_account_admit` & `orb_model_account_score`)

Account admission and ranking for model-scoped pools is decided by
`Orb.Kernel.modelAccountAdmit` (`orb_model_account_admit`) and
`Orb.Kernel.modelAccountScore` (`orb_model_account_score`) in `lean/Orb/Kernel.lean`,
verified in `lean/Orb/Spec.lean` and folded through `orb_route_argmin_step`:

- **Inputs:**
  - `candId : UInt32` (`0` = invalid)
  - `ineligible : UInt8` (`1` = `NeedsVerification` or disabled)
  - `entitlement : UInt8` (`0 = LacksModel`, `1 = Unknown`, `2 = Entitled`)
  - `requireEntitled : UInt8` (`1` when an EAP-gated model requires positive
    entitlement or at least one candidate in the pool is `Entitled`)
  - `hasPoolQuota : UInt8` (`1` when the candidate's quota pool for the requested
    model is unspent and not in native refusal cooldown)
  - `priorityRank : UInt32` (`0..65535`, smaller rank = higher configured priority)
  - `usableInSecs : UInt32` (seconds until the model's quota pool resets when
    `hasPoolQuota == 0`)

- **Admission (`orb_model_account_admit == 1`):**
  A candidate is admissible if and only if:
  1. `candId != 0`,
  2. `ineligible == 0`,
  3. `entitlement == 2` (`Entitled`), OR (`entitlement == 1` (`Unknown`) AND `requireEntitled == 0`).

- **Monotone Minimize-Score Key (`orb_model_account_score` -> `orb_route_argmin_step`):**
  For every admissible candidate, `orb_model_account_score` computes a 64-bit
  minimize-score folded through `orb_route_argmin_step` (and returns `UInt64.max`
  for inadmissible candidates):
  ```text
  entitlementPenalty = if entitlement == 2 then 0 else 1
  quotaPenalty       = if hasPoolQuota == 1 then 0 else 1
  waitSecs           = if hasPoolQuota == 1 then 0 else usableInSecs
  rankClamped        = min(priorityRank, 65535)
  score = (entitlementPenalty << 50) | (quotaPenalty << 49) | (waitSecs << 16) | rankClamped
  ```

- **Proven Invariants (`lean/Orb/Spec.lean`):**
  1. **Incompatible Exclusion (`ScopedAuthority`):** `entitlement == 0` (`LacksModel`),
     `entitlement > 2`, or `ineligible != 0` is never admitted under any priority
     or quota state.
  2. **EAP / Positive-Entitlement Gate (`ScopedAuthority`):** When
     `requireEntitled == 1`, `Unknown` accounts (`entitlement == 1`) are strictly
     rejected; an unprobed high-priority account can never preempt an entitled
     account or guess on an EAP model when no account is entitled.
  3. **Entitlement Dominance (`ScopedAuthority`):** Every admissible `Entitled`
     candidate strictly beats every admissible `Unknown` candidate (`scoreEnt < scoreUnk`),
     even if the `Entitled` candidate's pool is currently on cooldown and the
     `Unknown` candidate has `priorityRank = 0` and full quota.
  4. **Pool Quota & Reset Ordering (`ClockDiscipline`):** Within the same
     entitlement tier, unspent pool quota (`hasPoolQuota == 1`) strictly beats
     spent pool quota (`hasPoolQuota == 0`); among unspent candidates, smaller
     `priorityRank` wins; among spent candidates, earlier `usableInSecs` reset wins.

## Runtime & Node Isolation

1. **Dual Entitlement Evidence:**
   Per-account Carbon / model entitlement is derived from both
   `model-discovery.json` (`Completeness::Complete` catalog observations,
   matching accounts via `cli_proxy_accounts` identity rules as well as
   `cli_proxy_auth_file`) and live Cloud Code `retrieveUserQuota` model buckets
   recorded in `antigravity_accounts::Health` (`carbon_entitled`: `Some(true)`
   when `agy-model*` / Carbon buckets appear, `Some(false)` when a non-empty
   per-model bucket list omits Carbon). All Carbon effort/alias spellings
   (`agy-model`, `agy-model-{low,medium,high}`, `gemini-4-carbon*`) resolve to
   the same entitlement family.
2. **Per-Account Node Credential Slots (`antigravity:<slot>`):**
   Core derives a deterministic non-secret slot id (`16` lowercase hex chars of
   `SHA-256(refresh_token)`) per Antigravity login and pushes it to
   `PUT /managed-auth/antigravity?slot=<slot>` (keeping the legacy body/route
   compatible with older nodes). Upgraded `sandboxed-node` instances store each
   login under `managed-auth/antigravity/accounts/<slot>/antigravity-oauth-token`,
   advertise `antigravity:<slot>` on `/heartbeat`, and bind each job's
   `<mission_dir>/.gemini/antigravity-cli/antigravity-oauth-token` symlink to
   that exact slot while keeping `conversations/` and `brain/` inside
   `<mission_dir>/.gemini/antigravity-cli/`. Concurrent Carbon and non-Carbon
   jobs on the same node never share or overwrite each other's OAuth token.
   Provisioning with a named slot and `default=false` leaves the default unmodified even on a fresh node. A request with `default=false` and no named slot is invalid. Omitting the flag retains the default-profile behavior.
3. **Legacy Node & Discovery Non-Clobbering:**
   - `submit_leased_remote_job` syncs the model-selected credential immediately
     before `submit_job` and selects `antigravity:<slot>` whenever the node
     advertises it (falling back to `antigravity` on pre-slot nodes, and failing
     closed if an explicit EAP model has no compatible connected login).
   - `GET /api/providers/nodes/:node_id/antigravity/models` only seeds a node
     when its heartbeat does not yet advertise `antigravity`, and
     `discover_workspace_antigravity_models` probes `agy models` in a temporary
     `HOME` rather than overwriting the workspace's active sign-in.
   - Periodic `refresh_and_sync` updates the default `antigravity` profile
     without touching `accounts/<slot>` bindings and skips legacy single-slot
     nodes that currently have an active or tentative remote job in `job_ledger`.

### Member catalog discovery

For a signed-in member, Core lists models discovered by the native CLI for
enabled accounts the member has selected. Each probe uses the uniquely bound
subscription, a private disposable CLI profile, and the account's resolved
transport. A refresh credential stays with its owner. A personal opt-out takes
effect even when a successful catalog is cached. Rotating the credential or
changing the route invalidates the account's cached result. When every eligible
probe fails, the dedicated endpoint returns a retryable failure. Restoring the
route allows a fresh discovery. With no eligible subscription it returns an
empty list. Loading the other harnesses never waits on native catalog discovery.

A tunnel outage affects the account assigned to that tunnel. While its native
catalog returns 503, a mission bound to a second account on Direct can read
the catalog with that account’s credential. A subsequent request from the
first mission still returns 503 without contacting the upstream.

### Consumer headless eligibility on remote workers

The native launcher gives agy a local relay nonce. Core alone authenticates
gateway requests with the selected Google account through its configured
network route. A successful `v1internal:fetchUserInfo` response verifies only
that gateway request. On Linux, agy 1.5.13 also sends an authenticated GET to
`https://www.googleapis.com/oauth2/v2/userinfo` outside the configured
`CLOUD_CODE_URL`. A 401 there can stop eligibility before generation for both
Carbon and Neon. The terminal error alone does not identify which request
failed.

The worker cannot use the relay nonce as a Google OAuth credential. Remote
support needs a vendor-supported way for the selected account's credential
holder to perform this auxiliary identity check through the account's network
route and return Google's actual decision. A plain HTTPS CONNECT proxy would
transport the same nonce to Google.

To replay the rejection, use a disposable Linux guest with only loopback
enabled, map `www.googleapis.com` to `127.0.0.1` in the guest, and run:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=www.googleapis.com -addext subjectAltName=DNS:www.googleapis.com \
  -out cert.pem -keyout key.pem
python3 scripts/test_antigravity_native_eligibility.py \
  --agy "$(command -v agy)" --cert cert.pem --key key.pem
```

The disposable certificate is trusted only by the test process. The test
requires port 443 in the guest, rejects every identity request, and checks
the actual CLI terminal result and zero generation requests. Google's
headless CLI documentation describes using cached credentials after sign-in.
[Headless mode](https://antigravity.google/docs/cli/headless/)

### Running the signed-in CLI in a trusted per-account service

A service could keep the genuine native login and all Google traffic inside the
selected account's VPN. The remaining boundary is between that service and
mission-controlled workspace operations. On Linux agy 1.5.13 and 1.5.14, we
found no documented mode that assigns those operations exclusively to a
separately authenticated workspace executor.

* The terminal sandbox uses OS namespaces and permission-derived mounts for
  shell commands. Google documents that `--sandbox` has no effect when the
  sandbox is unavailable and describes execution outside it. The option
  specifies neither a mandatory remote runner nor the identity for other
  workspace subprocesses. Hooks can run scripts and stdio MCP servers have their
  own executable configuration. Mounting the remote checkout into the service
  solves file visibility alone.
  [Terminal sandbox](https://antigravity.google/docs/sandbox/)
  · [Hooks](https://antigravity.google/docs/hooks/)
  · [MCP transports](https://antigravity.google/docs/mcp/)
* ACP carries permission decisions and session state. In a loopback-only
  guest with an empty HOME, both binaries completed ACP v1 `initialize` with
  client terminal and file capabilities enabled. Both advertised session
  load and resume; `--process-per-session` added HTTP MCP capability. That
  handshake exercises capability negotiation only. The documented per-session
  process flag does not select an OS principal for tools. IDE MCP adds host
  tools; the documentation provides no exclusive client-execution contract
  for native commands, filesystem operations, or workspace integrations.
  [ACP interface and flags](https://antigravity.google/docs/ide/extensions/acp/)
* Remote Control attaches to the machine running the agent. Remote Agents use
  Google-managed environments and project resources. The App's SSH mode runs
  tools and saves the Google login on the SSH host. None documents a headless
  service option to bind a session to an existing Orb worker for tool execution.
  [Remote Control](https://antigravity.google/docs/remote-control/)
  · [Remote Agents](https://antigravity.google/docs/remote-agents/)
  · [SSH](https://antigravity.google/docs/ssh/)

**Minimal upstream request.** Add a mandatory workspace-executor mode to
`agy acp`. Let the authenticated service bind a session to a caller-supplied
executor for all workspace file access and process execution, including
terminal commands, hooks, and stdio MCP. Unsupported local integrations must
be disabled in that mode. Apply native tool approvals before dispatch; if the
executor disconnects, fail the operation without local fallback. The executor
receives mission-scoped authority only. OAuth, eligibility, inference and
native conversation state stay in the service.

Orb could then persist the selected account, mission, stable workspace
identity and native conversation ID together, verify that binding on resume,
and reconnect the same worker workspace. Acceptance would require a ledger
edit and resume on that worker, denial before dispatch, and a disconnected
executor producing zero local executions. The CLI scopes its local conversation
history by working directory.
[Conversation scoping](https://antigravity.google/docs/cli/conversations/)

#### Two-UID Linux fixture

The public Linux amd64 manifest identified 1.5.14. In a loopback-only guest,
we ran that released binary as UID 16001 with a private profile. The checkout
belonged to UID 16002 and permitted the harness to edit through group access.
UID 16002 could not read a harmless marker in the 0700 account directory.
The model endpoint was the existing disposable API-key protocol control;
this experiment measures local execution identity. It used no Google login.

With the current directory set to the mission checkout, the fixture ran
`agy --settings <goal-settings> --model gemini-4-carbon-high --mode accept-edits --output-format stream-json --print=<ledger-task>`,
then resumed with `--conversation <returned-id>`. A second guest repeated both
turns with `--sandbox`. The native write created the ledger as UID 16001.
The configured stdio MCP server returned its effective UID, also 16001.
Both runs resumed the original conversation and passed the explicit MCP denial
control. We did not measure a shell UID or inspect a keyring. The built-in
write and MCP measurements already disqualify this arrangement for shared
missions. They make no claim about terminal sandbox availability in the guest.

Orb's privileged node launcher applies `setgid` and `setuid` when launching a
user job and scrubs that job's environment. The launcher boundary covers the
job as a whole. Moving agy into an account-owned job therefore changes the
principal of the harness; the current CLI exposes no matching selector to
put all workspace actions back into a mission-owned job.

Orb resolves the account's verified VPN transport before opening the native
upstream request and passes the resulting SOCKS port to its own network
client. Launching a separate signed-in CLI does not itself attach that CLI
to the selected route. Google's `sandboxProxy` setting applies to sandboxed
terminal commands. A trusted deployment would have to enforce account egress
for the entire CLI, DNS and auxiliary clients, with end-to-end Google TLS and
no direct fallback. This fixture did not test a VPN route.

The nearest documented topology is a dedicated **single-owner** Linux host
or VM where the owner signs in interactively with agy and uses the same
persistent profile and checkout for headless turns and resume. This requires
trusting the checkout, its tools and its integrations as that owner. It is not
a deployment for untrusted Orb mission workspaces.
[Headless login](https://antigravity.google/docs/cli/headless/)
· [CLI proxy settings](https://antigravity.google/docs/settings/)

#### Whole-process account egress fixture

A supervisor creates an empty Linux network namespace, brings up only its
loopback interface, and puts the complete native job there before dropping to
UID 16001 with no supplementary groups and `no_new_privs`. The native CLI and
its shell inherit the namespace. The supervisor binds one TCP listener inside
it. Behind that listener it forwards bytes only to a fixed account relay socket
in the outer namespace. The listener survives relay loss and cannot choose a
different upstream. Changing proxy environment variables cannot create a route.

The fixture uses the existing Orb account relay's SOCKS5 username/password
and hostname CONNECT protocol with disposable values. The upstream sees
`127.0.0.3` on the relayed route and `127.0.0.1` on the direct control.
Only the local HTTPS origin holds the TLS private key. The test uses a
synthetic Gemini API-key model response, a native `run_command` ledger probe,
and the real CLI's conversation ID. Orb's VPN selection, Google OAuth, and
live WireGuard transport are outside this fixture. Core's verified VPN
transport has a separate integration test. [Account VPN](account-vpn.md)

**Reproduce in a disposable NIC-free Linux VM** as root with Python 3.12 or
later, network namespaces enabled, `ip`, OpenSSL, a mounted `/proc` and
`/dev/pts`, Bash, and native agy 1.5.14. Use a fresh guest with only loopback,
a free UDP port 53, and no local proxy, resolver service, or host service
sockets mounted into it. Place the checkout and CLI at paths readable by UID
16001. Inside the guest, run:

```sh
ip link set lo up
printf '127.0.0.2 ledger.test\n' >> /etc/hosts
printf 'nameserver 127.0.0.2\noptions timeout:1 attempts:1\n' > /etc/resolv.conf
mkdir -p /run/ledger-fixture
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=ledger.test \
  -addext subjectAltName=DNS:ledger.test -keyout /run/ledger-fixture/key.pem \
  -out /run/ledger-fixture/cert.pem
chmod 600 /run/ledger-fixture/key.pem
chmod 644 /run/ledger-fixture/cert.pem
python3 scripts/test_antigravity_job_egress.py --agy "$(command -v agy)" \
  --cert /run/ledger-fixture/cert.pem --key /run/ledger-fixture/key.pem
```

The test first reaches the direct TLS and DNS listeners from the outer
namespace. Inside the job, the native shell probes direct TCP, sends a DNS
query to the same listener, and exercises the system resolver. It records the
kernel namespace identity in the ledger receipt. The supervisor then kills
the account relay with SIGKILL while a job-side TLS tunnel is open. It checks
that the tunnel closes, a native resume reports a transport error within its
print deadline, and neither upstream receives fallback traffic. Restarting
only the relay must allow the same native conversation to finish through it.

Observed fixture stdout (exit 0, Linux amd64 agy 1.5.14):

```text
direct controls: TLS=204 DNS=NXDOMAIN
relay up: native turn=SUCCESS shell namespace=job direct TCP/DNS=blocked
relay down: established TLS closed native resume=ERROR upstream delta=0 direct TCP/DNS=blocked
relay restored: native resume=SUCCESS same conversation=true direct model calls=0 job DNS packets=0
```

#### Admission at the real node dispatcher

The optional `--node /absolute/path/to/sandboxed-node` variant starts a
disposable node in the isolated network namespace. A fixture client performs
the Core side of the signed `job:submit` exchange with this node's temporary
secret. Each turn is a new `POST /jobs` for the same mission and owner. The
client waits for the node ledger's terminal state. The fixture names one synthetic owner in admin-role leases. The daemon and
harness run under one unprivileged guest UID. The synthetic native profile
sits outside the mission checkout. The real MCP launcher uses a disposable
mission-scoped capabilities/call endpoint inside the namespace.
The guest also needs `env`, `sqlite3`, and `sandboxed-mcp` on PATH. Use
the preceding guest setup and add `--node /bin/sandboxed-node` to the
test command. No request is sent to an existing Core or node.

**Prerequisite for a dev runtime.** A trusted-owner enrollment record must bind
the authenticated Orb user, exact provider account, concrete node identity,
and local Unix principal/profile. Both Core and the node need to enforce this
binding on initial launch and resume. Core must check it before account catalog
probing, which can already open the Core-held credential. The node must check
it before opening the owner's native profile or starting a workspace process.
Changes to the owner, account, node, or route must invalidate an outstanding
launch. Generic and admin jobs must not be able to run an unrelated mission
as the enrolled profile owner.

The current static node roster stores ID, base URL, token environment name
and labels. Its signed job lease carries mission, node, job, owner, role, Unix
user, scope and expiry. Neither identifies an owner-enrolled Google profile.
The native mission grant binds an account and model for gateway RPCs, but
does not designate an owner-enrolled execution node. Initial account selection
can perform model discovery across the user's enabled accounts. Limiting user
preferences to one account does not establish node ownership.
[Core dispatch](../../lean/OrbCore/OrbCore/RemoteDispatch.lean)
· [Node lease](../../lean/OrbNode/OrbNode/Lease.lean)

The verified account SOCKS listener lives on **Core's loopback**. The fixture
has both ends in one VM. A remote node needs a private authenticated path to
that particular Core relay, with job-lifetime authority and revocation. It also
needs a distinct mission-scoped path to Core's MCP endpoint inside the job
boundary. Exposing the relay's long-lived account credential in a raw job
payload would persist authority outside that lifetime. Neither a node label
nor a proxy environment variable supplies these two paths.
[Account relay](../../lean/OrbCore/OrbCore/AccountVpnRelay.lean)
· [Node job admission](../../lean/OrbNode/OrbNode/Server.lean)

**Owner steps.** Current Orb UI can configure the account route: open
**Inference → the Antigravity account → Account connection**, choose
**AirVPN · NL**, and check **Verified exit**. Keep **Allow alternative
routers** off for native-only use. Machines shows the registered node. Neither
screen enrolls the owner/account/profile tuple. There is currently no supported
Orb UI action or CLI command to complete trusted-owner enrollment.

Once that admission and the node-to-Core path exist, the owner must perform
Google's native login from a terminal running as the bound Unix user, inside
the account-routed environment and using the persistent private home/keyring.
An eligible existing native session for that same profile can be reused.
Otherwise, over SSH, run `agy acp --login`, open its URL in the owner's
browser, choose the intended personal Google account, complete Google's
consent and eligibility prompts, and paste the returned one-time code into
that same terminal. An interactive `agy` session also supports this SSH flow.
Run `agy models` in the same context to check catalog access before a dev
mission. Only the owner can complete Google's interactive step.

The existing dev OAuth remains usable by the Core integration that owns it.
Google documents reuse of the CLI's cached native session. We found no
documented exchange of an Orb/CLIProxyAPI grant for that owner-held CLI
session. Orb's separate managed-auth installer takes access and refresh
tokens and attaches a credential file to a workspace. That is a different
credential distribution model from owner enrollment.
[Google SSH OAuth](https://antigravity.google/docs/install/#remote-ssh-oauth-flow)
· [Google ACP login](https://antigravity.google/docs/ide/extensions/acp/)
· [Orb managed-auth installer](../../lean/OrbNode/OrbNode/FileBrowser.lean)

Node dispatcher receipt (agy 1.5.14; installed Linux node binary SHA-256
`6d9b838e8d9dd5833350e7ffe945e8b74377c39b4ab18fa5f2a82fdbd9ae7c0f`):

```text
missing signed node ID: HTTP 400, job absent
different signed node ID: HTTP 400, job absent
node job=9760a1e5-dda0-4e53-ad36-d368cdb2a01d mission=a1033f4c-8e1c-4d14-a190-672294dc49c4 state=succeeded
native MCP get_compute_fleet: same mission receipt
relay up: native turn=SUCCESS shell namespace=job direct TCP/DNS=blocked
node job=07b835e5-e6d2-4283-9597-69d20fa88c69 mission=a1033f4c-8e1c-4d14-a190-672294dc49c4 state=failed
relay down: established TLS closed native resume=ERROR upstream delta=0 direct TCP/DNS=blocked
node job=0ee38fcf-646c-41bd-89dd-3118084665d3 mission=a1033f4c-8e1c-4d14-a190-672294dc49c4 state=succeeded
relay restored: native resume=SUCCESS same conversation=true direct model calls=0 job DNS packets=0
```

The two HTTP 400s exercise the existing node-ID check. They do not demonstrate
a trusted owner/profile admission check. The latter has no enrollment record
or signed claim in this protocol.
