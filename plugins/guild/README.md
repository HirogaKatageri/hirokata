# Guild Plugin

A Claude Code plugin for continuous agent orchestration through a persistent, database-backed work cycle.

**Status: v5.0.0-beta.3 — Stages 1, 2 and 3 of 5 are shipped.** Storage, visibility and the
roster are done; the execution graph, gates, the maintenance cycle and unattended operation are
not. See [What is not built yet](#what-is-not-built-yet) — this README describes what runs today,
not the design doc's endpoint (`docs/v5-design.md`).

## Overview

The **guild** plugin manages an ongoing development workflow on a **Turso database** at
`.guild/guild.db`. There is no `BOARD.md`, no ticket file, no `state.yaml` and no status
subdirectory: an artifact's **status is a column**, and the "board" is a live view rendered on
demand from SQL. A dependency-free **`scripts/guild` CLI** performs every deterministic operation —
skills and agents shell out to it instead of hand-rolling SQL, `find`/`mv` or ID arithmetic. Each
work session starts with a check-in: the orchestrator opens with `guild brief`, gathers input, and
walks a cursor through the queue — dispatching one ticket (or one parallel wave) at a time to
specialized agents, materializing their follow-ups, and continuing to the next.

The database is **derived state**. Two committed artifacts buy back what a file board gave for
free: an append-only `journal.ndjson` that `guild rebuild` replays into a fresh database, and a
generated `export/*.md` snapshot that is the PR-reviewable record.

### Key Features

- **Status is a column, and one writer owns it.** No directories to move, no `status:` frontmatter
  to reconcile, no counters. IDs are derived in SQL (`MAX(n) + 1` in the same statement as the
  insert, so two creates cannot collide) and the cursor is derived (the "current" task is whatever
  row is `in-progress`).
- **Direction above the board.** Goals → phases → requirements → plans → tasks. A goal is
  long-lived intent with a priority; a phase is an ordered stage of one goal. Attaching a
  requirement to a phase is optional and reversible — unaffiliated work is a first-class choice.
- **A ticket names a capability, not a member.** `guild new task --needs implement,svelte`, and
  any agent whose declared capabilities cover it is eligible; `guild match` ranks them
  deterministically (preferred covered, then *fewest* total capabilities so a specialist beats a
  generalist, then name). Adding `agents/developer-rust.md` with the right tags makes it eligible
  for work with **no skill edits and no chain rewiring** — which is the point of the whole stage.
  A ticket that still names an agent keeps working exactly as before, so nothing on an existing
  board changed.
- **A roster gap is loud, and it recruits.** No eligible member means `guild match` exits 1 naming
  the missing capabilities and the bounty board says `no-eligible-agent:rust`; the task parks in
  `blocked`, which counts as *open* for requirement completion, so nothing ever closes over work
  nobody attempted. The architect files the gap at **plan** time with `guild capability-request`,
  it surfaces in the brief's *Roster Gaps*, and once you add the agent file `guild sync-agents`
  admits it and closes the request. The roster accretes toward the shape of your projects.
- **Bugs and quality areas are rows, not prose.** The QA discipline files defects with
  `guild bug new` and maps risk with `guild coverage set`, so "what is still broken?" and "what has
  nobody looked at in a month?" are queries instead of someone's memory.
- **Two ways to read the board.** `guild:brief` narrates it — direction, what is in flight, open
  bugs and findings, what moved since the last check-in, what to do next. `guild:dashboard` builds
  the same state as one self-contained offline HTML page with seven views.
- **Durable without a database file.** Every mutation is journaled as the *resulting row state*
  (a change log replays across CLI versions; a command log does not), and a failed append is
  quarantined and reported rather than silently dropped. Delete `guild.db` and run `guild rebuild`.
- **Parallel development by default**: the architect designs plan slices with disjoint file sets
  and groups them into `parallel-group` waves; the orchestrator dispatches each wave concurrently
  in the shared working tree. Ungrouped (foundational) tickets run solo in ID order.
- **Live requirement planning, then automatic agent chains**: `guild:new-requirement` runs a live
  3-way interview between the product-owner, the architect, and you — the architect creates every
  downstream ticket directly before the skill returns. From there it's automatic: parallel
  developers → test-planner → test-writer (unit & integration) → 4 parallel reviewers.
- **Crash-safe resume**: agents log a start entry and milestones through the CLI, so an interrupted
  ticket is triaged three ways on the next check-in — never-started tickets are re-queued,
  finished-but-unrecorded tickets are recorded without re-running the agent, and half-done tickets
  resume from their Work Log.

## Storage: local by default, cloud gated

Chosen once at `guild init` and recorded in `.guild/config.yaml`.

| Mode | Where the board lives | Binary | Status |
|------|----------------------|--------|--------|
| `local` **(default)** | `.guild/guild.db` | `tursodb` | The only verified mode. No account, no token, no network. |
| `cloud` | a Turso Cloud database | `turso` | **`guild init --mode cloud` is refused** — an unverified code path, gated on purpose. |

`guild init` checks for `tursodb` and prints the install line rather than failing with "command not
found":

```bash
curl --proto '=https' --tlsv1.2 -LsSf \
  https://github.com/tursodatabase/turso/releases/latest/download/turso_cli-installer.sh | sh
```

Cloud mode is refused because `turso db shell` has no machine-readable output flag (every parser in
the CLI assumes `tursodb -q -m list`'s pipe-separated rows), because the FK preamble differs between
the two branches, and because the URL would travel in argv where libsql URLs commonly embed
`?authToken=`. `config.yaml` stores the **names** of environment variables, never the values, and
that is enforced before any file is written. See `scripts/README.md` for the full rationale and what
ungating would require.

## The work model

```
goal ──< phase ──< requirement ──< plan ──< plan_slice
                        │
                        └──< task ──< work_log, review_finding

bug        — defects, optionally linked to a requirement and to a fix task
coverage   — quality areas with a risk level, a spec path and an inspection clock
doc        — the evergreen, slug-keyed knowledge base
event      — the activity feed behind `guild brief` and the dashboard
```

Goals and phases **organize and prioritize; they do not gate.** The only gate in the shipped
pipeline is the per-requirement review gate. A requirement's `phase_id` is nullable by design —
a bug fix or a chore filed directly needs no goal — and `guild req assign REQ-NNN none` detaches
one again.

## The Agent Chain

```
guild:new-requirement (live interview, not ticket-dispatched)
  ├→ product-owner: interviews you, writes the REQ record
  ├→ orchestrator: offers a phase for the requirement (existing phase,
  │  new phase, new goal + phase, or unaffiliated) — the user decides
  └→ architect: explores codebase (calling guild:researcher inline as needed),
     writes the PLAN, creates dev tickets + the test-planner + reviewer tail directly
      │
      ▼  (tickets now exist — check-in drives the rest)
developer ×N: implement code per plan, in parallel-group
waves (disjoint files); foundational tickets run solo first
  └→ test-planner: inventories the diff, writes the test plan,
     declares the test-writer ticket(s)
      └→ test-writer: writes and runs unit & integration tests
          └→ 4 reviewers in parallel:
              ├── reviewer-security
              ├── reviewer-architecture
              ├── reviewer-business-logic
              └── reviewer-edge-case
                  └→ orchestrator compiles a review report (.guild/reviews/REQ-NNN.md)
                     and asks you which findings, if any, become fix tickets —
                     no automatic re-review
```

Direction is the guild master's layer: neither the product-owner nor the architect runs
`guild goal new`, `guild phase new` or `guild req assign`. They recommend; the orchestrator asks
you; you decide.

## Skills

### `guild:check-in`

The main orchestrator skill. Starts or resumes a work session, opens with the brief, gathers input,
and drives the continuous work cycle.

**Trigger Phrases:**
- "check in"
- "clock in"
- "standup"
- "guild check in"
- "let's get to work"
- "start working"
- "continue working"
- "daily standup"
- "guild standup"
- "I'm here"
- "reporting in"

A read-only status question ("what's the status", "where are we") belongs to `guild:brief`, which
reports without starting work.

**What it does:**
1. Initializes `.guild/` (config, schema, journal, `spool/`, `export/`, `docs/`, `qa/`, `reviews/`)
   on first use — and if a **v4 board** is present, moves it to `.guild/v4-archive/` untouched
2. Opens with `guild brief` — direction, in flight, bugs, coverage due, what moved
3. Routes the session — a work-intent trigger resumes immediately; otherwise asks
4. Walks the cursor: dispatch → drain the spool → complete → materialize follow-ups → advance
5. Presents a session summary when the work cycle ends

### `guild:brief`

The narrated read of the board, and the flagship of Stage 2. One query behind eight sections —
Direction, In Flight, Blocked, Open Bounties, Bugs, Coverage, Since Last Check-in, Roster Gaps —
plus a header carrying the same `Next:` answer `guild next` gives. **Read-only**: it dispatches
nothing, moves nothing and writes nothing, not even a journal line.

A section with no rows is not printed; an empty guild gets a short "nothing is on the board yet"
with three next steps rather than eight `(none)` blocks. (*Roster Gaps* became reachable in
Stage 3 — `guild capability-request` is what writes the table it reads. *Blocked* prints tasks
whose status is `blocked`; its `waiting on <ids>` clause reads `task_dependency`, which nothing
writes until Stage 4. Seeding the roster at `guild init` is deliberately *not* counted as
board activity, so a brand-new guild still reads as empty.)

**Where the roster shows up.** The brief is the recruiting surface: a gap the architect filed at
plan time is in *Roster Gaps* with its rationale and the member it proposes. For "who can take
what, and why not", `guild bounties` is the sharper tool — it prints the matched member per
open task and, underneath, everything that cannot be worked with a one-token reason
(`status-blocked`, `deps:<ids>`, `no-eligible-agent:<caps>`).

**Trigger Phrases:**
- "guild status"
- "board status"
- "what's the status"
- "show the board"
- "what's on the board"
- "project status"
- "show guild"
- "guild board"
- "what's happening"
- "brief me"
- "where are we"
- "what changed" / "what moved since last time"
- "what should I work on next"

### `guild:dashboard`

Builds `.guild/dashboard.html`: one file, all CSS and JS inline, the board data inlined as JSON. No
server, no build step, no network — it works offline and from `file://`. Seven views: **Roadmap**
(goals → phases → requirements with live progress), **Board** (tasks by status), **Graph** (the
execution graph — empty until Stage 4, and the view says so), **Bugs**, **Findings** (what
reviewers flagged and whether it was ever fixed), **Coverage** and **Activity**.

The output is deterministic — the same state produces byte-identical bytes, so the file diffs
cleanly if it is committed (`guild init` gitignores it by default). Nothing embeds a wall clock;
every "3 days ago" is computed in the browser at view time.

**Trigger Phrases:**
- "the dashboard" / "guild dashboard"
- "open the dashboard" / "show me the dashboard" / "build the dashboard"
- "visualize the board"
- "the roadmap" / "show the roadmap"
- "a visual view of the guild"
- "the coverage view"
- "the activity feed"

The page carries real requirement titles, task bodies and bug reports, so publishing it as a
shareable Artifact is offered once and never automatic.

### `guild:guild-status`

**Deprecated alias.** This was v4's status skill; it is now `guild:brief`. It deliberately claims
**no** natural-language trigger phrases — two skills advertising "guild status" would make every
status request a coin flip — and exists only so the typed slash command `/guild:guild-status` keeps
working. It loads `guild:brief` and follows it.

### `guild:new-requirement`

Runs a live 3-way interview between the product-owner, the architect, and you, then writes the
requirement, the implementation plan, and every developer/test-planner/reviewer ticket needed to
build it — all before the skill returns. Between the two, the orchestrator offers to place the
requirement on a phase (an existing one, a new phase, a new goal *and* its first phase, or leave it
unaffiliated). If Agent Teams is enabled (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`), the product-owner
and architect can message each other directly; otherwise the orchestrator moderates between them.
Either way, only the orchestrator can ask you questions directly — both agents relay through it.

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

### `guild:clear-board`

**Refuses, and says so.** v5 ships no `guild clear` and no `guild delete`, so this skill inventories
what is on the board, explains that it cannot remove it, and offers the honest alternatives — leave
it (done work gates nothing), move open work to `failed`, or start a genuinely fresh board with
`GUILD_DIR=.guild-next guild init` — instead of reporting a deletion that did not happen. A delete
command is pending a later stage.

**Trigger Phrases:**
- "clear the board"
- "reset the guild"
- "start fresh"
- "wipe the board"
- "clear all tasks"
- "reset the board"

### `guild:qa`

Seeds the guild's **independent QA discipline** — a quality function that runs beside the feature
chain rather than inside it. The `qa-strategist` maps product risk and writes one `coverage` row per
quality area; `qa-tester` agents run the actual app, author end-to-end (Playwright) regression
specs, file defects as `bug` rows, and stamp the areas they actually drove with
`guild coverage inspect`. Use it to build comprehensive e2e regression suites and to probe the
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
2. Seeds a `qa-strategist` task for the requested scope (whole product or a named flow), in `full`
   or `cadence` mode
3. The strategist resolves the oracle (internal specs → external board via MCP → code + running app
   → user), builds a risk map, writes the `coverage` rows, and declares `qa-tester` missions
4. `qa-tester` agents run the app, apply the what-if catalog, author e2e specs (hybrid oracle: lock
   good behavior, flag suspect behavior as a bug, ask the user when ambiguous), and file each defect
   with `guild bug new`
5. Each bug gets a developer fix task linked with `guild bug fix`, paired with a re-verify qa-tester
   ticket; the re-verify confirms the fix empirically and closes the bug

Bugs and quality areas live in the **database**, so they show up in `guild bug list`,
`guild coverage list --due`, the brief and the dashboard. The prose artifacts that remain under
`.guild/qa/` (charter, missions, session logs, regression manifest) are **evergreen** — they survive
releases. Committed e2e specs live in the project's real e2e dir and run in CI;
`developer`/`developer-svelte` co-maintain them. Can be armed on a **standing cadence** via
`/schedule` or `/loop` (opt-in per project).

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

Finalizes completed requirements into a versioned release: stamps `CHANGELOG.md` Unreleased with the
new version, regenerates `guild export` and **copies** the completed requirements' markdown into
`.guild/releases/{version}/`, and creates an annotated git tag. Does not push.

Each exported REQ file inlines that requirement's plans, tasks, work logs and review findings, so
the snapshot carries everything v4's archive did — in one file per requirement, and reviewable in
the PR. Nothing is moved off the board: v5 has no archive command, and a step that pretended to move
files would report work it did not do. `.guild/docs/` and `.guild/qa/` are evergreen and are never
snapshotted.

**Trigger Phrases:**
- "cut a release"
- "release the guild"
- "ship it"
- "tag a version"
- "guild release"

**Arguments:**
- `--dry-run` — preview the release plan without making changes
- `--only REQ-NNN,REQ-MMM` — release only specific requirements

The check-in skill appends a bullet to `CHANGELOG.md`'s `[Unreleased]` section whenever a
requirement is marked done, so the changelog is always current between releases.

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

### Also included

`guild:comprehensive-review` (multi-dimensional pre-PR review), `guild:create-workflow` (generate a
CI/script workflow), `guild:svelte-env-vars-check`, and the agent-facing reference skills
(`guild:qa-mindset`, `guild:qa-artifacts`, and the four `guild:svelte-*` skills) that specialist
agents pre-load rather than users invoking directly.

## Agents

| Agent | Model | Role |
|-------|-------|------|
| `guild:product-owner` | Sonnet | Interviews user (live, alongside the architect, inside `new-requirement`), writes the REQ record; can delegate quick lookups to `guild:researcher`. Never sets direction |
| `guild:architect` | Opus | Explores codebase, calls `guild:researcher` inline as needed, writes the implementation PLAN, creates dev/test-planner/reviewer tickets directly; reads `guild goal show` when the requirement sits on a phase; routes Svelte tasks to `developer-svelte` |
| `guild:developer` | Sonnet | Implements code per plan and requirement |
| `guild:developer-svelte` | Sonnet | Svelte 5 / SvelteKit specialist — pre-loaded with four reference skills; used when tasks touch `.svelte`, `+page.*`, `+layout.*`, `+server.*`, hooks, or `svelte.config.js` |
| `guild:test-planner` | Sonnet | Inventories the implemented diff, writes the test plan, declares the test-writer tickets |
| `guild:test-writer` | Sonnet | Implements the test plan — writes and runs unit & integration tests |
| `guild:product-reviewer` | Haiku | Verifies implementation satisfies plan requirements |
| `guild:reviewer-security` | Haiku | Security vulnerabilities, OWASP Top 10 |
| `guild:reviewer-architecture` | Haiku | Plan alignment, patterns, separation of concerns |
| `guild:reviewer-business-logic` | Haiku | Acceptance criteria, business rules, testability |
| `guild:reviewer-edge-case` | Haiku | Boundary conditions, null handling, error scenarios |
| `guild:researcher` | Haiku | Technology research, API investigation, documentation lookup |
| `guild:qa-strategist` | Sonnet | QA planning — risk map as `coverage` rows, adversarial what-if missions (independent QA discipline) |
| `guild:qa-tester` | Sonnet | Empirically runs the product, authors e2e/Playwright regression specs, files `bug` rows, stamps the inspection clock |

Agents never open a database connection. They read with `guild read` / `guild meta` / `guild slice`,
report with `guild log` / `guild finding` (a plain append to a per-task spool file), and the
orchestrator folds the spool in with `guild spool drain`. **The orchestrator owns every status
transition** — agents never move their own work.

## State Structure

The guild maintains a `.guild/` directory in your project:

```
.guild/
├── config.yaml            # committed — storage mode; env var NAMES only, never a credential
├── journal.ndjson         # committed — append-only change log; `guild rebuild` replays it
├── export/REQ-NNN.md      # committed — GENERATED snapshot; `guild export` rewrites it wholesale
├── releases/{version}/    # committed — release snapshots taken from the export
├── guild.db               # gitignored — DERIVED state; the board itself (local mode)
├── spool/TASK-NNN.ndjson  # gitignored — agents' un-drained log/finding lines
├── spool/rejected/        # COMMITTED — spool lines a drain could not import
├── journal.pending        # gitignored — quarantined journal lines (`guild journal recover`)
├── dashboard.html         # gitignored by default — regenerated by `guild dashboard`
├── backup-*/              # gitignored — pre-rebuild db copies, pre-compaction journal copies
├── docs/                  # evergreen researcher notes carried into the `doc` table at init
├── qa/                    # evergreen QA prose (charter, missions, sessions, regression manifest)
├── reviews/REQ-NNN.md     # per-requirement review reports
└── v4-archive/            # a v4 board `guild init` moved aside — never parsed, never deleted
```

**`journal.ndjson` is the durable board.** `guild.db` can be deleted at any time and rebuilt from
it; the reverse is not true. Each line records the *resulting row state*, so it replays across CLI
versions:

```json
{"seq":3,"ts":"2026-08-13T09:14:02Z","actor":"orchestrator","op":"upsert","table":"task","row":{"id":"TASK-014","status":"done"}}
```

A `journal_preflight` runs *before* the SQL in every mutating command, so an unwritable or
conflict-marked journal becomes a refusal that says plainly nothing was written — never a board
change the next rebuild silently undoes. `guild journal compact` refuses to lose a row unless
forced, and `guild journal sync` reconciles the append-only record tables. This is not atomicity
between a SQLite file and a text file; what is guaranteed is that divergence is prevented, or
recorded, or reported — never silent.

### Upgrading from v4

`guild init` on a directory holding a v4 board **moves the whole tree to `.guild/v4-archive/`** —
never deletes, never parses. **There is no history import**, and `guild migrate` is retired. Two
things carry over because they are evergreen rather than historical: `.guild/docs/*.md` into the
`doc` table, and `.guild/qa/` into the `coverage` table (with `last_inspected_at` left null, so
everything reads as due on day one). Unfinished v4 work is re-entered by hand through
`guild:new-requirement`, reading the archived plan for the details.

### `guild path` and `state.yaml` are gone

`guild path` was **removed, not renamed** — it still exits 1 with a message naming its replacements,
because thirteen v4 call sites used to *Edit* the file it returned. In v4 the path was the storage;
in v5 only requirements get an export file, that file is generated, and `guild export` rebuilds the
whole directory on every run, so an edit there is silently lost. `state.yaml` is gone too:
`last-checkin` is a row in `guild_state`, written only by `guild checkin`.

| You want to… | v4 | v5 |
|---|---|---|
| read a ticket | `cat "$(guild path TASK-1)"` | `guild read TASK-1` |
| read one field | `fm "$(guild path TASK-1)" agent` | `guild meta TASK-1 agent` |
| append to the Work Log | Edit the ticket file | `guild log TASK-1 --agent developer --entry '…'` |
| record a review finding | Edit the ticket file | `guild finding TASK-1 --reviewer r --severity major --summary '…'` |
| rename a ticket | Edit the `title:` line | `guild retitle TASK-1 'New title'` |
| stamp the check-in | Edit `state.yaml` | `guild checkin 2026-08-13` |

## The CLI

Every deterministic operation goes through `scripts/guild` (invoked as
`${CLAUDE_PLUGIN_ROOT}/scripts/guild`). Requires Bash 3.2+, standard Unix tools and one Turso
binary — no Python, no Node, no `jq`. Full reference: **`scripts/README.md`**.

| Group | Commands |
|-------|----------|
| Setup | `init`, `rebuild`, `journal compact\|recover\|sync` |
| Direction | `goal new\|list\|show\|move\|priority`, `phase new\|list\|move`, `req assign` |
| Board | `new req\|task\|plan`, `read`, `meta`, `status`, `slice`, `next-id`, `move`, `retitle`, `list`, `next`, `batch`, `checkin` |
| Agent writes | `log`, `finding`, `spool drain` |
| Records | `bug new\|list\|show\|fix\|close`, `coverage set\|inspect\|list\|show`, `doc put\|get\|list\|search` |
| Views | `board`, `brief`, `dashboard`, `export` |

Environment: `GUILD_DIR` (guild root, default `.guild`), `GUILD_ACTOR` (who mutations are attributed
to, default `orchestrator`), `GUILD_SCHEMA`, `GUILD_ASSUME_YES`.

Two rules run through the whole CLI and are worth knowing before you extend it: **all free text
travels into SQL as hex** (`CAST(x'…' AS TEXT)`), because tursodb's script splitter ends a statement
at a `;` that terminates a line even inside an open string literal; and **free text must never be
able to impersonate a structural token on the way out** — the board flattens it, the export uses a
length-prefixed header, the JSON surfaces go through `json_object()`, and the dashboard escapes
every `<` before it reaches the page.

## What is not built yet

Stages 4 and 5 of the v5 design are **not shipped**. Their tables exist in `schema.sql` so no stage
needs a migration, and a few read surfaces are already wired against them — which is why they render
as empty sections rather than as errors.

| Not shipped | Stage | What you see today |
|---|---|---|
| **The execution graph** — the `standard` and `maintenance` templates, `guild graph` / `graph validate` / `segment`, architect deviation with reasons, workflow compilation, the thinned check-in | 4 | The dashboard's Graph view says so rather than drawing a blank chart. The chain is still the fixed one the skills drive, and `guild next` is still the cursor |
| **Gates** — `guild gate --approve/--reject`, `gate-plan` and `gate-repairs` as records | 4 | The review gate in `guild next` is still the only gate, and the two human approvals happen in the skills' conversation rather than as `gate` rows. A `capability_request` therefore surfaces in `guild brief` and `guild:new-requirement`, **not** at `gate-plan` |
| **Task dependencies** — nothing writes `task_dependency` | 4 | `guild bounties` reports `deps:<ids>` and the brief reports `waiting on` correctly, but every dependency set is empty, so both clauses are inert |
| **The maintenance cycle** — `inspection` as a turn of QA over the coverage map, on the same machinery as a build | 4 | `guild coverage` maps and stamps areas; nothing records an inspection *pass* over several of them |
| **The unattended shift** — `guild shift`, failure and budget policy, git safety, gate notifications | 5 | Not present. Every session is driven by you |

Shipped-but-honest gaps in Stage 1–3 (`scripts/README.md` lists these in full):

- **No writer for `plan_slice`.** `guild slice` reads one; the architect puts each slice brief in
  its developer ticket's `--objective` instead.
- **No body writer after creation.** A requirement, plan or task document is written once, at
  `guild new … --body`. `guild doc put` (an upsert) and `guild bug fix`/`close` are the exceptions.
- **No `guild clear` / `guild delete` / `guild archive`.** `guild:clear-board` refuses rather than
  no-op'ing, and `guild:release` copies the export instead of moving files.
- **The `doc` table has CLI writers but no agent producer yet.** `guild doc put|get|list|search`
  work, and `guild init` carries a v4 `.guild/docs/` tree into the table — but the researcher still
  writes markdown files to `.guild/docs/` and the architect still reads that directory, so the
  directory is the live knowledge base today.
- **Cloud mode is refused at `guild init`** (see above).

## Quick Start

```
# Initialize and start your first work session
check in

# The guild will:
# - Create .guild/ (config, schema, journal, spool, export, docs, qa, reviews)
# - Open with the brief
# - Ask what you want to work on
# - Create a requirement and start the agent chain
# - Continue until you say "no" or the backlog is empty

# Read the board without starting work
guild status          # → guild:brief

# See it as a page
show me the dashboard

# Add a new requirement directly
new requirement
```

Or drive the CLI directly:

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"

"$GUILD" init 2026-08-13
"$GUILD" goal new --title "Ship checkout v2" --priority 2      # → GOAL-001
"$GUILD" phase new --goal GOAL-001 --title "Foundations"       # → PHASE-001
REQ=$("$GUILD" new req --title "User Authentication" --desc "Login & signup")
"$GUILD" req assign "$REQ" PHASE-001

# A ticket describes the WORK; the roster answers who takes it (init already seeded it)
"$GUILD" new task --title "Login form" --req "$REQ" --needs implement,frontend --prefers svelte
"$GUILD" match TASK-001                      # ranked candidates; rank 1 is the dispatch target
"$GUILD" bounties                            # what can be worked now — and what cannot, and why

TASK=$("$GUILD" next)                        # a bare ID, no path
"$GUILD" move "$TASK" in-progress            # dispatch
"$GUILD" spool drain "$TASK"                 # fold in the agent's reports
"$GUILD" move "$TASK" done

"$GUILD" checkin 2026-08-13
"$GUILD" brief                               # the narrated read
"$GUILD" dashboard --open                    # the same, as one offline page
"$GUILD" export                              # refresh the committed snapshot

rm -f .guild/guild.db && "$GUILD" rebuild    # the database is derived; the journal is the truth
```

## File Structure

```
guild/
├── .claude-plugin/
│   └── plugin.json                     # Plugin manifest
├── docs/
│   └── v5-design.md                    # The v5 architecture design doc (5 stages)
├── scripts/
│   ├── guild                           # Deterministic board CLI (dispatcher only)
│   ├── schema.sql                      # The DDL — idempotent
│   ├── dashboard.tmpl.html             # Generated-page template for `guild dashboard`
│   ├── test-guild.sh                   # CLI harness
│   ├── lib/
│   │   ├── db.sh                       # Driver: config, db_exec/db_query, sql_str/sql_text, spool
│   │   ├── journal.sh                  # preflight, append, recover, sync, rebuild, compact
│   │   ├── artifacts.sh                # new/read/meta/move/list/next/batch/log/finding/spool drain
│   │   ├── direction.sh                # goal, phase, req assign
│   │   ├── records.sh                  # bug, doc
│   │   ├── quality.sh                  # coverage and the inspection clock
│   │   ├── brief.sh                    # the structured briefing
│   │   ├── dashboard.sh                # the six-view HTML page
│   │   ├── render.sh                   # board, markdown export, JSON dump, escaping helpers
│   │   └── init.sh                     # init, v4 archival, rebuild, journal subcommands
│   └── README.md                       # CLI reference
├── agents/
│   ├── architect.md
│   ├── developer.md
│   ├── developer-svelte.md             # Svelte 5 / SvelteKit specialist
│   ├── product-owner.md
│   ├── product-reviewer.md
│   ├── qa-strategist.md                # QA discipline — risk map & coverage planning
│   ├── qa-tester.md                    # QA discipline — runs app, authors e2e specs, files bugs
│   ├── researcher.md
│   ├── reviewer-architecture.md
│   ├── reviewer-business-logic.md
│   ├── reviewer-edge-case.md
│   ├── reviewer-security.md
│   ├── test-planner.md
│   └── test-writer.md
└── skills/
    ├── check-in/
    │   ├── SKILL.md
    │   └── references/
    │       ├── agent-chains.md         # Agent chain patterns
    │       ├── state-format.md         # The database model, .guild/ layout, the cursor rule
    │       └── task-lifecycle.md       # Task record format and status transitions
    ├── brief/
    │   └── SKILL.md                    # The narrated read of the board
    ├── dashboard/
    │   └── SKILL.md                    # The self-contained HTML page
    ├── guild-status/
    │   └── SKILL.md                    # Deprecated alias → guild:brief
    ├── clear-board/
    │   └── SKILL.md
    ├── comprehensive-review/
    │   ├── SKILL.md
    │   └── references/
    │       ├── agent-capabilities.md
    │       └── review-interpretation.md
    ├── create-workflow/
    │   └── SKILL.md
    ├── discuss/
    │   └── SKILL.md
    ├── new-requirement/
    │   └── SKILL.md
    ├── qa/
    │   └── SKILL.md                    # Independent QA discipline entry point
    ├── qa-mindset/
    │   └── SKILL.md                    # QA pillars, what-if catalog, hybrid oracle (agent reference)
    ├── qa-artifacts/
    │   └── SKILL.md                    # Which QA output is a row and which stays prose
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
    ├── svelte-env-vars-check/
    │   └── SKILL.md                    # SvelteKit env-var usage audit
    └── verify-and-fix/
        ├── SKILL.md                    # End-to-end error diagnosis and fix workflow
        └── references/
            ├── investigation.md        # Investigation steps, source-query order, findings format
            └── tdd-fix.md              # TDD fix flow, test requirements, and final summary format
```

## License

MIT License - See LICENSE file for details.

## Author

**Gian Patrick Quintana**
- Email: gian.quintana@hirokata.dev
- GitHub: [@hirogakatageri](https://github.com/hirogakatageri)
