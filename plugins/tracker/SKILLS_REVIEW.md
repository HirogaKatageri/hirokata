# CC Tracker Plugin - Skills Review

## Hierarchy Structure

All skills follow this organizational hierarchy:

```
Tracker (project container)
  └── Phase (sequential stages)
       └── Track (feature groupings spanning phases)
            └── Task (individual work items)
```

## Skills Overview

### 1. Tracker Management

#### `/create-tracker`
- **Purpose**: Create a new task tracker with initial phases and tracks
- **Creates**: `.trackers/{name}/` directory with TRACKER.md, README.md, and subdirectories
- **Key Features**:
  - Interactive phase and track setup
  - Automatic directory structure creation
  - Template generation with frontmatter

#### `/edit-tracker`
- **Purpose**: Edit tracker-level metadata (name, description)
- **Edits**: Display name and description only
- **Does NOT**: Change directory name, update statuses, or modify statistics
- **Key Features**:
  - Updates frontmatter metadata
  - Preserves all existing structure
  - Auto-updates `updated` timestamp

#### `/review-tracker`
- **Purpose**: Review tracker progress and generate reports
- **Features**: Progress summaries, task status reports, filtering by phase/track

---

### 2. Phase Management

#### `/add-phase`
- **Purpose**: Add a new phase to an existing tracker
- **Key Features**:
  - Position control (beginning, middle, or end)
  - Automatic renumbering of existing phases
  - Updates track phase coverage
  - Creates phase section in Tasks area

#### `/edit-phase`
- **Purpose**: Edit phase details (name, description)
- **Edits**: Phase name and description only
- **Does NOT**: Update phase status (use `/mark-status` instead)
- **Key Features**:
  - Renames across Phases and Tasks sections
  - Preserves all tasks and status
  - Optional description management

---

### 3. Track Management

#### `/add-track`
- **Purpose**: Add a new track to an existing tracker
- **Key Features**:
  - Phase coverage configuration
  - Owner/lead assignment
  - Initial status setting
  - Creates track subsections in covered phases

#### `/edit-track`
- **Purpose**: Edit track details (name, description, owner, phase coverage)
- **Edits**: Track metadata only, NOT status
- **Does NOT**: Update track status (use `/mark-status` instead)
- **Key Features**:
  - Rename across all phases
  - Update phase coverage
  - Modify owner and description
  - Preserves status and progress

---

### 4. Task Management

#### `/add-task`
- **Purpose**: Add a new task to a tracker
- **Key Features**:
  - Auto-incremented task numbers (01, 02, 03...)
  - Priority and complexity settings
  - Acceptance criteria
  - Dependency tracking (blocked by)
  - Optional plan file generation

#### `/edit-task`
- **Purpose**: Edit task details (title, priority, complexity, criteria, dependencies)
- **Edits**: Task metadata only, NOT status
- **Does NOT**: Update task status (use `/mark-status` instead)
- **Key Features**:
  - Update title, description, priority, complexity
  - Manage acceptance criteria (add, remove, replace)
  - Modify dependencies
  - Auto-updates plan file if exists

---

### 5. Status Management

#### `/mark-status`
- **Purpose**: Quick status updates for phases, tracks, or tasks
- **Simplified**: Status-only changes without editing other details
- **Key Features**:
  - Updates status for any entity type
  - Auto-adds timestamps (started, completed)
  - Updates plan files
  - Recalculates statistics
  - Faster than edit skills for status-only changes

**Supported Statuses**:

- **Tasks**: Pending, In Progress, Complete, Blocked, On Hold, Cancelled
- **Tracks**: Not Started, Planned, In Progress, On Hold, Complete, Cancelled
- **Phases**: Pending, In Progress, Complete

---

## Skill Organization by Use Case

### Creating a New Project
1. `/create-tracker` - Initialize tracker
2. `/edit-tracker` - Add description and refine name
3. `/add-phase` - Add additional phases if needed
4. `/add-track` - Create feature tracks
5. `/add-task` - Add tasks to tracks

