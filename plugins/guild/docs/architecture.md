# Guild — Architecture

**Status:** current
**Companion to:** [`expectations.md`](./expectations.md) (the spec), [`../schema.sql`](../schema.sql) (the tool)
**Background:** [`v5-design.md`](./v5-design.md) records how the data model and its rules were reasoned out

---

## 1. The schema is the tool

`tursodb` already executes SQL, so the plugin does not ship a program that executes SQL for it.
It ships a schema and a body of knowledge:

> Templates, tables, how to access things should be in markdown, part of the skills, as knowledge.
> We're giving our guild members the tool to access the library or guild warehouse, and a general
> guide on how to access it. It's up to them to decide how best to update and retrieve the
> information.
>
> — the guild master

That is only sound if the rules live in the engine rather than in a wrapper, which is what §3
is about.

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

## 3. What the database enforces

`schema.sql` is 23 tables, 30 views and 44 triggers, at `schema_version = 8`.

**CHECK constraints are the vocabularies.** Every status and enum column carries its word list. A
value outside it is rejected by the engine, on every connection, from every member, forever. An
unpoliced status column is one where a typo makes a task vanish from every view at once, which is
why every one of them is checked.

*The price is real:* SQLite cannot `ALTER` a CHECK in place. Widening a vocabulary means rebuilding
the table (create / copy / drop / rename, `foreign_keys` off for the swap). **Adding a word is a
migration.** Choose words you can live with.

**Views are the derived rules.** This is the load-bearing one. The cursor rule, the review gate, node
readiness, the board and the brief each have exactly **one** definition, in `schema.sql`. A member
SELECTs from `v_next_task` rather than writing its own idea of "next", so two members cannot get two
answers to one question — and both look right when they disagree, which is what makes divergence
expensive.

**Triggers are the record.** Every meaningful mutation writes an `event` row and stamps `updated_at`
without anyone remembering to. There is no journal; `event` is the record, and it lives in the same
database as everything else, which is why `guild.db` is the durable board rather than derived state
that can be rebuilt.

**A member can forget to call a command. A member cannot bypass a trigger or a CHECK.** That is the
whole argument for putting the rules in the engine.

## 4. What is convention, not guarantee

The honest half. Nothing enforces these — they are documented in the `schema.sql` header, in
`README.md`, and here, and nowhere else.

1. **"The orchestrator owns every status transition."** SQL has no identity. Any connection can run
   any `UPDATE`. `guild_state.actor` is a courtesy label a member sets on itself; the triggers copy
   it into `event.actor` verbatim. It is not authentication — **a lying actor produces a lying
   feed.** This is the single biggest thing the engine cannot hold.
2. **"A requirement may not close over a blocked task."** `v_requirement_progress.tasks_open` is the
   query that tells you. Closing anyway is one `UPDATE` away.
3. **"A `failed` task is adjudicated when it is waived."** The waiver is a *prefix* on a work-log
   line, matched with `LIKE`. A marker, not a column. A stray log line can look like one.
4. **"Concurrently dispatched tickets touch disjoint files."** `task.files` is a JSON array. The
   disjointness across a `parallel_group` is an assertion by the architect; nothing checks it.
5. **"A ticket's capabilities name something a real agent declares."** The vocabulary is the agent
   files, so no SQL check can reach it at all — an unknown capability inserts fine and matches
   nobody. The dispatcher makes it speak by writing the ticket `blocked`; skip that write and the
   gap is silent.
6. **"A gate is decided by a human."** `gate.status` is a column. Anyone can write it.
7. **The graph is not acyclic by construction.** `graph_edge` accepts any pair, and a cycle makes
   `v_ready_nodes` return nothing for the whole loop — a silent stall, not an error. With no
   `WITH RECURSIVE` there is no way to detect one in SQL, so this is a review duty.
8. **Timestamps are UTC by convention.** The triggers use UTC. Hand-written values are whatever was
   written.
9. **"Every `knowledge_edge` points at something that exists."** Its endpoints are polymorphic, so
   there is no foreign key on either end and **G1 cannot cover them**. The write-time shape stops
   you *creating* a dangling edge; nothing stops you creating one by deleting the other end later.
   **G10** is the assertion that stands in. Nothing in the guild deletes at all (**G11**), so a
   dangling edge means somebody wrote raw SQL.
10. **"A document describes the code as it is now."** Nothing can know that. `v_doc_stale` is the
    honest approximation — a page whose subject has an `event` newer than the page — and it is a
    *signal*, never an invariant. A stale page is not a breach.

Where this document or any skill says a rule holds, check which list it is on.

**These ten are exactly what `docs/expectations.md` asserts.** A rule the engine enforces needs
no assertion — a bad status word is rejected by a CHECK on every connection, forever, and spending
an expectation on it buys nothing. The ten above are the ones nothing enforces at all, so each is
carried instead by a SQL assertion with a stated expected result: G6 catches the requirement closed
over an open task, G5 the capability outside the vocabulary, G4 the gate approved without the node
moved, G7 the mutation that wrote around the triggers. Items 1 and 7 — the lying actor and the long
cycle — cannot be asserted by anyone in SQL, and both are named as such rather than papered over.

## 5. Engine constraints

Verified against tursodb 0.7.2. Each of these shaped the schema.

- **No `WITH RECURSIVE`.** Readiness and dependency logic join **direct** predecessors only — one
  hop — and propagate as work completes. Never write a traversal.
