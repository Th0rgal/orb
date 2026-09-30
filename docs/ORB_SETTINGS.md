# Orb settings and shared SSH addresses

Orb iOS opens Settings from the profile icon, with Backend, Providers and Machines.
The backend connection and credential owner determine available provider actions.
Cloud accounts retain their existing provider-dashboard links; opening a website
on the phone does not authenticate a browser profile running on Core.

## SSH address book

The authenticated settings API shares non-secret SSH contact information among
clients of the same backend. Records are not execution nodes: saving an address
does not enroll a machine, add credentials, or authorize an SSH connection.

- `GET /api/settings/ssh-hosts` returns an array of records.
- `POST /api/settings/ssh-hosts` accepts `{name, host, user, port, note}`.
- `PUT /api/settings/ssh-hosts/:id` accepts those fields plus `revision`.
- `DELETE /api/settings/ssh-hosts/:id?revision=N` deletes the matching revision.

Records contain `id` (server UUID), `revision` (starts at 1), and the five address
fields. POST is idempotent by normalized host/user/port and preserves an existing
record's name and note. PUT rejects a stale revision or duplicate target with
409; DELETE rejects a stale revision with 409. A missing record returns 404.
Names/hosts/users/notes are bounded; ports must be integers in 1–65535.

The store uses a process mutex and atomic file replacement at
`{working_dir}/.sandboxed-sh/ssh-hosts.json`. Corrupt data fails closed rather than
being overwritten. Back up this file with the backend's persistent data. It is
independent of general settings updates and does not store private keys/passwords.

Desktop offers a preview before importing `orb.customMachines` into the selected
backend. Existing SSH targets are preserved; source data remains available for
recovery and older backends. Import completion is tracked per backend. “This Mac”
is never uploaded. Clients isolate caches by backend; offline snapshots are
read-only. A server returning 404 for the collection retains desktop local mode
and displays an update message on iOS.

## Rollout

Deploy the backend before the updated desktop and iOS clients. Existing clients
continue working. Verify create/update/delete across desktop and iOS on the same
backend, including a stale editor returning 409. Rollback of clients does not
remove the server address book. Keep the existing iOS bundle ID and TestFlight
group; allocate a build number above the latest App Store Connect build.

Validation: `cargo test -j 1 --lib ssh_hosts`; `cd orb && pnpm exec vitest run
tests/ssh-hosts.test.tsx`; Xcode `OrbSettingsTests`, `OrbProjectAppearanceTests`,
and the settings UI flow against `TestsSupport/orb_fixture_server.py`.
