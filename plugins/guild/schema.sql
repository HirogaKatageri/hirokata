-- =====================================================================================
-- guild — THE SCHEMA IS THE TOOL
-- =====================================================================================
--
-- APPLY IT
--
--   export PATH="$HOME/.turso:$PATH"
--   tursodb .guild/guild.db < schema.sql
--
-- It is IDEMPOTENT. Tables are `CREATE TABLE IF NOT EXISTS` (data survives). Views and
-- triggers are DROPPED AND RECREATED every time (they hold no data, so re-applying this
-- file is how you upgrade a rule). Seed rows are guarded by `WHERE NOT EXISTS`. Run it as
-- often as you like.
--
-- THAT IDEMPOTENCE IS ALSO ITS LIMIT: `CREATE TABLE IF NOT EXISTS` sees an existing table
-- and moves on, so a RENAMED table or a NEW COLUMN never reaches a live board from this
-- file. Those ship as one-shot scripts in `migrations/`, run in order, once each:
--
--   tursodb .guild/guild.db < migrations/008-the-library-becomes-a-graph.sql
--   tursodb .guild/guild.db < schema.sql
--
-- Check `SELECT version FROM schema_version` against the number seeded below. This file
-- is at version 8. A board reporting 7 has not been migrated, and applying this file over
-- it leaves the OLD `doc` shape standing — `CREATE TABLE IF NOT EXISTS` sees a table and
-- moves on, so `kind`, `status`, `area` and `created_at` never arrive, and every view and
-- trigger below that reads them fails at runtime. A board reporting 6 must run 007 first.
--
-- ------------------------------------------------------------------------------------
-- WHAT THIS FILE IS
--
-- There is no guild CLI. `tursodb` is already a tool that executes SQL, so the guild
-- does not ship a second one. Every member reaches the warehouse the same way —
-- they write SQL — and THIS FILE is the guild's knowledge of what the warehouse contains
-- and what its rules are.
--
-- THE ONE THING THAT IS DELIBERATELY NOT IN HERE IS THE ROSTER. Who the guild's members
-- are, what each can do and whether one runs serially are facts about the AGENT FILES,
-- and they are declared in those files' frontmatter:
--
--   ---
--   name: developer-svelte
--   model: sonnet
--   capabilities: [implement, frontend, svelte, sveltekit]
--   serial: false
--   ---
--
-- A mirror of that in SQL was a second copy of a truth that already had a home, and it
-- went stale the moment somebody added an agent file without syncing. So the dispatcher
-- READS THE FRONTMATTER OF EVERY SUBAGENT AVAILABLE TO THE USER at dispatch time — the
-- plugin's own `agents/`, the project's `.claude/agents/`, the user's `~/.claude/agents/`
-- and any other installed plugin's — and matches it against `task_capability`. The
-- warehouse records what a ticket NEEDS. It does not claim to know who exists.
--
-- That only works if the rules live in the database rather than in a wrapper, so:
--
--   CHECK constraints  are the vocabularies. A status outside its enum is REJECTED by the
--                      engine, on every connection, from every member, forever.
--   VIEWS              are the derived rules. The cursor rule, the review gate, node
--                      readiness, the board, the briefing — each has
--                      ONE definition, here. A member SELECTs from the view instead of
--                      re-deriving the logic, so two members cannot get two answers.
--   TRIGGERS           are the record. Every meaningful mutation writes an `event` row
--                      without anyone remembering to, and stamps `updated_at`.
--
-- A member can forget to call a command. A member cannot bypass a trigger or a CHECK.
--
-- ------------------------------------------------------------------------------------
-- WHAT THIS FILE CANNOT ENFORCE — read this before you trust anything above
--
-- Some rules the old CLI policed are CONVENTIONS again. They are documented here and
-- nowhere enforced. Do not tell yourself otherwise.
--
--   1. "THE ORCHESTRATOR OWNS EVERY STATUS TRANSITION." SQL has no identity. Any
--      connection can run any UPDATE. `guild_state.actor` (below) is a courtesy label a
--      member sets on itself; it is not authentication, and the triggers copy it into
--      `event.actor` verbatim. A lying actor produces a lying feed.
--   2. "A REQUIREMENT MAY NOT CLOSE OVER A BLOCKED TASK." No constraint expresses it.
--      `v_requirement_progress.tasks_open` is the query that tells you; closing anyway is
--      one UPDATE away.
--   3. "A `failed` TASK IS ADJUDICATED WHEN THE ORCHESTRATOR LOGS `Skipped by user…`."
--      The waiver lives in a work_log line's PREFIX, matched with LIKE. It is a marker,
--      not a column. `v_failed_tasks.waived` reads it back honestly; nothing stops a
--      stray log line from looking like one.
--   4. "CONCURRENTLY DISPATCHED TASKS TOUCH DISJOINT FILES." `task.files` is a JSON
--      array and the disjointness across a `parallel_group` is an ASSERTION BY THE
--      ARCHITECT. Nothing checks it.
--   5. "A TICKET'S CAPABILITIES NAME SOMETHING A REAL AGENT DECLARES." The vocabulary
--      lives in the agent files, not in here, so SQL cannot check a `task_capability`
--      row against it — a misspelled tag INSERTS fine and simply matches nobody at
--      dispatch. THE DISPATCHER IS WHAT MAKES IT SPEAK: when the frontmatter scan finds
--      no agent covering every required capability, it sets the ticket to `blocked`,
--      which puts it on the board naming the word nobody has.
--   6. "A GATE IS DECIDED BY A HUMAN." `gate.status` is a column. Anyone can write it.
--   7. THE GRAPH IS NOT ACYCLIC BY CONSTRUCTION. `graph_edge` accepts any pair. A cycle
--      makes `v_ready_nodes` return nothing for the whole loop — a silent stall, not an
--      error. There is no `WITH RECURSIVE` on tursodb to detect one, so this is a review
--      duty, not a check.
--   8. TIMESTAMPS ARE UTC BY CONVENTION. `strftime(…,'now')` in the triggers is UTC.
--      Whatever a member writes by hand is whatever they wrote.
--   9. "A `worktree` PROJECT'S TASKS RUN IN ITS WORKTREE." `project.worktree_path` is a
--      string. Nothing creates the checkout, nothing verifies it exists, and nothing
--      makes a dispatched agent honour it. The CHECK only stops a SHARED project from
--      carrying a path — which is the half a column CAN police.
--  10. "AN APPROVED GATE APPROVES ITS PLAN." `gate.status` and `plan.approval` are two
--      columns on two tables and approving the plan is TWO WRITES, exactly as moving a
--      gate's node is. `plan.gate_node_id` ties them together for a reader; it does not
--      keep them in step. `v_plans_pending_approval` is what tells you they drifted.
--  11. "EVERY `knowledge_edge` POINTS AT SOMETHING THAT EXISTS." Its endpoints are
--      POLYMORPHIC — `to_id` may name a doc, a requirement, a task or a bug — and SQLite
--      cannot REFERENCE a table chosen at runtime, so there is no foreign key on either
--      end. What stands in for it: write the edge with `INSERT ... SELECT ... FROM
--      <target> WHERE id = ...` so a missing endpoint yields zero rows, and read
--      `v_knowledge_dangling`, which is a global invariant `guild:validate` runs. Deleting
--      a requirement therefore ORPHANS its edges silently. The CHECKs that ARE enforced
--      are the rel/type pairings — `supersedes` between two non-docs is refused.
--  12. "A DOCUMENT DESCRIBES THE CODE AS IT IS NOW." Nothing can know that.
--      `v_doc_stale` is the honest approximation: it reports a doc whose subject has an
--      `event` newer than the doc's own `updated_at`. That catches "the work moved and
--      nobody revisited the page" and misses "the code changed under a doc nobody linked
--      to anything" — which is why `v_undocumented_work` exists beside it.
--
-- ------------------------------------------------------------------------------------
-- ENGINE CONSTRAINTS — verified on tursodb 0.7.2, and every one of them cost a round
--
--   * No `WITH RECURSIVE`. Readiness and dependency logic joins DIRECT predecessors only,
--     one hop, and propagates as the work runs. Never write a traversal.
--   * No FTS5. Text search is `LIKE`, with `%` and `_` escaped by the caller.
--   * No lag/lead/ntile/percent_rank/cume_dist. Ranking here is an `ORDER BY` and the
--     rank is the ROW'S POSITION, assigned by the reader — see `v_open_bounties`.
--   * STRICT tables accept only INT, INTEGER, REAL, TEXT, BLOB, ANY. Every column below
--     is TEXT or INTEGER. Keep it that way.
--   * WORKING: STRICT, RETURNING, ON CONFLICT DO UPDATE, printf(), plain CTEs, WAL,
--     foreign_keys, JSON functions, CHECK, VIEW, TRIGGER, `UPDATE OF <col>` triggers.
--   * ALSO WORKING, and the library's views lean on them — verified on
--     0.7.2, see references/tursodb-gotchas.md §7: `group_concat(col, sep)`, a LEFT JOIN
--     onto a VIEW, a correlated `NOT EXISTS` against a VIEW built from `UNION ALL`, and
--     `AFTER DELETE` triggers.
--
-- HOW TO SEND SQL WITHOUT CORRUPTING IT. The tursodb stdin splitter ends a statement at a
-- `;` that terminates a line — EVEN INSIDE AN OPEN STRING LITERAL. So any free text you
-- write (a title, a body, a rationale, a work-log entry, a code block) must cross as
--     CAST(x'<hex>' AS TEXT)
-- which is always one line and always safe. That hex must be VALID UTF-8: tursodb
-- substitutes U+FFFD for invalid bytes. And when you read back, remember `-m list` output
-- is PIPE-SEPARATED and free text can contain pipes and newlines — never parse it
-- positionally with a bare `cut -d'|'`. Ask for JSON, or put the free-text column LAST.
--
-- Note also: nothing in this file contains a `;` inside a string literal or at the end of
-- a comment line, for exactly that reason. Preserve that property when you edit it.
--
-- ------------------------------------------------------------------------------------
-- CHECK CONSTRAINTS: THE TRADE, STATED PLAINLY
--
-- The Stage-3 schema deliberately had NO check on `task.status`, so the vocabulary could
-- widen without rewriting the table on every live board. That was the right call while a
-- CLI was policing the vocabulary in one function. There is no CLI now, so an unpoliced
-- column is an unpoliced column, and the cost has flipped: a typo'd status is a task that
-- disappears from every view at once.
--
-- So the enums are CHECKs, and the price is real and you should know it: SQLite cannot
-- ALTER a CHECK in place. WIDENING A VOCABULARY MEANS REBUILDING THE TABLE —
-- `CREATE TABLE task_new … / INSERT INTO task_new SELECT * FROM task / DROP TABLE task /
-- ALTER TABLE task_new RENAME TO task`, with foreign_keys OFF for the swap. Adding a
-- word is a migration. Choose words you can live with.
--
-- Likewise, applying this file over a board whose tables PREDATE a CHECK does NOT add
-- that CHECK — `CREATE TABLE IF NOT EXISTS` sees the table and moves on. The new views
-- and triggers land, the constraint does not. A board that wants it rebuilds.
-- =====================================================================================


-- =====================================================================================
-- PRAGMAS
-- =====================================================================================
-- `journal_mode` is persisted in the database header and survives. `busy_timeout` and
-- `foreign_keys` are PER-CONNECTION: they are NOT remembered, and every member must
-- re-issue them at the top of every script, or foreign keys are simply off for that
-- session. This is the single most commonly forgotten line in the whole system.
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = ON;


-- =====================================================================================
-- SCHEMA VERSION
-- =====================================================================================
-- Single row, id = 1.
CREATE TABLE IF NOT EXISTS schema_version (
  id         INTEGER PRIMARY KEY CHECK (id = 1),
  version    INTEGER NOT NULL,
  applied_at TEXT
) STRICT;

INSERT INTO schema_version (id, version, applied_at)
SELECT 1, 8, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE NOT EXISTS (SELECT 1 FROM schema_version WHERE id = 1);


-- =====================================================================================
-- GUILD STATE — the small key/value facts about this board
-- =====================================================================================
-- Two keys are seeded and both are read by views or triggers:
--
--   last-checkin  the timestamp of the last check-in. `v_brief` reports it and
--                 `v_recent_activity` is normally filtered against it. Seeded 'null'.
--   actor         WHO IS WRITING RIGHT NOW. Every trigger copies this into `event.actor`.
--                 A member sets it once at the top of its script:
--                     UPDATE guild_state SET value = 'developer-svelte' WHERE key = 'actor'
--                 and the whole session's events are attributed to it. This is a LABEL,
--                 not an identity — see "what this file cannot enforce", item 1.
CREATE TABLE IF NOT EXISTS guild_state (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL DEFAULT ''
) STRICT;

INSERT INTO guild_state (key, value)
SELECT 'last-checkin', 'null'
WHERE NOT EXISTS (SELECT 1 FROM guild_state WHERE key = 'last-checkin');

INSERT INTO guild_state (key, value)
SELECT 'actor', 'orchestrator'
WHERE NOT EXISTS (SELECT 1 FROM guild_state WHERE key = 'actor');


-- =====================================================================================
-- DIRECTION — goal, project
-- =====================================================================================
-- Vocabulary: todo | in-progress | done. Deliberately the SHORT set. A goal has no
-- `blocked` and no `waived`: those are words about a unit of work, and a goal is a
-- direction. Priority is 1 (highest) to 5 (lowest) everywhere it appears.
--
-- A GOAL is a high-level target. A PROJECT is a named group of work that has to be done
-- to reach it. A project is NOT a stage: a stage implies one runs at a time, which is what
-- an `ordinal NOT NULL` would say. A project may run BESIDE its siblings — see `concurrent` and
-- `isolation` below, and `v_projects_runnable`, which is the one place that rule lives.

CREATE TABLE IF NOT EXISTS goal (
  id          TEXT PRIMARY KEY,               -- GOAL-001
  title       TEXT NOT NULL,
  body        TEXT NOT NULL DEFAULT '',
  status      TEXT NOT NULL DEFAULT 'todo'
              CHECK (status IN ('todo', 'in-progress', 'done')),
  priority    INTEGER NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
) STRICT;

-- ---- WHAT THE PARALLELISM COLUMNS MEAN ----------------------------------------------
--
--   ordinal       WHERE THIS SITS IN THE GOAL'S SEQUENCE, 1-based, and NULLABLE. NULL is
--                 'unordered' — the project waits for nobody. It is not 'first'.
--   concurrent    1 = this project may run beside its siblings and never waits its turn.
--                 0 = it waits for every lower-ordinal sequential project in the goal.
--                 The default is 0, because running two projects at once is a decision
--                 somebody should make on purpose.
--   isolation     'shared'   its tasks run in the repository's working tree, alongside
--                            every other shared project. Task-level file disjointness
--                            (`task.files` in a `parallel_group`) is the only thing
--                            keeping two members off one file.
--                 'worktree' its tasks run in their own git worktree, so file collisions
--                            with other projects are impossible by construction.
--   worktree_path the checkout. NULL until one exists, so a project can be MARKED for
--                 isolation before it is cut. A 'shared' project may not carry one --
--                 the CHECK below says so, because a path on a shared project is a
--                 statement nobody honours.
--
-- Nothing here creates, verifies or cleans up a worktree — see "what this file cannot
-- enforce", item 9.
CREATE TABLE IF NOT EXISTS project (
  id            TEXT PRIMARY KEY,             -- PROJ-001
  goal_id       TEXT NOT NULL REFERENCES goal(id),
  title         TEXT NOT NULL,
  body          TEXT NOT NULL DEFAULT '',
  ordinal       INTEGER,                      -- ordering within the goal, 1-based. NULL = unordered
  status        TEXT NOT NULL DEFAULT 'todo'
                CHECK (status IN ('todo', 'in-progress', 'done')),
  priority      INTEGER NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
  concurrent    INTEGER NOT NULL DEFAULT 0 CHECK (concurrent IN (0, 1)),
  isolation     TEXT NOT NULL DEFAULT 'shared'
                CHECK (isolation IN ('shared', 'worktree')),
  worktree_path TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  CHECK (isolation = 'worktree' OR worktree_path IS NULL)
) STRICT;


