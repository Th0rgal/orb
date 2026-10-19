# Publishing the Android Dashboard

Two stages: a tag-driven GitHub release (CI builds the signed APK), then a
Zapstore publish with **zsp**. Read this before improvising — every quirk below
was hit in practice and cost real time.

## Stage 1 — GitHub release (CI)

1. Bump `orbVersionCode` (+1) and `orbVersionName` in `gradle.properties` (CI can override the code with `-PorbVersionCode=N`).
   Convention: minor bump per feature release (`1.4.0` → `1.5.0`).
2. Optional local sanity build (exercises R8 + signing like CI):
   ```bash
   cd android_dashboard
   set -a; source keys/release-secrets.env; set +a
   export RELEASE_KEYSTORE=$PWD/keys/release.jks
   ./gradlew :app:assembleRelease
   ```
3. Commit, push, tag, push the tag:
   ```bash
   git tag android-vX.Y.Z && git push origin master android-vX.Y.Z
   ```
   The `Android APK` workflow builds the signed APK and creates the GitHub
   release with asset `sandboxed-dashboard-android-vX.Y.Z.apk`.

> CI and local builds are **not byte-identical** (signing timestamps differ).
> The canonical artifact is the GitHub release asset — always publish that one
> to Zapstore, not a local build.

## Stage 2 — Zapstore (zsp)

Zapstore is a Nostr app store: publishing signs three events (app kind `32267`,
release `30063`, software asset `3063`) to `wss://relay.zapstore.dev`, with the
APK blob on `cdn.zapstore.dev` (Blossom).

**Use `~/go/bin/zsp` (v0.4.10+).** It is the only tool that currently works
end-to-end: it emits the `apk_certificate_hash` tag the relay requires and its
uploads to cdn.zapstore.dev succeed. Do NOT use the old Dart `zapstore` CLI
(0.2.4) — it predates the relay's validation rules; see Appendix.

### Prerequisites

- `~/go/bin/zsp` installed, with its bunker pairing present under
  `~/Library/Application Support/zsp/bunker-keys/` (macOS). The maintainer's
  signing pubkey is `7ebbce1843a17cd778a5e169e3d2f679f5ac7b5125d1c43d265e190f7b27538c`.
- The maintainer reachable: **every publish requires them to approve signing
  requests in nsec.app** (icon/APK Blossom auth + the three events). If a sign
  request sits unapproved, zsp fails with
  `failed to sign auth event: context canceled` — that is a timeout, not a
  pairing problem. Ask them to keep nsec.app open, then retry.
- `zapstore.yaml` in this directory. zsp's schema: `release_source` (path to
  the APK), `repository`, `website`, `icon`, `name`, `summary`, `description`,
  `tags` (a **YAML list** — the Dart CLI wanted a string; keep the list),
  `license`. Validate after edits:
  ```bash
  GITHUB_TOKEN="$(gh auth token)" ~/go/bin/zsp publish --check zapstore.yaml
  ```

### Publish

```bash
cd android_dashboard

# 1. Place the CI-built APK where release_source points
TAG=android-vX.Y.Z
gh release download "$TAG" --repo adrienlacombe/sandboxed.sh \
  --pattern "sandboxed-dashboard-${TAG}.apk" --dir /tmp/zs-$TAG
mkdir -p app/build/outputs/apk/release
cp /tmp/zs-$TAG/*.apk app/build/outputs/apk/release/app-release.apk
shasum -a 256 app/build/outputs/apk/release/app-release.apk

# 2. Publish (maintainer approves sign requests in nsec.app as they appear)
SIGN_WITH="bunker://7ebbce1843a17cd778a5e169e3d2f679f5ac7b5125d1c43d265e190f7b27538c?relay=wss://relay.nsec.app" \
GITHUB_TOKEN="$(gh auth token)" \
  ~/go/bin/zsp publish -q --skip-preview --skip-certificate-linking zapstore.yaml
```

zsp flag behavior, learned the hard way:

- `-q` is **required when not on an interactive TTY** (agents, CI): the final
  "Ready to Publish" confirmation otherwise dies with
  `could not open a new TTY`. `-q` also suppresses ALL output — exit code 0 is
  your only success signal, so always verify on the relay afterwards.
- If the version already exists on the relay, zsp stops with
  `Asset sh.sandboxed.dashboard@X.Y.Z already exists` (with `-q` it may exit 0
  **silently without publishing**). Add `--overwrite-release` to republish.
- The release `d` tag becomes `sh.sandboxed.dashboard@X.Y.Z` (the APK's
  versionName, no `android-v` prefix). Keep it that way — it's the existing
  convention for all prior releases.

### Verify

```bash
nak req -k 32267 -k 30063 -k 3063 \
  -a 7ebbce1843a17cd778a5e169e3d2f679f5ac7b5125d1c43d265e190f7b27538c \
  wss://relay.zapstore.dev | jq -c '{kind, id: .id[0:8],
    d: ([.tags[]|select(.[0]=="d")|.[1]][0]),
    v: ([.tags[]|select(.[0]=="version")|.[1]][0])}'
```

Check: the newest 30063 has `d=sh.sandboxed.dashboard@X.Y.Z`, its `e` tag
equals the newest 3063's id, the 3063 carries `apk_certificate_hash`
`a98fa7bc…` (the release keystore cert; recompute with
`apksigner verify --print-certs`), and the blob resolves:
`curl -I https://cdn.zapstore.dev/<apk-sha256>` → 200.
Listing: https://zapstore.dev/apps/sh.sandboxed.dashboard

### Cleaning up a bad publish

The relay accepts kind-5 deletions. To remove stray events (e.g. a duplicate
release under a wrong `d` tag), sign a kind 5 via the bunker with `e` tags for
each event id, an `a` tag for the addressable release
(`30063:<pubkey>:sh.sandboxed.dashboard@<bad-version>`), and `k` tags, then
publish it to `wss://relay.zapstore.dev` with nak. Replaceable events also
won't overwrite on **equal** `created_at` — bump the timestamp when
republishing an addressable event.

## Appendix — why not the Dart zapstore CLI

Tried on 2026-06-12 (v1.5.0) before discovering zsp handles everything; kept
here so nobody repeats it. The Dart CLI 0.2.4 (last version with `publish`;
the zapstore-cli repo's master is a Go rewrite without it) fails four ways:

1. Its uploads to cdn.zapstore.dev surface as "connection reset by peer"
   (the server answers 401 early — its whitelist rejects this client's upload
   flow; zsp's works).
2. It treats Blossom `201 Created` as an error (expects 200).
3. The relay requires `NEW_FORMAT=1` (undocumented env toggle) — old-format
   kinds (1063) are rejected.
4. It emits `apk_signature_hash` where the relay demands `apk_certificate_hash`,
   so kind 3063 is always rejected; fixing it requires manual event surgery
   with jq + nak.

Also NIP-46 trivia that applies to any nak-based signing: nak uses a random
client key per run unless `NOSTR_CLIENT_KEY` is set, which burns a bunker
URL's one-time `secret=` on the first run (`already connected` forever after).
A persistent key lives at `~/.config/zapstore/client-key`.

## Security notes

- Never commit or paste bunker URLs containing a `secret=` parameter, any
  Nostr private key, or the contents of `keys/release-secrets.env`.
- All signing goes through NIP-46 (nsec.app); the identity key never leaves
  the maintainer's signer. Don't ask for or handle nsecs directly.
