# Guild v6 — Expectations

**Status:** current
**Companion to:** [`v6-architecture.md`](./v6-architecture.md) (the pivot), [`v5-design.md`](./v5-design.md) (the data model), [`../schema.sql`](../schema.sql) (the tool)
**Applies to:** tursodb 0.7.2, `schema_version = 5`

---

## 1. Purpose and how to use it

### What this document validates

v6 deleted a 31,348-line bash CLI and the 8,918-line test harness that came with it. Nothing
replaced the harness, and nothing should have — **there is no code left to unit-test.** The
plugin ships a schema and a body of knowledge. Everything that used to be a function is now
either a CHECK, a view, a trigger, or a paragraph a member is expected to read and act on.

So the thing that can fail changed. The failure mode is no longer "the function returned the
wrong value". It is:

> **An AI member read the schema and the process, understood some of it, and did something
> adjacent to what was needed.**

This document is the specification that catches that. It asserts that a member *understood the
schema and the process and did what was needed*. It does **not** assert that code works, that a
feature is correct, or that a test passes — the guild has reviewers, testers and a QA discipline
for that, and they operate on the product, not on the board.

Because the data model is a database, an expectation here is never prose to be interpreted. It
is a **SQL assertion with a stated expected result.** That is the property that makes this
document real rather than aspirational: every assertion below has been executed against a
scratch database seeded with a fixture, confirmed to return zero rows on a healthy board, and
confirmed to *fire* when the corresponding failure is injected. An assertion that has never been
seen to fail is not an assertion, it is a wish.

### The two ways this document gets used

**As a CONTRACT — while a skill is being written or reviewed.**

Before a skill is written, its section here says what the board must look like when it finishes.
The author writes to the postconditions rather than discovering them. During review, the section
is the checklist: every postcondition must be reachable by the SQL the skill actually contains,
and every anti-expectation must be impossible for it to produce. A skill that cannot satisfy its
section is not ready, and a skill whose section has no postconditions has not been specified.

**As a CHECK — after a skill runs, against the live database.**

```bash
export PATH="$HOME/.turso:$PATH"
tursodb .guild/guild.db < /path/to/assertion.sql
```

Every assertion in this document is written to return **zero rows when healthy** and the
offending rows when not, so a failure names its own cause. That shape is deliberate: a boolean
`FAIL` tells you to go looking, whereas `finding-open-past-gate-repairs | 1 | REQ-001` tells you
which row, which requirement, and which rule. Wire it up so that *any output at all* is a
failure:

```bash
out=$(tursodb .guild/guild.db < assertion.sql)
[ -z "$out" ] || { echo "EXPECTATION VIOLATED:"; echo "$out"; exit 1; }
```

Run **§3 (global invariants) after every skill, always.** Run the skill's own process section
after that skill specifically.

### Why the check cannot be skipped: the exit code is not evidence

The most important thing to understand before trusting any member's report of success. The
tursodb stdin splitter ends a statement at a `;` that terminates a line — *even inside an open
string literal.* A requirement body that quotes code contains such lines. Here is a real script,
run as written:

```sql
BEGIN;
INSERT INTO goal (...) VALUES ('GOAL-001', ...);
INSERT INTO phase (...) VALUES ('PHASE-001','GOAL-001', ...);
INSERT INTO requirement (id, ..., body, ...) VALUES ('REQ-001', ..., 'Acceptance:
const ok = 1;
That is all.', ...);
INSERT INTO task (...) VALUES ('TASK-001','REQ-001', ...);
COMMIT;
```

Observed result: **the goal and the phase committed. The requirement and the task did not.**
The `BEGIN`/`COMMIT` did not protect anything, because the splitter tore the script into
fragments before the engine ever saw a single transaction. The process exited `1`, but the exit
code tells you only that *something* failed — not what landed, and a member that reports
"created REQ-001" after this is not lying so much as never having looked.

Written as `CAST(x'<hex>' AS TEXT)`, the identical text lands intact, because the hex literal is
always one line. **This is why postconditions are queried rather than assumed.** A member's own
account of what it wrote is not evidence. The board is.

---

## 2. The section template

Every process section in this document — §4 and everything after it — **must** follow this
template exactly, with these six sub-headings, in this order, spelled this way. Uniformity is
what lets a reader jump to "what must NOT be true" in any section without reading the section.

A process section is a `## N. <process name>` heading, numbered sequentially. Sections 5 onward
are added by other authors and must conform to what follows.

### `### Trigger`

What starts this process. The user phrase, the skill name, the board state, or the upstream node
that hands off to it. One or two sentences. If a process can start more than one way, list them.

### `### Preconditions`

What must already be true before the process may legitimately begin, **as SQL wherever
possible.** These are assertions in the same shape as postconditions: zero rows when the process
is safe to start. A precondition that cannot be expressed in SQL goes in *Cannot be asserted*
instead — never stated here as prose, because prose in this position reads as if it were checked.

### `### Expected sequence`

What the member should do, in order, as a numbered list. This is the process itself. Name the
views a step must read from and the tables it must write to. Where a step's ordering is
load-bearing — a gate decided before a node moves, a task created before a finding points at it
— say so, because the assertions downstream depend on the order.

### `### Postconditions`

The SQL assertions, each with its stated expected result. Give every assertion a stable ID
(`§N.a`, `§N.b`, …) so a failure can be cited. Prefer the zero-rows-when-healthy shape. Where an
assertion must return a specific count or value instead, state the value explicitly — "expect
exactly `2`", not "expect the right number".

**Read from views wherever a view exists.** If the schema has one definition of a rule, an
assertion that re-derives it by hand is a second definition, and two definitions of one rule is
precisely the failure this document exists to catch.

### `### Anti-expectations`

What must **not** be true after the process. These are separate from postconditions because they
catch a different class of error: a postcondition catches work not done, an anti-expectation
catches work done *wrongly* or done *beyond its authority*. "The plan exists" is a
postcondition. "No ticket left `todo`" is an anti-expectation. Same shape — zero rows when
healthy.

### `### Cannot be asserted`

The judgment calls, named honestly. Anything this section's process depends on that SQL cannot
see: prose quality, whether a plan is *good*, whether a human actually made the decision the
gate records, whether a slice's file list is truly disjoint. **Do not fake these.** A weak proxy
assertion in the postconditions is worse than an honest sentence here, because it converts an
open question into a green check. If the section has no such items, write "None." rather than
deleting the heading.

---

## 3. Global invariants

**These hold at all times, whatever just ran.** They are not tied to a process, they are the
definition of a coherent board. Run all nine after every skill.

Every query below returns **zero rows** when healthy. Each has been verified to pass on a
correct board and to fire on an injected breach; the demonstrated breach is noted with each one.

A note on why these exist at all, given that CHECK constraints and foreign keys already enforce
much of it: **`PRAGMA foreign_keys` is per-connection and is not remembered.** It is the single
most commonly forgotten line in the system. A member that omits it writes orphans freely. And
`CREATE TABLE IF NOT EXISTS` does not add CHECKs to a table that already exists, so a board
carried forward from an earlier v5 stage has the views and triggers but *not* the constraints.
These assertions catch rows that predate a constraint or arrived around one.

### G1 — Referential health

Every foreign key, checked as data rather than as a constraint.

```sql
SELECT 'task.requirement_id' AS ref, t.id AS row_id, t.requirement_id AS missing FROM task t WHERE NOT EXISTS (SELECT 1 FROM requirement r WHERE r.id = t.requirement_id)
UNION ALL SELECT 'task.plan_id', t.id, t.plan_id FROM task t WHERE t.plan_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM plan p WHERE p.id = t.plan_id)
UNION ALL SELECT 'task.plan_slice_id', t.id, t.plan_slice_id FROM task t WHERE t.plan_slice_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM plan_slice s WHERE s.id = t.plan_slice_id)
UNION ALL SELECT 'task.claimed_by', t.id, t.claimed_by FROM task t WHERE COALESCE(t.claimed_by,'') <> '' AND NOT EXISTS (SELECT 1 FROM agent a WHERE a.name = t.claimed_by)
UNION ALL SELECT 'phase.goal_id', p.id, p.goal_id FROM phase p WHERE NOT EXISTS (SELECT 1 FROM goal g WHERE g.id = p.goal_id)
UNION ALL SELECT 'requirement.phase_id', r.id, r.phase_id FROM requirement r WHERE r.phase_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM phase p WHERE p.id = r.phase_id)
UNION ALL SELECT 'plan.requirement_id', p.id, p.requirement_id FROM plan p WHERE NOT EXISTS (SELECT 1 FROM requirement r WHERE r.id = p.requirement_id)
UNION ALL SELECT 'plan_slice.plan_id', s.id, s.plan_id FROM plan_slice s WHERE NOT EXISTS (SELECT 1 FROM plan p WHERE p.id = s.plan_id)
UNION ALL SELECT 'graph_node.requirement_id', n.id, n.requirement_id FROM graph_node n WHERE NOT EXISTS (SELECT 1 FROM requirement r WHERE r.id = n.requirement_id)
UNION ALL SELECT 'graph_node.task_id', n.id, n.task_id FROM graph_node n WHERE n.task_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM task t WHERE t.id = n.task_id)
UNION ALL SELECT 'graph_edge.from_node', e.from_node || ' -> ' || e.to_node, e.from_node FROM graph_edge e WHERE NOT EXISTS (SELECT 1 FROM graph_node n WHERE n.id = e.from_node)
UNION ALL SELECT 'graph_edge.to_node', e.from_node || ' -> ' || e.to_node, e.to_node FROM graph_edge e WHERE NOT EXISTS (SELECT 1 FROM graph_node n WHERE n.id = e.to_node)
UNION ALL SELECT 'gate.node_id', g.node_id, g.node_id FROM gate g WHERE NOT EXISTS (SELECT 1 FROM graph_node n WHERE n.id = g.node_id)
UNION ALL SELECT 'task_dependency.task_id', d.task_id || ' -> ' || d.depends_on, d.task_id FROM task_dependency d WHERE NOT EXISTS (SELECT 1 FROM task t WHERE t.id = d.task_id)
UNION ALL SELECT 'task_dependency.depends_on', d.task_id || ' -> ' || d.depends_on, d.depends_on FROM task_dependency d WHERE NOT EXISTS (SELECT 1 FROM task t WHERE t.id = d.depends_on)
UNION ALL SELECT 'review_finding.task_id', CAST(f.id AS TEXT), f.task_id FROM review_finding f WHERE NOT EXISTS (SELECT 1 FROM task t WHERE t.id = f.task_id)
UNION ALL SELECT 'review_finding.fix_task_id', CAST(f.id AS TEXT), f.fix_task_id FROM review_finding f WHERE f.fix_task_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM task t WHERE t.id = f.fix_task_id)
UNION ALL SELECT 'bug.fix_task_id', b.id, b.fix_task_id FROM bug b WHERE b.fix_task_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM task t WHERE t.id = b.fix_task_id)
UNION ALL SELECT 'bug.requirement_id', b.id, b.requirement_id FROM bug b WHERE b.requirement_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM requirement r WHERE r.id = b.requirement_id)
UNION ALL SELECT 'work_log.task_id', CAST(w.id AS TEXT), w.task_id FROM work_log w WHERE NOT EXISTS (SELECT 1 FROM task t WHERE t.id = w.task_id)
UNION ALL SELECT 'agent_capability.agent', ac.agent || '/' || ac.capability, ac.agent FROM agent_capability ac WHERE NOT EXISTS (SELECT 1 FROM agent a WHERE a.name = ac.agent)
UNION ALL SELECT 'task_capability.task_id', tc.task_id || '/' || tc.capability, tc.task_id FROM task_capability tc WHERE NOT EXISTS (SELECT 1 FROM task t WHERE t.id = tc.task_id)
UNION ALL SELECT 'capability_request.requirement_id', CAST(q.id AS TEXT), q.requirement_id FROM capability_request q WHERE NOT EXISTS (SELECT 1 FROM requirement r WHERE r.id = q.requirement_id)
UNION ALL SELECT 'inspection_coverage.inspection_id', ic.inspection_id || '/' || ic.coverage_id, ic.inspection_id FROM inspection_coverage ic WHERE NOT EXISTS (SELECT 1 FROM inspection i WHERE i.id = ic.inspection_id)
UNION ALL SELECT 'inspection_coverage.coverage_id', ic.inspection_id || '/' || ic.coverage_id, ic.coverage_id FROM inspection_coverage ic WHERE NOT EXISTS (SELECT 1 FROM coverage c WHERE c.id = ic.coverage_id)
UNION ALL SELECT 'graph_deviation.requirement_id', CAST(d.id AS TEXT), d.requirement_id FROM graph_deviation d WHERE NOT EXISTS (SELECT 1 FROM requirement r WHERE r.id = d.requirement_id)
ORDER BY ref, row_id;
```

*Verified to fire:* inserting a task with `requirement_id = 'REQ-404'` under
`PRAGMA foreign_keys = OFF` returns `task.requirement_id | TASK-900 | REQ-404`.

### G2 — Vocabulary conformance

Every status, severity, risk, disposition, kind and flag inside its allowed set, plus the two
JSON columns.

```sql
SELECT 'goal.status' AS col, id AS row_id, status AS value FROM goal WHERE status NOT IN ('todo','in-progress','done')
UNION ALL SELECT 'phase.status', id, status FROM phase WHERE status NOT IN ('todo','in-progress','done')
UNION ALL SELECT 'requirement.status', id, status FROM requirement WHERE status NOT IN ('todo','in-progress','done')
UNION ALL SELECT 'plan.status', id, status FROM plan WHERE status NOT IN ('todo','in-progress','done')
UNION ALL SELECT 'task.status', id, status FROM task WHERE status NOT IN ('todo','in-progress','done','failed','blocked','waived')
UNION ALL SELECT 'graph_node.kind', id, kind FROM graph_node WHERE kind NOT IN ('work','gate')
UNION ALL SELECT 'graph_node.status', id, status FROM graph_node WHERE status NOT IN ('pending','ready','running','done','failed','skipped')
UNION ALL SELECT 'graph_deviation.kind', CAST(id AS TEXT), kind FROM graph_deviation WHERE kind NOT IN ('add-node','drop-node','reshape','add-gate')
UNION ALL SELECT 'gate.kind', node_id, kind FROM gate WHERE kind NOT IN ('approve','select-findings')
UNION ALL SELECT 'gate.status', node_id, status FROM gate WHERE status NOT IN ('pending','approved','rejected')
UNION ALL SELECT 'review_finding.severity', CAST(id AS TEXT), severity FROM review_finding WHERE severity NOT IN ('critical','major','minor','nit')
UNION ALL SELECT 'review_finding.disposition', CAST(id AS TEXT), disposition FROM review_finding WHERE disposition NOT IN ('open','fixing','fixed','waived')
UNION ALL SELECT 'bug.severity', id, severity FROM bug WHERE severity NOT IN ('critical','major','minor')
UNION ALL SELECT 'bug.status', id, status FROM bug WHERE status NOT IN ('open','fixing','fixed','wontfix')
UNION ALL SELECT 'coverage.risk', id, risk FROM coverage WHERE risk NOT IN ('high','medium','low')
UNION ALL SELECT 'inspection.status', id, status FROM inspection WHERE status NOT IN ('todo','in-progress','done')
UNION ALL SELECT 'inspection_coverage.verdict', inspection_id || '/' || coverage_id, verdict FROM inspection_coverage WHERE verdict IS NOT NULL AND verdict NOT IN ('pass','issues','not-reached')
UNION ALL SELECT 'capability_request.status', CAST(id AS TEXT), status FROM capability_request WHERE status NOT IN ('open','created','declined')
UNION ALL SELECT 'agent.active', name, CAST(active AS TEXT) FROM agent WHERE active NOT IN (0,1)
UNION ALL SELECT 'agent.serial', name, CAST(serial AS TEXT) FROM agent WHERE serial NOT IN (0,1)
UNION ALL SELECT 'task_capability.required', task_id || '/' || capability, CAST(required AS TEXT) FROM task_capability WHERE required NOT IN (0,1)
UNION ALL SELECT 'goal.priority', id, CAST(priority AS TEXT) FROM goal WHERE priority NOT BETWEEN 1 AND 5
UNION ALL SELECT 'requirement.priority', id, CAST(priority AS TEXT) FROM requirement WHERE priority NOT BETWEEN 1 AND 5
UNION ALL SELECT 'task.priority', id, CAST(priority AS TEXT) FROM task WHERE priority NOT BETWEEN 1 AND 5
UNION ALL SELECT 'event.payload', CAST(id AS TEXT), payload FROM event WHERE NOT json_valid(payload)
UNION ALL SELECT 'plan_slice.files', id, files FROM plan_slice WHERE NOT json_valid(files) OR json_type(files) <> 'array'
ORDER BY col, row_id;
```

`inspection.trigger` is deliberately absent — it is the one open enum in the schema, left
uncheckable on purpose so a cadence can be added later without rebuilding the table.

*Verified:* on a current board the CHECKs reject an invented status at write time —
`UPDATE task SET status='in-review'` returns
`CHECK constraint failed: status IN ('todo', 'in-progress', 'done', 'failed', 'blocked', 'waived')`.
G2 is the net for rows that arrived before the constraint existed.

### G3 — ID conformance

Every id matches its `PREFIX-NNN` shape, and every composite id agrees with the columns it is
built from.

```sql
SELECT 'goal' AS tbl, id FROM goal WHERE NOT (id GLOB 'GOAL-[0-9][0-9][0-9]' OR id GLOB 'GOAL-[0-9][0-9][0-9][0-9]')
UNION ALL SELECT 'phase', id FROM phase WHERE NOT (id GLOB 'PHASE-[0-9][0-9][0-9]' OR id GLOB 'PHASE-[0-9][0-9][0-9][0-9]')
UNION ALL SELECT 'requirement', id FROM requirement WHERE NOT (id GLOB 'REQ-[0-9][0-9][0-9]' OR id GLOB 'REQ-[0-9][0-9][0-9][0-9]')
UNION ALL SELECT 'plan', id FROM plan WHERE NOT (id GLOB 'PLAN-[0-9][0-9][0-9]' OR id GLOB 'PLAN-[0-9][0-9][0-9][0-9]')
UNION ALL SELECT 'task', id FROM task WHERE NOT (id GLOB 'TASK-[0-9][0-9][0-9]' OR id GLOB 'TASK-[0-9][0-9][0-9][0-9]')
UNION ALL SELECT 'bug', id FROM bug WHERE NOT (id GLOB 'BUG-[0-9][0-9][0-9]' OR id GLOB 'BUG-[0-9][0-9][0-9][0-9]')
UNION ALL SELECT 'inspection', id FROM inspection WHERE NOT (id GLOB 'INSP-[0-9][0-9][0-9]' OR id GLOB 'INSP-[0-9][0-9][0-9][0-9]')
UNION ALL SELECT 'plan_slice', id FROM plan_slice WHERE id <> plan_id || '/' || slug
UNION ALL SELECT 'graph_node', id FROM graph_node WHERE substr(id, 1, instr(id, '/') - 1) <> requirement_id
UNION ALL SELECT 'graph_node.node_key', id FROM graph_node WHERE instr(id, '/') = 0
ORDER BY tbl, id;
```

**On duplicates, honestly:** every one of these tables has its id as `PRIMARY KEY`, so a
duplicate id is rejected by the engine and cannot be asserted into existence. There is nothing
for a query to catch. What G3 *does* catch is the shape — a hand-assigned `REQ-7` instead of
`REQ-007`, which sorts wrongly and breaks the `ORDER BY id LIMIT 1` that `v_next_task` depends
on — and the composite-id disagreements, where `plan_slice.id` or `graph_node.id` was built from
something other than the columns it claims to encode. Both are real and both have been produced
by hand-written SQL. Gaps in the numeric sequence are not errors and are not asserted.

The four-digit alternative is allowed because ids are zero-padded to three digits and text order
is numeric order only up to `999`; a board that reaches `TASK-1000` has a real ordering problem,
but it is not this assertion's job to hide it.

### G4 — Gate integrity

No requirement has work done past an unresolved gate, and exactly the template's gates exist.

