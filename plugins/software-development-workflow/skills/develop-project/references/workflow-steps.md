# Develop Project — Detailed Workflow Steps

Complete step-by-step instructions for all 6 steps of the develop-project skill.

---

## Step 0: Progress Tracking Setup (Do First)

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

---

## Step 1: Parse Arguments and Resolve Requirements File Path

**TaskUpdate Task 1 → in_progress**

### 1.1 Parse `$ARGUMENTS`

```
Format: <file-path-or-search-query>
```

Extract:
- `FILE_PATH_OR_QUERY` — first argument (path or search query)

### 1.2 Handle Missing File Path

If `FILE_PATH_OR_QUERY` is empty: ask "Please provide the name or path to your requirements file." and wait for response.

### 1.3 Resolve File Path

**a. Try exact path**: Use Read tool. If file exists → set `RESOLVED_FILE_PATH`, skip to 1.4.

**b. Search query fallback**: Use Glob:
- `**/*{FILE_PATH_OR_QUERY}*.md`
- `**/{FILE_PATH_OR_QUERY}`

**c. Handle results**:
- **No files**: Inform user, ask for different path, retry from 1.3a
- **One file**: Set `RESOLVED_FILE_PATH`, inform user
- **Multiple files**: Present numbered list (max 20), wait for user to pick a number or provide new query

### 1.4 Validate File

- Must be `.md` extension
- Must not be empty
- If invalid, ask for different file and retry

### 1.5 Check for Existing Progress (Resume)

Check for existing progress files to determine resume mode. Set `RESUME_MODE` based on what is found.

**Check 1**: Does `.trackers/{BASE_NAME}/TASKS.md` exist?

- **Yes** → Set `RESUME_MODE = tasks`. Read TASKS.md. For each phase, count `[x]` (done), `[ ]` and `[~]` and `[!]` (remaining) tasks. Present a resume summary to the user:

  ```
  Resuming existing build for {BASE_NAME}.

  Phase 1: Foundational  [complete]     — {X}/{total} tasks done
  Phase 2: Models        [complete]     — {X}/{total} tasks done
  Phase 3: Services      [in_progress]  — {X}/{total} tasks done, {remaining} remaining
  Phase 4: Data          [pending]      — 0/{total} tasks done
  ...

  Total remaining: {count} tasks across {count} phases.
  Skipping plan generation — jumping to execution.
  ```

  Then jump directly to Step 5 (skip Steps 2, 3, and 4).

**Check 2** (only if TASKS.md not found): Does `.trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md` exist?

- **Yes** → Set `RESUME_MODE = plan`. Inform user: "Found existing master plan. Skipping regeneration." Skip Step 2 (jump directly to Step 3).
- **No** → Set `RESUME_MODE = none`. Fresh run, continue normally.

### 1.6 Store Configuration

- `RESOLVED_FILE_PATH`
- `BASE_NAME` (filename without extension)
- `RESUME_MODE` (`none` | `plan` | `tasks`)

**TaskUpdate Task 1 → completed**

---

## Step 2: Generate Master Plan from Requirements

**Skip this step if `RESUME_MODE = plan` or `RESUME_MODE = tasks`.**

**TaskUpdate Task 2 → completed** (mark immediately if skipping)

**TaskUpdate Task 2 → in_progress** (only if running fresh)

1. Read `RESOLVED_FILE_PATH`
2. Create directory: `mkdir -p .trackers/{BASE_NAME}/plans`
3. Spawn `develop:software-architect` agent:

```
subagent_type: "develop:software-architect"
description: "Create master implementation plan"
prompt: "Analyze the requirements document and create a comprehensive master implementation plan.

## Requirements File
Read and analyze: {RESOLVED_FILE_PATH}

## Output File Path
Save the master plan to: .trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md

## Your Task
Create a detailed master plan that:

1. Analyzes all requirements from {RESOLVED_FILE_PATH} and extracts:
   - Feature descriptions
   - User stories
   - Acceptance criteria
   - Functional and non-functional requirements
   - Technical constraints

2. Identifies discrete tasks for implementation:
   - Break down features into actionable tasks
   - Include task titles and descriptions
   - Specify acceptance criteria for each task
   - Note dependencies between tasks
   - Consider technical architecture implications

3. Provides implementation guidance:
   - Suggest architectural patterns
   - Identify technical challenges
   - Recommend technology/framework choices
   - Note security and performance considerations

4. Organizes logically:
   - Group related tasks together
   - Show clear progression from foundation to UI to tests
   - Highlight critical paths and dependencies

CRITICAL: Use the Write tool to save the master plan directly to:
.trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md"
```

