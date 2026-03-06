---
name: add-task
description: This skill should be used when the user asks to "add a task", "add task to tracker", "create a new task", "add work item", "add a todo to tracker", or wants to add tasks with phase, track, priority, and complexity metadata.
---

# Add Task Skill

Add a new task to an existing tracker. Tasks are organized by phase and track, with metadata like priority, complexity, and acceptance criteria.

## Purpose

Add a new task to an existing tracker, updating both the task list and the tracker's overview statistics.

## Process Flow

### Step 1: Parse Arguments and Find Tracker

1. **Parse `$ARGUMENTS`** for:
   - Tracker name (first argument)
   - Optional flags:
     - `--phase=N` - Phase number
     - `--track=name` - Track name
     - `--priority=value` - Priority level
     - `--complexity=value` - Complexity level

2. **If tracker name not provided**:
   - List available trackers:
     ```bash
     ls -1 .trackers/
     ```
   - If no trackers exist:
     * Inform user: "No trackers found. Create one with /create-tracker"
     * Exit
   - If trackers exist:
     * Show list to user
     * Ask: "Which tracker would you like to add a task to?"
     * Wait for response

3. **Verify tracker exists**:
   - Check if `.trackers/{TRACKER_NAME}/TRACKER.md` exists
   - If not found:
     * Inform user: "Tracker '{TRACKER_NAME}' not found"
     * List available trackers
     * Exit

4. **Read the tracker file**:
   - Use Read tool on `.trackers/{TRACKER_NAME}/TRACKER.md`
   - Parse the content to extract:
     * Existing phases
     * Existing tracks
     * Current task count
     * Next available task number

### Step 2: Gather Task Information

Ask the user for task details (skip if provided via arguments):

1. **Task Title**:
   ```
   What is the task title?
   Example: "Implement user login API"
   ```

2. **Phase** (if not provided via --phase):
   ```
   Which phase is this task in?

   Available phases:
   1. Phase 1: {NAME}
   2. Phase 2: {NAME}
   ...

   Enter phase number:
   ```

3. **Track** (if not provided via --track):
   ```
   Which track does this task belong to?

   Existing tracks: {LIST_TRACKS}

   Enter track name (or create new):
   ```

4. **Priority** (if not provided via --priority):
   ```
   What is the priority? (High/Medium/Low)
   Press Enter for Medium:
   ```

5. **Complexity** (if not provided via --complexity):
   ```
   What is the complexity? (High/Medium/Low)
   Press Enter for Medium:
   ```

6. **Description**:
   ```
   Provide a brief description of the task (optional):
   ```

7. **Acceptance Criteria**:
   ```
   Add acceptance criteria? (y/n)
   Press Enter to skip:
   ```

   If yes:
   ```
   Enter acceptance criteria (one per line, empty line to finish):
   -
   ```

8. **Dependencies**:
   ```
   Does this task depend on other tasks? (y/n)
   Press Enter for no:
   ```

   If yes:
   ```
   Enter task numbers this task is blocked by (comma-separated):
   Example: 01, 03, 05
   ```

9. **Create plan file?**:
   ```
   Create a detailed plan file for this task? (y/n)
   Press Enter for no:
   ```

### Step 3: Calculate Task Number

1. **Parse existing tasks** from tracker file:
   - Find all task numbers in the format "Task NN:"
   - Extract the highest number
   - New task number = highest + 1
   - Format with zero-padding: 01, 02, 03, etc.

2. **Generate plan filename** (if plan file requested):
   - Sanitize task title (lowercase, hyphens, remove special chars)
   - Format: `{TASK_NUMBER}-{sanitized-title}.md`
   - Example: `05-implement-user-login.md`

### Step 4: Add Task to Tracker

1. **Find the correct phase section** in the tracker file:
   - Locate: `### Phase {N}: {NAME}`
   - Find the subsection for the track or create it

2. **Build task entry**:

```markdown
##### Task {TASK_NUMBER}: {TASK_TITLE}
**Status**: Pending
{IF_PLAN_FILE}**Plan File**: {PLAN_FILENAME}{END_IF}
**Priority**: {PRIORITY}
**Complexity**: {COMPLEXITY}
{IF_BLOCKED_BY}**Blocked By**: {TASK_NUMBERS}{END_IF}

{DESCRIPTION}

{IF_ACCEPTANCE_CRITERIA}
**Acceptance Criteria**:
{FOR_EACH_CRITERION}
- [ ] {CRITERION}
{END_FOR_EACH}
{END_IF}

---
```

