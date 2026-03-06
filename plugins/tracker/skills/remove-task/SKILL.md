---
name: remove-task
description: This skill should be used when the user asks to "remove task", "delete task", "remove a task from tracker", "delete work item", or wants to permanently delete a single task and optionally its plan file.
---

# Remove Task Skill

Remove a task from an existing tracker. Removing a task will delete the task and optionally its plan file.

## Purpose

Remove a single task from the tracker and update statistics accordingly.

## Hierarchy Reminder

The tracker follows this structure:
- **Phase** (sequential stages) → contains multiple Tracks
- **Track** (feature groupings) → spans across Phases, contains Tasks
- **Task** (individual work items) → belongs to a Phase and Track

## Process Flow

### Step 1: Parse Arguments and Find Tracker

1. **Parse `$ARGUMENTS`** for:
   - Tracker name (first argument)
   - Optional flags:
     - `--task=NN` - Task number to remove
     - `--confirm` - Skip confirmation prompt
     - `--keep-plan` - Keep the plan file (don't delete it)

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
   - Parse all tasks to build task index

### Step 2: Identify Task to Remove

1. **Get task number** (if not from --task):
   ```
   Current tasks:

   Phase 1: Foundation
     Track: authentication
       01: Setup authentication framework [Pending] - Priority: High
       02: Configure OAuth providers [In Progress] - Priority: Medium
     Track: dashboard
       03: Create dashboard layout [Complete] - Priority: Medium

   Phase 2: Implementation
     Track: authentication
       04: Implement login API [Blocked] - Priority: High, Blocked by: 01

   Which task would you like to remove?
   Enter task number:
   ```

2. **Validate task exists**:
   - Search for `##### Task {TASK_NUMBER}:` in Tasks section
   - If not found:
     * Inform user: "Task {TASK_NUMBER} not found"
     * List available tasks
     * Exit

3. **Parse task details**:
   - Extract task information:
     * Task number
     * Task title
     * Phase number and name
     * Track name
     * Status
     * Priority
     * Plan file (if exists)
   - Store for confirmation message

### Step 3: Check for Dependencies

1. **Search for tasks that depend on this task**:
   - Parse all tasks looking for `**Blocked By**:` fields
   - Check if any task lists this task number
   - Store list of dependent tasks

2. **If dependent tasks found**, prepare warning message:
   ```
   ⚠️  Other tasks depend on this task:
   {FOR_EACH_DEPENDENT}
   - Task {TASK_NUMBER}: {TITLE} (Blocked by: ..., {THIS_TASK}, ...)
   {END_FOR}

   These tasks will have invalid dependencies after removal.
   ```

### Step 4: Confirm Deletion

**Unless --confirm flag is provided**, display warning and ask for confirmation:

```
⚠️  Remove Task {TASK_NUMBER}?

**Task**: {TASK_NUMBER}: {TITLE}
**Phase**: Phase {N}: {PHASE_NAME}
**Track**: {TRACK_NAME}
**Status**: {STATUS}
**Priority**: {PRIORITY}
{IF_PLAN_FILE}**Plan File**: {PLAN_FILENAME}{END_IF}

{IF_DEPENDENT_TASKS}
⚠️  WARNING: {DEPENDENT_COUNT} task(s) depend on this task:
{FOR_EACH_DEPENDENT}
- Task {TASK_NUMBER}: {TITLE}
{END_FOR}

These tasks will have invalid dependencies after removal.
{END_IF}

{IF_PLAN_FILE}
{IF_NOT_KEEP_PLAN}
The plan file will also be deleted: {PLAN_FILENAME}
{ELSE}
The plan file will be kept: {PLAN_FILENAME}
{END_IF}
{END_IF}

This action cannot be undone.

Are you sure you want to remove this task? (yes/no)
```

- If user responds "no" or cancels, exit without changes
- If user responds "yes", proceed with deletion

### Step 5: Remove Task from Tasks Section

1. **Find the task**:
   - Locate phase section: `### Phase {N}:`
   - Locate track subsection: `#### Track: {TRACK_NAME}`
   - Find task: `##### Task {TASK_NUMBER}: {TITLE}`

2. **Delete task entry**:
   - Remove entire task section including:
     * Task header (`##### Task {TASK_NUMBER}: ...`)
     * All task metadata (Status, Plan File, Priority, etc.)
     * Description
     * Acceptance criteria
     * All content until next task or track separator (`---`)
   - Use Edit tool to remove

3. **Handle empty track subsection**:
   - If this was the only task in the track subsection:
     * Replace with: `_No tasks yet. Use /add-task to add tasks to this track._`
   - Otherwise, leave track subsection intact

### Step 6: Update Track Progress

1. **Find the track** in Tracks section:
   - Locate: `### Track: {TRACK_NAME}`

2. **Recalculate progress**:
   - Count remaining tasks in this track across all phases
   - Count completed tasks in this track
   - Calculate new percentage

3. **Update track progress**:
   - Update: `**Progress**: {COMPLETED}/{TOTAL} tasks complete ({PERCENTAGE}%)`
   - Use Edit tool

### Step 7: Delete Plan File (if exists and not --keep-plan)

1. **If task has plan file** and `--keep-plan` not specified:
   - Delete plan file:
     ```bash
     rm .trackers/{TRACKER_NAME}/plans/{PLAN_FILENAME}
     ```
   - Confirm deletion

2. **If --keep-plan specified**:
   - Keep the plan file
   - Inform user that plan file was preserved

### Step 8: Update Overview and Metadata

1. **Update task count**:
   - Find: `- **Total Tasks**: {OLD_COUNT}`
   - Replace with: `- **Total Tasks**: {NEW_COUNT}`

2. **Update completion statistics**:
   - Recalculate overall completion:
     * Count all remaining tasks
     * Count completed tasks
     * Calculate percentage
   - Update: `- **Completed**: {COMPLETED}/{TOTAL} tasks ({PERCENTAGE}%)`

3. **Update metadata**:
   - Update `updated:` field in frontmatter to current date
   - Get current date:
     ```bash
     date +%Y-%m-%d
     ```

### Step 9: Confirm Removal

```
Task removed successfully!

**Removed**: Task {TASK_NUMBER}: {TITLE}
**From**: Phase {N}: {PHASE_NAME} / Track: {TRACK_NAME}
**Was**: {STATUS}, Priority: {PRIORITY}
{IF_PLAN_DELETED}**Plan file deleted**: {PLAN_FILENAME}{END_IF}
{IF_PLAN_KEPT}**Plan file kept**: {PLAN_FILENAME}{END_IF}

{IF_DEPENDENT_TASKS}
⚠️  WARNING: Update dependencies manually

The following tasks have invalid dependencies:
{FOR_EACH_DEPENDENT}
- Task {TASK_NUMBER}: {TITLE}
  Fix with: /edit-task {TRACKER_NAME} --task={TASK_NUMBER}
{END_FOR}
{END_IF}

**Tracker updated**:
- Total tasks: {OLD_TASK_COUNT} → {NEW_TASK_COUNT}
- Completion: {OLD_PERCENTAGE}% → {NEW_PERCENTAGE}%

**Track updated**:
- {TRACK_NAME}: {OLD_TRACK_PROGRESS} → {NEW_TRACK_PROGRESS}

**Next steps**:
{IF_DEPENDENT_TASKS}
- Fix task dependencies with /edit-task
{END_IF}
- Review tracker: /review-tracker {TRACKER_NAME}
- Add another task: /add-task {TRACKER_NAME}

View tracker: .trackers/{TRACKER_NAME}/TRACKER.md
```

## Important Notes

- **Single task operation**: Only removes one task at a time
- **No renumbering**: Task numbers are not renumbered after deletion
- **Plan files**: By default, associated plan files are deleted (use --keep-plan to preserve)
- **Dependencies**: Task dependencies are NOT automatically updated
- **Track progress**: Track progress statistics are recalculated
- **Confirmation required**: User must confirm unless --confirm flag is used
- **No undo**: This operation cannot be reversed
- **Gap in numbering**: Removing a task creates a gap in task numbering (this is intentional)

## Examples

### Example 1: Remove Single Task
```
/remove-task my-app --task=05
> Warning: Will delete Task 05: Implement login API
> Confirm: yes
> Task removed
> Plan file deleted: 05-implement-login-api.md
```

### Example 2: Interactive Selection
```
/remove-task my-app
> Shows all tasks with numbers
> Enter task: 03
> Warning: Will delete Task 03
> Confirm: yes
```

### Example 3: Keep Plan File
```
/remove-task my-app --task=07 --keep-plan
> Task removed but plan file kept
```

### Example 4: Skip Confirmation
```
/remove-task my-app --task=02 --confirm
> Task removed immediately without confirmation
```

### Example 5: Task with Dependencies
```
/remove-task my-app --task=01
> Warning: Task 04 and Task 06 depend on this task
> Confirm: yes
> Task removed
> Warning: Update dependencies manually for Task 04, 06
```

## Error Handling

- If tracker doesn't exist, inform user and exit
- If task doesn't exist, show available tasks
- If user cancels confirmation, exit without changes
- Validate all inputs before modifying
- Ensure tracker structure remains valid after removal
- Handle cases where plan file doesn't exist or deletion fails

## Post-Removal Validation

After removing the task:
1. Verify track progress is correct
2. Ensure task count matches actual tasks
3. Validate completion percentage is accurate
4. Check that track/phase structure is intact
5. **Manual check required**: Verify dependent tasks are updated

## Dependency Management

**Important**: When a task is removed, you must manually update dependent tasks:

1. **List all dependent tasks** in the confirmation output
2. **For each dependent task**:
   - Use `/edit-task {TRACKER} --task={NUMBER}` to update
   - Remove the deleted task from "Blocked By" field
   - Or replace with a different dependency

**Example dependency fix**:
```
Task 04 was blocked by: 01, 02, 03
Task 02 was removed
New blocking: 01, 03 (manually updated)
```

## Why Task Numbers Are Not Renumbered

Task numbers are preserved (creating gaps) because:
- Tasks may be referenced in external documentation
- Git commits may reference task numbers
- Plan files use task numbers in filenames
- Renumbering would break these references

If you need sequential numbers, create a new tracker and migrate tasks.

## Integration with Other Skills

- Use `/edit-task` to update dependent tasks
- Use `/review-tracker` to see updated structure
- Use `/add-task` to add replacement tasks
- Use `/mark-status` to mark tasks as cancelled instead of deleting
