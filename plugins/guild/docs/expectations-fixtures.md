# Guild v6 — Expectation Fixtures

`expectations.md` states what a member's work is checked against. Every expectation there is a
SQL assertion with an expected result, and an assertion is only meaningful against a **known
database state**. This file is those states.

Without them, every validation run seeds its own board and two runs of the same expectation
answer differently — not because the member behaved differently, but because the fixture did.
A fixture is the control.

**Six fixtures.** Each is a runnable SQL block, each has a one-line sanity query, and **every
one of them was applied to a real `tursodb` 0.7.2 database and its sanity query executed** —
the outputs quoted below are transcripts, not predictions. Section 9 is the verification log.

---

## 0. Running a fixture

### 0.1 The chain

The fixtures are not six unrelated databases. `planned` → `in-flight` is one requirement
moving, and `review-ready` and `messy` are two futures branching off the same in-flight board.
Loading is therefore ordered, and the order is short:

```
schema.sql ──▶ empty
                 │
                 └─ 00-roster ──▶ 02-planned ──▶ 03-in-flight ──┬──▶ 04-review-ready
                                                                │
                                                                └──▶ 05-messy
```

`empty` is `schema.sql` and nothing else — not even the roster. Every other fixture starts with
the roster block (§0.5), because a board with no members cannot match, cannot dispatch, and
cannot produce a roster gap, so almost nothing in the schema means anything without it.

### 0.2 The recipe

```bash
export PATH="$HOME/.turso:$PATH"
DB=/tmp/guild-fixture.db
rm -f "$DB" "$DB"-wal "$DB"-shm

tursodb "$DB" < schema.sql            # prints `wal` and exits 0 — that line is journal_mode
tursodb "$DB" < 00-roster.sql
tursodb "$DB" < 02-planned.sql
tursodb "$DB" < 03-in-flight.sql
tursodb "$DB" < 05-messy.sql          # → the `messy` fixture
```

Each fixture below is the contents of one of those files. Save them under those names, or paste
the block straight into `tursodb "$DB"` on stdin — they are ordinary SQL scripts with no shell
substitution left in them.

### 0.3 "It loaded" is a claim you have to check

`tursodb` has no `-bail`. **A failing statement does not stop the script, and a wrapping
`COMMIT` still commits what landed** (gotcha 8), and **errors are written to stdout, not
stderr** (gotcha 1a). So the only honest load check reads both channels:

```bash
out=$(tursodb "$DB" < 02-planned.sql 2>&1); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] || { echo "LOAD FAILED rc=$rc: $out"; exit 1; }
```

Every fixture script here is silent on success — none of them ends in a `SELECT` — so **any
output at all is an error**. The one exception is `schema.sql` itself, which prints `wal` from
`PRAGMA journal_mode`. Then run the fixture's sanity query and compare it to the stated result.
Both checks, every time: a script can exit 0 having written half of what it meant to.

### 0.4 What is deterministic here, and what is not

Fixed ISO timestamps are used everywhere they can be. Three things are deliberately relative to
`'now'`, because the views that read them compare against the wall clock and a frozen timestamp
would make them meaningless:

| value | fixture | why it must be relative |
|---|---|---|
| `task.claimed_at` on the in-flight ticket | in-flight | `v_in_flight.minutes` |
| `work_log.ts` on the in-flight ticket | in-flight | ordering against `claimed_at` |

Consequences, stated so nobody asserts on the wrong column:

- **Never assert on `v_in_flight.minutes`, `v_brief.generated_at`,
  or any `event.ts`.** They change between two reads of the same database. Assert on
  *membership and counts* instead — `COUNT(*) FROM v_in_flight`, which id is in it.
- `v_brief.events_since_checkin` counts every event while `last-checkin` is `'null'`, so it is
  a function of how many rows the fixture wrote. It is stable per fixture but brittle to any
  edit of the seed. Do not assert on it.
- **Load fixtures fresh.** A kept database drifts against every relative timestamp in it.

`task` and `requirement` ids are zero-padded to three digits, so text order is numeric order —
which is what makes `v_next_task`'s `ORDER BY id LIMIT 1` predictable.

### 0.5 The roster block — `00-roster.sql`

The 12 members from `agents/*.md` with their declared capabilities, verbatim. No member carries
`serial = 1` today. There is no free text in this block at all —
every value is a key from a closed alphabet (a name, a model, a capability token) and
descriptions are `''`, so nothing here needs the hex transport.

The `ON CONFLICT` clauses make it re-runnable, which matters because a validation harness will
load it more than once against the same scratch directory.

```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'orchestrator' WHERE key = 'actor';

INSERT INTO agent (name, model, description, active, serial) VALUES
  ('architect',               'opus',   '', 1, 0),
  ('developer',               'sonnet', '', 1, 0),
  ('developer-svelte',        'sonnet', '', 1, 0),
  ('product-owner',           'sonnet', '', 1, 0),
  ('product-reviewer',        'haiku',  '', 1, 0),
  ('researcher',              'haiku',  '', 1, 0),
  ('reviewer-architecture',   'haiku',  '', 1, 0),
  ('reviewer-business-logic', 'haiku',  '', 1, 0),
  ('reviewer-edge-case',      'haiku',  '', 1, 0),
  ('reviewer-security',       'haiku',  '', 1, 0),
  ('test-planner',            'sonnet', '', 1, 0),
  ('test-writer',             'sonnet', '', 1, 0)
ON CONFLICT(name) DO UPDATE SET model = excluded.model, active = 1, serial = excluded.serial;

INSERT INTO agent_capability (agent, capability) VALUES
  ('architect','architecture'),
  ('developer','implement'), ('developer','backend'), ('developer','frontend'),
  ('developer-svelte','implement'), ('developer-svelte','frontend'),
  ('developer-svelte','svelte'), ('developer-svelte','sveltekit'),
  ('product-owner','requirements'),
  ('product-reviewer','review'), ('product-reviewer','requirements'),
  ('researcher','research'),
  ('reviewer-architecture','review'), ('reviewer-architecture','architecture'),
  ('reviewer-business-logic','review'), ('reviewer-business-logic','business-logic'),
  ('reviewer-edge-case','review'), ('reviewer-edge-case','edge-case'),
  ('reviewer-security','review'), ('reviewer-security','security'),
  ('test-planner','test-planning'),
  ('test-writer','test-authoring')
ON CONFLICT DO NOTHING;
```

---

## 1. `empty` — a brand-new guild

**What it represents.** `schema.sql` applied to a fresh file and nothing else. No roster, no
goal, no task, no event. This is what a member sees on the first check-in of a new project, and
it is the fixture that catches the most embarrassing failure: a brief, a board or a dashboard
that reads an empty guild as a broken one, or that invents work to have something to say.

**Seed SQL.** None.

```bash
export PATH="$HOME/.turso:$PATH"
rm -f /tmp/guild-empty.db*
tursodb /tmp/guild-empty.db < schema.sql     # prints `wal`, exits 0
```

**Sanity query.**

