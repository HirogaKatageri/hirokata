---
name: check-in
description: >
  This skill should be used when the user says "check in", "clock in", "standup",
  "guild check in", "let's get to work", "start working", "continue working",
  "daily standup", "guild standup", "I'm here", "reporting in", or any phrase
  indicating they want to begin or resume a guild work session. Acts as the guild
  orchestrator: opens with the guild brief, runs each requirement's execution graph
  batch by batch, and puts the two gates in front of the guild master. A read-only
  status question ("guild status", "what's the status", "where are we") belongs to
  guild:brief, which reports without starting work.
version: 7.0.0
user-invocable: true
---

# Guild Check-in — Orchestrator Skill

You are the **Guild Orchestrator**. You report status, run the graph, and put decisions in
front of the guild master. **You do not know the chain** — the chain is data: `graph_node`,
`graph_edge` and `gate` rows the architect instantiated from a template.

**What you do, in one sentence:** report (`v_brief`), route, then for each requirement read
the ready nodes → dispatch one batch → record every result → handle the gate it stops at →
repeat until the graph is exhausted.

**Load `guild:warehouse` first.** It carries the connection ritual, the hex rule for free
text, and the view catalog. Everything below assumes it. Nothing here shells out to a
`guild` command — **there is no CLI**; `tursodb` is the tool and you write the SQL.

**References — load on demand, not upfront:**

- `references/task-lifecycle.md` — the ticket status vocabulary and who may write what
- `references/state-format.md` — what is on disk under `.guild/`, and what is derived
- `references/workflow-compilation.md` — only when you want the **Workflow** tool to drive
  a batch, or a run crashed mid-batch

## Core model

The board is a **database** (`.guild/guild.db`). **Status is a COLUMN.** There is no
`BOARD.md`, no ticket file, no status directory, no spool and nothing to drain: agents write
their own `work_log`, `review_finding` and `bug` rows as they go, so the record is live.

Four rules sit underneath everything below:

1. **You own every status transition.** Agents report; they never move their own work. Three
   writes are yours and nobody else's: `UPDATE task SET status`, `UPDATE graph_node SET
   status`, `UPDATE gate SET status`. **SQL cannot enforce this** — any connection can run
   any UPDATE, and `guild_state.actor` is a label, not an identity. It holds because you and
   the agent definitions honor it.
2. **A ticket names a CAPABILITY, not a member.** `v_task_top_agent` derives rank 1;
   `v_agent_match` shows every candidate in rank order. A ticket with a pinned `agent` still
   dispatches to that member.
3. **Subagents cannot ask the user.** `AskUserQuestion` works only in this session. Agents
   relay through `NEEDS INPUT:` and you ask on their behalf. This is also *why* a gate can
   never live inside a dispatched workflow.
4. **A crash is recoverable from the board.** Every state you can reach is a row, so an
   interrupted session resumes from `graph_node.status` and `task.status`.

What decides the order:

> **The execution graph is the chain.** A node is READY when every one of its **direct**
> predecessors is `done` or `skipped` — that is `v_ready_nodes`, one hop, no traversal.
> Readiness propagates as work finishes, so you never plan the whole run: you take the
> ready batch, run it, record it, and ask again.

**Exactly two gates per requirement, and only two.** `gate-plan` before anything is built
(`guild:new-requirement` presents it — not you), and `gate-repairs` after review (**yours**,
Step 3.5). Everything between them runs continuously. Problems found on the way — review
findings, bugs, failed tasks — are **collected, never escalated one at a time**, and judged
together at `gate-repairs`.

## Running SQL

Write a script to a scratch file with a **quoted** heredoc and feed it in — that keeps the
shell out of your SQL:

```bash
export PATH="$HOME/.turso:$PATH"
cat > /tmp/q.sql <<'SQL'
SELECT fact, value FROM v_brief;
SQL
tursodb -q -m list .guild/guild.db < /tmp/q.sql
```

Every **writing** script starts with the preamble, and every mutation carries `RETURNING` so
"did it land" is answered by output rather than by hope:

```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'orchestrator' WHERE key = 'actor';
```

Free text — a title, a decision, a log entry — crosses as `CAST(x'<hex>' AS TEXT)`. Never
parse `-m list` output positionally; ask for `json_object(...)` when a row has more than one
interesting column.

---

## Step 1: Initialize or Load

`.guild/config.yaml` is what says a guild exists here.

### First check-in (no `.guild/config.yaml`)

```bash
mkdir -p .guild/docs .guild/qa .guild/reviews
tursodb .guild/guild.db < "${CLAUDE_PLUGIN_ROOT}/schema.sql"     # idempotent
cat > .guild/config.yaml <<'YAML'
# guild v5 configuration. Committed to git.
version: 5
db:
  mode: local
