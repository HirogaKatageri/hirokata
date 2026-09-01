# The warehouse, room by room

Orientation, not DDL. The DDL is `${CLAUDE_PLUGIN_ROOT}/schema.sql` and it is heavily
commented — read it when you need the exact column list. Read *this* when you are deciding
**where a piece of information belongs** and **what you can rely on**.

Twenty-five tables. They fall into seven groups:

| Group | Tables |
|---|---|
| bookkeeping | `schema_version` · `guild_state` |
| direction | `goal` · `phase` |
| work | `requirement` · `plan` · `task` · `task_dependency` |
| roster | `agent` · `agent_capability` · `task_capability` · `capability_request` |
| execution graph | `graph_node` · `graph_edge` · `graph_deviation` · `gate` |
| records | `work_log` · `review_finding` · `bug` |
| maintenance & memory | `coverage` · `inspection` · `inspection_coverage` · `doc` · `event` |

The spine is one containment chain:

```
goal → phase → requirement → plan
                    ↓           ↓
                   task ────────┘
                    ↓
        work_log · review_finding · task_dependency · task_capability
```

Everything else hangs off `requirement` (the graph, capability requests) or off `task`
(the records), or stands alone and evergreen (`coverage`, `doc`, `agent`).

---

## Bookkeeping

**`schema_version`** — one row, `id = 1`. Only interesting when you are migrating.

**`guild_state`** — a tiny key/value store. Two keys matter and both are read by machinery:

- `last-checkin` — the timestamp of the last check-in. `v_brief` reports it; filter
  `v_recent_activity` against it to answer "what moved since I was last here".
- `actor` — **who is writing right now.** Every trigger copies this into `event.actor`.
  Set it at the top of your script. It is a courtesy label, not authentication.

---

## Direction — `goal`, `phase`

Long-lived intent. A `goal` is a direction; a `phase` is an ordered stage within one
(`ordinal`, 1-based). Both use the SHORT status vocabulary — `todo | in-progress | done` —
deliberately: `blocked` and `waived` are words about a unit of work, and a direction is not
a unit of work.

`priority` is 1 (highest) to 5 (lowest) everywhere it appears in this schema.

`v_goal_progress` gives you each open goal with its *current phase* — the lowest-ordinal
phase not yet done — and its requirement counts.

---

## Work — `requirement`, `plan`, `task`, `task_dependency`

**`requirement`** — the unit the guild master asks for. `body` holds the full REQ markdown.
`phase_id` is **nullable**: unaffiliated work is legal and normal.

**`plan`** — the architect's implementation plan for a requirement. `task_id` is optional
and means "a plan written FOR one ticket" rather than for the whole requirement.

There is no intermediate row between a plan and its tickets. The decomposition lands on the
tickets, and `task.files` carries the file set each one owns.

**`task`** — the ticket. The one table with a six-word status vocabulary, and each word buys
something specific:

| status | meaning |
|---|---|
| `todo` | not started. The only status `v_task_actionable` will offer. |
| `in-progress` | claimed and running. `v_next_task` resumes one of these before claiming anything new. |
| `done` | finished. |
| `failed` | an agent tried and could not — **and a human has already seen it**, because the orchestrator sets it and immediately asks retry-or-skip. Adjudicated, so it does NOT hold the review gate. |
| `blocked` | **nobody on the roster can take this.** Not a general "stuck" flag: it means the capability match found nobody. A machine verdict nobody has ruled on, so it DOES hold the review gate. |
| `waived` | deliberately skipped by a gate decision. Counts as finished for dependency purposes, exactly like `done`. |

The `failed` / `blocked` asymmetry in the review gate is the most load-bearing judgment in
the schema. Adjudicated work stops blocking; un-adjudicated work does not. A held gate is
loud — the blocked task sits on the board naming the capability nobody has.

Two agent columns, and they are different things:

- **`agent`** — the PIN, a member the architect named on the ticket. Optional. When set it
  wins the match outright, and the ticket is never reported as a roster gap.
- **`claimed_by`** — who actually took it, `REFERENCES agent(name)`. Set it with
  `claimed_at` when you claim.

`parallel_group` groups tickets that dispatch together (`v_batch`); `node_key` is the
back-reference to the template node that produced the ticket. **`files`** is a JSON array of
the paths this ticket owns, and **the disjointness of those sets across a `parallel_group` is
an assertion by the architect, not a constraint** — it is the promise that lets the group run
concurrently in one working tree, and nothing verifies it.

**`task_dependency`** — **direct predecessors only.** There is no transitive closure
anywhere in this schema and there must not be one: readiness propagates a hop at a time as
work completes, which is exactly why `WITH RECURSIVE` (unavailable on tursodb) is never
needed. Self-dependency is rejected by a CHECK.

---

## The roster — `agent`, `agent_capability`, `task_capability`, `capability_request`

Adding an agent file to `agents/` and INSERTing its name and capability tags is the entire
process of adding a guild member. `v_agent_match` does the rest.

**`agent`** — `name` is the primary key and the address. `serial = 1` means "never run
concurrently with itself" (the qa-tester drives one app and one dev server). **Retire with
`active = 0`, never DELETE**: a done task from months ago may name an agent whose file is
gone, and deleting would either break the foreign key or orphan the history that explains
the board.

