# The `standard` template — build a requirement

**You are the architect. There is no parser.** This file used to be `standard.yaml`, read by
`_graph_parse_template` in a bash CLI. That CLI is gone. You read this page and you write the
`graph_node` / `graph_edge` / `gate` rows yourself, with the SQL at the bottom.

**Shape:** approve the plan, run to completion, decide what to repair, then plan the repair the
same way the build was planned.

```
gate-plan ─▶ implement (× tickets) ─▶ test-plan ─▶ test-write ─▶ review (× 4) ─▶ gate-repairs
   GATE                                                                             GATE
   └───────────────── segment 1: runs without stopping ─────────────────┘

  ─▶ repair-spec ─▶ repair-plan ─▶ gate-repair-plan ─▶ repair
                                        GATE
     └──── segment 2 ────┘              └── segment 3 ──┘
```

Use it for every requirement that produces code.

---

## 1. The node sequence

| # | node key | kind | after | fan-out | may run in parallel | required |
|---|----------|------|-------|---------|---------------------|----------|
| 1 | `gate-plan` | gate | — | none, always one | n/a | yes |
| 2 | `implement` | work | `gate-plan` | one node **per implement ticket** | tickets sharing a `parallel_group` | yes |
| 3 | `test-plan` | work | `implement` (all of them) | none, always one | no | no |
| 4 | `test-write` | work | `test-plan` | one **anchor**, tickets underneath | no | no |
| 5 | `review` | work | `test-write` | **fixed at 4 named reviewers** | all four together | yes |
| 6 | `gate-repairs` | gate | `review` (all four) | none, always one | n/a | yes |
| 7 | `repair-spec` | work | `gate-repairs` | none, always one | no | no |
| 8 | `repair-plan` | work | `repair-spec` | none, always one | no | no |
| 9 | `gate-repair-plan` | gate | `repair-plan` | none, always one | n/a | no |
| 10 | `repair` | work | `gate-repair-plan` | one **anchor**, tickets underneath | tickets sharing a `parallel_group` | no |

With *N* implement tickets that is **N + 12 nodes and 2N + 13 edges**. Two tickets → 14 nodes, 17
edges, 3 gate rows. That is the number to check your INSERT against.

**Rows 7–10 are one optional group.** If `gate-repairs` approves nothing, all four are dropped
together with a single `drop-node` deviation each, carrying the same reason. Approving nothing is
a legitimate outcome, not a degenerate one.

---

## 2. What each node produces

### `gate-plan` — the only approval before anything is built

Prompt: `Plan for {requirement} is ready for review. Approve implementation?`
Gate kind: `approve`.

Produces nothing. It *is* the decision. Everything downstream — how many tickets, which
reviewers, what gets tested — was already written by the time this gate is presented; the guild
master is approving a plan they can read, not authorizing an unknown.

The plan is the cheapest place to change your mind. One decision here redirects the entire
requirement. That is why it is the first node and why there is no second chance to redirect
before `gate-repairs`.

### `implement` — one node per implement ticket

Capability: `implement`. Produces: **working code and a passing build for one ticket.**

Fan-out is `per-task`: read the requirement's tickets where `node_key = 'implement'` and emit one
node per ticket, id `REQ-NNN/implement.<TASK-ID>`. Each node binds that ticket and inherits its
`parallel_group`.

**The one guard that is not obvious.** If the plan has no implement tickets yet — which is the
state every board is in for the first few minutes — emit **one unfanned node**
`REQ-NNN/implement` instead.
The two INSERTs below are mutually exclusive by construction. Never let a template key end up
with zero rows; see §5.

### `test-plan` — the barrier

Capability: `test-planning`. Produces: **a test declaration** — which behaviours need covering,
at what level, in how many specs.

It waits for **every** `implement.<TASK-ID>` node, because it inventories the whole diff. That is
what the cross-join edge INSERT gives you for free: one statement, `implement` × `test-plan`,
and a fanned predecessor becomes a real barrier.

### `test-write` — one anchor, not one node per spec

Capability: `test-authoring`. Produces: **the test files.**

Nominally `per-declaration` — the test-planner says how many. **It still instantiates as exactly
one node.** No command materializes siblings at run time; the anchor is the barrier and the
tickets are the work. The orchestrator dispatches every ticket the anchor covers and moves the
anchor `done` once.

