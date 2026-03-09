---
name: develop-project
description: This skill should be used when the user asks to "develop a project", "implement requirements", "build from requirements", "start a project from requirements", "turn my requirements into code", "build my app from my spec", "implement my app from this document", "scaffold from requirements", "I have a requirements doc and want to start coding", "I have a spec and want to start building", "full requirements-to-implementation workflow", or "build project using phases". Transforms a requirements document into a fully implemented, phase-structured codebase using automated planning and parallel execution across 8 clean architecture phases.
version: 0.4.0
---

# Develop Project Workflow Skill

Automate a complete requirements-to-implementation workflow. This skill takes a requirements document, generates a master plan, splits it into 8 architecture phase plans, executes implementations using developer agents, then runs a post-implementation comprehensive review. The user reviews only the master plan — after approval, execution runs automatically.

## Arguments

Parse these from user input or `$ARGUMENTS`:

| Argument | Type | Required | Description |
|---|---|---|---|
| `file-path-or-query` | string | No | Path to requirements `.md` file, or search query |

## 6-Step Workflow Overview

Execute these steps in order:

1. **Parse Arguments** — Resolve requirements file path
2. **Generate Master Plan** — `develop:software-architect` agent analyzes requirements and writes master plan
3. **Review Master Plan** — Present summary; wait for user approval (**only user gate**)
4. **Split Master Plan + Build TASKS.md** — Call `develop:split-plan` Skill directly (no agents); build `TASKS.md` from phase plans
5. **Execute All Phases** — Run `develop:senior-developer` agents per phase (max 3 when ≥3 tasks, 1 when <3 tasks), auto-continue between phases; run post-implementation comprehensive review loop once after all phases complete (max 2 iterations, ask user if issues remain)
6. **Generate Summary Report** — Write `{BASE_NAME}-SUMMARY.md` and present results

## Phase Architecture (Fixed, Sequential)

| # | Phase | Purpose |
|---|---|---|
| 1 | Foundational | Abstract classes, utilities, base setup |
| 2 | Models | Entities, data structures, JSON classes |
| 3 | Services | APIs, external services, network layer |
| 4 | Data | Repositories, DAOs, data access layer |
| 5 | Rules | Use cases, business rules, domain logic |
| 6 | State Management | View models, presenters, state handlers |
| 7 | UI | Widgets, components, screens, views |
| 8 | Tests | Unit tests, integration tests, test utilities |

**Tracks** within each phase represent features (e.g., "authentication", "products", "cart").

**File naming**: `{BASE_NAME}-{NN}-{phase-name}.md` (zero-padded `NN`: 01–08)

## Progress Tracking Setup (Critical — Do First)

**Before Step 1**, create all 6 workflow tasks using `TaskCreate` for real-time progress visibility:

| # | Subject | activeForm |
|---|---|---|
| 1 | Parse arguments and resolve requirements file | Parsing arguments and resolving requirements file |
| 2 | Generate master plan from requirements | Generating master plan from requirements |
| 3 | Review master plan with user | Reviewing master plan with user |
| 4 | Split master plan and build task list | Splitting master plan and building task list |
| 5 | Execute all phases | Executing all phases |
| 6 | Generate final summary report | Generating final summary report |

At the **start of each step**: `TaskUpdate` → `in_progress`. At the **end**: `TaskUpdate` → `completed`.

## TASKS.md — Task Tracking File

All task tracking is done via `.trackers/{BASE_NAME}/TASKS.md`. This file is created in Step 4 and updated throughout Step 5.

**Format**:

```markdown
# Tasks - {BASE_NAME}

**Requirements**: {RESOLVED_FILE_PATH}
**Status**: In Progress

---

## Phase 1: Foundational [pending]

### Track: {track-name}
- [ ] Task 1: {title} (complexity: {1|2|3})
- [ ] Task 2: {title} (complexity: {1|2|3})

## Phase 2: Models [pending]

### Track: {track-name}
- [ ] Task 3: {title} (complexity: {1|2|3})
```

**Task status markers**:

- `[ ]` = pending
- `[~]` = in_progress
- `[x]` = complete
- `[!]` = blocked

**Phase status** (in `[…]` after phase name): `[pending]`, `[in_progress]`, `[complete]`

Use the **Edit tool** to update statuses inline — no external skill calls required.

## Team Execution Rules (Step 5)

For each phase, a fixed team of developer agents is spawned once and works through all tasks:

- **≥ 3 pending tasks** → spawn **3** `develop:senior-developer` agents as a team
- **< 3 pending tasks** → spawn **1** `develop:senior-developer` agent

All agents run in parallel. Instead of pre-assigned tasks, each agent uses a **claim-and-work loop**: find the next `[ ]` task in the phase → mark it `[~]` to claim it → implement it → mark it `[x]` or `[!]` → repeat until no `[ ]` tasks remain. This ensures faster agents pick up more work and no agent idles waiting for others.

See **`references/workflow-steps.md` Step 5** for the full execution process.

## Post-Implementation Review Loop (Step 5)

After all 8 phases are complete, run a comprehensive review loop (max 2 iterations):

1. Execute `Skill: develop:comprehensive-review` against the requirements and all phase plans
2. If no issues → done
3. If issues found on iteration 1 → create `TodoWrite` todos, fix with developer agents, re-run review
4. If issues remain after iteration 2 → **ask user** whether to fix remaining issues or proceed to summary

## File Structure

All output goes under `.trackers/{BASE_NAME}/`:

```
.trackers/{BASE_NAME}/
├── TASKS.md
└── plans/
    ├── {BASE_NAME}-master-plan.md
    ├── {BASE_NAME}-01-foundational.md
    ├── {BASE_NAME}-02-models.md
    ├── {BASE_NAME}-03-services.md
    ├── {BASE_NAME}-04-data.md
    ├── {BASE_NAME}-05-rules.md
    ├── {BASE_NAME}-06-state-management.md
    ├── {BASE_NAME}-07-ui.md
    ├── {BASE_NAME}-08-tests.md
    └── {BASE_NAME}-SUMMARY.md
```

`BASE_NAME` = requirements filename without extension (e.g., `app-requirements.md` → `app-requirements`).

## Key Rules

- **Sequential phases**: Always execute 1→2→3→4→5→6→7→8 in order
- **Team-based execution**: Spawn 3 developer agents as a team when ≥3 tasks (1 agent when <3 tasks); each agent claims the next available `[ ]` task, marks it `[~]`, implements it, then repeats until no tasks remain; no repeated spawning between batches
- **Post-implementation review loop**: After all phases complete, run comprehensive review and fix issues (max 2 iterations); ask user if issues remain after 2nd pass
- **Single user gate**: Only one confirmation required — at master plan review (Step 3)
- **No tracker plugin**: All task tracking via TASKS.md using Edit tool
- **No development-planner agent**: split-plan Skill called directly by the orchestrator
- **Resume support**: Re-running detects three states — (1) TASKS.md exists: show per-phase remaining task summary and jump to execution (skip Steps 2–4); (2) only master plan exists: skip Step 2 regeneration, go to Step 3 for review; (3) neither: fresh run

## Additional Resources

### Reference Files

For detailed step-by-step execution instructions:

- **`references/workflow-steps.md`** — Complete Steps 1–6 process flow with exact prompts, file paths, user interactions, and TASKS.md operations
- **`references/summary-report.md`** — The markdown template used when writing the final summary file in Step 6
