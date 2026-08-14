---
name: new-requirement
description: >
  This skill should be used when the user asks to "add a requirement",
  "new requirement", "I need a feature", "add to the guild", "create requirement",
  "queue a feature", "I want to build", or wants to add a new work item to the
  guild board. Runs a live 3-way interview between the product-owner, the
  architect, and the user, places the requirement in the guild's direction (or
  deliberately leaves it unaffiliated), then writes the requirement doc, the
  implementation plan and its slices, the developer/test-planner/reviewer tickets,
  and the requirement's execution graph — and ends at `gate-plan`, where the guild
  master approves the plan before anything is built.
version: 4.0.0
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
fully-planned requirement: a requirement doc, an implementation plan and its slices, every
developer/test-planner/reviewer ticket needed to build it, and the **execution graph** that says
what runs when. Unlike the rest of the guild's pipeline, none of this is ticket-dispatched — you
(the orchestrator) spawn both agents directly and moderate the conversation until the user says
it's done.

## Where this skill stops: `gate-plan`

**This skill plans. It does not build.** It ends by presenting the plan at `gate-plan` — the first
of the guild's two gates, and the whole point of the gate model:

> **The plan is the cheapest place to change your mind.** Approving it costs one decision and
> redirects everything downstream. After that, the guild runs to completion without stopping, and
> the problems it finds are collected and judged together at the second gate, `gate-repairs`.

So the last thing you do here is put the plan in front of the guild master and record their answer
(Step 7). **Nothing is dispatched, nothing is implemented, no ticket is moved out of `todo` until
that approval exists.** If they approve, `/guild:check-in` runs the first segment. If they don't,
the requirement sits with a pending gate and the board is unchanged — which is exactly what a plan
gate is for.

**Only you can ask.** Subagents cannot call `AskUserQuestion`, which is why a gate can never live
inside a dispatched workflow and why this skill — the orchestrator session — is where it happens.

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

### 2.6. Load the Roster

The architect writes tickets that name a **capability**, not a member (design §5), and the matcher
can only see members that have been synced. Run this before spawning it:

```bash
"$GUILD" sync-agents
```

It scans `agents/*.md` and reconciles the roster. It is **idempotent and quiet** — a second run with
nothing changed prints `the roster is already up to date — nothing was written` and appends no
journal line, so it is safe on every invocation. New files are enlisted, changed ones updated,
removed ones deactivated (never deleted — a finished task may still name one).

**Why this is not optional:** on an unsynced guild the roster is empty, so a ticket declaring
`--needs implement` matches nobody and lands `blocked` the moment check-in reaches it. Verified: the
same ticket that matches `developer` on a synced board reports
`no guild member can take this bounty` on an unsynced one. (A ticket that names `--agent NAME`
directly is unaffected and works with no roster at all — that is the v4 path, and it still works.)

Two failures worth recognizing rather than working around:

- **`could not find the agents/ directory`** — the CLI looks at `$GUILD_AGENTS_DIR`, then
  `$CLAUDE_PLUGIN_ROOT/agents`, then `scripts/../../agents`. Report it; do not guess a path.
