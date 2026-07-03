# Task Lifecycle & File Format

## Task File Location — status is the directory

Task files live under `.guild/tasks/<status>/TASK-NNN.md` (zero-padded 3-digit ID), where
`<status>` is one of `todo`, `in-progress`, `done`, `failed`. **The directory IS the status** —
there is no `status` frontmatter field, no board, no second copy. To change a task's status, the
orchestrator **moves the file** with `guild move TASK-NNN <status>`.

All task creation, movement, and lookup go through the guild CLI at
`${CLAUDE_PLUGIN_ROOT}/scripts/guild` (see `scripts/README.md`).

## Task File Format

```markdown
---
id: TASK-001
title: "Short descriptive title"
agent: product-owner
requirement: REQ-001
plan: null
created: 2026-04-07
---

## Objective

Clear description of what this task needs to accomplish.

## Context

- Requirement: REQ-001
- Plan: PLAN-001 (if applicable)
- Prior task: TASK-000 (if this is a follow-up)

## Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

## Work Log

_Agent appends progress notes here as it works._

## Follow-up Tasks

_Agent declares follow-ups here upon completion._
```

`guild new task` scaffolds this template. Agents reference linked artifacts by **ID** and resolve
the current path with `guild path <ID>` / `guild read <ID>` (locations move as status changes).

## Frontmatter Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Task ID (e.g., `TASK-001`) |
| `title` | string | yes | Short descriptive title |
| `agent` | string | yes | Assigned agent (see enum below). The orchestrator spawns `guild:{agent}`. |
| `requirement` | string | yes | Linked requirement ID (e.g., `REQ-001`) |
| `plan` | string | no | Linked plan ID (e.g., `PLAN-001`), `null` if none |
| `plan-slice` | string | no | Slice **slug** for a per-task plan slice (e.g. `signup`). Resolve the current file with `guild slice PLAN-NNN <slug>`. When present, the developer reads this instead of the full plan. |
| `parallel-group` | string | no | A label (e.g., `A`, `B`) shared by `developer`/`developer-svelte` tickets the architect has verified touch **non-overlapping** files. Tickets with the same group run concurrently; a ticket with no group runs solo. Scoped per plan. |
| `created` | string | yes | Creation date (YYYY-MM-DD) |

> There is **no `status` field** — status is the containing directory. There is **no `depends-on`
> field** — sequencing is creation order (ID order) plus the per-REQ review gate, not a dependency
> graph. The research-first flow works because the researcher ticket is created before (lower ID
> than) the post-research architect ticket.

**`agent` enum:** `product-owner`, `architect`, `developer`, `developer-svelte`, `test-planner`,
`test-writer`, `researcher`, `reviewer`, `qa-strategist`, `qa-tester`. `reviewer` is a **trigger
alias**, not a real agent — when dispatched it spawns the 4 specialized reviewers
(`reviewer-security`, `reviewer-architecture`, `reviewer-business-logic`, `reviewer-edge-case`)
in parallel on the same ticket.

> **`parallel-group` is not a dependency graph either.** It is a pure safety assertion by the
> architect: "these dev tickets touch disjoint files and share no ordering, so the shared working
> tree won't be corrupted if they run at once." It only ever groups `developer`/`developer-svelte`
> tickets, never tail tickets (`test-writer`, `reviewer`). Ungrouped dev tickets stay sequential.

## Status Values & Transitions

Status is the directory; transitions are `guild move` calls performed by the **orchestrator**:

```
tasks/todo/  → tasks/in-progress/  → tasks/done/
                                   → tasks/failed/
```

| Directory | Meaning |
|-----------|---------|
| `tasks/todo/` | Ready to be picked up (waiting in the queue) |
| `tasks/in-progress/` | An agent is actively working on it |
| `tasks/done/` | Successfully completed |
| `tasks/failed/` | User-adjudicated: the agent failed and the user chose not to retry (waived). Does not block the review gate or requirement completion; waived tickets are reported in the completion summary. |

(There is no `blocked` status — without a dependency graph there is nothing to block on.)

**The orchestrator owns every transition.** On dispatch it runs `guild move TASK-NNN in-progress`;
on the agent's completion `guild move TASK-NNN done`; on failure `guild move TASK-NNN failed`; on
retry `guild move TASK-NNN todo`. **Agents never move their own files** — they report completion
and the orchestrator moves the task.

