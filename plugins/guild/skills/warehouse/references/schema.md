# The warehouse, room by room

Orientation, not DDL. The DDL is `${CLAUDE_PLUGIN_ROOT}/schema.sql` and it is heavily
commented — read it when you need the exact column list. Read *this* when you are deciding
**where a piece of information belongs** and **what you can rely on**.

Twenty-three tables. They fall into seven groups:

| Group | Tables |
|---|---|
| bookkeeping | `schema_version` · `guild_state` |
| direction | `goal` · `project` |
| work | `requirement` · `plan` · `task` · `task_dependency` · `task_capability` |
| execution graph | `graph_node` · `graph_edge` · `graph_deviation` · `gate` |
| records | `work_log` · `review_finding` · `bug` |
| maintenance | `coverage` · `inspection` · `inspection_coverage` |
| library & memory | `doc` · `knowledge_edge` · `doc_revision` · `event` |

The spine is one containment chain:

```
goal → project → requirement → plan
                       ↓           ↓
                      task ────────┘
                    ↓
        work_log · review_finding · task_dependency · task_capability
```

Everything else hangs off `requirement` (the graph) or off `task` (the records), or stands
alone and evergreen (`coverage`, `doc`).

**The library is the one thing that crosses the spine rather than hanging off it.** A
`knowledge_edge` may point at *any* row above — a requirement, a plan, a task, a bug — which
is what makes the documentation a graph *over the work* instead of a second database beside
it. Most of its nodes are rows that already exist; the edges are what make it a graph.

**THE ROSTER IS NOT IN HERE.** Who the guild's members are and what each can do lives in the
`capabilities:` frontmatter of the agent files, and the orchestrator reads it at dispatch
time across every subagent available to the user. See *Where the roster went*, below.

---

## Bookkeeping

**`schema_version`** — one row, `id = 1`. Only interesting when you are migrating.

**`guild_state`** — a tiny key/value store. Two keys matter and both are read by machinery:

- `last-checkin` — the timestamp of the last check-in. `v_brief` reports it; filter
  `v_recent_activity` against it to answer "what moved since I was last here".
- `actor` — **who is writing right now.** Every trigger copies this into `event.actor`.
  Set it at the top of your script. It is a courtesy label, not authentication.

---

## Direction — `goal`, `project`

Long-lived intent. A `goal` is a high-level target; a `project` is a named group of work
that has to be done to reach it. Both use the SHORT status vocabulary —
`todo | in-progress | done` — deliberately: `blocked` and `waived` are words about a unit
of work, and a direction is not a unit of work.

`priority` is 1 (highest) to 5 (lowest) everywhere it appears in this schema, `project`
included.

**A project is not a *stage*.** A stage implies one runs at a time; a project may run
**beside** its siblings:

| column | what it decides |
|---|---|
| `ordinal` | position in the goal's sequence, 1-based, and **nullable**. NULL means *unordered* — waits for nobody. It does not mean *first*. |
| `concurrent` | `1` = never waits its turn, runs beside its siblings. `0` (the default) = waits for every lower-ordinal sequential project in the goal. |
| `isolation` | `shared` = tasks run in the repository's working tree. `worktree` = tasks run in their own git worktree, so cross-project file collisions are impossible. |
| `worktree_path` | the checkout. NULL until one exists, so a project can be *marked* for isolation before it is cut. A `shared` project may not carry one — a CHECK says so. |

Nothing creates, verifies or cleans up a worktree. The column records a decision; honouring
it is the orchestrator's job.

**`v_projects_runnable` is the only place the parallelism rule lives.** Read it instead of
re-deriving "may this project run" — a project earns a place there by being `concurrent`,
by being unordered, or by having every lower-ordinal sequential sibling done.
`v_project_progress` is the same list with requirement and task counters, and a `runnable`
flag derived from that view rather than restated.

`v_goal_progress` gives each open goal its project counts, how many are runnable, and a
comma-joined `runnable_project_ids` for display. It reports no single *current* project,
because several projects under one goal may be in flight at once. Join
`v_projects_runnable` on `goal_id` when you need the rows.

---

## Work — `requirement`, `plan`, `task`, `task_dependency`, `task_capability`

**`requirement`** — the unit the guild master asks for. `body` holds the full REQ markdown.
`project_id` is **nullable**: unaffiliated work is legal and normal.

**`plan`** — the architect's implementation plan for a requirement. `task_id` is optional
and means "a plan written FOR one ticket" rather than for the whole requirement.

A plan carries **two independent states**, and conflating them was the old shape's worst
loss of information:

| column | question it answers |
|---|---|
| `status` | *is the document written?* `todo → in-progress → done`. The architect's drafting lifecycle. It says nothing about whether anybody agreed. |
| `approval` | *did the user say yes?* `pending → approved \| rejected`. The architect writes the plan; a **human** rules on it, and nothing is built until they do. |

