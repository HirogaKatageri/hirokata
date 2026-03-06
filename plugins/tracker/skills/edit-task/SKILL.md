---
name: edit-task
description: This skill should be used when the user asks to "edit task", "update task details", "modify task", "change task priority", "update task title", "edit acceptance criteria", "change task complexity", or wants to edit task metadata (excluding status changes, use mark-status for that).
---

# Edit Task Skill

Edit an existing task's details. This skill is for modifying task metadata, not status (use `/mark-status` for status-only changes).

## Purpose

Update task title, description, priority, complexity, acceptance criteria, dependencies, or other metadata while preserving structure.

## Hierarchy Reminder

The tracker follows this structure:
- **Phase** (sequential stages) → contains multiple Tracks
- **Track** (feature groupings) → spans across Phases, contains Tasks
- **Task** (individual work items) → belongs to a Phase and Track

## Process Flow

### Step 1: Parse Arguments and Find Tracker

1. **Parse `$ARGUMENTS`** for:
   - Tracker name (first argument)
   - Required flag:
     - `--task=NN` - Task number to edit
   - Optional flags:
     - `--title="New Title"` - New task title
     - `--description="text"` - New or updated description
     - `--priority=value` - New priority (High/Medium/Low)
     - `--complexity=value` - New complexity (High/Medium/Low)
     - `--add-criteria="criterion"` - Add acceptance criterion
     - `--blocked-by="01,02"` - Update dependencies
     - `--clear-blocked` - Remove all dependencies

2. **If tracker name not provided**:
   - List available trackers:
     ```bash
     ls -1 .trackers/
     ```
   - If no trackers exist:
     * Inform user: "No trackers found. Create one with /create-tracker"
     * Exit
   - If trackers exist:
     * Show list and ask user to select

3. **Verify tracker exists**:
   - Check if `.trackers/{TRACKER_NAME}/TRACKER.md` exists
   - If not found, inform user and exit

4. **Read the tracker file**:
   - Use Read tool on `.trackers/{TRACKER_NAME}/TRACKER.md`
   - Parse to find task and extract current state

### Step 2: Identify and Verify Task

1. **Parse task number from arguments**:
   - If `--task` flag provided, extract task number
   - If not provided:
     ```
     Available tasks:
     01: Setup authentication framework [Pending] - Phase 1, authentication
     02: Create user model [In Progress] - Phase 1, user-management
     03: Implement login API [Complete] - Phase 2, authentication
     ...

     Which task would you like to edit?
     Enter task number:
     ```

2. **Verify task exists**:
   - Search for `##### Task {TASK_NUMBER}:` in tracker
   - If not found:
     * Inform user: "Task {TASK_NUMBER} not found"
     * Exit

3. **Extract current task information**:
   - Parse the task section:
     * Current title
     * Current status
     * Current priority
     * Current complexity
     * Current description
     * Current acceptance criteria
     * Current dependencies (blocked by)
     * Plan file (if exists)
     * Phase and track

4. **Display current information**:
   ```
   Current task information:
   - Task: {TASK_NUMBER}
   - Title: {CURRENT_TITLE}
   - Status: {CURRENT_STATUS}
   - Phase: {PHASE_NUMBER} - {PHASE_NAME}
   - Track: {TRACK_NAME}
   - Priority: {CURRENT_PRIORITY}
   - Complexity: {CURRENT_COMPLEXITY}
   - Description: {DESCRIPTION or "None"}
   - Acceptance Criteria: {COUNT} items
   - Blocked By: {TASK_NUMBERS or "None"}
   - Plan File: {PLAN_FILE or "None"}
   ```

### Step 3: Gather Update Information

Ask for updates (skip fields provided via arguments):

1. **If no update flags provided**:
   ```
   What would you like to edit?

   Options:
   1. Task title
   2. Description
   3. Priority
   4. Complexity
   5. Acceptance criteria
   6. Dependencies
   7. Multiple fields
   8. Cancel

   Enter choice (or comma-separated numbers):
   ```