3. **Insert task into tracker**:
   - Find the section: `### Phase {N}: {PHASE_NAME}`
   - Find or create subsection: `#### Track: {TRACK_NAME}`
   - If track doesn't exist in this phase, create the track header
   - Append the task entry
   - Use Edit tool to insert at the correct location

4. **Update Overview section**:
   - Increment "Total Tasks" count
   - Update "Completed" ratio (still 0% if new task is pending)
   - If new track was created, increment "Total Tracks"

5. **Update Track status** (if exists in Tracks section):
   - Find: `### Track: {TRACK_NAME}`
   - Update task count: "{N}/{M} tasks complete"
   - If new track, add it to the Tracks section:
   ```markdown
   ### Track: {TRACK_NAME}
   **Phase Coverage**: {PHASE_NUMBER}-{MAX_PHASE}
   **Status**: Not Started (0/1 tasks complete)
   ```

6. **Update metadata**:
   - Update `updated:` field in frontmatter to current date

### Step 5: Create Plan File (if requested)

If user requested a plan file:

1. **Create plan file** at `.trackers/{TRACKER_NAME}/plans/{PLAN_FILENAME}`:

```markdown
# Task {TASK_NUMBER}: {TASK_TITLE}

**Phase**: {PHASE_NUMBER} - {PHASE_NAME}
**Track**: {TRACK_NAME}
**Priority**: {PRIORITY}
**Complexity**: {COMPLEXITY}
**Status**: Pending
{IF_BLOCKED_BY}**Blocked By**: Task {TASK_NUMBERS}{END_IF}

## Description

{DESCRIPTION}

## Acceptance Criteria

{FOR_EACH_CRITERION}
- [ ] {CRITERION}
{END_FOR_EACH}

## Implementation Plan

_Add detailed implementation steps here_

## Notes

_Add any additional notes, context, or decisions here_

## Progress Log

### {CURRENT_DATE}
- Task created
```

2. **Save the plan file** using Write tool

### Step 6: Confirm Addition

Inform the user:

```
Task added successfully!

**Task Number**: {TASK_NUMBER}
**Title**: {TASK_TITLE}
**Phase**: {PHASE_NUMBER} - {PHASE_NAME}
**Track**: {TRACK_NAME}
**Priority**: {PRIORITY}
**Complexity**: {COMPLEXITY}
**Status**: Pending
{IF_PLAN_FILE}
**Plan File**: .trackers/{TRACKER_NAME}/plans/{PLAN_FILENAME}
{END_IF}

**Tracker updated**:
- Total tasks: {NEW_TOTAL}
- Task added to Phase {N}
{IF_NEW_TRACK}
- New track created: {TRACK_NAME}
{END_IF}

**Next steps**:
- Review tracker: /review-tracker {TRACKER_NAME}
- Add another task: /add-task {TRACKER_NAME}
- Update task status: /update-tracker {TRACKER_NAME} --task={TASK_NUMBER}

View tracker: .trackers/{TRACKER_NAME}/TRACKER.md
```

## Important Notes

- Task numbers are auto-incremented and zero-padded (01, 02, 03...)
- Tasks are inserted into the correct phase and track section
- Overview statistics are updated automatically
- New tracks are created automatically if they don't exist
- Plan files are optional but recommended for complex tasks
- All edits maintain the tracker's markdown structure
- The tracker file is the single source of truth

## Examples

### Example 1: Quick Task Addition
```
/add-task my-app
> Title: "Setup authentication framework"
> Phase: 1
> Track: authentication
> Priority: High
> (accepts defaults for rest)
```

### Example 2: Detailed Task with Arguments
```
/add-task my-app --phase=2 --track=dashboard --priority=high
> Title: "Implement data visualization widgets"
> Complexity: Medium
> Create plan file: yes
> Acceptance criteria: ...
```

### Example 3: Task with Dependencies
```
/add-task my-app --phase=3
> Title: "Test authentication flow"
> Track: authentication
> Blocked by: 01, 02, 04
```

## Error Handling

- If tracker doesn't exist, list available trackers and exit
- If invalid phase number, show available phases
- If invalid priority/complexity, use default (Medium)
- If task insertion fails, report error
- Validate all inputs before modifying tracker
- Preserve existing tracker structure and formatting
