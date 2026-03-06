---
name: review-tracker
description: This skill should be used when the user asks to "review tracker", "show tracker progress", "generate tracker report", "show task status", "tracker summary", "check progress", "show tracker stats", or wants to analyze tracker progress, identify blockers, and view completion status.
---

# Review Tracker Skill

Review tracker progress and generate status reports. This skill analyzes the tracker, calculates statistics, identifies bottlenecks, and provides actionable insights.

## Purpose

Read the tracker, analyze progress, and present a comprehensive report with completion status, pending tasks, blockers, and recommendations.

## Process Flow

### Step 1: Parse Arguments and Find Tracker

1. **Parse `$ARGUMENTS`** for:
   - Tracker name (first argument)
   - Optional flags:
     - `--detailed` - Show detailed breakdown of all tasks
     - `--phase=N` - Filter by specific phase
     - `--track=name` - Filter by specific track
     - `--status=value` - Filter by status (Pending/In Progress/Complete/Blocked)
     - `--export` - Export report to file

2. **If tracker name not provided**:
   - List available trackers:
     ```bash
     ls -1 .trackers/
     ```
   - If no trackers exist:
     * Inform user: "No trackers found. Create one with /create-tracker"
     * Exit
   - If trackers exist:
     * Show list to user with basic stats
     * Ask: "Which tracker would you like to review?"
     * Wait for response

3. **Verify tracker exists**:
   - Check if `.trackers/{TRACKER_NAME}/TRACKER.md` exists
   - If not found:
     * Inform user: "Tracker '{TRACKER_NAME}' not found"
     * Exit

4. **Read the tracker file**:
   - Use Read tool on `.trackers/{TRACKER_NAME}/TRACKER.md`

### Step 2: Parse and Analyze Tracker

1. **Extract metadata**:
   - Tracker name
   - Created date
   - Last updated date
   - Overall status

2. **Parse phases**:
   - For each phase, extract:
     * Phase number and name
     * Phase status
     * Start and completion dates
     * List of tracks in this phase
     * List of tasks in this phase

3. **Parse tracks**:
   - For each track, extract:
     * Track name
     * Phase coverage
     * Track status
     * Task count and completion ratio

4. **Parse tasks**:
   - For each task, extract:
     * Task number
     * Title
     * Phase
     * Track
     * Status
     * Priority
     * Complexity
     * Blocked by (dependencies)
     * Started and completed dates
     * Plan file reference

5. **Calculate statistics**:

   a. **Overall stats**:
      - Total tasks
      - Tasks by status (Pending, In Progress, Complete, Blocked, On Hold, Cancelled)
      - Completion percentage
      - Average task complexity

   b. **Per-phase stats**:
      - Tasks per phase
      - Completion ratio per phase
      - Phase status

   c. **Per-track stats**:
      - Tasks per track
      - Completion ratio per track
      - Track status

   d. **Priority breakdown**:
      - High priority tasks (total, pending, complete)
      - Medium priority tasks
      - Low priority tasks

   e. **Blocked tasks**:
      - Count of blocked tasks
      - List of blockers
      - Identify circular dependencies

### Step 3: Identify Issues and Blockers

1. **Find blocking tasks**:
   - List all tasks with status "Blocked"
   - For each blocked task:
     * Identify what it's blocked by
     * Check if blocking tasks are complete
     * Calculate how many tasks are blocked by each blocker

2. **Find critical path**:
   - Identify high-priority tasks that are blocked
   - Find tasks blocking multiple other tasks
   - Calculate dependency chains

3. **Find stalled work**:
   - Tasks "In Progress" for extended periods (if timestamps available)
   - Phases with no recent progress

4. **Find risks**:
   - High number of pending high-priority tasks
   - Many blocked tasks
   - Phases with low completion rates

### Step 4: Generate Report

Based on flags, generate appropriate report:

#### Default Report (Summary View)

