---
name: remove-phase
description: This skill should be used when the user asks to "remove phase", "delete phase", "remove a phase from tracker", "delete stage", or wants to permanently delete a phase and all associated tracks and tasks, with automatic renumbering of subsequent phases.
---

# Remove Phase Skill

Remove a phase from an existing tracker. Removing a phase will delete all tracks and tasks within that phase, and renumber subsequent phases.

## Purpose

Remove a phase from the tracker, including all associated tracks and tasks, and update the structure accordingly.

## Hierarchy Reminder

The tracker follows this structure:
- **Phase** (sequential stages) → contains multiple Tracks
- **Track** (feature groupings) → spans across Phases, contains Tasks
- **Task** (individual work items) → belongs to a Phase and Track

**WARNING**: Removing a phase will permanently delete all tasks within that phase across all tracks.

## Process Flow

### Step 1: Parse Arguments and Find Tracker

1. **Parse `$ARGUMENTS`** for:
   - Tracker name (first argument)
   - Optional flags:
     - `--phase=N` - Phase number to remove
     - `--confirm` - Skip confirmation prompt

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

### Step 2: Identify Phase to Remove

1. **Get phase number** (if not from --phase):
   ```
   Current phases:
   1. Phase 1: {NAME} - {STATUS}
   2. Phase 2: {NAME} - {STATUS}
   3. Phase 3: {NAME} - {STATUS}

   Which phase would you like to remove?
   Enter phase number:
   ```

2. **Validate phase number**:
   - Ensure phase exists
   - If invalid, show available phases and ask again

3. **Count tasks in phase**:
   - Parse the Tasks section
   - Count all tasks under `### Phase {N}:`
   - Store task count for confirmation

### Step 3: Confirm Deletion

**Unless --confirm flag is provided**, display warning and ask for confirmation:

```
⚠️  WARNING: This will permanently delete Phase {N}: {PHASE_NAME}

This will remove:
- Phase {N}: {PHASE_NAME}
- All tracks within this phase
- {TASK_COUNT} task(s) in this phase

Remaining phases will be renumbered:
{FOR_EACH_SUBSEQUENT_PHASE}
- Phase {OLD_N} → Phase {NEW_N}
{END_FOR}

This action cannot be undone.

Are you sure you want to remove this phase? (yes/no)
```

- If user responds "no" or cancels, exit without changes
- If user responds "yes", proceed with deletion

### Step 4: Remove Phase from Phases Section

1. **Find phase section**:
   - Locate: `### Phase {N}: {PHASE_NAME}`
   - Find the entire section until next `### Phase` or end of Phases section

2. **Delete phase entry**:
   - Remove entire phase section including:
     * Phase header
     * Status, dates, description
     * All content until next phase
   - Use Edit tool to remove the section

3. **Renumber subsequent phases**:
   - For each phase after the removed one:
     * Update header: `### Phase {OLD_N}:` → `### Phase {NEW_N}:`
     * Update all references to phase numbers in the content
   - Use Edit tool for each change

### Step 5: Remove Phase from Tasks Section

1. **Find phase section in Tasks**:
   - Locate: `### Phase {N}: {PHASE_NAME}`
   - Find the entire section until next `### Phase` or end of Tasks section

