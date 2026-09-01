---
name: new-requirement
description: >
  This skill should be used when the user asks to "add a requirement",
  "new requirement", "I need a feature", "add to the guild", "create requirement",
  "queue a feature", "I want to build", or wants to add a new work item to the
  guild board. Runs a live 3-way interview between the product-owner, the
  architect, and the user, places the requirement in the guild's direction (or
  deliberately leaves it unaffiliated), then writes the requirement, the
  implementation plan, the developer/test-planner/reviewer tickets,
  and the requirement's execution graph — and ends at `gate-plan`, where the guild
  master approves the plan before anything is built.
version: 5.0.0
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

Run the product-owner and architect through a live interview with the user, then hand the board
a fully-planned requirement: the requirement itself, an implementation plan, every
ticket needed to build it, and the **execution graph** that says what runs when. Unlike the rest
of the guild's pipeline, none of this is ticket-dispatched — you (the orchestrator) spawn both
agents directly and moderate the conversation until the user says it's done.

**Load `guild:warehouse` first.** There is no guild CLI: `tursodb` is the tool and every write
below is SQL. The canonical statements — creating a requirement, a plan, a ticket with
its capabilities, instantiating a graph — are in `references/queries.md`; copy from there rather
than improvising.

## Where this skill stops: `gate-plan`

**This skill plans. It does not build.** It ends by presenting the plan at `gate-plan` — the
first of the guild's two gates, and the whole point of the gate model:

> **The plan is the cheapest place to change your mind.** Approving it costs one decision and
> redirects everything downstream. After that, the guild runs to completion without stopping,
> and the problems it finds are collected and judged together at `gate-repairs`.

So the last thing you do here is put the plan in front of the guild master and record their
answer (Step 7). **Nothing is dispatched, nothing is implemented, no ticket leaves `todo` until
that approval exists.** If they approve, `/guild:check-in` runs the first batch. If they don't,
the requirement sits with a pending gate and the board is unchanged — which is exactly what a
plan gate is for.

**Only you can ask.** Subagents cannot call `AskUserQuestion`, which is why a gate can never
live inside a dispatched workflow and why this skill — the orchestrator session — is where it
happens.

## Arguments

| Argument | Description |
|----------|-------------|
| `title` | Short title for the requirement (e.g., "User Authentication") |
| `description` | Brief description of what's needed |

## Steps

### 1. Check for Guild

`.guild/config.yaml` is what says a guild exists here. If it is missing:

```
No guild found. Run /guild:check-in to initialize first.
```

Stop there.

### 1.5. Offer to Clear the Board

```sql
SELECT (SELECT COUNT(*) FROM requirement) AS reqs,
       (SELECT COUNT(*) FROM task)        AS tasks,
       (SELECT COUNT(*) FROM plan)        AS plans;
```

If any are non-zero, ask:

```
The guild board currently has {N} requirements, {N} tasks, and {N} plans.
Clear the board before adding this new requirement? (yes / no)
```

**yes** → invoke `guild:clear-board` (it handles its own confirmation), then proceed.
**no** → proceed unchanged. All zero → skip this step.

### 2. Gather a Seed Title/Description

Ask for whichever was not supplied:

```
What's the title of this requirement? (e.g., "User Authentication", "Payment Integration")
Briefly describe what you need. The product-owner will dig into full details in the interview.
```

This is a seed — the interview in Step 5 gathers the real detail.

### 2.5. Read the Guild's Direction

Goals and phases are the layer *above* requirements, and a requirement's phase is what makes it
appear under Direction in the brief and on the dashboard's roadmap. Read what exists now — you
need it twice: as context for the product-owner (Step 5) and to build the placement question
(Step 6.5).

```sql
SELECT id, priority, current_phase_id, current_phase_title,
       requirements_done, requirements_total, title FROM v_goal_progress;
SELECT id, goal_id, ordinal, status, title FROM phase ORDER BY goal_id, ordinal;
```

Nothing back means the guild has no direction yet. That is normal on a young board and is
**not** a problem to fix before proceeding.

**Do not create a goal or a phase here.** Direction is the guild master's call — Step 6.5 is
where the user makes it.

### 2.6. Load the Roster