4. Wait for agent to complete. Inform user:

```
Master plan created and saved!

File: .trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md
Source Requirements: {RESOLVED_FILE_PATH}
```

**TaskUpdate Task 2 → completed**

---

## Step 3: Review Master Plan

**TaskUpdate Task 3 → in_progress**

1. Read `.trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md`
2. Present summary to user:

```
Master plan created! Please review before execution begins.

File: .trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md
Source Requirements: {RESOLVED_FILE_PATH}

Master Plan Summary:
[Brief overview: key features, major task groups, suggested architecture, total tasks]

Options:
- Type "proceed" to continue with phase splitting and full execution
- Type "review" to see the full master plan details
- Type "edit" to make changes to the master plan
```

3. Wait for response:
   - **"proceed"** → continue to Step 4
   - **"review"** → display full file content, ask again
   - **"edit"** → ask user to edit the file at the path, wait for confirmation, re-read, ask to proceed

**TaskUpdate Task 3 → completed**

---

## Step 4: Split Master Plan and Build TASKS.md

**TaskUpdate Task 4 → in_progress**

### 4.1 Call develop:split-plan Skill Directly

```
Skill: "develop:split-plan"
args: "--master-plan-path .trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md --base-name {BASE_NAME}"
```

Wait for skill to complete. It will create all 8 phase plan files in `.trackers/{BASE_NAME}/plans/`.

Expected files after skill:
```
.trackers/{BASE_NAME}/plans/
├── {BASE_NAME}-01-foundational.md
├── {BASE_NAME}-02-models.md
├── {BASE_NAME}-03-services.md
├── {BASE_NAME}-04-data.md
├── {BASE_NAME}-05-rules.md
├── {BASE_NAME}-06-state-management.md
├── {BASE_NAME}-07-ui.md
└── {BASE_NAME}-08-tests.md
```

### 4.2 Build TASKS.md

Read all 8 phase plan files. For each phase:
- Extract the phase name
- Extract all tracks (lines starting with `## Track:`)
- Extract all tasks (lines starting with `### Task`)
- Extract each task's title and complexity score

Create `.trackers/{BASE_NAME}/TASKS.md` using Write tool:

```markdown
# Tasks - {BASE_NAME}

**Requirements**: {RESOLVED_FILE_PATH}
**Status**: In Progress

---

## Phase 1: Foundational [pending]

### Track: {track-name}
- [ ] Task 1: {task-title} (complexity: {score})
- [ ] Task 2: {task-title} (complexity: {score})

## Phase 2: Models [pending]

### Track: {track-name}
- [ ] Task 3: {task-title} (complexity: {score})

[...continue for all phases and tasks, numbering tasks sequentially across all phases...]

---

## Phase 8: Tests [pending]

### Track: {track-name}
- [ ] Task N: {task-title} (complexity: {score})
```

**Rules for TASKS.md**:
- Number tasks sequentially (1, 2, 3…) across all phases — each task has a unique global ID
- If a phase has no tasks (empty phase), include the phase header with `[pending]` and a note: `- (no tasks)`
- Task status markers: `[ ]` pending · `[~]` in_progress · `[x]` complete · `[!]` blocked

### 4.3 Inform User

```
Phase plans created and task list built!

Plans: .trackers/{BASE_NAME}/plans/
Tasks: .trackers/{BASE_NAME}/TASKS.md

Total tasks: {count} across {non-empty-phase-count} phases
Starting execution now...
```

**TaskUpdate Task 4 → completed**

---

## Step 5: Execute All Phases

**TaskUpdate Task 5 → in_progress**

For each phase 1→8 in order:

### 5.1 Check Phase Status

Read TASKS.md. Find the section for this phase.

- If all tasks in this phase are `[x]` → log "Phase {N} already complete, skipping." → next phase
- If no tasks (`(no tasks)`) → log "Phase {N} has no tasks, skipping." → next phase
- Otherwise → proceed

### 5.2 Update Phase Status

Edit TASKS.md: change `## Phase {N}: {Name} [pending]` → `## Phase {N}: {Name} [in_progress]`

Read the phase plan: `.trackers/{BASE_NAME}/plans/{BASE_NAME}-{NN}-{name}.md`

### 5.3 Get Pending Tasks

Parse TASKS.md for this phase: collect all `- [ ] Task {id}: …` lines.

Extract for each: task ID, title, complexity score, track name.

