# shellcheck shell=bash
#
# lib/brief.sh — `guild brief`: the structured project briefing (design §10, Stage 2).
#
# v4's status was "list the directories". This is built from real queries, and it answers
# the whole check-in question in one pass:
#
#   Direction            active goals by priority, the phase each is on, progress
#   In Flight            what is in-progress right now, and for how long
#   Blocked              tasks that cannot move, and what they are waiting on
#   Open Bounties        what is actionable next — Stage 1's `guild next` rule
#   Bugs                 open defects, worst severity first
#   Failed Tasks         every task at `failed`, unresolved ones first, waived ones marked
#   Review Findings      what reviewers flagged and nobody has resolved
#   Coverage             quality areas never inspected or overdue for it
#   Since Last Check-in  what moved: the `event` feed since `--since` / `last-checkin`
#   Roster Gaps          `capability_request` rows still open (Stage 3 fills that table)
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` — scripts/guild owns those.
# Depends on lib/db.sh (die, db_require_init, db_query, db_fail, sql_text, sql_str) and
# on lib/render.sh (_render_flat, _render_tmp, _render_query). Bash 3.2 compatible.
#
# It EXPORTS two helpers to lib/dashboard.sh, which is the other Stage 2 read-only view
# over the same tables: `_brief_clip` (the free-text clip) and `_brief_fact_select` (the
# `H key=<integer>` count transport). Both commands compose their headline numbers out of
# counts rather than out of queried strings, and they do it the same way on purpose.
#
# It MUTATES NOTHING. There is no journal_append and no `event` row here, and that is not
# an oversight of design rule 5 — reading the board is not a change to it, and a brief
# that logged itself would pollute the very feed its "Since Last Check-in" section reads.
# `guild checkin` is the writer that moves the cutoff.
#
# ---------------------------------------------------------------------------------
# ONE db_exec (§2.2). This is the command most tempted to issue ten queries — it has ten
# sections — and it issues one. The mechanism is `render_board`'s, scaled up: a
# single script of tagged statements, run once through `_render_query`, folded into a
# document by awk. Statement ORDER fixes section order; each statement's own ORDER BY
# fixes row order inside a section.
#
#   M   meta          — one line (text: `M key=value`; json: `M {…}`)
#   H   counts        — `H key=<integer>`, one per fact, identical in both modes
#   A   direction     B  in flight      C  blocked        D  open bounties
#   E   bugs          J  failed tasks   K  review findings
#   F   coverage      G  activity       I  roster gaps
#
# J AND K ARE THE TWO NUMBERS THE SUMMARY USED TO PRINT WITHOUT NAMING. `N failed task(s)
# · N unresolved review finding(s)` sat on the header while no section below resolved
# either to an id — so a failed ticket could exist and appear NOWHERE in the document that
# exists to say what is wrong. A briefing may leave a section out because it is empty; it
# may not count a thing and then decline to name it. The two sections cost two statements
# in the same script and nothing else: `_render_query` still runs once.
#
# THE OUTPUT-CHANNEL RULE (§2.2.2, design rule 3). A value must never be able to
# impersonate a structural token. Here the structural tokens are the leading tag, and —
# for the human surface — the section HEADER LINES, which sit at column 0 and end in a
# colon. Two mechanisms, one per mode, and neither is a regex over attacker text:
#
#   * TEXT mode  — every free-text expression goes through `_brief_txt`, which is
#     `_render_flat` (CR/LF removed in the engine) over `_brief_clip`. A row is therefore
#     always exactly one line, every rendered line begins with the two spaces the SQL put
#     there, and no title can ever start a line — let alone start one with `Bugs:`.
#     Untagged lines are DROPPED by the reader, never folded onto the previous row.
#
#   * JSON mode  — every value is emitted by `json_object()`, which escapes newlines and
#     quotes in the engine, so one row is one line and awk never touches a value. Same
#     choice `export_json` makes, for the same reason.
#
# CLIPPING. Free text is clipped to a fixed width in BOTH modes. A brief is a briefing:
# the harness proves a 500 KB requirement body round-trips, and one such title would
# otherwise be the whole document. The byte-exact value is one round trip away in
# `guild meta <ID> title`, and the full state is in `guild export --json`.
#
# WHAT IS *NOT* FLATTENED IN JSON MODE: nothing needs to be. Flattening is lossy (a
# newline becomes a space) and json_object is not, so the JSON keeps the real value up to
# the clip width while the text surface keeps its one-line-per-row guarantee.
# ---------------------------------------------------------------------------------
#
# THE `next` FIELD IS `guild next`'S RULE, SPELLED AS ONE EXPRESSION — resume the
# lowest-ID in-progress task, else the lowest-ID todo task with the reviewer gate. Open
# Bounties lists the same predicate's rows. This is deliberate parity: the briefing must
# not name a bounty the CLI would refuse to hand out, or vice versa. When Stage 4 teaches
# `guild next` about `task_dependency`, `_brief_bounty_where` and `cmd_next` change
# together — a dependency-blocked todo task is listed in BOTH Blocked and Open Bounties
# today, which is the truth: Blocked says why it should wait, and `guild next` would still
# hand it out.
#
# PORTABILITY (§3.0). Plain CTEs, scalar subqueries, printf(), json_object(), group_concat
# and julianday() only. No FTS5, no WITH RECURSIVE, no generated columns, none of the five
# banned window functions — which is why "the newest 25 events, oldest first" is an
# ORDER BY inside a subquery rather than a row_number(). julianday() is the one datetime
# function used, verified against tursodb 0.7.2; it yields NULL on an unparseable stored
# timestamp, and every use is COALESCE-guarded so a bad row degrades to "age unknown"
# instead of blanking a line.

# ---- SQL fragment helpers ----------------------------------------------------------

# _brief_clip <sql-expression> [chars] — clip a value to at most <chars> characters,
# marking the cut with a horizontal ellipsis. See CLIPPING in the header.
_brief_clip() {
  local n="${2:-120}"
  printf "CASE WHEN length(%s) > %s THEN substr(%s, 1, %s) || '…' ELSE %s END" \
    "$1" "$n" "$1" "$((n - 1))" "$1"
}

# _brief_txt <sql-expression> [chars] — free text for the HUMAN surface: clipped, then
# flattened so it cannot span lines. The one gate every free-text value passes in text
# mode; see THE OUTPUT-CHANNEL RULE in the header.
_brief_txt() {
  _render_flat "$(_brief_clip "$1" "${2:-120}")"
}

