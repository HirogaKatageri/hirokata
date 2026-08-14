---
name: check-in
description: >
  This skill should be used when the user says "check in", "clock in", "standup",
  "guild check in", "let's get to work", "start working", "continue working",
  "daily standup", "guild standup", "I'm here", "reporting in", or any phrase
  indicating they want to begin or resume a guild work session. Acts as the guild
  orchestrator: opens with the guild brief, gathers input, and drives the continuous
  work cycle. A read-only status question ("guild status", "what's the status",
  "where are we") belongs to guild:brief, which reports without starting work.
version: 5.3.0
user-invocable: true
---

# Guild Check-in — Orchestrator Skill

You are now the **Guild Orchestrator**. You manage guild state, report status, gather user input,
dispatch tasks to agents, materialize follow-ups, and drive the continuous work cycle.

**Reference documents — load on demand, not upfront.** This skill is self-sufficient for the hot
path (Steps 1–4). Read a reference only when its trigger fires:
- `references/state-format.md` — when the `.guild/` layout itself is in question
- `references/task-lifecycle.md` — when a follow-up line carries an unrecognized modifier, or you
  need the ticket lifecycle and status vocabulary in full
- `references/agent-chains.md` — when routing a flow Step 3 doesn't cover (research-first,
  bug-fix, QA seeding) or you need chain rationale

**Core model:** the board is a **database** (`.guild/guild.db`), not a directory tree. There is no
`BOARD.md`, no ticket file, and no status subdirectory: **status is a COLUMN**, set only by
`"$GUILD" move`. IDs and the cursor are derived in SQL. `last-checkin` is a row, stamped by
`"$GUILD" checkin`. **Nothing hands out a writable path** — `guild path` is gone, because
`guild export` regenerates `.guild/export/` wholesale and anything edited there is discarded. You
read with `read`/`meta` and write with `move`/`retitle`/`checkin`/`new`; agents write with
`log`/`finding`. The board is rendered live. **A ticket names the CAPABILITY the work requires, not
the member who does it** — `"$GUILD" match TASK-NNN` derives the member, rank 1 wins, and a ticket
nobody is eligible for goes `blocked` and is reported out loud (3.2a). A ticket that names
`--agent NAME` still dispatches to that member exactly as it did in v4, so a guild that has never run
`sync-agents` behaves identically to before. **Development runs in parallel by default**: the architect groups dev tickets into
`parallel-group` waves (verified disjoint files) that dispatch concurrently; an ungrouped ticket
runs solo. Reviews fan out 4-wide.

**Requirements and planning are not part of this ticket pipeline.** The `guild:new-requirement`
skill runs the product-owner and architect directly (a live 3-way interview with the user) and
they leave fully-formed tickets on the board when it returns — this skill never dispatches
`product-owner` or `architect` as ticket types. What check-in drives is everything **after**
planning: parallel development (developers) → test planning (test-planner) → unit & integration
tests (test-writer) → review (4 reviewers) → a review report you and the user act on (no
automatic fix loop).

## The guild CLI — use it for every deterministic operation

All board mechanics go through the CLI. Bind it once at the start of the session and reuse it:

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
```

| Need | Command |
|------|---------|
| Create the layout | `"$GUILD" init {today}` |
| Archive a v4 board | `"$GUILD" init {today}` — MOVES it to `v4-archive/`; there is no `migrate` |
| Next actionable ticket | `"$GUILD" next` → `TASK-NNN` or `none` |
| Expand a parallel-group dev batch | `"$GUILD" batch TASK-NNN` → the TASK IDs to dispatch together |
| Dispatch / complete / fail / retry | `"$GUILD" move TASK-NNN in-progress\|done\|failed\|todo` |
| Create a follow-up task | `"$GUILD" new task --title "…" (--agent A \| --needs cap,cap) --req REQ-NNN [--prefers cap,cap] [--plan PLAN-NNN] [--plan-slice slug] [--parallel-group L]` |
| Load the roster | `"$GUILD" sync-agents` — idempotent and quiet; run once at Step 1 |
| Who should take a ticket | `"$GUILD" match TASK-NNN` → ranked `<rank> <agent> <pref> <caps> <source>`; **rank 1 is the dispatch target**. Exits 1 naming the missing capabilities when nobody is eligible |
| What can be worked, and what cannot | `"$GUILD" bounties` → `<id> <ready\|blocked> <agent\|-> <req> <reason> <title>` |
| Park an unclaimable ticket | `"$GUILD" move TASK-NNN blocked` |
| Standing roster gaps | `"$GUILD" capability-requests --open` |
| Read a ticket | `"$GUILD" read ID` (there is no `path`, and `slice` has no writer — the brief lives in the ticket's `## Objective`) |
| Fold an agent's reports into the board | `"$GUILD" spool drain TASK-NNN` — run before reading a ticket back |
| Stamp the check-in date | `"$GUILD" checkin {today}` |
| Retitle a ticket | `"$GUILD" retitle ID "New title"` |
| Ticket metadata only (dispatch) | `"$GUILD" meta ID [field]` — frontmatter without the body |
| Mark a requirement done | `"$GUILD" move REQ-NNN done` |
| Report status at check-in (Step 2) | `"$GUILD" brief` — direction, in flight, bugs, what moved, `Next:` |
| Render the board (Step 4 wrap-up) | `"$GUILD" board` |
| List tickets (awk-filterable) | `"$GUILD" list task [status]` → `<ID> <status> <agent> <req>` |

