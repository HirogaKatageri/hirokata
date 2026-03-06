---
name: remove-track
description: This skill should be used when the user asks to "remove track", "delete track", "remove feature track", "delete track and tasks", or wants to permanently delete a track and all associated tasks across all phases.
---

# Remove Track Skill

Remove a track from an existing tracker. Removing a track will delete all tasks within that track across all phases.

## Purpose

Remove a track from the tracker, including all associated tasks across all phases, and update the structure accordingly.

## Hierarchy Reminder

The tracker follows this structure:
- **Phase** (sequential stages) → contains multiple Tracks
- **Track** (feature groupings) → spans across Phases, contains Tasks
- **Task** (individual work items) → belongs to a Phase and Track

**WARNING**: Removing a track will permanently delete all tasks within that track across all phases.

## Process Flow

### Step 1: Parse Arguments and Find Tracker

1. **Parse `$ARGUMENTS`** for:
   - Tracker name (first argument)
   - Optional flags:
     - `--track=name` - Track name to remove
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
   - Parse existing tracks and phases

### Step 2: Identify Track to Remove

1. **Get track name** (if not from --track):
   ```
   Current tracks:
   1. authentication - Status: {STATUS}, Coverage: Phase {START}-{END}
   2. dashboard - Status: {STATUS}, Coverage: Phase {START}-{END}
   3. api - Status: {STATUS}, Coverage: Phase {START}-{END}

   Which track would you like to remove?
   Enter track name:
   ```

2. **Validate track exists**:
   - Search for `### Track: {TRACK_NAME}` in Tracks section
   - If not found:
     * Inform user: "Track '{TRACK_NAME}' not found"
     * List available tracks
     * Exit

3. **Count tasks in track**:
   - Parse all phase sections
   - Count all tasks under `#### Track: {TRACK_NAME}` across all phases
   - Store task count for confirmation
   - List affected phases

### Step 3: Confirm Deletion

**Unless --confirm flag is provided**, display warning and ask for confirmation:

```
⚠️  WARNING: This will permanently delete Track: {TRACK_NAME}

This will remove:
- Track: {TRACK_NAME}
- {TASK_COUNT} task(s) across {PHASE_COUNT} phase(s)

Affected phases:
{FOR_EACH_AFFECTED_PHASE}
- Phase {N}: {PHASE_NAME} ({TASK_COUNT_IN_PHASE} task(s))
{END_FOR}

Plan files that will be deleted:
{FOR_EACH_PLAN_FILE}
- {PLAN_FILENAME}
{END_FOR}

This action cannot be undone.

Are you sure you want to remove this track? (yes/no)
```

- If user responds "no" or cancels, exit without changes
- If user responds "yes", proceed with deletion

### Step 4: Remove Track from Tracks Section

1. **Find track section**:
   - Locate: `### Track: {TRACK_NAME}`
   - Find the entire section until next `### Track` or next `##` section

2. **Delete track entry**:
   - Remove entire track section including:
     * Track header
     * Status, phase coverage, description
     * Progress information
     * All content until next track or section
   - Use Edit tool to remove the section

### Step 5: Remove Track from All Phase Sections

1. **For each phase** in the tracker:
   - Locate phase section: `### Phase {N}:`
   - Search for track subsection: `#### Track: {TRACK_NAME}`

2. **If track subsection exists in phase**:
   - Find entire track subsection including:
     * Track header (`#### Track: {TRACK_NAME}`)
     * All tasks within this track (`##### Task ...`)
     * All content until next track or end of phase
   - Delete the entire subsection
   - Use Edit tool to remove

3. **Handle empty phases**:
   - If a phase has no more tracks after deletion:
     * Replace content with: `_No tasks yet. Use /add-task to add tasks to this phase._`

### Step 6: Delete Associated Plan Files

1. **Find all task plan files** for deleted tasks:
   - Parse removed tasks to get task numbers
   - For each task with a plan file:
     ```bash
     rm .trackers/{TRACKER_NAME}/plans/{TASK_NUMBER}-*.md
     ```

2. **List deleted plan files** for user confirmation

### Step 7: Update Overview and Metadata

1. **Update track count**:
   - Find: `- **Total Tracks**: {OLD_COUNT}`
   - Replace with: `- **Total Tracks**: {NEW_COUNT}`