-- =====================================================================================
-- WORK — requirement, plan, task, task_dependency
-- =====================================================================================

CREATE TABLE IF NOT EXISTS requirement (
  id          TEXT PRIMARY KEY,               -- REQ-001
  project_id  TEXT REFERENCES project(id),    -- nullable: unaffiliated work is legal
  title       TEXT NOT NULL,
  body        TEXT NOT NULL DEFAULT '',       -- the full REQ markdown
  status      TEXT NOT NULL DEFAULT 'todo'
              CHECK (status IN ('todo', 'in-progress', 'done')),
  priority    INTEGER NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
) STRICT;

-- ---- STATUS AND APPROVAL ARE TWO DIFFERENT QUESTIONS --------------------------------
--
--   status    IS THE DOCUMENT WRITTEN? todo -> in-progress -> done. It is the architect's
--             drafting lifecycle and says nothing about whether anybody agreed with it.
--   approval  DID THE USER SAY YES? pending -> approved | rejected. The architect writes
--             the plan, a HUMAN rules on it, and nothing is built until they do.
--
-- Collapsing them into one column was the old shape and it could not tell 'finished
-- writing, waiting on a person' from 'agreed and building', which is the single most
-- important distinction on the board.
--
-- `gate_node_id` ties the plan to the `gate-plan` node that carries the decision, so a
-- reader can go from either end. Setting `gate.status` does NOT set `plan.approval` —
-- see "what this file cannot enforce", item 10.
CREATE TABLE IF NOT EXISTS plan (
  id             TEXT PRIMARY KEY,            -- PLAN-001
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  task_id        TEXT REFERENCES task(id),    -- a plan written FOR one ticket
  title          TEXT NOT NULL,
  body           TEXT NOT NULL DEFAULT '',
  status         TEXT NOT NULL DEFAULT 'todo'
                 CHECK (status IN ('todo', 'in-progress', 'done')),
  approval       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (approval IN ('pending', 'approved', 'rejected')),
  approved_by    TEXT,                        -- 'user', or the name that ruled
  approved_at    TEXT,
  gate_node_id   TEXT REFERENCES graph_node(id),
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
) STRICT;

-- ---- THE TASK STATUS VOCABULARY, AND WHAT EACH WORD BUYS ----------------------------
--
--   todo         not started. The only status `v_task_actionable` will offer.
--   in-progress  claimed and running. `v_next_task` RESUMES one of these before it
--                claims anything new.
--   done         finished.
--   failed       an agent tried and could not. A HUMAN HAS SEEN IT: the orchestrator
--                sets it and immediately asks retry-or-skip. Because it has been
--                adjudicated, `failed` does NOT hold the review gate.
--   blocked      NOBODY AVAILABLE CAN TAKE THIS. It is not a general "stuck" flag — it
--                means the dispatcher scanned the frontmatter of every subagent the user
--                has and found none covering the ticket's required capabilities. A
--                machine verdict no human has ruled on yet, so it DOES hold the review
--                gate (see `v_task_actionable`). This is a WRITE the dispatcher makes,
--                not a state a view derives — the warehouse cannot see the agent files.
--   waived       deliberately skipped, by a gate decision. Counts as finished for
--                dependency purposes, exactly like `done` (see `v_task_deps`).
--
-- The asymmetry between `failed` and `blocked` in the review gate is the single most
-- load-bearing judgment in this schema, and it is spelled out in `v_task_actionable`.
CREATE TABLE IF NOT EXISTS task (
  id             TEXT PRIMARY KEY,            -- TASK-001
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  plan_id        TEXT REFERENCES plan(id),
  -- The file set this ticket touches. A JSON array, and THE DISJOINTNESS OF THOSE SETS
  -- ACROSS A `parallel_group` IS AN ASSERTION BY THE ARCHITECT, not a constraint — it is
  -- the promise that lets the group dispatch concurrently into one shared working tree
  -- without two members editing one file. Nothing verifies it. See "what this file
  -- cannot enforce", item 4.
  files          TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(files)),
  parallel_group TEXT,                        -- tasks sharing one dispatch together
  node_key       TEXT,                        -- the graph node that produced it
  title          TEXT NOT NULL,
  objective      TEXT NOT NULL DEFAULT '',
  body           TEXT NOT NULL DEFAULT '',
  status         TEXT NOT NULL DEFAULT 'todo'
                 CHECK (status IN ('todo', 'in-progress', 'done',
                                   'failed', 'blocked', 'waived')),
  priority       INTEGER NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
  -- `agent` is the PIN: a subagent the architect named on the ticket, by the `name` in
  -- that agent's frontmatter. Optional. When it is set the dispatcher spawns it and does
  -- NOT run the capability match at all — a pin is a decision that has already been made.
  -- NOT a foreign key, and it cannot be one: the roster is a directory of markdown files.
  agent          TEXT,
  -- Who actually took it. Also a plain name, for the same reason.
  claimed_by     TEXT,
  claimed_at     TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
) STRICT;

-- DIRECT predecessors only. There is no transitive closure anywhere in this schema and
-- there must not be one: readiness propagates a hop at a time as work completes, which is
-- exactly why `WITH RECURSIVE` is never needed (and is unavailable).
CREATE TABLE IF NOT EXISTS task_dependency (
  task_id    TEXT NOT NULL REFERENCES task(id),
  depends_on TEXT NOT NULL REFERENCES task(id),
  PRIMARY KEY (task_id, depends_on),
  CHECK (task_id <> depends_on)               -- self-dependency is always a mistake
) STRICT;



-- =====================================================================================
-- WHAT A TICKET NEEDS — task_capability
-- =====================================================================================
-- The ONE capability table. It records what the WORK requires. It does not record who
-- can do it: that is `capabilities:` in each agent file's frontmatter, and the dispatcher
-- reads it from there against every subagent available to the user.
--
-- A capability is compared for EQUALITY and never normalized, so the alphabet is narrow
-- on purpose: lowercase letters, digits and '-'. `e2e` and `E2E` would be two
-- capabilities that read as one, and the match would quietly stop working. The CHECK
-- below enforces the ALPHABET. The VOCABULARY — which words mean anything — is the union
-- of what the agent files declare, and no CHECK can reach it. See item 5 of "what this
-- file cannot enforce".
--
-- `required = 1` decides ELIGIBILITY: the matching agent's declared capabilities must be
-- a SUPERSET of the ticket's required set.
-- `required = 0` — "preferred" — decides RANK only. A preferred capability never excludes
-- anybody. That distinction is the whole of the match, and it now runs in the dispatcher.
--
-- A ticket with NO rows here and no pinned `agent` is one nobody can be found for. It is
-- the `unassigned` reason in `v_blocked_tasks`.
CREATE TABLE IF NOT EXISTS task_capability (
  task_id    TEXT NOT NULL REFERENCES task(id),
  capability TEXT NOT NULL
             CHECK (length(capability) BETWEEN 1 AND 64
                    AND capability = lower(capability)
                    AND capability GLOB '[a-z]*'
                    AND NOT capability GLOB '*[^a-z0-9-]*'),
  required   INTEGER NOT NULL DEFAULT 1 CHECK (required IN (0, 1)),
  PRIMARY KEY (task_id, capability)
) STRICT;

-- A capability the guild lacks is NOT filed here as a request row. The vocabulary is the
-- union of what the agent files declare, so ADMITTING A NEW WORD IS WRITING THE AGENT FILE
-- THAT DECLARES IT — there is no intermediate paperwork, and a request row that outlived
-- its recruitment would only ever be bookkeeping about bookkeeping.
--
-- The gap itself is still visible, and louder than a request row was: the ticket that
-- wanted the capability sits at `blocked` on the board, naming it.


-- =====================================================================================
-- EXECUTION GRAPH — graph_node, graph_edge, graph_deviation, gate
-- =====================================================================================
-- A requirement is instantiated into nodes and edges from a template. A node is READY
-- when every DIRECT predecessor is finished — that is `v_ready_nodes`, and it is a
-- one-hop join, never a traversal.

CREATE TABLE IF NOT EXISTS graph_node (
  id             TEXT PRIMARY KEY,            -- REQ-001/implement.auth-service
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  node_key       TEXT NOT NULL,               -- 'implement', 'review', 'gate-plan'
  kind           TEXT NOT NULL CHECK (kind IN ('work', 'gate')),
  task_id        TEXT REFERENCES task(id),    -- bound at dispatch when unambiguous
  parallel_group TEXT,
  status         TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'ready', 'running',
                                   'done', 'failed', 'skipped')),
                 -- `ready` is legal and optional: `v_ready_nodes` treats `pending` and
                 -- `ready` identically as candidates, so the working loop is
                 -- pending -> running -> done. Mark `ready` only if you want to record
                 -- what you are ABOUT to run.
                 --
                 -- `done` AND `skipped` BOTH COUNT AS FINISHED for a successor's
                 -- readiness. A node the architect deliberately skipped must not hold its
                 -- successors forever — `skipped` is the graph's spelling of `waived`.
  UNIQUE (requirement_id, node_key, task_id)
) STRICT;

CREATE TABLE IF NOT EXISTS graph_edge (
  from_node TEXT NOT NULL REFERENCES graph_node(id),
  to_node   TEXT NOT NULL REFERENCES graph_node(id),
  PRIMARY KEY (from_node, to_node),
  CHECK (from_node <> to_node)                -- a self-edge stalls the node forever
) STRICT;

-- Any departure from the template, WITH A REASON. `reason` is NOT NULL and CHECKed
-- non-empty, because the whole value of the row is the sentence in it.
CREATE TABLE IF NOT EXISTS graph_deviation (
  id             INTEGER PRIMARY KEY,
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  kind           TEXT NOT NULL
                 CHECK (kind IN ('add-node', 'drop-node', 'reshape', 'add-gate')),
  node_key       TEXT NOT NULL,
  reason         TEXT NOT NULL CHECK (length(trim(reason)) > 0),
  created_at     TEXT NOT NULL
) STRICT;

-- A gate is an ordinary graph node whose status a HUMAN writes instead of an agent.
--   kind = approve          "yes / no"
--   kind = select-findings  "which of these get repaired" — `decision` carries the JSON
--                           selection, and the successors fan out from it
-- Setting `gate.status` does NOT move the node. Approving a gate is two writes: the gate
-- row, then `graph_node.status = 'done'` (or 'skipped' on reject). `v_gates_pending` is
-- what the orchestrator reads to find gates waiting on a person.
CREATE TABLE IF NOT EXISTS gate (
  node_id     TEXT PRIMARY KEY REFERENCES graph_node(id),
  prompt      TEXT NOT NULL,
  kind        TEXT NOT NULL DEFAULT 'approve'
              CHECK (kind IN ('approve', 'select-findings')),
  status      TEXT NOT NULL DEFAULT 'pending'
              CHECK (status IN ('pending', 'approved', 'rejected')),
  decision    TEXT,                           -- free text / JSON of selections
  decided_at  TEXT
) STRICT;


-- =====================================================================================
-- RECORDS — work_log, review_finding, bug
-- =====================================================================================

-- Append-only. `entry` is free text (use the hex cast). The ORCHESTRATOR'S WAIVER LIVES
-- HERE, as an entry beginning `Skipped by user` — see `v_failed_tasks`.
CREATE TABLE IF NOT EXISTS work_log (
  id         INTEGER PRIMARY KEY,
  task_id    TEXT NOT NULL REFERENCES task(id),
  ts         TEXT NOT NULL,
  agent      TEXT NOT NULL,
  entry      TEXT NOT NULL
) STRICT;

