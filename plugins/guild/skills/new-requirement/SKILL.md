---
name: new-requirement
description: >
  This skill should be used when the user asks to "add a requirement",
  "new requirement", "I need a feature", "add to the guild", "create requirement",
  "queue a feature", "I want to build", or wants to add a new work item to the
  guild board. Runs a live 3-way interview between the product-owner, the
  architect, and the user, places the requirement in the guild's direction (or
  deliberately leaves it unaffiliated), then writes the requirement doc, the
  implementation plan, and the developer/test-planner/reviewer tickets — all
  before this skill returns.
version: 3.1.0
user-invocable: true
arguments:
  - name: title
    description: Short title for the requirement
    required: false
  - name: description
    description: Brief description of what is needed
    required: false
---

# New Requirement — Add Work to the Guild

Run the product-owner and architect through a live interview with the user, then hand the board a
fully-planned requirement: a requirement doc, an implementation plan, and every developer/
test-planner/reviewer ticket needed to build it. Unlike the rest of the guild's pipeline, none of
this is ticket-dispatched — you (the orchestrator) spawn both agents directly and moderate the
conversation until the user says it's done.

All deterministic state operations go through the guild CLI. Bind it once:

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
```

## Arguments

Parse from `$ARGUMENTS` or user input:

| Argument | Description |
|----------|-------------|
| `title` | Short title for the requirement (e.g., "User Authentication") |
| `description` | Brief description of what's needed |

## Steps

### 1. Check for Guild

Check for `.guild/config.yaml` — that is what marks a v5 guild (there is no `state.yaml`).

If not found:
```
No guild found. Run /guild:check-in to initialize first.
```
Stop here.

### 1.5. Offer to Clear the Board

Detect existing items via the CLI rather than counting files:

```bash
"$GUILD" list req
"$GUILD" list task
"$GUILD" list plan
```

If any of these print items, ask the user (use the counts from the list output):

```
The guild board currently has {N} requirements, {N} tasks, and {N} plans.
Clear the board before adding this new requirement? (yes / no)
```

**If "yes"**: Invoke the `guild:clear-board` skill (it will handle confirmation and deletion), then proceed.

**If "no"**: Proceed without changes.

If all three lists are empty, skip this step.

### 2. Gather a Seed Title/Description

If `title` is not provided, ask the user:
```
What's the title of this requirement? (e.g., "User Authentication", "Payment Integration")
```

If `description` is not provided, ask the user:
```
Briefly describe what you need. The product-owner will dig into full details in the interview.
```

This is just a seed — the interview in Step 5 is where the real detail gets gathered.

### 2.5. Read the Guild's Direction

Goals and phases are the layer *above* requirements, and a requirement's phase is what makes it
appear under `Direction:` in `guild brief` and on the dashboard's Roadmap. Read what already exists
now — you need it twice: as context for the product-owner (Step 5) and to build the placement
question (Step 6.5).

```bash
"$GUILD" goal list      # <GOAL-ID> <status> <priority> <phases-done>/<total> <title>
"$GUILD" phase list     # <PHASE-ID> <GOAL-ID> <ordinal> <status> <reqs-done>/<total> <title>
```

If both print nothing, the guild has no direction yet. That is normal on a young board and is
**not** a problem to fix before proceeding.

**Do not create a goal or a phase here.** Direction is the guild master's call — Step 6.5 is where
the user makes it.

### 3. Do NOT Create the Requirement Yet

**The product-owner creates it, at the end of the interview.** In v4 the requirement was a FILE,
so this step scaffolded a stub and the product-owner filled it in by Editing it. In v5 the board
is a database, nothing hands out a writable path, and Stage 1 has no writer for a requirement body
*after* creation — so a stub created here would stay a stub forever.

The product-owner therefore composes the whole document and creates the row in one call
(`guild new req --title … --body …`), then reports the REQ ID back to you. Everything downstream
— the architect's plan, every ticket — uses that ID.

You can still show the user what number it will land on:

```bash
"$GUILD" next-id req     # e.g. 001 — indicative only, not reserved
```

### 4. Detect the Interview Mode

```bash
if [ -n "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" ] && [ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS}" != "0" ] && [ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS}" != "false" ]; then
  MODE=team
else
  MODE=relay
