-- guild v5 — database schema
--
-- Applied by `guild init` (and by `guild rebuild` against a fresh database) via the
-- driver in lib/db.sh. Every statement is IDEMPOTENT: re-applying this file over an
-- existing v5 database is a no-op, so `guild init` is safe to run repeatedly.
--
-- PORTABILITY (design doc §3.0) — this file must parse and run on BOTH engines:
--   * TursoDB  (Rust rewrite) — local mode, `tursodb .guild/guild.db`
--   * libSQL   (SQLite fork)  — cloud mode, `turso db shell "$TURSO_DATABASE_URL"`
-- Therefore: STRICT tables, RETURNING, WAL, PRAGMA foreign_keys and JSON functions are
-- fair game; FTS5, WITH RECURSIVE, generated columns and the lag/lead/ntile/
-- percent_rank/cume_dist window functions are NOT. Readiness and dependency queries
-- must join on DIRECT predecessors, never recurse.
--
-- STRICT tables accept only INT, INTEGER, REAL, TEXT, BLOB and ANY column types.
-- Every column below is TEXT or INTEGER. Keep it that way.
--
-- Tables the CLI does not use yet (goal, phase, capability_request, coverage,
-- inspection, inspection_coverage, bug, doc, graph_*, gate, event, agent_*, ...) are
-- created now so later stages need no migration.

-- ---------- pragmas ----------
-- journal_mode is persisted in the database header; busy_timeout and foreign_keys are
-- PER-CONNECTION and must also be re-issued by the driver on every invocation.
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = ON;

-- ---------- schema version ----------
-- Single row, id = 1. Later stages read `version` to decide what to migrate.
CREATE TABLE IF NOT EXISTS schema_version (
  id         INTEGER PRIMARY KEY,      -- always 1
  version    INTEGER NOT NULL,
  applied_at TEXT
) STRICT;

INSERT INTO schema_version (id, version)
SELECT 1, 5
WHERE NOT EXISTS (SELECT 1 FROM schema_version WHERE id = 1);

-- ---------- guild state ----------
-- Key/value replacement for v4's `.guild/state.yaml`. Today it holds exactly one key,
-- `last-checkin`, which `guild board` prints and `guild init [DATE]` sets. Seeded with
-- the literal string 'null' to match v4's default rendering.
CREATE TABLE IF NOT EXISTS guild_state (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL DEFAULT ''
) STRICT;

INSERT INTO guild_state (key, value)
SELECT 'last-checkin', 'null'
WHERE NOT EXISTS (SELECT 1 FROM guild_state WHERE key = 'last-checkin');

