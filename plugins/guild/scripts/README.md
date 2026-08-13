# Guild CLI (`scripts/guild`)

A small Bash CLI that makes the guild's board operations **deterministic**.
Skills and agents shell out to it instead of hand-rolling SQL, `find`/`mv` or ID arithmetic.

v5 moves storage from a directory of markdown files to a **Turso database**. The read surface
is deliberately unchanged — the same names, the same arguments, the same stdout — and what changed
is where the bytes come from.

**Two things did change on purpose**, because in v4 the *file* was the write surface and there is
no file now:

- **`guild path` is removed.** It named a file agents used to Edit. In v5 only requirements get an
  export file, that file is generated, and `guild export` rebuilds the whole directory on every
  run — so an edit there is silently lost. `new`, `move` and `next` print the **bare ID** instead
  of `<ID> <path>`. Read with `read`/`meta`/`slice`.
- **Agents write through the CLI**, not by editing a document: `guild log` and `guild finding`
  append one line to a per-task spool, and the orchestrator folds them in with
  `guild spool drain`. That is what makes an interrupted task resumable.

## Invocation

Inside a plugin skill or agent, the CLI is at `${CLAUDE_PLUGIN_ROOT}/scripts/guild`. The
convention is to bind it once and reuse:

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
"$GUILD" board
```

It operates on `./.guild` by default (override with `GUILD_DIR=/path/to/.guild`).
Requires Bash 3.2+, standard Unix tools (`awk`, `sed`, `sort`, `mktemp`) and **one Turso
binary** — see below. No Python, no Node, no `jq`.

## Storage: local mode (cloud is gated)

Chosen once, at `guild init`, and recorded in `.guild/config.yaml`.

| Mode | Where the board lives | Binary | Install |
|------|----------------------|--------|---------|
| `local` **(default, the only verified mode)** | `.guild/guild.db` | `tursodb` | `curl --proto '=https' --tlsv1.2 -LsSf https://github.com/tursodatabase/turso/releases/latest/download/turso_cli-installer.sh \| sh` |
| `cloud` | a Turso Cloud database | `turso` | **refused — see below** |

Local mode needs no account, no token and no network. `guild init` checks for `tursodb` and prints
that install line rather than failing with "command not found".

### Cloud mode is REFUSED, deliberately

`guild init --mode cloud` exits with an explanation instead of initializing. This is a gate on an
**unverified** code path, not a missing feature:

- The cloud driver shells out to `turso db shell "$url"` with **no machine-readable output flag**.
  Local mode gets `tursodb -q -m list`, which is pipe-separated with no header — and that is the
  shape *every* parser in this CLI assumes (`[ "$out" = "E" ]`, `'OK|'*`, `awk -F'|'`,
  `index($0,"|")`). `turso db shell` renders a bordered table. Every read would come back "not
  found" and every write would still be journaled as if it had landed.
- `PRAGMA foreign_keys = ON` is prepended in the local branch only, so FK enforcement differs
  between the modes — and `spool_drain`'s "the spool is unlinked only after the SQL succeeds"
  guarantee rests on that enforcement.
- The cloud branch passes the URL in **argv**, world-readable in `ps` on Linux, and libsql URLs
  commonly embed `?authToken=`.
- Nobody has a Turso Cloud account to test against, so fixing it blind would be guessing.

The driver code is left intact; only the entrance refuses. A hand-written `config.yaml` with
`mode: cloud` still reaches it, and `db_exec` prints a warning to stderr when it does. Ungating
means: pass an output-format flag, move the URL out of argv, unify the FK preamble, and verify
against a real cloud database.

`config.yaml` stores the **names of environment variables**, never the values — and that is
enforced, not just documented: `--url-env` / `--token-env` reject anything that is not an
identifier, *before* any file is written, and a rejected value is never echoed back (it may be a
live token):

