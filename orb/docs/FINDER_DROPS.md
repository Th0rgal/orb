# Finder drops

Drop files onto the composer in New Agent or an existing conversation.
On This computer, the draft receives quoted original paths, without copying or
uploading file contents. On Core/remote machines, the files are uploaded to the
selected project's shared context under attachments/<UUID>/<original name>.
A project is required for remote uploads. Clipboard image paste is unchanged.

Native macOS drag positions are window points even though Tauri labels them
PhysicalPosition; do not divide them by Retina devicePixelRatio. Other platforms
use the physical-pixel conversion. The native relay authorizes reads of the
dropped files. Duplicate relay/native events are suppressed, while successive
user drops remain distinct. Changing the draft scope/destination mid-upload must
not insert the old result into the new draft.

## Verification — 2026-09-27

- 12 focused Vitest checks pass (composer-drop, uploads, upload-composer).
- TypeScript checking and native debug build pass.
- Physical Finder gesture into the native Tauri app: quoted local path inserted.
- Local mission 8ce606b1-1e0c-442f-9b44-c8f75869c2a3 read the original file and
  returned the exact unique marker. Filename included spaces and é.
- Remote mission 1f7a795f-070e-4fc1-a769-333099448719 on Ashur read shared context
  and returned the same marker.
- After changing the fixture's contents, a physical Finder drop into that remote
  mission's follow-up bar uploaded a new context path. Its response returned the
  new marker, confirming follow-up hydration and no overwrite of the first file.

The opt-in finder-live.test.ts uses a mode-0600 connection file supplied locally
at /tmp/orb-finder-connection.json; it never runs without ORB_FINDER_LIVE=1.
It creates only bounded read-only test work in orb-finder-validation.
