---
name: new-requirement
description: >
  This skill should be used when the user asks to "add a requirement",
  "new requirement", "I need a feature", "add to the guild", "create requirement",
  "queue a feature", "I want to build", or wants to add a new work item to the
  guild board. Creates a requirement stub and a product-owner task to gather
  the full details.
version: 2.0.0
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

All deterministic state operations go through the guild CLI. Bind it once:

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
```

## Arguments

Parse from `$ARGUMENTS` or user input:

| Argument | Description |
|----------|-------------|
| `title` | Short title for the requirement (e.g., "User Authentication") |
| `description` | Brief description of what's needed |

## Steps

### 1. Check for Guild

Read `.guild/state.yaml` (it holds only `last-checkin`).

If not found:
```
No guild found. Run /guild:check-in to initialize first.
```
Stop here.

### 1.5. Offer to Clear the Board

Detect existing items via the CLI rather than counting files:

```bash
"$GUILD" list req
"$GUILD" list task
"$GUILD" list plan
```

If any of these print items, ask the user (use the counts from the list output):

```
The guild board currently has {N} requirements, {N} tasks, and {N} plans.
Clear the board before adding this new requirement? (yes / no)
```

**If "yes"**: Invoke the `guild:clear-board` skill (it will handle confirmation and deletion), then proceed.

**If "no"**: Proceed without changes.

If all three lists are empty, skip this step.

### 2. Gather Details

If `title` is not provided, ask the user:
```
What's the title of this requirement? (e.g., "User Authentication", "Payment Integration")
```

If `description` is not provided, ask the user:
```
Briefly describe what you need. The product-owner will gather full details later.
```

### 3. Create the Requirement Stub

Run the CLI — it derives the next ID, scaffolds the template (Summary / User Stories /
Technical Considerations / Out of Scope, no status field) in `requirements/todo/`, and prints
`REQ-NNN <path>`. `--desc` populates the Summary section.

```bash
read REQ _ < <("$GUILD" new req --title "{title}" --desc "{description}" --date {today})
```

`$REQ` is now the requirement ID (e.g. `REQ-001`).

### 4. Create the Product-Owner Task

Run the CLI — it derives the next ID, scaffolds the task template in `tasks/todo/`, and prints
`TASK-NNN <path>`. Capture both the ID and the path.

```bash
read TASK TASK_PATH < <("$GUILD" new task \
  --title "Gather requirements for {title}" \
  --agent product-owner \
  --req "$REQ" \
  --date {today})
```

### 5. Add the Follow-up

Edit the new task file at `$TASK_PATH` and add this line under its `## Follow-up Tasks` section:

```
- Plan {title} implementation | agent: architect | priority: high
```

The standard chain starts with an architect planning task once the product-owner has gathered
the requirement.

### 6. Confirm

```
Requirement created!

  Requirement: {REQ} — {title}
  Task: {TASK} — Gather requirements for {title} (product-owner)
  Status: Added to backlog (tasks/todo/)

The product-owner will gather full details during the next work cycle.
Run /guild:check-in to start working.
```

## Rules

- **IDs are derived by the CLI** — never hand-assign or zero-pad IDs yourself; `guild new`
  computes the next ID from the filesystem.
- **No `status` field** — status is the containing directory. `guild new req`/`guild new task`
  place artifacts in `requirements/todo/` and `tasks/todo/` directly.
- **Keep the stub minimal** — the product-owner will flesh it out.
- **Pre-populate Follow-up Tasks** — the standard chain starts with an architect task.
- **No counters** — `state.yaml` holds only `last-checkin`; there are no `next-req`/`next-task`
  counters to read or increment.