**`agent_capability`** — what a member can do. A capability is compared for **equality and
never normalized**, so the alphabet is narrow on purpose (lowercase, digits, `-`) and the
CHECK enforces it. `e2e` and `E2E` would be two capabilities reading as one, and the matcher
would quietly stop working.

**`task_capability`** — what a ticket needs, and the `required` flag is the whole matcher:

- `required = 1` decides **eligibility** — an agent must cover every one of them.
- `required = 0` ("preferred") decides **rank only**. It never excludes anybody.

**`capability_request`** — a capability the architect needs and the roster lacks, filed at
plan time rather than discovered at dispatch time. `open → created | declined`. Filing one
is also what **legitimizes a new word**: `v_capability_vocabulary` unions in every
non-declined request, so the row that admits `rust` into the guild's language outlives the
recruitment. Never delete a `created` row — that un-admits the word on the next sync.

---

## The execution graph — `graph_node`, `graph_edge`, `graph_deviation`, `gate`

A requirement is instantiated into nodes and edges from a template
(`references/templates/{standard,maintenance}.md` in this skill), overridable per project at
`.guild/templates/*.yaml`.

**`graph_node`** — id is conventionally `REQ-001/implement.auth-service`. `kind` is `work`
or `gate`. Status is `pending | ready | running | done | failed | skipped`.

- `ready` is legal but optional — `v_ready_nodes` treats `pending` and `ready` identically
  as candidates, so the working loop is `pending → running → done`.
- **`done` and `skipped` both count as finished** for a successor's readiness. `skipped` is
  the graph's spelling of `waived`.

**`graph_edge`** — `from_node → to_node`, direct predecessors. Self-edges are rejected.

**`graph_deviation`** — any departure from the template, **with a reason**. `reason` is NOT
NULL and CHECKed non-empty, because the sentence in it is the whole value of the row.
`kind` is `add-node | drop-node | reshape | add-gate`.

**`gate`** — a graph node whose status a *human* writes. `kind = approve` is yes/no;
`kind = select-findings` carries the JSON selection in `decision` and the successors fan out
from it. **Setting `gate.status` does not move the node** — approving is two writes, the
gate row and then `graph_node.status`. `v_gates_pending` is what the orchestrator reads.

---

## Records — `work_log`, `review_finding`, `bug`

**`work_log`** — append-only, free text in `entry` (hex transport). **The orchestrator's
waiver lives here**, as an entry whose text *begins* `Skipped by user`. `v_failed_tasks`
reads it back as a `waived` flag and separately surfaces the agent's real `reason` (the most
recent entry that is not the waiver).

**`review_finding`** — one finding from one reviewer against one task. Severity
`critical | major | minor | nit`; disposition `open | fixing | fixed | waived`, with
`fix_task_id` linking the repair. `v_open_findings` gives you `open` + `fixing`, worst first.

**`bug`** — a defect against the product, not against a ticket. Severity is
`critical | major | minor` — **`nit` exists on findings and deliberately not here, because a
bug is not a nit.** Status `open | fixing | fixed | wontfix`. `found_by` may be an agent name
or `'user'`.

---

## Maintenance and memory — `coverage`, `inspection`, `inspection_coverage`, `doc`, `event`

**`coverage`** — what the product is made of, from a quality standpoint. **Evergreen**: it
survives releases and board resets. `risk` + `last_inspected_at` is what makes "what needs
looking at" a query (`v_coverage_due`: high stale at 14 days, medium at 30, low at 90)
rather than a judgment call. `spec_path` points at a committed e2e spec if one exists.

**`inspection`** / **`inspection_coverage`** — one turn of the maintenance cycle and its
per-area verdicts. `verdict` is NULL until the area is actually reached; **`not-reached` is
the honest answer for an area the inspection meant to cover and ran out of road before it
did — it is not NULL and it is not a pass.** `inspection."trigger"` is the one enum left
open on purpose (today only `'manual'`), so a cadence can be added later without rebuilding
the table.

**`doc`** — the library. Long-lived knowledge the guild looked up once and should not look
up again. Keyed by `slug`. **Search it with `LIKE`** — there is no FTS5 — and escape `%`
and `_` in the query (see `queries.md`).

**`event`** — the guild's memory, **written by triggers**. You do not normally INSERT here
by hand, and you never UPDATE or DELETE: a memory you can edit is not one. `subject_type` is
the subject's *table name*, which is what lets `v_recent_activity` resolve a title for it.
`verb` is deliberately not CHECKed — new machinery invents new verbs, and an event that
cannot be written is worse than an unfamiliar one. Payload is JSON; a status change is
`{"from":…,"to":…}`.

---

# What the database actually enforces

**CHECK constraints — rejected by the engine, on every connection, from every member.**

- Every status/severity/disposition/kind/risk/verdict vocabulary listed above. A typo'd
  status is refused rather than silently disappearing from every view at once.
- `priority BETWEEN 1 AND 5`; `active`/`serial`/`required` are 0 or 1.
- The capability **alphabet**: lowercase letters, digits, `-`, 1–64 chars, starting with a
  letter.