```sql
SELECT (SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table')   AS tables,
       (SELECT COUNT(*) FROM sqlite_schema WHERE type = 'view')    AS views,
       (SELECT COUNT(*) FROM sqlite_schema WHERE type = 'trigger') AS triggers,
       (SELECT version FROM schema_version)                        AS ver,
       (SELECT COUNT(*) FROM v_capability_vocabulary)              AS vocab,
       (SELECT COUNT(*) FROM v_recent_activity)                    AS events;
```

**Expected result — exactly one row:**

```
25|26|43|5|17|0
```

21 tables, 25 views, 39 triggers, schema version 5, the 14 seed capability words, zero events.
A vocabulary of 17 on an empty board is the point: the words exist before any member does.

**The traps this fixture sets.**

- `v_next_task` returns **zero rows**, and `v_brief.next` reads `none`. That is "nothing to do",
  which is **not** "the project is finished" and not an error. A member that reports either is
  wrong.
- Every list view is empty — `v_board`, `v_open_bounties`, `v_blocked_tasks`, `v_ready_nodes`,
  `v_gates_pending`, `v_goal_progress`, `v_recent_activity` — but `v_brief` still returns its
  full **23 rows**, all counts `0`. A brief that returns nothing here has skipped the view.
- `guild_state.actor` is `'orchestrator'` and `last-checkin` is the literal string `'null'`,
  not SQL NULL. Code that tests `IS NULL` on it is wrong; `NULLIF(value,'null')` is the idiom
  the schema itself uses.

---

## 2. `planned` — approved nothing, built nothing

**Load:** `schema.sql` → `00-roster.sql` → `02-planned.sql`

**What it represents.** One goal, one phase, one requirement, a plan cut into three implement tickets, six
tickets, and a `standard` graph instantiated over it with **`gate-plan` still `pending`**. Not
one line of code has been written and nothing has been approved. This is the state a board is in
for the minutes between the architect finishing and the guild master answering.

**The free text is where the traps live.** `REQ-001`'s title is two lines and **the first line
ends in a semicolon**; its body is markdown containing a fenced TypeScript block whose lines end
in semicolons. Written as a quoted literal, the tursodb statement splitter tears it apart mid-
string (gotcha 1) — which is why every title, body, work-log entry, finding and gate prompt in
every fixture below travels as `CAST(x'…' AS TEXT)`. The hex is the honest form; a comment names
the value above each one where it is not obvious.

To regenerate that title's hex, or to check the one below:

```bash
printf '%s' 'Harden the session cookie: set secure = true;
and rotate the signing key on deploy' | xxd -p | tr -d '\n'
```

