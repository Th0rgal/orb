# Mission dev pass

A mission requests `request_privileged_access` with `scope: "dev_operator"`,
`ttl_minutes` (1–240) and a reason. The existing operator approval flow creates
one lease; the target is always `dev` and no arbitrary units are permitted.
`dev_operator` has no generic privileged-command rank.

A member's mission may request and redeem its own separately approved dev pass.
The member's dashboard session or a participant in another user's shared mission
cannot take that mission's grant. Member grant listings contain only their own
mission's dev request/grant metadata, without raw host lease tokens or host audit.

With its own approved `grant_id`, the mission calls:

- `get_dev_access`: returns an opaque admin bearer and the dev URL. Use it in
  an Authorization header, never an URL, log, process argument or committed file.
- `deploy_dev` with a full lowercase 40-character `sha`: Core invokes
  `/usr/local/sbin/orb-deploy --detach SHA --dev-only`. The result acknowledges
  submission, not a healthy completed deployment. Check dev health afterwards.
- `read_dev_logs` with optional `lines` (1–500): Core reads only the dev journal.

Tokens have a separate `orb-dev-v1.` prefix, never an instance JWT signature.
Only a Core configured with `ORB_INSTANCE=dev` accepts them as admin. Dev checks
its local lease, or verifies the lease with its issuing Core on every request
via TLS `POST /api/dev-operator/verify`. The default issuer is `orbcore.thomas.md`;
`ORB_DEV_GRANT_ISSUER_HOST` can set its HTTPS hostname in the shared base env.
No JWT secret, password, provider key, user or mission is copied. Revocation,
expiry, deletion of the issuing mission, bunker mode and an unavailable issuer
fail closed. The issuer endpoint authenticates only the opaque dev capability;
it cannot authenticate a production API request.

Both issuing Core and dev need this code for cross-instance redemption. Until
the operator intentionally upgrades the issuing instance, use a mission and
approval local to dev; no production upgrade or restart is part of a dev deploy.
The operator installs the reviewed deploy script at the fixed path above.

A dev bearer cannot approve privileged requests, read Bitwarden/secrets, mint
independent sessions, run generic privileged commands, change host software or
services, use host workspace/console endpoints or deploy prod. It cannot alter
an existing administrator, create/promote an administrator, assign Linux
identities, mint proxy keys, read or restore raw settings, run provider logins or
access the owner's shared personal memory. It may create a zero-budget member
for isolation acceptance and disable that member afterwards. Account and
credential changes needing broader authority remain with the real operator.
Provider sealing remains reserved to a real operator session. Production
promotion remains an operator action.

Repository self-tests use temporary stores, synthetic leases and injected
command/issuer functions. They never deploy or read a live journal. Live
acceptance still requires the operator’s dev installation and approval.
