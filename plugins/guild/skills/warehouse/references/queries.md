# The canonical queries

Copy-paste from here. Every snippet below was run against `tursodb` 0.7.2 with
`schema.sql` applied.

**Prefer `SELECT * FROM v_…` wherever a view exists.** Re-deriving a rule by hand is how
members drift apart: two spellings of "which task is next" give the guild two answers to one
question, and neither is wrong on its own terms. When you catch yourself writing a
`NOT EXISTS` over `task_dependency`, stop and look for the view.

---

## 0. The preamble

Every script that writes:

```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'developer-svelte' WHERE key = 'actor';
```

`foreign_keys` is per-connection and defaults to OFF. `actor` is what every trigger copies
into `event.actor`.

### Getting free text in

```bash
export PATH="$HOME/.turso:$PATH"

# from a variable
hex=$(printf '%s' "$title" | xxd -p | tr -d '\n')

# from a file — better, because the content never passes through the shell at all
hex=$(xxd -p < body.md | tr -d '\n')

# no xxd?
hex=$(LC_ALL=C od -An -v -tx1 < body.md | LC_ALL=C tr -d ' \n')
```

Then interpolate as `CAST(x'$hex' AS TEXT)`. `printf '%s'`, never `echo`. Never round-trip
the *value* through `$( )` — command substitution strips trailing newlines. Empty string is
`''`, not `CAST(x'' AS TEXT)`. Hex must be even-length and valid UTF-8; tursodb silently
substitutes U+FFFD for invalid bytes while sqlite3 preserves them, so validate first:

```bash
printf '%s' "$v" | iconv -f UTF-8 -t UTF-16BE > /tmp/utf8check || echo "not UTF-8"
```

Values from a closed alphabet you control — ids, enum words, agent names, capability
tokens, timestamps you generated — may be plain quoted literals.

### Getting text out

```sql
-- byte-exact: exactly one column, so no separator is ever inserted
SELECT body FROM requirement WHERE id = 'REQ-001';

-- structured: json_object escapes control chars, so one row is always one line
SELECT json_object('id', id, 'status', status, 'title', title) FROM task ORDER BY id;

-- columnar: flatten server-side, before the value leaves the engine
SELECT id, status,
       replace(replace(replace(title, char(10), ' '), char(13), ' '), '|', '!')
  FROM task ORDER BY id;
```

---

## 1. Creating things

### The id pattern

Ids stay `PREFIX-NNN`, derived in the same statement as the insert so there is no
read-then-write race:

```sql
'REQ-' || printf('%03d', COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)), 0) + 1)
```

`instr(id,'-')+1` finds the number without you counting prefix characters, so the same
expression works for `REQ-`, `TASK-`, `PLAN-`, `GOAL-`, `PROJ-`, `BUG-` and `INSP-`.
Zero-padding to three digits is what makes text order equal numeric order up to 999 — which
is what `ORDER BY id` in the cursor relies on.

Two shapes, and the difference matters:

- **No parent to check** → aggregate over the table itself, `FROM <table>`. An aggregate
  returns one row even when the table is empty.
- **A parent to check** → put the id in a scalar subquery and select `FROM parent WHERE
  parent.id = …`. **The `FROM` clause IS the referential check**: a missing parent yields
  zero rows and no partial mutation, which matters because a failing statement does not stop
  the script.

### Goal, project

```sql
INSERT INTO goal (id, title, body, priority, created_at, updated_at)
SELECT 'GOAL-' || printf('%03d', COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)), 0) + 1),
       CAST(x'<hex>' AS TEXT), '', 2,
       strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM goal
RETURNING id;

INSERT INTO project (id, goal_id, title, ordinal, priority, concurrent, isolation, created_at, updated_at)
SELECT 'PROJ-' || printf('%03d', (SELECT COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)),0)+1 FROM project)),
       g.id, CAST(x'<hex>' AS TEXT),
       (SELECT COUNT(*)+1 FROM project WHERE goal_id = g.id),
       3, 0, 'shared',
       strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM goal g WHERE g.id = 'GOAL-001'
RETURNING id;
```