2. **Update task count**:
   - Find: `- **Total Tasks**: {OLD_COUNT}`
   - Calculate new count (old count - deleted tasks)
   - Replace with: `- **Total Tasks**: {NEW_COUNT}`

3. **Update completion statistics**:
   - Recalculate overall completion percentage
   - Update: `- **Completed**: {NEW_COMPLETED}/{NEW_TOTAL} tasks ({NEW_PERCENTAGE}%)`

4. **Update metadata**:
   - Update `updated:` field in frontmatter to current date
   - Get current date:
     ```bash
     date +%Y-%m-%d
     ```

### Step 8: Confirm Removal

```
Track removed successfully!

**Removed**: Track: {TRACK_NAME}
**Deleted**: {TASK_COUNT} task(s) across {PHASE_COUNT} phase(s)
**Plan files deleted**: {PLAN_COUNT}

**Tasks removed from phases**:
{FOR_EACH_AFFECTED_PHASE}
- Phase {N}: {PHASE_NAME} - {TASK_COUNT} task(s) removed
{END_FOR}

**Deleted plan files**:
{FOR_EACH_PLAN_FILE}
- {PLAN_FILENAME}
{END_FOR}

**Tracker updated**:
- Total tracks: {OLD_TRACK_COUNT} → {NEW_TRACK_COUNT}
- Total tasks: {OLD_TASK_COUNT} → {NEW_TASK_COUNT}
- Completion: {OLD_PERCENTAGE}% → {NEW_PERCENTAGE}%

**Next steps**:
- Review tracker: /review-tracker {TRACKER_NAME}
- Add new track if needed: /add-track {TRACKER_NAME}
- Check remaining tasks: /review-tracker {TRACKER_NAME} --detailed

View tracker: .trackers/{TRACKER_NAME}/TRACKER.md
```

## Important Notes

- **Destructive operation**: All tasks in the track are permanently deleted across all phases
- **No renumbering**: Unlike phase removal, track removal doesn't require renumbering
- **Plan files**: Associated plan files are deleted from the plans/ directory
- **Dependencies**: Task dependencies (Blocked By) are NOT automatically updated - tasks in other tracks that depend on deleted tasks will have invalid dependencies
- **Confirmation required**: User must confirm unless --confirm flag is used
- **No undo**: This operation cannot be reversed
- **Empty phases**: Phases may become empty if all their tasks were in the removed track

## Examples

### Example 1: Remove Complete Track
```
/remove-track my-app --track=authentication
> Warning: Will delete track 'authentication' with 8 tasks across 3 phases
> Confirm: yes
> Track removed
> 8 tasks deleted
> 3 plan files deleted
```

### Example 2: Interactive Selection
```
/remove-track my-app
> Available tracks: authentication, dashboard, api
> Select track: dashboard
> Warning: Will delete 5 tasks
> Confirm: yes
```

### Example 3: Skip Confirmation
```
/remove-track my-app --track=api --confirm
> Track 'api' removed immediately without confirmation
```

## Error Handling

- If tracker doesn't exist, inform user and exit
- If track doesn't exist, show available tracks
- If user cancels confirmation, exit without changes
- If track is the only track, warn and require explicit confirmation
- Validate all inputs before modifying
- Ensure tracker structure remains valid after removal
- Handle cases where plan file deletion fails

## Post-Removal Validation

After removing the track:
1. Verify all remaining tracks are intact
2. Ensure no orphaned track references remain
3. Validate task count matches actual tasks
4. Check that phases still have valid structure
5. **Warning**: Check for broken task dependencies manually

## Task Dependencies Warning

**Important**: If other tasks depend on tasks in the removed track:

```
⚠️  WARNING: Dependency check needed

The following tasks may have dependencies on removed tasks:
{FOR_EACH_TASK_WITH_DEPENDENCY}
- Task {TASK_NUMBER}: Blocked by Task {REMOVED_TASK_NUMBER} (deleted)
{END_FOR}

You may need to manually update these task dependencies using /edit-task.
```

## Integration with Other Skills

- Use `/review-tracker` to see updated structure
- Use `/add-track` if you need to add a different track
- Use `/edit-track` to modify remaining tracks
- Use `/edit-task` to fix broken task dependencies
- Check task dependencies manually after removal