- **`the roster declares N capability(ies) the guild's vocabulary does not have`** — an agent file
  carries a tag with no `capability_request` behind it, and **nothing was written**. This is the
  vocabulary guard (§5.3) working, not a bug. Show the message; the fix is either to file the gap
  (Step 6.6) or to correct the typo in the agent file.

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
           The roster is loaded ({N} active members) — declare each ticket's capabilities with
           --needs / --prefers per your Step 3.5. If the plan needs a capability outside the
           §5.3 vocabulary, follow your Step 3.6: file the capability-request, then raise it as
           a `NEEDS INPUT: ROSTER GAP` block and hold that slice's ticket until I answer. You
           may not create an agent file; only the guild master can.
           Your deliverable is the FULL Step 4-6 set: the plan, its SLICES (`guild plan slice`,
           with each slice's --files — that is the disjoint-file assertion parallel dispatch
           depends on), the tickets, and then the EXECUTION GRAPH — `guild graph new {REQ}
           --template standard`, any deviations via `guild graph deviate` each carrying a
           reason, and `guild graph validate {REQ}` passing before you report. Slices and
           tickets must exist BEFORE `graph new`, which binds nodes to them and refuses to run
           twice. You may not add or drop a gate. Stop at `gate-plan`: do not approve it, do not
           dispatch anything, do not move a ticket's status — the guild master approves the plan
           and I present it to them.
           Today's date: {today}."
)
```

### 6. Moderate the Interview Loop

Both agents may pause with a `NEEDS INPUT:` block (same relay protocol as the rest of the guild) —
this can happen from either one, in any order, since they run concurrently:

1. Whichever agent's completion notification carries `NEEDS INPUT:`, call **AskUserQuestion**
   yourself with exactly those questions. **One kind of question is not a plain question — an
   architect block whose first line reads `ROSTER GAP` is handled by Step 6.6.**
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

**Architect reports done:** it reports the PLAN-NNN id, the slices it wrote, the ticket IDs it
created (developer(s), test-planner, reviewer), and **the graph** — which template, how many nodes,
every deviation with its reason, and that `guild graph validate` passes. It created all of that
directly via the CLI; you do not re-create any of it. Go to Step 6.7 and check the graph yourself
before you take anything to the user.

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
  user skips the question, leave the requirement unaffiliated and say so in Step 8.
- **No direction on the board yet?** Still offer, but keep it to two choices — "start a goal for
  this" / "leave it unaffiliated" — and one line. A guild with no goals is not a broken guild.
- If the requirement lands on a phase and you are in `relay` mode, send the architect a one-line
  FYI (`"FYI: {REQ} is on PHASE-002 (Cart & coupon rework), under GOAL-001 …"`) so the plan can stay
  consistent with that phase's other requirements.

### 6.6. Recruiting — the Architect Hit a Roster Gap (§5.4)

This step runs **only** when the architect's `NEEDS INPUT:` block opens with `ROSTER GAP`. It means
the plan needs a capability no guild member has, the architect has already filed a
`capability_request` recording it, and it is now the **guild master's decision** — the roster is
their layer, exactly like goals and phases.

> **Nothing here creates an agent without the user saying so.** Not you, not the architect, not on a
> "reasonable inference". An agent file is a permanent addition to the guild.

**Why this is decided live rather than at `gate-plan`.** The request is a permanent record and it
**also surfaces at `gate-plan`** with the plan (§5.4) — but the architect cannot write the affected
slice's ticket until it knows the answer, and its session does not survive the gate. So the decision
happens here, and Step 7 reports what was decided plus anything still `open`. Either way the rule is
the same: **an agent is never created behind the guild master's back.**

**1. Read the gap back before you ask.** The architect's block is a claim; this is the record:

```bash
"$GUILD" capability-requests --open
# "<id> <status> <capability> <req> <proposed-agent> <why>"
# 1 open rust REQ-001 developer-rust Three plan slices are Rust crates; developer has no Rust idiom…
```

**2. Ask once, with AskUserQuestion**, offering §5.4's three answers. Put the rationale and the
proposed spec in the question body so the decision is informed:

| Choice | What it means |
|---|---|
| **Create `{proposed-agent}`** | The guild grows a permanent new member. The next requirement needing this capability finds it already there. |
| **Assign to `{existing member}` anyway** | The work goes to a generalist. The gap stays on the record, because the guild still cannot do this work well. |
| **Revise the plan** | The architect re-slices so the capability is not needed. Collect what the user wants changed. |

**3a. On "create":**

1. Scaffold the agent file from the architect's proposed spec. It goes in the guild's agents
   directory — `$GUILD_AGENTS_DIR` if set, otherwise `${CLAUDE_PLUGIN_ROOT}/agents/{name}.md`. The
   frontmatter shape the scanner supports is narrow and it **refuses** anything else rather than
   guessing; keys must sit at column 0:

   ```markdown
   ---
   name: developer-rust
   model: sonnet
   color: orange
   tools: ["Read", "Grep", "Glob", "Write", "Edit", "Bash"]
   capabilities: [implement, backend, rust]
   serial: false
   description: |
     Use this agent when the guild needs idiomatic Rust implementation. …
   ---

   # Rust Developer — Guild Agent
   {the role, the workflow, the close-out protocol — mirror an existing agent of the same shape}
   ```

   `plugin-dev:agent-development` is the skill to load if you want help writing the body well.
2. **Show the user the file and get their sign-off before syncing.** They asked for a member, not
   for whatever you wrote; this is a review, not a notification.
3. Admit it to the roster:

   ```bash
   "$GUILD" sync-agents
   ```

   Expect `new  developer-rust` in the output. `sync-agents` also moves the capability request from
   `open` to `created`, which is what removes it from `guild brief`'s Roster Gaps — confirm with
   `"$GUILD" capability-requests`.
4. `SendMessage` the architect: `"Roster gap resolved: developer-rust is on the roster and declares
   [implement, backend, rust]. Create the held tickets with --needs implement,rust."`

   **If `sync-agents` refuses** with `the roster declares N capability(ies) the guild's vocabulary
   does not have`, the file carries a tag the request did not legitimize (a typo, or a second
   capability nobody filed for). **Nothing was written.** Fix the file's `capabilities:` line to
   match the filed capability and sync again — do not file a second request to paper over a typo.

   **A newly added agent file is on the roster immediately, but the `Agent` tool resolves
   `subagent_type: "guild:{name}"` from the plugin manifest the session loaded at startup.** If a
   later dispatch reports an unknown subagent type, that is what happened: tell the user to restart
   Claude Code, and until they do, the ticket is dispatchable only by pinning it to an existing
   member.

