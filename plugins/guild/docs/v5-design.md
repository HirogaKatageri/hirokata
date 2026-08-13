# Guild v5 — Design Document

**Status:** Proposal, for review
**Author:** drafted with Claude, 2026-08-13
**Supersedes:** guild v4.0.0 (directory-encoded board, hardcoded agent chain)
**Breaking:** yes — v5.0.0

---

## 1. What v5 is

v4 is a **pipeline**: a fixed chain (developer → test-planner → test-writer → 4 reviewers)
walking a queue of markdown files whose status is the directory they sit in.

v5 is a **guild**: a roster of agents with declared capabilities, a database of goals,
priorities and open bounties, and an execution graph the architect composes per requirement
from a standard template. The guild master (you) approves at gates; the orchestrator compiles
each gate-free segment into a workflow and runs it.

Four things change:

| # | Change | Why |
|---|--------|-----|
| 1 | Turso database replaces the file board as source of truth | Queryable state: goals, phases, requirements, tasks, bugs, docs, findings, events |
| 2 | A self-contained HTML dashboard renders the project | See the whole project at a glance, not by reading directories |
| 3 | `guild:brief` reads and narrates current project state | One command, one briefing, from real queries |
| 4 | Architect emits an execution graph; orchestrator compiles it to a workflow | Work adapts to the requirement instead of running one hardcoded chain |
| 5 | Bounties can be worked **unattended** — run to the next gate, then stop and notify | The guild keeps working while the guild master is away |
| 6 | QA folds into the guild's practice as a **maintenance cycle** on the same machinery | Building and maintaining are one practice, not two systems |

**The guild master approves twice per requirement, and only twice:** once when the plan is
ready (nothing is built before that), and once after implementation and review, to approve
repairs. Everything in between runs continuously — attended or not.

The idea underneath all four, and the one that matters most:

> **Tasks stop naming an agent and start naming a required capability.**

In v4, `--agent developer-svelte` hardcodes the roster into the chain. In v5 a task declares
`needs: [implement, svelte]` and any agent whose capabilities cover it is eligible. Adding
`agents/developer-rust.md` with the right tags makes it immediately eligible for work — no
skill edits, no chain rewiring. The database, the dashboard and the dynamic graph are all in
service of that.

### Non-goals

- Not a server. No daemon, no long-running process (the dashboard is a static file).
- Not multi-user concurrency control. One guild master, one orchestrator writer.
- Not a replacement for git. Code review still happens in PRs.
- Not autonomous agents. "Claiming a bounty" is a deterministic matcher in the CLI, not a
  behavior the orchestrator improvises. Agents do not want things.

### What survives from v4 unchanged

Worth stating, because it bounds the blast radius:

- Human-readable IDs (`REQ-001`, `TASK-014`, `PLAN-003`).
- The `guild` CLI as the single deterministic interface. Skills and agents shell out; they
  never touch storage directly.
- **The orchestrator owns every status transition.** Agents report; they never move their own
  work. This one rule is what makes concurrent agents safe against a single writer.
- Agents read their work with `guild read TASK-014` and get markdown. The rendering moves from
  `cat` to a query, but the agent-facing contract is identical — so the 14 agent definitions
  need only small edits, not rewrites.
- Crash-safe resume, the 4-reviewer fan-out, parallel development, the QA discipline.

---

## 2. Storage

### 2.1 Turso, in two modes

The guild uses **Turso** as its database. Two supported setups, chosen at `guild init`:

**Mode `local`** — a database file inside the project.

```
.guild/guild.db
```

No auth token, no network, no account. **This is the default.**

**Mode `cloud`** — a Turso Cloud database.

```bash
turso auth login
turso db create my-project-guild
turso db show my-project-guild --url      # → libsql://...
turso db tokens create my-project-guild   # → auth token
```

Chosen when you want the board reachable from more than one machine, a hosted dashboard, or
Turso's branching and backups.

Connection settings live in `.guild/config.yaml`, which **stores env var names, never secret
values**:

```yaml
version: 5
db:
  mode: cloud            # local | cloud
  url_env: TURSO_DATABASE_URL
  token_env: TURSO_AUTH_TOKEN
```

For `mode: local` the whole `db` block reduces to `mode: local` and the path is fixed at
`.guild/guild.db`. `config.yaml` is committed; the token never is.

### 2.2 The driver layer

**The two modes need two different binaries.** This came out of the docs research and is not
what I first assumed: `turso db shell` takes a *cloud database name* or an `http://`/libSQL
URL — it has no documented support for a local `file:` path. Local files are the other
binary's job.

| Mode | Binary | Invocation |
|------|--------|-----------|
| `local` | `tursodb` (the TursoDB engine shell) | `tursodb -q -m list .guild/guild.db` |
| `cloud` | `turso` (the Turso Cloud CLI) | `turso db shell "$TURSO_DATABASE_URL" "SQL"` |

So the guild needs one internal function every command goes through:

```bash
# db_exec  — read SQL on stdin, emit rows on stdout
db_exec() {
  case "$GUILD_DB_MODE" in
    local) tursodb -q -m list "$GUILD_DIR/guild.db" ;;
    cloud) turso db shell "$(printenv "$GUILD_DB_URL_ENV")" ;;
  esac
}
```

`tursodb -m list` is documented as "minimal SQLite compatible format" — the parseable one.
`-q` suppresses the startup banner. `turso db shell` is documented to accept SQL on stdin
(`turso db shell mydb < dump.sql`) and as an inline argument.

**Installation** — two different install lines, which `guild init` must print rather than
failing with "command not found":

```bash
# local mode — the tursodb engine shell
curl --proto '=https' --tlsv1.2 -LsSf \
  https://github.com/tursodatabase/turso/releases/latest/download/turso_cli-installer.sh | sh

# cloud mode — the Turso Cloud CLI
brew install tursodatabase/tap/turso        # or: curl -sSfL https://get.tur.so/install.sh | bash
```

Three consequences worth designing around:

1. **One round trip per command.** In cloud mode every shell invocation is a network call.
   Commands must compose all their SQL into a single `db_exec` — `guild board` issues one
   query returning one result set, not eight. A hard rule, not an optimization.
2. **Non-interactive SQL on stdin works — verified.** Executed against `tursodb 0.7.2`:

   ```
   $ printf "CREATE TABLE t(a TEXT, b INT) STRICT;
             INSERT INTO t VALUES('it''s',1);
             SELECT a,b FROM t;" | tursodb -q -m list /tmp/x.db
   it's|1
   ```

   Confirms three things at once: stdin execution, **pipe-separated output** from `-m list`
   (so row parsing splits on `|`), and `''` quote escaping. `db_exec` above is therefore the
   design; the `turso dev --db-file` background-server fallback is not needed and the
   no-daemon non-goal holds.

   Note the parsing consequence: since rows are `|`-separated, any **text field that can itself
   contain a pipe** — titles, work-log entries, review findings — cannot be parsed positionally
   from a naive `SELECT a, b`. Emit such fields last, or `replace()` the separator server-side,
   or select them one at a time. This is a real footgun and the reason `-m list` output should
   never be split with a bare `cut -d'|'` on a query that includes free text.

### 2.2.1 Free text must travel as hex — the statement-splitter trap

Found the hard way, during Stage 1 implementation. **`tursodb`'s stdin script splitter ends a
statement at a `;` that terminates a line, even inside an open string literal:**

```sql
INSERT INTO t VALUES('code:
    const x = 1;        -- ← the splitter ends the statement HERE
    doThing();
done');
→ × non-terminated literal
```

A semicolon *inline* (`'has; semicolon'`) is fine. It is specifically a semicolon at
end-of-line inside a multi-line literal. Since requirement bodies and plan slices routinely
contain code fragments, this fires in **ordinary use**, not just adversarial input — and it
had been failing silently, with the error swallowed and empty stderr.

**The rule: every free-text value crosses into SQL as a hex blob cast to text.**

> **Caveat found later, during implementation review — `CAST(x'…' AS TEXT)` is byte-exact
> only for valid UTF-8.** The two engines diverge on invalid bytes, verified directly:
>
> | input `caf\xe9 \xff\xfe bad` | result |
> |---|---|
> | `tursodb 0.7.2` | `636166`**`EFBFBD`**`20`**`EFBFBDEFBFBD`**`20626164` — replaced with U+FFFD |
> | `sqlite3` | `636166`**`E9`**`20`**`FFFE`**`20626164` — bytes preserved |
>
> So non-UTF-8 input is **silently corrupted** on local mode, and differently on cloud.
> This is a regression in kind from the pre-hex behavior, where tursodb rejected the whole
> stream loudly. Either store free text as BLOB and cast on read, or validate UTF-8 at the
> flag boundary and refuse with a clear message. Do not leave it silent.

```sql
CAST(x'636f64653a0a2020636f6e7374207820...' AS TEXT)
```

Hex is unambiguous and, critically, **always single-line**, so the splitter can never tear it
and there is no escaping to get wrong. Verified round-tripping multi-line code with trailing
semicolons, plus `日本語 🎯 a|b it's "q" \ back;` — byte-exact.

