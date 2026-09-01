# TursoDB gotchas — read before you type SQL

`tursodb` 0.7.2 at `~/.turso/tursodb`. Put it on PATH: `export PATH="$HOME/.turso:$PATH"`.

Every trap below was **reproduced against the real binary**, and every one of them was
originally found the expensive way — silently corrupted data, a forged row, a fabricated
file. You write raw SQL against the warehouse now. There is no wrapper to catch these
for you.

**The four that will bite you today:**

| # | Trap | The rule |
|---|------|----------|
| 1 | A `;` ending a line ends the statement — even inside a string literal | Free text goes in as `CAST(x'<hex>' AS TEXT)` |
| 3 | `-m list` output is pipe-separated; free text has pipes *and newlines* | Never parse free text positionally |
| 9 | A failing statement does **not** stop the script, and `COMMIT` still commits | Check exit code *and* verify; keep scripts small |
| 6 | Free text in a rendered document can forge a row, heading or filename | Never interpolate free text into a structured format |

---

## 1. The statement splitter tears a string literal at a line-ending `;`

**What happens.** `tursodb` splits a stdin script into statements before parsing. A `;`
that *terminates a line* ends the statement — even when the parser is inside an open
string literal.

**Reproduce it.**

```bash
{ printf "INSERT INTO t(body) VALUES('code:\n"
  printf "const x = 1;\n"
  printf "done');\n"; } | tursodb -q -m list guild.db
```

```
  × non-terminated literal ''code:
  │ const x = 1;' at offset 27
  × near "done": syntax error
```

An **inline** semicolon is harmless — `VALUES('has; inline')` inserts fine. It is
specifically a `;` at end-of-line.

**Why it matters more than it looks.** Requirement bodies, plan bodies, work-log entries
and review findings routinely quote code. Code has lines ending in `;`. So this fires in
ordinary use, not adversarial use — and it fired **silently for three review rounds**,
because (see below) tursodb writes the parse error to *stdout*, where a caller doing
`out=$(… | tursodb …)` swallows it as data.

**What to do instead.** Send every free-text value as hex. Hex is unambiguous and,
critically, **always a single line**, so the splitter cannot tear it and there is no
escaping left to get wrong.

```bash
# encode
hex=$(printf '%s' "$value" | xxd -p | tr -d '\n')
printf "INSERT INTO t(body) VALUES(CAST(x'%s' AS TEXT));\n" "$hex" | tursodb -q -m list guild.db

# from a file — no shell substitution of the content at all, which is better
hex=$(xxd -p < body.md | tr -d '\n')
```

No `xxd`? `LC_ALL=C od -An -v -tx1 | LC_ALL=C tr -d ' \n'` produces byte-identical
output. Both ship with macOS and with coreutils/vim-common on Linux.

**Verified round-trip** for `code:\nconst x = 1;\ndoThing();\ndone` (34 bytes in, 34 out,
hex identical) and for `日本語 🎯 a|b it's "q" \ back;`.

**Three encoder rules that are not style:**

- **`printf '%s'`, never `echo`.** `echo` mangles backslashes and adds a newline.
- **Never round-trip the *value* through `$( )`.** Command substitution strips *all*
  trailing newlines: `V=$'body\n\n'` is `626f64790a0a`, but `W=$(printf '%s' "$V")` is
  `626f6479`. Pipe the value straight into the encoder. (Capturing the *hex* in `$( )` is
  fine — hex has no trailing newline.)
- **Empty string → `''`, not `CAST(x'' AS TEXT)`.** Both give a zero-length TEXT, but
  `''` is what a reader expects and keeps `NULLIF(x,'')` call sites obvious.

**When you may use a quoted literal instead.** Only for values from a closed, known-safe
alphabet that you validated: ids (`TASK-007`), enum values (`todo`), agent names,
capability tokens, ISO dates, timestamps you generated. Double any internal `'`. When in
doubt, use hex — it is correct for those too, just more verbose.

### 1a. Errors go to STDOUT, not stderr

```bash
printf "INSERT INTO t(body) VALUES('a:\nx = 1;\nb');\n" | tursodb -q -m list guild.db >o.txt 2>e.txt
# stdout: 548 bytes of diagnostics    stderr: 0 bytes    exit: 1
```

