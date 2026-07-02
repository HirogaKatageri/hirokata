# Agent Chains — Follow-up Patterns

This document defines the standard chains that drive the guild's continuous cycle:
**Requirements → Tasks → Plans → Tasks**. Tickets are walked by a single cursor in **ID order**
(see `state-format.md`); development runs **in parallel by default** — the architect groups dev
tickets into `parallel-group` waves (verified disjoint files) that dispatch concurrently — and
reviews fan out 4-wide.

## The Core Cycle

```
User provides input
  └→ product-owner: discusses & refines requirements, writes REQ document
      └→ architect: reads REQ, explores codebase, writes PLAN,
         declares dev tickets + the test-planner + reviewer tail
          └→ developer ×N: implement code per plan, in parallel-group
             waves (disjoint files); foundational tickets run solo first
              └→ test-planner: inventories the diff, writes the test plan,
                 declares the test-writer ticket(s)
                  └→ test-writer: writes and runs unit & integration tests
                      └→ 4 reviewers in parallel:
                          ├── reviewer-security
                          ├── reviewer-architecture
                          ├── reviewer-business-logic
                          └── reviewer-edge-case
                              ├→ [all approved] requirement complete → done
                              └→ [any issues] developer fixes → test-writer → reviewers again
```

## Chain 1: Standard Requirement Flow

The most common chain. A new requirement flows through all roles.

| Step | Agent | Input | Output | Follow-up |
|------|-------|-------|--------|-----------|
| 1 | product-owner | User conversation | REQ document | architect ticket |
| 2 | architect | REQ document + codebase | PLAN document | developer tickets **+ test-planner ticket + reviewer ticket** |
| 3 | developer (×N, parallel-group waves) | PLAN slice + REQ + codebase | Code changes | (none) |
| 4 | test-planner | Dev work logs + REQ + PLAN | Test plan (`slice-test-plan.md`) | test-writer ticket(s) |
| 5 | test-writer (×1–2) | Test plan + changed files | Unit & integration tests | fix tickets if bugs found |
| 6 | 4 reviewers (parallel) | Changed files + tests + REQ + PLAN | Review report | fix tickets OR approval |

The developer tickets, the test-planner ticket, and the reviewer ticket are all created at once
from the architect's follow-ups. Because the cursor runs in ID order, the test-planner is reached
only after every developer ticket is `done`. The test-writer ticket(s) are created later by the
test-planner and get **higher IDs than the reviewer ticket — that's fine**: the reviewer ticket is
**gated** (the orchestrator dispatches it only when every other ticket for its requirement is
`done`, the N/N gate), so the review always runs last, after the planner-declared test-writer
tickets complete. The gate is what turns ID order into the pipeline
dev → test-plan → tests → review.

### Step 1: Product Owner

**Input task title pattern:** "Gather requirements for {feature}"

**Follow-up declaration:**
```
- Plan {feature} implementation | agent: architect
```

### Step 2: Architect

**Input task title pattern:** "Plan {feature} implementation"

