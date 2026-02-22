# Develop Project — Detailed Workflow Steps

Complete step-by-step instructions for all 8 steps of the develop-project skill.

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

### 1.5 Store Configuration

- `RESOLVED_FILE_PATH`

**TaskUpdate Task 1 → completed**

---

## Step 2: Generate Master Plan from Requirements

**TaskUpdate Task 2 → in_progress**

1. Read `RESOLVED_FILE_PATH`
2. Extract `BASE_NAME` (filename without extension, e.g. `app-v1.md` → `app-v1`)
3. Create directory: `mkdir -p .trackers/{BASE_NAME}/plans`
4. Spawn `develop:software-architect` agent:

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

5. Wait for agent to complete. Inform user:

```
Master plan created and saved by software-architect agent!

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
Master plan created! Before organizing into phases, let's review the plan.

File: .trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md
Source Requirements: {RESOLVED_FILE_PATH}

Master Plan Summary:
[Brief overview: key features, major task groups, suggested architecture, total tasks]

Options:
- Type "proceed" to continue with split-plan workflow
- Type "review" to see the full master plan details
- Type "edit" to make changes to the master plan
```

3. Wait for response:
   - **"proceed"** → continue to Step 4
   - **"review"** → display full file content, ask again
   - **"edit"** → ask user to edit the file at the path, wait for confirmation, re-read, ask to proceed

**TaskUpdate Task 3 → completed**

---

## Step 4: Split Master Plan into Phase Plans

**TaskUpdate Task 4 → in_progress**

Spawn **3 `develop:development-planner` agents in parallel** (single message, three Task calls), each responsible for a subset of phases:

**Agent 1 — Phases 1, 2, 3**:
```
subagent_type: "develop:development-planner"
description: "Create phase plans 1-3 from master plan"
prompt: "Analyze the master plan and generate phase plan files for Phases 1, 2, and 3 only.

## Master Plan Location
File: .trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md

## Base Name
Use base name: {BASE_NAME}

## Output Directory
.trackers/{BASE_NAME}/plans/

## Your Task

Read the entire master plan, then generate ONLY these 3 phase plan files:
- {BASE_NAME}-01-foundational.md  (Phase 1: Foundational — base abstractions, utilities, infrastructure)
- {BASE_NAME}-02-models.md        (Phase 2: Models — data entities, DTOs, value objects)
- {BASE_NAME}-03-services.md      (Phase 3: Services — external APIs, service integrations)

For each phase:
1. Identify all tasks from the master plan that belong to this phase
2. Group tasks by feature tracks (lowercase-with-hyphens naming)
3. Score task complexity (1=Low, 2=Medium, 3=High)
4. Write the phase plan file using the standard phase plan template
5. If a phase has no tasks, use the empty phase template

Follow the develop:split-plan skill's phase classification rules:
- Phase 1: Sets up base infrastructure, abstract classes, project scaffolding
- Phase 2: Defines data structures, entities, models
- Phase 3: Calls external APIs, network layer, service integrations

After creating all 3 files, verify they exist and report:
- Files created (3/3)
- Tracks identified per phase
- Tasks per phase
- Complexity distribution"
```

**Agent 2 — Phases 4, 5, 6**:
```
subagent_type: "develop:development-planner"
description: "Create phase plans 4-6 from master plan"
prompt: "Analyze the master plan and generate phase plan files for Phases 4, 5, and 6 only.

## Master Plan Location
File: .trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md

## Base Name
Use base name: {BASE_NAME}

## Output Directory
.trackers/{BASE_NAME}/plans/

## Your Task

Read the entire master plan, then generate ONLY these 3 phase plan files:
- {BASE_NAME}-04-data.md             (Phase 4: Data — repositories, DAOs, local storage)
- {BASE_NAME}-05-rules.md            (Phase 5: Rules — business logic, use cases, validation)
- {BASE_NAME}-06-state-management.md (Phase 6: State Management — ViewModels, presenters, state handlers)

For each phase:
1. Identify all tasks from the master plan that belong to this phase
2. Group tasks by feature tracks (lowercase-with-hyphens naming)
3. Score task complexity (1=Low, 2=Medium, 3=High)
4. Write the phase plan file using the standard phase plan template
5. If a phase has no tasks, use the empty phase template

Follow the develop:split-plan skill's phase classification rules:
- Phase 4: Accesses local storage, repositories, data access layer
- Phase 5: Contains business logic, use cases, domain validation
- Phase 6: Manages app state, ViewModels, reactive state management

After creating all 3 files, verify they exist and report:
- Files created (3/3)
- Tracks identified per phase
- Tasks per phase
- Complexity distribution"
```