### Managing Work in Progress
1. `/mark-status` - Update task/track/phase statuses
2. `/edit-task` - Refine task details as work progresses
3. `/review-tracker` - Monitor overall progress

### Refining Structure
1. `/edit-phase` - Rename or describe phases
2. `/edit-track` - Update track details, ownership
3. `/edit-task` - Adjust priorities, dependencies, criteria

### Reporting and Review
1. `/review-tracker` - Generate progress reports
2. `/review-tracker --track=name` - Filter by specific track
3. `/review-tracker --phase=N` - Filter by specific phase

---

## Key Design Decisions

### Separation of Concerns

**Edit Skills** vs **Mark Status**:
- **Edit skills** (`edit-task`, `edit-phase`, `edit-track`, `edit-tracker`): For modifying details, metadata, descriptions, names
- **Mark-status**: Dedicated skill for fast status-only updates
- **Rationale**: Status updates are frequent and should be simple; detail edits are less frequent and more complex

### Hierarchy Enforcement

All skills enforce the structure:
- **Tracker** contains **Phases**
- **Phases** contain **Tracks** (as subsections)
- **Tracks** contain **Tasks**
- Tasks belong to exactly one Phase and one Track

### Automatic Updates

All skills automatically:
- Update the `updated` timestamp in frontmatter
- Recalculate statistics when needed
- Update plan files when tasks change
- Add timestamps for status transitions
- Maintain markdown structure and formatting

### Immutability

Certain fields are immutable:
- Tracker `created` date (never changes)
- Task numbers (auto-incremented, never change)
- Phase numbers (sequential position, may renumber on insert)
- Tracker directory name (only display name changes)

---

## File Structure

```
.trackers/
└── {tracker-name}/
    ├── TRACKER.md          # Main tracker file (single source of truth)
    ├── README.md           # Documentation and usage guide
    ├── plans/              # Detailed task plan files
    │   └── {NN}-{task-name}.md
    └── archive/            # Completed or cancelled items
```

---

## Common Workflows

### 1. Starting a New Feature Track
```bash
/add-track my-app --track=authentication --owner="Backend Team"
/add-task my-app --track=authentication --phase=1 --priority=high
/mark-status my-app --track=authentication --status="In Progress"
```

### 2. Managing Task Progress
```bash
/mark-status my-app --task=03 --status="In Progress"
# ... work happens ...
/edit-task my-app --task=03 --add-criteria="Must support OAuth2"
/mark-status my-app --task=03 --status=complete
```

### 3. Completing a Phase
```bash
/mark-status my-app --task=01 --status=complete
/mark-status my-app --task=02 --status=complete
# ... complete all phase tasks ...
/mark-status my-app --phase=1 --status=complete
```

### 4. Refactoring Tracker Structure
```bash
/edit-tracker my-app --description="Updated project scope"
/add-phase my-app --name="Integration Testing" --after=2
/edit-track my-app --track=api --phase-coverage="2-4"
```

---

## Validation and Error Handling

All skills include:
- **Existence checks**: Verify tracker, phase, track, or task exists
- **Duplicate detection**: Prevent duplicate names
- **Range validation**: Ensure phase numbers are valid
- **Status validation**: Only accept valid status values
- **Dependency validation**: Check that blocked-by tasks exist
- **Structure preservation**: Maintain markdown formatting
- **Graceful failures**: Inform user and suggest corrections

---

## Statistics Auto-Calculation

Statistics are automatically recalculated after:
- Task status changes
- Task additions
- Phase status changes
- Track updates

**Calculated Metrics**:
- Total tasks by status
- Completion percentage
- Track progress (completed/total per track)
- Phase progress (task completion within phase)
- Overall tracker status

---

## Future Enhancements

Potential additions mentioned in skills:
- Bulk status updates
- Track dependencies
- Velocity metrics
- Estimated completion dates
- Team size/effort allocation
- Archive functionality
- Export/import features
