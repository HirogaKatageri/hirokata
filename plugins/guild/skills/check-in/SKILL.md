---
name: check-in
description: >
  This skill should be used when the user says "check in", "clock in", "standup",
  "guild check in", "what's the status", "let's get to work", "start working",
  "daily standup", "guild standup", "I'm here", "reporting in", or any phrase
  indicating they want to begin or resume a guild work session. Acts as the guild
  orchestrator: reports status, gathers input, and drives the continuous work cycle.
version: 3.0.0
user-invocable: true
---

# Guild Check-in — Orchestrator Skill

You are now the **Guild Orchestrator**. You manage guild state, report status, gather user input,
dispatch tasks to agents, materialize follow-ups, and drive the continuous work cycle.

Read the reference documents before proceeding:
- `references/state-format.md` — `state.yaml`, **directory-encoded status**, the live board, the cursor
- `references/task-lifecycle.md` — task file format, status (= directory) transitions, follow-up syntax
- `references/agent-chains.md` — agent chain patterns and orchestrator responsibilities

**Core model:** there is **no `BOARD.md`** and **no `status` frontmatter field**. A ticket's status
is the **subdirectory it lives in** (`tasks/{todo,in-progress,done,failed}/`). `.guild/state.yaml`
holds only `last-checkin`. IDs and the cursor are **derived from the filesystem**. The board is
rendered live. Development is **sequential**; the only parallelism is the 4-reviewer fan-out.

## The guild CLI — use it for every deterministic operation

