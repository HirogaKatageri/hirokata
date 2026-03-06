# Tracker Plugin

A comprehensive project and task management system with an intelligent agent, skills, and structured tracking using phases, tracks, and tasks.

## What's Included

### Tracker Agent 🤖
An intelligent assistant that orchestrates all tracker skills to provide conversational project management. Use it for:
- Intelligent project setup and planning
- Multi-step workflow automation
- Progress analysis and insights
- Proactive recommendations

**Agent:** `tracker:tracker`

**Usage**: Simply ask for help with your project management needs:
```
"Help me set up tracking for my new web app"
"What should I work on today?"
"Review my project progress and suggest next steps"
```

See [agents/tracker.md](agents/tracker.md) for detailed agent documentation.

### Tracker Skills 🛠️
Individual skills for specific tracker operations. Use these when you need direct control:
- `/tracker:create-tracker` - Create new trackers
- `/tracker:add-task` - Add tasks to trackers
- `/tracker:review-tracker` - Generate progress reports
- And more...

## Overview

The Tracker system helps you organize project work into structured trackers with:
- **Phases**: Sequential stages of work (e.g., Planning, Implementation, Testing)
- **Tracks**: Feature-based groupings that span across phases (e.g., authentication, dashboard)
- **Tasks**: Individual work items with status, priority, complexity, and dependencies

All trackers are stored in `.trackers/` directory with a consistent markdown format.

## Quick Start

### Using the Tracker Agent (Recommended for Beginners)

The agent provides intelligent, conversational project management:

```
You: I'm starting a new e-commerce project and need help organizing tasks

Agent: I'll help you set up tracking for your e-commerce project.
       Let me ask a few questions to structure this properly:
       1. What are the main features? (products, cart, checkout, etc.)
       2. What development methodology are you using?
       3. Are you working solo or with a team?
       [Creates tracker with intelligent defaults and guidance]
```

### Using Individual Skills (For Direct Control)

If you prefer command-line style control, use individual skills directly.

## Agent vs. Skills: Which to Use?

### Use the Tracker Agent When:
- 🎯 You want **guidance and recommendations**
- 🔄 You need **multi-step workflows** (sprint planning, feature setup)
- 💡 You want **proactive insights** and analysis
- 💬 You prefer **conversational interaction**
- 🤔 You're **planning or strategizing**

**Example**: "Help me plan my next sprint" - The agent will review progress, suggest tasks, set priorities, and create a complete plan.

### Use Individual Skills When:
- ⚡ You know **exactly what to do**
- 🎯 You need a **specific operation**
- 🔧 You prefer **command-line control**
- ⏱️ You want **quick, direct execution**

**Example**: `/tracker:add-task my-app --phase=1 --track=auth --priority=high` - Direct task creation with no conversation.

---

## Available Skills

### 1. `/tracker:create-tracker` - Create a New Tracker

Creates a new task tracker with initial phases and tracks.

**Usage**:
```bash
/tracker:create-tracker [tracker-name]
```

**Examples**:
```bash
/tracker:create-tracker my-app
/tracker:create-tracker e-commerce-platform
```

**What it does**:
- Creates `.trackers/{tracker-name}/` directory
- Generates `TRACKER.md` file with phase and track structure
- Creates `plans/` directory for detailed task plans
- Sets up `archive/` directory for completed work

---

### 2. `/tracker:add-task` - Add Task to Tracker

Adds a new task to an existing tracker with metadata and optional plan file.

**Usage**:
```bash
/tracker:add-task [tracker-name] [options]
```

**Options**:
- `--phase=N` - Specify phase number
- `--track=name` - Specify track name
- `--priority=high|medium|low` - Set priority
- `--complexity=high|medium|low` - Set complexity

**Examples**:
```bash
/tracker:add-task my-app
/tracker:add-task my-app --phase=2 --track=authentication
/tracker:add-task my-app --phase=1 --priority=high
```

**What it does**:
- Auto-assigns task number (01, 02, 03...)
- Adds task to correct phase and track section
- Updates tracker statistics
- Optionally creates detailed plan file
- Updates track and phase counts

---

### 3. `/tracker:mark-status` - Quick Status Updates

Quickly updates task status with automatic timestamp tracking.

**Usage**:
```bash
/tracker:mark-status [tracker-name]
```

**Examples**:
```bash
/tracker:mark-status my-app
> Select task: 03
> New status: complete

/tracker:mark-status my-app
> Select task: 05
> New status: blocked
```

**What it does**:
- Interactive task selection
- Quick status changes
- Automatic timestamps (started, completed)
- Statistics recalculation
- Phase and track progress updates

**For comprehensive task editing** (priority, complexity, description, etc.), use `/tracker:edit-task` instead.