-- `nit` exists here and NOT on `bug`. A bug is not a nit.
--   disposition open    nobody has acted
--               fixing  a fix task is linked
--               fixed   repaired
--               waived  deliberately accepted
CREATE TABLE IF NOT EXISTS review_finding (
  id          INTEGER PRIMARY KEY,
  task_id     TEXT NOT NULL REFERENCES task(id),
  reviewer    TEXT NOT NULL,
  severity    TEXT NOT NULL
              CHECK (severity IN ('critical', 'major', 'minor', 'nit')),
  summary     TEXT NOT NULL,
  detail      TEXT NOT NULL DEFAULT '',
  file        TEXT,
  line        INTEGER,
  disposition TEXT NOT NULL DEFAULT 'open'
              CHECK (disposition IN ('open', 'fixing', 'fixed', 'waived')),
  fix_task_id TEXT REFERENCES task(id),
  created_at  TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS bug (
  id             TEXT PRIMARY KEY,            -- BUG-001
  title          TEXT NOT NULL,
  body           TEXT NOT NULL DEFAULT '',
  repro          TEXT NOT NULL DEFAULT '',
  severity       TEXT NOT NULL DEFAULT 'major'
                 CHECK (severity IN ('critical', 'major', 'minor')),
  status         TEXT NOT NULL DEFAULT 'open'
                 CHECK (status IN ('open', 'fixing', 'fixed', 'wontfix')),
  found_by       TEXT,                        -- agent name or 'user'
  requirement_id TEXT REFERENCES requirement(id),
  fix_task_id    TEXT REFERENCES task(id),
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
) STRICT;


-- =====================================================================================
-- MAINTENANCE — coverage, inspection, inspection_coverage
-- =====================================================================================

-- What the product is made of, from a quality standpoint. EVERGREEN: it survives releases
-- and board resets. `last_inspected_at` + `risk` is what makes "what needs looking at" a
-- QUERY (`v_coverage_due`) rather than a judgment call.
CREATE TABLE IF NOT EXISTS coverage (
  id                TEXT PRIMARY KEY,         -- 'checkout-flow'
  area              TEXT NOT NULL,            -- human name
  risk              TEXT NOT NULL DEFAULT 'medium'
                    CHECK (risk IN ('high', 'medium', 'low')),
  spec_path         TEXT,                     -- committed e2e spec, if one exists
  last_inspected_at TEXT,
  notes             TEXT NOT NULL DEFAULT ''
) STRICT;

-- One turn of the maintenance cycle.
--
-- `trigger` HAS NO CHECK, AND THAT IS DELIBERATE — it is the one enum in this file left
-- open. Today the only value written is 'manual', because an inspection is among the most
-- expensive things the guild does and nothing should start one on its own. The column
-- exists so a cadence can be added later WITHOUT rebuilding the table, which is precisely
-- the cost a CHECK would impose. Every other vocabulary here is closed because it is
-- settled. This one is not settled.
CREATE TABLE IF NOT EXISTS inspection (
  id          TEXT PRIMARY KEY,               -- INSP-001
  scope       TEXT NOT NULL,                  -- 'whole product' | a coverage area
  "trigger"   TEXT NOT NULL DEFAULT 'manual',
  status      TEXT NOT NULL DEFAULT 'todo'
              CHECK (status IN ('todo', 'in-progress', 'done')),
  started_at  TEXT,
  finished_at TEXT
) STRICT;

-- `verdict` is NULL until the area is actually reached. 'not-reached' is the honest
-- answer for an area the inspection intended to cover and ran out of road before it did —
-- it is NOT the same as NULL, and it is not a pass.
CREATE TABLE IF NOT EXISTS inspection_coverage (
  inspection_id TEXT NOT NULL REFERENCES inspection(id),
  coverage_id   TEXT NOT NULL REFERENCES coverage(id),
  verdict       TEXT CHECK (verdict IS NULL
                            OR verdict IN ('pass', 'issues', 'not-reached')),
  PRIMARY KEY (inspection_id, coverage_id)
) STRICT;

-- =====================================================================================
-- THE LIBRARY, WHICH IS A GRAPH — doc, knowledge_edge, doc_revision
-- =====================================================================================
-- Long-lived knowledge: what the business rules ARE, how a subsystem works, what was
-- DECIDED and why, and how each of those changed. EVERGREEN — the library survives
-- releases and board resets, exactly like `coverage`, because a decision does not stop
-- being true when the ticket that caused it ships.
--
-- THREE TABLES, THREE DIFFERENT JOBS, AND THEY ARE NOT INTERCHANGEABLE:
--
--   doc             THE NODES. One row per topic, keyed by `slug`.
--   knowledge_edge  THE RELATIONS. Typed, directed, and able to point at ANY board row —
--                   which is what makes this a graph over the work and not a second
--                   database sitting beside it. Most of the nodes already exist as
--                   requirements, plans, tasks and bugs.
--   doc_revision    THE HISTORY. Written by a TRIGGER on every body change, so a member
--                   cannot forget to snapshot, and "what did we believe in March" is a
--                   query rather than a git archaeology session.
--
-- WHY EDGES RATHER THAN MORE COLUMNS. `supersedes`, `contradicts` and `describes` are all
-- many-to-many and all carry a `note`. As columns they would be three nullable foreign
-- keys that could each only hold one value, and the fourth relation somebody needs next
-- year would be a table rebuild.

-- ---- doc ----------------------------------------------------------------------------
-- `kind` IS WHAT THE DOCUMENT IS FOR, and the vocabulary is closed on purpose because
-- every reader branches on it:
--
--   business    the domain's own rules. What a refund IS, when an account is dormant,
--               which invariants the product promises. Written from the requirement
--               interview, and the doc most likely to outlive the code that implements it.
--   technical   how a subsystem actually works right now. Owned by whoever last changed it.
--   decision    AN ADR. One choice, its context, the alternatives, the consequences. Without
--               this kind a decision lives in plan prose and in `gate.decision` JSON, where
--               nothing can find it again.
--   research    an external lookup the guild should not have to repeat. The researcher's
--               output.
--   runbook     the steps for an operation somebody performs — deploy, rotate, restore.
--   reference   everything else. The default, and deliberately boring.
--
-- `status` IS THE DOCUMENT'S OWN LIFECYCLE, and one vocabulary serves prose and ADRs both:
--
--   draft       being written, or — for a decision — PROPOSED and not yet agreed.
--   current     live. For a decision, ACCEPTED.
--   superseded  replaced. The row STAYS: a superseded decision is how you read the
--               project's evolution, and deleting it is how you lose it. `v_doc_current`
--               is what hides it from ordinary reads.
--   rejected    considered and declined. Also stays, for the same reason — the decisions
--               a project did NOT take are half of why it looks the way it does.
--
-- `area` is a FREE key ('auth', 'billing') and deliberately not CHECKed. It is how the
-- graph clusters, and a vocabulary that has to be migrated to add a subsystem is a
-- vocabulary people route around. Overlap it with `coverage.id` where it makes sense.
CREATE TABLE IF NOT EXISTS doc (
  slug       TEXT PRIMARY KEY,                -- 'sveltekit-form-actions', 'adr-session-store'
  title      TEXT NOT NULL,
  body       TEXT NOT NULL,
  kind       TEXT NOT NULL DEFAULT 'reference'
             CHECK (kind IN ('business', 'technical', 'decision',
                             'research', 'runbook', 'reference')),
  status     TEXT NOT NULL DEFAULT 'current'
             CHECK (status IN ('draft', 'current', 'superseded', 'rejected')),
  area       TEXT NOT NULL DEFAULT '',        -- free key: 'auth', 'billing'. Not CHECKed
  source     TEXT NOT NULL DEFAULT '',        -- who/what produced it
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
) STRICT;

-- ---- knowledge_edge -----------------------------------------------------------------
-- ONE ROW IS ONE ASSERTION: <from> --rel--> <to>, with an optional note saying why.
--
-- THE RELATION VOCABULARY, AND WHAT EACH ONE IS FOR:
--
--   describes     doc -> work   "this document explains that requirement/task/project."
--                               The edge `v_undocumented_work` looks for, and the edge
--                               `v_doc_stale` follows to notice the subject moved.
--   decides       doc -> work   "this DECISION governs that work." Narrower than
--                               `describes` on purpose: a reader asking "what were we
--                               committed to here" wants the ADRs, not the tutorials.
--   supersedes    doc -> doc    "this replaces that." THE EVOLUTION EDGE. Follow it
--                               backwards and you have the project's change of mind,
--                               in order, with both sides still readable.
--   refines       doc -> doc    "this is a narrower topic under that." The tree.
--   depends-on    doc -> doc    "read that first, or this will not make sense."
--   contradicts   doc -> doc    "these two disagree and somebody should resolve it."
--                               RECORDING drift beats pretending the library is coherent.
--   derived-from  doc -> any    provenance. Which plan, review finding or bug this
--                               document came out of. It is how a decision keeps its
--                               receipts after the ticket is archived.
--   evidence-for  any -> doc    the reverse: this bug/finding/coverage row is empirical
--                               support for that document's claim.
--
-- THE ENDPOINTS ARE POLYMORPHIC, WHICH COSTS US THE FOREIGN KEY. `to_id` may name a doc,
-- a requirement, a task or a bug, and SQLite cannot REFERENCE a table chosen at runtime.
-- Two things stand in for the constraint, and NEITHER is the engine refusing a bad write:
--
--   1. THE WRITE-TIME CHECK. Insert with `SELECT ... FROM <target table> WHERE id = ...`
--      so a missing endpoint yields zero rows instead of a dangling edge. queries.md has
--      the exact form. This is the same trick the rest of the guild uses for referential
--      safety inside a non-atomic script.
--   2. `v_knowledge_dangling`, which lists every edge whose endpoint is gone. It is a
--      global invariant in docs/expectations.md, so `guild:validate` runs it.
--
-- See "what this file cannot enforce", item 11.
--
-- THE rel/TYPE CHECKS BELOW ARE REAL CONSTRAINTS. They are what stops the vocabulary
-- becoming decorative: `supersedes` between a task and a bug would be meaningless, and
-- meaningless edges are how a knowledge graph turns into noise nobody trusts.
CREATE TABLE IF NOT EXISTS knowledge_edge (
  id         INTEGER PRIMARY KEY,
  rel        TEXT NOT NULL
             CHECK (rel IN ('describes', 'decides', 'supersedes', 'refines',
                            'depends-on', 'contradicts', 'derived-from', 'evidence-for')),
  from_type  TEXT NOT NULL
             CHECK (from_type IN ('doc', 'goal', 'project', 'requirement', 'plan',
                                  'task', 'bug', 'coverage', 'review_finding')),
  from_id    TEXT NOT NULL,
  to_type    TEXT NOT NULL
             CHECK (to_type IN ('doc', 'goal', 'project', 'requirement', 'plan',
                                'task', 'bug', 'coverage', 'review_finding')),
  to_id      TEXT NOT NULL,
  note       TEXT NOT NULL DEFAULT '',
  created_by TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE (rel, from_type, from_id, to_type, to_id),
  -- A self-edge is never an assertion, it is a typo
  CHECK (from_type <> to_type OR from_id <> to_id),
  -- doc-to-doc relations are doc-to-doc
  CHECK (rel NOT IN ('supersedes', 'refines', 'depends-on', 'contradicts')
         OR (from_type = 'doc' AND to_type = 'doc')),
  -- a document describes or decides something. Nothing describes a document
  CHECK (rel NOT IN ('describes', 'decides', 'derived-from') OR from_type = 'doc'),
  -- evidence points AT a document
  CHECK (rel <> 'evidence-for' OR to_type = 'doc')
) STRICT;

-- ---- doc_revision -------------------------------------------------------------------
-- THE BODY AS IT WAS BEFORE A CHANGE, written by `trg_doc_revised`. Append-only, and
-- treated like `event`: you do not INSERT here by hand and you never UPDATE or DELETE.
--
-- NO FOREIGN KEY TO `doc`, DELIBERATELY. A revision has to survive its document being
-- deleted, or it is not history — it is a footnote that disappears with the thing it was
-- meant to outlive. `slug` is therefore a plain TEXT column, and a revision whose doc is
-- gone is CORRECT rather than dangling. `v_knowledge_dangling` does not look at this table.
--
-- The row stores the OLD body, so the newest revision is the second-newest text and the
-- live text is in `doc` itself. That ordering trips people up exactly once.
CREATE TABLE IF NOT EXISTS doc_revision (
  id          INTEGER PRIMARY KEY,
  slug        TEXT NOT NULL,                  -- no REFERENCES, on purpose. See above
  title       TEXT NOT NULL,
  body        TEXT NOT NULL,                  -- the body BEFORE this change
  kind        TEXT NOT NULL,
  status      TEXT NOT NULL,
  replaced_at TEXT NOT NULL
) STRICT;


-- =====================================================================================
-- HISTORY — event
-- =====================================================================================
-- WRITTEN BY TRIGGERS. You do not normally INSERT here by hand, and you never UPDATE or
-- DELETE: this is the guild's memory, and a memory you can edit is not one.
--
-- `subject_type` IS THE SUBJECT'S TABLE NAME — 'task', 'requirement', 'coverage'. That is
-- what lets `v_recent_activity` resolve a title for it, and G7 asserts it. THE ONE
-- EXCEPTION IS 'shift', which names a span of time rather than a row: a shift is its
-- `started` and `ended` events and nothing else, so there is no table to name. G7 carries
-- that exception explicitly. Do not add a second one — write the table instead.
--
-- `verb` is intentionally NOT CHECKed: new machinery invents new verbs, and an event that
-- cannot be written is worse than one whose verb you have not seen before. The verbs the
-- triggers below emit are:
--
--   created  moved  deleted  claimed  logged  found  dispositioned  inspected
--   documented  decided  node-moved  deviated  isolated
--
-- `started` and `ended` are NOT in that list: they are the shift's two hand-written
-- events, and no trigger emits them.
--
-- `payload` is JSON. The shape the triggers use for a status change is
-- {"from":"todo","to":"in-progress"}, which `v_recent_activity` renders as a phrase.
CREATE TABLE IF NOT EXISTS event (
  id           INTEGER PRIMARY KEY,
  ts           TEXT NOT NULL,
  actor        TEXT NOT NULL,                 -- 'orchestrator' | agent name | 'user'
  verb         TEXT NOT NULL,
  subject_type TEXT NOT NULL,
  subject_id   TEXT NOT NULL,
  payload      TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(payload))
) STRICT;


-- =====================================================================================
-- INDEXES
-- =====================================================================================
-- Every query in this file is CORRECT without any of these. They are optimization only,
-- which is why they are safe to add or drop at will.
CREATE INDEX IF NOT EXISTS task_by_req      ON task(requirement_id, status);
CREATE INDEX IF NOT EXISTS task_by_status   ON task(status, id);
CREATE INDEX IF NOT EXISTS node_by_req      ON graph_node(requirement_id, status);
CREATE INDEX IF NOT EXISTS event_recent     ON event(ts DESC);
CREATE INDEX IF NOT EXISTS event_by_subject ON event(subject_type, subject_id);
CREATE INDEX IF NOT EXISTS finding_by_task  ON review_finding(task_id, disposition);
CREATE INDEX IF NOT EXISTS worklog_by_task  ON work_log(task_id, ts);
CREATE INDEX IF NOT EXISTS bug_by_status    ON bug(status, severity);
-- The approval queue is read on every check-in and is almost always tiny — a partial
-- index would be tidier, so keep this one narrow rather than adding columns to it.
CREATE INDEX IF NOT EXISTS plan_by_approval ON plan(approval, requirement_id);
CREATE INDEX IF NOT EXISTS project_by_goal  ON project(goal_id, ordinal);
-- `task_capability` is keyed (task_id, capability), so "what does this ticket need" is
-- already a seek. This covers the other direction — "which tickets want `rust`" — which
-- the dispatcher asks once per scan.
CREATE INDEX IF NOT EXISTS task_cap_by_cap  ON task_capability(capability, required);
-- Dependency and edge lookups run in BOTH directions in the readiness views.
CREATE INDEX IF NOT EXISTS dep_by_pred      ON task_dependency(depends_on);
CREATE INDEX IF NOT EXISTS edge_by_to       ON graph_edge(to_node);

-- The library's graph. `ke_out` and `ke_in` are the two directions of a one-hop
-- neighbourhood, which is every traversal this engine can do — there is no WITH RECURSIVE.
CREATE INDEX IF NOT EXISTS ke_out          ON knowledge_edge(from_type, from_id, rel);
CREATE INDEX IF NOT EXISTS ke_in           ON knowledge_edge(to_type, to_id, rel);
CREATE INDEX IF NOT EXISTS doc_by_kind     ON doc(kind, status);
CREATE INDEX IF NOT EXISTS doc_by_area     ON doc(area, kind);
CREATE INDEX IF NOT EXISTS revision_by_doc ON doc_revision(slug, replaced_at DESC);


-- =====================================================================================
-- =====================================================================================
--  V I E W S   —   T H E   G U I L D ' S   R U L E S
-- =====================================================================================
-- =====================================================================================
--
-- Every view is DROPped and recreated, so editing this file and re-applying it is how a
-- rule changes. Nothing below holds data.
--
-- READ THE VIEW INSTEAD OF REWRITING ITS LOGIC. That is the entire point. When two
-- members each write their own version of "which task is next", the guild has two answers
-- to one question and neither of them is wrong on its own terms. A view has one.
--
-- Views may reference other views, and several here do. The dependency order matters when
-- creating them, so they are defined bottom-up: helpers first.
--
-- INDEX OF VIEWS
--   helpers      v_task_who · v_task_deps · v_task_blockers
--   the cursor   v_task_actionable · v_next_task
--   the bounties v_open_bounties · v_blocked_tasks
--   the graph    v_ready_nodes · v_gates_pending · v_plans_pending_approval
--   direction    v_projects_runnable · v_project_progress · v_goal_progress
--   the board    v_board · v_requirement_progress
--   the briefing v_brief · v_in_flight · v_failed_tasks · v_open_findings ·
--                v_open_bugs · v_recent_activity
--   quality      v_coverage_due
--   the library  v_knowledge_ref · v_doc_current · v_doc_neighbors · v_doc_stale ·
--                v_undocumented_work · v_decision_log · v_knowledge_dangling
--
-- THERE IS NO MATCHER VIEW. Matching a ticket to a member is the dispatcher's job, because
-- the facts it needs — who exists, what they declare — live in the agent files and never
-- enter this database.


-- ------------------------------------------------------------------------------------
-- v_task_who — who is this ticket waiting ON, or what is it waiting FOR
-- ------------------------------------------------------------------------------------
-- `agent` is optional, and an empty one is not a cosmetic problem: a board line reading
-- "TASK-005: Build the parser ()" withholds the one fact the reader needs. So an
-- unassigned ticket reports its REQUIRED capabilities as `needs:frontend+implement`, and
-- a ticket with neither reports `-`. Never empty, never blank-containing: the value is
-- safe in a whitespace-separated column.
--
-- Only REQUIRED capabilities appear. Preferred ones rank candidates, they do not decide
-- who could take the work, and this column answers "who could take this".
DROP VIEW IF EXISTS v_task_who;
CREATE VIEW v_task_who AS
SELECT t.id AS task_id,
       CASE
         WHEN COALESCE(t.agent, '') <> '' THEN t.agent
         ELSE COALESCE(
                (SELECT 'needs:' || group_concat(c.capability, '+')
                   FROM (SELECT capability FROM task_capability
                          WHERE task_id = t.id AND required = 1
                          ORDER BY capability) c),
                '-')
       END AS who
  FROM task t;


