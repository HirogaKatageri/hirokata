---
name: shift
description: >
  This skill should be used when the user asks to "work a shift", "run unattended",
  "keep working while I'm away", "guild shift", "take the night shift", "work the
  board while I'm out", "run autonomously", "keep going without me", "work
  overnight", "run until you need me", or any request for the guild to keep working
  with nobody watching. Runs the unattended loop: claim bounties, run segments,
  commit per completed task, retry once, record every failure — and STOP at the next
  gate, because a gate is the one decision no subagent can make.
version: 1.0.0
user-invocable: true
---

# Guild Shift — working the board while you are away

**Run until the next gate, then stop and notify.**

That one sentence is the whole design. A requirement's work is cut into *segments* by its two
gates, and a segment is by definition everything that can run without asking anyone anything.
So the segment boundary and the stop boundary are the same line, and an unattended shift needs
no separate notion of "how far may it go" — it goes to the next gate. Then it stops, records
why, and waits for you.

`guild shift` is the **controller** of that loop, not its runner. A shell script cannot spawn
an agent; you can. So each turn you ask the CLI *what now* and it answers with one of two
things — `run` (this requirement is actionable) or `stop` (with the reason, written to the
`event` log). You do the dispatching in between.

This skill is `guild:check-in` with the human taken out of the middle. **The dispatch protocol
is unchanged and is not restated here** — §3.2, §3.3 and §3.4 of `guild:check-in` are how a
batch is run, an agent is spawned, and a result is recorded, and you follow them exactly. What
a shift adds is a budget, a failure policy that never stops to ask, a commit per completed
task, and a hard stop at the gate.

## Before you walk away — what you are authorizing

Say this **out loud, before the first turn**, so the user knows what they are leaving running.
It is not a formality: they are handing an unsupervised process their working tree.