So the CLI has two escapers, and the distinction is load-bearing:

| Helper | For | Mechanism |
|--------|-----|-----------|
| `sql_str` | identifiers, IDs, enums, dates — values from a known-safe alphabet | `'...'` with quotes doubled |
| `sql_text` | **all free text** — titles, bodies, objectives, work-log entries, findings | `CAST(x'…' AS TEXT)` |

**This is the same root cause as every output-side injection** (board section forgery, export
marker forgery, frontmatter field forgery): free text escaping its channel. On the way in, hex
solves it. On the way out, the same principle applies — never interpolate free text into a
structured line format; length-prefix or encode it so a value can never impersonate a
structural token.

### 2.2.2 The output side: one escaper per structural token

Hex fixes the way in. There is no single answer for the way out, because the CLI writes four
different structured formats and **each one has a different structural token**. Getting the
token right is the whole job; an escaper matched to the wrong granularity looks correct and
is not. Every one of these was a live, reproduced injection first.

| Surface | Structural token | Mechanism | Fidelity |
|---|---|---|---|
| `board`, the frontmatter block | **the start of a line** | `_render_flat` — CR deleted, LF → space, in SQL | one line per row, always |
| `list <kind>` | **the field boundary** (awk splits on blanks) | `_render_col` — flattening **plus** every blank → `_` | one row per artifact *and* one field per column |
| `export` | *(none — the body must keep its newlines)* | length-prefixed header; the reader consumes N lines **by count, never by inspection** | byte-exact |
| `export --json` | the JSON string | `json_object()` — the engine escapes | byte-exact |
| a composed body (`--objective`, `--desc`, a title) | **a line `guild read` itself generates** | `_art_defuse_body` — two-space indent on `---`, `## Work Log`, `## Follow-up Tasks` | those three lines shift by two spaces |

Three consequences are design decisions rather than implementation details:

1. **`guild list` is a filter, not a round trip.** `guild help` documents the orchestrator
   filtering it with `awk '$3 == "reviewer" && $4 == "REQ-001"'`, so a *space* in `--agent`
   forges a column exactly as a newline used to forge a row — `--agent 'reviewer REQ-001'` on
   REQ-002 matched that filter. No separator can fix it, since argv admits every byte but NUL;
   the fields are made unable to contain a blank instead. The byte-exact value is one round
   trip away in `guild meta <ID> <field>`, which is not columnar and so is never flattened.
2. **The frontmatter is YAML, and unforgeable is not the same as valid.** Flattening stops a
   title forging an `agent:` line, but `title: "C:\path\new"` is still a YAML *ScannerError*,
   and a literal `\n` in a title was being decoded back into a real newline by the reader —
   undoing the flattening on the far side. So the quoted field is escaped as a proper
   double-quoted scalar and the bare fields are quoted only when they are not already safe
   plain scalars (`GLOB '*[^A-Za-z0-9_.-]*'`), which keeps v4's `agent: developer` /
   `plan: null` / `parallel-group: impl` byte-identical and changes only what used to fail
   to parse.
3. **Every heading `guild read` generates is defused in a composed body — both of them.**
   `## Follow-up Tasks` is read back out of a rendered ticket to decide what work to
   materialize; `## Work Log` looks decorative but `skills/check-in` triages on an *empty*
   one ("never started — move it back to todo"), so a body that plants a non-empty one above
   the real one is writing the orchestrator's input just as directly. Verbatim and unforgeable
   cannot both hold on a line-oriented channel; the CLI chooses unforgeable for every line it
   generates and keeps `guild meta <ID> <field>` as the byte-exact channel.

3. **`tursodb --mcp` exists** — the binary can serve MCP instead of a shell, which would let
   Claude Code query the guild database through MCP tools directly. Tempting, but the CLI must
   work from inside compiled workflows and plain bash, where MCP wiring is not guaranteed.
   Noted as an alternative surface, not the mechanism.

**The SDK driver, and why it is deferred.** The alternative to shelling out per query is a
small Node script using Turso's client library (`@tursodatabase/database` / `@libsql/client`)
instead of the `turso` binary. The one thing that genuinely buys is **embedded replicas**,
which are SDK-only: a local database file kept as a live synced copy of a cloud database, so
reads hit local disk and work offline while writes go to the cloud. It would make cloud mode
feel like local mode. It costs a Node dependency and an `npm install` inside the plugin,
breaking "clone it and it works."

Since **local is the default**, embedded replicas solve a latency problem most projects will
never hit. Deferred — revisit only if cloud mode becomes the common case.

### 2.3 Durability: the journal and the export

You chose DB-as-source-of-truth over a derived index. That is the right call for query power,
and it costs three things a file board gave you for free: git-reviewable history, unmergeable
conflicts, and a corrupt database losing work. Two mechanisms buy them back.

**The journal — `.guild/journal.ndjson`, append-only, committed to git.**

Every mutation appends one line describing the *resulting row state*, not the command:

```json
{"seq":142,"ts":"2026-08-13T09:14:02Z","actor":"orchestrator","op":"upsert","table":"task","row":{"id":"TASK-014","status":"done","...":"..."}}
```

A change log, not a command log — deliberately. Replaying commands means replay diverges the
moment command semantics change between versions. Replaying row states is version-proof.

- `guild rebuild` replays the journal into a fresh database.
- `guild journal compact` snapshots current state as a new baseline and truncates.
- Being NDJSON, it diffs line-by-line in a PR. Your guild history stays reviewable.

**Honest limit:** in `cloud` mode the journal is a local audit tail. If a second machine
writes to the same cloud database, this machine's journal is incomplete and `guild rebuild`
is no longer a true recovery path. Cloud-mode durability comes from Turso's own backups and
`turso db branch`. The journal remains useful there as an activity record — just not as a
rebuild guarantee. Say so in the README so nobody trusts it wrongly.

**The export — `.guild/export/*.md`, generated, committed.**

`guild export` deterministically renders one markdown file per requirement, its plan and its
tasks inlined. Run automatically at the end of every check-in and on release. This is the
PR-reviewable snapshot: a reviewer sees "REQ-007 gained three tasks and a gate" as a normal
markdown diff. It is output only — never read back, never authoritative.

**What git holds, then:** `config.yaml`, `journal.ndjson`, `export/`. What it does not:
`guild.db` (gitignored in local mode; nonexistent in cloud mode).

### 2.4 Concurrency

**The research changed this section.** My first draft had parallel agents calling `guild log`
and `guild finding` directly, relying on WAL to sort it out. That does not hold: in local mode
every CLI invocation is a **separate `tursodb` process** against one file, and TursoDB's
multi-process WAL is an unstable, opt-in feature (`--experimental-multiprocess-wal`, via a
`.tshm` sidecar). Four reviewers and three developers writing concurrently through seven
processes is exactly the case it is not yet ready for.

**The fix: a spool.** Agents never write to the database. They append to a per-task NDJSON
file, which is a plain filesystem append with no cross-process contention:

```
.guild/spool/TASK-014.ndjson
{"ts":"...","kind":"log","agent":"developer","entry":"Implemented token refresh"}
{"ts":"...","kind":"finding","severity":"major","summary":"..."}
```

`guild log` and `guild finding` keep their signatures — they just write to the spool instead
of the database. The **orchestrator drains spools into the database** at each node completion,
as the single writer.

This costs nothing and buys three things:

- **One writer process, always.** The concurrency problem disappears rather than being managed.
- **Crash-safe resume survives.** Agents still record progress *as they go* (v4's property,
  which "have agents report at the end" would have lost) — an interrupted task's spool is right
  there on disk for the next check-in to triage.
- **It works identically in cloud mode**, where per-entry network writes from seven agents
  would have been slow as well as contended.

**`--experimental-multiprocess-wal` stays off** — decided. The spool removes the need for it,
and it is explicitly unstable; opting into an unstable storage flag to solve a problem already
solved by an append-only text file would be a bad trade. Revisit only if the spool proves
insufficient.

Remaining rules, unchanged from v4 and now load-bearing rather than stylistic:

- **All status transitions are orchestrator-only.** Single writer for anything with contention.
- WAL and `PRAGMA busy_timeout = 5000` still set at init — belt and braces for the single
  writer, not a substitute for the spool.

---

## 3. Schema

### 3.0 Portability rule: write to the intersection of both engines

Turso has **two engines**, and the guild's two modes land on different ones by default:
`turso db create my-db` gives the libSQL engine (a SQLite fork), `--tursodb` gives the TursoDB
engine (the Rust rewrite), and local `tursodb` is always the latter. Their SQL support differs.
The schema must therefore target the **intersection**, verified against TursoDB's compatibility
matrix:

**Verified empirically against `tursodb 0.7.2`**, not just read from the docs — every row
below was executed.

