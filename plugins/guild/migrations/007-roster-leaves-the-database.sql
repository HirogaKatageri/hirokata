-- =====================================================================================
-- guild migration 007 — the roster leaves the database
-- =====================================================================================
--
-- RUN IT ONCE, THEN RE-APPLY THE SCHEMA
--
--   export PATH="$HOME/.turso:$PATH"
--   tursodb .guild/guild.db < migrations/007-roster-leaves-the-database.sql
--   tursodb .guild/guild.db < schema.sql
--
-- ORDER IS NOT OPTIONAL. This file removes the tables. `schema.sql` then rebuilds every
-- view and trigger on top of the new shape. Running `schema.sql` first leaves views
-- standing on tables this file is about to drop.
--
-- RUN IT ONCE. It is NOT idempotent — the second run fails on `CREATE TABLE task_new`,
-- which is the safe direction to fail. Check first:
--
--   SELECT version FROM schema_version
--
-- 6 means this migration has not run. 7 means it has. A board below 6 must run
-- `006-project-and-plan-approval.sql` first.
--
-- BACK UP THE FILE FIRST. `cp .guild/guild.db .guild/guild.db.bak` costs nothing.
--
-- ------------------------------------------------------------------------------------
-- WHY
--
-- `agent` and `agent_capability` were a MIRROR. Every fact in them — who the guild's
-- members are, what each can do, which model it runs on, whether it runs serially — is
-- declared in the frontmatter of the member's own markdown file:
--
--   ---
--   name: developer-svelte
--   model: sonnet
--   capabilities: [implement, frontend, svelte, sveltekit]
--   serial: false
--   ---
--
-- Two copies of one truth is one copy too many, and the SQL copy was the one that went
-- stale: it was only ever as fresh as the last sync somebody remembered to run, and a new
-- agent file was invisible to the matcher until then. Worse, the mirror could only ever
-- see the plugin's OWN `agents/` directory, while the user has subagents from their
-- project, their home directory and every other installed plugin.
--
-- So the roster goes back to the files, and the dispatcher reads THE FRONTMATTER OF EVERY
-- SUBAGENT AVAILABLE TO THE USER at dispatch time.
--
-- ------------------------------------------------------------------------------------
-- WHAT CHANGES
--
--   agent               DROPPED
--   agent_capability    DROPPED
--   capability_request  DROPPED
--   task.claimed_by     loses `REFERENCES agent(name)` — a table rebuild, see step 2
--   task_capability     KEPT, unchanged. What the WORK needs is still board data.
--
--   v_agent_eligible · v_agent_match · v_task_top_agent            DROPPED
--   v_capability_vocabulary · v_capability_unknown · v_roster_gaps DROPPED
--   v_open_bounties · v_blocked_tasks · v_brief                    RESHAPED by schema.sql
--
-- The matching RULE did not die, it moved into the dispatcher. `schema.sql` documents it
-- where the matcher views used to stand.
--
-- ------------------------------------------------------------------------------------
-- WHAT IS DELIBERATELY LEFT ALONE
--
--   `event` rows whose `subject_type` is 'agent' or 'capability_request'. They are the
--   record of what was written at the time, and deleting them would be a lie about a
--   board that really did recruit those members. `v_recent_activity` resolves an unknown
--   subject_type to a blank title rather than failing, so the feed stays readable.
--
--   `task.agent` and `task.claimed_by` VALUES, including names whose agent file is long
--   gone. Retiring a member used to be `active = 0` precisely so old dispatches kept
--   their explanation. Deleting the roster must not cost what retiring never did.
--
--   `task_capability` rows naming a capability no agent declares. They are the ticket's
--   honest statement of need. The dispatcher will fail to match one and write the ticket
--   to `blocked`, which is where that gap belongs — on the board, not in a request table.
-- =====================================================================================

PRAGMA foreign_keys = OFF;
PRAGMA busy_timeout = 5000;


