---
name: edit-track
description: This skill should be used when the user asks to "edit track", "update track details", "modify track", "rename track", "change track owner", "update track description", "change phase coverage", or wants to edit track metadata (excluding status changes, use mark-status for that).
---

# Edit Track Skill

Edit an existing track's details. This skill is for modifying track metadata, not status (use `/mark-status` for status-only changes).

## Purpose

Update track name, description, owner, or phase coverage while preserving tasks and structure.

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
     - `--track=name` - Track to edit
   - Optional flags:
     - `--description="text"` - New description
     - `--owner=name` - New owner/lead
     - `--name=new-name` - Rename the track
     - `--phase-coverage=range` - Update phase coverage (e.g., "1-3" or "2-4")
     - `--remove-description` - Remove existing description
     - `--remove-owner` - Remove owner assignment

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
   - Parse existing phases and tracks

### Step 2: Identify and Verify Track

1. **Parse track name from arguments**:
   - If `--track` flag provided, extract track name
   - If not provided:
     ```
     Available tracks:
     - authentication (Phase 1-3, In Progress)
     - dashboard (Phase 2-3, Not Started)
     - user-management (Phase 1-2, Complete)

     Which track would you like to edit?
     Enter track name:
     ```

2. **Verify track exists**:
   - Search for `### Track: {TRACK_NAME}` in Tracks section
   - If not found:
     * Inform user: "Track '{TRACK_NAME}' not found"
     * List available tracks
     * Exit

3. **Extract current track information**:
   - Parse the track section:
     * Current status
     * Current phase coverage
     * Current description
     * Current owner
     * Current progress

4. **Display current information**:
   ```
   Current track information:
   - Name: {TRACK_NAME}
   - Status: {CURRENT_STATUS}
   - Phase Coverage: {PHASE_RANGE}
   - Description: {DESCRIPTION or "None"}
   - Owner: {OWNER or "None"}
   - Progress: {COMPLETED}/{TOTAL} tasks ({PERCENTAGE}%)
   ```

### Step 3: Gather Update Information

Ask for updates (skip fields provided via arguments):

1. **If no update flags provided**:
   ```
   What would you like to edit?

   Options:
   1. Track name
   2. Description
   3. Owner
   4. Phase coverage
   5. Multiple fields
   6. Cancel

   Enter choice (or comma-separated numbers):
   ```

2. **For each selected field**:

   **Track Name** (if --name not provided):
   ```
   Current name: {TRACK_NAME}

   Enter new track name (or press Enter to keep current):
   WARNING: This will rename the track across all phases and tasks.

   Examples: "authentication", "user-profile", "dashboard"
   ```

   **Description** (if --description not provided):
   ```
   Current description: {CURRENT_DESCRIPTION or "None"}

   Enter new description (or press Enter to keep current):
   Leave blank to remove description.
   ```

   **Owner** (if --owner not provided):
   ```
   Current owner: {CURRENT_OWNER or "None"}

   Enter new owner (or press Enter to keep current):
   Leave blank to remove owner.

   Examples: "Backend Team", "Jane Doe", "Auth Squad"
   ```

   **Phase Coverage** (if --phase-coverage not provided):
   ```
   Current phase coverage: {CURRENT_RANGE}
   Total phases in tracker: {TOTAL_PHASES}

   Enter new phase coverage (or press Enter to keep current):
   Format: "start-end" (e.g., "1-3" or "2-4")
   Or single phase: "2"
   ```

### Step 4: Update Track in Tracks Section

1. **Find the track section**:
   - Locate: `### Track: {TRACK_NAME}`
   - Extract the entire track entry

2. **Build updated track entry**:

```markdown
### Track: {NEW_NAME or TRACK_NAME}
**Status**: {CURRENT_STATUS}
**Phase Coverage**: {NEW_COVERAGE or CURRENT_COVERAGE}
{IF_DESCRIPTION}**Description**: {NEW_DESCRIPTION}{END_IF}
{IF_OWNER}**Owner**: {NEW_OWNER}{END_IF}
**Progress**: {COMPLETED}/{TOTAL} tasks complete ({PERCENTAGE}%)
{IF_STARTED}**Started**: {START_DATE}{END_IF}
{IF_COMPLETED}**Completed**: {COMPLETE_DATE}{END_IF}

{IF_DESCRIPTION}
{NEW_DESCRIPTION}
{END_IF}
```

