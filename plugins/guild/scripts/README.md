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
one of the modules below, each of which defines **functions only** — no top-level side effects,
no `set -e` (the dispatcher owns that).

| File | Owns |
|------|------|
| `schema.sql` | The DDL. Idempotent, so re-applying it is a no-op. |
| `lib/db.sh` | The driver: config, `db_exec`/`db_query`, `sql_str` / `sql_text`, JSON escaping, the spool, schema location |
| `lib/journal.sh` | `journal_preflight`, `journal_append`, `journal_recover`, `journal_sync`, `journal_rebuild`, `journal_compact` |
| `lib/artifacts.sh` | `new` / `read` / `meta` / `status` / `move` / `retitle` / `checkin` / `list` / `next` / `batch` / `slice` / `next-id` / `log` / `finding` / `spool drain` — **and the shared primitives every module reuses**: the row-projection registry (`_art_json_row`), the create/update protocol runners, the `--date` rule, the neutralizer |
| `lib/render.sh` | `board`, the markdown export, the JSON dump — **and the flattening/YAML/length-prefix helpers** the whole CLI escapes with |
| `lib/direction.sh` | `goal`, `phase`, `req assign`: the layer above requirements |
| `lib/records.sh` | `bug`, `doc`: defects and the evergreen knowledge base |
| `lib/quality.sh` | `coverage`: the quality areas the QA discipline maps, and the inspection clock that makes "what is due" a query |
| `lib/brief.sh` | `brief`: the structured briefing, text and JSON |
| `lib/dashboard.sh` + `dashboard.tmpl.html` | `dashboard`: the six-view self-contained HTML page and the data it inlines |
| `lib/roster.sh` | `sync-agents`, `match`, `bounties`, `capability-request(s)`: the roster, the deterministic matcher and recruiting |
| `lib/init.sh` | `init`, v4 archival, docs/qa carry-over, roster seeding, `rebuild`, `journal` subcommands |

