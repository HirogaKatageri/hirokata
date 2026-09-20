---
name: new-requirement
description: >
  This skill should be used when the user asks to "add a requirement",
  "new requirement", "I need a feature", "add to the guild", "create requirement",
  "queue a feature", "I want to build", or wants to add a new work item to the
  guild board. Runs a live interview between the project-manager and the user,
  places the requirement in the guild's direction (or deliberately leaves it
  unaffiliated), then hands the finished requirement to the strategist to write the
  implementation plan, the developer/test-planner/reviewer tickets, and the
  requirement's execution graph — and ends at `gate-plan`, where the guild
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

Run the project-manager through a live interview with the user, then — once the requirement is
final — hand it to the strategist to write the plan, the tickets, and the **execution graph**
that says what runs when. The two agents run **sequentially, never concurrently**: the
strategist does not start until the project-manager reports done. Unlike the rest of the guild's
pipeline, none of this is ticket-dispatched — you (the orchestrator) spawn each agent directly
and moderate its own interview loop in turn.

**Load `guild:warehouse` first.** There is no guild CLI: `tursodb` is the tool and every write
below is SQL. The canonical statements — creating a requirement, a plan, a ticket with
its capabilities, instantiating a graph — are in `guild:warehouse` → `references/queries.md`;
copy from there rather than improvising.

**Reference — load on demand:** `references/roster-gap.md` — the full recruiting procedure for
Step 8.5, only needed when the strategist's `NEEDS INPUT:` opens with `ROSTER GAP`.

## Where this skill stops: `gate-plan`

**This skill plans. It does not build.** It ends by presenting the plan at `gate-plan` — the
first of the guild's two gates, and the whole point of the gate model:

> **The plan is the cheapest place to change your mind.** Approving it costs one decision and
> redirects everything downstream. After that, the guild runs to completion without stopping,
> and the problems it finds are collected and judged together at `gate-repairs`.

So the last thing you do here is put the plan in front of the guild master and record their
answer (Step 10). **Nothing is dispatched, nothing is implemented, no ticket leaves `todo` until
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

### 2. Gather a Seed Title/Description

Ask for whichever was not supplied:

```
What's the title of this requirement? (e.g., "User Authentication", "Payment Integration")
Briefly describe what you need. The project-manager will dig into full details in the interview.
```

This is a seed — the interview in Step 5 gathers the real detail.

### 2.5. Read the Guild's Direction

Goals and projects are the layer *above* requirements, and a requirement's project is what makes
it appear under Direction in the brief and on the dashboard's roadmap. Read what exists now — you
need it twice: as context for the project-manager (Step 4) and to build the placement question
(Step 6).

```sql
SELECT id, priority, projects_runnable, runnable_project_ids,
       requirements_done, requirements_total, title FROM v_goal_progress;
SELECT id, goal_id, ordinal, status, priority, concurrent, isolation, title
  FROM v_project_progress;
SELECT id, why, isolation, title FROM v_projects_runnable;
```

Nothing back means the guild has no direction yet. That is normal on a young board and is
**not** a problem to fix before proceeding.

**Do not create a goal or a project here.** Direction is the guild master's call — Step 6 is
where the user makes it.

### 2.6. Read the Roster

The strategist writes tickets that name a **capability**, not a member. **There is nothing to
sync** — the roster is the frontmatter of the agent files, not a table — but you do have to
read it, so you can tell the strategist what the guild can actually do:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py"
```

One line per subagent available to the user: `name | model | serial | scope | capabilities`,
across this plugin, the project's `.claude/agents/`, the user's `~/.claude/agents/` and every
other installed plugin. **The union of that last column is the whole vocabulary** — there is no
seed list, and a word is legal exactly when some agent declares it.

**Why this is not optional:** the strategist has to aim its `task_capability` rows at words
somebody actually declares. A tag nobody has inserts fine and then **matches nobody, silently**
— no view can catch it, because the database cannot see the agent files. Pass the members and
their capabilities into the strategist's prompt (Step 7) so it is aiming at the real roster
rather than at the table in its own instructions.

The script also flags members declaring **no** capabilities. Those can still be pinned by name;
they simply never win a capability match.

### 3. Do NOT Create the Requirement Yet

**The project-manager creates it, at the end of the interview**, in one INSERT that carries the
whole document in `body` (hex transport — a requirement body quotes code, and a `;` ending a
line would split the statement). It then reports the REQ id back to you, and everything
downstream uses that id.

You can show the user what number it will land on, but the id is derived inside the INSERT
itself, so it is indicative only:

```sql
SELECT 'REQ-' || printf('%03d', COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)), 0) + 1)
  FROM requirement;
