# Changelog

All notable changes to the Guild Plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **On sources.** This file was reconstructed from the marketplace
> [root CHANGELOG](../../CHANGELOG.md) and the git history, because the guild plugin shipped
> without a changelog of its own through v7.0.0. The root file carries the long-form rationale for
> the v5–v7 entries; this one is the guild-scoped record. Six versions — 1.6.2, 1.8.0, 1.8.1,
> 1.8.2, 3.0.0 and 3.3.0 — were never written up anywhere and are reconstructed from their release
> commits; they are marked *(from commit)*.
>
> **The marketplace has never cut a git tag**, so no version here corresponds to a tagged release.

---

## [8.2.0] - 2026-09-02

### Removed
- **`guild:guild-status` is gone.** It was a deprecated alias kept alive only so the typed
  `/guild:guild-status` slash command still resolved to `guild:brief`. Its description had to
  spend a paragraph disclaiming the trigger phrases it deliberately did not claim, and that
  paragraph was loaded into the skill listing of every session to serve a command nobody types.
  Status requests already route to `guild:brief` by description; deleting the alias changes
  nothing about that and removes a skill's worth of description from every context window.
  **`docs/expectations.md` §10 went with it** — the section asserted the alias delegated
  correctly and measured the description collision it existed to avoid.
- **Version archaeology, from every file a member loads.** The agents, the skills, their
  references, the two working docs and the `schema.sql` comments carried a running commentary on
  what the plugin used to be: *"In v4 a bash guard refused you"*, *"this used to be
  `standard.yaml`"*, *"there is no spool file any more"*, *"the matcher was dropped in v7"*,
  *"before v8 a decision lived in plan prose"*. Every one of them stated a live rule and then
  explained a version the reader never ran. The rule survives in each case; the comparison does
  not. Four reviewer agents also carried a markdown findings template introduced as *"this is no
  longer written as markdown"* — a dead format shown for reference beside the SQL that replaced
  it. **The history is not lost: it is in this file and in the README**, which is where a reader
  looking for it goes.

### Changed
- **`docs/v6-architecture.md` → `docs/architecture.md`, rewritten as a description of the design
  rather than a comparison against v5.** §1 was "The pivot" — a section whose subject was the CLI
  it deleted. It now states what the schema is. §4's ten conventions are unchanged in substance
  and no longer framed as "these were bash guards in v5". §8 "What did not change" is gone: it
  only meant anything against a version nobody is running. `docs/v5-design.md` is **untouched**
  and still linked, from the header, as the record of how the data model was reasoned out.
- **`docs/expectations.md` renumbered: §11 → §10 (the maintenance cycle), §12 → §11 (the
  unattended shift)**, following §10's removal. Every cross-reference in `guild:qa`,
  `guild:shift`, `guild:validate` and the README moved with it. §8 is retitled from *"There is no
  board clear"* to *"The guild deletes nothing"* — the same assertions, stated as a rule rather
  than as the absence of a removed skill.
- **`guild:new-requirement` §1.5 "Do Not Offer to Clear the Board" is gone.** A section that
  existed to countermand a step no version of the skill still performs.
- **The plugin description no longer ends with the v6/v7 rewrite caveat**, which was 126
  characters of provenance in a field that loads on every session.

## [8.1.0] - 2026-09-02

### Removed
- **`guild:clear-board` is gone, and nothing replaced it. The guild deletes no records.** The skill
  existed since v1.0.4 and its job was to empty the board in place, keeping a hand-maintained list
  of things that "outlive a board" — `coverage`, `doc`, `event`, and after v8 the `doc → doc` edges.
  That list was the tell. Every release added to it, because every release added another table whose
  whole purpose was remembering: `event` is written by triggers and is the guild's memory,
  `doc_revision` holds the body before every rewrite, `knowledge_edge` records which decision
  governed which requirement. A `DELETE` reaches through all of them at once — the row goes, and the
  record of why it was ever there goes with it — and the skill's own v8 change was a fresh clause to
  cut the library's edges *first* or breach G10. That is a great deal of care to spend on losing
  information on purpose.

  **Work is retired by status, not by deletion.** `done`, `cancelled`, `superseded`. A finished
  requirement costs nothing on the board — `v_next_task` only ever looks at open work — and it is
  the only thing that explains the release that shipped it.

### Added
- **G11 — nothing is deleted.** The eleventh global invariant, and the assertion that makes the
  rule enforceable rather than merely stated. `goal`, `project`, `requirement`, `plan`, `task` and
  `bug` each already carried an `AFTER DELETE` trigger writing an `event` row with
  `verb = 'deleted'`, so **the act writes its own evidence** and G11 simply reads it. No schema
  change was needed for this; the triggers were there before the rule was.

  **Its second clause is narrow on purpose.** An `unlinked` event is not automatically a breach:
  retiring a decision legitimately deletes and rewrites `doc → doc` edges. What separates the
  innocent case from the guilty one is the edge's *`to`* end, and `trg_edge_unlinked` writes only
  the *`from`* end into the subject columns — that end is a doc either way. The target is in
  `payload`, so the clause reads `json_extract(payload, '$.to_type') <> 'doc'`. An edge deleted out
  of the library is fine; an edge deleted out of the **work** is the shape a board clear made.

- **A fresh board is a fresh file** — `docs/expectations.md` §8 and the guild README. Move
  `guild.db` aside with a timestamp and apply `schema.sql` to a new one. The retired file stays on
  disk and stays readable, so every id in git history still resolves against the board it was
  written on.

  **What that costs is stated plainly rather than papered over.** The new board does *not* inherit
  the library, the coverage map or the event feed — those are in the retired file. Carrying them
  forward would mean `ATTACH`, which was tested and rejected: it is **experimental on tursodb
  0.7.2** and requires `--experimental-attach`, and the guild does not build a procedure on an
  experimental flag. Nothing is destroyed; nothing is migrated either.