# _brief_age <timestamp-expression> <now-literal> — a human duration ('4d', '7h', '12m').
#
# Minutes are computed once as a julianday delta and then bucketed by INTEGER DIVISION,
# which is what SQLite's `/` does when both sides are integers. A NULL or unparseable
# timestamp makes the delta NULL, so the CASE falls to 'age unknown' rather than printing
# an empty field in the middle of a line.
_brief_age() {
  local m
  m="CAST((julianday($2) - julianday($1)) * 1440 AS INTEGER)"
  printf "CASE WHEN %s IS NULL THEN 'age unknown' WHEN %s < 1 THEN 'just now' WHEN %s < 60 THEN %s || 'm' WHEN %s < 1440 THEN (%s / 60) || 'h' ELSE (%s / 1440) || 'd' END" \
    "$m" "$m" "$m" "$m" "$m" "$m" "$m"
}

# _brief_blocked_where — the predicate for "cannot move": explicitly blocked, or todo with
# a direct predecessor that is not finished. DIRECT predecessors only, never recursive
# (§3.0): a transitively blocked task surfaces through the one it waits on.
_brief_blocked_where() {
  cat <<'SQL'
t.status = 'blocked'
   OR ( t.status = 'todo'
        AND EXISTS (SELECT 1 FROM task_dependency d JOIN task b ON b.id = d.depends_on
                     WHERE d.task_id = t.id AND b.status NOT IN ('done','waived')) )
SQL
}

# _brief_bounty_where — `guild next`'s candidate rule (lib/artifacts.sh cmd_next), which
# this file must not diverge from. See the note in the header.
#
# The reviewer gate: a task whose agent is exactly `reviewer` waits while any NON-reviewer
# task for its requirement is still open. Matched exactly, and other reviewers are ignored
# in the gate, because two reviewer tickets on one requirement otherwise gate each other
# into a permanent `none`.
#
# STAGE 3: `blocked` IS PART OF THE GATE'S OPEN SET, `failed` is not. The reasoning lives
# in one place — THE BLOCKED CONTRACT at the top of lib/artifacts.sh, decision 2 — and the
# short form is that a review certifying a requirement whose implementation slice was never
# dispatched is a green nobody can tell from a real one. This clause and cmd_next's are the
# SAME predicate written twice, and the header above forbids them to diverge: if you edit
# one, edit the other in the same change.
_brief_bounty_where() {
  cat <<'SQL'
t.status = 'todo'
   AND ( COALESCE(t.agent,'') <> 'reviewer'
         OR NOT EXISTS (SELECT 1 FROM task o
                         WHERE o.requirement_id = t.requirement_id
                           AND o.id <> t.id
                           AND o.status IN ('todo','in-progress','blocked')
                           AND COALESCE(o.agent,'') <> 'reviewer') )
SQL
}

# _brief_coverage_where — "never inspected, or overdue for it", risk-weighted.
#
# The thresholds are the judgment this section encodes, and they are stated once, here:
# a HIGH-risk area is stale after 14 days, medium after 30, low after 90. `coverage.risk`
# exists precisely so "what has nobody looked at" is a query rather than a feeling; an
# unrecognized risk value falls to the medium threshold rather than vanishing.
_brief_coverage_where() {
  cat <<SQL
COALESCE(c.last_inspected_at,'') = ''
   OR (julianday($1) - julianday(c.last_inspected_at))
        >= CASE c.risk WHEN 'high' THEN 14 WHEN 'low' THEN 90 ELSE 30 END
SQL
}

# _brief_waived <task-id-expression> — TRUE when a `failed` task has been ADJUDICATED.
#
# `failed` is two different facts wearing one status. The orchestrator sets it the moment
# an agent reports failure, and then asks the user to retry or skip; on **skip** it writes
# the waiver to the ticket's work log (guild:check-in §3.3) and the ticket stops blocking
# the review gate and requirement completion. Nothing in the schema records that decision
# — `task.status` is still `failed` either way — so the one place the fact exists is the
# work log line the orchestrator was told to write, and this is the predicate that reads
# it back. Getting it wrong is not cosmetic: a briefing that reports an adjudicated
# ticket as an open failure is asking the user to decide something they already decided.
#
# The marker is the ENTRY PREFIX the skill dictates, matched with LIKE (ASCII
# case-insensitive in SQLite, and verified so on tursodb 0.7.2). A prefix rather than a
# substring, because the reason text below quotes agent prose that may well contain the
# phrase; and note that the waiver is only ever consulted for a task already at `failed`,
# so a stray log line cannot invent a waived ticket out of a healthy one.
#
# `task.id` — never free text — is the only value interpolated, and it is composed by this
# file. When a later stage gives the waiver a column of its own, this function is the one
# place that changes.
_brief_waived() {
  printf "EXISTS (SELECT 1 FROM work_log w WHERE w.task_id = %s AND w.entry LIKE 'Skipped by user%%')" "$1"
}

# _brief_fail_reason <task-id-expression> — WHY a task failed, as the work log has it:
# the most recent entry that is not the waiver line.
#
# The waiver is excluded deliberately. On a waived ticket it is the LAST entry, so taking
# "the last entry" would replace every waived task's reason with "Skipped by user on …" —
# restating the marker the row already prints and discarding the agent's actual report,
# which is the only thing on the row a reader cannot get from the status. Skipping it
# keeps the two orthogonal: the marker says whether it was adjudicated, the reason says
# what went wrong. A task whose only log line is the waiver has no reason, and the caller
# drops the clause rather than printing an empty field.
#
# NULL when the log is empty, which is the common case for a ticket that failed before its
# agent wrote anything.
_brief_fail_reason() {
  printf "(SELECT w.entry FROM work_log w WHERE w.task_id = %s AND w.entry NOT LIKE 'Skipped by user%%' ORDER BY w.ts DESC, w.id DESC LIMIT 1)" "$1"
}

# _brief_severity_rank <severity-expression> — worst first, unknown last.
#
# `bug.severity` and `review_finding.severity` share an alphabet (review_finding also
# admits `nit`), and both sections want the same order, so both get it from here rather
# than from two hand-copied CASE ladders that can drift.
_brief_severity_rank() {
  printf "CASE %s WHEN 'critical' THEN 1 WHEN 'major' THEN 2 WHEN 'minor' THEN 3 WHEN 'nit' THEN 4 ELSE 5 END" "$1"
}

