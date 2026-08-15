---
name: brief
description: >
  This skill should be used when the user asks for "guild status", "board status",
  "what's the status", "show the board", "what's on the board", "project status",
  "show guild", "guild board", "what's happening", "brief me", "guild brief",
  "where are we", "what changed", "what moved since last time", "what should I
  work on next", or any read-only request for the state of the guild. Narrates a
  real briefing — direction, what is in flight, the open bugs, which tickets
  failed and why, the unresolved review findings, what moved since the last
  check-in, and what to do next — without starting a work session.
version: 6.0.0
user-invocable: true
---

# Guild Brief — the narrated read of the board

Read-only. This skill **reports**; it never dispatches an agent, never moves a task, and
never writes a row. If the user wants work to start, that is `guild:check-in`.

Load `guild:warehouse` for the connection ritual and the view catalog. Everything below is a
`SELECT`. Your job is to turn those rows into a briefing a human can act on — `guild:check-in`
opens with the same reads, so what you write here is what the daily flow reads too.

## Step 1 — is there a guild?

```bash
[ -f .guild/config.yaml ] || echo "no guild here"
```

If it is missing, say exactly this and stop:

```
No guild board found. Run /guild:check-in to initialize and start your first work session.
```

## Step 2 — read the board

One script, one round trip. Write it with a **quoted** heredoc so the shell never touches the
SQL:

```bash
export PATH="$HOME/.turso:$PATH"
cat > /tmp/brief.sql <<'SQL'
SELECT '## brief';        SELECT fact, value FROM v_brief;
SELECT '## direction';    SELECT id, priority, current_phase_id, current_phase_title,
                                 requirements_done, requirements_total, title FROM v_goal_progress;
SELECT '## requirements'; SELECT id, status, tasks_done, tasks_total, tasks_open,
                                 tasks_blocked, tasks_failed, title FROM v_requirement_progress
                           WHERE status <> 'done';
SELECT '## in-flight';    SELECT json_object('id',id,'req',requirement_id,'who',who,
                                 'minutes',minutes,'title',title) FROM v_in_flight;
SELECT '## bounties';     SELECT json_object('id',id,'req',requirement_id,'p',priority,
                                 'who',who,'title',title) FROM v_open_bounties;
SELECT '## blocked';      SELECT json_object('id',id,'req',requirement_id,'status',status,
                                 'reason',reason,'title',title) FROM v_blocked_tasks;
SELECT '## gaps';         SELECT json_object('cap',capability,'req',requirement_id,
                                 'proposed',proposed_agent,'covered',covered_by,
                                 'why',rationale) FROM v_roster_gaps;
SELECT '## bugs';         SELECT json_object('id',id,'sev',severity,'status',status,
                                 'by',found_by,'req',requirement_id,'title',title) FROM v_open_bugs;
SELECT '## failed';       SELECT json_object('id',id,'who',who,'waived',waived,
                                 'reason',COALESCE(reason,''),'title',title) FROM v_failed_tasks;
SELECT '## findings';     SELECT json_object('id',id,'task',task_id,'sev',severity,
                                 'disp',disposition,'by',reviewer,'at',
                                 COALESCE(file,'') || ':' || COALESCE(line,''),
                                 'what',summary) FROM v_open_findings;
SELECT '## coverage';     SELECT json_object('id',id,'risk',risk,'due',interval_days,
                                 'since',COALESCE(days_since,-1),'area',area) FROM v_coverage_due;
SELECT '## gates';        SELECT json_object('node',node_id,'req',requirement_id,
                                 'kind',kind,'prompt',prompt) FROM v_gates_pending;
SELECT '## moved';        SELECT json_object('ts',ts,'actor',actor,'verb',verb,
                                 'type',subject_type,'id',subject_id,'title',subject_title,
                                 'phrase',phrase) FROM v_recent_activity
                           WHERE ts >= COALESCE(NULLIF((SELECT value FROM guild_state
                                                         WHERE key='last-checkin'),'null'),'')
                           ORDER BY ts DESC LIMIT 30;
SQL
tursodb -q -m list .guild/guild.db < /tmp/brief.sql
```

Two things about that script, both deliberate:

- **`json_object` for anything with free text.** `-m list` output is pipe-separated with no
  quoting, and a title containing a newline forges a whole row that looks legitimate. JSON
  escapes control characters, so one row is always one line.
- **The `'## …'` markers** are how you tell the blocks apart in one flat stream. A missing
  marker never happens; a marker with nothing after it means that section is empty.

