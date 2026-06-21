# Agent Chains — Follow-up Patterns

This document defines the standard chains that drive the guild's continuous cycle: **Requirements → Tasks → Plans → Tasks**.

## The Core Cycle

```
User provides input
  └→ product-owner: gathers details, writes REQ document
      └→ architect: reads REQ, explores codebase, writes PLAN, declares dev tasks
          └→ developer ×N: implements code per plan
              └→ test-writer: writes and runs unit tests
                  └→ 4 reviewers in parallel:
                      ├── reviewer-security
                      ├── reviewer-architecture
                      ├── reviewer-business-logic
                      └── reviewer-edge-case
                          ├→ [all approved] requirement complete
                          └→ [any issues] developer: fix tasks → test-writer → reviewers again
```

## Chain 1: Standard Requirement Flow

The most common chain. A new requirement flows through all roles.

| Step | Agent | Input | Output | Follow-up |
|------|-------|-------|--------|-----------|
| 1 | product-owner | User conversation | REQ document | architect task |
| 2 | architect | REQ document + codebase | PLAN document | developer tasks (orchestrator auto-creates test + review) |
| 3 | developer (×N) | PLAN + REQ + codebase | Code changes | (none — orchestrator creates test task) |
| 4 | test-writer | Code changes + REQ + PLAN | Unit tests | fix tasks if bugs found |
| 5 | 4 reviewers (parallel) | Code + tests + REQ + PLAN | Review report | fix tasks OR approval |

### Step 4: Test Writer

**Input task title pattern:** "Write unit tests for {feature}"

**What they do:**
- Read all implemented code from the developer tasks
- Identify testable units and map acceptance criteria to test cases
- Write unit tests following the project's existing test patterns
- Run the tests and verify they pass
- If tests reveal implementation bugs, declare fix tasks for the developer

**Follow-up (if bugs found):**
```
- Fix: {bug found during testing} | agent: developer | priority: high
```

The orchestrator auto-creates the review task after the test-writer completes (and any fix tasks are resolved).

**Step 5 detail**: The orchestrator spawns all 4 specialized reviewers in parallel:
- `reviewer-security` — OWASP Top 10, injection, auth, data handling
- `reviewer-architecture` — plan alignment, patterns, separation of concerns
- `reviewer-business-logic` — acceptance criteria, business rules, testability
- `reviewer-edge-case` — boundary conditions, null handling, error scenarios

Each writes independently to the task's Work Log and declares fix tasks if needed. All 4 must pass for the review to be approved.

### Step 1: Product Owner

**Input task title pattern:** "Gather requirements for {feature}"

**What they do:**
- Interview user via AskUserQuestion
- Write/update the requirement document at `.guild/requirements/REQ-NNN.md`
- Update requirement status from `draft` to `in-progress`

**Follow-up declaration:**
```
- Plan {feature} implementation | agent: architect | priority: high
```

### Step 2: Architect

**Input task title pattern:** "Plan {feature} implementation"

**What they do:**
- Read the requirement document
- Explore the codebase for existing patterns
- Write a plan at `.guild/plans/PLAN-NNN.md`
- Declare implementation tasks derived from the plan

**Follow-up declaration:**
```
- Implement {component-1} | agent: developer | priority: high
- Implement {component-2} | agent: developer-svelte | priority: high
- Implement {component-3} | agent: developer | priority: medium
```

The architect declares only developer tasks. It does **not** declare a test-writer
or review task — the orchestrator auto-creates the test-writer after all developer
tasks for the plan complete, and the review after the test-writer completes
(check-in step 4.5). This guarantees reviewers never run before tests exist.

The architect picks the developer agent per slice. `developer-svelte` (sonnet, pre-loaded with Svelte 5 / SvelteKit knowledge via the `guild:svelte-*` skills) handles work touching Svelte components, SvelteKit routes, server hooks, and `svelte.config.js`. `developer` handles everything else. Both are dispatched the same way and both honor the `plan-slice` modifier.

### Step 3: Developer

**Input task title pattern:** "Implement {component}"

**What they do:**
- Read their task, the linked plan, and the requirement
- Implement the code following codebase patterns
- Append progress to Work Log