# _brief_subject_title <subject-type-expr> <subject-id-expr> — the TITLE of whatever an
# event names, or '' for a subject that has none.
#
# An event row carries `subject_type` + `subject_id` and nothing else, so a feed built from
# it alone reads `moved task TASK-001` twice in a row and never says WHICH task or what
# happened to it. `subject_type` is the SUBJECT'S TABLE NAME (every writer passes
# `sql_str "$table"`), so the title is a COALESCE over one guarded scalar subquery per
# titled table: the guard is inside the WHERE, so a non-matching type selects no rows and
# yields NULL rather than a wrong title, and a subject whose row was deleted — or one like
# `guild_state` that has no title column at all — falls through to ''.
#
# Each entry is `<table> <key-column> <title-column>`, because two of the eight disagree
# with the obvious guess: `doc` is keyed by `slug` rather than `id`, and `coverage` names
# its human label `area` rather than `title`. A wrong column name here is not a wrong title,
# it is `no such column` and a briefing that does not render at all.
#
# The table and column names are fixed text from this list, never from a row. The two
# expressions are interpolated as-is because both are composed by this file
# (`e.subject_type`, `e.subject_id`).
_brief_subject_title() {
  local st="$1" sid="$2" t key col out=""
  while read -r t key col; do
    [ -n "$t" ] || continue
    out="$out${out:+, }(SELECT s.$col FROM $t s WHERE $st = '$t' AND s.$key = $sid)"
  done <<'TITLED'
goal id title
phase id title
requirement id title
plan id title
task id title
bug id title
doc slug title
coverage id area
TITLED
  printf "COALESCE(%s, '')" "$out"
}

# _brief_payload_phrase <payload-expression> — an event payload as a PHRASE, not as JSON.
#
# `{"from":"open","to":"fixing"}` is how the writer recorded the move; `open → fixing` is
# what the reader wants, and it is the single most common payload shape on the feed. Any
# other payload is shown as it was stored (clipped by the caller) rather than dropped —
# losing it is how the text brief ended up strictly less informative than `--json`, which
# is the one surface the brief SKILL tells the narrator NOT to use.
#
# `json_extract` RAISES on malformed JSON, and a raised error aborts the whole briefing.
# `CASE WHEN json_valid(x) THEN json_extract(...) END` is the guard lib/db.sh's `_spool_sql`
# established for exactly this: CASE evaluates only the matched branch, so an unparseable
# payload (a hand-edited journal line, a v4 carry-over) degrades to "show it raw".
_brief_payload_phrase() {
  local p="$1" from to entry summary sev
  from="CASE WHEN json_valid($p) THEN CAST(json_extract($p, '\$.from') AS TEXT) END"
  to="CASE WHEN json_valid($p) THEN CAST(json_extract($p, '\$.to') AS TEXT) END"
  entry="CASE WHEN json_valid($p) THEN CAST(json_extract($p, '\$.entry') AS TEXT) END"
  summary="CASE WHEN json_valid($p) THEN CAST(json_extract($p, '\$.summary') AS TEXT) END"
  sev="CASE WHEN json_valid($p) THEN CAST(json_extract($p, '\$.severity') AS TEXT) END"
  # Four shapes, in the order they are worth reading: a status move, a work-log entry, a
  # review finding, and — for anything a later stage invents — the payload as stored,
  # which is worse to read than a phrase and far better than the nothing this line used to
  # print. `{}` is the fifth shape and renders as absence, because "created task TASK-012"
  # needs no detail column saying `{}`.
  printf "CASE WHEN COALESCE(%s,'') <> '' OR COALESCE(%s,'') <> '' THEN COALESCE(%s,'?') || ' → ' || COALESCE(%s,'?') WHEN COALESCE(%s,'') <> '' THEN %s WHEN COALESCE(%s,'') <> '' THEN COALESCE(NULLIF(%s,''),'?') || ': ' || %s WHEN COALESCE(%s,'') IN ('','{}') THEN '' ELSE %s END" \
    "$from" "$to" "$from" "$to" "$entry" "$entry" "$summary" "$sev" "$summary" "$p" "$p"
}

# _brief_fact_select — read `<key> <sql-count-expression>` lines on stdin; emit the
# UNION ALL body of one SELECT that renders each as an `H <key>=<integer>` line, in the
# order given.
#
# THE `H` LINES ARE THE ONE THING `guild brief` AND `guild dashboard` BUILD IDENTICALLY,
# so they build it with one function. Both commands compose a briefing out of counts
# rather than out of queried strings — the human Summary line, the JSON `summary` object,
# the page's stat tiles, and the "… and N more" / "showing N of M" footer every capped
# section needs — and both arrived with a byte-identical copy of this loop. Two copies of
# the transport is how the two surfaces stop agreeing about what a count line looks like.
#
# Each caller keeps its OWN fact list, because the two ask different questions (the brief
# wants `bounties` and `events_since`; the page wants `tasks_waived` and `graph_edges`).
# The list is a fixed heredoc at the call site and never input, so nothing a user typed
# reaches `$fkey` or `$fexpr` — which is what makes emitting them unquoted correct.
#
# Every value is a COUNT, so there is nothing to escape and nothing that can carry a
# value; that is also why the counts are UNCAPPED where the lists they describe are not.
_brief_fact_select() {
  local hsel fkey fexpr fno
  hsel=""
  fno=0
  while read -r fkey fexpr; do
    [ -n "$fkey" ] || continue
    fno=$((fno + 1))
    hsel="$hsel${hsel:+
UNION ALL }SELECT $fno AS o, 'H $fkey=' || $fexpr AS line"
  done
  printf '%s' "$hsel"
}

# ---- the single query --------------------------------------------------------------

