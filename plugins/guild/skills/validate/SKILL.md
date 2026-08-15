---
name: validate
description: >
  This skill should be used when the user asks to "validate the guild", "check the
  guild", "does this match expectations", "run the expectations", "validate the
  board", "check the invariants", "verify the board", "did that actually land",
  "check the board against expectations", or wants to know whether what a skill just
  did matches what was required. Runs the SQL assertions in docs/expectations.md
  against the live board — the global invariants by default, a named process's
  postconditions on request — and reports every failure with the offending rows.
version: 1.0.0
user-invocable: true
allowed-tools: Bash(tursodb *)
---

# Validating the guild

There is no code left to unit-test. What can fail now is a member reading the schema and
the process, understanding some of it, and doing something **adjacent** to what was needed.

`docs/expectations.md` is the specification that catches that, and because the data model is
a database, every expectation in it is a **SQL assertion with a stated expected result**
rather than prose to be interpreted. This skill runs them and reports what holds.

**Read-only by default, and say so in the report.** The only path that writes is
`--fixture`, which is gated behind a confirmation and refuses a board holding real work.

## The surface

| invocation | what runs |
|---|---|
| `validate` | §3 — the nine global invariants. They hold whatever just ran. |
| `validate <process>` | §3, then that process's preconditions, postconditions and anti-expectations. |
| `validate --fixture <name>` | Loads a fixture into a **scratch** database, then asserts against it. Writes. |

`<process>` names a skill, and the section it maps to:

| process | section | process | section |
|---|---|---|---|
| `new-requirement` | §4 the build flow | `clear-board` | §8 |
| `brief` | §5 | `release` | §9 |
| `dashboard` | §6 | `guild-status` | §10 |
| `check-in` | §7 | `qa` | §11 the maintenance cycle |
| | | `shift` | §12 the unattended shift |

`<name>` is one of `empty`, `planned`, `in-flight`, `review-ready`, `messy`, `maintenance` —
`docs/expectations-fixtures.md`.

## The shape every assertion has

**Zero rows when healthy, the offending rows when not**, so a failure names its own cause.
`finding-open-past-gate-repairs|1|REQ-001` tells you the row, the requirement and the rule;
a boolean `FAIL` tells you to go looking. **Any output at all is a failure.**

A handful state a count or a value instead — §4.b expects exactly the plan gate row, §4.c
expects `N+9 | 2N+10 | 2`, P4.a expects version `5`. The sentence above each block says
which. Read it; do not assume the zero-rows shape.

**The exit code is not evidence.** tursodb has no `-bail`, a failing statement does not stop
a script, and errors print on **stdout**. Check the return code *and* the output, every time.

## Running it

**The doc is the source.** Never retype an assertion and never paraphrase one — a second
copy of a rule is exactly the failure this document exists to catch. Extract it.

````bash
export PATH="$HOME/.turso:$PATH"
DOC="${CLAUDE_PLUGIN_ROOT}/docs/expectations.md"
DB=.guild/guild.db
WORK=$(mktemp -d)

for g in G1 G2 G3 G4 G5 G6 G7 G8 G9; do
  awk -v id="$g" '$0 ~ "^### " id " " {f=1}
                  f && /^```sql$/ {c=1; next}
                  c && /^```$/ {exit}
                  c {print}' "$DOC" > "$WORK/$g.sql"
  out=$(tursodb -q -m list "$DB" < "$WORK/$g.sql" 2>&1); rc=$?
  if [ $rc -eq 0 ] && [ -z "$out" ]; then printf '%s PASS\n' "$g"
  else printf '%s FAIL rc=%s\n%s\n' "$g" "$rc" "$out"; fi
done
````

A section assertion extracts the same way, keyed on its bold id. `REQ-NNN` in §4 is a
placeholder — substitute the requirement actually under test:

````bash
awk -v id="4.a" 'index($0, "**§"id" ") {f=1}
                 f && /^```sql$/ {c=1; next}
                 c && /^```$/ {exit}
                 c {print}' "$DOC" | sed 's/REQ-NNN/REQ-001/g' > "$WORK/s4a.sql"
````

Preconditions (`P4.a`, `P7.b`, …) live inside their section's single fenced block; extract
the block by its `### Preconditions` heading and run it whole.

## Reporting

Name the target, name the sections, and state the read-only fact first:

```
Validated .guild/guild.db against §3 + §7 (check-in) — READ-ONLY, nothing was written.

  G1  referential health   PASS      G6  closure and records  PASS
  …
  G5  roster integrity     FAIL      G9  concurrency          PASS

  G5 — roster integrity
      capability-outside-vocabulary|TASK-010|task:embedded
      uncovered-capability-no-request|TASK-010|embedded

1 of 9 invariants failed. TASK-010 requires `embedded`, no active member covers it, and no
capability_request was filed — the ticket will sit on the board matching nobody.
```

- **Print the offending rows verbatim.** Never compress a failure into a count; the rows
  are the whole value of the assertion's shape.
- **Read the breach token,** then say in one line what it means for the board and what
  closes it. A validation nobody can act on is a validation nobody runs twice.
- **Close a fully-passing run with what was not checked.** Every section has a *Cannot be
  asserted* heading and it is not decoration: nothing here sees whether a plan is good,
  whether the code was written, whether a human actually decided a gate, or who wrote a row.
  Say that once, plainly, rather than letting green read as proof.

## The fixture path — this one writes

`validate --fixture messy` seeds a known board so an assertion means the same thing twice.
Four things are mandatory:

1. **Never load into `.guild/guild.db`.** The target is a scratch file — `$(mktemp -d)/fx.db`
   — with `schema.sql` applied. If the user insists on a named target, run the guard below
   first and **refuse** if it returns anything, naming the tables that hold work:

   ```sql
   SELECT 'goal' AS tbl, CAST(COUNT(*) AS TEXT) AS rows FROM goal HAVING COUNT(*) > 0
   UNION ALL SELECT 'requirement', CAST(COUNT(*) AS TEXT) FROM requirement HAVING COUNT(*) > 0
   UNION ALL SELECT 'task',        CAST(COUNT(*) AS TEXT) FROM task        HAVING COUNT(*) > 0
   UNION ALL SELECT 'bug',         CAST(COUNT(*) AS TEXT) FROM bug         HAVING COUNT(*) > 0
   UNION ALL SELECT 'coverage',    CAST(COUNT(*) AS TEXT) FROM coverage    HAVING COUNT(*) > 0
   UNION ALL SELECT 'doc',         CAST(COUNT(*) AS TEXT) FROM doc         HAVING COUNT(*) > 0
   UNION ALL SELECT 'inspection',  CAST(COUNT(*) AS TEXT) FROM inspection  HAVING COUNT(*) > 0
   UNION ALL SELECT 'event',       CAST(COUNT(*) AS TEXT) FROM event       HAVING COUNT(*) > 0
   ORDER BY tbl;
   ```

   Zero rows means the file is safe to overwrite. A roster alone does not trip it.
2. **Confirm before loading**, naming the exact file that will be written. This is the one
   path in this skill that is not read-only and the user is told so before it runs.
3. **Load in order.** The chains are §0.1 of `expectations-fixtures.md`, and every one
   starts with the roster block (§0.5):
   `empty` = schema only · `planned` = `00`+`02` · `in-flight` = +`03` ·
   `review-ready` = +`04` · `messy` = `00`,`02`,`03`,`05` · `maintenance` = `00`,`06`.
   Extract each seed block by its `**Seed SQL — \`NN-name.sql\`:**` line, same awk.
4. **Check both channels after every load, then run the fixture's sanity query** and compare
   it to the stated result. Every seed script is silent on success, so *any* output is an
   error; `schema.sql` alone prints `wal`. A script can exit 0 having written half of what
   it meant to — the sanity row is what proves it did not.

## Rules

- **Read-only unless `--fixture`,** and the report says which it was.
- **The doc is the source.** If an assertion is wrong, fix `docs/expectations.md` — do not
  correct it inline here and do not carry a private copy.
- **Any output is a failure.** Check the return code *and* stdout, always.
- **Never `cut -d'|'` the result.** Board text carries pipes and newlines, and a newline
  forges a whole row (`guild:warehouse`, rule 3).
- **Never write the board to make an assertion pass.** Report the breach; repairing it is a
  separate, named decision by the guild master.
- **A green run is not a good run.** It says the member did not break the board's rules. It
  says nothing about whether the work was worth doing — that is the *Cannot be asserted*
  list, and it belongs in the report.
