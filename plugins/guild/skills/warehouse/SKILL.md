---
name: warehouse
description: >
  The guild's warehouse — how to read and write guild data with SQL. Load this
  before touching anything in the guild database: tasks, requirements, plans,
  goals, projects, bugs, review findings, work logs, docs, coverage, the execution
  graph, gates, the agent roster, capabilities, or the event feed. Also load it
  for the board, the brief, bounties, "what's next", "what moved", roster gaps,
  or a capability match. Trigger phrases include "guild board", "guild brief",
  "next task", "claim a task", "open bounties", "file a bug", "log work", "review
  finding", "ready nodes", "resolve a gate", "sync the roster", "match an agent",
  "guild.db", "tursodb", "warehouse", "guild database", "guild SQL".
version: 1.0.0
allowed-tools: Bash(tursodb *)
---

# The warehouse

`tursodb` is the tool. There is no guild CLI — you write SQL. The schema carries the
guild's rules as CHECK constraints, views and triggers, so the way to be correct is to
read what is already there rather than invent your own spelling of a rule.

## Connect

```bash
export PATH="$HOME/.turso:$PATH"
printf "SELECT fact, value FROM v_brief;\n" | tursodb -q -m list .guild/guild.db
```

Cloud boards (`.guild/config.yaml` has `mode: cloud`) use the other binary and the URL
from the env var named in that file:

```bash
printf "SELECT fact, value FROM v_brief;\n" | turso db shell "$(printenv TURSO_DATABASE_URL)"
```

The schema lives at `${CLAUDE_PLUGIN_ROOT}/schema.sql`. Applying it is idempotent —
`tursodb .guild/guild.db < schema.sql` — and is how a rule change reaches a live board.

## Six rules that are always true

1. **Free text crosses as hex.** A `;` that ends a line ends the statement, even inside a
   string literal — and requirement bodies quote code. Every title, body, rationale, log
   entry and finding goes in as `CAST(x'<hex>' AS TEXT)`, which is always one line:
   `hex=$(printf '%s' "$v" | xxd -p | tr -d '\n')`. Never `echo`. Never round-trip the
   value through `$( )` — that eats trailing newlines. Empty string is `''`.
   Ids, enum values, agent names, capabilities and timestamps you generated are closed
   alphabets and may be quoted literals.
2. **`PRAGMA foreign_keys = ON;` at the top of every writing script.** It is
   per-connection and defaults to OFF, and every invocation is a fresh connection.
3. **Never parse `-m list` output positionally.** It is pipe-separated with no quoting,
   and free text contains pipes *and newlines* — a newline forges a whole row. Either
   `json_object(...)`, or select exactly one column when you need a value byte-exact, or
   flatten in SQL before it leaves the engine.
4. **Read the view, do not re-derive the rule.** `v_next_task`, `v_open_bounties`,
   `v_task_actionable`, `v_ready_nodes`, `v_board`, `v_brief`, `v_agent_match` and the
   rest each hold ONE definition of a rule. Two members writing their own version of
   "which task is next" gives the guild two answers to one question, and both look right.
5. **A failing statement does not stop the script, and `COMMIT` still commits.** There is
   no `-bail`. Keep scripts to one logical change, put `RETURNING` on every mutation so
   "did it land" is answered by output, and do the referential check *inside* the write
   (`INSERT … SELECT … FROM parent WHERE parent.id = 'REQ-001'` — the `FROM` is the check).
6. **Errors print on stdout, not stderr.** `out=$(… | tursodb …)` captures the error as if
   it were a row. Always check the exit code, and never `>/dev/null` the failure path.

Set your name once per script so the triggers attribute the events to you:
`UPDATE guild_state SET value = 'developer-svelte' WHERE key = 'actor';`
It is a label, not an identity — nothing authenticates it.

## References — load what the task needs

- **`references/schema.md`** — what every table is FOR, how the tables relate, and which
  rules the database enforces versus which are conventions you must honor yourself. Load
  it when you are deciding *where a piece of information belongs*, or when you need to
  know whether something is actually guaranteed.
- **`references/queries.md`** — the canonical, verified queries: creating a requirement /
  plan / task / bug / doc with derived ids, moving something through status, the
  daily reads (board, brief, bounties, what moved), the execution graph, and the roster
  and matcher. Load it when you are about to write SQL. Copy from it rather than
  improvising.
- **`references/tursodb-gotchas.md`** — the traps, each reproduced against the real
  binary: the statement splitter, invalid UTF-8, `-m list` forgery, no `WITH RECURSIVE`,
  no FTS5, `LIKE` escaping, output-channel injection, non-atomic scripts, and the
  local-vs-cloud engine split. Load it before writing any *shell* around the SQL, before
  rendering guild data into a document or a board, or when something behaved strangely.
