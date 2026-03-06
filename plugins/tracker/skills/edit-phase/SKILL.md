---
name: edit-phase
description: This skill should be used when the user asks to "edit phase", "update phase details", "modify phase", "rename phase", "change phase name", "update phase description", or wants to edit phase metadata (excluding status changes, use mark-status for that).
---

# Edit Phase Skill

Edit an existing phase's details. This skill is for modifying phase metadata, not status (use `/mark-status` for status-only changes).

## Purpose

Update phase name, description, or other metadata while preserving tasks and structure.

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
     - `--phase=N` - Phase number to edit
   - Optional flags:
     - `--name="New Name"` - New phase name
     - `--description="text"` - New or updated description
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
   - Parse existing phases

### Step 2: Identify and Verify Phase

1. **Parse phase number from arguments**:
   - If `--phase` flag provided, extract phase number
   - If not provided:
     ```
     Available phases:
     1. Phase 1: {NAME} - {STATUS}
     2. Phase 2: {NAME} - {STATUS}
     3. Phase 3: {NAME} - {STATUS}

     Which phase would you like to edit?
     Enter phase number:
     ```

2. **Verify phase exists**:
   - Check if phase number is valid (1 to total phases)
   - If not found:
     * Inform user: "Phase {N} not found"
     * Show available phases
     * Exit

3. **Extract current phase information**:
   - Parse the phase section:
     * Current name
     * Current status
     * Current description (if exists)
     * Started/completed dates

4. **Display current information**:
   ```
   Current phase information:
   - Number: Phase {N}
   - Name: {CURRENT_NAME}
   - Status: {CURRENT_STATUS}
   - Description: {DESCRIPTION or "None"}
   - Started: {DATE or "-"}
   - Completed: {DATE or "-"}
   ```

### Step 3: Gather Update Information

Ask for updates (skip fields provided via arguments):

1. **If no update flags provided**:
   ```
   What would you like to edit?

   Options:
   1. Phase name
   2. Description
   3. Both
   4. Cancel

   Enter choice:
   ```

2. **Phase Name** (if --name not provided and selected):
   ```
   Current name: {CURRENT_NAME}

   Enter new phase name (or press Enter to keep current):
   Examples: "Foundation", "Implementation", "Testing"
   ```

3. **Description** (if --description not provided and selected):
   ```
   Current description: {CURRENT_DESCRIPTION or "None"}

   Enter new description (or press Enter to keep current):
   Leave blank to remove description.
   ```

### Step 4: Update Phase in Phases Section

1. **Find the phase section**:
   - Locate: `### Phase {N}: {OLD_NAME}`

2. **Build updated phase entry**:

```markdown
### Phase {N}: {NEW_NAME or CURRENT_NAME}
**Status**: {CURRENT_STATUS}
**Started**: {START_DATE or "-"}
**Completed**: {COMPLETE_DATE or "-"}
{IF_DESCRIPTION}

{NEW_DESCRIPTION}
{END_IF}
```

3. **Replace the phase section**:
   - Use Edit tool to update the phase header and content
   - Maintain position in Phases section
   - Preserve status and timestamp fields

### Step 5: Update Phase Name in Tasks Section

If the phase name was changed:

1. **Find Tasks section**:
   - Locate: `### Phase {N}: {OLD_NAME}`
   - Replace with: `### Phase {N}: {NEW_NAME}`
   - Use Edit tool

2. **Maintain task structure**:
   - All tasks under this phase remain unchanged
   - Only the phase header is updated

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
Phase updated successfully!

**Phase {N}**: {NEW_NAME or CURRENT_NAME}

**Changes made**:
{IF_NAME_CHANGED}- Name: {OLD_NAME} → {NEW_NAME}{END_IF}
{IF_DESCRIPTION_CHANGED}- Description updated{END_IF}
{IF_DESCRIPTION_REMOVED}- Description removed{END_IF}

**Current state**:
- Status: {CURRENT_STATUS}
- Started: {START_DATE or "Not started"}
- Completed: {COMPLETE_DATE or "Not completed"}
{IF_DESCRIPTION}- Description: {NEW_DESCRIPTION}{END_IF}

**Next steps**:
- Update phase status: /mark-status {TRACKER_NAME} --phase={N} --status=value
- Add tasks: /add-task {TRACKER_NAME} --phase={N}
- Review tracker: /review-tracker {TRACKER_NAME}

View tracker: .trackers/{TRACKER_NAME}/TRACKER.md
```

## Important Notes

- This skill edits phase DETAILS, not status
- Use `/mark-status` for status-only changes
- Phase number never changes (it's the sequential position)
- Renaming updates both Phases and Tasks sections
- Status and timestamps are preserved
- All tasks in the phase remain unchanged
- Description is optional and can be added/removed

## Examples

### Example 1: Rename Phase
```
/edit-phase my-app --phase=2 --name="Core Development"
> Phase 2 renamed from "Implementation" to "Core Development"
```

### Example 2: Update Description
```
/edit-phase my-app --phase=1 --description="Foundation work including architecture and setup"
> Description updated for Phase 1
```

### Example 3: Both Name and Description
```
/edit-phase my-app --phase=3 --name="QA & Testing" --description="Quality assurance and user acceptance testing"
> Phase 3 name and description updated
```

### Example 4: Interactive Mode
```
/edit-phase my-app --phase=1
> What to edit? 3 (both)
> New name: "Project Setup"
> Description: "Initial setup and configuration"
```

### Example 5: Remove Description
```
/edit-phase my-app --phase=2 --remove-description
> Description removed from Phase 2
```

## Error Handling

- If tracker doesn't exist, inform user and exit
- If phase number invalid, show available phases
- If no changes made, inform user (no-op)
- Validate all inputs before modifying
- Preserve existing structure and formatting
- Maintain all tasks and relationships

## Integration with Other Skills

### Works with:
- `/add-phase` - Add phases before editing them
- `/mark-status` - Update phase status
- `/add-task` - Add tasks to edited phases
- `/review-tracker` - View phase changes

### Common workflows:
1. **Refine phase naming**:
   ```
   /edit-phase my-app --phase=1 --name="Foundation & Architecture"
   ```

2. **Add phase descriptions later**:
   ```
   /edit-phase my-app --phase=2 --description="Core feature implementation"
   ```

3. **Restructure phase content**:
   ```
   /edit-phase my-app --phase=3 --name="Testing & QA" --description="Comprehensive testing before deployment"
   /mark-status my-app --phase=3 --status="In Progress"
   ```
