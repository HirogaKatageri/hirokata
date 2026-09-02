# Guild Plugin

**A schema and a set of skills.** The guild runs a roster of agents against a board that lives in
one SQLite database, and the guild's rules live *in that database* — as CHECK constraints, views and
triggers — rather than in a program that wraps it.

There is no guild CLI. `tursodb` is already a tool that executes SQL, so the guild does not ship a
second one. Every member reaches the board the same way: they load the `guild:warehouse` skill and
write SQL.

> **The v6 line is a fresh rewrite, and v7 builds on it.** The v5 CLI it replaced had four
> adversarial review rounds and a 2,278-check suite behind it. **None of that confidence carries
> over**, because none of that code exists any more. Read
> [Status](#status-what-is-verified-and-what-is-not) before you trust this.

---

## Overview

A work session starts with a check-in. The orchestrator reads the brief, asks what you want to work
on, and drives requirements through an execution graph that stops at exactly two gates — the plan is
approved before anything is built, and findings, bugs and failures are presented together as one
decision after review. Between gates it runs continuously. You can also leave it running unattended
with `guild:shift`, which works the same loop and stops at the same line.

### The pivot from v5

v5 shipped a 31,348-line bash CLI that owned every read and write to the board. v6 deletes it
entirely. The reasoning, from the guild master:

> When the turso CLI is already installed, we have a tool that can execute SQL. We don't need to
> build another tool that does the same thing. Templates, tables, how to access things should be in
> markdown, part of the skills, as knowledge. We're giving our guild members the tool to access the
> library or guild warehouse, and a general guide on how to access it. It's up to them to decide how
> best to update and retrieve the information.

The CLI's guarantees did not evaporate — they moved down into the engine, where they are harder to
skip:

| Construct | What it now carries |
|-----------|---------------------|
| **CHECK constraints** | The status vocabularies and enums. A value outside its enum is rejected by the engine, on every connection, from every member, forever. |
| **VIEWS** | The derived rules. The cursor rule, the review gate, node readiness, the agent matcher, the board, the brief — each has **one** definition. A member SELECTs from the view instead of re-deriving the logic, so two members cannot get two answers to one question. |
| **TRIGGERS** | The record. Every meaningful mutation writes an `event` row without anyone remembering to, and stamps `updated_at`. |

**A member can forget to call a command. A member cannot bypass a trigger or a CHECK.**

### What is convention, not guarantee

This is the honest half, and it is the part that changed for the worse. The v5 CLI policed these in
bash. Nothing polices them now — they are documented in `schema.sql` and nowhere enforced.

1. **"The orchestrator owns every status transition."** SQL has no identity. Any connection can run
   any `UPDATE`. `guild_state.actor` is a courtesy label a member sets on itself; it is not
   authentication, and the triggers copy it into `event.actor` verbatim. A lying actor produces a
   lying feed.
2. **"A requirement may not close over a blocked task."** No constraint expresses it.
   `v_requirement_progress.tasks_open` is the query that tells you; closing anyway is one `UPDATE`
   away.
3. **"A `failed` task is adjudicated when the orchestrator waives it."** The waiver lives in a
   work-log line's *prefix*, matched with `LIKE`. It is a marker, not a column.
4. **"Concurrently dispatched tickets touch disjoint files."** `task.files` is a JSON array; the
   disjointness across a `parallel_group` is an assertion by the architect. Nothing checks it.
5. **"A ticket's capabilities name something a real agent declares."** The vocabulary is the agent
   files, not a table, so no SQL check can reach it — a misspelled tag inserts fine and matches
   nobody. The dispatcher is what makes it speak, by writing the ticket `blocked`.
6. **"A gate is decided by a human."** `gate.status` is a column. Anyone can write it.
7. **The graph is not acyclic by construction.** `graph_edge` accepts any pair. A cycle makes
   `v_ready_nodes` return nothing for the whole loop — a silent stall, not an error. There is no
   `WITH RECURSIVE` on tursodb to detect one, so this is a review duty.
8. **Timestamps are UTC by convention.** The triggers use UTC; whatever a member writes by hand is
   whatever they wrote.

### Key features

- **A ticket names a required capability, not an agent.** `task_capability` rows say what the work
  needs; any subagent whose frontmatter `capabilities:` cover the set is eligible. Adding
  `agents/developer-rust.md` with the right tags makes it eligible with no skill edits, no chain
  rewiring and **nothing to sync** — the dispatcher reads the agent files on the next check-in.
- **The roster is the agent files, not a table.** Who exists, what each can do and whether one runs
  serially are declared in frontmatter and read at dispatch time, across this plugin, the project's
  `.claude/agents/`, your `~/.claude/agents/` and every other installed plugin. v7 dropped the SQL
  mirror of it, because a mirror is only ever as fresh as the last sync somebody remembered.
- **The chain is data.** An execution template is instantiated per requirement into `graph_node` /
  `graph_edge` / `gate` rows. `v_ready_nodes` says what can run.
- **Two gates, always.** `gate-plan` before anything is built; `gate-repairs` after review. Gates
  cannot live inside a workflow, because subagents cannot ask the user a question — segmenting at
  gates is the only shape that preserves guild-master control.
- **It can work a shift while you are away.** `guild:shift` runs the loop unattended, retries a
  failure once, commits per completed task on its own branch, and stops at the next gate. It never
  pushes and never touches the default branch.
- **An independent QA discipline** files `bug` rows and maps risk as `coverage` rows, so "what is
  still broken?" and "what has not been looked at lately?" are queries.
- **The board is a query, not a file.** There is no `BOARD.md`, no ticket file, no `state.yaml` and
  no status directory. Status is a column; the board is `v_board`.

---

## Setup

### 1. Install tursodb

```bash
brew install tursodatabase/tap/turso        # or: curl -sSfL https://get.tur.so/install.sh | bash
export PATH="$HOME/.turso:$PATH"
tursodb --version        # 0.7.2 is what the schema is verified against
```

Put the `export` line in your shell profile. Every skill assumes `tursodb` is on `PATH`.

### 2. Apply the schema

```bash
mkdir -p .guild/docs .guild/qa .guild/reviews
tursodb .guild/guild.db < "${CLAUDE_PLUGIN_ROOT}/schema.sql"
```

**Applying `schema.sql` is idempotent, and it is how a rule change reaches a live board.** Tables are
`CREATE TABLE IF NOT EXISTS`, so data survives. Views and triggers are dropped and recreated every
time — they hold no data, so re-applying the file is how you upgrade a rule. Seed rows are guarded
by `WHERE NOT EXISTS`. Run it as often as you like.

One honest limit: `CREATE TABLE IF NOT EXISTS` sees an existing table and moves on. Applying this
file over a database created by an **earlier v5 stage** lands the views and triggers but **not** the
CHECK constraints. A board that wants them has to rebuild.

### 3. Check in

Say **"check in"**. The orchestrator does the rest — it creates `.guild/config.yaml` if it is
missing, reads the roster straight from the agent files, and opens with the brief.

### Storage modes

| Mode | Where | Binary | Status |
|------|-------|--------|--------|
| `local` (default) | `.guild/guild.db` | `tursodb` | The verified path. |
| `cloud` | a Turso Cloud database | `turso` | The SQL is identical; only the binary and target change. **Not verified end to end** — treat a cloud board as unproven, not as broken. |

`config.yaml` is committed to git and holds env var **names** only, never a credential.

---

## The work model

The hierarchy, widest to narrowest:

```
goal → project → requirement → plan → task
```

A goal is a high-level target. A project is a named group of work that has to be done to reach it —
it can run beside its sibling projects (`concurrent`) and can be cut into its own git worktree
(`isolation`, `worktree_path`). A requirement is one unit of shipped value. A plan is how the
architect intends to build it, and **nothing is built until a human approves it** (`plan.approval`,
separate from `plan.status`, which only says whether the document is written). A task is a bounty a
guild member can claim, carrying the file set it owns in `files`.

`project` was called `phase` through v6.1. Existing boards migrate with
`migrations/006-project-and-plan-approval.sql` — run it before re-applying `schema.sql`.

Alongside them: `graph_node` / `graph_edge` / `gate` (the execution graph), `task_capability`
(what each ticket needs), `bug`, `coverage`, `review_finding`, `work_log`, `doc`, and `event` —
the activity feed the triggers write.

The roster left the database in v7. Existing boards migrate with
`migrations/007-roster-leaves-the-database.sql` — run it before re-applying `schema.sql`.

**`event` is the record.** There is no journal any more. `guild.db` is not derived state that can be
thrown away and rebuilt; it is the board. It is gitignored because a binary file is a bad thing to
merge, which means the board is machine-local unless you run in cloud mode. What git carries instead
is the human-readable residue: `config.yaml`, `.guild/docs/`, `.guild/qa/`, `.guild/reviews/`, and
the repo's own `CHANGELOG.md`.

### The views are the API

Read the view; do not re-derive the rule. The ones you will use most:

| View | Answers |
|------|---------|
| `v_brief` | Where does the guild stand? |
| `v_board` | Everything in flight, by status. |
| `v_next_task` / `v_batch` | What runs next, and what can run in parallel. |
| `v_open_bounties` | What can be claimed — and underneath, what cannot, with a reason. |
| `v_task_actionable` / `v_task_blockers` | Is this task workable, and if not, why not? |
| `v_ready_nodes` | Which graph nodes have all direct predecessors done. |
| `v_gates_pending` | What is waiting on the guild master. |
| `v_plans_pending_approval` | Which drafted plans nobody has ruled on yet. |
| `v_projects_runnable` | Which projects may run right now, and why — the parallelism rule, defined once. |
| `v_project_progress` | Every project with its counters, isolation and worktree. |
| `v_requirement_progress` / `v_goal_progress` | How far along. |
| `v_failed_tasks`, `v_open_findings`, `v_open_bugs`, `v_coverage_due` | What still needs attention. |
| `v_blocked_tasks` | What cannot move, and why — a `status-blocked` row's `who` names the capability nobody has. |
| `v_recent_activity` | What moved. |

---

## Working with the warehouse

Load `guild:warehouse` before touching guild data. It carries the connection recipe, the six rules
that are always true, and three references: `schema.md` (what every table is *for*, and which rules
are enforced versus conventional), `queries.md` (the canonical verified queries — copy from it rather
than improvising), and `tursodb-gotchas.md`.

The rules that bite hardest, in short:

1. **Free text crosses as hex.** The tursodb stdin splitter ends a statement at a `;` that terminates
   a line — *even inside an open string literal* — and requirement bodies quote code. Every title,
   body, rationale, log entry and finding goes in as `CAST(x'<hex>' AS TEXT)`, which is always one
   line.
2. **`PRAGMA foreign_keys = ON;` at the top of every writing script.** It is per-connection and
   defaults to OFF, and every invocation is a fresh connection.
3. **Never parse `-m list` output positionally.** It is pipe-separated with no quoting, and free text
   contains pipes *and newlines* — a newline forges a whole row. Ask for `json_object(...)`, or
   select exactly one column.
4. **Read the view, do not re-derive the rule.**
5. **A failing statement does not stop the script, and `COMMIT` still commits.** There is no `-bail`.
   Put `RETURNING` on every mutation so "did it land" is answered by output.
6. **Errors print on stdout, not stderr.** Always check the exit code.

### Engine constraints, verified on tursodb 0.7.2

- **No `WITH RECURSIVE`.** Readiness joins *direct* predecessors only, one hop, and propagates as the
  work runs. Never write a traversal.
- **No FTS5.** Text search is `LIKE`, with `%` and `_` escaped by the caller.
- **No `lag`/`lead`/`ntile`/`percent_rank`/`cume_dist`.** Ranking is an `ORDER BY`, and the rank is
  the row's position, assigned by the reader.
- **STRICT tables** accept only INT, INTEGER, REAL, TEXT, BLOB, ANY. Every column is TEXT or INTEGER.
- **Working:** STRICT, RETURNING, ON CONFLICT DO UPDATE, printf(), plain CTEs, WAL, foreign_keys,
  JSON functions, CHECK, VIEW, TRIGGER, `UPDATE OF <col>` triggers.

### Widening a vocabulary is a migration

SQLite cannot `ALTER` a CHECK in place. Adding a status word means rebuilding the table — create,
copy, drop, rename, with `foreign_keys` off for the swap. **Choose words you can live with.** This is
the price of moving the vocabulary into the engine, and it is a real one.

---

## Skills

| Skill | What it does |
|-------|--------------|
| `guild:check-in` | **The orchestrator.** Opens with the brief, gathers input, runs each requirement's execution graph, presents the two gates, and drives the continuous work cycle. Say "check in". |
| `guild:shift` | `check-in` with the human taken out of the middle. Runs unattended to the next gate, then stops and says why. Never decides a gate — not even "the obvious ones". |
| `guild:brief` | Where the project stands: direction, in flight, bugs, coverage due, what moved. Read-only. |
| `guild:guild-status` | **Deprecated alias for `guild:brief`** — the v4 name. It claims **no** natural-language trigger phrases; every status phrasing routes to `guild:brief`, because two skills advertising "guild status" would make every status request a coin flip. Reachable only by typing `/guild:guild-status`. |
| `guild:dashboard` | Renders the board as one self-contained offline HTML page. Read-only. |
| `guild:new-requirement` | A live 3-way interview between the product-owner, the architect and you. Writes the requirement, the plan, the tickets **and the execution graph**, then ends at `gate-plan` — nothing is built until you approve. |
| `guild:qa` | Seeds a QA pass onto the board: a qa-strategist plans risk-based coverage, then qa-testers run the app, author Playwright specs, and file bugs back to the board. |
| `guild:comprehensive-review` | Multi-dimensional pre-PR review — requirements compliance, coverage, edge cases, architecture, security. |
| `guild:verify-and-fix` | Diagnoses a reported error end to end, then applies a test-driven fix. |
| `guild:release` | Stamps `CHANGELOG.md`'s Unreleased section with a version, snapshots completed requirements, and creates an annotated tag. Does not push. |
| `guild:clear-board` | Deletes every unit of work, keeping the things that outlive a board. **There is no journal to replay any more** — a `DELETE` is final. Back the file up first. |
| `guild:discuss` | Surfaces the subjects in the current context and drives a focused discussion. |
| `guild:create-workflow` | Generates a CI or script workflow file. |
| `guild:validate` | **Runs `docs/expectations.md` against the live board** — the nine global invariants by default, a named process's postconditions on request. Reports each failure with the offending rows. Read-only unless you ask it to load a fixture. |
| `guild:warehouse` | **The reference every member loads before touching guild data.** |

Agent-facing skills that specialists pre-load rather than users invoking: `guild:qa-mindset`,
`guild:qa-artifacts`, and the four `guild:svelte-*` skills, plus `guild:svelte-env-vars-check`.

---

## The roster

**The roster is these files' frontmatter — there is no roster table.** A ticket names capabilities;
the orchestrator scans every subagent available to you and ranks the eligible ones deterministically
— eligible means the member's declared capabilities are a **superset** of the required set, ranked
by preferred-covered (desc), then total capability count (**asc**, so a specialist beats a
generalist), then name. Read it with:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py"
```

Adding a member is writing its file. There is nothing to sync, and no vocabulary to admit the word
to first.

| Agent | Model | Capabilities | Role |
|-------|-------|--------------|------|
| `architect` | Opus | `architecture` | Explores the codebase, writes the implementation plan and its tickets, composes the execution graph. Recommends direction; never sets it. |
| `product-owner` | Sonnet | `requirements` | Interviews you live alongside the architect, writes the requirement record. |
| `developer` | Sonnet | `implement`, `backend`, `frontend` | Implements code per plan and requirement. |
| `developer-svelte` | Sonnet | `implement`, `frontend`, `svelte`, `sveltekit` | Svelte 5 / SvelteKit specialist, pre-loaded with four reference skills. |
| `test-planner` | Sonnet | `test-planning` | Inventories the implemented diff and writes the test plan. |
| `test-writer` | Sonnet | `test-authoring` | Writes and runs unit and integration tests. |
| `product-reviewer` | Haiku | `review`, `requirements` | Verifies the implementation satisfies the plan. |
| `reviewer-security` | Haiku | `review`, `security` | Vulnerabilities, OWASP Top 10. |
| `reviewer-architecture` | Haiku | `review`, `architecture` | Plan alignment, patterns, separation of concerns. |
| `reviewer-business-logic` | Haiku | `review`, `business-logic` | Acceptance criteria, business rules, testability. |
| `reviewer-edge-case` | Haiku | `review`, `edge-case` | Boundary conditions, null handling, error scenarios. |
| `researcher` | Haiku | `research` | Technology research, API investigation, documentation lookup. |
| `qa-strategist` | Sonnet | `qa-planning` | Risk map as `coverage` rows, adversarial what-if missions. |
| `qa-tester` | Sonnet | `qa-execution`, `test-authoring`, `e2e` | **`serial: true`** — runs the product and authors e2e specs; Playwright collides on ports, so two may never run concurrently. |

**Hiring is adding a file.** Write `agents/<name>.md` with `name`, `model`, `capabilities` and
`serial` in the frontmatter, then check in — the dispatcher reads it on the next scan. **There is
nothing to sync.**

A capability nobody declares does not surface on its own: the ticket sits in `v_open_bounties`
once, and then the dispatcher has to write `status = 'blocked'`. No view derives that, so skipping
the write leaves a board on which nothing knows there is a gap — and a shift will re-pick the same
ticket all night. Read the gaps with:

```sql
SELECT id, who FROM v_blocked_tasks WHERE reason = 'status-blocked';
```

Each `needs:…` in `who` names the agent file somebody has to write.

**Agents write to the board themselves now.** In v5 they reported through a spool and the
orchestrator drained it. There is no spool and no drain; a member loads `guild:warehouse` and writes
its own `work_log` and `review_finding` rows. "The orchestrator owns every status transition" remains
the rule, but see [What is convention, not guarantee](#what-is-convention-not-guarantee) — nothing
enforces it.

---

## File structure

The plugin:

```
plugins/guild/
├── schema.sql              # THE TOOL. 21 tables, 23 views, 40 triggers, and the guild's rules
├── migrations/             # one-shot upgrades for what IF NOT EXISTS cannot reach —
│                           # renamed tables and new columns. Run, then re-apply schema.sql
├── agents/                 # 14 roster members; frontmatter is the roster source
├── skills/
│   ├── warehouse/          # how to reach the board — the skill every member loads
│   │   └── references/     # schema.md, queries.md, tursodb-gotchas.md, templates/
│   ├── validate/           # runs the expectations against the live board
│   └── …                   # check-in, shift, brief, dashboard, new-requirement, qa, …
├── docs/
│   ├── v6-architecture.md        # the current design — start here
│   ├── expectations.md           # THE SPEC a member's work is checked against
│   ├── expectations-fixtures.md  # the six known board states it is checked on
│   └── v5-design.md              # historical; the data model and rules are still in force
├── CHANGELOG.md
├── LICENSE
└── README.md
```

The board, in your repository:

```
.guild/
├── config.yaml         # committed. version + storage mode; env var NAMES only, never a credential
├── guild.db            # gitignored. THE BOARD
├── docs/               # evergreen researcher knowledge (the `doc` table is the primary copy)
├── qa/                 # evergreen QA artifacts — charter, missions, bug ledger, session logs
├── reviews/REQ-NNN.md  # per-requirement review records, appended per round
├── dashboard.html      # gitignored. regenerated wholesale
└── templates/*.yaml    # optional. a project's override of the shipped execution templates
```

---

## Validation: from testing code to validating behavior

v6 deleted a 31,348-line CLI, and its 8,918-line test harness went with it. Nothing replaced the
harness in kind, and nothing should have — **there is no code left to unit-test.** Every function
became a CHECK, a view, a trigger, or a paragraph a member is expected to read and act on.

So the thing that can fail changed. It is no longer *"the function returned the wrong value"*:

> An AI member read the schema and the process, understood some of it, and did something **adjacent**
> to what was needed.

`docs/expectations.md` is the specification that catches that. It asks one question — **did the
member understand the schema and the process, and do what was needed?** — and because the data model
is a database, it never answers in prose. Every expectation is a **SQL assertion with a stated
expected result**:

| | |
|---|---|
| **§3 — nine global invariants** | Hold at all times, whatever just ran: referential health, vocabulary, id shape, gate integrity, ticket routing, closure, event coverage, graph structure, concurrency. |
| **§4–§12 — one section per process** | Trigger, preconditions, expected sequence, postconditions, anti-expectations, and *cannot be asserted* — for `new-requirement`, `brief`, `dashboard`, `check-in`, `clear-board`, `release`, `guild-status`, `qa` and `shift`. |
| **`expectations-fixtures.md`** | Six known board states — `empty`, `planned`, `in-flight`, `review-ready`, `messy`, `maintenance` — because an assertion run against an unknown state answers differently every time. |

Assertions return **zero rows when healthy and the offending rows when not**, so a failure names its
own cause. `finding-open-past-gate-repairs|1|REQ-001` tells you the row, the requirement and the
rule; a boolean `FAIL` only tells you to go looking.

Say **"validate the guild"**, or run `guild:validate <process>`. Each process skill also closes by
running its own section, because a member's account of what it wrote is not evidence — the board is.
(The tursodb splitter can tear a script apart mid-string and still exit having committed half of it.
That is why postconditions are queried rather than assumed.)

**What this deliberately does not do.** It does not assert that the code works, that a feature is
correct, or that a test passes — the guild has reviewers, testers and a QA discipline for that, and
they operate on the product, not on the board. It also leaves the largest questions open on purpose:
whether a plan is any *good*, whether the code was actually written, whether a human genuinely made
the decision a gate records, who really wrote a row. Each section names those under *Cannot be
asserted* rather than inventing a proxy check, because a weak assertion turns an open question into
a green check.

---

## Upgrading a live board

`CREATE TABLE IF NOT EXISTS` cannot rename a table, drop one, or add a column — so re-applying
`schema.sql` alone lands views and triggers on columns that are not there. Check where the board
stands first, then run only the migrations above it, in order, and re-apply the schema at the end:

```bash
export PATH="$HOME/.turso:$PATH"
cp .guild/guild.db .guild/guild.db.bak
tursodb .guild/guild.db "SELECT version FROM schema_version;"

# run only the ones above the reported version, in order
tursodb .guild/guild.db < migrations/006-project-and-plan-approval.sql   # → 6
tursodb .guild/guild.db < migrations/007-roster-leaves-the-database.sql  # → 7
tursodb .guild/guild.db < schema.sql
```

| Migration | Takes a board to | What it does |
|-----------|------------------|--------------|
| **006** | 6 (v6.2) | Renames `phase` to `project`, rewrites `PHASE-NNN` ids, splits `plan.status` from `plan.approval`. |
| **007** | 7 (v7.0) | Drops `agent`, `agent_capability` and `capability_request` and the six roster views; rebuilds `task` without the FK to `agent(name)`. |

`schema.sql` seeds version **7**. **Neither migration is idempotent** — a second run of 006 fails on
`CREATE TABLE project`, which is the safe direction to fail — and **order is not optional**. A fresh
board needs none of this.

---

## Status: what is verified, and what is not

**Read this before trusting anything above.**

v6 is a **fresh rewrite**. The v5 CLI went through four adversarial review rounds and shipped behind
a 2,278-check harness that also enforced the portability rules statically over `schema.sql` and the
SQL embedded in `lib/`. **That code is deleted, and none of its assurance transfers to code that
replaced it.** Saying otherwise would imply a continuity of confidence that does not exist.

What *is* verified:

- The engine constraints above were each established by running the construct against tursodb 0.7.2.
  "No `WITH RECURSIVE`" and "no FTS5" are observed failures, not guesses.
- `schema.sql` applies cleanly and is idempotent across repeated runs.
- Individual SQL snippets in `references/queries.md` were run against a real database as they were
  authored.
- **Every assertion in `docs/expectations.md` and every fixture in `docs/expectations-fixtures.md`
  was executed** against a real tursodb 0.7.2 database — confirmed to pass on a healthy board, and,
  for the nine invariants, confirmed to *fire* on a deliberately injected breach. An assertion that
  has never been seen to fail is not an assertion, it is a wish.
- **The v6.2 `project` rename and plan approval** were verified the same way: the schema applies to a
  fresh board at version 6, `migrations/006-project-and-plan-approval.sql` was run end to end against
  a seeded v6.1 board with the views read back after it, all five fixtures load clean, every
  read-only guard in `docs/expectations.md` runs clean on the empty, messy and maintenance fixtures,
  and the `brief` and `dashboard` scripts were executed in full.
- **The v7 roster removal** was run end to end against a populated v6 board:
  `migrations/007-roster-leaves-the-database.sql` followed by `schema.sql` lands **21 tables, 23
  views, 40 triggers, `schema_version = 7`**, with data and history intact and
  `PRAGMA integrity_check` clean.
- **Both migrations have been run against seeded boards only, never against a board with real
  history.**

What is **not**:

- **No test suite exists**, and the expectations are not one. They replace the deleted harness at a
  **different level**: the harness proved a program's functions behaved, and this proves a board is
  coherent after an agent touched it. Different surface, not a smaller version of the same one.
- **The expectations have never been exercised against a real run.** They have only been run against
  fixtures written alongside them — which shares an author with what it checks, and is a weaker thing
  than meeting an actual member's output. Nothing runs the guild end to end.
- No skill or agent has been exercised against a live board in this form.
- Cloud mode is unverified end to end.
- The conventions listed above are unenforced by construction, and a rewrite is exactly when
  unenforced conventions get quietly violated. The expectations are aimed squarely at those eight —
  but aiming at a failure is not the same as having caught one.

Treat the v6/v7 line as a well-reasoned design that has not yet met its first real requirement. The
data model and the rules beneath it are inherited from a design that *was* scrutinized heavily —
see `docs/v5-design.md` — but the expression of them here is new.

---

## Version history

See [CHANGELOG.md](CHANGELOG.md) for the guild's own history, and the
[marketplace CHANGELOG](../../CHANGELOG.md) for the long-form rationale behind the v5–v7 entries.

---

## License

MIT — see [LICENSE](LICENSE).

## Author

Gian Patrick Quintana — <gian.quintana@hirokata.dev>