## Work Log Convention

Agents append to the Work Log section **as they work** — a start entry before substantive work
begins, a bullet per milestone, and a final completion/failure report. Each entry includes the date
and agent name:

```markdown
## Work Log

### 2026-04-07 — architect
- Started — analyzing REQ-001
- Analyzed REQ-001 requirements (5 user stories, 3 edge cases)
- Explored codebase: found existing auth patterns in src/middleware/
- Created PLAN-001 with 4 implementation tasks
- Work complete — reporting to orchestrator
```

The start entry is not optional politeness — it is what the recovery triage keys on. On check-in,
each task in `tasks/in-progress/` is triaged three ways:
- **Empty Work Log** → never started → back to `tasks/todo/`.
- **Final entry reports completion/failure** → the session died before the orchestrator recorded
  it → the orchestrator records the outcome now (follow-ups, then move) without re-dispatching.
- **Started but unfinished** → stays `in-progress`; the resumed agent reads the Work Log and
  continues from the last entry.

## Follow-up Tasks Section

When an agent completes its work, it declares follow-up tasks in this section. Each line follows the
format:

```
- {title} | agent: {agent-name}
```

Optional modifiers (combine freely, pipe-separated):
```
- {title} | agent: developer | plan: PLAN-NNN | plan-slice: {slice-slug} | parallel-group: A
```

The `plan:` modifier carries the PLAN ID the new ticket links to; **when absent, the ticket
inherits the parent ticket's `plan` frontmatter**. Only the architect emits it — its own ticket was
created before the plan existed (`plan: null`), so without the modifier the plan ID would never
reach downstream tickets. The `plan-slice` modifier is emitted by the architect for each developer
task as a slice **slug**; the orchestrator passes it to `guild new task --plan-slice {slug}`, which
records it in the new task's frontmatter. The `parallel-group` modifier is also emitted by the
architect, only on `developer`/`developer-svelte` tickets it has verified touch disjoint files; the
orchestrator passes it to `guild new task --parallel-group {label}` and uses it to batch the
dispatch (see "Parallel developer batching" below). There is no `priority` modifier (ordering is
strictly ID order; ignore a legacy `priority:` field on old tickets), no `depends-on`, and no magic
tokens.

### Parallel developer batching

