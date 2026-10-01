# Project skills in Orb

Project skills are ordinary synchronized project files. Put each skill in
`skills/<name>/SKILL.md`, with supporting files alongside it, for example:

```text
Context/architecture.md
skills/review/SKILL.md
skills/review/references/checklist.md
```

All missions in that project inherit its skills. There is no Library entry or
per-agent selection. `@context/skills/review/SKILL.md`, `@context/skills`, and
`@context/Context` resolve to the synchronized originals. Editing those paths
uses the existing project-file synchronization and conflict handling; it does
not edit a mission attachment or a pinned skill snapshot.

For native discovery, use the usual skill frontmatter:

```markdown
---
name: review
description: Review a proposed change using the project checklist.
---
Read references/checklist.md before reviewing the change.
```

Names are lowercase letters, numbers and hyphens, at most 64 characters. The
frontmatter name must match its folder. Plain Markdown without frontmatter is
adapted into a native copy that retains the complete original text and all
supporting files. A source notice directs the agent to edit the original.

## Preparation and ownership

Orb prepares the existing desktop replica before creating a local-origin
mission and before accepting a follow-up draft. The native launch path also
refreshes before every turn, including scheduled wake-ups. Core prepares the
project store and mounts it into container execution when applicable. Remote
launches use the node's existing continuously synchronized project replica.
The remote job wrapper prepares native discovery in its final working
directory before starting the harness.

Native discovery uses these managed entries in the execution directory:

| Harness | Project discovery directory |
| --- | --- |
| Codex | `.agents/skills/<name>` |
| Claude Code | `.claude/skills/<name>` |
| OpenCode | `.opencode/skills/<name>` |
| Gemini CLI | `.gemini/skills/<name>` |
| Grok | `.grok/skills/<name>` |
| ChatGPT UI / hosted agents | No project filesystem discovery integration; unsupported |

Entries normally link individual skill folders to the live synchronized tree.
When links cannot be created, Orb generates source-labelled copies and refreshes
those copies before launch/resume, including retained copies in previously used
harness paths that another harness can also scan. Preparation does not replace `.claude`,
`.codex`, `.opencode`, or any harness configuration file.

`.orb-project-skills.json` tracks managed links and generated file hashes.
Preparation removes deleted/renamed entries across previously used harnesses.
Existing native entries and changed generated copies cause an explicit collision
error instead of being overwritten. Compatible local discovery aliases are
checked as well, including OpenCode's singular `.opencode/skill` Library path.
Core checks the actual per-mission native roots when its execution directory
differs from its private state directory. It removes stale project entries
before Library preparation so Library skills can reuse deleted names.
Library skill writers likewise track only their own entries rather than deleting
an entire native skills directory. Untracked legacy Library entries are preserved;
a same-name collision requires resolving ownership rather than automatic adoption.
Library updates stage complete supporting files and journal old/new hashes before
replacing directories. A subsequent launch recovers an interrupted owned update
while still refusing outside edits.

A working directory with managed skills is bound to its source project. Another
project, or a project-less mission, cannot launch there or beneath it. Choose a
separate directory outside that tree. This deliberate refusal avoids replacing
skills underneath an already-running harness. Once the owning project deletes
all skills and launches/resumes to clean its entries, the directory can be reused.

A shared filesystem lock serializes preparation, including Library writers.
Native configuration remains in the existing per-mission state/routing paths.
Preparation failures report a retryable error and do not start the harness.
Local preflight errors retain the composer draft; Core/remote execution errors
retain the persisted mission prompt and provide the preparation error.

Skill preparation requires Python 3 on the execution machine when there are
skills or managed entries to check. Projects without either skip the Python
helper. Skills with YAML frontmatter also require PyYAML for that Python
interpreter (`python3-yaml` on Debian/Ubuntu). Core images and new container
bootstrap provision it; desktop and existing leaf-machine installations report
an actionable dependency error if it is missing. Frontmatter is parsed as YAML
before its required name/description strings are validated. Grok and Gemini require trusted working directories. Orb checks their native
listings and refuses to launch if trust or configuration hides project skills.
Orb does not change the user's trust configuration. Core resolves the selected
Grok/Gemini CLI with the runner's existing availability/installation logic before
inspection, including configured paths and runtime prefixes. Gemini authentication
setup merges only the selected auth type, retaining folder trust, disabled skills,
MCPs, and the remaining user settings; invalid existing JSON is not overwritten. Native entries are also
refused inside the synchronized source tree so discovery metadata cannot
contaminate project-file synchronization.

## Discovery and edits

Every new launch/resume refreshes the replica and managed entries. Native
symlinks expose source edits directly; this does not guarantee that a running
harness reloads its cached description/instructions immediately. Copied skills
refresh on the next launch/resume, not continuously during a turn.

| Harness | Native discovery/reload behavior and evidence |
| --- | --- |
| Codex | Official documentation supports symlinked folders and automatic skill changes, with restart as a fallback. `skills/list` on 0.159.3 discovered this implementation's link as a repository skill and reported the original source path. |
| Claude Code | Current official documentation supports symlinked skill folders. It documents live `SKILL.md` detection, `/reload-skills` for newly created discovery directories, and separate limits for supporting files. Native startup metadata on 2.1.286 listed this implementation's symlinked skill. Runtime instruction following through Orb is still required. |
| OpenCode | `opencode debug skill` on 1.18.34 discovered this implementation's link and parsed its description/body. New CLI processes scan discovery paths; live session reload was not tested. |
| Gemini | Official documentation lists workspace `.gemini/skills` and `/skills reload` (alias `/skills refresh`). The 0.62.0 CLI was installed only in a disposable prefix; its native `skills list --all` discovered this implementation's link with private fixture trust settings. Untrusted workspaces omitted both links and copies. |
| Grok | `grok inspect --json` on 1.0.44 discovered this implementation's link after trusting only a disposable test directory. An untrusted directory omitted both links and native copies. New-process discovery was verified; live session reload was not tested. |

Sources:
[Codex skills](https://developers.openai.com/codex/skills/),
[Claude Code skills](https://code.claude.com/docs/en/skills),
[OpenCode skills](https://opencode.ai/docs/skills/),
[Gemini CLI skills](https://geminicli.com/docs/cli/skills/).

All five native scanners also detected an added plain Markdown skill, its rename,
its deletion, and cleanup after deleting the final skill. These were new scanner
processes, not Orb mission resumes. The native listing evidence verifies discovery,
not that a mission read its
supporting reference or followed its instructions. See the validation report
for exactly what was and was not exercised through Orb.