2. **For each selected field**:

   **Title** (if --title not provided):
   ```
   Current title: {CURRENT_TITLE}

   Enter new task title (or press Enter to keep current):
   ```

   **Description** (if --description not provided):
   ```
   Current description: {CURRENT_DESCRIPTION or "None"}

   Enter new description (or press Enter to keep current):
   Leave blank to remove description.
   ```

   **Priority** (if --priority not provided):
   ```
   Current priority: {CURRENT_PRIORITY}

   New priority:
   1. High
   2. Medium
   3. Low

   Enter number or priority name (or press Enter to keep current):
   ```

   **Complexity** (if --complexity not provided):
   ```
   Current complexity: {CURRENT_COMPLEXITY}

   New complexity:
   1. High
   2. Medium
   3. Low

   Enter number or complexity level (or press Enter to keep current):
   ```

   **Acceptance Criteria**:
   ```
   Current acceptance criteria:
   {FOR_EACH_CRITERION}
   - [ ] {CRITERION}
   {END_FOR_EACH}

   What would you like to do?
   1. Add new criteria
   2. Remove criteria
   3. Replace all criteria
   4. Cancel

   Enter choice:
   ```

   If adding:
   ```
   Enter new acceptance criteria (one per line, empty line to finish):
   -
   ```

   If removing:
   ```
   Which criteria to remove? (comma-separated numbers, 1-based)
   ```

   If replacing:
   ```
   Enter new acceptance criteria (one per line, empty line to finish):
   -
   ```

   **Dependencies** (if --blocked-by not provided):
   ```
   Current dependencies: Task {TASK_NUMBERS or "None"}

   New blocked by tasks (comma-separated numbers):
   Leave blank to remove all dependencies.
   Example: 01, 03, 05
   ```

### Step 4: Update Task in Tracker

1. **Find the task section**:
   - Locate: `##### Task {TASK_NUMBER}: {OLD_TITLE}`

2. **Build updated task entry**:

```markdown
##### Task {TASK_NUMBER}: {NEW_TITLE or CURRENT_TITLE}
**Status**: {CURRENT_STATUS}
{IF_PLAN_FILE}**Plan File**: {PLAN_FILENAME}{END_IF}
**Priority**: {NEW_PRIORITY or CURRENT_PRIORITY}
**Complexity**: {NEW_COMPLEXITY or CURRENT_COMPLEXITY}
{IF_BLOCKED_BY}**Blocked By**: Task {TASK_NUMBERS}{END_IF}
{IF_STARTED}**Started**: {START_DATE}{END_IF}
{IF_COMPLETED}**Completed**: {COMPLETE_DATE}{END_IF}

{IF_DESCRIPTION}
{NEW_DESCRIPTION}

{END_IF}
{IF_ACCEPTANCE_CRITERIA}
**Acceptance Criteria**:
{FOR_EACH_CRITERION}
- [ ] {CRITERION}
{END_FOR_EACH}
{END_IF}

---
```

3. **Replace the task section**:
   - Use Edit tool to update the entire task entry
   - Preserve status, timestamps, and plan file reference
   - Maintain position in phase and track

### Step 5: Update Plan File (if exists)

If task has a plan file:

1. **Read plan file**:
   - Parse plan file path from task
   - Read `.trackers/{TRACKER_NAME}/plans/{PLAN_FILE}`

2. **Update plan file fields**:
   - Update title if changed
   - Update priority if changed
   - Update complexity if changed
   - Update description if changed
   - Update acceptance criteria if changed
   - Add progress log entry:
     ```markdown
     ### {CURRENT_DATE}
     - Task details updated
     {LIST_CHANGES}
     ```

3. **Save updated plan file**:
   - Use Edit tool to update plan file

### Step 6: Update Metadata

1. **Update tracker's `updated` field**:
   - Get current date:
     ```bash
     date +%Y-%m-%d
     ```
   - Update frontmatter `updated:` field
   - Use Edit tool

### Step 7: Confirm Update

