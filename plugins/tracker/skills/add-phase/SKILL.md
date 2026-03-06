---
name: add-phase
description: This skill should be used when the user asks to "add a phase", "create a phase", "add new phase", "insert a phase", "add stage to tracker", or wants to add a sequential stage to organize tracks and tasks.
---

# Add Phase Skill

Add a new phase to an existing tracker. Phases are sequential stages of work that organize tracks and tasks.

## Purpose

Add a new phase to the tracker's phase list and update the structure accordingly.

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
     - `--name="Phase Name"` - Phase name
     - `--position=N` - Where to insert (1=first, 2=second, etc.)
     - `--after=N` - Insert after phase N
     - `--before=N` - Insert before phase N

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

### Step 2: Gather Phase Information

1. **Get phase name** (if not from --name):
   ```
   What is the new phase called?
   Examples: "Foundation", "Implementation", "Testing", "Deployment"

   Enter phase name:
   ```

2. **Determine position** (if not from arguments):
   ```
   Current phases:
   1. Phase 1: {NAME}
   2. Phase 2: {NAME}
   3. Phase 3: {NAME}

   Where should this phase be added?
   1. At the beginning (becomes Phase 1)
   2. After Phase 1
   3. After Phase 2
   4. After Phase 3 (at the end)

   Enter position or press Enter to add at the end:
   ```

3. **Get phase description** (optional):
   ```
   Add a description for this phase? (y/n)
   Press Enter to skip:
   ```

### Step 3: Calculate Phase Number

1. **Determine insertion point**:
   - If position/after/before specified, calculate new phase number
   - If appending to end, new phase = total phases + 1
   - If inserting in middle, existing phases must be renumbered

2. **Handle renumbering** if inserting in middle:
   - All phases at or after insertion point get incremented
   - Example: Inserting at position 2
     * Old Phase 2 becomes Phase 3
     * Old Phase 3 becomes Phase 4
     * New phase becomes Phase 2

### Step 4: Add Phase to Phases Section

1. **Build phase entry**:

```markdown
### Phase {N}: {PHASE_NAME}
**Status**: Pending
**Started**: -
**Completed**: -
{IF_DESCRIPTION}

{DESCRIPTION}
{END_IF}
```

2. **Insert into Phases section**:
   - Find: `## Phases`
   - If appending, add at end of section
   - If inserting, find correct position and insert
   - Use Edit tool

3. **Renumber existing phases** if needed:
   - Update phase headers: `### Phase {OLD_N}:` → `### Phase {NEW_N}:`
   - Update phase references in Overview
   - Use Edit tool for each change

### Step 5: Update Tasks Section

1. **Add phase section to Tasks**:

```markdown
### Phase {N}: {PHASE_NAME}

_No tasks yet. Use /add-task to add tasks to this phase._

---
```

2. **Insert in correct position**:
   - Find: `## Tasks`
   - Insert new phase section at correct position
   - Renumber existing phase sections if inserting in middle

### Step 6: Update Track Phase Coverage

1. **For each existing track**:
   - Find: `### Track: {TRACK_NAME}`
   - Update **Phase Coverage** field:
     * If track spans all phases: `1-{NEW_TOTAL}`
     * If track spans specific range: Adjust if needed
   - Use Edit tool

### Step 7: Update Overview

1. **Update phase count**:
   - Find: `- **Total Phases**: {OLD_COUNT}`
   - Replace with: `- **Total Phases**: {NEW_COUNT}`

2. **Update metadata**:
   - Update `updated:` field in frontmatter to current date

### Step 8: Confirm Addition

```
Phase added successfully!

**Phase {N}**: {PHASE_NAME}
**Status**: Pending
{IF_DESCRIPTION}**Description**: {DESCRIPTION}{END_IF}

{IF_RENUMBERED}
**Note**: Existing phases were renumbered:
{FOR_EACH_CHANGE}
- Phase {OLD} → Phase {NEW}
{END_FOR_EACH}
{END_IF}

**Tracker updated**:
- Total phases: {OLD_COUNT} → {NEW_COUNT}
- Phase section added to Tasks
- Track phase coverage updated

**Next steps**:
- Add tasks to this phase: /add-task {TRACKER_NAME} --phase={N}
- Review tracker: /review-tracker {TRACKER_NAME}

View tracker: .trackers/{TRACKER_NAME}/TRACKER.md
```

## Important Notes

- Phases are sequential stages of work
- Adding a phase in the middle renumbers subsequent phases
- All track phase coverage ranges are updated automatically
- New phase is added to both Phases and Tasks sections
- Existing tasks remain in their original phases
- Phase numbers are 1-indexed
- Default position is at the end

## Examples

### Example 1: Add Phase at End
```
/add-phase my-app
> Phase name: "Deployment"
> Position: (press Enter for end)
> Creates Phase 4: Deployment
```

### Example 2: Add Phase at Beginning
```
/add-phase my-app --name="Discovery" --position=1
> Inserts as Phase 1
> Existing Phase 1 becomes Phase 2, etc.
```

### Example 3: Add Phase in Middle
```
/add-phase my-app --name="Integration Testing" --after=2
> Inserts after Phase 2 (becomes Phase 3)
> Old Phase 3 becomes Phase 4
```

### Example 4: With Description
```
/add-phase my-app --name="Beta Testing"
> Description: "User acceptance testing with beta users"
```

## Error Handling

- If tracker doesn't exist, inform user and exit
- If position is invalid, show valid range
- If phase name is empty, prompt again
- Validate all inputs before modifying
- Preserve existing structure and formatting
- Handle edge cases (inserting at position 1 or last)

## Integration with Other Skills

- After adding a phase, use `/add-task` to add tasks to it
- Use `/edit-phase` to modify phase details later
- Use `/mark-status` to update phase status
- Use `/review-tracker` to see the updated structure