### Changed
- **`docs/expectations.md` §8 keeps its number and loses its process.** Renumbering would have
  moved roughly ninety `§9`–`§13` cross-references for no reader's benefit, so §8 is now *There is
  no board clear*: the anti-expectations for the thing that no longer exists, the fresh-file
  procedure, and a pointer to G11 for the assertion.
- **`guild:new-requirement` no longer offers to clear the board** before adding work. A new
  requirement joins the board alongside whatever is already there, which is what a board is for.
- **`guild:release`** no longer defers a crowded board to `clear-board`'s question; there is no such
  question. **`guild:validate`** runs eleven invariants and its process table drops the
  `clear-board` row. **`guild:qa-artifacts`** describes `.guild/qa/` as outliving any one board
  rather than surviving a clear.
- **`references/queries.md` §7** replaces *"Do not `DELETE FROM agent`"* with the general rule.

### Fixed
- **Three v7 leftovers referencing the dropped `agent` table.** Two were the same stale advice —
  *"retire with `active = 0`"* — in `clear-board` (gone with the skill) and `references/queries.md`
  §7, both naming a table and a column that have not existed since v7.0.0. The third was live and
  broken: **`docs/expectations.md` §9.a carried `UNION ALL SELECT 'agent', COUNT(*) FROM agent`**,
  so the release fingerprint errored with `no such table: agent` on every board built since v7 —
  on *stdout*, where a member checking the exit code would never see it, and `tursodb` has no
  `-bail` so the script ran on and reported a fingerprint one line short. `doc_revision` and
  `knowledge_edge` take its place: a release must not touch those either, and unlike the roster
  they are actually in this database. Re-measured on the `messy` fixture — the documented
  `7c7`/`10c10` diff still holds exactly.
- **The README's upgrade section had not caught up with v8.** It listed migrations 006 and 007
  only, and said `schema.sql` seeds version **7**; it seeds **8**. The root README's version table
  still read guild 7.0.0.

### Migration
**None.** `schema.sql` is unchanged and `schema_version` stays at **8** — a v8 board is already a
v8.1 board. What changed is which skills ship and what the expectations assert.

**If your board ran `guild:clear-board` before v8.1, G11 will fire on it**, and that is correct: the
`deleted` events are a true record of something that happened. Scope the assertion with
`AND e.ts > '<upgrade timestamp>'` and say so in the report.

---

## [8.0.0] - 2026-09-02

### Added
- **The library becomes a knowledge graph.** `doc` was a flat pile: a slug, a title, a body and a
  source, with nothing pointing at anything. Three things it could not do, each of which cost
  something real. It could not say what a document was **for** — a domain rule, a subsystem
  walkthrough and an API lookup were the same kind of row. It could not hold a **decision** at
  all: architectural choices lived in `plan.body` prose and in `gate.decision` JSON, both attached
  to a ticket and both archived when the ticket closed, which made *"why is it like this"* the
  most expensive question the guild could be asked. And nothing related to anything, so nothing
  could be derived — not which shipped work was undocumented, not which page went stale when its
  subject moved, not what the project had decided and then un-decided.

  Three tables now, and the nodes are mostly rows the board already had:

  - **`doc`** gains `kind` (`business` · `technical` · `decision` · `research` · `runbook` ·
    `reference`), `status` (`draft` → `current` → `superseded` | `rejected`), `area` and
    `created_at`. One `status` vocabulary serves prose and ADRs both — for a decision, `draft`
    reads as *proposed* and `current` as *accepted*. **Superseded and rejected rows are never
    deleted**: they are how a project's evolution is read, and the options it did *not* take are
    half of why it looks the way it does.
  - **`knowledge_edge`** — typed, directed relations that may point at **any** board row, which
    is what makes this a graph over the work rather than a second database beside it.
    `describes` · `decides` (doc → work), `supersedes` · `refines` · `depends-on` · `contradicts`
    (doc → doc), `derived-from` (provenance) and `evidence-for` (a bug or finding backing a
    claim). The rel/type pairings are **CHECK constraints** — `supersedes` between two non-docs
    is refused by the engine.
  - **`doc_revision`** — the body before every change, written by `trg_doc_revised`. Documentation
    history needs no discipline from anybody, and it has **no foreign key to `doc` on purpose**:
    a revision must survive its document being deleted, or it is not history.

- **Seven views, and two of them make the library maintain itself.** `v_doc_stale` reports any
  page whose subject has an `event` newer than the page's own `updated_at` — documentation drift,
  derived from a record the board was already keeping, so nobody has to file a "docs are out of
  date" ticket. `v_undocumented_work` lists finished requirements nothing describes, in the same
  idiom `v_coverage_due` uses for quality. Alongside them: `v_knowledge_ref` (the polymorphic
  endpoint resolver the others stand on), `v_doc_current`, `v_doc_neighbors` (one hop, both
  directions), `v_decision_log` and `v_knowledge_dangling`. `v_brief` gains `docs_current`,
  `docs_stale` and `work_undocumented`.

- **A `document` node, and a `librarian` to run it.** The `standard` template's last node, after
  `repair` — so what gets written is what actually **shipped**, including the findings the guild
  master waived, which are among the most useful things a later reader can learn. `required: true`
  deliberately: a node that may be dropped is a node that gets dropped, and the cost is invisible
  for months and then enormous. The count arithmetic moves to **N + 10 nodes, 2N + 11 edges** —
  gates stay at exactly **2**, which was never negotiable.

