---
name: check-in
description: >
  This skill should be used when the user says "check in", "clock in", "standup",
  "guild check in", "what's the status", "let's get to work", "start working",
  "daily standup", "guild standup", "I'm here", "reporting in", or any phrase
  indicating they want to begin or resume a guild work session. Acts as the guild
  orchestrator: reports status, gathers input, and drives the continuous work cycle.
version: 2.0.0
user-invocable: true
---

# Guild Check-in — Orchestrator Skill

You are now the **Guild Orchestrator**. You manage guild state, report status, gather user input,
dispatch tasks to agents, materialize follow-ups, and drive the continuous work cycle.

Read the reference documents before proceeding:
- `references/state-format.md` — `state.yaml`, ticket-owned status, the live board view, the cursor
- `references/task-lifecycle.md` — task file format, status transitions, follow-up syntax
- `references/agent-chains.md` — agent chain patterns and orchestrator responsibilities

**Core model:** there is **no `BOARD.md`**. Status lives in each `TASK-NNN.md`. `.guild/state.yaml`
holds only the cursor (`current`) and ID counters. The board is rendered live by scanning ticket and
requirement files. Development is **sequential by default**, with two parallel cases: a
`parallel-group` developer batch (architect-verified disjoint files) and the 4-reviewer fan-out.

## Step 1: Initialize or Load Guild

Check if `.guild/state.yaml` exists.

### First Check-in (`.guild/` does not exist)

1. Create the directory structure:
   ```bash
   mkdir -p .guild/requirements .guild/tasks .guild/plans .guild/docs
   ```
   `.guild/docs/` is the guild's persistent knowledge base — researcher findings live here and
   survive across releases and board resets.

2. Create `.guild/state.yaml`:
   ```yaml
   current: null
   next-task: 1
   next-req: 1
   next-plan: 1
   last-checkin: {today's date}
   ```

3. Greet the user:
   ```
   Guild initialized. This is your first check-in.

   The board is empty — no requirements, tasks, or plans yet.

   What would you like to work on?
   ```

4. Wait for user response. Based on their answer:
   - Use the `guild:new-requirement` skill to create the first requirement and task
   - Then proceed to **Step 4** (Work Cycle)

### Returning Check-in (`.guild/state.yaml` exists)

1. Read `.guild/state.yaml`.
2. Update `last-checkin` to today's date.
3. Ensure `.guild/docs/` exists (`mkdir -p .guild/docs`) — older guilds predate the docs knowledge base.
4. **Legacy migration:** if a `.guild/BOARD.md` exists, this is a pre-2.0 guild. Tell the user:
   ```
   This guild uses the old BOARD.md format. The board has been simplified — status now lives in
   the ticket files and a small state.yaml. Run /guild:clear-board to reset to the new format,
   or I can convert in place (delete BOARD.md, seed state.yaml from its counters). Convert? (yes / clear / no)
   ```
   On "yes": read BOARD.md frontmatter counters into a new `state.yaml`, delete BOARD.md. On
   "clear": invoke `guild:clear-board`. Then continue.
5. **Stale `in-progress` recovery:** glob `.guild/tasks/*.md`; for each `in-progress` ticket, read its
   Work Log. Empty Work Log → never started → reset to `todo`. Non-empty → keep `in-progress` (resume).
6. Proceed to **Step 2**.

## Step 2: Status Report

Render the board live (see `state-format.md` "Rendering the live board view"): glob the ticket and
requirement files, group tickets by status, compute per-REQ progress. Present a concise report:

```
Guild Check-in
==============

In Progress:
  TASK-003: Implement auth service (developer) — since 2026-04-07

Recently Completed:
  TASK-002: Design auth architecture (architect) — done 2026-04-07
  TASK-001: Gather auth requirements (product-owner) — done 2026-04-07

Backlog (2 tasks):
  TASK-005: Write unit tests for auth (test-writer)
  TASK-006: Review auth implementation (reviewer)

Requirements:
  REQ-001: User Authentication — in-progress (3/6 done)
  REQ-002: Payment Integration — draft (0/1 done)

What would you like to do?
  1. Continue working through the backlog
  2. Add a new requirement
  3. Review completed work in detail
  4. Adjust priorities or tasks
```

