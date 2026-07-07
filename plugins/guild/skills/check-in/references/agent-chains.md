# Agent Chains — Follow-up Patterns

This document defines the standard chains that drive the guild's continuous cycle. **Requirements
and planning happen up front, outside the ticket board**, inside the `guild:new-requirement`
skill: the product-owner and architect run a live 3-way interview with the user, and the
architect creates every developer/test-planner/reviewer ticket directly (via the CLI) before that
skill returns. Everything below this point runs through the ticket board, walked by a single
cursor in **ID order** (see `state-format.md`); development runs **in parallel by default** — the
architect groups dev tickets into `parallel-group` waves (verified disjoint files) that dispatch
concurrently — and reviews fan out 4-wide.

## The Core Cycle

```
guild:new-requirement (live interview, not ticket-dispatched)
  ├→ product-owner: interviews the user, writes REQ document
  └→ architect: explores codebase (may run guild:researcher inline), writes PLAN,
     creates dev tickets + the test-planner + reviewer tail directly via the CLI
      │
      ▼  (tickets now exist — check-in drives the rest)
developer ×N: implement code per plan, in parallel-group
waves (disjoint files); foundational tickets run solo first
  └→ test-planner: inventories the diff, writes the test plan,
     declares the test-writer ticket(s)
      └→ test-writer: writes and runs unit & integration tests
          └→ 4 reviewers in parallel:
              ├── reviewer-security
              ├── reviewer-architecture
              ├── reviewer-business-logic
              └── reviewer-edge-case
                  └→ orchestrator compiles a review report, asks the user which
                     findings (if any) become fix tickets — no automatic re-review
```

## Chain 1: Standard Requirement Flow

The most common chain. A new requirement flows through all roles.

| Step | Agent | Input | Output | Where it runs |
|------|-------|-------|--------|-----------|
| 1 | product-owner | User conversation (live, 3-way with architect) | REQ document | `guild:new-requirement` (not ticket-dispatched) |
| 2 | architect | REQ document + codebase (+ inline `guild:researcher` calls as needed) | PLAN document + developer tickets **+ test-planner ticket + reviewer ticket**, created directly via the CLI | `guild:new-requirement` (not ticket-dispatched) |
| 3 | developer (×N, parallel-group waves) | PLAN slice + REQ + codebase | Code changes | check-in ticket board |
| 4 | test-planner | Dev work logs + REQ + PLAN | Test plan (`slice-test-plan.md`) | check-in ticket board |
| 5 | test-writer (×1–2) | Test plan + changed files | Unit & integration tests | check-in ticket board |
| 6 | 4 reviewers (parallel) | Changed files + tests + REQ + PLAN | Review report | check-in ticket board |

Steps 1 and 2 happen **before any ticket exists** — see `product-owner.md` and `architect.md` for
their workflow, and the `new-requirement` skill for how the orchestrator spawns and moderates
them. The architect creates the developer tickets, the test-planner ticket, and the reviewer
ticket directly with `guild new task`, in that order (developers first for lower IDs). Because the
cursor runs in ID order, the test-planner is reached only after every developer ticket is `done`.
The test-writer ticket(s) are created later by the test-planner and get **higher IDs than the
reviewer ticket — that's fine**: the reviewer ticket is **gated** (the orchestrator dispatches it
only when every other ticket for its requirement is `done`, the N/N gate), so the review always
runs last, after the planner-declared test-writer tickets complete. The gate is what turns ID order
into the pipeline dev → test-plan → tests → review.

**Parallel is the default**: the architect designs slices for disjoint file sets and puts every
dev ticket it can into a `parallel-group` wave — the orchestrator dispatches each wave
concurrently. A ticket stays ungrouped only when it is foundational (others build on it) or its
file set can't be bounded; the tail tickets never carry a group.

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
the codebase; reviews through its lens; and appends findings to the shared Work Log under its own
heading. Reviewers no longer declare `Fix:` tickets themselves.

**After all 4 return:** the orchestrator compiles their findings into `.guild/reviews/REQ-NNN.md`
and, if there are critical/major findings, asks the user which (if any) become fix tickets — see
Chain 4. There is no automatic fix loop and no re-review; if all 4 wrote PASS, the requirement
completes with nothing further to decide.

## Chain 2: Research-First Flow

