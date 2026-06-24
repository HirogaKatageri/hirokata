---
name: guild-status
description: >
  This skill should be used when the user asks for "guild status", "board status",
  "show the board", "what's on the board", "project status", "show guild",
  "guild board", or "what's happening". Shows a quick read-only view of the guild
  board without starting the work cycle.
version: 1.0.0
user-invocable: true
---

# Guild Status — Quick Board View

Display the current state of the guild board without starting a work session.

## Steps

### 1. Check for Guild

Read `.guild/state.yaml`.

If not found:
```
No guild board found. Run /guild:check-in to initialize and start your first work session.
```
Stop here.

### 2. Render the Board Live

There is no `BOARD.md`. Build the view by scanning files (see `check-in/references/state-format.md`):
- Glob `.guild/tasks/*.md`, read each frontmatter, and group by `status`: In Progress
  (`in-progress`), Backlog (`todo`), Recently Completed (`done`, newest IDs first), plus any `failed`.
- Glob `.guild/requirements/*.md` for the Requirements list; compute each REQ's progress as
  `done-tickets / total-tickets` by counting its tasks.
- Read `last-checkin` from `.guild/state.yaml`.

### 3. Display Status

Present a formatted summary:

```
Guild Board
===========

In Progress ({count}):
  TASK-003: Implement auth service (developer) — since 2026-04-07
  TASK-004: Review database schema (reviewer) — since 2026-04-07

Backlog ({count}):
  TASK-005: Implement login endpoint (developer) — high
  TASK-006: Plan payment feature (architect) — medium

Recently Completed ({count}):
  TASK-002: Design auth architecture (architect) — 2026-04-07
  TASK-001: Gather auth requirements (product-owner) — 2026-04-07

Requirements:
  REQ-001: User Authentication — in-progress (3/6 done)
  REQ-002: Payment Integration — draft (0/1 done)

Last check-in: 2026-04-07
```

If all sections are empty:
```
Guild Board
===========

The board is empty. Run /guild:check-in to start a work session.
```

## Rules

- **Read-only** — do not modify `state.yaml` or any guild files
- **No work execution** — just display status and stop
- **Keep it brief** — this is a quick glance, not a full check-in
