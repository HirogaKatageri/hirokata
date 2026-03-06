---
name: create-tracker
description: This skill should be used when the user asks to "create a tracker", "create a new tracker", "set up a tracker", "initialize tracker", "start tracking tasks", "make a task tracker", or wants to organize project work into phases and tracks.
---

# Create Tracker Skill

Create a new task tracker to organize project work. A tracker is a structured document that organizes tasks into phases (sequential stages) and tracks (feature-based groupings).

## Purpose

Create a new tracker with an initial structure of phases and tracks, saving it to the `.trackers/` directory.

## Process Flow

### Step 1: Parse Arguments and Get Tracker Name

1. **Check if tracker name was provided** via `$ARGUMENTS`:
   - If provided, extract the tracker name
   - If not provided, ask the user: "What would you like to name this tracker?"
   - Wait for user response

2. **Sanitize the tracker name**:
   - Convert to lowercase
   - Replace spaces with hyphens
   - Remove special characters (keep only alphanumeric and hyphens)
   - Example: "My Project" → "my-project"

3. **Store as `TRACKER_NAME`**

### Step 2: Check if Tracker Already Exists

1. **Check for existing tracker**:
   ```bash
   ls -la .trackers/
   ```

2. **If `.trackers/{TRACKER_NAME}/` already exists**:
   - Inform user: "A tracker named '{TRACKER_NAME}' already exists at .trackers/{TRACKER_NAME}/"
   - Ask: "Would you like to:
     1. Use a different name
     2. Overwrite the existing tracker
     3. Cancel"
   - Wait for user response
   - If "different name": Go back to Step 1
   - If "overwrite": Continue to Step 3
   - If "cancel": Exit

3. **If tracker doesn't exist**: Continue to Step 3

### Step 3: Gather Tracker Information

Ask the user for initial tracker setup:

1. **Ask about phases**:
   ```
   How many phases does this project have?

   Examples:
   - 3 phases: Planning, Implementation, Testing
   - 4 phases: Design, Development, QA, Deployment
   - Custom number of phases

   Enter number of phases (or press Enter for default 3):
   ```

2. **Get phase names**:
   - If user specified N phases, ask for each phase name:
     ```
     What is Phase 1 called? (e.g., "Foundation", "Planning")
     What is Phase 2 called? (e.g., "Implementation", "Development")
     ...
     ```
   - If user accepts default (3), use: "Planning", "Implementation", "Testing"

3. **Ask about tracks**:
   ```
   What feature tracks will this project have?

   Tracks are feature-based groupings that span across phases.
   Examples: "authentication", "user-profile", "dashboard", "api"

   Enter track names (comma-separated, or press Enter to add later):
   ```

4. **Parse tracks**:
   - Split by comma
   - Trim whitespace
   - Sanitize each track name (lowercase, hyphens)
   - If empty, set tracks to empty array (can add later)

### Step 4: Create Tracker Directory Structure

1. **Create directories**:
   ```bash
   mkdir -p .trackers/{TRACKER_NAME}/plans
   mkdir -p .trackers/{TRACKER_NAME}/archive
   ```

2. **Verify creation**:
   - Check that directories were created successfully
   - If error, inform user and exit

### Step 5: Generate Tracker File

1. **Get current date**:
   ```bash
   date +%Y-%m-%d
   ```

2. **Build tracker content** using this template:

```markdown
---
name: "{USER_PROVIDED_NAME}"
created: {CURRENT_DATE}
updated: {CURRENT_DATE}
status: "Not Started"
---

# Tracker: {USER_PROVIDED_NAME}

## Overview
- **Total Phases**: {PHASE_COUNT}
- **Total Tracks**: {TRACK_COUNT}
- **Total Tasks**: 0
- **Completed**: 0/0 (0%)

## Phases

{FOR_EACH_PHASE}
### Phase {N}: {PHASE_NAME}
**Status**: Pending
**Started**: -
**Completed**: -

{END_FOR_EACH}

## Tracks

{IF_TRACKS_DEFINED}
{FOR_EACH_TRACK}
### Track: {TRACK_NAME}
**Phase Coverage**: 1-{PHASE_COUNT}
**Status**: Not Started (0/0 tasks complete)

{END_FOR_EACH}
{ELSE}
_No tracks defined yet. Use /add-task to create tasks with tracks._
{END_IF}

## Tasks

{FOR_EACH_PHASE}
### Phase {N}: {PHASE_NAME}

_No tasks yet. Use /add-task to add tasks to this phase._

---

{END_FOR_EACH}

## Status Legend
- **Pending**: Not started
- **In Progress**: Currently being worked on
- **Complete**: Finished
- **Blocked**: Waiting on dependencies
- **On Hold**: Paused temporarily
- **Cancelled**: Won't be completed
```

3. **Save tracker file**:
   - Write to: `.trackers/{TRACKER_NAME}/TRACKER.md`
   - Use the Write tool

### Step 6: Create README

Create a README file at `.trackers/{TRACKER_NAME}/README.md`:

```markdown
# {USER_PROVIDED_NAME} - Tracker

Created: {CURRENT_DATE}

## Directory Structure

- `TRACKER.md` - Main tracker file with all tasks and progress
- `plans/` - Detailed plan files for individual tasks
- `archive/` - Completed or cancelled tasks

## Usage

### View Progress
```
/review-tracker {TRACKER_NAME}
```

### Add a Task
```
/add-task {TRACKER_NAME}
```

### Update Task Status
```
/update-tracker {TRACKER_NAME} --task=01 --status=Complete
```

## Phases

{LIST_PHASES}

## Tracks

{LIST_TRACKS_OR_NONE}
```

### Step 7: Confirm Creation

Inform the user:

```
Tracker created successfully!

**Name**: {USER_PROVIDED_NAME}
**Location**: .trackers/{TRACKER_NAME}/
**Phases**: {PHASE_COUNT}
**Tracks**: {TRACK_COUNT}

**Files created**:
- .trackers/{TRACKER_NAME}/TRACKER.md (main tracker)
- .trackers/{TRACKER_NAME}/README.md (documentation)
- .trackers/{TRACKER_NAME}/plans/ (directory for task plans)

**Next steps**:
1. Add tasks: /add-task {TRACKER_NAME}
2. Review progress: /review-tracker {TRACKER_NAME}
3. Update tasks: /update-tracker {TRACKER_NAME}

View your tracker at: .trackers/{TRACKER_NAME}/TRACKER.md
```

## Important Notes

- Tracker names are sanitized to be filesystem-safe
- All trackers are stored in `.trackers/` directory
- Each tracker has its own subdirectory with TRACKER.md file
- Phases are sequential stages of work
- Tracks are feature-based groupings that span phases
- Tasks are added later using /add-task skill
- The TRACKER.md file is the single source of truth

## Examples

### Example 1: Simple Project
```
/create-tracker my-app
> Phases: 3 (Planning, Implementation, Testing)
> Tracks: authentication, dashboard
```

### Example 2: Complex Project
```
/create-tracker e-commerce-platform
> Phases: 5 (Design, Backend, Frontend, Integration, Deployment)
> Tracks: user-management, products, cart, payments, admin
```

## Error Handling

- If tracker already exists, ask user for action
- If directory creation fails, report error and exit
- If file write fails, report error and exit
- Validate all user inputs before proceeding