```yaml
version: 5
db:
  mode: cloud
  url_env: TURSO_DATABASE_URL
  token_env: TURSO_AUTH_TOKEN
```

`config.yaml` is committed; the token never is.

**One round trip per command.** In cloud mode every invocation is a network call, so each
command composes all of its SQL into a single script and runs it once. `guild board` is
one query, not eight. This is a hard rule in the code, not an optimization.

### Free text travels as hex

There are **two SQL escapers and the distinction is load-bearing** (design §2.2.1):

| Helper | For | Mechanism |
|--------|-----|-----------|
| `sql_str` | identifiers, IDs, enums, dates — values from a known-safe alphabet, or values the CLI generated itself | `'...'`, quotes doubled |
| `sql_text` | **all free text** — titles, bodies, objectives, work-log entries, findings, doc bodies, file paths | `CAST(x'<hex>' AS TEXT)` |

`tursodb`'s stdin script splitter ends a statement at a `;` that terminates a **line**, even
inside an open string literal — so a quoted literal carrying a code fragment is torn in half:

```sql
INSERT INTO t VALUES('code:
    const x = 1;        -- the splitter ends the statement HERE
    doThing();
done');
→ × non-terminated literal
```

An *inline* `;` is harmless; it is specifically end-of-line. Requirement bodies and plan slices
routinely contain code, so this fires in ordinary use, and it used to fail **silently** (tursodb
writes the parse error to stdout, where the caller captures it as data). Hex is unambiguous and
always single-line, so the splitter cannot tear it and there is no escaping left to get wrong.
When in doubt, use `sql_text` — it is correct for known-safe values too, just more verbose.

The same principle governs the way out. Free text must never be able to impersonate a
structural token in a line-oriented channel, so the board, `guild list`, `guild batch` and the
frontmatter block **flatten** every free-text expression in SQL (CR deleted, LF to space), and
the export uses a **length-prefixed** header whose lines the reader consumes by count and never
inspects. A value that cannot start a line cannot forge a row, a field, a fence or a file.

## The model: status is a column

There is no status directory and no `status` frontmatter field — status is a column on the
row, and the CLI is the only thing that writes it.

```
.guild/
  config.yaml          # committed — mode + env var NAMES
  journal.ndjson       # committed — append-only change log (see Durability)
  export/REQ-NNN.md    # committed — generated markdown snapshot, output only
  guild.db             # gitignored — local mode only; DERIVED state
  spool/               # gitignored — per-task agent append files
  spool/rejected/      # COMMITTED — spool lines a drain could not import (see below)
  journal.pending      # gitignored — quarantined journal lines (`guild journal recover`)
  backup-*/            # gitignored — pre-rebuild db copies, pre-compaction journal copies
  docs/  qa/  reviews/ # evergreen; recreated by `guild init`
  v4-archive/          # a v4 board that `guild init` moved aside, untouched
```

- **IDs are derived in SQL** — `'TASK-' || printf('%03d', MAX(n) + 1)`, computed in the
  same statement as the insert, so there is no read-then-write race and no counter to
  maintain.
