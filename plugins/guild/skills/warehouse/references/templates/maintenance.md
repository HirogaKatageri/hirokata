# The `maintenance` template — inspect what was built

**You are the architect. There is no parser.** This page replaces `maintenance.yaml`. You read
it and write the `graph_node` / `graph_edge` / `gate` rows yourself, with the SQL in §7.

**Shape:** decide whether an inspection is due, plan it, run it one tester at a time, report,
approve repairs.

```
qa-check ─▶ qa-plan ─▶ qa-execute ─▶ qa-report ─▶ gate-repairs ─▶ repair
                       ONE AT A TIME                  GATE
└──────── segment 1: observes and records only ───────┘        └─ segment 2 ─┘
```

**QA is not a separate discipline with its own workflow.** It is the guild's second template,
running on the same graph machinery and ending at the same `gate-repairs` → `repair` tail as
[`standard`](standard.md). Both converge on *"here is what we found, approve the repairs"*, so
the guild master learns one interaction rather than two.

---

## 1. Manual trigger only — and this one is not negotiable

**Nothing starts an inspection except a person asking for one.** No auto-trigger on
requirement-done. No standing cadence.

A full inspection is among the most expensive things the guild does: it runs the real product,
drives a browser, and does it **one mission at a time**. Firing that automatically on every
completed requirement would quietly make every requirement cost several times what it appears
to cost — and the cost lands on a bill and a machine, not on the decision that caused it.

The machinery for a cadence is already present: `coverage.last_inspected_at` makes any interval
policy a one-line query (§4), and `inspection."trigger"` is a column that already exists. So
this is a decision that can be revisited from evidence later without redesign. Until then it
stays manual.

**An unattended shift may *work* an inspection but must never *start* one.** Every node from
`qa-check` through `qa-report` only observes and records — it runs the product, writes specs and
files bugs, and nothing before the gate touches production code. So once a person has started
one, a shift can carry it to `gate-repairs` overnight and have the findings waiting in the
morning. It just cannot decide on its own that inspection time has arrived.

That is the same rule as the build path, which is why it is the right one: the guild master
authorizes the expensive thing, and the guild then runs it to completion without interruption.

---

## 2. The node sequence

| # | node key | kind | after | capability | fan-out | may run in parallel | required |
|---|----------|------|-------|-----------|---------|---------------------|----------|
| 1 | `qa-check` | work | — | `qa-planning` | none, always one | n/a (single node) | **yes** |
| 2 | `qa-plan` | work | `qa-check` | `qa-planning` | none, always one | no | no |
| 3 | `qa-execute` | work | `qa-plan` | `qa-execution` | one **anchor**, one mission ticket each | **never — see §3** | no |
| 4 | `qa-report` | work | `qa-execute` | `qa-planning` | none, always one | no | **yes** |
| 5 | `gate-repairs` | gate | `qa-report` | — | none, always one | n/a | **yes** |
| 6 | `repair` | work | `gate-repairs` | `implement` | one **anchor**, tickets underneath | tickets sharing a `parallel_group` | no |

Always **6 nodes, 5 edges, 1 gate row**, whatever the inspection covers. There is no per-ticket
fan-out here, so the counts do not vary. That is the number to check your INSERT against.

---

## 3. What each node produces

### `qa-check` — is an inspection due, and over what?

Capability: `qa-planning`. Produces: **a list of coverage areas that warrant inspection, or
nothing.**

Reads `coverage`: areas touched by recently completed requirements, high-risk areas past their
interval, anything with no e2e spec at all. The query is in §4.

**This is the step that makes the cycle a cycle rather than a chore.** Because `coverage` rows
carry `last_inspected_at` and a `risk` level, *"what needs inspecting"* is a query rather than a
judgement call. **When nothing qualifies, the cycle ends here having cost almost nothing** —
which is what makes it safe to trigger often. Ending early is a success, not a failure; §7.3
shows how to close the graph out.

### `qa-plan` — the risk map and the missions

Capability: `qa-planning`, agent `qa-strategist`. Produces: **a risk map, a coverage matrix, and
a declared set of inspection missions** — one per coverage area worth a session.

Writes the `inspection` row and its `inspection_coverage` rows. Each mission becomes a ticket
under the `qa-execute` anchor.

### `qa-execute` — one tester at a time, always

Capability: `qa-execution`, agent `qa-tester`. Produces: **e2e specs, observations, and a verdict
per coverage area** (`pass` | `issues` | `not-reached` in `inspection_coverage.verdict`).