-- ------------------------------------------------------------------------------------
-- v_task_deps — the UNFINISHED direct predecessors of every task
-- ------------------------------------------------------------------------------------
-- ONE HOP. Never a traversal. A transitively blocked task surfaces through the one it
-- directly waits on, and readiness propagates as each predecessor finishes.
--
-- `done` and `waived` BOTH count as finished. A waived task was deliberately skipped by a
-- gate decision, and holding its successors forever would turn one decision into a
-- permanent stall.
DROP VIEW IF EXISTS v_task_deps;
CREATE VIEW v_task_deps AS
SELECT d.task_id      AS task_id,
       b.id           AS blocker_id,
       b.status       AS blocker_status
  FROM task_dependency d
  JOIN task b ON b.id = d.depends_on
 WHERE b.status NOT IN ('done', 'waived');


-- ------------------------------------------------------------------------------------
-- v_task_blockers — the same, rolled up to one row per task
-- ------------------------------------------------------------------------------------
-- The inner ORDER BY is a derived table rather than an argument to group_concat, so the
-- joined order is deterministic without relying on aggregate ORDER BY.
DROP VIEW IF EXISTS v_task_blockers;
CREATE VIEW v_task_blockers AS
SELECT task_id,
       COUNT(*)                       AS blocker_count,
       group_concat(blocker_id, ',')  AS blockers
  FROM (SELECT task_id, blocker_id FROM v_task_deps ORDER BY task_id, blocker_id)
 GROUP BY task_id;


-- ------------------------------------------------------------------------------------
-- v_task_actionable — THE CANDIDATE RULE, INCLUDING THE REVIEW GATE
-- ------------------------------------------------------------------------------------
-- Every `todo` task that may be offered right now. This is the single most copied
-- predicate in the old CLI (`cmd_next`, `guild brief`, `guild bounties` each held a
-- spelling of it) and the reason it is a view.
--
-- THE REVIEW GATE. A task whose `agent` is EXACTLY 'reviewer' is not actionable while any
-- OTHER, NON-REVIEWER task for the same requirement is still open. A review that
-- certifies a requirement whose implementation task never ran is a FALSE GREEN, and a
-- false green is silent — it looks exactly like a real one.
--
-- Three details, each of which was a real bug before it was a rule:
--
--   1. 'reviewer' IS MATCHED EXACTLY, not by prefix. One reviewer ticket is filed per
--      requirement and fanned out to the specialized reviewer agents at dispatch, so
--      matching `reviewer-security` here would gate tickets that never exist.
--
--   2. OTHER REVIEWERS ARE IGNORED BY THE GATE (`COALESCE(o.agent,'') <> 'reviewer'`).
--      Without this, two reviewer tickets on one requirement gate EACH OTHER and the
--      cursor answers "nothing to do" forever. That deadlock was reproducible, not
--      theoretical. With this clause, reviewers wait for all the work and then run one at
--      a time in id order.
--
--   3. THE OPEN SET IS ('todo','in-progress','blocked') — `blocked` HOLDS THE GATE AND
--      `failed` DOES NOT. That asymmetry is the judgment: `failed` has already been ruled
--      on by a human (set, then immediately retried or skipped), while `blocked` is a
--      machine verdict nobody has looked at. Adjudicated work stops blocking, and
--      un-adjudicated work does not. A held gate is LOUD — the blocked task is on the
--      board saying which capability nobody has. Between a failure that hides and a
--      failure that shouts, take the one that shouts.
--
-- A `blocked` task can never appear in this view, because the view asks for `todo`.
DROP VIEW IF EXISTS v_task_actionable;
CREATE VIEW v_task_actionable AS
SELECT t.*
  FROM task t
 WHERE t.status = 'todo'
   AND ( COALESCE(t.agent, '') <> 'reviewer'
         OR NOT EXISTS (SELECT 1 FROM task o
                         WHERE o.requirement_id = t.requirement_id
                           AND o.id <> t.id
                           AND o.status IN ('todo', 'in-progress', 'blocked')
                           AND COALESCE(o.agent, '') <> 'reviewer') );


-- ------------------------------------------------------------------------------------
-- v_next_task — THE CURSOR RULE. Zero or one row.
-- ------------------------------------------------------------------------------------
--   1. RESUME the lowest-id `in-progress` task, if there is one.
--   2. else CLAIM the lowest-id actionable `todo` task.
--   3. else nothing.
--
-- Resume beats claim unconditionally. Work already in flight is finished before new work
-- starts, so the guild never accumulates half-done tickets.
--
-- `ORDER BY id LIMIT 1` rather than MIN(id) because that is what the rule says — take the
-- first row in id order. Ids are zero-padded to three digits, so text order is numeric
-- order up to TASK-999.
--
--   SELECT * FROM v_next_task
--
-- Empty result means "nothing to do". It does NOT mean the board is finished — check
-- `v_blocked_tasks` and `v_gates_pending` before believing it.
--
-- WHAT THIS VIEW DOES NOT CHECK, and it is not an oversight: DEPENDENCIES and
-- ELIGIBILITY. The cursor is a cursor — it walks the board in id order and applies the
-- review gate, exactly as the old `guild next` did. It can therefore hand you a ticket
-- that is waiting on a predecessor, or one nobody available can take.
--
-- `v_open_bounties` IS THE DISPATCH-READY SET. It is this rule PLUS dependencies PLUS a
-- ticket that names what it wants. Use the cursor to answer "where was I", and the bounty board to answer
-- "what can I hand out". They are two different questions and they have two views.
DROP VIEW IF EXISTS v_next_task;
CREATE VIEW v_next_task AS
SELECT 'resume'          AS reason,
       t.id              AS id,
       t.requirement_id  AS requirement_id,
       t.status          AS status,
       t.priority        AS priority,
       w.who             AS who,
       t.parallel_group  AS parallel_group,
       t.title           AS title
  FROM task t
  JOIN v_task_who w ON w.task_id = t.id
 WHERE t.id = (SELECT r.id FROM task r
                WHERE r.status = 'in-progress' ORDER BY r.id LIMIT 1)
UNION ALL
SELECT 'claim',
       a.id, a.requirement_id, a.status, a.priority, w.who, a.parallel_group, a.title
  FROM v_task_actionable a
  JOIN v_task_who w ON w.task_id = a.id
 WHERE NOT EXISTS (SELECT 1 FROM task x WHERE x.status = 'in-progress')
   AND a.id = (SELECT b.id FROM v_task_actionable b ORDER BY b.id LIMIT 1);


-- ------------------------------------------------------------------------------------
-- v_batch — the tasks that must dispatch TOGETHER with a given one
-- ------------------------------------------------------------------------------------
-- Every open task sharing a `parallel_group` AND a requirement. A task with no group is a
-- batch of one (it joins to itself).
--
-- A `blocked` MEMBER IS EXCLUDED and the group dispatches without it. It cannot be
-- dispatched — that is what blocked means — and the tasks in a parallel group touch
-- disjoint files by assertion, so the members that can run have no reason to wait.
-- Holding the whole batch would turn one unfillable ticket into a stalled group while telling
-- the reader nothing new. The review gate is where the blocked task is accounted for.
--
--   SELECT member_id FROM v_batch WHERE task_id = 'TASK-003'
DROP VIEW IF EXISTS v_batch;
CREATE VIEW v_batch AS
SELECT t1.id              AS task_id,
       t2.id              AS member_id,
       t2.status          AS member_status,
       COALESCE(t1.parallel_group, '') AS parallel_group,
       t2.title           AS member_title
  FROM task t1
  JOIN task t2
    ON t2.requirement_id = t1.requirement_id
   AND ( t2.id = t1.id
         OR ( COALESCE(t1.parallel_group, '') <> ''
              AND t2.parallel_group = t1.parallel_group ) )
 WHERE t2.status IN ('todo', 'in-progress');


-- ------------------------------------------------------------------------------------
-- THE MATCHER IS GONE FROM SQL — v_agent_eligible, v_agent_match, v_task_top_agent
-- ------------------------------------------------------------------------------------
-- These three views ranked every member against every ticket, and a roster table in here
-- would be a mirror: the real answer to "who exists and what can they do" is the frontmatter
-- of the agent files, and a copy of it could only ever be as fresh as the last sync somebody
-- remembered to run.
--
-- THE RULE THEY ENCODED IS THE DISPATCHER'S. It applies it in this order, against every
-- subagent available to the user:
--
--   pin         `task.agent` is set — spawn it. The capability match is not run at all.
--   capability  the ticket has `task_capability` rows — an agent is ELIGIBLE when its
--               frontmatter `capabilities:` cover every `required = 1` row. Among the
--               eligible, rank by: most `required = 0` (preferred) rows covered DESC,
--               then FEWEST declared capabilities ASC (a specialist beats a generalist),
--               then name ASC so the answer is deterministic.
--   nobody      no pin and no eligible agent — the dispatcher writes `status = 'blocked'`,
--               and the ticket says so on the board with the capability it is waiting for.
--
-- THE DROPS BELOW ARE LOAD-BEARING. Re-applying this file over a board that still carries
-- these views is what removes them, and they must go before the tables do (see 007).
DROP VIEW IF EXISTS v_task_top_agent;
DROP VIEW IF EXISTS v_agent_match;
DROP VIEW IF EXISTS v_agent_eligible;


-- ------------------------------------------------------------------------------------
-- v_open_bounties — WORK THAT CAN BE DISPATCHED RIGHT NOW, with its matched member
-- ------------------------------------------------------------------------------------
-- The cursor rule PLUS dependencies PLUS something to dispatch against. Three conditions:
--
--   1. actionable          `v_task_actionable` — todo, past the review gate
--   2. no unfinished deps  `v_task_deps` is empty for it
--   3. it names what it wants — a pinned `agent`, or at least one `task_capability` row
--
-- CONDITION 3 IS NARROWER THAN IT LOOKS, AND THE DIFFERENCE MATTERS. It does not mean
-- "somebody can take it" — the roster is not in this database, so this view can only
-- promise that the ticket ASKS FOR SOMEBODY. Whether anybody answers
-- is settled by the dispatcher reading the agent files. A row here is a candidate for
-- dispatch, not a guarantee of one, and a ticket whose required capabilities nobody
-- covers appears here once and then gets written to `blocked`.
--
-- `agent` is the pin or '-'. A '-' means "match me", and `who` names the capabilities to
-- match on.
--
-- Ordered by priority then id, which is the order a dispatcher should walk it. Note that
-- `v_next_task` deliberately does NOT consider priority (it takes the lowest id) — the
-- cursor resumes and claims in a fixed order, while the bounty board is a market. Both
-- behaviors are intended and they are different questions.
--
-- THIS VIEW MUTATES NOTHING. A ticket does not become `blocked` by being read. Moving it
-- is a decision, and decisions are writes somebody makes on purpose.
DROP VIEW IF EXISTS v_open_bounties;
CREATE VIEW v_open_bounties AS
SELECT t.id                                   AS id,
       t.requirement_id                       AS requirement_id,
       t.priority                             AS priority,
       COALESCE(NULLIF(t.agent, ''), '-')     AS agent,
       w.who                                  AS who,
       COALESCE(t.parallel_group, '')         AS parallel_group,
       t.title                                AS title
  FROM v_task_actionable t
  JOIN v_task_who       w ON w.task_id = t.id
 WHERE NOT EXISTS (SELECT 1 FROM v_task_deps d WHERE d.task_id = t.id)
   AND ( COALESCE(t.agent, '') <> ''
         OR EXISTS (SELECT 1 FROM task_capability tc WHERE tc.task_id = t.id) )
 ORDER BY t.priority, t.id;


-- ------------------------------------------------------------------------------------
-- v_blocked_tasks — EVERYTHING OPEN THAT CANNOT MOVE, AND WHY
-- ------------------------------------------------------------------------------------
-- The companion to `v_open_bounties`. Three ways in, and `reason` is one blank-free token
-- so it survives a whitespace-separated column:
--
--   status-blocked        the task is explicitly `blocked` — somebody already ruled
--   deps:TASK-009,…       waiting on unfinished direct predecessors
--   unassigned            no pin AND no capabilities: it names nobody and asks for
--                         nothing, so there is no question the dispatcher could answer
--
-- Order matters in that CASE. An explicitly blocked task says so even when it ALSO has
-- unfinished dependencies, because the status was a human's decision and the dependency
-- is a fact about the graph.
--
-- THERE IS NO `no-eligible-agent:rust,embedded` REASON, because computing it would need the
-- roster. A ticket that declares capabilities nobody covers is NOT listed here on its own —
-- it sits in `v_open_bounties` until the
-- dispatcher scans the agent files, finds nobody, and WRITES `status = 'blocked'`. It
-- then appears here as `status-blocked`, with `who` naming the capabilities it wants.
--
-- So the roster-gap query is: this view, `status-blocked`, read `who`. The `needs:…`
-- it prints is the agent file somebody needs to write.
DROP VIEW IF EXISTS v_blocked_tasks;
CREATE VIEW v_blocked_tasks AS
SELECT t.id                                   AS id,
       t.requirement_id                       AS requirement_id,
       t.status                               AS status,
       COALESCE(NULLIF(t.agent, ''), '-')     AS agent,
       w.who                                  AS who,
       CASE
         WHEN t.status = 'blocked' THEN 'status-blocked'
         WHEN EXISTS (SELECT 1 FROM v_task_deps d WHERE d.task_id = t.id)
           THEN 'deps:' || COALESCE((SELECT b.blockers FROM v_task_blockers b
                                      WHERE b.task_id = t.id), '')
         ELSE 'unassigned'
       END                                    AS reason,
       t.title                                AS title
  FROM task t
  JOIN v_task_who       w ON w.task_id = t.id
 WHERE t.status = 'blocked'
    OR ( t.status = 'todo'
         AND EXISTS (SELECT 1 FROM v_task_deps d WHERE d.task_id = t.id) )
    OR ( t.id IN (SELECT a.id FROM v_task_actionable a)
         AND NOT EXISTS (SELECT 1 FROM v_task_deps d WHERE d.task_id = t.id)
         AND COALESCE(t.agent, '') = ''
         AND NOT EXISTS (SELECT 1 FROM task_capability tc WHERE tc.task_id = t.id) )
 ORDER BY t.id;


-- ------------------------------------------------------------------------------------
-- v_ready_nodes — GRAPH NODES WHOSE DIRECT PREDECESSORS ARE ALL FINISHED
-- ------------------------------------------------------------------------------------
-- A node is READY when no direct predecessor is unfinished. That is a plain one-hop join
-- over `graph_edge` — vacuously true for a root node, which is correct: a node with no
-- predecessors is ready the moment the graph exists.
--
-- `done` and `skipped` both count as finished.
--
-- THERE IS NO TRANSITIVE CLOSURE HERE AND THERE MUST NOT BE ONE. `WITH RECURSIVE` does
-- not work on tursodb, and it is not needed: readiness propagates one node at a time as
-- the work runs. If you find yourself wanting to traverse, you want to run the graph.
--
-- Candidates are `pending` or `ready`. A `running` node is not offered again.
--
-- `gate_status` is non-NULL exactly when this node is a gate — which is the fast way to
-- tell "ready to dispatch" from "ready to ask a human".
DROP VIEW IF EXISTS v_ready_nodes;
CREATE VIEW v_ready_nodes AS
SELECT n.id                                   AS id,
       n.requirement_id                       AS requirement_id,
       n.node_key                             AS node_key,
       n.kind                                 AS kind,
       n.task_id                              AS task_id,
       COALESCE(n.parallel_group, '')         AS parallel_group,
       n.status                               AS status,
       COALESCE((SELECT group_concat(x, ',')
                   FROM (SELECT ge.from_node AS x FROM graph_edge ge
                          WHERE ge.to_node = n.id ORDER BY ge.from_node)), '')
                                              AS predecessors,
       (SELECT g.status FROM gate g WHERE g.node_id = n.id) AS gate_status,
       (SELECT g.kind   FROM gate g WHERE g.node_id = n.id) AS gate_kind,
       (SELECT g.prompt FROM gate g WHERE g.node_id = n.id) AS gate_prompt
  FROM graph_node n
 WHERE n.status IN ('pending', 'ready')
   AND NOT EXISTS (SELECT 1 FROM graph_edge ge
                     JOIN graph_node gp ON gp.id = ge.from_node
                    WHERE ge.to_node = n.id
                      AND gp.status NOT IN ('done', 'skipped'))
 ORDER BY n.requirement_id, n.id;


