# Software Plugin

Four focused skills for planning, committing and reporting on software work: an 8-phase clean
architecture vocabulary for classifying tasks, a planner that splits a master plan into per-phase
plan files, a conventional-commit generator, and a daily handoff writer.

> **This plugin used to be a workflow engine.** Through v1.0.4 it also shipped a
> `develop-project` orchestration skill, a `generate-requirements` skill, a
> `comprehensive-review` skill and eight agents. In **v1.0.5 those were removed** — they had
> grown into duplicates of what the [Guild plugin](../guild) does with a real board behind it.
> What remains here is the part that had no equivalent: the phase model and the commit
> generator. See [CHANGELOG.md](CHANGELOG.md).

---

## Installation

```bash
/plugin install software@hirokata
```

---

## The 8-phase model

The plugin's shared vocabulary is a clean architecture dependency order:

```
Foundational → Models → Services → Data → Rules → State Management → UI → Tests
```

| # | Phase | What belongs in it |
|---|-------|--------------------|
| 1 | **Foundational** | Base abstractions, utilities, infrastructure, tooling setup |
| 2 | **Models** | Entities, model classes, DTOs, value objects |
| 3 | **Services** | External APIs, service integrations, the network layer |
| 4 | **Data** | Repositories, DAOs, the data access layer, local storage |
| 5 | **Rules** | Business logic, use cases, validation, domain rules |
| 6 | **State Management** | View models, presenters, state handlers, controllers |
| 7 | **UI** | Screens, components, views |
| 8 | **Tests** | Unit, integration and e2e tests, test utilities |

The order is not a preference — it is the dependency flow. UI depends on state management, which
depends on rules, which depends on data, and so on down. Work a phase before its predecessors and
you are building on something that does not exist yet.

### Feature tracks

A **track** is one complete feature cutting vertically through the phases — `authentication`,
`cart`, `products`. Within a phase, tasks are grouped by track, so Phase 2 (Models) might hold
`authentication` (User, Token), `products` (Product, Category) and `cart` (CartItem). Phases give
you the order; tracks tell you what a phase's work is *for*.

### Complexity scoring

Every task carries a 1–3 score, used for plan organization and rough estimation:

| Score | Means | Examples |
|-------|-------|----------|
| **1 — Low** | Simple and self-contained | Add a constant, create a simple model, add a utility |
| **2 — Medium** | Moderate effort | Implement a feature, build a component, wire an API |
| **3 — High** | Complex or architectural | Auth systems, state frameworks, payments, real-time |

Bump a score up for security-critical work, multiple integrations, or unclear requirements; down
for well-defined, isolated work with existing code to copy from.

---

## Skills

| Skill | Invocable | What it does |
|-------|-----------|--------------|
| `software:conventional-commit` | **Yes** | Analyzes staged and unstaged changes, groups related modifications, and generates Conventional Commits messages. |
| `software:daily-handoff` | **Yes** | Gathers the last 24 hours from GitHub, local checkouts and AI coding sessions, and writes a plain-language handoff document. |
| `software:split-plan` | Reference | Splits a master plan into 8 phase plan files organized by track, with complexity scores. |
| `software:categorize-task` | Reference | The classification guide — which of the 8 phases a given task belongs to. |

"Reference" skills are `user-invocable: false`: they are knowledge Claude loads when the work calls
for it, not commands you type.

### `software:conventional-commit`

Generates properly formatted conventional commits.

**Say:** "create a conventional commit", "generate commit", "commit with conventional format",
"group my changes for commits", "semantic commits".

**What it does:**

1. Analyzes staged and unstaged changes.
2. Groups related changes by purpose, type and scope.
3. Asks you for a commit strategy — separate, combined, or a single commit.
4. Writes messages that follow the Conventional Commits specification, including breaking-change
   markers, issue references and co-authors.
5. Stages and commits, handling pre-commit hooks and large changesets.

**Supporting files:**

- `references/conventional-commits-spec.md` — the full specification
- `references/commit-patterns.md` — patterns, anti-patterns and best practices
- `examples/commit-messages.txt`, `examples/multi-commit-workflow.sh`
- `scripts/group-changes.py`, `scripts/validate-commit-msg.sh`

### `software:daily-handoff`

Writes an end-of-day handoff a teammate can read without asking follow-up questions.

**Say:** "daily handoff", "write my handoff", "end of day summary", "EOD report", "what did I
work on today", "standup notes".

**Arguments (all optional):** `hours` (default 24), `scan-root` (default `~/Projects`), `output`
(default `~/YYYY-MM-DD-handoff.md`).

**What it gathers, for the last 24 hours:**

- Pull requests you authored — merged, open, and closed without merging — with their diffs,
  review state, requested reviewers and check results.
- Every comment you left on a pull request or issue, including inline code-review comments.
- Claude Code, Codex CLI and OpenCode sessions, reduced to the prompts you actually typed.
- Local checkouts carrying uncommitted changes, unpushed commits or stashes — including agent
  worktrees under `.claude/worktrees/`, which are the easiest work to lose.

