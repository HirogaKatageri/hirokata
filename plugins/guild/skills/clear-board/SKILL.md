---
name: clear-board
description: >
  This skill should be used when the user asks to "clear the board", "reset the guild",
  "start fresh", "wipe the board", "clear all tasks", "reset the board", or wants to
  remove all current work from the guild board and start over.
version: 1.0.0
user-invocable: true
---

# Clear Board — Reset the Guild

Wipe all tasks, requirements, and plans from the guild board and reset it to a clean state.

## Steps

### 1. Check for Guild

Read `.guild/state.yaml`.

If not found:
```
No guild board found. Nothing to clear.
Run /guild:check-in to initialize a new guild.
```
Stop here.

### 2. Inventory the Board

Count items by scanning the directories:
- Requirements: count files in `.guild/requirements/`
- Tasks in progress: count `.guild/tasks/*.md` with `status: in-progress`
- Tasks in backlog: count `.guild/tasks/*.md` with `status: todo`
- Completed tasks: count `.guild/tasks/*.md` with `status: done`
- Plan files: count files in `.guild/plans/`

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

1. Delete all files in `.guild/requirements/` (keep the directory)
2. Delete all files in `.guild/tasks/` (keep the directory)
3. Delete all files in `.guild/plans/` (keep the directory, including any slice subdirectories)

**NEVER touch `.guild/docs/`** — the knowledge base is evergreen and survives board resets. Researcher findings accumulate across requirements and should not be lost when clearing the board.

**NEVER touch `.guild/archive/`** — prior releases stay archived.

**NEVER touch `.guild/qa/`** — the QA discipline's charter, bug ledger, regression
manifest, sessions, and missions are evergreen and accumulate across passes and
releases, like `.guild/docs/`.

Use Bash to delete only the cleared directories' contents:
```bash
rm -rf .guild/requirements/* .guild/tasks/* .guild/plans/*
```

The `-r` flag removes plan slice subdirectories (e.g. `.guild/plans/PLAN-001/`). `.guild/docs/`, `.guild/qa/`, and `.guild/archive/` are not in the glob, so they remain untouched.

If a legacy `.guild/BOARD.md` exists, delete it too (`rm -f .guild/BOARD.md`) — the new format has no board file.

### 5. Reset state.yaml

Overwrite `.guild/state.yaml` with a clean slate, preserving today's date as `last-checkin`:

```yaml
current: null
next-task: 1
next-req: 1
next-plan: 1
last-checkin: {today's date}
```

### 6. Confirm

```
Board cleared.

  Removed: {N} requirement(s), {N} task(s), {N} plan(s)
  Counters reset to: REQ-001, TASK-001, PLAN-001

Run /guild:new-requirement to add work, or /guild:check-in to start a session.
```

## Rules

- **Always confirm before deleting** — this action is irreversible
- **Keep directories** — only delete files, not the `.guild/requirements/`, `.guild/tasks/`, `.guild/plans/` folders themselves
- **Never clear `.guild/docs/`** — the knowledge base is evergreen and preserved across resets
- **Never clear `.guild/qa/`** — the QA discipline's artifacts are evergreen and preserved across resets
- **Never clear `.guild/archive/`** — prior releases stay archived
- **Reset all counters to 1** in `state.yaml` — prevent ID confusion on the fresh board
- **Delete any legacy BOARD.md** — the new format stores state in `state.yaml` + ticket files
- **Update last-checkin** — so the state reflects when it was last touched