**THE TABLE'S RULE: IF THE CODE DEPENDS ON IT, IT HAS A ROW.** An incomplete matrix is worse
than no matrix, because it is read as an allowlist and silently trusted as one. Three review
rounds found constructs in `scripts/lib/*.sh` that were not listed here — including
`CAST(x'…' AS TEXT)`, which §2.2.1 makes the transport for *every free-text value in the
CLI*. So the list below is now the whole of what the code uses, not a highlights reel, and
adding an SQL construct to the CLI means adding its verified row here in the same change.

**Core — the schema and the shape of every query**

| Feature | Result | Verdict |
|---------|--------|---------|
| `STRICT` tables | ✅ Works; `VARCHAR(10)` correctly rejected (`× Parse error: unknown datatype`) | **Use it** |
| `CREATE TABLE IF NOT EXISTS` (re-run) | ✅ Idempotent | Use — `guild init` is re-runnable |
| `REFERENCES` / composite `PRIMARY KEY` / `UNIQUE (a, b)` / `NOT NULL DEFAULT` | ✅ Enforced — a duplicate gives `UNIQUE constraint failed: c.(pid, slug)` | Use — the whole of §3.2 |
| `PRAGMA foreign_keys=ON` | ✅ Enforced — a bad ref gives `FOREIGN KEY constraint failed` | Use |
| `PRAGMA foreign_keys=OFF` | ✅ | Use — `guild rebuild` replays out of dependency order |
| `PRAGMA journal_mode=WAL` | ✅ → `wal` | Use |
| `PRAGMA table_info(t)` | ✅ → `0\|id\|TEXT\|0\|\|1` rows | Use — `journal_sync` reads the live column list |
| `sqlite_master` (+ `name NOT LIKE 'sqlite_%'`) | ✅ → the user tables | Use — `journal compact` enumerates tables |
| Multi-statement script on stdin | ✅ Rows of every statement concatenate, in statement order | **Use it** — this is how one command is one round trip (§2.2) |
| Explicit `BEGIN;` … `COMMIT;` | ✅ | Use — every create is one transaction |

**Writes**

| Feature | Result | Verdict |
|---------|--------|---------|
| `INSERT … RETURNING` | ✅ `INSERT ... RETURNING id` → `X-1` | **Use it** — insert-and-get-ID in one statement |
| `UPDATE … RETURNING` | ✅ → `R\|X-1\|up` | **Use it** — `move` / `retitle` return the mutated row for the journal |
| `INSERT … SELECT … RETURNING` | ✅ → `R\|X-3\|hello` | **Use it** — the create shape of §2.2: the `FROM` clause *is* the referential check |
| `ON CONFLICT DO UPDATE` + `excluded.` | ✅ | Use — the journal replay and `checkin` depend on it |
| `INSERT OR REPLACE` | ✅ Replaces the conflicting row | Use — `journal rebuild` replays each row idempotently |

**Values — the transport and the escapers**

| Feature | Result | Verdict |
|---------|--------|---------|
| `CAST(x'…' AS TEXT)` | ✅ Byte-exact **for valid UTF-8** — `x'e697a5…'` → `日本語 🎯`, `x''` → `''`. ⚠️ **Invalid UTF-8 is replaced with U+FFFD, and libSQL preserves the bytes instead** | **Use it — it is the transport (§2.2.1)**, with the divergence in that section's caveat. The one row on this table that is not unconditionally safe |
| `NULLIF(x, '')` | ✅ → NULL for `''`, the value otherwise | Use — how an omitted optional flag becomes NULL |
| `COALESCE` | ✅ | Use |
| `replace` / `length` / `substr` / `trim` / `lower` / `abs` / `hex` / `instr` | ✅ | Use — `replace()` is the whole output-channel defence (§2.2.1) |
| Deeply nested `replace()` (36 levels, generated) | ✅ → `"C:\\path\\new \"\x07 日"` | Use — the YAML escaper in `lib/render.sh` is one such chain |
| `printf('%03d', n)` / `printf('%012d', n)` | ✅ → `TASK-007`, `000000000042` | Use — the ID derivation in §3.3 and the export's stable sort key |
| `CAST(x AS INTEGER)` | ✅ | Use — `MAX(CAST(substr(id,3) AS INTEGER))` is the next-ID scan |
| `GLOB` with a negated class (`'*[^A-Za-z0-9_.-]*'`) | ✅ `developer`/`TASK-001`/`2026-08-13`/`null` → 0; a space, a `:`, a TAB, non-ASCII → 1 | Use — decides which frontmatter fields need YAML quoting. `-` last in the class is a literal |
| `LIKE` with `%` | ✅ | Use — `sqlite_master` filtering; `doc search` |

**JSON**

| Feature | Result | Verdict |
|---------|--------|---------|
| `json_object(…)` | ✅ Escapes control characters, so one row is always one line | **Use it** — the journal, `export --json` and every `RETURNING` row |
| `json_object(<column>, v)` — a **computed label** | ✅ → `{"X-1":"hello"}` | Use — `export --json` renders `guild_state` as a real object. Fallback if an engine ever rejects it: `json_object('key', key, 'value', value)` |
| `json_extract` | ✅ Returns the JSON value's own type (`'v'`, `7`) | Use — spool drain and journal replay |
| `json_valid` | ✅ → `1` / `0` / NULL for NULL | Use — `CASE WHEN json_valid(x) THEN x END` is what stops a malformed spool line raising |

**Queries**

| Feature | Result | Verdict |
|---------|--------|---------|
| Non-recursive CTE (`WITH x AS ...`) | ✅ | **Use freely** — see the nuance below |
| `LEFT JOIN` + `GROUP BY` + `COUNT` / `SUM(CASE WHEN …)` / `MAX` | ✅ | Use — the board's live `N/M done` counters |
| Compound `UNION ALL` with one trailing `ORDER BY` | ✅ Ordering applies across the whole compound | Use — the export is one ordered compound SELECT |
| `ORDER BY CASE … END` | ✅ | Use — the board's status ordering |
| `NOT EXISTS (…)` correlated subquery | ✅ | Use — `guild next`'s review gate, in place of recursion |
| `LIMIT` | ✅ | Use |

**Not used — verified as unavailable, or deliberately declined**

| Feature | Result | Verdict |
|---------|--------|---------|
| `char(10)` | ✅ Works (→ `0A`) | **Declined.** A literal newline inside a quoted string and `CAST(x'0a' AS TEXT)` already cover it; a third spelling of one idea is a third thing to keep verified |
| `group_concat` | ✅ Works | **Declined.** The work log is emitted as its own statement so one row stays one line |
| **`WITH RECURSIVE`** | ❌ **Fails** | **Avoid** — see the trap below |
| **FTS5** (`CREATE VIRTUAL TABLE ... USING fts5`) | ❌ **Fails.** TursoDB uses a Tantivy-backed `CREATE INDEX ... USING fts` instead, itself experimental | **Avoid.** `doc search` uses `LIKE` |
| Generated columns | 🚧 Virtual only, behind `--experimental-generated-columns` | Avoid |
| Window functions | 🚧 No `lag`, `lead`, `ntile`, `percent_rank`, `cume_dist` | Avoid those five |
| `CREATE INDEX` — incl. `IF NOT EXISTS`, `DESC`, composite | ✅ Verified: `ON e(ts DESC)` and `ON e(a, ts)` both created and visible in `sqlite_master` | **Use it** — `schema.sql` creates four, applied by both `init` and `rebuild` |
| `VIEW` / `TRIGGER`, `AUTOINCREMENT`, `CHECK` constraints | — Not exercised | **Not used by the CLI.** Verify before introducing one |

**The CTE nuance:** plain `WITH x AS (SELECT ...)` works fine — only the `RECURSIVE` variant
fails. Worth stating explicitly so nobody over-corrects and bans all CTEs; the ordinary kind is
useful for keeping the single-round-trip board query readable.

**The `WITH RECURSIVE` trap.** Transitive closure over a dependency graph is the textbook
recursive-CTE query, and `guild segment` is exactly a graph traversal — so this looks fatal at
first glance. It is not: a node is **ready** when all of its *direct* predecessors are `done`,
which is a plain join with no recursion. Readiness propagates one node at a time as the segment
runs, rather than being computed transitively up front. Worth stating explicitly, because the
recursive version is the one you would naturally reach for and it would fail on local mode
only — the worst kind of bug to find late.

### 3.1 The hierarchy

```
goal ──< phase ──< requirement ──< plan ──< plan_slice
                        │              │
                        └──< task >────┘
                              │
                              ├──< work_log
                              ├──< review_finding
                              └──< bug
```

Your four new concepts (goals, phases, bugs, docs) slot in as: goals and phases *above*
requirements, giving long-lived direction; bugs and docs *beside* the hierarchy, referencing
into it.

### 3.2 DDL

