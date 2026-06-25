# Guild CLI (`scripts/guild`)

A small, dependency-free Bash CLI that makes the guild's board operations **deterministic**.
Skills and agents shell out to it instead of hand-rolling `find`/`mv`/ID arithmetic.

## Invocation

Inside a plugin skill or agent, the CLI is at `${CLAUDE_PLUGIN_ROOT}/scripts/guild`. The
convention is to bind it once and reuse:

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
"$GUILD" board
```

It operates on `./.guild` by default (override with `GUILD_DIR=/path/to/.guild`).
Requires only Bash 3.2+ and standard Unix tools (`awk`, `sed`, `find`, `sort`) — no Python,
no external dependencies.

## The model: status is a directory

There is **no `status` frontmatter field**. An artifact's status is the subdirectory it lives in:

```
.guild/
  requirements/{todo,in-progress,done}/REQ-NNN.md
  plans/{todo,in-progress,done}/PLAN-NNN.md      # PLAN-NNN/ slice dir sits alongside the file
  tasks/{todo,in-progress,done,failed}/TASK-NNN.md
  docs/    qa/    archive/                         # evergreen, untouched by the CLI
  state.yaml                                       # only: last-checkin
```

- **IDs are derived** from the filesystem — the next ID is `max(existing across all status
  dirs + archive) + 1`. There is no counter to maintain or reconcile.
- **The cursor is derived** — the "current" task is simply whatever sits in `tasks/in-progress/`.
- `state.yaml` holds only `last-checkin`.

## Commands

| Command | Purpose |
|---------|---------|
| `guild init [DATE]` | Create the status-dir layout + `state.yaml` (idempotent) |
| `guild new req --title T [--desc D] [--date D]` | Create a requirement stub in `requirements/todo/`; prints `<ID> <path>` |
| `guild new task --title T --agent A --req REQ-NNN [--plan PLAN-NNN] [--plan-slice slug] [--objective O] [--date D]` | Create a task in `tasks/todo/`; prints `<ID> <path>` |
| `guild new plan --title T --req REQ-NNN [--task TASK-NNN] [--date D]` | Create a plan in `plans/todo/` (+ slice dir); prints `<ID> <path>` |
| `guild path <ID>` | Print the file path, searching all statuses then `archive/` |
| `guild read <ID>` | Print the file contents |
| `guild status <ID>` | Print the artifact's status (its directory); `archived` if released |
| `guild slice <PLAN-ID> <slug>` | Print the path to a plan slice wherever the plan lives |
| `guild move <ID> <status>` | Move the artifact (and a plan's slice dir) into a status subdir |
| `guild list <req\|task\|plan> [status]` | List `<ID> <status>` lines, sorted |
| `guild next` | Print the next actionable task `<TASK-ID> <path>`, or `none` |
| `guild next-id <req\|task\|plan>` | Print the next available ID number (`NNN`) |
| `guild board` | Render the live board by scanning the directories |

### `guild next` — the cursor rule

Encodes the orchestrator's "next actionable ticket" logic deterministically:

1. **Resume** — any task in `tasks/in-progress/` (lowest ID first).
2. **Otherwise** — the lowest-ID task in `tasks/todo/`.
3. **Review gate** — a `reviewer` task is skipped unless every *other* task for its requirement
   has left `todo/` and `in-progress/` (the per-REQ N/N gate). The next non-gated `todo` is taken.
4. Prints `none` when nothing is actionable.

## Status transitions (who calls `move`)

The **orchestrator** (the check-in skill) owns every status transition:

- On dispatch: `guild move TASK-NNN in-progress`
- On success: `guild move TASK-NNN done`
- On failure: `guild move TASK-NNN failed`
- On retry:   `guild move TASK-NNN todo`

Sub-agents do **not** move their own task files or manage `state.yaml`. They do their work,
append to the Work Log, and report completion; the orchestrator moves the file. (Agents may use
`guild path`/`guild read`/`guild slice` read-only to locate inputs.)

## Examples

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"

# Seed a requirement + its product-owner task
read REQ _   < <("$GUILD" new req  --title "User Authentication" --desc "Login & signup" --date 2026-06-25)
"$GUILD" new task --title "Gather requirements for $REQ" --agent product-owner --req "$REQ" --date 2026-06-25

# Drive the cursor
read TASK PATH < <("$GUILD" next)          # e.g. TASK-001 .guild/tasks/todo/TASK-001.md
"$GUILD" move "$TASK" in-progress           # dispatch
# ... agent runs ...
"$GUILD" move "$TASK" done                  # complete

"$GUILD" board                              # live status
```
