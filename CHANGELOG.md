# Changelog

All notable changes to the HiroKata Claude Code Plugin Marketplace will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Guild Plugin v8.0.0 — the library becomes a knowledge graph (BREAKING).** `doc` was a flat
  pile: a slug, a title, a body and a source, with nothing pointing at anything. Three things it
  could not do, each of which cost something real. It could not say what a document was **for**, so
  a domain rule, a subsystem walkthrough and an API lookup were the same kind of row. It could not
  hold a **decision** at all — architectural choices lived in `plan.body` prose and in
  `gate.decision` JSON, both attached to a ticket and both archived when the ticket closed, which
  made *"why is it like this"* the most expensive question the guild could be asked. And nothing
  related to anything, so nothing could be derived.

  **`doc` gains `kind`, `status`, `area` and `created_at`**; `kind` is `business` · `technical` ·
  `decision` · `research` · `runbook` · `reference`, and one `status` vocabulary serves prose and
  ADRs both (`draft` reads as *proposed* on a decision, `current` as *accepted*). **Superseded and
  rejected rows are never deleted** — they are how a project's evolution is read, and the options
  it did *not* take are half of why it looks the way it does.

  **`knowledge_edge` is the new table that matters.** Typed, directed relations that may point at
  **any** board row, which is what makes this a graph *over the work* rather than a second database
  beside it: `describes` and `decides` (doc → requirement/task/project), `supersedes` · `refines` ·
  `depends-on` · `contradicts` (doc → doc), `derived-from` (provenance) and `evidence-for`. The
  rel/type pairings are CHECK constraints — `supersedes` between two non-docs is refused by the
  engine. **The endpoints have no foreign key**, because SQLite cannot `REFERENCES` a table chosen
  at runtime; the write-time shape `INSERT … SELECT … FROM <target> WHERE id = …` stops you
  creating a dangling edge, and **G10**, a new global invariant, catches one created by deleting
  the other end later.

  **`doc_revision` is written by a trigger**, so documentation history needs no discipline from
  anybody, and it deliberately has **no foreign key to `doc`**: a revision must survive its
  document being deleted, or it is not history.

  **Two views make the library maintain itself.** `v_doc_stale` reports any page whose subject has
  an `event` newer than the page — documentation drift derived from a record the board was already
  keeping, so nobody files a "docs are out of date" ticket. `v_undocumented_work` lists finished
  requirements nothing describes, in the idiom `v_coverage_due` already uses for quality.

  **Every requirement now documents itself.** The `standard` template's last node is `document`,
  run by a new `librarian` agent after `repair` — so what gets written is what actually shipped,
  including the findings the guild master waived. Graph arithmetic moves to **N + 10 nodes,
  2N + 11 edges**; gates stay at exactly **2**. The architect now also extracts each plan-time
  decision into an ADR and reads the decision log *before* designing, and
  `reviewer-architecture` reads it too — code that quietly violates a recorded decision is an
  architecture finding even when it matches the plan in front of it.

  **Migrating: `plugins/guild/migrations/008-the-library-becomes-a-graph.sql`, then re-apply
  `schema.sql`.** Schema version **7 → 8**. **Check `SELECT version FROM schema_version` reads 7
  first** — a second run does *not* fail safely, it resets every document's tagging, and no guard
  inside the file can prevent that because a failing statement does not stop a tursodb script. A
  `guild_state` tripwire makes a re-run exit non-zero so you find out afterwards; the version check
  is what tells you beforehand. The backfill guesses two things and says so: `created_at` copies
  `updated_at`, and `kind` is `research` when `source = 'researcher'`, `reference` otherwise. **No
  edges are invented** — an edge is an assertion about meaning and a script cannot make one — so
  every finished requirement appears in `v_undocumented_work` on the first read after upgrading.
  That number is the backlog becoming visible, not a fault.

  Verified end to end against tursodb 0.7.2: `23` tables, `30` views, `44` triggers, every new
  CHECK rejecting its bad row, every trigger firing (and correctly *not* firing on a no-op
  rewrite), G10 firing on both clauses, and a seeded v7 board round-tripping with
  `PRAGMA integrity_check` clean. Four SQL constructs the schema had not used before —
  `group_concat(col, sep)`, a `LEFT JOIN` onto a view, a correlated `NOT EXISTS` against a
  `UNION ALL` view, and `AFTER DELETE` triggers — were each verified and added to §7 of
  `tursodb-gotchas.md`.

### Documentation
- **Every plugin README and CHANGELOG audited against what actually ships.** Findings and fixes:
  - **The install instructions pointed at a repository that does not exist.** The root README told
    users to `/plugin marketplace add hirogakatageri/hirokata-cc-marketplace` and to
    `git clone …/hirokata-cc-marketplace.git`, in six places. The repository is
    `HirogaKatageri/hirokata`. Section 1.b's "copy plugins into `.claude-plugin/`" procedure was
    replaced with adding the clone as a local marketplace, which is the path the repo's own
    `marketplace.json` supports.
  - **The root README's version badge read 2.3.0**; `marketplace.json` says `6.0.0`. It now carries
    a plugin/version table instead of one number that has to be remembered.
  - **The guild plugin had no CHANGELOG.** It has one now —
    [`plugins/guild/CHANGELOG.md`](plugins/guild/CHANGELOG.md) — reconstructed from this file and
    the git history, covering 1.0.0 through 7.0.0. Six versions (1.6.2, 1.8.0, 1.8.1, 1.8.2, 3.0.0,
    3.3.0) had never been written up anywhere and were recovered from their release commits. The
    guild also had no `LICENSE` file despite its README claiming MIT; the root MIT license was
    copied in.
  - **The guild README still described v6.2.** `schema.sql` was listed as *24 tables, 29 views, 45
    triggers* — the real numbers are **21 / 23 / 40**, confirmed by applying the file to a fresh
    database. Invariant G5 was named *roster integrity* (v7 renamed it *ticket routing*), three
    passages described a roster that syncs into the database and a capability gap surfacing in the
    brief's *Roster Gaps* (v7 deleted `v_roster_gaps` — a gap is now `v_blocked_tasks` with
    `reason = 'status-blocked'`), and the upgrade section documented only migration 006, reading
    `schema_version` as `5 → 6`.
  - **`docs/expectations.md` §8.c asserted a fact that no longer exists.**
    `SELECT value FROM v_brief WHERE fact = 'roster_gaps'` cannot return a row — `v_brief` has no
    such fact since v7 — and `COUNT(*) FROM v_brief` was stated as `23`, a v6.1 number that v6.2
    took to 27 and v7 left at **25**. Corrected against a live schema apply. This one matters more
    than a README line: `guild:validate` runs these assertions.
  - **The software plugin's README documented a plugin that was deleted in v1.0.5** — the
    `/software:develop-project` command, the `comprehensive-review` and `generate-requirements`
    skills, and all eight agents — plus an embedded "Changelog" section frozen at 0.5.0 that
    contradicted its own `CHANGELOG.md`. Rewritten for the three skills that ship. Its CHANGELOG
    had no **1.0.5** entry at all despite `plugin.json` carrying that version; the entry is written,
    and the file's title no longer says "Develop Plugin".
  - **The software plugin's marketplace description advertised removed features** ("automated
    planning, adaptive parallel execution … comprehensive requirements documentation"). Replaced
    with what the three skills do.
  - **The guild's description ended "v6 is a fresh rewrite"** while shipping 7.0.0; now "the v6/v7
    line".
  - **The root README's guild skill table listed 12 of 22 skills** — `guild:shift`,
    `guild:validate` and `guild:warehouse` were missing, and the agent-facing skills were
    unmentioned. It also still offered to place a requirement on a **phase**, renamed to *project*
    in guild v6.2, and described "what the CLI would hand out next" three versions after the CLI
    was deleted.
  - **Research and storytelling were audited and found accurate** — every skill, agent and model in
    both READMEs matches the files on disk. Both gained a License/Author footer for consistency
    with the other two plugins.

- **Not fixed, and deliberately left for a decision.** This block has absorbed every marketplace
  version from **3.0.0 through 6.0.0** without ever being cut into dated release headers — the last
  one is `[2.7.0] - 2026-06-04` — and the repository has **no git tags at all**, so no version here
  corresponds to a tagged release. Splitting it needs release dates that only the author can
  assign.

### Removed
- **Guild CLI — `plugins/guild/scripts/` deleted entirely (BREAKING).** 24 files, 34,182 lines: the `guild` dispatcher, all 17 `lib/` modules, the 8,918-line `test-guild.sh` harness, `dashboard.tmpl.html` and `scripts/README.md`. `plugins/guild/templates/*.yaml` went too — the execution templates are knowledge now, at `skills/warehouse/references/templates/*.md`. **Every `guild <verb>` invocation is gone**; nothing replaces the command surface, because the replacement is SQL.
- **Project Management Plugin** — removed `plugins/project-management` and its marketplace/README entries
- **Session Tracker Plugin** — removed `plugins/session-tracker` and its marketplace/README entries

