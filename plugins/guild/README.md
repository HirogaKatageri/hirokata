# Guild Plugin

A Claude Code plugin for continuous agent orchestration through a persistent board-driven work cycle.

## Overview

The **guild** plugin manages an ongoing development workflow through a queue of ticket files. Each ticket owns its own status; a small `.guild/state.yaml` holds only the cursor and ID counters. There is **no `BOARD.md`** — the board is a live view rendered by scanning the ticket and requirement files. Each work session starts with a check-in: the orchestrator reports status, gathers input, and walks a cursor through the queue — dispatching one ticket at a time to specialized agents, materializing their follow-ups, and continuing to the next ticket.

### Key Features

- **Single source of truth**: status lives in each `TASK-NNN.md`; `state.yaml` holds only the cursor (`current`) and counters (`next-task`, `next-req`, `next-plan`). No duplicated board state to reconcile.
- **Cursor-driven sequencing**: tickets run in creation (ID) order. Development is **sequential** — one developer ticket at a time.
- **Automatic Agent Chains**: a new requirement flows through product-owner → architect → developers → test-writer → 4 parallel reviewers. The architect emits the test + review tail as real tickets up front.
- **Per-requirement review gate**: reviewers run once all of a requirement's implementation tickets are done, and fan out 4-wide in parallel — the only parallelism in the system.
- **Session-Based Workflow**: each check-in resumes exactly where the last session ended.
- **Stale Task Recovery**: tickets interrupted mid-session are detected and handled on the next check-in.

## The Agent Chain

