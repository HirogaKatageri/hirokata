# HiroKata Claude Code Plugin Marketplace

A curated collection of Claude Code plugins for enhanced development workflows. **Version 2.3.0** — [View Changelog](CHANGELOG.md)

---

## Installation

There are two ways to install plugins from this marketplace: using Claude Code's built-in marketplace system (recommended), or cloning the repository and copying plugins manually.

### 1.a. Install Using the Claude Code Marketplace

This is the official method. Claude Code's marketplace system handles discovery, installation, and future updates automatically.

**Step 1 — Add the marketplace**

Run this inside a Claude Code session or from the CLI:

```bash
# Inside Claude Code
/plugin marketplace add hirogakatageri/hirokata-cc-marketplace

# Or from the terminal
claude plugin marketplace add hirogakatageri/hirokata-cc-marketplace
```

**Step 2 — Install plugins**

Once the marketplace is added, install individual plugins by name. The marketplace identifier is `hirokata`.

```bash
# Install the Guild plugin
/plugin install guild@hirokata

# Install the Software plugin
/plugin install software@hirokata

# Install the Project Management plugin
/plugin install project-management@hirokata
```

**Step 3 — Keep plugins up to date**

Pull the latest versions at any time:

```bash
/plugin marketplace update hirokata
```

> **For teams:** Add the marketplace at project scope so it is shared automatically via `.claude/settings.json`:
> ```bash
> claude plugin marketplace add hirogakatageri/hirokata-cc-marketplace --scope project
> ```

### 1.b. Cloning the Repository and Copying a Plugin

For offline environments or when you want to vendor plugins directly into your project, clone the repo and copy plugin directories manually.

**Step 1 — Clone the marketplace**

```bash
git clone https://github.com/hirogakatageri/hirokata-cc-marketplace.git
```

**Step 2 — Copy plugins into your project**

Claude Code automatically discovers and loads every plugin in your project's `.claude-plugin/` directory.

```bash
# Guild plugin
cp -r hirokata-cc-marketplace/plugins/guild /path/to/your-project/.claude-plugin/guild

# Software plugin
cp -r hirokata-cc-marketplace/plugins/software-project /path/to/your-project/.claude-plugin/software
```

Your project will look like this:

```
your-project/
└── .claude-plugin/
    ├── guild/       # Loaded automatically on every session
    └── software/    # Loaded automatically on every session
```

> **Tip:** Commit `.claude-plugin/` to your repo so every team member gets the same plugins without any setup.

**Verify the plugins loaded** by trying a trigger phrase after starting Claude Code:

```
guild status
```

---

## How to Use the Guild Plugin

The Guild plugin (v1.5.0) provides continuous agent orchestration through a persistent board-driven work cycle. The guild tracks requirements, tasks, and progress across sessions — no per-session setup required.

```
product-owner → architect → developers / developer-svelte (up to 3 parallel)
    → test-writer → 4 reviewers in parallel
    → [fix cycle if issues found]
```

### Setting Up

The guild requires no manual initialization. On your first check-in it automatically creates a `.guild/` directory in your project:

```
.guild/
├── BOARD.md          # Central board: in-progress, backlog, done, requirements
├── requirements/     # REQ-NNN.md — one file per requirement
├── tasks/            # TASK-NNN.md — one file per task
├── plans/            # PLAN-NNN.md — one file per implementation plan
└── docs/             # Persistent knowledge base (survives board resets and releases)
```

Open a Claude Code session in your project and say:

```
check in
```

The guild will greet you, create the board, and ask what you want to work on.

### Creating Requirements

Requirements are the starting point for all guild work. There are two ways to add them.

**During check-in** — describe the feature in plain language when the guild asks what you want to work on:

```
I want to add user authentication with email and password login
```

**Directly at any time** using the `guild:new-requirement` skill:

```
new requirement
```

or with inline context:

```
I need a feature: dark mode toggle for the settings page
```

The guild spawns a `product-owner` agent to interview you, gather full details, and write a structured requirement document (`REQ-NNN.md`). All planning and implementation flows from that document — you do not need to write it manually.

> Multiple requirements can be queued. The guild exhausts all product-owner tasks (requirement gathering) before dispatching any architect tasks, ensuring every requirement is fully specified before planning begins.

### Checking In and Auto-Continue

**Checking in** resumes the guild exactly where it left off. Run it at the start of each session:

```
check in
```

The guild reports status — in-progress tasks, recent completions, backlog, and requirement progress — then asks what to do next:

```
Guild Check-in
==============

In Progress:
  TASK-003: Implement auth service (developer) — since 2026-04-07

Backlog (2 tasks):
  TASK-005: Implement login endpoint (developer) — high priority
  TASK-006: Plan payment feature (architect) — medium priority

Requirements:
  REQ-001: User Authentication — in-progress (3/6 done)

What would you like to do?
  1. Continue working through the backlog
  2. Add a new requirement
  3. Review completed work in detail
  4. Adjust priorities or tasks
```

After each task completes, the guild asks whether to continue. Respond with **"continue all"** to activate auto-continue mode:

```
Continue to next task? (yes / no / details / continue all)
> continue all
```

In auto-continue mode the guild skips the prompt between tasks and runs the full backlog autonomously, printing one-line status updates as each task finishes:

```
TASK-003 done: Implement auth service → 2 follow-ups created
TASK-005 done: Implement login endpoint → 1 follow-up created
```

Auto-continue stops when the backlog is empty or a task is blocked and needs your input.

### Skills Reference

| Skill | What it does | Trigger Phrases |
|-------|-------------|----------------|
| `guild:check-in` | Start or resume a work session, report status, drive the work cycle | "check in", "clock in", "let's get to work", "I'm here" |
| `guild:new-requirement` | Add a new requirement and queue a product-owner task to gather details | "new requirement", "I need a feature", "I want to build" |
| `guild:guild-status` | Read-only board view — no work is dispatched | "guild status", "show the board", "what's on the board" |
| `guild:comprehensive-review` | Run all 4 reviewers in parallel against recent changes | "review my changes", "run comprehensive review", "check all my code" |
| `guild:clear-board` | Wipe all tasks, requirements, and plans (asks for confirmation) | "clear the board", "reset the guild", "start fresh" |
| `guild:create-workflow` | Interactively design and generate automation workflows (GitHub Actions, scripts, Makefiles) | "create a workflow", "generate a workflow", "add a GitHub Actions workflow", "set up automation" |
| `guild:discuss` | Summarize conversation context and facilitate focused topic discussions | "discuss", "let's discuss", "discuss [topic]", "summarize the context", "what are we working on" |
| `guild:release` | Stamp CHANGELOG, archive completed requirements, create git tag | "cut a release", "ship it", "tag a version" |

### Agents

| Agent | Role |
|-------|------|
| `guild:product-owner` | Interviews user, gathers requirements, writes REQ document |
| `guild:architect` | Reads REQ, explores codebase, writes PLAN, declares dev tasks |
| `guild:developer` | Implements code per plan and requirement |
| `guild:developer-svelte` | Svelte 5 / SvelteKit specialist — used when tasks touch `.svelte`, `+page.*`, `+layout.*`, `+server.*` files |
| `guild:test-writer` | Writes and runs unit tests after all dev tasks complete |
| `guild:product-reviewer` | Verifies implementation satisfies plan requirements |
| `guild:reviewer-security` | Security vulnerabilities, OWASP Top 10 |
| `guild:reviewer-architecture` | Plan alignment, patterns, separation of concerns |
| `guild:reviewer-business-logic` | Acceptance criteria, business rules, testability |
| `guild:reviewer-edge-case` | Boundary conditions, null handling, error scenarios |
| `guild:researcher` | Technology research, API investigation, documentation lookup |

[View Full Guild Documentation](plugins/guild/README.md)

---

## Other Plugins & Useful Skills

### Software Plugin (v1.0.5)

A collection of standalone skills for software development workflows.

**`software:conventional-commit`** — Generates properly formatted conventional commits by analyzing changes, grouping related modifications, and creating semantic commit messages.

Trigger phrases: "create a conventional commit", "generate conventional commits", "commit with conventional format", "group my changes for commits"

**`software:split-plan`** — Analyzes a master plan file and splits it into 8 phase-specific implementation plans organized by feature tracks (Foundational → Models → Services → Data → Rules → State Management → UI → Tests).

**`software:categorize-task`** — Reference guide for classifying development tasks into the 8-phase clean architecture structure.

[View Software Plugin Documentation](plugins/software-project/README.md)

---

### Project Management Plugin (v1.0.0)

A file-based request queue that lets you drop work items into a folder and have the orchestrator pick them up and delegate them automatically.

**How it works:**

1. Initialize the project structure with `initialize project`
2. Create request files with `create a request`
3. Process all pending requests with `process requests` or start hourly auto-processing

**Skills:**

| Skill | What it does | Trigger Phrases |
|-------|-------------|----------------|
| `project-management:initialize-project` | Creates `requirements/`, `tasks/`, `requests/todo/`, `requests/done/` directories | "initialize project", "set up project", "init project" |
| `project-management:create-request` | Writes a structured request file to `requests/todo/` | "create a request", "queue a request", "new request" |
| `project-management:start-request-monitoring` | Schedules the orchestrator to run every hour against `requests/todo/` | "start request monitoring", "monitor requests", "watch requests" |
| `project-management:stop-request-monitoring` | Cancels the scheduled monitoring job | "stop request monitoring", "stop watching requests" |
| `project-management:list-request-monitoring` | Lists active monitoring jobs | "list request monitoring", "show monitoring jobs" |

**Agent:**

`project-management:project-orchestrator` — Scans `requests/todo/` for pending request files, delegates each to the appropriate agent or skill, then moves completed files to `requests/done/`.

---

## License

MIT License — see [LICENSE](LICENSE) for details.

Copyright (c) 2026 Gian Patrick Quintana

## Author

**Gian Patrick Quintana**
- Email: gian.quintana@hirokata.dev
- GitHub: [@hirogakatageri](https://github.com/hirogakatageri)