# _brief_sql <mode> <now-literal> <since-literal> — the whole briefing as one script.
# <mode> is `text` or `json` and selects the PROJECTION only: which rows each section
# holds, and in what order, is written once and shared by both.
_brief_sql() {
  local mode="$1" nowlit="$2" sincelit="$3"
  local since_expr src_expr next_expr age_expr
  local blocked_expr bounty_expr coverage_expr waived_expr reason_expr
  local meta_sql goal_expr flight_expr block_expr bounty_row_expr
  local bug_expr fail_expr find_expr cov_expr act_expr gap_expr
  local hsel

  # The cutoff, resolved IN SQL so that reading `guild_state` costs no second round trip:
  # an explicit --since wins; else the recorded check-in; else the empty string, which
  # every consumer below reads as "no cutoff — show the most recent events". The seeded
  # literal 'null' is not a date, so NULLIF folds it into "no cutoff".
  since_expr="COALESCE(NULLIF($sincelit, ''), (SELECT NULLIF(value, 'null') FROM guild_state WHERE key = 'last-checkin'), '')"
  src_expr="CASE WHEN NULLIF($sincelit, '') IS NOT NULL THEN 'arg' WHEN (SELECT NULLIF(value, 'null') FROM guild_state WHERE key = 'last-checkin') IS NOT NULL THEN 'checkin' ELSE 'none' END"

  # The three predicates are written multi-line for readability and folded to ONE line
  # here, because each is interpolated into the `H` fact list below, whose transport is
  # one fact per line. One representation, folded once, so the count and the listing can
  # never drift apart.
  blocked_expr="$(_brief_blocked_where | tr '\n' ' ')"
  bounty_expr="$(_brief_bounty_where | tr '\n' ' ')"
  coverage_expr="$(_brief_coverage_where "$nowlit" | tr '\n' ' ')"

  # Written once and used FOUR times — the `tasks_failed_waived` count, the section's
  # marker, its sort key, and the JSON's `waived` field. Same rule as the three above: one
  # representation, so the number and the listing cannot disagree about what waived means.
  waived_expr="$(_brief_waived 't.id')"
  reason_expr="$(_brief_fail_reason 't.id')"

  # `guild next`, as a scalar. Resume beats claim, exactly as cmd_next orders them.
  next_expr="COALESCE((SELECT id FROM task WHERE status = 'in-progress' ORDER BY id LIMIT 1), (SELECT t.id FROM task t WHERE $bounty_expr ORDER BY t.id LIMIT 1), '')"
  age_expr="$(_brief_age "COALESCE(NULLIF(t.claimed_at,''), t.updated_at)" "$nowlit")"

  if [ "$mode" = json ]; then
    meta_sql="SELECT 'M ' || json_object('generated_at', $nowlit, 'since', $since_expr, 'since_source', $src_expr, 'next', NULLIF($next_expr, ''))"

    goal_expr="json_object('id', g.id, 'title', $(_brief_clip 'g.title'), 'status', g.status, 'priority', g.priority, 'phase_id', ph.id, 'phase_title', $(_brief_clip 'ph.title'), 'phase_ordinal', ph.ordinal, 'requirements_total', COUNT(r.id), 'requirements_done', COALESCE(SUM(CASE WHEN r.status = 'done' THEN 1 ELSE 0 END), 0))"

    flight_expr="json_object('id', t.id, 'title', $(_brief_clip 't.title'), 'agent', t.agent, 'requirement_id', t.requirement_id, 'parallel_group', t.parallel_group, 'since', COALESCE(NULLIF(t.claimed_at,''), t.updated_at), 'age', $age_expr)"

    block_expr="json_object('id', t.id, 'title', $(_brief_clip 't.title'), 'agent', t.agent, 'requirement_id', t.requirement_id, 'status', t.status, 'waiting_on', (SELECT group_concat(x, ' ') FROM (SELECT b.id AS x FROM task_dependency d JOIN task b ON b.id = d.depends_on WHERE d.task_id = t.id AND b.status NOT IN ('done','waived') ORDER BY b.id)))"

    bounty_row_expr="json_object('id', t.id, 'title', $(_brief_clip 't.title'), 'agent', t.agent, 'requirement_id', t.requirement_id, 'priority', t.priority, 'parallel_group', t.parallel_group)"

    bug_expr="json_object('id', b.id, 'title', $(_brief_clip 'b.title'), 'severity', b.severity, 'status', b.status, 'found_by', b.found_by, 'requirement_id', b.requirement_id, 'fix_task_id', b.fix_task_id, 'created_at', b.created_at)"

    # `waived` is a JSON boolean-as-integer rather than a string, so a consumer branches on
    # it instead of string-matching a marker this file could later reword.
    fail_expr="json_object('id', t.id, 'title', $(_brief_clip 't.title'), 'agent', t.agent, 'requirement_id', t.requirement_id, 'waived', CASE WHEN $waived_expr THEN 1 ELSE 0 END, 'reason', $(_brief_clip "$reason_expr" 200), 'updated_at', t.updated_at)"

    # `detail` is carried here and NOT on the text surface: it is the reviewer's full
    # argument, which is a paragraph, and the text brief is a glance. This is the same
    # split `bug`/`bug show` makes, and it is why the skill no longer needs `export --json`
    # to read a finding.
    find_expr="json_object('id', f.id, 'task_id', f.task_id, 'reviewer', f.reviewer, 'severity', f.severity, 'disposition', f.disposition, 'summary', $(_brief_clip 'f.summary'), 'detail', $(_brief_clip 'f.detail' 200), 'file', f.file, 'line', f.line, 'fix_task_id', f.fix_task_id, 'created_at', f.created_at)"

    cov_expr="json_object('id', c.id, 'area', $(_brief_clip 'c.area'), 'risk', c.risk, 'spec_path', c.spec_path, 'last_inspected_at', c.last_inspected_at, 'days_since', CAST(julianday($nowlit) - julianday(c.last_inspected_at) AS INTEGER))"

    act_expr="json_object('ts', e.ts, 'actor', e.actor, 'verb', e.verb, 'subject_type', e.subject_type, 'subject_id', e.subject_id, 'subject_title', $(_brief_clip "$(_brief_subject_title 'e.subject_type' 'e.subject_id')" 120), 'payload', e.payload)"

    gap_expr="json_object('id', q.id, 'capability', q.capability, 'requirement_id', q.requirement_id, 'proposed_agent', q.proposed_agent, 'rationale', $(_brief_clip 'q.rationale' 200), 'created_at', q.created_at)"
  else
    # Every free-text value below is `_brief_txt`; every structural piece is a literal the
    # SQL owns. Ids go through it too — cheap, and `guild rebuild` replays ids from a file
    # that lives in git, so an id is not automatically a safe alphabet.

    # ONE FACT PER LINE, never `key=v key=v` on a shared line. `since` is the only free
    # text in the meta, and on a whitespace-separated line it did not need a newline to do
    # damage: `--since 'x source=arg next=TASK-999'` overwrote two other fields, and a
    # benign two-word value silently truncated itself to the first word. That is
    # `_render_col`'s finding in render.sh, one surface over — flattening turns a newline
    # into a SPACE, so on a space-delimited surface the attack simply moves one field to
    # the right. The fix is the same one: remove the shared boundary. With one fact per
    # line the only structural token is `key=` at the START of a line, the reader takes the
    # value as the WHOLE remainder after the first `=`, and a flattened value can never
    # begin a line.
    meta_sql="SELECT line FROM (
  SELECT 1 AS o, 'M now=' || $nowlit AS line
  UNION ALL SELECT 2, 'M since=' || $(_brief_txt "$since_expr" 64)
  UNION ALL SELECT 3, 'M source=' || $src_expr
  UNION ALL SELECT 4, 'M next=' || $(_brief_txt "$next_expr" 64)
) ORDER BY o"

    goal_expr="'  ' || $(_brief_txt 'g.id' 32) || '  [p' || g.priority || ' ' || $(_brief_txt 'g.status' 24) || ']  ' || $(_brief_txt 'g.title' 90) || CASE WHEN ph.id IS NULL THEN '  ·  no open phase' ELSE '  ·  on ' || $(_brief_txt 'ph.id' 32) || ' ' || $(_brief_txt 'ph.title' 60) END || '  ·  ' || COALESCE(SUM(CASE WHEN r.status = 'done' THEN 1 ELSE 0 END), 0) || '/' || COUNT(r.id) || ' req done'"

    # `_render_task_who`, NOT `COALESCE(NULLIF(t.agent,''), 'unassigned')` — the same
    # shared expression `guild board` and `guild list task` print, for the same reason.
    # Stage 3 made `--agent` optional, so a capability-routed ticket has an empty
    # `t.agent` and this column said `unassigned` about work the roster can absolutely
    # place. Three surfaces printing three answers about one ticket is the mismatch;
    # `needs:frontend+implement` is the answer all three now give.
    flight_expr="'  ' || $(_brief_txt 't.id' 32) || '  ' || $(_brief_txt 't.title' 80) || '  ·  ' || $(_brief_txt "$(_render_task_who 't.id')" 40) || '  ·  ' || $(_brief_txt 't.requirement_id' 32) || '  ·  ' || $age_expr"

    block_expr="'  ' || $(_brief_txt 't.id' 32) || '  ' || $(_brief_txt 't.title' 80) || '  ·  ' || $(_brief_txt 't.status' 24) || '  ·  waiting on ' || $(_brief_txt "COALESCE((SELECT group_concat(x, ' ') FROM (SELECT b.id AS x FROM task_dependency d JOIN task b ON b.id = d.depends_on WHERE d.task_id = t.id AND b.status NOT IN ('done','waived') ORDER BY b.id)), 'nothing recorded')" 80)"

    bounty_row_expr="'  ' || $(_brief_txt 't.id' 32) || '  ' || $(_brief_txt 't.title' 80) || '  ·  ' || $(_brief_txt "$(_render_task_who 't.id')" 40) || '  ·  ' || $(_brief_txt 't.requirement_id' 32) || '  ·  p' || t.priority"

    bug_expr="'  ' || $(_brief_txt 'b.id' 32) || '  ' || $(_brief_txt 'b.severity' 16) || '  ' || $(_brief_txt 'b.status' 16) || '  ' || $(_brief_txt 'b.title' 80) || '  ·  found by ' || $(_brief_txt "COALESCE(NULLIF(b.found_by,''), 'unknown')" 40) || CASE WHEN COALESCE(b.fix_task_id,'') = '' THEN '' ELSE '  ·  fix ' || $(_brief_txt 'b.fix_task_id' 32) END"

    # `[unresolved]` / `[waived]` sits where the bug row puts its status, because it is the
    # same question — is this still mine to deal with? The reason clause is dropped rather
    # than blanked when the work log carries nothing, exactly as the bug row drops `fix`.
    fail_expr="'  ' || $(_brief_txt 't.id' 32) || '  [' || CASE WHEN $waived_expr THEN 'waived' ELSE 'unresolved' END || ']  ' || $(_brief_txt 't.title' 80) || '  ·  ' || $(_brief_txt "$(_render_task_who 't.id')" 40) || '  ·  ' || $(_brief_txt 't.requirement_id' 32) || CASE WHEN COALESCE($reason_expr, '') = '' THEN '' ELSE '  ·  ' || $(_brief_txt "$reason_expr" 100) END"

    # severity · disposition · reviewer · the task it came from · the summary — then
    # file:line when the reviewer gave one, and the fix ticket when one is linked. The
    # location is on the human surface deliberately: "reviewer-security flagged an unsigned
    # callback token at src/queue/consume.ts:61" is the sentence the check-in narration is
    # asked for, and before this section it could only be reached by dumping the board.
    # `f.line` is an INTEGER column on a STRICT table, so it concatenates unescaped.
    find_expr="'  ' || $(_brief_txt 'f.severity' 16) || '  ' || $(_brief_txt 'f.disposition' 16) || '  ' || $(_brief_txt "COALESCE(NULLIF(f.reviewer,''), 'unknown')" 40) || '  on ' || $(_brief_txt 'f.task_id' 32) || '  ' || $(_brief_txt 'f.summary' 80) || CASE WHEN COALESCE(f.file,'') = '' THEN '' ELSE '  ·  ' || $(_brief_txt 'f.file' 60) || COALESCE(':' || f.line, '') END || CASE WHEN COALESCE(f.fix_task_id,'') = '' THEN '' ELSE '  ·  fix ' || $(_brief_txt 'f.fix_task_id' 32) END"

    cov_expr="'  ' || $(_brief_txt 'c.id' 40) || '  [' || $(_brief_txt 'c.risk' 16) || ']  ' || $(_brief_txt 'c.area' 60) || '  ·  ' || CASE WHEN COALESCE(c.last_inspected_at,'') = '' THEN 'never inspected' ELSE 'last ' || $(_brief_txt 'c.last_inspected_at' 32) || ' (' || CAST(julianday($nowlit) - julianday(c.last_inspected_at) AS INTEGER) || 'd ago)' END || CASE WHEN COALESCE(c.spec_path,'') = '' THEN '  ·  no spec' ELSE '  ·  ' || $(_brief_txt 'c.spec_path' 60) END"

    # THE ONE SECTION THE SKILL SAYS TO SUMMARIZE WAS THE ONE STRIPPED OF EVERYTHING
    # SUMMARIZABLE. `ts actor verb subject_type subject_id` renders two consecutive status
    # moves on the same task as two byte-identical lines, names nothing, and sends a
    # narrator who was told "prefer the text surface" to the strictly less informative of
    # the two. The title says WHICH, and the payload phrase says WHAT CHANGED — both
    # flattened and clipped like every other free-text value on this surface, so a row is
    # still exactly one line and no value can begin one.
    act_expr="'  ' || $(_brief_txt 'e.ts' 32) || '  ' || $(_brief_txt 'e.actor' 32) || '  ' || $(_brief_txt 'e.verb' 24) || '  ' || $(_brief_txt 'e.subject_type' 24) || ' ' || $(_brief_txt 'e.subject_id' 40) || CASE WHEN $(_brief_subject_title 'e.subject_type' 'e.subject_id') = '' THEN '' ELSE '  ' || $(_brief_txt "$(_brief_subject_title 'e.subject_type' 'e.subject_id')" 70) END || CASE WHEN $(_brief_payload_phrase 'e.payload') = '' THEN '' ELSE '  ·  ' || $(_brief_txt "$(_brief_payload_phrase 'e.payload')" 90) END"

    gap_expr="'  ' || $(_brief_txt 'q.capability' 40) || '  ·  ' || $(_brief_txt 'q.requirement_id' 32) || '  ·  proposed ' || $(_brief_txt 'q.proposed_agent' 40) || '  ·  ' || $(_brief_txt 'q.rationale' 100)"
  fi

  # ---- the counts -----------------------------------------------------------------
  #
  # `H key=<integer>` lines, IDENTICAL in both modes — every value is a COUNT, so there is
  # nothing to escape and nothing to render differently. They do three jobs at once: the
  # human Summary line, the JSON `summary` object, and the "… and N more" footer each
  # truncated section needs (the section itself is LIMITed; the count is not).
  #
  # They are also what makes an EMPTY GUILD produce a briefing instead of eight "(none)"
  # lines: the reader composes prose from these integers, never from a queried string.
  #
  # The transport is `_brief_fact_select`, shared with `guild dashboard`; only the LIST is
  # local. Note for the harness's interpolation audit: every key below is fixed text from
  # this heredoc, never user input, and the three `$*_expr` values interpolated into it
  # are SQL fragments this function composed and folded to one line. THE HEREDOC IS DATA,
  # NOT SQL — every line becomes one `UNION ALL SELECT 'H key=' || (expr)` — so it takes no
  # comments of its own, in either syntax. Anything to say about a fact is said here.
  #
  # `events_board` IS `events_total` MINUS THE ROSTER, and it exists because ONE consumer
  # asks a different question: "is this guild empty". Stage 3 seeds the roster during
  # `guild init`, which writes one `enlisted` row per agent file before the guild master
  # has done anything at all — so a brand-new guild had a non-zero `events_total` and
  # reported itself as non-empty, swallowing the "here is how to start" briefing that is
  # the entire point of the empty case. Filtered by SUBJECT TYPE rather than by verb,
  # because the roster has three verbs (`enlisted`, `updated`, `retired`) and only the
  # subject stays 'agent'.
  #
  # `events_total` KEEPS ITS PLAIN MEANING — every row, enlistments included — so it still
  # agrees with `guild dashboard`'s fact of the same name, which the page uses for
  # "showing N of M event(s)" over a list that DOES show them. One name, one value, in both
  # modules; the narrower question got its own name instead of quietly redefining a shared
  # one. Same for `events_since` and the Since Last Check-in section: enlistments are real
  # history, they are just not work.
  hsel="$(
    _brief_fact_select <<FACTS