**Agent 3 — Phases 7, 8**:
```
subagent_type: "develop:development-planner"
description: "Create phase plans 7-8 from master plan"
prompt: "Analyze the master plan and generate phase plan files for Phases 7 and 8 only.

## Master Plan Location
File: .trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md

## Base Name
Use base name: {BASE_NAME}

## Output Directory
.trackers/{BASE_NAME}/plans/

## Your Task

Read the entire master plan, then generate ONLY these 2 phase plan files:
- {BASE_NAME}-07-ui.md    (Phase 7: UI — screens, components, widgets, navigation)
- {BASE_NAME}-08-tests.md (Phase 8: Tests — unit tests, integration tests, test utilities)

For each phase:
1. Identify all tasks from the master plan that belong to this phase
2. Group tasks by feature tracks (lowercase-with-hyphens naming)
3. Score task complexity (1=Low, 2=Medium, 3=High)
4. Write the phase plan file using the standard phase plan template
5. If a phase has no tasks, use the empty phase template

Follow the develop:split-plan skill's phase classification rules:
- Phase 7: Renders UI, screens, components, widgets, user interactions, navigation
- Phase 8: Unit tests, integration tests, end-to-end tests, test utilities, mocks/fakes

For Phase 8 (Tests), identify all testing tasks:
- Unit tests for models, services, repositories, use cases, state management
- Integration tests for API clients, repositories, and complex workflows
- UI tests / widget tests / component tests
- Test utilities, mocks, fakes, and fixtures
- Test configuration and setup

After creating both files, verify they exist and report:
- Files created (2/2)
- Tracks identified per phase
- Tasks per phase
- Complexity distribution"
```

Wait for **all 3 agents to complete**. Expected output files:

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

Verify all 8 files exist, then present results to user:

```
Phase plans generated! All 8 phase plan files created.

Options:
- Type "proceed" to continue with tracker creation
- Type "review [phase-number]" to see a specific phase plan
- Type "review all" to see summary of all phases
```

Wait for response:
   - **"proceed"** → Step 5
   - **"review [N]"** → Read and display that phase plan, ask again
   - **"review all"** → Read all 8 plans, show summary, ask to proceed

**TaskUpdate Task 4 → completed**

---

## Step 5: Create Tracker and Populate from Phase Plans

**TaskUpdate Task 5 → in_progress**

1. Create empty tracker:
   ```
   Skill: "tracker:create-tracker"
   args: "{BASE_NAME}"
   ```

2. Read all 8 phase plan files to understand overall structure.

3. For each phase plan file (01–08) sequentially:

   a. Read the file; extract: phase name, tracks, tasks (title, description, complexity, priority, track)

   b. Add phase to tracker:
      ```
      Skill: "tracker:add-phase"
      args: "{BASE_NAME} --name='{Phase Name}' --description='{description}'"
      ```

   c. For each track in this phase:
      - If new track: add it:
        ```
        Skill: "tracker:add-track"
        args: "{BASE_NAME} --name='{track-name}' --description='{desc}' --phase='{Phase Name}'"
        ```
      - If already added: skip

   d. For each task in each track:
      ```
      Skill: "tracker:add-task"
      args: "{BASE_NAME} --phase='{Phase Name}' --track='{track}' --title='{title}' --description='{desc}' --complexity={1|2|3} --priority={high|medium|low}"
      ```

   e. Inform user: "Phase {N} added to tracker: {track_count} tracks, {task_count} tasks"

4. Verify tracker:
   ```
   Skill: "tracker:review-tracker"
   args: "{BASE_NAME} --detailed"
   ```

5. Inform user:
   ```
   Tracker creation complete!
   Tracker: {BASE_NAME}
   Location: .trackers/{BASE_NAME}/TRACKER.md
   Total Phases: 8 | Tracks: {count} | Tasks: {count}
   ```

**TaskUpdate Task 5 → completed**

---

## Step 6: Present Analysis and Select Phases

**TaskUpdate Task 6 → in_progress**

1. Run tracker review:
   ```
   Skill: "tracker:review-tracker"
   args: "{BASE_NAME} --detailed"
   ```

2. Present the full structure to user:

```
Analysis complete!

Source Requirements: {RESOLVED_FILE_PATH}
Master Plan: .trackers/{BASE_NAME}/plans/{BASE_NAME}-master-plan.md
Phase Plans: {BASE_NAME}-01 through {BASE_NAME}-08
Tracker: {BASE_NAME}

Feature Tracks Identified:
[List tracks from phase plan files with brief descriptions]

Phase Structure (Sequential execution):

Phase 1: Foundational
- Track: core ([X] tasks)
- Purpose: Set up base abstractions and toolings

Phase 2: Models
- Track: authentication ([X] tasks)
- Track: products ([X] tasks)
...

[Continue for phases 3–8]

Summary: Total Tasks: {count} | Tracks: {count} | Avg Complexity: {score}

Which phases would you like to execute?
- "All" — Execute all incomplete phases
- "Phase [N]" — Execute specific phase(s)
- "Phase [N] to [M]" — Execute a range
- "Review first" — Skip execution, go to summary
```

