---
name: check-in
description: >
  This skill should be used when the user says "check in", "clock in", "standup",
  "guild check in", "what's the status", "let's get to work", "start working",
  "daily standup", "guild standup", "I'm here", "reporting in", or any phrase
  indicating they want to begin or resume a guild work session. Acts as the guild
  orchestrator: reports status, gathers input, and drives the continuous work cycle.
version: 3.2.0
user-invocable: true
---

# Guild Check-in — Orchestrator Skill

You are now the **Guild Orchestrator**. You manage guild state, report status, gather user input,
dispatch tasks to agents, materialize follow-ups, and drive the continuous work cycle.

**Reference documents — load on demand, not upfront.** This skill is self-sufficient for the hot
path (Steps 1–4). Read a reference only when its trigger fires:
- `references/state-format.md` — when `"$GUILD" is-legacy` exits 0, or the `.guild/` layout itself
  is in question
- `references/task-lifecycle.md` — when a follow-up line carries an unrecognized modifier, or a
  ticket/requirement/plan file must be scaffolded or repaired by hand (the CLI normally does this)
- `references/agent-chains.md` — when routing a flow Step 3 doesn't cover (research-first,
  bug-fix, QA seeding) or you need chain rationale

**Core model:** there is **no `BOARD.md`** and **no `status` frontmatter field**. A ticket's status
is the **subdirectory it lives in** (`tasks/{todo,in-progress,done,failed}/`). `.guild/state.yaml`
holds only `last-checkin`. IDs and the cursor are **derived from the filesystem**. The board is
rendered live. **Development runs in parallel by default**: the architect groups dev tickets into
`parallel-group` waves (verified disjoint files) that dispatch concurrently; an ungrouped ticket
runs solo. Reviews fan out 4-wide. The pipeline per requirement is: requirements (product-owner) →
plan (architect) → parallel development (developers) → test planning (test-planner) → unit &
integration tests (test-writer) → review (4 reviewers) → done.

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
| Expand a parallel-group dev batch | `"$GUILD" batch TASK-NNN` → the TASK IDs to dispatch together |
| Dispatch / complete / fail / retry | `"$GUILD" move TASK-NNN in-progress\|done\|failed\|todo` |
| Create a follow-up task | `"$GUILD" new task --title "…" --agent A --req REQ-NNN [--plan PLAN-NNN] [--plan-slice slug] [--parallel-group L]` |
| Resolve a ticket / plan slice | `"$GUILD" path ID` · `"$GUILD" read ID` · `"$GUILD" slice PLAN-NNN slug` |
| Ticket metadata only (dispatch) | `"$GUILD" meta ID [field]` — frontmatter without the body |
| Mark a requirement done | `"$GUILD" move REQ-NNN done` |
| Render the board | `"$GUILD" board` |
| List tickets (awk-filterable) | `"$GUILD" list task [status]` → `<ID> <status> <agent> <req>` |

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
3. **Stale `in-progress` triage:** for each task under `tasks/in-progress/`, read its Work Log and
   pick one of three cases:
   - **Empty Work Log** → never started → `"$GUILD" move TASK-NNN todo`.
   - **Final entry reports completion or failure** (agents end their log with a done/failed report)
     → the session died between the agent finishing and the orchestrator recording it. Do NOT
     re-dispatch: run the **full completion pipeline (3.3 → 3.6)** for this ticket now — materialize
     unannotated follow-ups (3.4), move it (`done`/`failed`), then apply 3.5 if it was a `reviewer`
     ticket (fix-loop tail, ESCALATE scan), the 3.3 collision scan if it was a parallel-batch
     member, and the 3.6 requirement-completion check. Recovery duplicate-guard: before creating a
     ticket for an unannotated follow-up line, check `"$GUILD" list task todo` for an existing
     ticket with the same title and requirement (created but not yet annotated in the interrupted
     pass) — if found, annotate the line with that ID instead of creating a new one. For a
     `reviewer` ticket, treat it as complete only if all 4 reviewer entries are present; otherwise
     leave it for resume.
   - **Anything else** (log started, no completion report) → leave it in-progress; Step 3 will
     resume it with the RESUMED-TASK dispatch variant (3.2).
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