This holds for **parse errors and runtime errors alike** (`CHECK constraint failed`,
`UNIQUE constraint failed`, `NOT NULL constraint failed` — all 104-byte stdout, empty
stderr).

Consequences you must design around:

- `out=$(… | tursodb …)` captures the error message **as if it were a result row**. A
  reader that looks for `OK` in that string reports "not found" instead of "it blew up".
- **Never discard stdout on the failure path.** `>/dev/null` on a failing command
  produces exit 1 with no message anywhere, which is indistinguishable from a crash.
- Always check the exit code. Do not infer success from "no output" — a successful
  `INSERT` with no `RETURNING` also produces no output.

---

## 2. `CAST(x'…' AS TEXT)` is byte-exact only for valid UTF-8

**What happens.** Feed the transport a byte sequence that is not valid UTF-8 and it does
not fail. It is **silently corrupted, and the two engines corrupt it differently.**

**Reproduce it** with `caf\xe9 \xff\xfe bad` (latin-1 `é`, then two stray bytes):

```bash
hex=$(printf 'caf\xe9 \xff\xfe bad' | xxd -p | tr -d '\n')   # 636166e920fffe20626164
printf "SELECT hex(CAST(x'%s' AS TEXT));\n" "$hex" | tursodb -q -m list guild.db
printf "SELECT hex(CAST(x'%s' AS TEXT));\n" "$hex" | sqlite3
```

```
tursodb 0.7.2   636166 EFBFBD 20 EFBFBDEFBFBD 20626164    ← U+FFFD substituted
sqlite3         636166 E9     20 FFFE         20626164    ← bytes preserved
```

**Why it matters.** Same input, two different stored values depending on which engine
saw it. A record written on one engine and replayed on the other is a *different record*,
with no error and no warning at any point.

**What to do instead.** Validate before writing, and refuse rather than store. Practical
check (pure ASCII pattern over hex pairs, so no locale or awk-bracket-range weirdness):

```bash
# exits non-zero if $value is not valid UTF-8
printf '%s' "$value" | iconv -f UTF-8 -t UTF-16BE >/dev/null 2>&1
```

Two warnings about that one-liner, both measured:

- **`-t UTF-8` as the target is too permissive** — it passes `F4 90 80 80`,
  `F5 80 80 80` and 5-byte `F8 88 80 80 80`, all of which tursodb replaces with U+FFFD.
  `-t UTF-16BE` rejects them, because UTF-16 cannot represent them.
- **`/usr/bin/iconv` on macOS reports false positives on valid UTF-8** when stdout is
  `/dev/null` — `iconv(): Inappropriate ioctl for device`, depending on where multi-byte
  sequences fall relative to its buffer. Redirect to a **regular file** instead of
  `/dev/null` if you rely on it, or use Python: `python3 -c 'import sys;
  sys.stdin.buffer.read().decode("utf-8")'`.

If a value is not UTF-8, say so and name the offending byte and offset. Re-encode with
`iconv -f latin1 -t utf8`. Do not store it "and see".

---

## 3. `-m list` is pipe-separated, and free text contains pipes *and* newlines

**What happens.** `tursodb -q -m list` writes one row per line, columns joined with `|`,
no header, no quoting, no escaping. A title containing a pipe adds a column. A title
containing a newline adds a **row**.

**Reproduce it.** Store one title that contains both:

```bash
t=$(printf 'Fix a|b parsing\nTASK-999|done|Ship it' | xxd -p | tr -d '\n')
printf "INSERT INTO task VALUES('TASK-001','todo',CAST(x'%s' AS TEXT));\n" "$t" | tursodb -q -m list guild.db
printf "INSERT INTO task VALUES('TASK-002','todo','Normal title');\n"       | tursodb -q -m list guild.db

printf "SELECT id, title, status FROM task ORDER BY id;\n" | tursodb -q -m list guild.db
```

```
TASK-001|Fix a|b parsing
TASK-999|done|Ship it|todo          ← a row that does not exist
TASK-002|Normal title|todo
```

`cut -d'|' -f3` to read the status now yields `b parsing`, `Ship it`, `todo`.