2. **Delete phase section**:
   - Remove entire phase section including:
     * Phase header
     * All track subsections (#### Track: ...)
     * All tasks (##### Task ...)
     * All content until next phase
   - Use Edit tool to remove

3. **Renumber subsequent phase sections**:
   - For each phase section after the removed one:
     * Update header: `### Phase {OLD_N}:` → `### Phase {NEW_N}:`
   - Use Edit tool for each change

### Step 6: Update Track Phase Coverage

1. **For each existing track** in Tracks section:
   - Find: `### Track: {TRACK_NAME}`
   - Check **Phase Coverage** field
   - Update coverage if affected:
     * If track only covered the removed phase: Remove track entirely
     * If track starts at removed phase: Adjust start to next phase
     * If track ends at removed phase: Adjust end to previous phase
     * If track spans through removed phase: Adjust range
     * If track is after removed phase: Decrement phase numbers
   - Use Edit tool for updates

2. **Remove orphaned tracks**:
   - If any track's phase coverage is now invalid (no phases), remove it entirely

### Step 7: Delete Associated Plan Files

1. **Find all task plan files** for deleted tasks:
   - Parse removed tasks to get task numbers
   - For each task with a plan file:
     ```bash
     rm .trackers/{TRACKER_NAME}/plans/{TASK_NUMBER}-*.md
     ```

2. **Inform user** of deleted plan files

### Step 8: Update Overview and Metadata

1. **Update phase count**:
   - Find: `- **Total Phases**: {OLD_COUNT}`
   - Replace with: `- **Total Phases**: {NEW_COUNT}`

2. **Update task count**:
   - Find: `- **Total Tasks**: {OLD_COUNT}`
   - Calculate new count (old count - deleted tasks)
   - Replace with: `- **Total Tasks**: {NEW_COUNT}`

3. **Update track count** (if any tracks were removed):
   - Find: `- **Total Tracks**: {OLD_COUNT}`
   - Replace with: `- **Total Tracks**: {NEW_COUNT}`

4. **Update metadata**:
   - Update `updated:` field in frontmatter to current date
   - Get current date:
     ```bash
     date +%Y-%m-%d
     ```

### Step 9: Confirm Removal

```
Phase removed successfully!

**Removed**: Phase {N}: {PHASE_NAME}
**Deleted**: {TASK_COUNT} task(s)
**Plan files deleted**: {PLAN_COUNT}

{IF_RENUMBERED}
**Phases renumbered**:
{FOR_EACH_CHANGE}
- Phase {OLD} → Phase {NEW}
{END_FOR}
{END_IF}

{IF_TRACKS_REMOVED}
**Tracks removed** (no longer cover any phases):
{FOR_EACH_REMOVED_TRACK}
- {TRACK_NAME}
{END_FOR}
{END_IF}

{IF_TRACKS_UPDATED}
**Track coverage updated**:
{FOR_EACH_UPDATED_TRACK}
- {TRACK_NAME}: {OLD_COVERAGE} → {NEW_COVERAGE}
{END_FOR}
{END_IF}

**Tracker updated**:
- Total phases: {OLD_PHASE_COUNT} → {NEW_PHASE_COUNT}
- Total tasks: {OLD_TASK_COUNT} → {NEW_TASK_COUNT}
{IF_TRACK_COUNT_CHANGED}- Total tracks: {OLD_TRACK_COUNT} → {NEW_TRACK_COUNT}{END_IF}

**Next steps**:
- Review tracker: /review-tracker {TRACKER_NAME}
- Add new phase if needed: /add-phase {TRACKER_NAME}

View tracker: .trackers/{TRACKER_NAME}/TRACKER.md
```

## Important Notes

- **Destructive operation**: All tasks in the phase are permanently deleted
- **Cascading updates**: Subsequent phases are automatically renumbered
- **Track cleanup**: Tracks that no longer span any phases are removed
- **Plan files**: Associated plan files are deleted from the plans/ directory
- **Dependencies**: Task dependencies (Blocked By) are NOT automatically updated
- **Confirmation required**: User must confirm unless --confirm flag is used
- **No undo**: This operation cannot be reversed

## Examples

### Example 1: Remove Middle Phase
```
/remove-phase my-app --phase=2
> Warning: Will delete Phase 2: Implementation with 5 tasks
> Confirm: yes
> Phase 2 removed
> Phase 3 becomes Phase 2
> Phase 4 becomes Phase 3
```

### Example 2: Remove Last Phase
```
/remove-phase my-app
> Select phase: 4
> Warning: Will delete Phase 4: Deployment with 3 tasks
> Confirm: yes
> Phase 4 removed (no renumbering needed)
```

### Example 3: Skip Confirmation
```
/remove-phase my-app --phase=1 --confirm
> Phase 1 removed immediately without confirmation
```

## Error Handling

- If tracker doesn't exist, inform user and exit
- If phase number is invalid, show valid phases
- If user cancels confirmation, exit without changes
- If phase is the only phase, warn and require explicit confirmation
- Validate all inputs before modifying
- Handle edge cases (removing first or last phase)
- Ensure tracker structure remains valid after removal

## Post-Removal Validation

After removing the phase:
1. Verify all phase numbers are sequential (1, 2, 3...)
2. Ensure no orphaned task references remain
3. Validate all track phase coverage is correct
4. Confirm overview counts match actual content

## Integration with Other Skills

- Use `/review-tracker` to see updated structure
- Use `/add-phase` if you need to add a different phase
- Use `/edit-phase` to modify remaining phases
- Check task dependencies manually if needed
