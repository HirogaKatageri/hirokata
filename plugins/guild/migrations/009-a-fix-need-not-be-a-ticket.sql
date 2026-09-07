-- =====================================================================================
-- guild migration 009 — a fix need not be a ticket
-- =====================================================================================
--
-- RUN IT ONCE, THEN RE-APPLY THE SCHEMA
--
--   export PATH="$HOME/.turso:$PATH"
--   tursodb .guild/guild.db < migrations/009-a-fix-need-not-be-a-ticket.sql
--   tursodb .guild/guild.db < schema.sql
--
-- ORDER MATTERS, but less than it did for 008. This file adds two columns and stamps the
-- version; `schema.sql` then rebuilds every view and trigger on top of them. Running
-- `schema.sql` first is harmless but pointless — `CREATE TABLE IF NOT EXISTS` sees the old
-- `bug` and `review_finding` and moves on, so the columns never appear.
--
-- CHECK BEFORE YOU RUN IT:
--
--   SELECT version FROM schema_version
--
-- 8 means this migration has not run. 9 means it has. A board below 8 must run
-- `008-the-library-becomes-a-graph.sql` first, and so on back through 006.
--
-- SAFE TO RUN ON A LIVE BOARD. It adds two columns with defaults and writes one row. It
-- deletes nothing, rewrites no existing value, and drops no object.
--
--
-- WHY
--
-- G6 flagged `bug-fixing-without-task` for any bug marked `fixing` or `fixed` with no
-- `fix_task_id`, and the same for a `review_finding`. That is right for work the guild
-- did: a defect claiming to be fixed should have a ticket doing it.
--
-- It had no expression for a defect fixed OUTSIDE the board — by somebody committing
-- directly, which is how most defects in a small repository actually get fixed. All three
-- available encodings were wrong in a different way:
--
--   fixed    true, and breached G6
--   wontfix  passed G6, and was a lie: it WAS fixed
--   open     passed G6, and was also a lie: it is not open
--
-- Two real boards paid for this. The guild plugin's own board carried a deliberate G6
-- breach on the two defects fixed by commit 247414c and shipped in 8.1.1, because the
-- plugin had no board of its own at the time. And on a product board, BUG-023 — resolved
-- by re-planning a requirement rather than by a repair ticket — was first recorded `fixed`,
-- tripped G6, and was changed to `wontfix`, which is now a permanent inaccuracy for
-- exactly this reason.
--
-- `fix_ref` is free text on purpose. A commit sha, a PR url, "shipped in 8.1.1" and "fixed
-- by the REQ-003 re-plan" are all legitimate answers to "where did this get fixed", and a
-- column that only accepted one shape would push the others back into a lie.
--
-- G6 now accepts EITHER a `fix_task_id` or a non-empty `fix_ref`. It still fires when a
-- defect claims to be fixed and points at nothing at all, which is the case worth catching.
-- =====================================================================================

PRAGMA foreign_keys = ON;

ALTER TABLE bug            ADD COLUMN fix_ref TEXT NOT NULL DEFAULT '';
ALTER TABLE review_finding ADD COLUMN fix_ref TEXT NOT NULL DEFAULT '';

UPDATE schema_version
   SET version = 9, applied_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE id = 1;

-- Expect one row: 9
SELECT version FROM schema_version WHERE id = 1;
