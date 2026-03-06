---
name: mark-status
description: This skill should be used when the user asks to "mark status", "update status", "mark task as complete", "mark as done", "change status", "update task status", "mark as in progress", or wants to quickly update the status of a phase, track, or task without editing other metadata.
---

# Mark Status Skill

Quickly update the status of a phase, track, or task. This skill is optimized for status-only changes when no other edits are needed.

## Purpose

Update the status field of a phase, track, or task with minimal interaction, preserving all other details.

## Process Flow

### Step 1: Parse Arguments and Find Tracker

1. **Parse `$ARGUMENTS`** for:
   - Tracker name (first argument)
   - Entity type flags (one required):
     - `--task=NN` - Task number to update
     - `--track=name` - Track name to update
     - `--phase=N` - Phase number to update
   - Required flag:
     - `--status=value` - New status value

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
     * Ask: "Which tracker?"
     * Wait for response

3. **Verify tracker exists**:
   - Check if `.trackers/{TRACKER_NAME}/TRACKER.md` exists
   - If not found:
     * Inform user: "Tracker '{TRACKER_NAME}' not found"
     * Exit

4. **Read the tracker file**:
   - Use Read tool on `.trackers/{TRACKER_NAME}/TRACKER.md`

### Step 2: Determine Entity Type

Based on which flag was provided:

1. **If `--task=NN`**: Update task status (go to Step 3)
2. **If `--track=name`**: Update track status (go to Step 4)
3. **If `--phase=N`**: Update phase status (go to Step 5)
4. **If none provided**: Interactive mode

**Interactive mode**:
```
What would you like to update?

1. Task
2. Track
3. Phase

Enter number:
```

Then prompt for entity identifier and status.

### Step 3: Update Task Status

1. **Verify task exists**:
   - Search for `##### Task {TASK_NUMBER}:` in tracker
   - If not found:
     * Inform user: "Task {TASK_NUMBER} not found"
     * Exit

2. **Get status value** (if not from --status):
   ```
   Current status: {CURRENT_STATUS}

   New status:
   1. Pending
   2. In Progress
   3. Complete
   4. Blocked
   5. On Hold
   6. Cancelled

   Enter number or status name:
   ```

3. **Update task status**:
   - Find the task section
   - Update the status line:
     ```markdown
     **Status**: {NEW_STATUS}
     ```
   - If "In Progress" and no "Started" field exists, add:
     ```markdown
     **Started**: {CURRENT_DATE}
     ```
   - If "Complete", add or update:
     ```markdown
     **Completed**: {CURRENT_DATE}
     ```
   - Use Edit tool

4. **Update plan file** if exists:
   - Read plan file path from task
   - Update status and add progress log entry
   - Save plan file

5. **Recalculate statistics** (go to Step 6)

### Step 4: Update Track Status

1. **Verify track exists**:
   - Search for `### Track: {TRACK_NAME}` in Tracks section
   - If not found:
     * Inform user: "Track '{TRACK_NAME}' not found"
     * List available tracks
     * Exit

2. **Get status value** (if not from --status):
   ```
   Current status: {CURRENT_STATUS}

   New status:
   1. Not Started
   2. Planned
   3. In Progress
   4. On Hold
   5. Complete
   6. Cancelled

   Enter number or status name:
   ```

3. **Update track status**:
   - Find: `### Track: {TRACK_NAME}`
   - Update status line:
     ```markdown
     **Status**: {NEW_STATUS}
     ```
   - Add timestamps:
     * If "In Progress" and no start date: Add "Started: {DATE}"
     * If "Complete": Add "Completed: {DATE}"
   - Use Edit tool

4. **Recalculate statistics** (go to Step 6)

### Step 5: Update Phase Status

1. **Verify phase exists**:
   - Check if phase number is valid (1 to N)
   - If not: Show available phases and exit

2. **Get status value** (if not from --status):
   ```
   Current status: {CURRENT_STATUS}

   New status:
   1. Pending
   2. In Progress
   3. Complete

   Enter number or status name:
   ```

3. **Update phase status**:
   - Find: `### Phase {N}: {PHASE_NAME}`
   - Update status line:
     ```markdown
     **Status**: {NEW_STATUS}
     ```
   - Add timestamps:
     * If "In Progress": Add or update "Started: {DATE}"
     * If "Complete": Add or update "Completed: {DATE}"
   - Use Edit tool

4. **Recalculate statistics** (go to Step 6)

### Step 6: Recalculate Statistics

1. **Update Overview section**:
   - Count total tasks by status
   - Calculate completion percentage
   - Update completed count

2. **Update track progress** (if task was updated):
   - Count completed vs total tasks for affected track
   - Update track status line

3. **Update tracker metadata**:
   - Update `updated:` field to current date
   - Update overall tracker status if needed

### Step 7: Confirm Update

```
Status updated successfully!

{IF_TASK}
**Task {TASK_NUMBER}**: {TASK_TITLE}
Status: {OLD_STATUS} → {NEW_STATUS}
{IF_COMPLETED}Completed: {DATE}{END_IF}
{END_IF}

{IF_TRACK}
**Track**: {TRACK_NAME}
Status: {OLD_STATUS} → {NEW_STATUS}
Progress: {COMPLETED}/{TOTAL} tasks
{END_IF}

{IF_PHASE}
**Phase {N}**: {PHASE_NAME}
Status: {OLD_STATUS} → {NEW_STATUS}
{END_IF}

View tracker: .trackers/{TRACKER_NAME}/TRACKER.md
```

## Important Notes

- This skill ONLY updates status - use edit skills for other changes
- Statistics are recalculated automatically
- Timestamps are added automatically based on status
- Plan files are updated if they exist
- Faster than edit skills when only status change is needed
- Maintains all existing metadata and details

## Examples

### Example 1: Mark Task Complete
```
/mark-status my-app --task=03 --status=complete
```

### Example 2: Start a Track
```
/mark-status my-app --track=authentication --status="In Progress"
```

### Example 3: Complete a Phase
```
/mark-status my-app --phase=1 --status=complete
```

### Example 4: Interactive Mode
```
/mark-status my-app
> What to update? 1 (task)
> Task number? 05
> New status? 2 (In Progress)
```

## Valid Status Values

**For Tasks**:
- Pending
- In Progress
- Complete
- Blocked
- On Hold
- Cancelled

**For Tracks**:
- Not Started
- Planned
- In Progress
- On Hold
- Complete
- Cancelled

**For Phases**:
- Pending
- In Progress
- Complete

## Error Handling

- If tracker doesn't exist, inform user and exit
- If entity not found, show available options
- If invalid status value, show valid options
- Validate all inputs before modifying
- Preserve existing structure and formatting
