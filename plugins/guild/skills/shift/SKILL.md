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
version: 5.0.0
user-invocable: true
allowed-tools: Bash(tursodb *), Bash(git *)
---

# Guild Shift — working the board while you are away

**Run until the next gate, then stop and notify.**

That one sentence is the whole design. A requirement's work is cut into *segments* by its two
gates, and a segment is by definition everything that can run without asking anyone anything.
So the segment boundary and the stop boundary are the same line, and an unattended shift needs
no separate notion of "how far may it go" — it goes to the next gate. Then it stops, records
why, and waits.

**Load `guild:warehouse` before the first turn.** Every query on this page is raw SQL against
`.guild/guild.db`, and the six rules in that skill — hex transport, `PRAGMA foreign_keys`, never
parsing `-m list` positionally, reading views instead of re-deriving them, `RETURNING` on every
mutation, errors arriving on stdout — apply to every one of them. At 3am there is nobody to
notice a swallowed error.

This skill is `guild:check-in` with the human taken out of the middle. **The dispatch protocol is
unchanged and is not restated here** — how a batch is run, how an agent is spawned, and how a
result is recorded all live in `guild:check-in`, and you follow it exactly. What a shift adds is
a budget, a failure policy that never stops to ask, a commit per completed task, and a hard stop
at the gate.

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
| Append to `work_log` and `review_finding` | Push to a remote |
| Commit per completed task, on `guild/REQ-NNN` | Commit to the default branch |
| | Change goals, projects or priorities |
| | Create a guild member |

**The asymmetry is the point: an unattended guild can do work and record problems, but every
judgment call waits for the guild master.**

> **In v5 not one row of that table is enforced by anything.** The old CLI locked four of these
> doors in code — `guild node` refused a gate node, `guild git` had no `push` verb. That CLI is
> gone. SQL has no identity, `git` has no allowlist, and `guild_state.actor` is a label anyone
> can write. **Every line above is now a promise you keep, not a guard that catches you.** Read
> the table before each shift, and when you catch yourself reasoning toward an exception, that
> is the moment the table exists for.

## Step 1 — preflight

```bash
export PATH="$HOME/.turso:$PATH"
[ -f .guild/config.yaml ] || echo "no guild here"
q() { printf '%s\n' "$1" | tursodb -q -m list .guild/guild.db; }
```

`-m list`, always. The default `pretty` mode boxes the output and **truncates long values with
an ellipsis** — a clipped gate prompt at 3am is a decision presented wrong.

No guild → say so and stop. `/guild:check-in` initializes one.

Then read the board. Three questions, one script, **nothing written**:

```sql
-- is a decision already waiting?
SELECT node_id, requirement_id, node_key, kind FROM v_gates_pending;

-- is a shift already open? (a crashed shift is a `started` with no `ended`)
SELECT eo.subject_id, eo.ts, eo.payload FROM event eo
 WHERE eo.subject_type = 'shift' AND eo.verb = 'started'
   AND NOT EXISTS (SELECT 1 FROM event ec
                    WHERE ec.subject_type = 'shift' AND ec.verb = 'ended'
                      AND ec.subject_id = eo.subject_id)
 ORDER BY eo.ts DESC, eo.id DESC LIMIT 1;

-- what would this shift pick up? — THE CANDIDATE QUERY, restated in full at Step 2.1
SELECT r.id, r.priority FROM requirement r
 WHERE r.status <> 'done'
   AND EXISTS (SELECT 1 FROM graph_node g WHERE g.requirement_id = r.id)
 ORDER BY r.priority, r.id;
```

- **A gate is already pending** → there is no shift to work. Present that gate (Step 4) and
  stop. Starting a shift that ends on its first turn wastes a night.
- **A shift is already open** → you are resuming it. Its budget is the one recorded in that
  `started` payload; do not open a second one and do not re-ask the budget.
- **No candidate has ready work** → say so and stop. An idle shift ends idle rather than
  inventing work, and **a shift never starts an inspection** — that is `guild:qa`, deliberately
  manual-trigger-only because a full inspection runs the real product.