-- ------------------------------------------------------------------------------------
-- v_gates_pending — the gates that are waiting on a HUMAN, right now
-- ------------------------------------------------------------------------------------
-- A gate only counts as waiting once its own predecessors are done — an undecided gate
-- buried behind unfinished work is not something to ask about yet. This is the view an
-- unattended shift stops on.
DROP VIEW IF EXISTS v_gates_pending;
CREATE VIEW v_gates_pending AS
SELECT g.node_id       AS node_id,
       n.requirement_id AS requirement_id,
       n.node_key      AS node_key,
       g.kind          AS kind,
       g.prompt        AS prompt
  FROM gate g
  JOIN v_ready_nodes n ON n.id = g.node_id
 WHERE g.status = 'pending'
 ORDER BY n.requirement_id, g.node_id;


-- ------------------------------------------------------------------------------------
-- v_plans_pending_approval — the plans a HUMAN still has to rule on
-- ------------------------------------------------------------------------------------
-- The architect writes a plan. Nothing is built until the user approves it, and this is
-- the queue that says who is waiting. A plan still at `status = 'todo'` is not listed:
-- it has not been drafted yet, so there is nothing to agree with.
--
-- `gate_node_id` is the `gate-plan` node carrying the same decision, when one exists. It
-- is COALESCEd to '' rather than dropped: a plan with no gate node is legal (a small
-- change approved in conversation), and hiding it here would hide the plan.
DROP VIEW IF EXISTS v_plans_pending_approval;
CREATE VIEW v_plans_pending_approval AS
SELECT p.id                           AS id,
       p.requirement_id               AS requirement_id,
       COALESCE(p.task_id, '')        AS task_id,
       p.status                       AS status,
       COALESCE(p.gate_node_id, '')   AS gate_node_id,
       p.created_at                   AS created_at,
       p.title                        AS title
  FROM plan p
 WHERE p.approval = 'pending'
   AND p.status <> 'todo'
 ORDER BY p.requirement_id, p.id;


-- ------------------------------------------------------------------------------------
-- v_board — THE LIVE BOARD
-- ------------------------------------------------------------------------------------
--   SELECT section, id, who, title FROM v_board
--
-- One row per task, tagged with the section it belongs in and the order those sections
-- print. `Blocked` sits DIRECTLY UNDER `In Progress` rather than down with `Failed`,
-- because an unfillable ticket should be loud and the bottom of a long board is not — and it
-- reads correctly there: a blocked task is work that WOULD be in flight if the guild had
-- somebody to give it to.
--
-- The requirement roll-up is a separate view (`v_requirement_progress`) because it has a
-- different shape. A renderer prints this, then that.
--
-- The old CLI capped `Recently Completed` at the newest 20. This view does not cap
-- anything — that is the reader's call:
--
--   SELECT * FROM v_board WHERE section_no = 4 ORDER BY id DESC LIMIT 20
DROP VIEW IF EXISTS v_board;
CREATE VIEW v_board AS
SELECT 1 AS section_no, 'In Progress'        AS section,
       t.id, t.status, w.who, t.requirement_id, t.priority, t.title
  FROM task t JOIN v_task_who w ON w.task_id = t.id WHERE t.status = 'in-progress'
UNION ALL
SELECT 2, 'Blocked',
       t.id, t.status, w.who, t.requirement_id, t.priority, t.title
  FROM task t JOIN v_task_who w ON w.task_id = t.id WHERE t.status = 'blocked'
UNION ALL
SELECT 3, 'Backlog',
       t.id, t.status, w.who, t.requirement_id, t.priority, t.title
  FROM task t JOIN v_task_who w ON w.task_id = t.id WHERE t.status = 'todo'
UNION ALL
SELECT 4, 'Recently Completed',
       t.id, t.status, w.who, t.requirement_id, t.priority, t.title
  FROM task t JOIN v_task_who w ON w.task_id = t.id WHERE t.status = 'done'
UNION ALL
SELECT 5, 'Failed',
       t.id, t.status, w.who, t.requirement_id, t.priority, t.title
  FROM task t JOIN v_task_who w ON w.task_id = t.id WHERE t.status = 'failed'
UNION ALL
SELECT 6, 'Waived',
       t.id, t.status, w.who, t.requirement_id, t.priority, t.title
  FROM task t JOIN v_task_who w ON w.task_id = t.id WHERE t.status = 'waived'
 ORDER BY section_no, id;