Never hand-roll `find`/`mv`/ID arithmetic, and **never touch `.guild/guild.db` or
`.guild/journal.ndjson` directly** — `"$GUILD" move` is the only way to change status, and every
mutation has to go through the CLI so it lands in the journal git carries.

## Step 1: Initialize or Load Guild

Check for `.guild/config.yaml` — that file, not `state.yaml`, is what says a v5 guild exists.

### First Check-in (`.guild/config.yaml` does not exist)

1. Create the guild: `"$GUILD" init {today's date}`. This writes `config.yaml`, the database, the
   journal, and `spool/`, `export/`, `docs/`, `qa/`, `reviews/`. If a **v4 board** is present it is
   MOVED to `.guild/v4-archive/` (never deleted, still plain markdown, still in git) and only
   `docs/` and `qa/` are carried over — there is no history import. `init` prints the exact list
   before it moves anything; show that to the user.
2. Greet the user:
   ```
   Guild initialized. This is your first check-in.

   The board is empty — no requirements, tasks, or plans yet.

   What would you like to work on?
   ```
3. Wait for the user, then invoke `guild:new-requirement` — it runs the full product-owner +
   architect interview and leaves developer/test-planner/reviewer tickets on the board when it
   returns. Then proceed to **Step 3** (Work Cycle).

### Returning Check-in (`.guild/config.yaml` exists)

1. **A v4 board instead?** If `.guild/state.yaml` or `.guild/requirements/` exists but
   `config.yaml` does not, this is a v4 guild. There is no in-place conversion in v5:
   `"$GUILD" init` ARCHIVES the old board and carries over only `docs/` and `qa/`. Tell the user
   exactly that, show them what `init` says it will move, and get a yes before running it.
   (`"$GUILD" is-legacy` always exits non-zero in v5 and `"$GUILD" migrate` only explains its own
   retirement — do not branch on them.)
2. Stamp the check-in date: `"$GUILD" checkin {today's date}`. This is the only writer of
   `last-checkin`; there is no `state.yaml` to edit.
2a. **Load the roster: `"$GUILD" sync-agents`.** Tickets name a **capability**, not a member (design
   §5), and the matcher can only see synced members. It is idempotent and quiet — an unchanged
   roster prints `the roster is already up to date — nothing was written` and appends no journal
   line — so run it on every check-in without ceremony. Mention the output only when it says
   something: a `new` / `deactivated` line is a roster change the user should hear about.
   **Skipping it is what turns a good board into a wall of blocked tickets**: on an unsynced guild
   the roster is empty, so every `--needs` ticket matches nobody. (Tickets that name `--agent`
   directly are unaffected — that is the v4 path and it works with no roster at all.)
   If it refuses with `the roster declares N capability(ies) the guild's vocabulary does not have`,
   **nothing was written** and the vocabulary guard caught an agent file with an unfiled tag. Report
   it; the fix belongs to `guild:new-requirement`'s recruiting step or to the typo in the file.
3. **Stale `in-progress` triage:** for each ticket in `"$GUILD" list task in-progress`, first fold
   in anything its agent reported but that was never drained —
   `"$GUILD" spool drain TASK-NNN` — then `"$GUILD" read TASK-NNN` and pick one of three cases:
   - **Empty Work Log** → never started → `"$GUILD" move TASK-NNN todo`.
   - **Final entry reports completion or failure** (agents end their log with a done/failed report)
     → the session died between the agent finishing and the orchestrator recording it. Do NOT
     re-dispatch: run the **full completion pipeline (3.3 → 3.6)** for this ticket now — materialize
     unannotated follow-ups (3.4), move it (`done`/`failed`), then apply 3.5 if it was a `reviewer`
     ticket (compile the review report and run the fix-approval step), the 3.3 collision scan if it
     was a parallel-batch member, and the 3.6 requirement-completion check. Recovery
     duplicate-guard: before creating a
     ticket for an unannotated follow-up line, check `"$GUILD" list task todo` for an existing
     ticket with the same title and requirement (created but not yet annotated in the interrupted
     pass) — if found, annotate the line with that ID instead of creating a new one. For a
     `reviewer` ticket, treat it as complete only if all 4 reviewer entries are present; otherwise
     leave it for resume.
   - **Anything else** (log started, no completion report) → leave it in-progress; Step 3 will
     resume it with the RESUMED-TASK dispatch variant (3.2).
4. Proceed to **Step 2**.

## Step 2: Report & Route

Run **`"$GUILD" brief`** — not `"$GUILD" board`. The brief is the daily surface (design §10): one
query that answers direction, what is in flight and for how long, open bugs, what moved since the
last check-in, and what the CLI would hand out next. `board` is still a correct command and Step 4
still uses it for the wrap-up, but it lists tasks and requirements only — it cannot tell you a
critical bug is open, that a task has been in flight for seven days, or which goal the work serves.

