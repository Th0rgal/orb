# Dev multi-user isolation acceptance

Run acceptance only against dev, after its health endpoint reports the tested
commit. A local temporary-store test is regression evidence, not live acceptance.
Do not use production users or tokens. A dev operator pass may create a temporary
member with a zero spend cap; never copy a dashboard password, provider key or JWT
signing secret to a mission. Test data stays in dev.

Core must apply the same stored user identity to REST, desktop requests and MCP.
A caller-selected MCP role (`executor`, `coordinator` or `operator`) only governs
delegation within that identity. It cannot grant access to another user's data.
A session minted for a shared mission keeps the minting user's identity; the
mission owner's admin role is never inherited. Guessed foreign mission IDs return
the same not-found result as absent IDs before mutations or idempotent replay.

`TenantIsolationTests` exercises the real HTTP dispatcher with separate synthetic
admin/member records. It covers REST lists and guessed mission IDs, owner-only
secret routes, MCP mission reads and mutations, scoped sessions with each role,
external sessions, shared-mission sessions, project reads/mutations, and filtered
mission/project/workspace/machine lists, separate usage totals, owner-only personal
memory and per-user REST/MCP retry receipts. It checks admin records after denial and positive
access to each user's own mission. The Core self-test runs it on every build.

Live acceptance still requires all of these, with positive controls:

1. Create the temporary dev member and synthetic admin-owned mission/project.
2. As that member, probe admin missions, projects, secrets, machines, provider
   settings and usage with guessed IDs and user/role spoofing through REST.
3. Repeat through direct dashboard MCP calls, mission sessions for each role and
   an external session. Attempt reads and mutations; inspect the owner fixtures
   afterwards. Test a shared mission separately from an unshared one.
4. Log into the desktop client as the member. Check lists, direct mission links,
   settings and usage, and inspect the network responses. Hidden controls alone
   do not establish isolation. Repeat after switching from admin to member.
5. Add a regression for every leak, build/self-test, push, deploy dev and repeat.
   Disable the temporary member afterwards to revoke its sessions.

Never print response bodies that could contain secrets or existing transcripts.
Record route/tool, response status, pass/fail, build SHA and fixture integrity.
No live test has been certified by this document.

Account switches clear remote missions, projects and fleet state before the next
read, including the data sent to the native desktop sidebar. Failed member reads
must never retain the previous administrator's snapshot under the member's scope.
`tenant-switch.browser.spec.ts` replays admin-to-member switching with failed
catalog reads in both HTML and native-bridge modes. This local browser regression
does not substitute for the live desktop acceptance above.

Transport failover is also an instance boundary. Only the three explicit
production aliases may retry one another. Dev and custom hosts, including other
`thomas.md` subdomains, keep every authenticated request on their configured
origin after a network error. Desktop, its local daemon, iOS and Android share
this policy; `client-link-governor.json` includes the dev and custom-host cases.
The desktop transport regression fails both a read and an idempotent write and
checks that no production request was attempted.

Legacy rows without a recorded owner stay operator data. Members see only their
own managed snapshot metadata; snapshot creation and deletion check the source
machine before any provider or vault access. Provider inventory without a verified
local owner is visible only to the operator. Fleet settings return a member's own
usage, and global board task keys cannot overwrite another project's tasks.
REST and MCP share that board admission path. Session-to-project lookups require
the recorded project owner. The project controller/cron endpoints operate the
shared host Hermes scheduler and require a real operator; members and dev passes
cannot use those routes to read prompts, change jobs or launch host work.

Remote dispatch binds the mission's stored owner before minting MCP, model-proxy
or node credentials. A missing or disabled owner fails closed. Member placement
requires that user's stored Linux identity and a dedicated fleet node or their
own VM; control-plane node labels remain authoritative. The MCP create path uses
the same placement check even for missions created without an initial prompt.

The initial live REST/MCP probe is `scripts/dev_user_isolation.py`. It requires
the exact tested SHA and an already-approved dev bearer in an owner-only local
file; it does not obtain credentials. For example, from the checkout:

```sh
python3 scripts/dev_user_isolation.py --sha "$orb_test_sha" \
  --token-file "$orb_dev_bearer_file"
```

It accepts only `https://agent-backend-dev.thomas.md` or the operator's local
`http://127.0.0.1:3002`, refuses redirects, checks the build before mutation,
creates a zero-budget member and inert client-placed mission fixtures, and
disables the temporary member during cleanup. It prints statuses and boolean
results, never response bodies, passwords or bearers. Review cleanup results.
It includes synthetic project reads/mutations, scoped and external MCP sessions,
shared-host scheduler denials, shared mission sessions for all roles, share
revocation and account disabling. Its report explicitly leaves live machine
lifecycle and desktop coverage pending; a passing probe alone is not
completion of this acceptance procedure. It never rents a VM or starts a harness.