**Agree the budget before the first turn.** Defaults are **10 tasks** and **60 minutes**. If the
user did not name one, use **AskUserQuestion** once — how long, how many tasks — then never ask
again. The budget is **fixed when the shift opens**; a ceiling you can raise from inside the loop
is not a ceiling.

Optional scope: pin the shift to one requirement when the user names one. Otherwise let it work
the board's own order.

### Open the shift

Two writes, and they are the **only** hand-written `event` rows in the whole guild. Everything
else in `event` is trigger-written; these two are append-only, never updated, never deleted, and
they exist because §8.5 of the design asks that a whole shift be reconstructible from the log.

```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'orchestrator' WHERE key = 'actor';

INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'orchestrator', 'started', 'shift',
       'SHIFT-' || strftime('%Y%m%dT%H%M%SZ','now'),
       json_object('max_tasks', 10, 'max_minutes', 60, 'requirement', NULL)
 WHERE NOT EXISTS (SELECT 1 FROM event eo
                    WHERE eo.subject_type = 'shift' AND eo.verb = 'started'
                      AND NOT EXISTS (SELECT 1 FROM event ec
                                       WHERE ec.subject_type = 'shift' AND ec.verb = 'ended'
                                         AND ec.subject_id = eo.subject_id))
RETURNING subject_id, ts, payload;
```

`WHERE NOT EXISTS (…)` is what makes a second invocation **resume** rather than open a rival
shift. Zero rows back means one was already open — read it, and use its budget.

The mutable scratch state that is not memory goes in `guild_state`, where mutable things belong:

```sql
INSERT INTO guild_state (key, value) VALUES ('shift:used', '0')
ON CONFLICT(key) DO UPDATE SET value = excluded.value;
INSERT INTO guild_state (key, value) VALUES ('shift:stall', '0')
ON CONFLICT(key) DO UPDATE SET value = excluded.value;
```

## Step 2 — the loop

One turn is: **pick a requirement → run one batch → record → re-evaluate the stop reason.**
Never queue a whole segment blind, and never run two batches on one turn.

### 2.1 — which requirement, and is there work in it

This is the candidate query, and §8.1's pick-up order is the `tier` column: **tier 1** is a
`standard` build graph, which a shift may start cold; **tier 2** is anything else — a
`maintenance` inspection, a project's own template — which a shift may only *continue*, never
start. The default for an unknown template is the cautious one on purpose.

```sql
SELECT r.id, r.priority,
       COALESCE((SELECT gs.value FROM guild_state gs
                  WHERE gs.key = 'graph-template:' || r.id), '') AS template,
       (SELECT COUNT(*) FROM v_ready_nodes n
         WHERE n.requirement_id = r.id AND n.kind = 'work'
           AND NOT EXISTS (SELECT 1 FROM task tb WHERE tb.id = n.task_id
                            AND tb.status IN ('blocked','failed')))          AS ready_work,
       (SELECT COUNT(*) FROM graph_node g WHERE g.requirement_id = r.id
          AND g.kind <> 'gate' AND g.status = 'running')                     AS running,
       (SELECT COUNT(*) FROM graph_node g WHERE g.requirement_id = r.id
          AND g.kind <> 'gate' AND g.status = 'failed')                      AS failed,
       CASE WHEN COALESCE((SELECT gs.value FROM guild_state gs
                            WHERE gs.key = 'graph-template:' || r.id), '') = 'standard'
            THEN 1 ELSE 2 END                                                AS tier
  FROM requirement r
 WHERE r.status <> 'done'
   AND EXISTS (SELECT 1 FROM graph_node g WHERE g.requirement_id = r.id)
   AND (COALESCE((SELECT gs.value FROM guild_state gs
                   WHERE gs.key = 'graph-template:' || r.id), '') = 'standard'
        OR EXISTS (SELECT 1 FROM graph_node g
                    WHERE g.requirement_id = r.id AND g.status <> 'pending'))
 ORDER BY tier, r.priority, r.id;
```