---

### 4. `/tracker:review-tracker` - Review Progress

Reviews tracker progress and generates comprehensive status reports.

**Usage**:
```bash
/tracker:review-tracker [tracker-name] [options]
```

**Options**:
- `--detailed` - Show complete task breakdown
- `--phase=N` - Filter by phase
- `--track=name` - Filter by track
- `--status=value` - Filter by status
- `--export` - Save report to file

**Examples**:
```bash
/tracker:review-tracker my-app
/tracker:review-tracker my-app --detailed
/tracker:review-tracker my-app --status=blocked
/tracker:review-tracker my-app --phase=2
/tracker:review-tracker my-app --detailed --export
```

**What it shows**:
- Overall completion percentage
- Progress by phase and track
- Status breakdown (pending, in progress, complete, blocked)
- Priority breakdown (high, medium, low)
- Blocked tasks and dependencies
- Next actions and recommendations
- Visual progress bars

---

### Additional Skills

The plugin includes additional skills for advanced tracker management:

#### Phase Management
- `/tracker:add-phase` - Add a new phase to an existing tracker
- `/tracker:edit-phase` - Edit phase details (name, status, dates)
- `/tracker:remove-phase` - Remove a phase from the tracker

#### Track Management
- `/tracker:add-track` - Add a new feature track to the tracker
- `/tracker:edit-track` - Edit track details (name, description)
- `/tracker:remove-track` - Remove a track from the tracker

#### Task Management
- `/tracker:edit-task` - Edit task details (title, description, priority, complexity, dependencies)
- `/tracker:remove-task` - Remove a task from the tracker

#### Tracker Management
- `/tracker:edit-tracker` - Edit tracker metadata (name, description, status)

These skills provide fine-grained control over tracker structure and are useful for:
- Adapting to changing project requirements
- Reorganizing work breakdown structures
- Cleaning up completed or cancelled work
- Adjusting priorities and dependencies

---

## Tracker File Structure

```
.trackers/
├── {tracker-name}/
│   ├── TRACKER.md              # Main tracker file
│   ├── README.md               # Tracker documentation
│   ├── plans/                  # Individual task plan files
│   │   ├── 01-task-name.md
│   │   ├── 02-task-name.md
│   │   └── ...
│   ├── reviews/                # Exported review reports
│   │   └── {tracker-name}-review-{date}.md
│   └── archive/                # Completed tasks
│       └── completed-tasks/
```

## Tracker Format

### Frontmatter
```yaml
---
name: "Project Name"
created: 2026-01-27
updated: 2026-01-27
status: "In Progress"
---
```

### Overview Section
Shows total counts and completion percentage.

### Phases Section
Lists all phases with status and dates.

### Tracks Section
Lists feature tracks with progress across phases.

### Tasks Section
Organized by phase and track, each task includes:
- Task number (01, 02, 03...)
- Title
- Status (Pending, In Progress, Complete, Blocked, On Hold, Cancelled)
- Plan file reference
- Priority (High, Medium, Low)
- Complexity (High, Medium, Low)
- Started and completed timestamps
- Dependencies (blocked by)
- Acceptance criteria
- Description

## Typical Workflow

### 1. Create New Tracker
```bash
/tracker:create-tracker my-app
> Phases: 3 (Planning, Implementation, Testing)
> Tracks: authentication, dashboard
```

### 2. Add Tasks
```bash
/tracker:add-task my-app --phase=1 --track=authentication
> Title: "Setup authentication framework"
> Priority: High
> Complexity: Medium

/tracker:add-task my-app --phase=1 --track=dashboard
> Title: "Create dashboard layout"
> Priority: Medium
```

### 3. Work on Tasks
```bash
/tracker:mark-status my-app
> Task 01 → In Progress
# ... do work ...
/tracker:mark-status my-app
> Task 01 → Complete
```

### 4. Review Progress
```bash
/tracker:review-tracker my-app
> Shows: 1/2 tasks complete (50%)
> Recommends: Start Task 02
```

### 5. Continue Through Phases
```bash
/tracker:add-task my-app --phase=2 --track=authentication
> Title: "Implement login API"
> Blocked by: 01

/tracker:edit-phase my-app
> Phase 1 → Status: Complete
/tracker:review-tracker my-app --phase=2
```

## Status Values

- **Pending**: Not started
- **In Progress**: Currently being worked on
- **Complete**: Finished
- **Blocked**: Waiting on dependencies
- **On Hold**: Paused temporarily
- **Cancelled**: Won't be completed

## Priority Levels

- **High**: Critical, must complete
- **Medium**: Important, normal priority
- **Low**: Nice to have, can defer

## Complexity Levels

- **High**: Complex, architectural, time-consuming
- **Medium**: Standard implementation work
- **Low**: Simple, straightforward tasks

