# Develop Project — Summary Report Template

Use this template when writing the final summary file at Step 6.

**File path**: `tasks/{BASE_NAME}/plans/{BASE_NAME}-SUMMARY.md`

---

## Template

```markdown
# Build Summary - {BASE_NAME}

**Requirements File**: {RESOLVED_FILE_PATH}
**Date**: {timestamp}
**Status**: {Completed|Paused}

## Overview

- **Total Phases**: 8
- **Phases Completed**: {count}
- **Phases Remaining**: {count}
- **Total Tasks**: {count}
- **Tasks Complete**: {count}
- **Tasks Remaining**: {count}
- **Total Feature Tracks**: {count}

## Phase Architecture

This project follows clean architecture with 8 sequential phases:
1. Foundational → 2. Models → 3. Services → 4. Data → 5. Rules → 6. State Management → 7. UI → 8. Tests

## Phase Status

[Include a per-phase status row for each phase, based on TASKS.md]

| Phase | Name | Status | Tasks Complete |
|---|---|---|---|
| 1 | Foundational | {complete|in_progress|pending} | {X}/{total} |
| 2 | Models | {complete|in_progress|pending} | {X}/{total} |
| 3 | Services | {complete|in_progress|pending} | {X}/{total} |
| 4 | Data | {complete|in_progress|pending} | {X}/{total} |
| 5 | Rules | {complete|in_progress|pending} | {X}/{total} |
| 6 | State Management | {complete|in_progress|pending} | {X}/{total} |
| 7 | UI | {complete|in_progress|pending} | {X}/{total} |
| 8 | Tests | {complete|in_progress|pending} | {X}/{total} |

## Feature Tracks

The following features were built:
[List tracks with completion status derived from TASKS.md]

## Files Generated

### Task List
- Tasks: `tasks/{BASE_NAME}/TASKS.md`

### Plans (All in `tasks/{BASE_NAME}/plans/`)
- Master Plan: {BASE_NAME}-master-plan.md
- Phase 1 Plan: {BASE_NAME}-01-foundational.md
- Phase 2 Plan: {BASE_NAME}-02-models.md
- Phase 3 Plan: {BASE_NAME}-03-services.md
- Phase 4 Plan: {BASE_NAME}-04-data.md
- Phase 5 Plan: {BASE_NAME}-05-rules.md
- Phase 6 Plan: {BASE_NAME}-06-state-management.md
- Phase 7 Plan: {BASE_NAME}-07-ui.md
- Phase 8 Plan: {BASE_NAME}-08-tests.md
- Summary: {BASE_NAME}-SUMMARY.md (this file)

## How to Resume

To resume this build workflow:

1. Run the develop-project skill again with the same requirements file.
2. The skill reads `tasks/{BASE_NAME}/TASKS.md` for completion status, skips phases where all tasks are `[x]`, and resumes from incomplete phases.

## Next Steps

[If paused]
- Continue with Phase {next-number}: {name}
- Review `tasks/{BASE_NAME}/TASKS.md` for current progress
- Verify implementation before proceeding

[If completed]
- All phases complete!
- Review code quality
- Proceed to integration testing
- Deploy to staging environment
```