**3b. On "assign anyway":** `SendMessage` the architect the member's name and let *it* create the
tickets — `--agent developer --needs implement,rust`, so the board records both the pin and what the
work actually required. **You do not create these tickets and you do not edit the ones it made:
there is no command that changes a task's agent or capabilities after creation.**

Two things to say out loud, because both look like problems later and neither is:

- **The request stays open.** Nothing sets a request to `declined`, so `rust` keeps appearing under
  **Roster Gaps** in every `guild brief` until somebody recruits for it. That is the design working —
  the guild still cannot do this work well.
- **`guild bounties` will call the pinned ticket blocked.** `match` answers the capability question
  and ignores the pin, so the row reads `blocked - REQ-001 no-eligible-agent:implement,rust`.
  Verified: the ticket is still dispatchable — `guild next` returns it and `guild brief` lists it as
  a normal `developer` bounty. Check-in dispatches on the `agent` field and never parks a pinned
  ticket, so nothing is actually stuck.

**3c. On "revise the plan":** `SendMessage` the architect what the user wants changed and let it
re-slice. The same note about the request staying open applies.

**4. Never do any of these:** write an agent file the user did not approve; run
`guild capability-request` yourself (the architect files it — you resolve it); create or re-create a
ticket to work around a gap; or treat "the user did not answer" as consent. If the answer is
ambiguous, ask again rather than picking.

### 6.7. Check the Graph Before You Take It to the User

The architect says the graph validates. **Check it yourself** — it costs one command, it reads only,
and a graph that does not validate is a run nothing can start:

```bash
"$GUILD" graph validate "$REQ"     # exit 0 and one line, or exit 1 listing every FAIL
"$GUILD" graph "$REQ" --explain    # template vs actual, side by side, with every deviation reason
```

`--explain` is what you read at the gate: it prints the `standard` template and the actual graph next
to each other, so a deviation is a diff against a known baseline rather than a bespoke shape you have
to reason about from scratch.

**If `validate` fails**, do not fix it by hand. `SendMessage` the architect the exact FAIL lines and
have it correct the graph — deviations are its record and its reasoning, and a graph repaired by the
orchestrator has a shape nobody justified. Common codes and what they mean:

| Code | What happened |
|---|---|
| `no-graph` | the architect never ran `guild graph new` — send it back |
| `empty-reason` | a deviation with no justification behind it |
| `added-gate` / `dropped-gate` | the two-gate rule was broken; this one is never negotiable |
| `dropped-required` | `implement` or `review` was dropped; they may be reshaped, never dropped |
| `added-node-no-reason` / `dropped-node-no-reason` | the shape changed and nothing recorded why |
| `unknown-capability` | an added node names a capability no active member has — that is a roster gap (Step 6.6), not a graph problem to paper over |

**If the architect took the bug-fix short-circuit** (Step 6, no plan), there is no graph and there is
nothing to validate — skip this step and Step 7's gate; a simple fix does not get a plan gate,
because there is no plan to approve. Say so plainly in Step 8 and let check-in pick the tickets up.

### 7. `gate-plan` — Present the Plan, and Stop

**This is where the skill ends and the guild master decides.** Everything up to here is a proposal.

**1. Read the gate's own prompt** — the template wrote it, so use it rather than inventing wording:

```bash
"$GUILD" graph "$REQ"      # the gate row prints with its prompt, e.g.
                           # gate-plan  pending  "Plan for REQ-007 is ready for review. Approve implementation?"
```

The gate's node id is `{REQ}/gate-plan` — that is what `guild gate` takes.

**2. Present it.** Give the user enough to decide in one pass, and keep it short — the plan itself is
one `guild read PLAN-NNN` away if they want it:

```
REQ-007 — Session-backed authentication
  Plan: PLAN-004 · 3 slices (auth-service, session-store, migrations) — file sets disjoint
  Graph: standard · 9 nodes · 1 deviation
    + research (before implement) — "the payments provider's webhook API is undocumented
      in the repo and no .guild/docs/ file covers it"
  Tickets: TASK-011 (implement,backend) · TASK-012, TASK-013 (wave A) ·
           TASK-014 test-planning · TASK-015 reviewer
  Then: implement → test-plan → test-write → review, running to completion without stopping,
        and stopping next at gate-repairs.

⚠ Roster gap: `rust` — capability request 3, still open. Assigned to `developer` for now.

Approve implementation?
```

Include the roster-gap block **only** when a `capability_request` is still `open`
(`"$GUILD" capability-requests --open`) — §5.4 puts it in front of the guild master at this gate,
with the plan, as part of the same decision.

**3. Ask with AskUserQuestion.** Three answers, and all three are real:

| Answer | What you run | What happens next |
|---|---|---|
| **Approve** | `"$GUILD" gate "$REQ"/gate-plan --approve` | The plan is committed. `/guild:check-in` runs the first segment |
| **Reject** | `"$GUILD" gate "$REQ"/gate-plan --reject --decision "{their reason}"` | Nothing gets built. The plan and the graph stay on the board as the record of what was proposed and refused |
| **Not yet / let me think** | nothing | The gate stays `pending`. Check-in will present it again |

Pass the user's own words through `--decision` when they give any — a bare approval is a decision
with no reasoning attached, and six weeks later the reasoning is the part anyone wants.

**4. Then stop. Do not build.** Approval is not a dispatch:

- Do **not** spawn a developer, a test-planner or a reviewer.
- Do **not** move any ticket out of `todo`.
- Do **not** run `guild segment`, and do not compile a workflow.

`/guild:check-in` is what runs the approved segment, and it will find the gate approved and the
graph waiting. **The one thing this skill must never do is treat its own plan as permission to
execute it** — the whole value of a plan gate is that it belongs to somebody who is not the planner.

### 8. Confirm

```
Requirement planned!

  Requirement: {REQ} — {title}
  Direction: {PHASE-NNN — phase title (GOAL-NNN — goal title)}
             (or "unaffiliated — not attached to a goal")
  Plan: {PLAN-NNN} — {N} slices (or "none — simple fix, no plan needed")
  Graph: {standard · N nodes · N deviations} (or "none — simple fix, no graph")
  Tickets created: {list of TASK-NNN — title (needs: cap,cap | agent NAME)}
  Roster: {"developer-rust added on your approval — 15 members" | omit the line}
  gate-plan: APPROVED — run /guild:check-in to build it.
```