- **The cursor is derived** — the "current" task is whatever row is `in-progress`.
- **`last-checkin`** lives in the `guild_state` table (v4's `state.yaml` is archived), written
  only by `guild checkin`.

### Upgrading from v4

`guild init` on a directory holding a v4 board **moves the whole tree to
`.guild/v4-archive/`** — never deletes, never parses. There is no history import. Two
things carry over, because they are evergreen rather than historical:

- `.guild/docs/*.md` → the `doc` table (the researcher's knowledge base).
- `.guild/qa/` → the `coverage` table (each quality area with its risk level and, where
  the regression manifest names one, its committed spec path). `last_inspected_at` is left
  null, so everything reads as due on day one.

Unfinished v4 work is re-entered by hand through `guild:new-requirement`, reading the
archived plan for the details. `guild migrate` and the old flat-file format are retired.

## Module layout

`scripts/guild` is the dispatcher and nothing else. Every command is a `cmd_*` function in
one of five modules, each of which defines **functions only** — no top-level side effects,
no `set -e` (the dispatcher owns that).

| File | Owns |
|------|------|
| `schema.sql` | The DDL. Idempotent, so re-applying it is a no-op. |
| `lib/db.sh` | The driver: config, `db_exec`/`db_query`, `sql_str` / `sql_text`, JSON escaping, the spool, schema location |
| `lib/journal.sh` | `journal_preflight`, `journal_append`, `journal_recover`, `journal_sync`, `journal_rebuild`, `journal_compact` |
| `lib/artifacts.sh` | `new` / `read` / `meta` / `status` / `move` / `retitle` / `checkin` / `list` / `next` / `batch` / `slice` / `next-id` / `log` / `finding` / `spool drain` |
| `lib/render.sh` | `board`, the markdown export, the JSON dump |
| `lib/init.sh` | `init`, v4 archival, docs/qa carry-over, `rebuild`, `journal` subcommands |

**Portability rule.** The schema and every query must run on *both* engines — TursoDB
(local) and libSQL (cloud). `STRICT` tables, `RETURNING`, WAL, `PRAGMA foreign_keys` and
JSON functions are fair game. FTS5, `WITH RECURSIVE`, generated columns and the
`lag`/`lead`/`ntile`/`percent_rank`/`cume_dist` window functions are not — verified failing on
TursoDB 0.7.2. Dependency queries join on **direct** predecessors; they never recurse.
`test-guild.sh` enforces this statically, over `schema.sql` and over the SQL embedded in `lib/`.

**The output-channel rule.** `-m list` output is pipe-separated, and titles, bodies and work-log
entries are free text that can contain pipes **and newlines**. A value must therefore never be able
to impersonate a structural token — this was two live injections, not a theory (a task titled
`evil\n3   TASK-999: X` fabricated a board row; a body carrying an export marker created a phantom
`REQ-666.md` and truncated the real file). It is fixed at the source, per surface: the board wraps
every free-text expression in `replace()` so a row is always exactly one line; the export emits a
**length-prefixed** header and awk consumes that many lines by count, never by inspection; the
journal, the spool and the JSON dump go through `json_object()`, which escapes newlines. Smarter
regexes are not an acceptable fix here.

## Commands

| Command | Purpose |
|---------|---------|
| `guild init [--mode local] [--url-env N] [--token-env N] [--yes] [DATE]` | Create `config.yaml`, schema, journal, `spool/`, `export/`, `docs/`, `qa/`, `reviews/`; archive a v4 board; carry over `docs/` + `qa/`. Idempotent and resumable. `--mode cloud` is refused |
| `guild new req --title T [--desc D \| --body B] [--date D]` | Create a requirement; prints the ID |
| `guild new task --title T --agent A --req REQ-NNN [--plan PLAN-NNN] [--plan-slice slug] [--parallel-group LABEL] [--objective O \| --body B] [--date D]` | Create a task; prints the ID |
| `guild new plan --title T --req REQ-NNN [--desc D \| --body B] [--task TASK-NNN] [--date D]` | Create a plan; prints the ID |
| `guild read <ID>` | Render the artifact as markdown, from the database |
| `guild meta <ID> [field]` | Print the frontmatter block (or one field) — cheaper than `read` |
| `guild status <ID>` | Print the artifact's status |
| `guild slice <PLAN-ID> <slug>` | Print a plan slice's body |
| `guild next-id <req\|task\|plan>` | Print the next available ID number (`NNN`) |
| `guild move <ID> <status>` | Set status to `todo`\|`in-progress`\|`done`\[\|`failed`\]; prints the ID |
| `guild retitle <ID> "New title"` | Change the title (v4 edited the file's frontmatter); fixes up the body's `# ` heading when it still matches |
| `guild checkin [YYYY-MM-DD]` | Record the check-in date — the **only** writer of `last-checkin` |
| `guild log <TASK-ID> --agent A --entry "…"` | **Agent write.** Append one work-log entry to the task's spool |
| `guild finding <TASK-ID> --reviewer R --severity critical\|major\|minor\|nit --summary S [--detail D] [--file F] [--line N]` | **Agent write.** Append one review finding to the task's spool |
| `guild spool drain <TASK-ID>` | **Orchestrator.** Fold a task's spool into the database and journal what landed |
| `guild list <req\|task\|plan> [status]` | List `<ID> <status>` lines, sorted; task lines add `<agent> <requirement>` columns for awk filtering |
| `guild next` | Print the next actionable `<TASK-ID>`, or `none` |
| `guild batch <TASK-ID>` | Print all `todo`/`in-progress` task IDs sharing the task's `parallel-group` and `requirement`; a task with no group is a batch of one |
| `guild board` | Render the live board |
| `guild export [--json]` | Regenerate `.guild/export/*.md`, or dump board state as JSON |
| `guild rebuild` | Replay `journal.ndjson` into a fresh database |
| `guild journal compact [--force]` | Snapshot current state as a new baseline journal |
| `guild journal recover` | Fold `.guild/journal.pending` back into the journal |
| `guild journal sync [table…]` | Journal un-journaled `work_log` / `review_finding` / `event` rows |

Environment: `GUILD_DIR` (guild root, default `.guild`), `GUILD_ACTOR` (who mutations are
attributed to, default `orchestrator`), `GUILD_SCHEMA` (override the path to `schema.sql`),
`GUILD_ASSUME_YES` (skip the v4 archival prompt).

### There is no `guild path`

Removed, not renamed — and `guild path` still exits 1 with a message naming its replacements,
because thirteen v4 call sites used to **Edit** the file it returned.

In v4 the path *was* the storage, so resolving a path handed an agent something it could write. In
v5 only requirements get an export file, that file is generated output, and `export_all` rebuilds
the whole `.guild/export/` tree on every run — so anything written there is discarded on the next
export, silently. For `TASK-*` and `PLAN-*` the file never existed at all.

| You want to… | v4 | v5 |
|---|---|---|
| read a ticket | `cat "$(guild path TASK-1)"` | `guild read TASK-1` |
| read one field | `fm "$(guild path TASK-1)" agent` | `guild meta TASK-1 agent` |
| read a plan slice | `cat "$(guild slice P-1 auth)"` | `guild slice PLAN-1 auth` |
| append to the Work Log | Edit the ticket file | `guild log TASK-1 --agent developer --entry '…'` |
| record a review finding | Edit the ticket file | `guild finding TASK-1 --reviewer r --severity major --summary '…'` |
| write a requirement/plan document | Edit the file | `guild new req\|plan --body "$(cat <<'DOC' … DOC)"` at creation |
| rename a ticket | Edit the `title:` line | `guild retitle TASK-1 'New title'` |
| stamp the check-in | Edit `state.yaml` | `guild checkin 2026-08-13` |

**Authoring a document.** `--desc` / `--objective` fill one section of the created template;
`--body` replaces it outright and is how the product-owner and the architect write their documents
now. `--body` refuses a `## Work Log` or `## Follow-up Tasks` heading — those are *rendered* from
`work_log` rows, so storing them would render them twice and would let a document impersonate the
orchestrator's own input.

**Still missing (pending a later stage), stated plainly so nothing pretends otherwise:**

- **No writer for `plan_slice`.** `guild slice` reads one; nothing creates one. The architect puts
  each slice brief in its developer ticket's `--objective` instead.
- **No body writer after creation.** A document is written once, by `guild new … --body`.
- **No `guild clear` / `guild delete` / `guild archive`.** `guild:clear-board` refuses rather than
  no-op'ing, and `guild:release` snapshots the export instead of moving files.

### The agent write path (`log` / `finding` / `spool drain`)

Agents never open a database connection. In local mode every CLI invocation is its own `tursodb`
process and multi-process WAL is an unstable opt-in, so seven concurrent agents writing rows is
exactly the case that does not work.

So `guild log` and `guild finding` **append one NDJSON line to `.guild/spool/<TASK-ID>.ndjson`** —
a plain O_APPEND write, no contention, no connection. The orchestrator later runs
`guild spool drain <TASK-ID>` as the single writer; that is where the `work_log` / `review_finding`
rows and their journal lines appear.

```bash
# agent, mid-task
"$GUILD" log TASK-014 --agent developer --entry "Implemented token refresh in src/auth.ts"

# orchestrator, on completion — ALWAYS before reading the ticket back
"$GUILD" spool drain TASK-014
"$GUILD" read TASK-014          # the Work Log is now populated
```

**Draining is not optional.** An undrained ticket renders an empty `## Work Log`, and check-in's
triage rule ("empty Work Log → never started → move it back to `todo`") would then reset every
resumed task, forever.

Nothing is dropped silently: a spool line that is not valid JSON, or whose `kind` is unrecognized,
is copied verbatim to `.guild/spool/rejected/<TASK-ID>.ndjson` and reported on stderr *before* the
spool is unlinked. An entry is either in the database or in the rejects file — never neither. That
file is deliberately **re-included** by `.gitignore` (`spool/*` plus `!spool/rejected/`): it is the
only surviving copy of those entries, and ignoring it would have made "nothing was discarded" true
only until the worktree was thrown away.

### `guild next` — the cursor rule

Unchanged from v4, now expressed as one query:

1. **Resume** — any task that is `in-progress` (lowest ID first).
2. **Otherwise** — the lowest-ID `todo` task.
3. **Review gate** — a task whose agent is exactly `reviewer` is skipped unless every
   *other non-reviewer* task for its requirement has left `todo` and `in-progress` (the per-REQ
   N/N gate). The next non-gated `todo` is taken. Other reviewers are excluded from the gate on
   purpose: v4 counted them, so two `reviewer` tickets on one requirement gated each other and
   `guild next` answered `none` forever. With the one reviewer ticket per requirement the skills
   actually file, the behavior is identical to v4.
4. Prints `none` when nothing is actionable.

## Status transitions (who calls `move`)

Carried over from v4 unchanged, and now load-bearing rather than stylistic — it is what
makes concurrent agents safe against a single writer.

The **orchestrator** (the check-in skill) owns every status transition:

- On dispatch: `guild move TASK-NNN in-progress`
- On success: `guild move TASK-NNN done`
- On failure: `guild move TASK-NNN failed`
- On retry:   `guild move TASK-NNN todo`

Sub-agents do **not** move their own work and do **not** write to the database. They do their
work, report with `guild log` / `guild finding`, and let the orchestrator drain the spool and move
the row. (Agents read inputs with `guild read` / `guild meta` / `guild slice`.)

## Durability

The database is derived state. Two committed artifacts buy back what a file board gave for
free — git-reviewable history and recovery from a lost database.

**`journal.ndjson`** — append-only, one line per mutation, recording the *resulting row
state* rather than the command. A change log replays across CLI versions; a command log
diverges the moment command semantics change.

```json
{"seq":3,"ts":"2026-08-13T09:14:02Z","actor":"orchestrator","op":"upsert","table":"task","row":{"id":"TASK-014","status":"done"}}
```

- `guild rebuild` replays it into a fresh database (the old one is moved to
  `.guild/backup-<timestamp>/`, never deleted — the directory name is claimed with `mkdir`, so two
  rebuilds in the same second cannot overwrite each other's copy).
- `guild journal compact` snapshots current state as a new baseline. It **refuses to lose a row**:
  every `(table, identity)` pair the existing journal still implies must be present in the
  candidate, and the ones that are not are named in the refusal. It is an identity comparison, not
  a row count — counts compare different universes (the database holds `event` and seed rows
  nothing journals at write time) and a real loss hides inside that slack. `--force` overrides it.
  Without the guard, `clone → guild init → guild journal compact` writes a two-line baseline over
  the entire project history, because `guild.db` is gitignored and therefore empty on a fresh
  clone. On the path that installs a new baseline the previous journal is copied into `backup-*/`
  first, and a failed copy aborts the compaction rather than proceeding with an empty backup; a
  *refused* compaction claims no backup directory at all and leaves its candidate at the single
  fixed path `.guild/backup-rejected/`, so repeated refusals cannot litter the guild root.
- `guild journal recover` folds `.guild/journal.pending` back in (see below).
- Being NDJSON, it diffs line by line in a PR.

**A mutation is never silently lost.** Callers write to the database first and journal second, so
the window that matters is "committed, not yet journaled" — and `journal.ndjson` is committed to
git, which makes a merge conflict in it a *routine* event. Three mechanisms close it:

1. **`journal_preflight`** runs *before* the SQL in every mutating command. An unwritable or
   conflict-marked journal becomes a refusal that says plainly that **nothing was written**, rather
   than a board change the next `guild rebuild` silently undoes.
2. **`journal.pending`** catches an append that fails anyway: the line is quarantined, the failure
   is reported loudly, and the next successful mutation (or `guild journal recover`) folds it in.
3. **`journal sync`** reconciles the append-only record tables (`work_log`, `review_finding`,
   `event`) from the database into the journal — on demand, and automatically at the start of
   `guild rebuild`, so the recovery path cannot be the thing that destroys the agent work log.
   The comparison is by row IDENTITY (a surrogate-key row is identified by its immutable
   content, never by its local autoincrement id), so it stays exact against a journal merged
   from another machine. Its one bounded trade: two rows with byte-identical content in the
   same table are one identity, so an indistinguishable duplicate is journaled once.

This is not atomicity. There is no two-phase commit between a SQLite file and a text file. What is
guaranteed is that divergence is prevented, or recorded, or reported — never silent.

**Honest limit:** in cloud mode the journal is a local audit tail. If a second machine
writes to the same cloud database, this machine's journal is incomplete and `guild rebuild`
is not a true recovery path — use Turso's backups or `turso db branch`. The journal is
still a useful activity record there; just not a rebuild guarantee.

**`export/*.md`** — one markdown file per requirement, its plans and tasks inlined,
regenerated by `guild export`. Deterministic: a re-run with no state change produces a
byte-identical tree. This is the PR-reviewable snapshot. It is **output only** — never read
back, never authoritative.

## Examples

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"

# One-time setup (local mode, no account needed)
"$GUILD" init 2026-06-25

# Seed a requirement (the guild:new-requirement skill runs the product-owner +
# architect interview, and THEY create the requirement and tickets directly)
REQ=$("$GUILD" new req --title "User Authentication" --desc "Login & signup")
TASK=$("$GUILD" new task --title "Implement login endpoint" --agent developer --req "$REQ")

# Drive the cursor
TASK=$("$GUILD" next)                        # e.g. TASK-001 — a bare ID, no path
"$GUILD" move "$TASK" in-progress            # dispatch

# ... the agent works, reporting as it goes (no database connection) ...
"$GUILD" log "$TASK" --agent developer --entry "Implemented POST /login in src/routes/login.ts"

# Orchestrator: fold the agent's reports in BEFORE reading the ticket back
"$GUILD" spool drain "$TASK"
"$GUILD" read "$TASK"                        # Work Log is populated
"$GUILD" move "$TASK" done                   # complete

"$GUILD" checkin 2026-06-25                  # stamp the session
"$GUILD" board                               # live status
"$GUILD" export                              # refresh the committed snapshot

# Recovery: the database is derived; the journal is the truth
rm -f .guild/guild.db && "$GUILD" rebuild
```