The defaults above are the sequential, shared-tree project — the one that behaves exactly
like the old `phase`. Change three columns to change that:

```sql
-- runs BESIDE its siblings instead of waiting its turn
UPDATE project SET concurrent = 1 WHERE id = 'PROJ-003' RETURNING id, concurrent;

-- waits for nobody and is in no sequence at all
UPDATE project SET ordinal = NULL WHERE id = 'PROJ-004' RETURNING id, ordinal;

-- runs in its own git worktree. Set BOTH columns in one statement: a 'shared' project
-- may not carry a path, so setting the path alone fails the CHECK.
UPDATE project
   SET isolation = 'worktree', worktree_path = '.worktrees/PROJ-003'
 WHERE id = 'PROJ-003'
RETURNING id, isolation, worktree_path;
```

Never re-derive "may this project run" — `v_projects_runnable` is the one definition:

```sql
SELECT id, why, isolation, worktree_path, title FROM v_projects_runnable;
SELECT id, why, isolation, worktree_path, title FROM v_projects_runnable WHERE goal_id = 'GOAL-001';
```

### Requirement

```sql
INSERT INTO requirement (id, project_id, title, body, priority, created_at, updated_at)
SELECT 'REQ-' || printf('%03d', COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)), 0) + 1),
       'PROJ-001', CAST(x'<hex-title>' AS TEXT), CAST(x'<hex-body>' AS TEXT), 1,
       strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM requirement
RETURNING id;
```

`project_id` is nullable — pass `NULL` for unaffiliated work.

### Plan

```sql
INSERT INTO plan (id, requirement_id, title, body, created_at, updated_at)
SELECT 'PLAN-' || printf('%03d', (SELECT COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)),0)+1 FROM plan)),
       r.id, CAST(x'<hex>' AS TEXT), CAST(x'<hex>' AS TEXT),
       strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM requirement r WHERE r.id = 'REQ-001'
RETURNING id;
```

`task_id` is optional and means "a plan written FOR one ticket" — the test-planner uses it for
the test plan. Leave it NULL for the requirement's own implementation plan.

A new plan starts `approval = 'pending'`, and **nothing is built until a human rules on it**.
`status` and `approval` answer different questions — *is it written* versus *did the user say
yes* — so move them separately:

```sql
-- the architect has finished drafting. This does NOT approve anything.
UPDATE plan SET status = 'done' WHERE id = 'PLAN-001' RETURNING id, status, approval;

-- the user said yes. Record WHO ruled — the trigger uses it as the event's actor.
UPDATE plan
   SET approval = 'approved', approved_by = 'user',
       approved_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE id = 'PLAN-001'
RETURNING id, approval, approved_by;

-- rejected sends it back to the architect. The plan row stays; it is the same plan.
UPDATE plan
   SET approval = 'rejected', approved_by = 'user',
       approved_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'), status = 'in-progress'
 WHERE id = 'PLAN-001'
RETURNING id, approval, status;

-- tie the plan to the gate node carrying the same decision, so a reader can go either way
UPDATE plan SET gate_node_id = 'REQ-001/gate-plan' WHERE id = 'PLAN-001' RETURNING id, gate_node_id;

-- who is still waiting on a person
SELECT id, requirement_id, gate_node_id, title FROM v_plans_pending_approval;
```

Approving the **gate** does not write `plan.approval`. They are two writes, exactly like
moving a gate's node — do both, or `v_plans_pending_approval` will keep asking.

### Task, with its capabilities and dependencies

```sql
INSERT INTO task (id, requirement_id, plan_id, files, parallel_group,
                  title, objective, body, priority, agent, created_at, updated_at)
SELECT 'TASK-' || printf('%03d', (SELECT COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)),0)+1 FROM task)),
       r.id, 'PLAN-001',
       json_array('src/lib/auth.ts', 'src/routes/login/+page.server.ts'), 'wave-1',
       CAST(x'<hex-title>' AS TEXT), CAST(x'<hex-objective>' AS TEXT), CAST(x'<hex-body>' AS TEXT),
       2, NULL,
       strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM requirement r WHERE r.id = 'REQ-001'
RETURNING id;
```