-- ------------------------------------------------------------------------------------
-- v_requirement_progress — the Requirements section, with live counters
-- ------------------------------------------------------------------------------------
-- `tasks_open` counts todo + in-progress + BLOCKED. That is the number to look at before
-- closing a requirement: a requirement completed over a blocked task ships work nobody
-- ever attempted, and nothing in this schema will stop you (see "what this file cannot
-- enforce", item 2). `failed` is excluded from `tasks_open` because a human has already
-- ruled on it.
--
-- Sorted todo, then in-progress, then done — unfinished direction first.
DROP VIEW IF EXISTS v_requirement_progress;
CREATE VIEW v_requirement_progress AS
SELECT r.id         AS id,
       r.project_id AS project_id,
       r.status     AS status,
       r.priority  AS priority,
       COUNT(t.id) AS tasks_total,
       COALESCE(SUM(CASE WHEN t.status = 'done' THEN 1 ELSE 0 END), 0)    AS tasks_done,
       COALESCE(SUM(CASE WHEN t.status IN ('todo', 'in-progress', 'blocked')
                         THEN 1 ELSE 0 END), 0)                          AS tasks_open,
       COALESCE(SUM(CASE WHEN t.status = 'blocked' THEN 1 ELSE 0 END), 0) AS tasks_blocked,
       COALESCE(SUM(CASE WHEN t.status = 'failed'  THEN 1 ELSE 0 END), 0) AS tasks_failed,
       r.title     AS title
  FROM requirement r
  LEFT JOIN task t ON t.requirement_id = r.id
 GROUP BY r.id, r.project_id, r.status, r.priority, r.title
 ORDER BY CASE r.status WHEN 'todo' THEN 1 WHEN 'in-progress' THEN 2
                        WHEN 'done' THEN 3 ELSE 4 END, r.id;


-- ------------------------------------------------------------------------------------
-- v_projects_runnable — WHICH PROJECTS MAY RUN RIGHT NOW
-- ------------------------------------------------------------------------------------
-- THE PARALLELISM RULE, AND IT LIVES ONLY HERE. Three ways a project earns a place:
--
--   concurrent = 1   it never waits its turn. This is the "run beside other projects"
--                    case, and it is the whole reason `phase` became `project`.
--   ordinal IS NULL  it was never placed in a sequence, so there is no turn to wait for.
--   otherwise        it is sequential, and every SEQUENTIAL project with a LOWER ordinal
--                    in the same goal is done. A concurrent sibling never blocks it —
--                    a project that opted out of the queue does not get to hold it.
--
-- A done goal makes its projects unrunnable, whatever they say. A done project is never
-- listed.
--
-- `isolation` and `worktree_path` ride along because the caller that dispatches a project
-- is exactly the caller that has to know where its tasks run.
DROP VIEW IF EXISTS v_projects_runnable;
CREATE VIEW v_projects_runnable AS
SELECT p.id                          AS id,
       p.goal_id                     AS goal_id,
       p.status                      AS status,
       p.priority                    AS priority,
       p.ordinal                     AS ordinal,
       p.concurrent                  AS concurrent,
       p.isolation                   AS isolation,
       COALESCE(p.worktree_path, '') AS worktree_path,
       CASE WHEN p.concurrent = 1   THEN 'concurrent'
            WHEN p.ordinal IS NULL  THEN 'unordered'
            ELSE 'next in sequence' END AS why,
       p.title                       AS title
  FROM project p
  JOIN goal g ON g.id = p.goal_id
 WHERE p.status <> 'done'
   AND g.status <> 'done'
   AND (p.concurrent = 1
        OR p.ordinal IS NULL
        OR NOT EXISTS (SELECT 1 FROM project q
                        WHERE q.goal_id    = p.goal_id
                          AND q.concurrent = 0
                          AND q.ordinal IS NOT NULL
                          AND q.ordinal    < p.ordinal
                          AND q.status    <> 'done'))
 ORDER BY p.priority, p.goal_id,
          CASE WHEN p.ordinal IS NULL THEN 1 ELSE 0 END, p.ordinal, p.id;


-- ------------------------------------------------------------------------------------
-- v_project_progress — every project, with what is under it
-- ------------------------------------------------------------------------------------
-- The project-level mirror of `v_requirement_progress`, and the view a roadmap reads.
-- The task counters come through `requirement`, so a project with no requirements
-- reports zeroes rather than disappearing.
--
-- `runnable` is 1 when this project appears in `v_projects_runnable`. It is repeated here
-- so a roadmap does not have to join two views, and it is DERIVED from that view rather
-- than re-stating the rule — there is still only one definition of "may this run".
DROP VIEW IF EXISTS v_project_progress;
CREATE VIEW v_project_progress AS
SELECT p.id                            AS id,
       p.goal_id                       AS goal_id,
       p.status                        AS status,
       p.priority                      AS priority,
       p.ordinal                       AS ordinal,
       p.concurrent                    AS concurrent,
       p.isolation                     AS isolation,
       COALESCE(p.worktree_path, '')   AS worktree_path,
       CASE WHEN EXISTS (SELECT 1 FROM v_projects_runnable v WHERE v.id = p.id)
            THEN 1 ELSE 0 END          AS runnable,
       (SELECT COUNT(*) FROM requirement r WHERE r.project_id = p.id)
                                       AS requirements_total,
       (SELECT COUNT(*) FROM requirement r WHERE r.project_id = p.id AND r.status = 'done')
                                       AS requirements_done,
       (SELECT COUNT(*) FROM task t JOIN requirement r ON r.id = t.requirement_id
         WHERE r.project_id = p.id AND t.status IN ('todo', 'in-progress', 'blocked'))
                                       AS tasks_open,
       (SELECT COUNT(*) FROM task t JOIN requirement r ON r.id = t.requirement_id
         WHERE r.project_id = p.id AND t.status = 'blocked')
                                       AS tasks_blocked,
       p.title                         AS title
  FROM project p
 ORDER BY p.priority, p.goal_id,
          CASE WHEN p.ordinal IS NULL THEN 1 ELSE 0 END, p.ordinal, p.id;


-- ------------------------------------------------------------------------------------
-- v_goal_progress — the open goals, and what is runnable under each
-- ------------------------------------------------------------------------------------
-- This reports NO single "current" project. That would be a claim the schema cannot make:
-- several projects under one goal may be in flight at once, so the view reports a COUNT and
-- a LIST instead.
--
-- `runnable_project_ids` is a comma-joined list, which is a display convenience and NOT
-- something to parse — join `v_projects_runnable` on `goal_id` when you need the rows.
DROP VIEW IF EXISTS v_goal_progress;
CREATE VIEW v_goal_progress AS
SELECT g.id       AS id,
       g.status   AS status,
       g.priority AS priority,
       (SELECT COUNT(*) FROM project p WHERE p.goal_id = g.id)  AS projects_total,
       (SELECT COUNT(*) FROM project p WHERE p.goal_id = g.id AND p.status = 'done')
                                                                AS projects_done,
       (SELECT COUNT(*) FROM v_projects_runnable v WHERE v.goal_id = g.id)
                                                                AS projects_runnable,
       COALESCE((SELECT group_concat(v.id) FROM v_projects_runnable v
                  WHERE v.goal_id = g.id), '')                  AS runnable_project_ids,
       (SELECT COUNT(*) FROM requirement r JOIN project p ON p.id = r.project_id
         WHERE p.goal_id = g.id)                    AS requirements_total,
       (SELECT COUNT(*) FROM requirement r JOIN project p ON p.id = r.project_id
         WHERE p.goal_id = g.id AND r.status = 'done') AS requirements_done,
       g.title    AS title
  FROM goal g
 WHERE g.status <> 'done'
 ORDER BY g.priority, g.id;


-- ------------------------------------------------------------------------------------
-- v_in_flight — what is running, and for how long
-- ------------------------------------------------------------------------------------
-- `minutes` is against the wall clock, so it changes every time you read it. A large
-- number on a ticket nobody is watching is the classic sign of an agent that died.
DROP VIEW IF EXISTS v_in_flight;
CREATE VIEW v_in_flight AS
SELECT t.id              AS id,
       t.requirement_id  AS requirement_id,
       w.who             AS who,
       COALESCE(t.parallel_group, '')                       AS parallel_group,
       COALESCE(NULLIF(t.claimed_at, ''), t.updated_at)     AS since,
       CAST((julianday('now')
             - julianday(COALESCE(NULLIF(t.claimed_at, ''), t.updated_at)))
            * 1440 AS INTEGER)                              AS minutes,
       t.title           AS title
  FROM task t
  JOIN v_task_who w ON w.task_id = t.id
 WHERE t.status = 'in-progress'
 ORDER BY t.id;


-- ------------------------------------------------------------------------------------
-- v_failed_tasks — failures, and whether a human has ruled on them
-- ------------------------------------------------------------------------------------
-- `failed` is TWO different facts wearing one status. The orchestrator sets it the moment
-- an agent reports failure and then asks the user retry-or-skip. On SKIP it writes the
-- waiver into the ticket's work log, and from then on the ticket stops blocking anything.
--
-- Nothing in the schema records that decision — `task.status` is `failed` either way — so
-- THE WAIVER LIVES IN A WORK-LOG LINE'S PREFIX and this is the view that reads it back:
--
--   INSERT INTO work_log (task_id, ts, agent, entry)
--   VALUES ('TASK-009', <ts>, 'orchestrator', CAST(x'…' AS TEXT))
--   -- where the decoded entry begins exactly: Skipped by user
--
-- A PREFIX, not a substring, because `reason` below quotes agent prose that may well
-- contain the phrase. And the waiver is only ever consulted for a ticket already at
-- `failed`, so a stray log line cannot invent a waived ticket out of a healthy one.
--
-- `reason` is the most recent log entry that is NOT the waiver. Taking simply "the last
-- entry" would replace every waived ticket's reason with the waiver line itself and
-- discard the agent's actual report — the one thing on the row a reader cannot get from
-- the status. NULL when the agent failed before writing anything, which is common.
--
-- This is item 3 of "what this file cannot enforce". It is a marker, not a column.
DROP VIEW IF EXISTS v_failed_tasks;
CREATE VIEW v_failed_tasks AS
SELECT t.id             AS id,
       t.requirement_id AS requirement_id,
       w.who            AS who,
       CASE WHEN EXISTS (SELECT 1 FROM work_log wl
                          WHERE wl.task_id = t.id
                            AND wl.entry LIKE 'Skipped by user%')
            THEN 1 ELSE 0 END                                   AS waived,
       (SELECT wl.entry FROM work_log wl
         WHERE wl.task_id = t.id
           AND wl.entry NOT LIKE 'Skipped by user%'
         ORDER BY wl.ts DESC, wl.id DESC LIMIT 1)               AS reason,
       t.updated_at     AS updated_at,
       t.title          AS title
  FROM task t
  JOIN v_task_who w ON w.task_id = t.id
 WHERE t.status = 'failed'
 ORDER BY t.id;


-- ------------------------------------------------------------------------------------
-- v_open_findings — review findings that still owe work, worst first
-- ------------------------------------------------------------------------------------
-- `open` and `fixing` are the two dispositions that still owe something. `severity_rank`
-- exists so a caller sorts by severity without re-deriving the ladder — and the ladder is
-- shared with `v_open_bugs`, which is why it is spelled the same in both.
DROP VIEW IF EXISTS v_open_findings;
CREATE VIEW v_open_findings AS
SELECT f.id              AS id,
       f.task_id         AS task_id,
       t.requirement_id  AS requirement_id,
       f.reviewer        AS reviewer,
       f.severity        AS severity,
       CASE f.severity WHEN 'critical' THEN 1 WHEN 'major' THEN 2
                       WHEN 'minor' THEN 3 WHEN 'nit' THEN 4 ELSE 5 END AS severity_rank,
       f.disposition     AS disposition,
       f.file            AS file,
       f.line            AS line,
       f.fix_task_id     AS fix_task_id,
       f.created_at      AS created_at,
       f.summary         AS summary,
       f.detail          AS detail
  FROM review_finding f
  JOIN task t ON t.id = f.task_id
 WHERE f.disposition IN ('open', 'fixing')
 ORDER BY severity_rank, f.id;


-- ------------------------------------------------------------------------------------
-- v_open_bugs — bugs that still owe work, worst first
-- ------------------------------------------------------------------------------------
DROP VIEW IF EXISTS v_open_bugs;
CREATE VIEW v_open_bugs AS
SELECT b.id             AS id,
       b.severity       AS severity,
       CASE b.severity WHEN 'critical' THEN 1 WHEN 'major' THEN 2
                       WHEN 'minor' THEN 3 ELSE 5 END          AS severity_rank,
       b.status         AS status,
       b.found_by       AS found_by,
       b.requirement_id AS requirement_id,
       b.fix_task_id    AS fix_task_id,
       b.created_at     AS created_at,
       b.title          AS title
  FROM bug b
 WHERE b.status IN ('open', 'fixing')
 ORDER BY severity_rank, b.id;


-- ------------------------------------------------------------------------------------
-- v_recent_activity — the event feed, made readable
-- ------------------------------------------------------------------------------------
-- An `event` row carries `subject_type` + `subject_id` and nothing else, so a raw feed
-- reads "moved task TASK-001" twice in a row and never says WHICH task or what happened.
-- This view resolves the subject's title and renders the common payload as a phrase.
--
-- `subject_title` is a COALESCE over one GUARDED scalar subquery per titled table: the
-- type check sits inside the WHERE, so a non-matching type selects no rows and yields
-- NULL rather than a wrong title, and a deleted subject falls through to ''. Two of the
-- eight disagree with the obvious guess — `doc` is keyed by `slug`, and `coverage` calls
-- its human label `area`.
--
-- `json_extract` RAISES on malformed JSON and a raised error aborts the whole query, so
-- every extraction is wrapped in `CASE WHEN json_valid(...)`, which evaluates only the
-- matched branch. `event.payload` has a `json_valid` CHECK, but the guard stays: a CHECK
-- added today says nothing about rows written before it existed.
--
-- Newest first. Filter it against the check-in yourself:
--   SELECT * FROM v_recent_activity
--    WHERE ts >= (SELECT value FROM guild_state WHERE key = 'last-checkin')
DROP VIEW IF EXISTS v_recent_activity;
CREATE VIEW v_recent_activity AS
SELECT e.id           AS id,
       e.ts           AS ts,
       e.actor        AS actor,
       e.verb         AS verb,
       e.subject_type AS subject_type,
       e.subject_id   AS subject_id,
       COALESCE(
         (SELECT s.title FROM goal        s WHERE e.subject_type = 'goal'        AND s.id   = e.subject_id),
         (SELECT s.title FROM project     s WHERE e.subject_type = 'project'     AND s.id   = e.subject_id),
         (SELECT s.title FROM requirement s WHERE e.subject_type = 'requirement' AND s.id   = e.subject_id),
         (SELECT s.title FROM plan        s WHERE e.subject_type = 'plan'        AND s.id   = e.subject_id),
         (SELECT s.title FROM task        s WHERE e.subject_type = 'task'        AND s.id   = e.subject_id),
         (SELECT s.title FROM bug         s WHERE e.subject_type = 'bug'         AND s.id   = e.subject_id),
         (SELECT s.title FROM doc         s WHERE e.subject_type = 'doc'         AND s.slug = e.subject_id),
         (SELECT s.area  FROM coverage    s WHERE e.subject_type = 'coverage'    AND s.id   = e.subject_id),
         '')          AS subject_title,
       CASE WHEN json_valid(e.payload) THEN
         CASE WHEN COALESCE(CAST(json_extract(e.payload, '$.to') AS TEXT), '') <> ''
              THEN COALESCE(CAST(json_extract(e.payload, '$.from') AS TEXT), '?')
                   || ' -> ' || CAST(json_extract(e.payload, '$.to') AS TEXT)
              ELSE '' END
         ELSE '' END  AS phrase,
       e.payload      AS payload
  FROM event e
 ORDER BY e.ts DESC, e.id DESC;


-- ------------------------------------------------------------------------------------
-- v_coverage_due — QUALITY AREAS NOBODY HAS LOOKED AT LATELY
-- ------------------------------------------------------------------------------------
-- Never inspected, or past its risk-weighted interval. The thresholds ARE the judgment
-- this view encodes, and they are stated exactly once — here:
--
--   high risk    stale after 14 days
--   medium risk  stale after 30 days
--   low risk     stale after 90 days
--
-- An unrecognized risk value falls to the medium threshold rather than vanishing, which
-- is the safe direction to fall. (The CHECK on `coverage.risk` makes that unreachable
-- today, and the ELSE stays because a widened vocabulary should not silently drop rows.)
--
-- `days_since` is NULL for an area that has never been inspected — which is not "0 days
-- ago", and a reader that renders it as such is lying about the state of the product.
--
-- The clock is `'now'`, so this view is time-dependent by design.
DROP VIEW IF EXISTS v_coverage_due;
CREATE VIEW v_coverage_due AS
SELECT c.id                AS id,
       c.risk              AS risk,
       c.spec_path         AS spec_path,
       c.last_inspected_at AS last_inspected_at,
       CASE c.risk WHEN 'high' THEN 14 WHEN 'low' THEN 90 ELSE 30 END AS interval_days,
       CASE WHEN COALESCE(c.last_inspected_at, '') = '' THEN NULL
            ELSE CAST(julianday('now') - julianday(c.last_inspected_at) AS INTEGER)
       END                 AS days_since,
       c.area              AS area,
       c.notes             AS notes
  FROM coverage c
 WHERE COALESCE(c.last_inspected_at, '') = ''
    OR (julianday('now') - julianday(c.last_inspected_at))
       >= CASE c.risk WHEN 'high' THEN 14 WHEN 'low' THEN 90 ELSE 30 END
 ORDER BY CASE c.risk WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END, c.id;




-- ------------------------------------------------------------------------------------
-- v_knowledge_ref — EVERY ROW A knowledge_edge IS ALLOWED TO POINT AT, WITH A TITLE
-- ------------------------------------------------------------------------------------
-- The helper the rest of the library's views stand on. It exists because an edge endpoint
-- is POLYMORPHIC: `('requirement','REQ-004')` and `('doc','adr-session-store')` live in
-- different tables, and every reader would otherwise re-type the same eight-branch
-- COALESCE that `v_recent_activity` already carries once.
--
-- It answers two questions at once, and that is the whole trick:
--   DOES THIS ENDPOINT EXIST?   a missing row is a dangling edge -> `v_knowledge_dangling`
--   WHAT IS IT CALLED?          so a neighbourhood reads as prose, not as ids
--
-- `coverage` contributes its `area` and `review_finding` its `summary`, because those are
-- what those tables call their human-readable column. `review_finding.id` is an INTEGER,
-- so it is CAST here — an edge's `to_id` is TEXT and '42' is what a STRICT column stores.
--
-- THE TITLE IS RAW FREE TEXT. It can contain pipes and newlines, exactly like every other
-- title in this file, and flattening it is the READER's job (gotcha 3). No view here
-- flattens, so that the value stays byte-exact for a reader that asks for one column.
DROP VIEW IF EXISTS v_knowledge_ref;
CREATE VIEW v_knowledge_ref AS
SELECT 'doc'            AS ref_type, slug              AS ref_id, title   AS title FROM doc
UNION ALL SELECT 'goal',           id,                 title   FROM goal
UNION ALL SELECT 'project',        id,                 title   FROM project
UNION ALL SELECT 'requirement',    id,                 title   FROM requirement
UNION ALL SELECT 'plan',           id,                 title   FROM plan
UNION ALL SELECT 'task',           id,                 title   FROM task
UNION ALL SELECT 'bug',            id,                 title   FROM bug
UNION ALL SELECT 'coverage',       id,                 area    FROM coverage
UNION ALL SELECT 'review_finding', CAST(id AS TEXT),   summary FROM review_finding;


-- ------------------------------------------------------------------------------------
-- v_doc_current — THE LIBRARY AS IT STANDS, WITH THE HISTORY STILL BEHIND IT
-- ------------------------------------------------------------------------------------
-- A document is current when it is not `superseded`, not `rejected`, and NOTHING claims to
-- supersede it. The second half matters: `supersedes` is written by the NEW document, and
-- the old one's `status` is a second write somebody has to remember. This view does not
-- depend on them remembering — an inbound `supersedes` edge is enough to retire a page.
--
-- `draft` is INCLUDED. A draft is the current state of a topic somebody is actively
-- writing, and hiding it produces the worst outcome available: two people drafting the
-- same page because neither could see the other's.
DROP VIEW IF EXISTS v_doc_current;
CREATE VIEW v_doc_current AS
SELECT d.slug       AS slug,
       d.title      AS title,
       d.kind       AS kind,
       d.status     AS status,
       d.area       AS area,
       d.source     AS source,
       d.created_at AS created_at,
       d.updated_at AS updated_at,
       (SELECT COUNT(*) FROM doc_revision v WHERE v.slug = d.slug)      AS revisions,
       (SELECT COUNT(*) FROM knowledge_edge k
         WHERE (k.from_type = 'doc' AND k.from_id = d.slug)
            OR (k.to_type   = 'doc' AND k.to_id   = d.slug))            AS edges
  FROM doc d
 WHERE d.status IN ('draft', 'current')
   AND NOT EXISTS (SELECT 1 FROM knowledge_edge ke
                    WHERE ke.rel = 'supersedes'
                      AND ke.to_type = 'doc' AND ke.to_id = d.slug)
 ORDER BY d.kind, d.area, d.slug;


-- ------------------------------------------------------------------------------------
-- v_doc_neighbors — ONE HOP, BOTH DIRECTIONS. THE ONLY TRAVERSAL THIS ENGINE HAS
-- ------------------------------------------------------------------------------------
--   SELECT * FROM v_doc_neighbors WHERE slug = 'adr-session-store'
--
-- This is what a member reads BEFORE writing a document, so it links into the graph
-- instead of landing beside it as another orphan.
--
-- ONE HOP IS NOT A LIMITATION OF THE MODEL, IT IS A LIMITATION OF THE ENGINE. There is no
-- `WITH RECURSIVE` on tursodb, so a supersession chain three deep is THREE QUERIES, each
-- feeding the next — the same concession `v_ready_nodes` makes for the execution graph,
-- and for the same reason. Do not try to write the closure. Loop in the caller, and cap
-- the loop, because `contradicts` and `depends-on` can legitimately form a cycle here in
-- a way `graph_edge` may not.
--
-- `direction` is 'out' for an edge this doc asserts and 'in' for one asserted about it.
-- Both are in the same view because "what does this page relate to" never meant one of them.
DROP VIEW IF EXISTS v_doc_neighbors;
CREATE VIEW v_doc_neighbors AS
SELECT ke.from_id            AS slug,
       'out'                 AS direction,
       ke.rel                AS rel,
       ke.to_type            AS other_type,
       ke.to_id              AS other_id,
       COALESCE(r.title, '') AS other_title,
       ke.note               AS note,
       ke.created_by         AS created_by,
       ke.created_at         AS created_at
  FROM knowledge_edge ke
  LEFT JOIN v_knowledge_ref r ON r.ref_type = ke.to_type AND r.ref_id = ke.to_id
 WHERE ke.from_type = 'doc'
UNION ALL
SELECT ke.to_id, 'in', ke.rel, ke.from_type, ke.from_id,
       COALESCE(r.title, ''), ke.note, ke.created_by, ke.created_at
  FROM knowledge_edge ke
  LEFT JOIN v_knowledge_ref r ON r.ref_type = ke.from_type AND r.ref_id = ke.from_id
 WHERE ke.to_type = 'doc'
 ORDER BY 1, 2, 3, 5;


-- ------------------------------------------------------------------------------------
-- v_doc_stale — THE WORK MOVED AND THE PAGE DID NOT
-- ------------------------------------------------------------------------------------
-- Documentation drift, derived rather than declared. A document is stale when something it
-- `describes` or `decides` has an `event` NEWER than the document's own `updated_at`.
--
-- This is why the edges are worth writing. `event` is already a complete record of every
-- mutation on the board, so the moment a doc names its subject, the database can tell you
-- the subject changed underneath it. Nobody files a "docs are out of date" ticket — the
-- ticket is a SELECT.
--
-- TWO HONEST LIMITS, both stated rather than hidden:
--   * IT CANNOT SEE THE CODE. Only board events. A refactor that touched no row moves
--     nothing here. `v_undocumented_work` and a human reading the diff cover that half.
--   * AN UNLINKED DOC IS NEVER STALE. No edge, no subject, no signal. That is the correct
--     failure direction — the fix is to link it, and `v_doc_current.edges = 0` finds it.
--
-- TIMESTAMPS ARE COMPARED AT SECOND PRECISION, via `substr(ts, 1, 19)`. The triggers write
-- `event.ts` with MILLISECONDS ('...T10:00:00.123Z') and every `updated_at` without
-- ('...T10:00:00Z'), and a raw string comparison of those two puts '.' before 'Z' — so the
-- millisecond form sorts EARLIER than the second form at the same instant, and a doc would
-- read as fresh for up to a second after its subject moved. Truncating both to 19
-- characters is what makes the comparison mean what it says.
--
-- ONE ROW PER (doc, stale subject). A doc describing three moved requirements is three
-- rows, so COUNT DISTINCT the slug when you want "how many pages need attention".
DROP VIEW IF EXISTS v_doc_stale;
CREATE VIEW v_doc_stale AS
SELECT d.slug                AS slug,
       d.title               AS title,
       d.kind                AS kind,
       d.area                AS area,
       ke.rel                AS rel,
       ke.to_type            AS subject_type,
       ke.to_id              AS subject_id,
       substr(d.updated_at, 1, 19) AS doc_updated_at,
       (SELECT MAX(substr(e.ts, 1, 19)) FROM event e
         WHERE e.subject_type = ke.to_type AND e.subject_id = ke.to_id) AS subject_moved_at
  FROM doc d
  JOIN knowledge_edge ke
    ON ke.from_type = 'doc' AND ke.from_id = d.slug
   AND ke.rel IN ('describes', 'decides')
 WHERE d.status = 'current'
   AND (SELECT MAX(substr(e.ts, 1, 19)) FROM event e
         WHERE e.subject_type = ke.to_type AND e.subject_id = ke.to_id)
       > substr(d.updated_at, 1, 19)
 ORDER BY subject_moved_at DESC, d.slug;


-- ------------------------------------------------------------------------------------
-- v_undocumented_work — SHIPPED, AND NOBODY WROTE IT DOWN
-- ------------------------------------------------------------------------------------
-- Every `done` requirement with no `current` or `draft` document claiming to describe or
-- decide it. Documentation coverage, in exactly the idiom `v_coverage_due` already uses
-- for quality coverage: the gap is a QUERY, not somebody's recollection.
--
-- ONLY `done` REQUIREMENTS. Documenting work in flight is documenting a moving target, and
-- the `document` node in the standard template runs after `repair` for that reason.
--
-- A `rejected` document does not count as coverage. A `draft` one does — somebody is on it.
DROP VIEW IF EXISTS v_undocumented_work;
CREATE VIEW v_undocumented_work AS
SELECT r.id         AS id,
       r.title      AS title,
       r.project_id AS project_id,
       r.updated_at AS finished_at,
       CAST((SELECT COUNT(*) FROM task t
              WHERE t.requirement_id = r.id AND t.status = 'done') AS INTEGER) AS tasks_done
  FROM requirement r
 WHERE r.status = 'done'
   AND NOT EXISTS (SELECT 1
                     FROM knowledge_edge ke
                     JOIN doc d ON d.slug = ke.from_id
                    WHERE ke.from_type = 'doc'
                      AND ke.to_type = 'requirement' AND ke.to_id = r.id
                      AND ke.rel IN ('describes', 'decides')
                      AND d.status <> 'rejected')
 ORDER BY r.updated_at DESC, r.id;


-- ------------------------------------------------------------------------------------
-- v_decision_log — WHAT THIS PROJECT DECIDED, IN ORDER, INCLUDING WHAT IT UNDECIDED
-- ------------------------------------------------------------------------------------
-- The ADR log. `kind = 'decision'` documents, newest first, each carrying what it replaced,
-- what it governs, and how many times it has been rewritten.
--
-- SUPERSEDED AND REJECTED DECISIONS ARE INCLUDED ON PURPOSE. A decision log that shows only
-- the decisions still standing is not a history, it is a snapshot wearing a history's name —
-- and the question this view exists to answer ("why is it like this") is usually answered by
-- the option that was dropped. Filter on `status` if you want only the live ones.
--
-- `supersedes` and `governs` are space-separated id lists built with `group_concat`. Ids are
-- a closed alphabet, so they are safe in a whitespace-separated column — which is exactly
-- why the columns carry ids and not titles.
DROP VIEW IF EXISTS v_decision_log;
CREATE VIEW v_decision_log AS
SELECT d.slug       AS slug,
       d.title      AS title,
       d.status     AS status,
       d.area       AS area,
       d.source     AS source,
       d.created_at AS created_at,
       d.updated_at AS updated_at,
       COALESCE((SELECT group_concat(k.to_id, ' ') FROM knowledge_edge k
                  WHERE k.rel = 'supersedes' AND k.from_type = 'doc' AND k.from_id = d.slug),
                '')                                                       AS supersedes,
       COALESCE((SELECT group_concat(k.from_id, ' ') FROM knowledge_edge k
                  WHERE k.rel = 'supersedes' AND k.to_type = 'doc' AND k.to_id = d.slug),
                '')                                                       AS superseded_by,
       COALESCE((SELECT group_concat(k.to_type || ':' || k.to_id, ' ') FROM knowledge_edge k
                  WHERE k.rel = 'decides' AND k.from_type = 'doc' AND k.from_id = d.slug),
                '')                                                       AS governs,
       (SELECT COUNT(*) FROM doc_revision v WHERE v.slug = d.slug)         AS revisions
  FROM doc d
 WHERE d.kind = 'decision'
 ORDER BY d.created_at DESC, d.slug;


-- ------------------------------------------------------------------------------------
-- v_knowledge_dangling — THE FOREIGN KEY THE ENGINE CANNOT GIVE US
-- ------------------------------------------------------------------------------------
-- Every edge with an endpoint that no longer exists, one row per broken END, so an edge
-- broken at both ends reports twice and neither is hidden by the other.
--
-- THIS VIEW IS A GLOBAL INVARIANT — see docs/expectations.md. It must return ZERO ROWS at
-- all times, and `guild:validate` checks it. It is not a report you run when curious.
--
-- It exists because `knowledge_edge` endpoints are polymorphic and SQLite cannot REFERENCE
-- a table chosen at runtime (item 11). The write-time check —
-- `INSERT ... SELECT ... FROM <target> WHERE id = ...` — stops you CREATING a dangling
-- edge. Nothing stops you creating one by DELETING the other end later, and that is the
-- case this view is here for.
--
-- `doc_revision` is deliberately NOT checked. A revision outliving its document is history
-- working correctly, not a dangling reference.
DROP VIEW IF EXISTS v_knowledge_dangling;
CREATE VIEW v_knowledge_dangling AS
SELECT ke.id         AS edge_id,
       ke.rel        AS rel,
       'from'        AS broken_side,
       ke.from_type  AS missing_type,
       ke.from_id    AS missing_id,
       ke.to_type    AS other_type,
       ke.to_id      AS other_id,
       ke.created_by AS created_by,
       ke.created_at AS created_at
  FROM knowledge_edge ke
 WHERE NOT EXISTS (SELECT 1 FROM v_knowledge_ref r
                    WHERE r.ref_type = ke.from_type AND r.ref_id = ke.from_id)
UNION ALL
SELECT ke.id, ke.rel, 'to', ke.to_type, ke.to_id, ke.from_type, ke.from_id,
       ke.created_by, ke.created_at
  FROM knowledge_edge ke
 WHERE NOT EXISTS (SELECT 1 FROM v_knowledge_ref r
                    WHERE r.ref_type = ke.to_type AND r.ref_id = ke.to_id)
 ORDER BY 1, 3;


-- ------------------------------------------------------------------------------------
-- THE ROSTER VIEWS ARE GONE — v_capability_vocabulary, v_capability_unknown, v_roster_gaps
-- ------------------------------------------------------------------------------------
-- A vocabulary view, an unknown-tag audit and a roster-gap list would all need roster
-- tables, and there are none.
--
-- WHERE EACH QUESTION GOES:
--
--   "what words does this guild know?"
--       The union of `capabilities:` across the frontmatter of every subagent available
--       to the user. Read the files. There is no seed list to keep in step, and a word is
--       legal exactly when some agent claims it — which is the only definition that cannot
--       drift.
--
--   "which tags match nobody?"
--       The dispatcher answers it by scanning, and it answers LOUDLY: the ticket goes to
--       `blocked` and sits on the board naming the capability. That is strictly better
--       than a view somebody had to remember to run when the matcher went quiet.
--
--   "what gaps are open?"
--       `SELECT id, who FROM v_blocked_tasks WHERE reason = 'status-blocked'`. Each
--       `needs:…` is an agent file waiting to be written.
--
-- THE DROPS BELOW ARE LOAD-BEARING, exactly as the matcher's are.
DROP VIEW IF EXISTS v_roster_gaps;
DROP VIEW IF EXISTS v_capability_unknown;
DROP VIEW IF EXISTS v_capability_vocabulary;


-- ------------------------------------------------------------------------------------
-- v_brief — THE STANDUP, AS A LIST OF FACTS
-- ------------------------------------------------------------------------------------
--   SELECT fact, value FROM v_brief
--
-- One fact per row, `value` always TEXT. This is the shape a narrator reads before it
-- decides which of the detail views to open — the counts here and the lists elsewhere are
-- derived from the SAME views, so a count and its listing cannot disagree.
--
-- `next` is 'none' when there is nothing to do, which is NOT the same as "finished" —
-- read `bounties_stuck` and `gates_pending` in the same breath.
DROP VIEW IF EXISTS v_brief;
CREATE VIEW v_brief AS
SELECT  1 AS ord, 'generated_at'      AS fact, strftime('%Y-%m-%dT%H:%M:%SZ', 'now') AS value
UNION ALL SELECT  2, 'actor',         COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator')
UNION ALL SELECT  3, 'last_checkin',  COALESCE((SELECT value FROM guild_state WHERE key = 'last-checkin'), 'null')
UNION ALL SELECT  4, 'next',          COALESCE((SELECT id     FROM v_next_task LIMIT 1), 'none')
UNION ALL SELECT  5, 'next_reason',   COALESCE((SELECT reason FROM v_next_task LIMIT 1), 'none')
UNION ALL SELECT  6, 'tasks_in_progress',   CAST((SELECT COUNT(*) FROM task WHERE status = 'in-progress') AS TEXT)
UNION ALL SELECT  7, 'tasks_todo',          CAST((SELECT COUNT(*) FROM task WHERE status = 'todo') AS TEXT)
UNION ALL SELECT  8, 'tasks_blocked',       CAST((SELECT COUNT(*) FROM task WHERE status = 'blocked') AS TEXT)
UNION ALL SELECT  9, 'tasks_failed',        CAST((SELECT COUNT(*) FROM task WHERE status = 'failed') AS TEXT)
UNION ALL SELECT 10, 'tasks_failed_waived', CAST((SELECT COUNT(*) FROM v_failed_tasks WHERE waived = 1) AS TEXT)
UNION ALL SELECT 11, 'tasks_done',          CAST((SELECT COUNT(*) FROM task WHERE status = 'done') AS TEXT)
UNION ALL SELECT 12, 'bounties_open',       CAST((SELECT COUNT(*) FROM v_open_bounties) AS TEXT)
UNION ALL SELECT 13, 'bounties_stuck',      CAST((SELECT COUNT(*) FROM v_blocked_tasks) AS TEXT)
UNION ALL SELECT 14, 'requirements_open',   CAST((SELECT COUNT(*) FROM requirement WHERE status <> 'done') AS TEXT)
UNION ALL SELECT 15, 'requirements_done',   CAST((SELECT COUNT(*) FROM requirement WHERE status = 'done') AS TEXT)
UNION ALL SELECT 16, 'projects_open',       CAST((SELECT COUNT(*) FROM project WHERE status <> 'done') AS TEXT)
UNION ALL SELECT 17, 'projects_runnable',   CAST((SELECT COUNT(*) FROM v_projects_runnable) AS TEXT)
UNION ALL SELECT 18, 'projects_worktree',   CAST((SELECT COUNT(*) FROM v_projects_runnable WHERE isolation = 'worktree') AS TEXT)
UNION ALL SELECT 19, 'bugs_open',           CAST((SELECT COUNT(*) FROM v_open_bugs) AS TEXT)
UNION ALL SELECT 20, 'findings_open',       CAST((SELECT COUNT(*) FROM v_open_findings) AS TEXT)
UNION ALL SELECT 21, 'coverage_due',        CAST((SELECT COUNT(*) FROM v_coverage_due) AS TEXT)
UNION ALL SELECT 22, 'nodes_ready',         CAST((SELECT COUNT(*) FROM v_ready_nodes WHERE kind = 'work') AS TEXT)
UNION ALL SELECT 23, 'gates_pending',       CAST((SELECT COUNT(*) FROM v_gates_pending) AS TEXT)
UNION ALL SELECT 24, 'plans_pending_approval', CAST((SELECT COUNT(*) FROM v_plans_pending_approval) AS TEXT)
UNION ALL SELECT 25, 'events_since_checkin',
  CAST((SELECT COUNT(*) FROM event
         WHERE ts >= COALESCE(NULLIF((SELECT value FROM guild_state WHERE key = 'last-checkin'), 'null'), '')) AS TEXT)
-- The library's three facts. `docs_stale` counts PAGES, not (page, subject) pairs, which
-- is why it is a COUNT DISTINCT — `v_doc_stale` emits one row per stale subject
UNION ALL SELECT 26, 'docs_current',        CAST((SELECT COUNT(*) FROM v_doc_current) AS TEXT)
UNION ALL SELECT 27, 'docs_stale',          CAST((SELECT COUNT(DISTINCT slug) FROM v_doc_stale) AS TEXT)
UNION ALL SELECT 28, 'work_undocumented',   CAST((SELECT COUNT(*) FROM v_undocumented_work) AS TEXT)
 ORDER BY ord;


-- =====================================================================================
-- =====================================================================================
--  T R I G G E R S   —   T H E   G U I L D ' S   M E M O R Y
-- =====================================================================================
-- =====================================================================================
--
-- Two jobs, and nothing else:
--
--   1. EVERY MEANINGFUL MUTATION WRITES AN `event` ROW. Nobody has to remember to. The
--      activity feed, the briefing's event count and any dashboard are all built on those
--      rows, so a mutation that recorded no event would be invisible to every surface at
--      once.
--   2. `updated_at` IS STAMPED when a row changes and the writer did not set it.
--
-- WHY THEY CANNOT RECURSE.
--   * The event triggers INSERT into `event`, and `event` HAS NO TRIGGERS. Dead end.
--   * The `_touch` triggers UPDATE their own table, which would recurse — except the
--     `WHEN new.updated_at IS old.updated_at` guard: the trigger's own UPDATE changes
--     `updated_at`, so on any re-entry the guard is false and it stops. That holds even
--     if a member turns `PRAGMA recursive_triggers = ON`, which is the whole reason the
--     guard is written that way rather than relying on the default being OFF.
--
-- WHAT IS DELIBERATELY NOT INSTRUMENTED, and why:
--   * `task_capability` — the architect writes the whole set at plan time and rewrites it
--     wholesale when a ticket is re-scoped, so instrumenting it would bury the feed under
--     churn that says nothing. The `task` row itself is instrumented instead.
--   * `graph_node` INSERTS — instantiating one requirement's graph writes dozens of nodes
--     in a breath. Only node STATUS CHANGES are recorded, which is the part that means
--     something moved.
--   * `graph_edge`, `task_dependency`, `inspection_coverage` — structure,
--     written once at creation time alongside a parent that IS instrumented.
--
-- `knowledge_edge` IS THE EXCEPTION TO THAT LAST LINE, and the exception is the point: it
-- looks like a structure table and is not one. A `graph_edge` is written wholesale beside
-- an instrumented node. A `knowledge_edge` is an ASSERTION a member made about what
-- relates to what, arriving a few rows at a time, and who claimed it when is exactly what
-- the feed is for. It carries both an INSERT and a DELETE trigger — retracting a claim is
-- as much a decision as making one.
--
-- THE ACTOR IS `guild_state.actor`, defaulting to 'orchestrator'. Set it at the top of
-- your script. It is a label, not an identity — item 1 of "what this file cannot enforce".
--
-- ADD A TRIGGER WHEN YOU ADD A TABLE. A silent table is a table nobody can audit.


-- ---- goal ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_goal_created;
CREATE TRIGGER trg_goal_created AFTER INSERT ON goal
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'created', 'goal', new.id,
          json_object('status', new.status, 'priority', new.priority));