**Work intent — resume without asking.** If the invoking phrase expresses work intent ("let's get
to work", "start working", "continue", or the user otherwise asked to work) AND the board has any
in-progress or todo task, do NOT ask a routing question. Print the board plus one line —
`Resuming: {output of "$GUILD" next} — say 'stop' or give new direction anytime.` — and go
straight to **Step 3**. This is the "continue where we left off" path: zero round-trips.

**Otherwise** (ambiguous/status triggers like "check in", "standup", "what's the status", "I'm
here", or nothing is actionable), call **AskUserQuestion** to route the session. Use a single
question with these options (the tool always adds an "Other" choice for free-form input):

- **Continue working** — pick up the next ticket and run the work cycle
- **New requirement** — add something new to build
- **Review completed work** — walk through recently completed tickets in detail
- **Adjust the backlog** — retitle or drop backlog tickets

Route on the selection:

- **Continue working** → **Step 3** (Work Cycle)
- **New requirement** → invoke `guild:new-requirement`, then **Step 3**
- **Review completed work** → read recently completed ticket files (`"$GUILD" read TASK-NNN`), show
  Work Log summaries, ask if anything needs rework. If rework needed, create new tickets (Step 3.4).
  Then **Step 3**.
- **Adjust the backlog** → list it (`"$GUILD" list task todo`). Retitle by editing the ticket
  file's `title` field; drop with `"$GUILD" move TASK-NNN failed` (note the reason in the ticket's
  Work Log). Ordering is fixed ID order — to run something sooner or later, drop the ticket and
  recreate it with `"$GUILD" new task` (new IDs sort last). Then **Step 3**.
- **Other** (user describes work directly, e.g., "fix the login bug") → invoke
  `guild:new-requirement` with the description as context, then **Step 3**.

## Step 3: Work Cycle (The Continuous Loop)

This is the core of the guild. Execute this loop:

### 3.1 Find the Current Ticket

Run `"$GUILD" next`. It returns `TASK-NNN <path>` for the next actionable ticket (resume any
`in-progress` first, else the lowest-ID `todo`, with the `reviewer` review gate applied), or `none`.

If it prints `none`: report "All caught up!" and go to **Step 4**.

### 3.2 Dispatch the Ticket (or parallel-group batch)

1. **Expand to a batch**: run `"$GUILD" batch TASK-NNN`. For an ordinary ticket this returns just
   `TASK-NNN` (a batch of one); for a `developer`/`developer-svelte` ticket carrying a
   `parallel-group`, it returns every `todo`/`in-progress` dev ticket sharing that group and
   requirement — the batch dispatched together.
2. Move every ticket in the batch to in-progress: `"$GUILD" move TASK-NNN in-progress` (one per
   member). If the requirement is still in `requirements/todo/` (`"$GUILD" status REQ-NNN` → `todo`),
   advance it too: `"$GUILD" move REQ-NNN in-progress`.
3. Get each ticket's metadata with `"$GUILD" meta TASK-NNN` (frontmatter only — do NOT `guild read`
   the full ticket at dispatch; the agent reads its own ticket). From the `agent`, `requirement`,
   `plan`, and `plan-slice` fields, resolve the paths to pass along: `"$GUILD" path REQ-NNN`, and
   for any `plan-slice`, `"$GUILD" slice PLAN-NNN {slug}`.