### Changed
- **Guild Plugin v7.0.0 — the roster leaves the database (BREAKING).** `agent`, `agent_capability` and `capability_request` are dropped. They were a **mirror**: every fact in them — a member's name, model, capabilities, whether it runs serially — is already declared in the frontmatter of that member's own markdown file, and the SQL copy was the one that went stale. It was only ever as fresh as the last `sync-agents` somebody remembered to run, so a new agent file was invisible to the matcher until then. Worse, the mirror could only see the plugin's own `agents/` directory, while the user has subagents from their project, their home directory and every other installed plugin.

  **`task_capability` stayed, and it is the one that was never a mirror.** It records what the *work* needs, which is board data. What left is the claim to know who can do it.

  **Six views went with the tables.** `v_agent_eligible`, `v_agent_match` and `v_task_top_agent` were the matcher; `v_capability_vocabulary`, `v_capability_unknown` and `v_roster_gaps` were its audits. **The rule they encoded did not die, it moved into the dispatcher** (`guild:check-in` §3.3), unchanged: a pin wins outright and skips the match; otherwise eligible means the member's declared capabilities are a superset of the ticket's `required = 1` set, ranked by preferred-covered DESC, then fewest total capabilities ASC (a specialist beats a generalist), then name ASC for determinism. `skills/check-in/scripts/roster.py` reads the frontmatter and applies the superset test and the last two keys — `--covers implement,svelte` prints the eligible members, specialist first, and no output is a roster gap.

  **`v_open_bounties` and `v_blocked_tasks` changed what they promise, and the difference matters.** The bounty board's third condition used to be "somebody can take it", verified against the roster; it is now "the ticket asks for somebody" — a pin, or at least one capability row. A row there is a candidate for dispatch, not a guarantee of one. `v_blocked_tasks` lost the `no-eligible-agent:rust,embedded` reason it could no longer compute; a ticket nobody covers now sits in the bounties once, and then the **dispatcher writes `status = 'blocked'`**. That write is load-bearing: no view derives it, so skipping it leaves a board on which nothing knows there is a gap, and a shift re-picks the same ticket all night. The gap is then read as `SELECT id, who FROM v_blocked_tasks WHERE reason = 'status-blocked'`, and each `needs:…` names the agent file somebody has to write.

  **Recruiting is writing a file, and nothing precedes it.** A `capability_request` row existed to admit a word to a vocabulary this database owned; once the vocabulary is "what the agent files declare", that row is bookkeeping about bookkeeping. The architect records a gap in the plan's Technical Decisions (which rides through `gate-plan`) and raises it live as `NEEDS INPUT: ROSTER GAP`. Creating the agent is still the guild master's call alone — and now that a capability is admitted by writing a file rather than by a row somebody approves, that boundary is the only thing between a gap and an invented member.

  **`task.claimed_by` lost its foreign key** to `agent(name)`, which required a table rebuild. It and `task.agent` are plain TEXT now, deliberately: a done task from months ago may name a member whose file is gone, and it still reads correctly.

  **Assertions that crossed the database/filesystem boundary are gone, and `docs/expectations.md` says so rather than pretending.** G5 became *ticket routing* — every open ticket pins a member or declares what it needs — and its seven roster clauses are replaced by `roster.py --covers`, run by the architect at plan time and the dispatcher at dispatch time. G9's serial check can now only report a member holding two in-flight tickets; whether that member is serial lives in frontmatter. §7 C.a keeps the pinned case and loses the capability path. §12.b's "a shift never recruited" is now `git status --porcelain agents/`. Each of these is documented as a trade, not quietly dropped.

  **Migrating a live board is one script, then the schema.** `plugins/guild/migrations/007-roster-leaves-the-database.sql` drops every view and trigger (the `ALTER TABLE ... RENAME` in the `task` rebuild re-parses the whole schema, and `trg_requirement_moved` reads `task` — leaving it standing makes the rename fail and takes the `task` table with it), rebuilds `task` without the foreign key, drops the three tables, and stamps `schema_version = 7`. Then re-apply `schema.sql`. **Order is not optional and the migration is not idempotent.** `event` rows whose `subject_type` is `agent` or `capability_request` are deliberately left alone — they are the record of a board that really did recruit those members, and `v_recent_activity` resolves an unknown subject type to a blank title rather than failing. Verified end to end against a populated v6 board: 21 tables, 23 views, 40 triggers, data and history intact, `PRAGMA integrity_check` ok.

  **Fixtures lost `00-roster.sql`**, because a seed script cannot fake a roster any more. `empty` now reads `21|23|40|7|0`; `messy` blocks `TASK-010` alongside `TASK-009` (its gap has nowhere else to live) and its brief drops `roster_gaps` and `capability_unknown`. The §5.b roll call swapped `roster-gap`/`capability-unknown` for `blocked-needs`, fired off `v_blocked_tasks.who` — and lands on exactly 27 rows again, the same facts attached to the ticket that is actually stuck.

- **Guild Plugin v6.2.0 — `phase` becomes `project`, and a plan gets an approval (BREAKING).** The direction layer said *phase*, which means *stage*, and the table said the same thing structurally: `ordinal NOT NULL` and a `v_goal_progress` that reported exactly one "current phase" per goal. That shape could not express the thing the guild master actually wanted — **a group of work that can run beside its siblings, or in its own git worktree**. So `phase` is now `project`, `PHASE-NNN` is `PROJ-NNN`, and `requirement.phase_id` is `requirement.project_id`.

  **Four new columns on `project`, and one that loosened.** `ordinal` is **nullable** — NULL means *unordered*, waits for nobody, and is not the same as *first*. `concurrent` (default `0`) says whether the project may run beside its siblings or waits for every lower-ordinal sequential project in its goal. `isolation` (`shared` | `worktree`, default `shared`) and `worktree_path` say **where** its tasks run; a table-level CHECK stops a `shared` project from carrying a path, because a path nobody honours is worse than no path. `priority` (1–5) closes a real gap — every other level of the hierarchy had one and this one did not, which made ranking two parallel projects impossible. `body` was added for symmetry with `goal`, `requirement` and `task`.

  **The parallelism rule has exactly one definition: `v_projects_runnable`.** A project earns a place there by being `concurrent`, by being unordered, or by having every lower-ordinal *sequential* sibling done — and a concurrent sibling never blocks a sequential one, because a project that opted out of the queue does not get to hold it. `v_project_progress` is the same list with requirement and task counters and a `runnable` flag *derived from that view* rather than restated. `v_goal_progress` lost `current_phase_id`/`current_phase_title` — a claim the schema can no longer make — and reports `projects_total`, `projects_done`, `projects_runnable` and a display-only `runnable_project_ids` instead.

  **`plan.status` and `plan.approval` are now two columns, because they were always two questions.** `status` (`todo → in-progress → done`) is the architect's drafting lifecycle: *is the document written?* `approval` (`pending → approved | rejected`, with `approved_by` and `approved_at`) is the user's ruling: *did anyone agree?* The old single column could not tell "finished writing, waiting on a person" from "agreed and building" — the most important distinction on the board. `gate_node_id` links a plan to the `gate-plan` node carrying the same decision so a reader can go from either end, and `v_plans_pending_approval` is the queue. **Approving is now three writes** — the gate row, the graph node, and `plan.approval` — and the schema does not keep them in sync; that is items 9 and 10 of the header's "what this file cannot enforce" list, alongside the fact that **nothing creates, verifies or cleans up a worktree**. The column records a decision; honouring it is the orchestrator's job.

  **Migrating a live board is one script, then the schema.** `plugins/guild/migrations/006-project-and-plan-approval.sql` moves the data — it rebuilds `project` from `phase` (a rebuild, not a rename: `ordinal` had to lose `NOT NULL` and the table-level CHECK cannot be added by ALTER), renames the requirement column, adds the four plan columns, rewrites `PHASE-NNN` ids and the `event` rows that point at them, and stamps `schema_version = 6`. Then re-apply `schema.sql` for the views and triggers. **Order is not optional and the migration is not idempotent** — the second run fails on `CREATE TABLE project`, which is the safe direction to fail. Old `event.payload` values still say `"phase_id"` and are deliberately left alone: they are the record of what was written at the time. Plans already at `status = 'done'` are backfilled to `approved` by `migration-006` rather than `pending` — what was already built was already agreed to, and backfilling `pending` would put every historical plan into the approval queue on the next check-in.

  **Verified, not assumed.** The schema applies clean to a fresh board (24 tables, 29 views, 45 triggers, version 6); the migration was run end to end against a seeded v6.1 board and the views were read back on the other side; all five fixtures in `docs/expectations-fixtures.md` load without error against the new schema; all 63 read-only guard queries in `docs/expectations.md` run clean across the empty, messy and maintenance fixtures; and the `brief` and `dashboard` skills' full SQL scripts were executed and their JSON keys checked.

  **Everything downstream was updated with it**, not left to drift: `schema.sql`, `README.md`, `docs/v6-architecture.md`, `docs/expectations.md` and `docs/expectations-fixtures.md` (including the new `task-built-on-unapproved-plan` and `project-done-over-open-requirement` assertions), the `warehouse` guide and its `schema.md`/`queries.md` references, and the `new-requirement`, `check-in`, `shift`, `brief`, `dashboard`, `clear-board`, `qa` and `validate` skills. `check-in` and `shift` now stop for a pending plan approval **even when no gate row exists behind it** — a plan approved in conversation has no gate to surface it, and without that query it would be invisible. `new-requirement` writes the third approval statement at `gate-plan` and offers `concurrent`/`isolation` only when the user's own words invite it; the architect is told plainly that `plan.approval` is not its column and that a `shared` project means sibling projects may be editing the same tree. `docs/v5-design.md` stays historical, with its "still authoritative" note corrected to name this rename. Versions: guild **6.1.0 → 6.2.0**; marketplace **5.0.0 → 5.1.0**.