**One answer per problem, and it lives in the module that owns it.** Stage 2 added four
modules written independently, and the reconciliation that followed is a rule, not a
one-off: there is exactly one row-projection registry (`_art_json_row`, which every
journaled table is a case of), one create runner and one update runner for the
`OK|…` / `MISS|…` protocol, one neutralizer (`_art_defuse_lines`, called with a different
heading list per document kind), one shell-side flattener (`_render_flat_arg`), one
`H key=<integer>` count transport shared by `brief` and `dashboard`, and one
`${GUILD_ACTOR:-orchestrator}`. A second copy of any of them is the bug, not the
duplication.

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
| `guild init [--mode local] [--url-env N] [--token-env N] [--yes] [DATE]` | Create `config.yaml`, schema, journal, `spool/`, `export/`, `docs/`, `qa/`, `reviews/`; archive a v4 board; carry over `docs/` + `qa/`; **seed the roster** from `agents/*.md`. Idempotent and resumable. `--mode cloud` is refused |
| `guild goal new --title T [--body B] [--priority 1-5] [--date D]` | Create a goal; prints `<GOAL-ID> <title>` |
| `guild goal list [status]` | `<GOAL-ID> <status> <priority> <phases-done>/<total> <title>`, by priority then ID |
| `guild goal show <GOAL-ID>` | The goal, its phases, and their requirements, as markdown |
| `guild goal move <GOAL-ID> <status>` | Set status to `todo`\|`in-progress`\|`done`; prints the ID |
| `guild goal priority <GOAL-ID> <1-5>` | Reprioritize (1 highest); prints the ID |
| `guild phase new --goal GOAL-NNN --title T [--ordinal N] [--date D]` | Create a phase; `--ordinal` is derived as `MAX+1` within the goal when omitted |
| `guild phase list [--goal GOAL-NNN]` | `<PHASE-ID> <GOAL-ID> <ordinal> <status> <reqs-done>/<total> <title>` |
| `guild phase move <PHASE-ID> <status>` | Set status to `todo`\|`in-progress`\|`done`; prints the ID |
| `guild req assign <REQ-NNN> <PHASE-NNN\|none>` | Attach a requirement to a phase, or detach it; prints the REQ ID |
| `guild bug new --title T [--body B] [--repro R] [--severity critical\|major\|minor] [--req REQ-NNN] [--found-by WHO] [--date D]` | File a defect; prints `<BUG-ID> <title>`. `--req` is optional |
| `guild bug list [open\|fixing\|fixed\|wontfix] [--severity S]` | `<BUG-ID> <status> <severity> <req> <title>` (`null` req when unaffiliated) |
| `guild bug show <BUG-ID>` | Render the bug as markdown, with a YAML frontmatter block |
| `guild bug fix <BUG-ID> --task TASK-NNN` | Link the fix task and move the bug to `fixing`; prints the ID |
| `guild bug close <BUG-ID> [--wontfix]` | Close as `fixed`, or as `wontfix`; prints the ID |
| `guild coverage set <area-id> --area T [--risk high\|medium\|low] [--spec PATH] [--notes N]` | Upsert a quality area; prints `<area-id> <area>`. Preserves anything not passed, and **never** `last_inspected_at` |
| `guild coverage inspect <area-id> [--date D]` | Stamp `last_inspected_at` — the only writer of the staleness clock; prints the ID |
| `guild coverage list [--risk R] [--due]` | `<area-id> <risk> <last-inspected\|never> <spec\|none> <area>`; `--due` is `guild brief`'s own predicate |
| `guild coverage show <area-id>` | Render the area as markdown, with a YAML frontmatter block |
| `guild doc put <slug> --title T [--body B \| --file F] [--source S]` | Upsert a knowledge-base document; prints the slug |
| `guild doc get <slug>` | Print the body **verbatim** — byte-exact, so `get > f` / edit / `put --file f` round-trips |
| `guild doc list` | `<slug> <updated> <title>` |
| `guild doc search <query>` | Case-insensitive substring search over title and body (`LIKE`; no FTS5 on TursoDB) |
| `guild new req --title T [--desc D \| --body B] [--date D]` | Create a requirement; prints the ID |
| `guild new task --title T --req REQ-NNN (--agent A \| --needs cap,cap) [--prefers cap,cap] [--plan PLAN-NNN] [--plan-slice slug] [--parallel-group LABEL] [--objective O \| --body B] [--date D]` | Create a task; prints the ID. **One of `--agent` or `--needs` is required**; both together pin a member *and* record what the work needed |
| `guild new plan --title T --req REQ-NNN [--desc D \| --body B] [--task TASK-NNN] [--date D]` | Create a plan; prints the ID |
| `guild read <ID>` | Render the artifact as markdown, from the database |
| `guild meta <ID> [field]` | Print the frontmatter block (or one field) — cheaper than `read` |
| `guild status <ID>` | Print the artifact's status |
| `guild slice <PLAN-ID> <slug>` | Print a plan slice's body |
| `guild next-id <req\|task\|plan>` | Print the next available ID number (`NNN`) |
| `guild move <ID> <status>` | Set status to `todo`\|`in-progress`\|`done`\|`failed`, and for a task also `blocked`; prints the ID. `blocked → done` is the one refused transition |
| `guild sync-agents [--dry-run]` | Scan `agents/*.md` frontmatter into `agent` + `agent_capability`. Idempotent: new members added, removed members **deactivated** (never deleted), capability sets replaced. `$GUILD_AGENTS_DIR` overrides where it looks |
| `guild match <TASK-ID> [--json]` | The ranked eligible members, `<rank> <agent> <preferred-covered>/<total> <capabilities> <source>`. Rank 1 is the dispatch target. Exits 1 naming the missing capabilities when nobody is eligible |
| `guild bounties [--json]` | Open, dependency-satisfied tasks with their matched member — then everything that **cannot** be worked and why (`status-blocked`, `deps:<ids>`, `no-eligible-agent:<caps>`) |
| `guild capability-request <cap> --req REQ-NNN --rationale "…" --proposes NAME [--spec "…"]` | File a roster gap; prints the request ID. Also **admits the capability to the vocabulary**, so a new agent file declaring it will sync |
| `guild capability-requests [--open]` | `<id> <status> <capability> <req> <proposed-agent> <rationale>` |
| `guild retitle <ID> "New title"` | Change the title (v4 edited the file's frontmatter); fixes up the body's `# ` heading when it still matches |
| `guild checkin [YYYY-MM-DD]` | Record the check-in date — the **only** writer of `last-checkin` |
| `guild log <TASK-ID> --agent A --entry "…"` | **Agent write.** Append one work-log entry to the task's spool |
| `guild finding <TASK-ID> --reviewer R --severity critical\|major\|minor\|nit --summary S [--detail D] [--file F] [--line N]` | **Agent write.** Append one review finding to the task's spool |
| `guild spool drain <TASK-ID>` | **Orchestrator.** Fold a task's spool into the database and journal what landed |
| `guild list <req\|task\|plan> [status]` | List `<ID> <status>` lines, sorted; task lines add `<agent> <requirement>` columns for awk filtering |
| `guild next` | Print the next actionable `<TASK-ID>`, or `none` |
| `guild batch <TASK-ID>` | Print all `todo`/`in-progress` task IDs sharing the task's `parallel-group` and `requirement`; a task with no group is a batch of one |
| `guild board` | Render the live board |
| `guild brief [--since YYYY-MM-DD] [--json]` | The structured briefing: direction, in flight, blocked, open bounties, bugs, coverage due, and what moved since the last check-in. Reads only |
| `guild dashboard [--open] [--out PATH] [--json]` | Write a self-contained `.guild/dashboard.html` — roadmap, board, graph, bugs, coverage, activity. No server, no network, works offline |
| `guild export [--json]` | Regenerate `.guild/export/*.md`, or dump board state as JSON |
| `guild rebuild` | Replay `journal.ndjson` into a fresh database |
| `guild journal compact [--force]` | Snapshot current state as a new baseline journal |
| `guild journal recover` | Fold `.guild/journal.pending` back into the journal |
| `guild journal sync [table…]` | Journal un-journaled `work_log` / `review_finding` / `event` rows |

Environment: `GUILD_DIR` (guild root, default `.guild`), `GUILD_ACTOR` (who mutations are
attributed to, default `orchestrator`), `GUILD_SCHEMA` (override the path to `schema.sql`),
`GUILD_AGENTS_DIR` (where `sync-agents` reads agent definitions; defaults to
`$CLAUDE_PLUGIN_ROOT/agents`, then the checkout's own `agents/`), `GUILD_ASSUME_YES` (skip
the v4 archival prompt).

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
- **No body writer after creation.** A requirement, plan or task document is written once, by
  `guild new … --body`. Two Stage 2 records are the exceptions and are re-writable in place:
  `guild doc put` is an upsert, and `guild bug` has `fix` / `close`.
- **No `guild clear` / `guild delete` / `guild archive`.** `guild:clear-board` refuses rather than
  no-op'ing, and `guild:release` snapshots the export instead of moving files.
- **Stage 4–5 tables have no writers yet**, by design (design §13): `graph_node`,
  `graph_edge`, `graph_deviation`, `gate`, `task_dependency`, `inspection`,
  `inspection_coverage`. They exist in `schema.sql` so no stage needs a migration.
  (`coverage` is **not** on this list: it is Stage 2 and has `coverage set` /
  `coverage inspect`. `inspection` is Stage 4's record of an inspection *pass* over several
  areas, which is a different table. The four roster tables — `agent`, `agent_capability`,
  `task_capability`, `capability_request` — came off this list in Stage 3.) `guild brief`
  and `guild dashboard` already read several of the remaining ones: the Blocked section's
  `waiting on` and the dashboard's Graph view are wired and simply empty, which is why the
  Graph view says so rather than drawing a blank chart.
- **Nothing reads `task_dependency` into existence.** `guild bounties` reports `deps:<ids>`
  and `guild brief` reports `waiting on`, both correctly — but no command *creates* a
  dependency, so today every task's dependency set is empty and both clauses are inert.
  The graph writes them in Stage 4.
- **`guild export --json` still dumps Stage 1's tables only** (state, requirements, plans,
  slices, tasks, work log, findings). The dashboard does not read it — `guild dashboard --json`
  is its own document, with goals, phases, bugs, coverage and the activity feed. Two JSON
  surfaces with different scopes, one deliberately frozen as the Stage 1 snapshot.

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

