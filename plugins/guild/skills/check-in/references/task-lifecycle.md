# Task Lifecycle & Ticket Format

## There Are No Task Files — status is a column

A task is a ROW in `.guild/guild.db` with a zero-padded 3-digit ID (`TASK-001`). **`status` is a
column**, one of `todo`, `in-progress`, `done`, `failed`, and the orchestrator changes it with
`guild move TASK-NNN <status>` — there are no status directories and nothing to move on disk.

The markdown shown below is what `guild read TASK-NNN` RENDERS from that row (frontmatter
projected from columns, body from `body`, Work Log from `work_log`). It is not a file you can open
or edit. `.guild/export/REQ-NNN.md` is a generated snapshot that `guild export` rewrites wholesale;
editing it loses the edit.

All task creation, movement, and lookup go through the guild CLI at
`${CLAUDE_PLUGIN_ROOT}/scripts/guild` (see `scripts/README.md`).

## Task Record Format

```markdown
---
id: TASK-001
title: "Short descriptive title"
agent: developer
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

`guild new task` scaffolds this template; `guild new task --body` replaces it outright when the
creator has the whole document already.

**There are no ticket files, and no paths.** `## Work Log` and `## Follow-up Tasks` are RENDERED by
`guild read`, not stored — the log is built from `work_log` rows, which agents append to with
`guild log TASK-NNN --agent A --entry '...'` and the orchestrator folds in with
`guild spool drain TASK-NNN`. Agents reference linked artifacts by **ID** and read them with
`guild read <ID>` / `guild meta <ID> [field]` / `guild slice PLAN-NNN <slug>`. `guild path` was
removed in v5: the only files under `.guild/export/` are regenerated wholesale by `guild export`,
so anything written there is discarded.

## Frontmatter Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Task ID (e.g., `TASK-001`) |
| `title` | string | yes | Short descriptive title |
| `agent` | string | yes | Assigned agent (see enum below). The orchestrator spawns `guild:{agent}`. |
| `requirement` | string | yes | Linked requirement ID (e.g., `REQ-001`) |
| `plan` | string | no | Linked plan ID (e.g., `PLAN-001`), `null` if none |
| `plan-slice` | string | no | Slice **slug** for a per-task plan slice (e.g. `signup`). Read it with `guild slice PLAN-NNN <slug>`. When present, the developer reads this instead of the full plan. |
| `parallel-group` | string | no | A label (e.g., `A`, `B`) shared by `developer`/`developer-svelte` tickets the architect has verified touch **non-overlapping** files. Tickets with the same group run concurrently; a ticket with no group runs solo. Scoped per plan. |
| `created` | string | yes | Creation date (YYYY-MM-DD) |

> There is **no `status` frontmatter field** — status is a column on the row, projected into the
> rendered frontmatter by `guild read` but never written by editing it. There is **no `depends-on`
> field** — sequencing is creation order (ID order) plus the per-REQ review gate, not a dependency
> graph. The research-first flow works because the researcher ticket is created before (lower ID
> than) the post-research architect ticket.

**`agent` enum:** `developer`, `developer-svelte`, `test-planner`, `test-writer`, `researcher`,
`reviewer`, `qa-strategist`, `qa-tester`. `reviewer` is a **trigger alias**, not a real agent — when
dispatched it spawns the 4 specialized reviewers (`reviewer-security`, `reviewer-architecture`,
`reviewer-business-logic`, `reviewer-edge-case`) in parallel on the same ticket.

`product-owner` and `architect` are **not** ticket-dispatched agents — they're spawned directly by
the `guild:new-requirement` skill for a live interview, and the architect creates every downstream
ticket itself via the CLI before that skill returns. They never appear as a task's `agent:` value
in normal operation.

> **`parallel-group` is not a dependency graph either.** It is a pure safety assertion by the
> architect: "these dev tickets touch disjoint files and share no ordering, so the shared working
> tree won't be corrupted if they run at once." It only ever groups `developer`/`developer-svelte`
> tickets, never tail tickets (`test-writer`, `reviewer`). Ungrouped dev tickets stay sequential.

## Status Values & Transitions