**Seed SQL — `02-planned.sql`:**
```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'product-owner' WHERE key = 'actor';

INSERT INTO goal (id, title, body, status, priority, created_at, updated_at)
VALUES ('GOAL-001', CAST(x'53686970207468652073746f726566726f6e74' AS TEXT), '', 'in-progress', 2,
        '2026-08-01T09:00:00Z', '2026-08-01T09:00:00Z');

INSERT INTO phase (id, goal_id, title, ordinal, status, created_at, updated_at)
VALUES ('PHASE-001', 'GOAL-001', CAST(x'436865636b6f757420616e64207061796d656e7473' AS TEXT), 1, 'in-progress',
        '2026-08-01T09:05:00Z', '2026-08-01T09:05:00Z');

INSERT INTO requirement (id, phase_id, title, body, status, priority, created_at, updated_at)
VALUES ('REQ-001', 'PHASE-001', CAST(x'48617264656e207468652073657373696f6e20636f6f6b69653a2073657420736563757265203d20747275653b0a616e6420726f7461746520746865207369676e696e67206b6579206f6e206465706c6f79' AS TEXT), CAST(x'232320416363657074616e63650a0a2d205365742d436f6f6b69652063617272696573205365637572652c20487474704f6e6c7920616e642053616d65536974653d4c61780a2d20546865207369676e696e67206b657920726f7461746573206f6e206576657279206465706c6f790a0a60606074730a636f6f6b69652e736563757265203d20747275653b0a636f6f6b69652e73616d6553697465203d20226c6178223b0a6060600a' AS TEXT),
        'todo', 2, '2026-08-01T09:10:00Z', '2026-08-01T09:10:00Z');

UPDATE guild_state SET value = 'architect' WHERE key = 'actor';

INSERT INTO plan (id, requirement_id, task_id, title, body, status, created_at, updated_at)
VALUES ('PLAN-001', 'REQ-001', NULL, CAST(x'496d706c656d656e746174696f6e20706c616e20666f72205245512d303031' AS TEXT), '', 'todo',
        '2026-08-01T09:20:00Z', '2026-08-01T09:20:00Z');

INSERT INTO task (id, requirement_id, plan_id, files, parallel_group,
                  node_key, title, objective, body, status, priority, agent,
                  claimed_by, claimed_at, created_at, updated_at) VALUES
  ('TASK-001','REQ-001','PLAN-001','["src/lib/server/cart.ts","src/lib/server/cookies.ts"]','wave-1','implement',
   CAST(x'436172742041504920e280942073657373696f6e20636f6f6b696520666c616773' AS TEXT),'','', 'todo',2,NULL,NULL,NULL,'2026-08-01T09:30:00Z','2026-08-01T09:30:00Z'),
  ('TASK-002','REQ-001','PLAN-001','["src/routes/cart/+page.svelte"]','wave-1','implement',
   CAST(x'4361727420554920e2809420737572666163652074686520726f746174696f6e206e6f74696365' AS TEXT),'','', 'todo',2,NULL,NULL,NULL,'2026-08-01T09:30:01Z','2026-08-01T09:30:01Z'),
  ('TASK-003','REQ-001','PLAN-001','["src/lib/server/promo.ts"]','wave-2','implement',
   CAST(x'50726f6d6f20656e67696e6520e280942072652d7369676e2070726f6d6f20746f6b656e73' AS TEXT),'','', 'todo',2,NULL,NULL,NULL,'2026-08-01T09:30:02Z','2026-08-01T09:30:02Z'),
  ('TASK-004','REQ-001','PLAN-001','[]',NULL,'test-plan',
   CAST(x'4465636c617265207465737420636f76657261676520666f72205245512d303031' AS TEXT),'','', 'todo',3,NULL,NULL,NULL,'2026-08-01T09:30:03Z','2026-08-01T09:30:03Z'),
  ('TASK-005','REQ-001','PLAN-001','[]',NULL,'test-write',
   CAST(x'417574686f722074686520737065637320666f72205245512d303031' AS TEXT),'','', 'todo',3,NULL,NULL,NULL,'2026-08-01T09:30:04Z','2026-08-01T09:30:04Z'),
  ('TASK-006','REQ-001','PLAN-001','[]','review','review',
   CAST(x'526576696577205245512d303031' AS TEXT),'','', 'todo',2,'reviewer',NULL,NULL,'2026-08-01T09:30:05Z','2026-08-01T09:30:05Z');

INSERT INTO task_capability (task_id, capability, required) VALUES
  ('TASK-001','implement',1), ('TASK-001','backend',1),
  ('TASK-002','implement',1), ('TASK-002','frontend',1), ('TASK-002','svelte',0),
  ('TASK-003','implement',1), ('TASK-003','backend',1),
  ('TASK-004','test-planning',1),
  ('TASK-005','test-authoring',1);

INSERT INTO task_dependency (task_id, depends_on) VALUES
  ('TASK-004','TASK-001'), ('TASK-004','TASK-002'), ('TASK-004','TASK-003'),
  ('TASK-005','TASK-004');

-- ---- the standard template, instantiated verbatim -----------------------------------
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-001/gate-plan', r.id, 'gate-plan', 'gate', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-001';

INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-001/implement.' || t.id, r.id, 'implement', 'work', t.id, t.parallel_group, 'pending'
FROM requirement r
JOIN task t ON t.requirement_id = r.id AND t.node_key = 'implement'
WHERE r.id = 'REQ-001';

INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-001/implement', r.id, 'implement', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-001'
  AND NOT EXISTS (SELECT 1 FROM task t
                   WHERE t.requirement_id = r.id AND t.node_key = 'implement');

INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-001/test-plan', r.id, 'test-plan', 'work', 'TASK-004', NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-001';

INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-001/test-write', r.id, 'test-write', 'work', 'TASK-005', NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-001';

INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-001/review.' || a.name, r.id, 'review', 'work',
       (SELECT MIN(t.id) FROM task t WHERE t.requirement_id = r.id AND t.agent = a.name),
       'review', 'pending'
FROM requirement r,
     (SELECT 'reviewer-security'       AS name
      UNION ALL SELECT 'reviewer-architecture'
      UNION ALL SELECT 'reviewer-business-logic'
      UNION ALL SELECT 'reviewer-edge-case') a
WHERE r.id = 'REQ-001';

INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-001/gate-repairs', r.id, 'gate-repairs', 'gate', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-001';

INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-001/repair-spec', r.id, 'repair-spec', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-001';

INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-001/repair-plan', r.id, 'repair-plan', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-001';

INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-001/gate-repair-plan', r.id, 'gate-repair-plan', 'gate', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-001';

INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-001/repair', r.id, 'repair', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-001';

INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-001' AND t.requirement_id = 'REQ-001'
  AND f.node_key = 'gate-plan' AND t.node_key = 'implement' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-001' AND t.requirement_id = 'REQ-001'
  AND f.node_key = 'implement' AND t.node_key = 'test-plan' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-001' AND t.requirement_id = 'REQ-001'
  AND f.node_key = 'test-plan' AND t.node_key = 'test-write' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-001' AND t.requirement_id = 'REQ-001'
  AND f.node_key = 'test-write' AND t.node_key = 'review' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-001' AND t.requirement_id = 'REQ-001'
  AND f.node_key = 'review' AND t.node_key = 'gate-repairs' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-001' AND t.requirement_id = 'REQ-001'
  AND f.node_key = 'gate-repairs' AND t.node_key = 'repair-spec' AND f.id <> t.id;

INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-001' AND t.requirement_id = 'REQ-001'
  AND f.node_key = 'repair-spec' AND t.node_key = 'repair-plan' AND f.id <> t.id;

INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-001' AND t.requirement_id = 'REQ-001'
  AND f.node_key = 'repair-plan' AND t.node_key = 'gate-repair-plan' AND f.id <> t.id;

INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-001' AND t.requirement_id = 'REQ-001'
  AND f.node_key = 'gate-repair-plan' AND t.node_key = 'repair' AND f.id <> t.id;

INSERT INTO gate (node_id, prompt, kind, status, decision, decided_at)
SELECT n.id, CAST(x'506c616e20666f72205245512d30303120697320726561647920666f72207265766965772e20417070726f766520696d706c656d656e746174696f6e3f' AS TEXT), 'approve', 'pending', NULL, NULL
FROM graph_node n WHERE n.requirement_id = 'REQ-001' AND n.node_key = 'gate-plan';

INSERT INTO gate (node_id, prompt, kind, status, decision, decided_at)
SELECT n.id, CAST(x'46696e64696e677320616e6420627567732066726f6d205245512d30303120e2809420617070726f7665207768696368206765742072657061697265642e' AS TEXT), 'select-findings', 'pending', NULL, NULL
FROM graph_node n WHERE n.requirement_id = 'REQ-001' AND n.node_key = 'gate-repairs';

INSERT INTO gate (node_id, prompt, kind, status, decision, decided_at)
SELECT n.id, CAST(x'52657061697220706c616e20666f72205245512d3030312069732072656164792e20417070726f766520696d706c656d656e746174696f6e3f' AS TEXT),
       'approve', 'pending', NULL, NULL
FROM graph_node n WHERE n.requirement_id = 'REQ-001' AND n.node_key = 'gate-repair-plan';

INSERT INTO guild_state (key, value) VALUES ('graph-template:REQ-001', 'standard')
ON CONFLICT(key) DO UPDATE SET value = excluded.value;

UPDATE guild_state SET value = 'orchestrator' WHERE key = 'actor';
```

**Sanity query.**

```sql
SELECT (SELECT COUNT(*) FROM graph_node WHERE requirement_id = 'REQ-001')  AS nodes,
       (SELECT COUNT(*) FROM graph_edge WHERE to_node LIKE 'REQ-001/%')    AS edges,
       (SELECT COUNT(*) FROM graph_node
         WHERE requirement_id = 'REQ-001' AND kind = 'gate')               AS gates,
       (SELECT COUNT(*) FROM v_gates_pending)                              AS gates_waiting,
       (SELECT COUNT(*) FROM task WHERE status <> 'todo')                  AS not_todo;
```

**Expected result — exactly one row:**

```
12|16|2|1|0
```

Three implement tickets, so `standard`'s arithmetic is N+12 nodes and 2N+13 edges: **15 and 19**, exactly
the numbers `standard.md` §1 tells the architect to check the INSERT against. `gates` is 2 —
not one, not three. `gates_waiting` is 1 because `gate-repairs` is buried behind four unfinished
review nodes and an undecided gate nobody can reach yet is not something to ask a human about.
`not_todo` is 0: nothing has moved.

**Verifying the transport actually worked** — this is the check that catches a silently torn
title, and it is worth running once on any board:

```sql
SELECT hex(title) FROM requirement WHERE id = 'REQ-001';
```

must equal the output of the `printf | xxd` above, case-insensitively. It does:

```
48617264656E207468652073657373696F6E20636F6F6B69653A2073657420736563757265203D20747275653B0A616E6420726F7461746520746865207369676E696E67206B6579206F6E206465706C6F79
```

**The trap this fixture sets — the important one.** `gate-plan` is `pending`, and yet:

```sql
SELECT id, priority, agent, who FROM v_open_bounties;
```

```
TASK-001|2|developer|needs:backend+implement
TASK-002|2|developer-svelte|needs:frontend+implement
TASK-003|2|developer|needs:backend+implement
```

**Three tickets are dispatchable while the plan is unapproved.** This is not a bug in
`v_open_bounties` — that view answers "who could take this", and it knows nothing about the
graph. Nothing in the schema connects a `task` to the `gate` that ought to precede it. A member
that reads the bounty board and starts building has done exactly what the board told it to, and
has still violated the process. **The only thing standing between this fixture and premature
work is the member checking `v_gates_pending` first**, which is why that is an expectation and
not a constraint.

