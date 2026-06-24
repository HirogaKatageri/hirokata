---
name: release
description: >
  This skill should be used when the user asks to "cut a release", "release the
  guild", "ship it", "create a release", "tag a version", "publish a release",
  "guild release", or wants to finalize completed requirements into a versioned
  release. Renames CHANGELOG Unreleased to a version, archives completed REQs,
  and creates an annotated git tag. Does not push.
version: 1.0.0
user-invocable: true
---

# Guild Release — Archive and Tag a Version

Finalize completed guild requirements into a versioned release: stamp the `CHANGELOG.md` Unreleased section with a version, move completed requirement artifacts into a dated archive, and create an annotated git tag.

## Arguments

- `--dry-run` — print the full plan without making any changes
- `--only REQ-NNN[,REQ-MMM]` — release only the named requirements (default: all requirements with `status: done` since last release)

## Steps

### 1. Preconditions

Run in parallel:
- `git rev-parse --is-inside-work-tree` — confirm git repo
- `git status --short` — check for uncommitted changes
- `git tag --list --sort=-v:refname` — list existing tags
- Read `.guild/state.yaml` — confirm the guild exists

Stop conditions:
- Not a git repo → `Not inside a git repository. Guild release requires git.`
- No `.guild/state.yaml` → `No guild found. Nothing to release.`
- Uncommitted changes → ask:
  ```
  You have uncommitted changes. A release should be a clean point in history.
  Continue anyway? (yes / no)
  ```
  Default to stopping on "no".

### 2. Determine Scope

Find requirements to include:

- If `--only REQ-NNN,...` provided: use exactly those.
- Otherwise: scan `.guild/requirements/REQ-*.md` — include every requirement with `status: done` that is NOT already present in any `.guild/archive/*/requirements/` directory.

If the resulting set is empty, stop with:
```
No completed requirements to release since the last release.
```

### 3. Pre-release Gate

For each requirement in scope:

1. Find all its tasks (`.guild/tasks/TASK-*.md` with matching `requirement` frontmatter).

2. **Block release** if ANY task for an included requirement has:
   - `status: failed` → report which task and stop
   - A Work Log entry containing the literal token `ESCALATE` that has not been resolved → report and stop

3. **Warn (do not block)** if ANY task for an included requirement has:
   - `status: in-progress` or `status: todo` → list them and ask:
     ```
     These tasks for included requirements are not yet done:
       TASK-NNN: {title} ({status})
     They will remain on the board after release. Continue? (yes / no)
     ```

### 4. Prompt for Version

Read existing tags and suggest the next version:

1. Find the latest semver tag (`vX.Y.Z`). If none, suggest `v0.1.0`.
2. Display:
   ```
   Current version: {latest tag or "none"}
   Requirements in this release: {N}
     REQ-NNN: {title}
     REQ-MMM: {title}

   What version? (e.g. v1.2.0)
   ```
3. Validate the user's input matches `v\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?`. Re-prompt on invalid.
4. Reject the version if a tag with that name already exists.

### 5. Prepare CHANGELOG.md

The changelog lives at **repo root** (`CHANGELOG.md`), NOT inside `.guild/`.

**If `CHANGELOG.md` does not exist**, create it with this skeleton:
```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

```

**If `CHANGELOG.md` exists but has no `## [Unreleased]` section**, insert one immediately after the preamble (before the first `## [version]` heading).

**If the `## [Unreleased]` section is empty** (no bullet points) AND `--only` was not used, warn:
```
The [Unreleased] section is empty. Release anyway? (yes / no)
```

### 6. Build the Release Section

Transform `CHANGELOG.md`:

1. Capture all content under `## [Unreleased]` up to the next `## ` heading or EOF — call this `UNRELEASED_BODY`.

2. If `--only` was used, filter `UNRELEASED_BODY` to keep only bullet points referencing the included REQ IDs; move the rest back under `## [Unreleased]`.

3. For each requirement in scope that is NOT already in `UNRELEASED_BODY`, append a bullet:
   ```
   - REQ-NNN: {requirement title}
   ```
   (This catches requirements completed before the check-in skill started maintaining `[Unreleased]`.)

4. Replace the `## [Unreleased]` heading block with:
   ```
   ## [Unreleased]

   ## [{version}] - {today's date}

   {UNRELEASED_BODY}
   ```

   The new `## [Unreleased]` section is deliberately empty — ready for future work.

### 7. Archive Requirements