```sql
-- ---------- direction ----------
CREATE TABLE goal (
  id          TEXT PRIMARY KEY,           -- GOAL-001
  title       TEXT NOT NULL,
  body        TEXT NOT NULL DEFAULT '',
  status      TEXT NOT NULL DEFAULT 'todo',
  priority    INTEGER NOT NULL DEFAULT 3, -- 1 highest .. 5 lowest
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
) STRICT;

CREATE TABLE phase (
  id          TEXT PRIMARY KEY,           -- PHASE-001
  goal_id     TEXT NOT NULL REFERENCES goal(id),
  title       TEXT NOT NULL,
  ordinal     INTEGER NOT NULL,
  status      TEXT NOT NULL DEFAULT 'todo',
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
) STRICT;

-- ---------- work ----------
CREATE TABLE requirement (
  id          TEXT PRIMARY KEY,           -- REQ-001
  phase_id    TEXT REFERENCES phase(id),  -- nullable: unaffiliated work is legal
  title       TEXT NOT NULL,
  body        TEXT NOT NULL DEFAULT '',   -- the full REQ markdown
  status      TEXT NOT NULL DEFAULT 'todo',
  priority    INTEGER NOT NULL DEFAULT 3,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
) STRICT;

CREATE TABLE plan (
  id             TEXT PRIMARY KEY,        -- PLAN-001
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  title          TEXT NOT NULL,
  body           TEXT NOT NULL DEFAULT '',
  status         TEXT NOT NULL DEFAULT 'todo',
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
) STRICT;

CREATE TABLE plan_slice (
  id        TEXT PRIMARY KEY,             -- PLAN-001/auth-service
  plan_id   TEXT NOT NULL REFERENCES plan(id),
  slug      TEXT NOT NULL,
  title     TEXT NOT NULL,
  body      TEXT NOT NULL DEFAULT '',
  files     TEXT NOT NULL DEFAULT '[]',   -- JSON array: the disjoint-file assertion
  UNIQUE (plan_id, slug)
) STRICT;

CREATE TABLE task (
  id             TEXT PRIMARY KEY,        -- TASK-001
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  plan_slice_id  TEXT REFERENCES plan_slice(id),
  node_key       TEXT,                    -- the graph node that produced it
  title          TEXT NOT NULL,
  objective      TEXT NOT NULL DEFAULT '',
  body           TEXT NOT NULL DEFAULT '',
  status         TEXT NOT NULL DEFAULT 'todo',
                 -- todo | in-progress | done | failed | blocked | waived
  priority       INTEGER NOT NULL DEFAULT 3,
  claimed_by     TEXT REFERENCES agent(name),
  claimed_at     TEXT,
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
) STRICT;

CREATE TABLE task_dependency (
  task_id    TEXT NOT NULL REFERENCES task(id),
  depends_on TEXT NOT NULL REFERENCES task(id),
  PRIMARY KEY (task_id, depends_on)
) STRICT;

-- ---------- the roster ----------
CREATE TABLE agent (
  name        TEXT PRIMARY KEY,           -- 'developer-svelte'
  model       TEXT NOT NULL DEFAULT 'sonnet',
  description TEXT NOT NULL DEFAULT '',
  active      INTEGER NOT NULL DEFAULT 1,
  serial      INTEGER NOT NULL DEFAULT 0  -- 1 = never run concurrently (qa-tester)
) STRICT;

CREATE TABLE agent_capability (
  agent      TEXT NOT NULL REFERENCES agent(name),
  capability TEXT NOT NULL,
  PRIMARY KEY (agent, capability)
) STRICT;

CREATE TABLE task_capability (
  task_id    TEXT NOT NULL REFERENCES task(id),
  capability TEXT NOT NULL,
  required   INTEGER NOT NULL DEFAULT 1,  -- 1 = required, 0 = preferred
  PRIMARY KEY (task_id, capability)
) STRICT;

-- A capability the architect needs but the roster does not have. Raised at plan time,
-- resolved by the guild master creating a new member. See §5.4.
CREATE TABLE capability_request (
  id             INTEGER PRIMARY KEY,
  capability     TEXT NOT NULL,
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  rationale      TEXT NOT NULL,           -- why existing members cannot cover it
  proposed_agent TEXT NOT NULL,           -- suggested name, e.g. 'developer-rust'
  proposed_spec  TEXT NOT NULL DEFAULT '',-- draft role/tools/model for the new agent
  status         TEXT NOT NULL DEFAULT 'open',  -- open | created | declined
  created_at     TEXT NOT NULL
) STRICT;

-- ---------- execution graph ----------
CREATE TABLE graph_node (
  id             TEXT PRIMARY KEY,        -- REQ-001/implement.auth-service
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  node_key       TEXT NOT NULL,           -- 'implement', 'review', 'gate-plan'
  kind           TEXT NOT NULL,           -- 'work' | 'gate'
  task_id        TEXT REFERENCES task(id),
  parallel_group TEXT,
  status         TEXT NOT NULL DEFAULT 'pending',
                 -- pending | ready | running | done | failed | skipped
  UNIQUE (requirement_id, node_key, task_id)
) STRICT;

CREATE TABLE graph_edge (
  from_node TEXT NOT NULL REFERENCES graph_node(id),
  to_node   TEXT NOT NULL REFERENCES graph_node(id),
  PRIMARY KEY (from_node, to_node)
) STRICT;

CREATE TABLE graph_deviation (
  id             INTEGER PRIMARY KEY,
  requirement_id TEXT NOT NULL REFERENCES requirement(id),
  kind           TEXT NOT NULL,           -- add-node | drop-node | reshape | add-gate
  node_key       TEXT NOT NULL,
  reason         TEXT NOT NULL,           -- never empty; enforced by `guild graph validate`
  created_at     TEXT NOT NULL
) STRICT;

CREATE TABLE gate (
  node_id     TEXT PRIMARY KEY REFERENCES graph_node(id),
  prompt      TEXT NOT NULL,
  kind        TEXT NOT NULL DEFAULT 'approve',  -- approve | select-findings
  status      TEXT NOT NULL DEFAULT 'pending',  -- pending | approved | rejected
  decision    TEXT,                             -- free text / JSON of selections
  decided_at  TEXT
) STRICT;

-- ---------- records ----------
CREATE TABLE work_log (
  id         INTEGER PRIMARY KEY,
  task_id    TEXT NOT NULL REFERENCES task(id),
  ts         TEXT NOT NULL,
  agent      TEXT NOT NULL,
  entry      TEXT NOT NULL
) STRICT;

CREATE TABLE review_finding (
  id          INTEGER PRIMARY KEY,
  task_id     TEXT NOT NULL REFERENCES task(id),
  reviewer    TEXT NOT NULL,
  severity    TEXT NOT NULL,             -- critical | major | minor | nit
  summary     TEXT NOT NULL,
  detail      TEXT NOT NULL DEFAULT '',
  file        TEXT, line INTEGER,
  disposition TEXT NOT NULL DEFAULT 'open',  -- open | fixing | fixed | waived
  fix_task_id TEXT REFERENCES task(id),
  created_at  TEXT NOT NULL
) STRICT;

CREATE TABLE bug (
  id             TEXT PRIMARY KEY,        -- BUG-001
  title          TEXT NOT NULL,
  body           TEXT NOT NULL DEFAULT '',
  repro          TEXT NOT NULL DEFAULT '',
  severity       TEXT NOT NULL DEFAULT 'major',
  status         TEXT NOT NULL DEFAULT 'open',  -- open | fixing | fixed | wontfix
  found_by       TEXT,                    -- agent name or 'user'
  requirement_id TEXT REFERENCES requirement(id),
  fix_task_id    TEXT REFERENCES task(id),
  created_at     TEXT NOT NULL,
  updated_at     TEXT NOT NULL
) STRICT;

-- ---------- maintenance (§6.2) ----------
-- What the product is made of, from a quality standpoint. Evergreen: survives releases
-- and board resets. `last_inspected_at` is what makes "what needs inspection" a query
-- rather than a judgment call.
CREATE TABLE coverage (
  id                TEXT PRIMARY KEY,     -- 'checkout-flow'
  area              TEXT NOT NULL,        -- human name
  risk              TEXT NOT NULL DEFAULT 'medium',  -- high | medium | low
  spec_path         TEXT,                 -- committed e2e spec, if one exists
  last_inspected_at TEXT,
  notes             TEXT NOT NULL DEFAULT ''
) STRICT;

-- One turn of the maintenance cycle.
CREATE TABLE inspection (
  id          TEXT PRIMARY KEY,           -- INSP-001
  scope       TEXT NOT NULL,              -- 'whole product' | a coverage area
  trigger     TEXT NOT NULL DEFAULT 'manual',  -- manual only today; the column exists so a
                                          -- cadence can be added later without a migration
  status      TEXT NOT NULL DEFAULT 'todo',
  started_at  TEXT,
  finished_at TEXT
) STRICT;

CREATE TABLE inspection_coverage (
  inspection_id TEXT NOT NULL REFERENCES inspection(id),
  coverage_id   TEXT NOT NULL REFERENCES coverage(id),
  verdict       TEXT,                     -- pass | issues | not-reached
  PRIMARY KEY (inspection_id, coverage_id)
) STRICT;

CREATE TABLE doc (
  slug       TEXT PRIMARY KEY,            -- 'sveltekit-form-actions'
  title      TEXT NOT NULL,
  body       TEXT NOT NULL,
  source     TEXT NOT NULL DEFAULT '',    -- who/what produced it
  updated_at TEXT NOT NULL
) STRICT;

-- ---------- history ----------
CREATE TABLE event (
  id           INTEGER PRIMARY KEY,
  ts           TEXT NOT NULL,
  actor        TEXT NOT NULL,             -- 'orchestrator' | agent name | 'user'
  verb         TEXT NOT NULL,             -- 'dispatched' | 'completed' | 'approved' | ...
  subject_type TEXT NOT NULL,
  subject_id   TEXT NOT NULL,
  payload      TEXT NOT NULL DEFAULT '{}' -- JSON
) STRICT;

CREATE INDEX task_by_req    ON task(requirement_id, status);
CREATE INDEX node_by_req    ON graph_node(requirement_id, status);
CREATE INDEX event_recent   ON event(ts DESC);
CREATE INDEX finding_by_task ON review_finding(task_id, disposition);
```