fi
```

Both modes run the same interview shape — product-owner and architect spawned concurrently, both
still relaying user-facing questions through you via `NEEDS INPUT` (whether or not Agent Teams is
active, `AskUserQuestion` is not confirmed to work for teammates, so never skip the relay for
user-facing questions). The only difference is **how the two agents exchange context with each
other**:

- **`team`**: tell each agent it can `SendMessage` the other directly by name (`"product-owner"`,
  `"architect"`) for cross-talk — a technical constraint, a scope clarification, a question one
  should answer for the other.
- **`relay`** (default, always safe): you manually forward short "FYI" summaries between them via
  `SendMessage` to each agent's ID whenever one surfaces something the other should know.

If anything about team mode misbehaves (a teammate send fails, an agent seems stuck expecting a
teammate response that never arrives), fall back to `relay` for the rest of this session — don't
let an experimental feature stall the interview.

### 5. Spawn the Product-Owner and Architect

Spawn both **in the same message** so they run concurrently:

```
Agent(
  subagent_type: "guild:product-owner",
  prompt: "You're gathering requirements for a new feature — \"{title}\". There is NO
           requirement row yet: compose the document, then create it yourself with
           `guild new req --title ... --date {today} --body ...` and report the REQ ID.
           Seed description: {description}. Today's date: {today}.
           Interview mode: {MODE}. {if team: 'The architect is running concurrently and you can
           SendMessage it by name (\"architect\") for cross-talk.'} {if relay: 'The architect is
           running concurrently; the orchestrator will relay relevant context between you.'}
           Current direction (Step 2.5): {one line per goal and phase, or 'none declared yet'}.
           End your report with a one-line Placement proposal — an existing PHASE id, a new
           goal/phase you'd suggest, or none at all. It is a recommendation for the user, not a
           decision: do NOT run goal new / phase new / req assign yourself.
           Report done when the requirement doc is complete, or report the bug-fix short-circuit
           per your own instructions if this turns out to be a simple fix."
)
Agent(
  subagent_type: "guild:architect",
  prompt: "You're planning for a new feature — \"{title}\", currently being interviewed by the
           product-owner. The requirement row does not exist yet; the product-owner creates it
           when the interview concludes and I will send you its REQ ID then. Read it with
           `guild read REQ-NNN` at that point. Interview mode: {MODE}. {if team: 'The product-owner is
           running concurrently and you can SendMessage it by name (\"product-owner\") for
           cross-talk.'} {if relay: 'The product-owner is running concurrently; the orchestrator
           will relay relevant context between you.'} Start exploring the codebase now (your
           workflow Steps 1-2) and raise any technical questions that should shape scope via
           NEEDS INPUT. Do NOT write the plan yet — wait for the orchestrator to tell you the
           requirement is finalized before your Design/Write-Plan steps. I will also tell you
           which phase (if any) the requirement lands on; goals and phases are the guild
           master's to set, so never run goal new / phase new / req assign yourself.
           Today's date: {today}."
)
```

### 6. Moderate the Interview Loop

Both agents may pause with a `NEEDS INPUT:` block (same relay protocol as the rest of the guild) —
this can happen from either one, in any order, since they run concurrently:

1. Whichever agent's completion notification carries `NEEDS INPUT:`, call **AskUserQuestion**
   yourself with exactly those questions.
2. `SendMessage` the answers back to that same agent instance to resume it.
3. **`relay` mode only**: if the answer (or the agent's own framing) reveals something the *other*
   agent should know — a scope decision, a technical constraint — send a short FYI to the other
   agent's instance too (not a question, just context: `"FYI: user decided X"` /
   `"FYI: architect flagged Y — factor it into scope"`).
4. Repeat until an agent reports done, or the user signals they're finished with the discussion.

**The user decides when the interview ends — watch for it in any answer**, not just an explicit
"done": phrases like "let's finalize", "that's enough for now", "go with what you have" mean stop
asking. When you see this, `SendMessage` both agents to wrap up immediately — finalize their
current draft without further questions — rather than continuing the round-robin.

**Product-owner reports done:**
It reports the **REQ ID it created** — record it as `$REQ`; every later step needs it.

- If it took the **bug-fix short-circuit** (created the requirement plus its own
  fix/test-writer/reviewer tickets via Bash, per its own instructions), tell the architect to
  stop — this doesn't need a plan — and `TaskStop` its session. Skip to Step 6.5, where the
  placement question is usually a one-liner the user answers "unaffiliated" to.
- Otherwise `SendMessage` the architect: "The requirement is final: it is {REQ} — read it with
  `guild read {REQ}` and proceed to Design and Write the Plan." Keep relaying any further
  architect `NEEDS INPUT` rounds until it reports done.

**Architect reports done:** it will report the PLAN-NNN id and the ticket IDs it created
(developer(s), test-planner, reviewer) — no further action needed from you; it created them
directly via the CLI.

### 6.5. Place the Requirement in the Direction

Run this as soon as you have `$REQ` — you do not have to wait for the architect to finish planning.
**Ask the user; never decide for them.** The product-owner's report ends with a `Placement:` line;
that is a recommendation to put in front of the user, not an answer.

Ask once, with **AskUserQuestion**, offering only the choices that apply (drop the rest):

| Choice | What you run |
|---|---|
| An existing phase — one option per plausible phase from Step 2.5, the product-owner's proposal first, labelled like `PHASE-002 · Cart & coupon rework` | `"$GUILD" req assign {REQ} PHASE-NNN` |
| A new phase under an existing goal | `"$GUILD" phase new --goal GOAL-NNN --title "{phase title}" --date {today}` → then `"$GUILD" req assign {REQ} PHASE-NNN` |
| A new goal *and* its first phase | `"$GUILD" goal new --title "{goal title}" --priority {1-5, default 3} --date {today}` → `"$GUILD" phase new --goal GOAL-NNN --title "{phase title}" --date {today}` → `"$GUILD" req assign {REQ} PHASE-NNN` |
| **Leave it unaffiliated** | nothing — `requirement.phase_id` stays NULL |

Phrase the question so the last choice reads as neutral as the others, e.g.:

```
Where does {REQ} belong? "Leave it unaffiliated" is a real answer — small work
does not need a goal.
```

**Rules for this step:**

- **Unaffiliated is a first-class choice, not a failure.** `requirement.phase_id` is nullable by
  design and `guild req assign {REQ} none` detaches one later, so nothing here is permanent. Record
  it and move on — no warning, no "are you sure", no second ask.
- **Offer, never force.** Ask exactly once. If the user picks a new goal or phase, collect its title
  (and the goal's priority) in that same round or one short follow-up — this is a placement
  question, not a second interview.
- **Never create a goal or a phase the user did not ask for.** If the answer is ambiguous or the
  user skips the question, leave the requirement unaffiliated and say so in Step 7.
- **No direction on the board yet?** Still offer, but keep it to two choices — "start a goal for
  this" / "leave it unaffiliated" — and one line. A guild with no goals is not a broken guild.
- If the requirement lands on a phase and you are in `relay` mode, send the architect a one-line
  FYI (`"FYI: {REQ} is on PHASE-002 (Cart & coupon rework), under GOAL-001 …"`) so the plan can stay
  consistent with that phase's other requirements.

### 7. Confirm

```
Requirement planned!

  Requirement: {REQ} — {title}
  Direction: {PHASE-NNN — phase title (GOAL-NNN — goal title)}
             (or "unaffiliated — not attached to a goal")
  Plan: {PLAN-NNN} (or "none — simple fix, no plan needed")
  Tickets created: {list of TASK-NNN — title (agent)}

Run /guild:check-in to start building.
```

Report a new goal or phase you created on the user's instruction on its own line, so they can see
what the answer actually produced.

## Rules

- **IDs are derived by the CLI** — never hand-assign or zero-pad IDs yourself; `guild new`
  derives the next ID in the same SQL statement that inserts the row, so it cannot collide.
- **Status is a COLUMN, not a directory** — there are no `requirements/todo/` or `tasks/todo/`
  directories in v5. Everything created by `guild new` starts at `todo`, and only the
  orchestrator moves it (`guild move`).
- **Documents are written at creation** — `guild new … --body` is the whole write surface for a
  requirement or plan document. There is no `Edit the file`, because there is no file.
- **This skill does not return until planning is complete** — unlike the old flow, there is no
  hand-off to a later check-in for requirement-gathering or planning. Both happen here, live.
- **Never let a subagent try `AskUserQuestion` itself** — team mode or not, only you can ask the
  real user. Both product-owner and architect always relay via `NEEDS INPUT`.
- **Direction is the guild master's call** — `guild goal new`, `guild phase new` and
  `guild req assign` are yours alone, run only in Step 6.5 on an explicit answer from the user. The
  product-owner proposes a placement and the architect may flag a mismatch; neither of them files
  anything under a goal, and neither do you without being told to.
- **A requirement with no phase is a finished requirement** — `phase_id` is nullable by design.
  Never block, re-ask, or apologise because the user chose to leave one unaffiliated.
- **`--parallel-group` and `--plan-slice` are the architect's to set** — it designs the developer
  ticket waves itself; you only need to relay questions and forward context, not manage ticket
  frontmatter.
