# Develop Project — Summary Report Template

Use this template when writing the final summary file at Step 8.

**File path**: `.trackers/{BASE_NAME}/plans/{BASE_NAME}-SUMMARY.md`

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

## Tracker

All progress is tracked in the tracker system:
- **Tracker**: `.trackers/{BASE_NAME}/TRACKER.md`
- **Plans**: `.trackers/{BASE_NAME}/plans/`
- Use `/tracker:review-tracker {BASE_NAME}` to view current status

## Phase Status

[Include tracker summary for each phase showing completion status]

## Feature Tracks

The following features were built:
[List tracks with completion status from tracker]

## Files Generated

### Tracker
- Tracker: `.trackers/{BASE_NAME}/TRACKER.md`

### Plans (All in .trackers/{BASE_NAME}/plans/)
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
2. The skill will read the tracker for completion status, skip completed phases automatically, and resume from incomplete phases.
3. To check progress at any time: `/tracker:review-tracker {BASE_NAME}`

## Next Steps

[If paused]
- Continue with Phase {next-number}: {name}
- Review tracker for current progress
- Verify implementation before proceeding

[If completed]
- All phases complete!
- Review code quality
- Proceed to integration testing
- Deploy to staging environment
```