goals_total (SELECT COUNT(*) FROM goal)
goals_open (SELECT COUNT(*) FROM goal WHERE status <> 'done')
phases_open (SELECT COUNT(*) FROM phase WHERE status <> 'done')
req_total (SELECT COUNT(*) FROM requirement)
req_done (SELECT COUNT(*) FROM requirement WHERE status = 'done')
req_unattached (SELECT COUNT(*) FROM requirement WHERE phase_id IS NULL)
tasks_total (SELECT COUNT(*) FROM task)
tasks_done (SELECT COUNT(*) FROM task WHERE status = 'done')
tasks_failed (SELECT COUNT(*) FROM task WHERE status = 'failed')
tasks_failed_waived (SELECT COUNT(*) FROM task t WHERE t.status = 'failed' AND $waived_expr)
in_flight (SELECT COUNT(*) FROM task WHERE status = 'in-progress')
blocked (SELECT COUNT(*) FROM task t WHERE $blocked_expr)
bounties (SELECT COUNT(*) FROM task t WHERE $bounty_expr)
findings_open (SELECT COUNT(*) FROM review_finding WHERE disposition IN ('open','fixing'))
bugs_total (SELECT COUNT(*) FROM bug)
bugs_open (SELECT COUNT(*) FROM bug WHERE status IN ('open','fixing'))
bugs_critical (SELECT COUNT(*) FROM bug WHERE status IN ('open','fixing') AND severity = 'critical')
coverage_total (SELECT COUNT(*) FROM coverage)
coverage_never (SELECT COUNT(*) FROM coverage WHERE COALESCE(last_inspected_at,'') = '')
coverage_due (SELECT COUNT(*) FROM coverage c WHERE $coverage_expr)
docs_total (SELECT COUNT(*) FROM doc)
events_total (SELECT COUNT(*) FROM event)
events_board (SELECT COUNT(*) FROM event WHERE subject_type <> 'agent')
events_since (SELECT COUNT(*) FROM event e WHERE ($since_expr) = '' OR e.ts >= ($since_expr))
gaps_open (SELECT COUNT(*) FROM capability_request WHERE status = 'open')
FACTS
  )"

  # ---- the script -----------------------------------------------------------------
  #
  # Statement order IS section order. Every list is LIMITed, because a briefing that
  # prints four hundred bounties is not a briefing; the matching `H` count tells the
  # reader how much it is not showing.
  cat <<SQL
