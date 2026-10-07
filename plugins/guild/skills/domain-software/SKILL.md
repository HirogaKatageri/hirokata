---
name: domain-software
description: >
  The SOFTWARE domain profile for the strategist. A domain profile answers the six
  questions the strategist's method deliberately leaves open: what surveying the current
  state means, what two concurrent tickets contend for, which capabilities the work
  routes to, what sections a plan carries, what sections a ticket carries, and what needs
  tests and review. This profile answers all six for a code project — survey the codebase,
  contend over file paths, route to developer/test-writer/reviewer, carry Codebase Analysis
  and Files to Touch, and default to tests and review for code with behaviour. It is the
  DEFAULT profile: a guild with no `domain:` in `.guild/config.yaml` loads this one. Trigger
  phrases include "domain profile", "domain software", "files to touch", "codebase analysis",
  "what does a ticket own", "disjoint files", "needs tests", "needs review".
version: 1.0.0
---

# The `software` domain profile

**You are the strategist and this page is your domain.** `agents/strategist.md` carries the
*method* — read the requirement, survey, cut the work into tickets, assert what may run
together, emit the graph, record every deviation. That method knows nothing about software on
purpose. This page is what makes it a software plan.

**Load this before Step 2 of your workflow.** A guild with no `domain:` key in
`.guild/config.yaml` uses this profile, so on a code project it loads by default and nothing
about your behaviour changes.

Six slots. Each is a question the method asks and this profile answers.

---

## Slot 1 — What surveying the current state means

The strategist's method already tells you to read the guild's own library and decision log; that
part is domain-free and stays in the agent. This is the rest of it, for a code project:

1. **Read project docs**: `CLAUDE.md`, `README.md`, `ARCHITECTURE.md` if they exist
2. **Identify project type**: Check `package.json`, `pubspec.yaml`, `requirements.txt`, etc.
3. **Find related code**: Search for existing patterns related to the requirement
4. **Map the architecture**: Understand directory structure, module organization, key abstractions
5. **Note conventions**: Coding style, naming patterns, error handling approaches, test patterns

**When to delegate research.** Use the **Agent** tool inline — do not queue a handoff. Research is
needed if:

- The requirement involves a library, framework, API, or protocol you are not confident about,
  AND no `doc` row covers it
- The requirement depends on a third-party service whose current API shape you have not verified
  (and docs are absent or stale)
- The codebase uses a technology whose conventions you cannot infer from the files you read
- A key technical decision hinges on information not present in the codebase or docs

---

## Slot 2 — What two concurrent tickets contend for

**In this domain, a ticket owns a set of FILE PATHS**, and two tickets may run together only if
their sets are disjoint. That set is what goes into `task.files`.

Nothing in the schema parses that column — it is `CHECK (json_valid(files))` and no view reads
into it — so "file path" is this profile's answer, not the database's. Another domain puts
different handles in the same column.