-- ---- 0. clear every view -------------------------------------------------------------
-- All of them are recreated by `schema.sql`. Six name the roster directly, but the table
-- rebuild in step 2 re-parses the whole schema, and ANY surviving view over `task` would
-- trip it. Dropping the lot is both simpler and safer than dropping the six.
DROP VIEW IF EXISTS v_brief;
DROP VIEW IF EXISTS v_roster_gaps;
DROP VIEW IF EXISTS v_capability_unknown;
DROP VIEW IF EXISTS v_capability_vocabulary;
DROP VIEW IF EXISTS v_coverage_due;
DROP VIEW IF EXISTS v_recent_activity;
DROP VIEW IF EXISTS v_open_bugs;
DROP VIEW IF EXISTS v_open_findings;
DROP VIEW IF EXISTS v_failed_tasks;
DROP VIEW IF EXISTS v_in_flight;
DROP VIEW IF EXISTS v_goal_progress;
DROP VIEW IF EXISTS v_project_progress;
DROP VIEW IF EXISTS v_projects_runnable;
DROP VIEW IF EXISTS v_requirement_progress;
DROP VIEW IF EXISTS v_board;
DROP VIEW IF EXISTS v_plans_pending_approval;
DROP VIEW IF EXISTS v_gates_pending;
DROP VIEW IF EXISTS v_ready_nodes;
DROP VIEW IF EXISTS v_blocked_tasks;
DROP VIEW IF EXISTS v_open_bounties;
DROP VIEW IF EXISTS v_task_top_agent;
DROP VIEW IF EXISTS v_agent_match;
DROP VIEW IF EXISTS v_agent_eligible;
DROP VIEW IF EXISTS v_batch;
DROP VIEW IF EXISTS v_next_task;
DROP VIEW IF EXISTS v_task_actionable;
DROP VIEW IF EXISTS v_task_blockers;
DROP VIEW IF EXISTS v_task_deps;
DROP VIEW IF EXISTS v_task_who;


-- ---- 1. clear every trigger -----------------------------------------------------------
-- Same reasoning as step 0, and it is not paranoia: `ALTER TABLE ... RENAME` in step 2
-- RE-PARSES THE WHOLE SCHEMA, and `trg_requirement_moved` reads `task` in its body. With
-- that trigger still standing while `task` is momentarily absent, the rename fails with
-- "no such table: task" and leaves the board with no `task` table at all.
--
-- Dropping the lot is the safe move, and it costs nothing: `schema.sql` recreates every
-- one of these. The five roster triggers at the end are the exception — they are the ones
-- it deliberately does not recreate.
DROP TRIGGER IF EXISTS trg_goal_created;
DROP TRIGGER IF EXISTS trg_goal_moved;
DROP TRIGGER IF EXISTS trg_goal_deleted;
DROP TRIGGER IF EXISTS trg_goal_touch;
DROP TRIGGER IF EXISTS trg_project_created;
DROP TRIGGER IF EXISTS trg_project_moved;
DROP TRIGGER IF EXISTS trg_project_isolated;
DROP TRIGGER IF EXISTS trg_project_deleted;
DROP TRIGGER IF EXISTS trg_project_touch;
DROP TRIGGER IF EXISTS trg_requirement_created;
DROP TRIGGER IF EXISTS trg_requirement_moved;
DROP TRIGGER IF EXISTS trg_requirement_deleted;
DROP TRIGGER IF EXISTS trg_requirement_touch;
DROP TRIGGER IF EXISTS trg_plan_created;
DROP TRIGGER IF EXISTS trg_plan_moved;
DROP TRIGGER IF EXISTS trg_plan_deleted;
DROP TRIGGER IF EXISTS trg_plan_approved;
DROP TRIGGER IF EXISTS trg_plan_touch;
DROP TRIGGER IF EXISTS trg_task_created;
DROP TRIGGER IF EXISTS trg_task_moved;
DROP TRIGGER IF EXISTS trg_task_claimed;
DROP TRIGGER IF EXISTS trg_task_deleted;
DROP TRIGGER IF EXISTS trg_task_touch;
DROP TRIGGER IF EXISTS trg_bug_created;
DROP TRIGGER IF EXISTS trg_bug_moved;
DROP TRIGGER IF EXISTS trg_bug_deleted;
DROP TRIGGER IF EXISTS trg_bug_touch;
DROP TRIGGER IF EXISTS trg_finding_created;
DROP TRIGGER IF EXISTS trg_finding_dispositioned;
DROP TRIGGER IF EXISTS trg_worklog_created;
DROP TRIGGER IF EXISTS trg_coverage_created;
DROP TRIGGER IF EXISTS trg_coverage_inspected;
DROP TRIGGER IF EXISTS trg_inspection_created;
DROP TRIGGER IF EXISTS trg_inspection_moved;
DROP TRIGGER IF EXISTS trg_doc_created;
DROP TRIGGER IF EXISTS trg_doc_updated;
DROP TRIGGER IF EXISTS trg_doc_touch;
DROP TRIGGER IF EXISTS trg_node_moved;
DROP TRIGGER IF EXISTS trg_deviation_created;
DROP TRIGGER IF EXISTS trg_gate_decided;
DROP TRIGGER IF EXISTS trg_capreq_created;
DROP TRIGGER IF EXISTS trg_capreq_resolved;
DROP TRIGGER IF EXISTS trg_agent_recruited;
DROP TRIGGER IF EXISTS trg_agent_retired;
DROP TRIGGER IF EXISTS trg_agent_deleted;