Two deliberate wins over v4 hiding in there:

- **`review_finding` is a table.** In v4 findings are prose buried in a markdown work log,
  re-parsed by the orchestrator each time. As rows they are countable, filterable by severity,
  and linkable to the fix task that resolved them. "What did reviewers flag that we never
  fixed?" becomes a query.
- **`event` is the thing markdown genuinely cannot express** — an append-only record of who
  did what when, which powers both the dashboard activity feed and the daily brief's "what
  moved since your last check-in".

### 3.3 IDs

Still `PREFIX-NNN`, still derived, now trivially:

```sql
SELECT 'TASK-' || printf('%03d', COALESCE(MAX(CAST(substr(id,6) AS INTEGER)),0)+1) FROM task;
```

Done in the same statement as the insert via `RETURNING`, so there is no read-then-write race.

---

## 4. The CLI

`scripts/guild` stays the only interface. Roughly two-thirds of the v4 surface survives with
identical signatures — a deliberate constraint, so agent definitions need minimal edits.

### Unchanged contracts

| Command | Note |
|---------|------|
| `guild read <ID>` | Renders markdown **from the database**. Agents see no difference. |
| ~~`guild path <ID>`~~ | **REMOVED in implementation.** The draft kept it, returning an export path. That was wrong: `guild export` deletes and rebuilds `.guild/export/` on every run, so an agent that Edited a returned path lost its work silently — and for `TASK-*`/`PLAN-*` the file never existed at all. The command now exits 1 naming its replacements (`read`/`meta`/`slice` to read; `log`/`finding`/`retitle`/`move`/`checkin` to write), and `new`/`move`/`next` print the bare ID. |
| `guild meta <ID> [field]` | Frontmatter-equivalent projection of the row. The block form is flattened and YAML-escaped; the single-field form (`guild meta <ID> title`) is the **byte-exact** channel (§2.2.2). |
| `guild board` | Same rendering, one query behind it. |
| `guild list <kind> [status]` | Same awk-friendly columns — and now genuinely awk-safe: blanks inside a column become `_`, so the field count is fixed (§2.2.2). A **filter**, not a round trip. |
| `guild move <ID> <status>` | Orchestrator-only, unchanged semantics. |
| `guild slice <PLAN> <slug>` | Reads `plan_slice`. |

### New

| Command | Purpose |
|---------|---------|
| `guild init [--mode local\|cloud]` | Create config, schema, journal; check for `turso`; seed the roster |
| `guild goal new / phase new` | Direction above requirements |
| `guild bug new / bug list / bug fix <ID>` | First-class defect tracking |
| `guild doc put <slug> / doc get / doc search <q>` | Knowledge base. `search` uses `LIKE` — no FTS5 on TursoDB (§3.0) |
| `guild sync-agents` | Scan `agents/*.md` frontmatter → `agent` + `agent_capability` |
| `guild match <TASK-ID>` | Ranked eligible agents for a task |
| `guild capability-request <cap> --req R --rationale "..." --proposes NAME` | File a roster gap (architect, §5.4) |
| `guild capability-requests [--open]` | List roster gaps awaiting a decision |
| `guild spool drain <TASK-ID>` | Fold an agent's spool file into the database (orchestrator, §2.4) |
| `guild bounties` | Open, dependency-satisfied tasks with their matched agents |
| `guild graph <REQ> [--explain]` | Render the execution graph; `--explain` shows template vs actual with deviation reasons |
| `guild graph validate <REQ>` | Reject unreasoned deviations and dropped required nodes |
| `guild segment <REQ> [--json]` | The next gate-free run of node batches |
| `guild gate <NODE> --approve\|--reject [--decision X]` | Record a guild-master decision |
| `guild log <TASK> --agent A --entry "..."` | Append a work-log entry (agent-callable; writes to the spool, not the DB) |
| `guild finding <TASK> --reviewer R --severity S --summary "..."` | File a review finding (agent-callable; spooled) |
| `guild event <verb> <type> <id>` | Append to the activity log |
| `guild brief [--since DATE]` | Structured state briefing (feeds `guild:brief`) |
| `guild export [--json]` | Markdown snapshot to `.guild/export/`, or JSON for the dashboard |
| `guild dashboard [--open]` | Build `.guild/dashboard.html` |
| `guild rebuild` / `guild journal compact` | Journal replay and compaction |
| `guild shift [--max-tasks N] [--max-minutes M]` | Work bounties unattended until the next gate (§8) |

### Retired

`guild next` and `guild batch` are replaced by `guild segment` — the graph now decides what is
next and what runs together, rather than a hardcoded cursor rule with a special-cased review
gate. `guild is-legacy` and `guild migrate` are dropped entirely: there is no history import,
only archival at `init` (§11).

---

## 5. Capabilities and bounties

### 5.1 Declaring capability

Agent frontmatter gains one field:

```yaml
---
name: developer-svelte
model: sonnet
capabilities: [implement, frontend, svelte, sveltekit]
serial: false
---
```

`guild sync-agents` scans `agents/*.md` and reconciles the roster. Adding an agent file is the
entire process of adding a guild member.

### 5.2 The matcher

Deterministic, in the CLI, no model judgment:

1. **Eligible** = agents whose capabilities are a superset of the task's `required` set.
2. **Rank** by: count of `preferred` capabilities covered (desc) → total capability count
   (asc, so a specialist beats a generalist) → name (asc, for stable ties).
3. `guild match TASK-014` prints the ranked list; the orchestrator dispatches rank 1.
4. **No eligible agent** → task moves to `blocked` and surfaces at the next check-in as
   "no guild member can take this bounty: needs [rust, embedded]". That is a roster gap, and
   it should be loud.

The architect may still pin a specific agent (`claimed_by` preset) when it genuinely matters.
That is a deviation and needs a reason, like any other.

### 5.3 Seed capability vocabulary

Keep it small; a sprawling vocabulary makes matching mushy.

```
implement · frontend · backend · svelte · sveltekit
test-planning · test-authoring · e2e
review · security · architecture · business-logic · edge-case
research · qa-planning · qa-execution · requirements
```

New capabilities enter this vocabulary through §5.4, not ad hoc — otherwise two agents end up
tagged `e2e` and `end-to-end` and the matcher quietly stops working.

### 5.4 Recruiting: when the guild lacks a capability

A roster gap found at *dispatch* time is already a failure — the plan is approved, work is
underway, and a bounty has nobody to take it. So the architect resolves capabilities **at plan
time**, and when nothing in the roster covers what the plan needs, it does not silently route
to the nearest generalist. It files a `capability_request`:

```
$ guild capability-requests
CAP-REQ 3  rust        REQ-012  proposed: developer-rust
  Rationale: three plan slices are Rust crates; `developer` has no Rust idiom
             guidance and would produce non-idiomatic error handling.
```

This surfaces at `gate-plan`, alongside the plan itself, as part of the same approval:

```
REQ-012 plan is ready for review.

⚠ This plan needs a capability the guild does not have: `rust`
  The architect proposes a new member: developer-rust
  Draft: Sonnet · tools Read/Grep/Glob/Write/Edit/Bash · owns Rust implementation
         slices, follows the plan's crate boundaries

  [ Create the agent ]  [ Assign to `developer` anyway ]  [ Revise the plan ]
```

On **create**, the guild scaffolds `agents/developer-rust.md` from the architect's draft spec
(the `plugin-dev:agent-creator` agent is a natural fit for generating it), you review and edit
the file, then `guild sync-agents` admits it to the roster and the bounty becomes claimable.

Two reasons this is worth the machinery rather than just letting a generalist take the work:

- **The gap becomes visible at the cheapest moment** — while you are already reviewing the
  plan, not three hours into a build.
- **The guild grows its own roster.** Each recruitment is permanent: the next Rust requirement
  finds `developer-rust` already there. The roster accretes toward the shape of your projects.

An unattended shift may **never** create an agent. It records the request and stops at the
gate, like any other decision.

---

## 6. The execution graph