`blocked` never appears here, and it needs no clause to stay out: steps 1 and 2 ask for
`in-progress` and `todo`, and `blocked` is neither. Do not "fix" that by widening the query —
a blocked task is one nobody can take, and handing it out is exactly the move the status
exists to prevent. `guild bounties` is where it shows up, with the reason.

## The roster: capabilities, matching, recruiting

> **Tasks stop naming an agent and start naming a required capability.**

That is the whole of Stage 3, and the payoff is concrete: adding `agents/developer-rust.md`
with the right tags makes it eligible for work with **no skill edits and no chain rewiring**.

### Declaring capability

Agent frontmatter gains two optional fields:

```yaml
---
name: developer-svelte
model: sonnet
capabilities: [implement, frontend, svelte, sveltekit]
serial: false
---
```

`capabilities:` accepts an inline array on one line or a block list of `- item` lines.
`serial: true` marks a member that must never run concurrently (`qa-tester`). A key is a line
at **column 0** — which is what keeps `product-reviewer.md`'s `<example>` block, whose
indented lines read `user:` and `assistant:`, from being parsed as frontmatter.

`capabilities:` is **optional, and that is load-bearing**: a member with none declared is a
real member who simply cannot be reached by the matcher, only by a ticket naming them. That
is exactly what every v4-era agent was, so "no capabilities" means "as before", never
"broken". `guild sync-agents` refuses anything it cannot parse, naming the file — a
mis-parsed roster does not fail, it silently matches the wrong work.