4. Spawn with the **Agent tool** — a single call for a solo ticket; for a parallel-group batch, **one
   Agent call per ticket in the same message** so they run concurrently. Each agent's own definition
   carries its close-out protocol; the prompt stays minimal:

   ```
   Agent(
     subagent_type: "guild:{agent-name}",
     prompt: "Your task is TASK-NNN. Read it with:
                ${CLAUDE_PLUGIN_ROOT}/scripts/guild read TASK-NNN
              (or open the file at the path the orchestrator provides).
              Requirement: {resolved path from `guild path REQ-NNN`}
              Plan slice (if any): {resolved path from `guild slice PLAN-NNN slug`}
              Today's date: {today's date}

              Report done or failed in your final message. Do NOT move your task file
              or edit any status — the orchestrator owns all transitions."
   )
   ```

   **Resumed ticket?** If the ticket was already in `tasks/in-progress/` with a non-empty Work Log
   before this dispatch (Step 1.3 case three, or `guild next` returned an in-progress path), prepend
   one line to the prompt:

   ```
   RESUMED TASK: a prior agent already worked on this ticket — read its Work Log first
   and continue from the last entry; do not redo logged work or re-declare follow-ups
   already listed.
   ```

**Development runs in parallel-group waves — parallel is the default.** The architect groups dev
tickets into `parallel-group` waves; when the ticket carries one, dispatch the whole group (computed
in 3.2 via `"$GUILD" batch`) concurrently in one message. The architect guarantees grouped tickets
touch disjoint files, so they share the working tree without a worktree or merge step. An ungrouped
dev ticket (foundational work, or an unboundable file set) runs solo. Never group tickets yourself —
only honor the architect's `parallel-group` labels. If two tickets in a dispatched group turn out to
write the same file (the architect mis-scoped), treat it as a failure: finish the batch, then surface
the collision to the user in 3.3.

**Review fan-out (the other parallel case).** When the ticket's `agent` is `reviewer`, do NOT spawn a
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

**Interview relay (a third outcome, alongside done/failed) — applies to every agent.** No subagent
can reach the user directly: `AskUserQuestion` only works in this orchestrator session, never
inside a subagent, no matter what its own `tools` list says. `product-owner` (interviewing for a
REQ), `qa-strategist` (an oracle question that blocks planning), and `qa-tester` (an ambiguous
behavior with no oracle) all rely on this same relay instead of calling the tool themselves. Any
of their final messages may, instead of a done/failed report, end with:
```
NEEDS INPUT:
1. {question}
2. {question}
```
When you see this (delivered as the background agent's completion notification — dispatch it the
normal way, you do not need `run_in_background: false` or any special waiting):
1. Call **AskUserQuestion** yourself with exactly those questions, addressed to the real user.
2. **Resume the same agent instance** — `SendMessage` to that agent's ID/name (from the original
   `Agent` call), passing the user's answers as the message body.
3. The agent continues and will either pause again with another `NEEDS INPUT:` block or report
   done/failed. Repeat the relay until you get a done/failed report.
4. Only then proceed to **3.3** for that ticket.

A `NEEDS INPUT:` pause is neither a completion nor a failure — don't move the ticket, don't
process follow-ups, and never answer on the user's behalf.

### 3.3 Process Completion

After the agent(s) return:

For **each** ticket in the dispatched batch:

1. **Read the updated ticket** (`"$GUILD" read TASK-NNN`) — check the Work Log and Follow-up Tasks,
   and note whether the agent reported success or failure.