`files` is the JSON array of paths this ticket owns — the architect's disjointness assertion
for everything sharing its `parallel_group`. Nothing verifies it. Pass `'[]'` for tickets that
touch no bounded file set (test-plan, review).

Leave `agent` NULL and declare capabilities instead — that is what lets the matcher work and
what makes a roster gap visible. Set `agent` only when you mean to **pin** a specific member;
a pin outranks the match and is never reported as a gap.

```sql
-- required decides eligibility; required = 0 ("preferred") only decides rank
INSERT INTO task_capability (task_id, capability, required)
SELECT t.id, value, 1
  FROM task t JOIN json_each(json_array('implement','frontend')) ON t.id = 'TASK-001'
ON CONFLICT DO NOTHING;

INSERT INTO task_capability (task_id, capability, required)
SELECT t.id, value, 0
  FROM task t JOIN json_each(json_array('svelte','sveltekit')) ON t.id = 'TASK-001'
ON CONFLICT DO NOTHING;

-- direct predecessors only, never a transitive closure
INSERT INTO task_dependency (task_id, depends_on)
SELECT 'TASK-002', 'TASK-001'
 WHERE EXISTS (SELECT 1 FROM task WHERE id = 'TASK-002')
   AND EXISTS (SELECT 1 FROM task WHERE id = 'TASK-001')
RETURNING task_id || ' after ' || depends_on;
```

Check the words you used against the vocabulary before you walk away — an unknown capability
inserts fine and then matches nobody, silently:

```sql
SELECT side, owner, capability FROM v_capability_unknown;
```

### Bug

```sql
INSERT INTO bug (id, title, body, repro, severity, found_by, requirement_id,
                 created_at, updated_at)
SELECT 'BUG-' || printf('%03d', COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)),0)+1),
       CAST(x'<hex-title>' AS TEXT), CAST(x'<hex-body>' AS TEXT), CAST(x'<hex-repro>' AS TEXT),
       'major', 'qa-tester', 'REQ-001',
       strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM bug
RETURNING id;
```

`found_by` becomes the event's actor for the creation, so set it honestly. Severity here has
no `nit` — a bug is not a nit.

### Doc — upsert into the library

```sql
INSERT INTO doc (slug, title, body, source, updated_at)
VALUES ('sveltekit-form-actions', 'SvelteKit form actions',
        CAST(x'<hex-body>' AS TEXT), 'researcher',
        strftime('%Y-%m-%dT%H:%M:%SZ','now'))
ON CONFLICT(slug) DO UPDATE SET
  title      = excluded.title,
  body       = excluded.body,
  source     = excluded.source,
  updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
RETURNING slug;
```

The slug is a **key**: someone has to retype it. Validate it against a closed alphabet at the
door rather than slugifying silently — storing `my-notes` for `My Notes` makes the next
lookup report not-found, which reads as data loss.

### Searching the library — no FTS5, so `LIKE` with escapes

```sql
SELECT slug, title FROM doc
 WHERE lower(title) || char(10) || lower(body) LIKE
       '%' || replace(replace(replace(lower('fail()'), '\', '\\'), '%', '\%'), '_', '\_') || '%'
       ESCAPE '\'
 ORDER BY slug;
```

Escape the backslash **first**, so nothing introduced later gets double-escaped. Do it in
SQL, not the shell. `lower()` on both sides so behavior does not depend on the engine's
`case_sensitive_like` — its honest limit is that `lower()` is ASCII-only. **Refuse an empty
query**: it escapes to `%%` and quietly answers "everything".

---

## 2. Moving something through status

Always guard on the status you expect and always `RETURNING`. Zero rows back means somebody
already moved it — which is information, not an error:

```sql
UPDATE task SET status = 'in-progress',
                claimed_by = 'developer-svelte',
                claimed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE id = 'TASK-001' AND status = 'todo'
RETURNING id, status, claimed_by;

UPDATE task SET status = 'done'
 WHERE id = 'TASK-001' AND status = 'in-progress'
RETURNING id, status;

UPDATE requirement SET status = 'done'
 WHERE id = 'REQ-001' AND status <> 'done'
RETURNING id, status;
```