### The vocabulary is closed

```
implement · frontend · backend · svelte · sveltekit
test-planning · test-authoring · e2e · review · security
architecture · business-logic · edge-case · research
qa-planning · qa-execution · requirements
```

Kept small on purpose: "a sprawling vocabulary makes matching mushy", and the failure is
concrete — two agents tagged `e2e` and `end-to-end`, and a matcher that quietly stops
working. `guild sync-agents` **refuses** an agent file declaring a capability outside this
list. The only door in is a `capability_request` (below), which admits its capability as a
side effect, so the sequence is always *file the gap → write the agent file → sync*.

The **task** side is deliberately not enforced: `--needs kotlin` is accepted, matches
nobody, and reports itself as `no-eligible-agent:kotlin` on the bounty board. A typo there
is loud within one dispatch, which beats a second copy of the vocabulary in
`lib/artifacts.sh` that has to be kept in sync forever.

### The matcher (`guild match`)

Deterministic, in the CLI, no model judgment. In rank order:

1. **A pin wins.** If the ticket names an agent (`--agent A`), that member is rank 1, source
   `pin`. The capability-eligible members are still listed below it, so the deviation is
   visible rather than merely obeyed.
2. **Eligible** = active members whose capabilities are a **superset** of the task's
   `required` set (`--needs`).
3. **Ranked** by: preferred capabilities covered **desc** → total capability count **asc**
   (so a specialist beats a generalist) → name **asc** (so ties are stable and the answer is
   reproducible).
4. **Nobody eligible** → exit 1, naming the missing capabilities. That is a roster gap and it
   is loud, not a shrug.

`guild bounties` uses the same fragments — not a second spelling of them — so it can never
offer work `guild next` would refuse, nor name a different member than `guild match`.

### The fallback, which is the whole of backward compatibility

Every board built before Stage 3 has `task.agent = 'developer'` on every row, no
`task_capability` rows at all, and an empty `agent` table.

> **A task with no `task_capability` rows matches its `task.agent`, directly.**

The switch is the **presence** of a capability row, not the emptiness of the required set —
an empty required set is vacuously covered by *every* member, which would match all of them.
So:

| Ticket | `guild match` |
|---|---|
| `--agent A`, no capabilities | exactly one candidate, `A`, source `ticket`. The `agent` table is never consulted, so this works on a guild that never synced and on an agent with no file |
| `--needs …`, no agent | the matcher, in full. `task.agent` is **not** a rescue: a ticket that declared capabilities and covers none of them is a roster gap, which is the point of declaring them |
| both | `A` is rank 1, source `pin`; the eligible members follow |

An existing guild therefore behaves exactly as it does today. Stage 3 is opt-**in**, one
`--needs` at a time.

### `blocked`, and why it is loud

`blocked` is new, and it means **no guild member can take this bounty** — a roster gap, not a
verdict on the work. `failed` is the adjudicated status; `blocked` has never been attempted.
The distinction is what every surface is built on:

- `guild next` does not hand out blocked tasks (it asks for `in-progress` then `todo`).
- **For requirement completion `blocked` counts as open**, like `todo` and unlike `failed`.
  A requirement cannot close over an un-attempted slice, and the review gate keeps waiting.
- It is on **every** surface: its own `Blocked:` section on `guild board`, a `blocked` filter
  on `guild list task`, the `guild brief` Blocked section, the bounty board, and the
  dashboard.
- `guild move <TASK> blocked` is how the orchestrator parks a gap. **`blocked → done` is
  refused** — the one refused transition in the CLI — because marking it done would close a
  requirement over work nobody ever tried. The refusal names three exits: back to `todo`
  (you recruited), to `in-progress` (you are assigning it anyway), or to `failed` (you are
  giving up, on the record).

