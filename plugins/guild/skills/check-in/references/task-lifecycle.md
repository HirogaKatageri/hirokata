# Task Lifecycle & File Format

## Task File Location

All task files live in `.guild/tasks/` with the naming pattern `TASK-NNN.md` (zero-padded 3-digit ID).
Each task file **owns its own status** — there is no board, no second copy.

## Task File Format

```markdown
---
id: TASK-001
title: "Short descriptive title"
agent: product-owner
status: todo
requirement: REQ-001
plan: null
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
| `agent` | string | yes | Assigned agent (see enum below). The orchestrator spawns `guild:{agent}`. |
| `status` | string | yes | `todo`, `in-progress`, `done`, or `failed` |
| `requirement` | string | yes | Linked requirement ID (e.g., `REQ-001`) |
| `plan` | string | no | Linked plan ID (e.g., `PLAN-001`), `null` if none |
| `plan-slice` | string | no | Path to a per-task plan slice (e.g., `.guild/plans/PLAN-001/slice-auth-middleware.md`). When present, the developer reads this instead of the full plan. |
| `parallel-group` | string | no | A label (e.g., `A`, `B`) shared by `developer`/`developer-svelte` tickets the architect has verified touch **non-overlapping** files. Tickets with the same group run concurrently; a ticket with no group runs solo. Scoped per plan. |
| `created` | string | yes | Creation date (YYYY-MM-DD) |

**`agent` enum:** `product-owner`, `architect`, `developer`, `developer-svelte`, `test-writer`,
`researcher`, `reviewer`, `qa-strategist`, `qa-tester`. `reviewer` is a **trigger alias**, not a
real agent — when dispatched it spawns the 4 specialized reviewers (`reviewer-security`,
`reviewer-architecture`, `reviewer-business-logic`, `reviewer-edge-case`) in parallel on the same
ticket.

> There is **no `depends-on` field**. Sequencing is creation order (ID order) plus the per-REQ
> review gate — not a dependency graph. The research-first flow works because the researcher
> ticket is created before (lower ID than) the post-research architect ticket.

> **`parallel-group` is not a dependency graph either.** It is a pure safety assertion by the
> architect: "these dev tickets touch disjoint files and share no ordering, so the shared working
> tree won't be corrupted if they run at once." It only ever groups `developer`/`developer-svelte`
> tickets, never tail tickets (`test-writer`, `reviewer`). Ungrouped dev tickets stay sequential.

## Status Values & Transitions

```
todo → in-progress → done
                   → failed
```

| Status | Meaning |
|--------|---------|
| `todo` | Ready to be picked up (waiting in the queue) |
| `in-progress` | An agent is actively working on it |
| `done` | Successfully completed |
| `failed` | Agent could not complete — needs user intervention |

(There is no `blocked` status — without a dependency graph there is nothing to block on.)

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

The Work Log provides continuity across context resets. When a task is resumed, the new agent
reads the Work Log to understand what was already done. On check-in, a stale `in-progress` ticket
with an **empty** Work Log is reset to `todo` (never started); one with content stays
`in-progress` (resume).

## Follow-up Tasks Section

When an agent completes its work, it declares follow-up tasks in this section. Each line follows
the format:

```
- {title} | agent: {agent-name} | priority: {high|medium|low}
```

Optional modifiers (combine freely, pipe-separated):
```
- {title} | agent: developer | priority: {priority} | plan-slice: .guild/plans/PLAN-NNN/slice-{slug}.md | parallel-group: A
```

The `plan-slice` modifier is emitted by the architect for each developer task. The orchestrator
persists it into the new task's `plan-slice` frontmatter field. The `parallel-group` modifier is
also emitted by the architect, only on `developer`/`developer-svelte` tickets it has verified touch
disjoint files; the orchestrator persists it into the `parallel-group` frontmatter field and uses
it to batch the dispatch (see "Parallel developer batching" below). `priority` is advisory metadata
only — it does **not** affect ordering (the cursor runs in ID order). There are no `depends-on`
modifiers and no magic tokens.

### Parallel developer batching

Development is sequential **by default** — one ticket at a time, in ID order. The single escape
hatch is `parallel-group`: when the architect marks two or more `developer`/`developer-svelte`
tickets with the **same** group label, it has asserted their "Files to Touch" sets are disjoint and
neither depends on the other's output. The orchestrator then dispatches that whole group
concurrently in one message (multiple Agent calls in the shared working tree — no worktrees, no
merge step, because the file sets don't overlap).

Rules:
- Only `developer`/`developer-svelte` tickets carry a group. Tail tickets (`test-writer`,
  `reviewer`) and all other agents never do.
- A group is scoped to one plan. Reuse simple labels (`A`, `B`, …) per plan.
- A ticket with **no** `parallel-group` runs solo, exactly as before.
- The batch is dispatched together and the cursor only advances past it once **every** member is
  `done` — so the test-writer/reviewer tail still waits for all dev work, just as in the sequential
  case.

### The chain tail (test → review)

The tail is a `test-writer` ticket followed by a `reviewer` ticket. Who emits it:

- **Initial chain — the architect emits the tail.** After its developer follow-ups, the architect
  declares the `test-writer` and `reviewer` tickets explicitly, so the full pipeline is visible as
  real tickets up front.
- **Bug-fix flow (no architect) — the product-owner emits the tail** behind the fix ticket.
- **Fix loop — the orchestrator appends the tail.** The 4 reviewers declare only `Fix: …` tickets;
  after a review round that produced fixes, the orchestrator creates the fix tickets, then one
  `test-writer` ticket and one `Re-review …` ticket behind them (deduped — reviewers never each
  emit the tail).

### Examples

**Product owner completing requirements gathering (standard flow):**
```markdown
## Follow-up Tasks

