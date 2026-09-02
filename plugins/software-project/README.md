# Software Plugin

Three focused skills for planning and committing software work: an 8-phase clean architecture
vocabulary for classifying tasks, a planner that splits a master plan into per-phase plan files,
and a conventional-commit generator.

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
- `git` on `PATH` for `conventional-commit`

---

## License

MIT — see [LICENSE](LICENSE).

## Author

**Gian Patrick Quintana** — <gian.quintana@hirokata.dev> — [@HirogaKatageri](https://github.com/HirogaKatageri)