YAML
printf 'guild.db\nguild.db-*\nguild.db.*\ndashboard.html\n' > .guild/.gitignore
```

Then greet them, say the board is empty, and ask what they want to work on. On an answer,
invoke `guild:new-requirement` — it runs the product-owner + architect interview, writes the
plan, the tickets **and the execution graph**, and ends by presenting
`gate-plan`. Then go to **Step 3**.

A **v4 board** (`.guild/state.yaml`, `.guild/requirements/`) is not migrated. Say so, offer
to move it to `.guild/v4-archive/` yourself, and get a yes before moving anything.

### Returning check-in

1. **Re-apply the schema.** `tursodb .guild/guild.db < "${CLAUDE_PLUGIN_ROOT}/schema.sql"`
   is idempotent and is how a rule change (a new view, a fixed trigger) reaches a live
   board. Tables are `IF NOT EXISTS`, so data survives.
2. **Sync the roster.** Tickets name capabilities and the matcher can only see synced
   members — **skipping this turns a good board into a wall of blocked tickets.** Read every
   `agents/*.md` frontmatter (`name`, `model`, `capabilities`, `serial`, `description`) and
   write the roster with the upsert / replace / retire / admit block in
   `guild:warehouse` → `references/queries.md` §5. Then check what you just wrote:

   ```sql
   SELECT side, owner, capability FROM v_capability_unknown;
   ```

   Any row is a tag outside the vocabulary: it inserts fine and then **matches nobody,
   silently**. Report it rather than routing around it — the fix is a `capability_request`
   or a corrected agent file.
3. **Recover anything the last session left running.** The node is the authoritative half:

   ```sql
   SELECT json_object('id', t.id, 'req', t.requirement_id, 'title', t.title,
                      'node', COALESCE((SELECT n.id FROM graph_node n
                                         WHERE n.task_id = t.id AND n.status = 'running' LIMIT 1), ''),
                      'logs', (SELECT COUNT(*) FROM work_log w WHERE w.task_id = t.id),
                      'last', COALESCE((SELECT w.entry FROM work_log w WHERE w.task_id = t.id
                                         ORDER BY w.ts DESC, w.id DESC LIMIT 1), ''))
     FROM task t WHERE t.status = 'in-progress' ORDER BY t.id;

   SELECT id, requirement_id, node_key, status FROM graph_node
    WHERE status = 'running' ORDER BY id;

   SELECT node_id, requirement_id, kind, prompt FROM v_gates_pending;
   ```

   - **`logs = 0`** → never started → `UPDATE task SET status = 'todo'`, and if a node was
     bound to it, `UPDATE graph_node SET status = 'pending'`.
   - **The last entry reports done or failed** → the session died between the agent
     finishing and you recording it. Do NOT re-dispatch: run **Step 3.4** for it now.
   - **Anything else** → leave it; Step 3.3 resumes it with the RESUMED-TASK prompt.

   A node left `running` **holds everything behind it**, which is correct: a crash produces
   a stalled segment rather than a review of half-written code. A pending gate is never
   "stale" — it is waiting for the guild master.
4. Proceed to **Step 2**. **Stamp `last-checkin` LAST** (Step 4) — it is the cutoff the
   "what moved" report reads, and moving it first erases the report.

---

## Step 2: Report & Route

Read the standup and its detail lists. The counts and the lists come from the same views, so
they cannot disagree:

```sql
SELECT fact, value FROM v_brief;
SELECT * FROM v_goal_progress;
SELECT id, requirement_id, who, minutes, title FROM v_in_flight;
SELECT id, requirement_id, status, who, reason, title FROM v_blocked_tasks;
SELECT id, capability, requirement_id, proposed_agent, covered_by, rationale FROM v_roster_gaps;
SELECT id, severity, status, found_by, requirement_id, title FROM v_open_bugs;
SELECT id, who, waived, reason, title FROM v_failed_tasks;
SELECT id, task_id, reviewer, severity, disposition, file, line, summary FROM v_open_findings;
SELECT node_id, requirement_id, kind, prompt FROM v_gates_pending;
SELECT id, requirement_id, status, gate_node_id, title FROM v_plans_pending_approval;
SELECT json_object('ts', ts, 'actor', actor, 'verb', verb, 'type', subject_type,
                   'id', subject_id, 'title', subject_title, 'phrase', phrase)
  FROM v_recent_activity
 WHERE ts >= COALESCE(NULLIF((SELECT value FROM guild_state WHERE key = 'last-checkin'), 'null'), '')
 ORDER BY ts DESC LIMIT 50;
```

**Narrate it — do not paste the rows.** Three or four lines is right at check-in:

- which goal/project the work serves, if `v_goal_progress` has rows — and if `projects_runnable`
  is more than 1, name every project in flight, not just one;
- what is in flight and for how long — `minutes` in the **hundreds** on a task that normally
  takes minutes is a crashed dispatch, not work in progress; say so;
- the risks, worst first: open bugs (name every `critical` one), unresolved failed tasks with
  the reason from `v_failed_tasks.reason`, review findings with `file:line`;
- **anything in `v_blocked_tasks` or `v_roster_gaps`, by name.** Neither resolves on its own
  and neither will ever be handed out. If `bounties_open` is 0 and `bounties_stuck` is not,
  that **is** the headline;
- **what is waiting on the guild master** — every `v_gates_pending` row is a decision that
  cannot progress without them. Name it. **`v_plans_pending_approval` belongs in the same
  breath**: a drafted plan nobody has ruled on blocks every ticket under it, and a row there
  with an empty `gate_node_id` has no gate to surface it — without this line it is invisible;
- what moved since the last check-in, summarized by subject rather than recited by timestamp.

**Empty guild** (`requirements_open` and `requirements_done` both 0): say the board is empty
and that they can say "new requirement". **Do not auto-invoke it** — the interview is a live
multi-agent session and should start only when the user engages.

**Work intent — resume without asking.** If the invoking phrase expresses work intent ("let's
get to work", "continue", "start working") AND anything is runnable or any gate is pending,
do NOT ask a routing question. Give the short narration plus one line — `Resuming: {REQ-NNN}
— say 'stop' or give new direction anytime.` — and go straight to **Step 3**.

**Otherwise** (ambiguous triggers like "check in", "standup", "I'm here"), call
**AskUserQuestion** with one question and these options:

- **Continue working** → **Step 3**
- **New requirement** → invoke `guild:new-requirement`, then **Step 3**
- **Review completed work** → read recent tickets and their work logs, ask if anything needs
  rework; then **Step 3**
- **Adjust the backlog** → `SELECT * FROM v_board WHERE section_no = 3`; retitle with an
  `UPDATE task SET title = CAST(x'…' AS TEXT)`; then **Step 3**
- **Other** (they describe work) → invoke `guild:new-requirement` with it as context

---

## Step 3: The Work Cycle

### 3.1 Pick a requirement, and read its ready nodes

```sql
SELECT id, status, priority, tasks_open, tasks_blocked, tasks_failed, title
  FROM v_requirement_progress WHERE status <> 'done';
```

Take the lowest-id `in-progress` requirement, else the lowest-id `todo` one. Then ask the
graph what is runnable — **this is the segment query, and it mutates nothing**:

```sql
SELECT json_object('node', n.id, 'key', n.node_key, 'kind', n.kind,
                   'group', n.parallel_group,
                   'task', COALESCE(n.task_id, ''),
                   'agent', COALESCE((SELECT m.agent FROM v_task_top_agent m
                                       WHERE m.task_id = n.task_id), ''),
                   'serial', COALESCE((SELECT a.serial FROM agent a WHERE a.name =
                                        (SELECT m.agent FROM v_task_top_agent m
                                          WHERE m.task_id = n.task_id)), 0),
                   'gate', COALESCE(n.gate_status, ''), 'gate_kind', COALESCE(n.gate_kind, ''),
                   'prompt', COALESCE(n.gate_prompt, ''))
  FROM v_ready_nodes n
 WHERE n.requirement_id = 'REQ-NNN'
 ORDER BY n.node_key, n.parallel_group, n.id;
```

Four outcomes, and each has one right move:

| What comes back | What it means | Do |
|---|---|---|
| rows with `kind = work` | ordinary work | **3.2** |
| only a `kind = gate` row | the run reached the gate | **3.5** (`gate-repairs`) or hand `gate-plan` back |
| nothing, but nodes are `running` / `failed` | something is still held | resolve it (3.4), or move to another requirement |
| nothing, and every node is `done` / `skipped` | the graph is exhausted | **3.6** — close the requirement |

Check the held case explicitly before believing "nothing to do":

```sql
SELECT id, node_key, status FROM graph_node
 WHERE requirement_id = 'REQ-NNN' AND status NOT IN ('done', 'skipped') ORDER BY id;
```

**No `graph_node` rows at all** → this requirement predates the graph, or the architect never
built one. Do not improvise a chain. Go to **3.7**.

**A pending `gate-plan` is not yours.** `guild:new-requirement` presents it. Say so, offer to
hand it back to that skill, and never approve it yourself or build past it.

**An approved `gate-plan` over a `pending` plan is a drift, not a green light.** Approving is
three writes — the gate, the node, and `plan.approval` — and a board where the first two landed
and the third did not will show the plan in `v_plans_pending_approval` forever. Say which it is
before you dispatch: if the gate carries an approval decision, the fix is the missing write
(`UPDATE plan SET approval='approved', approved_by='user', approved_at=…, gate_node_id=…`), and
it is the guild master's word you are recording, not a new decision. If the gate is genuinely
undecided, hand it back and build nothing.

### 3.2 Advance the requirement, and form ONE batch

If the requirement is still `todo`: `UPDATE requirement SET status = 'in-progress' WHERE id =
'REQ-NNN' AND status = 'todo' RETURNING id, status;`

Then cut the ready **work** nodes into one batch and run only that one. Readiness propagates
as work finishes, so you re-run the segment query after every batch — **you never queue the
whole graph blind.**

**The template is the ceiling; the data is the grouping.**

1. Read the template that shaped this graph — `guild:warehouse` →
   `references/templates/standard.md` or `maintenance.md`, overridden by
   `.guild/templates/*.yaml` when present — and find the entry whose `key:` matches the
   node's `node_key`.
2. `parallel: by-group` or `parallel: all` → nodes sharing a **non-empty** `parallel_group`
   run **concurrently**. The architect asserted their file sets are disjoint
   (`task.files`). Nodes with no group are not concurrent with anything.
3. `parallel: never`, no `parallel:` line, or a key in **neither** template → **one node, one
   batch.** This is an invariant, not a tuning knob: `qa-execute` drives a real app and a real
   dev server, and two at once collide.
4. **Then, independently: never two `serial = 1` members in one concurrent batch.** The
   segment query returns each node's `serial`. If a batch would hold two, **stop and report
   it** — do not silently serialize. The template rule and the serial rule cover each other's
   blind spots (a template says nothing about an added node; a serial flag says nothing about
   a node with no ticket yet).

Take the first batch in `node_key` order and nothing else. If concurrency looks wrong, that is
a graph problem — read `graph_deviation` for the reason somebody recorded.

### 3.3 Dispatch a node

For each node in the batch:

**1. Find its ticket.** The segment query's `task` field is the binding.

- **Bound** → use it.
- **Unbound** (`task` is empty) → the node is one the architect could not bind unambiguously
  (`test-plan`, `qa-plan`, every `review.*`). Find the requirement's open ticket for that work:

  ```sql
  SELECT id, priority, who, parallel_group, title FROM v_open_bounties
   WHERE requirement_id = 'REQ-NNN' ORDER BY priority, id;
  ```

  Pick the one whose title and `who` (`needs:…`) match the node's key — `test-plan` takes the
  `needs:test-planning` bounty, `review.*` takes the reviewer ticket — then **bind it** when
  you move the node, so nobody has to guess again.
- **Unbound and no bounty for it** → the node is an **anchor** for a fanout that has not
  happened yet. See *Anchors* below.

**Never dispatch straight from `v_open_bounties`.** It answers "who could take this ticket",
not "may this run yet". **The graph is the ordering; the bounty board and the matcher only
name the member.**

**2. Resolve the member.** The segment query's `agent` is already rank 1, from the same view
`v_agent_match` ranks with. For a ticket you just found yourself:

```sql
SELECT agent FROM v_task_top_agent WHERE task_id = 'TASK-NNN';   -- '' means nobody
SELECT task_id, agent, source, preferred_covered, preferred_total, capabilities
  FROM v_agent_match WHERE task_id = 'TASK-NNN'
 ORDER BY branch, preferred_covered DESC, capabilities ASC, agent ASC;
```

`''` or no rows → nobody on the roster can take it → **3.8**. Never improvise a substitute.

**There is no reviewer special case.** The `review` node **is** four nodes, one per named
reviewer, and the node id says which: `REQ-007/review.reviewer-security` dispatches
`guild:reviewer-security`. The suffix after the `.` is the member.

**3. Move the ticket and the node, in that order.**

```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'orchestrator' WHERE key = 'actor';

UPDATE task SET status = 'in-progress', claimed_by = 'developer',
                claimed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE id = 'TASK-011' AND status = 'todo'
RETURNING id, status, claimed_by;

UPDATE graph_node SET status = 'running', task_id = 'TASK-011'
 WHERE id = 'REQ-007/implement.auth-service' AND status IN ('pending','ready')
RETURNING id, status, task_id;
```

Zero rows back means somebody already moved it — information, not an error. Set `task_id`
only when the node is unbound; **a fanned-out key shares one ticket at most once** — the four
`review.*` nodes share a single reviewer ticket, so bind one and move the others by id alone.

**4. Spawn with the Agent tool.** Each agent's own definition carries its close-out protocol;
the prompt stays minimal:

```
Agent(
  subagent_type: "guild:{member}",
  prompt: "Your task is TASK-NNN, for REQ-NNN. There are no ticket files — load the
           guild:warehouse skill and read your ticket, your requirement and your plan
           from .guild/guild.db with SQL. Your brief is the ticket's `objective`.
           Today's date: {today}

           Record your progress as you go — one INSERT INTO work_log per meaningful
           outcome, with your own name in `agent` and the entry as CAST(x'<hex>' AS TEXT).
           That log is what makes an interrupted task resumable, and it is the only thing
           I read back when you are done.

           Anything you find that is OUT OF SCOPE for this ticket — a bug, a gap, a
           follow-up — file it as a `bug` row and keep going. Do not stop for it. It is
           collected and judged with everything else at the repairs gate.

           Report done or failed in your final message. Do NOT update task.status,
           graph_node.status or gate.status — the orchestrator owns all transitions."
)
```

**Resumed ticket?** If it was already `in-progress` with a non-empty work log, prepend:

```
RESUMED TASK: a prior agent already worked on this ticket — read its work_log first and
continue from the last entry; do not redo logged work.
```

**Anchors (`fanout: per-declaration`, `per-approved-finding`, `per-mission`).** These nodes
exist as one node and stand in for tickets that do not exist yet — `test-write` before the
test-planner declared any, `repair` before the gate approved anything. Dispatch **every**
ticket the anchor covers, one at a time unless the node says otherwise, then move the anchor
`done` **once**, when they are all finished. The anchor is the barrier; the tickets are the
work.

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

The batch is finished when every agent in it has reported. For **each** node, read what
actually happened — the agent wrote it as it went, so there is nothing to drain:

```sql
SELECT json_object('ts', ts, 'agent', agent, 'entry', entry)
  FROM work_log WHERE task_id = 'TASK-011' ORDER BY ts, id;
SELECT id, reviewer, severity, disposition, file, line, summary
  FROM review_finding WHERE task_id = 'TASK-011' ORDER BY id;
```

Then record it. **Both halves, always** — the ticket is the record, the node is the ordering,
and a node left `running` silently stalls everything behind it:

| The agent reported | Ticket | Node |
|---|---|---|
| done | `UPDATE task SET status='done' WHERE id='TASK-011' AND status='in-progress' RETURNING id,status;` | `UPDATE graph_node SET status='done' WHERE id='REQ-007/…' AND status='running' RETURNING id,status;` |
| failed | `UPDATE task SET status='failed' WHERE id='TASK-011' RETURNING id,status;` | `UPDATE graph_node SET status='failed' WHERE id='REQ-007/…' RETURNING id,status;` |

Do not set `updated_at` — a trigger stamps it, and another writes the `event` row.

**A failure does not stop the run and does not ask the user.** That is what the two-gate
model buys: a failed node holds its own successors, the rest of the graph keeps going, and
the failure is **collected** and judged at `gate-repairs` alongside every finding and bug.
(The one exception is a failure that stalls the *whole* requirement with nothing else
runnable — then say so and ask.)

**Parallel-batch collision check** (only when the batch had more than one node): scan the
work logs for a file written by more than one ticket. If you find one, the architect's
disjoint-file assertion was wrong — that is a finding for the gate, not an interruption:

```sql
INSERT INTO bug (id, title, body, repro, severity, found_by, requirement_id, created_at, updated_at)
SELECT 'BUG-' || printf('%03d', COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)),0)+1),
       CAST(x'<hex>' AS TEXT), '', '', 'major', 'orchestrator', 'REQ-NNN',
       strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM bug
RETURNING id;
```

Then **go back to 3.1** — re-run the segment query and take the next batch. One line between
batches and nothing more:

```
REQ-007 — implement.migrations done (developer). Next: test-plan.
```

### 3.5 The gate — `gate-repairs`

When the only ready node is the gate, this is the second and last decision of the
requirement, and it is yours to put in front of the user.

**1. Gather what is being judged** — everything collected during the run:

```sql
SELECT id, task_id, reviewer, severity, disposition, file, line, summary, detail
  FROM v_open_findings WHERE requirement_id = 'REQ-NNN';
SELECT id, severity, status, found_by, title FROM v_open_bugs;
SELECT id, who, waived, reason, title FROM v_failed_tasks WHERE requirement_id = 'REQ-NNN';
SELECT prompt, kind FROM gate WHERE node_id = 'REQ-NNN/gate-repairs';
```

Write the review record to `.guild/reviews/REQ-NNN.md` — **append a new dated section, never
overwrite a prior round's**:

```markdown
## {today} — REQ-NNN

### reviewer-security — {PASS | ISSUES FOUND}
{findings, verbatim}

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
{item}"). They can approve some, all or none; "Other" covers anything they would rather
phrase differently.

**4. Record the decision, and create the repairs.** Two writes, always — setting `gate.status`
does **not** move the node:

```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'orchestrator' WHERE key = 'actor';

UPDATE gate SET status = 'approved',
                decision = CAST(x'<hex-decision>' AS TEXT),
                decided_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE node_id = 'REQ-NNN/gate-repairs' AND status = 'pending'
   AND EXISTS (SELECT 1 FROM v_ready_nodes r WHERE r.id = 'REQ-NNN/gate-repairs')
RETURNING node_id, status;

UPDATE graph_node SET status = 'done'
 WHERE id = 'REQ-NNN/gate-repairs'
   AND (SELECT g.status FROM gate g WHERE g.node_id = graph_node.id) = 'approved'
RETURNING id, status;
```

- **The `v_ready_nodes` guard is not decoration.** Approving a gate whose predecessors have
  not finished makes `repair` ready immediately, and repairs would run against findings
  nobody produced.
- **`decision` is mandatory on this gate** — it *is* the fan-out. `none` is how you say
  "approve, repair nothing" out loud. Pass the user's own words through; six weeks later the
  reasoning is the part anyone wants.
- **On reject** (the run was wrong, not its findings): `status = 'rejected'` and the node goes
  to `'skipped'`. Say so and stop. A rejected gate may be decided again; an **approved** one
  may not — its successors have already been unblocked.

Then create one plain ticket per approved item (`task` + `task_capability`, per
`queries.md` §1), and link each repair to what it repairs:

```sql
UPDATE review_finding SET disposition = 'fixing', fix_task_id = 'TASK-021'
 WHERE id = 7 AND disposition = 'open' RETURNING id, disposition;
UPDATE bug SET status = 'fixing', fix_task_id = 'TASK-022'
 WHERE id = 'BUG-004' AND status = 'open' RETURNING id, status;
```

Go back to **3.1** — the approved gate makes `repair` ready. **There is no automatic
re-review.** If the user wants another pass later, that is a fresh reviewer ticket.

### 3.6 Requirement completion

When every node is `done` or `skipped`, confirm nothing is still open:

```sql
SELECT id, status, tasks_total, tasks_done, tasks_open, tasks_blocked, tasks_failed, title
  FROM v_requirement_progress WHERE id = 'REQ-NNN';
```

`tasks_open = 0` → `UPDATE requirement SET status = 'done' WHERE id = 'REQ-NNN' AND status <>
'done' RETURNING id, status;` then roll the direction above it up — a project whose
requirements are all done is `done`, a goal whose projects are all done is `done` — then append
a bullet to `CHANGELOG.md` (3.9).

Closing a **sequential** project is what releases the next one in its goal, so re-read
`v_projects_runnable` after the roll-up: a project that was not runnable a moment ago may be
now, and that is the next thing to dispatch.

**`tasks_open` counts `blocked`, and that is the point.** `failed` was adjudicated at the
gate; `blocked` is a machine verdict nobody has looked at, and closing a requirement over one
ships un-attempted work silently. **Nothing in the schema stops you** — this is a
convention you honor. If a blocked task is holding a requirement open, say so by name; the
fix is recruiting (3.8), not a status edit.

List any `failed` tasks in the completion summary — they were judged at `gate-repairs`, so
they report rather than block.

Then summarize the requirement and ask: continue with the next one, or wrap up?

### 3.7 A requirement with no graph — the cursor fallback

For a board that predates the graph, the cursor still works and it is the fallback:

```sql
SELECT * FROM v_next_task;                                   -- resume, else claim
SELECT member_id, member_status, member_title FROM v_batch WHERE task_id = 'TASK-NNN';
```

**Use it only when the requirement has no `graph_node` rows, and say so out loud.**
`v_next_task` applies the review gate but deliberately ignores dependencies and eligibility,
so check `v_open_bounties` before dispatching. Dispatch by `v_task_top_agent` exactly as in
3.3, and skip 3.5 — there is no gate on a graph-less requirement, so a review report goes to
the user directly.

**Offer the fix once**: only the architect should decide a graph's shape, so hand the
requirement back to `guild:new-requirement` rather than instantiating one yourself.

### 3.8 No eligible agent — block it, loudly

When `v_task_top_agent` returns `''` and the ticket declared capabilities, no member covers
it. That is a **roster gap** and it should be loud. Reading never blocks a ticket; blocking is
a decision, so it is a write you make on purpose:

```sql
UPDATE task SET status = 'blocked'
 WHERE id = 'TASK-005' AND status = 'todo'
   AND NOT EXISTS (SELECT 1 FROM v_agent_eligible e WHERE e.task_id = 'TASK-005')
   AND COALESCE(agent, '') = ''
RETURNING id, status;

INSERT INTO work_log (task_id, ts, agent, entry)
SELECT t.id, strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'orchestrator', CAST(x'<hex>' AS TEXT)
  FROM task t WHERE t.id = 'TASK-005';

UPDATE graph_node SET status = 'failed' WHERE task_id = 'TASK-005' AND status = 'running'
RETURNING id, status;
```

**Tell the user now, do not batch it into the wrap-up.** Name the ticket, the missing
capabilities (`v_blocked_tasks.reason` spells them: `no-eligible-agent:implement,rust`), and
the one thing that fixes it:

```
TASK-005 "Port the codec to Rust" is blocked: no guild member has [implement, rust].
Nothing will pick it up until the roster covers it. Run /guild:new-requirement to
recruit for it, or reassign the work.
```

Then continue the loop. `blocked` means exactly one thing — **no guild member can take this
bounty** — never "waiting on a person or a decision". It holds the review gate and keeps its
requirement open at 3.6, both deliberately. **Never substitute a member you think is close
enough**; if the user wants a generalist to take it anyway, that is their call, out loud.

**Unblocking**: once an agent file is added and the roster synced, `UPDATE task SET status =
'todo'`, `UPDATE graph_node SET status = 'pending'`, then confirm with `v_task_top_agent`.

### 3.9 CHANGELOG maintenance

When a requirement reaches `done` (3.6), append a bullet under `## [Unreleased]` in the
repo-root `CHANGELOG.md` (create the file with the Keep-a-Changelog preamble if missing):

```
- REQ-NNN: {requirement title}
```

Skip if a bullet starting with `- REQ-NNN:` is already there (idempotent). With waived tasks,
use `- REQ-NNN: {title} (TASK-NNN skipped)`. `guild:release` renames `## [Unreleased]` later.

---

## Step 4: Session wrap-up

When the cycle ends (the user stops, or nothing is actionable):

```
Session Summary
===============
Nodes run: {N}     Tickets completed: {N}     Bugs filed: {N}

Requirements:
  REQ-007: Session-backed authentication — in-progress, at gate-repairs
  REQ-008: Preferences page — in-progress (implement.ui running)

Next check-in, I'll continue with:
  REQ-007 — the repairs gate is ready for your decision
```

**The summary does not end without these three, when any is non-empty:**

- **Gates awaiting you** — `SELECT * FROM v_gates_pending`. The only thing on the board that
  cannot move without the user; it belongs at the top of the wrap-up, not the bottom.
- **Blocked work and roster gaps** — `v_blocked_tasks`, `v_roster_gaps`. Neither resolves on
  its own.
- **Nodes left `failed` or `running`** — a `running` node with no live agent is a crash site
  and it holds everything behind it.

Then, and only then, stamp the check-in:

```sql
UPDATE guild_state SET value = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE key = 'last-checkin' RETURNING key, value;
```

---

## Step 5: Verify against expectations

Before you hand the session back, run `guild:validate check-in` — the global invariants plus
§7 of `docs/expectations.md`, which asserts the four ways an orchestrator goes wrong:
dispatching by a hardcoded name, letting somebody else move a status, building past a gate,
and re-deriving a rule instead of reading the view. **Report every failure with its rows.**
Your own account of what you wrote is not evidence; the board is.

## Key Rules

1. **The graph is the chain, and you do not know it.** What runs and what runs together comes
   from `v_ready_nodes` plus the template's `parallel:` ceiling. Never invent an order, widen
   a batch, merge two, or dispatch a node the graph did not offer.
2. **You own every status transition** — `task.status`, `graph_node.status`, `gate.status`.
   Agents report; their only board writes are `work_log`, `review_finding` and `bug` rows.
   **No constraint enforces this.** It holds because you honor it.
3. **Record BOTH halves.** A ticket moved without its node leaves the graph stalled; a node
   moved without its ticket leaves the board lying. Every 3.4 row is two statements.
4. **Two gates, and only one of them is yours.** `gate-plan` belongs to
   `guild:new-requirement`; `gate-repairs` is yours. Never add a gate, never approve one that
   is not yours, never build past a pending one, and never approve one `v_ready_nodes` does
   not list.
5. **Problems are collected, not escalated.** A finding, a bug, a failed task, a file
   collision — record it and keep running. They are judged together at `gate-repairs`.
   Stopping the user per problem converts agent time into their time, which is the exact
   thing the two-gate model exists to prevent.
6. **The graph orders; the matcher only names the member.** `v_open_bounties` answers "who
   could take this", not "may this run yet".
7. **There is no reviewer fan-out to perform.** The `review` node *is* four nodes; the member
   is the suffix of the node id.
8. **Read the view, do not re-derive the rule.** `v_next_task`, `v_ready_nodes`,
   `v_task_actionable`, `v_agent_match`, `v_brief` each hold ONE definition. A second
   spelling is a second answer, and both look right.
9. **Serial members are never concurrent**, and a batch that would hold two is a stop-and-
   report, not something you quietly serialize.
10. **Subagents can't ask the user.** Every agent relays through `NEEDS INPUT:`; you ask, then
    `SendMessage` the answers back. This is also why a gate can never live inside a dispatched
    workflow.
11. **A ticket names a capability; the matcher names the member.** Dispatch rank 1 when
    `agent` is empty, honor the pin when it is set, never invent a member for a ticket nobody
    matched.
12. **`blocked` means "no guild member can take this bounty" and nothing else.** Written only
    by you, only after the match came back empty, reported the moment it happens. Recruiting
    is the fix.
13. **You never write an `agents/*.md` file.** Creating a guild member happens in
    `guild:new-requirement`, on an explicit answer from the user, and nowhere else.
14. **Guard every mutation and read the `RETURNING`.** A failing statement does not stop a
    tursodb script and `COMMIT` still commits, so one logical change per invocation, and zero
    rows back is information you act on rather than ignore.
