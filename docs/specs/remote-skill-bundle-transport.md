# Remote skill bundle transport

Core sends the Library install script separately from the `bash -lc` command
argument. The script is carried in UTF-8-safe environment chunks of at most
96 KiB each, reconstructed with the shell's builtin `printf` into a private
`mktemp` file, opened on fd 4 and unlinked before execution. Chunk variables
are unset before `sh` reads the script from fd 4. The descriptor is closed
before launching the harness. Prompt delivery independently uses fd 3.

The encoded bundle budget is 1 MiB, not an argv budget. Safe regular UTF-8
files up to 64 KiB each are included, with SKILL.md files taking priority.
The existing path, depth, symlink and credential-filename filters still apply.
Files exceeding these resource limits remain excluded. An existing SKILL.md
does not prevent installing missing references, and existing files are kept.

Bundle content must never be interpolated into a `-c` argument or passed as
one environment value: both are subject to Linux's 128 KiB per-string limit.
Only chunk variable names occur in the staging command. All five remote
harness paths and the local Core install path use the same staging helper.
No node protocol or binary upgrade is required.

`TurnOutcomeTests` exercises a bundle larger than 128 KiB through a real
`bash -lc`, verifies every reference byte arrives, bounds the command and
environment entries, and checks prompt delivery and chunk-variable cleanup.
