---
name: edit-tracker
description: This skill should be used when the user asks to "edit tracker", "update tracker name", "modify tracker", "rename tracker", "change tracker description", or wants to edit tracker-level metadata (not task/phase/track details or statuses).
---

# Edit Tracker Skill

Edit tracker-level metadata. This skill is for modifying tracker name and description, not for updating task, phase, or track details or statuses.

## Purpose

Update tracker name or description in the frontmatter and header sections.

## Hierarchy Reminder

The tracker follows this structure:
- **Tracker** (project container) → contains multiple Phases
- **Phase** (sequential stages) → contains multiple Tracks
- **Track** (feature groupings) → spans across Phases, contains Tasks
- **Task** (individual work items) → belongs to a Phase and Track

## Process Flow

### Step 1: Parse Arguments and Find Tracker

1. **Parse `$ARGUMENTS`** for:
   - Tracker name (first argument)
   - Optional flags:
     - `--name="New Name"` - New tracker name (display name only, not directory)
     - `--description="text"` - New tracker description
     - `--remove-description` - Remove existing description

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
   - Parse frontmatter and content

### Step 2: Display Current Information

Show current tracker metadata:

```
Current tracker information:
- Directory: {TRACKER_NAME}
- Name: {CURRENT_NAME}
- Created: {CREATED_DATE}
- Last Updated: {UPDATED_DATE}
- Status: {CURRENT_STATUS}
- Description: {DESCRIPTION or "None"}

Statistics:
- Total Phases: {PHASE_COUNT}
- Total Tracks: {TRACK_COUNT}
- Total Tasks: {TASK_COUNT}
- Completed: {COMPLETED}/{TOTAL} ({PERCENTAGE}%)
```

### Step 3: Gather Update Information

Ask for updates (skip fields provided via arguments):

1. **If no update flags provided**:
   ```
   What would you like to edit?

   Options:
   1. Tracker name (display name)
   2. Description
   3. Both
   4. Cancel

   Enter choice:
   ```

2. **Tracker Name** (if --name not provided):
   ```
   Current tracker name: {CURRENT_NAME}

   Enter new tracker name (or press Enter to keep current):
   Note: This updates the display name only, not the directory name.

   Examples: "E-Commerce Platform", "Mobile App v2.0", "API Redesign"
   ```

3. **Description** (if --description not provided):
   ```
   Current description: {CURRENT_DESCRIPTION or "None"}

   Enter new tracker description (or press Enter to keep current):
   Leave blank to remove description.

   This can be a brief overview of the project or tracker purpose.
   ```

### Step 4: Update Tracker Frontmatter

1. **Get current date**:
   ```bash
   date +%Y-%m-%d
   ```

2. **Update frontmatter fields**:

```yaml
---
name: "{NEW_NAME or CURRENT_NAME}"
created: {CREATED_DATE}
updated: {CURRENT_DATE}
status: "{CURRENT_STATUS}"
{IF_DESCRIPTION}
description: "{NEW_DESCRIPTION}"
{END_IF}
---
```

3. **Use Edit tool** to update frontmatter section

### Step 5: Update Tracker Header

1. **Update the main heading**:
   - Find: `# Tracker: {OLD_NAME}`
   - Replace with: `# Tracker: {NEW_NAME or CURRENT_NAME}`
   - Use Edit tool

2. **Add or update description section** (if description provided):
   - After the main heading, before Overview section:

```markdown
# Tracker: {TRACKER_NAME}

{IF_DESCRIPTION}
{NEW_DESCRIPTION}

{END_IF}
## Overview
...
```

3. **Use Edit tool** to insert or update description

### Step 6: Confirm Update

```
Tracker metadata updated successfully!

**Tracker**: {TRACKER_NAME}
**Updated**: {CURRENT_DATE}

**Changes made**:
{IF_NAME_CHANGED}- Display name: {OLD_NAME} → {NEW_NAME}{END_IF}
{IF_DESCRIPTION_CHANGED}- Description: {CHANGE_TYPE}{END_IF}

**Current state**:
- Name: {NEW_NAME}
- Directory: .trackers/{TRACKER_NAME}/
- Created: {CREATED_DATE}
- Status: {CURRENT_STATUS}
{IF_DESCRIPTION}
- Description: {DESCRIPTION}
{END_IF}

**Project Statistics**:
- Phases: {PHASE_COUNT}
- Tracks: {TRACK_COUNT}
- Tasks: {COMPLETED}/{TOTAL} complete ({PERCENTAGE}%)

**Next steps**:
- Review tracker: /review-tracker {TRACKER_NAME}
- Update task status: /mark-status {TRACKER_NAME} --task=NN --status=value
- Edit phases: /edit-phase {TRACKER_NAME} --phase=N
- Edit tracks: /edit-track {TRACKER_NAME} --track=name

View tracker: .trackers/{TRACKER_NAME}/TRACKER.md
```

## Important Notes

- This skill edits TRACKER metadata only
- Does NOT change directory name (only display name)
- Does NOT update task, phase, or track statuses
- Use `/mark-status` for status updates
- Use `/edit-task`, `/edit-phase`, `/edit-track` for those entities
- Tracker statistics are read-only (auto-calculated)
- `updated` date is always set to current date
- `created` date is never changed

## Examples

### Example 1: Update Tracker Name
```
/edit-tracker my-app --name="My Awesome Application"
> Tracker display name updated to "My Awesome Application"
> Directory remains: .trackers/my-app/
```

### Example 2: Add Description
```
/edit-tracker my-app --description="Full-stack web application with React frontend and Node.js backend"
> Description added to tracker
```

### Example 3: Interactive Edit
```
/edit-tracker my-app
> What to edit? 3 (both)
> New name: "Enterprise Dashboard Platform"
> Description: "Real-time analytics dashboard for enterprise clients"
```

### Example 4: Remove Description
```
/edit-tracker my-app --remove-description
> Description removed from tracker metadata
```

## Error Handling

- If tracker doesn't exist, inform user and exit
- If no changes made, inform user (no-op)
- Validate all inputs before modifying
- Preserve existing structure and formatting
- Maintain all statistics and relationships

## Integration with Other Skills

### Works with:
- `/create-tracker` - Create trackers before editing them
- `/review-tracker` - View tracker after edits
- `/edit-phase` - Edit individual phases
- `/edit-track` - Edit individual tracks
- `/edit-task` - Edit individual tasks
- `/mark-status` - Update statuses

### Common workflows:
1. **Set up new tracker**:
   ```
   /create-tracker my-project
   /edit-tracker my-project --name="My Project" --description="Project description"
   /add-phase my-project
   ```

2. **Refine tracker details**:
   ```
   /edit-tracker my-app --description="Updated project scope and objectives"
   ```

3. **Update display name**:
   ```
   /edit-tracker api-v2 --name="API Platform v2.0"
   ```

## What This Skill Does NOT Do

- Change directory or file names
- Update task, phase, or track statuses (use `/mark-status`)
- Edit task details (use `/edit-task`)
- Edit phase details (use `/edit-phase`)
- Edit track details (use `/edit-track`)
- Modify statistics (auto-calculated)
- Change created date
- Add or remove phases/tracks/tasks