**Why the anchor must exist even with nothing under it yet.** `review` is `after: [test-write]`.
With zero `test-write` rows there is no edge into `review`, so `review` has no unfinished direct
predecessor — and the readiness rule (§7) says it is **immediately ready**. Review would run
before a single test was written. The anchor is what stops that.

### `review` — four reviewers, fixed, in parallel

Produces: **`review_finding` rows.** No code is changed here.

Fan-out is `fixed` with four named agents:

| agent | reads for |
|---|---|
| `reviewer-security` | injection, authz, secrets, unsafe deserialization |
| `reviewer-architecture` | layering, coupling, whether it matches the plan |
| `reviewer-business-logic` | does it do what the requirement said |
| `reviewer-edge-case` | nulls, empties, boundaries, concurrency, failure paths |

All four get `parallel_group = 'review'` so the batch query puts them in one wave. They read the
same diff and write to different rows; there is no contention.

### `gate-repairs` — report problems, approve repairs

Prompt: `Findings and bugs from {requirement} — approve which get repaired.`
Gate kind: `select-findings` — the guild master picks a subset, and the selection is stored in
`gate.decision`.

**Problems found during the run are collected, not escalated one at a time.** A failing task, a
security finding and a flaky test all wait here and surface together, where they can be judged
against each other in one pass. Escalating each one the moment it appears converts agent time
into the guild master's time, which is the resource the whole template is built to protect.

### `repair-spec` — the product-owner writes the repair requirements

Capability: `requirements`. Produces: **a `plan` row bound to its own ticket** (`plan.task_id`),
carrying what the approved repairs must achieve and how anyone would know they did.

**There is no interview here, and that is the whole point of its placement.** The product-owner
normally opens a requirement by asking the user what they want. It does not need to: the issues
were discussed item by item at `gate-repairs` and the user's own words are in `gate.decision`.
This node reads that decision and writes it up as acceptance criteria. A node that stopped to
re-interview would be asking the guild master the same question twice.

Read the decision, not the findings table, when they disagree — the decision is what the user
actually said.

### `repair-plan` — the architect plans the repair and cuts the tickets

Capability: `architecture`. Produces: **a `plan` row bound to its own ticket**, and **the repair
tickets themselves** — one per approved item, each with its `files` JSON array and
`parallel_group`, exactly as in Step 5 of the build.

Link each ticket back to what it repairs in the same pass:

```sql
UPDATE review_finding SET disposition = 'fixing', fix_task_id = 'TASK-021'
 WHERE id = 7 AND disposition = 'open' RETURNING id, disposition;
UPDATE bug SET status = 'fixing', fix_task_id = 'TASK-022'
 WHERE id = 'BUG-004' AND status = 'open' RETURNING id, status;
```

**The repair tickets belong to the SAME requirement.** `task.requirement_id` stays `REQ-NNN`.
This is what keeps `fix_task_id` meaningful — `v_open_findings` derives its `requirement_id`
through `task_id`, so a repair filed under a different requirement would leave the finding and
its fix answering to different requirements, and G6's closure rules would reason about the
wrong one.

### `gate-repair-plan` — approve the repair plan

Prompt: `Repair plan for {requirement} is ready. Approve implementation?`
Gate kind: `approve`.

The same decision `gate-plan` makes, about a smaller body of work. It is **not** a re-run of
`gate-repairs`: that one chose *which problems matter*, this one approves *how they will be
fixed*. If it were asking the same question twice it would not be worth its cost — see §4.

### `repair` — one anchor, tickets underneath

Capability: `implement`. Produces: **fixes for the approved findings only.**

Same anchor rule as `test-write`: one node, with the tickets `repair-plan` created underneath it.
Tickets inherit the `parallel_group` of the ticket they repair, so disjoint repairs still run
concurrently.

**No automatic re-review.** If the guild master wants another pass over the repaired code, that
is a fresh reviewer ticket they ask for.

---

## 3. What may run at the same time

`parallel_group` is a **label, not a strategy**. Nodes ready at the same instant and carrying
the same non-null label form one batch. A NULL label means "run me alone".

| node | label written at instantiation | effect |
|---|---|---|
| `implement.<TASK-ID>` | the implement ticket's own `parallel_group` | tickets the architect declared disjoint run together |
| `review.<agent>` | the literal `'review'` | all four reviewers in one wave |
| everything else | `NULL` | serial |

