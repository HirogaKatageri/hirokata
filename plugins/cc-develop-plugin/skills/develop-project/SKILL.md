---
name: develop-project
description: This skill should be used when the user asks to "develop a project", "implement requirements", "build from requirements", "start a project from requirements", "turn my requirements into code", "build my app from my spec", "implement my app from this document", "scaffold from requirements", "I have a requirements doc and want to start coding", "I have a spec and want to start building", "full requirements-to-implementation workflow", or "build project using phases". Transforms a requirements document into a fully implemented, phase-structured codebase using automated planning, tracking, and parallel execution across 8 clean architecture phases.
version: 0.2.0
---

# Develop Project Workflow Skill

Automate a complete requirements-to-implementation workflow. This skill takes a requirements document, creates a master plan via a planning agent, splits it into 8 architecture phase plans (distinct from the 8 orchestration steps below), populates a tracker, and executes implementations using senior developer agents.

## Arguments

Parse these from user input or `$ARGUMENTS`:

| Argument | Type | Required | Description |
|---|---|---|---|
| `file-path-or-query` | string | No | Path to requirements `.md` file, or search query |

## 8-Step Workflow Overview

Execute these steps in order:

1. **Parse Arguments** — Resolve requirements file path
2. **Generate Master Plan** — `develop:software-architect` agent analyzes requirements and writes master plan
3. **Review Master Plan** — Present summary; wait for user approval before continuing
4. **Split Master Plan** — 3 parallel `develop:development-planner` agents produce 8 phase plan files
5. **Create Tracker** — Build tracker with all phases, tracks, and tasks from phase plans
6. **Present Analysis & Select Phases** — Show structure; user picks which phases to execute
7. **Execute Phases** — Run `develop:senior-developer` agents per phase (max 3 when ≥3 tasks, 1 when <3 tasks), then run comprehensive review loop after each phase
8. **Generate Summary Report** — Write `{BASE_NAME}-SUMMARY.md` and present results

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

**Before Step 1**, create all 8 workflow tasks using `TaskCreate` for real-time progress visibility:

| # | Subject | activeForm |
|---|---|---|
| 1 | Parse arguments and resolve requirements file | Parsing arguments and resolving requirements file |
| 2 | Generate master plan from requirements | Generating master plan from requirements |
| 3 | Review master plan with user | Reviewing master plan with user |
| 4 | Split master plan into phase plans | Splitting master plan into phase plans |
| 5 | Create and populate tracker | Creating and populating tracker |
| 6 | Present analysis and select phases | Presenting analysis and selecting phases |
| 7 | Execute selected phases | Executing selected phases |
| 8 | Generate final summary report | Generating final summary report |

At the **start of each step**: `TaskUpdate` → `in_progress`. At the **end**: `TaskUpdate` → `completed`.

## Parallel Execution Rules (Step 7)

Within each phase, the number of parallel developer agents is fixed based on task count:
- **≥ 3 pending tasks** → spawn **3** `develop:senior-developer` agents in parallel
- **< 3 pending tasks** → spawn **1** `develop:senior-developer` agent

See **`references/workflow-steps.md` Step 7** for the full execution process.

## Post-Phase Review Loop (Step 7)

After each phase's implementation tasks are complete, run a comprehensive review loop:
1. Execute `develop:comprehensive-review` on the phase changes
2. Create `TodoWrite` todos for every issue found
3. Fix all todos using developer agents
4. Re-run comprehensive review to check if issues are resolved
5. **Repeat until all issues are fixed or 4th review iteration is reached** (stop regardless of remaining issues on 4th repeat)

## File Structure

All output goes under `.trackers/{BASE_NAME}/`:

```
.trackers/{BASE_NAME}/
├── TRACKER.md
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
- **Fixed parallelism**: Spawn 3 developer agents when ≥3 tasks, 1 agent when <3 tasks
- **Post-phase review loop**: After each phase, run comprehensive review and fix issues (max 4 iterations)
- **User confirmation required at**: master plan review (Step 3), proceed-to-tracker prompt after phase plans are created (Step 4), phase selection (Step 6), after each phase execution (Step 7)
- **Tracker integration**: All task management goes through `tracker:tracker` agent skills
- **Resume support**: Re-running the skill skips completed phases automatically using tracker status

## Additional Resources

### Reference Files

For detailed step-by-step execution instructions:
- **`references/workflow-steps.md`** — Complete Steps 1–8 process flow with exact prompts, file paths, user interactions, and tracker skill calls
- **`references/summary-report.md`** — The markdown template used when writing the final summary file in Step 8
