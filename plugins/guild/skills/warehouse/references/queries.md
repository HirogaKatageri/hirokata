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

Leave `agent` NULL and declare capabilities instead — that is what lets the dispatcher match
and what makes a roster gap visible. Set `agent` only when you mean to **pin** a specific
member; a pin skips the match entirely.

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

Check the words you used before you walk away — an unknown capability inserts fine and then
matches nobody, silently. **The check is not SQL**: the vocabulary is the agent files, so
nothing in the database can audit it.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py" --covers implement,frontend
```

At least one row back is the answer you want, and the first row is who will get the ticket.

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
INSERT INTO doc (slug, title, body, kind, status, area, source, created_at, updated_at)
VALUES ('adr-session-store', 'Sessions live in Redis',
        CAST(x'<hex-body>' AS TEXT), 'decision', 'current', 'auth', 'architect',
        strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'))
ON CONFLICT(slug) DO UPDATE SET
  title      = excluded.title,
  body       = excluded.body,
  kind       = excluded.kind,
  area       = excluded.area,
  source     = excluded.source,
  updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
RETURNING slug;
```

**`created_at` is not in the DO UPDATE list, and `status` is not either.** The first is a
birth date and an upsert must not reset it. The second is a *lifecycle*, moved by the
deliberate two-write supersession below — never as a side effect of somebody re-saving a
page.

**Pick `kind` on purpose.** It is the first thing every reader branches on:

| kind | for |
|---|---|
| `business` | the domain's own rules — what a refund *is*, when an account is dormant |
| `technical` | how a subsystem works right now |
| `decision` | **an ADR.** One choice, its context, its alternatives, its consequences |
| `research` | an external lookup the guild should not have to repeat |
| `runbook` | the steps for an operation somebody performs |
| `reference` | everything else. The default, and deliberately boring |

The slug is a **key**: someone has to retype it. Validate it against a closed alphabet at the
door rather than slugifying silently — storing `my-notes` for `My Notes` makes the next
lookup report not-found, which reads as data loss.

**The rewrite is snapshotted for you.** `trg_doc_revised` copies the OLD body into
`doc_revision` on every body change, so you never have to remember to keep history — and
the newest revision row is the text that came *before* the live one.

### Linking — the edge, and the referential check that is not a foreign key

`knowledge_edge` endpoints are polymorphic, so **there is no foreign key on either end**
(schema.sql, "cannot enforce" item 11). Write every edge as
`INSERT ... SELECT ... FROM <target table>` so a missing endpoint produces **zero rows
instead of a dangling edge** — the `FROM` clause *is* the check.

```sql
-- this decision governs REQ-004. If REQ-004 does not exist, nothing is written
INSERT INTO knowledge_edge (rel, from_type, from_id, to_type, to_id, note, created_by, created_at)
SELECT 'decides', 'doc', 'adr-session-store', 'requirement', r.id,
       CAST(x'<hex-note>' AS TEXT), 'architect', strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM requirement r WHERE r.id = 'REQ-004'
RETURNING id;
```

**Zero rows back means the target was not there.** That is the whole point of the shape, and
it is why `RETURNING` is not optional here — the write is otherwise indistinguishable from a
successful one.

The relations, and what each is for:

| rel | shape | means |
|---|---|---|
| `describes` | doc → work | this page explains that requirement/task/project |
| `decides` | doc → work | this **decision** governs that work |
| `supersedes` | doc → doc | **the evolution edge.** This replaces that |
| `refines` | doc → doc | a narrower topic under that one |
| `depends-on` | doc → doc | read that first |
| `contradicts` | doc → doc | these two disagree and somebody should resolve it |
| `derived-from` | doc → anything | provenance: this came out of that plan/finding/bug |
| `evidence-for` | anything → doc | that bug/finding is empirical support for this page |

The rel/type pairings are **CHECK constraints**, not conventions — `supersedes` between two
non-docs is refused by the engine. Verified on 0.7.2.

### Superseding a decision — two writes, and the order matters

Changing your mind is the single most valuable thing this library records, so it gets its own
recipe. **Never edit the old decision's body to say "we don't do this any more."** That
destroys the record of what was believed and substitutes a note about it.

