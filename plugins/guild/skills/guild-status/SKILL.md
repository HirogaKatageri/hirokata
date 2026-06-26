---
name: guild-status
description: >
  This skill should be used when the user asks for "guild status", "board status",
  "show the board", "what's on the board", "project status", "show guild",
  "guild board", or "what's happening". Shows a quick read-only view of the guild
  board without starting the work cycle.
version: 2.0.0
user-invocable: true
---

# Guild Status — Quick Board View

Display the current state of the guild board without starting a work session.

## Steps

### 1. Check for Guild

Read `.guild/state.yaml` (it holds only `last-checkin`).

If not found:
```
No guild board found. Run /guild:check-in to initialize and start your first work session.
```
Stop here.

### 2. Render the Board Live

The board is a live view rendered by the CLI scanning the status directories — there is no stored
board file. Bind the CLI and run `board`:

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
"$GUILD" board
```

`guild board` already groups **In Progress**, **Backlog**, **Recently Completed**, and any
**Failed** tasks, lists **Requirements** with their `done/total` progress, and prints the
**Last check-in** date. It does not modify anything.

### 3. Display Status

Present the `guild board` output to the user. A typical rendering:

```
Guild Board
===========

In Progress ({count}):
  TASK-003: Implement auth service (developer)
  TASK-004: Review database schema (reviewer)

Backlog ({count}):
  TASK-005: Implement login endpoint (developer)
  TASK-006: Plan payment feature (architect)

Recently Completed ({count}):
  TASK-002: Design auth architecture (architect)
  TASK-001: Gather auth requirements (product-owner)

Requirements:
  REQ-001: User Authentication — in-progress (3/6 done)
  REQ-002: Payment Integration — todo (0/1 done)

Last check-in: 2026-04-07
```

If the board is empty:
```
Guild Board
===========

The board is empty. Run /guild:check-in to start a work session.
```

## Rules

- **Read-only** — `guild board` only scans directories; do not modify `state.yaml` or any guild files
- **No work execution** — just display status and stop
- **Keep it brief** — this is a quick glance, not a full check-in
