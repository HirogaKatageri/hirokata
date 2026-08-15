-- =====================================================================================
-- guild v6 — THE SCHEMA IS THE TOOL
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
-- ------------------------------------------------------------------------------------
-- WHAT THIS FILE IS
--
-- There is no guild CLI any more. `tursodb` is already a tool that executes SQL, so the
-- guild does not ship a second one. Every member reaches the warehouse the same way —
-- they write SQL — and THIS FILE is the guild's knowledge of what the warehouse contains
-- and what its rules are.
--
-- That only works if the rules live in the database rather than in a wrapper, so:
--
--   CHECK constraints  are the vocabularies. A status outside its enum is REJECTED by the
--                      engine, on every connection, from every member, forever.
--   VIEWS              are the derived rules. The cursor rule, the review gate, node
--                      readiness, the agent matcher, the board, the briefing — each has
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
--   4. "PLAN SLICES TOUCH DISJOINT FILES." `plan_slice.files` is a JSON array and the
--      disjointness is an ASSERTION BY THE ARCHITECT. Nothing checks it.
--   5. "A CAPABILITY MUST BE IN THE VOCABULARY." `v_capability_vocabulary` defines the
--      word list and `v_capability_unknown` reports violations, but a CHECK cannot
--      reference another table, so an unknown capability INSERTS fine and simply matches
--      nobody. Read `v_capability_unknown` when the matcher goes quiet.
--   6. "A GATE IS DECIDED BY A HUMAN." `gate.status` is a column. Anyone can write it.
--   7. THE GRAPH IS NOT ACYCLIC BY CONSTRUCTION. `graph_edge` accepts any pair. A cycle
--      makes `v_ready_nodes` return nothing for the whole loop — a silent stall, not an
--      error. There is no `WITH RECURSIVE` on tursodb to detect one, so this is a review
--      duty, not a check.
--   8. TIMESTAMPS ARE UTC BY CONVENTION. `strftime(…,'now')` in the triggers is UTC.
--      Whatever a member writes by hand is whatever they wrote.
--
-- ------------------------------------------------------------------------------------
-- ENGINE CONSTRAINTS — verified on tursodb 0.7.2, and every one of them cost a round
--
--   * No `WITH RECURSIVE`. Readiness and dependency logic joins DIRECT predecessors only,
--     one hop, and propagates as the work runs. Never write a traversal.
--   * No FTS5. Text search is `LIKE`, with `%` and `_` escaped by the caller.
--   * No lag/lead/ntile/percent_rank/cume_dist. Ranking here is an `ORDER BY` and the
--     rank is the ROW'S POSITION, assigned by the reader — see `v_agent_match`.
--   * STRICT tables accept only INT, INTEGER, REAL, TEXT, BLOB, ANY. Every column below
--     is TEXT or INTEGER. Keep it that way.
--   * WORKING: STRICT, RETURNING, ON CONFLICT DO UPDATE, printf(), plain CTEs, WAL,
--     foreign_keys, JSON functions, CHECK, VIEW, TRIGGER, `UPDATE OF <col>` triggers.
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
-- Likewise, applying this file over a database created by an EARLIER v5 stage does NOT
-- add the CHECKs — `CREATE TABLE IF NOT EXISTS` sees the table and moves on. The new
-- views and triggers land, the constraints do not. A board that wants them rebuilds.
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
SELECT 1, 5, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
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
-- DIRECTION — goal, phase
-- =====================================================================================
-- Vocabulary: todo | in-progress | done. Deliberately the SHORT set. A goal has no
-- `blocked` and no `waived`: those are words about a unit of work, and a goal is a
-- direction. Priority is 1 (highest) to 5 (lowest) everywhere it appears.

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

CREATE TABLE IF NOT EXISTS phase (
  id          TEXT PRIMARY KEY,               -- PHASE-001
  goal_id     TEXT NOT NULL REFERENCES goal(id),
  title       TEXT NOT NULL,
  ordinal     INTEGER NOT NULL,               -- ordering within the goal, 1-based
  status      TEXT NOT NULL DEFAULT 'todo'
              CHECK (status IN ('todo', 'in-progress', 'done')),
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
) STRICT;


-- =====================================================================================
-- WORK — requirement, plan, plan_slice, task, task_dependency
-- =====================================================================================