```sql
-- 1. the new decision, as its own document
INSERT INTO doc (slug, title, body, kind, status, area, source, created_at, updated_at)
VALUES ('adr-session-store-v2', 'Sessions move to Postgres',
        CAST(x'<hex-body>' AS TEXT), 'decision', 'current', 'auth', 'architect',
        strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'))
RETURNING slug;

-- 2. the edge, which is what actually retires the old one
INSERT INTO knowledge_edge (rel, from_type, from_id, to_type, to_id, note, created_by, created_at)
SELECT 'supersedes', 'doc', 'adr-session-store-v2', 'doc', d.slug,
       CAST(x'<hex-reason>' AS TEXT), 'architect', strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM doc d WHERE d.slug = 'adr-session-store'
RETURNING id;

-- 3. optional, and only cosmetic
UPDATE doc SET status = 'superseded' WHERE slug = 'adr-session-store' RETURNING slug;
```

**Step 3 is optional on purpose.** `v_doc_current` hides a document that has an inbound
`supersedes` edge whatever its `status` says, so the edge alone is enough. Setting the status
makes the row read correctly on its own, which is worth doing — but the view does not depend
on you remembering.

**The old row stays.** A superseded decision is how the project's evolution is read;
`v_decision_log` lists it with `superseded_by` filled in.

### Reading the graph — one hop, because there is no `WITH RECURSIVE`

```sql
-- the neighbourhood: everything this page relates to, both directions, with titles
SELECT direction, rel, other_type, other_id, other_title, note
  FROM v_doc_neighbors WHERE slug = 'adr-session-store'
 ORDER BY direction, rel;

-- what this project decided, including what it un-decided
SELECT slug, title, status, supersedes, superseded_by, governs, revisions
  FROM v_decision_log;

-- how one page's text changed. The live body is in `doc`; these are what came before
SELECT id, replaced_at, title FROM doc_revision WHERE slug = 'refund-rules'
 ORDER BY replaced_at DESC;
SELECT body FROM doc_revision WHERE id = 12;   -- one column, so stdout IS the body
```

**A supersession chain three deep is three queries, not one.** `WITH RECURSIVE` is a parse
error on tursodb. Loop in the caller, one hop per round trip, and **cap the loop** — unlike
`graph_edge`, this graph is allowed to contain a cycle (`contradicts` and `depends-on` both
legitimately go both ways):

```bash
slug='adr-session-store'; seen=''; n=0
while [ -n "$slug" ] && [ "$n" -lt 20 ]; do
  case " $seen " in *" $slug "*) echo "cycle at $slug"; break;; esac
  seen="$seen $slug"; n=$((n+1))
  slug=$(printf "SELECT from_id FROM knowledge_edge
                  WHERE rel='supersedes' AND to_type='doc' AND to_id='%s' LIMIT 1;\n" "$slug" \
         | tursodb -q -m list "$DB")
done
```

### The two drift reads — documentation coverage as a query

```sql
-- the work moved and the page did not
SELECT slug, title, subject_type, subject_id, doc_updated_at, subject_moved_at
  FROM v_doc_stale;

-- shipped, and nobody wrote it down
SELECT id, title, finished_at, tasks_done FROM v_undocumented_work;

-- linked to nothing, so invisible to both of the above
SELECT slug, title, kind FROM v_doc_current WHERE edges = 0;
```

`v_doc_stale` emits **one row per (page, moved subject)**, so `COUNT(DISTINCT slug)` is the
number of pages needing attention — which is what `v_brief.docs_stale` reports.

**`v_knowledge_dangling` must always be empty.** It is a global invariant, it is the foreign
key the engine cannot give us, and `guild:validate` runs it. A non-empty result means
something an edge pointed at was deleted.

### Searching the library — no FTS5, so `LIKE` with escapes

```sql
SELECT slug, kind, title FROM doc
 WHERE status <> 'rejected'
   AND lower(title) || char(10) || lower(body) LIKE
       '%' || replace(replace(replace(lower('fail()'), '\', '\\'), '%', '\%'), '_', '\_') || '%'
       ESCAPE '\'
 ORDER BY kind, slug;
```

Escape the backslash **first**, so nothing introduced later gets double-escaped. Do it in
SQL, not the shell. `lower()` on both sides so behavior does not depend on the engine's
`case_sensitive_like` — its honest limit is that `lower()` is ASCII-only. **Refuse an empty
query**: it escapes to `%%` and quietly answers "everything".

**Filter by `kind` before you search when you know what you want.** "What are the business
rules for billing" is `WHERE kind = 'business' AND area = 'billing'` and needs no LIKE at all.
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