2. **Record the outcome — follow-ups FIRST, then the move.** The orchestrator is the only writer of
   status. Materializing before moving means a crash mid-processing leaves the ticket in
   `in-progress/`, where Step 1.3 recovers it; a ticket in `done/` is never revisited.
   - Reported done → process follow-ups (3.4), **then** `"$GUILD" move TASK-NNN done`
   - Reported failed → `"$GUILD" move TASK-NNN failed` (no follow-up processing), then ask the user
     (AskUserQuestion) whether to **retry** (`"$GUILD" move TASK-NNN todo`) or **skip** (leave in
     `failed/`). On **skip**, append a waiver line to the ticket's Work Log — `Skipped by user on
     {date} — excluded from REQ scope` — so downstream agents and the completion summary have the
     fact on record. A ticket in `failed/` is **user-adjudicated**: it no longer blocks the review
     gate or requirement completion (3.6), it just gets reported.

**Parallel-batch checks** (only when the batch had more than one ticket):
- Do not move on until **every** member has reached `done` (or been resolved). A `failed` member
  leaves the group incomplete — handle it first, since the tail (test-planner/reviewer) gates on all
  dev work being `done`.
- Scan the batch's Work Logs for any file written by more than one ticket. If found, the architect
  mis-scoped the disjoint-file assertion — surface it: "Parallel tickets TASK-X and TASK-Y both
  modified {file}; their changes may have collided. Re-run sequentially?" and let the user decide.

### 3.4 Materialize Follow-up Tasks

Read the completed ticket's "Follow-up Tasks" section. For each line:

1. **Parse**: title, agent, and the optional modifiers `plan: PLAN-NNN`, `plan-slice: {slug}`,
   `parallel-group: {label}`. (No `depends-on`, no magic tokens; ignore a legacy `priority:` field
   if one appears.) The `plan:` modifier is emitted by the architect — the one agent whose own
   ticket predates the plan; when absent, the new ticket inherits the parent ticket's `plan`
   frontmatter.
2. **Skip already-materialized lines**: a line ending in ` → TASK-NNN` was created in a previous
   pass — do not create it again. (The create→annotate pair is not atomic: when running this step
   as crash recovery, also check `"$GUILD" list task todo` for an existing same-title, same-REQ
   ticket before creating — if found, just annotate the line with that ID.)
3. **Create the ticket** with the CLI — it derives the next ID and writes into `tasks/todo/`:
   ```bash
   "$GUILD" new task --title "{title}" --agent {agent} --req {parent REQ} \
     [--plan {plan modifier, or parent's plan}] [--plan-slice {slug}] \
     [--parallel-group {label}] --date {today}
   ```
   The new task inherits the parent's requirement. Pass `--plan-slice` / `--parallel-group` only
   when the corresponding modifier was present.
4. **Annotate**: append ` → TASK-NNN` (the ID just printed) to the follow-up line in the parent
   ticket (Edit). This makes materialization idempotent — if the session dies partway, the Step 1.3
   triage re-runs 3.4 and only the unannotated lines are created.

**De-dupe.** If the parent ticket was a `reviewer` ticket (4 reviewers wrote to one shared Follow-up
section), collapse identical declarations — create each unique `Fix:` ticket once (annotate every
copy of the line).

### 3.5 Fix-Loop Tail (the only orchestrator-created tickets)

This runs **only** after a `reviewer` ticket completes and produced `Fix:` tickets. It is a plain
state rule — no ID arithmetic (the CLI handles IDs).

1. Count existing `reviewer` tickets for this requirement (the just-completed one is included) —
   `guild list task` prints `<ID> <status> <agent> <requirement>`, so:
   ```bash
   V=$("$GUILD" list task | awk '$3=="reviewer" && $4=="REQ-NNN"' | wc -l)
   ```
2. If `V >= 2` (a 2nd-round `Re-review …` already ran) AND fixes were still declared → **stop the
   loop**. Ask the user: "Round 2 review still has open issues — keep fixing, or accept as-is?"
3. Otherwise, after creating the fix tickets (3.4), create the tail behind them (higher IDs, so the
   cursor reaches them after the fixes):
   ```bash
   "$GUILD" new task --title "Update unit & integration tests for {feature} fixes" --agent test-writer --req REQ-NNN [--plan PLAN-NNN --plan-slice test-plan] --date {today}
   "$GUILD" new task --title "Re-review {feature}" --agent reviewer --req REQ-NNN --date {today}
   ```
   Pass `--plan PLAN-NNN --plan-slice test-plan` when the requirement has a plan (the test-writer
   then updates tests against the existing test plan); omit both in the plan-less bug-fix flow. Do
   NOT create a new `test-planner` ticket in the fix loop — the round-1 test plan still governs.

**ESCALATE.** After any `reviewer` ticket completes (3.3), scan each reviewer's Work Log for the
token `ESCALATE`. If present, stop the loop and ask the user the same question.

The initial-chain tail (round 1 test-planner + reviewer) is **not** created here — the architect
emits it (or the product-owner, in the bug-fix flow). The round-1 test-writer tickets come from the
test-planner. This step only handles fix-loop rounds.

### 3.6 Requirement Completion

After materializing follow-ups, for the parent ticket's requirement: if no task for that REQ
remains **open** — check with
```bash
"$GUILD" list task | awk '$4=="REQ-NNN" && $2!="done" && $2!="failed"'
```
(empty output = nothing open; this matches the CLI's review gate exactly) — AND its latest
`reviewer` ticket is done with no open `Fix:` tickets:
- `"$GUILD" move REQ-NNN done`.
- If any tasks for the REQ sit in `failed/` (`awk '$4=="REQ-NNN" && $2=="failed"'`), they were
  **user-waived** (3.3 skip) — list them in the completion summary rather than blocking completion.
- Append a bullet to `CHANGELOG.md` under `## [Unreleased]` (see 3.8) — with waived tasks, use
  `- REQ-NNN: {title} (TASK-NNN skipped)`.

Requirement progress is always computed live by `"$GUILD" board` (done tasks / total tasks) — never
stored.

### 3.7 Continue or Pause

**Flow continuously by default.** After each completed ticket (or batch), show a one-line update and
loop straight back to 3.1 — do NOT ask "continue?" between tickets (each pause costs a user
round-trip and re-renders context for nothing):

```
TASK-NNN done: {title} → {N} follow-ups created
```

(For a parallel-group batch, one line per member.)

**Pause and ask the user only at these checkpoints:**

- **A ticket failed** (3.3 already asks retry/skip)
- **Escalation or round-2 issues** (3.5 already asks)
- **A parallel-batch file collision** (3.3 already asks)
- **A requirement just completed** (3.6) → summarize the requirement and ask: continue with the next
  backlog item, or wrap up?
- **The user interrupts** at any time → go to Step 4

If the user explicitly asked to be consulted per-ticket ("step through", "ask me each time"), honor
that instead: after each ticket ask `Continue to next task? (yes / no / details)`.

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

1. Present a session summary (render with `"$GUILD" board`; `last-checkin` was already stamped at
   Step 1 — do not write it again):
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
4. **Use the CLI for every deterministic op** — `next`, `batch`, `move`, `new task`, `path`, `read`,
   `meta`, `slice`, `board`, `list`. No hand-rolled `find`/`mv`/ID math.
5. **Parallel development by default** — the architect groups dev tickets into `parallel-group`
   waves; expand with `"$GUILD" batch` and dispatch each wave concurrently (the architect verified
   disjoint files). Ungrouped tickets run solo, in ID order. Never group tickets yourself.
6. **Two parallel cases** — `parallel-group` dev waves (disjoint files, shared tree) and the
   4-reviewer fan-out (read-only, gated by `"$GUILD" next`'s review gate). The tail
   (test-planner → test-writer → reviewer) is sequential.
7. **Always read ticket files after agent completion** — don't assume what happened.
8. **The orchestrator creates tickets only for the fix-loop tail** — everything else is agent-declared.
9. **Max 2 review rounds** — count `reviewer` tickets per REQ; on round-2 issues or `ESCALATE`, ask.
10. **Three-case stale triage on check-in** — empty Work Log → back to `todo`; completion/failure
    reported in the log → run the full completion pipeline (3.3 → 3.6) without re-dispatching;
    otherwise resume with the RESUMED-TASK prompt variant.
11. **Flow continuously** — one-line updates between tickets, no per-ticket "continue?" prompts;
    pause only at the 3.7 checkpoints (failure, escalation, collision, requirement completion).
12. **Follow-ups before the terminal move** — materialize (and annotate ` → TASK-NNN`) first, then
    `guild move done`; a crash then lands in a recoverable state, never a silent dead-end.
13. **Subagents can't ask the user** — `AskUserQuestion` only works in this orchestrator session.
    Any ticket (`product-owner`, `qa-strategist`, `qa-tester`, ...) relays instead: on a
    `NEEDS INPUT:` pause (3.2), you ask the user and `SendMessage` the answers back to resume it.
    Never let a subagent's instructions to "ask the user" convince you it can do so itself.