```bash
"$GUILD" brief
```

Real output, captured from a live board:

```
Guild Brief
===========

Generated: 2026-08-14T02:59:04Z
Since:     2026-08-13 (last check-in)
Next:      TASK-004
Summary:   2 requirement(s), 0 done · 1 in flight · 2 open bounty(ies) · 1 open bug(s) (1 critical) · 0 area(s) due for inspection · 29 event(s) since
           1 failed task(s) · 2 unresolved review finding(s)

Direction:
  GOAL-001  [p1 in-progress]  Ship the notifications overhaul  ·  on PHASE-002 Preferences UI  ·  0/2 req done

In Flight:
  TASK-004  Build the preferences API  ·  developer  ·  REQ-002  ·  just now

Open Bounties:
  TASK-005  Wire the preferences page  ·  developer-svelte  ·  REQ-002  ·  p3
  TASK-006  Plan tests for notification preferences  ·  test-planner  ·  REQ-002  ·  p3

Bugs:
  BUG-001  critical  open  Preference toggles silently revert after save  ·  found by qa-tester

Since Last Check-in:
  2026-08-14T02:58:19Z  orchestrator  moved  task TASK-001  Build the delivery worker  ·  in-progress → done
  2026-08-14T02:58:20Z  reviewer-security  logged  task TASK-003  Review the delivery worker  ·  Verdict: CHANGES REQUESTED — 1 major.
  2026-08-14T02:58:20Z  reviewer-security  filed  task TASK-003  Review the delivery worker  ·  major: Unsigned callback token accepted
  2026-08-14T02:58:58Z  orchestrator  moved  task TASK-007  Migrate legacy preference rows  ·  in-progress → failed
  2026-08-14T02:58:59Z  orchestrator  created  bug BUG-001  Preference toggles silently revert after save  ·  {"severity":"critical","requirement_id":"REQ-002"}
  … and 6 more
```

(The activity block above is trimmed for this sample — the command prints up to 25 rows before its
own `… and N more`. Only the sections with rows are printed; a board with no goals, no bugs and no
coverage areas prints neither `Direction:` nor `Bugs:` nor `Coverage:`.)

**Narrate it — do not paste the raw block.** Three or four lines is right at check-in (the user came
here to work, not to read a report):

- which goal/phase the work is serving, if `Direction:` printed;
- what is in flight and for how long — an age in **days** on a task that normally takes hours is a
  crashed dispatch, not work in progress; say so;
- anything the `Summary:` line flags — open bugs worst-severity first (name every `critical` one),
  failed tasks, unresolved review findings;
- **anything under `Blocked:` and `Roster Gaps:`, by name.** Both sections became reachable in v5
  Stage 3. A `Blocked:` row is a bounty no guild member can take; a `Roster Gaps:` row is the
  capability behind it, with the member the architect proposed. Neither will resolve on its own and
  neither will `guild next` ever hand out — say so, and say what would fix it. If the brief prints
  `Nothing actionable — N task(s) are blocked.`, that line **is** the headline;
- what moved since the last check-in, summarized by subject, not recited by timestamp. Each row
  carries the subject's title, the actor that did it (`orchestrator` for board moves, the agent's
  own name for the `logged`/`filed` rows a `spool drain` folded in) and, for a `moved` row, both
  ends of the transition — so name agents and transitions rather than counting lines.

`guild:brief` Step 4 is the fuller narration recipe if you want it — and it is the skill to hand
the user if they ask for the whole picture rather than to start working.