**The half-fix that is not a fix.** "Put free text last and split on a fixed count"
handles pipes — and still loses:

```bash
printf "SELECT id, status, title FROM task ORDER BY id;\n" | tursodb -q -m list guild.db \
  | while IFS='|' read -r id status rest; do printf 'id=%s status=%s\n' "$id" "$status"; done
```

```
id=TASK-001 status=todo
id=TASK-999 status=done      ← the forged row is still there; the newline made it
id=TASK-002 status=todo
```

`-m line` is no better — a value containing `z = z` forges a field there in exactly the
same way, and a multi-line value spills across field boundaries.

**What to do instead — pick one:**

1. **Flatten server-side** (the general answer). Strip the separators inside SQL so the
   row is one line and has no interior pipe, *before* the value leaves the engine:

   ```sql
   SELECT id,
          replace(replace(replace(title, char(10), ' '), char(13), ' '), '|', '!'),
          status
     FROM task ORDER BY id;
   ```
   ```
   TASK-001|Fix a!b parsing TASK-999!done!Ship it|todo
   TASK-002|Normal title|todo
   ```
   Lossy on purpose. Correct for *columnar* surfaces — a board, a filter, a list — which
   are for scanning, not for round-tripping. The exact value is one query away.

2. **Select exactly one column** when you need the value byte-exact. With one column the
   driver never inserts a separator and the entire stdout *is* the value. This is how you
   read a body, an objective, a finding.

3. **Emit JSON.** `json_object(...)` escapes control characters, so one row is always one
   line, and the consumer parses it properly instead of splitting on `|`.

**Two more `-m list` sharp edges:**

- **`NULL` and `''` are byte-identical in the output.** `SELECT 'a',NULL,'c'` and
  `SELECT 'a','','c'` both print `a||c`. If the distinction matters, make it explicit in
  SQL: `CASE WHEN col IS NULL THEN '<null>' ELSE col END`, or `quote(col)`.
- **Zero rows produce no output at all, with exit 0** — indistinguishable from a
  statement that returns nothing. Select a sentinel (`SELECT 'FOUND', …`) when you need to
  tell "no such row" from "found it, and the field is empty".

---

## 4. No `WITH RECURSIVE`

```bash
printf "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<5) SELECT n FROM c;\n" \
  | tursodb -q -m list guild.db
#   × Parse error: Recursive CTEs are not yet supported     (exit 1)
```

**Plain CTEs are fine** — `WITH x AS (SELECT …) SELECT …` works, including inside a
`VIEW`. Do not over-correct and ban all CTEs.

**Why this hurts.** The execution graph is the textbook recursive-CTE case: transitive
closure over a dependency DAG.

**What to do instead — readiness is a direct-predecessor join, one hop, no traversal.**
A node is ready when *no direct predecessor is unfinished*, written as a `NOT EXISTS`
(vacuously true for a root node, which is correct):

```sql
CREATE VIEW node_ready AS
SELECT n.id FROM graph_node n
 WHERE n.status = 'pending'
   AND NOT EXISTS (SELECT 1 FROM graph_edge ge
                     JOIN graph_node gp ON gp.id = ge.from_node
                    WHERE ge.to_node = n.id
                      AND gp.status NOT IN ('done','skipped'));
```

Verified: with `plan→impl→test→review` and `plan` done, `node_ready` is `impl`; mark
`impl` done and it becomes `test`. **Readiness propagates one node at a time as work
completes** — the transitive closure is never needed, because you only ever ask "what can
start *now*".

Put it in a `VIEW` so the rule has exactly one definition. Two spellings of readiness is
two answers to "what runs next".

**Cycles.** You cannot detect a cycle with a traversal here. Guarantee acyclicity at
*write* time instead: require every `after:` reference to name a node declared **earlier**
in the template. Edges that all point backwards in declaration order cannot form a cycle,
and that is a linear check.

**`done` and `skipped` both count as finished.** A deliberately skipped node must not
block its successors forever.

---

## 5. No FTS5 — search with `LIKE`, and escape the wildcards

```bash
printf "CREATE VIRTUAL TABLE ft USING fts5(body);\n" | tursodb -q -m list guild.db
#   × Parse error: no such module: fts5     (exit 1)
```