Status is the `task.status` column; transitions are `guild move` calls performed by the
**orchestrator**:

```
todo  →  in-progress  →  done
                      →  failed
```

| Status | Meaning |
|--------|---------|
| `todo` | Ready to be picked up (waiting in the queue) |
| `in-progress` | An agent is actively working on it |
| `done` | Successfully completed |
| `failed` | User-adjudicated: the agent failed and the user chose not to retry (waived). Does not block the review gate or requirement completion; waived tickets are reported in the completion summary. |

(There is no `blocked` status — without a dependency graph there is nothing to block on.)

**The orchestrator owns every transition.** On dispatch it runs `guild move TASK-NNN in-progress`;
on the agent's completion `guild move TASK-NNN done`; on failure `guild move TASK-NNN failed`; on
retry `guild move TASK-NNN todo`. **Agents never move their own work** — they report completion
and the orchestrator moves the row.

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
each `in-progress` task is triaged three ways — **after `guild spool drain TASK-NNN`**, because an
undrained ticket renders an empty Work Log and would be reset:
- **Empty Work Log** → never started → `guild move TASK-NNN todo`.
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
those are done, even though they have higher IDs). Who creates what:

- **Initial chain — the architect creates the tail directly.** It has Bash and the CLI; after
  writing the plan, it runs `guild new task` for every developer ticket, then the `test-planner`
  ticket, then the `reviewer` ticket — no "Follow-up Tasks" declaration involved, since the
  architect has no ticket of its own for the orchestrator to materialize from. It never creates
  `test-writer` tickets — that's the test-planner's call.
- **Test planning — the test-planner emits the test-writer ticket(s)** (one combined, or one unit +
  one integration), each carrying `plan-slice: test-plan`. This is a normal Follow-up Tasks
  declaration, materialized by the orchestrator as usual (the test-planner IS ticket-dispatched).
- **Bug-fix flow (no architect, no test-planner) — the product-owner creates the tail directly**,
  the same way the architect does: `guild new task` for a fix ticket, a `test-writer` ticket, and a
  `reviewer` ticket, with no plan.
- **Review findings — no automatic tail at all.** The 4 reviewers only write findings to the Work
  Log now; they don't declare `Fix:` tickets. The orchestrator compiles a review report and asks
  the user which findings (if any) should become fix tickets — see "Review Reports" below. Approved
  fixes are plain `developer` tickets with no forced test-writer/re-review tail, and there is no
  automatic re-review.

### Examples

**Architect creating a plan's tickets (direct CLI calls, not a Follow-up Tasks declaration — the
architect has no ticket of its own):**
```bash
"$GUILD" new task --title "Implement user model and migration" --agent developer --req REQ-001 --plan PLAN-001 --plan-slice user-model --date 2026-04-07
"$GUILD" new task --title "Implement signup endpoint" --agent developer --req REQ-001 --plan PLAN-001 --plan-slice signup --parallel-group A --date 2026-04-07
"$GUILD" new task --title "Implement login endpoint" --agent developer --req REQ-001 --plan PLAN-001 --plan-slice login --parallel-group A --date 2026-04-07
"$GUILD" new task --title "Plan tests for authentication" --agent test-planner --req REQ-001 --plan PLAN-001 --date 2026-04-07
"$GUILD" new task --title "Review authentication implementation" --agent reviewer --req REQ-001 --plan PLAN-001 --date 2026-04-07
```

Here the user-model ticket is left ungrouped (the signup and login slices both build on it, so it
runs solo first). The signup and login slices touch disjoint files and share `parallel-group: A`, so
the orchestrator dispatches them together after the model is `done`.

**Test-planner completing the test plan (emits the test-writer tickets — a normal Follow-up Tasks
declaration, since the test-planner IS ticket-dispatched):**
```markdown
## Follow-up Tasks

- Write unit tests for authentication | agent: test-writer | plan-slice: test-plan
- Write integration tests for authentication | agent: test-writer | plan-slice: test-plan
```