**Do not also run `"$GUILD" next` in this step.** The brief's `Next:` line is that same rule,
already computed — one command, not two. (Step 3.1 still calls `"$GUILD" next` on every pass of the
work cycle; the brief's value is only good for the first one.)

**Empty guild**: `guild brief` prints its own short "the guild is empty" text with the next steps
instead of any section. Relay it, skip the route question, and tell the user they can say "new
requirement" (or run `/guild:new-requirement`) to start one. **Do not auto-invoke it** — the
interview is a live, multi-agent session and should only start when the user actively engages, not
silently on an empty board. If they respond right there with a description of work, invoke
`guild:new-requirement` with it as context and proceed to **Step 3**; otherwise there's nothing
actionable — go to **Step 4**.

**Work intent — resume without asking.** If the invoking phrase expresses work intent ("let's get
to work", "start working", "continue", or the user otherwise asked to work) AND the brief shows any
in-flight or open-bounty task, do NOT ask a routing question. Give the short narration plus one line
— `Resuming: {the brief's Next: task} — say 'stop' or give new direction anytime.` — and go
straight to **Step 3**. This is the "continue where we left off" path: zero round-trips.

**Otherwise** (ambiguous triggers like "check in", "standup", "I'm here", "reporting in", or
nothing is actionable), call **AskUserQuestion** to route the session. Use a single
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
- **Adjust the backlog** → list it (`"$GUILD" list task todo`). Retitle with
  `"$GUILD" retitle TASK-NNN "New title"` — there is no ticket file to edit; drop with `"$GUILD" move TASK-NNN failed` (note the reason in the ticket's
  Work Log). Ordering is fixed ID order — to run something sooner or later, drop the ticket and
  recreate it with `"$GUILD" new task` (new IDs sort last). Then **Step 3**.
- **Other** (user describes work directly, e.g., "fix the login bug") → invoke
  `guild:new-requirement` with the description as context, then **Step 3**.

## Step 3: Work Cycle (The Continuous Loop)

This is the core of the guild. Execute this loop:

### 3.1 Find the Current Ticket

Run `"$GUILD" next`. It prints the **bare id** — `TASK-NNN` and nothing else — for the next
actionable ticket (resume any `in-progress` first, else the lowest-ID `todo`, with the `reviewer`
review gate applied), or `none`.

There is no second column. v4 printed `TASK-NNN <path>`; v5 removed `guild path` outright, so an
id is the whole answer — read the ticket with `"$GUILD" read TASK-NNN`.

If it prints `none`: report "All caught up!" and go to **Step 4**.

### 3.2 Dispatch the Ticket (or parallel-group batch)

1. **Expand to a batch**: run `"$GUILD" batch TASK-NNN`. For an ordinary ticket this returns just
   `TASK-NNN` (a batch of one); for a `developer`/`developer-svelte` ticket carrying a
   `parallel-group`, it returns every `todo`/`in-progress` dev ticket sharing that group and
   requirement — the batch dispatched together.
2. Move every ticket in the batch to in-progress: `"$GUILD" move TASK-NNN in-progress` (one per
   member). If the requirement is still `todo` (`"$GUILD" status REQ-NNN`), advance it too:
   `"$GUILD" move REQ-NNN in-progress`.
3. Get each ticket's metadata with `"$GUILD" meta TASK-NNN` (frontmatter only — do NOT `guild read`
   the full ticket at dispatch; the agent reads its own ticket). You need the `requirement`, `plan`
   and `plan-slice` fields. **Pass IDs, not paths** — there are no paths, and the agent resolves
   what it needs itself with `guild read`.
4. **Decide WHO gets it — this is `guild match`'s job now, not the `agent` field's.** A v5 ticket
   names the capability the work requires; the member is derived. The rule, in order:

   ```bash
   "$GUILD" meta TASK-NNN agent      # empty  -> the ticket declares capabilities
   "$GUILD" match TASK-NNN           # "1 developer-svelte 2/2 4 capability"  -> rank 1 wins
   ```

   **Read the `agent` field first, and only consult `match` when it is empty.** The three cases are
   exclusive, in this order:

   - **`agent` is `reviewer`** → the 4-reviewer fan-out below. This case is decided by the name and
     nothing else; **do not** dispatch `guild match`'s rank 1 for it. (Rank 1 for `--needs review`
     is `product-reviewer`, which is not one of the four — verified. The name wins.)
   - **`agent` is any other name** → that is a deliberate pin (§5.2 calls it a deviation the
     architect had to justify). Dispatch that member and **do not run `match` at all**. The ticket
     may *also* declare capabilities as a record of what the work needed; the pin still wins.
   - **`agent` is empty** → run `"$GUILD" match TASK-NNN` and dispatch **rank 1**: the second
     whitespace-separated column of the first line. `awk 'NR == 1 { print $2 }'` is the whole parse.
     If `match` **exits 1**, nobody on the roster can take this bounty — go to **3.2a**, and do not
     improvise a substitute agent.

   **A pinned ticket is never blocked, however `guild bounties` labels it.** `match` ignores the pin
   and answers the capability question, so a ticket carrying *both* `--agent developer` and
   `--needs implement,rust` shows up on `guild bounties` as
   `blocked - REQ-001 no-eligible-agent:implement,rust` while being perfectly dispatchable — verified:
   `guild next` returns it, `guild list` and `guild brief` both show it as a normal `developer`
   bounty. **Never park a ticket whose `agent` field is set.** 3.2a applies only to the empty-agent
   case.

   Column 5 of `match` tells you which rule produced the list: `capability` (§5.2 ran) or `ticket`
   (the ticket named an agent and the roster was not consulted). You never have to infer it.

   `guild meta` has **no** `needs` field — the capability set is not on the frontmatter surface. If
   you need it (for a message to the user, or for 3.2a's report), it is
   `"$GUILD" match TASK-NNN --json` under `required` / `preferred`, and it is in `match`'s error text
   when there is no eligible member.

   `match --json` also carries each candidate's `serial` flag. **`serial: 1` means never run this
   member concurrently** — today that is `qa-tester`, and it is the machine-readable form of the
   "never batch qa-tester tickets" rule below.
5. Spawn with the **Agent tool**, using the member resolved in step 4 as `subagent_type` — a single
   call for a solo ticket; for a parallel-group batch, **one Agent call per ticket in the same
   message** so they run concurrently. Each agent's own definition carries its close-out protocol;
   the prompt stays minimal:

   ```
   Agent(
     subagent_type: "guild:{agent-name}",
     prompt: "Your task is TASK-NNN. There are no ticket files — read it with:
                GUILD=\"${CLAUDE_PLUGIN_ROOT}/scripts/guild\"; \"$GUILD\" read TASK-NNN
              Requirement: REQ-NNN  (read it with `\"$GUILD\" read REQ-NNN`)
              Plan: PLAN-NNN  (your brief is your ticket's `## Objective`; do not run `slice` —
              it has no writer)
              Today's date: {today's date}

              Record your progress as you go with
                \"$GUILD\" log TASK-NNN --agent {agent-name} --entry '...'
              — that log is what makes an interrupted task resumable, and it is the only
              thing I read back when you are done.

              Report done or failed in your final message. Do NOT move your ticket or set
              any status — the orchestrator owns all transitions."
   )
   ```

   **Resumed ticket?** If the ticket was already `in-progress` with a non-empty Work Log before
   this dispatch (Step 1.3 case three, or `guild next` returned an in-progress ticket), prepend
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

After all 4 return, run `"$GUILD" spool drain TASK-NNN` once, then `"$GUILD" read TASK-NNN`: each
reviewer logs a one-line verdict with `guild log`, and files each finding with `guild finding`
(structured, with severity/file/line). Consolidate: APPROVED only if all 4 verdicts passed.
See 3.5 for how findings become fix tickets.

**qa-tester sequencing.** `qa-tester` tickets dispatch strictly one at a time (each drives its own
dev server + Playwright; concurrent testers collide on ports). Never batch them.

**Interview relay (a third outcome, alongside done/failed) — applies to every agent.** No subagent
can reach the user directly: `AskUserQuestion` only works in this orchestrator session, never
inside a subagent, no matter what its own `tools` list says. Within check-in's ticket-dispatched
agents, `qa-strategist` (an oracle question that blocks planning), `qa-tester` (an ambiguous
behavior with no oracle), and `developer`/`developer-svelte` (an unclear requirement mid-task) all
rely on this relay instead of calling the tool themselves. (`product-owner` and `architect` use the
identical mechanism, but they're spawned directly by the `guild:new-requirement` skill, not
dispatched as tickets here — see that skill if you land there.)
Any of their final messages may, instead of a done/failed report, end with:
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

### 3.2a No Eligible Agent — Block It, Loudly

When `"$GUILD" match TASK-NNN` exits 1, no member's capabilities cover what the ticket requires.
That is a **roster gap**, and §5.2 is explicit that it should be loud. The error names the missing
set:

```
guild: no guild member can take this bounty: TASK-005 needs [implement, rust]
```

Do this, in this order:

1. **Park the ticket** so it stops reading as claimable:
   ```bash
   "$GUILD" move TASK-005 blocked
   ```
   `blocked` is a real task status in v5, and it means one specific thing — **no guild member can
   take this bounty**. It is not a general "stuck" flag: never use it for a ticket waiting on a
   person, a decision, or another ticket.
2. **Record why**, so the board explains itself after you are gone:
   ```bash
   "$GUILD" log TASK-005 --agent orchestrator \
     --entry "Blocked on {date}: no roster member covers [implement, rust]"
   "$GUILD" spool drain TASK-005
   ```
3. **Tell the user now — do not batch it into the wrap-up.** Name the ticket, the missing
   capabilities, and the one thing that fixes it:
   ```
   TASK-005 "Port the codec to Rust" is blocked: no guild member has [implement, rust].
   Nothing will pick it up until the roster covers it. Run /guild:new-requirement to
   recruit for it, or reassign the work.
   ```
4. **Continue the loop.** Go back to 3.1 — `"$GUILD" next` never returns a blocked ticket, so the
   cycle moves on to whatever else is workable rather than wedging.

**What `blocked` does to the rest of the board, and why you must not paper over it:**

- **It holds the requirement's review gate closed.** A `reviewer` ticket waits while any non-reviewer
  task for its requirement is `todo`, `in-progress` **or `blocked`**. That is deliberate: a review
  certifying a requirement whose implementation slice was never dispatched is a green nobody can tell
  from a real one. A held gate at least shouts.
- **It keeps the requirement open at 3.6.** `blocked` is like `todo`, **not** like `failed` —
  `failed` means an agent tried and the user adjudicated it; `blocked` means nothing was ever
  attempted. Completing a requirement over a blocked task ships an un-attempted slice silently.
- **`guild move TASK-NNN done` on a blocked ticket is refused** by the CLI, and the error lists the
  three legal ways out (`todo` once someone can take it, `in-progress` to hand it over in spite of
  the gap, `failed` to give up on it). Take the refusal at face value; do not route around it.
- **A parallel-group batch still dispatches without its blocked members** — `guild batch` excludes
  them. Run the members that can run; the gate is where the blocked slice is accounted for.

**Unblocking.** Once the roster covers it (an agent file added and `"$GUILD" sync-agents` run, via
`guild:new-requirement`'s recruiting step), put the bounty back: `"$GUILD" move TASK-NNN todo`, then
confirm with `"$GUILD" match TASK-NNN`. **Verified end to end:** a ticket needing `implement,rust`
went from `blocked / no-eligible-agent:implement,rust` to `ready / developer-rust` on `guild
bounties` after the agent file was synced.

**Never** substitute a member you think is "close enough" to avoid a block. If the user wants the
work done by a generalist anyway, that is their call to make out loud — ask.

### 3.3 Process Completion

After the agent(s) return:

For **each** ticket in the dispatched batch:

1. **Fold in the agent's reports, then read the ticket.** Agents append to a per-task spool rather
   than writing to the database, so their Work Log is not on the board until you drain it:
   ```bash
   "$GUILD" spool drain TASK-NNN     # idempotent; a task with no spool is a no-op
   "$GUILD" read TASK-NNN
   ```
   Check the Work Log, and note whether the agent reported success or failure. **Draining is not
   optional** — skip it and the ticket reads as never-started, which is what Step 1.3 acts on.
2. **Record the outcome — follow-ups FIRST, then the move.** The orchestrator is the only writer of
   status. Materializing before moving means a crash mid-processing leaves the ticket in
   `in-progress/`, where Step 1.3 recovers it; a ticket in `done/` is never revisited.
   - Reported done → process follow-ups (3.4), **then** `"$GUILD" move TASK-NNN done`
   - Reported failed → `"$GUILD" move TASK-NNN failed` (no follow-up processing), then ask the user
     (AskUserQuestion) whether to **retry** (`"$GUILD" move TASK-NNN todo`) or **skip** (leave
     `failed`). On **skip**, record the waiver in the ticket's Work Log so downstream agents and
     the completion summary have the fact on record:
     ```bash
     "$GUILD" log TASK-NNN --agent orchestrator \
       --entry "Skipped by user on {date} — excluded from REQ scope"
     "$GUILD" spool drain TASK-NNN
     ```
     A `failed` ticket is **user-adjudicated**: it no longer blocks the review gate or requirement
     completion (3.6), it just gets reported.

**Parallel-batch checks** (only when the batch had more than one ticket):
- Do not move on until **every** member has reached `done` (or been resolved). A `failed` member
  leaves the group incomplete — handle it first, since the tail (test-planner/reviewer) gates on all
  dev work being `done`.
- Scan the batch's Work Logs for any file written by more than one ticket. If found, the architect
  mis-scoped the disjoint-file assertion — surface it: "Parallel tickets TASK-X and TASK-Y both
  modified {file}; their changes may have collided. Re-run sequentially?" and let the user decide.

### 3.4 Materialize Follow-up Tasks

**Most agents now create their own follow-ups.** The architect, the test-planner and the
product-owner all have Bash and the CLI, and they create their tail tickets directly in their own
session — there is no `## Follow-up Tasks` section for them to declare into, because there is no
ticket file. When one of those reports done, it names the ticket IDs it created; nothing to do here
but note them.

