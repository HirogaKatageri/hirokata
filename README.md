# HiroKata Claude Code Plugin Marketplace

A curated collection of Claude Code plugins for enhanced development workflows. **Version 6.0.0** — [View Changelog](CHANGELOG.md)

| Plugin | Version | What it is |
|--------|---------|------------|
| [**guild**](plugins/guild) | 7.0.0 | Continuous agent orchestration on a SQLite board whose rules live in the schema |
| [**software**](plugins/software-project) | 1.0.5 | Task classification by clean-architecture phase, plan splitting, conventional commits |
| [**research**](plugins/research) | 1.0.0 | Multi-perspective deep research, after Stanford's STORM method |
| [**storytelling**](plugins/storytelling) | 1.0.0 | Six storytelling frameworks for making a message land |

---

## Installation

There are two ways to install plugins from this marketplace: using Claude Code's built-in marketplace system (recommended), or cloning the repository and copying plugins manually.

### 1.a. Install Using the Claude Code Marketplace

This is the official method. Claude Code's marketplace system handles discovery, installation, and future updates automatically.

**Step 1 — Add the marketplace**

Run this inside a Claude Code session or from the CLI:

```bash
# Inside Claude Code
/plugin marketplace add HirogaKatageri/hirokata

# Or from the terminal
claude plugin marketplace add HirogaKatageri/hirokata
```

**Step 2 — Install plugins**

Once the marketplace is added, install individual plugins by name. The marketplace identifier is `hirokata`.

```bash
# Install the Guild plugin
/plugin install guild@hirokata

# Install the Software plugin
/plugin install software@hirokata
```

**Step 3 — Keep plugins up to date**

Pull the latest versions at any time:

```bash
/plugin marketplace update hirokata
```

> **For teams:** Add the marketplace at project scope so it is shared automatically via `.claude/settings.json`:
> ```bash
> claude plugin marketplace add HirogaKatageri/hirokata --scope project
> ```

### 1.b. Installing From a Local Clone

For offline environments, or when you want to modify a plugin before using it, clone the repo and point Claude Code at your copy. The clone is itself a marketplace — `.claude-plugin/marketplace.json` is at its root — so the same install flow works against a path.

**Step 1 — Clone the marketplace**

```bash
git clone https://github.com/HirogaKatageri/hirokata.git
```

**Step 2 — Add the clone as a marketplace and install from it**

```bash
# Inside Claude Code
/plugin marketplace add ./hirokata
/plugin install guild@hirokata

# Or from the terminal
claude plugin marketplace add ./hirokata
claude plugin install guild@hirokata
```

Add `--scope project` to the `marketplace add` if you want the path recorded in the project's `.claude/settings.json` so teammates pick it up — in which case use a path everyone will have, or keep the GitHub form from 1.a instead.

Edits you make in the clone reach your sessions the same way an upstream change does: re-run `/plugin marketplace update hirokata`.

**Verify the plugins loaded** by trying a trigger phrase after starting Claude Code:

```
guild status
```

> **Guild prerequisite:** the guild board is a local Turso database, and `tursodb` is the tool the guild uses to reach it — there is no guild CLI. No account, token or network is required. Install it and put it on `PATH`:
>
> ```bash
> brew install tursodatabase/tap/turso   # or: curl -sSfL https://get.tur.so/install.sh | bash
> export PATH="$HOME/.turso:$PATH"
> ```

---

## How to Use the Guild Plugin

The Guild plugin (v7.0.0) provides continuous agent orchestration through a persistent, database-backed work cycle. The guild tracks direction, requirements, tasks, bugs and quality coverage across sessions — no per-session setup required.

**The plugin is a schema and a set of skills — not a program.** `tursodb` already executes SQL, so the guild ships no second tool that does the same thing: members write their own SQL, and the guild's rules live *in the database* as CHECK constraints (the status vocabularies), views (the derived rules — the cursor, the review gate, readiness, the board, each with one definition) and triggers (the `event` record, written on every mutation). A member can forget to call a command; a member cannot bypass a trigger or a CHECK.

**The one thing deliberately *not* in the database is the roster.** Who the guild's members are and what each can do is the `capabilities:` frontmatter of the agent files, read at dispatch time across every subagent available to you — this plugin's, your project's `.claude/agents/`, your `~/.claude/agents/`, and every other installed plugin's. A ticket names the capability it needs; adding an agent file that declares it is the whole of hiring, with nothing to sync.

```
guild:new-requirement — live 3-way interview (product-owner + architect + you)
    → developers / developer-svelte (parallel waves, disjoint files)
    → test-planner → test-writer (unit & integration)
    → 4 reviewers in parallel → a review report you act on
```

**The v6/v7 line is a fresh rewrite, and its status is worth reading before you trust it.** The v5 CLI it replaced had four adversarial review rounds and a 2,278-check suite; that code is deleted and none of that assurance carries over. It ships with no tests, by design. See the *Status* section in `plugins/guild/README.md`.