The architect writes tickets that name a **capability**, not a member, and the matcher can only
see synced members. Sync before spawning it: read every `agents/*.md` frontmatter (`name`,
`model`, `capabilities`, `serial`, `description`) and apply the upsert / capability-replace /
retire / admit block from `guild:warehouse` → `references/queries.md` §5. It is idempotent —
re-running with nothing changed rewrites the same rows.

Then audit what you wrote:

```sql
SELECT side, owner, capability FROM v_capability_unknown;
```

**Why this is not optional:** on an unsynced guild the roster is empty, so a ticket declaring
`implement` matches nobody and lands blocked the moment check-in reaches it. (A ticket that
pins `agent` directly is unaffected — that path never consults the roster.)

A row in `v_capability_unknown` is a tag outside the vocabulary. It inserts fine and then
**matches nobody, silently, forever.** Report it; the fix is either a `capability_request`
(Step 6.6) or a corrected agent file — never a shrug.

### 3. Do NOT Create the Requirement Yet

**The product-owner creates it, at the end of the interview**, in one INSERT that carries the
whole document in `body` (hex transport — a requirement body quotes code, and a `;` ending a
line would split the statement). It then reports the REQ id back to you, and everything
downstream uses that id.

You can show the user what number it will land on, but the id is derived inside the INSERT
itself, so it is indicative only:

```sql
SELECT 'REQ-' || printf('%03d', COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)), 0) + 1)
  FROM requirement;
```

### 4. Detect the Interview Mode

```bash
if [ -n "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" ] && [ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS}" != "0" ] && [ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS}" != "false" ]; then
  MODE=team
else
  MODE=relay
fi
```

Both modes run the same interview shape — product-owner and architect spawned concurrently,
both still relaying user-facing questions through you via `NEEDS INPUT` (whether or not Agent
Teams is active, `AskUserQuestion` is not confirmed to work for teammates, so **never skip the
relay for a user-facing question**). The only difference is how the two agents exchange context
with each other:

- **`team`**: tell each agent it can `SendMessage` the other directly by name
  (`"product-owner"`, `"architect"`) for cross-talk.
- **`relay`** (default, always safe): you manually forward short "FYI" summaries between them
  whenever one surfaces something the other should know.

If anything about team mode misbehaves, fall back to `relay` for the rest of the session — do
not let an experimental feature stall the interview.

### 5. Spawn the Product-Owner and Architect

Spawn both **in the same message** so they run concurrently:

```
Agent(
  subagent_type: "guild:product-owner",
  prompt: "You're gathering requirements for a new feature — \"{title}\". Load the
           guild:warehouse skill: there is no CLI, you write SQL. There is NO requirement
           row yet — compose the document, then create it yourself with the INSERT in
           queries.md §1 (body as CAST(x'<hex>' AS TEXT)) and report the REQ id it returns.
           Seed description: {description}. Today's date: {today}.
           Interview mode: {MODE}. {if team: 'The architect is running concurrently and you
           can SendMessage it by name (\"architect\") for cross-talk.'} {if relay: 'The
           architect is running concurrently; the orchestrator will relay context between you.'}
           Current direction (Step 2.5): {one line per goal and phase, or 'none declared yet'}.
           End your report with a one-line Placement proposal — an existing PHASE id, a new
           goal/phase you'd suggest, or none at all. It is a recommendation for the user, not
           a decision: do NOT insert a goal or a phase, and do not set requirement.phase_id.
           Report done when the requirement is complete, or report the bug-fix short-circuit
           per your own instructions if this turns out to be a simple fix."
)
Agent(
  subagent_type: "guild:architect",
  prompt: "You're planning for a new feature — \"{title}\", currently being interviewed by the
           product-owner. Load the guild:warehouse skill: there is no CLI, you write SQL.
           The requirement row does not exist yet; the product-owner creates it when the
           interview concludes and I will send you its REQ id then — read it with
           `SELECT body FROM requirement WHERE id = 'REQ-NNN'` at that point.
           Interview mode: {MODE}. {if team / if relay: as above}.
           Start exploring the codebase now (your workflow Steps 1-2) and raise any technical
           questions that should shape scope via NEEDS INPUT. Do NOT write the plan yet — wait
           until I tell you the requirement is finalized. I will also tell you which phase (if
           any) it lands on; goals and phases are the guild master's, so never insert one.
           The roster is loaded ({N} active members) — declare each ticket's capabilities as
           task_capability rows (required = 1 decides eligibility, required = 0 only ranks)
           and leave `agent` NULL unless you mean to pin. Check your words against
           v_capability_vocabulary before you finish: an unknown capability matches nobody,
           silently. If the plan needs a capability the guild lacks, INSERT the
           capability_request first, then raise it as a `NEEDS INPUT: ROSTER GAP` block and
           hold that ticket until I answer. You may not create an agent file; only the
           guild master can.
           Your deliverable is the full set: the plan, the TICKETS with each ticket's `files`
           JSON array — that is the disjoint-file assertion parallel dispatch depends on —
           their capabilities and parallel groups, and then the EXECUTION
           GRAPH: graph_node + graph_edge + gate rows instantiated from
           guild:warehouse references/templates/standard.md per queries.md §4, with a
           graph_deviation row (carrying a REASON) for every departure from it. The
           tickets must exist BEFORE the graph, because the nodes bind to them. Declare every
           edge BACKWARDS in template order — to_node declared after from_node — that is the
           only cycle protection there is. You may not add or drop a gate.
           Stop at `gate-plan`: do not approve it, do not dispatch anything, do not update any
           status column — the guild master approves the plan and I present it to them.
           Today's date: {today}."
)
```

