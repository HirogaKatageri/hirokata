---
name: add-track
description: This skill should be used when the user asks to "add a track", "create a track", "add feature track", "add new track to tracker", or wants to add a feature-based grouping that spans across multiple phases.
---

# Add Track Skill

Add a new track to an existing tracker. A track is a feature-based grouping that spans across multiple phases and contains related tasks.

## Purpose

Add a new track to an existing tracker, updating the Tracks section and preparing the structure for future tasks.

## Process Flow

### Step 1: Parse Arguments and Find Tracker

1. **Parse `$ARGUMENTS`** for:
   - Tracker name (first argument)
   - Optional flags:
     - `--track=name` - Track name
     - `--description="text"` - Track description
     - `--owner=name` - Track owner/lead
     - `--status=value` - Initial status

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
     * Ask: "Which tracker would you like to add a track to?"
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
     * Existing phases (with names and numbers)
     * Existing tracks
     * Current track count

### Step 2: Gather Track Information

Ask the user for track details (skip if provided via arguments):

1. **Track Name** (if not provided via --track):
   ```
   What is the track name?

   Tracks are feature-based groupings that span across phases.
   Examples: "authentication", "user-profile", "dashboard", "api"

   Enter track name:
   ```

   - Sanitize the track name:
     * Convert to lowercase
     * Replace spaces with hyphens
     * Remove special characters (keep only alphanumeric and hyphens)
     * Example: "User Profile" → "user-profile"

2. **Check if track already exists**:
   - Search for `### Track: {TRACK_NAME}` in the Tracks section
   - If found:
     * Inform user: "Track '{TRACK_NAME}' already exists in this tracker"
     * Ask: "Would you like to:
       1. Use a different name
       2. Update the existing track (switches to /update-track)
       3. Cancel"
     * Wait for user response
     * If "different name": Go back to Step 2.1
     * If "update existing": Exit and suggest `/update-track {TRACKER_NAME} --track={TRACK_NAME}`
     * If "cancel": Exit

3. **Description** (if not provided via --description):
   ```
   Provide a brief description of this track (optional):
   Press Enter to skip:
   ```

4. **Owner/Lead** (if not provided via --owner):
   ```
   Who owns or leads this track? (optional)
   Examples: "Backend Team", "Alice", "Mobile Squad"
   Press Enter to skip:
   ```

5. **Initial Status** (if not provided via --status):
   ```
   What is the initial status? (Not Started/Planned/In Progress)
   Press Enter for "Not Started":
   ```

   - Default to "Not Started" if empty

6. **Phase Coverage**:
   ```
   Which phases will this track span?

   Available phases:
   1. Phase 1: {NAME}
   2. Phase 2: {NAME}
   ...

   Enter phase range (e.g., "1-3" for phases 1 through 3, or "all"):
   Press Enter for all phases:
   ```

   - Parse the input:
     * "all" or empty → covers all phases (1 to max)
     * "N-M" → covers phases N through M
     * "N" → covers only phase N
   - Validate phase numbers exist

### Step 3: Add Track to Tracker

1. **Find the Tracks section** in the tracker file:
   - Locate: `## Tracks`
   - Find the insertion point (before `## Tasks` section or at end of Tracks section)

2. **Build track entry**:

```markdown
### Track: {TRACK_NAME}
**Status**: {STATUS}
**Phase Coverage**: {START_PHASE}-{END_PHASE}
{IF_DESCRIPTION}**Description**: {DESCRIPTION}{END_IF}
{IF_OWNER}**Owner**: {OWNER}{END_IF}
**Progress**: 0/0 tasks complete (0%)

{IF_DESCRIPTION}
{DESCRIPTION}
{END_IF}

---
```

3. **Insert track into tracker**:
   - Find the `## Tracks` section
   - If it shows "_No tracks defined yet..._", replace that text
   - Otherwise, append the new track entry before `## Tasks` section
   - Use Edit tool to insert at the correct location

4. **Update Overview section**:
   - Increment "Total Tracks" count
   - Use Edit tool to update the count

5. **Update metadata**:
   - Update `updated:` field in frontmatter to current date
   - Get current date:
     ```bash
     date +%Y-%m-%d
     ```

### Step 4: Add Track Subsections to Each Phase

For each phase that the track covers:

1. **Find the phase section**: `### Phase {N}: {PHASE_NAME}`

2. **Check if track subsection exists**:
   - Search for `#### Track: {TRACK_NAME}` within this phase
   - If not found, add it:

```markdown
#### Track: {TRACK_NAME}

_No tasks yet. Use /add-task to add tasks to this track._

---
```

3. **Insert the track subsection**:
   - Add it after the phase header but before the next phase
   - Maintain alphabetical or existing track order
   - Use Edit tool for insertion

### Step 5: Confirm Addition

Inform the user:

```
Track added successfully!

**Track Name**: {TRACK_NAME}
**Status**: {STATUS}
**Phase Coverage**: Phase {START} - Phase {END}
{IF_DESCRIPTION}**Description**: {DESCRIPTION}{END_IF}
{IF_OWNER}**Owner**: {OWNER}{END_IF}

**Tracker updated**:
- Total tracks: {NEW_TOTAL}
- Track sections added to {PHASE_COUNT} phase(s)

**Next steps**:
- Add tasks to this track: /add-task {TRACKER_NAME} --track={TRACK_NAME}
- Update track status: /update-track {TRACKER_NAME} --track={TRACK_NAME}
- Review tracker: /review-tracker {TRACKER_NAME}

View tracker: .trackers/{TRACKER_NAME}/TRACKER.md
```

## Important Notes

- Track names are sanitized to be filesystem-safe
- Tracks span across one or more phases
- Each track gets a section in the Tracks overview
- Each covered phase gets a track subsection for organizing tasks
- Track status is independent of phase status
- Progress is calculated from tasks within the track
- All edits maintain the tracker's markdown structure
- The tracker file is the single source of truth

## Examples

### Example 1: Simple Track
```
/add-track my-app
> Track name: authentication
> Description: User authentication and authorization
> Owner: Backend Team
> Status: Not Started
> Phase coverage: all
```

### Example 2: Track with Arguments
```
/add-track my-app --track=dashboard --owner="Frontend Team" --status="Planned"
> Description: Admin dashboard with analytics
> Phase coverage: 2-3
```

### Example 3: Limited Phase Coverage
```
/add-track e-commerce --track=payments
> Description: Payment processing and checkout flow
> Owner: Payments Squad
> Status: Not Started
> Phase coverage: 2-4
```

## Status Values

- **Not Started**: Track hasn't begun
- **Planned**: Track is planned but not active
- **In Progress**: Actively working on track tasks
- **On Hold**: Track is paused
- **Complete**: All track tasks finished
- **Cancelled**: Track won't be pursued

## Error Handling

- If tracker doesn't exist, list available trackers and exit
- If track already exists, offer to update instead or choose new name
- If invalid phase range, show available phases
- Validate all inputs before modifying tracker
- Preserve existing tracker structure and formatting
- If track insertion fails, report error and exit

## Integration with Other Skills

### After adding a track:
1. Use `/add-task {TRACKER_NAME} --track={TRACK_NAME}` to add tasks
2. Use `/update-track {TRACKER_NAME} --track={TRACK_NAME}` to modify track info
3. Use `/review-tracker {TRACKER_NAME} --track={TRACK_NAME}` to see track progress

### Before adding a track:
- Ensure tracker exists (create with `/create-tracker` if needed)
- Understand project phases (review with `/review-tracker`)