**Upgrading an existing board?** `CREATE TABLE IF NOT EXISTS` cannot rename or drop a table, so a live `.guild/guild.db` needs the migrations run once each, in order, with `schema.sql` re-applied at the end. Check `SELECT version FROM schema_version` first and run only the ones above it:

```bash
export PATH="$HOME/.turso:$PATH"
cp .guild/guild.db .guild/guild.db.bak
tursodb .guild/guild.db < plugins/guild/migrations/006-project-and-plan-approval.sql   # 5 → 6
tursodb .guild/guild.db < plugins/guild/migrations/007-roster-leaves-the-database.sql  # 6 → 7
tursodb .guild/guild.db < plugins/guild/schema.sql
```

- **006** (v6.2) renames `phase` to `project` and splits `plan.status` from `plan.approval`.
- **007** (v7.0) drops the `agent`, `agent_capability` and `capability_request` tables — the roster moved to the agent files.

Neither is idempotent, and each fails safely on a second run. A fresh board needs none of this.

### Setting Up

The guild requires no manual initialization. On your first check-in it creates a `.guild/` directory in your project:

```
.guild/
├── config.yaml       # committed — storage mode; env var NAMES only, never a credential
├── guild.db          # gitignored — THE BOARD
├── docs/  qa/        # evergreen knowledge base and QA artifacts
├── reviews/          # per-requirement review reports
└── dashboard.html    # gitignored — regenerated wholesale
```

The board is a **database**: there is no `BOARD.md`, no ticket file, no `state.yaml` and no status directory — an artifact's status is a **column**, and the "board" is a live view rendered from SQL. Local mode needs no account, token or network; it does need the `tursodb` binary. Cloud mode is unverified end to end.

**There is no journal, so `guild.db` is not disposable.** `event` rows written by triggers are the record, and they live in the same database as everything else. What git carries is the human-readable residue: `config.yaml`, `docs/`, `qa/`, `reviews/` and the repo's own `CHANGELOG.md`. Back the file up before clearing the board — a `DELETE` is final.

Open a Claude Code session in your project and say:

```
check in
```

The guild will greet you, create the board, and ask what you want to work on.

> **Upgrading from a v4 guild?** The check-in offers to **move** the old directory board to `.guild/v4-archive/` — never deletes, never parses — and there is no history import. `.guild/docs/` and `.guild/qa/` carry over because they are evergreen. Unfinished v4 work is re-entered through `new requirement`, reading the archived plan.

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

`guild:new-requirement` runs a **live 3-way interview**: the `product-owner` and the `architect` are spawned directly (not queued as tickets), both relay their questions through the orchestrator, and by the time the skill returns the requirement, the implementation plan and every developer / test-planner / reviewer ticket already exist on the board. You do not write the requirement document manually.

Between the two, the guild offers to place the requirement on a **project** — an existing one, a new project, a new goal *and* its first project, or left unaffiliated. A project can be marked `concurrent` (it runs beside its siblings instead of waiting its turn) and can be cut into its own git worktree. Direction is yours to set: no agent creates a goal or a project on its own.

> `project` was called `phase` through guild v6.1. If you see `PHASE-NNN` anywhere, that board predates the rename — run the migrations above.

> Multiple requirements can be queued. Each is fully planned at the moment it is filed, so the board only ever holds work that is ready to run.

### Checking In

**Checking in** resumes the guild exactly where it left off. Run it at the start of each session:

```
check in
```

It opens with the **brief** — direction, what is in flight and for how long, open bugs, quality areas due for inspection, what moved since last time, and what `v_next_task` says goes out next:

```
Guild Brief
===========

Generated: 2026-08-14T02:59:04Z
Since:     2026-08-13 (last check-in)
Next:      TASK-004
Summary:   2 requirement(s), 0 done · 1 in flight · 2 open bounty(ies) · 1 open bug(s) (1 critical)

Direction:
  GOAL-001  [p1 in-progress]  Ship the notifications overhaul  ·  2 of 3 projects runnable
            PROJ-002 Preferences UI (next in sequence)  ·  PROJ-003 Docs refresh (concurrent, worktree)  ·  0/2 req done

In Flight:
  TASK-004  Build the preferences API  ·  developer  ·  REQ-002  ·  just now

Bugs:
  BUG-001  critical  open  Preference toggles silently revert after save  ·  found by qa-tester
```

A section with nothing in it is not printed — an absent section is good news stated by its absence.

A **work-intent** phrase ("let's get to work", "start working", "continue") resumes immediately with zero routing questions. An ambiguous one ("check in", "standup", "I'm here") asks once: continue working / new requirement / review completed work / adjust the backlog.