**The last line is the one that changed, and it must tell the truth about what will happen next.**
Use whichever applies:

| Gate state | Line |
|---|---|
| Approved | `gate-plan: APPROVED — run /guild:check-in to build it.` |
| Rejected | `gate-plan: REJECTED — nothing will be built. The plan and graph stay on the board.` |
| Still pending | `gate-plan: PENDING your approval — nothing is built until you approve it. /guild:check-in will ask again.` |
| No graph (bug-fix short-circuit) | `No plan gate — this was a simple fix. Run /guild:check-in to work the tickets.` |

Never print "run check-in to start building" under a gate that is pending or rejected: that is the
one sentence that would make an unapproved plan look approved.

Report a new goal or phase you created on the user's instruction on its own line, so they can see
what the answer actually produced. Do the same for a new guild member: adding to the roster is the
other thing this skill can do that outlives the requirement.

**If any roster gap was left unresolved** (the user chose "assign anyway" or "revise"), add one line
so it is not a surprise later:

```
  Open roster gap: `rust` — assigned to `developer` for now. It stays in `guild brief`
  under Roster Gaps until a member declares it.
```

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
- **This skill PLANS; it never BUILDS.** It ends at `gate-plan`. No developer is spawned, no ticket
  leaves `todo`, no segment is run, no workflow is compiled — regardless of how obviously good the
  plan is, and regardless of the user saying "yes" enthusiastically. Approval records a decision; it
  does not start work. `/guild:check-in` starts work.
- **The graph is the architect's artifact, and only the architect edits it** — `guild graph new`,
  `guild graph deviate` are its commands, not yours. You run the read-only ones (`guild graph`,
  `guild graph validate`) and send failures back. A graph the orchestrator patched has a shape
  nobody justified.
- **Two gates, fixed** — `gate-plan` here, `gate-repairs` after review. Never ask the architect for
  an extra approval point and never accept a graph that grew one: `guild graph validate` reports it
  as `added-gate`. A third gate reads as caution and is what turns an unattended run into a session
  that stops every twenty minutes.
- **`guild gate` is yours alone** — it records a guild-master decision, so it runs only on an
  explicit answer from the user, in Step 7, and never on inference. "They seemed happy with it" is
  not an approval.
- **Never let a subagent try `AskUserQuestion` itself** — team mode or not, only you can ask the
  real user. Both product-owner and architect always relay via `NEEDS INPUT`.
- **Direction is the guild master's call** — `guild goal new`, `guild phase new` and
  `guild req assign` are yours alone, run only in Step 6.5 on an explicit answer from the user. The
  product-owner proposes a placement and the architect may flag a mismatch; neither of them files
  anything under a goal, and neither do you without being told to.
- **A requirement with no phase is a finished requirement** — `phase_id` is nullable by design.
  Never block, re-ask, or apologise because the user chose to leave one unaffiliated.
- **`--parallel-group`, `--plan-slice`, `--needs` and `--prefers` are the architect's to set** — it
  designs the developer ticket waves and decides what each slice requires; you only need to relay
  questions and forward context, not manage ticket frontmatter.
- **Slices are the architect's too, and they are what the graph fans out over** — `guild plan slice`
  writes them with their `--files` disjointness assertion, and `implement` produces one node per
  slice. Do not write slices yourself and do not "help" by adding one; if a slice is missing or its
  file set is wrong, that is a message to the architect.
- **The roster is the guild master's layer, like goals and phases** — `guild sync-agents` is yours to
  run (Step 2.6, idempotent, safe); writing an `agents/*.md` file is the **user's decision alone**
  (Step 6.6). The architect proposes a member and files the gap; neither of you enlists one.
- **A capability request cannot be withdrawn** — it is created `open` and only `guild sync-agents`
  admitting a matching agent moves it (`open → created`). Nothing writes `declined`. So say plainly
  when a gap is being left open rather than letting it appear unexplained in the next brief.
- **A ticket's agent and capabilities are fixed at creation** — there is no `guild assign`. If a
  ticket is wrong, it is dropped and recreated by whoever created it, not edited.