- **The whole chain writes the graph now, not just the librarian.** The **architect** extracts each
  plan-time decision into a `decision` doc with a `decides` edge (step 4.5) and reads
  `v_decision_log` *before* designing, so it stops designing past commitments it did not know
  about; the **product-owner** records the domain rules an interview surfaces as `business` docs;
  the **researcher** tags its rows `research` and links them; **`reviewer-architecture`** now reads
  the decision log too, because code that quietly violates a recorded ADR is an architecture
  finding even when it matches the plan in front of it.

- **G10 — library integrity**, the tenth global invariant. `knowledge_edge` endpoints are
  polymorphic, so SQLite cannot `REFERENCES` either end and **G1 cannot cover them**. G10 stands
  in: every dangling edge, plus every `current` doc that something already claims to supersede.
  Writes take the shape the rest of the guild uses for referential safety —
  `INSERT … SELECT … FROM <target> WHERE id = …`, where the `FROM` clause *is* the check and a
  missing endpoint yields zero rows instead of a broken edge.

### Changed
- **`guild:clear-board` cuts the library's edges into the work, first.** There is no cascade — an
  edge has no foreign key — so a clear that left them behind would leave edges pointing at
  requirements it had just deleted, breaching G10 on the next validate. `doc → doc` edges survive,
  so the decision log and its chains come through a board reset intact. What is genuinely lost is
  provenance, and nothing can rescue that: a decision that governed `REQ-004` cannot say so once
  `REQ-004` is gone.
- **A release names the decisions it shipped and copies none of them.** Slugs, not bodies — a
  decision goes on evolving after the release that introduced it, and a frozen copy becomes a
  second answer to a settled question.
- **`guild:dashboard` gains a Decisions view and a Library view** (nine total). The decision view
  renders each supersession chain rather than a flat list, and draws a superseded ADR struck
  through instead of hiding it: the chain *is* the content.
- **`guild:brief` reports the library in the risk beat, last and never first.** A documentation
  gap blocks no ticket, and a count with no example is not a briefing.

### Migration
- **`migrations/008-the-library-becomes-a-graph.sql`**, then re-apply `schema.sql`. Schema version
  **7 → 8**.
- **Check `SELECT version FROM schema_version` reads 7 before running it.** A second run does
  **not** fail safely — it resets `kind`, `status`, `area` and `created_at` on every document. The
  rebuild ends in an unconditional `DROP TABLE doc` and **no guard inside the file can prevent
  that**, because a failing statement does not stop a tursodb script (there is no `-bail`). A
  `guild_state` tripwire makes a second run exit non-zero so you find out, but it tells you
  afterwards. The version check tells you beforehand, and the backup is what undoes it.
- **The backfill guesses two things and says so**: `created_at` copies `updated_at`, because the
  old row carried no birth date and inventing a plausible one is worse than a visibly wrong one;
  `kind` is `research` when `source = 'researcher'` and `reference` otherwise. Re-tag by hand
  afterwards — `SELECT slug, title, kind FROM doc ORDER BY kind, slug`.
- **No edges are invented.** An edge is an assertion about meaning and a script cannot make one, so
  every finished requirement appears in `v_undocumented_work` on the first read after upgrading.
  That number is the backlog becoming visible, not a fault.

### Verified
- Every construct against **tursodb 0.7.2**, including four the schema had not used before —
  `group_concat(col, sep)`, a `LEFT JOIN` onto a view, a correlated `NOT EXISTS` against a view
  built from `UNION ALL`, and `AFTER DELETE` triggers. All four now carry a row in §7 of
  `tursodb-gotchas.md`.
- Every new CHECK **rejects** its bad row (each rel/type pairing, self-edges, duplicate edges,
  unknown `kind`); `trg_doc_revised` snapshots on a real body change and correctly skips a no-op
  rewrite and a metadata-only update; `v_doc_stale` stays empty until its subject moves and fires
  the moment it does; `v_knowledge_dangling` reports all four broken ends of a deleted doc; G10
  fires on both clauses and clears when fixed; the migration round-trips a seeded v7 board with
  `PRAGMA integrity_check` clean, and the `document` node becomes ready even when `repair` is
  `skipped`.

