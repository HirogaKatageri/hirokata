# Guild State Format

The guild has **no `BOARD.md`** and **no `status` frontmatter field**. An artifact's status is
the **subdirectory it lives in**. A tiny `state.yaml` holds only `last-checkin`. The "board" is a
**live view** rendered on demand by scanning the status directories — never a stored artifact.

All deterministic state operations go through the **guild CLI** at
`${CLAUDE_PLUGIN_ROOT}/scripts/guild` (see `scripts/README.md`). Skills and agents shell out to it
rather than hand-rolling `find`/`mv`/ID arithmetic.

## Status is a directory

```
.guild/
  state.yaml                              # only: last-checkin
  requirements/{todo,in-progress,done}/REQ-NNN.md
  plans/{todo,in-progress,done}/PLAN-NNN.md      # PLAN-NNN/ slice dir sits alongside the file
  tasks/{todo,in-progress,done,failed}/TASK-NNN.md
  docs/                                   # evergreen researcher knowledge base
  qa/                                     # evergreen QA artifacts
  archive/                                # evergreen released requirements
```

`docs/`, `qa/`, and `archive/` are evergreen — never cleared or archived away.

## Single source of truth per fact

| Fact | Lives in | Changed by |
|------|----------|------------|
| Task status (`todo`/`in-progress`/`done`/`failed`) | which `tasks/<status>/` dir holds `TASK-NNN.md` | the **orchestrator** via `guild move` |
| Task metadata (title, agent, requirement, plan, plan-slice) | `TASK-NNN.md` frontmatter | whoever creates the ticket (`guild new task`) |
| Work log / progress | `TASK-NNN.md` Work Log section | the assigned agent |
| Requirement status (`todo`/`in-progress`/`done`) | which `requirements/<status>/` dir holds `REQ-NNN.md` | the orchestrator / product-owner flow via `guild move` |
| Last check-in date | `.guild/state.yaml` | the orchestrator |

There is no second copy of any of these. The orchestrator never reconciles two stores. **Status is
never written into frontmatter** — moving the file is the only way to change status.

## `.guild/state.yaml`

```yaml
last-checkin: 2026-06-23   # ISO date of last check-in (null if never)
```

That is the entire file. There are **no ID counters** and **no `current` cursor**:

- **IDs are derived.** The next ID for a kind is `max(existing across all status dirs + archive)
  + 1`, computed by `guild next-id <req|task|plan>` (and used automatically by `guild new`). IDs
  are zero-padded to 3 digits (`001`…`999`) and continuous across releases. There is no counter to
  maintain, increment, or reset — deletion and creation are both self-correcting.
- **The cursor is derived.** "What am I working on" is simply whatever sits in
  `tasks/in-progress/`. `guild next` recomputes the next actionable task every cycle from the
  directories; there is nothing to cache or reconcile.

## The next actionable ticket — `guild next`

The orchestrator never scans by hand; it runs `guild next`, which encodes:

1. **Resume** — any task in `tasks/in-progress/` (lowest ID first). Interrupted work.
2. **Otherwise** — the lowest-ID task in `tasks/todo/`.
3. **Review gate** — a `reviewer` task is *only* actionable when every *other* task for its
   requirement has left `todo/` and `in-progress/` (the per-REQ N/N gate). If the lowest-ID `todo`
   is a reviewer task whose requirement still has open implementation/test/fix tasks, it is skipped
   and the next `todo` is taken.
4. **Nothing actionable** → `guild next` prints `none`; the board is caught up.

**Parallel-group batch.** When the task `guild next` returns is a `developer`/`developer-svelte`
ticket carrying a `parallel-group`, the actionable unit is the **batch**, not the single ticket. The
orchestrator expands it with `guild batch TASK-NNN` — all `todo`/`in-progress` dev tickets sharing
that `parallel-group` and `requirement` — dispatches them concurrently, and only advances once all
are `done`. A ticket with no `parallel-group` is a batch of one.

There is no priority sort and no dependency graph. Ordering is creation order (ID order); the
review gate is the only conditional. `parallel-group` is not ordering — it is the architect's
assertion that grouped dev tickets touch disjoint files and may run together (see
`task-lifecycle.md` "Parallel developer batching").

## Rendering the live board view — `guild board`

`guild-status` and `check-in` build the status report by running `guild board`, which scans the
directories — it does **not** read a board file:

1. Lists `tasks/in-progress/` (In Progress), `tasks/todo/` (Backlog), the newest ~20 of
   `tasks/done/` (Recently Completed), and any `tasks/failed/`.
2. Lists `requirements/*/REQ-*.md` grouped by their status dir; computes each REQ's progress as
   `done-tasks / total-tasks` by counting tasks whose `requirement` frontmatter matches (a task's
   doneness is read from its directory).
3. Reads `last-checkin` from `state.yaml`.

The output shape is unchanged from the old board view — only the source changed to a directory scan.

## Stale `in-progress` recovery

On check-in, a task left in `tasks/in-progress/` with an **empty** Work Log was never really
started — move it back with `guild move TASK-NNN todo`. One with Work Log content stays
`in-progress` (resume it).