**Follow-up declaration:** None. The developer does NOT declare follow-ups. Instead, the orchestrator automatically creates a **test-writer** task after ALL developer tasks for the same plan complete, and then a **review** task after that test-writer completes (check-in step 4.5). This is handled in the check-in skill's work cycle logic and guarantees reviewers run after tests exist.

### Step 4: Reviewers (4 in parallel)

**Input task title pattern:** "Review {feature} implementation"

When the orchestrator encounters a task with `agent: reviewer`, it spawns 4 specialized reviewers in parallel — all reading the same task file:

| Reviewer | Focus |
|----------|-------|
| `reviewer-security` | OWASP Top 10, injection, auth, data handling |
| `reviewer-architecture` | Plan alignment, patterns, separation of concerns |
| `reviewer-business-logic` | Acceptance criteria, business rules, testability |
| `reviewer-edge-case` | Boundary conditions, null handling, error scenarios |

Each reviewer:
- Reads the task, requirement, and plan
- Reviews through their specialized lens only
- Appends findings to the task Work Log under their own heading
- Independently declares fix tasks if critical/major issues found

**After all 4 return:**
- ANY fix tasks declared → orchestrator creates developer fix tasks. When those
  complete, round-aware auto-test creates a round-2 test-writer, then auto-review
  creates the round-2 review (capped at 2 rounds; see Chain 4).
- ALL 4 wrote PASS → requirement can be marked done

## Chain 2: Research-First Flow

When a requirement needs technology research before planning.

```
product-owner → researcher → architect → developer ×N → reviewer
```

This flow can be entered two ways:

**2a. Product owner declares research upfront** (when they already know research is needed):
```
- Research {technology/approach} for {feature} | agent: researcher | priority: high
- Plan {feature} implementation | agent: architect | priority: high | depends-on: TASK-NNN
```

**2b. Architect triggers research gate** (when the architect discovers during codebase analysis that they cannot plan responsibly without more information):

The architect runs Step 3.5 of its workflow — if research is needed, it skips plan-writing entirely and declares:
```
- Research {specific topic} for {feature} | agent: researcher | priority: high
- Plan {feature} implementation (post-research) | agent: architect | priority: high | depends-on: TASK-RESEARCH
```

The orchestrator resolves the literal `TASK-RESEARCH` placeholder to the actual researcher task ID assigned in that batch. The architect marks itself `done` (the research gate decision WAS its deliverable). The new architect task runs after the researcher completes, with findings available in the researcher's work log.

In both cases, the architect task that produces the plan is blocked until the researcher completes.

**Research knowledge persists:** the researcher writes findings to `.guild/docs/{topic-slug}.md`, not the task work log. These docs are evergreen — they survive release archiving and board clears. Before researching, the researcher checks existing docs and reuses them; before designing, the architect checks existing docs and may skip the research gate entirely if coverage is sufficient.

## Chain 3: Bug Fix Flow

Simplified chain for bug fixes — skip the architect.

```
product-owner → developer → reviewer
```

**Product owner declares:**
```
- Fix: {bug description} | agent: developer | priority: high
```

The developer's task for bug fixes doesn't go through the architect because there's no plan needed — the requirement itself describes the fix.

After the developer completes, the orchestrator creates a review task automatically.

## Chain 4: Review Fix Loop

When any reviewer finds issues, a fix loop starts. Maximum 2 rounds.

```
4 reviewers → developer ×N (fixes) → test-writer (round 2) → 4 reviewers (round 2) → done or escalate
```

The loop is driven entirely by the orchestrator's **round-aware** auto-test and
auto-review (check-in step 4.5), keyed on monotonic TASK IDs — not by reviewers
declaring re-review tasks:
- Reviewers declare only `Fix: … | agent: developer` tasks.
- When those developer fixes complete, auto-test fires again (newer developer work
  than the last test run) → a round-2 test-writer.
- When that test-writer completes, auto-review fires again (newer tests than the
  last review) → a round-2 review. Titled `Re-review …`.

**Round 2 reviewer behavior:**
- If still issues after round 2: write `ESCALATE` in the Work Log (reviewers do
  NOT declare a third round of fixes — the loop is capped at 2).
