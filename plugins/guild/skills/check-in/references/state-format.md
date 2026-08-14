# Guild State Format

The guild board is a **Turso database** at `.guild/guild.db`. There is **no `BOARD.md`**, no
ticket file, and no status directory: an artifact's status is a **column**. `last-checkin` is a row
in `guild_state` (there is no `state.yaml`). The "board" is a **live view** rendered on demand from
SQL — never a stored artifact.

**Nothing hands out a writable path.** `guild path` was removed in v5: the only files under
`.guild/export/` are a generated snapshot that `guild export` rewrites wholesale, so anything
edited there is discarded.

All deterministic state operations go through the **guild CLI** at
`${CLAUDE_PLUGIN_ROOT}/scripts/guild` (see `scripts/README.md`). Skills and agents shell out to it
rather than hand-rolling `find`/`mv`/ID arithmetic.

## What is on disk

```
.guild/
  config.yaml         # committed. storage mode; env var NAMES only, never a credential
  journal.ndjson      # committed. append-only change log — `guild rebuild` replays it
  export/REQ-NNN.md   # committed. GENERATED snapshot; `guild export` rewrites it wholesale
  releases/{version}/ # committed. release snapshots COPIED from the export by guild:release
  guild.db            # gitignored. DERIVED state — the board itself
  spool/TASK-NNN.ndjson  # gitignored. agents' un-drained log/finding lines
  spool/rejected/     # COMMITTED. spool lines a drain could not import — the only copy left
  journal.pending     # gitignored. quarantined journal lines — `guild journal recover`
  dashboard.html      # gitignored by default. regenerated wholesale by `guild dashboard`
  backup-*/           # gitignored. pre-rebuild database and pre-compaction journal copies
  docs/               # evergreen researcher knowledge base
  qa/                 # evergreen QA artifacts
  reviews/REQ-NNN.md  # per-requirement review reports
  v4-archive*/        # a v4 board `guild init` moved aside — never parsed, never deleted
```

**`journal.ndjson` is the durable board.** `guild.db` can be deleted at any time and rebuilt from
it. The reverse is not true: lose the journal and the history is gone.

`docs/` and `qa/` are evergreen — never cleared.

## Single source of truth per fact

| Fact | Lives in | Changed by |
|------|----------|------------|
| Task status (`todo`/`in-progress`/`done`/`failed`) | `task.status` | the **orchestrator** via `guild move` |
| Task metadata (title, agent, requirement, plan, plan-slice) | `task` columns | whoever creates the ticket (`guild new task`); title also by `guild retitle` |
| Work log / progress | `work_log` rows | the assigned agent via `guild log`, folded in by `guild spool drain` |
| Review findings | `review_finding` rows | reviewers via `guild finding`, folded in by `guild spool drain` |
| Requirement status (`todo`/`in-progress`/`done`) | `requirement.status` | the orchestrator via `guild move` |
| A requirement's phase (nullable) | `requirement.phase_id` | the orchestrator via `guild req assign REQ-NNN <PHASE-NNN\|none>` |
| Direction — goals and phases | `goal`, `phase` rows | the orchestrator via `guild goal …` / `guild phase …`, on the user's instruction only |
| Defects | `bug` rows | `qa-tester` via `guild bug new`; the orchestrator via `guild bug fix` / `close` |
| Quality areas and their risk | `coverage` rows | `qa-strategist` via `guild coverage set` |
| The inspection clock | `coverage.last_inspected_at` | `qa-tester` via `guild coverage inspect` — nothing else writes it |
| Last check-in date | the `last-checkin` row in `guild_state` | the orchestrator via `guild checkin` |

There is no second copy of any of these. The orchestrator never reconciles two stores. **Status is
never written into a document** — `guild move` is the only way to change it.

There are **no ID counters** and **no `current` cursor**:

- **IDs are derived.** `guild new` computes `MAX(n) + 1` in the same SQL statement that inserts the
  row, so two creates can never collide. `guild next-id <req|task|plan>` reports the same number.
  IDs are zero-padded to 3 digits (`001`…`999`), never reused, and continuous across releases.
- **The cursor is derived.** "What am I working on" is simply whatever task is `in-progress`.
  `guild next` recomputes the next actionable task every cycle; there is nothing to cache.

## The next actionable ticket — `guild next`

The orchestrator never scans by hand; it runs `guild next`, which encodes:

1. **Resume** — any `in-progress` task (lowest ID first). Interrupted work.
2. **Otherwise** — the lowest-ID `todo` task.
3. **Review gate** — a `reviewer` task is *only* actionable when every *other non-reviewer* task
   for its requirement has left `todo` and `in-progress` (the per-REQ N/N gate). If the lowest-ID
   `todo` is a reviewer task whose requirement still has open implementation/test/fix tasks, it is
   skipped and the next `todo` is taken. Other *reviewer* tickets are deliberately ignored by the
   gate: counting them would make two reviewer tickets on one requirement gate each other and
   answer `none` forever.
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

## Rendering the live views — `guild brief` and `guild board`

**`guild brief` is the read surface `check-in` opens with**, and the one the `guild:brief` skill
narrates: one query behind Direction, In Flight, Blocked, Open Bounties, Bugs, Coverage, Since Last
Check-in and Roster Gaps, plus a `Next:` header byte-identical to `guild next`'s answer. It mutates
nothing — no journal line, no `event` row. (`guild:guild-status` is a deprecated alias that loads
`guild:brief`; it does not run `guild board` as a substitute.)

`guild board` is still a real command and still correct — the narrower tasks-and-requirements view.
It is one SQL script and does **not** read a board file:

1. Lists `in-progress` tasks (In Progress), `todo` (Backlog), the newest 20 `done` (Recently
   Completed), and any `failed`.
2. Lists requirements grouped by status; computes each REQ's progress as `done-tasks / total-tasks`
   with a `LEFT JOIN` and a `SUM(CASE ...)`.
3. Reads the `last-checkin` row.

The output shape is unchanged from the v4 board view — only the source changed. It shows tasks and
requirements only: goals, phases, bugs and coverage are in `guild brief` and the dashboard.

`guild dashboard` writes the same state as one self-contained `.guild/dashboard.html` (seven
views, all CSS/JS inline, no server, no network). Also read-only.

## Stale `in-progress` recovery

On check-in, each `in-progress` task is triaged three ways (procedure: check-in skill Step 1.3).
**Run `guild spool drain TASK-NNN` first** — an agent's log lives in a spool file until it is
drained, so an undrained ticket reads as never-started and would be reset:
- **Empty Work Log** → never started → `guild move TASK-NNN todo`.
- **Final Work Log entry reports completion/failure** → the session died before the orchestrator
  recorded it → record the outcome now (materialize follow-ups, then move) without re-dispatching.
- **Otherwise** → stays `in-progress`; it is resumed with the RESUMED-TASK dispatch variant.