-- ---------- direction ----------
CREATE TABLE IF NOT EXISTS goal (
  id          TEXT PRIMARY KEY,           -- GOAL-001
  title       TEXT NOT NULL,
  body        TEXT NOT NULL DEFAULT '',
  status      TEXT NOT NULL DEFAULT 'todo',
  priority    INTEGER NOT NULL DEFAULT 3, -- 1 highest .. 5 lowest
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS phase (
  id          TEXT PRIMARY KEY,           -- PHASE-001
  goal_id     TEXT NOT NULL REFERENCES goal(id),
  title       TEXT NOT NULL,
  ordinal     INTEGER NOT NULL,
  status      TEXT NOT NULL DEFAULT 'todo',
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
) STRICT;

-- ---------- work ----------
CREATE TABLE IF NOT EXISTS requirement (
  id          TEXT PRIMARY KEY,           -- REQ-001
  phase_id    TEXT REFERENCES phase(id),  -- nullable: unaffiliated work is legal
  title       TEXT NOT NULL,
  body        TEXT NOT NULL DEFAULT '',   -- the full REQ markdown
  status      TEXT NOT NULL DEFAULT 'todo',
  priority    INTEGER NOT NULL DEFAULT 3,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS plan (
  id             TEXT PRIMARY KEY,        -- PLAN-001
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  task_id        TEXT REFERENCES task(id),-- v4 parity: `new plan --task TASK-NNN`
  title          TEXT NOT NULL,
  body           TEXT NOT NULL DEFAULT '',
  status         TEXT NOT NULL DEFAULT 'todo',
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS plan_slice (
  id        TEXT PRIMARY KEY,             -- PLAN-001/auth-service
  plan_id   TEXT NOT NULL REFERENCES plan(id),
  slug      TEXT NOT NULL,
  title     TEXT NOT NULL,
  body      TEXT NOT NULL DEFAULT '',
  files     TEXT NOT NULL DEFAULT '[]',   -- JSON array: the disjoint-file assertion
  UNIQUE (plan_id, slug)
) STRICT;

CREATE TABLE IF NOT EXISTS task (
  id             TEXT PRIMARY KEY,        -- TASK-001
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  plan_id        TEXT REFERENCES plan(id),-- v4 parity: `new task --plan PLAN-NNN`
  plan_slice_id  TEXT REFERENCES plan_slice(id),
  plan_slice     TEXT,                    -- v4 parity: raw `--plan-slice` slug
  parallel_group TEXT,                    -- v4 parity: drives `guild batch`
  node_key       TEXT,                    -- the graph node that produced it
  title          TEXT NOT NULL,
  objective      TEXT NOT NULL DEFAULT '',
  body           TEXT NOT NULL DEFAULT '',
  status         TEXT NOT NULL DEFAULT 'todo',
                 -- todo | in-progress | done | failed | blocked | waived
  priority       INTEGER NOT NULL DEFAULT 3,
  agent          TEXT,                    -- v4 parity: `new task --agent A` (free text)
  claimed_by     TEXT REFERENCES agent(name),
  claimed_at     TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS task_dependency (
  task_id    TEXT NOT NULL REFERENCES task(id),
  depends_on TEXT NOT NULL REFERENCES task(id),
  PRIMARY KEY (task_id, depends_on)
) STRICT;

-- ---------- the roster ----------
CREATE TABLE IF NOT EXISTS agent (
  name        TEXT PRIMARY KEY,           -- 'developer-svelte'
  model       TEXT NOT NULL DEFAULT 'sonnet',
  description TEXT NOT NULL DEFAULT '',
  active      INTEGER NOT NULL DEFAULT 1,
  serial      INTEGER NOT NULL DEFAULT 0  -- 1 = never run concurrently (qa-tester)
) STRICT;

CREATE TABLE IF NOT EXISTS agent_capability (
  agent      TEXT NOT NULL REFERENCES agent(name),
  capability TEXT NOT NULL,
  PRIMARY KEY (agent, capability)
) STRICT;

CREATE TABLE IF NOT EXISTS task_capability (
  task_id    TEXT NOT NULL REFERENCES task(id),
  capability TEXT NOT NULL,
  required   INTEGER NOT NULL DEFAULT 1,  -- 1 = required, 0 = preferred
  PRIMARY KEY (task_id, capability)
) STRICT;

-- A capability the architect needs but the roster does not have. Raised at plan time,
-- resolved by the guild master creating a new member. See §5.4.
CREATE TABLE IF NOT EXISTS capability_request (
  id             INTEGER PRIMARY KEY,
  capability     TEXT NOT NULL,
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  rationale      TEXT NOT NULL,            -- why existing members cannot cover it
  proposed_agent TEXT NOT NULL,            -- suggested name, e.g. 'developer-rust'
  proposed_spec  TEXT NOT NULL DEFAULT '', -- draft role/tools/model for the new agent
  status         TEXT NOT NULL DEFAULT 'open',  -- open | created | declined
  created_at     TEXT NOT NULL
) STRICT;

-- ---------- execution graph ----------
CREATE TABLE IF NOT EXISTS graph_node (
  id             TEXT PRIMARY KEY,        -- REQ-001/implement.auth-service
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  node_key       TEXT NOT NULL,           -- 'implement', 'review', 'gate-plan'
  kind           TEXT NOT NULL,           -- 'work' | 'gate'
  task_id        TEXT REFERENCES task(id),
  parallel_group TEXT,
  status         TEXT NOT NULL DEFAULT 'pending',
                 -- pending | ready | running | done | failed | skipped
  UNIQUE (requirement_id, node_key, task_id)
) STRICT;

CREATE TABLE IF NOT EXISTS graph_edge (
  from_node TEXT NOT NULL REFERENCES graph_node(id),
  to_node   TEXT NOT NULL REFERENCES graph_node(id),
  PRIMARY KEY (from_node, to_node)
) STRICT;

CREATE TABLE IF NOT EXISTS graph_deviation (
  id             INTEGER PRIMARY KEY,
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  kind           TEXT NOT NULL,           -- add-node | drop-node | reshape | add-gate
  node_key       TEXT NOT NULL,
  reason         TEXT NOT NULL,           -- never empty; enforced by `guild graph validate`
  created_at     TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS gate (
  node_id     TEXT PRIMARY KEY REFERENCES graph_node(id),
  prompt      TEXT NOT NULL,
  kind        TEXT NOT NULL DEFAULT 'approve',  -- approve | select-findings
  status      TEXT NOT NULL DEFAULT 'pending',  -- pending | approved | rejected
  decision    TEXT,                             -- free text / JSON of selections
  decided_at  TEXT
) STRICT;

-- ---------- records ----------
CREATE TABLE IF NOT EXISTS work_log (
  id         INTEGER PRIMARY KEY,
  task_id    TEXT NOT NULL REFERENCES task(id),
  ts         TEXT NOT NULL,
  agent      TEXT NOT NULL,
  entry      TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS review_finding (
  id          INTEGER PRIMARY KEY,
  task_id     TEXT NOT NULL REFERENCES task(id),
  reviewer    TEXT NOT NULL,
  severity    TEXT NOT NULL,             -- critical | major | minor | nit
  summary     TEXT NOT NULL,
  detail      TEXT NOT NULL DEFAULT '',
  file        TEXT,
  line        INTEGER,
  disposition TEXT NOT NULL DEFAULT 'open',  -- open | fixing | fixed | waived
  fix_task_id TEXT REFERENCES task(id),
  created_at  TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS bug (
  id             TEXT PRIMARY KEY,        -- BUG-001
  title          TEXT NOT NULL,
  body           TEXT NOT NULL DEFAULT '',
  repro          TEXT NOT NULL DEFAULT '',
  severity       TEXT NOT NULL DEFAULT 'major',
  status         TEXT NOT NULL DEFAULT 'open',  -- open | fixing | fixed | wontfix
  found_by       TEXT,                    -- agent name or 'user'
  requirement_id TEXT REFERENCES requirement(id),
  fix_task_id    TEXT REFERENCES task(id),
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
) STRICT;

-- ---------- maintenance (§6.2) ----------
-- What the product is made of, from a quality standpoint. Evergreen: survives releases
-- and board resets. `last_inspected_at` is what makes "what needs inspection" a query
-- rather than a judgment call.
CREATE TABLE IF NOT EXISTS coverage (
  id                TEXT PRIMARY KEY,     -- 'checkout-flow'
  area              TEXT NOT NULL,        -- human name
  risk              TEXT NOT NULL DEFAULT 'medium',  -- high | medium | low
  spec_path         TEXT,                 -- committed e2e spec, if one exists
  last_inspected_at TEXT,
  notes             TEXT NOT NULL DEFAULT ''
) STRICT;

-- One turn of the maintenance cycle.
CREATE TABLE IF NOT EXISTS inspection (
  id          TEXT PRIMARY KEY,           -- INSP-001
  scope       TEXT NOT NULL,              -- 'whole product' | a coverage area
  "trigger"   TEXT NOT NULL DEFAULT 'manual',  -- manual only today; the column exists so a
                                          -- cadence can be added later without a migration
  status      TEXT NOT NULL DEFAULT 'todo',
  started_at  TEXT,
  finished_at TEXT
) STRICT;

CREATE TABLE IF NOT EXISTS inspection_coverage (
  inspection_id TEXT NOT NULL REFERENCES inspection(id),
  coverage_id   TEXT NOT NULL REFERENCES coverage(id),
  verdict       TEXT,                     -- pass | issues | not-reached
  PRIMARY KEY (inspection_id, coverage_id)
) STRICT;

CREATE TABLE IF NOT EXISTS doc (
  slug       TEXT PRIMARY KEY,            -- 'sveltekit-form-actions'
  title      TEXT NOT NULL,
  body       TEXT NOT NULL,
  source     TEXT NOT NULL DEFAULT '',    -- who/what produced it
  updated_at TEXT NOT NULL
) STRICT;

-- ---------- history ----------
CREATE TABLE IF NOT EXISTS event (
  id           INTEGER PRIMARY KEY,
  ts           TEXT NOT NULL,
  actor        TEXT NOT NULL,             -- 'orchestrator' | agent name | 'user'
  verb         TEXT NOT NULL,             -- 'dispatched' | 'completed' | 'approved' | ...
  subject_type TEXT NOT NULL,
  subject_id   TEXT NOT NULL,
  payload      TEXT NOT NULL DEFAULT '{}' -- JSON
) STRICT;

-- ---------- indexes ----------
CREATE INDEX IF NOT EXISTS task_by_req     ON task(requirement_id, status);
CREATE INDEX IF NOT EXISTS node_by_req     ON graph_node(requirement_id, status);
CREATE INDEX IF NOT EXISTS event_recent    ON event(ts DESC);
CREATE INDEX IF NOT EXISTS finding_by_task ON review_finding(task_id, disposition);