```
Task updated successfully!

**Task {TASK_NUMBER}**: {NEW_TITLE or CURRENT_TITLE}

**Changes made**:
{IF_TITLE_CHANGED}- Title: {OLD_TITLE} → {NEW_TITLE}{END_IF}
{IF_DESCRIPTION_CHANGED}- Description updated{END_IF}
{IF_PRIORITY_CHANGED}- Priority: {OLD} → {NEW}{END_IF}
{IF_COMPLEXITY_CHANGED}- Complexity: {OLD} → {NEW}{END_IF}
{IF_CRITERIA_CHANGED}- Acceptance criteria: {CHANGE_DESCRIPTION}{END_IF}
{IF_DEPENDENCIES_CHANGED}- Dependencies: {CHANGE_DESCRIPTION}{END_IF}

**Current state**:
- Status: {CURRENT_STATUS}
- Phase: {PHASE_NUMBER} - {PHASE_NAME}
- Track: {TRACK_NAME}
- Priority: {PRIORITY}
- Complexity: {COMPLEXITY}
{IF_BLOCKED_BY}- Blocked By: Task {TASK_NUMBERS}{END_IF}
{IF_PLAN_FILE}
- Plan File: {PLAN_FILE} (updated)
{END_IF}

**Next steps**:
- Update task status: /mark-status {TRACKER_NAME} --task={TASK_NUMBER} --status=value
- Review tracker: /review-tracker {TRACKER_NAME}
- Edit another task: /edit-task {TRACKER_NAME}

View tracker: .trackers/{TRACKER_NAME}/TRACKER.md
```

## Important Notes

- This skill edits task DETAILS, not status
- Use `/mark-status` for status-only changes
- Task number and phase/track assignment cannot be changed here
- Status and timestamps are preserved
- Plan files are updated along with tracker
- All changes maintain markdown structure
- Acceptance criteria can be added, removed, or replaced

## Examples

### Example 1: Update Title and Priority
```
/edit-task my-app --task=03 --title="Implement secure user login API" --priority=high
> Task 03 title and priority updated
```

### Example 2: Add Acceptance Criteria
```
/edit-task my-app --task=05 --add-criteria="Must support OAuth2"
> Acceptance criterion added to Task 05
```

### Example 3: Update Dependencies
```
/edit-task my-app --task=07 --blocked-by="01,03,05"
> Task 07 dependencies updated
```

### Example 4: Interactive Multiple Fields
```
/edit-task my-app --task=02
> What to edit? 1,3,5 (title, priority, criteria)
> New title: "Create comprehensive user data model"
> Priority: 1 (High)
> Acceptance criteria: Add
> - Supports all required user fields
> - Includes validation rules
> (empty line to finish)
```

### Example 5: Clear Dependencies
```
/edit-task my-app --task=04 --clear-blocked
> All dependencies removed from Task 04
```

### Example 6: Update Description
```
/edit-task my-app --task=08 --description="Implement comprehensive error handling for all API endpoints with proper status codes and user-friendly messages"
```

## Error Handling

- If tracker doesn't exist, inform user and exit
- If task doesn't exist, show available tasks
- If invalid priority/complexity, show valid options
- If blocked-by task doesn't exist, warn and ask to confirm
- Validate all inputs before modifying
- Preserve existing structure and formatting
- Handle missing fields gracefully

## Integration with Other Skills

### Works with:
- `/add-task` - Add tasks before editing them
- `/mark-status` - Update task status after editing details
- `/review-tracker` - View task changes
- `/edit-tracker` - Edit tracker-level metadata

### Common workflows:
1. **Refine task before starting**:
   ```
   /edit-task my-app --task=05 --priority=high --add-criteria="Must be mobile responsive"
   /mark-status my-app --task=05 --status="In Progress"
   ```

2. **Update task after feedback**:
   ```
   /edit-task my-app --task=03 --description="Updated based on code review feedback"
   ```

3. **Adjust dependencies**:
   ```
   /edit-task my-app --task=10 --blocked-by="07,08,09"
   ```