```sql
-- a node moved while a DIRECT gate predecessor is still undecided
SELECT 'past-unresolved-gate' AS breach, n.id AS row_id, g.node_id AS detail
  FROM graph_node n
  JOIN graph_edge e ON e.to_node = n.id
  JOIN graph_node p ON p.id = e.from_node AND p.kind = 'gate'
  JOIN gate g ON g.node_id = p.id
 WHERE n.status IN ('running','done','failed') AND g.status = 'pending'
UNION ALL
-- a ticket left `todo` while its requirement's gate-plan is unapproved
SELECT 'built-before-gate-plan', t.id, g.status
  FROM task t
  JOIN graph_node n ON n.requirement_id = t.requirement_id AND n.node_key = 'gate-plan'
  JOIN gate g ON g.node_id = n.id
 WHERE g.status <> 'approved' AND t.status <> 'todo'
UNION ALL
SELECT 'gate-node-no-row', n.id, n.node_key FROM graph_node n
 WHERE n.kind = 'gate' AND NOT EXISTS (SELECT 1 FROM gate g WHERE g.node_id = n.id)
UNION ALL
SELECT 'gate-row-on-work-node', g.node_id, n.kind FROM gate g JOIN graph_node n ON n.id = g.node_id WHERE n.kind <> 'gate'
UNION ALL
-- approving a gate is TWO writes. This catches the second one being forgotten.
SELECT 'decided-gate-node-not-moved', g.node_id, n.status FROM gate g JOIN graph_node n ON n.id = g.node_id
 WHERE g.status <> 'pending' AND n.status NOT IN ('done','skipped')
UNION ALL
SELECT 'gate-decided-no-timestamp', g.node_id, g.status FROM gate g WHERE g.status <> 'pending' AND COALESCE(g.decided_at,'') = ''
UNION ALL
SELECT 'select-findings-no-decision', g.node_id, g.status FROM gate g WHERE g.kind = 'select-findings' AND g.status = 'approved' AND COALESCE(g.decision,'') = ''
UNION ALL
-- a gate key the template does not declare  =  AN ADDED GATE
SELECT 'added-gate', n.id, n.node_key FROM graph_node n
 WHERE n.kind = 'gate'
   AND (SELECT value FROM guild_state WHERE key = 'graph-template:' || n.requirement_id) = 'standard'
   AND n.node_key NOT IN ('gate-plan','gate-repairs')
UNION ALL
-- a template gate with no node  =  A DROPPED GATE
SELECT 'dropped-gate', r.id, k.k
  FROM requirement r
  JOIN (SELECT 'gate-plan' AS k UNION ALL SELECT 'gate-repairs') k
 WHERE (SELECT value FROM guild_state WHERE key = 'graph-template:' || r.id) = 'standard'
   AND NOT EXISTS (SELECT 1 FROM graph_node n WHERE n.requirement_id = r.id AND n.node_key = k.k AND n.kind = 'gate')
UNION ALL
SELECT 'add-gate-deviation', CAST(d.id AS TEXT), d.node_key FROM graph_deviation d WHERE d.kind = 'add-gate'
UNION ALL
SELECT 'graph-without-template', n.requirement_id, 'guild_state graph-template missing'
  FROM graph_node n
 WHERE NOT EXISTS (SELECT 1 FROM guild_state s WHERE s.key = 'graph-template:' || n.requirement_id)
 GROUP BY n.requirement_id
ORDER BY breach, row_id;
```

The template a requirement was built from is recorded as `guild_state` key
`graph-template:REQ-NNN`. Without it there is no baseline to diff a deviation against, which is
why its absence is itself a breach.

*Verified to fire:* reverting `gate-plan` to `pending` on a run requirement returns
`built-before-gate-plan | TASK-001 | pending` and four more. Adding a third gate node returns
`added-gate | REQ-001/gate-migrations | gate-migrations`.

### G5 — Roster integrity

No task requires a capability no member has without that gap existing as a `capability_request`
row, and no capability outside the vocabulary is in use.

```sql
SELECT 'uncovered-capability-no-request' AS breach, tc.task_id AS row_id, tc.capability AS detail
  FROM task_capability tc JOIN task t ON t.id = tc.task_id
 WHERE tc.required = 1 AND COALESCE(t.agent,'') = '' AND t.status IN ('todo','in-progress','blocked')
   AND NOT EXISTS (SELECT 1 FROM agent_capability ac JOIN agent a ON a.name = ac.agent
                    WHERE a.active = 1 AND ac.capability = tc.capability)
   AND NOT EXISTS (SELECT 1 FROM capability_request q WHERE q.capability = tc.capability AND q.status IN ('open','created'))
UNION ALL
SELECT 'capability-outside-vocabulary', u.owner, u.side || ':' || u.capability FROM v_capability_unknown u
UNION ALL
SELECT 'stale-roster-gap', CAST(rg.id AS TEXT), rg.capability || ' covered_by=' || rg.covered_by FROM v_roster_gaps rg WHERE rg.covered_by > 0
UNION ALL
SELECT 'created-request-still-uncovered', CAST(q.id AS TEXT), q.capability FROM capability_request q
 WHERE q.status = 'created'
   AND NOT EXISTS (SELECT 1 FROM agent_capability ac JOIN agent a ON a.name = ac.agent WHERE a.active = 1 AND ac.capability = q.capability)
UNION ALL
SELECT 'dispatched-to-inactive-agent', t.id, t.claimed_by FROM task t
  JOIN agent a ON a.name = t.claimed_by WHERE a.active = 0 AND t.status = 'in-progress'
UNION ALL
SELECT 'pinned-agent-not-on-roster', t.id, t.agent FROM task t
 WHERE COALESCE(t.agent,'') <> '' AND t.agent <> 'reviewer'
   AND NOT EXISTS (SELECT 1 FROM agent a WHERE a.name = t.agent)
UNION ALL
-- the two views that name a member for a ticket must never disagree
SELECT 'top-agent-disagrees-with-match', m.task_id, m.agent
  FROM v_task_top_agent m
 WHERE m.agent <> '' AND m.agent <> COALESCE((SELECT am.agent FROM v_agent_match am WHERE am.task_id = m.task_id
    ORDER BY am.branch, am.preferred_covered DESC, am.capabilities ASC, am.agent ASC LIMIT 1),'')
ORDER BY breach, row_id;
```

`v_capability_unknown` and `v_roster_gaps` are read rather than re-derived, per §2. The literal
`'reviewer'` is excluded from the pin check because it is the one pin that is a *role* fanned out
to four real agents at dispatch, not a member name — this is the same exact-match that
`v_task_actionable`'s review gate depends on.

*Verified to fire:* tagging an agent `rust` returns
`capability-outside-vocabulary | developer | agent:rust`. A task requiring `research` with the
capability stripped from the roster and no request filed returns
`uncovered-capability-no-request | TASK-007 | research`.

### G6 — Closure and records

Nothing is marked finished over work that is not, and every finding and bug that claims to be
being fixed has a task doing it.

```sql
SELECT 'requirement-done-over-open-task' AS breach, p.id AS row_id, 'tasks_open=' || p.tasks_open AS detail
  FROM v_requirement_progress p WHERE p.status = 'done' AND p.tasks_open > 0
UNION ALL
SELECT 'requirement-done-with-pending-gate', n.requirement_id, g.node_id
  FROM gate g JOIN graph_node n ON n.id = g.node_id JOIN requirement r ON r.id = n.requirement_id
 WHERE r.status = 'done' AND g.status = 'pending'
UNION ALL
SELECT 'requirement-done-with-unfinished-node', n.requirement_id, n.id || '=' || n.status
  FROM graph_node n JOIN requirement r ON r.id = n.requirement_id
 WHERE r.status = 'done' AND n.status NOT IN ('done','skipped')
UNION ALL
SELECT 'requirement-done-with-open-finding', f.requirement_id, CAST(f.id AS TEXT)
  FROM v_open_findings f JOIN requirement r ON r.id = f.requirement_id WHERE r.status = 'done'
UNION ALL
SELECT 'phase-done-over-open-requirement', r.phase_id, r.id
  FROM requirement r JOIN phase p ON p.id = r.phase_id WHERE p.status = 'done' AND r.status <> 'done'
UNION ALL
SELECT 'goal-done-over-open-phase', p.goal_id, p.id
  FROM phase p JOIN goal g ON g.id = p.goal_id WHERE g.status = 'done' AND p.status <> 'done'
UNION ALL
SELECT 'finding-fixing-without-task', CAST(f.id AS TEXT), f.disposition FROM review_finding f WHERE f.disposition IN ('fixing','fixed') AND f.fix_task_id IS NULL
UNION ALL
SELECT 'bug-fixing-without-task', b.id, b.status FROM bug b WHERE b.status IN ('fixing','fixed') AND b.fix_task_id IS NULL
UNION ALL
-- a finding still `open` after its repair gate was decided was DROPPED, not dispositioned
SELECT 'finding-open-past-gate-repairs', CAST(f.id AS TEXT), f.requirement_id
  FROM v_open_findings f
  JOIN graph_node n ON n.requirement_id = f.requirement_id AND n.node_key = 'gate-repairs'
  JOIN gate g ON g.node_id = n.id
 WHERE g.status <> 'pending' AND f.disposition = 'open'
UNION ALL
SELECT 'in-progress-unclaimed', t.id, COALESCE(t.claimed_by,'(null)') FROM task t WHERE t.status = 'in-progress' AND COALESCE(t.claimed_by,'') = ''
UNION ALL
SELECT 'todo-but-claimed', t.id, t.claimed_by FROM task t WHERE t.status = 'todo' AND COALESCE(t.claimed_by,'') <> ''
UNION ALL
SELECT 'claimed-without-timestamp', t.id, t.claimed_by FROM task t WHERE COALESCE(t.claimed_by,'') <> '' AND COALESCE(t.claimed_at,'') = ''
UNION ALL
-- `blocked` means NOBODY CAN TAKE IT. If the matcher names somebody, the status is a lie.
SELECT 'blocked-but-coverable', t.id, m.agent FROM task t JOIN v_task_top_agent m ON m.task_id = t.id WHERE t.status = 'blocked' AND m.agent <> ''
UNION ALL
SELECT 'updated-before-created', t.id, t.created_at || ' > ' || t.updated_at FROM task t WHERE t.updated_at < t.created_at
UNION ALL
SELECT 'requirement-updated-before-created', r.id, r.created_at || ' > ' || r.updated_at FROM requirement r WHERE r.updated_at < r.created_at
UNION ALL
-- the cursor answers a question that has one answer
SELECT 'cursor-multi-row', 'v_next_task', CAST((SELECT COUNT(*) FROM v_next_task) AS TEXT) WHERE (SELECT COUNT(*) FROM v_next_task) > 1
ORDER BY breach, row_id;
```

`v_requirement_progress.tasks_open` is read rather than recounted. It counts
`todo + in-progress + blocked` and deliberately excludes `failed`, because a human has already
ruled on a failure. This is convention item 2 in the schema header — nothing prevents the close,
so this assertion is the only thing that reports it.

*Verified to fire:* closing `REQ-001` over one open ticket returns
`requirement-done-over-open-task | REQ-001 | tasks_open=1`. Setting a finding to `fixing` with no
fix task returns `finding-fixing-without-task | 1 | fixing`.

### G7 — Event coverage

The triggers write an `event` row on every meaningful mutation. A gap means something wrote
around them — which, since `event` is the guild's entire memory in v6, means a mutation no
surface can ever show.

```sql
SELECT 'no-created-event' AS breach, 'goal' AS tbl, id AS row_id FROM goal g WHERE NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='goal' AND e.subject_id=g.id AND e.verb='created')
UNION ALL SELECT 'no-created-event','phase', id FROM phase p WHERE NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='phase' AND e.subject_id=p.id AND e.verb='created')
UNION ALL SELECT 'no-created-event','requirement', id FROM requirement r WHERE NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='requirement' AND e.subject_id=r.id AND e.verb='created')
UNION ALL SELECT 'no-created-event','plan', id FROM plan p WHERE NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='plan' AND e.subject_id=p.id AND e.verb='created')
UNION ALL SELECT 'no-created-event','task', id FROM task t WHERE NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='task' AND e.subject_id=t.id AND e.verb='created')
UNION ALL SELECT 'no-created-event','bug', id FROM bug b WHERE NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='bug' AND e.subject_id=b.id AND e.verb='created')
UNION ALL SELECT 'no-created-event','agent', name FROM agent a WHERE NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='agent' AND e.subject_id=a.name AND e.verb='recruited')
UNION ALL SELECT 'no-created-event','coverage', id FROM coverage c WHERE NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='coverage' AND e.subject_id=c.id AND e.verb='created')
UNION ALL SELECT 'no-found-event','review_finding', CAST(f.id AS TEXT) FROM review_finding f
 WHERE NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='task' AND e.subject_id=f.task_id AND e.verb='found'
                     AND json_valid(e.payload) AND json_extract(e.payload,'$.finding_id') = f.id)
UNION ALL SELECT 'no-created-event','work_log', CAST(w.id AS TEXT) FROM work_log w WHERE NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='task' AND e.subject_id=w.task_id AND e.verb='logged')
UNION ALL
SELECT 'no-moved-event','task', t.id FROM task t WHERE t.status <> 'todo' AND NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='task' AND e.subject_id=t.id AND e.verb='moved')
UNION ALL SELECT 'no-moved-event','requirement', r.id FROM requirement r WHERE r.status <> 'todo' AND NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='requirement' AND e.subject_id=r.id AND e.verb='moved')
UNION ALL SELECT 'no-moved-event','graph_node', n.id FROM graph_node n WHERE n.status <> 'pending' AND NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='graph_node' AND e.subject_id=n.id AND e.verb='node-moved')
UNION ALL SELECT 'no-decided-event','gate', g.node_id FROM gate g WHERE g.status <> 'pending' AND NOT EXISTS (SELECT 1 FROM event e WHERE e.subject_type='gate' AND e.subject_id=g.node_id AND e.verb='decided')
UNION ALL
SELECT 'empty-actor','event', CAST(e.id AS TEXT) FROM event e WHERE trim(e.actor) = ''
UNION ALL SELECT 'unknown-subject-type','event', CAST(e.id AS TEXT) || ':' || e.subject_type FROM event e
 WHERE e.subject_type NOT IN (SELECT name FROM sqlite_schema WHERE type='table')
ORDER BY breach, tbl, row_id;
```

Two subtleties, both of which cost a round to get right and are easy to get wrong when writing a
new assertion:

- **A finding's event is filed against the TASK, not the finding.** `trg_finding_created` writes
  `subject_type='task'`, `subject_id=new.task_id`, `verb='found'`, with the finding's own id in
  `payload.finding_id`. An assertion looking for `subject_type='review_finding'` finds nothing and
  reports every healthy finding as a breach.
- **The `no-moved-event` clauses only hold if rows were MOVED rather than inserted at their end
  state.** That is the point. A member that inserts a task already `done` produces a board with no
  history of it happening, and this is the assertion that says so. When this section fires on a
  board you believe is correct, the usual cause is a fixture or a script that took that shortcut.

*Verified to fire:* deleting one `moved` event returns `no-moved-event | task | TASK-001`.

### G8 — Graph structure

The execution graph is connected, stays inside its requirement, and matches its template.

```sql
SELECT 'orphan-node' AS breach, n.id AS row_id, 'no edge in or out' AS detail
  FROM graph_node n
 WHERE NOT EXISTS (SELECT 1 FROM graph_edge e WHERE e.from_node = n.id OR e.to_node = n.id)
   AND (SELECT COUNT(*) FROM graph_node m WHERE m.requirement_id = n.requirement_id) > 1
UNION ALL
SELECT 'cross-requirement-edge', e.from_node || ' -> ' || e.to_node, f.requirement_id || ' -> ' || t.requirement_id
  FROM graph_edge e JOIN graph_node f ON f.id = e.from_node JOIN graph_node t ON t.id = e.to_node
 WHERE f.requirement_id <> t.requirement_id
UNION ALL
SELECT 'two-cycle', e1.from_node || ' <-> ' || e1.to_node, 'mutual edge'
  FROM graph_edge e1 JOIN graph_edge e2 ON e2.from_node = e1.to_node AND e2.to_node = e1.from_node
 WHERE e1.from_node < e1.to_node
UNION ALL
SELECT 'dropped-required-node', r.id, k.k
  FROM requirement r JOIN (SELECT 'gate-plan' AS k UNION ALL SELECT 'implement'
                           UNION ALL SELECT 'review' UNION ALL SELECT 'gate-repairs') k
 WHERE (SELECT value FROM guild_state WHERE key = 'graph-template:' || r.id) = 'standard'
   AND NOT EXISTS (SELECT 1 FROM graph_node n WHERE n.requirement_id = r.id AND n.node_key = k.k)
UNION ALL
SELECT 'dropped-optional-node-no-deviation', r.id, k.k
  FROM requirement r JOIN (SELECT 'test-plan' AS k UNION ALL SELECT 'test-write' UNION ALL SELECT 'repair') k
 WHERE (SELECT value FROM guild_state WHERE key = 'graph-template:' || r.id) = 'standard'
   AND NOT EXISTS (SELECT 1 FROM graph_node n WHERE n.requirement_id = r.id AND n.node_key = k.k)
   AND NOT EXISTS (SELECT 1 FROM graph_deviation d WHERE d.requirement_id = r.id AND d.kind = 'drop-node' AND d.node_key = k.k)
UNION ALL
SELECT 'deviation-with-empty-reason', CAST(d.id AS TEXT), d.kind || ' ' || d.node_key
  FROM graph_deviation d WHERE trim(d.reason) = ''
UNION ALL
SELECT 'node-key-not-in-template', n.id, n.node_key
  FROM graph_node n
 WHERE (SELECT value FROM guild_state WHERE key = 'graph-template:' || n.requirement_id) = 'standard'
   AND n.node_key NOT IN ('gate-plan','implement','test-plan','test-write','review','gate-repairs','repair')
   AND NOT EXISTS (SELECT 1 FROM graph_deviation d WHERE d.requirement_id = n.requirement_id AND d.kind = 'add-node' AND d.node_key = n.node_key)
UNION ALL
SELECT 'work-node-done-without-task', n.id, n.node_key
  FROM graph_node n
 WHERE n.kind = 'work' AND n.status = 'done' AND n.task_id IS NULL
   AND NOT EXISTS (SELECT 1 FROM task t WHERE t.requirement_id = n.requirement_id AND t.node_key = n.node_key)
UNION ALL
SELECT 'node-done-while-its-task-open', n.id, t.id || '=' || t.status
  FROM graph_node n JOIN task t ON t.id = n.task_id
 WHERE n.status = 'done' AND t.status IN ('todo','in-progress','blocked')
ORDER BY breach, row_id;
```

**`two-cycle` is a two-hop check and only a two-hop check.** With no `WITH RECURSIVE` there is no
traversal available, so a longer cycle cannot be detected in SQL at all — see *Cannot be
asserted* below.

*Verified to fire:* deleting the four `review` nodes returns
`dropped-required-node | REQ-001 | review`. Adding a back-edge from `test-plan` to
`implement.auth-service` returns
`two-cycle | REQ-001/implement.auth-service <-> REQ-001/test-plan`.

### G9 — Concurrency

Includes the `qa-execute` invariant: **more than one tester at a time is a breach.** It is
expressed against `agent.serial` rather than against the name `qa-tester`, because `serial = 1`
is what the schema means by "never run concurrently with itself" and the QA tester is the member
that carries the flag, not the definition of the rule.

```sql
SELECT 'serial-agent-double-booked' AS breach, a.name AS row_id, CAST(COUNT(*) AS TEXT) || ' in-flight' AS detail
  FROM task t JOIN agent a ON a.name = t.claimed_by
 WHERE t.status = 'in-progress' AND a.serial = 1
 GROUP BY a.name HAVING COUNT(*) > 1
UNION ALL
SELECT 'parallel-group-crosses-requirements', t.parallel_group, group_concat(DISTINCT t.requirement_id)
  FROM task t WHERE COALESCE(t.parallel_group,'') <> ''
 GROUP BY t.parallel_group HAVING COUNT(DISTINCT t.requirement_id) > 1
ORDER BY breach, row_id;
```

*Verified to fire:* two tickets claimed by `qa-tester` simultaneously returns
`serial-agent-double-booked | qa-tester | 2 in-flight`.

### Cannot be asserted — globally

Named honestly, because a proxy assertion here would convert an open question into a green check.

- **Who actually wrote a row.** SQL has no identity. `guild_state.actor` is a courtesy label the
  writer sets on itself and the triggers copy verbatim, so a lying actor produces a lying feed and
  every event in it passes G7. This is the largest thing v6 gave up and no query can recover it.
- **Whether a human decided a gate.** `gate.status` is a column. G4 asserts a decision was
  *recorded coherently* — never that a person made it.
- **Cycles longer than two hops.** No `WITH RECURSIVE`. A longer cycle makes `v_ready_nodes`
  return nothing for the whole loop, which is a silent stall rather than an error. The available
  signal is indirect and not an assertion: an in-flight requirement whose `v_ready_nodes` is empty
  and whose gates are all decided is either finished or looping. Distinguishing the two is a
  review duty.
- **Whether plan slices touch disjoint files.** `plan_slice.files` is the architect's assertion.
  §4 checks the declared sets against each other, which catches a *stated* overlap — it cannot
  catch a slice whose file list is simply wrong or incomplete.
- **Whether a `failed` task was genuinely adjudicated.** The waiver is a work-log line beginning
  `Skipped by user`, read back by `v_failed_tasks.waived`. It is a marker, not a column, and a
  stray log line can look like one.
- **Whether the timestamps are UTC.** The triggers use UTC. Anything hand-written is whatever was
  written, and no query can tell the difference.
- **Whether any of the prose is any good.** A requirement body, a plan, a finding's summary, a
  deviation's reason. G8 asserts a reason is non-empty; nothing asserts it is a reason.

---

## 4. The build flow

The `standard` template, end to end.

### Trigger

`guild:new-requirement` — the user asks for a feature ("add a requirement", "I need a feature",
"I want to build…"). The skill runs a live three-way interview between the product-owner, the
architect and the user, and ends at `gate-plan` without building anything. Approval at that gate
is what releases the rest of the flow to `guild:check-in` or `guild:shift`.

### Preconditions

The schema is applied and the roster is populated. Before the flow may begin:

```sql
-- P4.a  the schema is current — expect exactly one row, version 5
SELECT version FROM schema_version WHERE id = 1;

-- P4.b  the roster is not empty and its tags are legal — expect ZERO ROWS
SELECT 'roster-empty' AS breach, '' AS detail WHERE NOT EXISTS (SELECT 1 FROM agent WHERE active = 1)
UNION ALL SELECT 'unknown-capability', side || ':' || owner || ':' || capability FROM v_capability_unknown;

-- P4.c  this requirement has no graph already — expect ZERO ROWS
SELECT id FROM graph_node WHERE requirement_id = 'REQ-NNN';
```

P4.c must be a **separate round trip.** A failing statement does not stop a tursodb script and
`COMMIT` still commits, so a guard in the same script as the INSERTs is not a guard.