Do not set `updated_at` — a trigger stamps it when you leave it alone. The status change and
the claim each write their own `event` row automatically.

**Before closing a requirement**, look at what is still open. Nothing in the schema stops you
from closing over a blocked task, and doing it ships work nobody ever attempted:

```sql
SELECT id, status, tasks_total, tasks_done, tasks_open, tasks_blocked, tasks_failed, title
  FROM v_requirement_progress WHERE id = 'REQ-001';
```

### Failing a task, and the waiver

```sql
UPDATE task SET status = 'failed' WHERE id = 'TASK-002' RETURNING id, status;

-- the agent's report
INSERT INTO work_log (task_id, ts, agent, entry)
SELECT t.id, strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'test-writer', CAST(x'<hex>' AS TEXT)
  FROM task t WHERE t.id = 'TASK-002';

-- the waiver, ONLY on the user's skip. The decoded entry must BEGIN exactly:
--   Skipped by user
INSERT INTO work_log (task_id, ts, agent, entry)
SELECT t.id, strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'orchestrator', CAST(x'<hex>' AS TEXT)
  FROM task t WHERE t.id = 'TASK-002';
```

Read it back — `waived` is the flag, `reason` is the most recent entry that is *not* the
waiver:

```sql
SELECT id, who, waived,
       replace(replace(COALESCE(reason,'-'), char(10),' '), '|','!') AS reason, title
  FROM v_failed_tasks;
```

### Logging work, filing and dispositioning a finding

```sql
INSERT INTO work_log (task_id, ts, agent, entry)
SELECT t.id, strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'developer-svelte', CAST(x'<hex>' AS TEXT)
  FROM task t WHERE t.id = 'TASK-001'
RETURNING id;

INSERT INTO review_finding (task_id, reviewer, severity, summary, detail, file, line, created_at)
SELECT t.id, 'reviewer-security', 'major',
       CAST(x'<hex-summary>' AS TEXT), CAST(x'<hex-detail>' AS TEXT),
       'src/lib/auth.ts', 42, strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM task t WHERE t.id = 'TASK-001'
RETURNING id;

-- link a repair ticket
UPDATE review_finding SET disposition = 'fixing', fix_task_id = 'TASK-011'
 WHERE id = 1 AND disposition = 'open'
RETURNING id, disposition;
```

The finding's event is attributed to `reviewer`, not to the ambient actor — a finding's
author is the most important fact about it.

---

## 3. The daily reads

All of these are views. None of them mutate anything: a ticket nobody can take does **not**
become `blocked` by being read.

```sql
-- the standup, one fact per row
SELECT fact, value FROM v_brief;

-- the board
SELECT section_no, section, id, status, who, requirement_id, priority,
       replace(replace(title, char(10), ' '), '|', '!') AS title
  FROM v_board;

-- cap a section yourself; the view deliberately does not
SELECT * FROM v_board WHERE section_no = 4 ORDER BY id DESC LIMIT 20;

-- the requirement roll-up, and the open goals
SELECT * FROM v_requirement_progress;
SELECT * FROM v_goal_progress;

-- WHAT CAN I HAND OUT: actionable + no unfinished deps + a matched member
SELECT id, requirement_id, priority, agent, who, parallel_group,
       replace(replace(title, char(10),' '), '|','!') AS title
  FROM v_open_bounties ORDER BY priority, id;

-- WHERE WAS I: resume-then-claim, zero or one row
SELECT * FROM v_next_task;

-- and everything that cannot move, with the reason
SELECT id, requirement_id, status, agent, who, reason,
       replace(replace(title, char(10),' '), '|','!') AS title
  FROM v_blocked_tasks ORDER BY id;

-- what must dispatch together with a ticket
SELECT member_id, member_status, member_title FROM v_batch WHERE task_id = 'TASK-003';

-- the detail lists
SELECT * FROM v_in_flight;
SELECT id, task_id, requirement_id, reviewer, severity, disposition, file, line, summary
  FROM v_open_findings;
SELECT id, severity, status, found_by, requirement_id, fix_task_id, title FROM v_open_bugs;
SELECT id, risk, interval_days, days_since, spec_path, area FROM v_coverage_due;
SELECT id, capability, requirement_id, proposed_agent, covered_by, rationale FROM v_roster_gaps;
```