Nominally `per-mission`; it instantiates as **exactly one anchor node** with `parallel_group`
NULL. No SQL materializes sibling nodes at run time — the anchor is the barrier and the mission
tickets are the work. The orchestrator dispatches the tickets **one at a time**, waits for each,
and moves the anchor `done` once when the last mission returns.

> **ONE TESTER AT A TIME IS AN INVARIANT, NOT A TUNING KNOB.** Playwright is heavy and every
> tester drives its own dev server. Concurrent testers **collide on ports and thrash the
> machine**, and the result is not a clean error — it is intermittent, confusing failures that
> look like product bugs. That is why it is defended in two independent places:
>
> 1. **`qa-execute.parallel_group` is NULL**, so no batch query ever groups two of them.
> 2. **`qa-tester` declares `serial: true` in its frontmatter**, so a dispatcher that read the
>    roster will not hand out a second concurrent assignment even if a caller asks.
>
> Two mechanisms, because one missed check here produces a mystery rather than a message.
>
> **Be honest about the enforcement:** a NULL `parallel_group` and a line of frontmatter are
> read by whoever dispatches — and the `serial` half is not in the database at all, so
> a dispatcher that skipped the roster scan cannot see it. Nothing in the schema
> physically prevents an orchestrator from starting two testers. **Run the guard in §5 before every dispatch.** It is a convention with a check,
> not an invariant the database holds for you.

### `qa-report` — compile and stamp

Capability: `qa-planning`. Produces: **`bug` rows**, and it **stamps `coverage.last_inspected_at`**
for every area actually reached.

`required: true` — the stamp is what closes the loop. An inspection that runs and does not
record that it ran will be re-run immediately by the next `qa-check`, and the guild will inspect
the same three areas forever.

### `gate-repairs` — the same gate as `standard`

Prompt: `Inspection of {requirement} found issues — approve which get repaired.`
Gate kind: `select-findings`. The selection is stored in `gate.decision`.

Identical semantics, identical selection UX, identical position in the graph. That is what
answers *"does QA need gates of its own?"* — it does not.

### `repair` — one anchor, tickets underneath

Capability: `implement`. Produces: **fixes for the approved bugs only.** Same anchor rule as
`standard`; tickets inherit the `parallel_group` of the area they touch.

---

## 4. `qa-check` — the query that decides

Verified against tursodb 0.7.2. Returns one row per coverage area that warrants inspection, and
**zero rows when the cycle should end early**.

```sql
SELECT c.id, c.risk,
       COALESCE(c.spec_path, '(no spec)')          AS spec,
       COALESCE(c.last_inspected_at, '(never)')    AS last_seen,
       CASE WHEN c.spec_path IS NULL              THEN 'no spec'
            WHEN c.last_inspected_at IS NULL      THEN 'never inspected'
            WHEN c.risk = 'high'   AND c.last_inspected_at < datetime('now','-14 days') THEN 'high risk, stale'
            WHEN c.risk = 'medium' AND c.last_inspected_at < datetime('now','-30 days') THEN 'medium risk, stale'
            WHEN c.risk = 'low'    AND c.last_inspected_at < datetime('now','-90 days') THEN 'low risk, stale'
       END AS why
FROM coverage c
WHERE c.spec_path IS NULL
   OR c.last_inspected_at IS NULL
   OR (c.risk = 'high'   AND c.last_inspected_at < datetime('now','-14 days'))
   OR (c.risk = 'medium' AND c.last_inspected_at < datetime('now','-30 days'))
   OR (c.risk = 'low'    AND c.last_inspected_at < datetime('now','-90 days'))
ORDER BY CASE c.risk WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END, c.id;
```

The intervals are the guild's current policy, not a law. They live in this query, so changing
them is an edit here — no migration, no schema change.

Also worth asking: **which areas did recently completed requirements touch?**

```sql
SELECT DISTINCT c.id, c.area, c.risk
FROM coverage c
JOIN requirement r ON r.status = 'done'
WHERE r.updated_at > COALESCE(c.last_inspected_at, '0000')
  AND (c.notes LIKE '%' || r.id || '%' OR c.id = r.id);
```

Note the `LIKE`: **tursodb has no FTS5** (verified failing). Text matching is `LIKE`, and if you
ever build the pattern from free text you must escape `%` and `_` yourself.

---