`guild bounties` reports the *condition* without acting on it: a task can appear as
`blocked / no-eligible-agent` while its stored status is still `todo`. That is the board
saying what it would do, one command before it does it — the orchestrator owns every status
transition, here as everywhere.

### Recruiting (`capability-request`)

A roster gap found at *dispatch* time is already a failure: the plan is approved and a bounty
has nobody to take it. So the architect resolves capabilities **at plan time** and files a
request instead of routing to the nearest generalist:

```console
$ guild capability-request rust --req REQ-012 \
    --rationale 'three plan slices are Rust crates; developer has no Rust idiom guidance' \
    --proposes developer-rust
1
$ guild capability-requests --open
1 open rust REQ-012 developer-rust three plan slices are Rust crates; …
```

One capability is **one** open request, however many requirements need it — a second filing
is refused and points at the first. A request cannot be withdrawn: it is created `open` and
only `guild sync-agents` closes it, by admitting an agent file that declares the capability.

Design §5.4 surfaces this at `gate-plan`. **Gates are Stage 4**, so in Stage 3 there are two
surfaces and no invented gate: `guild:new-requirement`, which is live and asks the user
directly, and **`guild brief`'s Roster Gaps section**, which has existed since Stage 2 and
was unreachable until this command started writing the table.

An unattended shift may never create an agent (§5.4). Nothing here does — the command writes
a row and stops. A human writes the agent file; `sync-agents` admits it.

### When `sync-agents` runs

**Both — at `guild init`, and on demand.** The two answers cover different failures:

- **At init**, because an empty `agent` table makes `guild match` useless on every `--needs`
  ticket. No guild created from Stage 3 onward is born with an empty roster. Design §4 asks
  for it in as many words: *"guild init … check for `turso`; seed the roster"*.
- **On demand**, because the roster is not static. "Adding an agent file is the entire
  process of adding a guild member" is only true if admitting one needs no re-initialization,
  so `guild:check-in` step 1 and `guild:new-requirement` both run it. It is idempotent and
  says *"the roster is already up to date"* when nothing changed.

Two properties keep the init half honest:

- **It cannot fail init.** It runs last, after the schema, state and carry-over are
  committed. A missing `agents/` directory or one malformed frontmatter block prints its
  diagnostic on **stderr** and leaves a working guild; the summary line says
  `roster: not loaded`. (Stderr, not stdout: init's stdout is a `key: value` block, and a
  filesystem path folded into it could forge a field.)
- **It stands down when the journal already carries the roster.** `.guild/guild.db` is
  gitignored, so a fresh clone has the journal and no database; without this guard, `init`
  would re-seed an empty database and append 40 duplicate lines to the journal *on every
  clone*. `guild rebuild` is what belongs in that sequence, and it replays the roster. The
  summary then reads `roster: 0 member(s) — the journal carries it; run 'guild rebuild'`.

**A guild initialized before Stage 3** never runs init again, and needs neither half: every
ticket on it names an agent, so the fallback dispatches all of it, and the first `--needs`
ticket that cannot be placed makes the empty roster loud — `guild match` exits 1 and ends
with *"check the roster is loaded at all: 'guild sync-agents'"*. A silent forever-fallback is
not reachable; it would require a capability ticket, and a capability ticket on an unsynced
board is an error message.

## Status transitions (who calls `move`)

Carried over from v4 unchanged, and now load-bearing rather than stylistic — it is what
makes concurrent agents safe against a single writer.

The **orchestrator** (the check-in skill) owns every status transition:

- On dispatch: `guild move TASK-NNN in-progress`
- On success: `guild move TASK-NNN done`
- On failure: `guild move TASK-NNN failed`
- On retry:   `guild move TASK-NNN todo`
- On a roster gap: `guild move TASK-NNN blocked` — no member can take the bounty. Tasks
  only; `blocked → done` is refused (see *The roster* above)

Sub-agents do **not** move their own work and do **not** write to the database. They do their
work, report with `guild log` / `guild finding`, and let the orchestrator drain the spool and move
the row. (Agents read inputs with `guild read` / `guild meta` / `guild slice`.)

## Direction and records: goals, phases, bugs, coverage, docs

Five tables that shipped in `schema.sql` with Stage 1 and got their writers in Stage 2 —
`goal` and `phase` in `lib/direction.sh`, `bug` and `doc` in `lib/records.sh`, `coverage` in
`lib/quality.sh`. No migration was needed for any of them; the commands and the presentation
are the new part.