### Expected sequence

1. **Interview.** The orchestrator spawns the product-owner and the architect and moderates.
   Nothing is written to the board yet.
2. **Create the requirement**, `status = 'todo'`, body as `CAST(x'…' AS TEXT)`. Id derived inside
   the INSERT with `printf('%03d', COALESCE(MAX(…),0)+1)`, never hand-assigned.
3. **Place it in the direction** — `phase_id`, on the user's explicit answer. Nullable by design;
   an unaffiliated requirement is finished, not deficient.
4. **Create the plan and its slices.** Each slice carries `files` as a JSON array — the
   disjointness assertion that parallel dispatch depends on.
5. **Create the tickets**, all at `todo`, each with its `task_capability` rows or a pinned
   `agent`, and `plan_slice_id` / `parallel_group` set from the slice.
6. **Instantiate the graph** from `templates/standard.md`: nodes, edges, two gate rows, and the
   `guild_state` key `graph-template:REQ-NNN`. With *N* slices this is **N + 9 nodes and 2N + 10
   edges** — for two slices, 11 and 14.
7. **Validate the graph read-only** and send failures back to the architect. Do not patch a graph
   by hand: deviations are its record, and a graph the orchestrator patched has a shape nobody
   justified.
8. **Present `gate-plan` and stop.** On approval, two writes in this order: the `gate` row, then
   `graph_node.status = 'done'`. Setting the gate does not move the node.
9. Then, and only then: implement → test-plan → test-write → review (×4) → `gate-repairs` →
   repair. Each work node moves `pending → running → done` as its ticket moves
   `todo → in-progress → done`.

### Postconditions

**§4.a — after planning, before the gate.** The whole board for this requirement is untouched
work. Expect **zero rows**:

```sql
SELECT 'task-already-moved' AS breach, t.id AS row_id, t.status AS detail FROM task t WHERE t.requirement_id='REQ-NNN' AND t.status <> 'todo'
UNION ALL SELECT 'node-already-moved', n.id, n.status FROM graph_node n WHERE n.requirement_id='REQ-NNN' AND n.status <> 'pending'
UNION ALL SELECT 'gate-plan-already-decided', g.node_id, g.status FROM gate g JOIN graph_node n ON n.id=g.node_id WHERE n.requirement_id='REQ-NNN' AND n.node_key='gate-plan' AND g.status <> 'pending'
UNION ALL SELECT 'ticket-already-claimed', t.id, t.claimed_by FROM task t WHERE t.requirement_id='REQ-NNN' AND COALESCE(t.claimed_by,'') <> ''
UNION ALL SELECT 'no-tickets', 'REQ-NNN', '0' WHERE NOT EXISTS (SELECT 1 FROM task WHERE requirement_id='REQ-NNN')
UNION ALL SELECT 'ticket-without-capability-or-pin', t.id, '' FROM task t
 WHERE t.requirement_id='REQ-NNN' AND COALESCE(t.agent,'')='' AND NOT EXISTS (SELECT 1 FROM task_capability c WHERE c.task_id=t.id)
UNION ALL SELECT 'graph-cannot-start', 'REQ-NNN', 'v_ready_nodes empty'
 WHERE NOT EXISTS (SELECT 1 FROM v_ready_nodes WHERE requirement_id='REQ-NNN')
UNION ALL SELECT 'unmatched-ticket', t.id, w.who FROM task t JOIN v_task_top_agent m ON m.task_id=t.id JOIN v_task_who w ON w.task_id=t.id
 WHERE t.requirement_id='REQ-NNN' AND m.agent=''
UNION ALL SELECT 'unknown-capability-tag', u.owner, u.side||':'||u.capability FROM v_capability_unknown u
ORDER BY breach, row_id;
```

**§4.b — the graph's only entry point is the plan gate.** Expect **exactly one row**, and it must
be the gate:

```sql
SELECT id, node_key, kind, gate_status FROM v_ready_nodes WHERE requirement_id = 'REQ-NNN';
-- REQ-NNN/gate-plan | gate-plan | gate | pending
```

This is the strongest single statement that nothing can be built yet. `v_ready_nodes` is the
schema's one definition of readiness, and at plan time it offers a human decision and nothing
else.

**§4.c — node, edge and gate counts.** For a plan with *N* slices, expect `N + 9`, `2N + 10`, and
**exactly 2**:

```sql
SELECT (SELECT COUNT(*) FROM graph_node WHERE requirement_id = 'REQ-NNN') AS nodes,
       (SELECT COUNT(*) FROM graph_edge WHERE to_node LIKE 'REQ-NNN/%') AS edges,
       (SELECT COUNT(*) FROM graph_node WHERE requirement_id = 'REQ-NNN' AND kind = 'gate') AS gates;
```

**§4.d — the plan, its slices, and the review fan-out.** Expect **zero rows**:

```sql
SELECT 'no-plan' AS breach, r.id AS row_id, '' AS detail FROM requirement r
 WHERE r.id='REQ-NNN' AND NOT EXISTS (SELECT 1 FROM plan p WHERE p.requirement_id=r.id)
UNION ALL
SELECT 'plan-without-slices', p.id, '' FROM plan p
 WHERE p.requirement_id='REQ-NNN' AND NOT EXISTS (SELECT 1 FROM plan_slice s WHERE s.plan_id=p.id)
UNION ALL
SELECT 'slice-names-no-files', s.id, s.files FROM plan_slice s JOIN plan p ON p.id=s.plan_id
 WHERE p.requirement_id='REQ-NNN' AND json_array_length(s.files) = 0
UNION ALL
SELECT 'slice-file-not-a-string', s.id, j.value FROM plan_slice s JOIN plan p ON p.id=s.plan_id
 JOIN json_each(s.files) j ON 1=1
 WHERE p.requirement_id='REQ-NNN' AND j.type <> 'text'
UNION ALL
-- two slices claiming the same file AND dispatched in the same wave
SELECT 'slices-share-a-file-in-one-parallel-group', s1.id || ' & ' || s2.id, j1.value
  FROM plan_slice s1 JOIN plan p1 ON p1.id=s1.plan_id
  JOIN plan_slice s2 ON s2.plan_id=s1.plan_id AND s2.id > s1.id
  JOIN json_each(s1.files) j1 ON 1=1
  JOIN json_each(s2.files) j2 ON j2.value = j1.value
  JOIN task t1 ON t1.plan_slice_id = s1.id
  JOIN task t2 ON t2.plan_slice_id = s2.id
 WHERE p1.requirement_id='REQ-NNN'
   AND COALESCE(t1.parallel_group,'') <> '' AND t1.parallel_group = t2.parallel_group
UNION ALL
SELECT 'slice-without-implement-node', s.id, '' FROM plan_slice s JOIN plan p ON p.id=s.plan_id
 WHERE p.requirement_id='REQ-NNN'
   AND NOT EXISTS (SELECT 1 FROM graph_node n WHERE n.requirement_id=p.requirement_id
                    AND n.node_key='implement' AND n.id = p.requirement_id || '/implement.' || s.slug)
UNION ALL
SELECT 'reviewer-count-not-four', 'REQ-NNN', CAST((SELECT COUNT(*) FROM graph_node WHERE requirement_id='REQ-NNN' AND node_key='review') AS TEXT)
 WHERE (SELECT COUNT(*) FROM graph_node WHERE requirement_id='REQ-NNN' AND node_key='review') <> 4
UNION ALL
SELECT 'reviewers-not-one-parallel-group', 'REQ-NNN', COALESCE(group_concat(DISTINCT COALESCE(n.parallel_group,'(null)')),'')
  FROM graph_node n WHERE n.requirement_id='REQ-NNN' AND n.node_key='review'
 GROUP BY n.requirement_id
HAVING COUNT(DISTINCT COALESCE(n.parallel_group,'(null)')) <> 1 OR MIN(COALESCE(n.parallel_group,'')) <> 'review'
ORDER BY breach, row_id;
```

**§4.e — review produced findings.** A review node that ran and recorded nothing is the false
green the whole gate model exists to prevent. Expect **zero rows**:

```sql
SELECT 'review-ran-but-produced-no-finding' AS breach, n.id AS row_id FROM graph_node n
 WHERE n.requirement_id='REQ-NNN' AND n.node_key='review' AND n.status='done'
   AND NOT EXISTS (SELECT 1 FROM review_finding f JOIN task t ON t.id=f.task_id WHERE t.requirement_id='REQ-NNN');
```

This one is a judgment encoded as an assertion, and it is worth being explicit about why: a clean
review is a legitimate outcome, so a firing here is not proof of a defect. It is proof that four
reviewers read a diff and wrote nothing down, which is rare enough to be worth a human look every
time. If a requirement genuinely reviews clean, record a `nit` saying so — that is cheaper than
an assertion nobody trusts.

**§4.f — approved findings became tasks, unapproved ones were dispositioned.** After
`gate-repairs` is decided, every finding named in `gate.decision` has a fix task, and every
finding *not* named has left `open`. Expect **zero rows**:

```sql
SELECT 'approved-finding-without-fix-task' AS breach, CAST(f.id AS TEXT) AS row_id, f.disposition AS detail
  FROM review_finding f JOIN task t ON t.id=f.task_id
  JOIN graph_node n ON n.requirement_id=t.requirement_id AND n.node_key='gate-repairs'
  JOIN gate g ON g.node_id=n.id
 WHERE t.requirement_id='REQ-NNN' AND g.status='approved' AND json_valid(COALESCE(g.decision,''))
   AND EXISTS (SELECT 1 FROM json_each(g.decision) j WHERE CAST(j.value AS INTEGER) = f.id)
   AND f.fix_task_id IS NULL
UNION ALL
SELECT 'unselected-finding-not-dispositioned', CAST(f.id AS TEXT), f.disposition
  FROM review_finding f JOIN task t ON t.id=f.task_id
  JOIN graph_node n ON n.requirement_id=t.requirement_id AND n.node_key='gate-repairs'
  JOIN gate g ON g.node_id=n.id
 WHERE t.requirement_id='REQ-NNN' AND g.status='approved' AND json_valid(COALESCE(g.decision,''))
   AND NOT EXISTS (SELECT 1 FROM json_each(g.decision) j WHERE CAST(j.value AS INTEGER) = f.id)
   AND f.disposition = 'open'
ORDER BY breach, row_id;
```

`gate.decision` for a `select-findings` gate must therefore be a **JSON array of
`review_finding.id` integers** — `'[1,4,7]'`. Nothing in the schema enforces that shape; these
two assertions are what make it a contract, and they are inert (`json_valid` guard) against a
decision written as free prose, which is itself worth catching.

### Anti-expectations

Must be false after the flow. All are covered by §3 and are restated here because they are the
specific ways *this* flow goes wrong:

| Must not be true | Caught by |
|---|---|
| Any ticket left `todo` before `gate-plan` was approved | G4 `built-before-gate-plan` |
| A third gate, or a missing one | G4 `added-gate`, `dropped-gate` |
| A gate approved without the node being moved | G4 `decided-gate-node-not-moved` |
| `implement` or `review` dropped from the graph | G8 `dropped-required-node` |
| A node key nobody recorded a deviation for | G8 `node-key-not-in-template` |
| A review node `done` while its ticket is still open | G8 `node-done-while-its-task-open` |
| The requirement closed over an open or blocked ticket | G6 `requirement-done-over-open-task` |
| A finding still `open` after the repair gate decided | G6 `finding-open-past-gate-repairs` |
| A ticket dispatched by hardcoded agent name to somebody the matcher would not pick | G5 `top-agent-disagrees-with-match` |
| An invented capability tag on a ticket | G5 `capability-outside-vocabulary` |

### Cannot be asserted

- **Whether the plan is a good plan.** §4.d asserts slices exist and name files. Nothing asserts
  the decomposition is sensible, that the slices are the right slices, or that the file lists are
  complete. This is the single largest unasserted thing in the build flow, and it is exactly what
  `gate-plan` exists to put in front of a human.
- **Whether the code was actually written.** The board records that a ticket moved to `done`. It
  does not see the repository. A member that moves a ticket without writing code produces a board
  that passes every assertion here.
- **Whether the four reviewers actually read the diff.** §4.e catches an empty review; it cannot
  distinguish a careful review from a plausible-sounding one.
- **Whether a finding is real,** whether its severity is right, and whether the repair fixes it.
  G6 asserts a `fixing` finding has a fix task; nothing asserts the task does anything.
- **Whether the human at `gate-plan` understood what they approved.** The gate records a
  decision. That is all a column can do.

---

## 5. The brief

The narrated read of the board. Judged against **`messy`**, never against `empty` — an empty
guild flatters every surface, and a brief with nothing to report cannot be wrong.

This is the first process in this document whose deliverable is **prose**, so the shape of its
expectations is different from §4's. Nothing here changes state, which means a postcondition
about the *board* proves only that the brief kept its hands off. The expectation that matters is
about **faithfulness**: does the narration agree with what the database actually contains? That
cannot be asserted by reading the board alone — it is asserted by generating the set of facts the
narration is obliged to carry and checking the narration against it.

### Trigger

`guild:brief` — "brief me", "what's the status", "where are we", "what moved since last time",
"what should I work on next", and every other read-only status phrasing. Also reached by the
deprecated `/guild:guild-status` alias (§10). `guild:check-in` Step 2 opens with the same reads
and is bound by §5.b and §5.c identically; the difference is that check-in then *acts*.

### Preconditions

```sql
-- P5.a  the board is readable and every view the brief reads exists — expect ZERO ROWS
SELECT 'missing-view' AS breach, v.n AS row_id FROM (
  SELECT 'v_brief' AS n UNION ALL SELECT 'v_goal_progress' UNION ALL SELECT 'v_requirement_progress'
  UNION ALL SELECT 'v_in_flight' UNION ALL SELECT 'v_open_bounties' UNION ALL SELECT 'v_blocked_tasks'
  UNION ALL SELECT 'v_roster_gaps' UNION ALL SELECT 'v_open_bugs' UNION ALL SELECT 'v_failed_tasks'
  UNION ALL SELECT 'v_open_findings' UNION ALL SELECT 'v_coverage_due' UNION ALL SELECT 'v_gates_pending'
  UNION ALL SELECT 'v_recent_activity' UNION ALL SELECT 'v_capability_unknown') v
 WHERE NOT EXISTS (SELECT 1 FROM sqlite_schema s WHERE s.type = 'view' AND s.name = v.n)
UNION ALL
SELECT 'schema-not-5', CAST(version AS TEXT) FROM schema_version WHERE version <> 5;
```

*Verified:* zero rows on `empty` and on `messy`; `DROP VIEW v_failed_tasks` returns
`missing-view | v_failed_tasks`. A dropped or stale view is the one precondition failure that
would otherwise present as a *quiet* omission — the brief would simply not have a failures beat,
and nothing would say why.

`.guild/config.yaml` existing is a shell check, not a SQL one, and it is the skill's own Step 1.

### Expected sequence

1. **One script, one round trip.** Every block in `guild:brief` Step 2 goes in a single
   heredoc-fed file. A brief that issues fourteen round trips can observe fourteen different
   boards.
2. **Read the counts from `v_brief`** and the detail lists from the same views those counts are
   derived from. Never recount.
3. **Free text crosses as `json_object(...)`** — one row is then always one line. `-m list` is
   pipe-separated with no quoting, and `messy`'s `BUG-001` forges a whole row otherwise
   (fixtures §5.1).
4. **The `## moved` cutoff is the recorded `last-checkin`,** read as
   `NULLIF(value,'null')` — the seed value is the literal string `'null'`, not SQL NULL.
5. **Narrate in the skill's order**: direction, in flight, blocked, risks, what moved, what is
   waiting on the user, what to do next.
6. **Write nothing.** No `last-checkin` stamp, no roster sync, no `agents/*.md`.

### Postconditions

**§5.a — the brief wrote nothing.** This is the only postcondition about the board, and it is
absolute. Capture the fingerprint before and after, and `diff` must be empty:

```sql
-- fingerprint.sql — run BEFORE and AFTER; diff the two outputs
SELECT 'event'          AS part, COUNT(*) || '/' || COALESCE(MAX(id),0) AS v FROM event
UNION ALL SELECT 'guild_state',    COUNT(*) || '/' || COALESCE(SUM(length(key) + length(value)),0) FROM guild_state
UNION ALL SELECT 'state:' || key,  value FROM guild_state WHERE key IN ('actor','last-checkin')
UNION ALL SELECT 'task',           COUNT(*) || '/' || COALESCE(SUM(length(id) + length(status) + length(COALESCE(claimed_by,''))),0) FROM task
UNION ALL SELECT 'graph_node',     COUNT(*) || '/' || COALESCE(SUM(length(id) + length(status)),0) FROM graph_node
UNION ALL SELECT 'gate',           COUNT(*) || '/' || COALESCE(SUM(length(node_id) + length(status)),0) FROM gate
UNION ALL SELECT 'requirement',    COUNT(*) || '/' || COALESCE(SUM(length(id) + length(status)),0) FROM requirement
UNION ALL SELECT 'work_log',       COUNT(*) || '/' || COALESCE(MAX(id),0) FROM work_log
UNION ALL SELECT 'review_finding', COUNT(*) || '/' || COALESCE(SUM(length(disposition)),0) FROM review_finding
UNION ALL SELECT 'bug',            COUNT(*) || '/' || COALESCE(SUM(length(id) + length(status)),0) FROM bug
UNION ALL SELECT 'coverage',       COUNT(*) || '/' || COALESCE(SUM(length(id) + length(COALESCE(last_inspected_at,''))),0) FROM coverage
UNION ALL SELECT 'agent',          COUNT(*) || '/' || COALESCE(SUM(length(name) + active + serial),0) FROM agent
UNION ALL SELECT 'doc',            COUNT(*) FROM doc
ORDER BY part;
```

```bash
tursodb -q -m list .guild/guild.db < fingerprint.sql > /tmp/fp.before
# … run guild:brief …
tursodb -q -m list .guild/guild.db < fingerprint.sql > /tmp/fp.after
diff /tmp/fp.before /tmp/fp.after || echo "EXPECTATION VIOLATED: the brief wrote to the board"
```

On `messy` the fingerprint is 14 lines beginning `agent|14/212` and ending `work_log|6/6`.

*Verified to fire:* the single most likely violation — a brief that stamps its own check-in —
returns

```
8c8
< guild_state|3/63
---
> guild_state|3/79
12c12
< state:last-checkin|null
---
> state:last-checkin|2026-08-15T00:00:00Z
```

which is exactly the failure `guild:brief`'s Step 2 warns about: stamping the cutoff pollutes
the feed the *next* brief's "what moved" section reads.

**§5.b — the roll call: what the narration is obliged to name.** This is the assertion this
section exists for. It returns one row per fact the brief must carry, as a token distinctive
enough to grep for:

```sql
-- rollcall.sql
SELECT DISTINCT kind, token FROM (
  SELECT 'bug-open'              AS kind, id                     AS token FROM v_open_bugs
  UNION ALL SELECT 'failed-unadjudicated', id                 FROM v_failed_tasks WHERE waived = 0
  UNION ALL SELECT 'failed-waived',        id                 FROM v_failed_tasks WHERE waived = 1
  UNION ALL SELECT 'blocked-task',         id                 FROM v_blocked_tasks
  UNION ALL SELECT 'blocked-because',      reason             FROM v_blocked_tasks
  UNION ALL SELECT 'coverage-stale',       id                 FROM v_coverage_due
  UNION ALL SELECT 'roster-gap',           capability         FROM v_roster_gaps
  UNION ALL SELECT 'capability-unknown',   owner              FROM v_capability_unknown
  UNION ALL SELECT 'gate-waiting',         node_id            FROM v_gates_pending
  UNION ALL SELECT 'finding-where',  COALESCE(file,'') || ':' || COALESCE(line,0)
                                          FROM v_open_findings WHERE severity IN ('critical','major')
  UNION ALL SELECT 'finding-reviewer',     reviewer           FROM v_open_findings WHERE severity IN ('critical','major')
  UNION ALL SELECT 'in-flight',            id                 FROM v_in_flight
  UNION ALL SELECT 'moved',                subject_id         FROM v_recent_activity
   WHERE ts >= COALESCE(NULLIF((SELECT value FROM guild_state WHERE key='last-checkin'),'null'),'')
     AND ( (subject_type='task' AND verb='moved') OR (subject_type='bug' AND verb='created')
        OR (subject_type='gate' AND verb='decided') )
) ORDER BY kind, token;
```

Every token must appear **literally** in the brief's text. The harness:

```bash
tursodb -q -m list .guild/guild.db < rollcall.sql > /tmp/rollcall.txt
fail=0
while IFS='|' read -r kind token; do
  [ -z "$token" ] && continue
  grep -qF -- "$token" /tmp/brief.md || { echo "BRIEF OMITS  $kind  $token"; fail=1; }
done < /tmp/rollcall.txt
[ $fail -eq 0 ] || exit 1
```

**On `messy` the roll call is exactly 27 rows**, and this is the transcript:

```
blocked-because|deps:TASK-003            failed-unadjudicated|TASK-007
blocked-because|deps:TASK-004            failed-waived|TASK-008
blocked-because|no-eligible-agent:embedded   in-flight|TASK-003
blocked-because|status-blocked           moved|BUG-001
blocked-task|TASK-004                    moved|BUG-002
blocked-task|TASK-005                    moved|REQ-001/gate-plan
blocked-task|TASK-009                    moved|TASK-001
blocked-task|TASK-010                    moved|TASK-002
blocked-task|TASK-011                    moved|TASK-003
bug-open|BUG-001                         moved|TASK-007
bug-open|BUG-002                         moved|TASK-008
capability-unknown|TASK-010              moved|TASK-009
coverage-stale|auth-session              roster-gap|rust
coverage-stale|checkout-flow
```