**How it sorts:**

| Bucket | What lands there |
|--------|------------------|
| **Done (Merged)** | Pull requests merged inside the window |
| **Ready for Merging** | Open non-draft PRs, and finished branches with no PR yet |
| **In Progress (Uncommitted)** | Uncommitted changes, stashes, draft PRs, sessions that produced nothing |
| **What's Next** | Follow-ups, unanswered review feedback, failing checks, dropped PRs |

**How it writes:** plain language, aimed at a teammate who does not know the codebase. General
information is summarized in one to three sentences; anything waiting on another person is
detailed — what is waiting, who on, what exactly they need to do, why it matters, how urgent.

**Supporting files:**

- `scripts/collect-github.sh` — PRs and comments via the `gh` CLI
- `scripts/collect-repos.sh` — uncommitted changes, unpushed commits, stashes (read-only)
- `scripts/collect-sessions.py` — Claude Code / Codex / OpenCode session transcripts
- `references/handoff-template.md` — the document structure
- `references/plain-language.md` — how to say technical things without technical words

Missing tooling degrades the document rather than stopping it: if `gh` is not signed in, the
handoff still covers local work and says the GitHub half is missing.

### `software:split-plan`

Takes a master plan file and produces 8 phase-specific plan files.

**Arguments:** `master-plan-path` (required), `base-name` (required — derived from the master plan
filename).

**Output:** `tasks/{base-name}/plans/{base-name}-{NN}-{phase}.md` — zero-padded `01`–`08`, lowercase
phase names (`foundational`, `models`, `services`, `data`, `rules`, `state-management`, `ui`,
`tests`). All 8 files are written even when a phase has no tasks; empty phases get a stub so the
sequence stays readable.

Each file groups its tasks by track, carries complexity scores, dependencies, implementation
guidance and acceptance criteria.

### `software:categorize-task`

The reference the other two lean on: for each of the 8 phases, what belongs in it, what does not,
and how to resolve the ambiguous cases.

---

## Best practices

### Writing a master plan

`split-plan` works from what you give it. A plan with clear feature groupings splits cleanly; a
wall of undifferentiated tasks does not.

```markdown
# Project Requirements

## Overview
Brief description of the project

## Features

### Feature 1: User Authentication
- User can sign up with email/password
- User can log in
- Sessions are maintained
- Passwords are securely hashed

### Feature 2: Product Catalog
- Display list of products
- Filter by category
- Search by name
- View product details

## Technical Requirements
- Use JWT for authentication
- RESTful API architecture
- PostgreSQL database
- React frontend
```

### Review the split before you build

The classification is a judgment call, not a fact. After a split, check that the tracks match how
you actually think about the features, that tasks landed in the right phase, and that the
complexity scores are honest. Fixing a plan is cheap; fixing code built from a wrong plan is not.

---

## Where the orchestration went

If you want the workflow this plugin used to run — requirements interviews, planning, dispatching
developers, review rounds, gates — install the [Guild plugin](../guild) instead. It does the same
job against a persistent SQLite board, so work survives across sessions.

The two compose: guild for the work cycle, `software:conventional-commit` for the commits it
produces.

---

## File structure

```
plugins/software-project/
├── .claude-plugin/
│   └── plugin.json                          # Plugin manifest
├── skills/
│   ├── conventional-commit/
│   │   ├── SKILL.md
│   │   ├── references/
│   │   │   ├── conventional-commits-spec.md
│   │   │   └── commit-patterns.md
│   │   ├── examples/
│   │   │   ├── commit-messages.txt
│   │   │   └── multi-commit-workflow.sh
│   │   └── scripts/
│   │       ├── group-changes.py
│   │       └── validate-commit-msg.sh
│   ├── daily-handoff/
│   │   ├── SKILL.md
│   │   ├── references/
│   │   │   ├── handoff-template.md
│   │   │   └── plain-language.md
│   │   └── scripts/
│   │       ├── collect-github.sh
│   │       ├── collect-repos.sh
│   │       └── collect-sessions.py
│   ├── split-plan/
│   │   └── SKILL.md
│   └── categorize-task/
│       └── SKILL.md
├── .gitignore
├── CHANGELOG.md
├── LICENSE
└── README.md
```

---

## Requirements

- **Claude Code**: latest version
- **Plan format**: markdown, with features described as headed sections
- `git` on `PATH` for `conventional-commit` and `daily-handoff`
- For `daily-handoff`: `jq`, `python3` 3.9+, and an authenticated `gh` (`gh auth status`) for the
  GitHub half

---

## License

MIT — see [LICENSE](LICENSE).

## Author

**Gian Patrick Quintana** — <gian.quintana@hirokata.dev> — [@HirogaKatageri](https://github.com/HirogaKatageri)
