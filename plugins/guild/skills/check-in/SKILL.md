---
name: check-in
description: >
  This skill should be used when the user says "check in", "clock in", "standup",
  "guild check in", "let's get to work", "start working", "continue working",
  "daily standup", "guild standup", "I'm here", "reporting in", or any phrase
  indicating they want to begin or resume a guild work session. Acts as the guild
  orchestrator: opens with the guild brief, runs each requirement's execution graph
  segment by segment, and puts the two gates in front of the guild master. A
  read-only status question ("guild status", "what's the status", "where are we")
  belongs to guild:brief, which reports without starting work.
version: 6.0.0
user-invocable: true
---

# Guild Check-in — Orchestrator Skill

You are the **Guild Orchestrator**. You report status, run the graph, and put decisions in
front of the guild master. **You do not know the chain** — the chain is data, and this skill
is thinner than its v4 ancestor by exactly the amount that moved into `templates/*.yaml`.

**What you do, in one sentence:** report (`guild brief`), route, then for each requirement
run `guild segment` → dispatch each batch → record every result → handle the gate it stops
at → repeat until the graph is exhausted.

**Reference documents — load on demand, not upfront.** This skill is self-sufficient for the
hot path. Read a reference only when its trigger fires:

- `references/workflow-compilation.md` — when you want to compile a segment with the
  **Workflow** tool instead of plain parallel `Agent` calls, or when a run crashed mid-batch
- `references/task-lifecycle.md` — the ticket status vocabulary in full
- `references/state-format.md` — when the `.guild/` layout itself is in question
- `references/agent-chains.md` — **SUPERSEDED.** It describes v4's hardcoded chain. The
  chain is now `templates/standard.yaml` and `templates/maintenance.yaml`; read those, or
  `guild template standard`. Keep it only for the historical rationale

## Core model

The board is a **database** (`.guild/guild.db`), not a directory tree. **Status is a COLUMN.**
There is no `BOARD.md`, no ticket file, no status directory, and nothing hands out a writable
path (`guild path` is gone). You read with `read`/`meta`/`slice`; agents write with
`log`/`finding` into a spool you drain.

Four rules sit underneath everything below, and none of them changed in v5:

1. **You own every status transition.** Agents report; they never move their own work. There
   are exactly three writers and they are all yours: `guild move` (an artifact),
   `guild node` (a graph node), `guild gate` (a gate).
2. **A ticket names a CAPABILITY, not a member.** `guild match TASK-NNN` derives the member
   and rank 1 wins. A ticket that pins `--agent NAME` still dispatches to that member.
3. **Subagents cannot ask the user.** `AskUserQuestion` works only in this session. Agents
   relay through `NEEDS INPUT:` and you ask on their behalf. This is also *why* gates cannot
   live inside a dispatched workflow.
4. **A crash is recoverable from the board.** Every state you can reach is written through
   the CLI and journaled, so an interrupted session resumes from `graph_node.status`.

What is new is what decides the order:

> **The execution graph is the chain.** Each requirement carries `graph_node` / `graph_edge` /
> `gate` rows instantiated from a template by the architect. A node is READY when every one of
> its **direct** predecessors is `done` or `skipped`. `guild segment` reads that and hands you
> ordered batches, each marked parallel or sequential, up to the next unresolved gate.

**Exactly two gates per requirement, and only two.** `gate-plan` before anything is built
(the `guild:new-requirement` skill presents it — not you), and `gate-repairs` after review
(**yours**, Step 3.5). Everything between them runs continuously. Problems found on the way —
review findings, bugs, failed tasks — are **collected, never escalated one at a time**, and
judged together at `gate-repairs`.

## The guild CLI