Row counts per fixture, so a harness can sanity-check its own load: `empty` **0**, `planned`
**5**, `review-ready` **12**, `maintenance` **8**, `messy` **27**.

**A brief that omits a failed task is a FAILURE.** Nothing crashed, no query errored, the exit
code was 0, and the deliverable is wrong — `TASK-007` failed with 12k of 480k rows backfilled and
nobody has ruled on it, and a brief that does not say so has told the guild master the board is
in better shape than it is. The same holds for every other row above: an omitted `roster-gap`
hides the one risk with a known remedy; an omitted `blocked-because` turns "nobody can take this"
into "it's in the backlog".

*Verified to fire.* Against a plausible-looking brief that covers direction, in-flight, both
bugs, all five stuck tickets and both coverage areas — everything a reader would call thorough —
the harness returns:

```
BRIEF OMITS  failed-unadjudicated  TASK-007
BRIEF OMITS  failed-waived  TASK-008
BRIEF OMITS  moved  REQ-001/gate-plan
BRIEF OMITS  moved  TASK-001
BRIEF OMITS  moved  TASK-002
BRIEF OMITS  moved  TASK-007
BRIEF OMITS  moved  TASK-008
BRIEF OMITS  roster-gap  rust
```

A brief that also carries the failures, the waiver, the gap and the activity beat returns
`BRIEF COMPLETE`, exit 0.

**§5.c — the counts the narration must agree with.** Every number the brief states must be a
value in this result. It is the reference, not an assertion the harness can run on its own
(see *Cannot be asserted*):

```sql
SELECT fact, value FROM v_brief;
```

On `messy`, the two rows that decide whether the brief is honest:

```
bounties_open|1
bounties_stuck|5
tasks_todo|6
```

**`tasks_todo` is 6 and `bounties_open` is 1.** Five of the six cannot be handed to anybody. A
brief that reports the backlog as available work is wrong by 500%, and both numbers must appear
in the text — `count-bounties-open` and `count-bounties-stuck` are cheap to add to §5.b's roll
call as `SELECT 'count-bounties-open', value FROM v_brief WHERE fact='bounties_open'` when a
stricter check is wanted.

**§5.d — the window is the recorded cutoff.** Expect the brief to state which cutoff it used,
and for that cutoff to be this value:

```sql
SELECT COALESCE(NULLIF((SELECT value FROM guild_state WHERE key = 'last-checkin'), 'null'), '(everything)');
-- messy → (everything)
```

On every fixture `last-checkin` is the literal `'null'`, so the window is the whole history and
`## moved` is the full feed. Do **not** assert on `v_brief.events_since_checkin` (61 on `messy`):
it is a function of how many rows the seed wrote and it moves whenever the fixture is edited.

### Anti-expectations

Zero rows / no match when healthy.

| Must not be true | How it is caught |
|---|---|
| The brief stamped `last-checkin`, synced the roster, or wrote any row | §5.a — the fingerprint diff |
| A failed, blocked or bugged item was left out | §5.b — the roll call names it |
| `next = none` was narrated as "finished" or "all caught up" | judgment; see below |
| The backlog count was presented as available work | §5.c — both numbers must appear |
| A number appears that no view produced | judgment; see below |
| An empty category was announced ("no bugs open") | judgment |
| The rows were pasted instead of narrated | judgment |

The `next = none` case is worth its own fixture note. It is **`review-ready`**, not `messy`:
there, `v_next_task` is empty, `v_open_bounties` is empty, every ticket is `done`, and
`v_requirement_progress` reads `6|6|0|0|0`. The roll call still returns 12 rows — a pending gate
and four findings, two of them `critical`/`major`. A brief that says "all caught up" on that
board has read four surfaces correctly and drawn the one conclusion the whole gate model exists
to prevent. §5.b catches it *only* because the gate and the findings are in the roll call; it
does not catch the sentence itself.

### Cannot be asserted

- **Whether a stated number is right.** §5.b proves a token is *present*. A brief that writes
  "TASK-007 failed 3 days ago" when it failed 13 days ago passes every check here. Only presence
  is mechanical; correctness of an unquoted figure is not.
- **Whether the prose is a briefing.** "Do not paste the rows and call it a briefing" is the
  skill's rule and it is unenforceable. A brief that dumps all 27 roll-call tokens as a bulleted
  list passes §5.b with full marks.
- **Whether the narration draws the right conclusion.** The three-way ambiguity of a zero —
  `nodes_ready = 0` on `messy` means *wait*, on `review-ready` means *ask a human*, and on a
  finished board means *done* — is a judgment. The facts distinguishing them are all in the roll
  call; whether the sentence built from them is right is not.
- **The empty guild.** On `empty` the roll call is **0 rows**, so every brief passes trivially.
  The failure there is the opposite shape — inventing work, or reading "nothing to do" as "the
  project is finished" — and it is not roll-call-catchable. The only mechanical handle is
  `v_brief` returning its full **23 rows of zeros**; a brief that returns nothing has skipped the
  view.
- **Whether a `-m list` row was parsed positionally.** The `json_object` rule prevents it, but a
  brief that got it wrong and then narrated `BUG-001`'s forged second line as a real ticket would
  contain the string `TASK-999`. `grep -F 'TASK-999' brief.md` is therefore an *indicator*, not
  an assertion — a brief that legitimately quotes `BUG-001`'s title verbatim trips it too — and
  in any case it catches only this one fixture's trap, not the class.

---

## 6. The dashboard

`.guild/dashboard.html`. The assertions in this section are over the **artifact**, not the
database — the board is unchanged by definition, so §5.a's fingerprint is the whole of the
board-side expectation and is not restated.

**Two of these are security, not cosmetics.** They are carried over from v5's review rounds, and
they exist because the board holds text the guild master and four kinds of agent typed:
requirement titles, bug reports, review findings, work logs. A page that executes a requirement
title is a real defect, reachable by anyone who can file a bug.

### Trigger

`guild:dashboard` — "the dashboard", "visualize the board", "the roadmap", "the coverage view",
"the activity feed". Also offered by `guild:brief`'s closing line, and by check-in's wrap-up.

### Preconditions

`.guild/config.yaml` exists (shell). The board-side precondition is §5.a's P5.a plus the four
raw tables the page reads directly rather than through a view:

```sql
-- P6.a  the page's data sources exist — expect ZERO ROWS
SELECT 'missing-source' AS breach, v.n AS row_id FROM (
  SELECT 'v_brief' AS n UNION ALL SELECT 'v_goal_progress' UNION ALL SELECT 'v_requirement_progress'
  UNION ALL SELECT 'v_board' UNION ALL SELECT 'v_blocked_tasks' UNION ALL SELECT 'v_roster_gaps'
  UNION ALL SELECT 'v_recent_activity'
  UNION ALL SELECT 'phase' UNION ALL SELECT 'graph_node' UNION ALL SELECT 'graph_edge'
  UNION ALL SELECT 'gate' UNION ALL SELECT 'bug' UNION ALL SELECT 'review_finding'
  UNION ALL SELECT 'coverage') v
 WHERE NOT EXISTS (SELECT 1 FROM sqlite_schema s WHERE s.type IN ('view','table') AND s.name = v.n);
```

### Expected sequence

1. **One query, one row, one column.** The whole board crosses as a single `json_object`, so
   `-m list` never inserts a separator and free text stays byte-exact.
2. **The three `replace()`s escape `&`, `<` and `>` inside the engine,** using `char(92)` for the
   backslash. Nothing between the engine and the file can mangle it.
3. **Verify the escape before building.** `grep -c '<' /tmp/guild-data.json` must be 0.
4. **Build in three pieces** — head, data file, tail, concatenated. The data is never substituted
   into a template.
5. **Render every node with `createElement` + `textContent`.** The island is the only door the
   board's text uses to reach the page.
6. **Seven views**, switched client-side, each with an honest empty state.
7. **Offer the Artifact link; never take it.**

Step 3's ordering is load-bearing: the check has to happen on the data file, before the
concatenation, because after the concatenation the page's own markup makes `grep -c '<'` useless.

### Postconditions

Assertions §6.a–§6.d run on the **data file**, §6.e–§6.g on the **built page**. `messy` is the
fixture, with one addition — a bug whose title carries a real script-close, which is the input
these assertions exist for:

```sql
-- 07-xss.sql, loaded over messy. Title: Totals wrong </script><script>alert(document.domain)</script> on promo
INSERT INTO bug (id, title, body, repro, severity, status, found_by, requirement_id,
                 fix_task_id, created_at, updated_at)
VALUES ('BUG-003', CAST(x'546f74616c732077726f6e67203c2f7363726970743e3c7363726970743e616c65727428646f63756d656e742e646f6d61696e293c2f7363726970743e206f6e2070726f6d6f' AS TEXT),
        '', '', 'major','open','qa-tester','REQ-001',NULL,
        '2026-08-02T12:00:00Z','2026-08-02T12:00:00Z');
-- and a task title carrying an attribute-context payload and a bare ampersand:
-- Escape the "cart" & <img src=x onerror=alert(1)> path
UPDATE task SET title = CAST(x'45736361706520746865202263617274222026203c696d67207372633d78206f6e6572726f723d616c6572742831293e2070617468' AS TEXT) WHERE id = 'TASK-012';
```

**§6.a — SECURITY. No unescaped angle bracket or ampersand leaves the engine.** Expect **0**:

```bash
grep -c '<' /tmp/guild-data.json      # must be 0
grep -c '>' /tmp/guild-data.json      # must be 0
grep -c '&' /tmp/guild-data.json      # must be 0
```

*Verified:* all three are `0` on the fixture above, and the injected title survives in the island
as `Totals wrong </script><script>alert(document.domain)</script> on promo`,
round-tripping through `JSON.parse` to the original text byte-for-byte.

*Verified to fire:* with the three `replace()`s removed, `grep -c '<'` returns **1**.

