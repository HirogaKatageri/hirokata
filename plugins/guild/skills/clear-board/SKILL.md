---
name: clear-board
description: >
  This skill should be used when the user asks to "clear the board", "reset the guild",
  "start fresh", "wipe the board", "clear all tasks", "reset the board", or wants to
  remove all current work from the guild board and start over.
version: 5.0.0
user-invocable: true
allowed-tools: Bash(tursodb *)
---

# Clear Board — reset the guild

Delete every unit of work from the guild board, keeping the things that outlive a board:
the library, the quality map, and the guild's memory. **The roster is not on this list because
it is not in the database** — it is the agent files, and a board reset cannot reach it.

**This is genuinely destructive and there is no undo.** The v4 file tree and the v5 CLI's
replayable journal are both gone; the board is one SQLite file and a `DELETE` is final. Back it
up first — that is step 2, and it is not optional.

Load `guild:warehouse` first. Every statement here is raw SQL and the six rules apply.

## Step 1 — is there a board

```bash
export PATH="$HOME/.turso:$PATH"
[ -f .guild/config.yaml ] || echo "no guild here"
```

Run every query on this page with `-m list`. The default `pretty` mode draws a box and
**truncates long values with an ellipsis**, which would make an inventory undercount nothing but
would quietly clip any title or reason you show the user before they type `yes`.

Not found:
```
No guild board found. Nothing to clear.
Run /guild:check-in to initialize a new guild.
```
Stop here.

## Step 2 — inventory, and what survives

One query, and it is also the thing you show the user:

```sql
SELECT 'goals',        COUNT(*) FROM goal
UNION ALL SELECT 'projects',     COUNT(*) FROM project
UNION ALL SELECT 'requirements', COUNT(*) FROM requirement
UNION ALL SELECT 'plans',        COUNT(*) FROM plan
UNION ALL SELECT 'tasks',        COUNT(*) FROM task
UNION ALL SELECT 'tasks_open',   COUNT(*) FROM task WHERE status IN ('todo','in-progress')
UNION ALL SELECT 'graph_nodes',  COUNT(*) FROM graph_node
UNION ALL SELECT 'bugs_open',    COUNT(*) FROM bug WHERE status IN ('open','fixing')
UNION ALL SELECT 'work_log',     COUNT(*) FROM work_log
UNION ALL SELECT 'findings',     COUNT(*) FROM review_finding
UNION ALL SELECT 'events',       COUNT(*) FROM event
UNION ALL SELECT 'KEEP:coverage',COUNT(*) FROM coverage
UNION ALL SELECT 'KEEP:docs',    COUNT(*) FROM doc
UNION ALL SELECT 'KEEP:revisions',COUNT(*) FROM doc_revision
UNION ALL SELECT 'KEEP:doc_links',COUNT(*) FROM knowledge_edge
                                   WHERE from_type = 'doc' AND to_type = 'doc'
UNION ALL SELECT 'links_to_work', COUNT(*) FROM knowledge_edge
                                   WHERE from_type <> 'doc' OR to_type <> 'doc';
```

If every countable row is 0, say `The guild board is already empty — nothing to clear.` and stop.

**What a clear deletes:** `goal`, `project`, `requirement`, `plan`, `task`,
`task_dependency`, `task_capability`, `graph_node`, `graph_edge`, `graph_deviation`, `gate`,
`work_log`, `review_finding`, `bug`, `inspection`, `inspection_coverage`, the
`graph-template:REQ-NNN` keys in `guild_state`, **and every `knowledge_edge` that touches one
of those rows.**

**That last clause is not optional and it is easy to miss.** A `knowledge_edge` has no foreign
key — its endpoints are polymorphic and the engine cannot cascade — so deleting a requirement
leaves any `describes` or `decides` edge pointing at it **silently dangling**, which breaks the
`v_knowledge_dangling` global invariant on the very next `guild:validate`. Step 4 deletes those
edges explicitly, **first**, before the rows they point at.

**The library keeps its own shape.** Only edges touching the work are cut. `doc → doc` edges —
`supersedes`, `refines`, `depends-on`, `contradicts` — survive untouched, so the decision log
and its chains read exactly as before. What is genuinely lost is *provenance*: a decision that
governed `REQ-004` can no longer say so, because `REQ-004` is gone. Nothing can preserve that,
and pretending otherwise with a dangling edge is worse than losing it cleanly.