### Goals and phases sit *above* requirements

```
goal ──< phase ──< requirement ──< plan ──< plan_slice
```

A **goal** is long-lived intent with a priority (1 highest … 5 lowest). A **phase** is an
ordered stage of one goal; `--ordinal` is derived as `MAX(ordinal) + 1` within that goal
when you omit it, and passing it explicitly is how you insert a phase between two existing
ones. Nothing forces a goal's ordinals to be unique or contiguous — renumbering the rest to
keep them so would be several writes hiding inside one command — and every ordering breaks
ties by ID, deterministically.

```bash
G=$("$GUILD" goal new --title "Ship the visibility stage" --priority 2)   # → GOAL-001 Ship …
"$GUILD" phase new --goal GOAL-001 --title "Foundations"                  # → PHASE-001 …
"$GUILD" phase new --goal GOAL-001 --title "Visibility"                   # → PHASE-002 …
"$GUILD" req assign REQ-003 PHASE-002
"$GUILD" goal show GOAL-001            # the goal, its phases, and their requirements
```

**`requirement.phase_id` is nullable by design and stays that way.** Unaffiliated work is
legal — a bug fix, a chore, anything a user files directly — so there is no
`guild new req --phase`, nothing validates that a requirement *has* a phase, and
`guild req assign REQ-003 none` detaches one again. Without that escape hatch the first
assignment would permanently remove a requirement from the unaffiliated pool, which would
make "unaffiliated work is legal" true only until someone filed it under a goal by mistake.

Goals and phases have their **own** verbs (`guild goal move`, `guild phase move`) rather
than joining `guild move`, whose v4-parity status sets and error text are pinned. Their
status set is `todo | in-progress | done` — deliberately not widened; `blocked`, `waived`
and an "abandoned" goal belong to later stages, and a status the CLI can write but nothing
renders is worse than no status at all. Per design §14, goals and phases **do not gate**:
they organize and prioritize, and the only two gates in v5 are on the requirement.

`guild read GOAL-001`, `guild list goal` and friends do not silently fail — they name the
command that does the job, because two verb families guarantee that mix-up.

### Bugs are rows, not prose

```bash
B=$("$GUILD" bug new --title "Login 500s on refresh" --severity critical \
      --repro "$(cat <<'R'
1. log in
2. wait for the token to expire
3. refresh
R
)" --found-by qa-tester)                       # --req REQ-NNN is OPTIONAL

T=$("$GUILD" new task --title "Fix token refresh" --agent developer --req REQ-003)
"$GUILD" bug fix "$B" --task "$T"              # links the fix task, moves the bug to `fixing`
"$GUILD" bug close "$B"                        # or: --wontfix
```

`--req` is optional **and that is the point**: bugs are found outside a requirement's scope
all the time — during a QA pass, in production, by a reviewer reading unrelated code — and a
tracker that cannot record one until somebody invents a requirement for it is a tracker
people route around.

`wontfix` is a real outcome, not a lesser `fixed`. "We looked, and we are choosing not to"
is the answer a triage pass most needs to record, and collapsing it into `fixed` would make
"what is still actually broken?" unanswerable from the board.

The fix task is **not** created by `bug fix`. The orchestrator files it with
`guild new task` and links it, which keeps the "orchestrator owns every transition" rule
intact.

Both filters on `bug list` are validated, unlike `guild list`'s status: `open | fixing |
fixed | wontfix` and `critical | major | minor` are closed, small vocabularies, so a typo is
a typo and saying so beats printing nothing.

### Coverage is the risk surface and its clock

```bash
"$GUILD" coverage set checkout-flow --area "Checkout & payment" --risk high \
      --spec e2e/checkout.spec.ts --notes "card + wallet paths; 3DS not covered"