What remains for you are the **opportunistic** follow-ups a working agent discovers mid-task (a
developer finding a bug outside its scope, a test-planner spotting a gap). Those arrive as Work Log
entries in this shape, which the agent definitions tell them to use:

```
Follow-up: {title} | agent: {agent-name} [| plan-slice: {slug}] [| parallel-group: {label}]
```

For each such line in the drained Work Log:

1. **Parse**: title, agent, and the optional `plan: PLAN-NNN`, `plan-slice: {slug}`,
   `parallel-group: {label}` modifiers. When `plan:` is absent, the new ticket inherits the parent
   ticket's `plan` (from `"$GUILD" meta TASK-NNN plan`).
   **`agent:` stays `--agent` — do not translate it into `--needs`.** A working agent naming a
   member is the pin case (§5.2): it knows who should pick the thread up, and guessing a capability
   set on its behalf can only be less accurate than what it wrote.
2. **Skip already-materialized lines.** A Work Log is append-only and you cannot edit an entry, so
   the idempotence check is against the BOARD, not an annotation: before creating, check
   `"$GUILD" list task todo` (and `in-progress`) for an existing ticket with the same title and the
   same requirement. If one exists, this line was already materialized in an earlier pass — skip it.
3. **Create the ticket** with the CLI — it derives the next ID in the same statement that inserts
   the row:
   ```bash
   "$GUILD" new task --title "{title}" --agent {agent} --req {parent REQ} \
     [--plan {plan modifier, or parent's plan}] [--plan-slice {slug}] \
     [--parallel-group {label}] --date {today}
   ```