Two smaller ones:

- `TASK-006` carries `agent = 'reviewer'` exactly, so `v_task_actionable`'s review gate holds it
  while any other non-reviewer ticket for `REQ-001` is open. It shows in `v_board` under
  `Backlog` and appears in **neither** `v_open_bounties` nor `v_blocked_tasks`. A dashboard that
  claims to show "everything not done" by unioning those two views will lose it.
- `TASK-002` prefers `svelte` but does not require it, so `developer-svelte` outranks
  `developer` on it while `developer` wins `TASK-001` and `TASK-003`. A member that hardcodes
  one developer for the whole requirement gets the wrong one twice.

---

## 3. `in-flight` — approved, two implement tickets done, one running

**Load:** `schema.sql` → `00-roster.sql` → `02-planned.sql` → `03-in-flight.sql`

**What it represents.** The guild master approved `gate-plan` (both writes: the `gate` row *and*
the `graph_node`, because setting `gate.status` moves nothing on its own). Two implement nodes
are `done` with work-log entries behind them, the third is `running`, and its ticket is claimed
and 45 minutes old.

**One deviation from the brief, stated plainly.** This fixture was asked for `test-plan` *ready*
alongside an unfinished implement node. **That state is unreachable, and the schema is right to
forbid it.** `test-plan` has an edge from every `implement.<task>` node — that cross-join edge
INSERT is what turns a fanned predecessor into a real barrier — so `v_ready_nodes` cannot offer
it while `implement.TASK-003` is `running`. Seeding it anyway would mean hand-writing a node
status the readiness rule contradicts, and the fixture would then be teaching the wrong lesson.

So this fixture ships with **zero ready work nodes**, and that is its most useful assertion: a
member that reports `test-plan` as runnable here has re-derived readiness by hand and got it
wrong. §3.1 shows the one write that legitimately releases it.

**Seed SQL — `03-in-flight.sql`:**
```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'user' WHERE key = 'actor';

UPDATE gate SET status = 'approved',
                decision = CAST(x'417070726f76656420e2809420746872656520736c696365732c20636172742d61706920616e6420636172742d756920696e206f6e6520776176652e' AS TEXT),
                decided_at = '2026-08-01T10:00:00Z'
 WHERE node_id = 'REQ-001/gate-plan' AND status = 'pending';

UPDATE graph_node SET status = 'done'
 WHERE id = 'REQ-001/gate-plan'
   AND (SELECT g.status FROM gate g WHERE g.node_id = graph_node.id) = 'approved';

UPDATE guild_state SET value = 'orchestrator' WHERE key = 'actor';

UPDATE requirement SET status = 'in-progress', updated_at = '2026-08-01T10:01:00Z'
 WHERE id = 'REQ-001';
UPDATE plan SET status = 'in-progress', updated_at = '2026-08-01T10:01:00Z'
 WHERE id = 'PLAN-001';

UPDATE task SET status = 'done', claimed_by = 'developer',
                claimed_at = '2026-08-01T10:02:00Z', updated_at = '2026-08-01T11:20:00Z'
 WHERE id = 'TASK-001';
UPDATE task SET status = 'done', claimed_by = 'developer-svelte',
                claimed_at = '2026-08-01T10:02:00Z', updated_at = '2026-08-01T11:35:00Z'
 WHERE id = 'TASK-002';
UPDATE task SET status = 'in-progress', claimed_by = 'developer',
                claimed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now','-45 minutes'),
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now','-45 minutes')
 WHERE id = 'TASK-003';

INSERT INTO work_log (task_id, ts, agent, entry) VALUES
  ('TASK-001','2026-08-01T11:20:00Z','developer',        CAST(x'5365742d436f6f6b6965206e6f7720656d697473205365637572652c20487474704f6e6c7920616e642053616d65536974653d4c61782e204275696c6420677265656e2e' AS TEXT)),
  ('TASK-002','2026-08-01T11:35:00Z','developer-svelte', CAST(x'526f746174696f6e206e6f7469636520616464656420746f20746865206361727420706167652e204275696c6420677265656e2e' AS TEXT)),
  ('TASK-003',strftime('%Y-%m-%dT%H:%M:%SZ','now','-40 minutes'),'developer', CAST(x'52652d7369676e696e67207468652070726f6d6f20746f6b656e2e20576f726b696e67207468726f75676820746865206c656761637920484d414320706174682e' AS TEXT));

UPDATE graph_node SET status = 'done'    WHERE id = 'REQ-001/implement.TASK-001';
UPDATE graph_node SET status = 'done'    WHERE id = 'REQ-001/implement.TASK-002';
UPDATE graph_node SET status = 'running' WHERE id = 'REQ-001/implement.TASK-003';
```

**Sanity query.**

```sql
SELECT (SELECT COUNT(*) FROM v_ready_nodes
         WHERE requirement_id = 'REQ-001' AND kind = 'work')     AS ready_work,
       (SELECT COALESCE((SELECT id     FROM v_next_task),'none')) AS next_id,
       (SELECT COALESCE((SELECT reason FROM v_next_task),'none')) AS next_reason,
       (SELECT COUNT(*) FROM v_in_flight)                         AS in_flight,
       (SELECT COUNT(*) FROM v_gates_pending)                     AS gates;
```

**Expected result — exactly one row:**

```
0|TASK-003|resume|1|0
```

`resume`, not `claim`: `v_next_task` finishes work already in flight before it starts anything
new, unconditionally. `gates` is 0 — `gate-plan` is decided and `gate-repairs` is still buried.

The full node state, for anyone diffing a member's understanding against the fixture:

```
REQ-001/gate-plan                      done
REQ-001/implement.TASK-001             done
REQ-001/implement.TASK-002              done
REQ-001/implement.TASK-003         running
REQ-001/test-plan                      pending
REQ-001/test-write                     pending
REQ-001/review.reviewer-architecture   pending
REQ-001/review.reviewer-business-logic pending
REQ-001/review.reviewer-edge-case      pending
REQ-001/review.reviewer-security       pending
REQ-001/gate-repairs                   pending
REQ-001/repair                         pending
```

### 3.1 Releasing the barrier

Two writes finish the third ticket, and `test-plan` becomes the only ready node. Run this against
a copy if you want to assert that the barrier releases rather than merely that it holds:

```sql
UPDATE task       SET status = 'done', updated_at = '2026-08-01T12:40:00Z' WHERE id = 'TASK-003';
UPDATE graph_node SET status = 'done' WHERE id = 'REQ-001/implement.TASK-003';
SELECT id, node_key FROM v_ready_nodes WHERE kind = 'work';
```

```
REQ-001/test-plan|test-plan
```

**The traps this fixture sets.**

- `v_in_flight.minutes` reads **45** the moment it loads and grows from there. It is wall-clock
  arithmetic. Assert on `COUNT(*)` and on which id is in flight, never on the number.
