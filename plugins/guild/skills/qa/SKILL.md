---
name: qa
description: >
  This skill should be used when the user wants quality assurance on the product
  itself — "QA the product", "QA the checkout flow", "run a QA pass", "build
  comprehensive e2e tests", "write regression tests", "test the running app",
  "what-if testing", or any request to empirically test the product and author
  end-to-end regression coverage. Seeds the guild's independent QA discipline:
  a qa-strategist maps the risk surface onto the board as coverage rows, then
  qa-testers run the app and author Playwright specs while filing defects as bug rows.
version: 5.0.0
user-invocable: true
allowed-tools: Bash(tursodb *)
arguments:
  - name: scope
    description: "What to QA — 'product' for a full pass, or a named area/flow (e.g. 'checkout')"
    required: false
  - name: mode
    description: "'full' (default — plan + author) or 'cadence' (regression + focused exploratory pass)"
    required: false
---

# QA — independent quality discipline

Seed a QA pass onto the guild board. QA is a **discipline that produces work**, not a step in
the feature chain: the qa-strategist plans risk-based coverage, the qa-tester runs the actual
product and authors end-to-end regression specs, and any defect is filed back as a developer fix
task paired with a re-verify qa-tester task that empirically confirms the fix.

**QA's two durable outputs are board rows.** The strategist writes the risk map as `coverage`
rows; the tester files defects as `bug` rows and stamps the areas it drove. That is what puts
QA's work in `v_brief`, in the dashboard's Bugs and Coverage views, and in reach of a cadence.
`.guild/qa/` still holds the charter, the missions, the session logs and the regression
manifest — the thinking, not the records.

Three skills carry the detail; load what you need:
- `guild:warehouse` — how to write SQL against the board at all. **Load it first.**
- `guild:qa-mindset` — the discipline (pillars, what-if catalog, hybrid oracle)
- `guild:qa-artifacts` — which output is a row, which is prose, and the exact SQL for each

## Step 1 — is there a guild

```bash
export PATH="$HOME/.turso:$PATH"
DB=.guild/guild.db
[ -f .guild/config.yaml ] || echo "no guild here"
q() { printf '%s\n' "$1" | tursodb -q -m list "$DB"; }
```

`-m list`, always — the default `pretty` mode truncates long values with an ellipsis, and a
clipped requirement body is a QA pass planned against the wrong oracle.

Not found:
```
No guild found. Run /guild:check-in to initialize first.
```
Stop here.

## Step 2 — ensure the QA workspace

```bash
mkdir -p .guild/qa/missions .guild/qa/sessions
```

## Step 3 — scope and mode

- **scope** — `product` (a full pass) or a named area/flow. If absent, ask:
  `What should QA cover? ("product" for a full pass, or a flow like "checkout")`
- **mode** — `full` (default) or `cadence`.

## Step 4 — the standing QA umbrella requirement

QA tasks anchor to a requirement, and there is **one** evergreen umbrella reused across every
pass. Look for it before creating it:

```sql
SELECT id, status FROM requirement WHERE title = 'Product QA & E2E Regression';
```

If it exists, use that id and skip to Step 5. If not, create it — and **write the whole document
in the one INSERT**. The body crosses as hex, because it contains `#`, `|` and lines that could
end in `;`:

```bash
hex=$(xxd -p < /tmp/qa-umbrella.md | tr -d '\n')       # never echo; never round-trip via $( )
```

```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'orchestrator' WHERE key = 'actor';

INSERT INTO requirement (id, phase_id, title, body, status, priority, created_at, updated_at)
SELECT 'REQ-' || printf('%03d', COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)), 0) + 1),
       NULL, 'Product QA & E2E Regression', CAST(x'<hex-body>' AS TEXT), 'in-progress', 3,
       strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM requirement
RETURNING id, status;
```

It opens `in-progress` and **stays there forever** — it is standing work, not a feature, and it
is deliberately never included in a release. `phase_id` is NULL: QA is not a stage of anything.

The umbrella's body, for reference:

```markdown
# Product QA & E2E Regression

## Summary

Umbrella for the guild's independent QA discipline: risk-based coverage planning, empirical
testing of the running product, end-to-end regression specs, and defect findings. Standing —
not tied to a single feature.

## User Stories

### US-1: Risk-based coverage
**As a** maintainer **I want** the highest-risk product areas covered first
**So that** a regression in something that matters is caught before release.

### US-2: Committed e2e regression
**As a** maintainer **I want** e2e specs committed to the project's test dir and run in CI
**So that** the suite keeps working without a QA pass.

## Technical Considerations

- e2e specs live in the project's real test dir and run in CI.
- Defects are `bug` rows and quality areas are `coverage` rows — both on the board.
- The charter, missions, session logs and regression manifest live under `.guild/qa/`.

## Out of Scope

- Unit and integration tests — owned by `test-writer`, planned by `test-planner`.
```

## Step 5 — seed the strategist ticket

One ticket, whole body in the one INSERT — there is no ticket file to edit afterwards, and
anything you leave out stays out.

```sql
INSERT INTO task (id, requirement_id, title, objective, body, status, priority, agent,
                  created_at, updated_at)
SELECT 'TASK-' || printf('%03d', (SELECT COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)),0)+1 FROM task)),
       r.id, CAST(x'<hex-title>' AS TEXT), CAST(x'<hex-objective>' AS TEXT),
       CAST(x'<hex-body>' AS TEXT), 'todo', 2, NULL,
       strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM requirement r WHERE r.id = 'REQ-004'
RETURNING id, status;
```

The `FROM requirement r WHERE r.id = …` **is** the referential check: a bad requirement id
returns zero rows and writes nothing, which matters because a failing statement does not stop
the script.