**The disjointness assertion belongs to the architect, not to the database.** `task.files`
is where you record which files a ticket owns; if two tickets share a file, give them different
`parallel_group` values and they serialize. Nothing in the schema checks this for you. If you
are unsure, use different groups — a wrong serialization costs time, a wrong parallelization
costs a merge conflict inside an unattended shift.

---

## 4. Exactly three gates, and their placement is the point

`standard` declares **three** gates and no more. That number is not a default, and the third one
was added deliberately against the argument below — which still holds, and is the price.

- `gate-plan` — approve the plan before anything is built.
- `gate-repairs` — decide **which problems matter**, once, over everything the run collected.
- `gate-repair-plan` — approve **how the chosen problems get fixed**.

**Adding a gate is the expensive mistake, and this one is not free.** Gates are the boundary at
which an unattended shift stops and notifies. Every gate is a place a shift can end with the
guild master asleep, and a requirement that reaches `gate-repairs` overnight will now stop a
second time before any repair is written. That cost is real and it is paid at 3am, not at the
moment of the decision.

What buys it: `repair` used to be plain tickets the orchestrator wrote at the gate — no
requirements, no plan, no file sets, no disjointness assertion. That is thin for anything larger
than a one-line fix, and it meant repairs were the only code the guild wrote without a plan
anyone approved. `repair-spec` and `repair-plan` close that, and `gate-repair-plan` is what makes
the plan mean something.

**Adding a fourth reads as caution** — *"I'd like to check in before the migrations run"* — and
there is no reason good enough. **Dropping one** removes the guild master's control surface; it
reads as an attack.

Three gates means a requirement is exactly **three segments**: `implement → review`,
`repair-spec → repair-plan`, and `repair`. Each compiles to one workflow.

**Why gates cannot live inside a workflow.** Subagents cannot call `AskUserQuestion`; only the
orchestrator session can. A generated workflow physically cannot ask anything. Segmenting at
gates is the only shape that preserves guild-master control.

---

## 5. Deviation rules — and why each one exists

The architect may deviate from this template. Every deviation writes a `graph_deviation` row
carrying a **non-empty reason**.

```sql
INSERT INTO graph_deviation (requirement_id, kind, node_key, reason, created_at)
VALUES ('REQ-007', 'add-node', 'research',
        CAST(x'<hex of the reason>' AS TEXT), datetime('now'));
```

`kind` is one of `add-node`, `drop-node`, `reshape`, `add-gate`.

| rule | why |
|---|---|
| A `required: true` node may be **reshaped but never dropped** | Review always happens; *how wide it fans out* is negotiable. Reshaping is a judgement about this requirement. Dropping is a judgement about the guild's standards, which is not the architect's to make. |
| **A gate may be neither dropped nor added** | §4. `add-gate` is refused outright, whatever the reason. |
| **Every deviation carries a non-empty reason** | Whitespace-only is empty. A graph with unexplained divergence cannot be diffed against a baseline when a run goes wrong — you end up staring at a bespoke graph with no way to tell intent from accident. |
| **An `add-node` must name a capability the roster has** | Otherwise you get a graph that cannot run: a node no active member can be matched to, discovered at dispatch time in the middle of a shift. Check before you insert (§8). |
| **Every template key gets at least one node** | This is what makes "dropped" unambiguous. A key with zero rows was dropped — full stop, with no *"unless its fan-out happened to be empty"* caveat to hide behind. It is also why `implement` has a no-tickets fallback and why the anchors exist. |

**Legitimate deviations look like:** a `research` node ahead of `implement` for an unfamiliar
API; dropping `test-plan` and going straight to `test-write` for a docs-only change; fanning
`review` to six with a performance and an accessibility reviewer for a UI-heavy requirement;
splitting `implement` into three sequential waves because the file sets are not disjoint.

### What is enforced and what is convention — read this before you trust it

| rule | enforced by |
|---|---|
| `kind ∈ ('work','gate')`, `status` vocabulary | **the database**, via CHECK constraints — cannot be bypassed |
| node id uniqueness, edge uniqueness, one gate row per gate node | **the database**, via PRIMARY KEY |
| the readiness rule, the review gate, the board | **the database**, via views — one definition, not one per reader |
| "no third gate", "no dropped required node", "reason is non-empty" | **you**, by running §8's checks. A trigger can enforce the gate rule if the warehouse schema carries one — check `SELECT name FROM sqlite_schema WHERE type='trigger'`. Do not assume it does. |
| "the orchestrator owns every status transition" | **nobody.** This was a bash guard in v4 and is now a convention. The schema has no identity concept, so it cannot tell an orchestrator's UPDATE from an agent's. Follow it because the board is incoherent otherwise, not because something will stop you. |