```

### 4. Spawn the Project-Manager

It runs **alone** — the strategist does not exist yet, and there is no mode to detect or
cross-talk to set up:

```
Agent(
  subagent_type: "guild:project-manager",
  prompt: "You're gathering requirements for a new feature — \"{title}\". Load the
           guild:warehouse skill: there is no CLI, you write SQL. There is NO requirement
           row yet — compose the document, then create it yourself with the INSERT in
           queries.md §1 (body as CAST(x'<hex>' AS TEXT)) and report the REQ id it returns.
           Seed description: {description}. Today's date: {today}.
           Current direction (Step 2.5): {one line per goal and project, or 'none declared yet'}.
           End your report with a one-line Placement proposal — an existing PROJ id, a new
           goal/project you'd suggest, or none at all. It is a recommendation for the user, not
           a decision: do NOT insert a goal or a project, and do not set requirement.project_id.
           Report done when the requirement is complete, or report the bug-fix short-circuit
           per your own instructions if this turns out to be a simple fix."
)
```

### 5. Moderate the Interview Loop

The project-manager may pause with a `NEEDS INPUT:` block, any number of times:

1. Call **AskUserQuestion** yourself with exactly those questions.
2. `SendMessage` the answers back to resume it.
3. Repeat until it reports done, or the user signals they're finished.

**The user decides when the interview ends — watch for it in any answer**, not just an explicit
"done": "let's finalize", "that's enough for now", "go with what you have" all mean stop asking.
When you see it, `SendMessage` to wrap up immediately rather than continuing the round-robin.

**It reports done:** it reports the **REQ id it created** — record it as `$REQ`.

- **Bug-fix short-circuit.** If it created the requirement plus its own
  fix/test-writer/reviewer tickets (per its own instructions), this doesn't need a plan —
  there is nothing to spawn the strategist for. Continue to Step 6 (the placement question is
  usually a one-liner answered "unaffiliated"), then skip straight to Step 11 (Confirm).
- **Standard case.** Continue to Step 6, then Step 7 to hand the finished requirement to the
  strategist.

### 6. Place the Requirement in the Direction

Runs in both branches above, right after the project-manager reports done. **Ask the user; never
decide for them.** The project-manager's `Placement:` line is a recommendation, not an answer.

Ask once, with **AskUserQuestion**, offering only the choices that apply:

| Choice | What you write |
|---|---|
| An existing project — one option per plausible project from Step 2.5, the project-manager's proposal first, labelled `PROJ-002 · Cart & coupon rework` | `UPDATE requirement SET project_id = 'PROJ-002' WHERE id = '{REQ}' RETURNING id, project_id;` |
| A new project under an existing goal | the `project` INSERT from queries.md §1 (its `ordinal` is derived from the goal's existing projects), then the UPDATE above |
| A new goal *and* its first project | the `goal` INSERT, then the `project` INSERT, then the UPDATE |
| **Leave it unaffiliated** | nothing — `project_id` stays NULL |

Phrase it so the last choice reads as neutral as the others:

```
Where does {REQ} belong? "Leave it unaffiliated" is a real answer — small work
does not need a goal.
```

**Rules for this step:**

- **Unaffiliated is a first-class choice, not a failure.** `project_id` is nullable by design and
  a later `UPDATE … SET project_id = NULL` detaches one, so nothing here is permanent. Record it
  and move on — no warning, no "are you sure", no second ask.
- **Offer, never force.** Ask exactly once. If they pick a new goal or project, collect its title
  (and the goal's priority, 1–5, default 3) in that same round.
- **A new project defaults to sequential and shared** — `concurrent = 0`, `isolation = 'shared'`,
  `ordinal` next in the goal. That is the old `phase` behaviour and the safe default. Ask the
  follow-up **only** when the user's own words invite it ("this can go in parallel", "keep it off
  the main tree"), and write it as one extra UPDATE:
  `UPDATE project SET concurrent = 1 WHERE id = 'PROJ-NNN';` or
  `UPDATE project SET isolation = 'worktree', worktree_path = '.worktrees/PROJ-NNN' WHERE id = 'PROJ-NNN';`
  (both columns in one statement — a `shared` project may not carry a path, and the CHECK will
  reject it). **Nothing cuts the worktree for you**; tell the user they need to create it.
- **Never create a goal or a project the user did not ask for.** Ambiguous answer or skipped
  question → leave it unaffiliated and say so in Step 11.
- **No direction on the board yet?** Still offer, but keep it to two choices — "start a goal for
  this" / "leave it unaffiliated" — and one line.
- **Bug-fix short-circuit?** Skip straight to Step 11 (Confirm) after this — there is no
  strategist to spawn.
- Otherwise, carry this decision straight into Step 7's dispatch prompt — including the
  project's `isolation`, which changes how far the strategist's file-disjointness assertion has
  to reach. There is no live strategist instance yet to send an FYI to; it simply starts knowing.

### 7. Spawn the Strategist

Only for the standard case. The requirement is final and the placement is decided, so the
strategist starts with everything it needs and never has to wait on anyone or coordinate with a
concurrently-running project-manager — there isn't one:

```
Agent(
  subagent_type: "guild:strategist",
  prompt: "You're planning for a new feature — \"{title}\". The requirement is final: it is
           {REQ} — read it with `SELECT body FROM requirement WHERE id = '{REQ}'`.
           Load the guild:warehouse skill: there is no CLI, you write SQL.
           It lands on {PROJ-NNN, isolation: worktree|shared | 'no project — unaffiliated'};
           goals and projects are the guild master's, so never insert one.
           The roster ({N} members) is: {name: [capabilities], ...} — read from the agent
           files, which are the only place it lives. Declare each ticket's capabilities as
           task_capability rows (required = 1 decides eligibility, required = 0 only ranks)
           and leave `agent` NULL unless you mean to pin. Check every word against that
           roster with `roster.py --covers` before you finish: an unknown capability matches
           nobody, silently, and NO VIEW WILL CATCH IT. If the plan needs a capability nobody
           declares, raise it as a `NEEDS INPUT: ROSTER GAP` block, record it in the plan's
           Technical Decisions, and hold that ticket until I answer. There is no
           capability_request table — writing the agent file IS the recruitment, and
           you may not write one; only the guild master can.
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

### 8. Moderate the Strategist's Planning

The same loop as Step 5, now for the strategist alone:

1. Call **AskUserQuestion** with its `NEEDS INPUT:` questions. **A block whose first line reads
   `ROSTER GAP` is not a plain question — it is handled by Step 8.5.**
2. `SendMessage` the answer back to resume it.
3. Repeat until it reports done.

**It reports done:** it reports the PLAN id, the ticket ids and their file sets, and **the
graph** — which template, how many nodes, and every deviation with its reason. It wrote all of
that itself; you do not re-create any of it. Go to Step 9 and check the graph yourself before
you take anything to the user.

### 8.5. Recruiting — the Strategist Hit a Roster Gap

Runs **only** when the strategist's `NEEDS INPUT:` block opens with `ROSTER GAP` — the plan
needs a capability no available subagent declares, and it is the **guild master's decision**,
never an inference. Full procedure — verifying the gap, the three-way AskUserQuestion,
scaffolding and getting sign-off on a new agent file, and the two non-"create" paths — is in
`references/roster-gap.md`. Read it before this situation comes up, not during it.

### 9. Check the Graph Before You Take It to the User

The strategist says the graph is sound. **Check it yourself** — it reads only, and a graph that
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

SELECT t.id, COALESCE(t.agent,'') AS pin, w.who, t.title
  FROM task t JOIN v_task_who w ON w.task_id = t.id
 WHERE t.requirement_id = 'REQ-NNN' ORDER BY t.id;
```

Then check every unpinned ticket's `who` against the roster — `needs:implement+svelte` becomes
`--covers implement,svelte`. **No SQL can do this for you**, and a ticket nobody covers is the
one failure below that will not surface until the middle of a shift:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py" --covers implement,svelte
```

Read them against `guild:warehouse` → `references/templates/standard.md`. Seven things fail a
graph,
and each one is a message back to the strategist — **do not fix a graph by hand**, because
deviations are its record and its reasoning, and a graph the orchestrator patched has a shape
nobody justified:

| What you see | What it means |
|---|---|
| no `graph_node` rows | the strategist never built the graph — send it back |
| more or fewer than the template's two gates | **never negotiable.** Dropping a gate removes the guild master's control surface; adding one turns unattended operation into a session that stops every twenty minutes |
| a REQUIRED key missing — `gate-plan`, `implement`, `review`, `gate-repairs` or `document` (`document` on `standard` only) | **a `drop-node` deviation does NOT make this legal.** G8 asserts `dropped-required-node` over that exact set and fires whatever reason was recorded. A required node may be RESHAPED — fanned out, re-pointed, given a different capability — never dropped. Doing the paperwork correctly is what hides this one |
| a node key not in the template, with no `graph_deviation` row | the shape changed and nothing recorded why |
| an OPTIONAL template key absent, with no `drop-node` deviation | same, in the other direction — the shape changed and nothing recorded why. For a required key see the row above: the deviation is not the point, the key is |
| `v_ready_nodes` empty for the requirement | the graph cannot start: no root, or a cycle. With no `WITH RECURSIVE` there is no traversal to find one, so the rule is written at build time — every edge points backwards in declaration order |
| an unpinned ticket whose `--covers` scan returns nothing | a roster gap or a typo'd tag — Step 8.5, not something to paper over |

An empty `reason` is impossible (the CHECK rejects it) and an edge to a node that does not exist
is impossible (the foreign key rejects it, when `PRAGMA foreign_keys = ON` was set) — those two
the database already caught.

**A bug-fix short-circuit never reaches this step** — it exits at Step 6, before the strategist
is even spawned, so there is no graph and nothing to validate here.

### 10. `gate-plan` — Present the Plan, and Stop

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

⚠ Roster gap: `rust` — no available subagent declares it. Assigned to `developer` for now.

Approve implementation?
```

Include the roster-gap block **only** when the strategist raised one and it is still unresolved
— read it from the plan's Technical Decisions. It goes in front of the guild master here, with
the plan, as part of the same decision.

**3. Ask with AskUserQuestion.** Three answers, and all three are real:

| Answer | What you write | What happens next |
|---|---|---|
| **Approve** | the three-write approval below | The plan is committed. `/guild:check-in` runs the first batch |
| **Reject** | the same, with `'rejected'` throughout and the node to `'skipped'` | Nothing gets built. The plan and the graph stay on the board as the record of what was proposed and refused |
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

UPDATE plan SET approval = 'approved',
                approved_by = 'user',
                approved_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'),
                gate_node_id = 'REQ-NNN/gate-plan'
 WHERE requirement_id = 'REQ-NNN' AND task_id IS NULL AND approval = 'pending'
RETURNING id, approval;
```

**Setting `gate.status` does not move the node, and it does not approve the plan either** —
approving is always **three** writes. The second is what makes `implement` ready; the third is
what takes the plan off `v_plans_pending_approval`, which is the queue the brief and check-in
read. Skip it and the board will keep asking about a plan the user already approved.

`task_id IS NULL` targets the requirement's own implementation plan and leaves the test plan
alone — a test plan is never approved at all, and does not need to be. It is written by an
agent AFTER this gate, implementing a direction the guild master already ruled on, so there
is no second decision to make. G6's `task-built-on-unapproved-plan` is scoped to
`p.task_id IS NULL` for exactly that reason. (It used to say the test plan was "approved at
its own point" — there was no such point, and every test-writer ticket carrying a `plan_id`
breached G6 with no documented write that could clear it.)

On reject: `'rejected'` on the gate, `'skipped'` on the node, `'rejected'` on the plan. A
rejected gate may be decided again later — reject, let the strategist revise, then approve; that
loop is the whole point of the plan gate. An **approved** one may not.

Pass the user's own words through `decision` when they give any — a bare approval is a decision
with no reasoning attached, and six weeks later the reasoning is the part anyone wants.

**4. Then stop. Do not build.** Approval is not a dispatch:

- Do **not** spawn a developer, a test-planner or a reviewer.
- Do **not** move any ticket out of `todo`.
- Do **not** move any other graph node, and do not compile a workflow.

`/guild:check-in` runs the approved graph, and it will find the gate `done` and `implement`
ready. **The one thing this skill must never do is treat its own plan as permission to execute
it** — the whole value of a plan gate is that it belongs to somebody who is not the planner.

### 11. Confirm

```
Requirement planned!

  Requirement: {REQ} — {title}
  Direction: {PROJ-NNN — project title (GOAL-NNN — goal title)}
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

Report a new goal, project or guild member you created on the user's instruction on its own line —
each one outlives the requirement. When you created a project with `isolation = 'worktree'`, say
so and say that **the checkout is not cut for you** — nothing in the schema creates it. And if a roster gap was left unresolved, one more line so it
is not a surprise later:

```
  Open roster gap: `rust` — assigned to `developer` for now. Nothing tracks it but the
  plan's Technical Decisions, so it is on you to remember it: writing an agent file
  declaring `rust` is the whole fix.
```

### 12. Verify against §4

Run `guild:validate new-requirement` before you report. §4 of `docs/expectations.md` asserts
what this skill is for: §4.a that nothing moved and nothing was claimed, §4.b that
`v_ready_nodes` offers **exactly one** row and it is `gate-plan`, §4.c the node/edge/gate
arithmetic (`N+10`, `2N+11`, `2`), §4.d the plan, its tickets and the four-way review fan-out.
**Report every failure with its rows.** A silently torn INSERT exits `1` and looks like
success — §4.b is the strongest single statement that nothing can be built yet.

## Rules — at a glance

Each is argued in full where it first applies above; this is the checklist, not the argument.

- IDs are derived inside the INSERT — never hand-assign or zero-pad one yourself.
- Free text crosses as hex, always — a requirement or plan body quotes code and a bare `;`
  would split the statement.
- Status is a COLUMN; everything created starts at `todo` and only the orchestrator moves it.
- Documents are written at creation — `body` is the whole write surface, there is no file.
- This skill does not return until planning is complete — gathering and planning both happen
  here, live.
- This skill PLANS; it never BUILDS. It ends at `gate-plan`: no developer spawned, no ticket
  leaves `todo`, no node moved, no matter how good the plan looks or how enthusiastic the "yes".
- The graph is the strategist's artifact — you run the read-only checks (§9) and send
  failures back; you never patch it by hand.
- Two gates, fixed — `gate-plan` here, `gate-repairs` after review. Never accept a graph that
  grew a third.
- The gate write is yours alone, on an explicit answer, only in Step 10 — never on inference.
- Never let a subagent try `AskUserQuestion` — every agent relays via `NEEDS INPUT`, and the two
  never run concurrently, so there is only ever one live interview loop to moderate.
- Direction is the guild master's call — goal/project/`project_id` writes are yours alone, only
  in Step 6, only on an explicit answer.
- A requirement with no project is a finished requirement — `project_id` is nullable by design.
- Never write `plan.approval` except at `gate-plan`, on the user's explicit answer.
- File sets, capabilities and parallel groups are the strategist's to set — a wrong one is a
  message back to it, not an edit you make.
- A capability request is closed by recruiting, not by withdrawal (§8.5) — say plainly when a
  gap is being left open rather than letting it appear unexplained in the next brief.
