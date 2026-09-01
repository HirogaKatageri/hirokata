# Task lifecycle — what a ticket is, and who may move it

A task is a **row** in `.guild/guild.db`. There are no ticket files, no status directories and
no writable paths. Read one with SQL; the columns are documented in
`guild:warehouse` → `references/schema.md`, and the DDL is `schema.sql`.

```sql
SELECT json_object('id', id, 'status', status, 'req', requirement_id, 'plan', plan_id,
                   'slice', COALESCE(plan_slice, ''), 'group', COALESCE(parallel_group, ''),
                   'agent', COALESCE(agent, ''), 'claimed_by', COALESCE(claimed_by, ''),
                   'priority', priority, 'title', title)
  FROM task WHERE id = 'TASK-001';

-- byte-exact free text: exactly one column, so no separator is ever inserted
SELECT objective FROM task WHERE id = 'TASK-001';
SELECT body      FROM task WHERE id = 'TASK-001';
```

**`agent` and `claimed_by` are different things.** `agent` is the **pin** the architect wrote
on the ticket — optional, and when set it wins the match outright. `claimed_by` is who
actually took it, written with `claimed_at` at dispatch.

**A ticket names a capability, not a member.** `task_capability.required = 1` decides
*eligibility* (an agent must cover every one); `required = 0` decides *rank only* and never
excludes anybody. A ticket with capabilities nobody covers is a **roster gap** — the matcher
returns nothing, which is the whole reason for declaring them.

## The status vocabulary

Six words, each of which buys something specific. The CHECK constraint on `task.status`
rejects anything else, on every connection.

```
todo  →  in-progress  →  done
  ↑                   →  failed      (agent tried; the guild master then rules on it)
  └──── blocked   ←────  (the matcher found nobody)
              waived     (skipped by a gate decision)
```

| Status | Meaning |
|---|---|
| `todo` | Not started. The only status `v_task_actionable` will offer. |
| `in-progress` | Claimed and running. `v_next_task` resumes one of these before claiming anything new. |
| `done` | Finished. |
| `failed` | An agent tried and could not — **and a human has already seen it**, because the orchestrator sets it and the gate rules on it. Adjudicated, so it does NOT hold the review gate. |
| `blocked` | **Nobody on the roster can take this.** Not a general "stuck" flag. A machine verdict nobody has ruled on, so it DOES hold the review gate. |
| `waived` | Deliberately skipped by a gate decision. Counts as finished for dependency purposes, exactly like `done`. |

**The `failed` / `blocked` asymmetry is the most load-bearing judgment in the schema.**
Adjudicated work stops blocking; un-adjudicated work does not. A held gate is loud — the
blocked task sits on the board naming the capability nobody has.

`blocked` therefore behaves like `todo`, not like `failed`:

- `v_task_actionable` asks for `todo`, so a blocked ticket can never be offered.
- It **holds its requirement's review gate closed** (the open set is
  `todo, in-progress, blocked`).
- It **keeps its requirement open** — `v_requirement_progress.tasks_open` counts it. Nothing
  in the schema stops you from closing over one; that is a convention you honor.
- `v_batch` excludes it, so the rest of a parallel group still dispatches.

The fix for a blocked ticket is **recruiting**, not a status edit.

## Who writes what

**The orchestrator owns every status transition.** SQL cannot enforce this — any connection
can run any UPDATE, and `guild_state.actor` is a courtesy label the triggers copy verbatim.
It holds because the orchestrator and the agent definitions honor it.

| Writer | May write |
|---|---|
| orchestrator | `task.status`, `graph_node.status`, `gate.status`, plus the rows it creates |
| any agent | `work_log`, `review_finding`, `bug`, `doc`, `coverage` — its own reports |
| nobody | `event` — the triggers write it, and a memory you can edit is not one |

Always guard the transition on the status you expect, and always `RETURNING`. Zero rows back
means somebody already moved it, which is information:

```sql
UPDATE task SET status = 'in-progress', claimed_by = 'developer',
                claimed_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE id = 'TASK-001' AND status = 'todo'
RETURNING id, status, claimed_by;
```

Do not set `updated_at` — a trigger stamps it, and another writes the `event` row.

## The work log, and the recovery triage

Agents append to `work_log` **as they work**: a start entry before substantive work begins,
one per milestone, and a final report. The entry is free text, so it crosses as
`CAST(x'<hex>' AS TEXT)`.

```sql
INSERT INTO work_log (task_id, ts, agent, entry)
SELECT t.id, strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'developer', CAST(x'<hex>' AS TEXT)
  FROM task t WHERE t.id = 'TASK-001'
RETURNING id;
```

The start entry is not optional politeness — it is what the check-in recovery triage keys on.
Each `in-progress` task at check-in is triaged three ways:

- **No log rows** → never started → back to `todo`, and its node back to `pending`.
- **The last entry reports completion or failure** → the session died before the orchestrator
  recorded it → record the outcome now, without re-dispatching.
- **Started but unfinished** → leave it `in-progress`; the resumed agent reads the log and
  continues from the last entry.

## The waiver

A `failed` ticket the guild master decided to skip is marked by a work-log entry whose text
**begins exactly** `Skipped by user`. It is a marker, not a column — `v_failed_tasks.waived`
reads it back, and `reason` is separately the most recent entry that is *not* the waiver, so
the agent's own account of the failure survives.

```sql
SELECT id, who, waived, reason, title FROM v_failed_tasks;
```

## Parallel groups

`parallel_group` is a **safety assertion by the architect**, not a dependency graph: "these
tickets touch disjoint files and neither needs the other's output". The disjointness lives in
`plan_slice.files` and **nothing verifies it** — a collision found afterwards is a bug filed
for the repairs gate.

Dependencies are a different table. `task_dependency` holds **direct predecessors only** —
there is no transitive closure anywhere, because readiness propagates one hop at a time as
work completes. `v_task_deps` and `v_task_blockers` read it; `done` and `waived` both count
as finished.