**Design for parallel development — parallel is the default, not the exception.** Actively shape
ticket boundaries so file sets are **disjoint** (no file appears in two tickets' "Files to Touch")
and organize the tasks into **waves**: an ungrouped foundational task runs solo first if others
build on it; every remaining task should land in a `parallel-group` wave (`A`, then `B` for a
second wave that depends on the first). Two tasks in the same wave must (a) touch disjoint files
and (b) have no ordering dependency (neither consumes a file the other creates) — they run
concurrently in the shared working tree. If a natural decomposition puts two tasks on the same
file, prefer redrawing the boundary (e.g. split the shared file's change into the foundation
task) over serializing them. Leave a task ungrouped **only** when it is foundational, or when you
genuinely cannot bound its file set. A plan whose dev tasks are all sequential should be rare and
justified in Technical Decisions.

**You ASSERT that disjointness on the record, and nothing verifies it.** Each ticket's file set
goes into `task.files` (Step 5), and the `implement` node fans out one node per implement ticket
(`fanout: per-task`), so those file sets are what makes concurrent dispatch reviewable. Two
tickets in one `parallel_group` claiming the same file means two developers editing one file
concurrently in a shared working tree. If you cannot make the sets disjoint, do not pretend they
are: split `implement` into sequential waves with a `reshape` deviation and say why.

---

## Slot 3 — Which capabilities the work routes to

| Ticket | required | preferred | Rank 1 today |
|---|---|---|---|
| Backend / service / generic implementation | `implement,backend` | — | `developer` |
| Frontend in a non-Svelte stack | `implement,frontend` | — | `developer` |
| Svelte / SvelteKit ticket | `implement,frontend` | `svelte,sveltekit` | `developer-svelte` |
| Test planning | `test-planning` | — | `test-planner` |
| Unit / integration test authoring | `test-authoring` | — | `test-writer` |
| End-to-end spec authoring | `test-authoring` | `e2e` | `qa-tester` |
| Technology research (standalone ticket) | `research` | — | `researcher` |

The right-hand column is what the match *ranked* against a 14-member guild roster, not an
assumption — but it is a property of the agent files on that day, so **confirm it against the
machine you are on** with `roster.py --covers` rather than trusting the table.

Use the **Svelte signals you already know** to decide whether to add the `svelte,sveltekit`
preferred pair: the project has `svelte` or `@sveltejs/kit` in `package.json`, and the ticket's
"Files to Touch" lists `.svelte`, `.svelte.ts`, `.svelte.js`, `+page.*`, `+layout.*`, `+server.*`,
`+error.svelte`, `hooks.server.*`, `hooks.client.*`, `app.html`, `svelte.config.js`, or files under
`src/routes/`, `src/lib/`, or `src/params/`. In a mixed-stack repo, decide **per ticket**, not per
plan — a ticket that builds a Go API requires `implement,backend`; its sibling that wires the Svelte
UI adds the preferred pair.

---

## Slot 4 — What sections the plan body carries

```markdown
# {Feature} Implementation Plan

## Architecture Overview

{High-level design: components, their relationships, data flow}

## Codebase Analysis

{What exists today that's relevant. Existing patterns to follow. Integration points.}

## Implementation Tasks

### 1. {Task Title} (complexity: {1|2|3})
- **Summary**: {One line — the full brief is that ticket's `objective`}
- **Depends on**: {Prerequisites, if any}

### 2. {Task Title} (complexity: {1|2|3})
{...repeat — one entry per developer task...}

## Assurance

| Ticket | Verification | Review | Why |
|--------|--------------|--------|-----|
| {TASK} {title} | {tests / checks / none} | {full / focused: lenses / none} | {one sentence} |

Graph effect: {which test and review steps run, and which are skipped}

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| {What} | {Choice} | {Why} |

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| {Risk} | {Impact} | {How to handle} |
```

`Architecture Overview`, `Assurance`, `Technical Decisions` and `Risks and Mitigations` are the method's own
and every profile carries them. `Codebase Analysis` is this profile's survey section.

---

## Slot 5 — What sections a ticket brief carries

```markdown
# {Task Title} (complexity: {1|2|3})

## Objective
{Specific deliverable for this task only}

## Files to Touch
- `path/to/file.ext` — {create | modify} — {what changes}

## Approach
{Step-by-step implementation approach, patterns to follow, existing code to mirror}

## Interface Contract
{What this task exposes to or consumes from sibling tasks. Function signatures, types, events, routes — whatever other tickets need to know.}

## Assurance
- Verification: {tests | checks — the commands | none}
- Review: {full | focused — the lenses | none}

## Acceptance Criteria
- [ ] {Specific, verifiable outcome}
```

`Objective`, `Approach`, `Assurance` and `Acceptance Criteria` are the method's own. `Files to Touch` is this
profile's contention section and `Interface Contract` is its hand-off section.

**"Files to Touch" must be accurate and complete** — it is the basis for parallel-group
disjointness, and it is literally the ticket's `files` assertion. If a ticket ends up touching a
file you didn't list, two grouped developers collide in a shared working tree. Nothing in the
schema checks this for you. List every file the task will create or modify; if you cannot bound
the file set confidently, leave that task ungrouped and store the files you are sure of.

Base everything on actual codebase analysis, not assumptions. Downstream agents — the
test-planner and the reviewers — orient from the overview, so keep it consistent with the tickets.

---

## Slot 6 — What needs tests, and what needs review

**The method decides per ticket at Step 3.7**; this slot is the software project's *defaults* and
its *never-skip* list. The decision procedure, the three places it is written down and the SQL to
skip a step are in `agents/references/strategist-assurance.md` — read it first.

**A software project does not only receive code.** It also receives articles, diagrams, research
notes, configuration and copy. Decide each ticket on what it produces, not on the repository it
lives in.

| The ticket produces… | Verification | Review |
|---|---|---|
| Logic, branching, state, parsing, validation, an API or a data contract | `tests` | `full` |
| An integration seam — a route, a handler, a store, a queue consumer | `tests` | `full` |
| A UI component with behaviour (state, events, async) | `tests` | `focused` — business-logic, edge-case, architecture; add security if it handles input or auth |
| A pure-presentation change — styling, layout, copy in markup | `checks` — build, lint, typecheck, visual check | `focused` — business-logic, or `none` if it is trivially reversible |
| A migration, anything touching auth, secrets, money or personal data | `tests` | `full` — **never skipped** |
| Configuration or CI | `checks` — the pipeline itself is the test | `focused` — security, architecture |
| An article, essay or documentation page | `checks` — the project's content checks, a build, a word count | `focused` — business-logic, edge-case; `none` while it is an unpublished draft only if nobody depends on it |
| A diagram, figure or other static asset | `none` or `checks` | `none`, or `focused` if it states claims a reader will rely on |
| Research notes, a decision record | `none` | `none` — the sources are the evidence |
| A rename, a comment, a typo | `none` | `none` |

**Read the repository's own rules before you apply the table.** If `CLAUDE.md` or the contributing
guide says "tests must not depend on content" or "every change needs a test", that is the answer,
and it beats the table.

**Never skip review** of a migration, anything that handles credentials, authentication,
authorization, money or personal data, a public contract other code depends on, or anything
hard to retract once it ships.

**Tests are run by the test-writer; checks are not tests.** A `checks` outcome means the author
runs the project's own commands (`build`, `lint`, `typecheck`, a content checker) and the test
planner, if one runs, only *plans* them. Do not ask for test files that would pin content or
duplicate what the toolchain already enforces.

---

## Writing a profile for another domain

A domain profile is this page with the six slots answered differently. Nothing else changes:
the method, the graph, the gates, the capability matching, the record and the audit are all
domain-free already, and `task.files` is an opaque JSON array of strings that no view parses.

| Slot | Software | A marketing team might say |
|---|---|---|
| 1 — Survey | read the codebase, docs, conventions | read past campaigns, performance data, brand guidelines |
| 2 — Contention | file paths | `channel:email`, `asset:hero-v2`, `segment:enterprise` |
| 3 — Routing | `implement,backend` → `developer` | `draft,longform` → `copywriter` |
| 4 — Plan section | `## Codebase Analysis` | `## Market Context` |
| 5 — Ticket section | `## Files to Touch` | `## Assets and Channels` |
| 6 — Tests and review | tests for behaviour, review for risk | a claims check and a legal read for anything public; no tests |

Name the file `skills/domain-<name>/SKILL.md`, then point a project at it:

```yaml
# .guild/config.yaml
version: 5
domain: marketing        # the strategist loads guild:domain-marketing
db:
  mode: local
```

**The column keeps the name `files` for now**, and that is a known wart rather than a design
claim: renaming it to something honest is a migration, and it buys nothing until a second domain
actually exists. What matters is that nothing reads it, so a marketing team putting
`["channel:email"]` in there gets correct batching, a correct `implement` fan-out and a correct
G9 audit with no schema change at all.