- `v_open_bounties` is empty here even though `TASK-004`, `TASK-005` and `TASK-006` are all
  `todo`, because 004 waits on 003, 005 waits on 004, and 006 is the held reviewer. "No
  bounties" and "nothing left to do" are different facts.
- The gate was approved with **two** writes. A fixture built by setting only `gate.status` would
  leave `REQ-001/gate-plan` at `pending` in `graph_node`, `v_ready_nodes` would still hold every
  implement node behind it, and the board would look stalled for no visible reason.

---

## 4. `review-ready` — everything built, four findings, waiting on a person

**Load:** `schema.sql` → `00-roster.sql` → `02-planned.sql` → `03-in-flight.sql` →
`04-review-ready.sql`

**What it represents.** Implementation, test plan and tests are all `done`, all four reviewers
have run and filed, and `gate-repairs` is `pending` **and reachable**. Every ticket on the board
is finished. The requirement is not.

The four findings are one of each severity, on purpose — `critical`, `major`, `minor`, `nit` —
so `v_open_findings.severity_rank` has something to order and a member cannot pass by accident
with a single-severity board. All four are `disposition = 'open'`: nothing has been triaged yet,
because triage is what the gate is for.

**Seed SQL — `04-review-ready.sql`:**
```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'orchestrator' WHERE key = 'actor';

UPDATE task SET status = 'done', updated_at = '2026-08-01T12:40:00Z' WHERE id = 'TASK-003';
UPDATE graph_node SET status = 'done' WHERE id = 'REQ-001/implement.TASK-003';

UPDATE task SET status = 'done', claimed_by = 'test-planner',
                claimed_at = '2026-08-01T12:45:00Z', updated_at = '2026-08-01T13:05:00Z'
 WHERE id = 'TASK-004';
UPDATE graph_node SET status = 'done' WHERE id = 'REQ-001/test-plan';

UPDATE task SET status = 'done', claimed_by = 'test-writer',
                claimed_at = '2026-08-01T13:10:00Z', updated_at = '2026-08-01T14:00:00Z'
 WHERE id = 'TASK-005';
UPDATE graph_node SET status = 'done' WHERE id = 'REQ-001/test-write';

INSERT INTO work_log (task_id, ts, agent, entry) VALUES
  ('TASK-003','2026-08-01T12:40:00Z','developer',    CAST(x'50726f6d6f20746f6b656e732072652d7369676e65642e204c656761637920484d414320706174682072656d6f7665642e204275696c6420677265656e2e' AS TEXT)),
  ('TASK-004','2026-08-01T13:05:00Z','test-planner', CAST(x'4465636c61726564203131206265686176696f757273206163726f737320332073706563732e2054776f2061726520626f756e64617279206361736573206f6e2070726f6d6f206578706972792e' AS TEXT)),
  ('TASK-005','2026-08-01T14:00:00Z','test-writer',  CAST(x'57726f7465206532652f636172742e737065632e74732c206532652f636f6f6b69652e737065632e747320616e64206532652f70726f6d6f2e737065632e74732e20416c6c20677265656e2e' AS TEXT));

UPDATE task SET status = 'done', updated_at = '2026-08-01T14:50:00Z' WHERE id = 'TASK-006';
UPDATE graph_node SET status = 'done'
 WHERE requirement_id = 'REQ-001' AND node_key = 'review';

INSERT INTO review_finding (task_id, reviewer, severity, summary, detail, file, line,
                            disposition, fix_task_id, created_at) VALUES
  ('TASK-001','reviewer-security','critical',
   CAST(x'43617274206c6f6f6b757020696e746572706f6c61746573207468652073657373696f6e20696420696e746f2053514c' AS TEXT), CAST(x'7372632f6c69622f7365727665722f636172742e7473206275696c647320746865207175657279207769746820737472696e6720636f6e636174656e6174696f6e2e20557365206120626f756e6420706172616d657465722e' AS TEXT),'src/lib/server/cart.ts',88,
   'open',NULL,'2026-08-01T14:45:00Z'),
  ('TASK-003','reviewer-edge-case','major',
   CAST(x'50726f6d6f20636f64652077697468207175616e7469747920302064697669646573206279207a65726f' AS TEXT), CAST(x'412063617274206c696e652077697468207175616e746974792030207265616368657320746865207065722d756e697420646973636f756e742063616c63756c6174696f6e20616e64207261697365732e' AS TEXT),'src/lib/server/promo.ts',142,
   'open',NULL,'2026-08-01T14:46:00Z'),
  ('TASK-002','reviewer-architecture','minor',
   CAST(x'54686520636172742070616765207265616368657320696e746f20746865207365727665722073746f7265206469726563746c79' AS TEXT), CAST(x'54686520636f6d706f6e656e7420696d706f7274732066726f6d206c69622f7365727665722e20526f757465207468652064617461207468726f75676820746865206c6f61642066756e6374696f6e2e' AS TEXT),'src/routes/cart/+page.svelte',12,
   'open',NULL,'2026-08-01T14:47:00Z'),
  ('TASK-002','reviewer-business-logic','nit',
   CAST(x'436f7079207361797320636172742077686572652074686520726571756972656d656e742073617973206261736b6574' AS TEXT), CAST(x'436f736d657469632e2054686520726571756972656d656e742075736573206261736b6574207468726f7567686f75742e' AS TEXT),'src/routes/cart/+page.svelte',30,
   'open',NULL,'2026-08-01T14:48:00Z');
```

**Sanity query.**

```sql
SELECT (SELECT COUNT(*) FROM v_open_findings)                        AS findings,
       (SELECT COALESCE((SELECT node_id FROM v_gates_pending),'none')) AS gate,
       (SELECT COUNT(*) FROM v_ready_nodes WHERE kind = 'work')      AS ready_work,
       (SELECT COALESCE((SELECT id FROM v_next_task),'none'))        AS next;
```

**Expected result — exactly one row:**

```
4|REQ-001/gate-repairs|0|none
```

**The trap this fixture sets — the false green.** `v_next_task` says `none`. `v_open_bounties`
is empty. `v_board` shows six tasks under *Recently Completed* and nothing anywhere else.
`v_requirement_progress` reads `6|6|0|0|0` — six tasks, six done, zero open, zero blocked, zero
failed. **Every surface a lazy reader looks at says the requirement is finished**, and it is not:
there is a critical SQL-injection finding open and a human has not decided anything.

Two ways a member fails here, and both look like success:

1. It closes `REQ-001` because `tasks_open = 0`. The counter is real, but it counts *tasks* —
   findings are not tasks and never appear in it.
2. It walks past `gate-repairs` and starts repairing, or worse, calls the requirement done. The
   gate is a column anyone can write (`v6-architecture.md` §4, item 6); nothing stops the UPDATE.

The assertion that catches both is the same one: `v_gates_pending` must be **empty** before a
requirement closes, and `v_open_findings` must be **empty or fully dispositioned**.

Also worth asserting: the four `review.*` nodes are `done` but their `task_id` is **NULL**. The
`standard` template binds a review node to `(SELECT MIN(t.id) … WHERE t.agent = a.name)`, and no
ticket on this board carries `agent = 'reviewer-security'` — the single `reviewer` ticket
(`TASK-006`) is fanned out to the four specialists at dispatch. An unbound review node is
correct here, not a broken graph, and a validator that treats `task_id IS NULL` on a `done` node
as an error will fail every well-formed `standard` graph in existence.