- **No FTS5.** Text search is `LIKE`, with `%` and `_` escaped by the caller. This is also why the
  library filters on `kind` and `area` before it searches at all — a column lookup beats a scan,
  and "what are the business rules for billing" never needed a text search.
- **No `lag`/`lead`/`ntile`/`percent_rank`/`cume_dist`.** Ranking is an `ORDER BY`; the rank is the
  row's position, assigned by the reader (see `v_open_bounties`).
- **STRICT** accepts only INT, INTEGER, REAL, TEXT, BLOB, ANY. Every column is TEXT or INTEGER.
- **Working:** STRICT, RETURNING, ON CONFLICT DO UPDATE, printf(), plain CTEs, WAL, foreign_keys,
  JSON functions, CHECK, VIEW, TRIGGER, `UPDATE OF <col>` triggers, `group_concat(col, sep)`, a
  `LEFT JOIN` onto a view, a correlated `NOT EXISTS` against a view built from `UNION ALL`, and
  `AFTER DELETE` triggers.
- **No polymorphic foreign key**, which is not a tursodb limitation but a SQLite one: `REFERENCES`
  names a table at declaration time. `knowledge_edge` endpoints may be a doc, a requirement, a task
  or a bug, so the constraint is replaced by a write-time shape
  (`INSERT … SELECT … FROM <target> WHERE id = …`, where a missing endpoint yields zero rows) and by
  `v_knowledge_dangling`, asserted as global invariant **G10**. The rel/type *pairings* are still
  real CHECKs — `supersedes` between two non-docs is refused.

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
a board whose tables predate a CHECK constraint lands the views and triggers but **not** that
constraint. A board that wants it rebuilds.

## 7. File layout

```
plugins/guild/
├── schema.sql              # THE TOOL — tables, CHECKs, views, triggers, and the rules in its header
├── migrations/             # one-shot scripts for what CREATE TABLE IF NOT EXISTS cannot reach:
│                           # renamed tables and new columns. Run in order, once each, then re-apply schema.sql
├── agents/                 # 15 members; frontmatter (name, model, capabilities, serial) IS the roster
├── skills/
│   ├── warehouse/          # the guide to the board — every member loads this first
│   ├── validate/           # runs docs/expectations.md against the live board
│   ├── check-in/           # the orchestrator; references/ holds state-format & task-lifecycle
│   ├── shift/              # the unattended loop
│   ├── brief/ dashboard/
│   ├── new-requirement/ qa/ qa-mindset/ qa-artifacts/
│   ├── release/ comprehensive-review/ discuss/ verify-and-fix/ create-workflow/
│   └── svelte-*/           # specialist reference skills
└── docs/
    ├── architecture.md           # this file
    ├── expectations.md           # THE SPEC a member's work is checked against — SQL assertions
    ├── expectations-fixtures.md  # the six known board states those assertions are run against
    └── v5-design.md              # how the data model and its rules were reasoned out
```

The board, in a repository:

```
.guild/
├── config.yaml         # committed. version + mode; env var NAMES only, never a credential
├── guild.db            # gitignored. THE BOARD — not derived, not rebuildable
├── docs/               # evergreen researcher knowledge
├── qa/                 # evergreen QA artifacts
├── reviews/REQ-NNN.md  # per-requirement review records
├── dashboard.html      # gitignored, regenerated wholesale
└── templates/*.yaml    # optional per-repo override of the execution templates
```

`guild.db` is gitignored because a binary file is a bad thing to merge — which means **the board is
machine-local** unless the guild runs in cloud mode. What git carries is the human-readable residue:
`config.yaml`, `docs/`, `qa/`, `reviews/`, and the repo's `CHANGELOG.md`.

## 8. Validation: not testing code, validating behavior

**There is no code here to unit-test.** Every rule is a CHECK, a view, a trigger, or a paragraph a
member is expected to read and act on. So the thing that can fail is not "the function returned the
wrong value". It is:

> An AI member read the schema and the process, understood some of it, and did something *adjacent*
> to what was needed.

`docs/expectations.md` is the specification that catches that. It asks one question — **did the
member understand the schema and the process, and do what was needed?** — and because the data model
is a database, it never answers in prose. Every expectation is a **SQL assertion with a stated
expected result**, written to return zero rows when healthy and the offending rows when not, so a
failure names its own cause. `docs/expectations-fixtures.md` supplies the six known board states
those assertions run against, because an assertion against an unknown state answers differently
every time. `guild:validate` runs them; each process skill closes by running its own section.

This proves a board is coherent after an agent touched it. It leaves the largest questions open on
purpose — whether a plan is any good, whether the code was actually written, whether a human
genuinely decided a gate, who really wrote a row. Each section names those under *Cannot be
asserted* rather than faking a proxy check, because a weak assertion converts an open question into
a green check.

## 9. Status

Established: `schema.sql` applies cleanly and idempotently; the engine constraints in §5 are observed
failures rather than guesses; every assertion in `expectations.md` and every fixture in
`expectations-fixtures.md` was executed against a real tursodb 0.7.2 database, confirmed to pass on a
healthy board and — for the invariants — confirmed to *fire* on an injected breach.

Not established: **nothing has exercised the guild end to end.** The expectations have never been run
against the output of a real member doing real work; they have only been run against fixtures written
alongside them, which is a weaker thing and shares an author with what it checks. The conventions in
§4 are precisely what gets violated quietly, and a real requirement is what will say whether these
assertions catch it.