### 6. Moderate the Interview Loop

Both agents may pause with a `NEEDS INPUT:` block — from either one, in any order, since they
run concurrently:

1. Whichever agent's completion notification carries `NEEDS INPUT:`, call **AskUserQuestion**
   yourself with exactly those questions. **One kind is not a plain question — an architect
   block whose first line reads `ROSTER GAP` is handled by Step 6.6.**
2. `SendMessage` the answers back to that same agent instance to resume it.
3. **`relay` mode only**: if the answer (or the agent's own framing) reveals something the
   *other* agent should know — a scope decision, a technical constraint — send a short FYI to
   the other instance too (`"FYI: user decided X"` / `"FYI: architect flagged Y — factor it
   into scope"`).
4. Repeat until an agent reports done, or the user signals they're finished.

**The user decides when the interview ends — watch for it in any answer**, not just an explicit
"done": "let's finalize", "that's enough for now", "go with what you have" all mean stop asking.
When you see it, `SendMessage` both agents to wrap up immediately rather than continuing the
round-robin.

**Product-owner reports done:** it reports the **REQ id it created** — record it as `$REQ`.

- If it took the **bug-fix short-circuit** (created the requirement plus its own
  fix/test-writer/reviewer tickets, per its own instructions), tell the architect to stop —
  this doesn't need a plan — and `TaskStop` its session. Skip to Step 6.5, where the placement
  question is usually a one-liner answered "unaffiliated".
- Otherwise `SendMessage` the architect: "The requirement is final: it is {REQ} — read it with
  `SELECT body FROM requirement WHERE id = '{REQ}'` and proceed to Design and Write the Plan."
  Keep relaying further `NEEDS INPUT` rounds until it reports done.

**Architect reports done:** it reports the PLAN id, the ticket ids and their file sets, and **the
graph** — which template, how many nodes, and every deviation with its reason. It wrote all of
that itself; you do not re-create any of it. Go to Step 6.7 and check the graph yourself before
you take anything to the user.

### 6.5. Place the Requirement in the Direction

Run this as soon as you have `$REQ` — you do not have to wait for the architect. **Ask the user;
never decide for them.** The product-owner's `Placement:` line is a recommendation, not an
answer.

Ask once, with **AskUserQuestion**, offering only the choices that apply:

| Choice | What you write |
|---|---|
| An existing phase — one option per plausible phase from Step 2.5, the product-owner's proposal first, labelled `PHASE-002 · Cart & coupon rework` | `UPDATE requirement SET phase_id = 'PHASE-002' WHERE id = '{REQ}' RETURNING id, phase_id;` |
| A new phase under an existing goal | the `phase` INSERT from queries.md §1 (its `ordinal` is derived from the goal's existing phases), then the UPDATE above |
| A new goal *and* its first phase | the `goal` INSERT, then the `phase` INSERT, then the UPDATE |
| **Leave it unaffiliated** | nothing — `phase_id` stays NULL |

Phrase it so the last choice reads as neutral as the others:

```
Where does {REQ} belong? "Leave it unaffiliated" is a real answer — small work
does not need a goal.
```

**Rules for this step:**

- **Unaffiliated is a first-class choice, not a failure.** `phase_id` is nullable by design and
  a later `UPDATE … SET phase_id = NULL` detaches one, so nothing here is permanent. Record it
  and move on — no warning, no "are you sure", no second ask.
- **Offer, never force.** Ask exactly once. If they pick a new goal or phase, collect its title
  (and the goal's priority, 1–5, default 3) in that same round.
- **Never create a goal or a phase the user did not ask for.** Ambiguous answer or skipped
  question → leave it unaffiliated and say so in Step 8.
- **No direction on the board yet?** Still offer, but keep it to two choices — "start a goal for
  this" / "leave it unaffiliated" — and one line.
- In `relay` mode, send the architect a one-line FYI when the requirement lands on a phase, so
  the plan stays consistent with that phase's other requirements.

### 6.6. Recruiting — the Architect Hit a Roster Gap

This step runs **only** when the architect's `NEEDS INPUT:` block opens with `ROSTER GAP`. The
plan needs a capability no member has, the architect has already filed the `capability_request`
recording it, and it is now the **guild master's decision** — the roster is their layer, exactly
like goals and phases.

> **Nothing here creates an agent without the user saying so.** Not you, not the architect, not
> on a "reasonable inference". An agent file is a permanent addition to the guild.

**Why live rather than at `gate-plan`.** The request is a permanent record and it **also**
surfaces at `gate-plan` with the plan — but the architect cannot write the affected
ticket until it knows the answer, and its session does not survive the gate.

**1. Read the gap back before you ask.** The architect's block is a claim; this is the record:

```sql
SELECT id, capability, requirement_id, proposed_agent, covered_by, rationale FROM v_roster_gaps;
```

`covered_by > 0` means the roster already has it and the request should simply be closed.

**2. Ask once, with AskUserQuestion**, putting the rationale and the proposed spec in the
question body so the decision is informed:

| Choice | What it means |
|---|---|
| **Create `{proposed-agent}`** | The guild grows a permanent new member. The next requirement needing this capability finds it already there. |
| **Assign to `{existing member}` anyway** | The work goes to a generalist. The gap stays on the record, because the guild still cannot do this work well. |
| **Revise the plan** | The architect redraws the tickets so the capability is not needed. Collect what the user wants changed. |

**3a. On "create":**

1. Scaffold the agent file from the architect's proposed spec, in the guild's agents directory
   (`$GUILD_AGENTS_DIR` if set, else `${CLAUDE_PLUGIN_ROOT}/agents/{name}.md`):

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

   `plugin-dev:agent-development` is the skill to load for help writing the body well.
2. **Show the user the file and get their sign-off before syncing.** They asked for a member,
   not for whatever you wrote; this is a review, not a notification.
3. Admit it to the roster: run the Step 2.6 sync, which upserts the agent, replaces its
   capabilities, and closes the request that asked for it:

   ```sql
   UPDATE capability_request SET status = 'created'
    WHERE status = 'open'
      AND capability IN (SELECT ac.capability FROM agent_capability ac
                           JOIN agent a ON a.name = ac.agent AND a.active = 1)
   RETURNING id, capability, status;
   ```

   **Never delete a `created` request** — that row is what keeps the word in
   `v_capability_vocabulary`, so removing it un-admits the capability on the next sync.
4. Confirm with `SELECT side, owner, capability FROM v_capability_unknown;` — a row means the
   file declares a tag nothing legitimized (a typo, or a second capability nobody filed for).
   Fix the file, do not file a second request to paper over it.
5. `SendMessage` the architect: `"Roster gap resolved: developer-rust is on the roster and
   declares [implement, backend, rust]. Create the held tickets requiring implement + rust."`

   **A newly added agent file is on the roster immediately, but the `Agent` tool resolves
   `subagent_type: "guild:{name}"` from the plugin manifest the session loaded at startup.** If
   a later dispatch reports an unknown subagent type, that is what happened: tell the user to
   restart Claude Code, and until they do, the ticket is dispatchable only by pinning it to an
   existing member.

**3b. On "assign anyway":** `SendMessage` the architect the member's name and let *it* write the
tickets — pin `agent` **and** declare the capabilities, so the board records both the pin and
what the work actually required. Two things to say out loud, because both look like problems
later and neither is:

- **The request stays open.** Nothing but recruiting closes it, so the capability keeps
  appearing under roster gaps. That is the design working — the guild still cannot do this work
  well.
- **`v_blocked_tasks` will name the pinned ticket** with `no-eligible-agent:implement,rust`,
  because the reason column reports the capability question and ignores the pin. The ticket is
  still dispatchable: `v_task_top_agent` returns the pin, and check-in dispatches on it.

**3c. On "revise the plan":** `SendMessage` the architect what the user wants changed and let it
redraw them. The same note about the request staying open applies.

**4. Never do any of these:** write an agent file the user did not approve; file the
`capability_request` yourself (the architect files it — you resolve it); create or re-create a
ticket to work around a gap; or treat "the user did not answer" as consent. If the answer is
ambiguous, ask again rather than picking.

### 6.7. Check the Graph Before You Take It to the User

The architect says the graph is sound. **Check it yourself** — it reads only, and a graph that
cannot start is a run nothing will ever begin:

```sql
SELECT n.node_key, n.kind, n.id, n.status, COALESCE(n.task_id,'-') AS task,
       COALESCE(n.parallel_group,'-') AS grp
  FROM graph_node n WHERE n.requirement_id = 'REQ-NNN' ORDER BY n.id;

SELECT from_node, to_node FROM graph_edge
 WHERE from_node LIKE 'REQ-NNN/%' ORDER BY from_node, to_node;

SELECT n.node_key, g.kind, g.status, g.prompt FROM gate g
  JOIN graph_node n ON n.id = g.node_id WHERE n.requirement_id = 'REQ-NNN';

SELECT kind, node_key, reason FROM graph_deviation WHERE requirement_id = 'REQ-NNN' ORDER BY id;

SELECT id, node_key, kind FROM v_ready_nodes WHERE requirement_id = 'REQ-NNN';

SELECT t.id, COALESCE(m.agent,'') AS matched, w.who, t.title
  FROM task t JOIN v_task_top_agent m ON m.task_id = t.id
              JOIN v_task_who       w ON w.task_id = t.id
 WHERE t.requirement_id = 'REQ-NNN' ORDER BY t.id;

SELECT side, owner, capability FROM v_capability_unknown;
```

Read them against `guild:warehouse` → `references/templates/standard.md`. Seven things fail a
graph,
and each one is a message back to the architect — **do not fix a graph by hand**, because
deviations are its record and its reasoning, and a graph the orchestrator patched has a shape
nobody justified:

| What you see | What it means |
|---|---|
| no `graph_node` rows | the architect never built the graph — send it back |
| more or fewer than the template's two gates | **never negotiable.** Dropping a gate removes the guild master's control surface; adding one turns unattended operation into a session that stops every twenty minutes |
| `implement` or `review` missing | required keys may be reshaped, never dropped |
| a node key not in the template, with no `graph_deviation` row | the shape changed and nothing recorded why |
| a template key absent, with no `drop-node` deviation | same, in the other direction |
| `v_ready_nodes` empty for the requirement | the graph cannot start: no root, or a cycle. With no `WITH RECURSIVE` there is no traversal to find one, so the rule is written at build time — every edge points backwards in declaration order |
| a ticket whose `matched` is `''`, or a row in `v_capability_unknown` | a roster gap or a typo'd tag — Step 6.6, not something to paper over |

An empty `reason` is impossible (the CHECK rejects it) and an edge to a node that does not exist
is impossible (the foreign key rejects it, when `PRAGMA foreign_keys = ON` was set) — those two
the database already caught.

**If the architect took the bug-fix short-circuit**, there is no graph and nothing to validate —
skip this step and Step 7's gate. A simple fix does not get a plan gate, because there is no plan
to approve. Say so plainly in Step 8 and let check-in pick the tickets up.

### 7. `gate-plan` — Present the Plan, and Stop

**This is where the skill ends and the guild master decides.** Everything up to here is a
proposal.

**1. Read the gate's own prompt** — the template wrote it, so use it rather than inventing
wording. It came back with the gate query above; the node id is `{REQ}/gate-plan`.

**2. Present it.** Enough to decide in one pass, and short — the plan is one `SELECT body FROM
plan` away if they want it:

```
REQ-007 — Session-backed authentication
  Plan: PLAN-004 · 3 implement tickets (auth-service, session-store, migrations) — file sets disjoint
  Graph: standard · 9 nodes · 1 deviation
    + research (before implement) — "the payments provider's webhook API is undocumented
      in the repo and no doc row covers it"
  Tickets: TASK-011 (implement,backend) · TASK-012, TASK-013 (wave A) ·
           TASK-014 test-planning · TASK-015 reviewer
  Then: implement → test-plan → test-write → review, running to completion without stopping,
        and stopping next at gate-repairs.

⚠ Roster gap: `rust` — capability request 3, still open. Assigned to `developer` for now.

Approve implementation?
```

Include the roster-gap block **only** when a request is still open (`v_roster_gaps`) — it goes
in front of the guild master here, with the plan, as part of the same decision.

**3. Ask with AskUserQuestion.** Three answers, and all three are real:

| Answer | What you write | What happens next |
|---|---|---|
| **Approve** | the two-write approval below | The plan is committed. `/guild:check-in` runs the first batch |
| **Reject** | the same, with `'rejected'` and the node to `'skipped'` | Nothing gets built. The plan and the graph stay on the board as the record of what was proposed and refused |
| **Not yet / let me think** | nothing | The gate stays `pending`. Check-in will present it again |

```sql
PRAGMA foreign_keys = ON;
UPDATE guild_state SET value = 'orchestrator' WHERE key = 'actor';

UPDATE gate SET status = 'approved',
                decision = CAST(x'<hex-their-words>' AS TEXT),
                decided_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE node_id = 'REQ-NNN/gate-plan' AND status = 'pending'
   AND EXISTS (SELECT 1 FROM v_ready_nodes r WHERE r.id = 'REQ-NNN/gate-plan')
RETURNING node_id, status;

UPDATE graph_node SET status = 'done'
 WHERE id = 'REQ-NNN/gate-plan'
   AND (SELECT g.status FROM gate g WHERE g.node_id = graph_node.id) = 'approved'
RETURNING id, status;
```

**Setting `gate.status` does not move the node** — approving is always two writes, and the
second one is what makes `implement` ready. On reject: `'rejected'`, and the node goes to
`'skipped'`. A rejected gate may be decided again later — reject, let the architect revise,
then approve; that loop is the whole point of the plan gate. An **approved** one may not.

Pass the user's own words through `decision` when they give any — a bare approval is a decision
with no reasoning attached, and six weeks later the reasoning is the part anyone wants.

**4. Then stop. Do not build.** Approval is not a dispatch:

- Do **not** spawn a developer, a test-planner or a reviewer.
- Do **not** move any ticket out of `todo`.
- Do **not** move any other graph node, and do not compile a workflow.

`/guild:check-in` runs the approved graph, and it will find the gate `done` and `implement`
ready. **The one thing this skill must never do is treat its own plan as permission to execute
it** — the whole value of a plan gate is that it belongs to somebody who is not the planner.

### 8. Confirm

```
Requirement planned!

  Requirement: {REQ} — {title}
  Direction: {PHASE-NNN — phase title (GOAL-NNN — goal title)}
             (or "unaffiliated — not attached to a goal")
  Plan: {PLAN-NNN} — {N} implement tickets (or "none — simple fix, no plan needed")
  Graph: {standard · N nodes · N deviations} (or "none — simple fix, no graph")
  Tickets created: {list of TASK-NNN — title (needs: cap,cap | pinned to NAME)}
  Roster: {"developer-rust added on your approval — 15 members" | omit the line}
  gate-plan: APPROVED — run /guild:check-in to build it.
```

**The last line must tell the truth about what happens next:**

| Gate state | Line |
|---|---|
| Approved | `gate-plan: APPROVED — run /guild:check-in to build it.` |
| Rejected | `gate-plan: REJECTED — nothing will be built. The plan and graph stay on the board.` |
| Still pending | `gate-plan: PENDING your approval — nothing is built until you approve it. /guild:check-in will ask again.` |
| No graph (bug-fix short-circuit) | `No plan gate — this was a simple fix. Run /guild:check-in to work the tickets.` |

Never print "run check-in to start building" under a gate that is pending or rejected: that is
the one sentence that would make an unapproved plan look approved.

Report a new goal, phase or guild member you created on the user's instruction on its own line —
each one outlives the requirement. And if a roster gap was left unresolved, one more line so it
is not a surprise later:

```
  Open roster gap: `rust` — assigned to `developer` for now. It stays on the brief
  under roster gaps until a member declares it.
```

### 9. Verify against §4

Run `guild:validate new-requirement` before you report. §4 of `docs/expectations.md` asserts
what this skill is for: §4.a that nothing moved and nothing was claimed, §4.b that
`v_ready_nodes` offers **exactly one** row and it is `gate-plan`, §4.c the node/edge/gate
arithmetic (`N+9`, `2N+10`, `2`), §4.d the plan, its tickets and the four-way review fan-out.
**Report every failure with its rows.** A silently torn INSERT exits `1` and looks like
success — §4.b is the strongest single statement that nothing can be built yet.

## Rules

- **IDs are derived inside the INSERT** — `'REQ-' || printf('%03d', COALESCE(MAX(…),0)+1)` in
  the same statement that inserts the row, so it cannot collide. Never hand-assign or zero-pad
  an id yourself.
- **Free text crosses as hex.** A requirement body, a plan body, a rationale, a decision — all
  `CAST(x'<hex>' AS TEXT)`. A `;` that ends a line ends the statement, **even inside a string
  literal**, and requirement bodies quote code.
- **Status is a COLUMN.** Everything created starts at `todo`, and only the orchestrator moves
  it.
- **Documents are written at creation** — `body` is the whole write surface for a requirement or
  a plan. There is no file to edit, because there is no file.
- **This skill does not return until planning is complete** — requirement-gathering and planning
  both happen here, live.
- **This skill PLANS; it never BUILDS.** It ends at `gate-plan`. No developer is spawned, no
  ticket leaves `todo`, no node is moved — regardless of how obviously good the plan is, and
  regardless of the user saying "yes" enthusiastically. Approval records a decision; it does not
  start work.
- **The graph is the architect's artifact, and only the architect edits it.** You run the
  read-only checks and send failures back. A graph the orchestrator patched has a shape nobody
  justified.
- **Two gates, fixed** — `gate-plan` here, `gate-repairs` after review. Never ask the architect
  for an extra approval point and never accept a graph that grew one. A third gate reads as
  caution and is what turns an unattended run into a session that stops every twenty minutes.
- **The gate write is yours alone** — it records a guild-master decision, so it runs only on an
  explicit answer, in Step 7, and never on inference. "They seemed happy with it" is not an
  approval. Note that **nothing in the schema enforces this**: `gate.status` is a column anyone
  can write. It holds because you honor it.
- **Never let a subagent try `AskUserQuestion`** — team mode or not, only you can ask the real
  user. Both agents always relay via `NEEDS INPUT`.
- **Direction is the guild master's call** — the goal, phase and `phase_id` writes are yours
  alone, run only in Step 6.5 on an explicit answer. The product-owner proposes a placement and
  the architect may flag a mismatch; neither of them writes one.
- **A requirement with no phase is a finished requirement.** `phase_id` is nullable by design.
  Never block, re-ask, or apologise because the user left one unaffiliated.
- **File sets, capabilities and parallel groups are the architect's to set.** `task.files` is
  the disjointness assertion parallel dispatch depends on, and **nothing verifies it** — if a
  ticket is missing or its file set is wrong, that is a message to the architect, not an edit
  you make.
- **A capability request is closed by recruiting, not by withdrawal.** Only an admitted agent
  moves it `open → created`; `declined` keeps the word out of the vocabulary entirely. Say
  plainly when a gap is being left open rather than letting it appear unexplained in the next
  brief.
