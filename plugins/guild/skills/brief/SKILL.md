---
name: brief
description: >
  This skill should be used when the user asks for "guild status", "board status",
  "what's the status", "show the board", "what's on the board", "project status",
  "show guild", "guild board", "what's happening", "brief me", "guild brief",
  "where are we", "what changed", "what moved since last time", "what should I
  work on next", or any read-only request for the state of the guild. Narrates a
  real briefing — direction, what is in flight, the open bugs, which tickets
  failed and why, the unresolved review findings, what moved since the last
  check-in, and what to do next — without starting a work session.
version: 5.2.0
user-invocable: true
---

# Guild Brief — the narrated read of the board

Read-only. This skill **reports**; it never dispatches an agent, never moves a task, and
never writes to the board. If the user wants work to start, that is `guild:check-in`.

It replaces v4's `guild-status`, which listed directories. `guild brief` answers the whole
check-in question in one query, and your job is to turn the sections it prints into a
briefing a human can act on. `guild:check-in` opens with this same command, so what you
write here is what the daily flow reads too.

## Step 1 — is there a guild?

`.guild/config.yaml` is what marks a v5 guild (there is no `state.yaml`).

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
[ -f .guild/config.yaml ] || echo "no guild here"
```

If it is missing, say exactly this and stop:

```
No guild board found. Run /guild:check-in to initialize and start your first work session.
```

## Step 2 — run the brief

```bash
"$GUILD" brief
```

Optional flags, used only when the user asks for them:

| Flag | When |
|------|------|
| `--since YYYY-MM-DD` | The user names a window ("what changed this week?"). Without it the cutoff is the recorded `last-checkin`. |
| `--json` | You need a value the text surface clips or omits — a finding's full `detail` paragraph, a bug's `created_at` — or you are feeding another tool. Same query, same sections, richer rows. Prefer the text surface for narration; it is the one designed to be read. |

`guild brief` reads only. It writes no journal line and no `event` row on purpose: a brief
that logged itself would pollute the very feed its "Since Last Check-in" section reads.
`guild checkin` is the one command that moves the cutoff, and only `guild:check-in` runs it.

**One query is the whole briefing. There are no exceptions.** If a section is absent, that
is the answer (see Step 3), and you never run a second command to "check" it.

This used to be a three-row allowlist, and it existed for exactly one reason: the
`Summary:` line printed `N failed task(s)` and `N unresolved review finding(s)`, no section
below resolved either to a name, and Step 4 asks you to report both — so the skill had to
go get the names itself with `guild list task failed`, a read of `.guild/reviews/*.md`, and
`guild export --json` as a last resort. **`Failed Tasks:` and `Review Findings:` now print
those names, with the failure reason and with `file:line`,** so all three are gone. If you
find yourself reaching for one, re-read the output — what you want is in it.

Nothing follows `guild brief`: no `list`, no `export`, no `move`, no `new`, no `checkin`,
no `spool drain`, no `rebuild`, no bare `guild dashboard` (bare `export` and bare
`dashboard` write files). Never widen this to "just check one more thing".

The one legitimate reason to run something else is a question the brief genuinely does not
answer — the full body of a finding, a bug's repro steps, a clipped title in full. Those
are the user's to ask for, and Step 4's last rule tells you to **name the command** rather
than run it.

## Step 3 — read the output

The command prints a header and then only the sections that have rows.

This is a **real capture** — a guild with one goal, two phases, two requirements, seven
tasks, one critical bug, two failed tasks (one of them waived) and two review findings, run
as `guild brief` with no flags:

```
Guild Brief
===========

Generated: 2026-08-14T06:31:08Z
Since:     2026-08-14 (last check-in)
Next:      TASK-004
Summary:   2 requirement(s), 0 done · 1 in flight · 2 open bounty(ies) · 1 open bug(s) (1 critical) · 0 area(s) due for inspection · 32 event(s) since
           2 failed task(s) (1 waived) · 2 unresolved review finding(s)

Direction:
  GOAL-001  [p1 in-progress]  Ship the notifications overhaul  ·  on PHASE-002 Preferences UI  ·  0/2 req done

In Flight:
  TASK-004  Build the preferences API  ·  developer  ·  REQ-002  ·  5m

Open Bounties:
  TASK-002  Plan tests for delivery  ·  test-planner  ·  REQ-001  ·  p3
  TASK-005  Wire the preferences page  ·  developer-svelte  ·  REQ-002  ·  p3

Bugs:
  BUG-001  critical  open  Preference toggles silently revert after save  ·  found by qa-tester

Failed Tasks:
  TASK-006  [unresolved]  Migrate legacy preference rows  ·  developer  ·  REQ-002  ·  Migration aborted: 412 legacy rows have a NULL channel and violate the new NOT NULL constraint.
  TASK-007  [waived]  Backfill the notification audit table  ·  developer  ·  REQ-002  ·  Audit table does not exist in staging; blocked on the DBA ticket.

Review Findings:
  major  open  reviewer-security  on TASK-003  Unsigned callback token accepted  ·  src/queue/consume.ts:61
  minor  open  reviewer-edge-case  on TASK-003  Retry backoff overflows at 32 attempts

Since Last Check-in:
  2026-08-14T06:25:04Z  orchestrator  moved  goal GOAL-001  Ship the notifications overhaul  ·  todo → in-progress
  2026-08-14T06:25:05Z  orchestrator  moved  phase PHASE-001  Delivery worker  ·  todo → done
  2026-08-14T06:25:05Z  orchestrator  moved  phase PHASE-002  Preferences UI  ·  todo → in-progress
  2026-08-14T06:25:16Z  orchestrator  moved  task TASK-001  Build the delivery worker  ·  todo → in-progress
  2026-08-14T06:25:16Z  orchestrator  moved  task TASK-001  Build the delivery worker  ·  in-progress → done
  2026-08-14T06:25:16Z  reviewer-security  logged  task TASK-003  Review the delivery worker  ·  Verdict: CHANGES REQUESTED — 1 major.
  2026-08-14T06:25:16Z  reviewer-security  filed  task TASK-003  Review the delivery worker  ·  major: Unsigned callback token accepted
  2026-08-14T06:25:16Z  reviewer-edge-case  filed  task TASK-003  Review the delivery worker  ·  minor: Retry backoff overflows at 32 attempts
  2026-08-14T06:25:17Z  developer  logged  task TASK-006  Migrate legacy preference rows  ·  Migration aborted: 412 legacy rows have a NULL channel and violate the new NOT NULL const…
  2026-08-14T06:25:17Z  orchestrator  moved  task TASK-006  Migrate legacy preference rows  ·  in-progress → failed
  2026-08-14T06:25:18Z  orchestrator  logged  task TASK-007  Backfill the notification audit table  ·  Skipped by user on 2026-08-14 — excluded from REQ scope
  2026-08-14T06:25:18Z  orchestrator  created  bug BUG-001  Preference toggles silently revert after save  ·  {"severity":"critical","requirement_id":"REQ-002"}
  … and 7 more
```

(Only the activity block is abridged for this page — the real capture printed 25 rows before
the CLI's own `… and N more`. Everything else is verbatim.)

Read that capture for what it teaches, because it is what the surface really is:

- **`Coverage:` did not print** — this board has no coverage areas, so the section is gone
  even though the `Summary:` still reports `0 area(s) due for inspection`.
- **The activity feed carries `ts · actor · verb · subject-type · subject-id · title`, and
  then a `·` detail** — the transition for a `moved` row (`todo → in-progress`), the entry
  text for a `logged` row, `severity: summary` for a `filed` row, the payload for a
  `created` one. **You may state a from→to; it is printed.** Two consecutive
  `moved task TASK-001` lines are a status pair and the detail column is what tells them
  apart. Step 4 still asks you to **summarize by subject** rather than recite — the feed is
  now informative enough to narrate from, which is not the same as short enough to paste.
- **`actor` is whoever did it.** `orchestrator` for board moves, but `reviewer-security`,
  `qa-tester`, `developer` for the rows a `guild spool drain` folded in. Name the agent.
- **The verbs are wider than the board moves**: `created`, `moved`, `assigned`, `retitled`,
  `reprioritized`, `checked-in`, plus `logged` / `filed` (drained agent work) and
  `updated` / `inspected` (coverage). A verb you do not recognize is data, not a glitch.
- **`Failed Tasks:` separates the two meanings of `failed`.** `[unresolved]` is a failure
  nobody has adjudicated — the user still has to decide retry-or-skip, and you should raise
  it. `[waived]` is a failure the user already skipped (the orchestrator recorded it in the
  ticket's Work Log); it no longer blocks the review gate or requirement completion, so
  report it as settled, not as a risk. The last `·` clause is the ticket's most recent Work
  Log entry, which is normally the agent's own account of what went wrong — quote it. It is
  **absent** when the ticket failed before its agent logged anything, and the `(N waived)`
  in the `Summary:` line is the count of the second kind.
- **`Review Findings:` is `severity · disposition · reviewer · on TASK-NNN · summary`,**
  worst severity first, then `· file:line` when the reviewer gave a location and `· fix
  TASK-NNN` when a fix ticket is linked. This is the section that turns "2 unresolved
  findings" into a sentence: everything Step 4 asks you to state is on the line. Two
  Stage 2 caveats — `disposition` always reads `open` (nothing moves a finding to `fixing`
  yet) and `fix` never appears (no writer sets `fix_task_id`), so do not read either as
  meaningful. The finding's full **detail** paragraph is not on this surface; it is in
  `guild brief --json` under `review_findings[].detail`, and you fetch it only if asked.

**An absent section is good news stated by its absence.** No `Bugs:` block means nothing is
open. Do not announce empty categories, and do not invent a section the command did not print.

### Two sections cannot print yet — do not narrate them

`guild brief` has slots for `Blocked:` and `Roster Gaps:`, and in Stage 2 **neither can ever
have a row**:

| Section | Why it is unreachable today |
|---|---|
| `Blocked:` | Needs `status='blocked'` or a `task_dependency` row. `guild move` rejects `blocked` (`allowed: todo in-progress done failed`) and nothing writes `task_dependency` — Stage 4. |
| `Roster Gaps:` | Reads `capability_request`, which Stage 3 fills. No writer exists. |

Treat their absence as structural, not as news. Do not tell the user "nothing is blocked" —
the guild cannot currently express that anything is. When Stage 3/4 lands, they become two
more beats in Step 4's order (blocked work right after in-flight; roster gaps with risks).

Two lines are always there and always matter:

- **`Next:`** is `guild next`'s answer — the exact task the guild would hand out. It is the
  same rule the CLI uses, so never recommend a different ticket as "next" without saying
  why you are overriding it.
- **`Since:`** tells you which cutoff was used (`--since`, the last check-in, or none at
  all). "No check-in recorded" means the activity list is simply the most recent events,
  not "nothing happened".

A truncated section ends with `… and N more`; the count in `Summary:` is the real total.

On a guild with nothing on it, the command prints its own short "the guild is empty" text
with the three next steps. Relay that and stop — do not narrate around it. One of those
steps tells the user to run `guild checkin`: that is advice **for them**, at their terminal
or through `guild:check-in`, which is the only skill that stamps it. Pass it on; do not run
it.

## Step 4 — narrate it

Present a short briefing in **this order**, in prose, with the raw block available if the
user wants it. Skip any part the data does not support.

1. **Direction** — which goal the guild is serving, its priority, which phase it is on,
   and progress. If `Direction:` says no goals are declared, say so plainly and note that
   requirements are being tracked without one — that is legal, not an error.
2. **In flight** — what is being worked on and for how long. Call out anything that has
   been in flight implausibly long (days, when tasks normally take hours); an unusually old
   in-progress task is usually a crashed dispatch, not work in progress.
3. **Risks — named, never counted.** In the order the output prints them. Open bugs
   worst-severity first, every `critical` one by ID and title. Then `Failed Tasks:` — the
   `[unresolved]` ones by ID, with the reason from their last Work Log entry and the fact
   that nothing will retry them on its own; mention the `[waived]` ones once, as settled.
   Then `Review Findings:` — at least the critical/major ones, each as severity + reviewer +
   what + where. Finish with coverage areas that are overdue or never inspected. "Two
   unresolved findings" is not a briefing; "reviewer-security flagged an unsigned callback
   token at src/queue/consume.ts:61" is — and that sentence is now a copy of one line of the
   output, not something you had to go and assemble.
4. **What moved** — summarize the activity feed rather than reciting it. Name subjects, not
   timestamps: "since your last check-in, TASK-001 and TASK-002 completed, reviewer-security
   filed a major finding on TASK-003, BUG-001 was filed critical, TASK-007 failed." Each row
   carries its subject's title and, for a `moved` row, both ends of the transition — so
   state the from→to and the actor, both of which are printed. Never invent one that is not.
5. **What to do next** — a concrete recommendation, with the reason. Default to `Next:`.
   Deviate only for something the numbers justify — a critical bug with no fix task, a
   failed task nothing will retry on its own, a goal at priority 1 whose phase has no open
   work — and say which fact changed your mind.

End by offering the obvious follow-ups, once, without doing them:

> Say **check in** to start working, or **dashboard** for the visual view.

## Rules

- **Read-only, and one command.** `guild brief` is the whole skill. Nothing follows it —
  not `list`, not `export --json`, not a read of `.guild/reviews/*.md`; every count the
  briefing prints is resolved to a name by a section of the same output. Never `move`,
  `new`, `checkin`, `spool drain`, `rebuild`, bare `export` or bare `dashboard` from here —
  the last two write files — and never touch `.guild/guild.db` or `.guild/journal.ndjson`.
- **Never invent a number.** Every figure you state comes from the output. If the user asks
  something the brief does not answer, say so and name the command that would
  (`guild goal show GOAL-001`, `guild bug show BUG-002`, `guild read TASK-014`).
- **Titles are clipped, not corrupted.** Long free text is cut with `…` in this surface;
  the byte-exact value is `guild meta <ID> title`. Do not present a clipped title as if it
  were the whole thing when the difference matters.
- **Do not paste the whole block and call it a briefing.** The block is evidence; the
  narration is the deliverable. Show the raw output only if asked, or if it is short enough
  that quoting it *is* the shortest honest answer.
- **Keep it to a screen.** This is a glance, not a report.