CREATE TABLE IF NOT EXISTS requirement (
  id          TEXT PRIMARY KEY,               -- REQ-001
  phase_id    TEXT REFERENCES phase(id),      -- nullable: unaffiliated work is legal
  title       TEXT NOT NULL,
  body        TEXT NOT NULL DEFAULT '',       -- the full REQ markdown
  status      TEXT NOT NULL DEFAULT 'todo'
              CHECK (status IN ('todo', 'in-progress', 'done')),
  priority    INTEGER NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS plan (
  id             TEXT PRIMARY KEY,            -- PLAN-001
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  task_id        TEXT REFERENCES task(id),    -- a plan written FOR one ticket
  title          TEXT NOT NULL,
  body           TEXT NOT NULL DEFAULT '',
  status         TEXT NOT NULL DEFAULT 'todo'
                 CHECK (status IN ('todo', 'in-progress', 'done')),
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
) STRICT;

-- A parallelizable unit of a plan. `files` is a JSON array and the DISJOINTNESS OF THOSE
-- FILE SETS ACROSS SLICES IS AN ASSERTION, not a constraint — it is the architect's
-- promise that the slices can run concurrently without stepping on each other. Nothing
-- verifies it. See "what this file cannot enforce", item 4.
CREATE TABLE IF NOT EXISTS plan_slice (
  id        TEXT PRIMARY KEY,                 -- PLAN-001/auth-service
  plan_id   TEXT NOT NULL REFERENCES plan(id),
  slug      TEXT NOT NULL,
  title     TEXT NOT NULL,
  body      TEXT NOT NULL DEFAULT '',
  files     TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(files)),
  UNIQUE (plan_id, slug)
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
--   blocked      NOBODY ON THE ROSTER CAN TAKE THIS. It is not a general "stuck" flag —
--                it means the capability match found nobody. A machine verdict no human
--                has ruled on yet, so it DOES hold the review gate (see `v_task_actionable`).
--   waived       deliberately skipped, by a gate decision. Counts as finished for
--                dependency purposes, exactly like `done` (see `v_task_deps`).
--
-- The asymmetry between `failed` and `blocked` in the review gate is the single most
-- load-bearing judgment in this schema, and it is spelled out in `v_task_actionable`.
CREATE TABLE IF NOT EXISTS task (
  id             TEXT PRIMARY KEY,            -- TASK-001
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  plan_id        TEXT REFERENCES plan(id),
  plan_slice_id  TEXT REFERENCES plan_slice(id),
  plan_slice     TEXT,                        -- the raw slice slug, denormalized
  parallel_group TEXT,                        -- tasks sharing one dispatch together
  node_key       TEXT,                        -- the graph node that produced it
  title          TEXT NOT NULL,
  objective      TEXT NOT NULL DEFAULT '',
  body           TEXT NOT NULL DEFAULT '',
  status         TEXT NOT NULL DEFAULT 'todo'
                 CHECK (status IN ('todo', 'in-progress', 'done',
                                   'failed', 'blocked', 'waived')),
  priority       INTEGER NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
  -- `agent` is the PIN: a member the architect named on the ticket. Optional. When it is
  -- set it wins the match outright (`v_task_top_agent`), and the ticket is never reported
  -- as a roster gap — a pin the roster cannot independently cover is a deviation to
  -- review, not a bounty nobody can take.
  agent          TEXT,
  claimed_by     TEXT REFERENCES agent(name),
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
-- THE ROSTER — agent, agent_capability, task_capability, capability_request
-- =====================================================================================
-- Adding an agent file to `agents/` and INSERTing its name and capability tags here is
-- the entire process of adding a guild member. The matcher (`v_agent_match`) does the
-- rest.

CREATE TABLE IF NOT EXISTS agent (
  name        TEXT PRIMARY KEY,               -- 'developer-svelte'
  model       TEXT NOT NULL DEFAULT 'sonnet',
  description TEXT NOT NULL DEFAULT '',
  active      INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  serial      INTEGER NOT NULL DEFAULT 0 CHECK (serial IN (0, 1))
              -- 1 = never run concurrently with itself (the qa-tester drives one app)
) STRICT;

-- A capability is compared for EQUALITY and never normalized, so the alphabet is narrow
-- on purpose: lowercase letters, digits and '-'. `e2e` and `E2E` would be two
-- capabilities that read as one, and the matcher would quietly stop working. The CHECK
-- below enforces the ALPHABET. The VOCABULARY (which words are legal) is
-- `v_capability_vocabulary`, and it cannot be a CHECK because a CHECK may not read
-- another table — `v_capability_unknown` is how you audit it.
CREATE TABLE IF NOT EXISTS agent_capability (
  agent      TEXT NOT NULL REFERENCES agent(name),
  capability TEXT NOT NULL
             CHECK (length(capability) BETWEEN 1 AND 64
                    AND capability = lower(capability)
                    AND capability GLOB '[a-z]*'
                    AND NOT capability GLOB '*[^a-z0-9-]*'),
  PRIMARY KEY (agent, capability)
) STRICT;

-- `required = 1` decides ELIGIBILITY (an agent must cover every one of them).
-- `required = 0` — "preferred" — decides RANK only. A preferred capability never
-- excludes anybody. That distinction is the whole of the matcher.
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

-- A capability the architect needs and the roster does not have. Raised at plan time,
-- resolved by the guild master creating a new member. Filing one is ALSO what legitimizes
-- a new WORD: `v_capability_vocabulary` unions in every non-declined request, so the row
-- that admits `rust` into the guild's language outlives the recruitment.
--   open      filed, nobody has acted
--   created   the member now exists
--   declined  refused — and the word stays out of the vocabulary
CREATE TABLE IF NOT EXISTS capability_request (
  id             INTEGER PRIMARY KEY,
  capability     TEXT NOT NULL,
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  rationale      TEXT NOT NULL,               -- why existing members cannot cover it
  proposed_agent TEXT NOT NULL,               -- suggested name, e.g. 'developer-rust'
  proposed_spec  TEXT NOT NULL DEFAULT '',    -- draft role/tools/model
  status         TEXT NOT NULL DEFAULT 'open'
                 CHECK (status IN ('open', 'created', 'declined')),
  created_at     TEXT NOT NULL
) STRICT;


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
-- MAINTENANCE — coverage, inspection, inspection_coverage, doc
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

-- The library. Long-lived knowledge the guild looked up once and should not look up
-- again. Search it with LIKE — there is no FTS5.
CREATE TABLE IF NOT EXISTS doc (
  slug       TEXT PRIMARY KEY,                -- 'sveltekit-form-actions'
  title      TEXT NOT NULL,
  body       TEXT NOT NULL,
  source     TEXT NOT NULL DEFAULT '',        -- who/what produced it
  updated_at TEXT NOT NULL
) STRICT;


-- =====================================================================================
-- HISTORY — event
-- =====================================================================================
-- WRITTEN BY TRIGGERS. You do not normally INSERT here by hand, and you never UPDATE or
-- DELETE: this is the guild's memory, and a memory you can edit is not one.
--
-- `subject_type` IS THE SUBJECT'S TABLE NAME — 'task', 'requirement', 'coverage'. That is
-- what lets `v_recent_activity` resolve a title for it. `verb` is intentionally NOT
-- CHECKed: new machinery invents new verbs, and an event that cannot be written is worse
-- than one whose verb you have not seen before. The verbs the triggers below emit are:
--
--   created  moved  deleted  claimed  logged  found  dispositioned  inspected
--   documented  decided  node-moved  requested  resolved  recruited  retired  deviated
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
CREATE INDEX IF NOT EXISTS phase_by_goal    ON phase(goal_id, ordinal);
CREATE INDEX IF NOT EXISTS slice_by_plan    ON plan_slice(plan_id);
-- Both capability tables are keyed (owner, capability), so "what does this agent/task
-- declare" is already a seek. The matcher asks the OTHER question — "who can cover
-- `rust`" — which is a scan on the second key column. These cover that direction.
CREATE INDEX IF NOT EXISTS agent_cap_by_cap ON agent_capability(capability);
CREATE INDEX IF NOT EXISTS task_cap_by_cap  ON task_capability(capability, required);
-- Dependency and edge lookups run in BOTH directions in the readiness views.
CREATE INDEX IF NOT EXISTS dep_by_pred      ON task_dependency(depends_on);
CREATE INDEX IF NOT EXISTS edge_by_to       ON graph_edge(to_node);


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
--   the matcher  v_agent_eligible · v_agent_match · v_task_top_agent
--   the bounties v_open_bounties · v_blocked_tasks
--   the graph    v_ready_nodes · v_gates_pending
--   the board    v_board · v_requirement_progress · v_goal_progress
--   the briefing v_brief · v_in_flight · v_failed_tasks · v_open_findings ·
--                v_open_bugs · v_recent_activity
--   quality      v_coverage_due
--   the roster   v_capability_vocabulary · v_capability_unknown · v_roster_gaps


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
-- certifies a requirement whose implementation slice never ran is a FALSE GREEN, and a
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
-- that is waiting on a predecessor, or one nobody on the roster can take.
--
-- `v_open_bounties` IS THE DISPATCH-READY SET. It is this rule PLUS dependencies PLUS a
-- matched member. Use the cursor to answer "where was I", and the bounty board to answer
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
-- dispatched — that is what blocked means — and a parallel group's slices touch disjoint
-- files by construction, so the members that can run have no reason to wait. Holding the
-- whole batch would turn one roster gap into a stalled group while telling the reader
-- nothing new. The review gate is where the blocked slice is accounted for.
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
-- v_agent_eligible — WHO CAN TAKE THIS TICKET (the capability path)
-- ------------------------------------------------------------------------------------
-- ELIGIBILITY IS A SUPERSET TEST: the agent's declared capabilities must be a superset of
-- the task's REQUIRED set. Written as "there is no required capability this agent lacks",
-- which is the universal quantifier as a doubled NOT EXISTS — a direct-row join, no
-- aggregate, no traversal.
--
-- THE SWITCH INTO THIS VIEW IS THE PRESENCE OF ANY `task_capability` ROW, required or
-- preferred — not the emptiness of the required set. A task with an EMPTY required set is
-- vacuously covered by every agent in the roster and would match all of them, which is
-- the wrong answer for a ticket that simply never declared anything. So a ticket with no
-- capability rows at all does not appear here at all, and falls to its pinned `agent`
-- instead (`v_agent_match`, branch 0).
--
-- Retired agents (`active = 0`) are excluded. Retiring is how a member leaves the roster
-- without deleting the record that explains old dispatches.
--
-- The three ranking numbers travel with the row:
--   preferred_covered  how many of the task's PREFERRED capabilities this agent has.
--                      HIGHER is better.
--   preferred_total    the denominator, so `2/3` is readable. Not a ranking key.
--   capabilities       the agent's TOTAL capability count. LOWER IS BETTER — a specialist
--                      beats a generalist. That is why the sort is ASC on a number that
--                      looks like it should be DESC.
DROP VIEW IF EXISTS v_agent_eligible;
CREATE VIEW v_agent_eligible AS
SELECT t.id   AS task_id,
       a.name AS agent,
       (SELECT COUNT(*) FROM task_capability tcp
         WHERE tcp.task_id = t.id AND tcp.required = 0
           AND EXISTS (SELECT 1 FROM agent_capability acp
                        WHERE acp.agent = a.name
                          AND acp.capability = tcp.capability))       AS preferred_covered,
       (SELECT COUNT(*) FROM task_capability tcq
         WHERE tcq.task_id = t.id AND tcq.required = 0)               AS preferred_total,
       (SELECT COUNT(*) FROM agent_capability act
         WHERE act.agent = a.name)                                    AS capabilities,
       a.serial                                                       AS serial,
       a.model                                                        AS model
  FROM task t
  JOIN agent a ON a.active = 1
 WHERE EXISTS (SELECT 1 FROM task_capability tc0 WHERE tc0.task_id = t.id)
   AND NOT EXISTS (SELECT 1 FROM task_capability tcr
                    WHERE tcr.task_id = t.id AND tcr.required = 1
                      AND NOT EXISTS (SELECT 1 FROM agent_capability acr
                                       WHERE acr.agent = a.name
                                         AND acr.capability = tcr.capability));


-- ------------------------------------------------------------------------------------
-- v_agent_match — THE MATCHER. Every candidate for every task, already ranked.
-- ------------------------------------------------------------------------------------
--   SELECT * FROM v_agent_match WHERE task_id = 'TASK-014'
--
-- THE RANK IS THE ROW'S POSITION. There is no rank column and there is no row_number():
-- the view carries the ORDER BY, and the first row for a task is rank 1. Restate the
-- ORDER BY yourself if you wrap this view in another query — a view's internal ordering
-- is not a contract SQLite promises to preserve through a join.
--
--   ORDER BY task_id, branch, preferred_covered DESC, capabilities ASC, agent ASC
--
-- The third key, `agent ASC`, is not a tiebreak of convenience. It is what makes the
-- answer DETERMINISTIC, which is the property that lets the orchestrator dispatch rank 1
-- without exercising judgment.
--
-- THREE SOURCES, AND THEY ARE NOT THREE FALLBACKS:
--
--   pin         the ticket names an agent AND declares capabilities. The pin ranks FIRST
--               and runs. The eligible members follow it, so the deviation is VISIBLE
--               rather than merely obeyed.
--   ticket      the ticket names an agent and declares NO capabilities. That one agent is
--               the only candidate, and the roster is not consulted at all — which is why
--               this works on a board that has never synced its agent files.
--   capability  §5.2 in full. Only reached when the ticket declares capabilities.
--
-- WHAT IS ABSENT IS THE POINT: a ticket that DECLARED capabilities and whose named agent
-- covers none of them still ranks that agent first (it is a pin), but a ticket with
-- capabilities and NO agent that nothing covers produces NO ROWS. That is a roster gap,
-- and it is the entire reason for declaring capabilities. `v_blocked_tasks` names it.
DROP VIEW IF EXISTS v_agent_match;
CREATE VIEW v_agent_match AS
-- branch 0 — the pin, and the no-capabilities ticket fallback
SELECT t.id   AS task_id,
       t.agent AS agent,
       CASE WHEN EXISTS (SELECT 1 FROM task_capability tc0 WHERE tc0.task_id = t.id)
            THEN 'pin' ELSE 'ticket' END                              AS source,
       0                                                              AS branch,
       (SELECT COUNT(*) FROM task_capability tcp
         WHERE tcp.task_id = t.id AND tcp.required = 0
           AND EXISTS (SELECT 1 FROM agent_capability acp
                        WHERE acp.agent = t.agent
                          AND acp.capability = tcp.capability))       AS preferred_covered,
       (SELECT COUNT(*) FROM task_capability tcq
         WHERE tcq.task_id = t.id AND tcq.required = 0)               AS preferred_total,
       (SELECT COUNT(*) FROM agent_capability act
         WHERE act.agent = t.agent)                                   AS capabilities,
       COALESCE((SELECT a2.serial FROM agent a2 WHERE a2.name = t.agent), 0) AS serial
  FROM task t
 WHERE COALESCE(t.agent, '') <> ''
UNION ALL
-- branch 1 — the capability match, minus the pinned member so nobody appears twice
SELECT e.task_id, e.agent, 'capability', 1,
       e.preferred_covered, e.preferred_total, e.capabilities, e.serial
  FROM v_agent_eligible e
 WHERE e.agent <> COALESCE((SELECT tp.agent FROM task tp WHERE tp.id = e.task_id), '')
 ORDER BY task_id, branch, preferred_covered DESC, capabilities ASC, agent ASC;


-- ------------------------------------------------------------------------------------
-- v_task_top_agent — rank 1, as one row per task. '' when nobody is eligible.
-- ------------------------------------------------------------------------------------
-- This IS "what `v_agent_match` would say first", and the branch order is identical on
-- purpose: if the two disagreed, one view would name a member and the other would name
-- somebody else for the same ticket.
DROP VIEW IF EXISTS v_task_top_agent;
CREATE VIEW v_task_top_agent AS
SELECT t.id AS task_id,
       CASE
         WHEN COALESCE(t.agent, '') <> '' THEN t.agent
         WHEN EXISTS (SELECT 1 FROM task_capability tc0 WHERE tc0.task_id = t.id)
           THEN COALESCE((SELECT e.agent FROM v_agent_eligible e
                           WHERE e.task_id = t.id
                           ORDER BY e.preferred_covered DESC,
                                    e.capabilities ASC,
                                    e.agent ASC
                           LIMIT 1), '')
         ELSE ''
       END AS agent
  FROM task t;


-- ------------------------------------------------------------------------------------
-- v_open_bounties — WORK THAT CAN BE DISPATCHED RIGHT NOW, with its matched member
-- ------------------------------------------------------------------------------------
-- The cursor rule PLUS dependencies PLUS somebody to give it to. Three conditions:
--
--   1. actionable          `v_task_actionable` — todo, past the review gate
--   2. no unfinished deps  `v_task_deps` is empty for it
--   3. somebody can take it — a pin, or an eligible member on the capability path
--
-- Ordered by priority then id, which is the order a dispatcher should walk it. Note that
-- `v_next_task` deliberately does NOT consider priority (it takes the lowest id) — the
-- cursor resumes and claims in a fixed order, while the bounty board is a market. Both
-- behaviors are intended and they are different questions.
--
-- THIS VIEW MUTATES NOTHING. In particular a ticket with nobody eligible does not become
-- `blocked` by being read — it just appears in `v_blocked_tasks` with the reason instead.
-- Moving it is a decision, and decisions are writes somebody makes on purpose.
DROP VIEW IF EXISTS v_open_bounties;
CREATE VIEW v_open_bounties AS
SELECT t.id                                   AS id,
       t.requirement_id                       AS requirement_id,
       t.priority                             AS priority,
       COALESCE(NULLIF(m.agent, ''), '-')     AS agent,
       w.who                                  AS who,
       COALESCE(t.parallel_group, '')         AS parallel_group,
       t.title                                AS title
  FROM v_task_actionable t
  JOIN v_task_top_agent m ON m.task_id = t.id
  JOIN v_task_who       w ON w.task_id = t.id
 WHERE NOT EXISTS (SELECT 1 FROM v_task_deps d WHERE d.task_id = t.id)
   AND ( COALESCE(t.agent, '') <> ''
         OR EXISTS (SELECT 1 FROM v_agent_eligible e WHERE e.task_id = t.id) )
 ORDER BY t.priority, t.id;


-- ------------------------------------------------------------------------------------
-- v_blocked_tasks — EVERYTHING OPEN THAT CANNOT MOVE, AND WHY
-- ------------------------------------------------------------------------------------
-- The companion to `v_open_bounties`. Three ways in, and `reason` is one blank-free token
-- so it survives a whitespace-separated column:
--
--   status-blocked        the task is explicitly `blocked` — somebody already ruled
--   deps:TASK-009,…       waiting on unfinished direct predecessors
--   no-eligible-agent:rust,embedded    declared capabilities nobody covers — A ROSTER GAP
--   no-eligible-agent:unassigned       no agent, no capabilities, nobody to give it to
--
-- Order matters in that CASE. An explicitly blocked task says so even when it ALSO has
-- unfinished dependencies, because the status was a human's decision and the dependency
-- is a fact about the graph.
--
-- `awk '$0 ~ /no-eligible-agent/'` over this view is the roster-gap query, and the answer
-- names the capability that would fix it — which is to say, it names the agent file
-- somebody needs to write.
DROP VIEW IF EXISTS v_blocked_tasks;
CREATE VIEW v_blocked_tasks AS
SELECT t.id                                   AS id,
       t.requirement_id                       AS requirement_id,
       t.status                               AS status,
       COALESCE(NULLIF(m.agent, ''), '-')     AS agent,
       w.who                                  AS who,
       CASE
         WHEN t.status = 'blocked' THEN 'status-blocked'
         WHEN EXISTS (SELECT 1 FROM v_task_deps d WHERE d.task_id = t.id)
           THEN 'deps:' || COALESCE((SELECT b.blockers FROM v_task_blockers b
                                      WHERE b.task_id = t.id), '')
         WHEN EXISTS (SELECT 1 FROM task_capability tc WHERE tc.task_id = t.id)
           THEN 'no-eligible-agent:'
                || COALESCE((SELECT group_concat(c, ',')
                               FROM (SELECT tcl.capability AS c FROM task_capability tcl
                                      WHERE tcl.task_id = t.id AND tcl.required = 1
                                      ORDER BY tcl.capability)), '')
         ELSE 'no-eligible-agent:unassigned'
       END                                    AS reason,
       t.title                                AS title
  FROM task t
  JOIN v_task_top_agent m ON m.task_id = t.id
  JOIN v_task_who       w ON w.task_id = t.id
 WHERE t.status = 'blocked'
    OR ( t.status = 'todo'
         AND EXISTS (SELECT 1 FROM v_task_deps d WHERE d.task_id = t.id) )
    OR ( t.id IN (SELECT a.id FROM v_task_actionable a)
         AND NOT EXISTS (SELECT 1 FROM v_task_deps d WHERE d.task_id = t.id)
         AND COALESCE(t.agent, '') = ''
         AND NOT EXISTS (SELECT 1 FROM v_agent_eligible e WHERE e.task_id = t.id) )
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
-- v_board — THE LIVE BOARD
-- ------------------------------------------------------------------------------------
--   SELECT section, id, who, title FROM v_board
--
-- One row per task, tagged with the section it belongs in and the order those sections
-- print. `Blocked` sits DIRECTLY UNDER `In Progress` rather than down with `Failed`,
-- because a roster gap should be loud and the bottom of a long board is not loud — and it
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
-- closing a requirement: a requirement completed over a blocked task ships a slice nobody
-- ever attempted, and nothing in this schema will stop you (see "what this file cannot
-- enforce", item 2). `failed` is excluded from `tasks_open` because a human has already
-- ruled on it.
--
-- Sorted todo, then in-progress, then done — unfinished direction first.
DROP VIEW IF EXISTS v_requirement_progress;
CREATE VIEW v_requirement_progress AS
SELECT r.id        AS id,
       r.phase_id  AS phase_id,
       r.status    AS status,
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
 GROUP BY r.id, r.phase_id, r.status, r.priority, r.title
 ORDER BY CASE r.status WHEN 'todo' THEN 1 WHEN 'in-progress' THEN 2
                        WHEN 'done' THEN 3 ELSE 4 END, r.id;


-- ------------------------------------------------------------------------------------
-- v_goal_progress — the open goals, each with the phase it is currently on
-- ------------------------------------------------------------------------------------
-- "Current phase" is the lowest-ordinal phase that is not yet done. NULL means every
-- phase is done and nobody closed the goal.
DROP VIEW IF EXISTS v_goal_progress;
CREATE VIEW v_goal_progress AS
SELECT g.id       AS id,
       g.status   AS status,
       g.priority AS priority,
       (SELECT p.id    FROM phase p WHERE p.goal_id = g.id AND p.status <> 'done'
         ORDER BY p.ordinal, p.id LIMIT 1)          AS current_phase_id,
       (SELECT p.title FROM phase p WHERE p.goal_id = g.id AND p.status <> 'done'
         ORDER BY p.ordinal, p.id LIMIT 1)          AS current_phase_title,
       (SELECT COUNT(*) FROM requirement r JOIN phase p ON p.id = r.phase_id
         WHERE p.goal_id = g.id)                    AS requirements_total,
       (SELECT COUNT(*) FROM requirement r JOIN phase p ON p.id = r.phase_id
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
         (SELECT s.title FROM phase       s WHERE e.subject_type = 'phase'       AND s.id   = e.subject_id),
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
-- v_capability_vocabulary — THE WORDS THIS GUILD KNOWS
-- ------------------------------------------------------------------------------------
-- The seed list, plus every capability legitimized by a `capability_request` that was not
-- declined. Kept SMALL on purpose: a sprawling vocabulary makes matching mushy, and the
-- concrete failure is two agents tagged `e2e` and `end-to-end` and a matcher that quietly
-- stops working.
--
-- THE ONLY DOOR INTO THIS LIST IS A `capability_request` ROW. It is deliberately NOT
-- sourced from `agent_capability` — that would be self-approving, and one typo'd tag would
-- become legal forever the moment somebody synced it.
--
-- This cannot be a CHECK: a CHECK may not read another table. So it is a view, and
-- `v_capability_unknown` is the audit. Item 5 of "what this file cannot enforce".
DROP VIEW IF EXISTS v_capability_vocabulary;
CREATE VIEW v_capability_vocabulary AS
SELECT 'implement'      AS capability
UNION SELECT 'frontend'
UNION SELECT 'backend'
UNION SELECT 'svelte'
UNION SELECT 'sveltekit'
UNION SELECT 'test-planning'
UNION SELECT 'test-authoring'
UNION SELECT 'e2e'
UNION SELECT 'review'
UNION SELECT 'security'
UNION SELECT 'architecture'
UNION SELECT 'business-logic'
UNION SELECT 'edge-case'
UNION SELECT 'research'
UNION SELECT 'qa-planning'
UNION SELECT 'qa-execution'
UNION SELECT 'requirements'
UNION SELECT capability FROM capability_request WHERE status <> 'declined';


-- ------------------------------------------------------------------------------------
-- v_capability_unknown — tags outside the vocabulary
-- ------------------------------------------------------------------------------------
-- An unknown capability does not fail. It matches nobody, silently, forever. This is the
-- view that makes it speak: run it whenever the matcher goes unexpectedly quiet.
--
-- An unknown tag on an AGENT is the worse of the two — the agent declares work it will
-- never be offered. An unknown tag on a TASK is loud within one dispatch, because the
-- ticket shows up in `v_blocked_tasks` as a roster gap naming the word.
DROP VIEW IF EXISTS v_capability_unknown;
CREATE VIEW v_capability_unknown AS
SELECT 'agent' AS side, ac.agent AS owner, ac.capability AS capability
  FROM agent_capability ac
 WHERE ac.capability NOT IN (SELECT capability FROM v_capability_vocabulary)
UNION ALL
SELECT 'task', tc.task_id, tc.capability
  FROM task_capability tc
 WHERE tc.capability NOT IN (SELECT capability FROM v_capability_vocabulary)
 ORDER BY side, owner, capability;


-- ------------------------------------------------------------------------------------
-- v_roster_gaps — capability requests nobody has acted on
-- ------------------------------------------------------------------------------------
-- `covered_by` counts active members who already have the capability. A non-zero count on
-- an OPEN request means the gap was filled and the request was never closed — resolve it
-- to `created` so the board stops asking.
DROP VIEW IF EXISTS v_roster_gaps;
CREATE VIEW v_roster_gaps AS
SELECT q.id             AS id,
       q.capability     AS capability,
       q.requirement_id AS requirement_id,
       q.proposed_agent AS proposed_agent,
       q.created_at     AS created_at,
       (SELECT COUNT(*) FROM agent_capability ac
          JOIN agent a ON a.name = ac.agent
         WHERE a.active = 1 AND ac.capability = q.capability) AS covered_by,
       q.rationale      AS rationale
  FROM capability_request q
 WHERE q.status = 'open'
 ORDER BY q.id;


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
UNION ALL SELECT 16, 'bugs_open',           CAST((SELECT COUNT(*) FROM v_open_bugs) AS TEXT)
UNION ALL SELECT 17, 'findings_open',       CAST((SELECT COUNT(*) FROM v_open_findings) AS TEXT)
UNION ALL SELECT 18, 'coverage_due',        CAST((SELECT COUNT(*) FROM v_coverage_due) AS TEXT)
UNION ALL SELECT 19, 'roster_gaps',         CAST((SELECT COUNT(*) FROM v_roster_gaps) AS TEXT)
UNION ALL SELECT 20, 'capability_unknown',  CAST((SELECT COUNT(*) FROM v_capability_unknown) AS TEXT)
UNION ALL SELECT 21, 'nodes_ready',         CAST((SELECT COUNT(*) FROM v_ready_nodes WHERE kind = 'work') AS TEXT)
UNION ALL SELECT 22, 'gates_pending',       CAST((SELECT COUNT(*) FROM v_gates_pending) AS TEXT)
UNION ALL SELECT 23, 'events_since_checkin',
  CAST((SELECT COUNT(*) FROM event
         WHERE ts >= COALESCE(NULLIF((SELECT value FROM guild_state WHERE key = 'last-checkin'), 'null'), '')) AS TEXT)
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
--   * `agent_capability` / `task_capability` — a roster sync deletes and reinserts every
--     row each run, so instrumenting them would bury the feed under churn that says
--     nothing. The `agent` row itself is instrumented instead.
--   * `graph_node` INSERTS — instantiating one requirement's graph writes dozens of nodes
--     in a breath. Only node STATUS CHANGES are recorded, which is the part that means
--     something moved.
--   * `graph_edge`, `task_dependency`, `plan_slice`, `inspection_coverage` — structure,
--     written once at creation time alongside a parent that IS instrumented.
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


-- ---- phase --------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_phase_created;
CREATE TRIGGER trg_phase_created AFTER INSERT ON phase
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'created', 'phase', new.id,
          json_object('goal_id', new.goal_id, 'ordinal', new.ordinal));
END;

DROP TRIGGER IF EXISTS trg_phase_moved;
CREATE TRIGGER trg_phase_moved AFTER UPDATE OF status ON phase
WHEN old.status IS NOT new.status
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'moved', 'phase', new.id,
          json_object('from', old.status, 'to', new.status));
END;

DROP TRIGGER IF EXISTS trg_phase_deleted;
CREATE TRIGGER trg_phase_deleted AFTER DELETE ON phase
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'deleted', 'phase', old.id, json_object('title', old.title));
END;

DROP TRIGGER IF EXISTS trg_phase_touch;
CREATE TRIGGER trg_phase_touch AFTER UPDATE ON phase
WHEN new.updated_at IS old.updated_at
BEGIN
  UPDATE phase SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = new.id;
END;


-- ---- requirement --------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_requirement_created;
CREATE TRIGGER trg_requirement_created AFTER INSERT ON requirement
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'created', 'requirement', new.id,
          json_object('phase_id', new.phase_id, 'priority', new.priority));
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


