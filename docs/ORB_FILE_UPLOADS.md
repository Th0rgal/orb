# Orb file attachments

The composer's **+ → Upload file or image…** works even when the project has no
context files. Desktop uses a native multi-file picker; the browser uses a file
input. A local agent receives the selected absolute path without a server copy.
Core and remote-node agents receive a path returned by the destination's upload
receipt. Files are uploaded before their paths enter the draft.

A machine/backend change is checked again on Send. References still in the
draft are transferred to the new destination and rewritten before launch or
follow-up. Removing a reference prevents another transfer. Failed transfers
preserve the draft and show an error. Selecting files never launches a mission.

`POST /api/uploads` is dashboard-authenticated and accepts `{node_id,name,
data_base64}`. Core stores locally for `core`, or forwards to the configured
node's bearer-authenticated `POST /uploads`. There is no host path supplied by
the client. Receipts contain absolute path, byte count and SHA-256. These paths
are ordinary prompt references, not project-snapshot attachments, so uploads
also work for remote launches and follow-ups without the legacy attachment
materializer.

Remote uploads are limited to 20 MiB per file and four concurrent store/forward
operations per process. Native local references have no upload size limit.
Bytes are stored under unique UUID directories, never overwriting a file of the
same name. A failed write removes its partial file. Storage is
`<resolved .sandboxed-sh>/uploads` on Core and `<node work root>/uploads` on nodes.
Uploaded files persist for later turns; removing their text reference does not
delete the server copy. They must not be swept as orphaned mission directories.
An eventual project/file retention UI should expose deletion explicitly.

Node binaries need the upload route; old nodes refuse clearly rather than
silently placing files on Core. No file-server credential reaches Orb or a
mission. Desktop binary reads are limited to files explicitly selected in that
process's native picker. Historical project mentions (`@file`, `@controller`)
retain their existing snapshot behavior.

Validation: byte-exact binary persistence and traversal rejection unit tests;
an actual temporary node rejects unauthenticated uploads and accepts binary
uploads; composer tests cover an empty context menu and failure preservation;
Playwright covers the file chooser, byte encoding, and Core → Ashur switching
before Send. The desktop Rust build and frontend build pass.

Draft persistence keeps uploaded paths and their destination. After restarting
Orb, an already-uploaded file can be reused on the same server/machine. Moving
a restored draft to another machine may require selecting the original file
again: browser file bytes and native-picker read authorization are not retained
across restarts. A transfer failure leaves the draft intact.

Production verification on 22 September 2026: Core deployed commit `55867c859`
through the guarded deploy endpoint, followed by a healthy Hermes restart.
The desktop debug build was relaunched with the native picker commands. The
merged UI passed 325 unit/component tests and both browser tests (file chooser
with machine switching, and image paste). Live binary uploads were forwarded
through Core and read back byte-for-byte on Core, Ashur, Nippur, old-agent,
sepolia and DGX Spark; remote reads used the `sandboxed-node` account. Only the
diagnostic upload files were removed afterward.

Babylon also passed on the later 22 September retry: resumable transfer of the
node binary completed, the update was installed, and Core→Babylon binary upload
passed byte-exact readback as the node service user. The diagnostic file was
removed. Babylon is now uncordoned and a subsequent OpenCode mission completed.
The previous node binary remains backed up. Intermittent network degradation
was observed earlier; see `archive/HARNESS_PERFORMANCE_AUDIT.md` for the evidence.

## Restored drafts (fixed October 2026)

An uploaded file is reused on Send when its destination matches and it was
uploaded to the same backend endpoint. The in-memory connection counter is not
enough on its own: it moves on every app start and reconnect, so a restored
draft used to re-transfer an already-uploaded `attachments/<id>/…` file, the
desktop refused to re-read the original (read authorization does not survive a
restart), and Send failed with two toasts ("Choose this file again using the
file picker"). Now:

- same destination and endpoint: the uploaded path is sent as is;
- the file must move and its original is gone: only that mention is removed,
  an inline "File no longer available — re-attach" notice names it, the rest of
  the draft is kept and the next Send goes through;
- other transfer failures still keep the whole draft and show one error.

Upload names are NFC-normalized (macOS hands out NFD) and mention matching
compares NFC, so `Questões (1).pdf` typed and picked match.

## Folders and many files

Desktop: **+ → Upload folder…** (native folder picker), multi-select in the
file picker, drag and drop of several files and folders (native drops are
walked by the desktop; browser drops through `webkitGetAsEntry`), and pasting
several files. `.DS_Store`, `.git`, `node_modules` and similar junk are skipped;
for shared context, paths Core would refuse (dotfiles, keys) are skipped up
front and counted on the chip.

A folder uploads into one batch, `attachments/<batch>/<Folder>/<path>` for
shared context or `<uploads>/<batch>/<Folder>/<path>` on a machine, with four
files in flight, three attempts per file, and cancel. One chip shows the file
count, size and aggregated progress and expands to per-file state; failed files
offer Retry or Skip failed. When every file landed, the draft gets one folder
mention (`@"attachments/<batch>/Folder/"`). More than 200 files or 500 MiB
asks first; more than 2000 files or 2 GiB is refused. A local agent gets the
folder's own path without copying.

Core accepts `batch_id` (a UUID) and `relative_path` on `POST /api/uploads` and
upload sessions. The path is NFC-normalized, relative, at most 32 segments and
1024 bytes, each segment a plain filename; directories are created by Core and
never followed through links; an existing file is never replaced. A node that
predates this ignores the fields and stores files flat; Orb then mentions each
file instead of the folder.

Mobile: iOS's document picker now selects several files at once (Android already
did). Folder upload (iOS document picker with folders, Android SAF tree) is a
noted gap on both.