Take the **first row with `ready_work > 0`**. If the user pinned a requirement, add
`AND r.id = 'REQ-NNN'`. If no row has ready work, go to Step 3 — the shift is over.

**The ticket filter is not an optimization.** A node whose bounty is `blocked` or `failed` is
ready by the graph's rules and unrunnable in fact — exactly the state the roster-gap rule
creates. Counting it would make the shift select the same requirement, emit the same directive,
and spin all night.

### 2.2 — the branch, once per requirement

```bash
git rev-parse --is-inside-work-tree                       # a repo at all?
git status --porcelain                                    # MUST be empty
git rev-parse --abbrev-ref HEAD
git switch -c "guild/REQ-NNN" 2>/dev/null || git switch "guild/REQ-NNN"
```

**If `git status --porcelain` prints anything the shift did not itself create, stop the shift**
(reason `operator`) and say what is dirty. `git switch` drags uncommitted changes onto the new
branch, and a guild master's work-in-progress must never be swept into a shift. Do not stash, do
not commit it, do not "clean up".

**The default branch is off limits.** Resolve it once and never commit while it is checked out:

```bash
git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' \
  || git config --get init.defaultBranch || echo main
```

**The git allowlist for a shift is exactly this:** `status`, `rev-parse`, `symbolic-ref`,
`branch`, `switch`, `diff`, `log`, `add -- <paths>`, `commit`, `checkout -- <paths>`.
Nothing else. Specifically **never** `push`, `fetch`, `pull`, `remote`, `rebase`, `reset`,
`stash`, `tag`, `cherry-pick`, `filter-branch`, or any `-f`/`--force` anything. There is no
wrapper enforcing that list any more — it is enforced by you reading it.

### 2.3 — the segment, and the dispatch

Read what runs, one batch at a time. `v_ready_nodes` is the definition of ready; do not
re-derive it.

```sql
SELECT id, node_key, kind, task_id, parallel_group
  FROM v_ready_nodes
 WHERE requirement_id = 'REQ-NNN' AND kind = 'work'
 ORDER BY id;
```

Nodes sharing a `parallel_group` are **one batch** and dispatch together. Take batch 1 and only
batch 1. Never widen a batch, never merge two, never re-order them.

Then follow `guild:check-in`'s dispatch protocol verbatim: resolve the member with
`v_task_top_agent`, move the ticket and the node in that order, spawn with the Agent tool, and
record both halves when it returns.

```sql
-- claim, then run the node. Two writes; the ticket first.
UPDATE task SET status = 'in-progress', claimed_by = 'developer',
                claimed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE id = 'TASK-001' AND status = 'todo' RETURNING id, status, claimed_by;

UPDATE graph_node SET status = 'running', task_id = 'TASK-001'
 WHERE id = 'REQ-001/implement.auth' AND status IN ('pending','ready')
RETURNING id, status;
```

Two things change because nobody is watching:

- **`NEEDS INPUT:` cannot be answered.** No subagent can reach the user and neither can you at
  3am. Treat the pause as a **failure of that node** — fail the ticket, fail the node, and log
  the questions to `work_log` so they are in the record. They surface at `gate-repairs`.
  **Never answer on the user's behalf.**
- **A parallel file collision stops the shift.** `guild:check-in` files a bug and keeps going; a
  shift may not. Two tickets writing the same file means the architect's disjoint-file assertion
  in `task.files` was wrong, and reconciling a tree nobody is watching is not safely
  automatable. File the bug, fail the batch's nodes, **leave the tree exactly as it is**, and end
  the shift with reason `collision`.

### 2.4 — git, per completed task

One commit per completed task is what makes a bad overnight run bisectable and revertible task
by task, and the commit log a second record of the shift beside the `event` feed.

```bash
# on done — commit ONLY that task's files (its own `task.files` list)
git add -- src/lib/auth.ts src/routes/login/+page.server.ts
git commit -m "$(printf 'feat(auth): session-backed login\n\nGuild-Task: TASK-001\nGuild-Requirement: REQ-001\n')"
```