### Fixed
- **README caught up with v7.** The file structure block still claimed `schema.sql` held
  *24 tables, 29 views, 45 triggers* — the v6.2 counts; it is **21 tables, 23 views, 40 triggers**.
  The validation section named invariant G5 *roster integrity*, which v7 replaced with
  *ticket routing*. Three passages still described a roster that syncs into the database
  ("syncs the roster from the agent files", "the roster sync picks it up", a capability gap
  surfacing in the brief's *Roster Gaps*) — all false since v7 dropped `v_roster_gaps` along with
  the tables; a gap now lands in `v_blocked_tasks` with `reason = 'status-blocked'`. The
  upgrade section documented only migration 006 and read `schema_version` as `5 → 6`, omitting
  007 and the move to `7`.

---

## [7.0.0] - 2026-09-02

### Removed
- **The roster leaves the database.** `agent`, `agent_capability` and `capability_request` are
  dropped. They were a **mirror** — every fact in them was already declared in the frontmatter of
  the member's own markdown file, and the SQL copy was the one that went stale. It was only ever as
  fresh as the last `sync-agents` somebody remembered to run, and it could only see the plugin's own
  `agents/` directory while the user has subagents from their project, their home directory and
  every other installed plugin.
- **Six views went with the tables.** `v_agent_eligible`, `v_agent_match` and `v_task_top_agent`
  were the matcher; `v_capability_vocabulary`, `v_capability_unknown` and `v_roster_gaps` were its
  audits.

### Changed
- **The matching rule moved into the dispatcher** (`guild:check-in` §3.3), unchanged: a pin wins
  outright and skips the match; otherwise eligible means the member's declared capabilities are a
  superset of the ticket's `required = 1` set, ranked by preferred-covered DESC, then fewest total
  capabilities ASC (a specialist beats a generalist), then name ASC for determinism.
  `skills/check-in/scripts/roster.py --covers implement,svelte` prints the eligible members,
  specialist first; no output is a roster gap.
- **`task_capability` stayed** — it records what the *work* needs, which is board data. What left is
  the claim to know who can do it.
- **`v_open_bounties` changed what it promises.** Its third condition used to be "somebody can take
  it", verified against the roster; it is now "the ticket asks for somebody" — a pin, or at least
  one capability row. A row there is a candidate for dispatch, not a guarantee of one.
- **`v_blocked_tasks` lost the `no-eligible-agent:rust,embedded` reason** it could no longer
  compute. A ticket nobody covers sits in the bounties once, and then **the dispatcher writes
  `status = 'blocked'`**. That write is load-bearing: no view derives it, so skipping it leaves a
  board on which nothing knows there is a gap, and a shift re-picks the same ticket all night. Read
  the gap as `SELECT id, who FROM v_blocked_tasks WHERE reason = 'status-blocked'`.
- **`task.claimed_by` lost its foreign key** to `agent(name)`, which required a table rebuild. It
  and `task.agent` are plain TEXT now, deliberately: a done task from months ago may name a member
  whose file is gone, and it still reads correctly.
- **Recruiting is writing a file, and nothing precedes it.** A `capability_request` row existed to
  admit a word to a vocabulary this database owned; once the vocabulary is "what the agent files
  declare", that row is bookkeeping about bookkeeping. The architect records a gap in the plan's
  Technical Decisions (which rides through `gate-plan`) and raises it live as
  `NEEDS INPUT: ROSTER GAP`. Creating the agent is still the guild master's call alone.
- **`docs/expectations.md` documents what it can no longer assert, as a trade rather than a quiet
  drop.** G5 became *ticket routing* — every open ticket pins a member or declares what it needs —
  and its seven roster clauses are replaced by `roster.py --covers`, run by the architect at plan
  time and the dispatcher at dispatch time. G9's serial check can now only report a member holding
  two in-flight tickets; whether that member is serial lives in frontmatter. §7 C.a keeps the pinned
  case and loses the capability path. §12.b's "a shift never recruited" is now
  `git status --porcelain agents/`.
- **Fixtures lost `00-roster.sql`**, because a seed script cannot fake a roster any more. `empty`
  now reads `21|23|40|7|0`; `messy` blocks `TASK-010` alongside `TASK-009` and its brief drops
  `roster_gaps` and `capability_unknown`. The §5.b roll call swapped `roster-gap`/
  `capability-unknown` for `blocked-needs`, fired off `v_blocked_tasks.who`, and still lands on
  exactly 27 rows.

### Fixed
- **`clear-board` never actually cleared a board that had an approved plan.** `plan.gate_node_id`
  (added in 6.2.0) points forward into `graph_node`, and the skill's delete script broke only the
  `plan.task_id`, `review_finding.fix_task_id` and `bug.fix_task_id` cycles. `DELETE FROM
  graph_node` failed the foreign key and every delete after it failed too — and because tursodb has
  no `-bail`, **the script ran to the end and reported a clear that had not happened.** One line
  (`UPDATE plan SET gate_node_id = NULL`) fixes it. Reproduces identically on 6.2.0.

### Migration
`migrations/007-roster-leaves-the-database.sql`, then re-apply `schema.sql`. **Order is not optional
and the migration is not idempotent.** It drops every view and trigger first — the
`ALTER TABLE … RENAME` in the `task` rebuild re-parses the whole schema, and `trg_requirement_moved`
reads `task`, so leaving it standing makes the rename fail and takes the `task` table with it —
then rebuilds `task` without the foreign key, drops the three tables, and stamps
`schema_version = 7`. `event` rows whose `subject_type` is `agent` or `capability_request` are
deliberately left alone: they are the record of a board that really did recruit those members, and
`v_recent_activity` resolves an unknown subject type to a blank title rather than failing.

### Verified
Run end to end against a populated v6 board: 21 tables, 23 views, 40 triggers, data and history
intact, `PRAGMA integrity_check` ok.

---

## [6.2.0] - 2026-09-02

### Changed (BREAKING)
- **`phase` becomes `project`.** The direction layer said *phase*, which means *stage*, and the
  table said the same thing structurally: `ordinal NOT NULL` and a `v_goal_progress` that reported
  exactly one "current phase" per goal. That shape could not express **a group of work that can run
  beside its siblings, or in its own git worktree**. `PHASE-NNN` is now `PROJ-NNN`, and
  `requirement.phase_id` is `requirement.project_id`.
- **Four new columns on `project`, and one that loosened.** `ordinal` is **nullable** — NULL means
  *unordered*, waits for nobody, and is not the same as *first*. `concurrent` (default `0`) says
  whether the project may run beside its siblings. `isolation` (`shared` | `worktree`, default
  `shared`) and `worktree_path` say **where** its tasks run; a table-level CHECK stops a `shared`
  project from carrying a path. `priority` (1–5) closes a gap every other level of the hierarchy
  had already closed. `body` was added for symmetry with `goal`, `requirement` and `task`.
- **The parallelism rule has exactly one definition: `v_projects_runnable`.** A project earns a
  place there by being `concurrent`, by being unordered, or by having every lower-ordinal
  *sequential* sibling done — a concurrent sibling never blocks a sequential one, because a project
  that opted out of the queue does not get to hold it. `v_project_progress` is the same list with
  counters and a `runnable` flag *derived from that view* rather than restated. `v_goal_progress`
  lost `current_phase_id`/`current_phase_title` and reports `projects_total`, `projects_done`,
  `projects_runnable` and a display-only `runnable_project_ids` instead.

### Added
- **`plan.status` and `plan.approval` are now two columns, because they were always two questions.**
  `status` (`todo → in-progress → done`) is the architect's drafting lifecycle: *is the document
  written?* `approval` (`pending → approved | rejected`, with `approved_by` and `approved_at`) is
  the user's ruling: *did anyone agree?* The old single column could not tell "finished writing,
  waiting on a person" from "agreed and building" — the most important distinction on the board.
  `gate_node_id` links a plan to the `gate-plan` node carrying the same decision, and
  `v_plans_pending_approval` is the queue.
- `check-in` and `shift` now stop for a pending plan approval **even when no gate row exists behind
  it** — a plan approved in conversation has no gate to surface it, and without that query it would
  be invisible.

### Known limits
Approving is **three writes** — the gate row, the graph node, and `plan.approval` — and the schema
does not keep them in sync. **Nothing creates, verifies or cleans up a worktree**; the column
records a decision, honouring it is the orchestrator's job. Both are listed in `schema.sql`'s
"what this file cannot enforce".

### Migration
`migrations/006-project-and-plan-approval.sql`, then re-apply `schema.sql`. **Not idempotent** — a
second run fails on `CREATE TABLE project`, which is the safe direction to fail. It rebuilds
`project` from `phase` (a rebuild, not a rename: `ordinal` had to lose `NOT NULL` and the
table-level CHECK cannot be added by ALTER), renames the requirement column, adds the four plan
columns, rewrites `PHASE-NNN` ids and the `event` rows pointing at them, and stamps
`schema_version = 6`. Old `event.payload` values still say `"phase_id"` and are left alone as the
record of what was written at the time. Plans already at `status = 'done'` are backfilled to
`approved`, not `pending` — what was already built was already agreed to.

### Verified
Schema applies clean to a fresh board (24 tables, 29 views, 45 triggers, version 6); the migration
run end to end against a seeded 6.1 board with the views read back after it; all fixtures load;
all 63 read-only guard queries in `docs/expectations.md` run clean across the `empty`, `messy` and
`maintenance` fixtures; the `brief` and `dashboard` skills' full SQL scripts executed and their
JSON keys checked. **The migration has been run against seeded boards only, never against a board
with real history.**

---

## [6.1.0] - 2026-09-02

### Changed (BREAKING)
- **The schema is the tool.** The plugin is no longer a program — it is **a schema and a set of
  skills**: `schema.sql` plus the knowledge that teaches a guild member to use it. The guild
  master's reasoning is the whole of the change:

  > When the turso CLI is already installed, we have a tool that can execute SQL. We don't need to
  > build another tool that does the same thing.

  `tursodb` **is** the tool; members write their own SQL; `skills/warehouse/` is the guide at the
  door.
- **The rules moved from the wrapper into the engine.** **CHECK constraints** carry the status
  vocabularies and enums — a value outside its enum is rejected on every connection, from every
  member, forever. **Views** carry the derived rules: the cursor rule, the review gate, node
  readiness, the matcher, the board and the brief each have exactly ONE definition, so two members
  cannot get two answers to one question. **Triggers** carry the record: every meaningful mutation
  writes an `event` row and stamps `updated_at` without anyone remembering to. *A member can forget
  to call a command; a member cannot bypass a trigger or a CHECK.*
- **There is no journal.** `event`, written by triggers, is the record — which makes `guild.db` the
  durable board rather than derived state that can be thrown away and replayed. `guild:clear-board`
  now warns that a `DELETE` is final.
- **There is no spool and no drain.** Agents write their own `work_log` and `review_finding` rows
  straight into the board instead of appending to a per-task file the orchestrator folded in.

### Removed
- **`plugins/guild/scripts/` deleted entirely** — 24 files, 34,182 lines: the `guild` dispatcher,
  all 17 `lib/` modules, the 8,918-line `test-guild.sh` harness, `dashboard.tmpl.html` and
  `scripts/README.md`. `templates/*.yaml` went too — the execution templates are knowledge now, at
  `skills/warehouse/references/templates/*.md`. **Every `guild <verb>` invocation is gone**;
  nothing replaces the command surface, because the replacement is SQL.

### What is convention, not guarantee
Several v5 guarantees were bash guards and are conventions again — documented in the `schema.sql`
header, the README and `docs/architecture.md` §4, and nowhere enforced. The largest:
**"the orchestrator owns every status transition"** cannot be expressed in SQL, which has no
identity; `guild_state.actor` is a courtesy label a member sets on itself, copied into
`event.actor` verbatim, so a lying actor produces a lying feed. Also conventional now: a requirement
may not close over a blocked task; the `failed`-task waiver is a work-log line *prefix* matched with
`LIKE`, not a column; plan-slice file disjointness is the architect's assertion; an unknown
capability inserts fine and matches nobody; `gate.status` is a column anyone can write; and the
graph is not acyclic by construction — a cycle is a silent stall in `v_ready_nodes`, undetectable
without `WITH RECURSIVE`.

### The price, stated plainly
SQLite cannot `ALTER` a CHECK in place, so widening a status vocabulary means rebuilding the table
(create / copy / drop / rename, `foreign_keys` off for the swap). **Adding a word is a migration.**
Relatedly, applying `schema.sql` over a database created by an earlier v5 stage lands the new views
and triggers but **not** the CHECKs — `CREATE TABLE IF NOT EXISTS` sees the table and moves on.

### Documentation
README rewritten for v6. New `docs/architecture.md` — the pivot, the warehouse metaphor, what
CHECK/VIEW/TRIGGER enforce, what is convention, the engine constraints and the file layout.
`docs/v5-design.md` **kept deliberately**, with a header saying which parts are historical (the
driver layer §2.2, the journal §2.3, the CLI surface §4) and which remain authoritative (the data
model §3.2, the roster and matcher §5, the execution graph and templates §6, the unattended shift
§8).

### Status
**The v5 CLI's four adversarial review rounds and 2,278-check suite do not carry over** — they
belonged to code that no longer exists. v6 ships with **no tests at all**, by the guild master's
explicit direction. What *is* verified: `schema.sql` applies cleanly and idempotently; the tursodb
engine constraints were each established by running the construct (no `WITH RECURSIVE`, no FTS5 —
observed failures, not guesses); individual queries in `references/queries.md` were run as they were
authored. What is not: nothing has exercised the guild end to end.

---

## [6.0.0] - 2026-08-15

Superseded by 6.1.0 the same cycle — the first cut of the schema-is-the-tool rewrite.

---

## [5.0.0] - 2026-08-15

### Added
- **Stages 4 and 5 of the five-stage v5 design** (`docs/v5-design.md`), completing it: the execution
  graph, segments, gates, templates, the maintenance cycle and the unattended shift. **No schema
  migration at any point** — every table shipped in `schema.sql` with Stage 1, which is why three
  stages of behaviour landed without one.
- `guild:release` is what cuts the tag.

---

## [5.0.0-beta.3] - 2026-08-14

### Added
- **The roster: a ticket declares what the work needs, not who does it.**
  `guild new task --needs implement,frontend [--prefers svelte]` writes `task_capability` rows, and
  any roster member whose capabilities cover the required set is eligible. `--agent` is no longer
  mandatory — one of the two is. Adding `agents/developer-rust.md` with the right tags makes it
  eligible with **no skill edits and no chain rewiring**.
- **`guild sync-agents` builds the roster from agent frontmatter** — idempotent; new members added,
  removed members **deactivated** rather than deleted, capability sets replaced. A file it cannot
  parse is a refusal that names the file. All 14 shipped agents declare capabilities.
- **`guild match` is deterministic — no model judgment.** Eligible = superset of the required set;
  ranked by preferred covered (desc) → total capability count (**asc**, specialist beats
  generalist) → name (asc). A **pin** is rank 1 with source `pin`, and the capability-eligible
  members are still listed under it so the deviation is visible rather than merely obeyed.
- **`guild bounties`** — open, dependency-satisfied tasks with their matched member, and underneath,
  everything that cannot be worked with a blank-free reason token (`status-blocked`, `deps:<ids>`,
  `no-eligible-agent:<caps>`).
- **`blocked` is a new task status, and it is loud.** It means *no guild member can take this
  bounty* — a roster gap, not a verdict on the work. For requirement completion it counts as open.
  **`blocked → done` is refused** — the CLI's one refused transition.
- **`guild capability-request`** records a capability the roster lacks and admits it to the
  vocabulary. One capability is one open request however many requirements need it; only
  `sync-agents` closes it. An unattended shift may never create an agent.
- **The capability vocabulary is closed** (17 words). `sync-agents` refuses an agent file declaring
  a capability outside it. The **task** side is deliberately not enforced: `--needs kotlin` is
  accepted, matches nobody, and reports `no-eligible-agent:kotlin`.

### Compatibility
A task with **no** `task_capability` rows matches its own `task.agent` directly, so every board
built by Stages 1–2 behaves exactly as before. A task that *did* declare capabilities gets no
rescue from `task.agent` — that is a roster gap, which is the point of declaring them.

Harness: **1848 checks, 0 failures.**

---

## [5.0.0-beta] - 2026-08-14

### Changed (BREAKING)
- **The board is a database, not a directory tree (Stage 1).** `.guild/guild.db` replaces the
  `{todo,in-progress,done,failed}/` ticket directories, `state.yaml` and every ticket file. **Status
  is a column**, written only by `guild move`; IDs are derived in SQL (`MAX(n) + 1` in the same
  statement as the insert, so two creates cannot collide) and the cursor is derived.
- **`guild path` is REMOVED** (breaking for custom automation) — it named a file agents used to
  Edit, and v5 has no such file. `new`, `move` and `next` print the **bare ID**. `guild migrate` and
  the pre-3.0 flat-file format are retired.
- **Migration: v4 boards are ARCHIVED, not migrated.** `guild init` moves the whole tree to
  `.guild/v4-archive/` — never deletes, never parses — with **no history import**. Only
  `.guild/docs/` and `.guild/qa/` carry over, because they are evergreen.

### Added
- **Storage modes.** Local `tursodb` by default, needing no account, token or network. `--mode
  cloud` is refused on purpose: the cloud driver has no machine-readable output flag, its FK
  preamble differs, and its URL would travel in argv. `config.yaml` stores env var **names**, never
  a credential.
- **Durability is two committed artifacts.** `journal.ndjson` is an append-only log of the resulting
  row state per mutation, with `rebuild` / `compact` / `recover` / `sync`; `guild export`
  regenerates one deterministic markdown file per requirement as the PR-reviewable snapshot.
- **Agents write through a spool** — `guild log` and `guild finding` append NDJSON, and the
  orchestrator folds them in as the single writer with `guild spool drain`. **Draining is not
  optional**: an undrained ticket renders an empty Work Log, which triage reads as never-started.
- **Direction above the board (Stage 2).** New `goal` and `phase` layers. Goals and phases
  **organize but do not gate**; `requirement.phase_id` is nullable by design.
- **Bugs and coverage are rows, not prose.** `guild bug` and `guild coverage`. `coverage list --due`
  is the brief's own predicate — never inspected, or stale past a risk-weighted threshold
  (high 14 days, medium 30, low 90).
- **Two new read surfaces and a skill for each** — `guild:brief` and `guild:dashboard`, both
  strictly read-only.
- **`guild:guild-status` is a deprecated alias** that loads `guild:brief`. It claims **no**
  natural-language triggers — two skills advertising "guild status" would make every status request
  a coin flip.

### Known limits at this point
Stages 3–5 (the capability roster, the execution graph and gates, the unattended shift) were **not**
shipped; their tables exist in `schema.sql` so no stage needs a migration, and the surfaces that
read them render as empty sections rather than errors.

---

## [4.0.0] - 2026-07-07

### Changed (BREAKING)
- **Requirements and planning move out of the ticket board entirely.** `guild:new-requirement` now
  spawns the product-owner and architect directly (not as ticket types) for a live 3-way interview
  with the user — both relay questions through the orchestrator (`AskUserQuestion` is still
  main-session-only), and the architect creates every ticket via the CLI before the skill returns.
- **`product-owner` and `architect` gain the `Agent` tool** and can spawn `guild:researcher` inline;
  the two-ticket async research-gate handoff is gone.
- **The automatic review fix-loop is gone.** The 4 reviewers now only write findings — no `Fix:`
  follow-ups, no round cap, no `ESCALATE` token. The orchestrator compiles every round into
  `.guild/reviews/REQ-NNN.md` and asks the user which findings become fix tickets.
- Developers relay unclear-requirement questions directly (`NEEDS INPUT`) instead of declaring a
  `Clarify:` follow-up.

### Added
- **Optional Agent Teams integration.** With `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` enabled, the
  product-owner and architect message each other directly during the interview; otherwise the
  orchestrator moderates between two concurrently-spawned sessions.

---

## [3.3.0] - 2026-07-07

*(from commit)* Minor version bump shipped alongside a marketplace bump; no behavioural change
recorded.

---

## [3.2.0] - 2026-07-02

### Fixed
- **"Continue where we left off" hardened end to end** — 27 adversarially-verified audit findings.
  Follow-ups are materialized *before* a ticket's terminal `guild move done` and each created line
  is annotated ` → TASK-NNN`, so a crash can no longer strand a requirement with un-created chain
  tickets. Check-in stale triage is now three-case: empty Work Log → re-queue; outcome recorded in
  the log → record it without re-dispatching; otherwise resume with a RESUMED-TASK dispatch.
- **Execution correctness.** The orchestrator now parses and passes `parallel-group` (previously
  silently dropped — dev waves degraded to sequential) and the architect's new `plan:` modifier
  (previously the plan ID never propagated, leaving `plan-slice` unresolvable). `failed/` is
  redefined as user-adjudicated (waived). The QA bug loop files each bug as a Fix + Re-verify pair.
  All CLI `for $(ls …)` loops replaced with quote-safe globs.

### Changed
- **Token efficiency.** Check-in no longer force-reads all three reference docs per session (~7k
  tokens, ~80% duplicated) — references are load-on-demand. New `guild meta <ID> [field]` prints
  frontmatter only. The dead `priority:` follow-up modifier was removed everywhere.

---

## [3.1.0] - 2026-07-02

### Changed
- **Parallel development is the default, not the escape hatch.** The architect designs plan slices
  for disjoint file sets and organizes dev tickets into `parallel-group` waves.
- **test-writer now owns unit AND integration tests**, implementing the test plan instead of
  re-deriving scope. `qa-tester` owns e2e only.
- The check-in work cycle flows continuously by default, pausing only on failure, escalation,
  collision, or requirement completion.

### Added
- **New `test-planner` agent** (Sonnet) — inventories the implemented diff into a Changed Files
  Inventory, maps acceptance criteria to unit and integration cases, and writes the plan as
  `PLAN-NNN/slice-test-plan.md`. The diff analysis happens once and is reused three times: the
  test-writer implements from it, and all 4 reviewers scope their reading to it.

---

## [3.0.0] - 2026-06-25

*(from commit)*

### Changed (BREAKING)
- **Directory-based board driven by a deterministic CLI.** Status is the subdirectory a ticket lives
  in (`requirements|plans/{todo,in-progress,done}`, tasks add `failed/`); the `status` frontmatter
  field is removed everywhere. IDs are derived from the filesystem (max existing + 1, archive
  included); the cursor is derived from `tasks/in-progress/`. `state.yaml` holds only
  `last-checkin`.
- **The orchestrator owns all status transitions** (`guild move`); agents only report done/failed
  and never move their own files. All 13 agents updated accordingly.

### Added
- **`scripts/guild`** — a dependency-free CLI (Bash 3.2+): `new req|task|plan`, `next`,
  `path`/`read`/`slice`, `move`, `list`, `board`, `status`, `next-id`, and `is-legacy`/`migrate` to
  convert pre-3.0 flat-file guilds.

---

## [2.0.0] - 2026-06-24

### Changed (BREAKING)
- **Removed `.guild/BOARD.md` entirely.** Task status lives solely in each `TASK-NNN.md`; a new
  `.guild/state.yaml` holds only the cursor and ID counters. The board is rendered as a live view by
  scanning ticket files — eliminating the dual-store reconciliation the orchestrator did every
  cycle.
- **Replaced the three-way sequencing logic** (follow-up declarations + ID-arithmetic auto-triggers
  + magic `depends-on` tokens) with a single cursor that walks tickets in ID order. Removed
  `depends-on`, the `all-developer`/`TASK-RESEARCH` tokens, the `blocked` status, and
  parallel-developer batching.
- **Development is now sequential.** Review remains per-requirement and gated on all implementation
  tickets being done, then fans out to the 4 reviewers in parallel — the only parallelism left.
- Renamed reference `board-format.md` → `state-format.md`.

### Migration
No automatic path — `/guild:clear-board` is the upgrade. Returning check-ins on a pre-2.0 guild are
offered an in-place convert or clear.

---

## [1.8.2] - 2026-06-22

*(from commit)* Release bump; no behavioural change recorded.

## [1.8.1] - 2026-06-21

*(from commit)* Ships the QA-driven fix-loop and chain-consistency repairs.

## [1.8.0] - 2026-06-21

*(from commit)*

### Added
- **The independent QA discipline** — `qa-strategist` and `qa-tester` agents, the `guild:qa` skill,
  and the `guild:qa-mindset` / `guild:qa-artifacts` reference skills.

## [1.7.0] - 2026-06-04

### Added
- `guild:verify-and-fix` — diagnoses and fixes reported errors through a structured five-phase
  workflow: detect/create the project's error-verification guide, collect the error artifact,
  investigate configured log and code sources, propose ranked solutions, then apply a test-driven
  fix.

## [1.6.2] - 2026-05-26

*(from commit)* Refines the auto-review trigger in check-in to fire once all non-review tasks across
all requirements are done, replacing the per-plan trigger after test-writer completion.

## [1.6.1] - 2026-05-24

### Changed
- `guild:svelte-env-vars-check` — stricter server-side enforcement: server files importing from
  `$env/*/public` are now a hard violation (previously advisory); migration step 5.3 added to strip
  the `PUBLIC_` prefix and rewrite imports to `$env/*/private`.

## [1.6.0] - 2026-05-24

### Added
- `guild:svelte-env-vars-check` — audits SvelteKit environment variable usage for PUBLIC/PRIVATE
  compliance and `process.env` violations; reports violations in three categories, optionally
  migrates to the correct patterns with a static/dynamic timing choice, and outputs an env var
  inventory table.

## [1.5.0] - 2026-05-14

### Added
- `guild:discuss` — a context summarizer and discussion facilitator. Open mode scans the
  conversation and groups subjects into a numbered topic map; targeted mode (`discuss [topic]`)
  scopes to a single topic. Wraps up with a closing summary and the decisions reached.

## [1.4.0] - 2026-05-14

### Added
- `guild:create-workflow` — an interactive skill for generating automation workflows (GitHub Actions
  pipelines, Python/Node/shell scripts, Makefiles); silently scans the project stack for
  context-aware suggestions and previews the generated file before writing.

## [1.3.0] - 2026-04-25

### Changed
- Check-in now exhausts all pending `product-owner` tasks before dispatching any `architect` task,
  ensuring requirements are fully written before planning begins.

## [1.2.0] - 2026-04-25

### Added
- `developer-svelte` — a Sonnet-backed specialist agent pre-loaded with Svelte 5 / SvelteKit
  knowledge via four `guild:svelte-*` reference skills (core, build-deploy, advanced,
  best-practices). The architect routes per-slice to it when work touches `.svelte`, `.svelte.ts`,
  `+page.*`, `+layout.*`, `+server.*`, hooks or `svelte.config.js`, and falls back to `developer`
  otherwise.

## [1.1.3] - 2026-04-23

*(from commit)* Check-in prioritizes product-owner tasks before architect dispatch.

## [1.1.2] - 2026-04-22

### Removed
- `guild:commit` — replaced by `software:conventional-commit` rather than maintained twice.

## [1.1.1] - 2026-04-21

### Changed
- `architect` model upgraded from Sonnet to Opus for higher-quality architectural planning.

## [1.1.0] - 2026-04-20

### Added
- `guild:commit` (conventional commits from recent developer tasks, no push) and `guild:release`
  (stamps `CHANGELOG.md`'s Unreleased, archives completed REQs to `.guild/archive/{version}/`,
  creates an annotated git tag).
- A **research gate** on the architect — auto-dispatches a researcher plus a follow-up architect
  task when it cannot plan responsibly without more information.
- `.guild/docs/` — an evergreen knowledge base where the researcher writes topic-keyed findings
  (updated in place on overlap) and the architect reads during codebase analysis. Docs survive both
  `clear-board` and `release`.
- Check-in maintains the `[Unreleased]` section of the repo-root `CHANGELOG.md` as requirements
  complete.

## [1.0.4] - 2026-04-20

### Added
- `guild:clear-board` — wipes all tasks, requirements and plans with confirmation.
  `new-requirement` delegates to it instead of duplicating the clear logic.

## [1.0.3] - 2026-04-20

### Changed
- `new-requirement` prompts to clear the board before adding a new requirement when existing work is
  present.

## [1.0.2] - 2026-04-18

### Changed
- The architect emits per-task plan slices so developers read a scoped brief instead of the full
  plan.
- `researcher` model downgraded to Haiku for cost efficiency.

## [1.0.1] - 2026-04-12

### Added
- `comprehensive-review` skill and `product-reviewer` agent, moved here from the software plugin as
  part of consolidating duplicated agents across plugins.

## [1.0.0] - 2026-04-12

### Added
- Continuous agent orchestration with persistent board management, automatic agent chains
  (product-owner → architect → developers → test-writer → 4 parallel reviewers), and session-based
  work cycles triggered by "check in".

---

## See Also

- [Marketplace CHANGELOG](../../CHANGELOG.md) — the long-form rationale for the v5–v7 entries
- [`docs/architecture.md`](docs/architecture.md) — the current design
- [`docs/v5-design.md`](docs/v5-design.md) — historical; the data model and rules are still in force