TursoDB offers a Tantivy-backed `CREATE INDEX … USING fts` instead, but it is
experimental and the cloud engine does not have it — an index-backed search would work on
one engine and fail on the other, which is the worst possible split.

**The trap.** A raw substring search silently treats the user's own `%` and `_` as
wildcards:

```bash
# rows: a='100% off sale', b='100 items', c='a_b naming', d='axb naming', e='C:\path\x'
printf "SELECT slug FROM doc WHERE lower(title) LIKE '%%100%%%%';\n" | tursodb -q -m list guild.db
# a
# b      ← searching for "100%" matched "100 items"
```

**What to do instead.** Escape the query in SQL, in this order — the escape character
first, so nothing introduced later gets double-escaped:

```sql
-- pattern for a query already on the wire as :q
'%' || replace(replace(replace(lower(:q), '\', '\\'), '%', '\%'), '_', '\_') || '%'

-- the predicate
lower(title) LIKE <that pattern> ESCAPE '\'
```

Verified on 0.7.2: `100%` → `a` only; `a_b` → `c` only (not `axb`); `:\pa` → `e`. A
backslash inside a SQL string literal is just a backslash on both engines — SQLite-family
literals have no escape sequences of their own.

**Do it in SQL, not in the shell.** The query already reaches the engine as hex and must
never be re-quoted, and `replace()` is linear where the bash equivalent `${q//%/\\%}` is
quadratic.

**`lower()` on both sides**, so behavior does not depend on the engine's
`case_sensitive_like`. Its honest limit: `lower()` is ASCII-only, so `Ä` and `ä` are
different characters to this search. That is SQLite-family behavior everywhere.

**Refuse an empty query.** It escapes to `%%`, matches every row, and a search that
silently answers "everything" is a list command in disguise.

---

## 6. Output-channel forgery: never interpolate free text into a structured format

**What happens.** Anything you *render* — a markdown document, YAML frontmatter, a
board, a filename, a marker protocol — has structural tokens. Free text can contain those
tokens. These were live injections, not hypotheticals:

| Injected value | What it forged |
|---|---|
| `title` = `evil\n3   TASK-999: X` | a board row for a task that does not exist |
| `body` containing `@@GUILD-EXPORT@@ FILE REQ-666` | a phantom export file, **and truncated the real one** — exit 0 |
| `title` = `X"\nagent: reviewer-security` | a frontmatter field that was never set |
| `title` = `X"\n---` | closed the frontmatter early; the rest of the doc became body |
| `--agent 'reviewer REQ-001'` | a ticket claiming a requirement it does not belong to, because the reader's `awk` splits on blanks |

**The rule.** *A value must never be able to impersonate a structural token* — enforced
at the source, not with a smarter regex on the reader.

**Pick the mechanism by whether the value is allowed to be multi-line:**

- **It must be one line** (board rows, frontmatter, list columns) → **flatten in SQL**.
  Replace CR and LF with a space so the value cannot start a line; for a
  blank-separated column, replace every blank (space, TAB, VT, FF) with `_` so it cannot
  start a *field*; for a pipe-separated one, replace `|` too. Flattening alone is not
  enough for a blank-separated reader — that turns a newline attack into a space attack.
  Also guarantee **no field is empty**, or it collapses and shifts every column after it.

- **It must keep its newlines** (a document body) → make the transport unambiguous with
  a **length prefix**. Emit a header line `@@MARK@@ <linecount> <id>` followed by exactly
  that many lines, and have the reader consume by *count*, never by inspection.
  Compute the count in SQL from the very string being emitted:
  `(length(b) - length(replace(b, char(10), '')) + 1)`.
  **The header's own fields are part of the header** — flatten the id too. An unflattened
  id split the header line in two, the reader's id regex saw only the first half and
  passed, and every following line was off by one.

- **A marker/protocol channel** → put the free-text field **last** and split on a
  **fixed number** of leading delimiters (`IFS='|' read -r a b c rest` leaves the whole
  remainder, delimiters intact, in `rest`), *and* flatten every non-final field. Both
  halves are required.

