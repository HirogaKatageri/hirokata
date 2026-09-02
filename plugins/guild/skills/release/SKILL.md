---
name: release
description: >
  This skill should be used when the user asks to "cut a release", "release the
  guild", "ship it", "create a release", "tag a version", "publish a release",
  "guild release", or wants to finalize completed requirements into a versioned
  release. Renames CHANGELOG Unreleased to a version, snapshots the completed
  requirements out of the board into a dated release directory, and creates an
  annotated git tag. Does not push.
version: 5.0.0
user-invocable: true
allowed-tools: Bash(tursodb *), Bash(git *)
---

# Guild Release — snapshot and tag a version

Finalize completed guild requirements into a versioned release: stamp `CHANGELOG.md`'s
Unreleased section with a version, render the released requirements out of the database into a
dated snapshot directory, record the release on the board, and create an annotated git tag.

Status is a **column**. There are no status directories and no ticket files — a release copies
nothing and moves nothing; it *renders*. Load `guild:warehouse` before the first query.

```bash
export PATH="$HOME/.turso:$PATH"
DB=.guild/guild.db
```

## Arguments

- `--dry-run` — print the full plan, write nothing, run no git command
- `--only REQ-NNN[,REQ-MMM]` — release only the named requirements (default: every `done`
  requirement not already recorded in a previous release)

## Step 1 — preconditions

Run in parallel:
- `git rev-parse --is-inside-work-tree` — confirm a repo
- `git status --short` — uncommitted changes
- `git tag --list --sort=-v:refname` — existing tags
- `[ -f .guild/config.yaml ]` — confirm the guild exists

Stop conditions:
- Not a git repo → `Not inside a git repository. Guild release requires git.`
- No `.guild/config.yaml` → `No guild found. Nothing to release.`
- Uncommitted changes → ask, and default to stopping on "no":
  ```
  You have uncommitted changes. A release should be a clean point in history.
  Continue anyway? (yes / no)
  ```

## Step 2 — what is in scope

A release is **recorded on the board**, in `guild_state` under `release:<version>`, so "what has
already shipped" is a query rather than a directory scan:

```sql
SELECT r.id, r.title
  FROM requirement r
 WHERE r.status = 'done'
   AND NOT EXISTS (SELECT 1 FROM guild_state gs, json_each(gs.value, '$.requirements') j
                    WHERE gs.key LIKE 'release:%' AND json_valid(gs.value) AND j.value = r.id)
 ORDER BY r.id;
```

With `--only`, use exactly the named ids instead — and verify each is `done` before including it.

Empty set → stop with `No completed requirements to release since the last release.`

**Exclude the standing QA umbrella.** It is `in-progress` forever by design, so the query above
already skips it; do not add it by hand under `--only`.

## Step 3 — the pre-release gate

For every requirement in scope, one query answers the whole gate:

```sql
SELECT id, status, tasks_total, tasks_done, tasks_open, tasks_blocked, tasks_failed,
       replace(replace(title, char(10), ' '), '|', '!') AS title
  FROM v_requirement_progress
 WHERE id IN ('REQ-007','REQ-008');
```

**Warn, never block.** Two different warnings, and the difference matters:

- `tasks_failed > 0` — a human already ruled on these. Distinguish the waived ones, because a
  waiver is a decision and a bare failure is not:

  ```sql
  SELECT id, waived, replace(replace(COALESCE(reason,'-'), char(10),' '), '|','!') AS reason, title
    FROM v_failed_tasks WHERE requirement_id IN ('REQ-007');
  ```
  ```
  These tasks for included requirements failed:
    TASK-013: {title}  (waived by you)
    TASK-021: {title}  (failed, not waived — {reason})
  The release will note them. Continue? (yes / no)
  ```

- `tasks_open > 0` — still `todo`, `in-progress`, **or `blocked`**. A blocked one is the loud
  case: it means nobody on the roster could take it, so the requirement is shipping work
  nobody ever attempted. Name it as such:

  ```
  These tasks for included requirements are not done:
    TASK-030: {title} (todo)
    TASK-031: {title} (BLOCKED — no eligible agent)
  They stay on the board after release. Continue? (yes / no)
  ```

## Step 4 — the version

1. Find the latest semver tag (`vX.Y.Z`). None → suggest `v0.1.0`.
2. Show current version, the requirements in scope with their titles, and ask `What version?`
3. Validate against `v\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?`. Re-prompt on invalid.
4. Reject a version whose tag already exists, **and** one already present as a
   `release:<version>` key on the board — either means this version was already cut.

## Step 5 — CHANGELOG.md

The changelog lives at **repo root**, not inside `.guild/`.

If it does not exist, create it with the Keep-a-Changelog skeleton and an empty
`## [Unreleased]`. If it exists without an `## [Unreleased]`, insert one after the preamble,
before the first `## [version]` heading. If `[Unreleased]` is empty and `--only` was not used,
warn: `The [Unreleased] section is empty. Release anyway? (yes / no)`

