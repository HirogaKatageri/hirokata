---
name: clear-board
description: >
  This skill should be used when the user asks to "clear the board", "reset the guild",
  "start fresh", "wipe the board", "clear all tasks", "reset the board", or wants to
  remove all current work from the guild board and start over.
version: 2.0.0
user-invocable: true
---

# Clear Board — Reset the Guild

Reset the guild board to a clean state.

> **In guild v5 this is not possible, and this skill says so instead of pretending.** The board is
> a database and Stage 1 ships no `guild clear` / `guild delete`. The steps below inventory the
> board, then Step 4 explains the situation and offers the options that DO work. Nothing is
> deleted. See Step 4 for why a silent no-op would be the worse outcome.

Bind the guild CLI once and reuse it for all inventory/recreate operations:
```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
```

## Steps

### 1. Check for Guild

Check for `.guild/config.yaml` — that is what marks a v5 guild (there is no `state.yaml`).

If not found:
```
No guild board found. Nothing to clear.
Run /guild:check-in to initialize a new guild.
```
Stop here.

### 2. Inventory the Board

Count items via the CLI — status is a column, so never scan the filesystem:
- Requirements: `"$GUILD" list req`
- Tasks in progress: `"$GUILD" list task in-progress`
- Tasks in backlog: `"$GUILD" list task todo`
- Completed tasks: `"$GUILD" list task done`
- Plans: `"$GUILD" list plan`

Each `list` prints one `<ID> <status>` line per artifact; count the lines.

### 3. Confirm with User

Present the current state and ask for confirmation:

```
Current board state:
  {N} requirement(s)
  {N} task(s) in progress
  {N} task(s) in backlog
  {N} task(s) completed
  {N} plan(s)

Heads up: guild v5 has no delete command, so I cannot actually clear this.
Shall I show you the options that do work? (yes / no)
```

**Do not promise deletion here.** The v4 wording ("This will permanently delete all requirements,
tasks, and plans") is what made the old no-op dangerous: the user consented to destruction, nothing
happened, and the skill reported success.

If the board is already empty (all counts are 0):
```
The guild board is already empty — nothing to clear.
```
Stop here.

**If "no"** or anything other than an explicit confirmation: Stop without making any changes.

**If "yes"**: Proceed to step 4.

### 4. Clear the Board — NOT AVAILABLE IN v5

> **STOP. There is no way to clear the board in v5, and this skill must not pretend otherwise.**
>
> v4 stored the board as files, so clearing it was `rm -rf .guild/requirements/* ...`. In v5 the
> board is a database and those directories do not exist: that `rm` matches nothing, `guild init`
> is idempotent and inserts nothing, and the user — who was just told "this will permanently
> delete all requirements, tasks, and plans" and typed yes — would be left with an untouched board
> and a success message. Silently doing nothing after a destructive confirmation is worse than
> refusing.
>
> Stage 1 ships no `guild clear` and no `guild delete`. Adding one is pending a later stage.

Tell the user exactly this, and stop:

```
I can't clear the board — the guild v5 CLI has no delete command yet.

The board is a database now (.guild/guild.db), and it is rebuilt from
.guild/journal.ndjson, which is committed to git. Nothing was changed.

Your options today:
  1. Leave it — completed requirements sit at `done` and don't block anything;
     `guild next` only ever looks at open tasks.
  2. Move open work out of the way instead:
       guild move TASK-NNN failed     (user-adjudicated; stops gating the review)
  3. Start a genuinely fresh board in a new directory:
       GUILD_DIR=.guild-next guild init {today's date}
     The old one stays intact, in git, for as long as you want it.

A real `guild clear` is pending a later stage.
```

Do NOT run `rm -rf` against `.guild/`, and do NOT delete `.guild/guild.db` or
`.guild/journal.ndjson`. The journal is the only record of the board's history that git carries;
deleting it is unrecoverable, and deleting the database alone just means the next command has to
`guild rebuild`.

## Rules

- **Never claim to have cleared anything** — Step 4 refuses; there is no delete command in v5.
- **Never `rm -rf` inside `.guild/`** — `journal.ndjson` is the only board history git carries and
  its loss is unrecoverable; `guild.db` is derived, but deleting it just forces a `guild rebuild`.
- **Never clear `.guild/docs/` or `.guild/qa/`** — the knowledge base and the QA discipline's
  artifacts are evergreen and survive everything.
- **A fresh board is a fresh `GUILD_DIR`** — `GUILD_DIR=.guild-next guild init {today}` gives the
  user a genuinely empty board without destroying the old one.
- **No counters to reset** — IDs are derived in SQL as `MAX(n) + 1` and are never reused.