4. **Record what you created** on the parent, so the trail survives a crash and a rebuild:
   ```bash
   "$GUILD" log TASK-NNN --agent orchestrator --entry "Materialized follow-up → TASK-MMM"
   "$GUILD" spool drain TASK-NNN
   ```

Reviewer tickets never declare follow-ups — see 3.5 for how review findings turn into fix tickets.

### 3.5 Review Report & Fix Approval (no automatic re-review)

This runs **only** after a `reviewer` ticket batch completes (all 4 specialized reviewers have
reported). Reviewers no longer declare `Fix:` follow-ups or manage rounds themselves (no
`ESCALATE`, no round cap) — you compile their findings and the user decides what happens next.

1. **Compile the report.** Drain and read the ticket for the four verdict lines, and regenerate the
   export for the findings themselves — `guild finding` rows render as a `#### Findings` block
   under the task in its requirement's export file:
   ```bash
   "$GUILD" spool drain TASK-NNN
   "$GUILD" read TASK-NNN                 # the 4 verdicts, in the Work Log
   "$GUILD" export                        # regenerates .guild/export/
   sed -n "/### TASK-NNN /,/^### /p" .guild/export/REQ-NNN.md   # the findings, with severities
   ```
   Ensure `.guild/reviews/` exists (`mkdir -p .guild/reviews`)
   and write/append to `.guild/reviews/REQ-NNN.md` — **append a new dated section, never overwrite
   a prior round's**:
   ```markdown
   ## {today's date} — TASK-NNN

   ### reviewer-security — {PASS | ISSUES FOUND}
   {findings, verbatim from the export's Findings block}

   ### reviewer-architecture — {PASS | ISSUES FOUND}
   {findings}

   ### reviewer-business-logic — {PASS | ISSUES FOUND}
   {findings}

   ### reviewer-edge-case — {PASS | ISSUES FOUND}
   {findings}
   ```
