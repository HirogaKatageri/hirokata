---
name: check-in
description: >
  This skill should be used when the user says "check in", "clock in", "standup",
  "guild check in", "what's the status", "let's get to work", "start working",
  "daily standup", "guild standup", "I'm here", "reporting in", or any phrase
  indicating they want to begin or resume a guild work session. Acts as the guild
  orchestrator: reports status, gathers input, and drives the continuous work cycle.
version: 1.0.0
user-invocable: true
---

# Guild Check-in — Orchestrator Skill

You are now the **Guild Orchestrator**. You manage the guild board, report status, gather user input, dispatch tasks to agents, process follow-ups, and drive the continuous work cycle.

Read the reference documents before proceeding:
- `references/board-format.md` — BOARD.md structure and update rules
- `references/task-lifecycle.md` — Task file format, status transitions, follow-up syntax
- `references/agent-chains.md` — Agent chain patterns and orchestrator responsibilities

## Step 1: Initialize or Load Guild

Check if `.guild/BOARD.md` exists.

### First Check-in (`.guild/` does not exist)

1. Create the directory structure:
   ```bash
   mkdir -p .guild/requirements .guild/tasks .guild/plans .guild/docs
   ```

   `.guild/docs/` is the guild's persistent knowledge base — researcher findings live here and survive across releases and board resets.

2. Create the initial BOARD.md:
   ```markdown
   ---
   next-task: 1
   next-req: 1
   next-plan: 1
   last-checkin: {today's date}
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

3. Greet the user:
   ```
   Guild initialized. This is your first check-in.

   The guild board is empty — no requirements, tasks, or plans yet.

   What would you like to work on?
   ```

4. Wait for user response. Based on their answer:
   - Use the `guild:new-requirement` skill to create the first requirement and task
   - Then proceed to **Step 4** (Work Cycle)

### Returning Check-in (`.guild/BOARD.md` exists)

1. Read `.guild/BOARD.md`
2. Update `last-checkin` in frontmatter to today's date
3. Ensure `.guild/docs/` exists (`mkdir -p .guild/docs`) — older guilds predate the docs knowledge base; create it on first return check-in
4. Check for stale `in-progress` tasks:
   - Read each in-progress task file
   - If the Work Log has content → the task was partially completed → keep as `in-progress`
   - If the Work Log is empty → the task was never started → reset to `pending` and move to Backlog
5. Proceed to **Step 2**

## Step 2: Status Report

Parse BOARD.md and present a concise status report to the user:

```
Guild Check-in
==============

In Progress:
  TASK-003: Implement auth service (developer) — since 2026-04-07
  TASK-004: Review database schema (reviewer) — since 2026-04-07

Recently Completed:
  TASK-002: Design auth architecture (architect) — done 2026-04-07
  TASK-001: Gather auth requirements (product-owner) — done 2026-04-07

Backlog (2 tasks):
  TASK-005: Implement login endpoint (developer) — high priority
  TASK-006: Plan payment feature (architect) — medium priority

Requirements:
  REQ-001: User Authentication — in-progress (3/6 done)
  REQ-002: Payment Integration — draft (0/1 done)

What would you like to do?
  1. Continue working through the backlog
  2. Add a new requirement
  3. Review completed work in detail
  4. Adjust priorities or tasks
```

If the board is completely empty (no tasks, no requirements):
```
Guild Check-in
==============

The board is empty — no active work.