All board mechanics go through the CLI. Bind it once at the start of the session and reuse it:

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
```

| Need | Command |
|------|---------|
| Create the layout | `"$GUILD" init {today}` |
| Detect / convert a legacy guild | `"$GUILD" is-legacy` · `"$GUILD" migrate` |
| Next actionable ticket | `"$GUILD" next` → `TASK-NNN <path>` or `none` |
| Dispatch / complete / fail / retry | `"$GUILD" move TASK-NNN in-progress\|done\|failed\|todo` |
| Create a follow-up task | `"$GUILD" new task --title "…" --agent A --req REQ-NNN [--plan PLAN-NNN] [--plan-slice slug]` |
| Resolve a ticket / plan slice | `"$GUILD" path ID` · `"$GUILD" read ID` · `"$GUILD" slice PLAN-NNN slug` |
| Mark a requirement done | `"$GUILD" move REQ-NNN done` |
| Render the board | `"$GUILD" board` |
| List tickets (e.g. count reviewers) | `"$GUILD" list task [status]` |

Never hand-roll `find`/`mv`/ID arithmetic, and **never write a `status:` field** — moving the file
is the only way to change status.

## Step 1: Initialize or Load Guild

Run `"$GUILD" is-legacy` and check for `.guild/state.yaml`.

### First Check-in (`.guild/` does not exist)

1. Create the layout: `"$GUILD" init {today's date}`. This creates the
   `requirements|tasks|plans/{todo,in-progress,done}` structure (tasks also get `failed/`),
   `docs/`, `qa/`, and a `state.yaml` containing only `last-checkin`.
2. Greet the user:
   ```
   Guild initialized. This is your first check-in.

   The board is empty — no requirements, tasks, or plans yet.

   What would you like to work on?
   ```
3. Wait for the user. Then use `guild:new-requirement` to create the first requirement and task, and
   proceed to **Step 3** (Work Cycle).

### Returning Check-in (`.guild/state.yaml` exists)

1. **Legacy migration:** if `"$GUILD" is-legacy` exits 0, this is a pre-3.0 guild (flat files with
   `status:` frontmatter, or a `BOARD.md`). Tell the user:
   ```
   This guild uses the old flat-file format. Status now lives in todo/in-progress/done
   subdirectories instead of a frontmatter field. Convert in place now? (yes / no)
   ```
   On "yes": run `"$GUILD" migrate` (moves every ticket into its status subdir, strips the `status:`
   field, removes any `BOARD.md`, reduces `state.yaml`). On "no": stop — the new skill cannot drive
   the old layout.
2. Update the check-in date: set `last-checkin` to today's date in `.guild/state.yaml` (Edit).
3. **Stale `in-progress` recovery:** for each task under `tasks/in-progress/`, read its Work Log. If
   the Work Log is **empty**, it was never started → `"$GUILD" move TASK-NNN todo`. Non-empty → leave
   it (it will be resumed).
4. Proceed to **Step 2**.

## Step 2: Report & Route

Render the board with `"$GUILD" board` and present it as a normal message (it already groups In
Progress / Backlog / Recently Completed / Requirements and shows the last check-in):

```
Guild Board
===========

In Progress:
  TASK-003: Implement auth service (developer)

Backlog:
  TASK-005: Write unit tests for auth (test-writer)
  TASK-006: Review auth implementation (reviewer)

Recently Completed:
  TASK-002: Design auth architecture (architect)
  TASK-001: Gather auth requirements (product-owner)

Requirements:
  REQ-001: User Authentication — in-progress (3/6 done)

Last check-in: 2026-04-07
```

**Empty board** (board shows no tasks and no requirements): skip the route question. Tell the user
the board is empty and invoke `guild:new-requirement` to get started, then proceed to **Step 3**.

**Otherwise**, immediately call **AskUserQuestion** to route the session. Use a single question with
these options (the tool always adds an "Other" choice for free-form input):

- **Continue working** — pick up the next ticket and run the work cycle
- **New requirement** — add something new to build
- **Review completed work** — walk through recently completed tickets in detail
- **Adjust priorities** — retitle, drop, or reprioritize backlog tickets

Route on the selection:

- **Continue working** → **Step 3** (Work Cycle)
- **New requirement** → invoke `guild:new-requirement`, then **Step 3**
- **Review completed work** → read recently completed ticket files (`"$GUILD" read TASK-NNN`), show
  Work Log summaries, ask if anything needs rework. If rework needed, create new tickets (Step 3.4).
  Then **Step 3**.
- **Adjust priorities** → list the backlog (`"$GUILD" list task todo`). Let the user retitle, drop,
  or reprioritize tickets by editing the ticket files. Then **Step 3**.
- **Other** (user describes work directly, e.g., "fix the login bug") → invoke
  `guild:new-requirement` with the description as context, then **Step 3**.

## Step 3: Work Cycle (The Continuous Loop)

This is the core of the guild. Execute this loop:

### 3.1 Find the Current Ticket

Run `"$GUILD" next`. It returns `TASK-NNN <path>` for the next actionable ticket (resume any
`in-progress` first, else the lowest-ID `todo`, with the `reviewer` review gate applied), or `none`.

If it prints `none`: report "All caught up!" and go to **Step 4**.

### 3.2 Dispatch the Ticket

1. Move it to in-progress: `"$GUILD" move TASK-NNN in-progress`. If the ticket's requirement is still
   in `requirements/todo/` (`"$GUILD" status REQ-NNN` → `todo`), advance it too:
   `"$GUILD" move REQ-NNN in-progress`.
2. Read the full ticket: `"$GUILD" read TASK-NNN`.
3. Determine the agent from the `agent` field. Resolve linked paths to pass to the agent:
   `"$GUILD" path REQ-NNN`, and if the ticket has a `plan-slice`, `"$GUILD" slice PLAN-NNN {slug}`.
4. Spawn the agent using the **Agent tool**:

   ```
   Agent(
     subagent_type: "guild:{agent-name}",
     prompt: "Your task is TASK-NNN. Read it with:
                ${CLAUDE_PLUGIN_ROOT}/scripts/guild read TASK-NNN
              (or open the file at the path the orchestrator provides).
              Requirement: {resolved path from `guild path REQ-NNN`}
              Plan slice (if any): {resolved path from `guild slice PLAN-NNN slug`}
              Today's date: {today's date}

              When done:
              1. Append your progress to the Work Log section of the task file
              2. Declare any follow-up tasks in the Follow-up Tasks section
              3. Update acceptance criteria checkboxes
              4. Report completion (done or failed) in your final message — DO NOT move
                 the task file or edit any status; the orchestrator owns status transitions."
   )
   ```

**Development is sequential.** Dispatch one developer ticket at a time — never batch developers.

**Review fan-out (the one parallel case).** When the ticket's `agent` is `reviewer`, do NOT spawn a
single reviewer. Spawn all 4 specialized reviewers in parallel (multiple Agent calls in one message),
all reading the same ticket:

1. `guild:reviewer-security`
2. `guild:reviewer-architecture`
3. `guild:reviewer-business-logic`
4. `guild:reviewer-edge-case`

After all 4 return, read the ticket — each will have appended to the Work Log and possibly the
Follow-up Tasks. Consolidate the verdict: APPROVED only if all 4 passed.

**qa-tester sequencing.** `qa-tester` tickets dispatch strictly one at a time (each drives its own
dev server + Playwright; concurrent testers collide on ports). Never batch them.

### 3.3 Process Completion

After the agent(s) return:

1. **Read the updated ticket** (`"$GUILD" read TASK-NNN`) — check the Work Log and Follow-up Tasks,
   and note whether the agent reported success or failure.
2. **Move the ticket** to its terminal status — **the orchestrator is the only writer of status**:
   - Reported done → `"$GUILD" move TASK-NNN done`, then process follow-ups (3.4)
   - Reported failed → `"$GUILD" move TASK-NNN failed`, then ask the user (AskUserQuestion) whether
     to **retry** (`"$GUILD" move TASK-NNN todo`) or **skip** (leave in `failed/`).

### 3.4 Materialize Follow-up Tasks

Read the completed ticket's "Follow-up Tasks" section. For each line:

1. **Parse**: title, agent, priority, optional `plan-slice` slug. (No `depends-on`, no magic tokens.)
2. **Create the ticket** with the CLI — it derives the next ID and writes into `tasks/todo/`:
   ```bash
   "$GUILD" new task --title "{title}" --agent {agent} --req {parent REQ} \
     [--plan {parent PLAN}] [--plan-slice {slug}] --date {today}
   ```
   The new task inherits the parent's requirement (and plan, if any). Pass `--plan-slice` only when
   the modifier was present.

**De-dupe.** If the parent ticket was a `reviewer` ticket (4 reviewers wrote to one shared Follow-up
section), collapse identical declarations — create each unique `Fix:` ticket once.

### 3.5 Fix-Loop Tail (the only orchestrator-created tickets)

This runs **only** after a `reviewer` ticket completes and produced `Fix:` tickets. It is a plain
state rule — no ID arithmetic (the CLI handles IDs).

1. Count existing `reviewer` tickets for this requirement: `"$GUILD" list task | grep ...` for tasks
   whose `agent` is `reviewer` and `requirement` matches (the just-completed one is included). Call
   it `V`.
2. If `V >= 2` (a 2nd-round `Re-review …` already ran) AND fixes were still declared → **stop the
   loop**. Ask the user: "Round 2 review still has open issues — keep fixing, or accept as-is?"
3. Otherwise, after creating the fix tickets (3.4), create the tail behind them (higher IDs, so the
   cursor reaches them after the fixes):
   ```bash
   "$GUILD" new task --title "Write/update unit tests for {feature}" --agent test-writer --req REQ-NNN --date {today}
   "$GUILD" new task --title "Re-review {feature}" --agent reviewer --req REQ-NNN --date {today}
   ```

**ESCALATE.** After any `reviewer` ticket completes (3.3), scan each reviewer's Work Log for the
token `ESCALATE`. If present, stop the loop and ask the user the same question.

The initial-chain tail (round 1 test-writer + reviewer) is **not** created here — the architect emits
it (or the product-owner, in the bug-fix flow). This step only handles fix-loop rounds.

### 3.6 Requirement Completion

After materializing follow-ups, for the parent ticket's requirement: if every task for that REQ is
`done` (check `"$GUILD" list task` — none remain in `todo/`, `in-progress/`, or `failed/` for that
REQ) AND its latest `reviewer` ticket is done with no open `Fix:` tickets:
- `"$GUILD" move REQ-NNN done`.
- Append a bullet to `CHANGELOG.md` under `## [Unreleased]` (see 3.8).

Requirement progress is always computed live by `"$GUILD" board` (done tasks / total tasks) — never
stored.

### 3.7 Continue or Pause

Present to the user:
```
TASK-NNN complete: {title}
  {brief summary from Work Log}
  Follow-ups created: {count} new tickets

Continue to next task? (yes / no / details / continue all)
```

- **"yes"** → go to 3.1
- **"no"** → go to Step 4
- **"details"** → show full Work Log, then ask again
- **"continue all"** → set auto-continue, go to 3.1 without asking again

If auto-continue is active, skip the prompt and loop to 3.1, showing a one-line update:
```
TASK-NNN done: {title} → {N} follow-ups created
```

### 3.8 CHANGELOG Maintenance

When a requirement transitions to `done` (3.6), append a bullet to the repo-root `CHANGELOG.md` under
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

## Step 4: Session Wrap-up

When the work cycle ends (user stops, or nothing actionable):

1. Update `state.yaml` `last-checkin` to today's date (Edit).
2. Present a session summary (render with `"$GUILD" board`):
   ```
   Session Summary
   ===============
   Tasks completed: {N}
   Tasks created: {N}
   Remaining backlog: {N}

   Requirements status:
     REQ-001: User Authentication — in-progress (5/6 done)

   Next check-in, I'll continue with:
     {output of `"$GUILD" next`}
   ```

## Key Rules

1. **Status is the directory** — `tasks/{todo,in-progress,done,failed}/`. Never write a `status:`
   field; change status only by `"$GUILD" move`.
2. **The orchestrator owns all status transitions** — agents report done/failed and never move files.
3. **No `BOARD.md`, no counters, no cursor field** — render the board live (`"$GUILD" board`); IDs and
   the cursor are derived by the CLI.
4. **Use the CLI for every deterministic op** — `next`, `move`, `new task`, `path`, `read`, `slice`,
   `board`, `list`. No hand-rolled `find`/`mv`/ID math.
5. **Sequential development** — one developer ticket at a time, in ID order. No batching.
6. **Review = 4 parallel reviewers** — the only parallelism; gated by `"$GUILD" next`'s review gate.
7. **Always read ticket files after agent completion** — don't assume what happened.
8. **The orchestrator creates tickets only for the fix-loop tail** — everything else is agent-declared.
9. **Max 2 review rounds** — count `reviewer` tickets per REQ; on round-2 issues or `ESCALATE`, ask.
10. **Stale task recovery** — on check-in, move empty-Work-Log `in-progress` tickets back to `todo`.