Development runs **in parallel by default**: the architect designs slices for disjoint file sets
and marks each wave of `developer`/`developer-svelte` tickets with the **same** `parallel-group`
label, asserting their "Files to Touch" sets are disjoint and neither depends on the other's
output. The orchestrator expands the batch deterministically with `guild batch TASK-NNN` (which
lists every `todo`/`in-progress` task sharing that ticket's `parallel-group` and `requirement`),
then dispatches the whole group concurrently in one message (multiple Agent calls in the shared
working tree — no worktrees, no merge step, because the file sets don't overlap). An ungrouped
ticket runs solo — the exception, for foundational work or unboundable file sets.

Rules:
- Only `developer`/`developer-svelte` tickets carry a group. Tail tickets (`test-planner`,
  `test-writer`, `reviewer`) and all other agents never do.
- A group is scoped to one plan. Reuse simple labels (`A`, `B`, …) per plan.
- A ticket with **no** `parallel-group` runs solo, exactly as before.
- The batch is dispatched together and the cursor only advances past it once **every** member is
  `done` — so the test-writer/reviewer tail still waits for all dev work, just as in the sequential
  case.

### The chain tail (test planning → tests → review)

The tail is a `test-planner` ticket followed by a `reviewer` ticket; the test-planner then declares
the `test-writer` ticket(s) that sit between them (the reviewer's N/N gate holds the review until
those are done, even though they have higher IDs). Who emits what:

- **Initial chain — the architect emits the tail.** After its developer follow-ups, the architect
  declares the `test-planner` and `reviewer` tickets explicitly, so the full pipeline is visible as
  real tickets up front. It never declares `test-writer` tickets — that's the test-planner's call.
- **Test planning — the test-planner emits the test-writer ticket(s)** (one combined, or one unit +
  one integration), each carrying `plan-slice: test-plan`.
- **Bug-fix flow (no architect, no test-planner) — the product-owner emits the tail** behind the
  fix ticket: a `test-writer` ticket and a `reviewer` ticket directly.
- **Fix loop — the orchestrator appends the tail.** The 4 reviewers declare only `Fix: …` tickets;
  after a review round that produced fixes, the orchestrator creates the fix tickets, then one
  `test-writer` ticket (with `plan-slice: test-plan` when a plan exists) and one `Re-review …`
  ticket behind them (deduped — reviewers never each emit the tail). The test-planner is not
  re-run in the fix loop.

### Examples

**Product owner completing requirements gathering (standard flow):**
```markdown
## Follow-up Tasks

- Plan authentication implementation | agent: architect
```

**Architect completing a plan (emits dev tickets + the tail, every line carrying `plan:`):**
```markdown
## Follow-up Tasks

- Implement user model and migration | agent: developer | plan: PLAN-001 | plan-slice: user-model
- Implement signup endpoint | agent: developer | plan: PLAN-001 | plan-slice: signup | parallel-group: A
- Implement login endpoint | agent: developer | plan: PLAN-001 | plan-slice: login | parallel-group: A
- Plan tests for authentication | agent: test-planner | plan: PLAN-001
- Review authentication implementation | agent: reviewer | plan: PLAN-001
```

Here the user-model ticket is left ungrouped (the signup and login slices both build on it, so it
runs solo first). The signup and login slices touch disjoint files and share `parallel-group: A`, so
the orchestrator dispatches them together after the model is `done`.

**Test-planner completing the test plan (emits the test-writer tickets):**
```markdown
## Follow-up Tasks

- Write unit tests for authentication | agent: test-writer | plan-slice: test-plan
- Write integration tests for authentication | agent: test-writer | plan-slice: test-plan
```

**Reviewer finding issues (declares fixes only — orchestrator appends the tail):**
```markdown
## Follow-up Tasks

- Fix: Missing input validation on signup endpoint | agent: developer
- Fix: SQL injection risk in login query | agent: developer
```

### How the Orchestrator Processes Follow-ups

The operative procedure lives in the check-in skill, **Step 3.4** (parse → skip annotated lines →
`guild new task` → annotate ` → TASK-NNN`), and Step 3.3 orders it **before** the parent's terminal
`guild move done` so a crash never strands unmaterialized follow-ups. This file owns only the line
grammar above; do not duplicate the procedure here.

## Requirement File Format

Location: `.guild/requirements/<status>/REQ-NNN.md` (status = directory; `todo` ≈ the old `draft`).

```markdown
---
id: REQ-001
title: "User Authentication"
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

**Status (directory) transitions:** `requirements/todo/` → `requirements/in-progress/` →
`requirements/done/`, performed with `guild move REQ-NNN <status>`. `guild new req` scaffolds a stub
in `requirements/todo/`. No `status` frontmatter field.

## Knowledge Base: `.guild/docs/`

The guild maintains a persistent knowledge base at `.guild/docs/` — researcher findings live here,
one file per topic, named `{topic-slug}.md`.

**Characteristics:**

- **Evergreen** — never archived on release, never cleared by `clear-board`
- **One topic per file** — the researcher updates existing docs in place when topics overlap rather
  than creating duplicates
- **Findable** — the architect globs `.guild/docs/` during codebase analysis; prior research informs
  new plans without re-dispatching the researcher

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

The architect emits one overview file plus one slice per developer task. `guild new plan` scaffolds
the overview in `plans/todo/` and creates its sibling slice directory.

**Overview** at `.guild/plans/<status>/PLAN-NNN.md` — for reviewers and orientation.
**Slices** at `.guild/plans/<status>/PLAN-NNN/slice-{slug}.md` — one per developer task. The slice
directory travels with the overview when the plan is moved between status dirs, so agents resolve a
slice path with `guild slice PLAN-NNN {slug}` rather than hardcoding it. Each slice is
self-contained: a developer reads only its slice (not the overview, not sibling slices) to do its
work. The slice's "Interface Contract" section documents what the task exposes to or consumes from
sibling tasks.

**Test plan** at `.guild/plans/<status>/PLAN-NNN/slice-test-plan.md` — written later by the
test-planner (not the architect), after all development for the requirement is done. Resolved with
`guild slice PLAN-NNN test-plan`. It carries the Changed Files Inventory, the test infrastructure
survey, and the unit/integration case lists; the test-writer implements it and the reviewers reuse
its inventory to scope their reading.

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