```
User provides input
  └→ product-owner: gathers details, writes REQ document
      └→ architect: reads REQ, explores codebase, writes PLAN,
         declares dev tickets + the test-writer + reviewer tail
          └→ developer ×N: implement code per plan, ONE AT A TIME (sequential)
              └→ test-writer: writes and runs unit tests
                  └→ 4 reviewers in parallel:
                      ├── reviewer-security
                      ├── reviewer-architecture
                      ├── reviewer-business-logic
                      └── reviewer-edge-case
                          ├→ [all approved] requirement complete
                          └→ [any issues] developer fixes → test-writer → reviewers again (max 2 rounds)
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
1. Initializes `.guild/` and `state.yaml` on first use, or loads existing state
2. Reports in-progress tickets, recent completions, backlog, and requirement status (rendered live from a file scan)
3. Gathers user input (continue / new requirement / review / adjust priorities)
4. Walks the cursor: dispatch → complete → materialize follow-ups → advance → repeat
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

### `guild:discuss`

Analyzes the current conversation context, surfaces subjects, and facilitates a focused discussion. Two modes:

- **Open mode** (`/discuss` or "discuss") — scans the full conversation, groups topics into a numbered map (3–8 subjects), lets you pick one or say "all", then drives a back-and-forth discussion loop until you're satisfied.
- **Targeted mode** (`discuss [topic]`) — scopes to a specific topic, presents a summary with key points and open questions, then enters the loop immediately.

Wraps up with a closing summary of what was covered and any decisions reached.

**Trigger Phrases:**
- "discuss"
- "let's discuss"
- "discuss [topic]"
- "talk about"
- "let's talk about"
- "summarize the context"
- "what are we working on"
- "break down the topics"
- "recap the conversation"

### `guild:release`

Finalizes completed requirements into a versioned release: stamps `CHANGELOG.md` Unreleased with the new version, archives completed requirement artifacts to `.guild/archive/{version}/`, and creates an annotated git tag. Does not push.

**Trigger Phrases:**
- "cut a release"
- "release the guild"
- "ship it"
- "tag a version"
- "guild release"

**Arguments:**
- `--dry-run` — preview the release plan without making changes
- `--only REQ-NNN,REQ-MMM` — release only specific requirements

The check-in skill automatically appends a bullet to `CHANGELOG.md`'s `[Unreleased]` section whenever a requirement is marked done, so the changelog is always current between releases.

### `guild:verify-and-fix`

Diagnoses and fixes reported errors through a structured end-to-end workflow: gather context via your error-verification guide, investigate configured log and code sources, propose ranked solutions, then apply a test-driven fix.

**Trigger Phrases:**
- "check this error"
- "check this bug"
- "here's an error"
- "here's a bug"
- "I have an error"
- "I have a bug"
- "found a bug"
- "got an error"
- "debug this"
- "this is broken"
- "fix this error"
- "verify and fix"

**What it does:**
1. Phase 0 — Guide Gate: detects or creates an error-verification guide in `CLAUDE.md` by interviewing the user about their monitoring services, issue tracker, stack, and environments
2. Phase 1 — Error Input: collects the error artifact (inline text, stack trace, file path, or link) from the triggering message
3. Phase 2 — Investigation: reads `references/investigation.md`, queries configured log and code sources in priority order, and gathers evidence
4. Phase 3 — Solution Proposal: produces a findings report, then presents a ranked solution set for the user to choose from
5. Phase 4 — TDD Fix: reads `references/tdd-fix.md`, writes a failing test for the selected solution, applies the fix, runs the test, and delivers a final summary

### `guild:qa`

Seeds the guild's **independent QA discipline** — a quality function that runs
beside the feature chain rather than inside it. The `qa-strategist` maps product
risk and plans coverage; `qa-tester` agents run the actual app, author end-to-end
(Playwright) regression specs, and file bugs back to the board as developer fix
tasks. Use it to build comprehensive e2e regression suites and to probe the
running product with adversarial "what-if" inputs.

**Trigger Phrases:**
- "QA the product"
- "QA the checkout flow"
- "run a QA pass"
- "build comprehensive e2e tests"
- "write regression tests"
- "test the running app"
- "what-if testing"

**What it does:**
1. Ensures a `.guild/qa/` workspace and a standing "Product QA & E2E Regression" umbrella requirement
2. Seeds a `qa-strategist` task for the requested scope (whole product or a named flow), in `full` or `cadence` mode
3. The strategist resolves the oracle (internal specs → external board via MCP → code + running app → user), builds a risk map and coverage matrix, and declares `qa-tester` missions
4. `qa-tester` agents run the app, apply the what-if catalog, author e2e specs (hybrid oracle: lock good behavior, flag suspect behavior as bugs, ask the user when ambiguous), and file developer fix tasks
5. Bugs flow through the normal bug-fix chain; on fix, a re-verify qa-tester confirms and the spec joins the regression manifest

QA artifacts (`charter`, `missions`, `sessions`, `ledger`, `regression` manifest)
live under `.guild/qa/` and are **evergreen** — they survive releases and board
resets. Committed e2e specs live in the project's real e2e dir and run in CI;
`developer`/`developer-svelte` co-maintain them. Can be armed on a **standing
cadence** via `/schedule` or `/loop` (opt-in per project).

## Agents

| Agent | Model | Role |
|-------|-------|------|
| `guild:product-owner` | Sonnet | Interviews user, gathers full requirements, writes REQ document |
| `guild:architect` | Opus | Reads REQ, explores codebase, writes implementation PLAN, declares dev tasks; routes Svelte tasks to `developer-svelte` |
| `guild:developer` | Sonnet | Implements code per plan and requirement |
| `guild:developer-svelte` | Sonnet | Svelte 5 / SvelteKit specialist — pre-loaded with four reference skills; used when tasks touch `.svelte`, `+page.*`, `+layout.*`, `+server.*`, hooks, or `svelte.config.js` |
| `guild:test-writer` | Sonnet | Writes and runs unit tests after all dev tasks complete |
| `guild:product-reviewer` | Haiku | Verifies implementation satisfies plan requirements |
| `guild:reviewer-security` | Haiku | Security vulnerabilities, OWASP Top 10 |
| `guild:reviewer-architecture` | Haiku | Plan alignment, patterns, separation of concerns |
| `guild:reviewer-business-logic` | Haiku | Acceptance criteria, business rules, testability |
| `guild:reviewer-edge-case` | Haiku | Boundary conditions, null handling, error scenarios |
| `guild:researcher` | Haiku | Technology research, API investigation, documentation lookup |
| `guild:qa-strategist` | Sonnet | QA planning — risk map, coverage matrix, adversarial what-if missions (independent QA discipline) |
| `guild:qa-tester` | Sonnet | Empirically runs the product, authors e2e/Playwright regression specs, files bugs (independent QA discipline) |

## State Structure

The guild maintains a `.guild/` directory in your project:

```
.guild/
├── state.yaml                  # Cursor (current) + ID counters — the only orchestrator state file
├── requirements/
│   └── REQ-NNN.md              # One file per requirement
├── tasks/
│   └── TASK-NNN.md             # One file per task — OWNS its status, work log, and follow-ups
├── plans/
│   └── PLAN-NNN.md             # One file per implementation plan (+ slice files)
├── docs/                       # Evergreen knowledge base (researcher findings)
│   └── {topic-slug}.md         # One file per topic; updated in place on overlap
├── qa/                         # Evergreen QA artifacts (charter, missions, ledger, manifest)
└── archive/                    # Created by guild:release
    └── {version}/              # Archived requirements, plans, tasks per release