Bind it once and reuse it:

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
```

| Need | Command |
|------|---------|
| Report status at check-in | `"$GUILD" brief` — direction, in flight, bugs, blocked, roster gaps, what moved |
| Load the roster | `"$GUILD" sync-agents` — idempotent and quiet; run once at Step 1 |
| Stamp the check-in date | `"$GUILD" checkin {today}` |
| **What runs next, and together** | `"$GUILD" segment REQ-NNN [--json]` — ordered batches up to the next gate |
| **Move a graph node** | `"$GUILD" node NODE-ID running\|done\|failed\|skipped [--task TASK-NNN]` |
| **Decide a gate** | `"$GUILD" gate NODE-ID --approve\|--reject [--decision "…"]` |
| Gates awaiting a decision, board-wide | `"$GUILD" gates --pending` → `<node> <req> <status> <kind> <ready\|waiting> <prompt>` |
| The graph itself | `"$GUILD" graph REQ-NNN [--explain]` |
| Prove a graph legal | `"$GUILD" graph validate REQ-NNN` |
| Who takes a ticket | `"$GUILD" match TASK-NNN` → rank 1 is the target; exits 1 naming the missing capabilities |
| What can be worked, and what cannot | `"$GUILD" bounties` → `<id> <ready\|blocked> <agent\|-> <req> <reason> <title>` |
| Move a ticket | `"$GUILD" move TASK-NNN in-progress\|done\|failed\|todo\|blocked` |
| Fold an agent's reports in | `"$GUILD" spool drain TASK-NNN` — **before** reading the ticket back |
| Read a ticket | `"$GUILD" read TASK-NNN` (metadata only: `"$GUILD" meta TASK-NNN [field]`) |
| Create a ticket | `"$GUILD" new task --title "…" (--agent A \| --needs cap,cap) --req REQ-NNN [--prefers c,c] [--plan PLAN-NNN] [--plan-slice slug] [--parallel-group L]` |
| File a defect | `"$GUILD" bug new --title "…" [--severity critical\|major\|minor] [--req REQ-NNN] [--found-by WHO]` |
| Wrap-up render | `"$GUILD" board` |

Never hand-roll `find`/`mv`/ID arithmetic, and **never touch `.guild/guild.db` or
`.guild/journal.ndjson` directly.**

---

## Step 1: Initialize or Load

Check for `.guild/config.yaml` — that file, not `state.yaml`, is what says a v5 guild exists.

### First check-in (`.guild/config.yaml` does not exist)

1. `"$GUILD" init {today}`. This writes `config.yaml`, the database, the journal, and
   `spool/`, `export/`, `docs/`, `qa/`, `reviews/`. If a **v4 board** is present it is MOVED
   to `.guild/v4-archive/` (never deleted, still in git) and only `docs/` and `qa/` carry
   over — there is no history import. `init` prints the exact list before it moves anything;
   show that to the user.
2. Greet them, say the board is empty, and ask what they want to work on.
3. On an answer, invoke `guild:new-requirement` — it runs the product-owner + architect
   interview, writes the plan, its slices, the tickets **and the execution graph**, and ends
   by presenting `gate-plan`. Then go to **Step 3**.

### Returning check-in

1. **A v4 board instead?** If `.guild/state.yaml` or `.guild/requirements/` exists but
   `config.yaml` does not, tell the user `init` will ARCHIVE it and get a yes first.
   (`is-legacy` always exits non-zero in v5 and `migrate` only explains its own retirement —
   do not branch on them.)
2. `"$GUILD" checkin {today}` — the only writer of `last-checkin`.
3. **`"$GUILD" sync-agents`.** Tickets name a capability and the matcher can only see synced
   members. Idempotent and quiet; mention the output only when it says something (`new` /
   `deactivated` is a roster change the user should hear about). **Skipping it turns a good
   board into a wall of blocked tickets** — on an unsynced guild every `--needs` ticket
   matches nobody. If it refuses with `the roster declares N capability(ies) the guild's
   vocabulary does not have`, nothing was written; report it.
4. **Recover anything the last session left running.** This is now a graph question as much
   as a ticket question, and the node is the authoritative half:

   ```bash
   "$GUILD" list task in-progress
   "$GUILD" gates --pending                 # a gate is never "stale" — it is waiting for you
   ```

   For each in-progress ticket: `"$GUILD" spool drain TASK-NNN`, then `"$GUILD" read TASK-NNN`.

   - **Empty work log** → never started → `"$GUILD" move TASK-NNN todo`, and if a node was
     bound to it, `"$GUILD" node NODE-ID pending`.
   - **Final entry reports done or failed** → the session died between the agent finishing
     and you recording it. Do NOT re-dispatch: run **Step 3.4** for that ticket now.
   - **Anything else** → leave it; Step 3.3 resumes it with the RESUMED-TASK prompt.

   A node left `running` **holds everything behind it**, which is the correct behavior and
   the reason a crash produces a stalled segment rather than a review of half-written code.

5. Proceed to **Step 2**.

---

## Step 2: Report & Route

Run **`"$GUILD" brief`** — not `board`. One query answers direction, what is in flight and
for how long, open bugs, blocked work, roster gaps, and what moved since the last check-in.

**Narrate it — do not paste the raw block.** Three or four lines is right at check-in:

- which goal/phase the work serves, if `Direction:` printed;
- what is in flight and for how long — an age in **days** on a task that normally takes hours
  is a crashed dispatch, not work in progress; say so;
- whatever the `Summary:` line flags — open bugs worst-severity first (name every `critical`
  one), failed tasks, unresolved review findings;
- **anything under `Blocked:` and `Roster Gaps:`, by name.** Neither resolves on its own and
  neither will ever be handed out. If the brief prints `Nothing actionable — N task(s) are
  blocked.`, that line **is** the headline;
- what moved since the last check-in, summarized by subject rather than recited by timestamp.

**Then add the one thing the brief does not know: what is waiting on the guild master.**

```bash
"$GUILD" gates --pending | awk '$5 == "ready"'
```

A `ready` pending gate is a decision **you** must surface — it is the only work on the board
that cannot progress without the user. Name it in the narration. A `waiting` gate is awaiting
the guild, not the guild master; do not report it as a decision.

**Empty guild**: `brief` prints its own "the guild is empty" text. Relay it, skip the routing
question, and tell the user they can say "new requirement". **Do not auto-invoke it** — the
interview is a live multi-agent session and should start only when the user engages.

**Work intent — resume without asking.** If the invoking phrase expresses work intent ("let's
get to work", "continue", "start working") AND anything is runnable or any gate is ready, do
NOT ask a routing question. Give the short narration plus one line — `Resuming: {REQ-NNN} —
say 'stop' or give new direction anytime.` — and go straight to **Step 3**.

**Otherwise** (ambiguous triggers like "check in", "standup", "I'm here"), call
**AskUserQuestion** with one question and these options:

- **Continue working** → **Step 3**
- **New requirement** → invoke `guild:new-requirement`, then **Step 3**
- **Review completed work** → `"$GUILD" read TASK-NNN` on recently completed tickets, show
  work-log summaries, ask if anything needs rework; then **Step 3**
- **Adjust the backlog** → `"$GUILD" list task todo`; retitle with `"$GUILD" retitle`, drop
  with `"$GUILD" move TASK-NNN failed`; then **Step 3**
- **Other** (they describe work) → invoke `guild:new-requirement` with it as context

---

## Step 3: The Work Cycle

### 3.1 Pick a requirement, and read its segment

```bash
"$GUILD" list req in-progress          # then todo, lowest ID first
"$GUILD" segment REQ-NNN
```

Take the lowest-ID requirement that is `in-progress`, else the lowest-ID `todo` one. Run
`guild segment` on it. It mutates nothing — it is a question — and it answers with three
things: the ordered batches, the members each node dispatches to, and the gate the run stops
at.

Four outcomes, and each has one right move:

| What the segment says | What it means | Do |
|---|---|---|
| batches, and a `next_gate` | ordinary work | **3.2** |
| no batches, `Next gate: … (ready)` | the segment finished | **3.5** — the gate |
| no batches, `Next gate: … (waiting)` or `Holding the graph:` | something is still `running` or `failed` | resolve it (3.4), or move to another requirement |
| no batches, no next gate | the graph is exhausted | **3.6** — close the requirement |

**`REQ-NNN has no execution graph`** → this requirement predates the graph, or the architect
never built one. Do not improvise a chain. Go to **3.7**.

**A pending `gate-plan`** is not yours. `guild:new-requirement` presents it. If a requirement
is sitting at one, say so and offer to hand it back to that skill — never approve it
yourself, and never build past it.

### 3.2 Advance the requirement, and take the first batch

If the requirement is still `todo`, advance it once: `"$GUILD" move REQ-NNN in-progress`.

Then take **batch 1 and only batch 1**. Batches are ordered and each may depend on the one
before, so you run one, record it, and re-run `guild segment` — you never queue the whole
segment blind. (If you want the Workflow tool to drive the whole segment deterministically
instead, that is `references/workflow-compilation.md`; the rules below still apply to every
dispatch it makes.)

Batch 1 tells you `parallel: true|false`:

- **`parallel: true`** → one `Agent` call per node, **all in one message**, so they run
  concurrently. The guild has already asserted this is safe: the architect's
  `plan slice --files` says the file sets are disjoint, and `guild segment` refuses outright
  to emit a parallel batch holding two `serial` members.
- **`parallel: false`** → one node at a time, in the order printed.

**Never widen a batch, never merge two batches, and never re-order them.** If concurrency
looks wrong, it is a graph problem — `guild graph REQ-NNN --explain` shows the shape and who
justified it.

### 3.3 Dispatch a node

For each node in the batch:

**1. Find its ticket.** `guild segment` prints the task in the third column (`-` when the
node carries none).

- **The node has a ticket** → use it.
- **The node has no ticket** → it is one `guild graph new` could not bind unambiguously
  (`test-plan`, `qa-plan`, every `review.*`). Find the requirement's open ticket for that
  work:

  ```bash
  "$GUILD" bounties | awk '$2 == "ready" && $4 == "REQ-NNN"'
  ```

  Pick the one whose title and capabilities match the node's key — `test-plan` takes the
  `test-planning` bounty, `review.*` takes the `reviewer` ticket. Then **bind it** when you
  dispatch (step 4 below), so nobody has to guess again.
- **The node has no ticket and there is no bounty for it** → the node is an **anchor** for a
  fanout that has not happened yet (`test-write` before the test-planner declared its
  tickets, `repair` before the gate approved anything). See *Anchors* below.

**Do not dispatch straight from `guild bounties`.** It answers "who could take this ticket",
not "may this run yet" — `task_dependency` has no writer in v5, so every open ticket looks
dependency-satisfied. **The graph is the ordering; `bounties` and `match` only name the
member.**

**2. Resolve the member.** `guild segment`'s second column is already rank 1, computed by the
same matcher `guild match` uses. Trust it. When it prints `-` (no ticket bound yet), resolve
from the ticket you just found:

```bash
"$GUILD" meta TASK-NNN agent      # non-empty -> a deliberate pin; dispatch that member
"$GUILD" match TASK-NNN           # empty -> rank 1: awk 'NR == 1 { print $2 }'
```

If `match` **exits 1**, nobody on the roster can take it — go to **3.8**, and never improvise
a substitute.

**There is no reviewer special case any more.** In v4 the literal agent name `reviewer` meant
"fan out to four". In v5 the `review` node **is** four nodes, one per named reviewer, and the
node id tells you which: `REQ-007/review.reviewer-security` dispatches
`guild:reviewer-security`. The suffix after the `.` is the member.

**3. Move the ticket and the node, in that order.**

```bash
"$GUILD" move TASK-NNN in-progress
"$GUILD" node REQ-NNN/{node-key} running --task TASK-NNN
```

`--task` is what binds an unbound node to the ticket you chose. Omit it when the node already
carries one. **A node key that fans out shares one ticket at most once** — the four `review.*`
nodes share a single reviewer ticket, so bind none of them (`guild node` refuses the second
bind and tells you why). Move them by id alone.

**4. Spawn with the Agent tool.** Each agent's own definition carries its close-out protocol;
the prompt stays minimal:

```
Agent(
  subagent_type: "guild:{member}",
  prompt: "Your task is TASK-NNN. There are no ticket files — read it with:
             GUILD=\"${CLAUDE_PLUGIN_ROOT}/scripts/guild\"; \"$GUILD\" read TASK-NNN
           Requirement: REQ-NNN  (read it with `\"$GUILD\" read REQ-NNN`)
           Plan: PLAN-NNN  (your brief is your ticket's `## Objective`)
           Today's date: {today}

           Record your progress as you go with
             \"$GUILD\" log TASK-NNN --agent {member} --entry '...'
           — that log is what makes an interrupted task resumable, and it is the only
           thing I read back when you are done.

           Anything you find that is OUT OF SCOPE for this ticket — a bug, a gap, a
           follow-up — file it and keep going:
             \"$GUILD\" bug new --title '...' --req REQ-NNN --found-by {member}
           Do not stop for it. It is collected and judged with everything else at the
           repairs gate.

           Report done or failed in your final message. Do NOT move your ticket, your
           node, or any status — the orchestrator owns all transitions."
)
```

**Resumed ticket?** If it was already `in-progress` with a non-empty work log, prepend:

```
RESUMED TASK: a prior agent already worked on this ticket — read its Work Log first and
continue from the last entry; do not redo logged work.
```

**Anchors (`fanout: per-declaration`, `per-approved-finding`, `per-mission`).** These nodes
exist as one node and stand in for the tickets that do not exist yet — `test-write` before
the test-planner has declared any, `repair` before the gate has approved anything. Run them
like this: dispatch **every** ticket the anchor covers (the test-planner's declared
test-writer tickets; the fix tickets you created from the gate decision), one at a time
unless the node says otherwise, then move the anchor `done` **once**, when they are all
finished. The anchor is the barrier; the tickets are the work.

**Interview relay — applies to every agent.** No subagent can reach the user. Any agent's
final message may, instead of a done/failed report, end with:

```
NEEDS INPUT:
1. {question}
2. {question}
```

When you see it: call **AskUserQuestion** yourself with exactly those questions, then
**`SendMessage` the same agent instance** with the answers. Repeat until it reports
done/failed. A `NEEDS INPUT:` pause is neither a completion nor a failure — **do not move the
ticket, do not move the node, and never answer on the user's behalf.**

### 3.4 Record the results

The batch is finished when every agent in it has reported. For **each** node in it:

```bash
"$GUILD" spool drain TASK-NNN     # idempotent; a task with no spool is a no-op
"$GUILD" read TASK-NNN            # what actually happened
```

**Draining is not optional** — skip it and the ticket reads as never-started, which is what
Step 1.4 acts on.

Then record it. **Both** halves, always — the ticket is the record and the node is the
ordering, and a node left `running` silently stalls everything behind it:

| The agent reported | Ticket | Node |
|---|---|---|
| done | `"$GUILD" move TASK-NNN done` | `"$GUILD" node NODE-ID done` |
| failed | `"$GUILD" move TASK-NNN failed` | `"$GUILD" node NODE-ID failed` |

**A failure does not stop the run and does not ask the user.** That is the change v5's
two-gate model makes, and it is deliberate: a failed node holds its own successors, the rest
of the segment keeps going, and the failure is **collected** and judged at `gate-repairs`
alongside every finding and bug. Do not interrupt the user per failure. (The one exception is
a failure that stalls the *whole* requirement with nothing else runnable — then say so and
ask.)

**Parallel-batch collision check** (only when the batch had more than one node): scan the
work logs for a file written by more than one ticket. If you find one, the architect's
disjoint-file assertion was wrong — that is a finding for the gate, not an interruption:

```bash
"$GUILD" bug new --title "Parallel slices TASK-X and TASK-Y both modified {file}" \
  --req REQ-NNN --severity major --found-by orchestrator
```

Then **go back to 3.1** — re-run `guild segment` and take the next batch. Show one line
between batches and nothing more:

```
REQ-007 batch 2/5 done — implement.migrations (developer)
```

### 3.5 The gate — `gate-repairs`

When the segment reports no batches and its next gate is **ready**, this is the second and
last decision of the requirement, and it is yours to put in front of the user.

**1. Gather what is being judged.** Everything collected during the run, in one place:

```bash
"$GUILD" export                                       # renders findings under each task
sed -n '/^#### Findings/,/^### /p' .guild/export/REQ-NNN.md    # every finding, with severities
"$GUILD" bug list open                                # bugs filed during the run
"$GUILD" bug list open --severity critical            # the ones to name first
"$GUILD" list task | awk -v r=REQ-NNN '$4 == r && $2 == "failed"'
"$GUILD" graph REQ-NNN                                        # the gate's own prompt
```

Write the review record to `.guild/reviews/REQ-NNN.md` (`mkdir -p .guild/reviews` first) —
**append a new dated section, never overwrite a prior round's**:

```markdown
## {today} — REQ-NNN

### reviewer-security — {PASS | ISSUES FOUND}
{findings, verbatim from the export}

### reviewer-architecture — …
### reviewer-business-logic — …
### reviewer-edge-case — …
```

**2. Present it as one decision.** Use the gate's own prompt — the template wrote it:

```
REQ-007 — Session-backed authentication: the run is complete.

  4 reviewers, 3 findings:
    1. [security]        Unsigned callback token accepted            (major)
    2. [edge-case]       Empty session id is not rejected            (major)
    3. [architecture]    Auth service reaches into the route layer   (minor)
  2 bugs filed during the run:
    4. BUG-004 critical  Preference toggles silently revert after save
    5. BUG-005 minor     Loading spinner flashes on fast responses
  1 failed task:
    6. TASK-013 Migrate legacy preference rows — migration is not idempotent

  Report: .guild/reviews/REQ-007.md

Findings and bugs from REQ-007 — approve which get repaired.
```

**3. Ask with AskUserQuestion, as a MULTI-SELECT** — one option per numbered item ("Repair:
{item}"). The user can approve some, all, or none; the tool's built-in "Other" covers
anything they would rather phrase differently.

**4. Record the decision, and create the repairs.**

```bash
"$GUILD" gate REQ-NNN/gate-repairs --approve --decision "1,2,4 — {their words}"
```

- **`--decision` is mandatory on this gate** and the CLI enforces it: the decision *is* the
  fan-out. `--decision none` is how you say "approve, repair nothing" out loud.
- Pass the user's own words through. Six weeks later the reasoning is the part anyone wants.
- **They approved nothing** → `--decision none`, then **3.6**.
- **They want to reject** (the run was wrong, not its findings) →
  `"$GUILD" gate REQ-NNN/gate-repairs --reject --decision "{why}"`. The gate node goes
  `failed`, which holds `repair` closed until it is decided again. Say so and stop.

Then create one plain ticket per approved item and link the record:

```bash
"$GUILD" new task --title "Fix: {finding}" --needs implement --req REQ-NNN --date {today}
"$GUILD" bug fix BUG-004 --task TASK-NNN        # for an approved bug
```

Go back to **3.1** — the approved gate makes `repair` ready, and the next segment is the
repair run. **There is no automatic re-review.** If the user wants another pass later, that is
a fresh reviewer ticket like any other.

### 3.6 Requirement completion

When the segment reports **no batches and no next gate**, the graph is exhausted. Confirm
nothing is still open:

```bash
"$GUILD" list task | awk -v r=REQ-NNN '$4 == r && $2 != "done" && $2 != "failed"'
```

Empty output → `"$GUILD" move REQ-NNN done`, then `"$GUILD" goal rollup` so the phase and
goal above it follow, then append a bullet to `CHANGELOG.md` under `## [Unreleased]` (3.9).

**A `blocked` task counts as OPEN, and the awk above already gets that right.** Do not "fix"
the filter with `&& $2 != "blocked"`. The asymmetry is the point: `failed` was adjudicated at
the gate; `blocked` is a machine verdict nobody has looked at, and closing a requirement over
one ships an un-attempted slice silently. If a blocked task is holding a requirement open, say
so by name — the fix is recruiting (3.8), not a status edit.

List any `failed` tasks in the completion summary — they were judged at `gate-repairs`, so
they report rather than block.

Then summarize the requirement and ask: continue with the next one, or wrap up?

### 3.7 A requirement with no graph — the v4 cursor

`guild next` and `guild batch` still work, and they are the fallback for a board that predates
Stage 4: the lowest-ID actionable ticket, with the old hardcoded reviewer gate.

**Use them only when `guild segment` says there is no graph, and say so out loud.** Run the
tickets in `guild next` order, expanding a `parallel-group` with `guild batch`, dispatching by
`guild match` exactly as in 3.3, and skip 3.5 entirely — there is no gate on a graph-less
requirement, so a review report goes to the user directly.

**Offer the fix once**: `guild:new-requirement` builds graphs for new work, and an existing
requirement can get one with `"$GUILD" graph new REQ-NNN --template standard` — but only the
architect should decide its shape, so hand it back rather than instantiating it yourself.

### 3.8 No eligible agent — block it, loudly

When `"$GUILD" match TASK-NNN` exits 1, no member's capabilities cover the ticket. That is a
**roster gap** and it should be loud.

```bash
"$GUILD" move TASK-005 blocked
"$GUILD" log TASK-005 --agent orchestrator \
  --entry "Blocked on {today}: no roster member covers [implement, rust]"
"$GUILD" spool drain TASK-005
"$GUILD" node REQ-NNN/{node-key} failed      # the node is not runnable either — say so in the graph
```

**Tell the user now, do not batch it into the wrap-up.** Name the ticket, the missing
capabilities, and the one thing that fixes it:

```
TASK-005 "Port the codec to Rust" is blocked: no guild member has [implement, rust].
Nothing will pick it up until the roster covers it. Run /guild:new-requirement to
recruit for it, or reassign the work.
```

Then continue the loop. `blocked` means exactly one thing — **no guild member can take this
bounty** — never "waiting on a person or a decision". It keeps its requirement open at 3.6,
and `guild move TASK-NNN done` on a blocked ticket is refused by the CLI. **Never substitute a
member you think is close enough**; if the user wants a generalist to take it anyway, that is
their call to make out loud.

**Unblocking**: once an agent file is added and `sync-agents` run,
`"$GUILD" move TASK-NNN todo` and `"$GUILD" node NODE-ID pending`, then confirm with
`"$GUILD" match TASK-NNN`.

### 3.9 CHANGELOG maintenance

When a requirement reaches `done` (3.6), append a bullet under `## [Unreleased]` in the
repo-root `CHANGELOG.md` (create the file with the Keep-a-Changelog preamble if it is
missing):

```
- REQ-NNN: {requirement title}
```

Skip if a bullet starting with `- REQ-NNN:` is already there (idempotent). With waived tasks,
use `- REQ-NNN: {title} (TASK-NNN skipped)`. The `guild:release` skill renames
`## [Unreleased]` later.

---

## Step 4: Session wrap-up

When the cycle ends (the user stops, or nothing is actionable):

```
Session Summary
===============
Nodes run: {N}     Tickets completed: {N}     Bugs filed: {N}

Requirements:
  REQ-007: Session-backed authentication — in-progress, at gate-repairs
  REQ-008: Preferences page — in-progress (batch 2 of 4)

Next check-in, I'll continue with:
  REQ-007 — the repairs gate is ready for your decision
```

Render the board with `"$GUILD" board`; `last-checkin` was already stamped at Step 1 — do not
stamp it again.

**The summary does not end without these three, when any of them is non-empty:**

- **Gates awaiting you** — `"$GUILD" gates --pending | awk '$5 == "ready"'`. A ready gate is
  the only thing on the board that cannot move without the user; it belongs at the top of the
  wrap-up, not the bottom.
- **Blocked work and roster gaps** — `"$GUILD" board` prints a Blocked section with the
  capability set inline; `"$GUILD" capability-requests --open` names the proposed member.
  Neither resolves on its own.
- **Nodes left `failed` or `running`** — `"$GUILD" graph REQ-NNN`. A `running` node with no
  live agent is a crash site and it holds everything behind it.

---

## Key Rules

1. **The graph is the chain, and you do not know it.** What runs, what runs together and what
   waits comes from `guild segment`. Never invent an order, widen a batch, merge two, or
   dispatch a node the segment did not offer.
2. **You own every status transition — all three writers.** `guild move` for a ticket,
   `guild node` for a graph node, `guild gate` for a gate. Agents report; they move nothing.
   Their only board writes are `guild log`, `guild finding` and `guild bug new`.
3. **Record BOTH halves.** A ticket moved without its node leaves the graph stalled; a node
   moved without its ticket leaves the board lying. Every 3.4 row is two commands.
4. **Two gates, and only one of them is yours.** `gate-plan` belongs to
   `guild:new-requirement`; `gate-repairs` is yours. **Never add a gate, never approve one
   that is not yours, and never build past a pending one.**
5. **Problems are collected, not escalated.** A review finding, a bug, a failed task, a file
   collision — file it and keep running. They are judged together at `gate-repairs`. Stopping
   the user per problem converts agent time into their time, which is the exact thing the
   two-gate model exists to prevent.
6. **`guild segment` orders; `guild match` and `guild bounties` only name the member.**
   `task_dependency` has no writer in v5, so `bounties` shows every open ticket as
   dependency-satisfied. Dispatching from it would run work the graph has not opened.
7. **There is no reviewer fan-out to perform.** The `review` node *is* four nodes; the member
   is the suffix of the node id.
8. **Drain before you read** — `guild spool drain TASK-NNN` is what turns an agent's reports
   into board state. An undrained ticket reads as never-started.
9. **Serial members are never concurrent.** `guild segment` refuses to emit such a batch
   (exit 1). If you ever see one, stop and report it — do not serialize it yourself.
10. **Subagents can't ask the user.** `AskUserQuestion` works only here. Every agent relays
    through `NEEDS INPUT:`; you ask, then `SendMessage` the answers back. This is also why a
    gate can never live inside a dispatched workflow.
11. **A ticket names a capability; `guild match` names the member.** Dispatch rank 1 when
    `agent` is empty, honor the pin when it is set, never invent a member for a ticket
    `match` refused.
12. **`blocked` means "no guild member can take this bounty" and nothing else.** It is
    written only by you, only after `match` exits 1, reported the moment it happens, and
    recruiting is the fix.
13. **You never write an `agents/*.md` file.** Creating a guild member happens in
    `guild:new-requirement`, on an explicit answer from the user, and nowhere else.
14. **A crash is recoverable from `graph_node`.** Never repair one by editing the database —
    every state you need is reachable with `guild node`, and every one is journaled.