- **Guild Plugin v6.1.0 — the schema is the tool (BREAKING).** The plugin is no longer a program. It is **a schema and a set of skills**: `plugins/guild/schema.sql` plus the knowledge that teaches a guild member to use it. The guild master's reasoning — *"when the turso CLI is already installed, we have a tool that can execute SQL; we don't need to build another tool that does the same thing"* — is the whole of the change. `tursodb` **is** the tool; members write their own SQL; `skills/warehouse/` is the guide at the door.

  **The rules moved from the wrapper into the engine, where they are harder to skip.** `schema.sql` is now 25 tables, 26 views and 43 triggers. **CHECK constraints** carry the status vocabularies and enums — a value outside its enum is rejected on every connection, from every member, forever. **Views** carry the derived rules: the cursor rule, the review gate, node readiness, the agent matcher, the board and the brief each have exactly ONE definition, so a member SELECTs from `v_next_task` instead of writing its own idea of "next" and two members cannot get two answers to one question. **Triggers** carry the record: every meaningful mutation writes an `event` row and stamps `updated_at` without anyone remembering to. *A member can forget to call a command; a member cannot bypass a trigger or a CHECK.*

  **Read this before trusting any of it.** The v5 CLI had four adversarial review rounds and a 2,278-check suite behind Stages 1–3. **None of that carries over — it belonged to code that no longer exists**, and v6 ships with **no tests at all**, by the guild master's explicit direction. What *is* verified: `schema.sql` applies cleanly and idempotently, the tursodb engine constraints were each established by running the construct (no `WITH RECURSIVE`, no FTS5 — observed failures, not guesses), and individual queries in `references/queries.md` were run as they were authored. What is not: nothing has exercised the guild end to end. The plugin README says exactly this in its *Status* section rather than implying continuity of confidence.

  **Be equally clear about what is no longer enforced.** Several v5 guarantees were bash guards and are conventions again, documented in the `schema.sql` header, the README and `docs/v6-architecture.md` §4 — and nowhere enforced. The largest: **"the orchestrator owns every status transition"** cannot be expressed in SQL, which has no identity. `guild_state.actor` is a courtesy label a member sets on itself; the triggers copy it into `event.actor` verbatim, so a lying actor produces a lying feed. Also conventional now: a requirement may not close over a blocked task; the `failed`-task waiver is a work-log line *prefix* matched with `LIKE`, not a column; plan-slice file disjointness is the architect's assertion; an unknown capability inserts fine and simply matches nobody (a CHECK cannot reference another table); `gate.status` is a column anyone can write; and the graph is not acyclic by construction — a cycle is a silent stall in `v_ready_nodes`, undetectable without `WITH RECURSIVE`.

  **The price of moving vocabularies into the engine, stated plainly.** SQLite cannot `ALTER` a CHECK in place, so widening a status vocabulary means rebuilding the table (create / copy / drop / rename, `foreign_keys` off for the swap). **Adding a word is a migration.** Relatedly, applying `schema.sql` over a database created by an earlier v5 stage lands the new views and triggers but **not** the CHECKs — `CREATE TABLE IF NOT EXISTS` sees the table and moves on. A board that wants them rebuilds.

  **Other structural consequences.** *There is no journal* — `event`, written by triggers, is the record, which makes `guild.db` the durable board rather than derived state that can be thrown away and replayed; `guild:clear-board` now warns that a `DELETE` is final. *There is no spool and no drain* — agents write their own `work_log` and `review_finding` rows straight into the board instead of appending to a per-task file the orchestrator folded in. Applying the schema is idempotent and is how a rule change reaches a live board: views and triggers are dropped and recreated every run.

  **Documentation.** `plugins/guild/README.md` rewritten for v6 (the model, setup, the views-as-API table, the roster, and an honest *Status* section). New `plugins/guild/docs/v6-architecture.md` — the pivot, the warehouse metaphor, what CHECK/VIEW/TRIGGER enforce, what is convention, the engine constraints and the file layout. `plugins/guild/docs/v5-design.md` is **kept deliberately** and carries a prominent header: it describes the deleted CLI, but the data model (§3.2), the roster and matcher (§5), the execution graph and templates (§6) and the unattended shift (§8) remain authoritative, while the driver layer (§2.2), the journal (§2.3) and the CLI surface (§4) are historical. Versions: guild **5.0.0 → 6.1.0**; the marketplace goes **`4.2.0` → `5.0.0`** — the guild rewrite is breaking and two plugins left the catalog in this same block. **The v5 entry below is superseded** — it is retained as the record of how the data model and the rules were reasoned out, all of which v6 inherited unchanged.

