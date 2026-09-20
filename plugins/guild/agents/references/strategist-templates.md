# Document templates — plan overview, task brief, ADR

The three markdown shapes Step 4 and Step 4.5 write to files before hexing them into the
database.

## The plan overview (Step 4a)

Written to `/tmp/plan-overview.md`, becomes the plan's `body`. `title` is a **column**,
projected by every reader — do NOT write YAML frontmatter into the body; there is nothing to
parse it and it will render as text.

**The section list is your domain profile's (Slot 4).** Below is the shape every profile
shares; the profile adds its own survey section — on `software` that is `## Codebase
Analysis` — and may rename `Implementation Tasks` to whatever the domain calls a unit of work.

```markdown
# {Feature} Implementation Plan

## Architecture Overview

{High-level design: components, their relationships, data flow}

{PROFILE SURVEY SECTION — software: "## Codebase Analysis", with what exists today
 that's relevant, existing patterns to follow, and integration points}

## Implementation Tasks

### 1. {Task Title} (complexity: {1|2|3})
- **Summary**: {One line — the full brief is that ticket's `objective`}
- **Depends on**: {Prerequisites, if any}

### 2. {Task Title} (complexity: {1|2|3})
{...repeat — one entry per developer task...}

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| {What} | {Choice} | {Why} |

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| {Risk} | {Impact} | {How to handle} |
```

## The task brief (Step 4b)

One per developer task. This text becomes that ticket's `objective`, hexed from the file you
wrote it to.

**The section list is your domain profile's (Slot 5).** `Objective`, `Approach` and
`Acceptance Criteria` are the method's and appear in every domain; the profile supplies the
contention section and the hand-off section.

```markdown
# {Task Title} (complexity: {1|2|3})

## Objective
{Specific deliverable for this task only}

{PROFILE CONTENTION SECTION — software: "## Files to Touch", one line per file:
 `path/to/file.ext` — {create | modify} — {what changes}}

## Approach
{Step-by-step approach, patterns to follow, existing work to mirror}

{PROFILE HAND-OFF SECTION — software: "## Interface Contract", what this task exposes to
 or consumes from sibling tasks: function signatures, types, events, routes}

## Acceptance Criteria
- [ ] {Specific, verifiable outcome}
```

**Rules:**
- One overview (the plan's `body`). One task brief per developer task, written to that
  ticket's `objective`, hexed from the file you composed it in.
- **One implement ticket per unit of work, always.** The `implement` node fans out per ticket;
  work folded into a sibling's ticket is work the graph cannot see as its own node.
- **The contention section must be accurate and complete** — it is the basis for
  parallel-group disjointness, and it is literally the ticket's `files` assertion. If a ticket
  ends up owning something you didn't list, two grouped members contend for it. Nothing in the
  schema checks this for you. List everything the task will claim; if you cannot bound the set
  confidently, leave that task ungrouped and store what you are sure of.
- Task briefs are self-contained — a member should not need to read the overview or sibling
  briefs to start work. The hand-off section is what makes this possible.
- Base everything on what you actually surveyed, not assumptions.
- Downstream agents orient from the overview — keep it consistent with the tickets.

## The ADR (Step 4.5)

The sections people skip are the ones with the value:

```markdown
# {State the decision, not the topic}

## Context
{What was true that forced a choice. The constraint, not the feature.}

## Decision
{What we are doing, present tense, one or two sentences.}

## Alternatives considered
- **{Option}** — {why not}

## Consequences
{What it costs. What it makes easy. What it makes hard.
 An ADR with no negative consequence has not been thought about.}
```
