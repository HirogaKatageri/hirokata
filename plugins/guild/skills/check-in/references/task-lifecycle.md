# Task Lifecycle & File Format

## Task File Location

All task files live in `.guild/tasks/` with the naming pattern `TASK-NNN.md` (zero-padded 3-digit ID).

## Task File Format

```markdown
---
id: TASK-001
title: "Short descriptive title"
agent: product-owner
status: pending
requirement: REQ-001
plan: null
depends-on: []
priority: high
created: 2026-04-07
---

## Objective

Clear description of what this task needs to accomplish.

## Context

- Requirement: [REQ-001](.guild/requirements/REQ-001.md) — Title
- Plan: [PLAN-001](.guild/plans/PLAN-001.md) — Title (if applicable)
- Prior task: TASK-000 (if this is a follow-up)

## Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Work Log

_Agent appends progress notes here as it works._

## Follow-up Tasks

_Agent declares follow-ups here upon completion._
```

## Frontmatter Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Task ID (e.g., `TASK-001`) |
| `title` | string | yes | Short descriptive title |
| `agent` | string | yes | Assigned agent: `product-owner`, `architect`, `developer`, `reviewer`, `researcher` |
| `status` | string | yes | Current status (see Status Values below) |
| `requirement` | string | yes | Linked requirement ID (e.g., `REQ-001`) |
| `plan` | string | no | Linked plan ID (e.g., `PLAN-001`), `null` if none |
| `depends-on` | array | no | Task IDs that must complete first (e.g., `[TASK-002, TASK-003]`) |
| `priority` | string | yes | `high`, `medium`, or `low` |
| `created` | string | yes | Creation date (YYYY-MM-DD) |

## Status Values & Transitions

```
pending → in-progress → done
                      → failed
pending → blocked → pending (when dependency resolves)
```

| Status | Meaning |
|--------|---------|
| `pending` | Ready to be picked up (or waiting in backlog) |
| `in-progress` | An agent is actively working on it |
| `done` | Successfully completed |
| `blocked` | Cannot proceed — unmet dependencies |
| `failed` | Agent could not complete — needs user intervention |

## Work Log Convention

Agents append to the Work Log section as they work. Each entry includes the date and agent name:

```markdown
## Work Log

### 2026-04-07 — architect
- Analyzed REQ-001 requirements (5 user stories, 3 edge cases)
- Explored codebase: found existing auth patterns in src/middleware/
- Created PLAN-001 with 4 implementation tasks
- Marked task as done
```

The Work Log provides continuity across context resets. When a task is resumed, the new agent reads the Work Log to understand what was already done.

## Follow-up Tasks Section

When an agent completes its work, it declares follow-up tasks in this section. Each line follows the format:

```
- {title} | agent: {agent-name} | priority: {high|medium|low}
```

Optional modifiers:
```
- {title} | agent: {agent-name} | priority: {priority} | depends-on: all-developer
- {title} | agent: {agent-name} | priority: {priority} | depends-on: TASK-005
```

### Examples

**Product owner completing requirements gathering:**
```markdown
## Follow-up Tasks

- Plan authentication implementation | agent: architect | priority: high
```

**Architect completing a plan:**
```markdown
## Follow-up Tasks

- Implement user model and migration | agent: developer | priority: high
- Implement signup endpoint | agent: developer | priority: high
- Implement login endpoint | agent: developer | priority: medium
- Implement session management | agent: developer | priority: medium
- Review authentication implementation | agent: reviewer | priority: high | depends-on: all-developer
```

**Reviewer finding issues:**
```markdown
## Follow-up Tasks

- Fix: Missing input validation on signup endpoint | agent: developer | priority: high
- Fix: SQL injection risk in login query | agent: developer | priority: high
- Re-review authentication fixes | agent: reviewer | priority: high | depends-on: all-developer
```

### How the Orchestrator Processes Follow-ups

1. Read the completed task's "Follow-up Tasks" section
2. For each line:
   a. Parse title, agent, priority, and optional depends-on
   b. Assign the next available TASK ID from BOARD.md counters
   c. Create the task file in `.guild/tasks/`
   d. Add the task to BOARD.md Backlog section
   e. If `depends-on: all-developer` — resolve to all developer task IDs just created
3. Increment `next-task` counter in BOARD.md frontmatter
4. Link new tasks back to the same requirement as the parent task

## Requirement File Format

Location: `.guild/requirements/REQ-NNN.md`

```markdown
---
id: REQ-001
title: "User Authentication"
status: draft
created: 2026-04-07
---

# User Authentication

## Summary
[Overview of the requirement]

## User Stories
[Stories with acceptance criteria in Given/When/Then format]

## Technical Considerations
[Constraints, dependencies, security, performance]

## Out of Scope
[What's explicitly excluded]
```

**Status values:** `draft` → `in-progress` → `done`

## Plan File Format

Location: `.guild/plans/PLAN-NNN.md`

```markdown
---
id: PLAN-001
title: "Authentication Implementation Plan"
requirement: REQ-001
task: TASK-002
created: 2026-04-07
---

# Authentication Implementation Plan

## Architecture Overview
[High-level design decisions]

## Implementation Tasks
[Specific developer tasks — these get transcribed into the originating task's Follow-up Tasks section]

## Technical Decisions
[Key choices and rationale]

## Risks
[Identified risks and mitigations]
```
