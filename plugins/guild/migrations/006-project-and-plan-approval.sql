-- =====================================================================================
-- guild migration 006 — `phase` becomes `project`, and a plan gets an approval
-- =====================================================================================
--
-- RUN IT ONCE, THEN RE-APPLY THE SCHEMA
--
--   export PATH="$HOME/.turso:$PATH"
--   tursodb .guild/guild.db < migrations/006-project-and-plan-approval.sql
--   tursodb .guild/guild.db < schema.sql
--
-- ORDER IS NOT OPTIONAL. This file moves the DATA. `schema.sql` then rebuilds every view
-- and trigger on top of the new shape. Running `schema.sql` first lands views on columns
-- that are not there yet.
--
-- RUN IT ONCE. It is NOT idempotent — the second run fails on `CREATE TABLE project`,
-- which is the safe direction to fail. Check first:
--
--   SELECT version FROM schema_version
--
-- 5 means this migration has not run. 6 means it has. Anything below 5 is a board from a
-- v5 stage that never got the CHECK constraints, and it should be rebuilt rather than
-- migrated.
--
-- BACK UP THE FILE FIRST. `cp .guild/guild.db .guild/guild.db.bak` costs nothing.
--
-- ------------------------------------------------------------------------------------
-- WHAT CHANGES
--
--   phase                -> project, and `PHASE-001` -> `PROJ-001`
--   phase.ordinal        NOT NULL -> nullable. NULL means 'unordered', not 'first'
--   project.body         new, ''
--   project.priority     new, 3 — every other level had one and this one did not
--   project.concurrent   new, 0 — an existing phase was sequential, so it stays sequential
--   project.isolation    new, 'shared' — nobody was running in a worktree before this
--   project.worktree_path new, NULL
--   requirement.phase_id -> requirement.project_id
--   plan.approval        new, 'pending' — except finished plans, see below
--   plan.approved_by     new, NULL
--   plan.approved_at     new, NULL
--   plan.gate_node_id    new, NULL — link it to the `gate-plan` node yourself if you want
--                        the two ends tied on old rows
--
-- WHAT IS DELIBERATELY LEFT ALONE
--
--   `event.payload` on old rows still says `"phase_id"`. It is the record of what was
--   written at the time and rewriting it would be a lie about history. Only
--   `event.subject_type` and `event.subject_id` move, because `v_recent_activity` joins
--   on those to find a title and a feed that cannot name its subject is worse.
-- =====================================================================================

PRAGMA foreign_keys = OFF;
PRAGMA busy_timeout = 5000;


-- ---- 0. clear the objects that name the old shape ------------------------------------
-- All of these are recreated by `schema.sql`. Dropping them here keeps the rebuild below
-- from tripping over a view that still says `phase`.
DROP VIEW    IF EXISTS v_goal_progress;
DROP VIEW    IF EXISTS v_requirement_progress;
DROP VIEW    IF EXISTS v_recent_activity;
DROP VIEW    IF EXISTS v_brief;
DROP TRIGGER IF EXISTS trg_phase_created;
DROP TRIGGER IF EXISTS trg_phase_moved;
DROP TRIGGER IF EXISTS trg_phase_deleted;
DROP TRIGGER IF EXISTS trg_phase_touch;
DROP TRIGGER IF EXISTS trg_requirement_created;
DROP TRIGGER IF EXISTS trg_requirement_touch;
DROP TRIGGER IF EXISTS trg_plan_touch;
DROP INDEX   IF EXISTS phase_by_goal;


-- ---- 1. phase -> project ------------------------------------------------------------
-- A REBUILD rather than a RENAME, because `ordinal` has to lose its NOT NULL and the
-- table-level CHECK on `worktree_path` cannot be added by ALTER. The column list on the
-- INSERT is explicit on both sides: a positional `SELECT *` here would silently shift
-- every value one column left the day somebody adds a column to `phase`.
CREATE TABLE project (
  id            TEXT PRIMARY KEY,
  goal_id       TEXT NOT NULL REFERENCES goal(id),
  title         TEXT NOT NULL,
  body          TEXT NOT NULL DEFAULT '',
  ordinal       INTEGER,
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

INSERT INTO project (id, goal_id, title, body, ordinal, status,
                     priority, concurrent, isolation, worktree_path,
                     created_at, updated_at)
SELECT p.id, p.goal_id, p.title, '', p.ordinal, p.status,
       3, 0, 'shared', NULL,
       p.created_at, p.updated_at
  FROM phase p;

DROP TABLE phase;


-- ---- 2. requirement.phase_id -> requirement.project_id -------------------------------
ALTER TABLE requirement RENAME COLUMN phase_id TO project_id;


-- ---- 3. plan gains an approval, separate from its drafting status --------------------
ALTER TABLE plan ADD COLUMN approval TEXT NOT NULL DEFAULT 'pending'
                 CHECK (approval IN ('pending', 'approved', 'rejected'));
ALTER TABLE plan ADD COLUMN approved_by TEXT;
ALTER TABLE plan ADD COLUMN approved_at TEXT;
ALTER TABLE plan ADD COLUMN gate_node_id TEXT REFERENCES graph_node(id);


-- ---- 4. PHASE-001 -> PROJ-001 --------------------------------------------------------
-- `substr(id, 7)` drops the six characters of 'PHASE-'. The GLOB guard means a board that
-- somehow already carries `PROJ-` ids is left untouched.
UPDATE project
   SET id = 'PROJ-' || substr(id, 7)
 WHERE id GLOB 'PHASE-*';

UPDATE requirement
   SET project_id = 'PROJ-' || substr(project_id, 7)
 WHERE project_id IS NOT NULL AND project_id GLOB 'PHASE-*';

UPDATE event
   SET subject_type = 'project',
       subject_id   = CASE WHEN subject_id GLOB 'PHASE-*'
                           THEN 'PROJ-' || substr(subject_id, 7)
                           ELSE subject_id END
 WHERE subject_type = 'phase';


-- ---- 5. what was already built was already agreed to ---------------------------------
-- A plan whose drafting finished on the old board got built, which means somebody said
-- yes to it — the board simply had nowhere to write that down. Backfilling `pending`
-- instead would put every historical plan into the approval queue on the next check-in.
-- `approved_by` names the migration rather than 'user', because no user clicked anything.
UPDATE plan
   SET approval    = 'approved',
       approved_by = 'migration-006',
       approved_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE status = 'done';


-- ---- 6. stamp the version ------------------------------------------------------------
UPDATE schema_version
   SET version = 6, applied_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE id = 1;

PRAGMA foreign_keys = ON;

-- =====================================================================================
-- NOW RUN `schema.sql`. Until you do, this board has no views and an incomplete set of
-- triggers.
-- =====================================================================================