Stage the ticket's declared `files` by path. Fall back to `git add -A` **only** when no other
finished task of this requirement is uncommitted — otherwise the diff is mis-attributed to
whichever task happened to commit first.

```bash
# on failed — quarantine the partial edits, never delete them
mkdir -p ".guild/backup-revert-TASK-001-$(date -u +%Y%m%dT%H%M%SZ)"
git diff -- <that task's paths> > ".guild/backup-revert-TASK-001-<ts>/partial.diff"
git checkout -- <that task's paths>
```

Untracked files that task created are **moved** into the quarantine directory, not removed.
Nothing is committed for a failed task, and its partial edits leave the tree before the next
bounty starts, so one bad task cannot contaminate the next.

**It never pushes.** Publishing is a guild-master action, made while looking at the diff.

### 2.5 — the failure policy

Nothing runs this for you now. These are three rules you apply yourself, each with its own SQL.

**Task fails → retry it once, with a fresh agent instance.** Same ticket, same member — the
matcher is deterministic and re-picking would silently route work to the roster's second choice.
The retry marker is a `work_log` line whose text *begins* `Shift retry`, the same
prefix-as-marker convention `Skipped by user` already uses:

```sql
-- has this shift already retried this ticket?
SELECT COUNT(*) FROM work_log
 WHERE task_id = 'TASK-001' AND entry LIKE 'Shift retry%'
   AND ts >= (SELECT ts FROM event WHERE subject_type = 'shift' AND verb = 'started'
                AND subject_id = 'SHIFT-…');

-- no → record the retry and put the node back
INSERT INTO work_log (task_id, ts, agent, entry)
SELECT t.id, strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'orchestrator', CAST(x'<hex>' AS TEXT)
  FROM task t WHERE t.id = 'TASK-001';
UPDATE task SET status = 'todo', claimed_by = NULL, claimed_at = NULL
 WHERE id = 'TASK-001' AND status = 'failed' RETURNING id, status;
UPDATE graph_node SET status = 'pending'
 WHERE id = 'REQ-001/implement.auth' AND status = 'failed' RETURNING id, status;
```

**Still failing → give up on that branch and move on.** The node stays `failed`, its ticket is
failed with it, and the shift continues with the requirement's other independent work. A `failed`
node holds only its own successors, which is exactly right: the dead branch stops, the rest runs.

**No eligible agent → block the ticket and move on.** A read never does this; it is a decision:

```sql
UPDATE task SET status = 'blocked'
 WHERE id = 'TASK-014' AND status = 'todo'
   AND NOT EXISTS (SELECT 1 FROM v_agent_eligible e WHERE e.task_id = 'TASK-014')
   AND COALESCE(agent, '') = ''
RETURNING id, status;
```

It surfaces as a roster gap in `v_roster_gaps` and `v_blocked_tasks`, and **`blocked` holds the
review gate on purpose** — a roster gap should be loud. Do not improvise a substitute member;
creating an agent is a guild-master decision.

**A retry costs nothing from the task budget**, because the budget counts distinct graph nodes
this shift moved and a retried node was already counted.

Between turns, show **one line** and nothing more:

```
REQ-007 batch 2/5 done — implement.migrations (developer) — committed 9f2c1ab
```

### 2.6 — the stop check, at the end of every turn

```sql
-- tasks spent: DISTINCT graph nodes moved since the shift opened
SELECT COUNT(*) AS used FROM (
  SELECT em.subject_id FROM event em
   WHERE em.subject_type = 'graph_node' AND em.verb = 'moved'
     AND em.ts >= (SELECT ts FROM event WHERE subject_type = 'shift' AND verb = 'started'
                     AND subject_id = 'SHIFT-…')
   GROUP BY em.subject_id);

-- minutes spent
SELECT CAST((julianday('now') - julianday(
         (SELECT ts FROM event WHERE subject_type = 'shift' AND verb = 'started'
            AND subject_id = 'SHIFT-…'))) * 1440 AS INTEGER) AS minutes;

-- is any gate waiting?
SELECT COUNT(*) FROM v_gates_pending;

-- is any DRAFTED PLAN waiting on a person? A plan with no gate node behind it stops the
-- shift for the same reason a gate does — only a human can rule on it — and nothing else
-- in this loop would ever surface it.
SELECT COUNT(*) FROM v_plans_pending_approval;
```

