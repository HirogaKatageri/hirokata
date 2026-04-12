# BOARD.md Format Specification

The guild board at `.guild/BOARD.md` is the single source of truth for all guild state. Every agent and skill reads and updates this file.

## Frontmatter

```yaml
---
next-task: 1       # Next available TASK ID (auto-increment)
next-req: 1        # Next available REQ ID (auto-increment)
next-plan: 1       # Next available PLAN ID (auto-increment)
last-checkin: null  # ISO date of last check-in (null if never)
---
```

When creating a new entity:
1. Read the counter (e.g., `next-task: 5`)
2. Use it as the ID (e.g., `TASK-005`)
3. Increment the counter (e.g., `next-task: 6`)

IDs are zero-padded to 3 digits: `001`, `002`, ..., `999`.

## Sections

### In Progress

Tasks currently being worked on by agents.

```markdown
## In Progress
| Task | Title | Agent | Req | Since |
|------|-------|-------|-----|-------|
| TASK-003 | Implement auth service | developer | REQ-001 | 2026-04-07 |
```

- **Task**: Task ID (links to `.guild/tasks/TASK-NNN.md`)
- **Title**: Short task title
- **Agent**: Which agent is working on it (`product-owner`, `architect`, `developer`, `reviewer`, `researcher`)
- **Req**: Linked requirement ID
- **Since**: Date work started

### Backlog

Tasks waiting to be picked up. Ordered by priority (high first).

```markdown
## Backlog
| Task | Title | Agent | Req | Priority | Created |
|------|-------|-------|-----|----------|---------|
| TASK-004 | Plan payment feature | architect | REQ-002 | high | 2026-04-07 |
| TASK-005 | Research caching strategies | researcher | REQ-001 | medium | 2026-04-07 |
```

- **Priority**: `high`, `medium`, or `low`
- **Created**: Date task was created

### Done

Recently completed tasks. Keep only the last 20 entries — older ones are trimmed. Task files are the permanent record.

```markdown
## Done
| Task | Title | Agent | Req | Completed |
|------|-------|-------|-----|-----------|
| TASK-002 | Design auth architecture | architect | REQ-001 | 2026-04-07 |
| TASK-001 | Gather auth requirements | product-owner | REQ-001 | 2026-04-07 |
```

### Requirements

All requirements and their current status.

```markdown
## Requirements
| Req | Title | Status | Progress |
|-----|-------|--------|----------|
| REQ-001 | User Authentication | in-progress | 3/6 done |
| REQ-002 | Payment Integration | draft | 0/1 done |
```

- **Status**: `draft`, `in-progress`, `done`
- **Progress**: `N/M done` where N = completed tasks, M = total tasks for this requirement

## Update Rules

1. **Only the orchestrator (check-in skill) updates BOARD.md** — agents never touch it directly
2. Use the **Edit tool** for updates — replace specific table rows or frontmatter values
3. When moving a task between sections, **remove it from the old section** and **add it to the new section**
4. After all updates, increment affected counters in frontmatter
5. Keep sections in the defined order: In Progress → Backlog → Done → Requirements

## Empty Board Template

```markdown
---
next-task: 1
next-req: 1
next-plan: 1
last-checkin: null
---

# Guild Board

## In Progress
| Task | Title | Agent | Req | Since |
|------|-------|-------|-----|-------|

## Backlog
| Task | Title | Agent | Req | Priority | Created |
|------|-------|-------|-----|----------|---------|

## Done
| Task | Title | Agent | Req | Completed |
|------|-------|-------|-----|-----------|

## Requirements
| Req | Title | Status | Progress |
|-----|-------|--------|----------|
```