Then transform it:

1. Capture everything under `## [Unreleased]` up to the next `## ` heading or EOF —
   `UNRELEASED_BODY`.
2. With `--only`, keep only the bullets referencing the included REQ ids; move the rest back
   under `## [Unreleased]`.
3. For each in-scope requirement not already mentioned, append `- REQ-NNN: {title}`. Flatten the
   title first (`replace(replace(title, char(10),' '), '|','!')`) — **a newline inside a title
   would forge a changelog bullet, or worse, a heading.**
4. Replace the heading block with a fresh empty `## [Unreleased]`, then
   `## [{version}] - {today}` carrying `UNRELEASED_BODY`.

## Step 6 — render the snapshot

There is no export command any more. Render each requirement out of the database with SQL,
one file per requirement, plans and tasks and records inlined.

**The one rule that keeps this safe:** structure is written by the shell from ids and enum
words; free text is appended as a whole block by a single-column query and is never interpolated
into a heading, a table cell or a filename. A `body` containing `## [v9.9.9]` can only ever be
body text; it can never become a section of the document.

```bash
V=v1.2.0; REQ=REQ-007
mkdir -p ".guild/releases/$V"
OUT=".guild/releases/$V/$REQ.md"

q() { printf '%s\n' "$1" | tursodb -q -m list "$DB"; }   # -m list ALWAYS: `pretty` truncates

{
  printf '# %s\n\n' "$REQ"
  printf '## Requirement\n\n'
} > "$OUT"
q "SELECT body FROM requirement WHERE id = '$REQ';" >> "$OUT"

printf '\n## Plans\n\n' >> "$OUT"
q "SELECT body FROM plan WHERE requirement_id = '$REQ' ORDER BY id;" >> "$OUT"

printf '\n## Ticket file sets\n\n' >> "$OUT"
q "SELECT '- ' || t.id || ' — ' || replace(replace(t.title, char(10),' '), '|','!')
        || '  files: ' || t.files
     FROM task t
    WHERE t.requirement_id = '$REQ' AND t.node_key = 'implement' ORDER BY t.id;" >> "$OUT"

printf '\n## Tasks\n\n' >> "$OUT"
q "SELECT '- ' || id || '  [' || status || ']  ' || COALESCE(claimed_by, agent, '-') || '  '
        || replace(replace(title, char(10),' '), '|','!')
     FROM task WHERE requirement_id = '$REQ' ORDER BY id;" >> "$OUT"

printf '\n## Work log\n\n' >> "$OUT"
q "SELECT '### ' || w.task_id || ' · ' || w.ts || ' · ' || w.agent || char(10) || char(10) || w.entry
     FROM work_log w JOIN task t ON t.id = w.task_id
    WHERE t.requirement_id = '$REQ' ORDER BY w.ts, w.id;" >> "$OUT"

printf '\n## Review findings\n\n' >> "$OUT"
q "SELECT '### ' || f.severity || ' · ' || f.reviewer || ' · ' || f.disposition
        || ' · ' || f.task_id || COALESCE(' · ' || f.file || ':' || f.line, '')
        || char(10) || char(10) || f.summary || char(10) || char(10) || COALESCE(f.detail, '')
     FROM review_finding f JOIN task t ON t.id = f.task_id
    WHERE t.requirement_id = '$REQ' ORDER BY f.id;" >> "$OUT"

printf '\n## Bugs\n\n' >> "$OUT"
q "SELECT '### ' || id || ' · ' || severity || ' · ' || status || char(10) || char(10)
        || title || char(10) || char(10) || COALESCE(repro, '')
     FROM bug WHERE requirement_id = '$REQ' ORDER BY id;" >> "$OUT"

[ -f ".guild/reviews/$REQ.md" ] && cp ".guild/reviews/$REQ.md" ".guild/releases/$V/$REQ.review.md"
```

Check the exit status of every `q` and do not send its output to `/dev/null` on the failure path
— tursodb writes errors to **stdout**, so a failed query would otherwise land in the snapshot
looking like content.

**Point at the decisions, do not copy them.** A requirement's snapshot should name the ADRs
that governed it, so a reader of `v1.2.0` a year from now can find the reasoning without
guessing at slugs:

```bash
q "SELECT '### Decisions' || char(10) || char(10)
        || group_concat('- \`' || d.slug || '\` — '
             || replace(replace(d.title, char(10), ' '), '|', '!')
             || ' (' || d.status || ')', char(10))
     FROM knowledge_edge ke JOIN doc d ON d.slug = ke.from_id
    WHERE ke.rel = 'decides' AND ke.from_type = 'doc'
      AND ke.to_type = 'requirement' AND ke.to_id = '$REQ'
      AND d.kind = 'decision';" >> "$OUT"
```