**The stall detector.** Compare `used` with `guild_state['shift:used']` from the previous turn.
Same number means nothing moved between them and the loop is spinning; **two in a row ends the
shift as `infrastructure`.** Two rather than one, because one is reachable honestly — a turn
whose whole contribution was a retry moves no node. Then write both keys back:

```sql
UPDATE guild_state SET value = '<the used count you just read>' WHERE key = 'shift:used';
UPDATE guild_state SET value = '<0, or the previous stall + 1>' WHERE key = 'shift:stall';
```

Both are integers you computed, so they may be quoted literals. Write them **every turn**,
including the turns where nothing changed — a stall counter that is only written when it
increments never decrements.

**Stop on the FIRST of these, in this precedence:**

| # | Reason | Condition |
|---|---|---|
| 1 | `gate` | no candidate has ready work **and** `v_gates_pending` or `v_plans_pending_approval` is non-empty |
| 2 | `infrastructure` | the stall counter reached 2 |
| 3 | `max-tasks` | `used >= max_tasks` |
| 4 | `max-minutes` | `minutes >= max_minutes` |
| 5 | `idle` | no candidate has ready work and no gate is waiting either |
| 6 | `collision` | two tickets wrote the same file — only you can see this |
| 7 | `operator` | the user ended it |

`gate` outranks the ceilings deliberately: if both are true at once, "a decision is waiting" is
actionable and "out of budget" is noise. A pending **plan approval** counts as a gate here even
when no `gate` row exists for it — the shift cannot rule on a plan any more than it can decide
a gate, so name the plan in the stop report exactly as you would name the gate. `infrastructure` outranks them too, because a stalled
loop reported as `max-tasks` is a lie that costs a whole night — it would say the shift did its
ten when in fact it did nothing ten times.

## Step 3 — the stop, and its reason

**Surface the reason first, before anything else.** It is the single most useful sentence in the
morning. Close the shift with the second and last hand-written event:

```sql
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'orchestrator', 'ended', 'shift',
       eo.subject_id,
       json_object('reason', 'gate', 'note', CAST(x'<hex>' AS TEXT),
                   'tasks', 5, 'minutes', 42, 'requirement', 'REQ-007')
  FROM event eo
 WHERE eo.subject_type = 'shift' AND eo.verb = 'started'
   AND NOT EXISTS (SELECT 1 FROM event ec
                    WHERE ec.subject_type = 'shift' AND ec.verb = 'ended'
                      AND ec.subject_id = eo.subject_id)
 ORDER BY eo.ts DESC, eo.id DESC LIMIT 1
RETURNING subject_id, payload;
```

`reason` comes from the closed vocabulary above and nowhere else — `guild:brief` and the morning
report both read it back, and a reason one surface writes and another cannot read is worse than
no reason at all.

| Reason | What you say |
|---|---|
| `gate` | **This is the shift succeeding.** Go to Step 4. |
| `infrastructure` | Something dispatched and never reported back. Name the requirement and the nodes left `running`. |
| `max-tasks` / `max-minutes` | A ceiling, not a fault. Offer a longer shift. |
| `idle` | The board is out of work a shift may take. Not "all done" — read `v_blocked_tasks`. |
| `collision` | The tree was left untouched **on purpose**. This one is theirs to reconcile. |
| `operator` | Nothing to explain. |

## Step 4 — at a gate: stop, present, and **never decide**

A gate is the one thing a shift can never do, and the reason is structural: subagents cannot call
`AskUserQuestion`, so a generated workflow physically cannot ask anything. That is not a
limitation to work around — it is what makes unattended operation safe.

