# Changelog

All notable changes to the HiroKata Claude Code Plugin Marketplace will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed
- **Project Management Plugin** — removed `plugins/project-management` and its marketplace/README entries
- **Session Tracker Plugin** — removed `plugins/session-tracker` and its marketplace/README entries

### Changed
- **Guild Plugin v5.0.0-beta — Turso storage and the visibility layer (BREAKING)** — Stages 1 and 2 of the five-stage v5 design (`plugins/guild/docs/v5-design.md`). Stages 3–5 (the capability roster, the execution graph and gates, the unattended shift) are **not** shipped; their tables exist in `schema.sql` so no stage needs a migration, and the surfaces that read them render as empty sections rather than as errors.
  - **The board is a database, not a directory tree (Stage 1).** `.guild/guild.db` — a Turso/SQLite database — replaces the `{todo,in-progress,done,failed}/` ticket directories, `state.yaml` and every ticket file. **Status is a column**, written only by `guild move`; IDs are derived in SQL (`MAX(n) + 1` in the same statement as the insert, so two creates cannot collide) and the cursor is derived (the current task is whatever row is `in-progress`). `last-checkin` is a row in `guild_state`. The CLI's read surface is deliberately unchanged — same names, same arguments, same stdout — only the source of the bytes changed.
  - **Storage runs in local mode; cloud mode is refused, on purpose.** `guild init` defaults to a local `tursodb` database needing no account, token or network, and prints the install line rather than failing with "command not found". `guild init --mode cloud` exits with an explanation: the cloud driver has no machine-readable output flag (every parser assumes `tursodb -q -m list`), its FK preamble differs, and its URL would travel in argv. `config.yaml` stores the **names** of environment variables and never a credential, enforced before any file is written.
  - **Durability is two committed artifacts.** `journal.ndjson` is an append-only log of the *resulting row state* per mutation (a change log replays across CLI versions; a command log does not) — `guild rebuild` replays it into a fresh database, `guild journal compact` refuses to lose a row unless forced, `guild journal recover` folds quarantined lines back in, and `guild journal sync` reconciles the append-only record tables. A `journal_preflight` runs *before* the SQL in every mutating command, so an unwritable or conflict-marked journal is a refusal that says nothing was written. `guild export` regenerates one deterministic markdown file per requirement as the PR-reviewable snapshot; it is **output only**.
  - **`guild path` is REMOVED (breaking for any custom automation).** It named a file agents used to Edit, and v5 has no such file — it exits 1 naming its replacements. `new`, `move` and `next` print the **bare ID** instead of `<ID> <path>`. Read with `read` / `meta` / `slice`; write with `move` / `retitle` / `checkin` / `new`. `guild migrate` and the pre-3.0 flat-file format are retired.
  - **Agents write through a spool, not a document.** In local mode every CLI invocation is its own process, so concurrent agents cannot share a connection: `guild log` and `guild finding` append one NDJSON line to `.guild/spool/<TASK-ID>.ndjson`, and the orchestrator folds them in as the single writer with `guild spool drain`. A line that cannot be imported is copied to `.guild/spool/rejected/` (committed — it is the only surviving copy) and reported before the spool is unlinked. **Draining is not optional**: an undrained ticket renders an empty Work Log, which check-in's triage reads as never-started.
  - **Direction above the board (Stage 2).** New `goal` and `phase` layers — `guild goal new|list|show|move|priority`, `guild phase new|list|move`, `guild req assign REQ-NNN <PHASE-NNN|none>`. A goal is long-lived intent with a priority; a phase is an ordered stage of one goal, its ordinal derived as `MAX+1` when omitted. `requirement.phase_id` is nullable by design — unaffiliated work stays legal — and goals and phases **organize but do not gate**. `guild:new-requirement` now offers a placement (existing phase / new phase / new goal + phase / unaffiliated) once, and only the user's answer creates one.
  - **Bugs and coverage are rows, not prose.** `guild bug new|list|show|fix|close` (`--req` optional, because defects are found outside a requirement's scope all the time; `wontfix` is a real outcome, not a lesser `fixed`) and `guild coverage set|inspect|list|show`. `qa-tester` files defects with `guild bug new` instead of appending to `.guild/qa/ledger.md`, and stamps the areas it actually drove with `guild coverage inspect`; `qa-strategist` writes one `coverage` row per quality area. `coverage set` is an upsert that never touches the inspection clock, and `coverage list --due` is `guild brief`'s own predicate — never inspected, or stale past a risk-weighted threshold (high 14 days, medium 30, low 90).
  - **Two new read surfaces, and a new skill for each.** `guild brief` / **`guild:brief`** — one query behind Direction, In Flight, Blocked, Open Bounties, Bugs, Coverage, Since Last Check-in and Roster Gaps, with a `Next:` header byte-identical to `guild next`; empty sections are omitted and an empty guild gets three next steps rather than eight `(none)` blocks. `guild dashboard` / **`guild:dashboard`** — a self-contained `.guild/dashboard.html` with six views (Roadmap, Board, Graph, Bugs, Coverage, Activity), all CSS and JS inline, deterministic bytes, no server and no network. Both are strictly read-only: rendering the board is not a change to it, so neither writes a journal line or an `event` row. `guild:check-in` now opens with the brief.
  - **`guild:guild-status` is a deprecated alias** that loads `guild:brief`. It deliberately claims **no** natural-language trigger phrases — two skills advertising "guild status" would make every status request a coin flip — and exists only so the typed `/guild:guild-status` keeps working.
  - **`guild:clear-board` now refuses instead of pretending.** v5 ships no `guild clear` and no `guild delete`, so the skill inventories the board, says plainly that nothing was changed, and offers the real alternatives (leave it, waive open work to `failed`, or `GUILD_DIR=.guild-next guild init`). **`guild:release` copies rather than moves**: it snapshots the export into `.guild/releases/{version}/` and leaves the requirements on the board, because v5 has no archive command and a file-moving step would report work it did not do.
  - **Every mutation is journaled and writes an `event` row**, which is what makes the brief's "Since Last Check-in" and the dashboard's Activity feed possible. Free text travels into SQL as hex (`CAST(x'…' AS TEXT)`) because tursodb's script splitter ends a statement at a `;` that terminates a line even inside an open string literal, and on the way out it can never impersonate a structural token — the board flattens it, the export uses a length-prefixed header, JSON goes through `json_object()`, and the dashboard escapes every `<` before it reaches the page. Two live injections (a fabricated board row, a phantom export file) were fixed at the source, per surface.
  - **Migration: v4 boards are ARCHIVED, not migrated.** `guild init` on a directory holding a v4 board **moves the whole tree to `.guild/v4-archive/`** — never deletes, never parses — and there is **no history import**. Two things carry over because they are evergreen rather than historical: `.guild/docs/*.md` into the `doc` table, and `.guild/qa/` into the `coverage` table (with `last_inspected_at` left null, so every area reads as due on day one). Unfinished v4 work is re-entered by hand through `guild:new-requirement`, reading the archived plan for the details. Nothing is lost: the archive stays plain markdown, in git.
  - Documentation caught up with the code: the plugin README, `scripts/README.md` and the check-in references now describe the database model, the two storage modes, the durability contract and the new commands — and state plainly which stages are not built yet. The guild plugin is **`5.0.0-beta`** (Stages 1–2 of 5), and the marketplace is `4.1.0`.
- **Guild Plugin v4.0.0 — Live requirement planning, human-gated review (BREAKING)**
  - **Requirements and planning move out of the ticket board entirely.** `guild:new-requirement` now spawns the product-owner and architect directly (not as ticket types) for a live 3-way interview with the user — both relay questions through the orchestrator (`AskUserQuestion` is still main-session-only), and the architect creates every developer/test-planner/reviewer ticket directly via the CLI before the skill returns. `check-in` no longer dispatches `product-owner` or `architect` tickets; an empty board now prompts instead of auto-invoking `new-requirement`.
  - **`product-owner` and `architect` gain the `Agent` tool** and can spawn `guild:researcher` (Haiku) inline for quick lookups and codebase checks — the old two-ticket async research-gate handoff is gone; the architect just calls the researcher mid-session and keeps planning.
  - **Optional Agent Teams integration.** When `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` is enabled, the product-owner and architect message each other directly during the interview; otherwise the orchestrator moderates between two concurrently-spawned sessions. Both paths still relay user-facing questions the same way.
  - **The automatic review fix-loop is gone.** The 4 reviewers now only write findings (no more `Fix:` follow-ups, no round cap, no `ESCALATE` token) — the orchestrator compiles every round into `.guild/reviews/REQ-NNN.md` and asks the user (multi-select) which findings, if any, become fix tickets. Approved fixes are plain `developer` tickets with no forced test-writer/re-review tail, and there is no automatic re-review; another pass is just a fresh `reviewer` ticket like any other.
  - Developers/`developer-svelte` now relay unclear-requirement questions directly (`NEEDS INPUT`) instead of declaring a `Clarify: … | agent: product-owner` follow-up, since `product-owner` is no longer ticket-dispatched. `.guild/reviews/` archives alongside its requirement at release time (evergreen `.guild/docs/`/`.guild/qa/` are unaffected).
- **Guild Plugin v3.2.0 — Crash-safe resume, execution hardening, leaner token budget** (27 adversarially-verified audit findings fixed)
  - **"Continue where we left off" hardened end to end.** Follow-ups are now materialized *before* a ticket's terminal `guild move done` and each created line is annotated ` → TASK-NNN` (idempotent re-processing) — a crash can no longer strand a requirement with un-created chain tickets. Check-in stale triage is now three-case: empty Work Log → re-queue; completion/failure recorded in the log → record the outcome without re-dispatching the agent; otherwise resume with a new RESUMED-TASK dispatch variant. All worker agents now log a start entry + milestones (an interrupted agent is no longer indistinguishable from a never-started one), the product-owner persists interview answers into the REQ draft as it goes, and the architect logs its scaffolded PLAN-NNN immediately so a rerun resumes instead of orphaning a duplicate plan. A work-intent trigger ("let's get to work") resumes with zero routing questions.
  - **Execution correctness.** The orchestrator's follow-up materialization now parses/passes `parallel-group` (previously silently dropped — dev waves degraded to sequential) and a new `plan:` modifier emitted by the architect (previously the plan ID never propagated, leaving `plan-slice` unresolvable downstream). `guild list task` output gained `<agent> <requirement>` columns so the review-round cap and requirement-completion checks are actually executable via awk. `failed/` is now defined as user-adjudicated (waived): it doesn't block review or completion, and waived tickets are reported in the summary + CHANGELOG bullet. The QA bug loop now files each bug as a Fix + Re-verify qa-tester pair (previously nobody created the re-verify and QA fixes ran with no verification tail). All CLI `for $(ls …)` loops replaced with quote-safe globs — the board/cursor no longer break for repo paths containing spaces.
  - **Token efficiency.** The check-in skill no longer force-reads all three reference docs per session (~7k tokens, ~80% duplicated) — references are now load-on-demand with explicit triggers. New `guild meta <ID> [field]` prints frontmatter only; dispatch uses it instead of full `guild read`. The dispatch prompt dropped its "When done" boilerplate (duplicated in every agent definition). Developers read the REQ only when their self-contained slice doesn't cover it, and no longer re-read CLAUDE.md. The dead `priority:` follow-up modifier (emitted ~30×, consumed by nothing) was removed everywhere; "Adjust priorities" became an honest "Adjust the backlog" (retitle/drop; ordering is ID order). The redundant wrap-up `last-checkin` write was dropped.
  - **Consistency.** `scripts/README.md` caught up with the CLI (`batch`, `meta`, `is-legacy`, `migrate`, `--parallel-group`, list columns) and its example no longer clobbers `$PATH`; the release skill's pre-release gate now treats waived (`failed/`) tasks as warn-and-confirm instead of a hard block (only unresolved ESCALATE blocks) and uses the new list columns; the comprehensive-review skill and product-reviewer agent are now guild-board-aware and no longer hardcode another plugin's 8-phase methodology; architect's dangling "Step 4.5" reference fixed; task-lifecycle's orchestrator-procedure section reduced to a pointer at the canonical SKILL.md Step 3.4. A second adversarial verification pass (3 lenses) confirmed the edit set and closed 11 residual gaps it found (QA agents' resume protocol, full-pipeline recovery in stale triage, create→annotate duplicate guard, architect orphan-plan fallback).
- **Guild Plugin v3.1.0 — Pipeline refinement: parallel-by-default development, dedicated test planning, integration tests, diff-scoped reviews**
  - The per-requirement pipeline is now: requirements discussion & refinement (product-owner) → architecture & planning (architect) → **parallel development** (developer waves) → **test planning** (new `test-planner` agent) → **unit & integration test writing** (test-writer) → review (4 parallel reviewers) → done.
  - **Parallel development is the default, not the escape hatch.** The architect designs plan slices for disjoint file sets and organizes dev tickets into `parallel-group` waves (foundation solo first, then concurrent waves); ungrouped tickets are the exception, reserved for foundational or unboundable work. Mechanics are unchanged (`guild batch`, shared working tree, no worktrees) — only the planning posture flipped.
  - **New `guild:test-planner` agent** (Sonnet) runs after all dev work: inventories the implemented diff into a Changed Files Inventory, surveys the test infrastructure, maps acceptance criteria to unit and integration cases, writes the plan as `PLAN-NNN/slice-test-plan.md` (rides the existing slice mechanism — resolve with `guild slice PLAN-NNN test-plan`; zero CLI changes), and declares the test-writer ticket(s). The architect's tail is now `test-planner` + `reviewer`; the reviewer's N/N gate keeps the review last even though test-writer tickets get higher IDs.
  - **test-writer now owns unit AND integration tests**, implementing the test plan instead of re-deriving scope; it falls back to self-derived scope in the plan-less bug-fix flow. The QA discipline's `qa-tester` now owns e2e only.
  - **Token-efficiency:** the diff analysis happens once (test-planner) and is reused three times — the test-writer implements from it and all 4 reviewers scope their reading to its Changed Files Inventory instead of re-scanning the codebase; the check-in work cycle now flows continuously by default (one-line updates between tickets; pauses only on failure, escalation, collision, or requirement completion) instead of prompting after every ticket.
  - Fix loop unchanged (max 2 rounds), but the fix-loop test-writer ticket now carries `plan-slice: test-plan` when a plan exists; the test-planner is never re-run in the fix loop. Bug-fix flow (Chain 3) intentionally skips the test-planner.

### Added
- **Research Plugin v1.0.0** — PhD-level multi-perspective research inspired by Stanford's STORM method
  - `research:storm-research` — orchestrates the full four-phase pipeline: parallel five-persona fan-out, contradiction mapping, synthesis into a cited briefing, and an adversarial peer review with an optional revision loop; each phase delegated to a dedicated sub-agent to keep the main context lean
  - `research:multi-perspective-scan` — STORM Phase 1 standalone; fans out the five persona agents in parallel for a fast multi-angle read
  - `research:contradiction-map` — STORM Phase 2 standalone; maps disagreements (with verdicts), the reliable core of agreement, and blind spots across a workspace, documents, or pasted viewpoints
  - `research:research-peer-review` — STORM Phase 4 standalone; audits any research artifact for hallucinations, bias, completeness, fair contradiction handling, and actionability, then assigns a reliability grade
  - Five persona agents (`practitioner`, `skeptic`, `economist`, `historian`, `academic`), each with an owned worldview and owned bias, gathering cited web evidence; plus `contradiction-mapper`, `synthesizer` (Opus), and `peer-reviewer` (Opus) analytical agents
  - Runs write to a reusable, gitignored `.storm/{topic-slug}/` workspace

### Changed
- **Guild Plugin v2.0.0 — Board simplification (BREAKING)**
  - Removed `.guild/BOARD.md` entirely. Task status now lives solely in each `TASK-NNN.md` (`todo` → `in-progress` → `done` / `failed`); a new `.guild/state.yaml` holds only the cursor (`current`) and ID counters. The board is rendered as a live view by scanning ticket and requirement files — eliminating the dual-store reconciliation the orchestrator did every cycle.
  - Replaced the three-way sequencing logic (follow-up declarations + ID-arithmetic auto-triggers + magic `depends-on` tokens) with a single cursor that walks tickets in ID order. Removed the `depends-on` field, the `all-developer`/`TASK-RESEARCH` tokens, the `blocked` status, and parallel-developer batching.
  - **Development is now sequential** (one developer ticket at a time). Review remains per-requirement and gated on all implementation tickets being done, then fans out to the 4 reviewers in parallel — the only parallelism left.
  - The architect now emits the test-writer + reviewer **chain tail** as real tickets up front (product-owner emits it in the bug-fix flow); the orchestrator only creates tickets for the fix-loop tail. Fix loop is capped at 2 review rounds by counting reviewer tickets per requirement.
  - Renamed reference `board-format.md` → `state-format.md`. Updated `check-in`, `new-requirement`, `clear-board`, `guild-status`, and `release` skills plus the architect, product-owner, developer, and developer-svelte agents accordingly.
  - **Migration:** no automatic path — clearing the board (`/guild:clear-board`) is the upgrade. Returning check-ins on a pre-2.0 guild are offered an in-place convert or clear.
  - Marketplace bumped to v3.1.0 — the v3 major mirrors this Guild breaking change; the v3.1 minor adds the new Research Plugin.

### Planned
- Test Plugin: Automated test generation and execution
- Review Plugin: Code review assistance and suggestions
- Deploy Plugin: Deployment automation workflows
- Docs Plugin: Documentation generation from code
- Web-based marketplace browser
- Plugin dependency management
- Version compatibility checking

## [2.7.0] - 2026-06-04

### Added
- **Guild Plugin v1.7.0**
  - Added `guild:verify-and-fix` — diagnoses and fixes reported errors through a structured five-phase workflow: detect/create the project's error-verification guide, collect the error artifact, investigate configured log and code sources, propose ranked solutions, then apply a test-driven fix

## [2.6.1] - 2026-05-24

### Updated
- **Guild Plugin v1.6.1**
  - `guild:svelte-env-vars-check` — stricter server-side enforcement: server files importing from `$env/*/public` are now a hard violation (previously advisory); migration step 5.3 added to strip `PUBLIC_` prefix and rewrite imports to `$env/*/private`

## [2.6.0] - 2026-05-22

### Added
- **Guild Plugin v1.6.0**
  - Added `guild:svelte-env-vars-check` — audits SvelteKit environment variable usage for PUBLIC/PRIVATE pattern compliance and `process.env` violations; reports violations grouped into three categories (client-side using private, server-side not using private, `process.env` usage), optionally migrates to correct patterns with static/dynamic timing choice, and outputs an env var inventory table

## [2.5.0] - 2026-05-19

### Added
- **Session Tracker Plugin v1.1.0**
  - Added `session-tracker:end-session` — triggers on session-ending phrases; spawns the Haiku logger agent which queries committed and uncommitted git changes for the past 28 hours, synthesizes a summary, and appends it to `.logs/YYYY-MM-DD-log.md`
  - Added `session-tracker:daily-summary` — spawns the Haiku summarizer agent which finds all `.logs/YYYY-MM-DD-log.md` files across subdirectories, groups sessions by project, and writes a cross-project report to `.logs/YYYY-MM-DD-daily-summary.md`
  - Internal `query-changes` and `save-log` skills guide the logger agent's git querying and file write behavior

## [2.4.0] - 2026-05-14

### Updated
- **Guild Plugin v1.5.0**
  - Added `guild:discuss` — a context summarizer and discussion facilitator; in open mode it scans the conversation, groups subjects into a numbered topic map, and drives a focused discussion loop; in targeted mode (`discuss [topic]`) it scopes analysis to a single topic, presents a summary with key points and open questions, then enters the loop; wraps up with a closing summary and decisions reached

## [2.3.0] - 2026-05-14

### Updated
- **Guild Plugin v1.4.0**
  - Added `guild:create-workflow` — an interactive skill for generating automation workflows (GitHub Actions pipelines, Python scripts, Node.js scripts, shell scripts, Makefiles); silently scans the project stack for context-aware suggestions, previews the generated file before writing, and provides post-creation next steps

## [2.2.0] - 2026-04-25

### Updated
- **Guild Plugin v1.3.0**
  - Added `guild:developer-svelte` — a Sonnet-backed specialist agent pre-loaded with Svelte 5 / SvelteKit knowledge via four reference skills (`svelte-core`, `svelte-build-deploy`, `svelte-advanced`, `svelte-best-practices`); architect routes tasks touching `.svelte`, `+page.*`, `+layout.*`, `+server.*`, hooks, or `svelte.config.js` to this agent and falls back to the standard developer otherwise
  - Check-in now exhausts all pending `product-owner` tasks before dispatching any `architect` task, ensuring all requirements are fully written before planning begins
  - Replaced `guild:commit` skill with `software:conventional-commit`

## [2.1.0] - 2026-04-20

### Updated
- **Guild Plugin v1.1.0** - Added `guild:commit` skill (conventional commits from recent developer tasks, no push) and `guild:release` skill (stamps `CHANGELOG.md` Unreleased, archives completed REQs to `.guild/archive/{version}/`, creates annotated git tag); architect gained a research gate that auto-dispatches a researcher + follow-up architect task when it cannot plan responsibly without more information; added `.guild/docs/` evergreen knowledge base where the researcher writes topic-keyed findings (updated in place on overlap) and the architect reads during codebase analysis — docs survive both `clear-board` and `release`; check-in now maintains the `[Unreleased]` section of repo-root `CHANGELOG.md` as requirements complete

## [2.0.2] - 2026-04-20

### Updated
- **Guild Plugin v1.0.4** - Added `guild:clear-board` skill to wipe all tasks, requirements, and plans with confirmation; `new-requirement` now delegates to it instead of duplicating the clear logic

## [2.0.1] - 2026-04-20

### Updated
- **Guild Plugin v1.0.3** - `new-requirement` skill now prompts to clear the board (requirements, tasks, plans) before adding a new requirement when existing work is present
- **Guild Plugin v1.0.2** - Architect emits per-task plan slices so developers read a scoped brief instead of the full plan; researcher agent downgraded to Haiku for cost efficiency
- **Guild Plugin v1.0.1** - Consolidated duplicated agents across plugins into the guild plugin

## [2.0.0] - 2026-04-12

### Added
- **Guild Plugin v1.0.0** - Continuous agent orchestration system with persistent board management, automatic agent chains (product-owner → architect → developers → test-writer → 4 parallel reviewers), and session-based work cycles triggered by "check in"

### Updated
- **Software Plugin v1.0.4** - Refactored `conventional-commit` skill: moved Best Practices into `commit-patterns.md` reference file, removed redundant When to Use section for cleaner skill definition

## [1.0.3] - 2026-03-29

### Updated
- **Software Plugin v1.0.3** - Added "deep code review" and "deep review" as trigger phrases for `comprehensive-review` skill

## [1.0.2] - 2026-03-24

### Updated
- **Software Plugin v1.0.2** - Added "generate commit" trigger phrase to `conventional-commit` skill

## [1.0.1] - 2026-03-23

### Updated
- **Software Plugin v1.0.1** - Fixed `TodoWrite` references in `develop-project` post-implementation review loop; review fix issues are now tracked via `TASKS.md`

## [1.0.0] - 2026-03-20

### Changed
- **Plugin restructure**: Renamed `software-development-workflow` → `software-project`, `tracker` → `project-management`
- **Software Plugin v1.0.0** — First stable release
  - Fixed agent color collision: `code-reviewer-security` changed from `red` to `orange`
  - Trimmed `product-owner` agent tools from 16 to 8 (removed unused MCP, notebook, and task tools)
  - Generic `Co-Authored-By: Claude` placeholder in conventional commit skill
  - Optimized `agent-capabilities.md` reference — removed per-agent sections that duplicated agent prompts, kept cross-agent insights only
  - Added explicit `user-invocable: true` to all 4 user-invocable skills
- **Project Management Plugin v1.0.0** — New plugin replacing the tracker plugin with project orchestration capabilities

### Removed
- **Tracker Plugin** — Replaced by project-management plugin

## [0.6.1] - 2026-03-09

### Updated
- **Develop Plugin v0.6.1** - Hotfix release

## [0.6.0] - 2026-03-06

### Updated
- **Develop Plugin v0.6.0**
  - Team-based phase execution: 3 senior-developer agents spawned once per phase, tasks distributed round-robin, each developer works sequentially through their queue
  - Senior developer now reads requirements document first (Phase 0) before any code or documentation analysis
  - Senior developer model upgraded from Haiku to inherit

## [0.5.0] - 2026-03-03

### Updated
- **Develop Plugin v0.5.0** - Consolidation release for the full 0.3.x development cycle
  - 8-phase clean architecture workflow (Foundational → Models → Services → Data → Rules → State Management → UI → Tests)
  - 5-agent comprehensive review system running in parallel: product, business logic, edge case, architecture, and security (OWASP Top 10)
  - Streamlined 6-step develop-project workflow with a single user gate (master plan review only)
  - Three-state resume: TASKS.md present → resume execution; master plan only → resume from split-plan; neither → fresh run
  - Fixed parallelism: 3 senior-developer agents per phase when ≥3 tasks, 1 otherwise
  - Self-contained progress tracking via TASKS.md (tracker plugin dependency removed)
  - Complexity scoring integrated into split-plan; estimate-task skill removed
  - YAML frontmatter formatting fixed across all 8 agents

### Migration Notes
- **0.4.x → 0.5.0**: No breaking changes for end users; estimate-task skill removed (use split-plan instead); tracker plugin no longer required

## [0.4.2] - 2026-03-03

### Fixed
- **Develop Plugin v0.3.2** - Agent frontmatter YAML formatting hotfix
  - Converted single-line description strings to proper YAML block scalar format across all 8 agents

## [0.4.1] - 2026-03-02

### Updated
- **Develop Plugin v0.3.1** - Workflow streamlining and developer experience improvements
  - Streamlined develop-project from 8 to 6 steps with a single user gate (master plan review only)
  - Removed development-planner agent; split-plan skill now called directly from develop-project
  - Three-state resume support: TASKS.md (execution resume), master plan only (split-plan resume), or fresh run
  - senior-developer model downgraded to Haiku for cost efficiency during concurrent agent execution
  - TASKS.md replaces tracker plugin integration for progress tracking

### Improved
- Reduced cognitive overhead with a streamlined, largely automated develop-project workflow
- Cost efficiency with Haiku model for concurrent senior-developer agents during parallel phase execution

## [0.4.0] - 2026-02-22

### Updated
- **Develop Plugin v0.3.0** - Security review and 8-phase architecture upgrade
  - New code-reviewer-security agent with OWASP Top 10 coverage
  - Phase 8 (Tests) added to clean architecture workflow
  - develop-project moved from commands to skills
  - estimate-task removed; complexity scoring integrated into split-plan
  - development-planner model updated to haiku for efficiency
  - senior-developer agent enhanced with strict documentation guidelines

### Improved
- Security posture with automated vulnerability detection in code reviews
- Architecture clarity by separating test tasks into dedicated Phase 8
- Workflow consistency with develop-project as a skill
- Developer documentation quality guidelines

## [0.3.0] - 2026-02-08

### Added
- Root changelog for tracking marketplace-level changes
- Enhanced documentation structure across all plugins

### Updated
- **Develop Plugin v0.2.3** - Comprehensive code review system
  - Four specialized review agents (product, business logic, edge case, architecture)
  - comprehensive-review skill for parallel multi-dimensional analysis
  - Complete code quality assurance workflow
  - Requirements compliance verification
  - Test coverage and edge case identification

### Improved
- Code quality tooling with systematic review capabilities
- Pre-PR validation workflows
- Requirements traceability from planning to implementation

## [0.2.0] - 2026-02-08

### Updated
- **Develop Plugin v0.2.2** - Software architect agent
  - New dedicated agent for master plan creation
  - Analyzes requirements and existing codebase
  - Creates comprehensive implementation strategies
  - Streamlined workflow with direct plan writing
- **Develop Plugin v0.2.1** - Requirements generation
  - generate-requirements skill for structured requirements documentation
  - Enhanced product-owner agent with single-file output policy
  - Comprehensive requirements template and examples

### Improved
- Master plan creation efficiency with specialized architect agent
- Requirements gathering workflow with structured templates
- Separation of concerns between planning and implementation

## [0.1.0] - 2026-02-07

### Updated
- **Tracker Plugin v0.2.0** - Enhanced documentation
  - Purpose sections for all 18 skills
  - Improved skill descriptions with trigger examples
  - Better skill discoverability and user guidance
- **Develop Plugin v0.2.0** - Documentation improvements
  - Critical concepts section in develop-project command
  - Enhanced workflow documentation with 8-step process
  - Action-oriented skill descriptions

### Improved
- Documentation consistency across both plugins
- User guidance and clarity in all skills
- Plugin discoverability and usage patterns

## [0.0.1] - 2026-01-27

### Added
- Initial marketplace structure
- **Tracker Plugin v0.1.0**
  - Phase-based project organization
  - Feature-based tracks
  - Intelligent tracker agent
  - 18 individual skills for direct control
  - Progress reports with visual indicators
  - Task dependencies and complexity tracking
- **Develop Plugin v0.1.0**
  - 7-phase clean architecture workflow
  - Adaptive parallel execution (1-8 agents)
  - Master plan and phase plan generation
  - Tracker integration
  - Development planning and execution agents
- Comprehensive marketplace README
- Individual plugin documentation
- MIT License
- Contributing guidelines

### Infrastructure
- Git repository initialization
- Plugin directory structure
- Marketplace manifest (.claude-plugin/marketplace.json)

## Release Notes

### Version Numbering
- Marketplace versions reflect the most significant plugin update
- Individual plugins maintain independent semantic versioning
- Major marketplace updates (new plugins, breaking changes) increment major version
- Plugin updates increment minor or patch versions accordingly

### Plugin Compatibility
- No breaking changes between current versions

### Migration Notes
- **0.4.x → 0.5.0**: No breaking changes for end users; estimate-task skill removed (use split-plan instead); tracker plugin no longer required by develop plugin
- **0.4.0 → 0.4.1**: No breaking changes; develop-project workflow streamlined, development-planner agent removed (internal)
- **0.3.0 → 0.4.0**: Minor breaking change — estimate-task skill removed; develop-project moved to skills
- **0.2.0 → 0.3.0**: No breaking changes, new review features are additive
- **0.1.0 → 0.2.0**: No breaking changes, enhanced documentation and new agents
- **0.0.1 → 0.1.0**: No breaking changes, documentation improvements

## See Also
- [Software Plugin Changelog](plugins/software-project/CHANGELOG.md)