3. **Replace the track section**:
   - Use Edit tool to update the track entry
   - Maintain position in Tracks section
   - Preserve status and timestamps

### Step 5: Update Track Name in Phase Sections (if renamed)

If the track name was changed:

1. **For each phase in the tracker**:
   - Find: `#### Track: {OLD_TRACK_NAME}`
   - Replace with: `#### Track: {NEW_TRACK_NAME}`
   - Use Edit tool for each occurrence

2. **Update all task references**:
   - Tasks belong to tracks via their parent section
   - Structure is maintained automatically

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
Track updated successfully!

**Track**: {NEW_NAME or TRACK_NAME}

**Changes made**:
{IF_NAME_CHANGED}- Name: {OLD_NAME} → {NEW_NAME}{END_IF}
{IF_DESCRIPTION_CHANGED}- Description: {CHANGE_TYPE}{END_IF}
{IF_OWNER_CHANGED}- Owner: {CHANGE_DESCRIPTION}{END_IF}
{IF_COVERAGE_CHANGED}- Phase Coverage: {OLD_RANGE} → {NEW_RANGE}{END_IF}

**Current state**:
- Status: {CURRENT_STATUS}
- Phase Coverage: {COVERAGE}
- Progress: {COMPLETED}/{TOTAL} tasks ({PERCENTAGE}%)
{IF_DESCRIPTION}- Description: {DESCRIPTION}{END_IF}
{IF_OWNER}- Owner: {OWNER}{END_IF}

{IF_NAME_CHANGED}
**Note**: Track renamed across {PHASE_COUNT} phase section(s)
{END_IF}

**Next steps**:
- Update track status: /mark-status {TRACKER_NAME} --track={TRACK_NAME} --status=value
- Add tasks: /add-task {TRACKER_NAME} --track={TRACK_NAME}
- Review tracker: /review-tracker {TRACKER_NAME}

View tracker: .trackers/{TRACKER_NAME}/TRACKER.md
```

## Important Notes

- This skill edits track DETAILS, not status
- Use `/mark-status` for status-only changes
- Renaming updates all references across phases
- Status and timestamps are preserved
- Progress is calculated from tasks (read-only)
- Phase coverage defines which phases contain this track
- All edits maintain markdown structure

## Examples

### Example 1: Rename Track
```
/edit-track my-app --track=user-profile --name=user-management
> Track renamed across all phases
```

### Example 2: Update Description and Owner
```
/edit-track my-app --track=authentication --description="User authentication and authorization system" --owner="Security Team"
> Description and owner updated
```

### Example 3: Update Phase Coverage
```
/edit-track my-app --track=dashboard --phase-coverage="2-4"
> Track now spans phases 2-4
```

### Example 4: Interactive Edit
```
/edit-track my-app --track=payments
> What to edit? 2,3 (description, owner)
> Description: Payment processing and billing system
> Owner: Payments Team
```

### Example 5: Remove Owner
```
/edit-track my-app --track=api --remove-owner
> Owner removed from track "api"
```

## Error Handling

- If tracker doesn't exist, inform user and exit
- If track doesn't exist, list available tracks
- If renaming would create duplicate, abort and warn
- If phase coverage invalid, show valid range
- Validate all inputs before modifying
- Preserve existing structure and formatting

## Integration with Other Skills

### Works with:
- `/add-track` - Add tracks before editing them
- `/mark-status` - Update track status
- `/add-task` - Add tasks to edited tracks
- `/review-tracker` - View track changes

### Common workflows:
1. **Refine track details**:
   ```
   /edit-track my-app --track=authentication --description="OAuth2 and JWT-based authentication"
   ```

2. **Reassign ownership**:
   ```
   /edit-track my-app --track=api --owner="New Backend Team"
   ```

3. **Adjust phase coverage**:
   ```
   /edit-track my-app --track=testing --phase-coverage="3-4"
   /mark-status my-app --track=testing --status="In Progress"
   ```