## 5. The serial guard — run it before every `qa-execute` dispatch

```sql
-- Must return ZERO rows. If it returns anything, a tester is already running: wait.
SELECT 'TESTER ALREADY RUNNING: ' || n.id
FROM graph_node n
WHERE n.node_key = 'qa-execute' AND n.status = 'running';

-- Same question from the ticket side — the frontmatter serial:true half of the invariant.
SELECT 'TESTER ALREADY CLAIMED: ' || t.id
FROM task t WHERE t.claimed_by = 'qa-tester' AND t.status = 'in-progress';
```

Board-wide, not per-requirement. Two inspections on two different requirement carriers still
share one machine and one set of ports.

---

## 6. Deviation rules — and why each one exists

Same rules as `standard`, same reasoning. Every deviation writes a `graph_deviation` row with a
**non-empty reason**.

```sql
INSERT INTO graph_deviation (requirement_id, kind, node_key, reason, created_at)
VALUES ('REQ-041', 'reshape', 'qa-execute',
        CAST(x'<hex of the reason>' AS TEXT), datetime('now'));
```

| rule | why |
|---|---|
| **`qa-check`, `qa-report` and `gate-repairs` may be reshaped but never dropped** | Dropping `qa-check` turns a cycle into an unconditional expense. Dropping `qa-report` means `coverage.last_inspected_at` is never stamped, and the same areas get re-inspected forever. These are guild standards, not per-inspection judgements. |
| **A gate may be neither dropped nor added** | `maintenance` declares exactly **one** gate. Dropping it removes the guild master's control over what gets repaired. Adding one is the subtler mistake: gates are where an unattended shift stops and notifies, so an extra gate turns an overnight inspection into a session that stops to ask a sleeping human. `add-gate` is refused outright, whatever the reason — the cost is not paid at the moment of the decision. |
| **`qa-execute` may be reshaped, but never to run in parallel** | Reshaping its scope, its mission count or its ordering is fine. Giving it a non-null `parallel_group` is not a deviation, it is a defect (§3). |
| **Every deviation carries a non-empty reason** | Whitespace-only is empty. Without it there is no way to tell an intentional divergence from a mistake when an inspection goes wrong. |
| **An `add-node` must name a capability some available subagent declares** | Otherwise the graph cannot run, and you find out mid-shift. **Nothing in SQL can check this.** Use `roster.py --covers` before you insert (§8). |
| **Every template key gets at least one node** | What makes "dropped" unambiguous — a key with zero rows was dropped, with no caveat to hide behind. This is why `qa-execute` and `repair` instantiate as anchors rather than as nothing. |

**Legitimate deviations look like:** dropping `qa-plan` for a single-area spot check where the
strategist's mission list would be one line; adding a `perf-probe` node between `qa-execute` and
`qa-report` for a latency complaint, when some available subagent declares that capability; reshaping `qa-execute` to cover one area instead of six.

### What is enforced and what is convention

| rule | enforced by |
|---|---|
| `kind ∈ ('work','gate')`, `status` and `verdict` vocabularies | **the database**, via CHECK constraints |
| node id uniqueness, one gate row per gate node, one verdict per (inspection, area) | **the database**, via PRIMARY KEY |
| readiness, the review gate, the board | **the database**, via views |
| "exactly one gate", "no dropped required node", "non-empty reason" | **you**, by running §8. A trigger can hold the gate rule if the warehouse schema ships one — check `SELECT name FROM sqlite_schema WHERE type='trigger'` rather than assuming. |
| **"one tester at a time"** | **you**, via §5 plus `serial: true` in the agent's frontmatter. The database does not know what a port is, and it does not know what `serial` is either. |
| "manual trigger only" | **you.** `inspection."trigger"` records what started it; nothing rejects an automated caller. |
| "the orchestrator owns every status transition" | **nobody.** A convention — the schema has no identity concept and cannot tell whose UPDATE it is. |

---

## 7. Instantiating the graph

### 7.1 The carrier requirement

`graph_node.requirement_id` is `NOT NULL REFERENCES requirement(id)`. **An inspection has no id
of its own to hang a graph off.** So before you build the graph, you need a requirement row to
carry it — either:

- **the requirement that motivated the inspection**, if one did ("we just shipped REQ-039, look
  at checkout"), or
- **a carrier requirement created for this inspection**, unaffiliated (`project_id` NULL, which is
  legal), titled so it is obviously not feature work.

Prefer the carrier. Hanging a maintenance graph off a feature requirement gives that requirement
two graphs and makes `guild_state` ambiguous about which template built it.

The `inspection` row is separate and is written by `qa-plan`; the carrier requirement is only
what the graph is keyed by.

### 7.2 Preflight — run this first, on its own

```sql
SELECT COUNT(*) FROM graph_node WHERE requirement_id = 'REQ-041';
SELECT COUNT(*) FROM requirement WHERE id = 'REQ-041';
```

Expect **`0`** then **`1`** (the carrier INSERT in the script below is idempotent and will supply
the `1` on a fresh id). A separate round trip on purpose: **a failing statement does not stop a
tursodb script and `COMMIT` still commits** (gotcha 9), so a guard inside the same script as the
INSERTs is not a guard.

### 7.3 The prompt travels as hex

```bash
printf '%s' "Inspection of REQ-041 found issues — approve which get repaired." | xxd -p | tr -d '\n'
```

The em dash is multi-byte and the sentence ends in a `.`; hex is always single-line, so the
statement splitter cannot tear it (gotcha 1). Regenerate for your carrier id.

### 7.4 The script

Replace every `REQ-041` with your carrier id and the hex blobs with yours. Verified against
tursodb 0.7.2 — 6 nodes, 5 edges, 1 gate.

```sql
BEGIN;

-- 0. the carrier requirement. Skip this statement if you are hanging the inspection
--    off an existing requirement. Title travels as hex like any free text.
INSERT INTO requirement (id, project_id, title, body, status, priority, created_at, updated_at)
SELECT 'REQ-041', NULL,
       CAST(x'4d61696e74656e616e636520696e7370656374696f6e' AS TEXT),  -- 'Maintenance inspection'
       '', 'todo', 3, datetime('now'), datetime('now')
WHERE NOT EXISTS (SELECT 1 FROM requirement WHERE id = 'REQ-041');

-- 1..6. the nodes. No fan-out anywhere: qa-execute and repair are ANCHORS, and their
--       siblings are tickets, not nodes.
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-041/qa-check', r.id, 'qa-check', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-041';
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-041/qa-plan', r.id, 'qa-plan', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-041';
-- parallel_group MUST be NULL here. See §3.
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-041/qa-execute', r.id, 'qa-execute', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-041';
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-041/qa-report', r.id, 'qa-report', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-041';
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-041/gate-repairs', r.id, 'gate-repairs', 'gate', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-041';
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-041/repair', r.id, 'repair', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-041';

-- EDGES: one statement per (predecessor key, successor key) pair. A cross join over the
-- instances of the two keys — the same form as `standard`, so a fanned predecessor would
-- become a real barrier if a deviation ever introduced one here.
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-041' AND t.requirement_id = 'REQ-041'
  AND f.node_key = 'qa-check' AND t.node_key = 'qa-plan' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-041' AND t.requirement_id = 'REQ-041'
  AND f.node_key = 'qa-plan' AND t.node_key = 'qa-execute' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-041' AND t.requirement_id = 'REQ-041'
  AND f.node_key = 'qa-execute' AND t.node_key = 'qa-report' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-041' AND t.requirement_id = 'REQ-041'
  AND f.node_key = 'qa-report' AND t.node_key = 'gate-repairs' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-041' AND t.requirement_id = 'REQ-041'
  AND f.node_key = 'gate-repairs' AND t.node_key = 'repair' AND f.id <> t.id;

-- THE ONE GATE.
INSERT INTO gate (node_id, prompt, kind, status, decision, decided_at)
SELECT n.id, CAST(x'496e7370656374696f6e206f66205245512d30343120666f756e642069737375657320e2809420617070726f7665207768696368206765742072657061697265642e' AS TEXT),
       'select-findings', 'pending', NULL, NULL
FROM graph_node n WHERE n.requirement_id = 'REQ-041' AND n.node_key = 'gate-repairs';

-- WHICH TEMPLATE BUILT THIS GRAPH — the baseline every deviation is diffed against.
INSERT INTO guild_state (key, value) VALUES ('graph-template:REQ-041', 'maintenance');

COMMIT;
```

If the warehouse schema does not write an `event` row by trigger on `graph_node`
(`SELECT name, tbl_name FROM sqlite_schema WHERE type = 'trigger';`), add one before `COMMIT`:

```sql
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT datetime('now'), 'architect', 'instantiated', 'graph', 'REQ-041',
       json_object('template', 'maintenance', 'trigger', 'manual',
                   'nodes', (SELECT COUNT(*) FROM graph_node WHERE requirement_id = 'REQ-041'));
```

### 7.5 Ending the cycle early at `qa-check`

When §4 returns nothing, mark `qa-check` done and **skip** the rest. Do not delete the nodes —
the record of an inspection that correctly decided to do nothing is worth keeping, and deleting
them would make the graph look dropped to §8.

```sql
BEGIN;
UPDATE graph_node SET status = 'done'
 WHERE id = 'REQ-041/qa-check';
UPDATE graph_node SET status = 'skipped'
 WHERE requirement_id = 'REQ-041'
   AND node_key IN ('qa-plan','qa-execute','qa-report','gate-repairs','repair');
UPDATE gate SET status = 'approved', decision = 'nothing due', decided_at = datetime('now')
 WHERE node_id = 'REQ-041/gate-repairs';
COMMIT;
```

`skipped` counts as finished in the readiness rule, so the graph closes out cleanly rather than
sitting forever with a `repair` node nothing will ever release.

---

## 8. Reading it back, and validating a deviation

**Readiness is a direct-predecessor join, not a traversal.** `WITH RECURSIVE` does not work on
tursodb — verified failing — and is not needed: readiness propagates one node at a time.

```sql
-- what can run right now
SELECT n.id, n.node_key, COALESCE(n.parallel_group, '(serial)') AS batch
FROM graph_node n
WHERE n.requirement_id = 'REQ-041' AND n.status = 'pending'
  AND NOT EXISTS (SELECT 1 FROM graph_edge ge
                   JOIN graph_node gp ON gp.id = ge.from_node
                  WHERE ge.to_node = n.id AND gp.status NOT IN ('done','skipped'))
ORDER BY n.id;
```

`done` and `skipped` both count as finished. The warehouse schema ships `v_ready_nodes` —
**select from it instead of re-typing this**; two spellings of readiness is two answers to
"what runs next".

Validation — each of these returns **zero rows when the graph is sound**:

```sql
-- (a) a template key with no instance = a DROPPED node
WITH tpl(k, required) AS (VALUES
  ('qa-check',1),('qa-plan',0),('qa-execute',0),
  ('qa-report',1),('gate-repairs',1),('repair',0))
SELECT 'DROPPED' || CASE WHEN tpl.required = 1 THEN ' (REQUIRED)' ELSE '' END || ': ' || tpl.k
FROM tpl
WHERE NOT EXISTS (SELECT 1 FROM graph_node n
                   WHERE n.requirement_id = 'REQ-041' AND n.node_key = tpl.k);

-- (b) a gate whose key is not the template's = an ADDED GATE. Always a failure.
SELECT 'ADDED GATE: ' || n.id
FROM graph_node n
WHERE n.requirement_id = 'REQ-041' AND n.kind = 'gate' AND n.node_key <> 'gate-repairs';

-- (c) an add-gate deviation row. Also always a failure, however good the reason.
SELECT 'ADD-GATE DEVIATION: ' || node_key || ' — ' || reason
FROM graph_deviation WHERE requirement_id = 'REQ-041' AND kind = 'add-gate';

-- (d) a deviation with an empty or whitespace-only reason
SELECT 'EMPTY REASON: ' || kind || ' ' || node_key
FROM graph_deviation WHERE requirement_id = 'REQ-041' AND trim(reason) = '';

-- (e) THE INVARIANT: qa-execute must never carry a parallel_group
SELECT 'PARALLEL QA-EXECUTE: ' || n.id
FROM graph_node n
WHERE n.node_key = 'qa-execute' AND n.parallel_group IS NOT NULL;
```

Before an `add-node` deviation, confirm some available subagent declares the capability.
**This one is not SQL** — the roster is the agent files:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py" --covers perf-probing
```

No output means no member. Do not add the node.

Counts, against §2:

```sql
SELECT (SELECT COUNT(*) FROM graph_node WHERE requirement_id = 'REQ-041') AS nodes,
       (SELECT COUNT(*) FROM graph_edge WHERE to_node LIKE 'REQ-041/%') AS edges,
       (SELECT COUNT(*) FROM graph_node WHERE requirement_id = 'REQ-041' AND kind = 'gate') AS gates;
```

Expect **6, 5, 1**. Not two gates — that is `standard`.