- **YAML frontmatter** → flattening makes a value unforgeable but not *valid*.
  `title: "C:\path\new"` is a YAML scanner error (unknown escape `\p`); a value containing
  `"` ends the scalar early. Escape `\` and `"` inside the quoted scalar as well.

- **JSON** → `json_object()` already escapes control characters, so one row is always one
  line. Prefer it whenever the consumer can parse JSON.

- **A filename** → never build one from free text. Derive it from a validated id.

**Validate keys instead of escaping them.** A slug, a capability, an agent name is a
*key*: someone has to retype it. Enforce a closed alphabet at the door and reject what
does not fit — do not slugify silently, because `put 'My Notes'` storing `my-notes` makes
the next `get 'My Notes'` report not-found, which reads as data loss.

Set `LC_ALL=C` around any bash bracket-expression check. `A-Za-z` is a *collation* range,
not a byte range: under `LANG=en_US.UTF-8` an accented letter collates **inside** `a-z`,
so `café` passed on a laptop and was refused in CI, from the same input. Whitespace,
punctuation and emoji collate outside `a-z`, which is exactly why the leak went unnoticed
for so long.

---

## 7. What is safe — verified on 0.7.2

| Construct | Verified |
|---|---|
| `STRICT` tables | ✅ `VARCHAR(10)` correctly rejected: `× Parse error: unknown datatype` |
| `CHECK (status IN (…))` | ✅ `Error: Runtime error: CHECK constraint failed: …` |
| `NOT NULL`, `UNIQUE`, composite `PRIMARY KEY`, `REFERENCES` | ✅ enforced |
| `CREATE VIEW` (incl. a view of a view, and a view containing a plain CTE) | ✅ **no flag needed** |
| `CREATE TRIGGER` — `AFTER UPDATE OF col … WHEN OLD.x <> NEW.x` | ✅ fires; `OLD.`/`NEW.` available |
| `BEFORE` trigger + `SELECT RAISE(ABORT, 'msg')` | ✅ `Error: Runtime error: cannot reopen a done task` |
| Triggers fire on `ON CONFLICT DO UPDATE` too | ✅ verified |
| `INSERT/UPDATE … RETURNING` | ✅ |
| `INSERT … ON CONFLICT(k) DO UPDATE SET v = excluded.v` | ✅ |
| `INSERT OR REPLACE` | ✅ |
| Plain CTE `WITH x AS (…)` | ✅ |
| `NOT EXISTS` correlated subquery | ✅ — this is what replaces recursion |
| `LEFT JOIN` + `GROUP BY` + `COUNT` / `SUM(CASE WHEN …)` / `MAX` | ✅ |
| `UNION ALL` compound with one trailing `ORDER BY` | ✅ ordering applies across the whole compound |
| `ORDER BY CASE … END`, `LIMIT` | ✅ |
| `printf('%03d', 7)` → `TASK-007` | ✅ |
| `replace` / `length` / `substr` / `trim` / `lower` / `abs` / `hex` / `instr` / `quote` | ✅ deeply nested `replace()` chains fine (36 levels tested) |
| `COALESCE`, `NULLIF(x,'')`, `CAST(x AS INTEGER)`, `char(10)` | ✅ |
| `GLOB` with a negated class `'*[^A-Za-z0-9_.-]*'` | ✅ (`-` last in the class is a literal) |
| `json_object` / `json_extract` / `json_valid` | ✅ `json_object` escapes control chars → one row is one line |
| `AUTOINCREMENT`, `CREATE INDEX` (incl. `IF NOT EXISTS`, `DESC`, composite) | ✅ |
| `PRAGMA journal_mode=WAL`, `table_info(t)`, `sqlite_master` | ✅ |
| Multi-statement script on stdin | ✅ rows concatenate in statement order |

**Experimental — do not use.** `CREATE MATERIALIZED VIEW` (needs `--experimental-views`;
plain `VIEW` does not), generated columns, `ATTACH`, `WITHOUT ROWID`, custom types.
The flag exists on the local shell and not on the cloud engine, so anything behind one is
an engine split waiting to happen.