When a requirement needs technology research before planning, the architect (or product-owner)
just calls `guild:researcher` directly with the **Agent** tool, mid-session, and keeps going once
it returns — there is no separate ticket, no second architect pass, and no async handoff:

```
new-requirement session: product-owner + architect (architect calls guild:researcher inline
as needed) → developer ×N → test-planner → test-writer → reviewer
```

`guild:researcher` is spawned directly (not via a ticket) with a specific question and reports
back a short answer for immediate use, in addition to writing full findings to
`.guild/docs/{topic-slug}.md` as it always has.

**Research knowledge still persists:** the researcher writes findings to
`.guild/docs/{topic-slug}.md`, not a task work log. These docs are evergreen — they survive release
archiving and board clears. Before researching, the researcher checks existing docs and reuses
them; before designing, the architect checks existing docs and may skip the research call
entirely.

(A `researcher` ticket type still exists for the rare case someone manually queues one on the
board — `researcher.md` documents both invocation modes — but the standard flow no longer produces
one.)

## Chain 3: Bug Fix Flow

Simplified chain for bug fixes — skip the architect **and the test-planner** (a scoped fix doesn't
need a test plan). Recognized by the product-owner during the interview; since it has no ticket of
its own to declare follow-ups on, it **creates the tail directly** with the CLI (it has Bash):

```
new-requirement session: product-owner only → developer → test-writer → reviewer
```

**Product owner runs:**
```bash
"$GUILD" new task --title "Fix: {bug description}" --agent developer --req REQ-NNN --date {today}
"$GUILD" new task --title "Write unit tests for {fix}" --agent test-writer --req REQ-NNN --date {today}
"$GUILD" new task --title "Review {fix}" --agent reviewer --req REQ-NNN --date {today}
```

With no `plan-slice`, the test-writer falls back to deriving scope from the developer's Work Log,
and reviewers scope their reading the same way. `new-requirement` tells the architect to stop
(no plan needed) when the product-owner takes this path.

## Chain 4: Review Report & Fix Approval

When reviewers find issues, there is **no automatic fix loop** — the orchestrator compiles a
report and the user decides what happens next:

```
4 reviewers → orchestrator compiles .guild/reviews/REQ-NNN.md → user approves 0+ findings as
fix tickets → developer ×N (fixes, plain tickets, no forced tail) → done (no automatic re-review)
```

- Reviewers only write findings to the shared Work Log (Verdict + Findings per reviewer) — they no
  longer declare `Fix:` follow-ups, and there is no round concept or `ESCALATE` token to scan for.
- After all 4 return, the orchestrator appends a dated section to `.guild/reviews/REQ-NNN.md` with
  each reviewer's verdict and findings (never overwriting a prior round's section).
- If there are critical/major findings, the orchestrator lists them and asks the user (multi-select
  `AskUserQuestion`) which should become fix tickets. Approved ones become plain `developer`
  tickets — no `plan-slice`, no `parallel-group`, and no forced test-writer/re-review tail.
- Once any approved fix tickets reach `done`, the requirement completes normally (3.6) — there is
  no automatic re-review. If the user wants another pass, they ask for a fresh `reviewer` ticket
  like any other.

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
   `guild new task …` (the CLI derives the next ID and writes them into `tasks/todo/`). (The
   architect and product-owner instead create their tickets directly, inside `new-requirement` —
   this mechanism is for the tickets that run after planning: developer, test-planner, test-writer,
   and reviewer follow-ups.)
2. **Status transitions**: `guild move TASK-NNN in-progress` on dispatch, `… done` on completion,
   `… failed` on failure. Agents never move their own files.
3. **Compiling the review report and creating user-approved fix tickets**: after a `reviewer`
   ticket completes, append a dated section to `.guild/reviews/REQ-NNN.md`, then ask the user which
   findings (if any) become fix tickets — the only orchestrator-created tickets outside of
   `new-requirement`. No automatic re-review follows.
4. **Enforcing the review gate**: `guild next` skips a `reviewer` ticket until its requirement's
   other tickets have left `todo/` and `in-progress/`.
5. **Tracking requirement progress**: computed live by `guild board` (done tickets / total tickets
   per REQ, doneness read from the directory) — not stored.
6. **Marking requirements done**: `guild move REQ-NNN done` when no task for the requirement remains
   open (including any user-approved fix tickets).

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
