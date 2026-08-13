---
name: release
description: >
  This skill should be used when the user asks to "cut a release", "release the
  guild", "ship it", "create a release", "tag a version", "publish a release",
  "guild release", or wants to finalize completed requirements into a versioned
  release. Renames CHANGELOG Unreleased to a version, snapshots completed REQs
  from the board export, and creates an annotated git tag. Does not push.
version: 2.0.0
user-invocable: true
---

# Guild Release — Archive and Tag a Version

Finalize completed guild requirements into a versioned release: stamp the `CHANGELOG.md` Unreleased section with a version, snapshot the completed requirements from the board export into a dated release directory, and create an annotated git tag.

Status is a **column** in the guild database — there are no status subdirectories and no ticket
files. All board lookups and moves go through the guild CLI. Bind it once and reuse:
```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
```

## Arguments

- `--dry-run` — print the full plan without making any changes
- `--only REQ-NNN[,REQ-MMM]` — release only the named requirements (default: every `done` requirement not named in a previous release snapshot)

## Steps

### 1. Preconditions

Run in parallel:
- `git rev-parse --is-inside-work-tree` — confirm git repo
- `git status --short` — check for uncommitted changes
- `git tag --list --sort=-v:refname` — list existing tags
- Read `.guild/config.yaml` — confirm the guild exists (v5 has no `state.yaml`)

Stop conditions:
- Not a git repo → `Not inside a git repository. Guild release requires git.`
- No `.guild/config.yaml` → `No guild found. Nothing to release.`
- Uncommitted changes → ask:
  ```
  You have uncommitted changes. A release should be a clean point in history.
  Continue anyway? (yes / no)
  ```
  Default to stopping on "no".

### 2. Determine Scope

Find requirements to include:

- If `--only REQ-NNN,...` provided: use exactly those.
- Otherwise: list the done requirements with `"$GUILD" list req done` — include every one that is
  NOT already listed in a previous release snapshot under `.guild/releases/*/RELEASE.md`.

If the resulting set is empty, stop with:
```
No completed requirements to release since the last release.
```

### 3. Pre-release Gate

A task's status is the subdirectory it lives in (`tasks/{todo,in-progress,done,failed}/`), not a frontmatter field. `guild list task` prints `<ID> <status> <agent> <requirement>`, so a REQ's tasks come from one awk filter:

```bash
"$GUILD" list task | awk '$4=="REQ-NNN"'
```

For each requirement in scope:

1. Find all its tasks with the awk filter above.