**Follow-up declaration (dev tickets + the tail — every line carries `plan:`, since the
architect's own ticket predates the plan):**
```
- Implement {component-1} | agent: developer | plan: PLAN-NNN | plan-slice: {slug-1}
- Implement {component-2} | agent: developer-svelte | plan: PLAN-NNN | plan-slice: {slug-2} | parallel-group: A
- Implement {component-3} | agent: developer | plan: PLAN-NNN | plan-slice: {slug-3} | parallel-group: A
- Plan tests for {feature} | agent: test-planner | plan: PLAN-NNN
- Review {feature} implementation | agent: reviewer | plan: PLAN-NNN
```

The `plan-slice` value is the slice **slug** (e.g. `signup`), not a path — agents resolve the
current file with `guild slice PLAN-NNN {slug}`, since slice locations move with the plan's status.

The architect emits the `test-planner` and `reviewer` tail explicitly. The orchestrator does not
auto-create them in the initial chain. Listing dev tickets first keeps their IDs lower, so they run
before the tail. **Parallel is the default**: the architect designs slices for disjoint file sets
and puts every dev ticket it can into a `parallel-group` wave (components 2 and 3 above) — the
orchestrator dispatches each wave concurrently. A ticket stays ungrouped only when it is
foundational (others build on it) or its file set can't be bounded; the tail tickets never carry
a group.

The architect picks the developer agent per slice. `developer-svelte` (sonnet, pre-loaded with
Svelte 5 / SvelteKit knowledge via the `guild:svelte-*` skills) handles work touching Svelte
components, SvelteKit routes, server hooks, and `svelte.config.js`. `developer` handles everything
else. Both honor the `plan-slice` modifier.

### Step 3: Developer

**Input task title pattern:** "Implement {component}"

Developers run in **parallel-group waves**: the orchestrator dispatches every dev ticket sharing a
group concurrently (the architect verified their slices touch disjoint files, so they safely share
the working tree). Ungrouped tickets (foundational work) run solo in ID order. Each developer reads
its slice, implements, appends to the Work Log, and reports done. **Developers declare no
follow-ups** (the architect already emitted the tail), except a `Fix:`/`Clarify:` ticket if they
discover a genuine blocker mid-work.

### Step 4: Test Planner

**Input task title pattern:** "Plan tests for {feature}"

- Inventory what development produced (dev Work Logs + `git diff`) into a **Changed Files
  Inventory**, survey the test infrastructure, and map every acceptance criterion to unit and
  integration test cases.
- Write the plan as a plan slice: `PLAN-NNN/slice-test-plan.md` (resolve with
  `guild slice PLAN-NNN test-plan`). Downstream, the test-writer implements it and the reviewers
  reuse its inventory to scope their reading — nobody re-derives the analysis.
- Declare the test-writer ticket(s) — one combined, or one unit + one integration — each carrying
  `plan-slice: test-plan`:
  ```
  - Write unit tests for {feature} | agent: test-writer | plan-slice: test-plan
  - Write integration tests for {feature} | agent: test-writer | plan-slice: test-plan
  ```

### Step 5: Test Writer

**Input task title pattern:** "Write unit tests for {feature}" / "Write integration tests for
{feature}" / "Write unit & integration tests for {feature}"

- Read the test plan slice, implement the section(s) the ticket title names, and run the suite.
- E2e tests are out of scope (QA discipline).
- If tests reveal implementation bugs, declare `Fix: … | agent: developer` tickets.

### Step 6: Reviewers (4 in parallel)

**Input task title pattern:** "Review {feature} implementation" (`agent: reviewer`)

When the orchestrator encounters a `reviewer` ticket whose N/N gate is satisfied, it spawns 4
specialized reviewers in parallel on the same ticket:

| Reviewer | Focus |
|----------|-------|
| `reviewer-security` | OWASP Top 10, injection, auth, data handling |
| `reviewer-architecture` | Plan alignment, patterns, separation of concerns |
| `reviewer-business-logic` | Acceptance criteria, business rules, testability |
| `reviewer-edge-case` | Boundary conditions, null handling, error scenarios |

Each reviewer reads the ticket, requirement, and plan overview, then scopes its code reading to the
test plan's **Changed Files Inventory** (`guild slice PLAN-NNN test-plan`) rather than re-scanning
the codebase; reviews through its lens; appends findings to the shared Work Log under its own
heading; and independently declares `Fix:` tickets if needed.

**After all 4 return:**
- ANY `Fix:` tickets declared → the orchestrator creates the developer fix tickets, then appends
  one round-2 `test-writer` ticket and one round-2 `Re-review …` ticket behind them (see Chain 4).
- ALL 4 wrote PASS → the requirement is marked `done`.

## Chain 2: Research-First Flow

When a requirement needs technology research before planning.

```
product-owner → researcher → architect → developer ×N → test-planner → test-writer → reviewer
```

Two entry points:

**2a. Product owner declares research upfront:**
```
- Research {technology/approach} for {feature} | agent: researcher
- Plan {feature} implementation | agent: architect
```

**2b. Architect triggers the research gate** (discovers mid-analysis it cannot plan responsibly):
```
- Research {specific topic} for {feature} | agent: researcher
- Plan {feature} implementation (post-research) | agent: architect
```

In both cases the researcher ticket is created **before** the post-research architect ticket, so it
gets a lower ID and the cursor runs it first — no `depends-on` needed. The architect marks its own
gate-decision ticket `done`; the new architect ticket produces the plan after the researcher
finishes, with findings available in `.guild/docs/`.

**Research knowledge persists:** the researcher writes findings to `.guild/docs/{topic-slug}.md`,
not the task work log. These docs are evergreen — they survive release archiving and board clears.
Before researching, the researcher checks existing docs and reuses them; before designing, the
architect checks existing docs and may skip the research gate entirely.

## Chain 3: Bug Fix Flow

Simplified chain for bug fixes — skip the architect **and the test-planner** (a scoped fix doesn't
need a test plan). Because there is no architect to emit the tail, the **product-owner emits it**:

```
product-owner → developer → test-writer → reviewer
```

**Product owner declares:**
```
- Fix: {bug description} | agent: developer
- Write unit tests for {fix} | agent: test-writer
- Review {fix} | agent: reviewer
```

With no `plan-slice`, the test-writer falls back to deriving scope from the developer's Work Log,
and reviewers scope their reading the same way.

## Chain 4: Review Fix Loop

When any reviewer finds issues, a fix loop starts. **Maximum 2 review rounds.**

```
4 reviewers → developer ×N (fixes) → test-writer (round 2) → 4 reviewers (round 2) → done or escalate
```

The loop is driven by **declaration + one orchestrator-appended tail per round** — no ID
arithmetic:
- Reviewers declare only `Fix: … | agent: developer` tickets.
- After a review round that produced fixes, the orchestrator creates the fix tickets, then appends
  **one** `test-writer` ticket and **one** `Re-review …` ticket behind them. The fix-loop
  test-writer ticket carries `plan-slice: test-plan` when the requirement has a plan — the round-1
  test plan still governs; the test-planner is never re-run in the fix loop.
- The cursor walks fixes → test → re-review in ID order; the re-review's N/N gate holds it until the
  fixes and tests are `done`.

**Round cap (count `reviewer` tickets for the requirement):**
- If a `Re-review …` ticket (the 2nd review) completes and still has `Fix:` declarations, do NOT
  append a 3rd round. Stop and ask the user: "Round 2 review still has open issues — keep fixing, or
  accept as-is?"
- Round-2 reviewers write `ESCALATE` in the Work Log when issues persist. After any review
  completes, the orchestrator scans reviewer Work Logs for `ESCALATE` and stops the loop with the
  same question if found.

## Chain 5: QA Discipline (peer, not a chain step)

QA is **independent** of the feature chain. Where the feature chain *terminates* at a review gate,
QA is a standing discipline that runs against the whole product and *produces* board work — it sits
beside the chain like the product-owner does, not inside it.

```
        ┌──────── feature chain (REQ → plan → dev → test → review → done) ────────┐
        │                                                                         ▼
   QA discipline ──finds bugs──▶ board (fix tickets) ──▶ dev chain fixes ──▶ QA re-verifies
        ▲                                                                         │
        └──────────────────────── on-demand / standing cadence ──────────────────┘
```

**Entry:** the `guild:qa` skill seeds a `qa-strategist` ticket anchored to a standing "Product QA &
E2E Regression" umbrella requirement. QA is never auto-spawned after a developer task.

```
qa-strategist (charter + risk map + coverage matrix)
  └→ qa-tester ×N, run SEQUENTIALLY (run the product, explore, author Playwright specs)
      ├→ bugs → developer fix tickets, each paired with a re-verify qa-tester ticket
      │         (the re-verify IS the verification tail — no test-writer/reviewer)
      └→ confirmed-good high-risk paths → committed e2e specs + regression manifest
```

**qa-testers run one at a time, never in parallel.** Each tester launches the running product
(dev/preview server + Playwright); concurrent testers would collide on the same port. The ×N is the
*total* number of tester missions, dispatched sequentially.

| Step | Agent | Input | Output | Follow-up |
|------|-------|-------|--------|-----------|
| 1 | qa-strategist | scope + oracle sources + running app | charter, risk map, missions | qa-tester ticket per mission |
| 2 | qa-tester (×N) | mission + running app | e2e specs (in repo) + bug ledger | developer fix tickets + re-verify qa-tester |

**Ownership boundary:** `test-writer` owns **unit and integration** tests (inside the feature
chain, per the test-planner's plan); `qa-tester` owns **e2e** tests against the running product
(the QA discipline). E2e specs live in the project's real e2e dir and run in CI;
`developer`/`developer-svelte` **co-maintain** them when a feature change alters asserted
behavior, and QA reviews the update.

**Persistence:** QA artifacts live under `.guild/qa/` and are evergreen — they survive releases and
`clear-board`, like `.guild/docs/`.

## Orchestrator Responsibilities in the Chain

All of these run through the guild CLI (`${CLAUDE_PLUGIN_ROOT}/scripts/guild`):

1. **Materializing follow-ups**: read the "Follow-up Tasks" section, create real task files with
   `guild new task …` (the CLI derives the next ID and writes them into `tasks/todo/`).
2. **Status transitions**: `guild move TASK-NNN in-progress` on dispatch, `… done` on completion,
   `… failed` on failure. Agents never move their own files.
3. **Appending the fix-loop tail**: after a review round with fixes, append one test-writer and one
   re-review ticket behind the fix tickets (the only orchestrator-created tickets).
4. **Enforcing the review gate**: `guild next` skips a `reviewer` ticket until its requirement's
   other tickets have left `todo/` and `in-progress/`.
5. **Tracking requirement progress**: computed live by `guild board` (done tickets / total tickets
   per REQ, doneness read from the directory) — not stored.
6. **Marking requirements done**: `guild move REQ-NNN done` when a requirement's reviewer ticket
   completes with no open fixes.
7. **Handling escalation**: when a reviewer writes `ESCALATE` or round 2 still has fixes, prompt the
   user.

## Execution Model — Parallel by Default

- **Development runs in `parallel-group` waves.** The architect designs slices for disjoint file
  sets and labels every wave (verified disjoint "Files to Touch", no ordering dependency); the
  orchestrator dispatches a whole wave concurrently in the shared working tree — no worktrees, no
  merge step, because the file sets don't overlap. The cursor advances past a wave only when all
  members are `done`. The orchestrator never invents groups; it only honors the architect's labels.
- **Ungrouped dev tickets run solo, in ID order** — the exception, reserved for foundational work
  other slices build on, or slices whose file set the architect couldn't bound.
- **The 4-reviewer fan-out.** All 4 run at once on the same review ticket (safe because reviewers
  are read-only); only the orchestrator materializes their follow-ups afterward.
- **The tail is sequential by design** — test-planner, then test-writer ticket(s), then review;
  each stage consumes the previous one's artifact.
- **`qa-tester` tickets are strictly sequential** — one at a time even when several are pending,
  because each drives its own dev server + Playwright and would otherwise collide on ports. They are
  never given a `parallel-group`.