$meta_sql;

SELECT line FROM ($hsel) ORDER BY o;

SELECT 'A ' || $goal_expr
  FROM goal g
  LEFT JOIN phase ph ON ph.id = (SELECT p.id FROM phase p
                                  WHERE p.goal_id = g.id AND p.status <> 'done'
                                  ORDER BY p.ordinal, p.id LIMIT 1)
  LEFT JOIN phase pg ON pg.goal_id = g.id
  LEFT JOIN requirement r ON r.phase_id = pg.id
 WHERE g.status <> 'done'
 GROUP BY g.id, g.title, g.status, g.priority, ph.id, ph.title, ph.ordinal
 ORDER BY g.priority, g.id
 LIMIT 10;

SELECT 'B ' || $flight_expr
  FROM task t
 WHERE t.status = 'in-progress'
 ORDER BY COALESCE(NULLIF(t.claimed_at,''), t.updated_at), t.id
 LIMIT 20;

SELECT 'C ' || $block_expr
  FROM task t
 WHERE $blocked_expr
 ORDER BY t.id
 LIMIT 20;

SELECT 'D ' || $bounty_row_expr
  FROM task t
 WHERE $bounty_expr
 ORDER BY t.id
 LIMIT 10;

SELECT 'E ' || $bug_expr
  FROM bug b
 WHERE b.status IN ('open','fixing')
 ORDER BY $(_brief_severity_rank 'b.severity'), b.id
 LIMIT 20;