"$GUILD" coverage inspect checkout-flow          # ← the ONLY writer of the clock
"$GUILD" coverage list --due                     # what nobody has looked at lately
```

`guild init` seeds this table from a v4 `.guild/qa/` charter, and Stage 2 gave it the two
writers that make it live: the `qa-strategist` maps areas with `coverage set`, and the
`qa-tester` stamps `coverage inspect` on the areas it actually drove.

- **`set` is an upsert keyed on the area id**, and it preserves anything not passed —
  a cadence re-run that retypes an area's risk must not fork a near-duplicate row (which
  would double-count every "due" answer). Both filters are validated against closed
  vocabularies (`high | medium | low`).
- **`set` never touches `last_inspected_at`.** Planning an area is not inspecting it.
  Letting an upsert stamp the clock would make an area nobody has opened in three months
  look freshly inspected because somebody edited its notes — which is the one failure this
  table exists to prevent.
- **`--due` is `guild brief`'s own predicate, called rather than restated**
  (`_brief_coverage_where`): never inspected, or stale past a risk-weighted threshold —
  high after 14 days, medium after 30, low after 90. An unrecognized risk value falls to
  the medium threshold rather than vanishing from the answer.

### Docs are the evergreen knowledge base

Slug-keyed, and load-bearing: `guild init` carries a v4 `.guild/docs/` tree into this table,
it survives releases and board resets, and **the architect reads it when planning**.

```bash
"$GUILD" doc put sveltekit-form-actions --title "SvelteKit form actions" --file notes.md
"$GUILD" doc get sveltekit-form-actions > notes.md    # edit it, then put it back
"$GUILD" doc search "form action"
```

- **`--file` is the real workflow**, and it exists because `--body "$(cat notes.md)"` loses
  every trailing newline to command substitution and mangles anything that looks like a
  flag. The CLI reads the file itself, verbatim.
- **`doc get` round-trips byte for byte.** `-m list` terminates every row with exactly one
  LF, and that byte is the driver's, not the document's — so the read drops exactly one
  byte. Get it wrong and the researcher's `get → edit → put` cycle grows a blank line *per
  cycle, forever*.
- **The body is stored verbatim** — neither flattened nor neutralized. A doc is a whole
  markdown document that legitimately contains `---`, its own front matter and fenced code,
  and the only surface that emits a body is `doc get`, which prints it alone with no
  frontmatter, no headings and no markers. A channel with no structural token cannot be
  forged, so neutralizing here would corrupt real documents to defend against nothing. The
  metadata lives on the columnar surface (`doc list`) instead.
- **`search` is `LIKE`, not a full-text index.** FTS5 does not exist on TursoDB (§3.0), and
  the Tantivy-backed replacement is experimental — an index-backed search would work on the
  cloud engine and fail on the default local one, which is the worst possible split. The
  query's `%` and `_` are escaped so they are literal: a search for `100%` that matched
  every document would be a wrong answer reported as a result, which in a knowledge base is
  exactly where it gets believed.

`doc put` is an **upsert**, so it requires `--body` or `--file`: filing a slug with no body
would overwrite an existing document's contents with nothing. An omitted `--source` on an
update keeps the existing one rather than clearing it.

### Every one of these is journaled, and every one writes an `event`

`guild brief`'s "Since Last Check-in" section and the dashboard's Activity feed are both
built on the `event` table, so a mutation that records no event is invisible to the entire
reason Stage 2 exists. Each command here writes its `event` row **in the same SQL script**
as the mutation — before the `UPDATE`, so the payload can carry both ends of a transition —
and `journal_append`s the resulting row afterwards, exactly as `guild move` has always done.

## The brief

`guild brief` is one query behind eight sections — Direction, In Flight, Blocked, Open
Bounties, Bugs, Coverage, Since Last Check-in, Roster Gaps — plus a header carrying
`Next:` (byte-identical to `guild next`'s answer, by construction: the same predicate is
written once and used by both) and a `Summary:` line composed entirely from `COUNT()`
results. `--json` emits the same state as a document; `--since YYYY-MM-DD` overrides the
cutoff, which otherwise comes from `guild_state.last-checkin`.

**It mutates nothing** — no journal line, no `event` row. That is not an oversight of the
"journal every mutation" rule: reading the board is not a change to it, and a brief that
logged itself would pollute the very feed its activity section reads. `guild checkin` is
the one writer that moves the cutoff.

A section with no rows is **not printed**. An absent section is good news stated by its
absence; eight `(none)` blocks are a wall, not a briefing. An entirely empty guild gets a
short "nothing is on the board yet" with the three next steps, composed from the counts
rather than from a queried string.

Free text is **clipped** with an ellipsis in both modes — the harness proves a 500 KB
requirement body round-trips, and one such title would otherwise be the whole document. The
byte-exact value is one round trip away in `guild meta <ID> title`.

The text surface puts one fact per line (`M since=…`, `H bugs_open=3`) rather than
`key=v key=v` on a shared line. That is `_render_col`'s finding one surface over:
flattening turns a newline into a *space*, so on a space-delimited surface the injection
just moves one field right — `--since 'x source=arg next=TASK-999'` overwrote two other
fields, and a benign two-word value silently truncated itself. Removing the shared boundary
is the fix; with one fact per line the only structural token is `key=` at the start of a
line, and a flattened value can never begin one.

## The dashboard

`guild dashboard` writes `.guild/dashboard.html`: one file, all CSS and JS inline, the board
data inlined as JSON. No server, no build step, no network — it works offline and from
`file://`. `--open` hands it to `open` / `xdg-open` and **never fails the command** when
neither exists. `--json` prints the inlined document and writes nothing.