`approved_by` and `approved_at` record the ruling. `gate_node_id` links the plan to the
`gate-plan` node carrying the same decision, so a reader can go from either end — but
approving the gate does **not** write `plan.approval`. They are two writes, exactly like
moving a gate's node, and `v_plans_pending_approval` is what tells you they drifted.

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
| `blocked` | **nobody available can take this.** Not a general "stuck" flag: it means the dispatcher scanned the agent files and found nobody covering the required capabilities. A machine verdict nobody has ruled on, so it DOES hold the review gate. **No view derives it** — the dispatcher writes it, or the gap stays invisible. |
| `waived` | deliberately skipped by a gate decision. Counts as finished for dependency purposes, exactly like `done`. |

The `failed` / `blocked` asymmetry in the review gate is the most load-bearing judgment in
the schema. Adjudicated work stops blocking; un-adjudicated work does not. A held gate is
loud — the blocked task sits on the board naming the capability nobody has.

Two agent columns, and they are different things:

- **`agent`** — the PIN, a member the architect named on the ticket, by the `name` in that
  agent's frontmatter. Optional. When set, the dispatcher spawns it and **does not run the
  capability match at all**.
- **`claimed_by`** — who actually took it. Set it with `claimed_at` when you claim.

Neither is a foreign key, and neither can be: there is no table to point at. A name whose
agent file is long gone still reads correctly on an old ticket, which is the point.

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

## Where the roster is — and `task_capability`, which is in here

**The database holds exactly one capability table: `task_capability`.** There is no `agent`
table and no `agent_capability` table, because they would be a **mirror**. Every fact they
would hold — the member's name, model, capabilities, whether it runs serially — is already
declared in the frontmatter of the member's own markdown file:

```yaml
---
name: developer-svelte
model: sonnet
capabilities: [implement, frontend, svelte, sveltekit]
serial: false
---
```

Two copies of one truth is one copy too many, and **the SQL copy was the one that went
stale**: it was only as fresh as the last sync somebody ran, so a new agent file was
invisible to the matcher until then. Worse, the mirror could only ever see the plugin's own
`agents/` directory, while the user has subagents from their project, their home directory
and every other installed plugin.

`capability_request` existed to admit a word to a vocabulary this database owned. Once the
vocabulary is just "what the agent files declare", **admitting a word is writing the file**,
and a request row is bookkeeping about bookkeeping.