**This is an ILLUSTRATION of the shape, not the authoritative node list.** The template is —
`references/templates/standard.md` §6 for `standard`, `maintenance.md` for `maintenance` — and it
is what you copy from when instantiating a real graph. Keeping a second copy of the key list here
is exactly the drift this file warns about everywhere else, and a partial copy that *looks*
complete is worse than a pointer: `document` is in the required set, so a graph built from a
stale list silently drops a node that `G8` requires and ships the requirement undocumented, with
nothing failing until a later check-in.

```sql
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT r.id || '/' || j.value, r.id, j.value,
       CASE WHEN j.value LIKE 'gate-%' THEN 'gate' ELSE 'work' END,
       NULL, NULL, 'pending'
  FROM requirement r
  JOIN json_each(json_array('gate-plan','implement','test-plan','test-write',
                            'review','gate-repairs','repair','document')) j
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
        json_array('gate-repairs','repair'),
        json_array('repair','document'))) j
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

## 5. The roster — not in this database

**There is nothing to sync and no roster tables to write.** Who the guild's members are, what
each declares and whether one runs serially are facts about the agent FILES:

```bash
# every subagent available to the user: name | model | serial | scope | capabilities
python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py"

# just the members covering a ticket's REQUIRED set, already specialist-first
python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py" --covers implement,svelte
```

Adding a member is writing `agents/<name>.md` with `capabilities:` in its frontmatter. That
is the whole recruitment — no INSERT, no vocabulary to admit the word to, and it works on the
very next check-in. Retiring one is deleting or emptying that file; old tickets keep the name
in `task.agent` and `task.claimed_by`, which are plain TEXT precisely so history survives.

### Match an agent to a task

The match is **not a view** — the database cannot see the agent files. The rule lives in
check-in §3.3 and this is it:

1. `task.agent` set → dispatch that member, **do not run the match**.
2. Otherwise ELIGIBLE = the member's declared capabilities ⊇ the ticket's `required = 1` set.
3. Rank the eligible: preferred (`required = 0`) covered **DESC**, then total declared
   capabilities **ASC** (a specialist beats a generalist), then name **ASC** so the answer is
   deterministic. Dispatch rank 1.

Read the ticket's half out of SQL, then hand it to the scanner:

```sql
SELECT COALESCE(t.agent, '') AS pin,
       COALESCE((SELECT group_concat(c.capability || ':' || c.required, ' ')
                   FROM (SELECT capability, required FROM task_capability
                          WHERE task_id = t.id ORDER BY required DESC, capability) c), '') AS caps
  FROM task t WHERE t.id = 'TASK-001';
```

`implement:1 svelte:1 frontend:0` reads as "must have implement and svelte, prefers frontend".

**No output from `--covers`** for a ticket that declared capabilities is a **roster gap**, and
it is the entire reason for declaring them. Mark it blocked (below) — that write is the only
thing that makes the gap visible.

### There is no capability request

There is no row to file and no vocabulary to admit a word to. **The fix for a missing
capability is writing the agent file, and nothing precedes it.**

Record the gap where the guild master will actually see it: the plan's Technical Decisions
(it rides through `gate-plan`), and the board, as a `blocked` ticket whose `who` column reads
`needs:implement+rust`.

### Mark a task blocked when nobody can take it

Reading never does this, and **no view derives it** — skip this write and `v_open_bounties`
offers the ticket again every check-in. It is a decision, so it is a write somebody makes on
purpose, after the scan came back empty:

```sql
UPDATE task SET status = 'blocked'
 WHERE id = 'TASK-014' AND status = 'todo'
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
- **Do not DELETE anything.** Not a task, not a requirement, not a doc, not the `event` feed —
  the guild has no supported procedure that removes a record (**G11**, and §8 of
  `docs/expectations.md`). Work is retired by *status*: `done`, `cancelled`, `superseded`.
  A board that genuinely has to start over starts over as a **new database file**, with the old
  one moved aside and still readable. The one narrow exception is a `doc → doc` `knowledge_edge`
  rewritten while retiring a decision, and G11 is scoped to allow exactly that.
- **Do not write your own readiness, cursor, gate or matcher logic.** Every one of them is a
  view, and a second spelling is a second answer.
- **Do not wrap a batch in `BEGIN … COMMIT` and assume atomicity.** A failing statement does
  not stop the script and the `COMMIT` still commits what landed. One logical change per
  invocation; read the state back after a non-zero exit.
- **Do not `cut -d'|'` a result that contains free text.** A newline in a title forges an
  entire row that looks completely legitimate.