-- ---- 2. task loses its foreign key to a table that is going away ----------------------
-- `claimed_by TEXT REFERENCES agent(name)` cannot be removed by ALTER, so this is the
-- standard rebuild: new table, copy, drop, rename. Leaving the constraint behind would be
-- worse than untidy — with `PRAGMA foreign_keys = ON` every future write to `task` would
-- fail against a missing parent table.
--
-- The column list is explicit on both sides. A positional `SELECT *` would silently shift
-- every value one column left the day somebody adds a column to `task`.
CREATE TABLE task_new (
  id             TEXT PRIMARY KEY,
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  plan_id        TEXT REFERENCES plan(id),
  files          TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(files)),
  parallel_group TEXT,
  node_key       TEXT,
  title          TEXT NOT NULL,
  objective      TEXT NOT NULL DEFAULT '',
  body           TEXT NOT NULL DEFAULT '',
  status         TEXT NOT NULL DEFAULT 'todo'
                 CHECK (status IN ('todo', 'in-progress', 'done',
                                   'failed', 'blocked', 'waived')),
  priority       INTEGER NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
  agent          TEXT,
  claimed_by     TEXT,
  claimed_at     TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
) STRICT;

INSERT INTO task_new (id, requirement_id, plan_id, files, parallel_group, node_key,
                      title, objective, body, status, priority,
                      agent, claimed_by, claimed_at, created_at, updated_at)
SELECT t.id, t.requirement_id, t.plan_id, t.files, t.parallel_group, t.node_key,
       t.title, t.objective, t.body, t.status, t.priority,
       t.agent, t.claimed_by, t.claimed_at, t.created_at, t.updated_at
  FROM task t;

DROP TABLE task;
ALTER TABLE task_new RENAME TO task;


-- ---- 3. drop the roster ---------------------------------------------------------------
-- Children first. `agent_capability` points at `agent`, so dropping `agent` under it would
-- leave a dangling reference on any board that later turns foreign keys back on.
DROP INDEX IF EXISTS agent_cap_by_cap;
DROP TABLE IF EXISTS agent_capability;
DROP TABLE IF EXISTS capability_request;
DROP TABLE IF EXISTS agent;


-- ---- 4. stamp the version -------------------------------------------------------------
UPDATE schema_version
   SET version = 7, applied_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE id = 1;

PRAGMA foreign_keys = ON;

-- =====================================================================================
-- NOW RUN `schema.sql`. Until you do, this board has no views and an incomplete set of
-- triggers.
--
-- Then confirm the roster is really gone and the board still reads:
--
--   SELECT name FROM sqlite_schema WHERE name LIKE '%agent%' OR name LIKE '%cap%'
--     -> task_capability and task_cap_by_cap (plus their autoindex), and nothing else
--   SELECT fact, value FROM v_brief
-- =====================================================================================
