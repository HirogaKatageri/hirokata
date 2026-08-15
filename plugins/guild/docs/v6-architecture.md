# Guild v6 — Architecture

**Status:** current
**Supersedes:** [`v5-design.md`](./v5-design.md) — the CLI, not the model
**Breaking:** yes — v6.0.0

---

## 1. The pivot

v5 shipped a 31,348-line bash CLI. Every read and write to the board went through it, and it carried
the guild's rules in its functions: which task is next, when a review may close, whether a node is
ready, who is eligible for a ticket.

v6 deletes it. The decision, from the guild master:

> When the turso CLI is already installed, we have a tool that can execute SQL. We don't need to
> build another tool that does the same thing. Templates, tables, how to access things should be in
> markdown, part of the skills, as knowledge. We're giving our guild members the tool to access the
> library or guild warehouse, and a general guide on how to access it. It's up to them to decide how
> best to update and retrieve the information.

So `tursodb` **is** the tool. The plugin ships a schema and a body of knowledge, and nothing else
executable.

This is only sound if the rules stop living in the wrapper. They moved into the engine.

## 2. The warehouse

The metaphor is the point. The board is a **warehouse** the guild shares. `tursodb` is the key every
member already holds. `skills/warehouse/` is the guide posted at the door: what is stored where, how
to ask for it, and which shelves have rules attached.

A member is not handed a menu of permitted operations. It is handed a key and a map, and it decides
what to fetch and how. What keeps that from becoming chaos is that the shelves themselves enforce
their own rules — which is the next section.

```
skills/warehouse/
├── SKILL.md                        # connect, the six rules that are always true
└── references/
    ├── schema.md                   # what each table is FOR; enforced vs. conventional
    ├── queries.md                  # the canonical verified queries — copy, don't improvise
    ├── tursodb-gotchas.md          # the engine's sharp edges
    └── templates/                  # the execution templates, as knowledge
        ├── standard.md
        └── maintenance.md
```

## 3. What the database now enforces

`schema.sql` is 25 tables, 26 views and 43 triggers.

**CHECK constraints are the vocabularies.** Every status and enum column carries its word list. A
value outside it is rejected by the engine, on every connection, from every member, forever. v5's
Stage-3 schema deliberately left `task.status` unchecked so the vocabulary could widen without
rewriting the table — correct while a CLI policed the vocabulary in one function. With no CLI, an
unpoliced column is an unpoliced column, and a typo'd status is a task that vanishes from every view
at once. The cost flipped, so the CHECKs went in.

*The price is real:* SQLite cannot `ALTER` a CHECK in place. Widening a vocabulary means rebuilding
the table (create / copy / drop / rename, `foreign_keys` off for the swap). **Adding a word is a
migration.** Choose words you can live with.

**Views are the derived rules.** This is the load-bearing one. The cursor rule, the review gate, node
readiness, the agent matcher, the board and the brief each have exactly **one** definition, in
`schema.sql`. A member SELECTs from `v_next_task` rather than writing its own idea of "next", so two
members cannot get two answers to one question — and both look right when they disagree, which is
what makes divergence expensive.

**Triggers are the record.** Every meaningful mutation writes an `event` row and stamps `updated_at`
without anyone remembering to. There is no journal in v6; `event` is the record, and it lives in the
same database as everything else, which is why `guild.db` is the durable board rather than derived
state that can be rebuilt.

**A member can forget to call a command. A member cannot bypass a trigger or a CHECK.** That is the
whole argument for the pivot.

## 4. What is convention, not guarantee

The honest half. These were bash guards in v5. Nothing enforces them now — they are documented in
the `schema.sql` header, in `README.md`, and here, and nowhere else.

1. **"The orchestrator owns every status transition."** SQL has no identity. Any connection can run
   any `UPDATE`. `guild_state.actor` is a courtesy label a member sets on itself; the triggers copy
   it into `event.actor` verbatim. It is not authentication — **a lying actor produces a lying
   feed.** This is the single biggest thing v6 gave up.
2. **"A requirement may not close over a blocked task."** `v_requirement_progress.tasks_open` is the
   query that tells you. Closing anyway is one `UPDATE` away.
3. **"A `failed` task is adjudicated when it is waived."** The waiver is a *prefix* on a work-log
   line, matched with `LIKE`. A marker, not a column. A stray log line can look like one.
4. **"Plan slices touch disjoint files."** `plan_slice.files` is a JSON array. The disjointness is an
   assertion by the architect; nothing checks it.
5. **"A capability must be in the vocabulary."** A CHECK cannot reference another table, so an
   unknown capability inserts fine and matches nobody. `v_capability_unknown` reports them — read it
   when the matcher goes quiet.
6. **"A gate is decided by a human."** `gate.status` is a column. Anyone can write it.
7. **The graph is not acyclic by construction.** `graph_edge` accepts any pair, and a cycle makes
   `v_ready_nodes` return nothing for the whole loop — a silent stall, not an error. With no
   `WITH RECURSIVE` there is no way to detect one in SQL, so this is a review duty.