Two mechanics worth stating, because both have been got wrong: the data file is **exactly one
line** (`json_object` escapes the real newline in `BUG-001`'s title to `\n`), so `grep -c` returns
0 or 1 rather than an occurrence count — which is sufficient for a must-be-zero test but is not a
tally. And `&` is escaped for the same reason as the brackets: `&lt;/script&gt;` is not the risk,
but an unescaped `&` in an HTML-parsed context is one entity away from reconstructing one.

**§6.b — SECURITY. A title containing `</script>` appears as literal text and does not close the
element.** This is the assertion, and it is two greps on the **built page**:

```bash
# the payload is present, escaped, inside the island
grep -c 'u003c/script' .guild/dashboard.html          # must be >= 1 when the fixture is loaded
# the page contains exactly the closers it wrote itself: the island's, and the code block's
[ "$(grep -o '</script>' .guild/dashboard.html | wc -l)" -eq 2 ] || echo "ISLAND ESCAPED"
```

*Verified:* `1` and `2` on the built page. The rendered `<li>` reads
`Totals wrong </script><script>alert(document.domain)</script> on promo` as text, because
`textContent` was used.

*Verified to fire:* built from the unescaped data, the same page contains **6** `</script>`
closers instead of 2 — the injected title breaks out of the island once in `bugs[]` and once in
`activity[]`, and each break contributes two. Six is not a subtle signal; the point of counting
rather than searching is that it stays a hard number as the page grows.

**§6.c — every view is present, and every empty one is an empty array rather than `null`.** Run
against the data file:

```python
NEEDED = ['brief','goals','phases','requirements','tasks','blocked','gaps',
          'nodes','edges','gates','bugs','findings','coverage','activity']
d = json.load(open('/tmp/guild-data.json'))
for k in NEEDED:
    assert k in d,                    'MISSING KEY   ' + k
    assert d[k] is not None,          'NULL NOT []   ' + k
    assert isinstance(d[k], list),    'NOT AN ARRAY  ' + k
assert not [k for k in d if k not in NEEDED], 'UNDECLARED KEY'
```

**Fourteen keys, no more and no fewer.** *Verified* on `messy` and on **`empty`**, where all
thirteen list keys are `[]` and `brief` still carries its full **23 rows**. `empty` is the fixture
that matters here: a page whose Bugs view renders `undefined` or throws on an empty board reads an
empty guild as a broken one.

The honest-empty-state rule extends to one value the JSON cannot express:
`coverage[].last` is `''` for an area never inspected. Rendering that as "0 days ago" lies about
the state of the product, and on `messy` `auth-session` is exactly that case.

**§6.d — SECURITY. No `innerHTML`, and no external request of any kind.** Both greps run on the
page with the island removed, because the island legitimately contains board text that looks like
markup — on `messy` the injected `TASK-012` title contains the literal `src=`, and a naive grep
over the whole file reports it as an external image:

```bash
grep -vxF -f /tmp/guild-data.json .guild/dashboard.html > /tmp/dash-shell.html

grep -n 'innerHTML\|outerHTML\|insertAdjacentHTML\|document\.write\|eval(\|new Function' /tmp/dash-shell.html
grep -niE 'https?://|//cdn|fetch\(|XMLHttpRequest|WebSocket|EventSource|<link|<img|<iframe|<object|<embed|@import|url\(|integrity=|crossorigin' /tmp/dash-shell.html
```

Nothing printed by either is the passing result. *Verified:* both silent on a 34-line, 1426-byte
shell extracted from a 19,918-byte page. *Verified to fire:* inserting
`<link rel="stylesheet" href="https://cdn.example.com/x.css">` into the head returns
`5:<link rel="stylesheet" href="https://cdn.example.com/x.css"></head><body>`.

`grep -vxF -f <datafile>` deletes the lines that exactly match the data — which works precisely
because the data is one line, and is the reason §6.a's "one line" property is worth preserving.

**§6.e — the same input produces the same page.** Build twice with no board write in between:

```bash
tursodb -q -m list .guild/guild.db < /tmp/guild-dash.sql > /tmp/d1.json
tursodb -q -m list .guild/guild.db < /tmp/guild-dash.sql > /tmp/d2.json
cmp /tmp/d1.json /tmp/d2.json || echo "EXPECTATION VIOLATED: the page is not reproducible"
```

**This assertion currently FIRES, and the cause is one field.** Two builds two seconds apart
differ in exactly one place:

```
  .brief[0].value              '2026-08-15T11:41:26Z' != '2026-08-15T11:41:28Z'
```

`v_brief`'s first row is `generated_at`, defined as `strftime('%Y-%m-%dT%H:%M:%SZ','now')`, and the
dashboard pulls all 23 `v_brief` rows into the island. The skill's own claim — *"The board holds
no wall clock: `json_object` carries only stored timestamps, so the same state produces the same
bytes and the file diffs cleanly if the user commits it"* — is false for this one field, and it is
false in the way that matters: a user who commits `.guild/dashboard.html` gets a diff on every
rebuild whether or not the board moved.

The fix is one of two things, and it belongs in the skill rather than in this assertion: drop
`generated_at` from the island (`FROM v_brief WHERE fact <> 'generated_at'`) and render the build
time in the browser like every other "3 days ago", or accept the field and narrow the assertion to
`d1 == d2` after deleting `brief[0]`. **Nothing else in the payload carries a clock** — that was
checked by diffing every leaf of the two documents, and `brief[0].value` was the only one.

**§6.f — the page is self-contained and opens from `file://`.** Structural, not a grep:
`.guild/dashboard.html` is a single file, the CSS and JS are inline, and the data is inline. §6.d
covers the network half. The remaining half — that the page *works* — is not assertable without a
browser; see below.

**§6.g — the summary tiles link to the view behind them.** Every number on the page reaches a list
of names in one click. Not assertable; it is the design rule the page exists to satisfy.

### Anti-expectations

| Must not be true | Caught by |
|---|---|
| A board value reaches the page as markup rather than as JSON | §6.a, §6.b |
| The page contains more `</script>` closers than it wrote itself | §6.b |
| A view key is missing, `null`, or undeclared | §6.c |
| `innerHTML` / `insertAdjacentHTML` / `eval` anywhere in the shell | §6.d |
| Any CDN, font, image, `fetch`, or socket | §6.d |
| Two builds of one board differ | §6.e — **currently fires on `brief[0]`** |
| A never-inspected coverage area rendered as fresh | §6.c's note; not mechanical |
| The page published as an Artifact without being asked | not assertable |
| `.guild/dashboard.html` hand-edited | not assertable — the next build discards it |

### Cannot be asserted

- **That the page renders.** Every assertion here is textual. A page that passes all of them and
  throws on `DATA.requirements.forEach` at load is not distinguishable from one that works without
  actually opening a browser. Opening it is the check, and it is a human's.
- **That `textContent` was used everywhere it should have been.** §6.d proves the *banned sinks*
  are absent, which is a different claim: a page that assembles a node's text with
  `node.setAttribute('title', bug.title)` passes the grep and still puts board text in an
  attribute, which the skill's own rules forbid.
- **Whether the seven views answer the questions the table says they answer.** §6.c proves the
  data for each view is present. Whether the Findings view actually groups by severity, or the
  Graph view shows predecessors, is a read of the code.
- **Whether an empty state is honest.** "Nothing here yet" versus a blank panel versus a thrown
  error are three different user experiences and one identical JSON payload.
- **Whether publishing the page was the right call.** The disclosure decision — the page carries
  real requirement titles, bug reports and activity history — belongs to the user, and no query
  can tell whether they were asked.

---

## 7. The check-in loop

The orchestrator. This is the only process in this document that both reads and writes at scale,
and its expectations split cleanly along that line: **§5's roll call binds its Step 2 narration**
(it opens with the same reads as the brief), and everything below binds the loop.

Four things are asserted here, and they are the four ways an orchestrator goes wrong:

1. it re-derives a rule instead of reading the view, and gets it subtly different;
2. it dispatches by a hardcoded agent name rather than by `v_agent_match`;
3. it lets somebody other than itself move a status;
4. it builds past a gate.

### Trigger

`guild:check-in` — "check in", "standup", "let's get to work", "continue", "I'm here". Also the
resume path after `guild:new-requirement` hands `gate-plan` back approved.

### Preconditions

```sql
-- P7.a  the roster is synced and legal — expect ZERO ROWS.
--       Step 1.2 writes this; skipping it turns a good board into a wall of blocked tickets.
SELECT 'roster-empty' AS breach, '' AS detail WHERE NOT EXISTS (SELECT 1 FROM agent WHERE active = 1)
UNION ALL SELECT 'unknown-capability', side || ':' || owner || ':' || capability FROM v_capability_unknown;

-- P7.b  nothing was left half-recorded by the last session — expect ZERO ROWS
SELECT 'running-node-no-claimed-ticket' AS breach, n.id AS row_id, COALESCE(n.task_id,'(unbound)') AS detail
  FROM graph_node n
 WHERE n.status = 'running'
   AND NOT EXISTS (SELECT 1 FROM task t WHERE t.id = n.task_id AND t.status = 'in-progress');
```

P7.a is a **report**, not a stop: on `messy` it returns
`unknown-capability | task:TASK-010:embedded`, which is a real board state the check-in must
narrate rather than route around. On `empty` it returns `roster-empty` — correct, and the reason
Step 1.2's roster sync runs before anything else. P7.b returning rows is the crash-recovery case
that Step 1.3 exists for: resolve it before Step 3, never by re-dispatching blind.

*Verified:* P7.b is zero rows on all six fixtures; on `review-ready` with `test-plan` forced back
to `running` it returns `running-node-no-claimed-ticket | REQ-001/test-plan | TASK-004`.

### Expected sequence

1. **Step 1** — apply the schema (idempotent), sync the roster, recover anything `running`.
   Do **not** stamp `last-checkin`; it is the cutoff Step 2 reads.
2. **Step 2** — read `v_brief` and its detail lists in one script and narrate. Bound by §5.b.
3. **3.1** — pick the lowest-id `in-progress` requirement, else the lowest-id `todo` one, then ask
   `v_ready_nodes` what is runnable. **The segment query mutates nothing.**
4. **3.2** — cut the ready *work* nodes into ONE batch, capped by the template's `parallel:`
   line, and independently capped by the `serial` flag. Never two `serial = 1` members at once.
5. **3.3** — resolve the member from `v_task_top_agent` / `v_agent_match`, then move the ticket
   and the node, **in that order**, each with `RETURNING`.
6. **3.4** — record both halves for every node in the batch, then go back to 3.1. Readiness
   propagates; the whole graph is never queued.
7. **3.5** — at `gate-repairs`, present one decision, record `gate.status` **and**
   `graph_node.status`, then fan out repair tickets and link them.
8. **3.6** — close the requirement only when `tasks_open = 0`, which counts `blocked`.
9. **Step 4** — wrap up, then **stamp `last-checkin` last**.

Two orderings are load-bearing and the assertions below depend on them: the gate row is written
*before* the node moves (setting `gate.status` moves nothing on its own), and `last-checkin` is
stamped *after* everything else.

### Postconditions

One script, seven clauses. Zero rows when healthy. Run it after every batch, not only at wrap-up:

```sql
-- checkin.sql
-- C.a  a ticket handed to somebody the matcher never offered  =  HARDCODED DISPATCH
SELECT 'dispatched-to-unmatched-agent' AS breach, t.id AS row_id, t.claimed_by AS detail
  FROM task t
 WHERE COALESCE(t.claimed_by,'') <> ''
   AND NOT EXISTS (SELECT 1 FROM v_agent_match m WHERE m.task_id = t.id AND m.agent = t.claimed_by)
UNION ALL
-- C.b  a status transition whose actor is neither the orchestrator nor the guild master
SELECT 'status-moved-by-non-orchestrator', e.subject_type || ':' || e.subject_id, e.actor
  FROM event e
 WHERE e.verb IN ('moved','node-moved','decided','claimed')
   AND e.actor NOT IN ('orchestrator','user')
UNION ALL
-- C.c  a gate approved while one of its predecessors had not finished
SELECT 'gate-approved-while-predecessor-open', g.node_id, p.id || '=' || p.status
  FROM gate g
  JOIN graph_edge e ON e.to_node = g.node_id
  JOIN graph_node p ON p.id = e.from_node
 WHERE g.status = 'approved' AND p.status NOT IN ('done','skipped')
UNION ALL
-- C.d  the two halves disagree, in either direction
SELECT 'task-done-node-still-running', t.id, n.id || '=' || n.status
  FROM task t JOIN graph_node n ON n.task_id = t.id
 WHERE t.status = 'done' AND n.status IN ('pending','running')
UNION ALL
SELECT 'node-done-task-still-open', n.id, t.id || '=' || t.status
  FROM graph_node n JOIN task t ON t.id = n.task_id
 WHERE n.status = 'done' AND t.status IN ('todo','in-progress','blocked')
UNION ALL
-- C.e  a node left running with nobody working  =  a crash site holding everything behind it
SELECT 'running-node-no-claimed-ticket', n.id, COALESCE(n.task_id,'(unbound)')
  FROM graph_node n
 WHERE n.status = 'running'
   AND NOT EXISTS (SELECT 1 FROM task t WHERE t.id = n.task_id AND t.status = 'in-progress')
UNION ALL
-- C.f  WRAP-UP ONLY: work was recorded after the check-in was stamped
SELECT 'event-after-last-checkin-stamp', CAST(COUNT(*) AS TEXT), MAX(e.ts)
  FROM event e
 WHERE (SELECT value FROM guild_state WHERE key='last-checkin') <> 'null'
   AND e.ts > (SELECT value FROM guild_state WHERE key='last-checkin')
HAVING COUNT(*) > 0
UNION ALL
-- C.g  a ticket claimed while its requirement's plan gate is undecided
SELECT 'claimed-before-gate-plan', t.id, g.status
  FROM task t
  JOIN graph_node n ON n.requirement_id = t.requirement_id AND n.node_key = 'gate-plan'
  JOIN gate g ON g.node_id = n.id
 WHERE g.status <> 'approved' AND COALESCE(t.claimed_by,'') <> ''
ORDER BY breach, row_id;
```

*Verified:* **zero rows on all six fixtures** — `empty`, `planned`, `in-flight`,
`review-ready`, `maintenance` and `messy`. Every clause was then fired individually:

| clause | injected breach | returned |
|---|---|---|
| **C.a** | `TASK-004` (needs `test-planning`) claimed by `developer` | `dispatched-to-unmatched-agent \| TASK-004 \| developer` |
| **C.b** | `actor = 'developer'`, then `UPDATE task SET status='done'` | `status-moved-by-non-orchestrator \| task:TASK-011 \| developer` |
| **C.c** | `gate-repairs` approved with one review node back at `pending` | `gate-approved-while-predecessor-open \| REQ-001/gate-repairs \| REQ-001/review.reviewer-security=pending` |
| **C.d/C.e** | `test-plan` node forced to `running` while its ticket is `done` | `task-done-node-still-running \| TASK-004 \| REQ-001/test-plan=running` and `running-node-no-claimed-ticket \| REQ-001/test-plan \| TASK-004` |
| **C.f** | `last-checkin` set to a date before the run | `event-after-last-checkin-stamp \| 61 \| 2026-08-15T11:37:45.776Z` |
| **C.g** | `gate-plan` reverted to `pending` on `messy` | `claimed-before-gate-plan \| TASK-001 \| pending` and four more |

**§7.a — C.a is the hardcoded-dispatch assertion, and it is the strongest one here.** G5's
`top-agent-disagrees-with-match` compares the two matcher views against each other; C.a compares
*what actually happened* against them. A member that decided "REQ-001 is a developer requirement"
and claimed all six tickets for `developer` passes G5 — the views still agree with each other —
and fails C.a on `TASK-004` and `TASK-005` immediately. `messy` is the fixture that makes it
visible: `TASK-002` prefers `svelte` and goes to `developer-svelte`, while `TASK-001` and
`TASK-003` go to `developer`, so one hardcoded name is wrong twice on one requirement.

C.a deliberately reads `v_agent_match` rather than `v_task_top_agent`: dispatching rank 2 is a
legitimate call the guild master can make out loud, and the assertion is about dispatching to
somebody the matcher *never named at all*.

**§7.b — C.b is "you own every status transition", made checkable.** `guild:check-in` Key Rule 2
says plainly that no constraint enforces it. This clause is the only thing that reports it, and
its `'user'` exemption is exactly one thing: a gate decision, which `03-in-flight.sql` records
with `actor = 'user'` and which appears in the feed as
`user | decided | gate | REQ-001/gate-plan | pending -> approved`. Everything else must be
`orchestrator`. Note what it does **not** cover: `created`, `logged` and `found` are agents' own
writes and are legal from any actor — an agent filing a `bug` mid-run is the collect-don't-escalate
rule working.

**§7.c — C.f is a wrap-up-only assertion.** Between sessions, `last-checkin` is *supposed* to be
older than the newest event, so running C.f on an idle board fires by design. Run it once,
immediately after Step 4's stamp. One subtlety, verified: trigger-written `event.ts` carries
milliseconds (`2026-08-15T11:37:45.776Z`) while `last-checkin` does not
(`strftime('%Y-%m-%dT%H:%M:%SZ')`), and `'…45.776Z' > '…45Z'` evaluates to **0** — `.` sorts below
`Z` — so an event written in the same second as the stamp does not produce a false positive.

**§7.d — stopping at gates.** Covered by G4 (`built-before-gate-plan`, `past-unresolved-gate`,
`decided-gate-node-not-moved`) plus C.c and C.g. The division is worth stating: G4 asks whether
*work moved* past an undecided gate; C.g asks whether a ticket was *claimed* — which happens
earlier and is the first observable moment the process went wrong. `planned` is the fixture:
three tickets sit on `v_open_bounties` with `gate-plan` still `pending`, and nothing in the schema
connects them to it.

**§7.e — the serial invariant.** G9 `serial-agent-double-booked`, run before every `qa-execute`
dispatch, not only afterwards. `maintenance` is the fixture and the trap is live:

```sql
SELECT task_id, agent, source, serial FROM v_agent_match WHERE task_id = 'TASK-904';
-- TASK-904|qa-tester|capability|1
```

`serial = 1` is in the row the matcher hands over. **Nothing will stop the dispatch.**

### Anti-expectations

| Must not be true | Caught by |
|---|---|
| A ticket dispatched to a member `v_agent_match` never named | §7 C.a |
| An agent moved its own ticket, node or gate | §7 C.b |
| A gate approved before its predecessors finished | §7 C.c |
| A ticket moved without its node, or a node without its ticket | §7 C.d |
| A node left `running` with nobody on it | §7 C.e, P7.b |
| `last-checkin` stamped before the work | §7 C.f |
| A ticket claimed before `gate-plan` was approved | §7 C.g |
| `gate-plan` approved by the orchestrator rather than handed back | not assertable — see below |
| Two `serial = 1` members in one batch | G9 |
| A requirement closed over a `blocked` ticket | G6 `requirement-done-over-open-task` |
| A finding left `open` after `gate-repairs` decided | G6 `finding-open-past-gate-repairs` |
| A gate added or dropped | G4 `added-gate`, `dropped-gate` |
| A blocked ticket the matcher could actually cover | G6 `blocked-but-coverable` |

### Cannot be asserted

- **Which view a member read.** This is the largest gap in this section. C.a catches a dispatch
  the matcher would not have made, and §5.b catches a narration that omits a fact — but a member
  that hand-rolled its own `NOT EXISTS` over `task_dependency`, got the same answer as
  `v_blocked_tasks` this time, and will get a different one next time, is invisible to every
  query here. The board records outcomes, not methods. Reviewing the SQL the member actually ran
  is the only check, and it is a human's.
- **Whether `gate-plan` was approved by the right skill.** `gate.status` is a column and
  `guild_state.actor` is a label. C.b's `'user'` exemption is exactly the hole: an orchestrator
  that set `actor = 'user'` and approved its own plan gate passes.
- **Whether the batch respected the template's `parallel:` ceiling.** The template lives in a
  markdown file, not in the database, and a batch is not a row — only its effects are. Two nodes
  moved to `running` in the same second is suggestive and not evidence.
- **Whether an agent actually did the work.** A ticket moved to `done` with a plausible work-log
  entry and no repository change passes everything in this document.
- **Whether a `NEEDS INPUT:` pause was relayed rather than answered on the user's behalf.** The
  board shows a ticket that did not move. It cannot show who answered.
- **Whether the narration at Step 2 was acted on.** §5.b proves the facts were stated. That the
  orchestrator then picked the requirement the facts pointed at is judgment.

---

## 8. Clearing the board

`guild:clear-board`. Genuinely destructive, no undo, and the expectations are symmetrical: what
must be **gone**, and what must be **untouched**. The second half is the one that matters — a
clear that also took the coverage map or a roster member has destroyed something a board reset
was never supposed to reach.

### Trigger

`guild:clear-board` — "clear the board", "reset the guild", "start fresh", "wipe the board".

### Preconditions

```sql
-- P8.a  there is something to clear — expect AT LEAST ONE non-zero row
SELECT 'requirements' AS what, COUNT(*) AS n FROM requirement
UNION ALL SELECT 'tasks', COUNT(*) FROM task
UNION ALL SELECT 'graph_nodes', COUNT(*) FROM graph_node
UNION ALL SELECT 'plans', COUNT(*) FROM plan;
```

All zero → `The guild board is already empty — nothing to clear.` and stop.

**P8.b — the backup exists, and it was taken BEFORE the confirmation was asked.** A filesystem
check, not SQL, and not optional: `ls .guild/guild.db.bak-*` must name a file newer than the
session. This is the only undo there is.

**P8.c — the keep fingerprint is captured before the deletes.** Everything §8.b asserts is a
comparison, so there has to be a *before*:

```sql
-- keep.sql — run BEFORE the clear, and again after
SELECT 'agent'            AS t, COUNT(*) AS n FROM agent
UNION ALL SELECT 'agent_capability', COUNT(*) FROM agent_capability
UNION ALL SELECT 'coverage',         COUNT(*) FROM coverage
UNION ALL SELECT 'doc',              COUNT(*) FROM doc
UNION ALL SELECT 'event',            COUNT(*) FROM event
UNION ALL SELECT 'state-actor',      (SELECT COUNT(*) FROM guild_state WHERE key = 'actor')
UNION ALL SELECT 'state-checkin',    (SELECT COUNT(*) FROM guild_state WHERE key = 'last-checkin')
ORDER BY t;
```

On `messy` this reads `agent|14`, `agent_capability|26`, `coverage|3`, `doc|0`, `event|61`,
`state-actor|1`, `state-checkin|1`.

### Expected sequence

1. Inventory, and show it.
2. **Back up before asking**, not after answering.
3. Confirm, stating both what dies and what survives.
4. The deletes, **in the order the skill gives**, with `PRAGMA foreign_keys = ON`.
5. Read the counts back and report what they actually say.
6. The `event` feed is a **second** question, asked separately.

**The order is load-bearing.** `plan.task_id ↔ task.plan_id`, `review_finding.fix_task_id` and
`bug.fix_task_id` are nulled first; everything after is a child-to-parent sweep. *Verified to
fire:* deleting `task` without nulling `plan.task_id` first returns
`Error: Runtime error: immediate foreign key constraint failed`, exit 1, **on stdout**, and
leaves all 12 tasks in place. That is the good case; the bad one is a member that did not check
and reported success.

### Postconditions

**§8.a — every board table is empty.** Expect **zero rows**:

```sql
SELECT 'not-cleared' AS breach, t.tbl AS row_id, CAST(t.n AS TEXT) AS detail FROM (
  SELECT 'goal' AS tbl, COUNT(*) AS n FROM goal
  UNION ALL SELECT 'phase', COUNT(*) FROM phase
  UNION ALL SELECT 'requirement', COUNT(*) FROM requirement
  UNION ALL SELECT 'plan', COUNT(*) FROM plan
  UNION ALL SELECT 'plan_slice', COUNT(*) FROM plan_slice
  UNION ALL SELECT 'task', COUNT(*) FROM task
  UNION ALL SELECT 'task_dependency', COUNT(*) FROM task_dependency
  UNION ALL SELECT 'task_capability', COUNT(*) FROM task_capability
  UNION ALL SELECT 'graph_node', COUNT(*) FROM graph_node
  UNION ALL SELECT 'graph_edge', COUNT(*) FROM graph_edge
  UNION ALL SELECT 'graph_deviation', COUNT(*) FROM graph_deviation
  UNION ALL SELECT 'gate', COUNT(*) FROM gate
  UNION ALL SELECT 'work_log', COUNT(*) FROM work_log
  UNION ALL SELECT 'review_finding', COUNT(*) FROM review_finding
  UNION ALL SELECT 'bug', COUNT(*) FROM bug
  UNION ALL SELECT 'capability_request', COUNT(*) FROM capability_request
  UNION ALL SELECT 'inspection', COUNT(*) FROM inspection
  UNION ALL SELECT 'inspection_coverage', COUNT(*) FROM inspection_coverage
  UNION ALL SELECT 'guild_state:graph-template', COUNT(*) FROM guild_state WHERE key LIKE 'graph-template:%'
) t WHERE t.n > 0
UNION ALL
-- referential health survived the sweep
SELECT 'orphan-after-clear', 'inspection_coverage', ic.coverage_id FROM inspection_coverage ic
 WHERE NOT EXISTS (SELECT 1 FROM coverage c WHERE c.id = ic.coverage_id)
ORDER BY breach, row_id;
```

**Nineteen things, and `guild_state`'s `graph-template:REQ-NNN` keys are the nineteenth.** They
are the easiest to forget because they are not a table, and without them G4's
`graph-without-template` fires on the *next* requirement built on this board.

*Verified:* the skill's exact delete script, run against `messy`, exits 0 with silent stdout and
this assertion returns zero rows. G1's referential-health clauses are also clean afterwards.

**§8.b — the evergreen survived, unchanged.** `diff` the keep fingerprint:

```bash
diff /tmp/keep.before /tmp/keep.after
```

Expect **exactly one differing line**, and it must be `event`, and it must have **increased**.
On `messy` the verified transcript is `event|61` → `event|80`: nineteen delete statements, each
firing the trigger that records it. Every other line is byte-identical — `agent|14`,
`agent_capability|26`, `coverage|3`, `doc|0`, `state-actor|1`, `state-checkin|1`.

That the count *rises* is the assertion, not an artifact: a board that vanished with no trace is
indistinguishable from a corrupted one. A clear that left `event` unchanged means the deletes ran
around the triggers.

**§8.c — the views still answer on a cleared board.** *Verified* on the cleared `messy`:

```
SELECT COUNT(*) FROM v_brief;                    -- 23
SELECT value FROM v_brief WHERE fact = 'next';   -- none
SELECT value FROM v_brief WHERE fact = 'tasks_todo';    -- 0
SELECT value FROM v_brief WHERE fact = 'coverage_due';  -- 2
SELECT value FROM v_brief WHERE fact = 'roster_gaps';   -- 0
```

**`coverage_due` is 2 and `roster_gaps` is 0 on a freshly cleared board, and both are correct.**
The coverage map describes the *product*, which did not go away; the capability requests were
board rows and went with the board. A member that reads the first as a bug — or that "tidies up"
by deleting the coverage rows to make the brief quiet — has destroyed the QA discipline's memory
to fix a number that was telling the truth.

**§8.d — the event purge, only if asked a second time.** After Step 5:

```sql
SELECT 'event-not-purged' AS breach, CAST(COUNT(*) AS TEXT) FROM event HAVING COUNT(*) > 0
UNION ALL SELECT 'checkin-not-reset', value FROM guild_state
 WHERE key = 'last-checkin' AND value <> 'null';
```

Both halves, because a purge that leaves `last-checkin` pointing into a feed that no longer
exists gives the next brief a cutoff with nothing behind it.

### Anti-expectations

| Must not be true | Caught by |
|---|---|
| An agent row deleted rather than deactivated | §8.b — `agent` line changed |
| `coverage` or `doc` deleted | §8.b — those lines changed |
| `event` deleted as part of Step 4 | §8.b — `event` must *rise*, not fall |
| `guild_state.actor` or `last-checkin` deleted | §8.b — the two `state-*` lines |
| `graph-template:*` keys left behind | §8.a — the nineteenth row |
| The clear left no trace | §8.b — `event` unchanged |
| `.guild/docs/`, `.guild/qa/`, `.guild/reviews/` removed | filesystem check; not SQL |
| An `rm -rf` anywhere inside `.guild/` | not assertable after the fact |
| One `yes` destroyed both the board and the feed | not assertable — it is a conversation |

### Cannot be asserted

- **Whether the backup was taken before the question was asked.** The file's mtime proves it
  exists, not that the ordering held.
- **Whether the user understood what they said yes to.** The skill's confirmation text names what
  survives precisely because a user who thinks their coverage map is about to go answers a
  different question. Whether they read it is not a row.
- **Whether the on-disk evergreen directories survived.** `ls .guild/docs .guild/qa
  .guild/reviews` is the check and it is a shell one; nothing in the database knows they exist.
- **Whether a `FOREIGN KEY constraint failed` line was noticed.** It arrives on *stdout*, exit
  code 1, and a member that piped the script to `/dev/null` has a half-cleared board and a
  clean-looking report. §8.a is what catches the result; nothing catches the not-looking.

---

## 9. Cutting a release

`guild:release`. A release **records**; it does not retire. Every expectation here follows from
that one sentence: the only board write is a single `guild_state` row, and if anything else on
the board moved, the release did something it was not asked to.

### Trigger

`guild:release` — "cut a release", "ship it", "tag a version". `--dry-run` runs steps 1–5 and
writes nothing.

### Preconditions

```sql
-- P9.a  what is in scope — expect AT LEAST ONE row, else stop
SELECT r.id, replace(replace(r.title, char(10),' '), '|','!') AS title
  FROM requirement r
 WHERE r.status = 'done'
   AND NOT EXISTS (SELECT 1 FROM guild_state gs, json_each(gs.value, '$.requirements') j
                    WHERE gs.key LIKE 'release:%' AND json_valid(gs.value) AND j.value = r.id)
 ORDER BY r.id;

-- P9.b  the version is not already cut — expect ZERO ROWS
SELECT key FROM guild_state WHERE key = 'release:v1.2.0';
```

*Verified* against a board where `REQ-001` has been carried all the way through
`gate-repairs` → repairs → `done`: P9.a returns
`REQ-001|Harden the session cookie: set secure = true; and rotate the signing key on deploy` —
note the title flattened in SQL, before it leaves the engine, because a newline in a title would
otherwise forge a changelog bullet or a heading. After the release is recorded, P9.a returns
**nothing**, which is what makes "what has already shipped" a query rather than a directory scan.

`git rev-parse --is-inside-work-tree`, `git status --short` and `git tag --list` are the other
three preconditions and they are shell, not SQL.

### Expected sequence

1. Preconditions (git + guild).
2. Scope — P9.a, or exactly the `--only` ids, each verified `done`.
3. The pre-release gate: **warn, never block**, and distinguish a waived failure from a bare one.
4. The version: validated, not already tagged, not already on the board.
5. `CHANGELOG.md` at **repo root**, `[Unreleased]` → `[{version}] - {today}`.
6. Render the snapshot: structure written by the shell from ids and enum words, free text
   appended as a whole block by a single-column query and **never** interpolated into a heading,
   a table cell or a filename.
7. **One** board write: the `release:<version>` upsert.
8. Commit and tag. No push, no `--no-verify`.

### Postconditions

**§9.a — the release touched nothing but `guild_state`.** Fingerprint before and after:

```sql
-- relfp.sql
SELECT 'requirement'    AS part, COUNT(*) || '/' || COALESCE(SUM(length(id)+length(status)),0) AS v FROM requirement
UNION ALL SELECT 'task',           COUNT(*) || '/' || COALESCE(SUM(length(id)+length(status)),0) FROM task
UNION ALL SELECT 'plan',           COUNT(*) FROM plan
UNION ALL SELECT 'plan_slice',     COUNT(*) FROM plan_slice
UNION ALL SELECT 'graph_node',     COUNT(*) || '/' || COALESCE(SUM(length(status)),0) FROM graph_node
UNION ALL SELECT 'gate',           COUNT(*) || '/' || COALESCE(SUM(length(status)),0) FROM gate
UNION ALL SELECT 'work_log',       COUNT(*) FROM work_log
UNION ALL SELECT 'review_finding', COUNT(*) || '/' || COALESCE(SUM(length(disposition)),0) FROM review_finding
UNION ALL SELECT 'bug',            COUNT(*) FROM bug
UNION ALL SELECT 'coverage',       COUNT(*) || '/' || COALESCE(SUM(length(id)+length(COALESCE(last_inspected_at,''))),0) FROM coverage
UNION ALL SELECT 'doc',            COUNT(*) FROM doc
UNION ALL SELECT 'agent',          COUNT(*) FROM agent
UNION ALL SELECT 'guild_state',    COUNT(*) FROM guild_state
UNION ALL SELECT 'release-keys',   COUNT(*) FROM guild_state WHERE key LIKE 'release:%'
ORDER BY part;
```

Expect **exactly two differing lines**, and they must be these two:

```
7c7
< guild_state|3
---
> guild_state|4
10c10
< release-keys|0
---
> release-keys|1
```

*Verified* — that is the transcript. `requirement`, `task`, `graph_node`, `gate`, `work_log`,
`review_finding`, `bug`, `coverage`, `doc` and `agent` are all byte-identical across the release.
A third differing line means a release restatused, snapshotted-and-deleted, or "tidied" something.

Under `--dry-run` the correct diff is **empty**. Steps 2, 3 and 4 are reads and are safe; step 7's
upsert is not and must not run.

**§9.b — the release record is well-formed and honest.** Expect **zero rows**:

```sql
SELECT 'release-value-not-json' AS breach, gs.key AS row_id, gs.value AS detail
  FROM guild_state gs WHERE gs.key LIKE 'release:%' AND NOT json_valid(gs.value)
UNION ALL
SELECT 'release-missing-field', gs.key,
       CASE WHEN json_extract(gs.value,'$.released') IS NULL THEN 'released' ELSE 'requirements' END
  FROM guild_state gs WHERE gs.key LIKE 'release:%' AND json_valid(gs.value)
   AND (json_extract(gs.value,'$.released') IS NULL
        OR json_type(gs.value,'$.requirements') <> 'array')
UNION ALL
SELECT 'release-empty', gs.key, '0'
  FROM guild_state gs WHERE gs.key LIKE 'release:%' AND json_valid(gs.value)
   AND json_array_length(json_extract(gs.value,'$.requirements')) = 0
UNION ALL
SELECT 'released-requirement-not-done', j.value,
       COALESCE((SELECT r.status FROM requirement r WHERE r.id = j.value),'(missing)')
  FROM guild_state gs, json_each(gs.value,'$.requirements') j
 WHERE gs.key LIKE 'release:%' AND json_valid(gs.value)
   AND COALESCE((SELECT r.status FROM requirement r WHERE r.id = j.value),'(missing)') <> 'done'
UNION ALL
SELECT 'requirement-released-twice', j.value, CAST(COUNT(*) AS TEXT)
  FROM guild_state gs, json_each(gs.value,'$.requirements') j
 WHERE gs.key LIKE 'release:%' AND json_valid(gs.value)
 GROUP BY j.value HAVING COUNT(*) > 1
UNION ALL
-- ADVISORY, not a failure: the pre-release gate warns, it does not block
SELECT 'released-over-open-task', p.id,
       'open=' || p.tasks_open || ' blocked=' || p.tasks_blocked || ' failed=' || p.tasks_failed
  FROM v_requirement_progress p
 WHERE (p.tasks_open > 0 OR p.tasks_failed > 0)
   AND EXISTS (SELECT 1 FROM guild_state gs, json_each(gs.value,'$.requirements') j
                WHERE gs.key LIKE 'release:%' AND json_valid(gs.value) AND j.value = p.id)
ORDER BY breach, row_id;
```

`guild_state.value` for a `release:` key must therefore be
`{"released":"YYYY-MM-DD","requirements":["REQ-NNN",…]}`. Nothing in the schema enforces that
shape; these clauses are what make it a contract, and the `json_valid` guards keep them inert
rather than raising against a value written as prose — which is itself the first clause.

*Verified to fire,* one injection each:

| clause | injected | returned |
|---|---|---|
| `release-value-not-json` | `value = 'shipped it'` | `release-value-not-json \| release:v1.3.0 \| shipped it` |
| `release-missing-field` | no `released` key | `release-missing-field \| release:v1.3.0 \| released` |
| `released-requirement-not-done` | `requirements: ["REQ-404"]` | `released-requirement-not-done \| REQ-404 \| (missing)` |
| `requirement-released-twice` | `REQ-001` in two release keys | `requirement-released-twice \| REQ-001 \| 2` |
| `released-over-open-task` | one new `todo` ticket on `REQ-001` | `released-over-open-task \| REQ-001 \| open=1 blocked=0 failed=0` |
| — | `UPDATE requirement SET status='todo'` after release | `released-requirement-not-done \| REQ-001 \| todo` |

The last row is the one that makes §9.a's fingerprint redundant for its most likely failure: a
release that restatused a requirement is caught twice, from two directions.

**§9.c — the advisory clause is a report, not a stop.** `released-over-open-task` fires on a
legitimate board — the pre-release gate *warns* and the guild master may say yes. Wire it to
print rather than to exit non-zero, and read it: `blocked=1` in that row means the release shipped
a slice nobody on the roster could take, and that is the loud case the skill spells out by name.

### Anti-expectations

| Must not be true | Caught by |
|---|---|
| A requirement's status changed by the release | §9.a, §9.b `released-requirement-not-done` |
| Any row deleted | §9.a — every count is in the fingerprint |
| `coverage` or `doc` snapshotted, moved or touched | §9.a — both lines byte-identical |
| The same requirement released twice | §9.b `requirement-released-twice` |
| A version cut twice | P9.b |
| A `--dry-run` that wrote the board row | §9.a — the diff must be empty |
| A raw title interpolated into a CHANGELOG heading | flattened in SQL; not assertable afterwards |
| The tag pushed, or hooks skipped | not assertable from the board |
| The standing QA umbrella released | P9.a excludes it — it is `in-progress` forever by design |

### Cannot be asserted

- **The snapshot's contents.** `.guild/releases/{version}/REQ-NNN.md` is a file. That it contains
  the requirement's real body — rather than a truncated one from `-m pretty`, or a tursodb error
  message that landed on stdout and was appended as content — is checkable only by reading it.
  The skill's rule to check every query's exit code is the guard, and nothing enforces it.
- **Whether `CHANGELOG.md` was transformed correctly.** Repo root, not `.guild/`; a real
  `[Unreleased]` section; the bullets moved rather than duplicated. All file state.
- **Whether the git tag matches the board record.** Two systems, one convention. A tag `v1.2.0`
  with a board key `release:v1.2.1` passes every query here.
- **Whether the release is a good place to cut one.** The pre-release gate warns and does not
  block, by design. `released-over-open-task` reports; the judgment stays with the user.

---

## 10. `guild-status` — the deprecated alias

A one-line section, because it is a one-line skill: it exists only to keep the typed
`/guild:guild-status` working and must delegate to `guild:brief`.

### Trigger

The literal slash command `/guild:guild-status`, typed. **Nothing else.**

### Preconditions

None beyond §5's.

### Expected sequence

1. Load `guild:brief` and follow it. Do not re-implement, and do not substitute
   `SELECT * FROM v_board` — the board view is correct and is *part* of what the brief reads, but
   on its own it shows tasks only.
2. Mention the new name once, in passing.

### Postconditions

**§10.a — everything in §5 applies unchanged.** The fingerprint (§5.a) and the roll call (§5.b)
are the postconditions of this skill, because its output is the brief's output.

**§10.b — it claims no natural-language trigger phrases.** Two skills advertising "guild status"
makes every status request a coin flip. Mechanically checkable against the frontmatter:

```bash
comm -12 \
  <(awk '/^---$/{n++;next} n==1' skills/brief/SKILL.md        | grep -oE '"[^"]+"' | sort -u) \
  <(awk '/^---$/{n++;next} n==1' skills/guild-status/SKILL.md | grep -oE '"[^"]+"' | sort -u)
```

Expect **no output**. **This assertion currently FIRES:**

```
"board status"
"guild status"
"project status"
"what's happening"
```

The four phrases appear in `guild-status`'s own description — inside the sentence that *disclaims*
them: *"It claims NO natural-language trigger phrases; 'guild status', 'board status', ... belong
to guild:brief and must route there."* A human reads that as a disclaimer. A router matching on
the description string reads it as four claimed phrases, which is exactly the coin flip the
rename was meant to end. The fix is to name the phrases without quoting them, or to drop the
enumeration entirely and say only *"this skill claims no trigger phrases; every status phrasing
belongs to `guild:brief`."*

### Anti-expectations

| Must not be true | Caught by |
|---|---|
| It narrates the board itself instead of delegating | not assertable |
| It substitutes `v_board` for the brief | not assertable |
| It writes anything | §5.a |
| It advertises a phrase `guild:brief` also advertises | §10.b — **currently fires, 4 phrases** |

### Cannot be asserted

- **Whether the skill delegated or re-implemented.** Both produce a briefing. Only the second
  produces a *different* briefing, and §5.b would catch that only if the difference happened to
  be an omission.
- **Which skill the router actually picked** for a given user phrase. §10.b measures the
  collision in the descriptions, which is the cause; the effect is a runtime coin flip nothing
  here observes.

---

## 11. The maintenance cycle

The `maintenance` template, end to end: `qa-check` → `qa-plan` → `qa-execute` → `qa-report` →
`gate-repairs` → `repair`. Six nodes, five edges, **one** gate — invariant, whatever the
inspection covers, because nothing here fans out per slice.

### Trigger

`guild:qa` — the user asks for one ("QA the checkout flow", "run a QA pass"). **That is the only
trigger there is.** No auto-start on requirement-done, no cadence, and no shift may start one
(§6). A full inspection runs the real product one browser at a time, so the expense is
authorized by a person or it is not incurred.

The cycle hangs off a **carrier requirement** — `graph_node.requirement_id` is
`NOT NULL REFERENCES requirement(id)` and an inspection has no id of its own to key a graph by.
Prefer a fresh unaffiliated carrier (`phase_id` NULL) over a feature requirement, which would
otherwise carry two graphs and one ambiguous `graph-template:` key.

### Preconditions

```sql
-- P11.a  the schema is current — expect exactly one row, version 5
SELECT version FROM schema_version WHERE id = 1;

-- P11.b  the carrier has no graph already — expect ZERO ROWS, in its own round trip
SELECT id FROM graph_node WHERE requirement_id = 'REQ-NNN';

-- P11.c  the cycle is worth starting and can be staffed — expect ZERO ROWS
SELECT 'no-area-is-due' AS breach, 'coverage' AS row_id, CAST((SELECT COUNT(*) FROM coverage) AS TEXT) AS detail
 WHERE NOT EXISTS (SELECT 1 FROM v_coverage_due)
UNION ALL
SELECT 'no-member-can-plan', 'qa-planning', '' WHERE NOT EXISTS
  (SELECT 1 FROM agent_capability ac JOIN agent a ON a.name = ac.agent
    WHERE a.active = 1 AND ac.capability = 'qa-planning')
UNION ALL
SELECT 'no-member-can-execute', 'qa-execution', '' WHERE NOT EXISTS
  (SELECT 1 FROM agent_capability ac JOIN agent a ON a.name = ac.agent
    WHERE a.active = 1 AND ac.capability = 'qa-execution')
UNION ALL
SELECT 'the-executor-is-not-serial', a.name, CAST(a.serial AS TEXT) FROM agent a
  JOIN agent_capability ac ON ac.agent = a.name AND ac.capability = 'qa-execution'
 WHERE a.active = 1 AND a.serial <> 1
UNION ALL
SELECT 'a-tester-is-already-running', n.id, n.status FROM graph_node n
 WHERE n.node_key = 'qa-execute' AND n.status = 'running'
UNION ALL
SELECT 'a-tester-already-holds-a-ticket', t.id, COALESCE(t.claimed_by,'') FROM task t
 WHERE t.claimed_by IN (SELECT name FROM agent WHERE serial = 1) AND t.status = 'in-progress'
ORDER BY breach, row_id;
```

**`no-area-is-due` is a precondition, not a failure.** It says the cycle should end at `qa-check`
having cost nothing (§11.b), not that something is wrong. The other five are failures: a cycle
that cannot be staffed, or a second one starting on top of a tester that is already driving a
browser.

*Verified:* zero rows on a cold `maintenance` carrier. On the `maintenance` fixture — where
`INSP-001` is live — it returns `a-tester-already-holds-a-ticket | TASK-903 | qa-tester` and
`a-tester-is-already-running | REQ-900/qa-execute | running`, which is exactly the refusal
wanted: **do not start a second cycle while one is under way.**

### Expected sequence

1. **Create or choose the carrier requirement.** Unaffiliated, titled so nobody mistakes it for
   feature work. Never a requirement that already has a graph.
2. **Instantiate the graph** — 6 nodes, 5 edges, 1 `select-findings` gate row, and the
   `guild_state` key `graph-template:REQ-NNN` = `maintenance`. `qa-execute.parallel_group` is
   **NULL and stays NULL**.
3. **`qa-check`** reads `v_coverage_due`. It does not re-derive the interval policy by hand; the
   view is the one definition of "due" and its thresholds are 14 / 30 / 90 days by risk.
4. **If nothing is due, end here** — `qa-check` `done`, everything downstream `skipped`, the
   gate `approved` with a decision saying so (§11.b). Do not delete the nodes: an inspection that
   correctly decided to do nothing is a record worth keeping, and deleting it reads as a drop.
5. **`qa-plan`** writes the `inspection` row and its `inspection_coverage` rows, one per area in
   scope, `verdict` NULL. Each mission becomes a ticket under the `qa-execute` anchor.
6. **`qa-execute`** dispatches those tickets **one at a time**. Run the guard in §11.c *before
   every dispatch*, board-wide — two inspections on two carriers still share one machine and one
   set of ports. The anchor moves `done` once, when the last mission returns.
7. **`qa-report`** compiles observations into `bug` rows with a severity from the vocabulary,
   sets every reached area's `verdict`, stamps `coverage.last_inspected_at`, and closes the
   `inspection` row. **The stamp is what closes the loop** — an inspection that runs without it
   will be re-run immediately by the next `qa-check`, forever.
8. **`gate-repairs`** — the same gate, the same `select-findings` kind, the same multi-select
   presentation as the build flow. Two writes on approval: the `gate` row, then the node.
9. **`repair`**, fanned out from `gate.decision` into fix tickets.

Ordering that is load-bearing: the `inspection` row exists before any verdict points at it; the
verdict is recorded before the stamp; the stamp happens before the inspection is closed.

### Postconditions

**§11.a — the trigger was a person.** Expect **zero rows**:

```sql
SELECT 'inspection-not-manual' AS breach, i.id AS row_id, i."trigger" AS detail
  FROM inspection i WHERE i."trigger" <> 'manual'
UNION ALL
SELECT 'inspection-without-maintenance-carrier', i.id, 'no graph-template:… = maintenance' FROM inspection i
 WHERE NOT EXISTS (SELECT 1 FROM guild_state s WHERE s.key LIKE 'graph-template:%' AND s.value = 'maintenance')
UNION ALL
SELECT 'inspection-before-qa-check', i.id, i.status FROM inspection i
 WHERE NOT EXISTS (SELECT 1 FROM graph_node n
                    WHERE n.node_key = 'qa-check' AND n.status IN ('done','skipped')
                      AND (SELECT value FROM guild_state
                            WHERE key = 'graph-template:' || n.requirement_id) = 'maintenance')
UNION ALL
SELECT 'maintenance-carrier-has-a-plan', p.requirement_id, p.id FROM plan p
 WHERE (SELECT value FROM guild_state WHERE key = 'graph-template:' || p.requirement_id) = 'maintenance'
ORDER BY breach, row_id;
```

`inspection."trigger"` is the one open enum in the schema — no CHECK, deliberately, so a cadence
can be added later without rebuilding the table. **These two clauses are therefore the only
things in the system that hold "manual only" at all.** `inspection-before-qa-check` is the
sharper of the two: an `inspection` row that exists while no `qa-check` anywhere has finished is
an inspection nobody decided was due.

*Verified to fire:* setting `"trigger" = 'cron'` and reverting `qa-check` to `pending` on the
`maintenance` fixture returns `inspection-before-qa-check | INSP-001 | in-progress` and
`inspection-not-manual | INSP-001 | cron`.

**§11.b — the cheap exit is a complete exit.** When `qa-check` finds nothing due, the graph closes
out cleanly rather than leaving a `repair` node nothing will ever release. Expect **zero rows**:

```sql
SELECT 'early-end-left-work-open' AS breach, n.id AS row_id, n.status AS detail
  FROM graph_node n
 WHERE n.requirement_id IN (SELECT requirement_id FROM graph_node WHERE node_key = 'qa-plan' AND status = 'skipped')
   AND n.status NOT IN ('done','skipped')
UNION ALL
SELECT 'early-end-with-mission-ticket', t.id, t.status FROM task t
 WHERE t.node_key = 'qa-execute'
   AND t.requirement_id IN (SELECT requirement_id FROM graph_node WHERE node_key = 'qa-plan' AND status = 'skipped')
UNION ALL
SELECT 'early-end-gate-left-pending', g.node_id, g.status FROM gate g JOIN graph_node n ON n.id = g.node_id
 WHERE n.node_key = 'gate-repairs' AND g.status = 'pending'
   AND n.requirement_id IN (SELECT requirement_id FROM graph_node WHERE node_key = 'qa-plan' AND status = 'skipped')
UNION ALL
SELECT 'inspection-running-nothing-due', i.id, 'v_coverage_due is empty'
  FROM inspection i WHERE i.status = 'in-progress' AND NOT EXISTS (SELECT 1 FROM v_coverage_due)
ORDER BY breach, row_id;
```

`v_coverage_due` is read, never re-derived: it is the schema's one definition of the interval
policy, and a hand-written `datetime('now','-14 days')` beside it is a second one.

*Verified:* zero rows on the `maintenance` fixture (an inspection legitimately under way, two
areas due) **and** zero rows on the same fixture after `maintenance.md` §7.5's early-exit script. Leaving `repair`
`pending`, the gate undecided and one mission ticket behind returns all three of
`early-end-gate-left-pending`, `early-end-left-work-open | REQ-900/repair | pending` and
`early-end-with-mission-ticket`. Making every area fresh while `INSP-001` is still running
returns `inspection-running-nothing-due | INSP-001 | v_coverage_due is empty`.

**§11.c — one tester, board-wide.** This is the invariant the whole template is shaped around, so
it is asserted directly rather than left to `agent.serial`. **G9 catches the ticket half from the
roster's side; these are the node-side and mission-side halves it does not see.** Expect **zero
rows**:

```sql
SELECT 'two-qa-execute-running' AS breach, n.id AS row_id, n.requirement_id AS detail
  FROM graph_node n
 WHERE n.node_key = 'qa-execute' AND n.status = 'running'
   AND (SELECT COUNT(*) FROM graph_node m WHERE m.node_key = 'qa-execute' AND m.status = 'running') > 1
UNION ALL
SELECT 'two-mission-tickets-in-flight', t.id, t.requirement_id FROM task t
 WHERE t.node_key = 'qa-execute' AND t.status = 'in-progress'
   AND (SELECT COUNT(*) FROM task u WHERE u.node_key = 'qa-execute' AND u.status = 'in-progress') > 1
UNION ALL
SELECT 'qa-execute-has-parallel-group', n.id, n.parallel_group FROM graph_node n
 WHERE n.node_key = 'qa-execute' AND n.parallel_group IS NOT NULL
UNION ALL
SELECT 'mission-ticket-has-parallel-group', t.id, t.parallel_group FROM task t
 WHERE t.node_key = 'qa-execute' AND COALESCE(t.parallel_group,'') <> ''
UNION ALL
SELECT 'qa-execute-running-node-unbound', n.id, 'task_id IS NULL' FROM graph_node n
 WHERE n.node_key = 'qa-execute' AND n.status = 'running' AND n.task_id IS NULL
UNION ALL
SELECT 'mission-ticket-not-with-the-serial-member', t.id, COALESCE(t.claimed_by,'(null)') FROM task t
 WHERE t.node_key = 'qa-execute' AND t.status = 'in-progress'
   AND NOT EXISTS (SELECT 1 FROM agent a WHERE a.name = t.claimed_by AND a.serial = 1)
ORDER BY breach, row_id;
```

**No clause here is scoped to a requirement, and that is the point.** Two inspections on two
carriers still share one machine. A `parallel_group` on a `qa-execute` node is not a deviation
an architect may justify — it is a defect, which is why it is asserted as an absolute rather than
excused by a `graph_deviation` row the way an added node would be.

*Verified to fire:* claiming `TASK-904` alongside `TASK-903` returns two
`two-mission-tickets-in-flight` rows; setting `parallel_group = 'qa'` returns
`qa-execute-has-parallel-group | REQ-900/qa-execute | qa`. A second carrier `REQ-901` with its
own `qa-execute` running returns `two-qa-execute-running` for **both** nodes plus
`qa-execute-running-node-unbound | REQ-901/qa-execute`.

**§11.d — the report was compiled and the stamp was made.** Expect **zero rows**:

```sql
SELECT 'qa-report-done-inspection-still-open' AS breach, i.id AS row_id, i.status AS detail
  FROM inspection i
 WHERE i.status <> 'done'
   AND EXISTS (SELECT 1 FROM graph_node n WHERE n.node_key = 'qa-report' AND n.status = 'done'
                 AND (SELECT value FROM guild_state
                       WHERE key = 'graph-template:' || n.requirement_id) = 'maintenance')
UNION ALL
SELECT 'reached-area-not-stamped', ic.inspection_id || '/' || ic.coverage_id, COALESCE(c.last_inspected_at,'(never)')
  FROM inspection_coverage ic JOIN inspection i ON i.id = ic.inspection_id
  JOIN coverage c ON c.id = ic.coverage_id
 WHERE i.status = 'done' AND ic.verdict IN ('pass','issues')
   AND COALESCE(c.last_inspected_at,'') < COALESCE(i.started_at,'')
UNION ALL
SELECT 'inspection-done-with-unreported-area', ic.inspection_id || '/' || ic.coverage_id, 'verdict IS NULL'
  FROM inspection_coverage ic JOIN inspection i ON i.id = ic.inspection_id
 WHERE i.status = 'done' AND ic.verdict IS NULL
UNION ALL
SELECT 'issues-found-but-no-bug-filed', n.requirement_id, 'qa-report done, 0 bugs'
  FROM graph_node n
 WHERE n.node_key = 'qa-report' AND n.status = 'done'
   AND (SELECT value FROM guild_state WHERE key = 'graph-template:' || n.requirement_id) = 'maintenance'
   AND EXISTS (SELECT 1 FROM inspection_coverage ic WHERE ic.verdict = 'issues')
   AND NOT EXISTS (SELECT 1 FROM bug b WHERE b.requirement_id = n.requirement_id)
UNION ALL
SELECT 'bug-found-by-non-member', b.id, b.found_by FROM bug b
 WHERE COALESCE(b.found_by,'') <> '' AND NOT EXISTS (SELECT 1 FROM agent a WHERE a.name = b.found_by)
UNION ALL
SELECT 'inspection-done-no-finished-at', i.id, '(null)' FROM inspection i
 WHERE i.status = 'done' AND COALESCE(i.finished_at,'') = ''
ORDER BY breach, row_id;
```

Severity vocabulary is **not** re-checked here — G2 already asserts `bug.severity ∈ (critical,
major, minor)` board-wide, and the engine's CHECK rejects an invented one at write time. What G2
cannot see is a bug that was never filed at all, which is what
`issues-found-but-no-bug-filed` is for.

`inspection-done-with-unreported-area` is the one that catches the honest-looking failure:
`verdict` NULL means *not yet reached*, `'not-reached'` means *intended and ran out of road*, and
they are not interchangeable. Closing an inspection with a NULL verdict leaves an area that a
summariser will render as inspected when nobody looked at it.

*Verified to fire:* moving `qa-report` to `done` with the bugs deleted returns
`issues-found-but-no-bug-filed | REQ-900 | qa-report done, 0 bugs` and
`qa-report-done-inspection-still-open | INSP-001 | in-progress`. Then closing `INSP-001` without
stamping adds `inspection-done-no-finished-at`, `inspection-done-with-unreported-area |
INSP-001/auth-session | verdict IS NULL` and `reached-area-not-stamped | INSP-001/checkout-flow`.

**§11.e — the shared tail, and this is the assertion that matters most in this section.** The
central simplification of the design is that QA does *not* get gates of its own: both templates
converge on one `gate-repairs` → `repair` tail with identical semantics. That claim is
checkable, so it is checked — **and this query is template-agnostic on purpose**, running over
every graph on the board whatever built it. Expect **zero rows**:

```sql
SELECT 'tail-missing-gate-repairs' AS breach, substr(s.key,16) AS row_id, s.value AS detail
  FROM guild_state s WHERE s.key LIKE 'graph-template:%'
   AND NOT EXISTS (SELECT 1 FROM graph_node n WHERE n.requirement_id = substr(s.key,16)
                    AND n.node_key = 'gate-repairs' AND n.kind = 'gate')
UNION ALL
SELECT 'tail-gate-not-select-findings', g.node_id, g.kind FROM gate g JOIN graph_node n ON n.id = g.node_id
 WHERE n.node_key = 'gate-repairs' AND g.kind <> 'select-findings'
UNION ALL
SELECT 'tail-gate-not-followed-by-repair', n.id, 'no edge to repair' FROM graph_node n
 WHERE n.node_key = 'gate-repairs'
   AND NOT EXISTS (SELECT 1 FROM graph_edge e JOIN graph_node r ON r.id = e.to_node
                    WHERE e.from_node = n.id AND r.node_key = 'repair')
UNION ALL
SELECT 'tail-repair-predecessor-not-the-gate', r.id, p.node_key
  FROM graph_node r JOIN graph_edge e ON e.to_node = r.id JOIN graph_node p ON p.id = e.from_node
 WHERE r.node_key = 'repair' AND p.node_key <> 'gate-repairs'
UNION ALL
SELECT 'tail-repair-not-terminal', r.id, e.to_node
  FROM graph_node r JOIN graph_edge e ON e.from_node = r.id WHERE r.node_key = 'repair'
UNION ALL
SELECT 'tail-repair-fanned-out', n.requirement_id, CAST(COUNT(*) AS TEXT) || ' repair nodes'
  FROM graph_node n WHERE n.node_key = 'repair' GROUP BY n.requirement_id HAVING COUNT(*) <> 1
ORDER BY breach, row_id;
```

`substr(s.key,16)` recovers the requirement id — `'graph-template:'` is fifteen characters.

*Verified* against a board carrying **both** templates at once (`REQ-001` standard, `REQ-900`
maintenance): zero rows, and the two tails read identically —

```
REQ-001|standard   |gate-repairs|gate|select-findings|REQ-001/repair
REQ-001|standard   |repair      |work|-              |
REQ-900|maintenance|gate-repairs|gate|select-findings|REQ-900/repair
REQ-900|maintenance|repair      |work|-              |
```

*Verified to fire:* dropping `REQ-900`'s gate→repair edge and changing `REQ-001`'s gate kind to
`approve` returns `tail-gate-not-followed-by-repair | REQ-900/gate-repairs` and
`tail-gate-not-select-findings | REQ-001/gate-repairs | approve`.

**§11.f — the maintenance graph matches its template.** G4's `added-gate` / `dropped-gate` and
G8's `node-key-not-in-template` are both guarded by `= 'standard'` and **do not fire on a
maintenance graph at all.** These are their `maintenance` counterparts, and without them a
maintenance carrier is unchecked. Expect **zero rows**:

```sql
SELECT 'added-gate' AS breach, n.id AS row_id, n.node_key AS detail FROM graph_node n
 WHERE n.kind = 'gate' AND n.node_key <> 'gate-repairs'
   AND (SELECT value FROM guild_state WHERE key = 'graph-template:' || n.requirement_id) = 'maintenance'
UNION ALL
SELECT 'dropped-required-node', r.id, k.k
  FROM requirement r JOIN (SELECT 'qa-check' AS k UNION ALL SELECT 'qa-report'
                           UNION ALL SELECT 'gate-repairs') k
 WHERE (SELECT value FROM guild_state WHERE key = 'graph-template:' || r.id) = 'maintenance'
   AND NOT EXISTS (SELECT 1 FROM graph_node n WHERE n.requirement_id = r.id AND n.node_key = k.k)
UNION ALL
SELECT 'dropped-optional-node-no-deviation', r.id, k.k
  FROM requirement r JOIN (SELECT 'qa-plan' AS k UNION ALL SELECT 'qa-execute'
                           UNION ALL SELECT 'repair') k
 WHERE (SELECT value FROM guild_state WHERE key = 'graph-template:' || r.id) = 'maintenance'
   AND NOT EXISTS (SELECT 1 FROM graph_node n WHERE n.requirement_id = r.id AND n.node_key = k.k)
   AND NOT EXISTS (SELECT 1 FROM graph_deviation d WHERE d.requirement_id = r.id
                     AND d.kind = 'drop-node' AND d.node_key = k.k)
UNION ALL
SELECT 'node-key-not-in-template', n.id, n.node_key FROM graph_node n
 WHERE (SELECT value FROM guild_state WHERE key = 'graph-template:' || n.requirement_id) = 'maintenance'
   AND n.node_key NOT IN ('qa-check','qa-plan','qa-execute','qa-report','gate-repairs','repair')
   AND NOT EXISTS (SELECT 1 FROM graph_deviation d WHERE d.requirement_id = n.requirement_id
                     AND d.kind = 'add-node' AND d.node_key = n.node_key)
UNION ALL
SELECT 'node-count-not-six', r.id, CAST((SELECT COUNT(*) FROM graph_node n WHERE n.requirement_id = r.id) AS TEXT)
  FROM requirement r
 WHERE (SELECT value FROM guild_state WHERE key = 'graph-template:' || r.id) = 'maintenance'
   AND (SELECT COUNT(*) FROM graph_node n WHERE n.requirement_id = r.id) <> 6
   AND NOT EXISTS (SELECT 1 FROM graph_deviation d WHERE d.requirement_id = r.id)
UNION ALL
SELECT 'edge-count-not-five', r.id, CAST((SELECT COUNT(*) FROM graph_edge e
        JOIN graph_node n ON n.id = e.to_node WHERE n.requirement_id = r.id) AS TEXT)
  FROM requirement r
 WHERE (SELECT value FROM guild_state WHERE key = 'graph-template:' || r.id) = 'maintenance'
   AND (SELECT COUNT(*) FROM graph_edge e JOIN graph_node n ON n.id = e.to_node
         WHERE n.requirement_id = r.id) <> 5
   AND NOT EXISTS (SELECT 1 FROM graph_deviation d WHERE d.requirement_id = r.id)
UNION ALL
SELECT 'gate-count-not-one', r.id, CAST((SELECT COUNT(*) FROM graph_node n
        WHERE n.requirement_id = r.id AND n.kind = 'gate') AS TEXT)
  FROM requirement r
 WHERE (SELECT value FROM guild_state WHERE key = 'graph-template:' || r.id) = 'maintenance'
   AND (SELECT COUNT(*) FROM graph_node n WHERE n.requirement_id = r.id AND n.kind = 'gate') <> 1
ORDER BY breach, row_id;
```

`gate-count-not-one` is **not** excused by a deviation, unlike the node and edge counts: a gate
may be neither added nor dropped, whatever the reason, because an extra gate turns an overnight
inspection into a session that stops to ask a sleeping human. The counts a healthy carrier
reports:

```sql
SELECT (SELECT COUNT(*) FROM graph_node WHERE requirement_id = 'REQ-NNN')  AS nodes,
       (SELECT COUNT(*) FROM graph_edge WHERE to_node LIKE 'REQ-NNN/%')    AS edges,
       (SELECT COUNT(*) FROM graph_node
         WHERE requirement_id = 'REQ-NNN' AND kind = 'gate')               AS gates;
-- 6|5|1   — not 2 gates, that is `standard`
```

*Verified to fire:* adding a `gate-sign-off` gate node and dropping `qa-check` returns
`added-gate | REQ-900/gate-sign-off`, `dropped-required-node | REQ-900 | qa-check`,
`edge-count-not-five | REQ-900 | 4`, `gate-count-not-one | REQ-900 | 2` and
`node-key-not-in-template | REQ-900/gate-sign-off`. Note what did **not** fire:
`node-count-not-six`, because one node was added and one removed. Counts alone are not a
template check, which is why the key-level clauses are there too.

### Anti-expectations

Must be false after the cycle.

| Must not be true | Caught by |
|---|---|
| An inspection nobody asked for | §11.a `inspection-not-manual`, `inspection-before-qa-check` |
| An inspection started while a tester was already running | P11.c `a-tester-is-already-running` |
| Two testers at once, from either side | §11.c, G9 `serial-agent-double-booked` |
| A `parallel_group` on a `qa-execute` node or mission ticket | §11.c — a defect, not a deviation |
| A `qa-check` that found nothing but left the graph half-open | §11.b `early-end-left-work-open` |
| An inspection closed without stamping `last_inspected_at` | §11.d `reached-area-not-stamped` |
| An inspection closed with a NULL verdict passed off as inspected | §11.d `inspection-done-with-unreported-area` |
| A maintenance carrier that also carries a plan and feature tickets | §11.a `maintenance-carrier-has-a-plan` |
| A second gate on a maintenance graph | §11.f `added-gate`, `gate-count-not-one` |
| A maintenance graph advancing past its undecided gate | G4 `past-unresolved-gate` |
| A bug in `fixing` with no fix task | G6 `bug-fixing-without-task` |
| The carrier closed with the inspection still open | G6 `requirement-done-with-unfinished-node` |

### Cannot be asserted

- **Whether the tester actually drove the product.** A `pass` verdict, a stamped
  `last_inspected_at` and an e2e spec path are three columns. Nothing here opens a browser, and a
  member that writes all three without running anything produces a board that passes every
  assertion in this section. This is the single largest unasserted thing in the cycle.
- **Whether a mission was worth running,** whether the risk map is right, and whether the
  strategist's coverage areas are the areas that matter.
- **Whether the inspected areas were the due ones.** Deliberately not asserted: an inspection may
  legitimately cover an area that is *not* due — the `maintenance` fixture does exactly this,
  recording `not-reached` for `admin-panel`, which `v_coverage_due` never offered. An assertion
  that every inspected area was due would fire on a correct board.
- **Whether `spec_path` points at a spec that exists,** or at one that still passes. The column
  is a string; the repository is not visible to SQL.
- **Whether a filed bug is real,** whether its severity is right, and whether a `wontfix` was a
  judgement or an evasion.
- **That the trigger really was a person.** `inspection."trigger" = 'manual'` is a value the
  writer chose about itself. §11.a asserts the value and the ordering around it; it cannot
  reach the human.

---

## 12. The unattended shift

The highest-risk process in the guild: work runs with nobody watching, on somebody's working
tree, spending real money. **Run until the next gate, then stop and notify.** The segment
boundary and the stop boundary are the same line, which is what makes "how far may it go" a
question that needs no separate answer.

Its expectations matter more than any other section's, for a reason worth stating plainly: in v5
the CLI locked four of these doors in code — `guild node` refused a gate node, `guild git` had no
`push` verb. **That CLI is gone.** Nothing enforces any line of the MAY / MAY NOT table any more.
The assertions below are what remains, and they run *after* the night, not during it.

### The shift window

Six of the assertions below are scoped to one shift. They all open with the same clause:

```sql
WITH w(t0, t1) AS (
  SELECT substr((SELECT ts FROM event WHERE subject_type='shift' AND verb='started'
                  ORDER BY ts DESC, id DESC LIMIT 1), 1, 19),
         substr(COALESCE((SELECT ts FROM event WHERE subject_type='shift' AND verb='ended'
                           ORDER BY ts DESC, id DESC LIMIT 1),
                         strftime('%Y-%m-%dT%H:%M:%SZ','now')), 1, 19) || 'Z')
```

**`substr(…, 1, 19)` is not cosmetic and dropping it breaks the window.** The triggers write
`event.ts` with milliseconds (`%Y-%m-%dT%H:%M:%fZ`), the shift writes its own two rows with
seconds (`%SZ`). Compared as text, `'…:16.123Z'` sorts *before* `'…:16Z'` — `.` is 0x2E, `Z` is
0x5A — so a trigger event in the same second as the `started` row falls outside a naive
`e.ts >= start`. Truncating both sides to the second makes the two formats comparable, and
appending `'Z'` to the upper bound puts every millisecond of the closing second inside it.

An open shift has no `ended` row, so `t1` is `now`. That is correct and is what makes these
assertions runnable *during* a shift as well as after it.

### Trigger

`guild:shift` — "work a shift", "run overnight", "keep going without me". Also armed on a cadence
by `/loop 10m /guild:shift` or a scheduled agent, in which case each run is one shift.

### Preconditions

```sql
-- P12.a  is there a shift to work at all? — expect ZERO ROWS
SELECT 'a-gate-is-already-waiting' AS breach, node_id AS row_id, node_key AS detail FROM v_gates_pending
UNION ALL
SELECT 'a-shift-is-already-open', eo.subject_id, eo.ts FROM event eo
 WHERE eo.subject_type='shift' AND eo.verb='started'
   AND NOT EXISTS (SELECT 1 FROM event ec WHERE ec.subject_type='shift' AND ec.verb='ended'
                     AND ec.subject_id = eo.subject_id)
UNION ALL
SELECT 'no-candidate-has-ready-work', 'board', '0'
 WHERE NOT EXISTS (
   SELECT 1 FROM requirement r
    WHERE r.status <> 'done'
      AND (COALESCE((SELECT gs.value FROM guild_state gs
                      WHERE gs.key='graph-template:'||r.id),'') = 'standard'
           OR EXISTS (SELECT 1 FROM graph_node g WHERE g.requirement_id=r.id AND g.status <> 'pending'))
      AND EXISTS (SELECT 1 FROM v_ready_nodes n WHERE n.requirement_id=r.id AND n.kind='work'
                   AND NOT EXISTS (SELECT 1 FROM task tb WHERE tb.id=n.task_id
                                    AND tb.status IN ('blocked','failed'))))
ORDER BY breach, row_id;
```

Each row means something different and none of them is an error:

- **`a-gate-is-already-waiting`** — do not open a shift. It would end on its first turn and waste
  the night. Present the gate instead.
- **`a-shift-is-already-open`** — you are *resuming*. Use the budget in that row's payload; do not
  open a rival shift and do not re-ask the ceiling.
- **`no-candidate-has-ready-work`** — the shift would end `idle` immediately.

The tier clause is the one that keeps a shift out of an inspection: a `standard` graph may be
picked up cold, **anything else only if a node has already moved past `pending`.** The cautious
default for an unknown template is deliberate — the CLI cannot know whether a project template's
first step is cheap.

```bash
# P12.b  the tree is not somebody's work in progress. Expect NO OUTPUT.
git status --porcelain | grep -v '^?? \.guild/'
```

`git switch` *carries* uncommitted changes onto the branch it moves to. Anything dirty that the
shift did not create means stop with reason `operator` — do not stash, do not commit it, do not
tidy it up.

*Verified:* on `planned`, P12.a returns `a-gate-is-already-waiting | REQ-001/gate-plan | gate-plan`
**and** `no-candidate-has-ready-work` — a board with three dispatchable bounties and no shift to
work, exactly as intended. On `in-flight` it returns `no-candidate-has-ready-work`, because the
only live node is already `running` and a shift dispatches ready nodes rather than adopting
running ones. Releasing that barrier (`TASK-003` done, its node done) makes P12.a return **zero
rows** and `v_ready_nodes` offer `REQ-001/test-plan` — the first genuinely startable shift board.

### Expected sequence

1. **Preflight.** Read the three questions above, write nothing.
2. **Agree the budget**, once, before the first turn. Defaults 10 tasks / 60 minutes. It is fixed
   when the shift opens: a ceiling raisable from inside the loop is not a ceiling.
3. **Open the shift** — one hand-written `event` row, `verb = 'started'`, `subject_type='shift'`,
   payload carrying `max_tasks`, `max_minutes` and `requirement`. Guarded by
   `WHERE NOT EXISTS (…an open shift…)` so a second invocation resumes instead. Seed
   `guild_state['shift:used']` and `['shift:stall']`.
4. **Branch, once per requirement** — `guild/REQ-NNN`, created if absent. Never the default
   branch.
5. **One turn = pick a requirement → run one batch → record → re-evaluate the stop reason.** Read
   `v_ready_nodes` for the batch; never widen it, never merge two, never queue a segment blind.
6. **Record both halves, in order**: the ticket, then the node. A node left `running` stalls
   everything behind it and at 3am nobody notices.
7. **Commit per completed task**, staging that task's declared slice files, with `Guild-Task:` in
   the trailer. Nothing is committed for a failed task; its partial edits are quarantined into
   `.guild/backup-revert-<TASK>-<ts>/` before the next bounty starts.
8. **On failure**: retry once with a fresh agent instance — the marker is a `work_log` line
   beginning `Shift retry` — then give up, leaving the node `failed` and its ticket `failed`, and
   continue with the requirement's other independent work.
9. **On no eligible agent**: mark the ticket `blocked` and file a `capability_request`. Never
   improvise a member.
10. **At the end of every turn**, recompute the stop reason and write `shift:used` / `shift:stall`
    back — *including on the turns where nothing changed*, or the stall counter never decrements.
11. **Stop on the first condition, in precedence order,** and write the `ended` event naming why.
12. **At a gate: present and stop. Never decide.**

Ordering that is load-bearing: the `started` event before any work (every window assertion is
measured from it); the ticket before the node; the quarantine before the next bounty; the `ended`
event as the last write of the shift.

### Postconditions

**§12.a — it stopped at a gate and never past one.** The single most important assertion in this
document. Expect **zero rows**:

```sql
WITH w(t0, t1) AS ( /* the shift window, above */ )
SELECT 'gate-decided-during-shift' AS breach, e.subject_id AS row_id, e.ts || ' ' || e.actor AS detail
  FROM event e, w WHERE e.subject_type='gate' AND e.verb='decided' AND e.ts >= w.t0 AND e.ts <= w.t1
UNION ALL
SELECT 'gate-approved-with-no-shift-boundary', g.node_id, g.status || ' at ' || COALESCE(g.decided_at,'(null)')
  FROM gate g, w WHERE g.status <> 'pending'
   AND substr(COALESCE(g.decided_at,''),1,19) >= w.t0
   AND substr(COALESCE(g.decided_at,''),1,19) <= substr(w.t1,1,19)
UNION ALL
SELECT 'work-past-unresolved-gate', n.id, g.node_id
  FROM graph_node n
  JOIN graph_edge e ON e.to_node = n.id
  JOIN graph_node p ON p.id = e.from_node AND p.kind = 'gate'
  JOIN gate g ON g.node_id = p.id
 WHERE n.status IN ('running','done','failed') AND g.status = 'pending'
UNION ALL
SELECT 'node-moved-past-pending-gate-during-shift', e.subject_id, e.ts
  FROM event e, w
  JOIN graph_node n ON n.id = e.subject_id
 WHERE e.subject_type='graph_node' AND e.verb='node-moved' AND e.ts >= w.t0 AND e.ts <= w.t1
   AND EXISTS (SELECT 1 FROM graph_edge ge JOIN gate g2 ON g2.node_id = ge.from_node
                WHERE ge.to_node = n.id AND g2.status = 'pending')
ORDER BY breach, row_id;
```

Two clauses come at the same rule from opposite directions, and both are needed.
`gate-decided-during-shift` reads the trigger's event, which records **when the write happened**
and cannot be back-dated. `gate-approved-with-no-shift-boundary` reads `gate.decided_at`, which
records **what the writer claimed**. A member that decides a gate and sets `decided_at` to
yesterday is caught by the first; one that writes `decided_at` honestly is caught by both.
`work-past-unresolved-gate` is time-free and holds forever, which is why it is the one to keep if
you keep only one.

*Verified to fire:* on an open shift, approving `gate-repairs` and moving `repair` to `running`
returns `gate-approved-with-no-shift-boundary | REQ-001/gate-repairs` and
`gate-decided-during-shift | REQ-001/gate-repairs | … orchestrator`. Reverting the gate to
`pending` afterwards — leaving the work where it stands — adds
`node-moved-past-pending-gate-during-shift | REQ-001/repair` and
`work-past-unresolved-gate | REQ-001/repair | REQ-001/gate-repairs`.

**Read the window clauses with their limit in mind.** They compare real timestamps, so they are
meaningful on a board whose history accumulated over hours and meaningless on one seeded in a
single second — a fixture loaded inside the window makes every `decided` event in it look like
the shift's work. Open the shift *after* the board exists, which is what a real run does anyway.

**§12.b — what it never touched.** Expect **zero rows**:

```sql
WITH w(t0, t1) AS ( /* the shift window, above */ )
SELECT 'shift-started-an-inspection' AS breach, e.subject_id AS row_id, e.ts AS detail
  FROM event e, w
 WHERE e.subject_type='graph_node' AND e.verb='node-moved'
   AND json_extract(e.payload,'$.node_key') = 'qa-check'
   AND json_extract(e.payload,'$.from') = 'pending'
   AND e.ts >= w.t0 AND e.ts <= w.t1
UNION ALL
SELECT 'shift-opened-an-inspection-row', i.id, i.started_at
  FROM inspection i, w
 WHERE substr(COALESCE(i.started_at,''),1,19) >= w.t0
   AND substr(COALESCE(i.started_at,''),1,19) <= substr(w.t1,1,19)
UNION ALL
SELECT 'shift-declared-a-coverage-area', e.subject_id, e.ts
  FROM event e, w
 WHERE e.subject_type='coverage' AND e.verb='created' AND e.ts >= w.t0 AND e.ts <= w.t1
UNION ALL
SELECT 'shift-recruited-or-retired-a-member', e.subject_id, e.verb || ' at ' || e.ts
  FROM event e, w
 WHERE e.subject_type='agent' AND e.verb IN ('recruited','retired') AND e.ts >= w.t0 AND e.ts <= w.t1
UNION ALL
SELECT 'shift-touched-the-direction', e.subject_type || ':' || e.subject_id, e.verb || ' at ' || e.ts
  FROM event e, w
 WHERE e.subject_type IN ('goal','phase') AND e.ts >= w.t0 AND e.ts <= w.t1
UNION ALL
SELECT 'shift-filed-a-capability-request-and-created-the-member', q.capability, q.proposed_agent
  FROM capability_request q
 WHERE q.status = 'open' AND EXISTS (SELECT 1 FROM agent a WHERE a.name = q.proposed_agent)
ORDER BY breach, row_id;
```

`qa-check` moving off `pending` **is** an inspection starting — it is the entry node of the
`maintenance` graph, so the one event says the whole thing. A shift may *continue* an inspection
freely: every node from `qa-check` through `qa-report` only observes and records, and nothing
before the gate touches production code. So `qa-plan`, `qa-execute` and `qa-report` moving inside
the window are all legal, and only the first move of the first node is not.

The last clause is a shape rather than a window: a `capability_request` still `open` whose
`proposed_agent` already exists on the roster means somebody filed the gap *and then filled it
themselves*, which is the exact thing `v5-design.md` §5.4's last line forbids.

*Verified:* zero rows on a cold `maintenance` carrier with an open shift over it. Moving
`qa-check` to `done`, inserting an `inspection` row and creating `developer-embedded` returns
`shift-started-an-inspection | REQ-900/qa-check`, `shift-opened-an-inspection-row | INSP-009` and
`shift-recruited-or-retired-a-member | developer-embedded | recruited at …`. Closing `GOAL-001`
and `PHASE-001` mid-shift returns `shift-touched-the-direction` for both.

**§12.c — the failure policy was followed and the shift did not deadlock.** Expect **zero rows**:

```sql
WITH w(t0, t1) AS ( /* the shift window, above */ )
SELECT 'retried-more-than-once' AS breach, l.task_id AS row_id, CAST(COUNT(*) AS TEXT) || ' retries' AS detail
  FROM work_log l, w
 WHERE l.entry LIKE 'Shift retry%' AND l.ts >= w.t0 AND l.ts <= w.t1
 GROUP BY l.task_id HAVING COUNT(*) > 1
UNION ALL
SELECT 'given-up-without-a-retry', t.id, t.status
  FROM task t, w
 WHERE t.status = 'failed'
   AND substr(t.updated_at,1,19) >= w.t0 AND substr(t.updated_at,1,19) <= substr(w.t1,1,19)
   AND NOT EXISTS (SELECT 1 FROM work_log l WHERE l.task_id = t.id AND l.entry LIKE 'Shift retry%'
                     AND l.ts >= w.t0 AND l.ts <= w.t1)
UNION ALL
SELECT 'failed-ticket-with-no-reason-logged', t.id, ''
  FROM task t WHERE t.status = 'failed'
   AND NOT EXISTS (SELECT 1 FROM work_log l WHERE l.task_id = t.id AND l.entry NOT LIKE 'Shift retry%')
UNION ALL
SELECT 'failed-node-live-ticket', n.id, t.id || '=' || t.status
  FROM graph_node n JOIN task t ON t.id = n.task_id
 WHERE n.status = 'failed' AND t.status NOT IN ('failed','blocked')
UNION ALL
SELECT 'failed-ticket-live-node', t.id, n.id || '=' || n.status
  FROM task t JOIN graph_node n ON n.task_id = t.id
 WHERE t.status = 'failed' AND n.status NOT IN ('failed','skipped')
UNION ALL
SELECT 'retry-left-the-ticket-claimed', t.id, COALESCE(t.claimed_by,'')
  FROM task t WHERE t.status = 'todo' AND COALESCE(t.claimed_by,'') <> ''
UNION ALL
SELECT 'shift-deadlocked-with-work-available', 'shift', json_extract(e.payload,'$.reason')
  FROM event e, w
 WHERE e.subject_type='shift' AND e.verb='ended'
   AND json_extract(e.payload,'$.reason') = 'idle'
   AND EXISTS (SELECT 1 FROM v_ready_nodes n WHERE n.kind = 'work'
                AND NOT EXISTS (SELECT 1 FROM task tb WHERE tb.id = n.task_id
                                 AND tb.status IN ('blocked','failed')))
ORDER BY breach, row_id;
```

**"At most once" is counted from the log, not from a column**, and the marker is a prefix —
`Shift retry`, the same prefix-as-marker convention `Skipped by user` already uses. Scoping the
count to the window is what makes it reset on the next shift: a bounty that failed twice last
night deserves a fresh attempt tonight.

`failed-node-live-ticket` and `failed-ticket-live-node` are the same rule from both ends, and
they are here because **recording only one half is the most common way an unattended failure goes
wrong.** A failed node with a live ticket offers the ticket forever; a failed ticket under a live
node stalls everything behind it silently.

`shift-deadlocked-with-work-available` is the honest half of the failure policy: ending `idle`
while a dispatchable node exists means the shift stopped rather than moved on.

*Verified:* zero rows on a real shift that failed `TASK-005`, retried it once, and gave up.
A second `Shift retry` line inside an open shift returns
`retried-more-than-once | TASK-005 | 2 retries`. Putting the node back to `pending` while the
ticket stays `failed` returns `failed-ticket-live-node | TASK-005 | REQ-001/test-write=pending`.
Deleting the work log returns `failed-ticket-with-no-reason-logged` and
`given-up-without-a-retry | TASK-005 | failed`.

**§12.d — a blocked ticket became a roster gap, not a silent skip.** Expect **zero rows**:

```sql
SELECT 'uncoverable-ticket-left-todo' AS breach, t.id AS row_id, w.who AS detail
  FROM task t JOIN v_task_who w ON w.task_id = t.id
 WHERE t.status = 'todo' AND COALESCE(t.agent,'') = ''
   AND NOT EXISTS (SELECT 1 FROM v_agent_eligible e WHERE e.task_id = t.id)
   AND EXISTS (SELECT 1 FROM event WHERE subject_type = 'shift' AND verb = 'ended')
UNION ALL
SELECT 'blocked-ticket-invisible-as-a-gap', t.id, ''
  FROM task t WHERE t.status = 'blocked'
   AND NOT EXISTS (SELECT 1 FROM v_blocked_tasks b WHERE b.id = t.id)
UNION ALL
SELECT 'blocked-for-a-capability-nobody-requested', tc.task_id, tc.capability
  FROM task_capability tc JOIN task t ON t.id = tc.task_id
 WHERE t.status = 'blocked' AND tc.required = 1
   AND NOT EXISTS (SELECT 1 FROM agent_capability ac JOIN agent a ON a.name = ac.agent
                    WHERE a.active = 1 AND ac.capability = tc.capability)
   AND NOT EXISTS (SELECT 1 FROM capability_request q WHERE q.capability = tc.capability
                    AND q.status IN ('open','created'))
UNION ALL
SELECT 'blocked-but-coverable', t.id, m.agent
  FROM task t JOIN v_task_top_agent m ON m.task_id = t.id
 WHERE t.status = 'blocked' AND m.agent <> ''
ORDER BY breach, row_id;
```

`uncoverable-ticket-left-todo` is the assertion that names the failure this section exists to
catch: a ticket nobody can take, left `todo` after a shift ended. `todo` means available. It is
not available. The shift would select the same requirement next turn, emit the same directive and
spin all night — **marking it `blocked` is what makes the loop move on**, and `blocked` holding
the review gate is deliberate, because a roster gap should be loud.

`blocked-but-coverable` is the mirror: `blocked` means *nobody can take it*. If `v_task_top_agent`
names somebody, the status is a lie and a member is being denied work. (It also appears in G6;
restated here because a shift is the thing most likely to write it.)

*Verified to fire:* reverting `TASK-013` to `todo` after the shift ended returns
`uncoverable-ticket-left-todo | TASK-013 | needs:embedded`. Blocking a ticket the matcher can
staff returns `blocked-but-coverable | TASK-006 | reviewer`. Deleting the `embedded` capability
request returns `blocked-for-a-capability-nobody-requested | TASK-013 | embedded`.

**§12.e — the shift said why it stopped, every time.** Expect **zero rows**:

```sql
SELECT 'shift-never-said-why-it-stopped' AS breach, eo.subject_id AS row_id, eo.ts AS detail
  FROM event eo
 WHERE eo.subject_type='shift' AND eo.verb='started'
   AND NOT EXISTS (SELECT 1 FROM event ec WHERE ec.subject_type='shift' AND ec.verb='ended'
                     AND ec.subject_id = eo.subject_id)
   AND eo.id < (SELECT MAX(id) FROM event WHERE subject_type='shift' AND verb='started')
UNION ALL
SELECT 'two-shifts-open-at-once', 'shift', CAST(COUNT(*) AS TEXT) || ' open'
  FROM event eo
 WHERE eo.subject_type='shift' AND eo.verb='started'
   AND NOT EXISTS (SELECT 1 FROM event ec WHERE ec.subject_type='shift' AND ec.verb='ended'
                     AND ec.subject_id = eo.subject_id)
HAVING COUNT(*) > 1
UNION ALL
SELECT 'stop-reason-outside-the-vocabulary', e.subject_id, COALESCE(json_extract(e.payload,'$.reason'),'(null)')
  FROM event e
 WHERE e.subject_type='shift' AND e.verb='ended'
   AND COALESCE(json_extract(e.payload,'$.reason'),'') NOT IN
       ('gate','infrastructure','max-tasks','max-minutes','idle','collision','operator')
UNION ALL
SELECT 'shift-opened-without-a-budget', e.subject_id, e.payload
  FROM event e
 WHERE e.subject_type='shift' AND e.verb='started'
   AND (json_extract(e.payload,'$.max_tasks') IS NULL OR json_extract(e.payload,'$.max_minutes') IS NULL)
UNION ALL
SELECT 'budget-changed-mid-shift', eo.subject_id, CAST(COUNT(*) AS TEXT) || ' started rows'
  FROM event eo WHERE eo.subject_type='shift' AND eo.verb='started'
 GROUP BY eo.subject_id HAVING COUNT(*) > 1
UNION ALL
SELECT 'shift-ended-that-never-started', ec.subject_id, ec.ts
  FROM event ec WHERE ec.subject_type='shift' AND ec.verb='ended'
   AND NOT EXISTS (SELECT 1 FROM event eo WHERE eo.subject_type='shift' AND eo.verb='started'
                     AND eo.subject_id = ec.subject_id)
UNION ALL
SELECT 'over-budget', e.subject_id, 'tasks=' || COALESCE(json_extract(e.payload,'$.tasks'),'?')
  FROM event e JOIN event s ON s.subject_id = e.subject_id AND s.verb='started' AND s.subject_type='shift'
 WHERE e.subject_type='shift' AND e.verb='ended'
   AND CAST(COALESCE(json_extract(e.payload,'$.tasks'),0) AS INTEGER)
     > CAST(COALESCE(json_extract(s.payload,'$.max_tasks'),0) AS INTEGER)
ORDER BY breach, row_id;
```

The reason vocabulary is **closed and has exactly seven words**. It is not CHECKed anywhere —
`event.verb` and `event.payload` are deliberately unconstrained — so
`stop-reason-outside-the-vocabulary` is the only thing that holds it. A reason one surface writes
and another cannot read is worse than no reason at all: `guild:brief` and the morning report both
read this value back.

`shift-never-said-why-it-stopped` exempts the *newest* `started` row on purpose: that one may
legitimately still be open. Any older one without an `ended` row is a crashed shift, and knowing
that is the point.

*Verified to fire:* a second `started` row with no `ended` returns
`shift-never-said-why-it-stopped | SHIFT-…`; two simultaneously open shifts add
`two-shifts-open-at-once | shift | 2 open`. A shift ended with `reason` `'ran out of stuff'`,
`tasks: 44` against `max_tasks: 10`, and no budget in its `started` payload, returns
`over-budget`, `shift-opened-without-a-budget` and `stop-reason-outside-the-vocabulary`
together. An `ended` row with no matching `started` returns `shift-ended-that-never-started`.

**§12.f — git safety.** *Asserted with `git`, not with SQL — the repository is not a table, and
saying so is more useful than a proxy query that pretends otherwise.* Run these from the repo
root after the shift. Each states its expected output exactly.

```bash
# G-1  the shift worked on its own branch
git rev-parse --abbrev-ref HEAD
# guild/REQ-001

# G-2  the default branch has nothing on it that is not already published
git rev-list --count origin/main..main
# 0

# G-3  nothing was pushed: no guild branch exists on the remote
git ls-remote --heads origin 'refs/heads/guild/*' | wc -l | tr -d ' '
# 0

# G-4  every commit the shift made is still local
echo "$(git rev-list --count main..HEAD) $(git log --branches --not --remotes --oneline | wc -l | tr -d ' ')"
# 2 2      — the two numbers must be equal

# G-5  one commit per completed task, each carrying the trailer
git log main..HEAD --format='%H %(trailers:key=Guild-Task,valueonly)' | awk 'NF==1'
# (no output — a commit with no Guild-Task trailer is a commit nobody can attribute)

# G-6  the failed task left no commit
git log main..HEAD --format='%(trailers:key=Guild-Task,valueonly)' | grep -cx 'TASK-005'
# 0

# G-7  the tree is clean apart from the guild's own directory
git status --porcelain | grep -v '^?? \.guild/' | wc -l | tr -d ' '
# 0
```

**G-8 — the cross-check, and the only one that catches a commit that lies.** The set of tasks in
the commit trailers must equal the set of tasks the board says the shift completed. Neither
source alone can be trusted: the board does not see the repository, and a commit message is prose.

```bash
git log main..HEAD --format='%(trailers:key=Guild-Task,valueonly)' | sed '/^$/d' | sort -u > /tmp/git-tasks
printf "%s\n" "SELECT DISTINCT subject_id FROM event
 WHERE subject_type='task' AND verb='moved'
   AND json_extract(payload,'\$.to')='done'
   AND ts >= substr((SELECT ts FROM event WHERE subject_type='shift' AND verb='started'
                      ORDER BY ts DESC, id DESC LIMIT 1),1,19)
 ORDER BY subject_id;" | tursodb -q -m list .guild/guild.db > /tmp/db-tasks
diff /tmp/git-tasks /tmp/db-tasks && echo IDENTICAL
```

*Verified:* on a shift that completed `TASK-003` and `TASK-004`, failed `TASK-005` and quarantined
its edits, all seven checks return their stated values and G-8 prints `IDENTICAL`. Then, breaching
each in turn — `git push origin guild/REQ-001`, a commit made on `main`, and a commit carrying
`Guild-Task: TASK-005` — G-2 returns `1`, G-3 returns `1`, G-4 returns `3 2`, G-6 returns `1`, and
G-8 reports `< TASK-005`: **a commit for a task the board never completed.**

Note what G-8 catches that nothing else does: commits attributed to tasks finished in an *earlier*
session. An early version of this fixture committed `TASK-001` and `TASK-002` on the shift branch,
and the diff named both — work that was real, on a branch it did not belong to.

### Anti-expectations

Must be false after a shift. These are the specific ways *this* process goes wrong.

| Must not be true | Caught by |
|---|---|
| A gate moved from `pending` to decided during the shift | §12.a `gate-decided-during-shift`, `gate-approved-with-no-shift-boundary` |
| Any node moved past an unresolved gate | §12.a `work-past-unresolved-gate`, G4 `past-unresolved-gate` |
| A requirement closed past an unresolved gate | G6 `requirement-done-with-pending-gate` |
| An inspection *started* by the shift | §12.b `shift-started-an-inspection`, `shift-opened-an-inspection-row` |
| A member created, or a filed gap quietly self-filled | §12.b `shift-recruited-or-retired-a-member`, `shift-filed-a-capability-request-and-created-the-member` |
| A goal or phase moved | §12.b `shift-touched-the-direction` |
| A ticket retried twice inside one shift | §12.c `retried-more-than-once` |
| A failure recorded on only one of the ticket and the node | §12.c `failed-node-live-ticket`, `failed-ticket-live-node` |
| A ticket left `in-progress` by a crashed turn | G6 `in-progress-unclaimed`, `claimed-without-timestamp` |
| A ticket nobody can take left `todo` | §12.d `uncoverable-ticket-left-todo` |
| A ticket `blocked` that the matcher could staff | §12.d `blocked-but-coverable`, G6 |
| A shift that ended without saying why | §12.e `shift-never-said-why-it-stopped` |
| A stop reason nobody else can read | §12.e `stop-reason-outside-the-vocabulary` |
| A ceiling raised from inside the loop | §12.e `budget-changed-mid-shift`, `over-budget` |
| A commit on the default branch, or anything pushed | §12.f G-2, G-3, G-4 |
| A commit for a failed task | §12.f G-6, G-8 |
| An invented capability tag on a ticket the shift created | G5 `capability-outside-vocabulary` |
| A dispatch to somebody the matcher would not have picked | G5 `top-agent-disagrees-with-match` |

### Cannot be asserted

The shift is where the gap between what SQL can see and what actually happened is widest, so this
list is longer than the others' and every item on it is load-bearing.

- **Whether the shift, or a human, made any given change.** SQL has no identity and
  `guild_state.actor` is a label the writer sets on itself. Every window assertion above answers
  *"did this happen during the shift"*, never *"did the shift do it"*. A guild master who wakes at
  4am and approves a gate produces exactly the row §12.a fires on. **This is the single largest
  thing v6 gave up, and it is worst here**, because the shift is the one process where nobody is
  present to remember.
- **A priority change is invisible.** Verified: `UPDATE task SET priority = 1` and
  `UPDATE requirement SET priority = 5` each write **no `event` row at all** — the `_touch`
  triggers only stamp `updated_at`. "Never change priorities" is in the MAY NOT table and
  **nothing in this document can check it.** The same holds for a retitled requirement or an
  edited body.
- **Whether the retry used a fresh agent instance.** The `Shift retry` marker records that a retry
  happened. Nothing sees the context the second attempt ran with, and re-dispatching the same
  exhausted conversation looks identical on the board.
- **Whether the commit contains the task's work.** G-8 matches trailer *sets*. It cannot tell
  whether the diff under `Guild-Task: TASK-003` is that task's code, somebody else's, or nothing
  of consequence.
- **Whether the quarantine is complete.** `.guild/backup-revert-<TASK>-<ts>/` is a directory the
  shift creates by convention. Nothing checks that the partial edits went into it rather than
  being discarded, and `git checkout --` destroys what it reverts.
- **Whether a file collision actually occurred.** It is invisible to the board by construction —
  two slices writing one file is a fact about the tree. Only the orchestrator can see it, which is
  why `collision` is one of the two stop reasons SQL cannot compute.
- **Whether the notification was sent,** or arrived, or was read. `.guild/shift.notify` records
  consent, not delivery.
- **Whether the user was actually away.** The whole premise of the process, and it is a social
  fact.
- **Whether a `NEEDS INPUT:` was answered on the user's behalf.** The rule is to fail the node and
  log the questions. A member that guessed instead produces a `done` node and a plausible work
  log, and no query distinguishes them.
- **Whether the board was clean before the shift.** P12.b is a *precondition* run at the time, not
  a postcondition: by morning the tree contains the shift's own work and the earlier state is
  unrecoverable.