**Never approve on the guild master's behalf. Not "the obvious ones", not "the trivial ones",
not "to keep the shift going".** If you find yourself reasoning about which findings they would
probably have picked, stop.

```sql
SELECT node_id, requirement_id, node_key, kind, prompt FROM v_gates_pending;
SELECT id, requirement_id, status, gate_node_id, title FROM v_plans_pending_approval;
```

The second query is not redundant. A plan can be waiting on a person with **no gate row behind
it** — approved in conversation on a small change, or a `gate_node_id` never linked — and the
first query cannot see it. Present both lists.

### `gate-plan` — before anything is built

This gate belongs to `guild:new-requirement`. A shift that reaches one has found a requirement
whose plan was never approved. **Do not approve it and do not build past it.** Gather and
present, then hand it back:

```sql
SELECT body FROM requirement WHERE id = 'REQ-NNN';          -- one column: byte-exact
SELECT body FROM plan WHERE requirement_id = 'REQ-NNN';
SELECT json_object('task', id, 'group', COALESCE(parallel_group,''), 'files', files)
  FROM task WHERE requirement_id = 'REQ-NNN' AND node_key = 'implement';
SELECT id, capability, proposed_agent, rationale FROM capability_request WHERE status = 'open';
SELECT id, node_key, kind, status FROM graph_node WHERE requirement_id = 'REQ-NNN' ORDER BY id;
```

Present the plan, its tickets and their file sets, and **every open capability request by name** — each is a member
the architect proposed and the guild does not have, and approving the plan is also approving the
recruiting. Then say plainly: *this is yours to approve; `/guild:new-requirement` is where it
happens.* Stop.

### `gate-repairs` — after review

Present this one in full, exactly as `guild:check-in` does. Gather everything the run collected:

```sql
SELECT id, task_id, reviewer, severity, disposition, file, line, summary FROM v_open_findings;
SELECT id, severity, status, found_by, requirement_id, title FROM v_open_bugs;
SELECT id, who, waived, replace(replace(COALESCE(reason,'-'), char(10),' '), '|','!'), title
  FROM v_failed_tasks;
```

Write the dated review record to `.guild/reviews/REQ-NNN.md`, then put it up as **one decision,
as a MULTI-SELECT** — one option per numbered item, so the user can approve some, all, or none:

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

Then, and only then, with their answer in hand — **two writes, always**, because setting
`gate.status` does not move the node:

```sql
UPDATE gate SET status = 'approved',
                decision = CAST(x'<hex-their-words>' AS TEXT),
                decided_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE node_id = 'REQ-007/gate-repairs' AND status = 'pending' RETURNING node_id, status;

UPDATE graph_node SET status = 'done'
 WHERE id = 'REQ-007/gate-repairs'
   AND (SELECT g.status FROM gate g WHERE g.node_id = graph_node.id) = 'approved'
RETURNING id, status;
```

The decision **is** the fan-out, so it is never blank — `none` is how they approve and repair
nothing. Pass their own words through.

**If the user is not there when the gate arrives, the shift is over.** Present it in your final
message, notify, and stop. Do not hold the session open waiting.

## Step 5 — the morning report

This is a different question from the brief:

- **`guild:brief`** — *where does the project stand.* Its spine is the board, as it is now.
- **this report** — *what happened while I was away.* Its spine is the shift, and its window is
  where the last shift began, not the last check-in.

The rule for keeping them apart: **the brief reports state, the report reports events.**

```sql
-- the shifts themselves, newest first
SELECT json_object('shift', subject_id, 'ts', ts, 'verb', verb, 'payload', payload)
  FROM event WHERE subject_type = 'shift' ORDER BY ts DESC, id DESC LIMIT 20;

-- everything that moved during the last shift
SELECT json_object('ts', ts, 'actor', actor, 'verb', verb, 'type', subject_type,
                   'subject', subject_id, 'title', subject_title, 'phrase', phrase)
  FROM v_recent_activity
 WHERE ts >= (SELECT ts FROM event WHERE subject_type = 'shift' AND verb = 'started'
               ORDER BY ts DESC, id DESC LIMIT 1)
 ORDER BY ts DESC;

-- and what it left behind
SELECT * FROM v_failed_tasks;
SELECT id, requirement_id, status, who, reason FROM v_blocked_tasks ORDER BY id;
SELECT node_id, requirement_id, node_key, kind FROM v_gates_pending;
SELECT id, requirement_id, gate_node_id, title FROM v_plans_pending_approval;
```

