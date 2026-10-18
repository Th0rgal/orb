# Skill delivery

A mission can receive skills from two places:

- **Library skills**: `skill/<name>/SKILL.md` in the git-backed Library.
- **Project-file skills**: `skills/<name>/SKILL.md` in a project's synchronized
  context files. See [PROJECT_SKILLS.md](PROJECT_SKILLS.md).

This page covers Library skills: which ones a mission gets, and how they reach
local and remote executions.

## Frontmatter contract

```yaml
---
name: lean-proofs
description: ...
metadata:
  sandboxed:
    audience: [mission, coordinator, local]  # absent => [mission, local]
    scope: global                            # absent => on-demand
---
```

- `audience` says who the skill is for. Missions only receive skills whose
  audience includes `mission`, unless something selects them by name (see
  below). Coordinator-only skills (`[coordinator]`) are never delivered to the
  default host workspace.
- `scope: global` delivers the skill to every mission whose audience matches.
  `on-demand` (the default) means it is delivered only when selected.

`GET /api/library/skill` and `GET /api/library/skill/:name` return
`audience`, `scope` (`global` | `on-demand`) and `line_count` alongside the
existing fields.

## The three scopes

```text
mission skills = base ∪ globals ∪ project      (deduplicated, stable order)

base    = workspace.skills, if non-empty
          else, for the default host workspace: every Library skill with audience ∋ mission
          else nothing
globals = Library skills with scope=global and audience ∋ mission
project = the project's Library skill list (projects.db)
```

Names that are not in the Library are logged and skipped. One function,
`workspace::skill_delivery::resolve_skill_delivery`, implements this rule for
local and remote missions.

Project skill lists:

- `GET /api/projects/:slug/skills` → `{slug, skills, missing}`
- `PUT /api/projects/:slug/skills` with `{"skills": ["name", ...]}`

Names must be lowercase letters, digits and hyphens, at most 64 characters.
Names that are not in the Library are accepted, and `GET` reports them under
`missing`. Project records (`/api/projects`) also include `skills`.

To preview what a mission would receive:
`GET /api/library/skill-delivery?workspace_id=<uuid>&project=<slug>` returns
`{skills: [{name, reasons: [base|global|project]}], missing: [...]}`.

## Delivery paths

### Local missions (host or container workspaces)

When it prepares the mission directory, the core writes copies that it
manages and tracks with `.orb-library-skills.json`:

| Harness | Directory |
|---|---|
| all | `.opencode/skill/<name>` |
| Claude Code | `.claude/skills/<name>` |
| Codex | `.codex/skills/<name>` |
| Antigravity | `.agents/skills/<name>` |
| Vibe | `.vibe/skills/<name>` |
| Grok | `.grok/skills/<name>` |

When `workspace.skills` is set, OpenCode's skill allowlist covers the whole
resolved set, so globals and project selections are not denied.

### Remote node missions

The core resolves the same set and builds a deterministic `tar.gz` of
`skills/<name>/...`. Entries are sorted, mtime/uid/gid are zero, frontmatter
is normalized like the native writer, and `<encrypted>` tags are stripped.
The archive is uploaded to the node's existing `POST /uploads` as
`library-skills-<sha12>.tar.gz`, so no node update is needed. The core keeps
an in-memory cache keyed by (node, sha256) so an unchanged set is not
uploaded again. An upload failure is logged, and the mission launches without
Library skills.

The job prefix runs these steps in the final cwd on every turn:

1. `prepare_library_skills` **cleanup** removes the entries it owns
   (`.sandboxed-library-skills.json`, with a fingerprint per entry). An entry
   that someone edited becomes user-owned: it is left in place and dropped
   from the manifest.
2. Project-file skill preparation runs unchanged. It is strict, and a
   failure aborts the job.
3. `prepare_library_skills` **install** verifies the sha256, extracts the
   archive once into
   `${XDG_CACHE_HOME:-~/.cache}/sandboxed-sh/library-skills/<sha>`, and
   copies each skill into the harness's native directory. Extraction rejects
   absolute paths, `..`, links and anything that is not a regular file. A
   name that already exists is skipped with a notice on stderr.

Library steps are best-effort. If `python3` is missing, a step fails, or the
upload is gone and the cache is empty, the job prints a notice and continues.

## Precedence

When two skills share a name, this one wins:

1. user-managed entries already in the native directory
2. project-file skills (`skills/<name>` in project context)
3. Library skills (base, global or project-selected)
