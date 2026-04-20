# Guild Plugin

A Claude Code plugin for continuous agent orchestration through a persistent board-driven work cycle.

## Overview

The **guild** plugin manages an ongoing development workflow through a shared board (`.guild/BOARD.md`). Each work session starts with a check-in: the orchestrator reports status, gathers input, and drives a continuous loop — dispatching tasks to specialized agents, processing follow-ups, and automatically chaining the next work items.

### Key Features

- **Persistent Board**: `.guild/BOARD.md` tracks requirements, in-progress tasks, backlog, and done work across sessions
- **Automatic Agent Chains**: A new requirement flows automatically through product-owner → architect → developers → test-writer → 4 parallel reviewers
- **Session-Based Workflow**: Each check-in resumes exactly where the last session ended
- **Parallel Execution**: Up to 3 developer agents run in parallel per plan; all 4 reviewers run simultaneously
- **Stale Task Recovery**: Tasks interrupted mid-session are detected and handled on the next check-in

## The Agent Chain

```
User provides input
  └→ product-owner: gathers details, writes REQ document
      └→ architect: reads REQ, explores codebase, writes PLAN, declares dev tasks
          └→ developer ×N: implements code per plan (up to 3 in parallel)
              └→ test-writer: writes and runs unit tests
                  └→ 4 reviewers in parallel:
                      ├── reviewer-security
                      ├── reviewer-architecture
                      ├── reviewer-business-logic
                      └── reviewer-edge-case
                          ├→ [all approved] requirement complete
                          └→ [any issues] developer: fix tasks → test-writer → reviewers again
```

## Skills

### `guild:check-in`

The main orchestrator skill. Starts or resumes a work session, reports status, gathers input, and drives the continuous work cycle.

**Trigger Phrases:**
- "check in"
- "clock in"
- "standup"
- "guild check in"
- "what's the status"
- "let's get to work"
- "start working"
- "daily standup"
- "guild standup"
- "I'm here"
- "reporting in"

**What it does:**
1. Initializes `.guild/` on first use or loads the existing board
2. Reports in-progress tasks, recent completions, backlog, and requirement status
3. Gathers user input (continue / new requirement / review / adjust priorities)
4. Enters the work cycle: dispatch → complete → follow-ups → repeat
5. Presents a session summary when the work cycle ends

### `guild:guild-status`

Quick read-only view of the board. No work is executed.

**Trigger Phrases:**
- "guild status"
- "board status"
- "show the board"
- "what's on the board"
- "project status"
- "show guild"
- "guild board"
- "what's happening"

### `guild:new-requirement`

Adds a new requirement stub to the board and creates a product-owner task to gather full details.

**Trigger Phrases:**
- "add a requirement"
- "new requirement"
- "I need a feature"
- "add to the guild"
- "create requirement"
- "queue a feature"
- "I want to build"

**Arguments:**
- `title` — short title for the requirement (optional, asked if not provided)
- `description` — brief description of what is needed (optional, asked if not provided)

**Clear-board prompt:** If the board already has requirements, tasks, or plans, the skill asks whether to wipe them before adding the new requirement. Answering "yes" delegates to `guild:clear-board`; "no" preserves existing work.

### `guild:clear-board`

Wipes all tasks, requirements, and plans from the board and resets it to a clean slate. Always asks for confirmation before deleting.

**Trigger Phrases:**
- "clear the board"
- "reset the guild"
- "start fresh"
- "wipe the board"
- "clear all tasks"
- "reset the board"

## Agents

| Agent | Model | Role |
|-------|-------|------|
| `guild:product-owner` | Sonnet | Interviews user, gathers full requirements, writes REQ document |
| `guild:architect` | Sonnet | Reads REQ, explores codebase, writes implementation PLAN, declares dev tasks |
| `guild:developer` | Sonnet | Implements code per plan and requirement |
| `guild:test-writer` | Sonnet | Writes and runs unit tests after all dev tasks complete |
| `guild:product-reviewer` | Sonnet | Verifies implementation satisfies plan requirements |
| `guild:reviewer-security` | Sonnet | Security vulnerabilities, OWASP Top 10 |
| `guild:reviewer-architecture` | Sonnet | Plan alignment, patterns, separation of concerns |
| `guild:reviewer-business-logic` | Sonnet | Acceptance criteria, business rules, testability |
| `guild:reviewer-edge-case` | Sonnet | Boundary conditions, null handling, error scenarios |
| `guild:researcher` | Sonnet | Technology research, API investigation, documentation lookup |

## Board Structure

The guild maintains a `.guild/` directory in your project:

```
.guild/
├── BOARD.md                    # Central board: in-progress, backlog, done, requirements
├── requirements/
│   └── REQ-NNN.md              # One file per requirement
├── tasks/
│   └── TASK-NNN.md             # One file per task (includes work log and follow-ups)
└── plans/
    └── PLAN-NNN.md             # One file per implementation plan
```

**BOARD.md** tracks:
- **In Progress** — tasks currently being worked
- **Backlog** — pending tasks ordered by priority
- **Done** — last 20 completed tasks
- **Requirements** — all requirements with progress counters

## Quick Start

```
# Initialize and start your first work session
check in

# The guild will:
# - Create .guild/BOARD.md and directory structure
# - Ask what you want to work on
# - Create a requirement and start the agent chain
# - Continue until you say "no" or the backlog is empty

# Check status without starting work
guild status

# Add a new requirement directly
new requirement

# Clear the board and start over
clear the board
```

## File Structure

```
guild/
├── .claude-plugin/
│   └── plugin.json                     # Plugin manifest
├── agents/
│   ├── architect.md
│   ├── developer.md
│   ├── product-owner.md
│   ├── product-reviewer.md
│   ├── researcher.md
│   ├── reviewer-architecture.md
│   ├── reviewer-business-logic.md
│   ├── reviewer-edge-case.md
│   ├── reviewer-security.md
│   └── test-writer.md
└── skills/
    ├── check-in/
    │   ├── SKILL.md
    │   └── references/
    │       ├── agent-chains.md         # Agent chain patterns
    │       ├── board-format.md         # BOARD.md structure and update rules
    │       └── task-lifecycle.md       # Task file format and status transitions
    ├── clear-board/
    │   └── SKILL.md
    ├── guild-status/
    │   └── SKILL.md
    └── new-requirement/
        └── SKILL.md
```

## License

MIT License - See LICENSE file for details.

## Author

**Gian Patrick Quintana**
- Email: gian.quintana@hirokata.dev
- GitHub: [@hirogakatageri](https://github.com/hirogakatageri)
