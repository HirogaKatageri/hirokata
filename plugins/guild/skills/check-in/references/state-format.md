# Guild State Format

The guild has **no `BOARD.md`**. State is distributed across the ticket and requirement
files, with a single tiny `state.yaml` holding only the cursor and ID counters. The "board"
is a **live view** rendered on demand by scanning those files — never a stored artifact.

## Single source of truth per fact

| Fact | Lives in | Written by |
|------|----------|------------|
| Task status (`todo`/`in-progress`/`done`/`failed`) | `.guild/tasks/TASK-NNN.md` frontmatter | the assigned agent |
| Task metadata (title, agent, requirement, plan, plan-slice) | `.guild/tasks/TASK-NNN.md` frontmatter | whoever creates the ticket |
| Work log / progress | `.guild/tasks/TASK-NNN.md` Work Log section | the assigned agent |
| Requirement status (`draft`/`in-progress`/`done`) | `.guild/requirements/REQ-NNN.md` frontmatter | product-owner / orchestrator |
| Cursor + ID counters | `.guild/state.yaml` | the orchestrator |

There is no second copy of any of these. The orchestrator never reconciles two stores.

## `.guild/state.yaml`

```yaml
current: TASK-005     # the ticket the orchestrator is presently on (derived cache)
next-task: 6          # next available TASK ID (auto-increment)
next-req: 2           # next available REQ ID (auto-increment)
next-plan: 1          # next available PLAN ID (auto-increment)
last-checkin: 2026-06-23   # ISO date of last check-in (null if never)
```

- **`current`** is a *derived cache*, not a status authority. The orchestrator recomputes
  the next actionable ticket every cycle (see below) and writes it here for visibility. If
  `current` ever disagrees with real ticket state, ticket state wins — just recompute.
  `null` when there is nothing actionable.
- **Counters** auto-increment. When creating an entity: read the counter, use it as the ID,
  increment it. IDs are zero-padded to 3 digits (`001`, `002`, …, `999`). Counters are
  **never reset** except by `clear-board`, and are continuous across releases.

### Empty state template

```yaml
current: null
next-task: 1
next-req: 1
next-plan: 1
last-checkin: null
```

## The next actionable ticket

The orchestrator picks what to run by scanning `.guild/tasks/*.md`:

1. **Resume** — any ticket with `status: in-progress` (lowest ID first). Interrupted work.
2. **Otherwise** — the lowest-ID ticket with `status: todo`.
3. **Gate exception** — a `reviewer` ticket is *only* actionable when every non-tail ticket
   for its requirement is `done` (the per-REQ N/N review gate). If the lowest-ID `todo` is a
   reviewer ticket whose requirement still has open implementation/test/fix tickets, skip it
   and take the next `todo`.
4. **Nothing actionable** → set `current: null`; the board is caught up.

There is no priority sort and no dependency graph. Ordering is creation order (ID order); the
review gate is the only conditional.

## Rendering the live board view

`guild-status` and `check-in` build the status report by scanning files — they do **not** read
a board file:

1. Glob `.guild/tasks/*.md`, read each frontmatter.
2. Group by `status`: In Progress (`in-progress`), Backlog (`todo`), Recently Completed
   (`done`, sort by ID desc, show the last ~20), plus any `failed`.
3. Glob `.guild/requirements/*.md` for the Requirements list; compute progress as
   `done-tickets / total-tickets` for each REQ by counting its tasks.
4. Read `last-checkin` from `state.yaml`.

The output shape is unchanged from the old board view — only the source changed from a parsed
table to a file scan.

## Directory layout

```
.guild/
  state.yaml              # cursor + counters (the only orchestrator state file)
  requirements/REQ-NNN.md # one per requirement
  tasks/TASK-NNN.md       # one per task — owns its own status
  plans/PLAN-NNN.md       # plan overview
  plans/PLAN-NNN/slice-*.md
  docs/                   # evergreen researcher knowledge base
  qa/                     # evergreen QA artifacts
  archive/                # evergreen released requirements
```

`docs/`, `qa/`, and `archive/` are evergreen — never cleared or archived away.