```

There is **no `BOARD.md`**. Status lives in each `TASK-NNN.md` (`todo` → `in-progress` → `done` / `failed`); the "board" is rendered live by scanning the ticket and requirement files. `state.yaml` holds only:

```yaml
current: TASK-005     # the ticket the orchestrator is on (derived cache)
next-task: 6
next-req: 2
next-plan: 1
last-checkin: 2026-06-23
```

**`.guild/docs/`** is the guild's persistent knowledge base. The researcher writes findings here (not to task work logs), and the architect reads these docs during codebase analysis — so prior research informs new plans without re-dispatching the researcher. Docs are evergreen: they survive `guild:clear-board` and `guild:release`.

The live board view groups tickets by status:
- **In Progress** — tickets with `status: in-progress`
- **Backlog** — `todo` tickets, walked by the cursor in ID order
- **Recently Completed** — most recent `done` tickets
- **Requirements** — all requirements with live-computed progress counters

## Quick Start

```
# Initialize and start your first work session
check in

# The guild will:
# - Create .guild/state.yaml and directory structure
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
│   ├── developer-svelte.md             # Svelte 5 / SvelteKit specialist
│   ├── product-owner.md
│   ├── product-reviewer.md
│   ├── qa-strategist.md                 # QA discipline — risk map & coverage planning
│   ├── qa-tester.md                     # QA discipline — runs app, authors e2e specs
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
    │       ├── state-format.md         # state.yaml, ticket-owned status, live board view, cursor
    │       └── task-lifecycle.md       # Task file format and status transitions
    ├── clear-board/
    │   └── SKILL.md
    ├── comprehensive-review/
    │   └── SKILL.md
    ├── create-workflow/
    │   └── SKILL.md
    ├── discuss/
    │   └── SKILL.md
    ├── guild-status/
    │   └── SKILL.md
    ├── new-requirement/
    │   └── SKILL.md
    ├── qa/
    │   └── SKILL.md                    # Independent QA discipline entry point
    ├── qa-mindset/
    │   └── SKILL.md                    # QA pillars, what-if catalog, hybrid oracle (agent reference)
    ├── qa-artifacts/
    │   └── SKILL.md                    # .guild/qa/ artifact formats (agent reference)
    ├── release/
    │   └── SKILL.md
    ├── svelte-core/
    │   └── SKILL.md                    # Svelte 5 core concepts reference
    ├── svelte-build-deploy/
    │   └── SKILL.md                    # SvelteKit build and deployment reference
    ├── svelte-advanced/
    │   └── SKILL.md                    # Svelte 5 advanced patterns reference
    ├── svelte-best-practices/
    │   └── SKILL.md                    # Svelte development best practices reference
    └── verify-and-fix/
        ├── SKILL.md                    # End-to-end error diagnosis and fix workflow
        └── references/
            ├── investigation.md        # Investigation steps, source-query order, findings and solution format
            └── tdd-fix.md              # TDD fix flow, test requirements, and final summary format
```

## License

MIT License - See LICENSE file for details.

## Author

**Gian Patrick Quintana**
- Email: gian.quintana@hirokata.dev
- GitHub: [@hirogakatageri](https://github.com/hirogakatageri)