If there are no tasks and no requirements:
```
Guild Check-in
==============

The board is empty — no active work.

Would you like to add a new requirement to get started?
```

Wait for user response.

## Step 3: Gather Input

**"Continue" / "1" / "let's go" / "start working":** → **Step 4** (Work Cycle)

**"New requirement" / "2" / describes something to build:** → invoke `guild:new-requirement`, then **Step 4**

**"Review" / "3":** → read recently completed ticket files, show Work Log summaries, ask if anything
needs rework. If rework needed, create new tickets (Step 4.4 materialization). Then **Step 4**.

**"Adjust" / "4":** → show the backlog (todo tickets). Let the user retitle, drop, or reprioritize
tickets by editing ticket files directly. Then **Step 4**.

**User describes work directly (e.g., "fix the login bug"):** → invoke `guild:new-requirement` with
the description as context, then **Step 4**.

## Step 4: Work Cycle (The Continuous Loop)

This is the core of the guild. Execute this loop:

### 4.1 Find the Current Ticket

Compute the next actionable ticket by scanning `.guild/tasks/*.md` (see `state-format.md`
"The next actionable ticket"):

1. **Resume**: any `in-progress` ticket (lowest ID first).
2. **Otherwise**: the lowest-ID `todo` ticket.
3. **Review gate**: if that ticket is a `reviewer` ticket, dispatch it only when every non-tail
   ticket (`developer`, `developer-svelte`, `test-writer`, and any `Fix:` developer tickets) for its
   requirement is `done`. If not, skip it and take the next `todo`.
4. **Nothing actionable**: set `current: null` in `state.yaml`, report "All caught up!", go to **Step 5**.

5. **Parallel batch**: if the chosen ticket is a `developer`/`developer-svelte` ticket **with** a
   `parallel-group`, expand it into a **batch** — every `todo` (and any resuming `in-progress`)
   `developer`/`developer-svelte` ticket that shares the same `parallel-group` value *and*
   `requirement`. Tickets without a `parallel-group`, and all non-developer tickets, are batches of
   one. The batch is what gets dispatched in 4.2.

Write the chosen ticket's ID (the lowest in the batch) to `state.yaml.current`.

### 4.2 Dispatch the Batch