- **Guild Plugin v5.0.0 — the guild: a roster, an execution graph, two gates, and a shift it can work while you sleep** — Stages 3, 4 and 5 of the five-stage v5 design (`plugins/guild/docs/v5-design.md`), completing it. **No schema migration at any point**: every table shipped in `schema.sql` with Stage 1, which is why three stages of behaviour landed without one.

  **Read this first — the five stages did not get equal scrutiny.** Stages 1–3 were adversarially reviewed over several rounds behind a **2278-check harness** (`scripts/test-guild.sh`), which also enforces the portability rules statically over `schema.sql` and the SQL embedded in `lib/`. **Stages 4 and 5 were implemented with no tests and no adversarial review round, at the guild master's explicit direction.** They parse, they lint clean under `shellcheck -S style` with no suppressions, their embedded awk programs parse-check, and Stage 5 closed with a reconciliation pass over both — but no Stage 4–5 behaviour has been executed against a real board. The plugin README says so in a *Status* section rather than presenting v5 as uniformly proven, and that asymmetry is the single most important thing in this entry.

  **Stage 3 — the roster (shipped as `5.0.0-beta.3`; summarized here, detailed in the entry below).**
  - **A ticket declares what the work needs.** `guild new task --needs implement,frontend [--prefers svelte]` writes `task_capability` rows, and any roster member whose capabilities cover the required set is eligible. `--agent` is no longer mandatory — one of the two is — so the roster stops being hardcoded into the skills and the chain. Adding `agents/developer-rust.md` with the right tags makes it eligible with **no skill edits and no chain rewiring**.
  - **`guild sync-agents` builds the roster from agent frontmatter** (`capabilities:`, `serial:`), idempotently: new members added, removed members **deactivated** rather than deleted, capability sets replaced. A file it cannot parse is a refusal that names the file — a mis-parsed roster does not fail, it silently matches the wrong work. `guild init` seeds it, and cannot fail init by doing so.
  - **`guild match` is deterministic — no model judgment.** Eligible = capabilities are a superset of the required set; ranked by preferred covered (desc) → total capability count (**asc**, so a specialist beats a generalist) → name. A pin is rank 1 with source `pin`, with the capability-eligible members still listed beneath it so the deviation is visible rather than merely obeyed.
  - **`guild bounties` is the bounty board** — what can be worked, and underneath it everything that cannot with a single blank-free reason token (`status-blocked`, `deps:<ids>`, `no-eligible-agent:<caps>`).
  - **`blocked` is a new task status, and it is loud.** It means *no guild member can take this bounty*. For requirement completion it counts as **open**, so nothing ever closes over un-attempted work, and `blocked → done` is the CLI's one refused transition.
  - **Recruiting: a gap is filed at plan time.** `guild capability-request` records a capability the roster lacks and **admits it to the vocabulary** so an agent file declaring it will sync. Only `guild sync-agents` closes one, by admitting the agent — and an unattended shift may never create one. The **capability vocabulary is closed** (17 words) on the agent side and deliberately open on the task side: `--needs kotlin` matches nobody and reports `no-eligible-agent:kotlin`, which is loud within one dispatch.

  **Stage 4 — the execution graph, and the two gates.**
  - **The chain is data.** Through Stage 3 the order of work was compiled into the skills — check-in *knew* review follows test-write. Now it is `templates/{standard,maintenance}.yaml`, instantiated per requirement into `graph_node` / `graph_edge` / `gate` rows by `guild graph new`, and **`guild segment` is what says what runs next**. A project overrides either template by name at `.guild/templates/<name>.yaml`.
  - **Two gates, always, and neither can be added or dropped.** `gate-plan` before anything is built; `gate-repairs` after review, where findings, bugs and failures are presented as **one** multi-select decision — the decision *is* the fan-out. `guild graph deviate --kind add-gate` is refused, always. Gates cannot live inside a workflow because subagents cannot call `AskUserQuestion`: segmenting at gates is the only shape that preserves guild-master control.
  - **Deviation with teeth.** `guild graph deviate --kind add-node|drop-node|reshape` requires a reason, `add-node` requires `--needs` covered by an active member, and `guild graph validate` checks twelve rules against what is **stored** (rows also arrive by journal replay).
  - **`guild segment` refuses illegal concurrency one command earlier than designed.** A parallel batch holding two `serial` members (`qa-tester` — Playwright collides on ports) exits 1 naming both nodes rather than being emitted, so no compiler, Workflow or fallback, can act on the illegal shape.
  - **Readiness is one hop, never a traversal.** `WITH RECURSIVE` is unsupported on TursoDB, so a node is ready when every **direct** predecessor is `done` or `skipped` — one predicate, called by the render, the segment sweep, the gate refusal and the shift, because two spellings of readiness is two answers to "what runs next".
  - **`guild node` was missing from the design entirely** and nothing could have run without it: it is the work-node writer, and moving a node is what propagates readiness. It refuses a gate node — a gate's status is a decision, and `guild gate` is where one is recorded. `guild gates` gained a **readiness column**, because a pending gate whose predecessors are still running is awaiting the *guild*, not the guild master.
  - **One YAML parser, reconciled from two.** `lib/template.sh` is a projection of `lib/graph.sh`'s scanner rather than a second scanner. The two had disagreed about the default `fanout:`, about legal indentation and about backslash escapes — and the divergence would have been invisible, because `guild segment` degrades *silently* when it cannot read a node's `parallel:` mode and would have quietly run everything sequentially.
  - `guild:check-in` was rebuilt around segments and gates (793 → 648 lines); `guild:new-requirement` now ends at `gate-plan`, so **nothing is built until you approve the plan**; the architect writes a graph instead of tickets one at a time. Workflow compilation — including what a crashed workflow leaves behind — lives in `skills/check-in/references/workflow-compilation.md`, loaded on demand, because the non-Workflow fallback is complete on its own.

  **Stage 5 — the unattended shift.**
  - **Run until the next gate, then stop and notify.** A segment is by definition everything that can run without asking anyone anything, so the segment boundary and the stop boundary are the same line — and unattended mode needs no separate notion of *how far may it go*.
  - **`guild shift` is the loop's controller, not its runner.** A shell script cannot dispatch an agent, so it is called once per turn and answers exactly one question — *what now* — with `run` or `stop`. It deliberately does **not** re-emit the batches: `guild segment` already produces that document, and a second answer to "what runs next" is the divergence the module layout exists to prevent.
  - **The shift record lives in `event` and only in `event`** — `started` (whose payload *is* the budget), `stepped`, `ended`, plus `retried` / `gave-up` / `blocked`. Every derived fact is a scalar subquery over them. Insert-only state means a crashed shift is not a corrupt row: it is a `started` with no `ended`, which the next call resumes and `guild shift --end` closes. Nothing is repaired by hand.
  - **Budget, and why it cannot be moved from inside the loop.** Defaults 10 tasks / 60 minutes, **fixed when the shift opens** — passing the same values every turn is fine (a `/loop` entry does exactly that), passing different ones is refused with nothing written. The unit is a *graph node this shift moved*, counted once however many times it moves, so a retry costs nothing.
  - **Seven stop reasons, in a fixed precedence, computed in SQL inside the transaction that records them** — so the directive on stdout and the row in the database cannot disagree. `gate` outranks the ceilings (reaching a gate is the shift *succeeding*); `infrastructure` outranks them too, because a stalled loop reported as `max-tasks` is a lie that costs a whole night. "Repeated infrastructure failure" is made mechanical as a **stall detector**: two steps in a row that moved no node.
  - **The policy table is enforcement, not commentary.** Every action a step can take is guarded by a lookup into the same list `guild shift --policy` prints, so moving a row from MAY to MAY NOT stops the statement being *generated* — in the live path and in `--dry-run` together. **`--dry-run` is not a description of the policy; it is the policy, run with the writes left out.** An unknown verb is denied: a typo must fail closed.
  - **Git safety is its own module with one allowlisted door.** `guild git branch-for | commit-task | revert-task | shift-status` is the entire surface, and every invocation goes through one wrapper: a verb **allowlist** (`push`, `fetch`, `pull`, `merge`, `rebase`, `reset`, `cherry-pick`, `clean`, `tag` are simply absent), a flag denylist (`--force`, `--hard`, `--amend`, `--no-verify`), hooks never bypassed, and `commit.gpgsign=false` — a machine commit must not carry the guild master's signature. `branch-for` refuses a dirty tree the shift did not create, because `git switch` *carries* uncommitted changes with it. `commit-task` refuses to mis-attribute a diff when sibling tasks are still uncommitted (`--path` or `--all`). **`revert-task` deletes nothing** — the diff goes to `.guild/backup-revert-<TASK>-<ts>/` and untracked files are *moved* there.
  - **`guild shift-report` is the morning read, and it is not a section of `guild brief`.** The brief reports **state** ("where does the project stand"); the report reports **events** ("what happened while I was away"), windowed by default to where the last shift began rather than to the last check-in. Neither mutates anything.
  - **`guild:shift` is `guild:check-in` with the human taken out of the middle.** The dispatch protocol is *referenced, not restated* — two copies would drift. What it adds: the authorization table said out loud before the first turn, a budget agreed once, `NEEDS INPUT:` treated as a node failure (nobody answers on the user's behalf at 3am), a file collision that stops the shift rather than filing a bug and continuing, and **never deciding a gate — not "the obvious ones"**. Cadence (`/loop`, cron) and notifications are opt-in per project; a shift pushes on exactly two events, a gate arriving and an abnormal stop, because one that notifies for everything trains you to mute the one that mattered.

  **Consistency fixes found reconciling three modules written in parallel with no suite running between them.** `lib/gitsafe.sh` had re-derived the journal write path instead of calling the shared one. `lib/shift.sh`'s header asserted the CLI "has never shelled out to git and Stage 5 is the worst possible moment to start" — while its sibling module was adding `guild git`; the split is now stated as the design it is. Two writers of the `ended` event disagreed by one key (`steps`), so a hand-ended shift reported "0 step(s)". The marker-channel spec in `lib/shift.sh` had drifted from the SQL beneath it. And three stale documentation facts were corrected: the dashboard has **seven** views and was documented as six, `guild plan slice` exists and the README still said `plan_slice` had no writer, and `GUILD_TEMPLATES_DIR` was undocumented.

  Versions: the guild plugin goes **`5.0.0-beta.3` → `5.0.0`** and the marketplace stays `4.2.0`. `guild:release` is what cuts the tag.
- **Guild Plugin v5.0.0-beta.3 — the roster: tasks name a capability, not an agent** — Stage 3 of the five-stage v5 design (`plugins/guild/docs/v5-design.md`), building on Stages 1–2 below. **No schema migration**: all four tables shipped in `schema.sql` with Stage 1, and `blocked` needed no DDL because the status vocabulary was never a `CHECK`. Stages 4–5 (the execution graph, segments, gates, templates, the maintenance cycle, the unattended shift) are still **not** shipped.
  - **A ticket declares what the work needs.** `guild new task --needs implement,frontend [--prefers svelte]` writes `task_capability` rows, and any roster member whose capabilities cover the required set is eligible. `--agent` is no longer mandatory — one of the two is — so the roster stops being hardcoded into the skills and the chain. Adding `agents/developer-rust.md` with the right tags makes it eligible for work with **no skill edits and no chain rewiring**, which is the payoff the design calls the point of v5.
  - **`guild sync-agents` builds the roster from agent frontmatter.** `capabilities: [implement, frontend]` (inline or a block list) and `serial: true` are read from `agents/*.md` into `agent` + `agent_capability`. Idempotent: new members added, removed members **deactivated** rather than deleted (a finished task may still name one), capability sets replaced. A file it cannot parse is a refusal that names the file — a mis-parsed roster does not fail, it silently matches the wrong work. `$GUILD_AGENTS_DIR` overrides where it looks. All 14 shipped agents now declare capabilities.
  - **`guild match` is the matcher, and it is deterministic — no model judgment.** Eligible = capabilities are a superset of the required set; ranked by preferred covered (desc) → total capability count (**asc**, so a specialist beats a generalist) → name (asc, so ties are stable). Rank 1 is the dispatch target. A **pin** (`--agent A` alongside `--needs`) is rank 1 with source `pin`, and the capability-eligible members are still listed under it so the deviation is visible rather than merely obeyed.
  - **`guild bounties` is the bounty board.** Open, dependency-satisfied tasks with their matched member — and, underneath, everything that *cannot* be worked with a single blank-free reason token (`status-blocked`, `deps:<ids>`, `no-eligible-agent:<caps>`), so `awk '$5 ~ /^no-eligible-agent/'` is the roster-gap query. It reports the condition without acting on it: the orchestrator still owns every status transition.
  - **`blocked` is a new task status, and it is loud.** It means *no guild member can take this bounty* — a roster gap, not a verdict on the work. It has its own section on `guild board`, a filter on `guild list task`, a section in `guild brief`, a row on the dashboard, and a reason on the bounty board. **For requirement completion it counts as open**, like `todo` and unlike (adjudicated) `failed`, so a requirement can never close over an un-attempted slice and the review gate keeps waiting. `guild next` never hands one out. **`blocked → done` is refused** — the CLI's one refused transition — with a message naming the three real exits (`todo` if you recruited, `in-progress` if you are assigning it anyway, `failed` if you are giving up).
  - **Recruiting: a gap is filed at plan time, not discovered at dispatch time.** `guild capability-request <cap> --req REQ-NNN --rationale "…" --proposes NAME` records a capability the roster lacks, and **admits that capability to the vocabulary** so an agent file declaring it will sync. One capability is one open request however many requirements need it; it cannot be withdrawn, and only `guild sync-agents` closes it, by admitting the agent. Design §5.4 surfaces this at `gate-plan` — **gates are Stage 4**, so the Stage 3 surfaces are `guild:new-requirement` (which asks you directly) and **`guild brief`'s *Roster Gaps* section**, which had existed since Stage 2 and was unreachable until this command started writing the table. An unattended shift may never create an agent; nothing here does.
  - **The capability vocabulary is closed** (design §5.3, 17 words). `sync-agents` refuses an agent file declaring a capability outside it, because two members tagged `e2e` and `end-to-end` is a matcher that quietly stops working. The **task** side is deliberately not enforced: `--needs kotlin` is accepted, matches nobody, and reports `no-eligible-agent:kotlin` — a typo is loud within one dispatch, which beats a second copy of the vocabulary that has to be kept in sync forever.
  - **Backward compatibility is explicit, and it is the presence of a capability row.** A task with **no** `task_capability` rows matches its own `task.agent` directly, without consulting the `agent` table at all — so every board built by Stages 1–2, and any guild that never ran `sync-agents`, behaves exactly as it does today. (Not "fall back when the match finds nothing": an empty required set is vacuously covered by *every* member and would match all of them.) A task that *did* declare capabilities gets no rescue from `task.agent` — that is a roster gap, which is the point of declaring them. Stage 3 is opt-**in**, one `--needs` at a time.
  - **`guild init` now seeds the roster**, so no guild is born with an empty `agent` table (design §4). It runs last and **cannot fail init** — a missing `agents/` directory prints its diagnostic on stderr and leaves a working guild — and it **stands down when the journal already carries the roster**, so a fresh clone (`guild.db` is gitignored) does not append duplicate journal lines on every checkout; `guild rebuild` replays it instead. `sync-agents` stays a command because admitting a new member must never require re-initializing anything, and `guild:check-in` step 1 and `guild:new-requirement` both run it. A guild initialized *before* Stage 3 needs neither: every ticket on it names an agent, and the first `--needs` ticket that cannot be placed makes the empty roster loud.
  - **Consistency fixes found reconciling the parallel work.** `guild match`/`guild bounties` now honor a pinned agent, which `guild list` and `guild board` had always displayed — a ticket pinned to `developer-svelte` listed as `developer-svelte` and dispatched to `developer`. `guild brief` now shows `needs:frontend+implement` for a capability-routed ticket through the same shared expression the board and the list use, instead of calling it `unassigned`. And seeding the roster no longer makes a brand-new guild report itself as non-empty: the emptiness test counts board events, while `events_total` keeps its plain meaning so it still agrees with the dashboard's fact of the same name.
  - `guild:check-in`, `guild:new-requirement`, `guild:brief` and the `architect` / `product-owner` / `qa-strategist` / `qa-tester` agents were updated to load the roster, write capability-bearing tickets and route a gap. `scripts/README.md` documents the matcher, the fallback, `blocked` and the sync timing in full. Harness: **1848 checks, 0 failures**.
- **Guild Plugin v5.0.0-beta — Turso storage and the visibility layer (BREAKING)** — Stages 1 and 2 of the five-stage v5 design (`plugins/guild/docs/v5-design.md`). Stages 3–5 (the capability roster, the execution graph and gates, the unattended shift) were **not** shipped at this point — Stage 3 landed in `5.0.0-beta.3` above; their tables exist in `schema.sql` so no stage needs a migration, and the surfaces that read them render as empty sections rather than as errors.
  - **The board is a database, not a directory tree (Stage 1).** `.guild/guild.db` — a Turso/SQLite database — replaces the `{todo,in-progress,done,failed}/` ticket directories, `state.yaml` and every ticket file. **Status is a column**, written only by `guild move`; IDs are derived in SQL (`MAX(n) + 1` in the same statement as the insert, so two creates cannot collide) and the cursor is derived (the current task is whatever row is `in-progress`). `last-checkin` is a row in `guild_state`. The CLI's read surface is deliberately unchanged — same names, same arguments, same stdout — only the source of the bytes changed.
  - **Storage runs in local mode; cloud mode is refused, on purpose.** `guild init` defaults to a local `tursodb` database needing no account, token or network, and prints the install line rather than failing with "command not found". `guild init --mode cloud` exits with an explanation: the cloud driver has no machine-readable output flag (every parser assumes `tursodb -q -m list`), its FK preamble differs, and its URL would travel in argv. `config.yaml` stores the **names** of environment variables and never a credential, enforced before any file is written.
  - **Durability is two committed artifacts.** `journal.ndjson` is an append-only log of the *resulting row state* per mutation (a change log replays across CLI versions; a command log does not) — `guild rebuild` replays it into a fresh database, `guild journal compact` refuses to lose a row unless forced, `guild journal recover` folds quarantined lines back in, and `guild journal sync` reconciles the append-only record tables. A `journal_preflight` runs *before* the SQL in every mutating command, so an unwritable or conflict-marked journal is a refusal that says nothing was written. `guild export` regenerates one deterministic markdown file per requirement as the PR-reviewable snapshot; it is **output only**.
  - **`guild path` is REMOVED (breaking for any custom automation).** It named a file agents used to Edit, and v5 has no such file — it exits 1 naming its replacements. `new`, `move` and `next` print the **bare ID** instead of `<ID> <path>`. Read with `read` / `meta` / `slice`; write with `move` / `retitle` / `checkin` / `new`. `guild migrate` and the pre-3.0 flat-file format are retired.
  - **Agents write through a spool, not a document.** In local mode every CLI invocation is its own process, so concurrent agents cannot share a connection: `guild log` and `guild finding` append one NDJSON line to `.guild/spool/<TASK-ID>.ndjson`, and the orchestrator folds them in as the single writer with `guild spool drain`. A line that cannot be imported is copied to `.guild/spool/rejected/` (committed — it is the only surviving copy) and reported before the spool is unlinked. **Draining is not optional**: an undrained ticket renders an empty Work Log, which check-in's triage reads as never-started.
  - **Direction above the board (Stage 2).** New `goal` and `phase` layers — `guild goal new|list|show|move|priority`, `guild phase new|list|move`, `guild req assign REQ-NNN <PHASE-NNN|none>`. A goal is long-lived intent with a priority; a phase is an ordered stage of one goal, its ordinal derived as `MAX+1` when omitted. `requirement.phase_id` is nullable by design — unaffiliated work stays legal — and goals and phases **organize but do not gate**. `guild:new-requirement` now offers a placement (existing phase / new phase / new goal + phase / unaffiliated) once, and only the user's answer creates one.
  - **Bugs and coverage are rows, not prose.** `guild bug new|list|show|fix|close` (`--req` optional, because defects are found outside a requirement's scope all the time; `wontfix` is a real outcome, not a lesser `fixed`) and `guild coverage set|inspect|list|show`. `qa-tester` files defects with `guild bug new` instead of appending to `.guild/qa/ledger.md`, and stamps the areas it actually drove with `guild coverage inspect`; `qa-strategist` writes one `coverage` row per quality area. `coverage set` is an upsert that never touches the inspection clock, and `coverage list --due` is `guild brief`'s own predicate — never inspected, or stale past a risk-weighted threshold (high 14 days, medium 30, low 90).
  - **Two new read surfaces, and a new skill for each.** `guild brief` / **`guild:brief`** — one query behind Direction, In Flight, Blocked, Open Bounties, Bugs, Coverage, Since Last Check-in and Roster Gaps, with a `Next:` header byte-identical to `guild next`; empty sections are omitted and an empty guild gets three next steps rather than eight `(none)` blocks. `guild dashboard` / **`guild:dashboard`** — a self-contained `.guild/dashboard.html` with six views (Roadmap, Board, Graph, Bugs, Coverage, Activity), all CSS and JS inline, deterministic bytes, no server and no network. Both are strictly read-only: rendering the board is not a change to it, so neither writes a journal line or an `event` row. `guild:check-in` now opens with the brief.
  - **`guild:guild-status` is a deprecated alias** that loads `guild:brief`. It deliberately claims **no** natural-language trigger phrases — two skills advertising "guild status" would make every status request a coin flip — and exists only so the typed `/guild:guild-status` keeps working.
  - **`guild:clear-board` now refuses instead of pretending.** v5 ships no `guild clear` and no `guild delete`, so the skill inventories the board, says plainly that nothing was changed, and offers the real alternatives (leave it, waive open work to `failed`, or `GUILD_DIR=.guild-next guild init`). **`guild:release` copies rather than moves**: it snapshots the export into `.guild/releases/{version}/` and leaves the requirements on the board, because v5 has no archive command and a file-moving step would report work it did not do.
  - **Every mutation is journaled and writes an `event` row**, which is what makes the brief's "Since Last Check-in" and the dashboard's Activity feed possible. Free text travels into SQL as hex (`CAST(x'…' AS TEXT)`) because tursodb's script splitter ends a statement at a `;` that terminates a line even inside an open string literal, and on the way out it can never impersonate a structural token — the board flattens it, the export uses a length-prefixed header, JSON goes through `json_object()`, and the dashboard escapes every `<` before it reaches the page. Two live injections (a fabricated board row, a phantom export file) were fixed at the source, per surface.
  - **Migration: v4 boards are ARCHIVED, not migrated.** `guild init` on a directory holding a v4 board **moves the whole tree to `.guild/v4-archive/`** — never deletes, never parses — and there is **no history import**. Two things carry over because they are evergreen rather than historical: `.guild/docs/*.md` into the `doc` table, and `.guild/qa/` into the `coverage` table (with `last_inspected_at` left null, so every area reads as due on day one). Unfinished v4 work is re-entered by hand through `guild:new-requirement`, reading the archived plan for the details. Nothing is lost: the archive stays plain markdown, in git.
  - Documentation caught up with the code: the plugin README, `scripts/README.md` and the check-in references now describe the database model, the two storage modes, the durability contract and the new commands — and state plainly which stages are not built yet. The guild plugin was **`5.0.0-beta`** at this point (Stages 1–2 of 5); it is now **`5.0.0-beta.3`** (Stages 1–3 of 5) and the marketplace is `4.2.0`.
- **Guild Plugin v4.0.0 — Live requirement planning, human-gated review (BREAKING)**
  - **Requirements and planning move out of the ticket board entirely.** `guild:new-requirement` now spawns the product-owner and architect directly (not as ticket types) for a live 3-way interview with the user — both relay questions through the orchestrator (`AskUserQuestion` is still main-session-only), and the architect creates every developer/test-planner/reviewer ticket directly via the CLI before the skill returns. `check-in` no longer dispatches `product-owner` or `architect` tickets; an empty board now prompts instead of auto-invoking `new-requirement`.
  - **`product-owner` and `architect` gain the `Agent` tool** and can spawn `guild:researcher` (Haiku) inline for quick lookups and codebase checks — the old two-ticket async research-gate handoff is gone; the architect just calls the researcher mid-session and keeps planning.
  - **Optional Agent Teams integration.** When `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` is enabled, the product-owner and architect message each other directly during the interview; otherwise the orchestrator moderates between two concurrently-spawned sessions. Both paths still relay user-facing questions the same way.
  - **The automatic review fix-loop is gone.** The 4 reviewers now only write findings (no more `Fix:` follow-ups, no round cap, no `ESCALATE` token) — the orchestrator compiles every round into `.guild/reviews/REQ-NNN.md` and asks the user (multi-select) which findings, if any, become fix tickets. Approved fixes are plain `developer` tickets with no forced test-writer/re-review tail, and there is no automatic re-review; another pass is just a fresh `reviewer` ticket like any other.
  - Developers/`developer-svelte` now relay unclear-requirement questions directly (`NEEDS INPUT`) instead of declaring a `Clarify: … | agent: product-owner` follow-up, since `product-owner` is no longer ticket-dispatched. `.guild/reviews/` archives alongside its requirement at release time (evergreen `.guild/docs/`/`.guild/qa/` are unaffected).
- **Guild Plugin v3.2.0 — Crash-safe resume, execution hardening, leaner token budget** (27 adversarially-verified audit findings fixed)
  - **"Continue where we left off" hardened end to end.** Follow-ups are now materialized *before* a ticket's terminal `guild move done` and each created line is annotated ` → TASK-NNN` (idempotent re-processing) — a crash can no longer strand a requirement with un-created chain tickets. Check-in stale triage is now three-case: empty Work Log → re-queue; completion/failure recorded in the log → record the outcome without re-dispatching the agent; otherwise resume with a new RESUMED-TASK dispatch variant. All worker agents now log a start entry + milestones (an interrupted agent is no longer indistinguishable from a never-started one), the product-owner persists interview answers into the REQ draft as it goes, and the architect logs its scaffolded PLAN-NNN immediately so a rerun resumes instead of orphaning a duplicate plan. A work-intent trigger ("let's get to work") resumes with zero routing questions.
  - **Execution correctness.** The orchestrator's follow-up materialization now parses/passes `parallel-group` (previously silently dropped — dev waves degraded to sequential) and a new `plan:` modifier emitted by the architect (previously the plan ID never propagated, leaving `plan-slice` unresolvable downstream). `guild list task` output gained `<agent> <requirement>` columns so the review-round cap and requirement-completion checks are actually executable via awk. `failed/` is now defined as user-adjudicated (waived): it doesn't block review or completion, and waived tickets are reported in the summary + CHANGELOG bullet. The QA bug loop now files each bug as a Fix + Re-verify qa-tester pair (previously nobody created the re-verify and QA fixes ran with no verification tail). All CLI `for $(ls …)` loops replaced with quote-safe globs — the board/cursor no longer break for repo paths containing spaces.
  - **Token efficiency.** The check-in skill no longer force-reads all three reference docs per session (~7k tokens, ~80% duplicated) — references are now load-on-demand with explicit triggers. New `guild meta <ID> [field]` prints frontmatter only; dispatch uses it instead of full `guild read`. The dispatch prompt dropped its "When done" boilerplate (duplicated in every agent definition). Developers read the REQ only when their self-contained slice doesn't cover it, and no longer re-read CLAUDE.md. The dead `priority:` follow-up modifier (emitted ~30×, consumed by nothing) was removed everywhere; "Adjust priorities" became an honest "Adjust the backlog" (retitle/drop; ordering is ID order). The redundant wrap-up `last-checkin` write was dropped.
  - **Consistency.** `scripts/README.md` caught up with the CLI (`batch`, `meta`, `is-legacy`, `migrate`, `--parallel-group`, list columns) and its example no longer clobbers `$PATH`; the release skill's pre-release gate now treats waived (`failed/`) tasks as warn-and-confirm instead of a hard block (only unresolved ESCALATE blocks) and uses the new list columns; the comprehensive-review skill and product-reviewer agent are now guild-board-aware and no longer hardcode another plugin's 8-phase methodology; architect's dangling "Step 4.5" reference fixed; task-lifecycle's orchestrator-procedure section reduced to a pointer at the canonical SKILL.md Step 3.4. A second adversarial verification pass (3 lenses) confirmed the edit set and closed 11 residual gaps it found (QA agents' resume protocol, full-pipeline recovery in stale triage, create→annotate duplicate guard, architect orphan-plan fallback).
- **Guild Plugin v3.1.0 — Pipeline refinement: parallel-by-default development, dedicated test planning, integration tests, diff-scoped reviews**
  - The per-requirement pipeline is now: requirements discussion & refinement (product-owner) → architecture & planning (architect) → **parallel development** (developer waves) → **test planning** (new `test-planner` agent) → **unit & integration test writing** (test-writer) → review (4 parallel reviewers) → done.
  - **Parallel development is the default, not the escape hatch.** The architect designs plan slices for disjoint file sets and organizes dev tickets into `parallel-group` waves (foundation solo first, then concurrent waves); ungrouped tickets are the exception, reserved for foundational or unboundable work. Mechanics are unchanged (`guild batch`, shared working tree, no worktrees) — only the planning posture flipped.
  - **New `guild:test-planner` agent** (Sonnet) runs after all dev work: inventories the implemented diff into a Changed Files Inventory, surveys the test infrastructure, maps acceptance criteria to unit and integration cases, writes the plan as `PLAN-NNN/slice-test-plan.md` (rides the existing slice mechanism — resolve with `guild slice PLAN-NNN test-plan`; zero CLI changes), and declares the test-writer ticket(s). The architect's tail is now `test-planner` + `reviewer`; the reviewer's N/N gate keeps the review last even though test-writer tickets get higher IDs.
  - **test-writer now owns unit AND integration tests**, implementing the test plan instead of re-deriving scope; it falls back to self-derived scope in the plan-less bug-fix flow. The QA discipline's `qa-tester` now owns e2e only.
  - **Token-efficiency:** the diff analysis happens once (test-planner) and is reused three times — the test-writer implements from it and all 4 reviewers scope their reading to its Changed Files Inventory instead of re-scanning the codebase; the check-in work cycle now flows continuously by default (one-line updates between tickets; pauses only on failure, escalation, collision, or requirement completion) instead of prompting after every ticket.
  - Fix loop unchanged (max 2 rounds), but the fix-loop test-writer ticket now carries `plan-slice: test-plan` when a plan exists; the test-planner is never re-run in the fix loop. Bug-fix flow (Chain 3) intentionally skips the test-planner.

### Fixed
- **Guild `clear-board` never actually cleared a board that had an approved plan.** `plan.gate_node_id` (added in v6.2.0) points forward into `graph_node`, and the skill's delete script broke only the `plan.task_id`, `review_finding.fix_task_id` and `bug.fix_task_id` cycles. `DELETE FROM graph_node` failed the foreign key and every delete after it failed too — and because tursodb has no `-bail`, **the script ran to the end and reported a clear that had not happened.** One line (`UPDATE plan SET gate_node_id = NULL`) fixes it. Found by running the skill's own script against the `messy` fixture while verifying the v7 changes; it reproduces identically on v6.2.0.

### Added
- **Research Plugin v1.0.0** — PhD-level multi-perspective research inspired by Stanford's STORM method
  - `research:storm-research` — orchestrates the full four-phase pipeline: parallel five-persona fan-out, contradiction mapping, synthesis into a cited briefing, and an adversarial peer review with an optional revision loop; each phase delegated to a dedicated sub-agent to keep the main context lean
  - `research:multi-perspective-scan` — STORM Phase 1 standalone; fans out the five persona agents in parallel for a fast multi-angle read
  - `research:contradiction-map` — STORM Phase 2 standalone; maps disagreements (with verdicts), the reliable core of agreement, and blind spots across a workspace, documents, or pasted viewpoints
  - `research:research-peer-review` — STORM Phase 4 standalone; audits any research artifact for hallucinations, bias, completeness, fair contradiction handling, and actionability, then assigns a reliability grade
  - Five persona agents (`practitioner`, `skeptic`, `economist`, `historian`, `academic`), each with an owned worldview and owned bias, gathering cited web evidence; plus `contradiction-mapper`, `synthesizer` (Opus), and `peer-reviewer` (Opus) analytical agents
  - Runs write to a reusable, gitignored `.storm/{topic-slug}/` workspace

### Changed
- **Guild Plugin v2.0.0 — Board simplification (BREAKING)**
  - Removed `.guild/BOARD.md` entirely. Task status now lives solely in each `TASK-NNN.md` (`todo` → `in-progress` → `done` / `failed`); a new `.guild/state.yaml` holds only the cursor (`current`) and ID counters. The board is rendered as a live view by scanning ticket and requirement files — eliminating the dual-store reconciliation the orchestrator did every cycle.
  - Replaced the three-way sequencing logic (follow-up declarations + ID-arithmetic auto-triggers + magic `depends-on` tokens) with a single cursor that walks tickets in ID order. Removed the `depends-on` field, the `all-developer`/`TASK-RESEARCH` tokens, the `blocked` status, and parallel-developer batching.
  - **Development is now sequential** (one developer ticket at a time). Review remains per-requirement and gated on all implementation tickets being done, then fans out to the 4 reviewers in parallel — the only parallelism left.
  - The architect now emits the test-writer + reviewer **chain tail** as real tickets up front (product-owner emits it in the bug-fix flow); the orchestrator only creates tickets for the fix-loop tail. Fix loop is capped at 2 review rounds by counting reviewer tickets per requirement.
  - Renamed reference `board-format.md` → `state-format.md`. Updated `check-in`, `new-requirement`, `clear-board`, `guild-status`, and `release` skills plus the architect, product-owner, developer, and developer-svelte agents accordingly.
  - **Migration:** no automatic path — clearing the board (`/guild:clear-board`) is the upgrade. Returning check-ins on a pre-2.0 guild are offered an in-place convert or clear.
  - Marketplace bumped to v3.1.0 — the v3 major mirrors this Guild breaking change; the v3.1 minor adds the new Research Plugin.

### Planned
- Test Plugin: Automated test generation and execution
- Review Plugin: Code review assistance and suggestions
- Deploy Plugin: Deployment automation workflows
- Docs Plugin: Documentation generation from code
- Web-based marketplace browser
- Plugin dependency management
- Version compatibility checking

## [2.7.0] - 2026-06-04

### Added
- **Guild Plugin v1.7.0**
  - Added `guild:verify-and-fix` — diagnoses and fixes reported errors through a structured five-phase workflow: detect/create the project's error-verification guide, collect the error artifact, investigate configured log and code sources, propose ranked solutions, then apply a test-driven fix

## [2.6.1] - 2026-05-24

### Updated
- **Guild Plugin v1.6.1**
  - `guild:svelte-env-vars-check` — stricter server-side enforcement: server files importing from `$env/*/public` are now a hard violation (previously advisory); migration step 5.3 added to strip `PUBLIC_` prefix and rewrite imports to `$env/*/private`

## [2.6.0] - 2026-05-22

### Added
- **Guild Plugin v1.6.0**
  - Added `guild:svelte-env-vars-check` — audits SvelteKit environment variable usage for PUBLIC/PRIVATE pattern compliance and `process.env` violations; reports violations grouped into three categories (client-side using private, server-side not using private, `process.env` usage), optionally migrates to correct patterns with static/dynamic timing choice, and outputs an env var inventory table

## [2.5.0] - 2026-05-19

### Added
- **Session Tracker Plugin v1.1.0**
  - Added `session-tracker:end-session` — triggers on session-ending phrases; spawns the Haiku logger agent which queries committed and uncommitted git changes for the past 28 hours, synthesizes a summary, and appends it to `.logs/YYYY-MM-DD-log.md`
  - Added `session-tracker:daily-summary` — spawns the Haiku summarizer agent which finds all `.logs/YYYY-MM-DD-log.md` files across subdirectories, groups sessions by project, and writes a cross-project report to `.logs/YYYY-MM-DD-daily-summary.md`
  - Internal `query-changes` and `save-log` skills guide the logger agent's git querying and file write behavior

## [2.4.0] - 2026-05-14

### Updated
- **Guild Plugin v1.5.0**
  - Added `guild:discuss` — a context summarizer and discussion facilitator; in open mode it scans the conversation, groups subjects into a numbered topic map, and drives a focused discussion loop; in targeted mode (`discuss [topic]`) it scopes analysis to a single topic, presents a summary with key points and open questions, then enters the loop; wraps up with a closing summary and decisions reached

## [2.3.0] - 2026-05-14

### Updated
- **Guild Plugin v1.4.0**
  - Added `guild:create-workflow` — an interactive skill for generating automation workflows (GitHub Actions pipelines, Python scripts, Node.js scripts, shell scripts, Makefiles); silently scans the project stack for context-aware suggestions, previews the generated file before writing, and provides post-creation next steps

## [2.2.0] - 2026-04-25

### Updated
- **Guild Plugin v1.3.0**
  - Added `guild:developer-svelte` — a Sonnet-backed specialist agent pre-loaded with Svelte 5 / SvelteKit knowledge via four reference skills (`svelte-core`, `svelte-build-deploy`, `svelte-advanced`, `svelte-best-practices`); architect routes tasks touching `.svelte`, `+page.*`, `+layout.*`, `+server.*`, hooks, or `svelte.config.js` to this agent and falls back to the standard developer otherwise
  - Check-in now exhausts all pending `product-owner` tasks before dispatching any `architect` task, ensuring all requirements are fully written before planning begins
  - Replaced `guild:commit` skill with `software:conventional-commit`

## [2.1.0] - 2026-04-20

### Updated
- **Guild Plugin v1.1.0** - Added `guild:commit` skill (conventional commits from recent developer tasks, no push) and `guild:release` skill (stamps `CHANGELOG.md` Unreleased, archives completed REQs to `.guild/archive/{version}/`, creates annotated git tag); architect gained a research gate that auto-dispatches a researcher + follow-up architect task when it cannot plan responsibly without more information; added `.guild/docs/` evergreen knowledge base where the researcher writes topic-keyed findings (updated in place on overlap) and the architect reads during codebase analysis — docs survive both `clear-board` and `release`; check-in now maintains the `[Unreleased]` section of repo-root `CHANGELOG.md` as requirements complete

## [2.0.2] - 2026-04-20

### Updated
- **Guild Plugin v1.0.4** - Added `guild:clear-board` skill to wipe all tasks, requirements, and plans with confirmation; `new-requirement` now delegates to it instead of duplicating the clear logic

## [2.0.1] - 2026-04-20

### Updated
- **Guild Plugin v1.0.3** - `new-requirement` skill now prompts to clear the board (requirements, tasks, plans) before adding a new requirement when existing work is present
- **Guild Plugin v1.0.2** - Architect emits per-task plan slices so developers read a scoped brief instead of the full plan; researcher agent downgraded to Haiku for cost efficiency
- **Guild Plugin v1.0.1** - Consolidated duplicated agents across plugins into the guild plugin

## [2.0.0] - 2026-04-12

### Added
- **Guild Plugin v1.0.0** - Continuous agent orchestration system with persistent board management, automatic agent chains (product-owner → architect → developers → test-writer → 4 parallel reviewers), and session-based work cycles triggered by "check in"

### Updated
- **Software Plugin v1.0.4** - Refactored `conventional-commit` skill: moved Best Practices into `commit-patterns.md` reference file, removed redundant When to Use section for cleaner skill definition

## [1.0.3] - 2026-03-29

### Updated
- **Software Plugin v1.0.3** - Added "deep code review" and "deep review" as trigger phrases for `comprehensive-review` skill

## [1.0.2] - 2026-03-24

### Updated
- **Software Plugin v1.0.2** - Added "generate commit" trigger phrase to `conventional-commit` skill

## [1.0.1] - 2026-03-23

### Updated
- **Software Plugin v1.0.1** - Fixed `TodoWrite` references in `develop-project` post-implementation review loop; review fix issues are now tracked via `TASKS.md`

## [1.0.0] - 2026-03-20

### Changed
- **Plugin restructure**: Renamed `software-development-workflow` → `software-project`, `tracker` → `project-management`
- **Software Plugin v1.0.0** — First stable release
  - Fixed agent color collision: `code-reviewer-security` changed from `red` to `orange`
  - Trimmed `product-owner` agent tools from 16 to 8 (removed unused MCP, notebook, and task tools)
  - Generic `Co-Authored-By: Claude` placeholder in conventional commit skill
  - Optimized `agent-capabilities.md` reference — removed per-agent sections that duplicated agent prompts, kept cross-agent insights only
  - Added explicit `user-invocable: true` to all 4 user-invocable skills
- **Project Management Plugin v1.0.0** — New plugin replacing the tracker plugin with project orchestration capabilities

### Removed
- **Tracker Plugin** — Replaced by project-management plugin

## [0.6.1] - 2026-03-09

### Updated
- **Develop Plugin v0.6.1** - Hotfix release

## [0.6.0] - 2026-03-06

### Updated
- **Develop Plugin v0.6.0**
  - Team-based phase execution: 3 senior-developer agents spawned once per phase, tasks distributed round-robin, each developer works sequentially through their queue
  - Senior developer now reads requirements document first (Phase 0) before any code or documentation analysis
  - Senior developer model upgraded from Haiku to inherit

## [0.5.0] - 2026-03-03

### Updated
- **Develop Plugin v0.5.0** - Consolidation release for the full 0.3.x development cycle
  - 8-phase clean architecture workflow (Foundational → Models → Services → Data → Rules → State Management → UI → Tests)
  - 5-agent comprehensive review system running in parallel: product, business logic, edge case, architecture, and security (OWASP Top 10)
  - Streamlined 6-step develop-project workflow with a single user gate (master plan review only)
  - Three-state resume: TASKS.md present → resume execution; master plan only → resume from split-plan; neither → fresh run
  - Fixed parallelism: 3 senior-developer agents per phase when ≥3 tasks, 1 otherwise
  - Self-contained progress tracking via TASKS.md (tracker plugin dependency removed)
  - Complexity scoring integrated into split-plan; estimate-task skill removed
  - YAML frontmatter formatting fixed across all 8 agents

### Migration Notes
- **0.4.x → 0.5.0**: No breaking changes for end users; estimate-task skill removed (use split-plan instead); tracker plugin no longer required

## [0.4.2] - 2026-03-03

### Fixed
- **Develop Plugin v0.3.2** - Agent frontmatter YAML formatting hotfix
  - Converted single-line description strings to proper YAML block scalar format across all 8 agents

## [0.4.1] - 2026-03-02

### Updated
- **Develop Plugin v0.3.1** - Workflow streamlining and developer experience improvements
  - Streamlined develop-project from 8 to 6 steps with a single user gate (master plan review only)
  - Removed development-planner agent; split-plan skill now called directly from develop-project
  - Three-state resume support: TASKS.md (execution resume), master plan only (split-plan resume), or fresh run
  - senior-developer model downgraded to Haiku for cost efficiency during concurrent agent execution
  - TASKS.md replaces tracker plugin integration for progress tracking

### Improved
- Reduced cognitive overhead with a streamlined, largely automated develop-project workflow
- Cost efficiency with Haiku model for concurrent senior-developer agents during parallel phase execution

## [0.4.0] - 2026-02-22

### Updated
- **Develop Plugin v0.3.0** - Security review and 8-phase architecture upgrade
  - New code-reviewer-security agent with OWASP Top 10 coverage
  - Phase 8 (Tests) added to clean architecture workflow
  - develop-project moved from commands to skills
  - estimate-task removed; complexity scoring integrated into split-plan
  - development-planner model updated to haiku for efficiency
  - senior-developer agent enhanced with strict documentation guidelines

### Improved
- Security posture with automated vulnerability detection in code reviews
- Architecture clarity by separating test tasks into dedicated Phase 8
- Workflow consistency with develop-project as a skill
- Developer documentation quality guidelines

## [0.3.0] - 2026-02-08

### Added
- Root changelog for tracking marketplace-level changes
- Enhanced documentation structure across all plugins

### Updated
- **Develop Plugin v0.2.3** - Comprehensive code review system
  - Four specialized review agents (product, business logic, edge case, architecture)
  - comprehensive-review skill for parallel multi-dimensional analysis
  - Complete code quality assurance workflow
  - Requirements compliance verification
  - Test coverage and edge case identification

### Improved
- Code quality tooling with systematic review capabilities
- Pre-PR validation workflows
- Requirements traceability from planning to implementation

## [0.2.0] - 2026-02-08

### Updated
- **Develop Plugin v0.2.2** - Software architect agent
  - New dedicated agent for master plan creation
  - Analyzes requirements and existing codebase
  - Creates comprehensive implementation strategies
  - Streamlined workflow with direct plan writing
- **Develop Plugin v0.2.1** - Requirements generation
  - generate-requirements skill for structured requirements documentation
  - Enhanced product-owner agent with single-file output policy
  - Comprehensive requirements template and examples

### Improved
- Master plan creation efficiency with specialized architect agent
- Requirements gathering workflow with structured templates
- Separation of concerns between planning and implementation

## [0.1.0] - 2026-02-07

### Updated
- **Tracker Plugin v0.2.0** - Enhanced documentation
  - Purpose sections for all 18 skills
  - Improved skill descriptions with trigger examples
  - Better skill discoverability and user guidance
- **Develop Plugin v0.2.0** - Documentation improvements
  - Critical concepts section in develop-project command
  - Enhanced workflow documentation with 8-step process
  - Action-oriented skill descriptions

### Improved
- Documentation consistency across both plugins
- User guidance and clarity in all skills
- Plugin discoverability and usage patterns

## [0.0.1] - 2026-01-27

### Added
- Initial marketplace structure
- **Tracker Plugin v0.1.0**
  - Phase-based project organization
  - Feature-based tracks
  - Intelligent tracker agent
  - 18 individual skills for direct control
  - Progress reports with visual indicators
  - Task dependencies and complexity tracking
- **Develop Plugin v0.1.0**
  - 7-phase clean architecture workflow
  - Adaptive parallel execution (1-8 agents)
  - Master plan and phase plan generation
  - Tracker integration
  - Development planning and execution agents
- Comprehensive marketplace README
- Individual plugin documentation
- MIT License
- Contributing guidelines

### Infrastructure
- Git repository initialization
- Plugin directory structure
- Marketplace manifest (.claude-plugin/marketplace.json)

## Release Notes

### Version Numbering
- Marketplace versions reflect the most significant plugin update
- Individual plugins maintain independent semantic versioning
- Major marketplace updates (new plugins, breaking changes) increment major version
- Plugin updates increment minor or patch versions accordingly

### Plugin Compatibility
- No breaking changes between current versions

### Migration Notes
- **0.4.x → 0.5.0**: No breaking changes for end users; estimate-task skill removed (use split-plan instead); tracker plugin no longer required by develop plugin
- **0.4.0 → 0.4.1**: No breaking changes; develop-project workflow streamlined, development-planner agent removed (internal)
- **0.3.0 → 0.4.0**: Minor breaking change — estimate-task skill removed; develop-project moved to skills
- **0.2.0 → 0.3.0**: No breaking changes, new review features are additive
- **0.1.0 → 0.2.0**: No breaking changes, enhanced documentation and new agents
- **0.0.1 → 0.1.0**: No breaking changes, documentation improvements

## See Also
- [Guild Plugin Changelog](plugins/guild/CHANGELOG.md)
- [Software Plugin Changelog](plugins/software-project/CHANGELOG.md)
- [Research Plugin Changelog](plugins/research/CHANGELOG.md)
- [Storytelling Plugin Changelog](plugins/storytelling/CHANGELOG.md)