---

## 5. `messy` — the fixture the brief and the dashboard are actually judged on

**Load:** `schema.sql` → `00-roster.sql` → `02-planned.sql` → `03-in-flight.sql` →
`05-messy.sql`

`messy` branches off `in-flight`, not off `review-ready`. It is the same board a week later,
after things went wrong.

**What it represents — and why it exists.** An empty guild flatters every surface. A brief with
nothing to report is a brief that cannot be wrong; a dashboard with one row renders beautifully.
This fixture is the one that separates a narrator from a template, because it holds every
awkward shape at once:

| what | where |
|---|---|
| a failed task nobody has ruled on | `TASK-007` — agent report in the work log, no waiver |
| a failed task the user waived | `TASK-008` — a second log line prefixed `Skipped by user` |
| a blocked task nobody can take | `TASK-009` — requires `rust`, status already `blocked` |
| a task with a capability nobody covers | `TASK-010` — requires `embedded`, still `todo` |
| tasks stuck behind an unfinished predecessor | `TASK-004`, `TASK-005`, `TASK-011` |
| one genuinely dispatchable bounty | `TASK-012` |
| a review ticket held by the review gate | `TASK-006` |
| an open bug with no fix task | `BUG-001` |
| a bug being fixed, linked to its fix ticket | `BUG-002` → `TASK-012` |
| an open roster gap | the `rust` capability request |
| a requirement with no tasks and no graph | `REQ-002` |

**`BUG-001`'s title is the second transport trap**: it contains a pipe *and* a newline, and the
second line is shaped exactly like a `-m list` row (`TASK-999|done|Ship it`). §5.1 shows it
firing.

**Seed SQL — `05-messy.sql`:**
```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'orchestrator' WHERE key = 'actor';

-- a second requirement, queued, with no tasks and no graph
INSERT INTO requirement (id, phase_id, title, body, status, priority, created_at, updated_at)
VALUES ('REQ-002', 'PHASE-001', CAST(x'53756e73657420746865206c65676163792070726f6d6f2073657276696365' AS TEXT), '', 'todo', 4,
        '2026-08-02T08:00:00Z', '2026-08-02T08:00:00Z');

INSERT INTO task (id, requirement_id, plan_id, files, parallel_group,
                  node_key, title, objective, body, status, priority, agent,
                  claimed_by, claimed_at, created_at, updated_at) VALUES
  ('TASK-007','REQ-001','PLAN-001','[]',NULL,NULL, CAST(x'4261636b66696c6c207468652070726f6d6f20617564697420726f7773'  AS TEXT),'','','todo',3,NULL,NULL,NULL,'2026-08-02T09:00:00Z','2026-08-02T09:00:00Z'),
  ('TASK-008','REQ-001','PLAN-001','[]',NULL,NULL, CAST(x'4d69677261746520746865206c656761637920636f75706f6e207461626c65'  AS TEXT),'','','todo',3,NULL,NULL,NULL,'2026-08-02T09:00:01Z','2026-08-02T09:00:01Z'),
  ('TASK-009','REQ-001','PLAN-001','[]',NULL,NULL, CAST(x'506f7274207468652070726963696e67206b65726e656c20746f2052757374'  AS TEXT),'','','todo',2,NULL,NULL,NULL,'2026-08-02T09:00:02Z','2026-08-02T09:00:02Z'),
  ('TASK-010','REQ-001','PLAN-001','[]',NULL,NULL, CAST(x'466c6173682074686520696e2d73746f7265207465726d696e616c206669726d77617265' AS TEXT),'','','todo',3,NULL,NULL,NULL,'2026-08-02T09:00:03Z','2026-08-02T09:00:03Z'),
  ('TASK-011','REQ-001','PLAN-001','[]',NULL,NULL, CAST(x'57697265207468652070726f6d6f20776562686f6f6b' AS TEXT),'','','todo',3,NULL,NULL,NULL,'2026-08-02T09:00:04Z','2026-08-02T09:00:04Z'),
  ('TASK-012','REQ-001','PLAN-001','[]',NULL,NULL, CAST(x'46697820746865206361727420726174652d6c696d697420627970617373' AS TEXT),'','','todo',1,NULL,NULL,NULL,'2026-08-02T09:00:05Z','2026-08-02T09:00:05Z');

INSERT INTO task_capability (task_id, capability, required) VALUES
  ('TASK-007','implement',1), ('TASK-007','backend',1),
  ('TASK-008','implement',1), ('TASK-008','backend',1),
  ('TASK-009','rust',1),
  ('TASK-010','embedded',1),
  ('TASK-011','implement',1), ('TASK-011','backend',1),
  ('TASK-012','implement',1), ('TASK-012','backend',1);

INSERT INTO task_dependency (task_id, depends_on) VALUES ('TASK-011','TASK-003');

-- two failures: one un-adjudicated, one waived by the user
UPDATE task SET status = 'failed', claimed_by = 'developer',
                claimed_at = '2026-08-02T09:10:00Z', updated_at = '2026-08-02T09:55:00Z'
 WHERE id = 'TASK-007';
UPDATE task SET status = 'failed', claimed_by = 'developer',
                claimed_at = '2026-08-02T10:00:00Z', updated_at = '2026-08-02T10:30:00Z'
 WHERE id = 'TASK-008';

INSERT INTO work_log (task_id, ts, agent, entry) VALUES
  ('TASK-007','2026-08-02T09:55:00Z','developer',    CAST(x'4261636b66696c6c2061626f727465642061667465722031326b206f66203438306b20726f77732e20546865206175646974207772697465722072656a656374732061204e554c4c206163746f7220616e6420746865206c656761637920726f77732068617665206e6f6e652e204e656564732061206465636973696f6e206f6e206120706c616365686f6c646572206163746f72206265666f726520746869732063616e2072756e2e'  AS TEXT)),
  ('TASK-008','2026-08-02T10:30:00Z','developer',    CAST(x'4d6967726174696f6e20736372697074206661696c73206f6e2074686520636f6d706f73697465206b65792e20546865206c6567616379207461626c6520686173206475706c69636174652028636f64652c20726567696f6e292070616972732e'  AS TEXT)),
  ('TASK-008','2026-08-02T10:40:00Z','orchestrator', CAST(x'536b6970706564206279207573657220e2809420746865206c656761637920636f75706f6e207461626c65206973206265696e672064726f7070656420696e205245512d30303220696e73746561642e' AS TEXT));

-- a roster gap somebody already ruled on: nobody covers rust
UPDATE task SET status = 'blocked', updated_at = '2026-08-02T09:20:00Z' WHERE id = 'TASK-009';

INSERT INTO capability_request (capability, requirement_id, rationale, proposed_agent,
                                proposed_spec, status, created_at)
VALUES ('rust', 'REQ-001', CAST(x'546872656520706c616e20736c6963657320696e20746865206e657874207068617365206172652052757374206372617465732e2054686520646576656c6f706572206d656d62657220686173206e6f2052757374206964696f6d2067756964616e636520616e6420776f756c642070726f64756365206e6f6e2d6964696f6d61746963206572726f722068616e646c696e672e' AS TEXT), 'developer-rust',
        CAST(x'5275737420696d706c656d656e7465722e20546f6f6c733a20526561642c2057726974652c20456469742c20426173682e204d6f64656c3a20736f6e6e65742e' AS TEXT), 'open', '2026-08-02T09:25:00Z');

-- bugs
INSERT INTO bug (id, title, body, repro, severity, status, found_by, requirement_id,
                 fix_task_id, created_at, updated_at) VALUES
  ('BUG-001', CAST(x'436865636b6f757420746f74616c2077726f6e6720666f7220617c622070726f6d6f20636f6465730a5441534b2d3939397c646f6e657c53686970206974' AS TEXT), CAST(x'412070726f6d6f20636f646520636f6e7461696e696e67206120706970652069732073706c6974206279207468652070617273657220616e64206f6e6c79207468652066697273742068616c66206973206170706c6965642e' AS TEXT), CAST(x'4170706c792070726f6d6f20636f646520225341564531307c45552220746f20612063617274206f662033206974656d732e20546f74616c20697320646973636f756e7465642062792031302070657263656e742074776963652e' AS TEXT),
   'critical','open','reviewer-security','REQ-001',NULL,'2026-08-02T11:00:00Z','2026-08-02T11:00:00Z'),
  ('BUG-002', CAST(x'52617465206c696d6974206f6e202f636172742063616e2062652062797061737365642077697468206120747261696c696e6720736c617368' AS TEXT), '', '',
   'major','fixing','reviewer-edge-case','REQ-001','TASK-012','2026-08-02T11:05:00Z','2026-08-02T11:20:00Z');

```