`v_next_task` returning nothing means "nothing to do" — it does **not** mean the board is
finished. Read `v_blocked_tasks` and `v_gates_pending` in the same breath before believing it.

### What moved since the last check-in

```sql
SELECT json_object('ts', ts, 'actor', actor, 'verb', verb,
                   'subject_type', subject_type, 'subject', subject_id,
                   'title', subject_title, 'phrase', phrase)
  FROM v_recent_activity
 WHERE ts >= COALESCE(NULLIF((SELECT value FROM guild_state WHERE key = 'last-checkin'), 'null'), '')
 ORDER BY ts DESC
 LIMIT 50;
```

Then stamp the check-in, last, once you have reported:

```sql
UPDATE guild_state SET value = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE key = 'last-checkin'
RETURNING key, value;
```

---

## 4. The execution graph

### Instantiate a requirement from a template

Nodes and edges are data, so a template lands as two `json_each` inserts. Node ids are
`REQ-001/<node-key>`; a gate node's key is conventionally prefixed `gate-`.

```sql
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT r.id || '/' || j.value, r.id, j.value,
       CASE WHEN j.value LIKE 'gate-%' THEN 'gate' ELSE 'work' END,
       NULL, NULL, 'pending'
  FROM requirement r
  JOIN json_each(json_array('gate-plan','implement','test-plan','test-write',
                            'review','gate-repairs','repair')) j
 WHERE r.id = 'REQ-001'
RETURNING id;

INSERT INTO graph_edge (from_node, to_node)
SELECT 'REQ-001/' || json_extract(j.value,'$[0]'),
       'REQ-001/' || json_extract(j.value,'$[1]')
  FROM json_each(json_array(
        json_array('gate-plan','implement'),
        json_array('implement','test-plan'),
        json_array('test-plan','test-write'),
        json_array('test-write','review'),
        json_array('review','gate-repairs'),
        json_array('gate-repairs','repair'))) j
RETURNING from_node || ' -> ' || to_node;

INSERT INTO gate (node_id, prompt, kind, status)
SELECT n.id, CAST(x'<hex-prompt>' AS TEXT), 'approve', 'pending'
  FROM graph_node n WHERE n.id = 'REQ-001/gate-plan'
RETURNING node_id;
```

**Declare every edge backwards in template order** — `to_node` must be a node declared after
`from_node`. That is the only cycle protection there is: with no `WITH RECURSIVE`, a cycle is
undetectable and shows up as `v_ready_nodes` silently returning nothing for the whole loop.

Fanning a node out per implement ticket (id becomes `REQ-001/implement.<TASK-ID>`):

```sql
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-001/implement.' || t.id, 'REQ-001', 'implement', 'work', t.id, t.parallel_group, 'pending'
  FROM task t
 WHERE t.requirement_id = 'REQ-001' AND t.node_key = 'implement'
RETURNING id;

INSERT INTO graph_edge (from_node, to_node)
SELECT 'REQ-001/gate-plan', n.id FROM graph_node n
 WHERE n.requirement_id = 'REQ-001' AND n.node_key = 'implement'
   AND n.id <> 'REQ-001/implement'
RETURNING from_node || ' -> ' || to_node;
```

Any departure from the template gets a row **with a reason** — the sentence is the whole
value of it, and an empty one is rejected:

```sql
INSERT INTO graph_deviation (requirement_id, kind, node_key, reason, created_at)
SELECT r.id, 'add-node', 'research', CAST(x'<hex-reason>' AS TEXT),
       strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM requirement r WHERE r.id = 'REQ-001'
RETURNING id;
```

### Find what is ready