You chose **template + justified deviation**. Here is what that means concretely.

Two templates ship with the plugin: **`standard`** (build a requirement) and **`maintenance`**
(inspect what was built). Both are data, both run on the same machinery, and both end at
`gate-repairs`.

### 6.1 The standard template

`plugins/guild/templates/standard.yaml` — shipped with the plugin, overridable per project at
`.guild/templates/`:

```yaml
name: standard
description: Plan-gated feature chain — approve the plan, then run to completion.
nodes:
  # ---- GATE 1: the only approval before anything is built ----
  - key: gate-plan
    kind: gate
    prompt: "Plan for {requirement} is ready for review. Approve implementation?"
    required: true

  # ---- continuous run: nothing below stops for the guild master ----
  - key: implement
    needs: [implement]
    after: [gate-plan]
    fanout: per-slice          # one node per plan slice
    parallel: by-group         # slices sharing a parallel-group run concurrently
    required: true

  - key: test-plan
    needs: [test-planning]
    after: [implement]

  - key: test-write
    needs: [test-authoring]
    after: [test-plan]
    fanout: per-declaration    # test-planner declares how many

  - key: review
    after: [test-write]
    fanout: fixed
    agents: [reviewer-security, reviewer-architecture, reviewer-business-logic, reviewer-edge-case]
    parallel: all
    required: true

  # ---- GATE 2: report problems, approve repairs ----
  - key: gate-repairs
    kind: gate
    after: [review]
    prompt: "Findings and bugs from {requirement} — approve which get repaired."
    kind_detail: select-findings
    required: true

  - key: repair
    needs: [implement]
    after: [gate-repairs]
    fanout: per-approved-finding
    parallel: by-group
```

**Exactly two gates, and their placement is the point.** The plan is the cheapest place to
change your mind — approving it costs one decision and redirects everything downstream. After
that, stopping to ask again mid-build just converts agent time into your time. Problems found
during the run (review findings, QA bugs, failed tasks) are *collected*, not escalated one at
a time; they surface together at `gate-repairs` where you can judge them against each other
and approve repairs in one pass.

This also means a requirement is exactly **two segments**: `implement → review` and `repair`.
That maps cleanly onto one compiled workflow each.

### 6.2 The maintenance template

QA stops being a separate discipline with its own skill, its own artifact formats and its own
parallel workflow. **It becomes the guild's second template** — the maintenance cycle, running
on the same graph machinery, ending at the same gate.

The shape follows the practice directly: something was built, so it needs maintaining; QA
checks whether inspection is due, plans the inspection, executes it, and reports what it found.

`plugins/guild/templates/maintenance.yaml`:

```yaml
name: maintenance
description: Inspect the built product, report findings, repair on approval.
nodes:
  - key: qa-check
    needs: [qa-planning]
    required: true
    # Is an inspection due, and over what? Reads `coverage`: areas touched by
    # recently-completed requirements, high-risk areas, anything stale.
    # Ends the cycle early if nothing warrants inspection.

  - key: qa-plan
    needs: [qa-planning]
    after: [qa-check]
    # qa-strategist: risk map, coverage matrix, declares inspection missions.

  - key: qa-execute
    needs: [qa-execution]
    after: [qa-plan]
    fanout: per-mission
    parallel: never          # INVARIANT — see below. Not a tuning knob.
    # qa-tester: runs the real product, applies the what-if catalog, authors e2e
    # specs, records a verdict per coverage area. One tester at a time, always.

  - key: qa-report
    needs: [qa-planning]
    after: [qa-execute]
    required: true
    # Compiles observations into `bug` rows and stamps coverage.last_inspected_at.

  - key: gate-repairs
    kind: gate
    after: [qa-report]
    prompt: "Inspection {inspection} found {n} issues — approve which get repaired."
    kind_detail: select-findings
    required: true

  - key: repair
    needs: [implement]
    after: [gate-repairs]
    fanout: per-approved-finding
    parallel: by-group
```

**Note what it shares with `standard`:** the same `gate-repairs` → `repair` tail, the same
gate semantics, the same selection UX. That is what resolves the question of whether QA needs
gates of its own — it does not. Both templates converge on "here is what we found, approve the
repairs," and the guild master learns one interaction rather than two.

**`qa-check` is the step that makes this a cycle rather than a chore.** Because `coverage` rows
carry `last_inspected_at` and a risk level, "what needs inspecting" is a query — areas touched
by requirements completed since the last pass, high-risk areas past their interval, areas with
no e2e spec at all. When nothing qualifies, the cycle ends at `qa-check` having cost almost
nothing. That is what makes it safe to trigger often.

**One tester, always — this is an invariant, not a default.** Playwright is heavy and every
tester drives its own dev server, so concurrent testers collide on ports and thrash the
machine. `qa-tester` therefore carries `serial: true` in the roster (§3.2), and the workflow
compiler must never place two serial agents in one `parallel()` batch (§7). Two independent
mechanisms enforce it because a single missed check here produces confusing, intermittent
failures rather than a clean error.

**Triggers: manual only.** `guild:qa` starts an inspection; nothing else does. There is
deliberately **no auto-trigger on requirement-done and no standing cadence**, because a full
inspection is one of the most expensive things the guild can do — it runs the real product,
drives a browser, and does it one mission at a time. Firing that automatically on every
completed requirement would quietly make every requirement cost several times what it looks
like it costs. The guild master decides when the product is worth inspecting.

The machinery for a cadence is nonetheless already there — `coverage.last_inspected_at` makes
any interval policy a one-line query — so this is a decision that can be revisited from
evidence later without redesign.

**An unattended shift will work an inspection, but never start one.** Every node from
`qa-check` through `qa-report` only observes and records: it runs the product, writes specs and
files bugs, and nothing before the gate touches production code. So once *you* have started an
inspection, a shift can carry it to `gate-repairs` overnight and have the findings waiting in
the morning. It just cannot decide on its own that inspection time has arrived.

That is the same rule as the build path, which is why it is the right one: the guild master
authorizes the expensive thing, and the guild then runs it to completion without further
interruption.

### 6.3 Deviation, with teeth

The architect instantiates the template and may deviate. Every deviation writes a
`graph_deviation` row carrying a **non-empty reason**, and `guild graph validate` enforces:

- A node marked `required: true` may be **reshaped** but never **dropped**. Review always
  happens; how wide it fans out is negotiable.
- **A gate may never be dropped, and no new gate may be added.** Gates are the guild master's
  control surface, fixed at two. An architect removing your approval point is the obvious
  failure mode; an architect *adding* gates is the subtler one — it would quietly turn
  unattended operation back into a session that stops every twenty minutes waiting for you.
- Every `add-node` names the capability it needs, and that capability must exist in the
  roster — otherwise you get a graph that cannot run.

Legitimate deviations look like: adding a `research` node ahead of `implement` for an
unfamiliar API; dropping `test-plan` and going straight to `test-write` for a docs-only change;
fanning `review` to six by adding a performance and an accessibility reviewer for a UI-heavy
requirement; splitting `implement` into three sequential waves because the slices are not
disjoint.

`guild graph REQ-007 --explain` prints template vs actual side by side with reasons — so when
a run goes wrong you diff against a known baseline instead of staring at a bespoke graph.

### 6.4 Segments and gates

A **segment** is the maximal set of nodes runnable from the current state up to, but not
including, the next unresolved gate.

With two gates, a requirement has two segments. After `gate-plan` is approved:

```
$ guild segment REQ-007 --json
{
  "requirement": "REQ-007",
  "batches": [
    { "parallel": true,  "nodes": ["implement.auth-service", "implement.session-store"] },
    { "parallel": false, "nodes": ["implement.migrations"] },
    { "parallel": false, "nodes": ["test-plan"] },
    { "parallel": false, "nodes": ["test-write.unit", "test-write.integration"] },
    { "parallel": true,  "nodes": ["review.security", "review.architecture",
                                   "review.business-logic", "review.edge-case"] }
  ],
  "next_gate": { "node": "gate-repairs", "prompt": "Findings and bugs from REQ-007..." }
}
```

That whole segment runs without stopping. It ends by presenting findings and bugs at
`gate-repairs`.

**Why gates cannot live inside a workflow.** Subagents cannot call `AskUserQuestion` — only
the orchestrator session can. A generated workflow therefore physically cannot ask you
anything. Segmenting at gates is not a stylistic choice; it is the only shape that preserves
guild-master control. It is also what makes unattended operation coherent: the segment
boundary and the "stop and notify" boundary are the same line.

---

## 7. Compiling a segment to a workflow

The orchestrator reads `guild segment --json` and emits a workflow script:

```js
export const meta = {
  name: 'guild-REQ-007-seg1',
  description: 'REQ-007 — implement, then test-plan',
  phases: [{ title: 'Implement' }, { title: 'Test planning' }],
}

const slices = args.batches[0].nodes
await parallel(slices.map(n => () =>
  agent(dispatchPrompt(n), { label: n, phase: 'Implement' })))

await agent(dispatchPrompt('implement.migrations'), { phase: 'Implement' })
await agent(dispatchPrompt('test-plan'), { phase: 'Test planning' })
```