**Read the roster with:**

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py"
python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py" --covers implement,svelte
```

The scan is authoritative for *what a file declares*. It is **not** authoritative for what is
spawnable — the session's own agent-type list is. When they disagree, the session wins.

**`task_capability`** — the survivor, and the one that was never a mirror. It records what
the **work** needs, which is board data and belongs here:

- `required = 1` decides **eligibility** — a member must cover every one of them.
- `required = 0` ("preferred") decides **rank only**. It never excludes anybody.

A capability is compared for **equality and never normalized**, so the alphabet is narrow on
purpose (lowercase, digits, `-`) and a CHECK enforces it. `e2e` and `E2E` would be two
capabilities reading as one, and the match would quietly stop working. The **vocabulary** —
which words mean anything — is the union of what the agent files declare, and no CHECK can
reach a directory of markdown, so a misspelled tag inserts fine and matches nobody.

**The matching rule did not die, it moved.** The dispatcher applies it (check-in §3.3):

1. `task.agent` set → spawn it, no match.
2. Otherwise, eligible = frontmatter `capabilities` ⊇ the ticket's required set. Rank by
   preferred covered DESC, then **fewest declared capabilities ASC** (a specialist beats a
   generalist), then name ASC for determinism.
3. Nobody → the dispatcher **writes** `status = 'blocked'`. That write is the only thing
   that makes the gap visible; skip it and `v_open_bounties` offers the ticket forever.

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

## Maintenance — `coverage`, `inspection`, `inspection_coverage`

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

## The library — `doc`, `knowledge_edge`, `doc_revision`

**Evergreen**, like `coverage`: it survives releases and board resets, because a decision does
not stop being true when the ticket that caused it ships.

**`doc`** — the nodes. One row per topic, keyed by `slug`. Two columns decide how every reader
treats it:

| `kind` | what belongs there |
|---|---|
| `business` | the domain's own rules. What a refund *is*, when an account is dormant, which invariants the product promises. Most likely to outlive the code that implements it. |
| `technical` | how a subsystem works **right now**. |
| `decision` | **an ADR** — one choice, its context, alternatives, consequences. |
| `research` | an external lookup the guild should not have to repeat. |
| `runbook` | the steps for an operation somebody performs. |
| `reference` | everything else. The default, and deliberately boring. |

| `status` | prose | a decision |
|---|---|---|
| `draft` | being written | **proposed** |
| `current` | live | **accepted** |
| `superseded` | replaced — **the row stays** | replaced |
| `rejected` | declined — **the row stays** | declined |

**Superseded and rejected rows are never deleted.** They are how the project's evolution is
read, and the decisions a project did *not* take are half of why it looks the way it does.
`v_doc_current` is what keeps them out of ordinary reads.

`area` ('auth', 'billing') is a free key and deliberately **not** CHECKed — a vocabulary you
have to migrate to add a subsystem is a vocabulary people route around. Overlap it with
`coverage.id` where it makes sense.

**`knowledge_edge`** — the relations. One row is one assertion: `<from> --rel--> <to>`, with an
optional `note` saying why. Eight relations, closed by CHECK: `describes` and `decides`
(doc → work), `supersedes` / `refines` / `depends-on` / `contradicts` (doc → doc),
`derived-from` (doc → anything, provenance) and `evidence-for` (anything → doc).

**Its endpoints are polymorphic, so there is no foreign key on either end** — SQLite cannot
`REFERENCES` a table chosen at runtime. Two things stand in, and *neither* is the engine
refusing a bad write: the write-time check (`INSERT … SELECT … FROM <target> WHERE id = …`,
so a missing endpoint yields zero rows) and `v_knowledge_dangling`, which is a **global
invariant** `guild:validate` runs. The rel/type *pairings* are real CHECKs, though —
`supersedes` between two non-docs is refused.

**`doc_revision`** — the history, **written by a trigger** on every body change. Append-only,
treated like `event`: never INSERT by hand, never UPDATE, never DELETE. It stores the **old**
body, so the newest revision row is the text that came *before* the live one — the single
mistake this table invites. It has **no foreign key to `doc` on purpose**: a revision must
survive its document being deleted, or it is not history.

**A decision does not live in `plan.body` prose or in `gate.decision` JSON.** Both are
attached to a ticket and both go quiet when the ticket closes, which is what makes "why is it
like this" an expensive question. It is `SELECT * FROM v_decision_log` instead.

## Memory — `event`

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
- The capability **alphabet** on `task_capability`: lowercase letters, digits, `-`, 1–64
  chars, starting with a letter. The *vocabulary* it belongs to is not enforceable here.
- `json_valid()` on `task.files` and `event.payload`.
- `graph_deviation.reason` is non-empty; `task_dependency` and `graph_edge` reject
  self-reference; `schema_version.id = 1`.
- **The `knowledge_edge` rel/type pairings.** `supersedes`, `refines`, `depends-on` and
  `contradicts` must be doc → doc; `describes`, `decides` and `derived-from` must start at a
  doc; `evidence-for` must end at one. A self-edge is refused. So is a duplicate — the
  `UNIQUE (rel, from_type, from_id, to_type, to_id)` means asserting the same thing twice is
  one row. What is **not** checked is whether the endpoints exist: see item 11 below.

**Foreign keys** — but only when you issue `PRAGMA foreign_keys = ON` on that connection.

**Triggers** — every meaningful mutation writes an `event` row and `updated_at` gets
stamped. You cannot forget to. **`doc_revision` is written the same way**: `trg_doc_revised`
snapshots the old body on every body change, so documentation history needs no discipline
from anybody. `knowledge_edge` is instrumented on INSERT *and* DELETE — unlike `graph_edge`,
it is not structure but an assertion somebody made, and retracting one is as much a decision
as making it. Deliberately *not* instrumented: `task_capability` (the
architect rewrites a ticket's whole set at once and it would bury the feed), `graph_node` inserts (only status changes
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
5. **A ticket's capabilities name something a real agent declares.** The vocabulary is the
   agent files, so SQL cannot check a `task_capability` row against it at all — a misspelled
   tag inserts fine and matches nobody. **There is no audit view**: the dispatcher
   is what makes it speak, by writing the ticket to `blocked` when the scan finds nobody.
   Skip that write and the gap is silent. `roster.py --covers` before writing the ticket is
   the check that catches it early.
6. **A gate is decided by a human.** `gate.status` is a column. Anyone can write it.
7. **The graph is not acyclic by construction.** `graph_edge` accepts any pair, and a cycle
   makes `v_ready_nodes` return nothing for the whole loop — a *silent stall*, not an error.
   With no `WITH RECURSIVE` there is no traversal to detect one, so guarantee acyclicity at
   **write** time: require every `after:` reference to name a node declared earlier in the
   template. Edges that all point backwards in declaration order cannot form a cycle.
8. **Timestamps are UTC by convention.** The triggers use `strftime(…, 'now')`, which is
   UTC. Whatever you write by hand is whatever you wrote.
9. **A `worktree` project's tasks run in its worktree.** `project.worktree_path` is a
   string. Nothing creates the checkout, nothing verifies it exists, and nothing makes a
   dispatched agent honour it. The CHECK only stops a `shared` project from carrying a
   path — which is the half a column *can* police.
10. **An approved gate approves its plan.** `gate.status` and `plan.approval` are two
    columns on two tables, so approving a plan is **two writes**, exactly like moving a
    gate's node. `plan.gate_node_id` ties them for a reader; it does not keep them in
    step. `v_plans_pending_approval` is what tells you they drifted.
11. **Every `knowledge_edge` points at something that exists.** Its endpoints are
    polymorphic, so there is no foreign key on either end. Write the edge as
    `INSERT … SELECT … FROM <target> WHERE id = …` (zero rows instead of a dangling edge),
    and read **`v_knowledge_dangling`**, which must always be empty and which
    `guild:validate` runs. Deleting a requirement silently orphans its edges.
12. **A document describes the code as it is now.** Nothing can know that. `v_doc_stale` is
    the honest approximation — a doc whose subject has an `event` newer than the doc's own
    `updated_at`. It catches "the work moved and nobody revisited the page" and misses "the
    code changed under a doc nobody linked", which is why `v_undocumented_work` and
    `v_doc_current WHERE edges = 0` exist beside it.

# The views, and which question each answers

| View | Question |
|---|---|
| `v_task_who` | Who is this ticket waiting on, or what capability is it waiting for? Never blank. |
| `v_task_deps` · `v_task_blockers` | Which direct predecessors are unfinished? (`done` and `waived` count as finished.) |
| `v_task_actionable` | Which `todo` tasks may be offered right now — **including the review gate**. |
| `v_next_task` | **The cursor.** Zero or one row: resume the lowest-id `in-progress`, else claim the lowest-id actionable. Ignores dependencies and eligibility on purpose. |
| `v_batch` | Which open tasks must dispatch together with this one? |
| `v_open_bounties` | **What is ready to be matched**: actionable + no unfinished deps + a pin or at least one capability row. Not a promise anybody can take it. |
| `v_blocked_tasks` | Everything open that cannot move, and why (`status-blocked` / `deps:…` / `unassigned`). |
| `v_ready_nodes` | Which graph nodes have all direct predecessors finished? |
| `v_gates_pending` | Which gates are waiting on a human *right now*? |
| `v_plans_pending_approval` | Which drafted plans has nobody ruled on yet? (A `todo` plan is still being written, so it is not listed.) |
| `v_board` | The live board, one row per task, tagged with its section and print order. |
| `v_projects_runnable` | **The parallelism rule.** Which projects may run right now, and why (`concurrent` / `unordered` / `next in sequence`), with their `isolation` and worktree. |
| `v_project_progress` | Every project with its requirement and task counters, plus a `runnable` flag derived from the view above. |
| `v_requirement_progress` · `v_goal_progress` | The roll-ups. |
| `v_in_flight` · `v_failed_tasks` · `v_open_findings` · `v_open_bugs` · `v_recent_activity` | The briefing's detail lists. |
| `v_coverage_due` | Which quality areas are past their risk-weighted interval? |
| `v_knowledge_ref` | Every row an edge may point at, with its title. The helper the library's views stand on. |
| `v_doc_current` | The library as it stands — nothing superseded, nothing rejected — with each page's revision and edge counts. |
| `v_doc_neighbors` | What does this page relate to, **one hop**, both directions, with titles resolved? |
| `v_doc_stale` | **Which pages went stale** because something they describe has moved since? One row per (page, subject). |
| `v_undocumented_work` | Which finished requirements has nobody documented? |
| `v_decision_log` | What did this project decide, in order, **including what it un-decided**? |
| `v_knowledge_dangling` | **A global invariant.** Which edges point at something that no longer exists? Must be empty. |
| `v_brief` | **The standup**, one fact per row, all derived from the views above so a count and its listing cannot disagree. |

Two pairs that look interchangeable and are not:

- **`v_next_task` vs `v_open_bounties`.** The cursor answers "where was I" — id order, review
  gate applied, dependencies and eligibility deliberately *not* checked. The bounty board
  answers "what can I hand out" — priority order, dependencies and a matched member
  required. Different questions, different views.
- **`v_open_bounties` vs "can anybody take it".** The bounty board says a ticket ASKS for
  somebody — a pin, or at least one capability row. Whether anybody ANSWERS is settled by
  the dispatcher against the agent files, and a ticket nobody covers appears here once
  before it is written to `blocked`.

**Restate the `ORDER BY` yourself if you wrap a view in another query.** A view's internal
ordering is not a contract SQLite promises to preserve through a join.