**What survives, and why:**

| Kept | Because |
|---|---|
| the agent files | **not in the database at all.** The roster is the guild, not the board — `agents/*.md` is untouched by anything here |
| `coverage` | evergreen. It describes the **product**, and the product did not go away |
| `doc` | the library. The business rules, the technical pages and **every decision this project ever made** — none of which stopped being true because the board was reset |
| `doc_revision` | the library's own history, and the reason a superseded page can still be read |
| `knowledge_edge`, **doc → doc only** | the supersession and refinement chains. The edges into the work are cut with the work |
| `event` | the guild's memory. Deleting it is a separate, louder decision — see Step 5 |
| `guild_state` (except `graph-template:*`) | `actor` and `last-checkin` are board plumbing |
| `.guild/docs/` · `.guild/qa/` on disk | evergreen for exactly the same reasons as `doc` and `coverage` |

## Step 3 — back up, then confirm

**Take the backup before you ask, not after they answer.** A confirmed clear against a board with
no backup is the one outcome nobody can walk back.

```bash
cp .guild/guild.db ".guild/guild.db.bak-$(date -u +%Y%m%dT%H%M%SZ)"
ls -la .guild/guild.db.bak-*
```

Then present the inventory and ask, in these words — say what is destroyed **and** what is kept,
because a user who thinks their QA coverage map is about to go will answer the wrong question:

```
Current board:
  {N} requirement(s), {N} plan(s), {N} task(s) ({N} still open)
  {N} graph node(s), {N} work-log entries, {N} review finding(s), {N} open bug(s)

This DELETES all of it, permanently. There is no undo.

Kept: the coverage map, the doc library, and the event feed. (The agent roster
lives in the agent files and is not affected either way.)
Backed up first: .guild/guild.db.bak-{stamp}

Clear the board? (yes / no)
```

Anything other than an explicit `yes` → stop, change nothing, and say the backup is still there
to delete if they want.

## Step 4 — the clear

**The order is load-bearing.** With `PRAGMA foreign_keys = ON` a parent cannot go before its
children, and two pairs of tables reference each other — `plan.task_id ↔ task.plan_id`, and
`review_finding`/`bug` both point at a repair task. Those three references get nulled first;
everything after that is a straight child-to-parent sweep.

```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'orchestrator' WHERE key = 'actor';

-- break the reference cycles first. `plan.gate_node_id` is the one that is easy to miss:
-- it points FORWARD into `graph_node`, so without this line `DELETE FROM graph_node` fails
-- the foreign key and every delete after it cascades into failure — and because tursodb has
-- no `-bail`, the script runs to the end and reports a clear that never happened.
UPDATE plan           SET task_id      = NULL;
UPDATE plan           SET gate_node_id = NULL;
UPDATE review_finding SET fix_task_id  = NULL;
UPDATE bug            SET fix_task_id  = NULL;

-- the execution graph
DELETE FROM gate;
DELETE FROM graph_edge;
DELETE FROM graph_node;
DELETE FROM graph_deviation;

-- the records
DELETE FROM work_log;
DELETE FROM review_finding;
DELETE FROM bug;

-- the work
DELETE FROM task_capability;
DELETE FROM task_dependency;
DELETE FROM task;
DELETE FROM plan;

-- maintenance runs (the coverage rows they point at STAY)
DELETE FROM inspection_coverage;
DELETE FROM inspection;

-- direction
DELETE FROM requirement;
DELETE FROM project;
DELETE FROM goal;

-- the per-requirement template keys; `actor` and `last-checkin` stay
DELETE FROM guild_state WHERE key LIKE 'graph-template:%';

-- NOTE: the knowledge_edge delete belongs at the TOP of this script, not here — see below.

SELECT 'left', (SELECT COUNT(*) FROM task), (SELECT COUNT(*) FROM requirement),
               (SELECT COUNT(*) FROM graph_node),
               (SELECT COUNT(*) FROM coverage), (SELECT COUNT(*) FROM doc),
               (SELECT COUNT(*) FROM v_knowledge_dangling);
```

