---
name: clear-board
description: >
  This skill should be used when the user asks to "clear the board", "reset the guild",
  "start fresh", "wipe the board", "clear all tasks", "reset the board", or wants to
  remove all current work from the guild board and start over.
version: 2.0.0
user-invocable: true
---

# Clear Board — Reset the Guild

Wipe all tasks, requirements, and plans from the guild board and reset it to a clean state.

Bind the guild CLI once and reuse it for all inventory/recreate operations:
```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
```

## Steps

### 1. Check for Guild

Read `.guild/state.yaml` (it holds only `last-checkin`).

If not found:
```
No guild board found. Nothing to clear.
Run /guild:check-in to initialize a new guild.
```
Stop here.

### 2. Inventory the Board

Count items via the CLI — status is the directory an artifact lives in, so never scan flat files or a `status:` frontmatter field:
- Requirements: `"$GUILD" list req`
- Tasks in progress: `"$GUILD" list task in-progress`
- Tasks in backlog: `"$GUILD" list task todo`
- Completed tasks: `"$GUILD" list task done`
- Plan files: `"$GUILD" list plan`

Each `list` prints one `<ID> <status>` line per artifact; count the lines.

### 3. Confirm with User

Present the current state and ask for confirmation:

```
Current board state:
  {N} requirement(s)
  {N} task(s) in progress
  {N} task(s) in backlog
  {N} task(s) completed
  {N} plan(s)

This will permanently delete all requirements, tasks, and plans.
Are you sure you want to clear the board? (yes / no)
```

If the board is already empty (all counts are 0):
```
The guild board is already empty — nothing to clear.
```
Stop here.

**If "no"** or anything other than an explicit confirmation: Stop without making any changes.

**If "yes"**: Proceed to step 4.

### 4. Clear the Board

Status is encoded by the subdirectory each artifact lives in, so clearing the board means wiping the status subdirectories under `requirements/`, `tasks/`, and `plans/` (this includes any plan slice subdirectories).

**NEVER touch `.guild/docs/`** — the knowledge base is evergreen and survives board resets. Researcher findings accumulate across requirements and should not be lost when clearing the board.

**NEVER touch `.guild/archive/`** — prior releases stay archived.

**NEVER touch `.guild/qa/`** — the QA discipline's charter, bug ledger, regression
manifest, sessions, and missions are evergreen and accumulate across passes and
releases, like `.guild/docs/`.

Use Bash to delete only the cleared directories' contents, then recreate the empty status-dir skeleton so the board stays valid:
```bash
rm -rf .guild/requirements/* .guild/tasks/* .guild/plans/*
"$GUILD" init {today's date}
```

The `-r` flag removes the status subdirectories and any plan slice subdirectories (e.g. `.guild/plans/done/PLAN-001/`). `.guild/docs/`, `.guild/qa/`, and `.guild/archive/` are not in the glob, so they remain untouched.

`guild init` is idempotent: it recreates `requirements|tasks|plans/{todo,in-progress,done}`, the tasks `failed/` dir, plus `docs/` and `qa/`, **without** overwriting an existing `state.yaml`. (Step 5 resets `state.yaml` explicitly.)

If a legacy `.guild/BOARD.md` exists, delete it too (`rm -f .guild/BOARD.md`) — the new format has no board file.

### 5. Reset state.yaml

There are no ID counters or cursor in the new model — IDs are derived from the filesystem and the cursor is whatever sits in `tasks/in-progress/`. Overwrite `.guild/state.yaml` with the single fact it holds, today's date:

```yaml
last-checkin: {today's date}
```

### 6. Confirm

```
Board cleared.

  Removed: {N} requirement(s), {N} task(s), {N} plan(s)

The board is empty — the next IDs restart at REQ-001 / TASK-001 / PLAN-001
(unless archived items keep the sequence higher).

Run /guild:new-requirement to add work, or /guild:check-in to start a session.
```

## Rules

- **Always confirm before deleting** — this action is irreversible
- **Keep the skeleton valid** — after `rm -rf`, run `guild init {today}` to recreate the empty `requirements|tasks|plans` status subdirectories
- **Never clear `.guild/docs/`** — the knowledge base is evergreen and preserved across resets
- **Never clear `.guild/qa/`** — the QA discipline's artifacts are evergreen and preserved across resets
- **Never clear `.guild/archive/`** — prior releases stay archived
- **No counters to reset** — IDs derive from the filesystem; after clearing, the next IDs naturally restart at 001 unless archived items exist
- **Delete any legacy BOARD.md** — the new format stores state in `state.yaml` + ticket files
- **Update last-checkin** — so the state reflects when it was last touched
