# Check-in edge cases

Three situations that come up during the work cycle but are not part of the main loop:
a requirement with no execution graph, a ticket nobody on the roster can take, and the
CHANGELOG bullet on completion.

## A requirement with no graph — the cursor fallback

For a board that predates the graph, the cursor still works and it is the fallback:

```sql
SELECT * FROM v_next_task;                                   -- resume, else claim
SELECT member_id, member_status, member_title FROM v_batch WHERE task_id = 'TASK-NNN';
```

**Use it only when the requirement has no `graph_node` rows, and say so out loud.**
`v_next_task` applies the review gate but deliberately ignores dependencies and eligibility,
so check `v_open_bounties` before dispatching. Resolve the member with the pin/capability
rule in §3.3, and skip §3.5 — there is no gate on a graph-less requirement, so a review report
goes to the user directly.

**Offer the fix once**: only the strategist should decide a graph's shape, so hand the
requirement back to `guild:new-requirement` rather than instantiating one yourself.

## No eligible agent — block it, loudly

When the match in §3.3 comes back empty — the ticket declared capabilities, has no pin, and no
roster member's `capabilities` cover its required set — that is a **gap in the roster** and it
should be loud.

**This write is the ONLY thing that makes the gap visible.** The database cannot see the agent
files, so no view can derive "nobody covers this": `v_open_bounties` will keep offering the
ticket every check-in until you write it down. Reading never blocks a ticket; blocking is a
decision, so it is a write you make on purpose:

```sql
UPDATE task SET status = 'blocked'
 WHERE id = 'TASK-005' AND status = 'todo'
   AND COALESCE(agent, '') = ''
RETURNING id, status;

INSERT INTO work_log (task_id, ts, agent, entry)
SELECT t.id, strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'orchestrator', CAST(x'<hex>' AS TEXT)
  FROM task t WHERE t.id = 'TASK-005';

UPDATE graph_node SET status = 'failed' WHERE task_id = 'TASK-005' AND status = 'running'
RETURNING id, status;
```

**Tell the user now, do not batch it into the wrap-up.** Name the ticket, the missing
capabilities (`v_blocked_tasks.who` spells them: `needs:implement+rust`), and the one thing
that fixes it:

```
TASK-005 "Port the codec to Rust" is blocked: no subagent available to you declares
[implement, rust]. Nothing will pick it up until one does. Adding an agent file with
`capabilities: [implement, rust]` to .claude/agents/ is the whole fix — or reassign
the work by pinning a member you accept.
```

**Say which capability is missing, not just that the match failed.** The word is the agent
file somebody needs to write, and it is the only actionable half of the report.

Then continue the loop. `blocked` means exactly one thing — **no guild member can take this
bounty** — never "waiting on a person or a decision". It holds the review gate and keeps its
requirement open at §3.6, both deliberately. **Never substitute a member you think is close
enough**; if the user wants a generalist to take it anyway, that is their call, out loud.

**Unblocking**: the moment an agent file declaring the capability exists, the gap is closed —
there is nothing to sync. Re-run the roster scan, confirm the new member covers the required
set, then `UPDATE task SET status = 'todo'` and `UPDATE graph_node SET status = 'pending'`.

## CHANGELOG maintenance

When a requirement reaches `done` (§3.6), append a bullet under `## [Unreleased]` in the
repo-root `CHANGELOG.md` (create the file with the Keep-a-Changelog preamble if missing):

```
- REQ-NNN: {requirement title}
```

Skip if a bullet starting with `- REQ-NNN:` is already there (idempotent). With waived tasks,
use `- REQ-NNN: {title} (TASK-NNN skipped)`. `guild:release` renames `## [Unreleased]` later.