**One script is the whole briefing.** If a section is empty, that is the answer — do not run a
second query to "check" it. **Do not widen this to a window the user did not ask for.** The
cutoff for `## moved` is the recorded `last-checkin`; when the user names a window ("what
changed this week?"), swap the `WHERE ts >=` value for their date, and say which cutoff you
used.

**Nothing else runs from this skill.** No `UPDATE`, no `INSERT`, no roster sync, no
`last-checkin` stamp — a brief that logged itself would pollute the very feed its "what moved"
section reads, and `guild:check-in` is the one skill that moves the cutoff. Writing an
`agents/*.md` file from here is likewise out of bounds.

The one legitimate reason to run something else is a question these rows genuinely do not
answer — the full body of a finding, a bug's repro steps, a clipped title in full. Those are
the user's to ask for, and Step 4's last rule tells you to **name the query** rather than run it.

## Step 3 — read what came back

`v_brief` is the standup as one fact per row: `next`, `next_reason`, the task counts,
`bounties_open` / `bounties_stuck`, `bugs_open`, `findings_open`, `coverage_due`,
`roster_gaps`, `capability_unknown`, `nodes_ready`, `gates_pending`, `events_since_checkin`.
Every count comes from the same view its detail list comes from, so **a count and its listing
cannot disagree.** Never state a number that is not in these rows.

What each block teaches:

- **`next` is `v_next_task`'s answer** — the exact ticket the cursor would hand out, and
  `next_reason` says `resume` or `claim`. It deliberately ignores dependencies and
  eligibility, so it can name a ticket nobody can take. **`next = none` means "nothing to do",
  not "finished"** — read `## blocked` and `## gates` in the same breath before saying the
  board is clear.
- **`## in-flight` carries `minutes` against the wall clock.** Hundreds of minutes on a ticket
  that normally takes minutes is a crashed dispatch, not work in progress. Say so.
- **`## failed` separates the two meanings of `failed`.** `waived = 1` is a failure the guild
  master already skipped — settled, and it no longer holds the review gate or requirement
  completion. `waived = 0` is unadjudicated: nothing will retry it on its own, and it belongs
  in the risk beat. `reason` is the agent's own most recent account of what went wrong, and it
  is **empty** when the ticket failed before logging anything. Quote it.
- **`## findings` is severity · disposition · reviewer · task · `file:line` · summary,** worst
  severity first. That line is the sentence — "reviewer-security flagged an unsigned callback
  token at src/queue/consume.ts:61" is a briefing; "two unresolved findings" is not. The full
  `detail` paragraph is not in this read; fetch it only if asked.
- **`## moved` carries `ts · actor · verb · type · id · title` and a `phrase`** which, for a
  status change, is `from -> to`. **State the transition; it is printed.** `actor` is whoever
  did it — `orchestrator` for board moves, but `reviewer-security`, `qa-tester`, `developer`
  for the rows agents wrote themselves. Name the agent. A verb you do not recognize is data,
  not a glitch: the vocabulary is open by design.
- **`## coverage` reports `since = -1` for an area that has never been inspected.** That is not
  "0 days ago", and rendering it as such lies about the state of the product.

**An empty block is good news stated by its absence.** No `## bugs` rows means nothing is
open. Do not announce empty categories, and do not invent one.

### The two blocks that are usually the most important thing on the page

```json
{"id":"TASK-005","req":"REQ-001","status":"blocked",
 "reason":"no-eligible-agent:implement,rust","title":"Port the codec to Rust"}
{"cap":"rust","req":"REQ-001","proposed":"developer-rust","covered":0,
 "why":"Three plan slices are Rust crates; developer has no Rust idiom guidance."}
```

- **`## blocked` is `id · req · status · reason · title`,** and `reason` is one blank-free
  token: `status-blocked`, `deps:TASK-009,…`, or `no-eligible-agent:<capabilities>`. The last
  is a **roster gap** — the ticket declared capabilities nobody covers — and the token names
  the words that would fix it, which is to say it names the agent file somebody needs to
  write. `blocked` means exactly one thing in this guild: *this bounty has no taker*.
- **`## gaps` is one row per open `capability_request`** — a decision the guild master has not
  made yet. The architect hit a capability the guild does not have, filed it rather than
  routing to the nearest generalist, and proposed a member. **`covered > 0` on an open request
  means the gap was filled and nobody closed the request** — worth saying, because the board
  is still asking for something it already has.
- **A gap disappears when it is filled, not when it is dismissed.** Only a roster sync that
  admits an agent declaring the capability moves it `open → created`. So a gap that has been
  on the brief for a week means nobody recruited for it — including when the user chose to
  hand the work to a generalist anyway. Report it as standing, never as stale.
- **The two are usually one story.** A blocked row and a gap row on the same board are the
  bounty and its cause; narrate them together in one sentence.
- **When blocked work is all that is left** — `bounties_open` is 0 and `bounties_stuck` is
  not — that **is** the headline. It is not "all caught up", and it must never be narrated as
  if it were.

**`capability_unknown > 0`** is worth one line too: an agent or a ticket carries a tag outside
the vocabulary, so it matches nobody, silently, forever. `SELECT side, owner, capability FROM
v_capability_unknown` names it.

## Step 4 — narrate it

Present a short briefing in **this order**, in prose, with the rows available if the user wants
them. Skip any part the data does not support.

1. **Direction** — which goal the guild is serving, its priority, which phase it is on, and
   progress. If `## direction` is empty, say so plainly and note that requirements are being
   tracked without one — that is legal, not an error.
2. **In flight** — what is being worked on and for how long, calling out anything implausibly
   old.
2a. **Blocked — immediately after in-flight, by name, never as a count.** Give the ticket, the
   title, the capability nobody has, and the fact that makes it urgent: *nothing will pick this
   up on its own, and it holds its requirement open.* "TASK-005, Port the codec to Rust, is
   blocked — no guild member has `rust`, so REQ-001 cannot complete." If nothing is blocked,
   say nothing; there is no good news to announce here.
3. **Risks — named, never counted.** Open bugs worst-severity first, every `critical` one by id
   and title. Then the unadjudicated failed tasks, with their reason. Then the findings, at
   least the critical and major ones, each as severity + reviewer + what + where. Then coverage
   areas overdue or never inspected. **End the risk beat with the roster gaps** — a gap is a
   risk with a known remedy, which is the most useful kind to state: "`rust` has been an open
   gap since REQ-001; the architect proposed `developer-rust`."
4. **What moved** — summarize by subject rather than reciting timestamps: "since your last
   check-in, TASK-001 and TASK-002 completed, reviewer-security filed a major finding on
   TASK-003, BUG-001 was filed critical, TASK-007 failed." Each row carries its subject's title
   and, for a move, both ends of the transition. Never invent one that is not printed.
5. **What is waiting on you** — every `## gates` row is a decision only the guild master can
   make, and nothing behind it moves until they do. Name the requirement and quote the gate's
   prompt.
6. **What to do next** — a concrete recommendation, with the reason. Default to `next`. Deviate
   only for something the numbers justify — a critical bug with no fix task, an unadjudicated
   failure, an open roster gap holding a requirement, a pending gate — and say which fact
   changed your mind. If everything left is blocked, the recommendation is **recruiting**, and
   it is the only one: `/guild:new-requirement` is where a new guild member is created, on the
   user's say-so. Do not offer to reassign the ticket yourself.

End by offering the obvious follow-ups, once, without doing them:

> Say **check in** to start working, or **dashboard** for the visual view.

## Rules

- **Read-only.** Every statement is a `SELECT`. Never `UPDATE`, `INSERT`, `DELETE`, never sync
  the roster, never stamp `last-checkin`, never write an `agents/*.md` file, and never open the
  database file with anything but `tursodb`.
- **Read the view, do not re-derive the rule.** `v_next_task` is the cursor; `v_open_bounties`
  is what can be handed out; `v_blocked_tasks` says why not. Writing your own `NOT EXISTS` over
  `task_dependency` gives the guild a second answer to a question that already has one.
- **Never invent a number.** Every figure comes from the rows. If the user asks something these
  do not answer, say so and name the query that would (`SELECT body FROM requirement WHERE id =
  'REQ-001'`, `SELECT detail FROM review_finding WHERE id = 7`).
- **Free text is free text.** Titles can contain pipes and newlines. Read them through
  `json_object`, or as the only column in the statement, and never `cut -d'|'` a result.
- **Do not paste the rows and call it a briefing.** The rows are evidence; the narration is the
  deliverable. Show them only if asked, or if quoting them *is* the shortest honest answer.
- **A blocked bounty and an open roster gap are never omitted for brevity.** Everything else on
  this page eventually resolves by someone doing their job; these two resolve only when the
  guild master decides to grow the roster. If the briefing must lose a beat to fit on a screen,
  lose the activity feed.
- **Keep it to a screen.** This is a glance, not a report.