Narrate stop reason first, then what got done, then the decisions waiting, then what you would do
next. **Name things** — "TASK-013 failed twice and was given up on; its edits are quarantined in
`.guild/backup-revert-TASK-013-…`" is a briefing. "1 failure" is not.

## Step 6 — verify against §12, and put it in the report

Run `guild:validate shift` before the morning report goes out, and fold the result into it.
§12 of `docs/expectations.md` matters more than any other section: **in v5 the CLI locked
four of these doors in code, and that CLI is gone.** §12.a asserts you stopped at a gate and
never past one, §12.b what you never touched, §12.c the failure policy, §12.d that a blocked
ticket became a roster gap rather than a silent skip, §12.e that every stop said why, and
§12.f the git safety checks — never pushed, never on the default branch. The assertions run
*after* the night, not during it, so a failure here is something the user reads at breakfast.
**Report every one with its rows, before the summary.**

## Arming it on a cadence — opt-in, per project

A shift is one loop; a cadence is what makes it a night's work. Both of these arm **this skill**.

```
/loop 10m /guild:shift              # this session, on an interval
```

or a scheduled agent (the `schedule` skill) running `/guild:shift` on a cron expression.

**Only set one up when the user asks, and only for the project they asked about.** Say what it
will do and how it stops: each run works until the next gate, the budget applies per run, and a
gate arrival ends the run rather than pausing it. Tell them how to disarm it in the same breath.

## Notifications — the one moment a shift genuinely needs a human

A gate is that moment. Nothing else is.

**Opt-in per project.** The marker is a file, so it is a fact and not a memory:

```bash
[ -f .guild/shift.notify ] && echo "notifications on"
```

Create it only when the user says yes, with the one line they agreed to inside it. Absent means
**never notify**.

When it exists, send **PushNotification** on exactly two events: **a gate arrived** (stop reason
`gate`), and **an abnormal stop** (`infrastructure` or `collision`, because both mean the night
ended early and something is wrong). One line, under 200 characters, leading with what they would
act on:

> `REQ-007 repairs gate ready — 3 findings, 2 bugs, 1 failed task. 5 tasks done, 42 min.`

Never notify on `max-tasks`, `max-minutes`, `idle`, `operator`, or on per-task progress. A shift
that pushes for every event trains the user to mute it, and then the gate notification — the one
that mattered — arrives silenced.

## Rules

1. **Never decide a gate.** Not `gate-plan`, not `gate-repairs`, not "the obvious ones". Nothing
   refuses this for you any more.
2. **Never push, never commit to the default branch, never rewrite history.** The git allowlist
   in §2.2 is the whole of what a shift may run.
3. **The budget is fixed when the shift opens.** It lives in the `started` event's payload. If
   you want a different ceiling, end the shift and open a new one, and say why.
4. **One requirement, one batch, per turn.** Never queue a whole segment blind.
5. **A failure does not stop the run and does not wake the user.** It is collected and judged at
   `gate-repairs`. Exactly two exceptions: a file collision, and a failure that leaves the whole
   requirement with nothing runnable.
6. **Record both halves, always** — the ticket and the node. A node left `running` silently
   stalls everything behind it, and at 3am there is nobody to notice.
7. **Never improvise a member.** No eligible agent means the ticket is a roster gap; block it and
   move on.
8. **Never change direction.** No `goal`, no `project`, no `priority`, no retitling somebody else's
   work. A shift executes the plan; it does not edit it.
9. **`started` and `ended` are the only `event` rows you write by hand,** and they are never
   updated or deleted. Everything else in `event` is the triggers' to write.
10. **End with the reason and the report**, not a list of everything that went right.