**Sanity query.**

```sql
SELECT (SELECT COUNT(*) FROM v_open_bounties)               AS bounties,
       (SELECT COUNT(*) FROM v_blocked_tasks)               AS stuck,
       (SELECT COUNT(*) FROM v_failed_tasks WHERE waived=0) AS unadjudicated,
       (SELECT COUNT(*) FROM v_open_bugs)                   AS bugs,
       (SELECT COUNT(*) FROM v_roster_gaps)                 AS gaps;
```

**Expected result — exactly one row:**

```
1|5|1|2|2|1
```

### 5.1 The pipe-and-newline trap, firing

A naive read of two bugs:

```sql
SELECT id, severity, status, title FROM v_open_bugs;
```

```
BUG-001|critical|open|Checkout total wrong for a|b promo codes
TASK-999|done|Ship it
BUG-002|major|fixing|Rate limit on /cart can be bypassed with a trailing slash
```

**Three lines for two bugs**, and the middle one is a row that does not exist. Pull the status
column out positionally and the forgery lands in your data:

```bash
… | cut -d'|' -f3
```
```
open
Ship it
fixing
```

The fix is server-side flattening, in SQL, before the value leaves the engine — lossy on
purpose, because a columnar surface is for scanning:

```sql
SELECT id, severity, status,
       replace(replace(replace(title, char(10),' '), char(13),' '), '|','!')
  FROM v_open_bugs;
```
```
BUG-001|critical|open|Checkout total wrong for a!b promo codes TASK-999!done!Ship it
BUG-002|major|fixing|Rate limit on /cart can be bypassed with a trailing slash
```

The value itself is intact — `SELECT hex(title) FROM bug WHERE id='BUG-001'` round-trips
byte-for-byte against the `printf | xxd` that produced it. Only the rendering was ever lossy.

### 5.2 The reference readings

These are the shapes a brief or a dashboard has to get right. They are transcripts.

**Why each stuck ticket is stuck** — `reason` is one blank-free token by design, and the
ordering of that `CASE` matters: `TASK-009` reports `status-blocked` rather than its missing
capability, because a human already ruled on it and the status is that ruling.

```sql
SELECT id, status, reason, who FROM v_blocked_tasks;
```
```
TASK-004|todo|deps:TASK-003|needs:test-planning
TASK-005|todo|deps:TASK-004|needs:test-authoring
TASK-009|blocked|status-blocked|needs:rust
TASK-010|todo|no-eligible-agent:embedded|needs:embedded
TASK-011|todo|deps:TASK-003|needs:backend+implement
```

**The two failures, and which one still owes a decision.** `waived` is read back from a
work-log line's *prefix* — a marker, not a column (`v6-architecture.md` §4, item 3). Note that
`reason` is the **agent's report**, not the waiver: `v_failed_tasks` deliberately skips the
`Skipped by user…` line so the one fact a reader cannot get from the status survives.

```sql
SELECT id, waived, who,
       replace(replace(COALESCE(reason,'(none)'), char(10),' '), '|','!')
  FROM v_failed_tasks;
```
```
TASK-007|0|needs:backend+implement|Backfill aborted after 12k of 480k rows. …
TASK-008|1|needs:backend+implement|Migration script fails on the composite key. …
```

**The roster gap, and the word that is not in the vocabulary.** `rust` and `embedded` are both
outside the seed list, but only `embedded` is reported unknown — filing the `rust` capability
request is what admitted the word, and `v_capability_vocabulary` unions in every non-declined
request. That is the whole mechanism, visible in one query:

```sql
SELECT side, owner, capability FROM v_capability_unknown;
SELECT id, capability, proposed_agent, covered_by FROM v_roster_gaps;
```
```
task|TASK-010|embedded

1|rust|developer-rust|0
```

`covered_by = 0` means the gap is real. A non-zero count on an open request would mean somebody
filled it and never closed the request.

**The brief, in full.** Every count below is derived from the same views the detail listings
come from, so a count and its listing cannot disagree — which is exactly what makes a
disagreement a finding.

```
next|TASK-003                bounties_open|1
next_reason|resume           bounties_stuck|5
tasks_in_progress|1          requirements_open|2
tasks_todo|6                 requirements_done|0
tasks_blocked|1              bugs_open|2
tasks_failed|2               findings_open|0
tasks_failed_waived|1        roster_gaps|1
tasks_done|2                 capability_unknown|1
                             nodes_ready|0
                             gates_pending|0
```

### 5.3 The traps this fixture sets

- **`tasks_todo` is 6 but `bounties_open` is 1.** Five of the six cannot be handed to anybody
  right now. A brief that reports the backlog count as available work is wrong by 500%.
- **`TASK-006` is in neither bounty view.** It is `todo`, it has no dependencies, and it is
  invisible to both `v_open_bounties` (the review gate holds it) and `v_blocked_tasks` (no
  clause matches a gated reviewer). `tasks_todo` (6) is not `bounties_open` + `bounties_stuck`
  restricted to todo (1 + 4). A dashboard that builds "everything outstanding" by unioning the
  two bounty views **silently drops the review ticket**. Union `v_board` sections instead.
- **`nodes_ready` is 0 and `gates_pending` is 0 on a board with 6 todo tasks.** The graph is
  parked behind a running node. "Nothing ready" here means "wait", not "ask a human" and not
  "finished" — three different conclusions from one zero.