**The slug, not the body.** A decision keeps evolving after the release that introduced it —
that is the whole point of `supersedes` — and a copied body freezes it at the wrong moment and
then disagrees with the live one. The slug always resolves to the current thinking, and
`v_decision_log` shows what replaced it.

**Never snapshot the library or the QA discipline.** `doc` rows, `doc_revision` rows,
`knowledge_edge` rows, `coverage` rows, `.guild/docs/` and `.guild/qa/` are evergreen:
researcher findings, business rules, the decision log, the risk map and the regression manifest
all persist across releases so the next architect can reuse them.

## Step 7 — record the release on the board

This is what makes Step 2 a query next time, and it is the only board write a release makes:

```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'orchestrator' WHERE key = 'actor';

INSERT INTO guild_state (key, value)
VALUES ('release:v1.2.0',
        json_object('released', date('now'),
                    'requirements', json_array('REQ-007','REQ-008')))
ON CONFLICT(key) DO UPDATE SET value = excluded.value
RETURNING key, value;
```

Then write `.guild/releases/{version}/RELEASE.md` as the human artifact beside the snapshots:

```markdown
---
released: {today}
version: {version}
requirements:
  - REQ-NNN: {flattened title}
---

# Release {version}

Each requirement in this release is captured beside this file as `REQ-NNN.md`, rendered from the
board at release time — plans, tasks, work logs, findings and bugs inlined.

The requirements themselves stay on the live board as `done`. Nothing was deleted: the board is
the record, and `guild_state['release:{version}']` is what marks these as shipped.

IDs are derived as `MAX(n) + 1` and are never reused, so the sequence stays continuous across
releases and nothing has to be reset.
```

**A release never changes a requirement's status and never deletes a row.** `done` requirements
cost nothing on the board — `v_next_task` only ever looks at open tasks — and deleting them would
orphan every work log, finding and event that explains how the release was built. If a board is
genuinely too crowded to read, that is `guild:clear-board`'s question, asked deliberately, not a
side effect of shipping.

## Step 8 — commit and tag

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

If pre-commit hooks fail, surface the error and stop. The snapshot files are already written and
the board row is already recorded, but nothing was moved or deleted — re-running the release
after fixing the hook is safe, because Step 7's write is an upsert and Step 2 will then find the
scope already released and say so.

## Step 9 — report

```
Released {version}
==================

Changelog: CHANGELOG.md (new [{version}] section)
Snapshot:  .guild/releases/{version}/
  {N} requirement(s), rendered from the board with plans, tasks, work logs,
  findings and bugs inlined
Board:     guild_state['release:{version}'] records what shipped

  Released requirements stay on the live board as `done`. Nothing was deleted.

Git:
  Commit {short-hash}: chore(release): {version}
  Tag: {version}

Not pushed. Push with:
  git push && git push --tags
```

## Step 10 — verify against §9

Run `guild:validate release`. §9 of `docs/expectations.md` follows from one sentence — a
release *records*, it does not retire: §9.a fingerprints the board before and after and the
**only** difference permitted is the one `guild_state` row, §9.b that the release record is
well-formed and no requirement was released twice or released while not done. **Report every
failure with its rows.** Under `--dry-run`, §9.a's diff must be empty.

## Dry-run mode

With `--dry-run`, run steps 1–5 to build the plan and print it: the version, the requirements in
scope with their titles, the CHANGELOG transformation, the files that would be written, and the
git actions that would run — plus every warning from the pre-release gate. **Write no file, run
no git command, and make no board write.** The step-2, step-3 and step-4 queries are all reads
and are safe to run; step 7's upsert is not, and must not run.

## Rules

- **Never push** — the user decides when to publish a tag.
- **Never skip hooks** — no `--no-verify`.
- **Never delete or restatus a released requirement.** A release records; it does not retire.
- **`-m list`, always.** The default `pretty` output mode truncates long values with an ellipsis,
  and a truncated requirement body in a release snapshot is a lie that outlives the release.
- **Flatten free text before it becomes structure.** A newline in a title forges a changelog
  bullet or a heading; `replace(replace(x, char(10),' '), '|','!')` in SQL, before it leaves the
  engine.
- **Check every query's exit code.** Errors arrive on stdout and would be written into the
  snapshot as content.
- **IDs are derived, never counters** — nothing is reset at a release.
- **CHANGELOG.md lives at repo root**, not inside `.guild/`.
- **`doc`, `doc_revision`, `knowledge_edge`, `coverage`, `.guild/docs/` and `.guild/qa/` are
  evergreen** — never snapshotted, never touched. A release **names** the decision slugs a
  requirement was governed by and copies none of them: a decision goes on evolving after the
  release that introduced it, and a frozen copy is a second answer to a settled question.
- **`.guild/reviews/REQ-NNN.md` is COPIED into the snapshot** — it is per-requirement history,
  not cross-cutting knowledge. The original stays where it is.
- **One commit, one tag**, both created in step 8.