- After any review completes, the orchestrator scans reviewer Work Logs for
  `ESCALATE`, and also stops if a round-2 review still declares fixes, then asks the
  user whether to continue fixing or accept as-is.

## Chain 5: QA Discipline (peer, not a chain step)

QA is **independent** of the feature chain. Where the feature chain *terminates*
at a review gate, QA is a standing discipline that runs against the whole product
and *produces* board work — it sits beside the chain like the product-owner does,
not inside it.

```
        ┌──────── feature chain (REQ → plan → dev → review → done) ────────┐
        │                                                                  ▼
   QA discipline ──finds bugs──▶ board (fix tasks) ──▶ dev chain fixes ──▶ QA re-verifies
        ▲                                                                  │
        └──────────────────── on-demand / standing cadence ───────────────┘
```

**Entry:** the `guild:qa` skill (on-demand or scheduled cadence) seeds a
`qa-strategist` task anchored to a standing "Product QA & E2E Regression" umbrella
requirement. QA is never auto-spawned after a developer task.

```
qa-strategist (charter + risk map + coverage matrix)
  └→ qa-tester ×N, run SEQUENTIALLY (run the product, explore, author Playwright specs)
      ├→ bugs → developer fix tasks (Chain 3 bug-fix flow) → re-verify qa-tester
      └→ confirmed-good high-risk paths → committed e2e specs + regression manifest
```

**qa-testers run one at a time, never in parallel.** Each tester launches the
running product (dev/preview server + Playwright); concurrent testers would
collide on the same port. The ×N above is the *total* number of tester missions,
dispatched sequentially — not a parallel batch like developers.

| Step | Agent | Input | Output | Follow-up |
|------|-------|-------|--------|-----------|
| 1 | qa-strategist | scope + oracle sources + running app | charter, risk map, missions | qa-tester task per mission |
| 2 | qa-tester (×N) | mission + running app | e2e specs (in repo) + bug ledger | developer fix tasks + re-verify qa-tester |

**Ownership boundary:** `test-writer` owns **unit** tests (inside the feature
chain); `qa-tester` owns **e2e/integration** tests (the QA discipline). E2e specs
live in the project's real e2e dir and run in CI; `developer`/`developer-svelte`
**co-maintain** them when a feature change alters asserted behavior, and QA
reviews the update.

**Oracle:** the hybrid rule — lock current behavior as the regression baseline
when it agrees with a spec/ticket/user or is clearly sane; flag suspect behavior
as a bug instead of asserting it; ask the user when ambiguous. See the
`guild:qa-mindset` skill.

**Persistence:** QA artifacts live under `.guild/qa/` (charter, missions,
sessions, ledger, regression manifest) and are evergreen — they survive releases
and `clear-board`, like `.guild/docs/`.

## Orchestrator Responsibilities in the Chain

The orchestrator (check-in skill) handles these chain logistics:

1. **Materializing follow-ups**: Read "Follow-up Tasks" section, create actual task files, update BOARD.md
2. **Auto-creating review tasks**: After all developer tasks for a plan complete, create a reviewer task (even though developers don't declare one)
3. **Resolving `depends-on: all-developer`**: Replace with actual task IDs of all developer tasks created in the same batch
4. **Tracking requirement progress**: Update the Progress column in BOARD.md Requirements table
5. **Marking requirements done**: When a reviewer approves (no follow-ups), mark the requirement as `done`
6. **Handling escalation**: When reviewer writes "ESCALATE", prompt the user for direction

## Parallel Execution

When dispatching developer tasks, the orchestrator can parallelize:

- **3+ pending developer tasks for the same plan** → spawn 3 developer agents simultaneously
- **< 3 pending developer tasks** → spawn 1 developer agent

Rules for parallel execution:
- Only the orchestrator updates BOARD.md (after all agents return)
- Each developer writes only to their own task file
- Developers write code to different files (the plan ensures non-overlapping scope)

**Exception — `qa-tester` tasks are never parallelized.** They dispatch strictly
one at a time, even when 3 or more are pending for the same QA pass. Each tester
drives its own dev server + Playwright, so concurrent testers would fight over
the same port. Spawn one qa-tester, wait for it to finish, then spawn the next.