---

## 6. Instantiating the graph

### Preflight — run this first, on its own

```sql
SELECT COUNT(*) FROM graph_node WHERE requirement_id = 'REQ-007';
SELECT COUNT(*) FROM requirement WHERE id = 'REQ-007';
```

Expect **`0`** then **`1`**. If the first is non-zero the requirement already has a graph;
re-instantiating would either duplicate nodes or orphan the deviations already recorded against
them. Stop and read the existing graph instead.

This is a separate round trip on purpose. **A failing statement does not stop a tursodb script,
and `COMMIT` still commits** (gotcha 9) — so a guard buried inside the same script as the
INSERTs is not a guard.

### The prompts must travel as hex

Gate prompts are free text with a `?` and an em dash, and free text ends a tursodb statement the
moment a `;` terminates a line (gotcha 1). Generate them per requirement:

```bash
printf '%s' "Plan for REQ-007 is ready for review. Approve implementation?" | xxd -p | tr -d '\n'
printf '%s' "Findings and bugs from REQ-007 — approve which get repaired." | xxd -p | tr -d '\n'
printf '%s' "Repair plan for REQ-007 is ready. Approve implementation?"      | xxd -p | tr -d '\n'
```

The hex literals in the script below are those two strings for `REQ-007`. **Regenerate them for
your requirement id** — the id is substituted into the prompt, not into a placeholder.

### The script

Replace every `REQ-007` with your requirement id, and the two hex blobs with yours. Verified
against tursodb 0.7.2.