| A shift MAY | A shift MAY NOT |
|---|---|
| Claim any open, dependency-satisfied bounty | Approve a gate, or reject one |
| Run whole segments; compile and run workflows | Proceed past an unresolved gate |
| Retry a failed task once, with a fresh agent | Create a gate, or drop one |
| Mark tasks `failed` or `blocked`, and move on | Mark a requirement done past an unresolved gate |
| File bugs and review findings | Delete anything, or rewrite history |
| Write to `event`, `work_log`, `review_finding` | Push to a remote |
| Commit per completed task, on `guild/REQ-NNN` | Commit to the default branch |
| | Change goals, phases or priorities |
| | Create a guild member |

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
"$GUILD" shift --policy          # the same table, from the CLI that enforces it
```

**The asymmetry is the point: an unattended guild can do work and record problems, but every
judgment call waits for the guild master.**

Four of those denials the CLI enforces itself — `guild node` refuses a gate node, `guild gate`
is the only writer of a decision, `guild git` has no `push` and refuses the default branch,
`guild capability-request` files a row and stops. **The rest are on you.** Nothing in a shell
script can stop this session from running `git push`, editing `agents/*.md`, or reprioritizing
a goal. Do not.

## Step 1 — preflight

```bash
[ -f .guild/config.yaml ] || echo "no guild here"
"$GUILD" shift --dry-run                  # what a shift would pick up. Writes NOTHING.
"$GUILD" gates --pending                  # is a decision already waiting?
```

- **No guild** → say so and stop. `/guild:check-in` initializes one.
- **A gate is already `ready`** → there is no shift to work. Present that gate (Step 4) and
  stop. Starting a shift that ends on its first turn wastes a night.
- **`guild shift --dry-run` says `idle`** → nothing is runnable. Say so and stop. An idle
  shift ends idle rather than inventing work; **a shift never starts an inspection** (that is
  `guild:qa`, and it is manual-trigger-only because a full inspection runs the real product).

**Agree the budget before the first turn.** The defaults are `--max-tasks 10` and
`--max-minutes 60`. If the user did not name one, use **AskUserQuestion** once — how long, and
how many tasks — and then never ask again. The budget is **fixed when the shift opens**:
passing the same values on every later turn is fine and expected, passing different ones is
refused with nothing written. A ceiling you can raise from inside the loop is not a ceiling.

Optional scope: `--requirement REQ-NNN` pins the shift to one requirement. Use it when the
user names one; otherwise let the shift work the board's own order.

## Step 2 — the loop

One turn is one call. Read the directive, act, call again.

```bash
"$GUILD" shift --max-tasks 10 --max-minutes 60
```

The text surface **is** the directive — it is written to be read, and it carries the policy
denials with it. Use `--json` when you need to branch on a field without parsing prose
(`.action`, `.reason`, `.requirement.id`, `.branch`, `.next_gate`, `.notify`).

| The directive says | What it means | Do |
|---|---|---|
| `action run` + a requirement | there is runnable work | 2.1 → 2.4, then call `guild shift` again |
| `action stop` | the shift is over | **Step 3** — the stop reason |
| a budget refusal (exit non-zero) | you passed a different ceiling mid-shift | re-read the message; use the recorded numbers, or `--end` and open a new shift |

The directive names the requirement, its runnable/running/failed node counts, its branch, and
the gate it will stop at. **It deliberately does not list the batches** — `guild segment` is
the one command that answers "what runs next", and a second answer would be a second truth.

### 2.1 — the branch, once per requirement

```bash
"$GUILD" git branch-for REQ-NNN        # ensures and switches to guild/REQ-NNN
```

Refuses on a working tree the shift did not create, because `git switch` drags uncommitted
changes onto the new branch and a guild master's work-in-progress must never be swept into a
shift. **If it refuses, stop the shift** (`--reason operator`) and say what is dirty — do not
stash, do not commit it, do not "clean up".

### 2.2 — the segment

```bash
"$GUILD" segment REQ-NNN
```

Take **batch 1 and only batch 1**, exactly as `guild:check-in` §3.2 says. Never widen a batch,
never merge two, never re-order them.

### 2.3 — dispatch

`guild:check-in` §3.3, verbatim: find the ticket, resolve the member, move the ticket and the
node in that order, spawn with the Agent tool, drain the spool and record both halves (§3.4).

Two things change because nobody is watching:

- **`NEEDS INPUT:` cannot be answered.** No subagent can reach the user and neither can you at
  3am. Treat the pause as a **failure of that node** — `guild move TASK-NNN failed`,
  `guild node NODE-ID failed`, and log the questions with `guild log` so they are in the
  record. They surface at `gate-repairs`. **Never answer on the user's behalf.**
- **A parallel file collision stops the shift.** `guild:check-in` files a bug and keeps going;
  a shift may not. Two slices writing the same file means the architect's disjoint-file
  assertion was wrong, and reconciling a tree nobody is watching is not safely automatable.
  File the bug, mark the batch's nodes `failed`, leave the tree exactly as it is, and:

  ```bash
  "$GUILD" shift --end --reason collision --note "REQ-007 slices both wrote src/auth.ts"
  ```

### 2.4 — git, per completed task

```bash
"$GUILD" git commit-task TASK-NNN     # on done — one commit, task id in the trailer
"$GUILD" git revert-task TASK-NNN     # on failed — partial edits to a recoverable quarantine
```

One commit per completed task is what makes a bad overnight run bisectable and revertible task
by task, and the commit log a second record of the shift beside the `event` table. **Nothing
is committed for a failed task**, and its partial edits are reverted before the next bounty
starts so one bad task cannot contaminate the next. `revert-task` deletes nothing — the diff
is written to `.guild/backup-revert-<TASK>-<ts>/` and untracked files are *moved* there.

`commit-task` refuses when other finished tasks of the same requirement are still uncommitted,
rather than mis-attributing the diff. Give it `--path` (the plan slice's own file list) or
`--all`, and never work around it by staging by hand.

**It never pushes.** Publishing is a guild-master action, made while looking at the diff.

### 2.5 — the failure policy, which the CLI runs for you

You do not implement any of this; you read it off the directive and keep going:

- **Task fails** → the shift retries it **once**, with a fresh agent instance (same ticket,
  same member — the matcher is deterministic and re-picking would silently route work to the
  roster's second choice). It sets the node back to `pending`; you dispatch it again.
- **Still failing** → the node stays `failed`, its ticket is failed with it, and the shift
  moves on. The dead branch holds only its own successors.
- **No eligible agent** → the ticket is marked `blocked` and the shift moves on. It surfaces
  as a roster gap in `guild brief`. Do not improvise a substitute member.
- **A retry costs nothing from the task budget** — the budget counts distinct graph nodes
  moved, and a retried node was already counted.

Between turns, show **one line** and nothing more:

```
REQ-007 batch 2/5 done — implement.migrations (developer) — committed 9f2c1ab
```

## Step 3 — the stop, and its reason

**Surface the reason first, before anything else.** It is the single most useful sentence in
the morning, and every exit writes it to `event` so the record and your narration agree.

| Reason | What it means | What you say |
|---|---|---|
| `gate` | a decision is waiting | **This is the shift succeeding.** Go to Step 4. |
| `infrastructure` | two steps in a row moved no node | Something dispatched and never reported back. Name `guild graph REQ-NNN` and `guild bounties`. |
| `max-tasks` / `max-minutes` | the ceiling the user set | A ceiling, not a fault. Offer a longer shift. |
| `idle` | nothing runnable, no gate waiting | The board is out of work a shift may take. Not "all done" — check `guild bounties` for blocked work. |
| `collision` | two slices wrote the same file | The tree was left untouched **on purpose**. This one is theirs to reconcile. |
| `operator` | you or the user ended it | Nothing to explain. |

`gate` outranks the ceilings deliberately: if both are true at once, "a decision is waiting" is
actionable and "out of budget" is noise.

If the user comes back mid-shift and wants it over:

```bash
"$GUILD" shift --end --reason operator
```

## Step 4 — at a gate: stop, present, and **never decide**

A gate is the one thing a shift can never do, and the reason is structural: subagents cannot
call `AskUserQuestion`, so a generated workflow physically cannot ask anything. That is not a
limitation to work around — it is what makes unattended operation safe.

**Never approve on the guild master's behalf. Not "the obvious ones", not "the trivial ones",
not "to keep the shift going".** If you find yourself reasoning about which findings they
would probably have picked, stop.

```bash
"$GUILD" gates --pending           # <node> <req> <status> <kind> <ready|waiting> <prompt>
```

### `gate-plan` — before anything is built

This gate belongs to `guild:new-requirement`. A shift that reaches one has found a requirement
whose plan was never approved. **Do not approve it and do not build past it.** Gather and
present, then hand it back:

```bash
"$GUILD" read REQ-NNN
"$GUILD" read PLAN-NNN
"$GUILD" plan slices PLAN-NNN --files      # the disjoint-file assertion, per slice
"$GUILD" capability-requests --open        # roster gaps the architect raised at plan time
"$GUILD" graph REQ-NNN                     # the shape the plan compiles to
```

Present the plan, its slices, and **every open capability request by name** — each is a member
the architect proposed and the guild does not have, and approving the plan is also approving
the recruiting. Then say plainly: *this is yours to approve; `/guild:new-requirement` is where
it happens.* Stop.

### `gate-repairs` — after review

This one you present in full, exactly as `guild:check-in` §3.5 does. Gather everything the run
collected, write the dated review record to `.guild/reviews/REQ-NNN.md`, and put it up as
**one decision, as a MULTI-SELECT** — one option per numbered item, so the user can approve
some, all, or none:

```
REQ-007 — Session-backed authentication: the run is complete.

  4 reviewers, 3 findings:
    1. [security]     Unsigned callback token accepted          (major)
    2. [edge-case]    Empty session id is not rejected          (major)
    3. [architecture] Auth service reaches into the route layer (minor)
  2 bugs filed during the run:
    4. BUG-004 critical  Preference toggles silently revert after save
  1 failed task:
    5. TASK-013 Migrate legacy preference rows — migration is not idempotent

  Report: .guild/reviews/REQ-007.md

Findings and bugs from REQ-007 — approve which get repaired.
```

Then, and only then, with their answer in hand:

```bash
"$GUILD" gate REQ-NNN/gate-repairs --approve --decision "1,2,4 — {their words}"
```

`--decision` is mandatory here and the CLI enforces it — the decision *is* the fan-out.
`--decision none` is how they approve and repair nothing. Pass their own words through.

**If the user is not there when the gate arrives, the shift is over.** Present it in your
final message, notify (below), and stop. Do not hold the session open waiting.

## Step 5 — the report

```bash
"$GUILD" shift-report
```

This is the morning read, and it is a different question from the brief:

- **`guild brief`** — *where does the project stand.* Direction, what is in flight, what is
  blocked, what is open to claim, bugs, coverage due. Its spine is the board, as it is now.
- **`guild shift-report`** — *what happened while I was away.* Which shifts ran and how each
  one ended, what they finished, what failed and was retried, what they left blocked, what
  they filed and committed, which gates are waiting, and **why it stopped**. Its spine is the
  shift. Its window defaults to where the last shift began, not to the last check-in.

The rule for keeping them apart: **the brief reports state, the report reports events.** If an
answer does not change when a shift runs, it belongs in the brief. Run both if the user wants
the whole picture; do not paraphrase one from the other.

`--since YYYY-MM-DD` widens the window to several shifts. `--json` carries the same rows with
the clipped values intact. Both read only and write nothing.

Narrate it the way `guild:brief` narrates: the stop reason first, then what got done, then the
decisions waiting, then what you would do next. Name things — "TASK-013 failed twice and was
given up on; its edits are quarantined in `.guild/backup-revert-TASK-013-…`" is a briefing;
"1 failure" is not.

## Arming it on a cadence — opt-in, per project

A shift is one loop; a cadence is what makes it a night's work. Both of these arm **this
skill**, not the CLI — `guild shift` alone cannot dispatch an agent, so a bare cron entry
calling it would spin and stall.

```
/loop 10m /guild:shift              # this session, on an interval
```

or a scheduled agent (the `schedule` skill) that runs `/guild:shift` on a cron expression.

**Only set one up when the user asks for it, and only for the project they asked about.** Say
what it will do and how it stops: each run works until the next gate, the budget applies per
run, and a gate arrival ends the run rather than pausing it. Tell them how to disarm it in the
same breath.

## Notifications — the one moment a shift genuinely needs a human

A gate is that moment. Nothing else is.

**Opt-in per project.** The marker is a file, so it is a fact and not a memory:

```bash
[ -f .guild/shift.notify ] && echo "notifications on"
```

Create it only when the user says yes, with the one line they agreed to inside it. Absent
means **never notify**.

When it exists, send **PushNotification** on exactly two events:

- **a gate arrived** (`stop`, reason `gate`) — the one moment the shift genuinely needs them;
- **an abnormal stop** — `infrastructure` or `collision`, because both mean the night ended
  early and something is wrong.

One line, under 200 characters, leading with what they would act on:

> `REQ-007 repairs gate ready — 3 findings, 2 bugs, 1 failed task. 5 tasks done, 42 min.`

Never notify on `max-tasks`, `max-minutes`, `idle`, `operator`, or on any per-task progress. A
shift that pushes for every event trains the user to mute it, and then the gate notification —
the one that mattered — arrives silenced.

## Rules

1. **Never decide a gate.** Not `gate-plan`, not `gate-repairs`, not "the obvious ones". The
   CLI refuses to do it for you and so should you.
2. **Never push, never commit to the default branch, never rewrite history.** `guild git` has
   no verb for any of it; do not reach around it with a bare `git` call.
3. **The budget is fixed when the shift opens.** Pass the same values every turn. If you want
   a different ceiling, `--end` the shift and open a new one, and say why.
4. **One `guild shift` per turn, one batch per segment read.** Never queue a whole segment
   blind, and never call `guild shift` twice in a row hoping for a different answer.
5. **A failure does not stop the run and does not wake the user.** It is collected and judged
   at `gate-repairs`. The exceptions are exactly two: a file collision, and a failure that
   leaves the whole requirement with nothing runnable.
6. **Record both halves, always** — the ticket and the node. A node left `running` silently
   stalls everything behind it, and at 3am there is nobody to notice.
7. **Never improvise a member.** If `guild match` exits 1, the ticket is a roster gap; the
   shift blocks it and moves on. Creating an agent is a guild-master decision (`§5.4`).
8. **Never change direction.** No `goal`, no `phase`, no `priority`, no `retitle` of somebody
   else's work. A shift executes the plan; it does not edit it.
9. **Every mutation goes through the CLI.** Never touch `.guild/guild.db` or
   `.guild/journal.ndjson`, and never hand-edit a file under `.guild/export/` — it is
   regenerated.
10. **End with the reason and the report.** The last thing you say is why the shift stopped
    and what is waiting, not a list of everything that went right.