**Two `json_extract` notes.** It returns the JSON value's own type, so cast on the way
into a STRICT table (`CAST(json_extract(j,'$.x') AS TEXT)`). And it *raises* on malformed
JSON, which aborts the statement — wrap as `CASE WHEN json_valid(j) THEN j END`, since
`json_extract(NULL, path)` is `NULL` rather than an error. A bare
`WHERE json_valid(j) AND json_extract(…)` does **not** reliably protect: the subquery
flattens and `json_extract` is still evaluated.

**One `STRICT` surprise, on both engines:** `INSERT INTO t(text_col) VALUES(42)` succeeds
and stores `'42'` as `text`. STRICT rejects unknown *datatypes*, not lossless coercions.

---

## 8. Scripts are not atomic, and `COMMIT` will commit anyway

**What happens.** A failing statement does **not** stop the rest of the script, and
wrapping it in `BEGIN … COMMIT` does not save you — the script keeps running, reaches the
`COMMIT`, and commits what did land.

**Reproduce it.**

```bash
printf "BEGIN;\nINSERT INTO q VALUES('one');\nINSERT INTO q VALUES('one');\nINSERT INTO q VALUES('two');\nCOMMIT;\n" \
  | tursodb -q -m list guild.db
#   Error: Runtime error: UNIQUE constraint failed: q.a (19)     exit 1
printf "SELECT a FROM q ORDER BY a;\n" | tursodb -q -m list guild.db
#   one
#   two          ← both landed, despite exit 1 and a wrapping transaction
```

`sqlite3` behaves the same way, but it has `-bail` to stop on the first error.
**`tursodb` has no `-bail`.**

**What to do instead:**

- Treat a non-zero exit as **"some unknown prefix of this script may have landed"**, not
  as "nothing happened". Read the state back before deciding what to do.
- Do the referential check **inside the write** so a bad reference produces zero rows
  rather than a partial mutation: `INSERT INTO child(…) SELECT …, FROM parent WHERE
  parent.id = :id RETURNING id` — the `FROM` clause *is* the check, and a missing parent
  yields no row and no error.
- Prefer **one logical change per invocation**. Small scripts make the failure mode
  small.
- `RETURNING` on every mutation, so "did it land" is answered by output rather than by
  inference.

**`PRAGMA foreign_keys` is per-connection and defaults to OFF.** Every `tursodb`
invocation is a fresh connection:

```bash
printf "PRAGMA foreign_keys;\n"            | tursodb -q -m list guild.db   # → 0
printf "PRAGMA foreign_keys=ON;\nPRAGMA foreign_keys;\n" | tursodb -q -m list guild.db   # → 1
```

Prepend `PRAGMA foreign_keys = ON;` to **every** script that writes. The *set* form of a
boolean pragma returns no rows, so it cannot pollute your output — but the *query* form
does, so never leave a bare `PRAGMA foreign_keys;` in a script you parse. (Same reason
`busy_timeout` stays out of the preamble: its set form *does* return a row in SQLite and
would corrupt your first result line.)

---

## 9. Two engines — write to the intersection

`turso db create` gives the **libSQL** engine (a SQLite fork); `--tursodb`, and every
local `tursodb`, gives the **TursoDB** engine (the Rust rewrite). Their SQL support
differs, and so does their behavior on the same input.

Known divergences, all reproduced above:

| | TursoDB 0.7.2 (local) | libSQL / sqlite3 |
|---|---|---|
| Invalid UTF-8 through `CAST(x'…' AS TEXT)` | replaced with U+FFFD | bytes preserved |
| `WITH RECURSIVE` | ✗ parse error | ✓ |
| FTS5 | ✗ no such module | ✓ |
| Full-text index | `CREATE INDEX … USING fts` (experimental) | FTS5 virtual table |
| Stop-on-first-error flag | none | `sqlite3 -bail` |
| Output shape | `-m list` → pipe-separated, no header | `turso db shell` → bordered table with a header |

That last row is why a parser written for one silently reports "nothing found" against
the other, and why writes look like they succeeded when they did not.

**The rule: if the code depends on an SQL construct, it has a verified row in §7.** An
incomplete matrix is worse than no matrix, because it gets read as an allowlist and
trusted as one. Three review rounds found constructs in use that were not on the list —
including `CAST(x'…' AS TEXT)`, the transport for *every free-text value in the system*.
Adding a construct means adding its verified row in the same change.