- Plan authentication implementation | agent: architect | priority: high
```

**Architect completing a plan (emits dev tickets + the tail):**
```markdown
## Follow-up Tasks

- Implement user model and migration | agent: developer | priority: high | plan-slice: .guild/plans/PLAN-001/slice-user-model.md
- Implement signup endpoint | agent: developer | priority: high | plan-slice: .guild/plans/PLAN-001/slice-signup.md | parallel-group: A
- Implement login endpoint | agent: developer | priority: medium | plan-slice: .guild/plans/PLAN-001/slice-login.md | parallel-group: A
- Write unit tests for authentication | agent: test-writer | priority: high
- Review authentication implementation | agent: reviewer | priority: high
```

Here the user-model ticket is left ungrouped (the signup and login slices both build on it, so it
runs solo first). The signup and login slices touch disjoint files and share `parallel-group: A`, so
the orchestrator dispatches them together after the model is `done`.

**Reviewer finding issues (declares fixes only — orchestrator appends the tail):**
```markdown
## Follow-up Tasks

- Fix: Missing input validation on signup endpoint | agent: developer | priority: high
- Fix: SQL injection risk in login query | agent: developer | priority: high
```

### How the Orchestrator Processes Follow-ups

1. Read the completed task's "Follow-up Tasks" section.
2. For each line:
   a. Parse title, agent, priority, and optional `plan-slice` / `parallel-group`.
   b. Assign the next available TASK ID from `state.yaml` (`next-task`), then increment it.
   c. Create the task file in `.guild/tasks/` with `status: todo` — if `plan-slice` or
      `parallel-group` was present, write each into the frontmatter.
3. Link new tasks back to the same requirement as the parent task.
4. **Fix-loop tail:** if the completed ticket was a `reviewer` ticket and any `Fix:` tickets were
   declared, after creating the fix tickets append one `test-writer` ticket and one `Re-review …`
   ticket (only if a 2nd review round hasn't already run — see the round cap in `agent-chains.md`).

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

## Knowledge Base: `.guild/docs/`

The guild maintains a persistent knowledge base at `.guild/docs/` — researcher findings live here,
one file per topic, named `{topic-slug}.md`.

**Characteristics:**

- **Evergreen** — never archived on release, never cleared by `clear-board`
- **One topic per file** — the researcher updates existing docs in place when topics overlap
  rather than creating duplicates
- **Findable** — the architect globs `.guild/docs/` during codebase analysis; prior research
  informs new plans without re-dispatching the researcher

**Doc format:**

```markdown
---
title: "{Human-readable title}"
topic: {topic-slug}
created: {original creation date}
last-updated: {latest update date}
related-reqs: [REQ-NNN, REQ-MMM]
sources:
  - {url}
---

# {Title}

## Summary
## Key Findings
## Recommendations
## Compatibility Notes
## Risks and Gotchas
## References
```

Researcher task work logs contain only a short pointer (`See: .guild/docs/{slug}.md`) — the full
findings live in the doc.

## Plan File Format

The architect emits one overview file plus one slice per developer task.

**Overview** at `.guild/plans/PLAN-NNN.md` — for reviewers and orientation.
**Slices** at `.guild/plans/PLAN-NNN/slice-{slug}.md` — one per developer task. Each slice is
self-contained: a developer reads only its slice (not the overview, not sibling slices) to do its
work. The slice's "Interface Contract" section documents what the task exposes to or consumes from
sibling tasks.

Overview format:

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