### 5.4 Determine Agent Count

```
If pending tasks ≥ 3 → AGENT_COUNT = 3
If pending tasks < 3 → AGENT_COUNT = 1
```

Log to user:
```
Phase {N} — {name}:
- Pending Tasks: {count}
- Spawning {AGENT_COUNT} developer(s) as a team...
```

### 5.5 Execute with Developer Team

Spawn all AGENT_COUNT developers **in parallel** (single message, multiple Agent tool calls). Each developer uses a claim-and-work loop to pick up tasks independently — no pre-assignment needed:

```
subagent_type: "develop:senior-developer"
description: "Developer {DEV_N} — Phase {N}: {phase-name}"
prompt: "You are Developer {DEV_N} of {AGENT_COUNT} working on Phase {N}: {phase-name}.

## Requirements
Read and understand the project requirements before implementing:
{RESOLVED_FILE_PATH}

## Context
- Detailed phase plan: .trackers/{BASE_NAME}/plans/{BASE_NAME}-{NN}-{name}.md
- Task list: .trackers/{BASE_NAME}/TASKS.md

## Implementation Instructions
1. Read the requirements document to understand the project scope.
2. Read the detailed phase plan for architectural context and acceptance criteria.
3. Work through tasks using this claim-and-work loop:
   a. Read TASKS.md and find the first `- [ ] Task {id}:` line in Phase {N}
   b. If none found → you are done, stop.
   c. Edit TASKS.md: change `- [ ] Task {id}:` → `- [~] Task {id}:` to claim it
   d. Review the task's acceptance criteria in the phase plan
   e. Analyze existing code patterns
   f. Implement the task fully and correctly
   g. Edit TASKS.md: change `- [~] Task {id}:` → `- [x] Task {id}:` (or `- [!]` if blocked)
   h. Go back to step a
Follow the project's existing patterns and architecture throughout."
```

Wait for all agents to complete.

### 5.6 Complete Phase

Edit TASKS.md: change `## Phase {N}: {Name} [in_progress]` → `## Phase {N}: {Name} [complete]`

Log to user:
```
Phase {N}: {name} complete. ({completed-count}/{total-count} tasks)
Proceeding to Phase {next-N}...
```

Auto-continue to next phase — no user confirmation needed between phases.

### 5.7 Post-Implementation Comprehensive Review Loop

After all 8 phases are complete, run a review loop (max 2 iterations):

**Iteration tracking**: Start `REVIEW_ITERATION = 1`

**Loop:**

1. Execute comprehensive review:
   ```
   Skill: "develop:comprehensive-review"
   ```
   Pass context: the requirements file and all phase plan files.

2. Collect all issues from the review report.

3. If **no issues found** → log "Implementation review passed. No issues found." → exit loop.

4. If **issues found** AND `REVIEW_ITERATION < 2`:
   - Create a `TodoWrite` todo for **each issue** found, with the issue description and file reference
   - For each todo (batch in groups of AGENT_COUNT):
     - Spawn `develop:senior-developer` agent(s) to fix the issue
     - Wait for completion
     - Mark todo as done
   - Set `REVIEW_ITERATION = REVIEW_ITERATION + 1`
   - Go back to step 1 (re-run review)

5. If `REVIEW_ITERATION == 2` (2nd iteration, issues still found from step 1):
   - Present the remaining issues to the user and ask:
     ```
     Review complete. {count} issue(s) remain after 2 passes.
     Would you like to fix the remaining issues, or proceed to the summary report?
     ```
   - **"fix"** → create todos, spawn fix agents, then generate summary
   - **"proceed"** → exit loop and continue to Step 6

**TaskUpdate Task 5 → completed**

---

## Step 6: Generate Final Summary Report

**TaskUpdate Task 6 → in_progress**

1. Read `.trackers/{BASE_NAME}/TASKS.md` to collect completion counts.

2. Write summary to `.trackers/{BASE_NAME}/plans/{BASE_NAME}-SUMMARY.md` — see `references/summary-report.md` for the template.

3. Present to user:
   ```
   Build workflow complete!

   Summary: .trackers/{BASE_NAME}/plans/{BASE_NAME}-SUMMARY.md
   Tasks:   .trackers/{BASE_NAME}/TASKS.md

   Completed: {count} phases, {count} tasks
   Remaining: {count} phases, {count} tasks (blocked or skipped)

   To resume at any time: run /develop:develop-project again with the same requirements file.
   ```

**TaskUpdate Task 6 → completed**