- **`REQ-002` has no tasks and no graph.** `v_requirement_progress` gives it `0|0|0|0|0`. A
  renderer dividing done-by-total to draw a progress bar divides by zero here.
- **`BUG-001` has no `fix_task_id`.** That is correct while it is `open` — a bug earns a fix
  task when a gate approves the repair, not when it is filed. `BUG-002` shows the other half:
  `fixing`, linked to `TASK-012`. An assertion that every open bug has a fix task would be
  wrong; an assertion that every bug in `fixing` has one is right.
- **`TASK-009` is `blocked`, so it holds the review gate.** That is deliberate — `blocked` is a
  machine verdict nobody has looked at, while `failed` has been adjudicated. Between a failure
  that hides and one that shouts, the schema takes the one that shouts.

---

## 6. Which fixture catches which failure

Every row is a failure mode from `expectations.md`. The fixture named is the one where that
failure is *visible* — where a member doing the wrong thing produces a different answer than a
member doing the right one. A failure mode with no fixture is a failure mode nothing tests.

| failure mode | fixture | what makes it visible |
|---|---|---|
| building before `gate-plan` is approved | **planned** | 3 dispatchable bounties, gate `pending` |
| advancing past an unresolved gate | **review-ready** | every ticket done, `gate-repairs` pending, `next = none` |
| re-deriving readiness instead of reading `v_ready_nodes` | **in-flight** | `test-plan` looks next; the barrier says no |
| re-deriving the review gate | **planned**, **messy** | `TASK-006` is in neither bounty view |
| free text without the hex transport | **planned** | `REQ-001` title, first line ends in `;` |
| parsing `-m list` positionally | **messy** | `BUG-001` forges a whole row |
| inventing a status / severity / capability | **all** | `CHECK` rejects it — the one class the engine catches |
| a capability outside the vocabulary | **messy** | `embedded` reported, `rust` admitted by its request |
| a task with no requirement | **none — cannot happen** | `requirement_id` is `NOT NULL REFERENCES` |
| a graph node with no edges | **messy**, **maintenance** | `REQ-002` has no graph at all — the honest orphan case |
| a bug with no fix task once approved | **messy** | `BUG-001` open/unlinked vs `BUG-002` fixing/linked |
| a finding with no disposition | **review-ready** | four `open` findings, none triaged |
| dispatching by hardcoded agent name | **planned**, **messy** | `TASK-002` prefers `svelte`, 001/003 do not |
| a requirement closed over open tasks | **messy** | `REQ-001` `tasks_open = 6`, `tasks_blocked = 1` |
| a requirement closed over a *blocked* task | **messy** | `TASK-009` — `tasks_blocked` is its own column for this |
| more than one tester at a time | **maintenance** | `TASK-904` is a live bounty for a `serial = 1` member |
| an empty guild read as a broken one | **empty** | `v_brief` returns 23 rows of zeros, not zero rows |

Two rows in that table say **"cannot happen"** or **"the engine catches it"**, and they are the
useful ones to know about: an orphan task and a bad status word are enforced by
`NOT NULL REFERENCES` and by `CHECK`, on every connection, forever. Do not spend an expectation
on them. Spend expectations on the eight items in `v6-architecture.md` §4, which nothing
enforces at all.

---

## 7. What these fixtures cannot do

Honest limits, so nobody reads a passing fixture as more than it is.

**A fixture cannot assert a judgment.** Whether `reviewer-security`'s finding is *correct*,
whether the architect's three implement tickets are the right three, whether a mission actually exercised
the checkout flow or just loaded the page — none of that is in the database, and no query will
find it. The fixtures can assert that a finding was *filed with a severity and a file and a
line*; they cannot assert it was worth filing.

**A fixture cannot detect a lying actor.** `guild_state.actor` is a label. Every event in
`messy` attributed to `developer` was written by whoever ran the script. This is item 1 of §4
and the single biggest thing v6 gave up; it is not testable in SQL, at all, by anyone.

**A fixture cannot check file disjointness.** `task.files` in `planned` are disjoint
because I wrote them that way. Nothing verifies it, here or in the schema, and two tickets
sharing a file would load without complaint and produce a merge conflict inside an unattended
shift.

**A fixture cannot prove the graph is acyclic.** With no `WITH RECURSIVE`, a cycle is not
detectable in one query. It manifests as `v_ready_nodes` returning nothing for the whole loop —
a silent stall that looks exactly like `in-flight`'s legitimate "nothing ready, wait for the
running node". Distinguishing them is a review duty. **No fixture here contains a cycle**,
because a fixture whose correct behaviour is indistinguishable from a defect teaches nothing.

**A fixture cannot cover concurrency.** Every one of these is a single-connection load. Two
members writing at once — the actual failure mode behind `busy_timeout` and the `serial` flag —
is not reproducible from a seed script.

**These are not the only states worth having.** Deliberately absent, and each is a real gap:
a graph with a recorded `graph_deviation`; a `select-findings` gate that has been *decided*,
with repair tickets fanned out from `gate.decision`; a board with two requirements running
concurrently, which is where the review gate's per-requirement scoping earns its keep; a
`declined` capability request, which is the only way a word leaves the vocabulary. Add them when
an expectation needs them, not before — an unused fixture rots.

---

## 8. Verification log

Everything above was run. Binary: `~/.turso/tursodb`, **Turso 0.7.2**, macOS.

| fixture | load chain | exit | stdout on load | sanity query result |
|---|---|---|---|---|
| `empty` | `schema.sql` | 0 | `wal` | `25\|26\|43\|5\|17\|0` |
| `planned` | + `00`, `02` | 0 | *(silent)* | `12\|16\|2\|1\|0` |
| `in-flight` | + `03` | 0 | *(silent)* | `0\|TASK-003\|resume\|1\|0` |
| `review-ready` | + `04` | 0 | *(silent)* | `4\|REQ-001/gate-repairs\|0\|none` |
| `messy` | `00`, `02`, `03`, `05` | 0 | *(silent)* | `1\|5\|1\|2\|2\|1` |
| `maintenance` | `00`, `06` | 0 | *(silent)* | `6\|5\|1\|1` |

Also verified, in the same session:

- **`schema.sql` is idempotent** — applied twice to the same file, exit 0 both times, `wal` both
  times, no error on either.
- **Both trap values round-trip byte-exact.** `hex(title)` for `REQ-001` and for `BUG-001` each
  equal the output of the `printf … | xxd -p | tr -d '\n'` that produced them.
- **The `-m list` forgery reproduces.** `SELECT id, severity, status, title FROM v_open_bugs`
  emits 3 lines for 2 rows, and `cut -d'|' -f3` returns `open / Ship it / fixing`.
- **The `test-plan` barrier releases** on the two writes in §3.1, and `v_ready_nodes` then
  returns exactly `REQ-001/test-plan`.

Every load was checked for a non-zero exit **and** for non-empty stdout, because tursodb writes
errors to stdout and keeps going after one (gotchas 1a and 8). A fixture that "loaded fine"
without both checks has not been checked.