```sql
BEGIN;

-- 1. gate-plan -----------------------------------------------------------------
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-007/gate-plan', r.id, 'gate-plan', 'gate', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-007';

-- 2a. implement — one node per implement ticket, bound to that ticket ----------
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-007/implement.' || t.id, r.id, 'implement', 'work',
       t.id, t.parallel_group, 'pending'
FROM requirement r
JOIN task t ON t.requirement_id = r.id AND t.node_key = 'implement'
WHERE r.id = 'REQ-007';

-- 2b. implement — the fallback when the plan has no implement tickets yet.
--     Mutually exclusive with 2a by construction. Together they are what makes
--     "every template key gets at least one node" true.
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-007/implement', r.id, 'implement', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-007'
  AND NOT EXISTS (SELECT 1 FROM task t
                   WHERE t.requirement_id = r.id AND t.node_key = 'implement');

-- 3. test-plan -----------------------------------------------------------------
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-007/test-plan', r.id, 'test-plan', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-007';

-- 4. test-write — ONE anchor. Siblings are tickets, not nodes. ------------------
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-007/test-write', r.id, 'test-write', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-007';

-- 5. review — four fixed reviewers, one parallel_group ---------------------------
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-007/review.' || a.name, r.id, 'review', 'work',
       (SELECT MIN(t.id) FROM task t WHERE t.requirement_id = r.id AND t.agent = a.name),
       'review', 'pending'
FROM requirement r,
     (SELECT 'reviewer-security'       AS name
      UNION ALL SELECT 'reviewer-architecture'
      UNION ALL SELECT 'reviewer-business-logic'
      UNION ALL SELECT 'reviewer-edge-case') a
WHERE r.id = 'REQ-007';

-- 6. gate-repairs ---------------------------------------------------------------
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-007/gate-repairs', r.id, 'gate-repairs', 'gate', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-007';

-- 7. repair-spec — the product-owner writes the repair requirements ---------------
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-007/repair-spec', r.id, 'repair-spec', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-007';

-- 8. repair-plan — the architect plans it and cuts the tickets --------------------
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-007/repair-plan', r.id, 'repair-plan', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-007';

-- 9. gate-repair-plan -------------------------------------------------------------
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-007/gate-repair-plan', r.id, 'gate-repair-plan', 'gate', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-007';

-- 10. repair — ONE anchor ---------------------------------------------------------
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT 'REQ-007/repair', r.id, 'repair', 'work', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = 'REQ-007';

-- EDGES: one statement per (predecessor key, successor key) pair.
-- A CROSS JOIN over the INSTANCES of the two keys, so a fanned predecessor becomes a
-- real barrier: test-plan waits for every implement.<TASK-ID>. Template-sized, never
-- board-sized: six statements whatever N is.
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-007' AND t.requirement_id = 'REQ-007'
  AND f.node_key = 'gate-plan' AND t.node_key = 'implement' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-007' AND t.requirement_id = 'REQ-007'
  AND f.node_key = 'implement' AND t.node_key = 'test-plan' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-007' AND t.requirement_id = 'REQ-007'
  AND f.node_key = 'test-plan' AND t.node_key = 'test-write' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-007' AND t.requirement_id = 'REQ-007'
  AND f.node_key = 'test-write' AND t.node_key = 'review' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-007' AND t.requirement_id = 'REQ-007'
  AND f.node_key = 'review' AND t.node_key = 'gate-repairs' AND f.id <> t.id;
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-007' AND t.requirement_id = 'REQ-007'
  AND f.node_key = 'gate-repairs' AND t.node_key = 'repair-spec' AND f.id <> t.id;

INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-007' AND t.requirement_id = 'REQ-007'
  AND f.node_key = 'repair-spec' AND t.node_key = 'repair-plan' AND f.id <> t.id;

INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-007' AND t.requirement_id = 'REQ-007'
  AND f.node_key = 'repair-plan' AND t.node_key = 'gate-repair-plan' AND f.id <> t.id;

INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = 'REQ-007' AND t.requirement_id = 'REQ-007'
  AND f.node_key = 'gate-repair-plan' AND t.node_key = 'repair' AND f.id <> t.id;

-- GATE ROWS. Prompts as hex — always single-line, so the splitter cannot tear them.
INSERT INTO gate (node_id, prompt, kind, status, decision, decided_at)
SELECT n.id, CAST(x'506c616e20666f72205245512d30303720697320726561647920666f72207265766965772e20417070726f766520696d706c656d656e746174696f6e3f' AS TEXT),
       'approve', 'pending', NULL, NULL
FROM graph_node n WHERE n.requirement_id = 'REQ-007' AND n.node_key = 'gate-plan';
INSERT INTO gate (node_id, prompt, kind, status, decision, decided_at)
SELECT n.id, CAST(x'46696e64696e677320616e6420627567732066726f6d205245512d30303720e2809420617070726f7665207768696368206765742072657061697265642e' AS TEXT),
       'select-findings', 'pending', NULL, NULL
FROM graph_node n WHERE n.requirement_id = 'REQ-007' AND n.node_key = 'gate-repairs';

INSERT INTO gate (node_id, prompt, kind, status, decision, decided_at)
SELECT n.id, CAST(x'52657061697220706c616e20666f72205245512d3030372069732072656164792e20417070726f766520696d706c656d656e746174696f6e3f' AS TEXT),
       'approve', 'pending', NULL, NULL
FROM graph_node n WHERE n.requirement_id = 'REQ-007' AND n.node_key = 'gate-repair-plan';

-- WHICH TEMPLATE BUILT THIS GRAPH. Not a column on graph_node, and without it there is
-- no baseline to diff a deviation against.
INSERT INTO guild_state (key, value) VALUES ('graph-template:REQ-007', 'standard');

COMMIT;
```

If the warehouse schema does not write an `event` row by trigger on `graph_node`, add one before
`COMMIT`:

```sql
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT datetime('now'), 'architect', 'instantiated', 'graph', 'REQ-007',
       json_object('template', 'standard',
                   'nodes', (SELECT COUNT(*) FROM graph_node WHERE requirement_id = 'REQ-007'));
```

Check first: `SELECT name, tbl_name FROM sqlite_schema WHERE type = 'trigger';`

---

## 7. Reading the graph back

**Readiness is a direct-predecessor join, not a traversal.** `WITH RECURSIVE` does not work on
tursodb — verified failing. It is not needed either: readiness propagates one node at a time as
the segment runs, so the transitive closure never has to be computed.

A node is ready when **no direct predecessor is unfinished** — a universal quantifier written as
a `NOT EXISTS`, vacuously true for a root node, which is correct.