3. Wait for user response:
   - **Adjust organization** → Handle edits to phase plans, then ask again
   - **"Review first"** → Skip to Step 8
   - **Phase selection** → Parse selection, continue to Step 7

**NEVER proceed without explicit user confirmation on structure AND phase selection.**

**TaskUpdate Task 6 → completed**

---

## Step 7: Execute Implementations

**TaskUpdate Task 7 → in_progress**

For each selected phase, in order (1→2→...→8):

### 7.1 Read Phase Plan

Read `.trackers/{BASE_NAME}/plans/{BASE_NAME}-{NN}-{name}.md`

### 7.2 Get Pending Tasks

```
Skill: "tracker:review-tracker"
args: "{BASE_NAME} --phase={N} --status=pending"
```

Extract: task ID, name, description, track, complexity score, plan file reference. If no pending tasks, skip this phase.

### 7.3 Determine Agent Count

```
If pending tasks ≥ 3 → AGENT_COUNT = 3
If pending tasks < 3 → AGENT_COUNT = 1
```

Log to user:
```
Phase {N} — {name}:
- Pending Tasks: {count}
- Spawning {count} developer agent(s)...
```

### 7.4 Mark Tasks In Progress

For each pending task in the current batch:
```
Skill: "tracker:mark-status"
args: "{BASE_NAME} --task={task-id} --status=in-progress"
```

### 7.5 Execute Batches

Split pending tasks into batches of size `AGENT_COUNT`.

For each batch — spawn developer agents **in parallel** (single message, multiple Task calls):

```
subagent_type: "develop:senior-developer"
description: "Implement Task {id}"
prompt: "Implement Task {id} from Phase {N}: {name}

## Task Details
{Full task description}
Complexity: {score} ({Low|Medium|High})
Track: {track-name}

## Context
- Phase {N}: {name}
- Detailed plan: .trackers/{BASE_NAME}/plans/{plan-file-reference}
- Read the phase plan for full architectural context

## Implementation
Read the detailed phase plan, then implement this specific task.
Follow the project's existing patterns and architecture."
```

Wait for batch to complete, then update tracker:
- Success: `tracker:mark-status` → `complete`
- Failure: `tracker:mark-status` → `blocked`

Repeat batches until all pending tasks for this phase are processed.

### 7.6 Post-Phase Comprehensive Review Loop

After all tasks in this phase are implemented, run a review loop (max 4 iterations):

**Iteration tracking**: Start `REVIEW_ITERATION = 1`

**Loop:**

1. Execute comprehensive review:
   ```
   Skill: "develop:comprehensive-review"
   ```
   Pass context: the phase plan file and the changes made in this phase.

2. Collect all issues from the review report.

3. If **no issues found** → log "Phase {N} review passed. No issues found." → exit loop.

4. If **issues found** AND `REVIEW_ITERATION < 4`:
   - Create a `TodoWrite` todo for **each issue** found, with the issue description and file reference
   - For each todo (batch in groups of AGENT_COUNT):
     - Spawn `develop:senior-developer` agent(s) to fix the issue
     - Wait for completion
     - Mark todo as done
   - Set `REVIEW_ITERATION = REVIEW_ITERATION + 1`
   - Go back to step 1 (re-run review)

5. If `REVIEW_ITERATION == 4` (4th iteration):
   - Run the review one final time
   - Present remaining issues to the user but **do not fix further**
   - Log:
     ```
     Phase {N} review reached maximum iterations (4).
     Remaining issues: {count}
     Proceeding to next phase. Issues can be addressed in a follow-up run.
     ```
   - Exit loop

### 7.7 After Phase Completion

```
Skill: "tracker:review-tracker"
args: "{BASE_NAME} --phase={N}"
```

Ask user:
```
Phase {N}: {name} completed!
[Show tracker summary]

Next Phase: Phase {next-N}: {name}

Type "continue" to proceed, or "pause" to stop here.
```

- **"continue"** → next selected phase
- **"pause"** → go to Step 8

**TaskUpdate Task 7 → completed**

---

## Step 8: Generate Final Summary Report

**TaskUpdate Task 8 → in_progress**

1. Run tracker review:
   ```
   Skill: "tracker:review-tracker"
   args: "{BASE_NAME} --detailed"
   ```

2. Write summary to `.trackers/{BASE_NAME}/plans/{BASE_NAME}-SUMMARY.md` — see `references/summary-report.md` for the template.

3. Present to user:
   ```
   Build workflow complete!

   Summary: .trackers/{BASE_NAME}/plans/{BASE_NAME}-SUMMARY.md
   Tracker: .trackers/{BASE_NAME}/TRACKER.md

   Completed: {count} phases, {count} tasks
   Remaining: {count} phases, {count} tasks

   To view progress: /tracker:review-tracker {BASE_NAME}
   Resume at any time by running /develop-project again.
   ```

**TaskUpdate Task 8 → completed**