**Reviewer findings (Work Log only — no Follow-up Tasks declaration; see "Review Reports" below
for how findings become fix tickets):**
```markdown
### 2026-04-07 — reviewer-security

**Verdict:** ISSUES FOUND

**Findings:**
1. [critical] src/routes/signup.ts:42 — missing input validation on signup endpoint
   Recommendation: validate email format and password length server-side before insert
```

### How the Orchestrator Processes Follow-ups

The operative procedure lives in the check-in skill, **Step 3.4** (parse → skip annotated lines →
`guild new task` → annotate ` → TASK-NNN`), and Step 3.3 orders it **before** the parent's terminal
`guild move done` so a crash never strands unmaterialized follow-ups. This file owns only the line
grammar above; do not duplicate the procedure here.

## Requirement Record Format

A row in the `requirement` table, rendered by `guild read REQ-NNN`. `status` is a column
(`todo` ≈ the old `draft`), set only by `guild move`.

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

**Status transitions:** `todo` → `in-progress` → `done`, performed with
`guild move REQ-NNN <status>`. `guild new req` inserts the row at `todo`. No `status` frontmatter
field, and no directories.

**Direction is optional and lives above the requirement.** `requirement.phase_id` is nullable:
`guild req assign REQ-NNN PHASE-NNN` attaches it to a phase (and `… none` detaches it), and
unaffiliated requirements are legal by design. Goals and phases have their own verbs
(`guild goal …`, `guild phase …`) and **do not gate** — the per-REQ review gate is still the only
conditional in `guild next`.

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

> **The `doc` table exists alongside the directory.** `guild init` carries a v4 `.guild/docs/` tree
> into it, and `guild doc put|get|list|search` read and write it. The researcher still writes
> markdown files to `.guild/docs/`, and the architect still globs that directory — so the directory
> is the live surface today and the table is seeded but not yet produced into. Do not "fix" one by
> deleting the other; wiring the researcher onto `guild doc put` is a change, not a cleanup.

## Review Reports: `.guild/reviews/`

Compiled by the **orchestrator** (not an agent) after a `reviewer` ticket batch completes — see
check-in Step 3.5. One file per requirement: `.guild/reviews/REQ-NNN.md`. Unlike `.guild/docs/`,
this is not agent-maintained knowledge — it's the orchestrator's record of what each review round
found, for the user to read and act on.

**Append, never overwrite** — each round adds a new dated section:

```markdown
## 2026-04-07 — TASK-012

### reviewer-security — ISSUES FOUND
1. [critical] src/routes/signup.ts:42 — missing input validation on signup endpoint
   Recommendation: validate email format and password length server-side before insert

### reviewer-architecture — PASS

### reviewer-business-logic — PASS

### reviewer-edge-case — ISSUES FOUND
1. [major] src/routes/signup.ts:58 — duplicate signup requests not idempotent
   Recommendation: dedupe on email within a short window
```

Findings marked critical/major here are what the orchestrator lists when it asks the user
(`AskUserQuestion`) which should become fix tickets. There is no automatic fix loop and no round
cap — see check-in Step 3.5 and agent-chains.md Chain 4.

## Plan Record Format

The architect writes one overview plus one slice brief per developer task. **There are no plan
files and no slice directory** — a plan is a row and a slice is a row.

**Overview** — passed as `guild new plan --desc` (or `--body`) at creation, read back with
`guild read PLAN-NNN`. For reviewers and orientation.

**Slice briefs** — one per developer task. `plan_slice` rows exist in the schema and
`guild slice PLAN-NNN {slug}` reads one, but **Stage 1 ships no command that writes one**; that is
pending a later stage. Until it lands, the architect puts each slice brief in its developer
ticket's `--objective`, which `guild read TASK-NNN` renders under `## Objective`, and still passes
`--plan-slice {slug}` so the association is recorded on the row. Each brief is self-contained: a
developer reads only its own ticket (not the overview, not sibling briefs) to do its work. The
brief's "Interface Contract" section documents what the task exposes to or consumes from
sibling tasks.

**Test plan** — composed later by the test-planner (not the architect), after all development for
the requirement is done, and passed as the `--objective` of the test-writer ticket(s) it creates
(with `--plan-slice test-plan`). It carries the Changed Files Inventory, the test infrastructure
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