```sql
-- what can run right now
SELECT n.id, n.node_key, COALESCE(n.parallel_group, '(serial)') AS batch,
       COALESCE(n.task_id, '(unbound)') AS task
FROM graph_node n
WHERE n.requirement_id = 'REQ-007'
  AND n.status = 'pending'
  AND NOT EXISTS (SELECT 1 FROM graph_edge ge
                   JOIN graph_node gp ON gp.id = ge.from_node
                  WHERE ge.to_node = n.id AND gp.status NOT IN ('done','skipped'))
ORDER BY batch, n.id;
```

`done` **and** `skipped` both count as finished. A node the architect deliberately skipped must
not hold its successors forever; that is the graph's spelling of `task.waived`.

The warehouse schema ships `v_ready_nodes` — **select from it instead of re-typing this
predicate.** Two spellings of readiness is two answers to "what runs next".

```sql
-- the segment: everything ready, grouped into waves, up to the next unresolved gate
SELECT COALESCE(n.parallel_group, '(serial)') AS batch, group_concat(n.id, ' ')
FROM graph_node n
WHERE n.requirement_id = 'REQ-007' AND n.status = 'pending'
  AND NOT EXISTS (SELECT 1 FROM graph_edge ge JOIN graph_node gp ON gp.id = ge.from_node
                  WHERE ge.to_node = n.id AND gp.status NOT IN ('done','skipped'))
GROUP BY 1;

-- the next unresolved gate
SELECT n.id, g.kind, g.status, g.prompt
FROM graph_node n JOIN gate g ON g.node_id = n.id
WHERE n.requirement_id = 'REQ-007' AND g.status = 'pending'
ORDER BY n.id LIMIT 1;
```

---

## 8. Validating a graph you deviated from

Run these after any deviation. Each returns **zero rows when the graph is sound**.

```sql
-- (a) a template key with no instance = a DROPPED node
WITH tpl(k, required) AS (VALUES
  ('gate-plan',1),('implement',1),('test-plan',0),('test-write',0),
  ('review',1),('gate-repairs',1),('repair',0))
SELECT 'DROPPED' || CASE WHEN tpl.required = 1 THEN ' (REQUIRED)' ELSE '' END || ': ' || tpl.k
FROM tpl
WHERE NOT EXISTS (SELECT 1 FROM graph_node n
                   WHERE n.requirement_id = 'REQ-007' AND n.node_key = tpl.k);

-- (b) a gate node whose key is not one of the template's = an ADDED GATE. Always a failure.
WITH tpl(k) AS (VALUES ('gate-plan'),('gate-repairs'))
SELECT 'ADDED GATE: ' || n.id
FROM graph_node n
WHERE n.requirement_id = 'REQ-007' AND n.kind = 'gate'
  AND n.node_key NOT IN (SELECT k FROM tpl);

-- (c) an add-gate deviation row. Also always a failure, however good the reason.
SELECT 'ADD-GATE DEVIATION: ' || node_key || ' — ' || reason
FROM graph_deviation WHERE requirement_id = 'REQ-007' AND kind = 'add-gate';

-- (d) a deviation with an empty or whitespace-only reason
SELECT 'EMPTY REASON: ' || kind || ' ' || node_key
FROM graph_deviation
WHERE requirement_id = 'REQ-007' AND trim(reason) = '';

-- (e) an edge that leaves the requirement, or a node with no path at all
SELECT 'CROSS-REQ EDGE: ' || e.from_node || ' -> ' || e.to_node
FROM graph_edge e
JOIN graph_node f ON f.id = e.from_node
JOIN graph_node t ON t.id = e.to_node
WHERE t.requirement_id = 'REQ-007' AND f.requirement_id <> t.requirement_id;
```

Before an `add-node` deviation, confirm the capability exists on an active member:

```sql
SELECT 'NO MEMBER FOR: ' || 'perf-profiling'
WHERE NOT EXISTS (SELECT 1 FROM agent_capability ac JOIN agent a ON a.name = ac.agent
                   WHERE ac.capability = 'perf-profiling' AND a.active = 1);
```

Node counts, as a sanity check against the numbers in §1:

```sql
SELECT (SELECT COUNT(*) FROM graph_node WHERE requirement_id = 'REQ-007') AS nodes,
       (SELECT COUNT(*) FROM graph_edge WHERE to_node LIKE 'REQ-007/%') AS edges,
       (SELECT COUNT(*) FROM graph_node WHERE requirement_id = 'REQ-007' AND kind = 'gate') AS gates;
```

`gates` must be **2**. Not one, not three.