Create archive directory `.guild/archive/{version}/` with subdirectories `requirements/`, `plans/`, `tasks/`.

For each requirement in scope:

1. Move `.guild/requirements/REQ-NNN.md` → `.guild/archive/{version}/requirements/REQ-NNN.md`
2. For each plan with matching `requirement: REQ-NNN` in its frontmatter:
   - Move `.guild/plans/PLAN-NNN.md` → `.guild/archive/{version}/plans/PLAN-NNN.md`
   - Move the slice directory `.guild/plans/PLAN-NNN/` (if exists) → `.guild/archive/{version}/plans/PLAN-NNN/`
3. For each task file with matching `requirement: REQ-NNN`, `status: done`:
   - Move `.guild/tasks/TASK-NNN.md` → `.guild/archive/{version}/tasks/TASK-NNN.md`

Leave any `in-progress` / `todo` tasks in place (their files stay in `.guild/tasks/`).

**Never archive `.guild/docs/`** — the knowledge base is evergreen. Researcher findings persist across releases so future architects and researchers can reuse them. Docs are not versioned alongside releases.

**Never archive `.guild/qa/`** — the QA discipline's charter, ledger, regression
manifest, sessions, and missions are evergreen and span releases. The standing
"Product QA & E2E Regression" umbrella requirement stays `in-progress` and is
never included in a release.

### 8. Snapshot Board State

Write `.guild/archive/{version}/STATE-snapshot.md` containing the `state.yaml` counter values at release time:

```markdown
---
released: {today's date}
version: {version}
next-task-at-release: {value from state.yaml}
next-req-at-release: {value from state.yaml}
next-plan-at-release: {value from state.yaml}
requirements:
  - REQ-NNN: {title}
  - REQ-MMM: {title}
---

# Release {version} Snapshot

Requirements included in this release are archived alongside this file.
ID counters are continuous across releases — they are NOT reset.
```

Do NOT reset the `state.yaml` counters. IDs remain continuous across releases to keep archived references stable.

### 9. No Board Table to Update

There is no `BOARD.md`. Once a released requirement's REQ file is moved into the archive (step 7), it
no longer appears in the live requirements view — nothing else to update. Leave the completed task
files for that requirement archived in step 7; any unfinished tasks stay in `.guild/tasks/`.

### 10. Create Git Tag

Run:
```bash
git add CHANGELOG.md .guild/
git commit -m "$(cat <<'EOF'
chore(release): {version}

Release {N} requirement(s):
{one bullet per REQ}
EOF
)"
git tag -a {version} -m "$(cat <<'EOF'
Release {version}

{UNRELEASED_BODY content}
EOF
)"
```

Do NOT push. Do NOT pass `--no-verify`.

If pre-commit hooks fail, surface the error and stop. The archive moves have already happened on disk — instruct the user to resolve the hook issue and commit manually.

### 11. Report Result

```
Released {version}
==================

Changelog: CHANGELOG.md (new [{version}] section added)
Archived: .guild/archive/{version}/
  {N} requirement(s)
  {N} plan(s)
  {N} task(s)

Git:
  Commit {short-hash}: chore(release): {version}
  Tag: {version}

Not pushed. Push with:
  git push && git push --tags
```

## Dry-run Mode

If `--dry-run` is set, execute steps 1–6 to build the plan, then print:

```
Dry run — no changes would be made.

Version: {version}
Requirements to release ({N}):
  REQ-NNN: {title}
  REQ-MMM: {title}

CHANGELOG.md changes:
  ## [Unreleased] → ## [{version}] - {today's date}
  New [Unreleased] section would be created empty

Files to move:
  .guild/requirements/REQ-NNN.md → .guild/archive/{version}/requirements/REQ-NNN.md
  ...

Git actions:
  Commit: chore(release): {version}
  Tag: {version} (annotated)
  Push: NOT executed

Warnings:
  {any warnings from the pre-release gate}
```

Do not create files, move anything, or run any git commands.

## Rules

- **Never push** — the user decides when to push commits and tags
- **Never skip hooks** — do not pass `--no-verify`
- **Never reset ID counters** — archived references must remain valid
- **Never delete files** — archive (move) only
- **CHANGELOG.md lives at repo root** — not inside `.guild/`
- **`.guild/docs/` is evergreen** — never archive or touch the knowledge base during a release
- **Pre-release gate blocks on failed / unresolved ESCALATE** — these must be handled before release
- **In-progress tasks stay on the board** — they are not included in the archive
- **One commit, one tag** — both are created atomically at step 10