Seven views (design §9): **Roadmap** (goals → phases → requirements, with live progress),
**Board** (tasks by status, coloured by priority), **Graph** (the execution graph — Stage 4
fills `graph_node`/`graph_edge`, so until then this view says so rather than drawing an
empty chart), **Bugs**, **Findings** ("what did reviewers flag that we never fixed?" —
grouped by severity, unresolved first, with the resolved ones one filter away),
**Coverage** ("what has nobody looked at in a month?") and **Activity** (the `event` feed).

Every summary tile is an anchor to the view behind it, and that is a rule rather than a
decoration: a headline number with no list under it names nobody, which is exactly the v4
failure mode `review_finding` was made a table to end. The href is a same-document fragment
built from a fixed literal — the page still fetches nothing.

**Inlining data into HTML is an injection channel, and the structural token is `<`.** It is
the one byte that can end the `<script type="application/json">` element the data sits in —
and `</script>` is a perfectly legal JSON *string*, so a JSON encoder alone is not a defense.
Three layers, each sufficient alone:

1. every row is emitted by the engine's `json_object()`, which escapes quotes, backslashes,
   newlines and control characters;
2. every `<`, `>` and `&` in the finished document is then rewritten as `<`, `>`
   and `&`. This is lossless because **none of those bytes appears in a JSON structural
   token**, so every occurrence is necessarily inside a string — and the emitted document
   therefore contains no `<` byte at all, which is what makes "cannot close the element" a
   property rather than a hope;
3. the page renders every value with `textContent`. `innerHTML`, `insertAdjacentHTML`,
   `document.write`, `eval` and `new Function` appear nowhere in the template, and the
   harness greps the generated file to keep it that way.

**The output is deterministic** — the same state produces byte-identical bytes, so the file
diffs cleanly if it is committed (`init` gitignores it by default). Nothing embeds a wall
clock: the file carries only stored timestamps, and every "3 days ago" is computed in the
browser at view time. `dashboard.tmpl.html` is a generated-page template with exactly one
`@@GUILD_DASHBOARD_DATA@@` line; `$GUILD_DASHBOARD_TEMPLATE` overrides its location.

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
"$GUILD" brief                               # the narrated read: direction, blockers, what moved
"$GUILD" dashboard --open                    # the same, as one offline HTML page
"$GUILD" export                              # refresh the committed snapshot

# Recovery: the database is derived; the journal is the truth
rm -f .guild/guild.db && "$GUILD" rebuild
```

The roster, end to end — a ticket that names a capability, a gap, and the recruitment that
closes it:

```bash
# init already seeded the roster; this re-reads it after any agents/*.md change
"$GUILD" sync-agents                         # idempotent, quiet when nothing changed

# A ticket that describes the WORK instead of naming a member
T=$("$GUILD" new task --title "Token refresh UI" --req REQ-001 \
      --needs implement,frontend --prefers svelte)
"$GUILD" match "$T"                          # 1 developer-svelte 1/1 4 capability
"$GUILD" bounties                            # who can take what, and why not

# A capability nobody has: match exits 1, so the gap is impossible to miss
T2=$("$GUILD" new task --title "Port the codec" --req REQ-001 --needs implement,rust)
"$GUILD" match "$T2" || "$GUILD" move "$T2" blocked

# Recruit for it. This also admits `rust` to the vocabulary, so the agent file can declare it
"$GUILD" capability-request rust --req REQ-001 \
  --rationale 'three plan slices are Rust crates' --proposes developer-rust
"$GUILD" brief                               # the gap is now in "Roster Gaps"

# ... a human writes agents/developer-rust.md with `capabilities: [implement, rust]` ...
"$GUILD" sync-agents                         # admits it, and closes the request
"$GUILD" move "$T2" todo                     # the bounty is claimable again
```