From there the work cycle **flows continuously** — one-line updates between tickets, pausing only on a failure, an escalation, or a completed requirement:

```
TASK-003 done: Implement auth service → 2 follow-ups created
TASK-005 done: Implement login endpoint → 1 follow-up created
```

Development runs in **parallel waves** by default: the architect groups dev tickets whose file sets it has verified disjoint, and the orchestrator dispatches each wave concurrently in the shared working tree.

### Reading the board without starting work

```
guild status          # → the guild:brief skill; narrates the same brief, read-only
show me the dashboard # → .guild/dashboard.html: six views, offline, no server
```

The dashboard is one self-contained file — all CSS and JS inline, deterministic bytes — with Roadmap, Board, Graph, Bugs, Coverage and Activity views.

### Skills Reference

| Skill | What it does | Trigger Phrases |
|-------|-------------|----------------|
| `guild:check-in` | Start or resume a work session, open with the brief, drive the work cycle | "check in", "clock in", "let's get to work", "I'm here" |
| `guild:shift` | `check-in` with you taken out of the middle — runs unattended to the next gate, then stops and says why. Never decides a gate | "work a shift", "run unattended" |
| `guild:brief` | The narrated read of the board — direction, in flight, bugs, what moved, what's next. Read-only | "guild status", "what's the status", "show the board", "where are we", "what changed" |
| `guild:dashboard` | Build and open `.guild/dashboard.html` — six views, offline, self-contained | "the dashboard", "show the roadmap", "visualize the board", "the activity feed" |
| `guild:new-requirement` | Live 3-way interview (product-owner + architect + you) that leaves a planned, ticketed requirement on the board | "new requirement", "I need a feature", "I want to build" |
| `guild:qa` | Seed the independent QA discipline — risk-mapped coverage, e2e regression specs, bugs filed as rows | "QA the product", "run a QA pass", "build comprehensive e2e tests" |
| `guild:comprehensive-review` | Run all 4 reviewers in parallel against recent changes | "review my changes", "run comprehensive review", "check all my code" |
| `guild:clear-board` | Deletes every unit of work, keeping what outlives a board — there is no journal to replay, so a `DELETE` is final | "clear the board", "reset the guild", "start fresh" |
| `guild:create-workflow` | Interactively design and generate automation workflows (GitHub Actions, scripts, Makefiles) | "create a workflow", "generate a workflow", "add a GitHub Actions workflow", "set up automation" |
| `guild:discuss` | Summarize conversation context and facilitate focused topic discussions | "discuss", "let's discuss", "discuss [topic]", "summarize the context", "what are we working on" |
| `guild:release` | Stamp CHANGELOG, snapshot completed requirements from the export, create git tag | "cut a release", "ship it", "tag a version" |
| `guild:verify-and-fix` | Diagnose an error end-to-end and apply a test-driven fix | "check this error", "I have a bug", "debug this", "this is broken" |
| `guild:validate` | Run `docs/expectations.md` against the live board — nine global invariants, or one process's postconditions. Read-only | "validate the guild", "check the board is coherent" |
| `guild:warehouse` | The reference every guild member loads before touching board data — the connection recipe, the six rules, and the canonical queries | loaded by agents, not typed |
| `guild:guild-status` | Deprecated alias for `guild:brief`; claims no trigger phrases | typed `/guild:guild-status` only |

Agent-facing skills that specialists pre-load rather than users invoking: `guild:qa-mindset`, `guild:qa-artifacts`, the four `guild:svelte-*` reference skills, and `guild:svelte-env-vars-check`.

### Agents

| Agent | Role |
|-------|------|
| `guild:product-owner` | Interviews the user live, writes the requirement record |
| `guild:architect` | Reads the REQ, explores the codebase, writes the PLAN, creates every downstream ticket |
| `guild:developer` | Implements code per plan and requirement |
| `guild:developer-svelte` | Svelte 5 / SvelteKit specialist — used when tasks touch `.svelte`, `+page.*`, `+layout.*`, `+server.*` files |
| `guild:test-planner` | Inventories the implemented diff and writes the test plan |
| `guild:test-writer` | Implements the test plan — unit and integration tests |
| `guild:qa-strategist` | Maps product risk into `coverage` rows and declares QA missions |
| `guild:qa-tester` | Runs the real app, authors e2e specs, files defects as `bug` rows |
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

### Research Plugin (v1.0.0)

PhD-level, multi-perspective research inspired by Stanford's **STORM** method. Instead of the majority view a single prompt returns, it analyzes a topic from five independent expert lenses, maps where they disagree, synthesizes a cited briefing, and red-teams its own output — each phase delegated to a dedicated sub-agent so the heavy reading stays off your main context window.

**How it works:**