```sql
SELECT id, requirement_id, node_key, kind, task_id, parallel_group, predecessors,
       gate_status, gate_kind
  FROM v_ready_nodes
 WHERE requirement_id = 'REQ-001';

-- work ready to dispatch vs gates ready to ask a human
SELECT * FROM v_ready_nodes WHERE kind = 'work' AND gate_status IS NULL;
SELECT node_id, requirement_id, node_key, kind, prompt FROM v_gates_pending;
```

Readiness is a **one-hop join** and it propagates as work completes. If you find yourself
wanting to traverse, you want to run the graph.

### Run a node

```sql
UPDATE graph_node SET status = 'running', task_id = 'TASK-001'
 WHERE id = 'REQ-001/implement.auth-service' AND status IN ('pending','ready')
RETURNING id, status;

UPDATE graph_node SET status = 'done'
 WHERE id = 'REQ-001/implement.auth-service' AND status = 'running'
RETURNING id, status;
```

`skipped` is the graph's `waived` — a deliberately skipped node must not hold its successors
forever, so `done` and `skipped` both count as finished.

### Resolve a gate — two writes, always

Setting `gate.status` does **not** move the node. Nothing does it for you.

```sql
UPDATE gate SET status = 'approved',
                decision = CAST(x'<hex-decision>' AS TEXT),
                decided_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE node_id = 'REQ-001/gate-plan' AND status = 'pending'
RETURNING node_id, status;

UPDATE graph_node SET status = 'done'
 WHERE id = 'REQ-001/gate-plan'
   AND (SELECT g.status FROM gate g WHERE g.node_id = graph_node.id) = 'approved'
RETURNING id, status;
```

On reject, `gate.status = 'rejected'` and the node goes to `'skipped'`. For a
`select-findings` gate, `decision` carries the JSON selection and the repair nodes fan out
from it.

---

## 5. The roster

### Sync agent files into the roster

One block per agent file, then one retirement sweep. Capabilities are **replaced, not
merged** — the file is the declaration.

```sql
INSERT INTO agent (name, model, description, active, serial)
VALUES ('developer-svelte', 'sonnet', CAST(x'<hex-description>' AS TEXT), 1, 0)
ON CONFLICT(name) DO UPDATE SET
  model       = excluded.model,
  description = excluded.description,
  active      = 1,
  serial      = excluded.serial
RETURNING name;

DELETE FROM agent_capability
 WHERE agent = 'developer-svelte'
   AND capability NOT IN (SELECT value FROM json_each(
         json_array('implement','frontend','svelte','sveltekit')));

INSERT INTO agent_capability (agent, capability)
SELECT 'developer-svelte', value
  FROM json_each(json_array('implement','frontend','svelte','sveltekit'))
 WHERE EXISTS (SELECT 1 FROM agent WHERE name = 'developer-svelte')
ON CONFLICT DO NOTHING;
```

Then, with the full set of names that have files:

```sql
-- RETIRE, never DELETE: a done task from months ago may still name this agent
UPDATE agent SET active = 0
 WHERE active = 1
   AND name NOT IN (SELECT value FROM json_each(
         json_array('developer-svelte','developer','test-writer','qa-tester')))
RETURNING name;

-- admission closes the gap that asked for it, so the board stops reporting it
UPDATE capability_request SET status = 'created'
 WHERE status = 'open'
   AND capability IN (SELECT ac.capability FROM agent_capability ac
                        JOIN agent a ON a.name = ac.agent AND a.active = 1)
RETURNING id, capability, status;
```

Never delete a `created` request — the row is what keeps the word in
`v_capability_vocabulary`, so removing it un-admits the capability on the next sync.

### Match an agent to a task

```sql
-- every candidate, ranked; RESTATE the ORDER BY, a view's ordering is not a contract
SELECT task_id, agent, source, preferred_covered, preferred_total, capabilities, serial
  FROM v_agent_match
 WHERE task_id = 'TASK-001'
 ORDER BY branch, preferred_covered DESC, capabilities ASC, agent ASC;

-- just rank 1; '' means nobody is eligible
SELECT agent FROM v_task_top_agent WHERE task_id = 'TASK-001';
```

