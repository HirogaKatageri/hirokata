---
name: qa
description: >
  This skill should be used when the user wants quality assurance on the product
  itself — "QA the product", "QA the checkout flow", "run a QA pass", "build
  comprehensive e2e tests", "write regression tests", "test the running app",
  "what-if testing", or any request to empirically test the product and author
  end-to-end regression coverage. Seeds the guild's independent QA discipline:
  a qa-strategist plans risk-based coverage, then qa-testers run the app and
  author Playwright specs while filing bugs back to the board.
version: 2.0.0
user-invocable: true
arguments:
  - name: scope
    description: "What to QA — 'product' for a full pass, or a named area/flow (e.g. 'checkout')"
    required: false
  - name: mode
    description: "'full' (default — plan + author) or 'cadence' (regression + focused exploratory pass)"
    required: false
---

# QA — Independent Quality Discipline

Seed a QA pass onto the guild board. QA is a **discipline that produces work**,
not a step in the feature chain: the qa-strategist plans risk-based coverage, the
qa-tester runs the actual product and authors end-to-end regression specs, and any
defects are filed back as developer fix tasks, each paired with a re-verify
qa-tester task that empirically confirms the fix.

The discipline and artifact formats live in two reference skills the QA agents
load automatically; consult them if you need detail while seeding:
- `guild:qa-mindset` — the discipline (pillars, what-if catalog, hybrid oracle)
- `guild:qa-artifacts` — `.guild/qa/` artifact formats

## Step 1: Check for Guild

Check for `.guild/config.yaml` (v5 has no `state.yaml`). If not found:

```
No guild found. Run /guild:check-in to initialize first.
```

Stop here.

## Step 2: Ensure QA Workspace

Create the QA artifact directories if absent (idempotent):

```bash
mkdir -p .guild/qa/missions .guild/qa/sessions
```

## Step 3: Resolve Scope and Mode

Parse from `$ARGUMENTS` / user input:
- **scope** — `product` (full pass) or a named area/flow. If absent, ask:
  ```
  What should QA cover? ("product" for a full pass, or a flow like "checkout")
  ```
- **mode** — `full` (default) or `cadence`.

## Step 4: Ensure the QA Umbrella Requirement

Bind the CLI: `GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"`.

QA tasks must anchor to a requirement. Reuse a single evergreen QA umbrella REQ
across passes. Look for an existing one titled "Product QA & E2E Regression" by
reading the ids from `"$GUILD" list req` and checking each with
`"$GUILD" meta REQ-NNN title`.

If none exists, create it. **Write the whole document in the same call** — there is
no requirement file to Edit afterwards, and Stage 1 has no writer for a requirement
body after creation, so anything left out here stays out:

```bash
REQ=$("$GUILD" new req --title "Product QA & E2E Regression" --date {today} --body "$(cat <<'DOC'
# Product QA & E2E Regression

## Summary

Umbrella for the guild's independent QA discipline: risk-based coverage planning,
empirical testing of the running product, end-to-end regression specs, and bug
findings. Standing — not tied to a single feature.

## User Stories

### US-1: Risk-based coverage
**As a** maintainer **I want** the highest-risk product areas covered first
**So that** a regression in something that matters is caught before release.

### US-2: Committed e2e regression
**As a** maintainer **I want** e2e specs committed to the project's test dir and run
in CI **So that** the suite keeps working without a QA pass.

## Technical Considerations

- e2e specs live in the project's real test dir and run in CI.
- The charter, missions, bug ledger and regression manifest live under `.guild/qa/`.

## Out of Scope

- Unit and integration tests — owned by `test-writer`, planned by `test-planner`.
DOC
)")
"$GUILD" move "$REQ" in-progress   # the umbrella is standing/evergreen
```

There is no `status` field to edit — status is a column, and only `guild move` sets it.

## Step 5: Seed the QA Strategist Task

