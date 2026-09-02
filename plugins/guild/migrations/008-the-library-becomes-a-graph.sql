-- =====================================================================================
-- guild migration 008 — the library becomes a graph
-- =====================================================================================
--
-- RUN IT ONCE, THEN RE-APPLY THE SCHEMA
--
--   export PATH="$HOME/.turso:$PATH"
--   tursodb .guild/guild.db < migrations/008-the-library-becomes-a-graph.sql
--   tursodb .guild/guild.db < schema.sql
--
-- ORDER IS NOT OPTIONAL. This file rebuilds `doc`. `schema.sql` then creates the two new
-- tables and rebuilds every view and trigger on top of the new shape. Running `schema.sql`
-- first does nothing useful — `CREATE TABLE IF NOT EXISTS` sees the OLD `doc` and moves
-- on, and every view below that reads `doc.kind` then fails at runtime on a column that
-- was never added.
--
-- RUN IT ONCE, AND CHECK BEFORE YOU DO:
--
--   SELECT version FROM schema_version
--
-- 7 means this migration has not run. 8 means it has. A board below 7 must run
-- `007-roster-leaves-the-database.sql` first, and a board below 6 must run 006 before that.
--
-- THAT CHECK IS NOT OPTIONAL, AND HERE IS THE UNCOMFORTABLE REASON. A SECOND RUN DOES NOT
-- FAIL SAFELY — IT RESETS `kind`, `status`, `area` AND `created_at` ON EVERY DOCUMENT,
-- discarding whatever you re-tagged after the first run. The rebuild in step 2 ends in an
-- unconditional `DROP TABLE doc`, and no guard inside this file can prevent that:
-- **a failing statement does not stop a tursodb script** (there is no `-bail`), so a
-- tripwire statement at the top aborts nothing that follows it.
--
-- WHAT THE TRIPWIRE IN STEP 2 DOES BUY is that a re-run is LOUD instead of silent — the
-- duplicate `guild_state` key fails with a UNIQUE constraint error and the whole
-- invocation exits non-zero, so you find out. It tells you AFTERWARDS. The version check
-- above is what tells you BEFOREHAND, and the backup is what undoes it.
--
-- BACK UP THE FILE FIRST. `cp .guild/guild.db .guild/guild.db.bak` costs nothing, and it
-- is the only thing here that can actually reverse a mistaken second run.
--
-- ------------------------------------------------------------------------------------
-- WHY
--
-- The library was a FLAT PILE. `doc` held a slug, a title, a body and a source, and that
-- was the whole of the guild's long-term memory. Three things it could not do, each of
-- which cost something real:
--
--   1. IT COULD NOT SAY WHAT A DOCUMENT WAS FOR. A domain rule, a subsystem walkthrough,
--      an external API lookup and a runbook were the same kind of row, so no reader could
--      ask for one without reading all of them.
--
--   2. IT COULD NOT HOLD A DECISION AT ALL. Architectural choices lived in `plan.body`
--      prose and in `gate.decision` JSON — both attached to a ticket, both archived when
--      the ticket closed, neither findable a quarter later. "Why is it like this" was the
--      single most expensive question the guild could be asked, and the answer was
--      usually "read the git log". A project's decisions ARE its shape. They needed a home.
--
--   3. NOTHING POINTED AT ANYTHING. A page had no relation to the requirement it
--      explained, the decision it superseded, or the bug that proved it wrong. So nothing
--      could be derived: not "which shipped work is undocumented", not "which page went
--      stale when its subject moved", not "what did we decide, and what did we un-decide".
--
-- WHAT REPLACES IT IS NOT A SECOND DATABASE. The nodes of the knowledge graph are mostly
-- rows this board already has — requirements, plans, tasks, bugs, coverage areas. What was
-- missing was TYPED EDGES between them and a document kind that could carry a decision. So
-- this migration adds exactly that, and one trigger-written history table.
--
-- ------------------------------------------------------------------------------------
-- WHAT CHANGES
--
--   doc              REBUILT. Gains `kind`, `status`, `area` and `created_at`, all with
--                    the CHECKs a live board cannot be given by ALTER. See step 2.
--   knowledge_edge   NEW, created by `schema.sql` — typed, directed, polymorphic edges.
--   doc_revision     NEW, created by `schema.sql` — the body before each change, written
--                    by `trg_doc_revised`, which this file does not need to install
--                    because `schema.sql` creates every trigger.
--
--   v_knowledge_ref · v_doc_current · v_doc_neighbors · v_doc_stale ·
--   v_undocumented_work · v_decision_log · v_knowledge_dangling   NEW, from `schema.sql`
--   v_brief          gains `docs_current`, `docs_stale`, `work_undocumented`
--
-- ------------------------------------------------------------------------------------
-- WHAT THE BACKFILL GUESSES, AND WHAT YOU SHOULD FIX BY HAND AFTERWARDS
--
--   created_at  <- updated_at. THE ROW DOES NOT KNOW WHEN IT WAS WRITTEN. The old table
--                  carried one date and it was the last-touched one. Copying it forward
--                  is the only honest option available, and it means every pre-v8 doc
--                  reads as though it was created the day it was last edited. It is
--                  wrong and it is visible — better than inventing a plausible date.
--   kind        <- 'research' when `source` is 'researcher', else 'reference'. A
--                  HEURISTIC, and stated as one. Before v8 the researcher was very nearly
--                  the only writer, so this is right far more often than not — but any
--                  business rule or subsystem note somebody filed by hand lands on
--                  'reference' and needs re-tagging. Find them with:
--                      SELECT slug, title, kind FROM doc ORDER BY kind, slug
--   status      <- 'current' for every row. There was no lifecycle to preserve.
--   area        <- '' for every row. There was no area to preserve.
--
-- NO EDGES ARE INVENTED. This migration writes ZERO `knowledge_edge` rows, and that is
-- deliberate: an edge is an assertion about meaning, and a script cannot make one. The
-- board will therefore report every finished requirement in `v_undocumented_work` on the
-- first read after upgrading. That number is not a bug, it is the backlog becoming
-- visible for the first time. Work it down with `guild:document`, or ignore it.
-- =====================================================================================