8. **Timestamps are UTC by convention.** The triggers use UTC. Hand-written values are whatever was
   written.

Where this document or any skill says a rule holds, check which list it is on.

## 5. Engine constraints

Verified against tursodb 0.7.2. Each of these shaped the schema.

- **No `WITH RECURSIVE`.** Readiness and dependency logic join **direct** predecessors only — one
  hop — and propagate as work completes. Never write a traversal.
- **No FTS5.** Text search is `LIKE`, with `%` and `_` escaped by the caller.
- **No `lag`/`lead`/`ntile`/`percent_rank`/`cume_dist`.** Ranking is an `ORDER BY`; the rank is the
  row's position, assigned by the reader (see `v_agent_match`).
- **STRICT** accepts only INT, INTEGER, REAL, TEXT, BLOB, ANY. Every column is TEXT or INTEGER.
- **Working:** STRICT, RETURNING, ON CONFLICT DO UPDATE, printf(), plain CTEs, WAL, foreign_keys,
  JSON functions, CHECK, VIEW, TRIGGER, `UPDATE OF <col>` triggers.

**The statement splitter.** tursodb ends a statement at a `;` that terminates a line — *even inside
an open string literal*. Requirement bodies quote code, so free text must cross as
`CAST(x'<hex>' AS TEXT)`, which is always one line. The hex must be valid UTF-8 (tursodb substitutes
U+FFFD for invalid bytes; sqlite3 preserves them). `schema.sql` itself contains no `;` inside a
string literal or at the end of a comment line, for exactly this reason — **preserve that property
when editing it.**

**Reading back.** `-m list` output is pipe-separated with no quoting, and free text contains pipes
*and newlines* — a newline forges a whole row. Ask for `json_object(...)`, or select one column.

## 6. Applying the schema

```bash
export PATH="$HOME/.turso:$PATH"
tursodb .guild/guild.db < "${CLAUDE_PLUGIN_ROOT}/schema.sql"
```

Idempotent, and **this is how a rule change reaches a live board.** Tables are `IF NOT EXISTS`, so
data survives. Views and triggers are dropped and recreated on every run — they hold no data, so
re-applying the file is the upgrade path for a corrected view or a new trigger. Seed rows are guarded
by `WHERE NOT EXISTS`.

One limit: `CREATE TABLE IF NOT EXISTS` sees an existing table and moves on. Applying this file over
a database created by an **earlier v5 stage** lands the views and triggers but **not** the CHECK
constraints. A board that wants them rebuilds.

## 7. File layout

```
plugins/guild/
├── schema.sql              # THE TOOL — tables, CHECKs, views, triggers, and the rules in its header
├── agents/                 # 14 members; frontmatter (name, model, capabilities, serial) IS the roster
├── skills/
│   ├── warehouse/          # the guide to the board — every member loads this first
│   ├── check-in/           # the orchestrator; references/ holds state-format & task-lifecycle
│   ├── shift/              # the unattended loop
│   ├── brief/ dashboard/ guild-status/
│   ├── new-requirement/ qa/ qa-mindset/ qa-artifacts/
│   ├── release/ clear-board/ comprehensive-review/ discuss/ verify-and-fix/ create-workflow/
│   └── svelte-*/           # specialist reference skills
└── docs/
    ├── v6-architecture.md  # this file
    └── v5-design.md        # historical; the model and rules it reasons out are still in force
```

The board, in a project:

```
.guild/
├── config.yaml         # committed. version + mode; env var NAMES only, never a credential
├── guild.db            # gitignored. THE BOARD — not derived, not rebuildable
├── docs/               # evergreen researcher knowledge
├── qa/                 # evergreen QA artifacts
├── reviews/REQ-NNN.md  # per-requirement review records
├── dashboard.html      # gitignored, regenerated wholesale
└── templates/*.yaml    # optional project override of the execution templates
```

`guild.db` is gitignored because a binary file is a bad thing to merge — which means **the board is
machine-local** unless the guild runs in cloud mode. What git carries is the human-readable residue:
`config.yaml`, `docs/`, `qa/`, `reviews/`, and the repo's `CHANGELOG.md`.

## 8. What did not change

Worth stating, because it bounds the blast radius. The data model, the ID scheme, the capability
matcher's ranking rule, the two-gate structure, the execution graph, the shift's policy and budget,
and the QA discipline are all exactly as reasoned out in `v5-design.md`. v6 changed **what enforces
them and who writes the SQL** — not what they are.

## 9. Status

v6 is a fresh rewrite and should be treated as one. The v5 CLI had four adversarial review rounds and
a 2,278-check suite; **that code is deleted and none of its assurance transfers.** No test suite
exists for v6, by explicit direction. `schema.sql` applies cleanly and idempotently, the engine
constraints above are observed facts, and individual queries were run as they were authored — but
nothing has exercised the guild end to end, and the conventions in §4 are precisely the kind of thing
a rewrite violates quietly.