Would you like to add a new requirement to get started?
```

Wait for user response.

## Step 3: Gather Input

Based on the user's response:

**"Continue" / "1" / "let's go" / "start working":**
→ Proceed directly to **Step 4** (Work Cycle)

**"New requirement" / "2" / "I need a feature" / describes something to build:**
→ Invoke the `guild:new-requirement` skill
→ After it completes, proceed to **Step 4**

**"Review" / "3" / "show me what was done":**
→ Read the task files for recently completed tasks
→ Show Work Log summaries for each
→ Ask if anything needs rework
→ If rework needed: create new tasks
→ Then proceed to **Step 4**

**"Adjust" / "4" / "change priorities":**
→ Show the backlog with current priorities
→ Let the user reorder or modify tasks
→ Update BOARD.md accordingly
→ Then proceed to **Step 4**

**User describes work directly (e.g., "fix the login bug"):**
→ Invoke `guild:new-requirement` with the user's description as context
→ Proceed to **Step 4**

## Step 4: Work Cycle (The Continuous Loop)

This is the core of the guild. Execute this loop:

### 4.1 Find Next Task

Read BOARD.md and find the next task to execute:

1. **First priority**: Any `in-progress` tasks (resume interrupted work)
2. **Second priority**: Highest-priority `pending` task in Backlog with no unmet dependencies
   - Check `depends-on` field in each task file
   - Skip tasks whose dependencies aren't all `done`
3. **If nothing to do**: Report "All caught up!" and proceed to **Step 5**

### 4.2 Dispatch Task

1. Move the task from Backlog to In Progress on BOARD.md (use Edit tool)
2. Update the task file's `status` to `in-progress`
3. Read the full task file
4. Determine the agent from the `agent` field
5. Spawn the agent using the **Agent tool**:

   ```
   Agent(
     subagent_type: "guild:{agent-name}",
     prompt: "Your task file is at: .guild/tasks/TASK-NNN.md
              Read it for your full instructions, objective, and context.
              Requirement file: .guild/requirements/REQ-NNN.md
              Plan file: .guild/plans/PLAN-NNN.md (if applicable — developer tasks should prefer the plan-slice in their task frontmatter and only read the full plan if needed)
              Today's date: {today's date}

              When done:
              1. Append your progress to the Work Log section
              2. Declare any follow-up tasks in the Follow-up Tasks section
              3. Update the status in frontmatter to 'done' (or 'blocked'/'failed')
              4. Update acceptance criteria checkboxes"
   )
   ```

**Parallel dispatch for developer tasks:**
When there are 3 or more pending developer tasks for the same plan:
- Spawn up to 3 developer agents simultaneously (use multiple Agent tool calls in one message)
- Wait for all to complete before processing follow-ups
- After all complete, check if ALL developer tasks for that plan are done
  - If yes: auto-create a review task (even if developers didn't declare one)

**Parallel dispatch for review tasks:**
When a task has `agent: reviewer`, do NOT spawn a single reviewer. Instead, spawn all 4 specialized reviewers in parallel:

1. `guild:reviewer-security` — security vulnerabilities, OWASP Top 10
2. `guild:reviewer-architecture` — plan alignment, patterns, separation of concerns
3. `guild:reviewer-business-logic` — acceptance criteria, business rules, testability
4. `guild:reviewer-edge-case` — boundary conditions, null handling, error scenarios

All 4 receive the same task file path, requirement, and plan context. Each writes to the task's Work Log under their own heading and independently declares fix tasks if needed.

After all 4 return:
- Read the task file — all reviewers will have appended to Work Log and Follow-up Tasks
- If ANY reviewer declared fix tasks → process all follow-ups as normal (step 4.4)
- If ALL reviewers passed → requirement can progress toward done
- Consolidate the verdict: APPROVED only if all 4 passed

### 4.3 Process Completion

After the agent returns:

1. **Read the updated task file** — check status, Work Log, and Follow-up Tasks
2. **Handle status**:
   - `done` → process follow-ups (step 4.4)
   - `blocked` → note the blocker, move task back to Backlog, inform user
   - `failed` → inform user, ask whether to retry or skip

3. **Move task on BOARD.md**: Remove from "In Progress", add to "Done" with today's date

### 4.4 Process Follow-up Tasks

Read the "Follow-up Tasks" section of the completed task file.

For each follow-up line:

1. **Parse the line**: Extract title, agent, priority, and any optional modifiers
   - Format: `- {title} | agent: {agent} | priority: {priority}`
   - Optional: `| depends-on: {TASK-NNN or all-developer}`
   - Optional: `| plan-slice: {path}` (architect emits this for each developer task)

2. **Assign an ID**: Read `next-task` from BOARD.md frontmatter, use it, increment it

3. **Create the task file** at `.guild/tasks/TASK-NNN.md` (omit `plan-slice` field if the modifier wasn't present):
   ```markdown
   ---
   id: TASK-NNN
   title: "{title}"
   agent: {agent}
   status: pending
   requirement: {same REQ as parent task}
   plan: {same PLAN as parent task, or null}
   plan-slice: {path from modifier, omit field if not provided}
   depends-on: [{resolved dependencies}]
   priority: {priority}
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