- `json_valid()` on `task.files` and `event.payload`.
- `graph_deviation.reason` is non-empty; `task_dependency` and `graph_edge` reject
  self-reference; `schema_version.id = 1`.

**Foreign keys** — but only when you issue `PRAGMA foreign_keys = ON` on that connection.

**Triggers** — every meaningful mutation writes an `event` row and `updated_at` gets
stamped. You cannot forget to. Deliberately *not* instrumented: capability rows (a roster
sync rewrites them all and would bury the feed), `graph_node` inserts (only status changes
mean something moved), and pure-structure tables (`graph_edge`, `task_dependency`,
`inspection_coverage`).

**Views** — one definition per rule. Read them instead of rewriting them.

# What is NOT enforced — conventions you have to honor yourself

Do not tell yourself otherwise. Each of these was a bash guard in the old CLI and is now a
convention:

1. **"The orchestrator owns every status transition."** SQL has no identity. Any connection
   can run any UPDATE. `guild_state.actor` is a label the triggers copy verbatim; a lying
   actor produces a lying feed.
2. **"A requirement may not close over a blocked task."** No constraint expresses it.
   `v_requirement_progress.tasks_open` is the query that tells you. Closing anyway is one
   UPDATE away.
3. **The `failed`-task waiver is a work-log line's PREFIX**, matched with `LIKE`. It is a
   marker, not a column. Nothing stops a stray log line from looking like one — though the
   waiver is only ever consulted for a ticket already at `failed`.
4. **Concurrently dispatched tickets touch disjoint files.** An assertion in `task.files`. Nothing checks
   it.
5. **A capability must be in the vocabulary.** A CHECK cannot reference another table, so an
   unknown capability inserts fine and simply **matches nobody, silently, forever**.
   `v_capability_unknown` is the audit — run it when the matcher goes unexpectedly quiet.
6. **A gate is decided by a human.** `gate.status` is a column. Anyone can write it.
7. **The graph is not acyclic by construction.** `graph_edge` accepts any pair, and a cycle
   makes `v_ready_nodes` return nothing for the whole loop — a *silent stall*, not an error.
   With no `WITH RECURSIVE` there is no traversal to detect one, so guarantee acyclicity at
   **write** time: require every `after:` reference to name a node declared earlier in the
   template. Edges that all point backwards in declaration order cannot form a cycle.
8. **Timestamps are UTC by convention.** The triggers use `strftime(…, 'now')`, which is
   UTC. Whatever you write by hand is whatever you wrote.

# The views, and which question each answers

| View | Question |
|---|---|
| `v_task_who` | Who is this ticket waiting on, or what capability is it waiting for? Never blank. |
| `v_task_deps` · `v_task_blockers` | Which direct predecessors are unfinished? (`done` and `waived` count as finished.) |
| `v_task_actionable` | Which `todo` tasks may be offered right now — **including the review gate**. |
| `v_next_task` | **The cursor.** Zero or one row: resume the lowest-id `in-progress`, else claim the lowest-id actionable. Ignores dependencies and eligibility on purpose. |
| `v_batch` | Which open tasks must dispatch together with this one? |
| `v_agent_eligible` | Whose capabilities are a superset of this ticket's required set? |
| `v_agent_match` | **The matcher.** Every candidate, already ranked — the rank IS the row's position. |
| `v_task_top_agent` | Rank 1 as one row per task; `''` when nobody is eligible. |
| `v_open_bounties` | **What can be dispatched right now**: actionable + no unfinished deps + somebody to give it to. |
| `v_blocked_tasks` | Everything open that cannot move, and why (`status-blocked` / `deps:…` / `no-eligible-agent:…`). |
| `v_ready_nodes` | Which graph nodes have all direct predecessors finished? |
| `v_gates_pending` | Which gates are waiting on a human *right now*? |
| `v_board` | The live board, one row per task, tagged with its section and print order. |
| `v_requirement_progress` · `v_goal_progress` | The roll-ups. |
| `v_in_flight` · `v_failed_tasks` · `v_open_findings` · `v_open_bugs` · `v_recent_activity` | The briefing's detail lists. |
| `v_coverage_due` | Which quality areas are past their risk-weighted interval? |
| `v_capability_vocabulary` · `v_capability_unknown` · `v_roster_gaps` | The roster audits. |
| `v_brief` | **The standup**, one fact per row, all derived from the views above so a count and its listing cannot disagree. |

Two pairs that look interchangeable and are not:

- **`v_next_task` vs `v_open_bounties`.** The cursor answers "where was I" — id order, review
  gate applied, dependencies and eligibility deliberately *not* checked. The bounty board
  answers "what can I hand out" — priority order, dependencies and a matched member
  required. Different questions, different views.
- **`v_agent_match` vs `v_task_top_agent`.** The same branch order on purpose. If they
  disagreed, one view would name a member and the other would name somebody else for the
  same ticket.

**Restate the `ORDER BY` yourself if you wrap a view in another query.** A view's internal
ordering is not a contract SQLite promises to preserve through a join.