PRAGMA foreign_keys = OFF;
PRAGMA busy_timeout = 5000;


-- ---- 0. clear every view -------------------------------------------------------------
-- All of them are recreated by `schema.sql`. Only a handful name `doc`, but the table
-- rebuild in step 2 RE-PARSES THE WHOLE SCHEMA, and any surviving view over `doc` would
-- trip it while the table is momentarily absent. Dropping the lot is simpler and safer
-- than reasoning about which ones matter, and it is exactly what 007 did.
DROP VIEW IF EXISTS v_brief;
DROP VIEW IF EXISTS v_knowledge_dangling;
DROP VIEW IF EXISTS v_decision_log;
DROP VIEW IF EXISTS v_undocumented_work;
DROP VIEW IF EXISTS v_doc_stale;
DROP VIEW IF EXISTS v_doc_neighbors;
DROP VIEW IF EXISTS v_doc_current;
DROP VIEW IF EXISTS v_knowledge_ref;
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
DROP VIEW IF EXISTS v_batch;
DROP VIEW IF EXISTS v_next_task;
DROP VIEW IF EXISTS v_task_actionable;
DROP VIEW IF EXISTS v_task_blockers;
DROP VIEW IF EXISTS v_task_deps;
DROP VIEW IF EXISTS v_task_who;


-- ---- 1. clear every trigger -----------------------------------------------------------
-- Same reasoning as step 0, and the same lesson 007 paid for: `ALTER TABLE ... RENAME`
-- re-parses the whole schema, so a trigger whose BODY names a table that is briefly absent
-- fails the rename and can leave the board without the table entirely. `schema.sql`
-- recreates every one of these.
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
DROP TRIGGER IF EXISTS trg_doc_moved;
DROP TRIGGER IF EXISTS trg_doc_revised;
DROP TRIGGER IF EXISTS trg_doc_touch;
DROP TRIGGER IF EXISTS trg_edge_linked;
DROP TRIGGER IF EXISTS trg_edge_unlinked;
DROP TRIGGER IF EXISTS trg_node_moved;
DROP TRIGGER IF EXISTS trg_deviation_created;
DROP TRIGGER IF EXISTS trg_gate_decided;


-- ---- 2. doc gains a type, a lifecycle, an area and a birth date -----------------------
-- SQLite cannot ALTER in a CHECK, so a vocabulary arrives as a table rebuild: new table,
-- copy, drop, rename. The column list is explicit on both sides — a positional `SELECT *`
-- would silently shift every value one column left the day somebody adds a column.
--
-- The four new columns are given their defaults IN THE SELECT rather than relying on the
-- column default, so the backfill is readable here rather than inferred from the DDL.
-- THE TRIPWIRE. It cannot stop a second run (see the header) — it makes one LOUD. On a
-- board that has already been migrated this INSERT fails on the primary key, the
-- invocation exits non-zero, and the operator learns that the rebuild below just reset
-- every document's tagging. On a first run it is a silent, ordinary row.
INSERT INTO guild_state (key, value)
VALUES ('migration-008', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));

CREATE TABLE doc_new (
  slug       TEXT PRIMARY KEY,
  title      TEXT NOT NULL,
  body       TEXT NOT NULL,
  kind       TEXT NOT NULL DEFAULT 'reference'
             CHECK (kind IN ('business', 'technical', 'decision',
                             'research', 'runbook', 'reference')),
  status     TEXT NOT NULL DEFAULT 'current'
             CHECK (status IN ('draft', 'current', 'superseded', 'rejected')),
  area       TEXT NOT NULL DEFAULT '',
  source     TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
) STRICT;

INSERT INTO doc_new (slug, title, body, kind, status, area, source, created_at, updated_at)
SELECT d.slug,
       d.title,
       d.body,
       CASE WHEN d.source = 'researcher' THEN 'research' ELSE 'reference' END,
       'current',
       '',
       d.source,
       d.updated_at,
       d.updated_at
  FROM doc d;

DROP TABLE doc;
ALTER TABLE doc_new RENAME TO doc;


-- ---- 3. stamp the version -------------------------------------------------------------
UPDATE schema_version
   SET version = 8, applied_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE id = 1;

PRAGMA foreign_keys = ON;

-- =====================================================================================
-- NOW RUN `schema.sql`. Until you do, this board has no views, an incomplete set of
-- triggers, and neither of the two new tables.
--
-- Then confirm the library survived and the graph is standing:
--
--   SELECT version FROM schema_version                     -> 8
--   SELECT value FROM guild_state WHERE key='migration-008' -> when this file ran
--   SELECT kind, COUNT(*) FROM doc GROUP BY kind           -> your docs, tagged by the heuristic
--   SELECT COUNT(*) FROM knowledge_edge                    -> 0. Nothing invents an edge
--   SELECT COUNT(*) FROM v_knowledge_dangling              -> 0, and it must stay 0
--   SELECT fact, value FROM v_brief                        -> now carries the three doc facts
--
-- Then re-tag the docs the heuristic put on 'reference' but that are really 'business',
-- 'technical' or 'runbook', and start linking. An unlinked document is invisible to
-- `v_doc_stale` and counts for nothing in `v_undocumented_work`.
-- =====================================================================================