2. **Warn (do not block)** if ANY task for an included requirement is:
   - `failed` — these are **user-waived** (the user chose "skip" when the task failed; the waiver
     is noted in the ticket's Work Log). List them and ask:
     ```
     These tasks for included requirements were waived (failed, user chose not to retry):
       TASK-NNN: {title}
     The release will note them. Continue? (yes / no)
     ```
   - `in-progress` or `todo` → list them and ask:
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

### 7. Snapshot the Released Requirements

> **ARCHIVING IS PENDING A LATER STAGE — this step no longer moves anything.**
>
> v4 archived a release by moving `.guild/requirements/done/REQ-NNN.md` and friends into
> `.guild/archive/{version}/`. Those files do not exist in v5: the board is a database, status is a
> column, and there is no `guild archive` and no `guild delete` in Stage 1. A file-moving step here
> would silently do nothing (the `rm`/`mv` targets are absent) while reporting that it archived N
> requirements — which is worse than not running at all.
>
> What replaces it, and what is deferred:
> - **Replaced now:** the release snapshot below, taken from `guild export`. That export is
>   markdown, is committed, and is exactly the PR-reviewable record the archive used to be.
> - **Deferred:** actually retiring a released requirement from the live board. Until a later
>   stage adds that, a `done` requirement simply stays `done` on the board. It does not block
>   anything — `guild next` only ever looks at open tasks — it just keeps appearing in
>   `guild board`'s Requirements list.

Regenerate the export and copy it into a release snapshot directory. `guild export` rebuilds
`.guild/export/` wholesale from current state, so it is a true snapshot of the moment:

```bash
"$GUILD" export
mkdir -p ".guild/releases/{version}"
for req in {the REQs in scope}; do
  cp ".guild/export/$req.md" ".guild/releases/{version}/$req.md"
  if [ -f ".guild/reviews/$req.md" ]; then
    cp ".guild/reviews/$req.md" ".guild/releases/{version}/$req.review.md"
  fi
done
```

Each exported REQ file already inlines that requirement's plans, tasks, work logs and review
findings — so the snapshot carries everything the v4 archive did, in one file per requirement,
without moving anything out from under the live board.

**Never snapshot `.guild/docs/`** — the knowledge base is evergreen. Researcher findings persist
across releases so future architects and researchers can reuse them.

**Never snapshot `.guild/qa/`** — the QA discipline's charter, ledger, regression manifest,
sessions and missions are evergreen and span releases. The standing "Product QA & E2E Regression"
umbrella requirement stays `in-progress` and is never included in a release.

### 8. Write the Release Record

IDs are derived in SQL (`MAX(n) + 1`) and are never reused, so nothing has to be reset or carried
across a release. `last-checkin` is a database row written only by `"$GUILD" checkin` — do NOT
touch it here.

Write `.guild/releases/{version}/RELEASE.md`. This file is also what Step 2 reads back to decide
what has already been released, so the REQ IDs must appear in it verbatim:

```markdown
---
released: {today's date}
version: {version}
highest-req-at-release: {`guild next-id req` - 1}
highest-task-at-release: {`guild next-id task` - 1}
highest-plan-at-release: {`guild next-id plan` - 1}
requirements:
  - REQ-NNN: {title}
  - REQ-MMM: {title}
---

# Release {version} Snapshot

Each requirement in this release is captured beside this file as `REQ-NNN.md`, exported from the
board at release time with `guild export` — plans, tasks, work logs and review findings inlined.

The requirements themselves remain on the live board as `done`. v5 has no archive command yet;
retiring released requirements from the board is pending a later stage.

IDs are derived in SQL and are never reused, so they remain continuous across releases.
```

### 9. No Board Table to Update

There is no `BOARD.md` — `"$GUILD" board` renders live from the database. Released requirements
stay on it as `done` (see the note in step 7); nothing here edits board state.

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

If pre-commit hooks fail, surface the error and stop. The snapshot files have already been written
— instruct the user to resolve the hook issue and commit manually. Nothing was moved or deleted, so
re-running the release after fixing the hook is safe.

### 11. Report Result

```
Released {version}
==================

Changelog: CHANGELOG.md (new [{version}] section added)
Snapshot: .guild/releases/{version}/
  {N} requirement(s), exported with plans, tasks, work logs and findings inlined

  Note: released requirements stay on the live board as `done` — v5 has no
  archive command yet, so nothing was moved off the board.

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

Files to write (nothing is moved or deleted):
  .guild/releases/{version}/REQ-NNN.md        (from `guild export`)
  .guild/releases/{version}/REQ-NNN.review.md (if a review report exists)
  .guild/releases/{version}/RELEASE.md
  ...

Git actions:
  Commit: chore(release): {version}
  Tag: {version} (annotated)
  Push: NOT executed

Warnings:
  {any warnings from the pre-release gate}
```

Do not create files or run any git commands. (Note that `--dry-run` must NOT run
`"$GUILD" export` either — the export rebuilds `.guild/export/` on disk.)

## Rules

- **Never push** — the user decides when to push commits and tags
- **Never skip hooks** — do not pass `--no-verify`
- **IDs are derived, not counters** — derived in SQL as `MAX(n) + 1` and never reused, so nothing is reset and the sequence stays continuous
- **Never delete or move board state** — a release only ever COPIES the export into a snapshot
- **Archiving is deferred** — released requirements stay `done` on the live board; v5 has no
  `guild archive`, and a step that pretended to move files would report work it did not do
- **CHANGELOG.md lives at repo root** — not inside `.guild/`
- **`.guild/docs/` is evergreen** — never snapshot or touch the knowledge base during a release
- **`.guild/reviews/REQ-NNN.md` is COPIED into the snapshot** — unlike `docs/`, review reports are
  per-requirement history, not cross-cutting knowledge. The original stays where it is.
- **Pre-release gate only warns, never blocks** — user-waived (`failed`) and not-yet-done tasks
  warn and ask; there's no automatic-fix-loop escalation token to block on anymore
- **In-progress tasks stay on the board** — they are not included in the snapshot
- **One commit, one tag** — both are created atomically at step 10
