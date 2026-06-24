---
name: new-requirement
description: >
  This skill should be used when the user asks to "add a requirement",
  "new requirement", "I need a feature", "add to the guild", "create requirement",
  "queue a feature", "I want to build", or wants to add a new work item to the
  guild board. Creates a requirement stub and a product-owner task to gather
  the full details.
version: 1.0.0
user-invocable: true
arguments:
  - name: title
    description: Short title for the requirement
    required: false
  - name: description
    description: Brief description of what is needed
    required: false
---

# New Requirement — Add Work to the Guild

Create a new requirement stub and a task for the product-owner to gather full details.

## Arguments

Parse from `$ARGUMENTS` or user input:

| Argument | Description |
|----------|-------------|
| `title` | Short title for the requirement (e.g., "User Authentication") |
| `description` | Brief description of what's needed |

## Steps

### 1. Check for Guild

Read `.guild/state.yaml`.

If not found:
```
No guild found. Run /guild:check-in to initialize first.
```
Stop here.

### 1.5. Offer to Clear the Board

If the board has any existing requirements, tasks, or plans (check the `.guild/requirements/`, `.guild/tasks/`, `.guild/plans/` directories), ask the user:

```
The guild board currently has {N} requirements, {N} tasks, and {N} plans.
Clear the board before adding this new requirement? (yes / no)
```

**If "yes"**: Invoke the `guild:clear-board` skill (it will handle confirmation and deletion), then proceed.

**If "no"**: Proceed without changes.

If the board is empty, skip this step.

### 2. Gather Details

If `title` is not provided, ask the user:
```
What's the title of this requirement? (e.g., "User Authentication", "Payment Integration")
```

If `description` is not provided, ask the user:
```
Briefly describe what you need. The product-owner will gather full details later.
```

### 3. Read State Counters

Read `.guild/state.yaml` to get:
- `next-req` → use as REQ ID
- `next-task` → use as TASK ID

Zero-pad IDs to 3 digits (e.g., `1` → `001`).

### 4. Create Requirement Stub

Write `.guild/requirements/REQ-NNN.md`:

```markdown
---
id: REQ-NNN
title: "{title}"
status: draft
created: {today's date}
---

# {title}

## Summary

{description}

## User Stories

_To be gathered by the product-owner._

## Technical Considerations

_To be determined._

## Out of Scope

_To be determined._
```

### 5. Create Product-Owner Task

Write `.guild/tasks/TASK-NNN.md`:

```markdown
---
id: TASK-NNN
title: "Gather requirements for {title}"
agent: product-owner
status: todo
requirement: REQ-NNN
plan: null
priority: high
created: {today's date}
---

## Objective

Interview the user and gather comprehensive requirements for: {title}

{description}

## Context

- Requirement: .guild/requirements/REQ-NNN.md

## Acceptance Criteria

- [ ] Requirement document fully written with user stories
- [ ] Acceptance criteria defined for each story
- [ ] Edge cases identified
- [ ] Technical considerations documented
- [ ] Out of scope clearly defined

## Work Log

## Follow-up Tasks

- Plan {title} implementation | agent: architect | priority: high
```

### 6. Update state.yaml

Using the Edit tool, increment counters in `.guild/state.yaml`:
- `next-req` → increment by 1
- `next-task` → increment by 1

The new requirement and task are now discoverable by scanning their files — there is no board
table to update.

### 7. Confirm

```
Requirement created!

  Requirement: REQ-NNN — {title}
  Task: TASK-NNN — Gather requirements for {title} (product-owner)
  Status: Added to backlog

The product-owner will gather full details during the next work cycle.
Run /guild:check-in to start working.
```

## Rules

- **Never overwrite** existing files — if REQ-NNN.md already exists, something went wrong with counters
- **Always increment counters** — prevent ID collisions
- **Keep the stub minimal** — the product-owner will flesh it out
- **Pre-populate Follow-up Tasks** — the standard chain starts with an architect task

- **No board tables** — requirements and tasks are discovered by scanning their files; `state.yaml` holds only counters