Notes on doing this correctly:

- **Prefer `pipeline()` over `parallel()`.** A barrier is only right when a stage genuinely
  needs all prior results together — as `test-plan` does, since it inventories the whole diff.
  Independent slice chains should pipeline so a fast slice is not held behind a slow one.
- **Every agent still reports through the CLI** (`guild log`, `guild finding`). The workflow's
  return value is a summary; the database is the record. This is what makes a crashed workflow
  recoverable — node status is in `graph_node`, so re-running `guild segment` simply excludes
  what finished.
- **Serial agents — a hard compiler invariant.** `qa-tester` has `serial: true`: Playwright is
  heavy and each tester drives its own dev server, so two at once collide on ports and thrash
  the machine. The compiler must never place two serial agents in one `parallel()` batch, and
  should **fail loudly** if a template asks it to rather than silently serializing — a template
  that requests illegal concurrency is a bug worth surfacing at compile time, not papering over
  at run time.
- **Opt-in.** The Workflow tool needs explicit user opt-in, and a skill whose instructions
  direct the orchestrator to call it satisfies that. `check-in` will say so plainly.
- **Graceful degradation.** If Workflow is unavailable, the orchestrator falls back to v4
  behavior: parallel `Agent` calls in a single message. Same batches, same results, no
  deterministic control flow. The design must not depend on Workflow being present.

---

## 8. Unattended operation

The guild must be able to work a shift while the guild master is away. The two-gate model is
what makes this coherent: **run until the next gate, then stop and notify.** The segment
boundary and the stop boundary are the same line, so unattended mode needs no separate notion
of "how far may it go."

### 8.1 Triggering

```bash
guild shift [--max-tasks N] [--max-minutes M] [--requirement REQ-NNN]
```

Driven by `/loop`, by a cron entry, or invoked directly. The `guild:shift` skill wraps it.

**What a shift picks up, in order:**

1. Open build bounties whose dependencies are satisfied (the `standard` template).
2. Nodes of an inspection **the guild master already started** (the `maintenance` template).
3. Nothing left → the shift ends.

Note what is absent: a shift never *starts* an inspection (§6.2). Both templates work the same
way — you authorize the expensive thing, the guild runs it to completion and stops at
`gate-repairs`. An idle shift ends idle rather than inventing work, which is the conservative
default while unattended operation is new.

### 8.2 What it may and may not do

| May | May not |
|-----|---------|
| Claim any open, dependency-satisfied bounty | Approve a gate, or proceed past one |
| Run whole segments; compile and run workflows | Create or drop gates |
| Retry a failed task once with a fresh agent | Mark a requirement done past an unresolved gate |
| Mark tasks `failed` or `blocked` and move on | Delete anything, or rewrite history |
| File bugs and findings | Push to a remote, or commit to the default branch |
| Write to `event`, `work_log`, `review_finding` | Change goals, phases, or priorities |

The asymmetry is deliberate: **an unattended guild can do work and record problems, but every
judgment call waits for you.**

### 8.3 Failure policy

A shift must never deadlock on one bad bounty:

- **Task fails** → retry once with a fresh agent. Still failing → mark `failed`, record the
  reason, continue with other independent bounties.
- **No eligible agent** → mark `blocked`, continue. Surfaces as a roster gap in the brief.
- **Parallel file collision** (the architect mis-scoped a disjoint-file assertion) → mark the
  whole batch `failed`, do not attempt to reconcile the tree, stop the shift. This one is not
  safely automatable.
- **Gate reached** → record `gate.status = pending`, notify, end the shift cleanly.

### 8.4 Stop conditions and budget

An unattended loop with no ceiling is a runaway token burn. A shift ends on the first of:

1. An unresolved gate.
2. `--max-tasks` reached (default 10).
3. `--max-minutes` reached (default 60).
4. No actionable bounties remain.
5. A collision or repeated infrastructure failure.

Every exit writes an `event` row with the reason, so the morning brief can say why it stopped.

### 8.5 Reporting back

The guild master should be able to reconstruct the whole shift from the `event` log. Two
surfaces:

- **`guild brief --since <last-checkin>`** — narrates what moved, what failed, what is
  blocked, and which gates are waiting. This is the morning read.
- **A push notification on gate arrival** — the one moment the guild genuinely needs you.
  Optional and opt-in per project.

### 8.6 Git safety

Unattended agents write code. Left unconstrained overnight that is the highest-risk part of
this whole design.

- A shift works on a dedicated branch (`guild/REQ-NNN`), created if absent.
- **It commits per completed task** — decided. A bad overnight run is then bisectable and
  revertible task by task, and the commit log doubles as a second record of the shift
  alongside the `event` table. Message format follows the existing conventional-commit skill,
  with the task ID in the trailer.
- **It never pushes and never commits to the default branch.** Publishing stays a guild-master
  action.
- Nothing is committed for a `failed` task — a failed attempt's partial edits are reverted
  (`git restore`) before the next bounty starts, so one bad task cannot contaminate the next.

---

## 9. The dashboard

`guild dashboard --open` writes a single self-contained `.guild/dashboard.html` with the JSON
inlined — no server, no build step, no network, works offline.

Six views:

1. **Roadmap** — goals → phases → requirements, with live progress.
2. **Board** — bounties by status, colored by priority, showing matched agent and blockers.
3. **Graph** — the execution graph for the selected requirement as a Mermaid DAG, nodes
   colored by status, gates called out.
4. **Bugs** — open defects by severity, linked to fix tasks.
5. **Coverage** — quality areas by risk, each showing when it was last inspected and whether
   it has a committed e2e spec. The view that answers "what has nobody looked at in a month?"
6. **Activity** — the `event` feed.

Optionally publishable as an Artifact for a shareable link, via a thin `guild:dashboard` skill.
Local file first; the artifact is a convenience, not the mechanism.

---

## 10. Skills and agents

### Skills

| Skill | Change |
|-------|--------|
| `check-in` | **Substantially thinner.** The chain logic (v4 Steps 3.2–3.6, ~200 lines) moves into templates and the graph. What remains: brief, route, run segments, handle gates, wrap up. |
| `guild-status` → `brief` | Rebuilt on `guild brief`. Narrates goals, priorities, open bounties, blockers, what moved since last check-in. |
| `new-requirement` | Flow unchanged (live 3-way interview). The architect now writes a graph instead of creating tickets one at a time, and ends at `gate-plan` — the plan is presented for your approval and **nothing is built until you give it**. |
| `dashboard` | New. Builds and opens the HTML. |
| `shift` | New. Unattended work until the next gate (§8). Armable via `/loop` or cron. |
| `clear-board`, `release` | Rewritten against the database. `release` gains `turso db branch` as a snapshot mechanism in cloud mode. |
| `create-workflow` | **Rename to `create-ci-workflow`.** It generates GitHub Actions YAML and has nothing to do with agent orchestration. With v5 the name collision becomes actively confusing. |
| `qa` | **Reduced to a trigger, and the only way an inspection starts.** It instantiates a `maintenance` graph (§6.2) and returns. All the flow it used to own — oracle resolution, mission declaration, bug filing, re-verify pairing — becomes template nodes running on the same machinery as everything else. |
| `qa-mindset`, `qa-artifacts` | Survive as **agent reference skills**, which is what they always were. `qa-artifacts` shrinks: the charter/mission/ledger *formats* become tables, so what remains is guidance on the what-if catalog and the hybrid oracle. |
| `verify-and-fix`, `svelte-*` | Unchanged apart from CLI calls. |

### Agents

All 14 need the same three small edits, and nothing more:

1. Add `capabilities:` to frontmatter.
2. Replace "append to the Work Log section" with `guild log TASK-NNN --agent X --entry "..."`.
   Strictly better — an atomic CLI call instead of a markdown edit that can clobber a
   concurrent write.
3. Reviewers replace prose findings with `guild finding` calls.

The architect gets real new work: emit a graph, and justify deviations.

---

## 11. Migration from v4

**There is no history migration.** v5 starts with an empty board. This was a deliberate call,
and it removes the single largest and least valuable chunk of implementation work in the
project — a best-effort markdown parser for every v4 artifact shape, plus a round-trip
verifier to prove it worked, all in service of importing work that is already finished.

`guild init` on a directory that already contains a v4 board:

1. Detects `.guild/requirements|tasks|plans/`.
2. Moves the entire existing tree to `.guild/v4-archive/`, untouched and still in git. Old
   requirements, plans, work logs and reviews stay readable as plain markdown forever — they
   just are not queryable.
3. Creates the v5 schema, config, and journal alongside it.
4. Prints what it archived and what carried over.

**Two things carry over, because they are evergreen rather than historical:**

- `.guild/docs/` → the `doc` table. This is the researcher's accumulated knowledge base; the
  architect reads it when planning, so losing it would make v5 measurably dumber on day one.