Create the strategist task with the CLI, **passing the whole ticket body in the same
call**. There is no task file to Edit afterwards:

```bash
TASK=$("$GUILD" new task --title "QA strategy: {scope}" --agent qa-strategist \
  --req "$REQ" --date {today} --body "$(cat <<'DOC'
## Objective

Plan a {mode} QA pass for: {scope}. Build/refresh the charter, risk map, and
coverage matrix, then create the qa-tester mission tickets.

## Context

- Requirement: {REQ id}
- Mode: {full | cadence}
- Scope: {product | named area}
- Charter: .guild/qa/charter.md (create or update in place)

## Acceptance Criteria

- [ ] Oracle sources resolved (specs / board / code+app / user)
- [ ] Charter written with quality definition, risk map, coverage matrix
- [ ] qa-tester mission tickets created, prioritized by risk
DOC
)")
```

`--body` replaces the ticket template outright, so what you write is exactly what
`guild read "$TASK"` renders. Do NOT include a `## Work Log` or `## Follow-up Tasks`
heading — those are rendered from the board, and the CLI refuses a body containing
them.
```

The task now lives in `tasks/todo/` and is discoverable by `"$GUILD" next`.

## Step 6: Confirm and Offer to Run

```
QA pass seeded.

  Requirement: REQ-NNN — Product QA & E2E Regression
  Task: TASK-NNN — QA strategy: {scope} (qa-strategist)
  Mode: {full | cadence}

The strategist will map risk and declare tester missions; testers then run the
app, author e2e specs, and file any bugs as developer fix tasks.

Run /guild:check-in to execute now, or I can start the work cycle for you.
```

If the user wants to proceed immediately, hand off to `guild:check-in`'s work
cycle (Step 4 of that skill) — the QA tasks dispatch like any other agent.

## How QA Flows Through the Existing Orchestrator

QA reuses all existing orchestration — no special-casing needed:

1. `qa-strategist` runs → declares `qa-tester` missions as follow-ups.
2. The orchestrator dispatches `qa-tester` tasks **sequentially — one at a time,
   never in parallel** (each tester drives its own dev server + Playwright, so
   concurrent testers would collide on the same port).
3. Each `qa-tester` runs the app, authors specs, and for every bug declares a
   **pair** of follow-ups: a `developer` fix task, then a re-verify `qa-tester`
   task (declared second → higher ID → the cursor runs fix, then re-verify).
4. The re-verify qa-tester IS the verification tail for QA fixes: it empirically
   confirms the fix and promotes the spec from `fixme` to passing. QA fixes do not
   get test-writer/reviewer tickets — a reviewer on the standing QA umbrella REQ
   would be gated behind every other pending QA task.

## Standing Cadence (opt-in, per project)

QA can run on a schedule so quality is checked continuously, not just on demand.
This is **opt-in per project** — it does not auto-arm.

To arm it, schedule a periodic invocation of this skill in `cadence` mode using
your scheduler of choice — e.g. the `/schedule` skill (cloud routine) or `/loop`
for an in-session cadence:

```
/schedule create "weekly product QA" --cron "0 9 * * 1" --prompt "/guild:qa product cadence"
```

A `cadence` pass differs from a full pass: the strategist skips full re-planning
and declares a single qa-tester mission that (a) runs the existing regression
suite from `.guild/qa/regression.md`, and (b) does a focused exploratory pass on
the top-risk areas from the charter — filing anything new it finds. This keeps the
suite green and extends coverage over time without rebuilding the charter.

## Rules

- **Never overwrite** the charter/ledger/regression manifest — update in place.
- **IDs are derived by the CLI** — never hand-assign or maintain counters.
- **No `status` field** — an artifact's status is the directory it lives in.
- **Committed specs live in the repo's e2e dir**, never under `.guild/`.
- **Don't bake in bugs** — suspect behavior is filed or asked, never asserted as
  correct (the hybrid oracle rule).
