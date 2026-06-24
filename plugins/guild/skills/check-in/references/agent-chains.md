# Agent Chains — Follow-up Patterns

This document defines the standard chains that drive the guild's continuous cycle:
**Requirements → Tasks → Plans → Tasks**. Tickets are walked by a single cursor in **ID order**
(see `state-format.md`); development is **sequential by default**, with two parallel cases: a
`parallel-group` developer batch (architect-verified disjoint files) and the 4-reviewer fan-out.

## The Core Cycle

```
User provides input
  └→ product-owner: gathers details, writes REQ document
      └→ architect: reads REQ, explores codebase, writes PLAN,
         declares dev tickets + the test-writer + reviewer tail
          └→ developer ×N: implement code per plan (sequential, or
             in parallel-group batches when slices touch disjoint files)
              └→ test-writer: writes and runs unit tests
                  └→ 4 reviewers in parallel:
                      ├── reviewer-security
                      ├── reviewer-architecture
                      ├── reviewer-business-logic
                      └── reviewer-edge-case
                          ├→ [all approved] requirement complete
                          └→ [any issues] developer fixes → test-writer → reviewers again
```

## Chain 1: Standard Requirement Flow

The most common chain. A new requirement flows through all roles.

| Step | Agent | Input | Output | Follow-up |
|------|-------|-------|--------|-----------|
| 1 | product-owner | User conversation | REQ document | architect ticket |
| 2 | architect | REQ document + codebase | PLAN document | developer tickets **+ test-writer ticket + reviewer ticket** |
| 3 | developer (×N, sequential or parallel-group batches) | PLAN + REQ + codebase | Code changes | (none) |
| 4 | test-writer | Code changes + REQ + PLAN | Unit tests | fix tickets if bugs found |
| 5 | 4 reviewers (parallel) | Code + tests + REQ + PLAN | Review report | fix tickets OR approval |

The developer tickets, the test-writer ticket, and the reviewer ticket are all created at once
from the architect's follow-ups. Because the cursor runs in ID order, the test-writer ticket is
reached only after every developer ticket is `done`, and the reviewer ticket only after the
test-writer is `done` — whether the dev tickets ran one at a time or in `parallel-group` batches.
The reviewer ticket is additionally **gated**: the orchestrator dispatches it only when every
non-tail ticket for the requirement is `done` (the N/N gate) — a cheap safety belt on top of ordering.

### Step 1: Product Owner

**Input task title pattern:** "Gather requirements for {feature}"

**Follow-up declaration:**
```
- Plan {feature} implementation | agent: architect | priority: high
```

### Step 2: Architect

**Input task title pattern:** "Plan {feature} implementation"

**Follow-up declaration (dev tickets + the tail):**
```
- Implement {component-1} | agent: developer | priority: high | plan-slice: .guild/plans/PLAN-NNN/slice-{slug-1}.md
- Implement {component-2} | agent: developer-svelte | priority: high | plan-slice: .guild/plans/PLAN-NNN/slice-{slug-2}.md | parallel-group: A
- Implement {component-3} | agent: developer | priority: medium | plan-slice: .guild/plans/PLAN-NNN/slice-{slug-3}.md | parallel-group: A
- Write unit tests for {feature} | agent: test-writer | priority: high
- Review {feature} implementation | agent: reviewer | priority: high
```

The architect emits the `test-writer` and `reviewer` tail explicitly. The orchestrator does not
auto-create them in the initial chain. Listing dev tickets first keeps their IDs lower, so they run
before the tail. The architect adds a `parallel-group` label to dev tickets it has verified touch
disjoint files (components 2 and 3 above) — the orchestrator dispatches those concurrently; the tail
tickets never carry a group.

The architect picks the developer agent per slice. `developer-svelte` (sonnet, pre-loaded with
Svelte 5 / SvelteKit knowledge via the `guild:svelte-*` skills) handles work touching Svelte
components, SvelteKit routes, server hooks, and `svelte.config.js`. `developer` handles everything
else. Both honor the `plan-slice` modifier.

### Step 3: Developer

**Input task title pattern:** "Implement {component}"

Developers run **one at a time** in ID order, **except** when the architect has tagged a set of dev
tickets with a shared `parallel-group` — those are dispatched concurrently (the architect verified
their slices touch disjoint files, so they safely share the working tree). Each developer reads its
slice, implements, appends to the Work Log, and marks itself `done`. **Developers declare no
follow-ups** (the architect already emitted the tail), except a `Fix:`/`Clarify:` ticket if they
discover a genuine blocker mid-work.

### Step 4: Test Writer

**Input task title pattern:** "Write unit tests for {feature}"

- Read all implemented code, map acceptance criteria to test cases, write and run tests.
- If tests reveal implementation bugs, declare `Fix: … | agent: developer` tickets.

### Step 5: Reviewers (4 in parallel)

**Input task title pattern:** "Review {feature} implementation" (`agent: reviewer`)

When the orchestrator encounters a `reviewer` ticket whose N/N gate is satisfied, it spawns 4
specialized reviewers in parallel on the same ticket:

| Reviewer | Focus |
|----------|-------|
| `reviewer-security` | OWASP Top 10, injection, auth, data handling |
| `reviewer-architecture` | Plan alignment, patterns, separation of concerns |
| `reviewer-business-logic` | Acceptance criteria, business rules, testability |
| `reviewer-edge-case` | Boundary conditions, null handling, error scenarios |

Each reviewer reads the ticket, requirement, and plan; reviews through its lens; appends findings
to the shared Work Log under its own heading; and independently declares `Fix:` tickets if needed.

**After all 4 return:**
- ANY `Fix:` tickets declared → the orchestrator creates the developer fix tickets, then appends
  one round-2 `test-writer` ticket and one round-2 `Re-review …` ticket behind them (see Chain 4).
- ALL 4 wrote PASS → the requirement is marked `done`.

## Chain 2: Research-First Flow

When a requirement needs technology research before planning.

```
product-owner → researcher → architect → developer ×N → test-writer → reviewer
```

Two entry points:

**2a. Product owner declares research upfront:**
```
- Research {technology/approach} for {feature} | agent: researcher | priority: high
- Plan {feature} implementation | agent: architect | priority: high
```

**2b. Architect triggers the research gate** (discovers mid-analysis it cannot plan responsibly):
```
- Research {specific topic} for {feature} | agent: researcher | priority: high
- Plan {feature} implementation (post-research) | agent: architect | priority: high
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

Simplified chain for bug fixes — skip the architect. Because there is no architect to emit the
tail, the **product-owner emits it**:

```
product-owner → developer → test-writer → reviewer
```

**Product owner declares:**
```
- Fix: {bug description} | agent: developer | priority: high
- Write unit tests for {fix} | agent: test-writer | priority: high
- Review {fix} | agent: reviewer | priority: high
```

## Chain 4: Review Fix Loop

When any reviewer finds issues, a fix loop starts. **Maximum 2 review rounds.**

```
4 reviewers → developer ×N (fixes) → test-writer (round 2) → 4 reviewers (round 2) → done or escalate
```

The loop is driven by **declaration + one orchestrator-appended tail per round** — no ID
arithmetic:
- Reviewers declare only `Fix: … | agent: developer` tickets.
- After a review round that produced fixes, the orchestrator creates the fix tickets, then appends
  **one** `test-writer` ticket and **one** `Re-review …` ticket behind them.
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
      ├→ bugs → developer fix tickets (Chain 3 bug-fix flow) → re-verify qa-tester
      └→ confirmed-good high-risk paths → committed e2e specs + regression manifest
```

**qa-testers run one at a time, never in parallel.** Each tester launches the running product
(dev/preview server + Playwright); concurrent testers would collide on the same port. The ×N is the
*total* number of tester missions, dispatched sequentially.

| Step | Agent | Input | Output | Follow-up |
|------|-------|-------|--------|-----------|
| 1 | qa-strategist | scope + oracle sources + running app | charter, risk map, missions | qa-tester ticket per mission |
| 2 | qa-tester (×N) | mission + running app | e2e specs (in repo) + bug ledger | developer fix tickets + re-verify qa-tester |

**Ownership boundary:** `test-writer` owns **unit** tests (inside the feature chain); `qa-tester`
owns **e2e/integration** tests (the QA discipline). E2e specs live in the project's real e2e dir and
run in CI; `developer`/`developer-svelte` **co-maintain** them when a feature change alters asserted
behavior, and QA reviews the update.

**Persistence:** QA artifacts live under `.guild/qa/` and are evergreen — they survive releases and
`clear-board`, like `.guild/docs/`.

## Orchestrator Responsibilities in the Chain

1. **Materializing follow-ups**: read the "Follow-up Tasks" section, create real task files with
   `status: todo`, increment `next-task` in `state.yaml`.
2. **Appending the fix-loop tail**: after a review round with fixes, append one test-writer and one
   re-review ticket behind the fix tickets (the only orchestrator-created tickets).
3. **Enforcing the review gate**: dispatch a `reviewer` ticket only when its requirement's non-tail
   tickets are all `done`.
4. **Tracking requirement progress**: computed live (done tickets / total tickets per REQ) — not
   stored.
5. **Marking requirements done**: when a requirement's reviewer ticket completes with no open fixes.
6. **Handling escalation**: when a reviewer writes `ESCALATE` or round 2 still has fixes, prompt the
   user.

## Sequential Execution & the Two Exceptions

- **Development is sequential by default** — one developer ticket at a time, in ID order.
- **Exception 1 — `parallel-group` dev batches.** When the architect tags dev tickets with a shared
  `parallel-group` (verified disjoint "Files to Touch", no ordering dependency), the orchestrator
  dispatches the whole group concurrently in the shared working tree — no worktrees, no merge step,
  because the file sets don't overlap. The cursor advances past the group only when all members are
  `done`. The orchestrator never invents groups; it only honors the architect's labels.
- **Exception 2 — the 4-reviewer fan-out.** All 4 run at once on the same review ticket (safe
  because reviewers are read-only); only the orchestrator materializes their follow-ups afterward.
- **`qa-tester` tickets are strictly sequential** — one at a time even when several are pending,
  because each drives its own dev server + Playwright and would otherwise collide on ports. They are
  never given a `parallel-group`.