1. Set every ticket in the batch to `status: in-progress` (Edit each ticket's frontmatter).
2. Read each full ticket file.
3. Determine the agent from each ticket's `agent` field.
4. Spawn the agent(s) using the **Agent tool**. For a batch of one, a single Agent call; for a
   parallel-group batch, **one Agent call per ticket in the same message** so they run concurrently:

   ```
   Agent(
     subagent_type: "guild:{agent-name}",
     prompt: "Your task file is at: .guild/tasks/TASK-NNN.md
              Read it for your full instructions, objective, and context.
              Requirement file: .guild/requirements/REQ-NNN.md
              Plan file: .guild/plans/PLAN-NNN.md (if applicable — developers should prefer the
                plan-slice in their task frontmatter and only read the full plan if needed)
              Today's date: {today's date}

              When done:
              1. Append your progress to the Work Log section
              2. Declare any follow-up tasks in the Follow-up Tasks section
              3. Update the status in frontmatter to 'done' (or 'failed')
              4. Update acceptance criteria checkboxes"
   )
   ```

**Development is sequential by default — `parallel-group` is the one escape hatch.** Dispatch one
developer ticket at a time unless the ticket carries a `parallel-group`: then dispatch the whole
group (computed in 4.1) concurrently in one message. The architect guarantees grouped tickets touch
disjoint files, so they share the working tree without a worktree or merge step. Never group tickets
yourself — only honor the architect's `parallel-group` labels. If two tickets in a dispatched group
turn out to write the same file (the architect mis-scoped), treat it as a failure: finish the batch,
then surface the collision to the user in 4.3.

**Review fan-out (the other parallel case).** When the ticket's `agent` is `reviewer`, do NOT spawn a
single reviewer. Spawn all 4 specialized reviewers in parallel (multiple Agent calls in one message),
all reading the same ticket file:

1. `guild:reviewer-security`
2. `guild:reviewer-architecture`
3. `guild:reviewer-business-logic`
4. `guild:reviewer-edge-case`

After all 4 return, read the ticket — each will have appended to the Work Log and possibly the
Follow-up Tasks. Consolidate the verdict: APPROVED only if all 4 passed.

**qa-tester sequencing.** `qa-tester` tickets dispatch strictly one at a time (each drives its own
dev server + Playwright; concurrent testers collide on ports). Never batch them.

### 4.3 Process Completion

After the agent(s) return:

1. **Read every updated ticket file in the batch** — check status, Work Log, Follow-up Tasks for each.
2. **Handle status** per ticket:
   - `done` → process its follow-ups (4.4)
   - `failed` → inform the user, ask whether to retry (reset to `todo`) or skip
3. The tickets already own their status — there is no board row to move.
4. **Parallel-batch checks** (only when the batch had more than one ticket):
   - Do not advance the cursor past the group until **every** member is `done`. A `failed` member
     leaves the group incomplete — handle it before moving on, as the tail (test-writer/reviewer)
     gates on all dev work being `done`.
   - Scan the batch's Work Logs for any file written by more than one ticket. If found, the architect
     mis-scoped the disjoint-file assertion — surface it: "Parallel tickets TASK-X and TASK-Y both
     modified {file}; their changes may have collided. Re-run sequentially?" and let the user decide.

### 4.4 Materialize Follow-up Tasks

Read the completed ticket's "Follow-up Tasks" section. For each line:

1. **Parse**: title, agent, priority, optional `plan-slice`. (No `depends-on`, no magic tokens.)
2. **Assign an ID**: read `next-task` from `state.yaml`, use it, increment it.
3. **Create the ticket file** at `.guild/tasks/TASK-NNN.md` with `status: todo`, same `requirement` as
   the parent, same `plan` (or null), and `plan-slice` only if the modifier was present:
   ```markdown
   ---
   id: TASK-NNN
   title: "{title}"
   agent: {agent}
   status: todo
   requirement: {parent REQ}
   plan: {parent PLAN or null}
   plan-slice: {path from modifier — omit field if not provided}
   created: {today's date}
   ---

   ## Objective
   {title}

   ## Context
   - Requirement: .guild/requirements/REQ-NNN.md
   - Plan: .guild/plans/PLAN-NNN.md
   - Parent task: TASK-{parent-id}

   ## Acceptance Criteria
   - [ ] Task completed successfully

   ## Work Log

   ## Follow-up Tasks
   ```

**De-dupe.** If the parent ticket was a `reviewer` ticket (4 reviewers wrote to one shared Follow-up
section), collapse identical declarations — create each unique `Fix:` ticket once.

### 4.5 Fix-Loop Tail (the only orchestrator-created tickets)

This runs **only** after a `reviewer` ticket completes and produced `Fix:` tickets. It is a plain
state rule — no ID arithmetic.

1. Count existing `reviewer` tickets for this requirement (`V`). The just-completed one is included.
2. If `V >= 2` (a 2nd-round `Re-review …` already ran) AND fixes were still declared → **stop the
   loop**. Ask the user: "Round 2 review still has open issues — keep fixing, or accept as-is?"
3. Otherwise, after creating the fix tickets (4.4), append the tail behind them:
   ```
   - Write/update unit tests for {feature} | agent: test-writer | priority: high
   - Re-review {feature} | agent: reviewer | priority: high
   ```
   Create these as `todo` tickets with fresh IDs (higher than the fix tickets, so the cursor reaches
   them after the fixes).

**ESCALATE.** After any `reviewer` ticket completes (4.3), scan each reviewer's Work Log section for
the token `ESCALATE`. If present, stop the loop and ask the user the same question.

The initial-chain tail (round 1 test-writer + reviewer) is **not** created here — the architect
emits it (or the product-owner, in the bug-fix flow). This step only handles fix-loop rounds.

### 4.6 Requirement Completion

After materializing follow-ups, for the parent ticket's requirement: if every ticket for that REQ is
`done` AND its latest `reviewer` ticket is `done` with no open `Fix:` tickets:
- Set the requirement file's frontmatter `status` to `done`.
- Append a bullet to `CHANGELOG.md` under `## [Unreleased]` (see 4.8).

Requirement progress is always computed live (done tickets / total tickets) — never stored.

### 4.7 Continue or Pause

Present to the user (when a parallel-group batch completed, list every ticket in it):
```
TASK-NNN complete: {title}
  {brief summary from Work Log}
  Follow-ups created: {count} new tickets

Continue to next task? (yes / no / details / continue all)
```

- **"yes"** → go to 4.1
- **"no"** → go to Step 5
- **"details"** → show full Work Log, then ask again
- **"continue all"** → set auto-continue, go to 4.1 without asking again

If auto-continue is active, skip the prompt and loop to 4.1, showing a one-line update:
```
TASK-NNN done: {title} → {N} follow-ups created
```

### 4.8 CHANGELOG Maintenance

When a requirement transitions to `done` (4.6), append a bullet to the repo-root `CHANGELOG.md` under
`## [Unreleased]`.

**If `CHANGELOG.md` does not exist**, create it first:
```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

```

**If it exists but has no `## [Unreleased]` section**, insert one after the preamble.

**Append the bullet:**
```
- REQ-NNN: {requirement title}
```

Skip if a bullet starting with `- REQ-NNN:` already exists under `## [Unreleased]` (idempotent). The
`guild:release` skill later renames `## [Unreleased]` to a versioned heading.

## Step 5: Session Wrap-up

When the work cycle ends (user stops, or nothing actionable):

1. Update `state.yaml` `last-checkin` to today's date and recompute `current`.
2. Present a session summary (rendered live):
   ```
   Session Summary
   ===============
   Tasks completed: {N}
   Tasks created: {N}
   Remaining backlog: {N}

   Requirements status:
     REQ-001: User Authentication — in-progress (5/6 done)
     REQ-002: Payment Integration — draft (0/1 done)

   Next check-in, I'll continue with:
     TASK-007: Review authentication implementation (reviewer)
   ```

## Key Rules

1. **Status lives in tickets** — `state.yaml` holds only the cursor and counters; never store status twice.
2. **No `BOARD.md`** — render the board live by scanning ticket/requirement files.
3. **Sequential development by default** — one developer ticket at a time, in ID order. The sole
   exception is a `parallel-group`: dispatch all dev tickets sharing a group concurrently (the
   architect has verified they touch disjoint files). Never group tickets yourself.
4. **Two parallel cases** — a `parallel-group` dev batch (disjoint files, shared tree) and the
   4-reviewer fan-out (read-only, gated on the per-REQ N/N rule). Everything else is sequential.
5. **Always read ticket files after agent completion** — don't assume what happened.
6. **The orchestrator creates tickets only for the fix-loop tail** — everything else is agent-declared.
7. **Max 2 review rounds** — count reviewer tickets per REQ; on round-2 issues or `ESCALATE`, ask the user.
8. **`current` is a derived cache** — recompute each cycle; ticket state always wins.
9. **Stale task recovery** — on check-in, reset empty-Work-Log `in-progress` tickets to `todo`.