## Best Practices

1. **Create trackers for projects**, not individual features
2. **Use phases** for sequential stages (can't skip phases)
3. **Use tracks** for parallel features (can work simultaneously)
4. **Set priorities** to focus work on what matters
5. **Mark blockers** to identify dependency chains
6. **Review regularly** to track progress and identify issues
7. **Create plan files** for complex tasks needing detailed planning
8. **Export reports** for meetings and retrospectives

## Integration with Other Plugins

### With develop Plugin
The develop plugin integrates automatically with the tracker system:
1. Use `/develop:develop-project` to create trackers and implement features
2. The plugin automatically organizes work into phases and tracks
3. Progress updates happen in real-time as implementation proceeds

### With git-worktree
When working on multiple feature tracks:
1. Create git worktrees for different feature tracks
2. Use `/tracker:mark-status` to update task status as you complete work in each worktree
3. Keep your tracker synchronized with your branching strategy

## Examples

### Software Development Project
```
Phases: Foundation, Implementation, Testing, Deployment
Tracks: authentication, user-profile, products, cart, checkout

Task flow:
- Phase 1 sets up base infrastructure for all tracks
- Phase 2 implements features across all tracks
- Phase 3 tests each track independently
- Phase 4 deploys all tracks together
```

### Content Creation Project
```
Phases: Research, Writing, Editing, Publishing
Tracks: blog-posts, tutorials, documentation

Task flow:
- Research topics for all content types
- Write drafts for each track
- Edit and refine content
- Publish across all tracks
```

### Migration Project
```
Phases: Analysis, Planning, Execution, Validation
Tracks: database, api, frontend, infrastructure

Task flow:
- Analyze current state of all systems
- Plan migration strategy per track
- Execute migrations (some tracks may be blocked by others)
- Validate each track independently
```

## Tips

- Start with 3-5 phases for most projects
- Keep track names short and descriptive
- Use task numbers for easy reference
- Review blocked tasks regularly
- Update status frequently to keep tracker accurate
- Export reports before meetings
- Archive completed trackers for reference

## Troubleshooting

**Q: Can I reorder tasks?**
A: Task numbers are sequential and auto-assigned. To reorder, manually edit the TRACKER.md file.

**Q: Can I move a task to a different phase?**
A: Yes, manually edit the TRACKER.md file to move the task section to the correct phase.

**Q: What if I need to add a phase later?**
A: Manually edit the TRACKER.md file to add the new phase section.

**Q: How do I delete a task?**
A: Use `/tracker:mark-status` to set status to "Cancelled", use `/tracker:remove-task` to delete it completely, or manually edit TRACKER.md.

**Q: Can tasks have sub-tasks?**
A: No, the tracker format keeps tasks flat for simplicity. Break complex tasks into multiple tasks instead.

**Q: How do I handle recurring tasks?**
A: Create separate task entries for each occurrence with unique numbers.

## Architecture

### Components

```
tracker/
├── agents/
│   └── tracker.md              # Tracker Agent system prompt
├── skills/
│   ├── create-tracker/         # Create tracker skill
│   ├── add-task/              # Add task skill
│   ├── review-tracker/        # Review tracker skill
│   └── ...                    # More skills
├── .trackers/                 # Your tracker data
│   └── {tracker-name}/
│       ├── TRACKER.md         # Main tracker file
│       ├── plans/             # Task plan files
│       └── reviews/           # Exported reports
└── .claude-plugin/
    └── plugin.json            # Plugin manifest
```

### How It Works

1. **Agent Layer**: Provides intelligent orchestration and decision-making
2. **Skills Layer**: Executes specific tracker operations
3. **Data Layer**: Stores trackers in structured markdown format

The agent uses skills internally, but you can also use skills directly.

## Documentation

- **Agent Documentation**: [agents/tracker.md](agents/tracker.md) - Comprehensive agent guide
- **Plugin Overview**: This file (README.md) - Quick reference for all features
- **Skill Documentation**: Each skill has a `SKILL.md` file with detailed instructions

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with Claude Code
5. Submit a pull request

## License

MIT License - See LICENSE file for details.

## Author

**Gian Patrick Quintana**
- Email: gian.quintana@hirokata.dev
- GitHub: [@hirogakatageri](https://github.com/hirogakatageri)

## Support

For issues or feature requests:
- **Agent issues**: See [agents/tracker.md](agents/tracker.md)
- **Skill details**: Refer to individual SKILL.md files in each subdirectory:
  - `skills/create-tracker/SKILL.md`
  - `skills/add-task/SKILL.md`
  - `skills/review-tracker/SKILL.md`
  - And more...
- **General questions**: Check this README or the agent documentation
