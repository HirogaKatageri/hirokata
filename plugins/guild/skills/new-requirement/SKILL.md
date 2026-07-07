---
name: new-requirement
description: >
  This skill should be used when the user asks to "add a requirement",
  "new requirement", "I need a feature", "add to the guild", "create requirement",
  "queue a feature", "I want to build", or wants to add a new work item to the
  guild board. Runs a live 3-way interview between the product-owner, the
  architect, and the user, then writes the requirement doc, the implementation
  plan, and the developer/test-planner/reviewer tickets — all before this skill
  returns.
version: 3.0.0
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

Read `.guild/state.yaml` (it holds only `last-checkin`).

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

### 3. Create the Requirement Stub

```bash
read REQ _ < <("$GUILD" new req --title "{title}" --desc "{description}" --date {today})
```

`$REQ` is now the requirement ID (e.g. `REQ-001`). The CLI scaffolds the template (Summary / User
Stories / Technical Considerations / Out of Scope) in `requirements/todo/`.

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
  prompt: "You're gathering requirements for {REQ} — \"{title}\". Requirement path:
           {`guild path REQ-NNN`}. Seed description: {description}. Today's date: {today}.
           Interview mode: {MODE}. {if team: 'The architect is running concurrently and you can
           SendMessage it by name (\"architect\") for cross-talk.'} {if relay: 'The architect is
           running concurrently; the orchestrator will relay relevant context between you.'}
           Report done when the requirement doc is complete, or report the bug-fix short-circuit
           per your own instructions if this turns out to be a simple fix."
)
Agent(
  subagent_type: "guild:architect",
  prompt: "You're planning for {REQ} — \"{title}\", currently being interviewed by the
           product-owner (requirement path: {`guild path REQ-NNN`}, still a stub — it will fill in
           as the interview proceeds). Interview mode: {MODE}. {if team: 'The product-owner is
           running concurrently and you can SendMessage it by name (\"product-owner\") for
           cross-talk.'} {if relay: 'The product-owner is running concurrently; the orchestrator
           will relay relevant context between you.'} Start exploring the codebase now (your
           workflow Steps 1-2) and raise any technical questions that should shape scope via
           NEEDS INPUT. Do NOT write the plan yet — wait for the orchestrator to tell you the
           requirement is finalized before your Design/Write-Plan steps. Today's date: {today}."
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
- If it took the **bug-fix short-circuit** (created its own fix/test-writer/reviewer tickets via
  Bash, per its own instructions), tell the architect to stop — this doesn't need a plan — and
  `TaskStop` its session. Skip to Step 7.
- Otherwise, once the product-owner is done, `SendMessage` the architect: "The requirement is
  final at {path} — proceed to Design and Write the Plan." Keep relaying any further architect
  `NEEDS INPUT` rounds until it reports done.

**Architect reports done:** it will report PLAN-NNN's path and the ticket IDs it created
(developer(s), test-planner, reviewer) — no further action needed from you; it created them
directly via the CLI.

### 7. Confirm

```
Requirement planned!

  Requirement: {REQ} — {title}
  Plan: {PLAN-NNN} (or "none — simple fix, no plan needed")
  Tickets created: {list of TASK-NNN — title (agent)}

Run /guild:check-in to start building.
```

## Rules

- **IDs are derived by the CLI** — never hand-assign or zero-pad IDs yourself; `guild new`
  computes the next ID from the filesystem.
- **No `status` field** — status is the containing directory. `guild new req` places the stub in
  `requirements/todo/` directly; the architect's `guild new task` calls place tickets in
  `tasks/todo/` directly.
- **This skill does not return until planning is complete** — unlike the old flow, there is no
  hand-off to a later check-in for requirement-gathering or planning. Both happen here, live.
- **Never let a subagent try `AskUserQuestion` itself** — team mode or not, only you can ask the
  real user. Both product-owner and architect always relay via `NEEDS INPUT`.
- **`--parallel-group` and `--plan-slice` are the architect's to set** — it designs the developer
  ticket waves itself; you only need to relay questions and forward context, not manage ticket
  frontmatter.