1. Say `storm research <topic>` to run the full pipeline
2. Phase 1 fans out five persona agents in parallel (practitioner, skeptic, economist, historian, academic)
3. Phase 2 maps their contradictions, agreements, and blind spots
4. Phase 3 synthesizes a cited research briefing with reliability ratings
5. Phase 4 peer-reviews the briefing and assigns a reliability grade
6. All artifacts land in a reusable `.storm/{topic-slug}/` workspace (gitignored)

**Skills:**

| Skill | What it does | Trigger Phrases |
|-------|-------------|----------------|
| `research:storm-research` | Runs the full four-phase STORM pipeline end-to-end | "storm research <topic>", "run STORM on <topic>", "deep research <topic>", "research <topic> from every angle" |
| `research:multi-perspective-scan` | STORM Phase 1 standalone — fast five-lens read of a topic | "5 perspectives on <topic>", "multi-perspective scan", "analyze <topic> from multiple angles" |
| `research:contradiction-map` | STORM Phase 2 standalone — maps disagreements, agreements, and blind spots | "contradiction map", "where do these disagree", "map the conflicts" |
| `research:research-peer-review` | STORM Phase 4 standalone — audits any research artifact, assigns a reliability grade | "peer review this", "red team this report", "audit my research" |

**Agents:**

| Agent | Role |
|-------|------|
| `research:practitioner` | The theory–practice gap; what actually works in the field |
| `research:skeptic` | Overclaims, hidden flaws, the buried failure cases |
| `research:economist` | Who profits, who pays, the misaligned incentives |
| `research:historian` | The pattern that repeated before; where we are in the cycle |
| `research:academic` | What the evidence actually shows, including conflicting findings |
| `research:contradiction-mapper` | Maps contradictions (with verdicts), the reliable core, and blind spots |
| `research:synthesizer` | Weaves all lenses into one cited briefing with reliability ratings |
| `research:peer-reviewer` | Adversarial audit: hallucination, bias, completeness, fairness, actionability |

[View Research Plugin Documentation](plugins/research/README.md)

---

### Storytelling Plugin (v1.0.0)

Turn any idea, pitch, update, or decision into a message that **lands** — using six proven storytelling frameworks. Most communication fails because it's delivered in the wrong shape: a board wants the answer first, a team wants a reason to care, a customer wants to be the hero. The plugin diagnoses the situation, picks the framework that fits, drafts the message in it, and — when the framing is uncertain — drafts it several ways in parallel so you can pick the version that lands. Inspired by Eric Partaker's rundown of six CEO storytelling frameworks.

**How it works:**

1. Say `help me tell the story of <X>` (or invoke a framework skill directly)
2. It captures your message, audience, desired outcome, and medium
3. It recommends the framework that fits the job and drafts the message
4. **Panel mode:** when the frame is uncertain, it drafts 2–3 frameworks in parallel via the `story-drafter` agent for side-by-side comparison
5. **Sharpening:** for high-stakes messages, the `story-critic` agent scores and tightens the draft

**Skills:**

| Skill | What it does | Trigger Phrases |
|-------|-------------|----------------|
| `storytelling:storytelling` | Diagnoses audience/goal, recommends a framework, drafts the message (single or panel mode) | "help me tell the story of <X>", "how should I pitch <X>", "make this message land", "which storytelling framework fits <X>" |
| `storytelling:golden-circle` | Simon Sinek's Why → How → What — for vision and rallying | "golden circle", "start with why", "frame our mission" |
| `storytelling:pyramid-principle` | Minto's answer-first, MECE-supported structure — for decision-makers | "pyramid principle", "bottom line up front", "structure this exec summary" |
| `storytelling:pixar-pitch` | Emma Coats' story spine — for transformation & journey narratives | "pixar pitch", "tell this as a journey", "before and after story" |
| `storytelling:storybrand` | Donald Miller's SB7 (customer as hero) — for marketing & sales | "storybrand", "make the customer the hero", "write a landing page" |
| `storytelling:what-so-what-now-what` | Fact → impact → action — for post-mortems & status | "what so what now what", "structure this post-mortem", "help me debrief" |
| `storytelling:abt` | And, But, Therefore — for elevator pitches & one-liners | "abt", "elevator pitch", "make this punchy", "give me a hook" |

**Agents:**

| Agent | Role |
|-------|------|
| `storytelling:story-drafter` | Drafts a message in one framework; spawned in parallel for panel-mode comparison (Sonnet) |
| `storytelling:story-critic` | Audits a draft against its framework and audience, scores it, returns a tightened rewrite (Opus) |

[View Storytelling Plugin Documentation](plugins/storytelling/README.md)

---

## License

MIT License — see [LICENSE](LICENSE) for details.

Copyright (c) 2026 Gian Patrick Quintana

## Author

**Gian Patrick Quintana**
- Email: gian.quintana@hirokata.dev
- GitHub: [@hirogakatageri](https://github.com/hirogakatageri)