Declare the capability rather than pinning the agent — that is what lets the matcher work and
what makes a roster gap visible if the qa-strategist is ever missing:

```sql
INSERT INTO task_capability (task_id, capability, required)
SELECT t.id, 'qa-planning', 1 FROM task t WHERE t.id = 'TASK-042'
ON CONFLICT DO NOTHING;
```

Ticket body:

```markdown
## Objective

Plan a {mode} QA pass for: {scope}. Map the risk surface onto the board as `coverage` rows,
write the charter, then create the qa-tester mission tickets.

## Context

- Requirement: {REQ id}
- Mode: {full | cadence}
- Scope: {product | named area}
- Existing risk surface: `SELECT id, area, risk, spec_path FROM coverage ORDER BY id`
  (upsert into it — never fork a new id for an area that already has one)
- Charter: .guild/qa/charter.md (create or update in place)

## Acceptance Criteria

- [ ] Oracle sources resolved (specs / board / code+app / user)
- [ ] One `coverage` row per quality area, with risk, spec path and reasoning
- [ ] Charter written with the quality definition and the oracle ledger
- [ ] qa-tester mission tickets created, prioritized by what `v_coverage_due` returns
```

Then check the words you used are real, because an unknown capability inserts fine and matches
nobody, silently, forever:

```sql
SELECT side, owner, capability FROM v_capability_unknown;
```

## Step 6 — confirm and offer to run

```
QA pass seeded.

  Requirement: REQ-NNN — Product QA & E2E Regression
  Task: TASK-NNN — QA strategy: {scope} (qa-planning)
  Mode: {full | cadence}

The strategist will map risk and declare tester missions; testers then run the app,
author e2e specs, and file any bugs as developer fix tasks.

Run /guild:check-in to execute now, or I can start the work cycle for you.
```

If they want to proceed immediately, hand off to `guild:check-in`'s work cycle — QA tickets
dispatch like any other.

## How QA flows through the orchestrator

QA reuses all existing orchestration; nothing is special-cased.

1. `qa-strategist` runs → declares `qa-tester` missions as follow-up tickets.
2. The orchestrator dispatches `qa-tester` tickets **sequentially — one at a time, never in
   parallel.** Each tester drives its own dev server and Playwright instance, so concurrent
   testers collide on the same port. The schema says this too: `agent.serial = 1` on qa-tester.
   Honor it — nothing enforces it.
3. Each tester runs the app, authors specs, files each defect as a `bug` row, stamps the areas
   it genuinely drove (`coverage.last_inspected_at`), and for every bug declares a **pair** of
   follow-ups: a `developer` fix ticket, then a re-verify `qa-tester` ticket. Declared in that
   order, so the second gets the higher id and the cursor runs fix, then re-verify. Wire the
   order explicitly rather than trusting id order:

   ```sql
   INSERT INTO task_dependency (task_id, depends_on)
   SELECT 'TASK-051', 'TASK-050'
    WHERE EXISTS (SELECT 1 FROM task WHERE id = 'TASK-051')
      AND EXISTS (SELECT 1 FROM task WHERE id = 'TASK-050')
   RETURNING task_id || ' after ' || depends_on;
   ```
4. The re-verify qa-tester **is** the verification tail for QA fixes: it empirically confirms the
   fix, promotes the spec from `fixme` to passing, and closes the bug:

   ```sql
   UPDATE bug SET status = 'fixed' WHERE id = 'BUG-014' AND status IN ('open','fixing')
   RETURNING id, status;
   ```

   QA fixes get no test-writer or reviewer tickets — a reviewer on the standing umbrella would
   be gated behind every other pending QA ticket, forever.

After a pass, everything QA produced is one query away:

```sql
SELECT id, severity, status, found_by, requirement_id, fix_task_id, title FROM v_open_bugs;
SELECT id, risk, interval_days, days_since, spec_path, area FROM v_coverage_due;
SELECT fact, value FROM v_brief;
```

## Standing cadence — opt-in, per project

QA can run on a schedule so quality is checked continuously. **Opt-in per project**; it does not
auto-arm, and a shift never starts one.

```
/schedule create "weekly product QA" --cron "0 9 * * 1" --prompt "/guild:qa product cadence"
```

A `cadence` pass skips full re-planning and asks the board what is due:

```sql
SELECT id, area, risk, interval_days, days_since, spec_path FROM v_coverage_due;
```

`days_since` is **NULL for an area nobody has ever inspected** — that is not "0 days ago", and
reporting it as such lies about the state of the product.

The strategist then declares a single qa-tester mission that (a) runs the existing regression
suite from `.guild/qa/regression.md`, and (b) does a focused exploratory pass on exactly those
areas, filing anything new it finds. **If nothing is due, the pass ends there** — that is the
cadence working, not failing.

## Rules

- **Never overwrite** the charter or the regression manifest — update in place.
- **Defects are `bug` rows**, not markdown. There is no `.guild/qa/ledger.md`.
- **The risk map is `coverage` rows**, not a charter table. One id per area, upserted.
- **IDs are derived in the INSERT** — `MAX(n) + 1` in the same statement, never a counter you
  keep, never a read-then-write.
- **Status is a column.** Move it with a guarded `UPDATE … WHERE status = <expected>
  RETURNING`; zero rows back means somebody already moved it, which is information.
- **Committed specs live in the repo's e2e dir**, never under `.guild/`.
- **Only stamp `last_inspected_at` for an area actually exercised.** The stamp is a claim, and a
  trigger fires on that column alone so re-saving risk or notes must not make a stale area read
  as fresh.
- **Don't bake in bugs** — suspect behavior is filed or asked, never asserted as correct (the
  hybrid oracle rule).