SELECT 'J ' || $fail_expr
  FROM task t
 WHERE t.status = 'failed'
 ORDER BY CASE WHEN $waived_expr THEN 1 ELSE 0 END, t.id
 LIMIT 20;

SELECT 'K ' || $find_expr
  FROM review_finding f
 WHERE f.disposition IN ('open','fixing')
 ORDER BY $(_brief_severity_rank 'f.severity'), f.id
 LIMIT 20;

SELECT 'F ' || $cov_expr
  FROM coverage c
 WHERE $coverage_expr
 ORDER BY CASE c.risk WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END,
          CASE WHEN COALESCE(c.last_inspected_at,'') = '' THEN 0 ELSE 1 END,
          c.last_inspected_at, c.id
 LIMIT 15;

SELECT 'G ' || line FROM (
  SELECT e.ts AS ts, e.id AS eid, $act_expr AS line
    FROM event e
   WHERE ($since_expr) = '' OR e.ts >= ($since_expr)
   ORDER BY e.ts DESC, e.id DESC
   LIMIT 25
) ORDER BY ts, eid;

SELECT 'I ' || $gap_expr
  FROM capability_request q
 WHERE q.status = 'open'
 ORDER BY q.id
 LIMIT 10;
SQL
}

# ---- the human renderer -------------------------------------------------------------

# _brief_text <rows-file> — fold the tagged rows into the briefing.
#
# A row is `<TAG> <text>` and — because every free-text expression was flattened in the
# engine — a row is ALWAYS exactly one line. So the tag can only have been written by the
# SQL, never by a title. Anything untagged is driver noise (a banner, a blank line between
# statements) and is DROPPED rather than folded onto the previous row: folding is how the
# injection used to land, and with flattening there is no legitimate continuation line.
_brief_text() {
  LC_ALL=C awk '
    /^[A-Z] / {
      tag = substr($0, 1, 1)
      txt = substr($0, 3)
      # `M` and `H` are both `key=value`, ONE PER LINE. The key is everything before the
      # FIRST `=`; the value is the whole remainder, so a value containing `=` or spaces
      # is kept intact and cannot reach a second key. See the note on meta_sql.
      if (tag == "M" || tag == "H") {
        eq = index(txt, "=")
        if (eq > 1) fact[tag substr(txt, 1, eq - 1)] = substr(txt, eq + 1)
        next
      }
      n[tag]++
      buf[tag, n[tag]] = txt
      next
    }
    { next }

    function metaval(k) { return fact["M" k] }
    function num(k) { return fact["H" k] + 0 }

    # emit — a section prints only when it has rows. An absent section is good news
    # stated by its absence; eight "(none)" blocks are a wall, not a briefing.
    function emit(head, tag, total,   i, shown) {
      shown = n[tag] + 0
      if (shown == 0) return
      print ""
      print head
      for (i = 1; i <= shown; i++) print buf[tag, i]
      if (total + 0 > shown) printf "  … and %d more\n", total - shown
    }

    END {
      print "Guild Brief"
      print "==========="
      print ""

      src = metaval("source")
      since = metaval("since")
      nxt = metaval("next")

      printf "Generated: %s\n", metaval("now")
      if (src == "arg")          printf "Since:     %s (--since)\n", since
      else if (src == "checkin") printf "Since:     %s (last check-in)\n", since
      else                       print  "Since:     no check-in recorded — showing the most recent activity"

      # An entirely empty guild gets a briefing, not eight empty sections.
      if (num("goals_total") + num("req_total") + num("tasks_total") + num("bugs_total") \
          + num("coverage_total") + num("events_board") == 0) {
        print ""
        print "The guild is empty — nothing is on the board yet."
        print ""
        print "  · Declare direction with the goal and phase commands."
        print "  · Add the first requirement with the guild:new-requirement skill."
        print "  · Run `guild checkin` to open a session, so the next brief can report"
        print "    what moved since this one."
        exit 0
      }

      printf "Next:      %s\n", (nxt == "" ? "none" : nxt)
      printf "Summary:   %d requirement(s), %d done · %d in flight · %d open bounty(ies) · %d open bug(s)",
             num("req_total"), num("req_done"), num("in_flight"), num("bounties"), num("bugs_open")
      if (num("bugs_critical") > 0) printf " (%d critical)", num("bugs_critical")
      printf " · %d area(s) due for inspection · %d event(s) since\n",
             num("coverage_due"), num("events_since")
      # The counts stay — they are the total, and the sections below are LIMITed — but
      # every one of them now resolves to a name further down. `(N waived)` is the same
      # move `(N critical)` makes on the bug count: the number that changes what you do
      # about it, stated beside the number it qualifies.
      if (num("tasks_failed") > 0 || num("findings_open") > 0) {
        printf "           %d failed task(s)", num("tasks_failed")
        if (num("tasks_failed_waived") > 0) printf " (%d waived)", num("tasks_failed_waived")
        printf " · %d unresolved review finding(s)\n", num("findings_open")
      }

      if (n["A"] + 0 > 0) {
        emit("Direction:", "A", num("goals_open"))
      } else {
        print ""
        print "Direction:"
        if (num("goals_total") == 0)
          printf "  No goals declared — %d requirement(s) tracked without one.\n", num("req_total")
        else
          printf "  Every one of the %d goal(s) is done.\n", num("goals_total")
      }

      emit("In Flight:", "B", num("in_flight"))
      emit("Blocked:", "C", num("blocked"))

      if (n["D"] + 0 > 0) {
        emit("Open Bounties:", "D", num("bounties"))
      } else {
        print ""
        print "Open Bounties:"
        if (num("in_flight") > 0)
          printf "  Nothing new to claim — %d task(s) already in flight.\n", num("in_flight")
        else if (num("blocked") > 0)
          printf "  Nothing actionable — %d task(s) are blocked.\n", num("blocked")
        else if (num("tasks_total") == 0)
          print "  No tasks on the board. Add a requirement with the guild:new-requirement skill."
        else
          print "  Nothing actionable — every task on the board is finished or waived."
      }

      emit("Bugs:", "E", num("bugs_open"))
      # Immediately after Bugs, because these three ARE the risk beat the check-in
      # narration reads in order, and because the two counts they resolve are printed
      # three lines above.
      emit("Failed Tasks:", "J", num("tasks_failed"))
      emit("Review Findings:", "K", num("findings_open"))
      emit("Coverage:", "F", num("coverage_due"))
      emit("Since Last Check-in:", "G", num("events_since"))
      emit("Roster Gaps:", "I", num("gaps_open"))
    }
  ' "$1"
}

