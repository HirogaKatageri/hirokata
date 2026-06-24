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
version: 1.0.0
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
defects are filed back as developer fix tasks that flow through the normal bug-fix
chain.

The discipline and artifact formats live in two reference skills the QA agents
load automatically; consult them if you need detail while seeding:
- `guild:qa-mindset` — the discipline (pillars, what-if catalog, hybrid oracle)
- `guild:qa-artifacts` — `.guild/qa/` artifact formats

## Step 1: Check for Guild

Read `.guild/state.yaml`. If not found:

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

QA tasks must anchor to a requirement. Reuse a single evergreen QA umbrella REQ
across passes. Glob `.guild/requirements/` for one titled "Product QA & E2E
Regression". If none exists, create it using the next `next-req` counter from
`.guild/state.yaml`:

```markdown
---
id: REQ-NNN
title: "Product QA & E2E Regression"
status: in-progress
created: {today}
---

# Product QA & E2E Regression

## Summary
Umbrella for the guild's independent QA discipline: risk-based coverage planning,
empirical testing of the running product, end-to-end regression specs, and bug
findings. Standing — not tied to a single feature.

## User Stories
_QA missions and findings attach here; see `.guild/qa/charter.md`._

## Technical Considerations
E2e specs live in the project's real test dir and run in CI. Devs co-maintain
specs when feature changes alter asserted behavior.

## Out of Scope
Unit tests (owned by test-writer).
```

Increment `next-req` in `.guild/state.yaml` if the requirement was newly created.

## Step 5: Seed the QA Strategist Task

Read `next-task` from `.guild/state.yaml`. Create `.guild/tasks/TASK-NNN.md`:

```markdown
---
id: TASK-NNN
title: "QA strategy: {scope}"
agent: qa-strategist
status: todo
requirement: REQ-NNN
plan: null
priority: high
created: {today}
---

## Objective

Plan a {mode} QA pass for: {scope}. Build/refresh the charter, risk map, and
coverage matrix, then declare qa-tester missions.

## Context

- Requirement: .guild/requirements/REQ-NNN.md
- Mode: {full | cadence}
- Scope: {product | named area}
- Charter: .guild/qa/charter.md (create or update in place)

## Acceptance Criteria

- [ ] Oracle sources resolved (specs / board / code+app / user)
- [ ] Charter written with quality definition, risk map, coverage matrix
- [ ] Missions declared as qa-tester follow-ups, prioritized by risk

## Work Log

## Follow-up Tasks
```

Increment `next-task` in `.guild/state.yaml`. The task is now discoverable by scanning `.guild/tasks/`.

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
3. Each `qa-tester` runs the app, authors specs, and declares `developer` fix
   tasks for bugs (+ a re-verify `qa-tester` task).
4. Fix tasks flow through the normal bug-fix chain (developer → review). On fix,
   the re-verify qa-tester confirms and promotes the spec from `fixme` to passing.

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
- **Always increment counters** to avoid ID collisions.
- **Committed specs live in the repo's e2e dir**, never under `.guild/`.
- **Don't bake in bugs** — suspect behavior is filed or asked, never asserted as
  correct (the hybrid oracle rule).