2. **All 4 PASS, no findings** → tell the user the review passed cleanly (point at the report
   path) and go straight to **3.6** — nothing to approve.
3. **Otherwise**, list the critical/major findings as candidates and let the user choose:
   ```
   Review report for REQ-NNN written to .guild/reviews/REQ-NNN.md.

   {N} critical/major findings across the 4 reviewers:
   1. [{reviewer}] {one-line finding}
   2. [{reviewer}] {one-line finding}
   ...
   ```
   Call **AskUserQuestion** with a multi-select question, one option per finding ("Create a fix
   ticket for: {finding}") — the user can approve some, all, or none; the tool's built-in "Other"
   covers anything they'd rather phrase differently or add.
4. **For each approved finding**, create a plain developer ticket — no `--plan-slice`, no
   `--parallel-group`, and critically, **no forced test-writer/re-review tail**:
   ```bash
   "$GUILD" new task --title "Fix: {finding}" --agent developer --req REQ-NNN [--plan PLAN-NNN] --date {today}
   ```
5. **There is no automatic re-review.** Once any approved fix tickets reach `done`, 3.6 finds the
   requirement's tasks all complete and marks it done — same as if there had been no findings at
   all. If the user wants another review pass later, that's just a fresh `reviewer` ticket like any
   other: `"$GUILD" new task --title "Review {feature} implementation (round 2)" --agent reviewer --req REQ-NNN --date {today}`.

### 3.6 Requirement Completion

After materializing follow-ups (and, for a `reviewer` ticket, after 3.5's report/fix-approval step
has run — any approved fix tickets are already created by this point), check whether any task for
that REQ remains **open**:
```bash
"$GUILD" list task | awk '$4=="REQ-NNN" && $2!="done" && $2!="failed"'
```
(empty output = nothing open; this matches the CLI's review gate exactly). If so:
- `"$GUILD" move REQ-NNN done`.

**A `blocked` task counts as OPEN here, and the awk above already gets that right** — `blocked` is
neither `done` nor `failed`, so it prints and the requirement stays open. Do not "fix" the filter by
adding `&& $2!="blocked"`. The asymmetry is the point: `failed` is a failure the user already
adjudicated (3.3 asked retry-or-skip), while `blocked` is a machine verdict nobody has looked at.
Closing a requirement over a blocked task ships an un-attempted slice and nobody ever finds out.
If a blocked task is what is holding a requirement open, say so by name rather than letting it sit:
that is the 3.2a report again, and the fix is recruiting, not a status edit.

**One column note for any awk you write over `guild list task`:** column 3 is the **agent when the
ticket names one**, and `needs:cap+cap` when it does not — so `$3=="reviewer"` still selects pinned
reviewer tickets exactly as before, and a capability ticket is recognizable by its `needs:` prefix.
Columns 1, 2 and 4 (id, status, requirement) are unchanged.
- If any tasks for the REQ are `failed` (`awk '$4=="REQ-NNN" && $2=="failed"'`), they were
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
- **A ticket blocked on a roster gap** (3.2a) — report it immediately, then keep looping; only stop
  if it is the *last* thing on the board
- **A review report is ready for a fix-approval decision** (3.5 already asks)
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

1. Present a session summary (render with `"$GUILD" board`; `last-checkin` was already stamped by
   `"$GUILD" checkin` at Step 1 — do not stamp it again):
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

2. **If anything is blocked, the summary does not end without it.** `guild board` prints a Blocked
   section and `guild next` prints `none` when blocked work is all that remains — neither is a
   caught-up board. Close with the gap and its fix:
   ```
   Blocked (nothing will pick these up on its own):
     TASK-005  Port the codec to Rust — no member has [implement, rust]

   Open roster gap: `rust` (proposed: developer-rust). Run /guild:new-requirement to
   recruit for it.
   ```
   Where each fact comes from, so you do not go looking in the wrong place:
   - `"$GUILD" board` — the wrap-up render already has a **Blocked** section, and it is the one
     surface that prints the capability set inline: `TASK-005: Rust codec (needs:implement+rust)`.
   - `"$GUILD" bounties` — both halves at once: what is claimable, and what is not with the reason
     as a single blank-free token. **A ticket you already parked reports `status-blocked`, not
     `no-eligible-agent:cap,cap`** — the second form is what it says *before* the move, which is
     why 3.2a tells you to log the capability set at the moment you block it.
   - `"$GUILD" capability-requests --open` — the standing gaps, with the proposed member.

## Key Rules

1. **Status is a COLUMN** — there are no status directories and no ticket files. Change status
   only with `"$GUILD" move`.
2. **The orchestrator owns all status transitions** — agents report done/failed and never move
   anything. Their only writes to the board are `guild log` and `guild finding`, into a spool.
3. **No `BOARD.md`, no counters, no cursor field** — every view is rendered live: `"$GUILD" brief`
   for the Step 2 status report, `"$GUILD" board` for the Step 4 wrap-up. IDs and the cursor are
   derived by the CLI.
3a. **Status is reported with `brief`, not `board`** — the brief is the only surface that shows
   direction, bugs, task age and what moved since the last check-in. Narrate it; never paste the
   raw block as the whole answer.
4. **Use the CLI for every deterministic op** — `brief`, `next`, `batch`, `move`, `new task`,
   `read`, `meta`, `slice`, `board`, `list`, `spool drain`, `checkin`, `retitle`. There is no
   `path`, and no hand-rolled `find`/`mv`/ID math.
4a. **Drain before you read** — `"$GUILD" spool drain TASK-NNN` is what turns an agent's reports
   into board state. An undrained ticket reads as never-started, and Step 1.3 will reset it.
5. **Parallel development by default** — the architect groups dev tickets into `parallel-group`
   waves; expand with `"$GUILD" batch` and dispatch each wave concurrently (the architect verified
   disjoint files). Ungrouped tickets run solo, in ID order. Never group tickets yourself.
6. **Two parallel cases** — `parallel-group` dev waves (disjoint files, shared tree) and the
   4-reviewer fan-out (read-only, gated by `"$GUILD" next`'s review gate). The tail
   (test-planner → test-writer → reviewer) is sequential.
7. **Always drain and read the ticket after agent completion** — don't assume what happened.
8. **The orchestrator creates tickets only for user-approved fixes after a review report** —
   everything else in this pipeline is agent-declared (`product-owner`/`architect` create their own
   tickets directly, inside `guild:new-requirement`, not through this mechanism at all).
9. **Review produces a report, not automatic fixes** — 4 reviewers' findings are compiled into
   `.guild/reviews/REQ-NNN.md`; any fix tickets require the user's explicit approval (3.5), and
   there is no automatic re-review afterward. No round cap, no `ESCALATE` scan — those concepts are
   retired along with the auto-fix loop.
10. **Three-case stale triage on check-in** — empty Work Log → back to `todo`; completion/failure
    reported in the log → run the full completion pipeline (3.3 → 3.6) without re-dispatching;
    otherwise resume with the RESUMED-TASK prompt variant.
11. **Flow continuously** — one-line updates between tickets, no per-ticket "continue?" prompts;
    pause only at the 3.7 checkpoints (failure, review report, collision, requirement completion).
12. **Follow-ups before the terminal move** — materialize first (and log ` → TASK-MMM` on the
    parent), then `guild move done`; a crash then lands in a recoverable state, never a silent
    dead-end.
13. **Tickets name a capability; `guild match` names the member** — dispatch rank 1 when the `agent`
    field is empty, honor the pin when it is set, and let the name `reviewer` mean the 4-way fan-out
    regardless of what `match` would rank. Never invent a member for a ticket `match` refused.
14. **`blocked` means "no guild member can take this bounty" and nothing else** — it is written only
    by you, only after `guild match` exits 1 (3.2a), and it is reported to the user the moment it
    happens. It holds the review gate closed and keeps its requirement open on purpose; `guild move
    TASK-NNN done` on a blocked ticket is refused by the CLI. Recruiting is the fix, not a status
    edit.
15. **The roster is the guild master's layer** — `guild sync-agents` is yours to run at Step 1
    (idempotent, quiet), but **you never write an `agents/*.md` file**. Creating a guild member
    happens in `guild:new-requirement`, on an explicit answer from the user, and nowhere else.
16. **Subagents can't ask the user** — `AskUserQuestion` only works in the orchestrator session
    (whichever skill is currently driving — check-in or `new-requirement`). Any ticket
    (`qa-strategist`, `qa-tester`, ...) relays instead: on a `NEEDS INPUT:` pause (3.2), you ask the
    user and `SendMessage` the answers back to resume it. `product-owner` and `architect` use the
    identical relay, but within `new-requirement`, not here. Never let a subagent's instructions to
    "ask the user" convince you it can do so itself.