- `.guild/qa/` → the `coverage` table. The v4 charter and regression manifest describe the
  *current* product's risk surface, so each area becomes a `coverage` row with its risk level
  and committed spec path (`last_inspected_at` left null — everything is due on day one).
  Past QA *sessions* are history and are archived, not imported.

Both are small, well-structured, single-shape parses — not the open-ended import that
migrating tickets would require.

**Unfinished v4 work is re-entered by hand** through `guild:new-requirement`. If a requirement
was mid-flight, its v4 plan is sitting in `.guild/v4-archive/` to read from and paste. Given
that in-flight work is usually one or two requirements, this is minutes of effort against
days of parser work.

---

## 12. Risks

| Risk | Mitigation | Residual |
|------|-----------|----------|
| Turso is now a hard dependency | `guild init` checks and prints install instructions | Users must install it; v4's zero-dependency property is gone permanently. Local and cloud need *different* binaries (`tursodb` vs `turso`) |
| Undocumented `tursodb` behavior the guild relies on | Stdin execution verified against a real install; driver layer isolates it either way | It is undocumented, so a future release could change it without it being a breaking change on their side |
| Concurrent agent writes corrupt a local DB | Spool files, single-writer orchestrator (§2.4) | Spool draining is a new failure point; an undrained spool means a task's log is on disk but not queryable |
| Database corruption or loss | Journal replay (`guild rebuild`); Turso backups in cloud mode | Journal replay is not a guarantee in cloud mode with multiple machines |
| Guild state leaves git history | `journal.ndjson` + `export/*.md` both committed | The export is generated, so a reviewer reviews output, not input |
| Cloud latency per CLI call | One round trip per command, enforced | Interactive use over a slow link will feel it; embedded replicas would fix it, at the cost of a Node dependency |
| Architect composes a bad graph | `required` nodes, gates neither droppable nor addable, `graph validate`, `--explain` diff | A poorly reasoned but valid deviation still runs; the reason string is the audit trail |
| Scope — five subsystems at once | Staged rollout below, each stage shippable | This is a large change to a plugin already broken at v4 |
| Secrets in the repo | `config.yaml` stores env var *names* only | Standard env hygiene still required of the user |
| **Unattended run writes bad code overnight** | Dedicated branch, per-task commits, never pushes, never touches the default branch; `--max-tasks` / `--max-minutes` ceilings | A long unattended run still produces a large diff to review; the gate is where you catch it, and by then the work is done |
| **Unattended run burns tokens on a stuck loop** | Hard stop conditions (§8.4), retry-once policy, every exit logged with a reason | A shift can still spend its full budget on work you would not have approved |
| Only two gates means less oversight | Problems are collected and reported together at `gate-repairs` rather than dropped | You see problems *after* the build, not during — the deliberate trade you chose |

---

## 13. Rollout

Four stages, each independently shippable and useful.

**Stage 1 — Storage (v5.0.0-alpha).**
Turso driver layer (local mode), schema, journal, export, v4 archival with `docs/` and `qa/`
carry-over. Rewrite the existing CLI commands against the database, keeping their signatures.
**Behavior identical to v4** — same board, same chain, same skills. This stage proves the
schema under real use while risking nothing. Cloud mode can land here or in Stage 2; it is
one driver branch.

**Stage 2 — Visibility (v5.0.0-beta).**
`guild brief`, `guild dashboard`, the `brief` and `dashboard` skills, goals and phases, bugs
as first-class records. Highest value per unit of work, and the part you will use daily.

**Stage 3 — The roster.**
Capabilities in agent frontmatter, `sync-agents`, `match`, `bounties`. Tasks switch from
naming agents to naming capabilities. The chain is still fixed, but the roster is now
decoupled from it — this is the extensibility win, and it lands before the riskiest stage.

**Stage 4 — The graph (v5.0.0).**
Templates, `graph`/`segment`/`gate`, architect deviation, workflow compilation, the thinned
`check-in`. Both templates land here — `standard` and `maintenance` (§6.2), since folding QA in
is just a second YAML file plus the `coverage`/`inspection` tables once the machinery exists.
Built on three stages that already work.

**Stage 5 — The shift (v5.1.0).**
`guild shift`, failure and budget policy, git safety, gate notifications, the `guild:shift`
skill. Deliberately last: unattended operation is only as safe as the gates and stop
conditions beneath it, and those are Stage 4. Shipping this earlier would mean an autonomous
loop running against a chain that cannot stop itself.

---

## 14. Open questions

### Resolved

1. ~~Local or cloud default?~~ **Local.** Cloud opt-in at `init`.
2. ~~Node/SDK driver?~~ **Deferred** — its only real payoff is embedded replicas, which
   address a cloud-mode latency problem that a local default mostly avoids.
3. ~~Goals and phases carrying their own gates?~~ **No.** Two gates total, both on the
   requirement: `gate-plan` and `gate-repairs`. Goals and phases organize and prioritize; they
   do not gate.
4. ~~Should bounties run unattended?~~ **Yes, required.** Designed in §8.
5. ~~How much v4 history to migrate?~~ **None.** Archive it; carry over only `docs/` and
   `qa/`. See §11.

6. ~~Does TursoDB support `STRICT` and FTS5?~~ **Researched.** `STRICT` yes, no longer
   experimental — use it. FTS5 **no**; TursoDB replaced it with a Tantivy-backed
   `CREATE INDEX ... USING fts`, itself experimental. `doc search` uses `LIKE`. Research also
   turned up a second, more dangerous gap: **`WITH RECURSIVE` is unsupported**, which would
   have bitten the graph traversal. Both captured as a portability rule in §3.0.
7. ~~Does `turso db shell` accept a local file path?~~ **Researched: no.** It takes a cloud
   database name or an `http://`/libSQL URL. Local files belong to the separate `tursodb`
   binary. The driver is now mode-specific (§2.2).
8. ~~Should an unattended shift commit per task?~~ **Yes**, on a dedicated `guild/REQ-NNN`
   branch, never pushed, with failed-task edits reverted (§8.6).
9. ~~What happens when no agent has the needed capability?~~ **The architect files a
   `capability_request` at plan time and proposes a new member**, which you approve at
   `gate-plan`; the guild scaffolds the agent file and admits it via `sync-agents`. Designed in
   §5.4 — this also turns the roster into something that grows with your projects.
10. ~~Per-requirement or batched `gate-repairs`?~~ **Per requirement.**

11. ~~Does `tursodb` read SQL from stdin?~~ **Yes**, confirmed against a real install. The
    `db_exec` driver in §2.2 stands and no background server is needed.
12. ~~Enable `--experimental-multiprocess-wal`?~~ **No.** The spool already solves it; opting
    into an unstable storage flag to re-solve a solved problem is a bad trade.
13. ~~Does QA get gates of its own?~~ **No — QA becomes the `maintenance` template** (§6.2)
    and reuses `gate-repairs`. Both templates converge on "here is what we found, approve the
    repairs," so there is one gate concept in the system, not two.

14. ~~Cadence for `maintenance`?~~ **No auto-trigger at all** — manual via `guild:qa` only. A
    full inspection is among the most expensive things the guild does, and firing it on every
    completed requirement would hide that cost. `coverage.last_inspected_at` keeps a cadence
    cheap to add later, from evidence.
15. ~~Can `qa-execute` run more than one tester?~~ **Never.** Playwright is heavy and testers
    collide on ports. Now an invariant enforced in two places: `serial: true` on the agent, and
    a compiler that fails loudly rather than silently serializing (§7).

### Still open

Nothing. Every design question raised in this document is resolved; the remaining unknowns are
implementation details that Stage 1 will surface on contact.

---

## References

**Runtime verification.** The §2.2 driver invocation and every §3.0 portability claim were
executed against `tursodb 0.7.2` (installed at `~/.turso/tursodb`) rather than taken from the
docs. Where the docs and the binary disagreed, the binary won — and it settled two things the
documentation does not cover at all: stdin execution, and the pipe-separated shape of
`-m list` output.

Turso documentation consulted for §2.2 and §3.0:

- [Turso CLI overview](https://docs.turso.tech/quickstart) — install lines, `turso db create --tursodb`
- [`turso db shell` reference](https://docs.turso.tech/cli/db/shell) — accepted arguments, inline SQL, stdin
- [Local development](https://github.com/tursodatabase/turso-docs/blob/main/local-development.mdx) — file databases, `turso dev --db-file`
- [`tursodb` manual](https://github.com/tursodatabase/turso/blob/main/docs/manual.md) — CLI flags, `-m list`, `--mcp`, `--experimental-multiprocess-wal`
- [TursoDB compatibility matrix](https://github.com/tursodatabase/turso/blob/main/COMPAT.md) — `STRICT`, `RETURNING`, `WITH RECURSIVE`, FTS5, window functions
- [Turso v0.5.0 release notes](https://turso.tech/blog/turso-0.5.0) — `STRICT` no longer experimental
- [Beyond FTS5](https://turso.tech/blog/beyond-fts5) — the Tantivy-backed FTS index method