```markdown
# Tracker Review: {TRACKER_NAME}

**Generated**: {CURRENT_DATE}
**Last Updated**: {TRACKER_UPDATED_DATE}
**Status**: {TRACKER_STATUS}

## Overview

- **Total Tasks**: {TOTAL} ({COMPLETE} complete, {PENDING} pending)
- **Completion**: {PERCENTAGE}%
- **Phases**: {PHASE_COUNT} ({COMPLETE_PHASES} complete)
- **Tracks**: {TRACK_COUNT}

**Progress Bar**:
[████████░░░░░░░░░░░░] {PERCENTAGE}%

## Status Breakdown

| Status       | Count | Percentage |
|--------------|-------|------------|
| Complete     | {N}   | {%}        |
| In Progress  | {N}   | {%}        |
| Pending      | {N}   | {%}        |
| Blocked      | {N}   | {%}        |
| On Hold      | {N}   | {%}        |
| Cancelled    | {N}   | {%}        |

## Phase Progress

{FOR_EACH_PHASE}
### Phase {N}: {PHASE_NAME}
**Status**: {STATUS} | **Progress**: {COMPLETE}/{TOTAL} tasks ({PERCENTAGE}%)

{IF_PHASE_COMPLETE}✓ Complete{END_IF}
{IF_PHASE_IN_PROGRESS}⏳ In Progress - {PENDING} tasks remaining{END_IF}
{IF_PHASE_PENDING}⏸ Not started{END_IF}

{END_FOR_EACH}

## Track Progress

{FOR_EACH_TRACK}
### {TRACK_NAME}
**Progress**: {COMPLETE}/{TOTAL} tasks ({PERCENTAGE}%)
**Status**: {STATUS}
**Phases**: {PHASE_COVERAGE}

{END_FOR_EACH}

## Priority Breakdown

| Priority | Total | Complete | Pending | In Progress |
|----------|-------|----------|---------|-------------|
| High     | {N}   | {N}      | {N}     | {N}         |
| Medium   | {N}   | {N}      | {N}     | {N}         |
| Low      | {N}   | {N}      | {N}     | {N}         |

## Blockers

{IF_BLOCKED_TASKS}
**{COUNT} tasks are currently blocked**:

{FOR_EACH_BLOCKED}
- Task {NUMBER}: {TITLE}
  - Blocked by: Task {BLOCKER_NUMBERS}
  {IF_BLOCKER_COMPLETE}  - ⚠️ Blocker task {N} is complete - update this task!{END_IF}
{END_FOR_EACH}

{ELSE}
✓ No blocked tasks
{END_IF}

## Next Actions

**Ready to start** ({COUNT} tasks with no blockers):
{LIST_PENDING_TASKS_NO_BLOCKERS_TOP_5}

**In Progress** ({COUNT} tasks):
{LIST_IN_PROGRESS_TASKS}

**High Priority Pending** ({COUNT} tasks):
{LIST_HIGH_PRIORITY_PENDING_TASKS}

## Recommendations

{DYNAMIC_RECOMMENDATIONS}
```

#### Detailed Report (--detailed flag)

Include everything from summary, plus:

```markdown
## Detailed Task List

{FOR_EACH_PHASE}
### Phase {N}: {PHASE_NAME}

{FOR_EACH_TRACK_IN_PHASE}
#### Track: {TRACK_NAME}

{FOR_EACH_TASK}
##### Task {NUMBER}: {TITLE}
- **Status**: {STATUS}
- **Priority**: {PRIORITY}
- **Complexity**: {COMPLEXITY}
{IF_PLAN_FILE}- **Plan**: {PLAN_FILE}{END_IF}
{IF_STARTED}- **Started**: {DATE}{END_IF}
{IF_COMPLETED}- **Completed**: {DATE}{END_IF}
{IF_BLOCKED}- **Blocked By**: Task {NUMBERS}{END_IF}

{END_FOR_EACH_TASK}
{END_FOR_EACH_TRACK}
{END_FOR_EACH_PHASE}
```

#### Filtered Reports

**By Phase** (`--phase=N`):
- Show only tasks in specified phase
- Phase-specific statistics
- Track progress within that phase

**By Track** (`--track=name`):
- Show only tasks in specified track
- Track progress across all phases
- Track-specific timeline

**By Status** (`--status=value`):
- Show only tasks with specified status
- Useful for "what's blocked?", "what's pending?", etc.

### Step 5: Generate Dynamic Recommendations

Based on analysis, provide actionable recommendations:

1. **If many blocked tasks**:
   ```
   ⚠️ {COUNT} tasks are blocked. Focus on:
   - Task {N}: {TITLE} (blocks {COUNT} other tasks)
   - Task {M}: {TITLE} (blocks {COUNT} other tasks)
   ```

2. **If phase has low completion**:
   ```
   📊 Phase {N} is {PERCENTAGE}% complete. Consider:
   - Focusing resources on this phase
   - Breaking down complex tasks
   - Reviewing phase scope
   ```

3. **If high-priority tasks pending**:
   ```
   🔴 {COUNT} high-priority tasks are pending:
   - Prioritize Task {N}: {TITLE}
   - Prioritize Task {M}: {TITLE}
   ```

4. **If near completion**:
   ```
   🎉 Almost done! {PERCENTAGE}% complete.
   - {COUNT} tasks remaining
   - Focus on: {LIST_REMAINING}
   ```

5. **If stalled progress** (tasks in progress for long time):
   ```
   ⏱️ Some tasks may be stalled:
   - Task {N}: {TITLE} (in progress since {DATE})
   - Consider updating status or adding help
   ```

6. **If circular dependencies**:
   ```
   🔄 Circular dependency detected:
   - Task {N} blocked by Task {M}
   - Task {M} blocked by Task {N}
   - Resolve dependencies
   ```

7. **If no blockers**:
   ```
   ✓ Good progress! No blocking issues.
   - {COUNT} tasks ready to start
   - {COUNT} tasks in progress
   ```

### Step 6: Export Report (if --export flag)

If user requested export:

1. **Generate filename**:
   - Format: `{TRACKER_NAME}-review-{DATE}.md`
   - Example: `my-app-review-2026-01-27.md`

2. **Save report** to `.trackers/{TRACKER_NAME}/reviews/{FILENAME}`
   - Create `reviews/` directory if needed
   - Write full report to file

3. **Inform user**:
   ```
   Report exported to: .trackers/{TRACKER_NAME}/reviews/{FILENAME}
   ```

### Step 7: Present Report to User

Display the generated report to the user.

If not exported, display in terminal.

Add footer:

```
---

**Commands**:
- Update task: /update-tracker {TRACKER_NAME} --task={N}
- Add task: /add-task {TRACKER_NAME}
- Review again: /review-tracker {TRACKER_NAME}
- Export report: /review-tracker {TRACKER_NAME} --export

Tracker location: .trackers/{TRACKER_NAME}/TRACKER.md
```

## Report Types by Use Case

### Daily Standup Report
```
/review-tracker my-app --status="In Progress"
```
Shows what's actively being worked on.

### Sprint Review
```
/review-tracker my-app --detailed --export
```
Complete detailed report for sprint retrospective.

### Blocker Review
```
/review-tracker my-app --status=blocked
```
Shows all blocked tasks and what's blocking them.

### Phase Status Check
```
/review-tracker my-app --phase=2
```
Focus on specific phase progress.

### Track Progress
```
/review-tracker my-app --track=authentication
```
See progress on a specific feature.

## Important Notes

- Reports are generated from current tracker state
- Statistics are calculated in real-time
- Recommendations are dynamic based on current status
- Export creates timestamped report files
- Filters can be combined for detailed analysis
- Progress bars provide visual representation
- Blocker analysis identifies critical path
- No modifications are made to the tracker

## Examples

### Example 1: Quick Status Check
```
/review-tracker my-app
```
Shows summary overview with key stats.

### Example 2: Detailed Review
```
/review-tracker my-app --detailed
```
Shows complete task breakdown.

### Example 3: Check Blockers
```
/review-tracker my-app --status=blocked
```
Shows only blocked tasks and dependencies.

### Example 4: Phase Review
```
/review-tracker my-app --phase=2 --detailed
```
Detailed view of Phase 2 tasks.

### Example 5: Export for Meeting
```
/review-tracker my-app --detailed --export
```
Generates and saves complete report.

## Error Handling

- If tracker doesn't exist, list available trackers
- If invalid phase number, show available phases
- If invalid track name, show available tracks
- If invalid status value, show valid options
- If no tasks match filters, inform user
- Handle missing or malformed data gracefully
- Display partial results if some data is invalid