4. **Resolve `depends-on: all-developer`**: Replace with the actual TASK IDs of all developer tasks created in this batch

   **Resolve `depends-on: TASK-RESEARCH`**: When the architect has declared a researcher follow-up plus a new architect task that depends on it, replace `TASK-RESEARCH` with the actual TASK ID assigned to the researcher follow-up in this same batch. This enables the research-first flow: researcher runs → new architect task dispatches with findings available.

5. **Add to BOARD.md**: Append a row to the Backlog table

6. **Update requirement progress**: Recalculate the Progress column in the Requirements table (count done tasks / total tasks for that REQ)

7. **Requirement completion check**: If a requirement's progress just reached N/N AND its latest review task is `done` with no pending fix tasks:
   - Update the requirement file's frontmatter `status` to `done`
   - Update the Status column in BOARD.md Requirements table to `done`
   - Append a bullet to `CHANGELOG.md` under the `## [Unreleased]` section (see "CHANGELOG Maintenance" below)

### 4.5 Check for Auto-Test and Auto-Review

After processing follow-ups, check the completion state of developer tasks for each plan:

**Auto-test:** If all developer tasks for a plan are now `done` AND no test-writer task exists for that plan yet:
- Auto-create a test-writer task:
  ```
  - Write unit tests for {feature} | agent: test-writer | priority: high
  ```
  Link it to the same REQ and PLAN. Add to BOARD.md Backlog.

**Auto-review:** If the test-writer task for a plan is `done` AND no review task exists for that plan yet:
- Auto-create a review task with `agent: reviewer`:
  ```
  - Review {feature} implementation | agent: reviewer | priority: high
  ```
  Link it to the same REQ and PLAN. Add to BOARD.md Backlog.

The chain is: **developers complete → test-writer → 4 reviewers in parallel**.

Note: The `agent: reviewer` designation is a trigger — when step 4.2 encounters it, it spawns 4 specialized reviewers in parallel (see Parallel dispatch for review tasks above).

### 4.6 Continue or Pause

Present to the user:
```
TASK-NNN complete: {title}
  {brief summary from Work Log}
  Follow-ups created: {count} new tasks added to backlog

Continue to next task? (yes / no / details / continue all)
```

- **"yes"** → go to step 4.1
- **"no"** → proceed to Step 5
- **"details"** → show full Work Log, then ask again
- **"continue all"** → set auto-continue flag, go to step 4.1 without asking again

If auto-continue is active, skip the prompt and loop directly to step 4.1 — but still show one-line status updates:
```
TASK-NNN done: {title} → {N} follow-ups created
```

### 4.7 CHANGELOG Maintenance

When a requirement transitions to `done` (step 4.4 item 7), append a bullet to the repo-root `CHANGELOG.md` under the `## [Unreleased]` section.

**If `CHANGELOG.md` does not exist at the repo root**, create it with this skeleton before appending:

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

```

**If `CHANGELOG.md` exists but has no `## [Unreleased]` section**, insert one immediately after the preamble (before the first `## [version]` heading, if any).

**Append the bullet** under `## [Unreleased]`:

```
- REQ-NNN: {requirement title}
```

Skip the append if a bullet starting with `- REQ-NNN:` already exists under `## [Unreleased]` (idempotent — avoid duplicates on re-runs).

The `guild:release` skill later renames `## [Unreleased]` to a versioned heading and creates a fresh empty `[Unreleased]` section.

## Step 5: Session Wrap-up

When the work cycle ends (user stops, or backlog empty):

1. Update BOARD.md `last-checkin` to today's date
2. Present session summary:
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
     TASK-007: Implement login endpoint (developer) — high priority
   ```

## Key Rules

1. **Only YOU update BOARD.md** — agents never touch it
2. **Sequential dispatch by default** — only parallelize developer tasks (≥3 for same plan)
3. **Always read task files after agent completion** — don't assume what happened
4. **Respect dependencies** — never dispatch a task with unmet `depends-on`
5. **Cap Done section at 20 entries** — trim oldest when adding new completions
6. **Auto-create review tasks** — after all dev tasks for a plan complete
7. **Review = 4 parallel reviewers** — security, architecture, business-logic, edge-case
8. **Max 2 review rounds** — if any reviewer writes ESCALATE, ask the user
8. **Stale task recovery** — on check-in, detect and handle interrupted tasks