END;

DROP TRIGGER IF EXISTS trg_goal_moved;
CREATE TRIGGER trg_goal_moved AFTER UPDATE OF status ON goal
WHEN old.status IS NOT new.status
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'moved', 'goal', new.id,
          json_object('from', old.status, 'to', new.status));
END;

DROP TRIGGER IF EXISTS trg_goal_deleted;
CREATE TRIGGER trg_goal_deleted AFTER DELETE ON goal
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'deleted', 'goal', old.id, json_object('title', old.title));
END;

DROP TRIGGER IF EXISTS trg_goal_touch;
CREATE TRIGGER trg_goal_touch AFTER UPDATE ON goal
WHEN new.updated_at IS old.updated_at
BEGIN
  UPDATE goal SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = new.id;
END;


-- ---- project ------------------------------------------------------------------------
-- The created event carries `concurrent` and `isolation` because "was this meant to run
-- beside the others, and where" is the question a post-mortem asks about a project, and
-- both are decisions somebody made rather than facts that fell out.
DROP TRIGGER IF EXISTS trg_project_created;
CREATE TRIGGER trg_project_created AFTER INSERT ON project
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'created', 'project', new.id,
          json_object('goal_id', new.goal_id, 'ordinal', new.ordinal,
                      'concurrent', new.concurrent, 'isolation', new.isolation));
END;

DROP TRIGGER IF EXISTS trg_project_moved;
CREATE TRIGGER trg_project_moved AFTER UPDATE OF status ON project
WHEN old.status IS NOT new.status
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'moved', 'project', new.id,
          json_object('from', old.status, 'to', new.status, 'goal_id', new.goal_id));
END;

-- Cutting or abandoning a worktree changes WHERE every task under this project runs, so
-- it is recorded even though nothing else about the row moved.
DROP TRIGGER IF EXISTS trg_project_isolated;
CREATE TRIGGER trg_project_isolated AFTER UPDATE OF isolation, worktree_path ON project
WHEN old.isolation IS NOT new.isolation OR old.worktree_path IS NOT new.worktree_path
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'isolated', 'project', new.id,
          json_object('from', old.isolation, 'to', new.isolation,
                      'worktree_path', new.worktree_path));