`capabilities ASC` is not a typo: it is the agent's *total* capability count, and lower is
better, so a specialist beats a generalist. `source` tells you which path produced the row —
`pin` (the ticket named an agent and also declared capabilities), `ticket` (named an agent
and declared none, so the roster is not consulted at all), or `capability`.

**No rows at all** for a ticket that declared capabilities is a **roster gap**, and it is the
entire reason for declaring them. `v_blocked_tasks` names the missing word.

### File a capability request

```sql
INSERT INTO capability_request (capability, requirement_id, rationale, proposed_agent,
                                proposed_spec, created_at)
SELECT 'rust', r.id, CAST(x'<hex-rationale>' AS TEXT), 'developer-rust',
       CAST(x'<hex-spec>' AS TEXT), strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM requirement r WHERE r.id = 'REQ-001'
RETURNING id, capability;
```

File it at **plan** time. A gap found at dispatch time is already a failure — the plan is
approved and a bounty has nobody to take it. Filing is also what legitimizes the word:
`v_capability_vocabulary` unions in every non-declined request.

To decline: `UPDATE capability_request SET status = 'declined' WHERE id = 1;` — and the word
stays out.

### Mark a task blocked when nobody can take it

Reading never does this. It is a decision, so it is a write somebody makes on purpose:

```sql
UPDATE task SET status = 'blocked'
 WHERE id = 'TASK-014' AND status = 'todo'
   AND NOT EXISTS (SELECT 1 FROM v_agent_eligible e WHERE e.task_id = 'TASK-014')
   AND COALESCE(agent, '') = ''
RETURNING id, status;
```

Remember that `blocked` **holds the review gate** — deliberately. A roster gap should be
loud, and between a failure that hides and a failure that shouts, take the one that shouts.

---

## 6. Quality and maintenance

```sql
INSERT INTO coverage (id, area, risk, spec_path, notes)
VALUES ('checkout-flow', 'Checkout flow', 'high', 'e2e/checkout.spec.ts', CAST(x'<hex>' AS TEXT))
ON CONFLICT(id) DO UPDATE SET
  area = excluded.area, risk = excluded.risk, spec_path = excluded.spec_path,
  notes = excluded.notes
RETURNING id;

INSERT INTO inspection (id, scope, "trigger", status, started_at)
SELECT 'INSP-' || printf('%03d', COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)),0)+1),
       'whole product', 'manual', 'in-progress', strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM inspection
RETURNING id;

INSERT INTO inspection_coverage (inspection_id, coverage_id, verdict)
SELECT i.id, c.id, NULL
  FROM inspection i JOIN coverage c ON i.id = 'INSP-001'
ON CONFLICT DO NOTHING;

UPDATE inspection_coverage SET verdict = 'issues'
 WHERE inspection_id = 'INSP-001' AND coverage_id = 'checkout-flow'
RETURNING coverage_id, verdict;
```

Stamp `last_inspected_at` **only when the area was actually inspected** — the trigger fires
on that column alone, and re-saving risk or notes must not make a stale area read as fresh:

```sql
UPDATE coverage SET last_inspected_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE id = 'checkout-flow'
RETURNING id, last_inspected_at;
```

`verdict = 'not-reached'` is the honest answer for an area the inspection meant to cover and
ran out of road before it did. It is not NULL and it is not a pass.

---

## 7. Things not to do

- **Do not INSERT, UPDATE or DELETE `event` by hand.** The triggers write it. It is the
  guild's memory, and a memory you can edit is not one.
- **Do not set `updated_at` yourself** unless you mean to override the trigger.
- **Do not `DELETE FROM agent`.** Set `active = 0`.
- **Do not write your own readiness, cursor, gate or matcher logic.** Every one of them is a
  view, and a second spelling is a second answer.
- **Do not wrap a batch in `BEGIN … COMMIT` and assume atomicity.** A failing statement does
  not stop the script and the `COMMIT` still commits what landed. One logical change per
  invocation; read the state back after a non-zero exit.
- **Do not `cut -d'|'` a result that contains free text.** A newline in a title forges an
  entire row that looks completely legitimate.
