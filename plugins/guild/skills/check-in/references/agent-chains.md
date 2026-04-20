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
| 2 | architect | REQ document + codebase | PLAN document | developer tasks + reviewer task |
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
- Implement {component-2} | agent: developer | priority: high
- Implement {component-3} | agent: developer | priority: medium
- Review {feature} implementation | agent: reviewer | priority: high | depends-on: all-developer
```

### Step 3: Developer

**Input task title pattern:** "Implement {component}"

**What they do:**
- Read their task, the linked plan, and the requirement
- Implement the code following codebase patterns
- Append progress to Work Log

**Follow-up declaration:** None. The developer does NOT declare follow-ups. Instead, the orchestrator automatically creates a review task after ALL developer tasks for the same plan complete. This is handled in the check-in skill's work cycle logic.

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
- ANY fix tasks declared → orchestrator creates developer fix tasks + re-review task
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
4 reviewers → developer ×N (fixes) → test-writer (update tests) → 4 reviewers (round 2) → done or escalate
```

**Round 2 reviewer behavior:**
- If still issues after round 2: write "ESCALATE" in Work Log
- The orchestrator detects "ESCALATE" from any reviewer and asks the user whether to continue fixing or accept as-is

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