**The very first delete in the script must be the library's edges into the work**, before
anything they point at is gone. Put this at the top, above the `work_log` delete:

```sql
-- Cut the library's links INTO the board. doc -> doc edges are untouched, so the decision
-- log and its supersession chains survive intact.
-- There is no cascade to do this for us: an edge's endpoints are polymorphic, so the engine
-- has no foreign key on either end. Skipping this leaves dangling edges and breaks the
-- v_knowledge_dangling invariant on the next validate.
DELETE FROM knowledge_edge WHERE from_type <> 'doc' OR to_type <> 'doc';
```

**`v_knowledge_dangling` must read 0 in the verification SELECT.** If it does not, an edge
survived pointing at something that did not — say so and stop rather than deleting more.

**Verify with that last SELECT and report what it actually says.** A failing statement does not
stop a tursodb script and the errors arrive on *stdout*, so "no error scrolled past" proves
nothing. The three work counts must be 0 and the three kept counts must be unchanged. If a
`FOREIGN KEY constraint failed` line came back, some table you did not expect still points at a
row — name it, stop, and do not start improvising deletes.

The deletes each fire a trigger that writes an `event` row, so the clear is itself in the record.
That is deliberate: a board that vanished with no trace is indistinguishable from a corrupted one.

## Step 5 — the event feed, only if they ask again

`event` is **not** cleared by Step 4. It is the guild's memory, its rows now name subjects that
no longer exist, and that is fine — `v_recent_activity` resolves a missing title to `''`.

If the user explicitly wants the memory gone too, ask a **second** time, in its own breath, and
say what it costs: the shift history, every status transition the guild ever made, and the
`last-checkin` window that `guild:brief` narrates from.

```sql
DELETE FROM event;
UPDATE guild_state SET value = 'null' WHERE key = 'last-checkin';
```

Never fold this into Step 4's confirmation. One `yes` must not destroy two different things.

## Step 6 — report

```
Board cleared.

  Deleted: {N} requirement(s), {N} plan(s), {N} task(s), {N} graph node(s),
           {N} work-log entries, {N} finding(s), {N} bug(s)
  Kept:    {N} agent(s), {N} coverage area(s), {N} doc(s), {N} event(s)
  Backup:  .guild/guild.db.bak-{stamp}

IDs are derived as MAX(n) + 1 and are never reused, so the next requirement is
REQ-001 again on an emptied board — but any ID in git history or in .guild/qa/
now points at nothing. Delete the backup when you are sure.
```

## Step 7 — verify against §8

Run `guild:validate clear-board`. §8 of `docs/expectations.md` is symmetrical and the second
half is the one that matters: §8.a asserts every board table is empty, §8.b diffs the *keep*
fingerprint — Step 2's counts — to prove the coverage map, the library and the event feed came
through untouched. **Report any line that moved.** A clear that took an
evergreen row destroyed something a board reset was never allowed to reach.

## Rules

- **Back up before you ask.** `cp .guild/guild.db .guild/guild.db.bak-<stamp>` is the only undo
  there is; there is no journal to replay any more.
- **Never `rm -rf` inside `.guild/`.** The clear is SQL. `.guild/docs/`, `.guild/qa/` and
  `.guild/reviews/` are evergreen and a shell glob does not know that.
- **Never `DELETE FROM agent`.** Retire with `active = 0`. A done task from months ago may still
  name a member whose file is gone, and deleting either breaks the foreign key or orphans the
  history that explains the board.
- **Never delete `coverage`, `doc` or `doc_revision`.** They describe the product and the
  guild's knowledge — including every decision it ever made — and all of that survives any
  number of boards.
- **Do delete the `knowledge_edge` rows that point into the work, and do it first.** There is
  no cascade. Leaving them behind breaks a global invariant, and the dangling edge claims a
  requirement exists that does not. `doc → doc` edges stay.
- **`event` is a separate question**, asked separately, answered separately.
- **Verify by reading the counts back**, not by the absence of an error message.
- **A fresh board can also be a fresh file** — `GUILD_DIR=.guild-next` with the schema applied to
  a new `guild.db` gives a genuinely empty board and leaves the old one intact. Offer it to
  anyone who hesitates at Step 3.