# ---- the JSON renderer ---------------------------------------------------------------

# _brief_json <rows-file> — the same rows as one JSON document.
#
# Every value was escaped by the engine's json_object(), so awk only assembles arrays and
# never touches a value — the same division of labour `export_json` uses. The `summary`
# object is built from the `H` counts, whose values are validated as digit strings before
# they are emitted unquoted: they are COUNT() results, so this can only ever pass, and it
# means no path exists by which a non-number reaches a JSON number position.
_brief_json() {
  LC_ALL=C awk '
    /^[A-Z] / {
      tag = substr($0, 1, 1)
      txt = substr($0, 3)
      if (tag == "M") { if (substr(txt, 1, 1) == "{") meta = txt; next }
      if (tag == "H") {
        eq = index(txt, "=")
        if (eq > 1) { hk[++hn] = substr(txt, 1, eq - 1); hv[hn] = substr(txt, eq + 1) }
        next
      }
      if (substr(txt, 1, 1) != "{") next
      n[tag]++
      row[tag, n[tag]] = txt
      next
    }
    { next }

    function arr(name, tag,   i) {
      if (n[tag] + 0 == 0) { printf "  \"%s\": [],\n", name; return }
      printf "  \"%s\": [\n", name
      for (i = 1; i <= n[tag]; i++)
        printf "    %s%s\n", row[tag, i], (i < n[tag] ? "," : "")
      print "  ],"
    }

    END {
      print "{"
      printf "  \"meta\": %s,\n", (meta == "" ? "{}" : meta)
      printf "  \"summary\": {"
      for (i = 1; i <= hn; i++) {
        v = hv[i]
        if (v !~ /^-?[0-9]+$/) v = "0"
        printf "%s\n    \"%s\": %s", (i > 1 ? "," : ""), hk[i], v
      }
      print (hn > 0 ? "\n  }," : "},")
      arr("direction",   "A")
      arr("in_flight",   "B")
      arr("blocked",     "C")
      arr("bounties",    "D")
      arr("bugs",        "E")
      arr("failed_tasks",    "J")
      arr("review_findings", "K")
      arr("coverage",    "F")
      arr("activity",    "G")
      # last array: no trailing comma
      if (n["I"] + 0 == 0) {
        print "  \"roster_gaps\": []"
      } else {
        print "  \"roster_gaps\": ["
        for (i = 1; i <= n["I"]; i++)
          printf "    %s%s\n", row["I", i], (i < n["I"] ? "," : "")
        print "  ]"
      }
      print "}"
    }
  ' "$1"
}

# ---- the command ---------------------------------------------------------------------

# brief_run <mode> <since> — compose the script, run it ONCE, render it.
brief_run() {
  local mode="$1" since="$2" nowlit sincelit rows sqlf
  db_require_init

  nowlit="$(sql_str "$(db_now)")"
  sincelit="$(sql_text "$since" '--since')"

  rows="$(_render_tmp brief)"
  sqlf="$(_render_tmp brief-sql)"
  _brief_sql "$mode" "$nowlit" "$sincelit" >"$sqlf"
  _render_query "$sqlf" "$rows" "guild: could not read the briefing from the database"

  if [ "$mode" = json ]; then
    _brief_json "$rows"
  else
    _brief_text "$rows"
  fi
  rm -f "$rows"
}

# cmd_brief [--since DATE] [--json] — the dispatcher entry point (design §10).
#
#   guild brief                    the human briefing
#   guild brief --json             the same state for the dashboard and the brief skill
#   guild brief --since 2026-08-01 override the "what moved" cutoff
#
# With no --since the cutoff is `guild_state.last-checkin`; with no check-in recorded the
# activity section shows the most recent events instead of nothing.
cmd_brief() {
  local mode="text" since="" nl
  nl=$'\n'
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) mode="json" ;;
      --since)
        shift
        [ $# -gt 0 ] || die "guild: brief --since needs a date (e.g. --since 2026-08-01)"
        since="$1"
        ;;
      --since=*) since="${1#--since=}" ;;
      -*) die "guild: unknown option '$1' for brief (try 'guild brief [--since DATE] [--json]')" ;;
      *) die "guild: brief takes no positional arguments (got '$1')" ;;
    esac
    shift
  done

  # The cutoff is compared against stored timestamps AS A STRING — ISO-8601 sorts
  # lexicographically, which is why `2026-08-01` correctly admits `2026-08-01T09:14:00Z`.
  # That also means a value that is not a date fails SILENTLY AND WRONGLY: `--since
  # yesterday` sorts above every timestamp this century, so the activity section reports
  # "0 events since" and nothing says why. So the shape is checked rather than trusted.
  #
  # A date PREFIX is all that is required, so a full timestamp (`2026-08-01T09:00:00Z`) is
  # accepted unchanged. Only argv is checked; `guild_state.last-checkin` is whatever
  # `guild checkin` recorded and is never rejected here — the resolved cutoff is printed
  # in the header either way, so what was actually used is always visible.
  case "$since" in
    "") ;;
    *"$nl"*) die "guild: brief --since must be a single line" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) ;;
    *) die "guild: brief --since must start with a YYYY-MM-DD date (got '$since')" ;;
  esac

  brief_run "$mode" "$since"
}