END;

DROP TRIGGER IF EXISTS trg_project_deleted;
CREATE TRIGGER trg_project_deleted AFTER DELETE ON project
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'deleted', 'project', old.id, json_object('title', old.title));
END;

DROP TRIGGER IF EXISTS trg_project_touch;
CREATE TRIGGER trg_project_touch AFTER UPDATE ON project
WHEN new.updated_at IS old.updated_at
BEGIN
  UPDATE project SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = new.id;
END;


-- ---- requirement --------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_requirement_created;
CREATE TRIGGER trg_requirement_created AFTER INSERT ON requirement
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'created', 'requirement', new.id,
          json_object('project_id', new.project_id, 'priority', new.priority));
END;

DROP TRIGGER IF EXISTS trg_requirement_moved;
CREATE TRIGGER trg_requirement_moved AFTER UPDATE OF status ON requirement
WHEN old.status IS NOT new.status
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'moved', 'requirement', new.id,
          json_object('from', old.status, 'to', new.status,
                      'tasks_open', (SELECT COUNT(*) FROM task
                                      WHERE requirement_id = new.id
                                        AND status IN ('todo', 'in-progress', 'blocked'))));
END;

DROP TRIGGER IF EXISTS trg_requirement_deleted;
CREATE TRIGGER trg_requirement_deleted AFTER DELETE ON requirement
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'deleted', 'requirement', old.id, json_object('title', old.title));
END;

DROP TRIGGER IF EXISTS trg_requirement_touch;
CREATE TRIGGER trg_requirement_touch AFTER UPDATE ON requirement
WHEN new.updated_at IS old.updated_at
BEGIN
  UPDATE requirement SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = new.id;
END;


-- ---- plan ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_plan_created;
CREATE TRIGGER trg_plan_created AFTER INSERT ON plan
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'created', 'plan', new.id,
          json_object('requirement_id', new.requirement_id, 'task_id', new.task_id));
END;

DROP TRIGGER IF EXISTS trg_plan_moved;
CREATE TRIGGER trg_plan_moved AFTER UPDATE OF status ON plan
WHEN old.status IS NOT new.status
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'moved', 'plan', new.id,
          json_object('from', old.status, 'to', new.status));
END;

DROP TRIGGER IF EXISTS trg_plan_deleted;
CREATE TRIGGER trg_plan_deleted AFTER DELETE ON plan
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'deleted', 'plan', old.id, json_object('title', old.title));
END;

-- Approval is the one plan event a HUMAN is behind, so it is recorded apart from the
-- drafting status and the ruler's name rides along. `decided` is the same verb a gate
-- decision uses — it is the same act, recorded on whichever row carries it.
DROP TRIGGER IF EXISTS trg_plan_approved;
CREATE TRIGGER trg_plan_approved AFTER UPDATE OF approval ON plan
WHEN old.approval IS NOT new.approval
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE(NULLIF(new.approved_by, ''),
                   (SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'decided', 'plan', new.id,
          json_object('from', old.approval, 'to', new.approval,
                      'requirement_id', new.requirement_id,
                      'gate_node_id', new.gate_node_id));
END;

DROP TRIGGER IF EXISTS trg_plan_touch;
CREATE TRIGGER trg_plan_touch AFTER UPDATE ON plan
WHEN new.updated_at IS old.updated_at
BEGIN
  UPDATE plan SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = new.id;
END;


-- ---- task ---------------------------------------------------------------------------
-- The status event carries `agent` as well as from/to, because "who was this dispatched
-- to" is the question every post-mortem asks first and the ticket may be reassigned
-- later.
DROP TRIGGER IF EXISTS trg_task_created;
CREATE TRIGGER trg_task_created AFTER INSERT ON task
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'created', 'task', new.id,
          json_object('requirement_id', new.requirement_id, 'agent', new.agent,
                      'priority', new.priority, 'parallel_group', new.parallel_group));
END;

DROP TRIGGER IF EXISTS trg_task_moved;
CREATE TRIGGER trg_task_moved AFTER UPDATE OF status ON task
WHEN old.status IS NOT new.status
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'moved', 'task', new.id,
          json_object('from', old.status, 'to', new.status,
                      'agent', COALESCE(new.claimed_by, new.agent),
                      'requirement_id', new.requirement_id));
END;

DROP TRIGGER IF EXISTS trg_task_claimed;
CREATE TRIGGER trg_task_claimed AFTER UPDATE OF claimed_by ON task
WHEN old.claimed_by IS NOT new.claimed_by AND new.claimed_by IS NOT NULL
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'claimed', 'task', new.id,
          json_object('agent', new.claimed_by, 'requirement_id', new.requirement_id));
END;

DROP TRIGGER IF EXISTS trg_task_deleted;
CREATE TRIGGER trg_task_deleted AFTER DELETE ON task
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'deleted', 'task', old.id,
          json_object('title', old.title, 'status', old.status));
END;

DROP TRIGGER IF EXISTS trg_task_touch;
CREATE TRIGGER trg_task_touch AFTER UPDATE ON task
WHEN new.updated_at IS old.updated_at
BEGIN
  UPDATE task SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = new.id;
END;


-- ---- bug ----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_bug_created;
CREATE TRIGGER trg_bug_created AFTER INSERT ON bug
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE(new.found_by,
                   (SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'created', 'bug', new.id,
          json_object('severity', new.severity, 'requirement_id', new.requirement_id));
END;

DROP TRIGGER IF EXISTS trg_bug_moved;
CREATE TRIGGER trg_bug_moved AFTER UPDATE OF status ON bug
WHEN old.status IS NOT new.status
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'moved', 'bug', new.id,
          json_object('from', old.status, 'to', new.status,
                      'severity', new.severity, 'fix_task_id', new.fix_task_id));
END;

DROP TRIGGER IF EXISTS trg_bug_deleted;
CREATE TRIGGER trg_bug_deleted AFTER DELETE ON bug
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'deleted', 'bug', old.id, json_object('title', old.title));
END;

DROP TRIGGER IF EXISTS trg_bug_touch;
CREATE TRIGGER trg_bug_touch AFTER UPDATE ON bug
WHEN new.updated_at IS old.updated_at
BEGIN
  UPDATE bug SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = new.id;
END;


-- ---- review_finding -----------------------------------------------------------------
-- The actor is the REVIEWER, not the ambient session label — a finding's author is the
-- single most important fact about it, and the row already carries it.
DROP TRIGGER IF EXISTS trg_finding_created;
CREATE TRIGGER trg_finding_created AFTER INSERT ON review_finding
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          new.reviewer, 'found', 'task', new.task_id,
          json_object('finding_id', new.id, 'severity', new.severity,
                      'summary', new.summary, 'file', new.file, 'line', new.line));
END;

DROP TRIGGER IF EXISTS trg_finding_dispositioned;
CREATE TRIGGER trg_finding_dispositioned AFTER UPDATE OF disposition ON review_finding
WHEN old.disposition IS NOT new.disposition
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'dispositioned', 'task', new.task_id,
          json_object('finding_id', new.id, 'from', old.disposition,
                      'to', new.disposition, 'fix_task_id', new.fix_task_id));
END;


-- ---- work_log -----------------------------------------------------------------------
-- The actor is the log line's own `agent`. The subject is the TASK, not the log row: a
-- feed reading "logged work_log 47" would be useless.
DROP TRIGGER IF EXISTS trg_worklog_created;
CREATE TRIGGER trg_worklog_created AFTER INSERT ON work_log
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (new.ts, new.agent, 'logged', 'task', new.task_id,
          json_object('entry', new.entry));
END;


-- ---- coverage -----------------------------------------------------------------------
-- `inspected` fires only when the CLOCK moves. Re-saving an area's risk or notes is not
-- an inspection, and letting it look like one would make an area nobody has opened in
-- three months read as fresh.
DROP TRIGGER IF EXISTS trg_coverage_created;
CREATE TRIGGER trg_coverage_created AFTER INSERT ON coverage
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'created', 'coverage', new.id,
          json_object('risk', new.risk, 'spec_path', new.spec_path));
END;

DROP TRIGGER IF EXISTS trg_coverage_inspected;
CREATE TRIGGER trg_coverage_inspected AFTER UPDATE OF last_inspected_at ON coverage
WHEN old.last_inspected_at IS NOT new.last_inspected_at
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'inspected', 'coverage', new.id,
          json_object('from', old.last_inspected_at, 'to', new.last_inspected_at,
                      'risk', new.risk));
END;


-- ---- inspection ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_inspection_created;
CREATE TRIGGER trg_inspection_created AFTER INSERT ON inspection
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'created', 'inspection', new.id,
          json_object('scope', new.scope, 'trigger', new."trigger"));
END;

DROP TRIGGER IF EXISTS trg_inspection_moved;
CREATE TRIGGER trg_inspection_moved AFTER UPDATE OF status ON inspection
WHEN old.status IS NOT new.status
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'moved', 'inspection', new.id,
          json_object('from', old.status, 'to', new.status));
END;


-- ---- doc ----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_doc_created;
CREATE TRIGGER trg_doc_created AFTER INSERT ON doc
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE(NULLIF(new.source, ''),
                   (SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'documented', 'doc', new.slug, json_object('title', new.title));
END;

DROP TRIGGER IF EXISTS trg_doc_updated;
CREATE TRIGGER trg_doc_updated AFTER UPDATE OF body ON doc
WHEN old.body IS NOT new.body
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE(NULLIF(new.source, ''),
                   (SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'documented', 'doc', new.slug, json_object('title', new.title));
END;

DROP TRIGGER IF EXISTS trg_doc_touch;
CREATE TRIGGER trg_doc_touch AFTER UPDATE ON doc
WHEN new.updated_at IS old.updated_at
BEGIN
  UPDATE doc SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE slug = new.slug;
END;

-- A doc's LIFECYCLE is an event too. Retiring a decision — 'current' -> 'superseded', or a
-- proposal declined as 'rejected' — is one of the few things on this board that is pure
-- judgment, and it belongs in the feed beside the work it explains.
DROP TRIGGER IF EXISTS trg_doc_moved;
CREATE TRIGGER trg_doc_moved AFTER UPDATE OF status ON doc
WHEN old.status IS NOT new.status
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'moved', 'doc', new.slug,
          json_object('from', old.status, 'to', new.status, 'kind', new.kind));
END;

-- THE DOCUMENTATION'S OWN HISTORY, and the reason `doc_revision` needs no discipline from
-- anybody. A member can forget to snapshot a page before rewriting it. A member cannot
-- bypass this.
--
-- IT STORES `old.body`, NOT THE NEW ONE. The live text is in `doc`, and the newest revision
-- row is the text that came before it. Reading them the other way round is the one mistake
-- this table invites, which is why the column is commented in both places.
--
-- `UPDATE OF body` plus `WHEN old.body <> new.body` is two guards for one job on purpose:
-- the first keeps it off updates that never touch the body (a status change, a re-tag), and
-- the second keeps it off an update that rewrites the body with identical text. Neither is
-- a change worth a revision row, and a history full of no-ops is a history nobody reads.
--
-- IT CANNOT RECURSE with `trg_doc_touch`. That trigger updates only `updated_at`, which is
-- not `body`, so `UPDATE OF body` does not fire for it — and this trigger writes to a table
-- that has no triggers of its own. Both halves hold even under `PRAGMA recursive_triggers = ON`.
DROP TRIGGER IF EXISTS trg_doc_revised;
CREATE TRIGGER trg_doc_revised AFTER UPDATE OF body ON doc
WHEN old.body <> new.body
BEGIN
  INSERT INTO doc_revision (slug, title, body, kind, status, replaced_at)
  VALUES (old.slug, old.title, old.body, old.kind, old.status,
          strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;


-- ---- knowledge_edge -----------------------------------------------------------------
-- INSTRUMENTED, UNLIKE `graph_edge` AND `task_dependency` — and the difference is worth
-- stating, because the header says structure tables are deliberately silent.
--
-- `graph_edge` is STRUCTURE: it is written once, wholesale, alongside a `graph_node` that
-- is itself instrumented, and dozens of rows land in a breath. A `knowledge_edge` is an
-- ASSERTION somebody made — "this decision supersedes that one", "these two contradict" —
-- and it arrives a few at a time, from a member who is claiming something. When a link
-- appeared, and who claimed it, is exactly the kind of question the feed is for.
--
-- The subject is the edge's FROM end, so a doc's links show up in that doc's own history.
DROP TRIGGER IF EXISTS trg_edge_linked;
CREATE TRIGGER trg_edge_linked AFTER INSERT ON knowledge_edge
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE(NULLIF(new.created_by, ''),
                   (SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'linked', new.from_type, new.from_id,
          json_object('rel', new.rel, 'to_type', new.to_type, 'to_id', new.to_id,
                      'note', new.note));
END;

-- RETRACTING an assertion is as much a decision as making one, and a graph that silently
-- forgets its retractions cannot be audited. This is the only DELETE in the library that
-- leaves a trace, which is fine — deleting a `doc` is meant to be rare, and its revisions
-- survive it by design.
DROP TRIGGER IF EXISTS trg_edge_unlinked;
CREATE TRIGGER trg_edge_unlinked AFTER DELETE ON knowledge_edge
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'unlinked', old.from_type, old.from_id,
          json_object('rel', old.rel, 'to_type', old.to_type, 'to_id', old.to_id));
END;


-- ---- graph_node ---------------------------------------------------------------------
-- Status changes only. See the header for why instantiation is not instrumented.
DROP TRIGGER IF EXISTS trg_node_moved;
CREATE TRIGGER trg_node_moved AFTER UPDATE OF status ON graph_node
WHEN old.status IS NOT new.status
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'node-moved', 'graph_node', new.id,
          json_object('from', old.status, 'to', new.status,
                      'requirement_id', new.requirement_id,
                      'node_key', new.node_key, 'task_id', new.task_id));
END;


-- ---- graph_deviation ----------------------------------------------------------------
-- A deviation is a decision, and the reason column is the whole point of the row, so it
-- travels into the payload where the feed can show it.
DROP TRIGGER IF EXISTS trg_deviation_created;
CREATE TRIGGER trg_deviation_created AFTER INSERT ON graph_deviation
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'deviated', 'requirement', new.requirement_id,
          json_object('kind', new.kind, 'node_key', new.node_key,
                      'reason', new.reason));
END;


-- ---- gate ---------------------------------------------------------------------------
-- A gate decision is the one event a human is guaranteed to be behind, so the decision
-- text rides along. Remember that this records the GATE row changing — the node still has
-- to be moved separately, and nothing here does it for you.
DROP TRIGGER IF EXISTS trg_gate_decided;
CREATE TRIGGER trg_gate_decided AFTER UPDATE OF status ON gate
WHEN old.status IS NOT new.status
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'decided', 'gate', new.node_id,
          json_object('from', old.status, 'to', new.status,
                      'kind', new.kind, 'decision', new.decision));
END;


-- ---- the roster has no triggers ----------------------------------------------------
-- `capability_request` and `agent` are not tables, so recruiting, retiring and requesting
-- a member are not events this database can witness. They are commits to the agent files.
-- THE DROPS ARE LOAD-BEARING: re-applying this file over a board that predates the change
-- is what removes triggers that would otherwise fire against tables the migration drops.
DROP TRIGGER IF EXISTS trg_capreq_created;
DROP TRIGGER IF EXISTS trg_capreq_resolved;
DROP TRIGGER IF EXISTS trg_agent_recruited;
DROP TRIGGER IF EXISTS trg_agent_retired;
DROP TRIGGER IF EXISTS trg_agent_deleted;


-- =====================================================================================
-- END. Re-apply this file any time — it is idempotent, and re-applying is how a rule
-- change reaches a live board.
-- =====================================================================================