-- ---- capability_request -------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_capreq_created;
CREATE TRIGGER trg_capreq_created AFTER INSERT ON capability_request
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'requested', 'capability_request', CAST(new.id AS TEXT),
          json_object('capability', new.capability,
                      'requirement_id', new.requirement_id,
                      'proposed_agent', new.proposed_agent));
END;

DROP TRIGGER IF EXISTS trg_capreq_resolved;
CREATE TRIGGER trg_capreq_resolved AFTER UPDATE OF status ON capability_request
WHEN old.status IS NOT new.status
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'resolved', 'capability_request', CAST(new.id AS TEXT),
          json_object('from', old.status, 'to', new.status,
                      'capability', new.capability));
END;


-- ---- agent --------------------------------------------------------------------------
-- Recruiting and retiring a member are rare and consequential, so both are recorded.
-- Capability rows are not — see the header.
DROP TRIGGER IF EXISTS trg_agent_recruited;
CREATE TRIGGER trg_agent_recruited AFTER INSERT ON agent
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'recruited', 'agent', new.name,
          json_object('model', new.model, 'serial', new.serial));
END;

DROP TRIGGER IF EXISTS trg_agent_retired;
CREATE TRIGGER trg_agent_retired AFTER UPDATE OF active ON agent
WHEN old.active IS NOT new.active
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          CASE WHEN new.active = 0 THEN 'retired' ELSE 'recruited' END,
          'agent', new.name,
          json_object('from', old.active, 'to', new.active));
END;

DROP TRIGGER IF EXISTS trg_agent_deleted;
CREATE TRIGGER trg_agent_deleted AFTER DELETE ON agent
BEGIN
  INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
  VALUES (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
          COALESCE((SELECT value FROM guild_state WHERE key = 'actor'), 'orchestrator'),
          'retired', 'agent', old.name, json_object('deleted', 1));
END;


-- =====================================================================================
-- END. Re-apply this file any time — it is idempotent, and re-applying is how a rule
-- change reaches a live board.
-- =====================================================================================
