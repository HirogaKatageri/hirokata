# shellcheck shell=bash
#
# lib/report.sh — guild v5 Stage 5: REPORTING BACK FROM AN UNATTENDED SHIFT (design §8.5).
#
#   > The guild master should be able to reconstruct the whole shift from the `event` log.
#
#   guild shift-report [--since YYYY-MM-DD] [--json]
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` (scripts/guild owns those).
# Bash 3.2 compatible: no associative arrays, no `declare -A`, no `mapfile`, no ${var^^}.
#
# Depends on lib/db.sh    : die, db_require_init, db_now, sql_str, sql_text
#          on lib/render.sh: _render_tmp, _render_query, _render_task_who
#          on lib/brief.sh : _brief_clip, _brief_txt, _brief_fact_select,
#                            _brief_severity_rank, _brief_subject_title,
#                            _brief_payload_phrase   (THE SHARED READ-SURFACE TOOLKIT)
#          on lib/graph.sh : _graph_ready_where      (THE one definition of "ready")
#          on lib/roster.sh: _roster_req_caps        (what a blocked ticket asked for)
#          on lib/shift.sh : _shift_json_int         (the json_valid-guarded integer read)
#
# ---------------------------------------------------------------------------------
# WHY THIS IS NOT A SECTION OF `guild brief`
#
# The two commands read the same tables and answer DIFFERENT QUESTIONS, and the whole
# value of having two is that neither has to compromise for the other:
#
#   guild brief          WHERE DOES THE PROJECT STAND — direction, what is in flight, what
#                        is blocked, what is open to claim, bugs, coverage due. Its spine is
#                        THE BOARD: goals down to bounties, as they are right now. Its
#                        window (`last-checkin`) is a human's attention span.
#
#   guild shift-report   WHAT HAPPENED WHILE I WAS AWAY — which shifts ran, what each one
#                        finished, what it failed at and retried, what it left blocked, what
#                        it filed, what it committed, WHERE IT STOPPED AND WHY. Its spine is
#                        THE SHIFT: a bounded run with an id, a clock, a budget and an
#                        outcome. Its window defaults to THE LAST SHIFT'S OWN START, not to
#                        a check-in — because the question is about that run, not about the
#                        day.
#
# THE SHARP EDGE BETWEEN THEM, stated so it can be kept: this command reports EVENTS, the
# brief reports STATE. A row here is something that HAPPENED, timestamped; a row there is
# something that IS. That is why "Blocked" appears in both and is not a duplicate — the
# brief lists tickets that cannot move, this one lists tickets THIS SHIFT could not place
# and says which shift blocked them and why. Two surfaces that drift apart are worse than
# one, so the test for any future section is the question it answers, not the table it
# reads: if the answer does not change when a shift runs, it belongs in the brief.
#
# ONE CONSEQUENCE, DELIBERATE: there is no Direction section, no Open Bounties section and
# no Coverage section here. A shift cannot change direction (§8.2), so restating it would
# be a paragraph that is identical every morning — and the reader who wants it is one
# command away. The report ENDS by naming `guild brief`, rather than absorbing it.
#
# ---------------------------------------------------------------------------------
# IT MUTATES NOTHING. No journal_append, no `event` row, no `guild_state` write — the same
# posture `guild brief` takes, for a sharper version of the same reason: a shift report that
# logged itself would be an event inside the very window it exists to summarize, and every
# subsequent report would carry the record of the last one being read.
#
# ---------------------------------------------------------------------------------
# HARD RULES honored throughout (§2.2, §2.2.1, §3.0):
#
#   * ONE db_exec. Ten sections, one script, one `_render_query`, one awk pass. Statement
#     order fixes section order; each statement's own ORDER BY fixes row order inside it.
#
#   * sql_text FOR ALL FREE TEXT. Exactly one value reaches SQL from argv — `--since`, a
#     date the guild master typed — and it travels as hex. Everything else this file
#     interpolates is a fixed literal, a column name from a list written here, or a SQL
#     fragment composed by this file.
#
#   * NEVER `WITH RECURSIVE`, and no CTE at all. Readiness is `_graph_ready_where` — CALLED,
#     never restated — which is one hop over `graph_edge`. Every derived fact is a scalar
#     subquery, which is what lib/shift.sh's fragments are too, so the two files spell the
#     same question the same way.
#
#   * A VALUE MUST NEVER IMPERSONATE A STRUCTURAL TOKEN (§2.2.2). Two channels, two
#     disciplines, both inherited from lib/brief.sh because this is the same channel:
#       TEXT — every free-text expression goes through `_brief_txt` (clip, then flatten IN
#              THE ENGINE), so a row is always exactly one line, every rendered line begins
#              with the two spaces the SQL put there, and no title can start a line — let
#              alone start one with `Gates Waiting:`. Untagged lines are DROPPED.
#       JSON — every value is emitted by `json_object()`, which escapes in the engine. awk
#              contributes brackets, commas, fixed key names and integers it validated as
#              digit strings. It never touches a value.
#
#   * NO QUADRATIC STRING HANDLING. Nothing in this file applies `${v%%pat*}` to an
#     unbounded value; the meta channel is `key=<the whole remainder>`, split once by
#     `index()`.
#
#   * `json_extract` RAISES on malformed JSON and a raised error aborts the whole report, so
#     every payload read is wrapped in the `CASE WHEN json_valid(x)` guard lib/db.sh's
#     `_spool_sql` established. A payload this file did not write degrades to NULL, and
#     every caller COALESCEs.

# ---- SQL fragment helpers ------------------------------------------------------------

# _rep_json_txt <json-expression> <key> — a TEXT value out of an event payload, or NULL.
#
# The sibling of lib/shift.sh's `_shift_json_int`, which is CALLED rather than copied for
# the integer keys. Two functions rather than one because the CAST differs and a report that
# prints `7.0` where the payload said `7` is a report somebody has to double-check.
_rep_json_txt() {
  printf "CASE WHEN json_valid(%s) THEN CAST(json_extract(%s, '\$.%s') AS TEXT) END" \
    "${1-}" "${1-}" "${2-}"
}

# _rep_last_started <column> — that column of the MOST RECENT `started` shift event.
#
# The newest `started` is the last shift whether or not it is still open, which is exactly
# what "what happened while I was away" wants: an open shift is the one running now, and a
# closed one is the one that just finished. lib/shift.sh's `_shift_open_evt` answers the
# narrower question (is one open) and is not what this file needs — a report that went blank
# the moment a shift ended would be useless every morning.
_rep_last_started() {
  printf "(SELECT es.%s FROM event es
            WHERE es.subject_type = 'shift' AND es.verb = 'started'
            ORDER BY es.ts DESC, es.id DESC LIMIT 1)" "${1-subject_id}"
}

# _rep_end_of <column> <started-alias> — that column of the `ended` event closing the shift
# the aliased `started` row opened, or NULL while it is still open.
#
# The EARLIEST matching `ended` wins. A shift ends once; a second `ended` row can only come
# from `guild shift --end` racing the loop's own stop condition, and the first one is the
# one that actually closed it.
_rep_end_of() {
  printf "(SELECT ec.%s FROM event ec
            WHERE ec.subject_type = 'shift' AND ec.verb = 'ended'
              AND ec.subject_id = %s.subject_id
            ORDER BY ec.ts, ec.id LIMIT 1)" "${1-payload}" "${2-e}"
}

# _rep_last_end <column> — the same, for the most recent shift, un-aliased.
_rep_last_end() {
  printf "(SELECT ec.%s FROM event ec
            WHERE ec.subject_type = 'shift' AND ec.verb = 'ended'
              AND ec.subject_id = %s
            ORDER BY ec.ts, ec.id LIMIT 1)" "${1-payload}" "$(_rep_last_started subject_id)"
}

# _rep_subject_label <subject-type-expr> <subject-id-expr> — a human name for whatever an
# event points at.
#
# `_brief_subject_title` covers the eight TITLED tables and is CALLED here rather than
# re-listed. It does not cover `graph_node`, which has no title column — and a shift's two
# most interesting events (`retried`, `gave-up`) point at exactly that. So the node's
# `node_key` is tried first and the shared list is the fallback: `implement.auth-service`
# is the label a reader recognizes, and `GN-0041` is not.
_rep_subject_label() {
  local st="${1-}" sid="${2-}"
  printf "COALESCE(NULLIF((SELECT gn.node_key FROM graph_node gn
                            WHERE %s = 'graph_node' AND gn.id = %s), ''), %s)" \
    "$st" "$sid" "$(_brief_subject_title "$st" "$sid")"
}

# _rep_detail <payload-expression> — WHY, for a failure row.
#
# A `retried` / `gave-up` / `blocked` payload carries an explicit `reason`; a `moved` payload
# carries `from`/`to`. `_brief_payload_phrase` already renders the second shape (and every
# other shape the CLI writes, and raw JSON for anything a later stage invents), so it is the
# fallback rather than the whole answer — the reason is strictly better when there is one.
_rep_detail() {
  local p="${1-}" r
  r="$(_rep_json_txt "$p" reason)"
  printf "CASE WHEN COALESCE(%s, '') <> '' THEN %s ELSE %s END" \
    "$r" "$r" "$(_brief_payload_phrase "$p")"
}

# _rep_git_detail <verb-expression> <payload-expression> — the one fact worth reading beside
# a git event, per verb.
#
# The four verbs are lib/gitsafe.sh's, and their payload shapes are its too; this is the
# only place in the CLI that reads them back, so the correspondence is stated here rather
# than assumed. A verb this file does not know renders as the payload phrase, which is how
# a fifth verb shows up as information rather than as a blank column.
_rep_git_detail() {
  local v="${1-}" p="${2-}" sha files br quar
  sha="$(_rep_json_txt "$p" commit)"
  files="$(_shift_json_int "$p" files)"
  br="$(_rep_json_txt "$p" branch)"
  quar="$(_rep_json_txt "$p" quarantine)"
  printf "CASE
            WHEN %s = 'committed' THEN COALESCE(substr(%s, 1, 10), '?') || '  ·  '
                                       || COALESCE(%s, 0) || ' file(s)'
            WHEN %s = 'nothing-to-commit' THEN 'no code to commit'
            WHEN %s = 'reverted' THEN 'quarantined to ' || COALESCE(%s, '?')
            WHEN %s = 'branched' THEN COALESCE(%s, '?')
            ELSE %s
          END" \
    "$v" "$sha" "$files" "$v" "$v" "$quar" "$v" "$br" "$(_brief_payload_phrase "$p")"
}

# _rep_gate_pick <projection-expression> — that projection of THE GATE THE GUILD MASTER
# SHOULD LOOK AT FIRST: a ready one if any gate is ready, else the one nearest to being.
#
# Same ordering `guild gates` prints and `guild shift` stops on — ready before waiting, then
# the board's own priority, then id — because a report that nominated a different gate from
# the one the shift stopped at would be a report arguing with the loop that wrote it.
#
# Written as three sibling subqueries at the call site rather than one nested three deep;
# lib/shift.sh's fragments are un-nested for the same reason (query size grows
# multiplicatively the other way).
_rep_gate_pick() {
  printf "(SELECT %s FROM gate g
             JOIN graph_node n ON n.id = g.node_id
             JOIN requirement r ON r.id = n.requirement_id
            WHERE n.status NOT IN ('done','skipped')
            ORDER BY (CASE WHEN %s THEN 0 ELSE 1 END), r.priority, n.id LIMIT 1)" \
    "${1-n.id}" "$(_graph_ready_where n)"
}

# ---- the single query ----------------------------------------------------------------

# _rep_sql <mode> <now-literal> <since-literal> — the whole report as one script.
#
# <mode> is `text` or `json` and selects the PROJECTION only: which rows each section holds,
# and in what order, is written once and shared by both. `_brief_sql`'s shape exactly, and
# for the same reason — two renderers that disagree about which rows exist is the divergence
# a single query makes impossible.
#
#   M   meta       — one line (text: `M key=value`; json: `M {…}`)
#   H   counts     — `H key=<integer>`, one per fact, identical in both modes
#   A   shifts     B  completed    C  failed and retried    D  blocked
#   E   gates      F  bugs filed   K  findings filed        G  git
_rep_sql() {
  local mode="$1" nowlit="$2" sincelit="$3"
  local since_expr src_expr win_evt state_expr
  local last_id last_ts last_reason last_note last_req
  local gate_node gate_kind gate_ready ready_n
  local shift_expr done_expr fail_expr blk_expr gate_expr bug_expr find_expr git_expr
  local meta_sql hsel

  # FOLDED TO ONE LINE, all three of them, and the reason is `_brief_fact_select`: its
  # transport is one fact per line, so any fragment interpolated into the `H` list must not
  # carry a newline. Folding here rather than at each use is what keeps ONE representation
  # of each predicate — the count and the listing beneath it cannot then drift apart.
  ready_n="$(_graph_ready_where n | tr '\n' ' ')"

  # ---- the window -------------------------------------------------------------------
  #
  # Resolved IN SQL so that reading it costs no second round trip, and defaulted to THE LAST
  # SHIFT'S OWN START rather than to `last-checkin` — that is the one substantive difference
  # between this command's window and the brief's, and it is what makes "what happened while
  # I was away" answerable without the guild master remembering when they left. An explicit
  # --since always wins; with no shift ever recorded the cutoff is '' and every consumer
  # below reads that as "no cutoff".
  since_expr="$(printf "COALESCE(NULLIF(%s, ''), %s, '')" \
    "$sincelit" "$(_rep_last_started ts)" | tr '\n' ' ')"
  src_expr="$(printf "CASE WHEN NULLIF(%s, '') IS NOT NULL THEN 'arg' WHEN %s IS NOT NULL THEN 'shift' ELSE 'none' END" \
    "$sincelit" "$(_rep_last_started ts)" | tr '\n' ' ')"

  # The window predicate. `e.ts` is the event timestamp in every statement that uses it —
  # the alias is fixed rather than a parameter, because a section that windowed on a
  # different column would be a section reporting a different night.
  win_evt="(($since_expr) = '' OR e.ts >= ($since_expr))"

  last_id="$(_rep_last_started subject_id)"
  last_ts="$(_rep_last_started ts)"
  last_reason="$(_rep_json_txt "$(_rep_last_end payload)" reason)"
  last_note="$(_rep_json_txt "$(_rep_last_end payload)" note)"
  last_req="$(_rep_json_txt "$(_rep_last_started payload)" requirement)"

  # An open shift is a `started` with no `ended` — the log IS the state (lib/shift.sh's
  # header). Asked here about the LAST shift specifically, which is the only one a reader can
  # act on, and answered as a WORD rather than as a flag: `none` (no shift has ever run) and
  # `ended` are different answers, and a boolean could not tell them apart.
  state_expr="CASE WHEN $last_id IS NULL THEN 'none'
                   WHEN $(_rep_last_end ts) IS NULL THEN 'open' ELSE 'ended' END"

  gate_node="$(_rep_gate_pick 'n.id')"
  gate_kind="$(_rep_gate_pick 'g.kind')"
  gate_ready="$(_rep_gate_pick "CASE WHEN $ready_n THEN 1 ELSE 0 END")"

  if [ "$mode" = json ]; then
    meta_sql="SELECT 'M ' || json_object('generated_at', $nowlit, 'since', $since_expr, 'since_source', $src_expr, 'shift', $last_id, 'shift_started', $last_ts, 'state', $state_expr, 'stop_reason', $last_reason, 'note', $(_brief_clip "$last_note" 300), 'requirement', $last_req, 'gate_node', $gate_node, 'gate_kind', $gate_kind, 'gate_ready', $gate_ready)"

    shift_expr="json_object('id', e.subject_id, 'started', e.ts, 'ended', $(_rep_end_of ts e), 'open', CASE WHEN $(_rep_end_of ts e) IS NULL THEN 1 ELSE 0 END, 'reason', $(_rep_json_txt "$(_rep_end_of payload e)" reason), 'note', $(_brief_clip "$(_rep_json_txt "$(_rep_end_of payload e)" note)" 300), 'tasks', $(_shift_json_int "$(_rep_end_of payload e)" tasks), 'minutes', $(_shift_json_int "$(_rep_end_of payload e)" minutes), 'steps', $(_shift_json_int "$(_rep_end_of payload e)" steps), 'requirement', $(_rep_json_txt 'e.payload' requirement), 'max_tasks', $(_shift_json_int 'e.payload' max_tasks), 'max_minutes', $(_shift_json_int 'e.payload' max_minutes))"

    done_expr="json_object('ts', e.ts, 'id', t.id, 'title', $(_brief_clip 't.title'), 'agent', t.agent, 'requirement_id', t.requirement_id, 'actor', e.actor)"

    fail_expr="json_object('ts', e.ts, 'verb', e.verb, 'subject_type', e.subject_type, 'subject_id', e.subject_id, 'subject', $(_brief_clip "$(_rep_subject_label 'e.subject_type' 'e.subject_id')" 120), 'detail', $(_brief_clip "$(_rep_detail 'e.payload')" 200))"

    blk_expr="json_object('id', t.id, 'title', $(_brief_clip 't.title'), 'requirement_id', t.requirement_id, 'needs', NULLIF($(_roster_req_caps 't.id'), ''), 'since', (SELECT eb.ts FROM event eb WHERE eb.subject_type = 'task' AND eb.verb = 'blocked' AND eb.subject_id = t.id ORDER BY eb.ts DESC, eb.id DESC LIMIT 1), 'reason', (SELECT $(_rep_json_txt 'eb.payload' reason) FROM event eb WHERE eb.subject_type = 'task' AND eb.verb = 'blocked' AND eb.subject_id = t.id ORDER BY eb.ts DESC, eb.id DESC LIMIT 1))"

    gate_expr="json_object('node', n.id, 'requirement_id', r.id, 'kind', g.kind, 'status', g.status, 'ready', CASE WHEN $ready_n THEN 1 ELSE 0 END, 'prompt', $(_brief_clip 'g.prompt' 400), 'decision', $(_brief_clip 'g.decision' 200))"

    bug_expr="json_object('id', b.id, 'title', $(_brief_clip 'b.title'), 'severity', b.severity, 'status', b.status, 'found_by', b.found_by, 'requirement_id', b.requirement_id, 'created_at', b.created_at)"

    find_expr="json_object('id', f.id, 'task_id', f.task_id, 'reviewer', f.reviewer, 'severity', f.severity, 'disposition', f.disposition, 'summary', $(_brief_clip 'f.summary'), 'file', f.file, 'line', f.line, 'created_at', f.created_at)"

    git_expr="json_object('ts', e.ts, 'verb', e.verb, 'subject_id', e.subject_id, 'detail', $(_brief_clip "$(_rep_git_detail 'e.verb' 'e.payload')" 200), 'branch', $(_rep_json_txt 'e.payload' branch))"
  else
    # Every free-text value below is `_brief_txt`; every structural piece is a literal the
    # SQL owns. Ids go through it too — `guild rebuild` replays ids from a file that lives
    # in git, so an id is not automatically a safe alphabet.
    #
    # ONE FACT PER LINE for the meta, never `key=v key=v` on a shared line: on a
    # space-delimited surface a flattened value simply moves the attack one field to the
    # right (lib/brief.sh's finding, and `_render_col`'s one surface over). With one fact
    # per line the only structural token is `key=` at the START of a line and the reader
    # takes the whole remainder as the value.
    meta_sql="SELECT line FROM (
  SELECT 1 AS o, 'M now=' || $nowlit AS line
  UNION ALL SELECT 2, 'M since=' || $(_brief_txt "$since_expr" 64)
  UNION ALL SELECT 3, 'M source=' || $src_expr
  UNION ALL SELECT 4, 'M shift=' || $(_brief_txt "COALESCE($last_id, '')" 64)
  UNION ALL SELECT 5, 'M state=' || $state_expr
  UNION ALL SELECT 6, 'M reason=' || $(_brief_txt "COALESCE($last_reason, '')" 40)
  UNION ALL SELECT 7, 'M note=' || $(_brief_txt "COALESCE($last_note, '')" 200)
  UNION ALL SELECT 8, 'M scope=' || $(_brief_txt "COALESCE($last_req, '')" 40)
  UNION ALL SELECT 9, 'M gate=' || $(_brief_txt "COALESCE($gate_node, '')" 80)
  UNION ALL SELECT 10, 'M gate_kind=' || $(_brief_txt "COALESCE($gate_kind, '')" 40)
  UNION ALL SELECT 11, 'M gate_ready=' || COALESCE($gate_ready, 0)
) ORDER BY o"

    shift_expr="'  ' || $(_brief_txt 'e.subject_id' 40) || '  [' || CASE WHEN $(_rep_end_of ts e) IS NULL THEN 'open' ELSE 'ended' END || ']  ' || $(_brief_txt "COALESCE($(_rep_json_txt "$(_rep_end_of payload e)" reason), 'running')" 24) || '  ·  ' || COALESCE($(_shift_json_int "$(_rep_end_of payload e)" tasks), 0) || ' task(s), ' || COALESCE($(_shift_json_int "$(_rep_end_of payload e)" minutes), 0) || ' min, ' || COALESCE($(_shift_json_int "$(_rep_end_of payload e)" steps), 0) || ' step(s)' || CASE WHEN COALESCE($(_rep_json_txt 'e.payload' requirement), '') = '' THEN '' ELSE '  ·  ' || $(_brief_txt "$(_rep_json_txt 'e.payload' requirement)" 32) END || CASE WHEN COALESCE($(_rep_json_txt "$(_rep_end_of payload e)" note), '') = '' THEN '' ELSE '  ·  ' || $(_brief_txt "$(_rep_json_txt "$(_rep_end_of payload e)" note)" 120) END"

    done_expr="'  ' || $(_brief_txt 'e.ts' 32) || '  ' || $(_brief_txt 't.id' 32) || '  ' || $(_brief_txt 't.title' 70) || '  ·  ' || $(_brief_txt "$(_render_task_who 't.id')" 40) || '  ·  ' || $(_brief_txt 't.requirement_id' 32)"

    fail_expr="'  ' || $(_brief_txt 'e.ts' 32) || '  ' || $(_brief_txt 'e.verb' 20) || '  ' || $(_brief_txt 'e.subject_id' 40) || CASE WHEN $(_rep_subject_label 'e.subject_type' 'e.subject_id') = '' THEN '' ELSE '  ' || $(_brief_txt "$(_rep_subject_label 'e.subject_type' 'e.subject_id')" 60) END || CASE WHEN COALESCE($(_rep_detail 'e.payload'), '') = '' THEN '' ELSE '  ·  ' || $(_brief_txt "$(_rep_detail 'e.payload')" 100) END"

    blk_expr="'  ' || $(_brief_txt 't.id' 32) || '  ' || $(_brief_txt 't.title' 70) || '  ·  ' || $(_brief_txt 't.requirement_id' 32) || '  ·  ' || $(_brief_txt "COALESCE((SELECT $(_rep_json_txt 'eb.payload' reason) FROM event eb WHERE eb.subject_type = 'task' AND eb.verb = 'blocked' AND eb.subject_id = t.id ORDER BY eb.ts DESC, eb.id DESC LIMIT 1), 'no reason recorded')" 60) || CASE WHEN $(_roster_req_caps 't.id') = '' THEN '' ELSE '  ·  needs ' || $(_brief_txt "$(_roster_req_caps 't.id')" 60) END"

    gate_expr="'  ' || $(_brief_txt 'n.id' 60) || '  [' || CASE WHEN $ready_n THEN 'ready' ELSE 'waiting' END || ']  ' || $(_brief_txt 'g.kind' 24) || '  ·  ' || $(_brief_txt 'g.status' 16) || '  ·  ' || $(_brief_txt 'g.prompt' 120)"

    bug_expr="'  ' || $(_brief_txt 'b.id' 32) || '  ' || $(_brief_txt 'b.severity' 16) || '  ' || $(_brief_txt 'b.status' 16) || '  ' || $(_brief_txt 'b.title' 80) || '  ·  found by ' || $(_brief_txt "COALESCE(NULLIF(b.found_by,''), 'unknown')" 40)"

    find_expr="'  ' || $(_brief_txt 'f.severity' 16) || '  ' || $(_brief_txt "COALESCE(NULLIF(f.reviewer,''), 'unknown')" 40) || '  on ' || $(_brief_txt 'f.task_id' 32) || '  ' || $(_brief_txt 'f.summary' 80) || CASE WHEN COALESCE(f.file,'') = '' THEN '' ELSE '  ·  ' || $(_brief_txt 'f.file' 60) || COALESCE(':' || f.line, '') END"

    git_expr="'  ' || $(_brief_txt 'e.ts' 32) || '  ' || $(_brief_txt 'e.verb' 20) || '  ' || $(_brief_txt 'e.subject_id' 32) || '  ·  ' || $(_brief_txt "$(_rep_git_detail 'e.verb' 'e.payload')" 100)"
  fi

  # ---- the counts -------------------------------------------------------------------
  #
  # `H key=<integer>` lines, IDENTICAL in both modes — every value is a COUNT or a bounded
  # integer, so there is nothing to escape and nothing to render differently. They do three
  # jobs at once: the human Summary block, the JSON `summary` object, and the "… and N more"
  # footer each capped section needs.
  #
  # The transport is `_brief_fact_select`, shared with `guild brief` and `guild dashboard`;
  # only the LIST is local, because the three commands ask different questions. THE HEREDOC
  # IS DATA, NOT SQL — every line becomes one `UNION ALL SELECT 'H key=' || (expr)` — so it
  # takes no comments of its own. Every key is fixed text from this file, never input.
  #
  # WHY `nodes_done` AND `tasks_done` ARE BOTH HERE, and are different numbers: the shift's
  # budget counts GRAPH NODES it moved (§8.4), and the board's unit of work a human
  # recognizes is a TICKET. Reporting only the first would answer a question nobody asked;
  # reporting only the second would not reconcile with `--max-tasks`.
  hsel="$(
    _brief_fact_select <<FACTS
shifts (SELECT COUNT(*) FROM event e WHERE e.subject_type = 'shift' AND e.verb = 'started' AND $win_evt)
shifts_ended (SELECT COUNT(*) FROM event e WHERE e.subject_type = 'shift' AND e.verb = 'ended' AND $win_evt)
shifts_open (SELECT COUNT(*) FROM event eo WHERE eo.subject_type = 'shift' AND eo.verb = 'started' AND NOT EXISTS (SELECT 1 FROM event ec WHERE ec.subject_type = 'shift' AND ec.verb = 'ended' AND ec.subject_id = eo.subject_id))
steps (SELECT COUNT(*) FROM event e WHERE e.subject_type = 'shift' AND e.verb = 'stepped' AND $win_evt)
nodes_done (SELECT COUNT(*) FROM (SELECT e.subject_id FROM event e WHERE e.subject_type = 'graph_node' AND e.verb = 'moved' AND $(_rep_json_txt 'e.payload' to) = 'done' AND $win_evt GROUP BY e.subject_id))
nodes_moved (SELECT COUNT(*) FROM (SELECT e.subject_id FROM event e WHERE e.subject_type = 'graph_node' AND e.verb = 'moved' AND $win_evt GROUP BY e.subject_id))
tasks_done (SELECT COUNT(*) FROM event e WHERE e.subject_type = 'task' AND e.verb = 'moved' AND $(_rep_json_txt 'e.payload' to) = 'done' AND $win_evt)
tasks_failed (SELECT COUNT(*) FROM event e WHERE e.subject_type = 'task' AND e.verb = 'moved' AND $(_rep_json_txt 'e.payload' to) = 'failed' AND $win_evt)
retried (SELECT COUNT(*) FROM event e WHERE e.subject_type = 'graph_node' AND e.verb = 'retried' AND $win_evt)
gave_up (SELECT COUNT(*) FROM event e WHERE e.subject_type = 'graph_node' AND e.verb = 'gave-up' AND $win_evt)
blocked_window (SELECT COUNT(*) FROM event e WHERE e.subject_type = 'task' AND e.verb = 'blocked' AND $win_evt)
blocked_now (SELECT COUNT(*) FROM task WHERE status = 'blocked')
gates_open (SELECT COUNT(*) FROM gate g JOIN graph_node n ON n.id = g.node_id WHERE n.status NOT IN ('done','skipped'))
gates_ready (SELECT COUNT(*) FROM gate g JOIN graph_node n ON n.id = g.node_id WHERE n.status NOT IN ('done','skipped') AND $ready_n)
gates_decided (SELECT COUNT(*) FROM event e WHERE e.subject_type = 'gate' AND e.verb IN ('approved','rejected') AND $win_evt)
bugs_filed (SELECT COUNT(*) FROM bug b WHERE ($since_expr) = '' OR b.created_at >= ($since_expr))
findings_filed (SELECT COUNT(*) FROM review_finding f WHERE ($since_expr) = '' OR f.created_at >= ($since_expr))
commits (SELECT COUNT(*) FROM event e WHERE e.verb = 'committed' AND $win_evt)
nothing_to_commit (SELECT COUNT(*) FROM event e WHERE e.verb = 'nothing-to-commit' AND $win_evt)
reverts (SELECT COUNT(*) FROM event e WHERE e.verb = 'reverted' AND $win_evt)
branches (SELECT COUNT(*) FROM event e WHERE e.verb = 'branched' AND $win_evt)
events_window (SELECT COUNT(*) FROM event e WHERE $win_evt)
FACTS
  )"

  # ---- the script -------------------------------------------------------------------
  #
  # Statement order IS section order. Every list is capped, because a report that prints
  # four hundred rows is not a report; the matching `H` count tells the reader how much it
  # is not showing.
  #
  # THE GATES SECTION IS THE ONE THAT IS NOT WINDOWED, and that is deliberate: a gate left
  # waiting three shifts ago is still waiting, and the whole point of §8.5 is that the
  # morning read surfaces the decisions. Everything else here is an event in the window.
  cat <<SQL
$meta_sql;

SELECT line FROM ($hsel) ORDER BY o;

SELECT 'A ' || $shift_expr
  FROM event e
 WHERE e.subject_type = 'shift' AND e.verb = 'started' AND $win_evt
 ORDER BY e.ts DESC, e.id DESC
 LIMIT 10;

SELECT 'B ' || $done_expr
  FROM event e JOIN task t ON t.id = e.subject_id
 WHERE e.subject_type = 'task' AND e.verb = 'moved'
   AND $(_rep_json_txt 'e.payload' to) = 'done'
   AND $win_evt
 ORDER BY e.ts, e.id
 LIMIT 25;

SELECT 'C ' || $fail_expr
  FROM event e
 WHERE $win_evt
   AND ( (e.subject_type = 'graph_node' AND e.verb IN ('retried','gave-up'))
      OR (e.subject_type = 'task' AND e.verb = 'moved'
          AND $(_rep_json_txt 'e.payload' to) = 'failed') )
 ORDER BY e.ts, e.id
 LIMIT 25;

SELECT 'D ' || $blk_expr
  FROM task t
 WHERE t.status = 'blocked'
 ORDER BY t.id
 LIMIT 20;

SELECT 'E ' || $gate_expr
  FROM gate g
  JOIN graph_node n ON n.id = g.node_id
  JOIN requirement r ON r.id = n.requirement_id
 WHERE n.status NOT IN ('done','skipped')
 ORDER BY (CASE WHEN $ready_n THEN 0 ELSE 1 END), r.priority, n.id
 LIMIT 20;

SELECT 'F ' || $bug_expr
  FROM bug b
 WHERE ($since_expr) = '' OR b.created_at >= ($since_expr)
 ORDER BY $(_brief_severity_rank 'b.severity'), b.id
 LIMIT 20;

SELECT 'K ' || $find_expr
  FROM review_finding f
 WHERE ($since_expr) = '' OR f.created_at >= ($since_expr)
 ORDER BY $(_brief_severity_rank 'f.severity'), f.id
 LIMIT 20;

SELECT 'G ' || $git_expr
  FROM event e
 WHERE e.verb IN ('branched','committed','nothing-to-commit','reverted')
   AND $win_evt
 ORDER BY e.ts, e.id
 LIMIT 25;
SQL
}

# ---- the human renderer ---------------------------------------------------------------

# _rep_text <rows-file> — fold the tagged rows into the report.
#
# A row is `<TAG> <text>` and — because every free-text expression was flattened in the
# engine — a row is ALWAYS exactly one line. So the tag can only have been written by the
# SQL, never by a gate prompt. Anything untagged is driver noise and is DROPPED rather than
# folded onto the previous row: folding is how the injection used to land, and with
# flattening there is no legitimate continuation line.
#
# THE STOP REASON IS THE HEADLINE. §8.5 asks the report to say why the shift stopped, and
# the gloss for each reason is a FIXED literal in this program keyed by a word from
# `_shift_reasons` — the closed vocabulary lib/shift.sh defines and lib/shift.sh's own CASE
# produces. An unrecognized reason prints bare rather than being decorated with a sentence
# that might not be true of it.
_rep_text() {
  LC_ALL=C awk '
    /^[A-Z] / {
      tag = substr($0, 1, 1)
      txt = substr($0, 3)
      # `M` and `H` are both `key=value`, ONE PER LINE. The key is everything before the
      # FIRST `=`; the value is the whole remainder, so a value containing `=` or spaces is
      # kept intact and cannot reach a second key.
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

    # emit — a section prints only when it has rows. An absent section is good news stated
    # by its absence; eight "(none)" blocks are a wall, not a report.
    function emit(head, tag, total,   i, shown) {
      shown = n[tag] + 0
      if (shown == 0) return
      print ""
      print head
      for (i = 1; i <= shown; i++) print buf[tag, i]
      if (total + 0 > shown) printf "  … and %d more\n", total - shown
    }

    # gloss — why the shift stopped, in one sentence. Fixed literals, keyed by the closed
    # vocabulary; the empty string for anything else, and the caller prints the bare word.
    function gloss(r) {
      if (r == "gate")           return "a decision is waiting on you; this is the shift succeeding"
      if (r == "infrastructure") return "the loop stopped progressing: two steps in a row moved no node"
      if (r == "max-tasks")      return "the task ceiling you set, not a fault"
      if (r == "max-minutes")    return "the time ceiling you set, not a fault"
      if (r == "idle")           return "nothing was runnable and no gate was waiting"
      if (r == "collision")      return "two parallel slices wrote the same file; the tree was left exactly as it is"
      if (r == "operator")       return "you ended it"
      return ""
    }

    END {
      print "Shift Report"
      print "============"
      print ""

      src   = metaval("source")
      since = metaval("since")
      state = metaval("state")
      sid   = metaval("shift")
      reason = metaval("reason")
      note   = metaval("note")
      scope  = metaval("scope")

      printf "Generated: %s\n", metaval("now")
      if (src == "arg")        printf "Window:    since %s (--since)\n", since
      else if (src == "shift") printf "Window:    since %s (the last shift began)\n", since
      else                     print  "Window:    no shift has ever run here"

      # No shift has run: say so and say how to start one, rather than printing eight empty
      # sections under a header that implies something happened.
      if (state == "none") {
        print ""
        print "No shift has been worked on this board."
        print ""
        print "  · Start one with the guild:shift skill, or run `guild shift` directly."
        print "  · `guild shift --policy` is what a shift may and may not do, in full."
        print "  · `guild shift --dry-run` shows what one would pick up, writing nothing."
        exit 0
      }

      printf "Shift:     %s", sid
      if (scope != "") printf " (scoped to %s)", scope
      print ""

      if (state == "open") {
        printf "Stopped:   still running — %d step(s) so far\n", num("steps")
      } else {
        printf "Stopped:   %s", (reason == "" ? "ended, reason not recorded" : reason)
        g = gloss(reason)
        if (g != "") printf " — %s", g
        print ""
        if (note != "") printf "Note:      %s\n", note
      }

      printf "Worked:    %d shift(s) · %d node(s) done · %d ticket(s) done · %d step(s)\n",
             num("shifts"), num("nodes_done"), num("tasks_done"), num("steps")
      printf "Trouble:   %d failed · %d retried · %d given up on · %d blocked\n",
             num("tasks_failed"), num("retried"), num("gave_up"), num("blocked_window")
      printf "Waiting:   %d gate(s) open", num("gates_open")
      if (num("gates_ready") > 0) printf " (%d ready for your decision)", num("gates_ready")
      printf " · %d bug(s) filed · %d finding(s) filed\n", num("bugs_filed"), num("findings_filed")
      if (num("commits") + num("reverts") + num("branches") + num("nothing_to_commit") > 0)
        printf "Tree:      %d commit(s) · %d revert(s) · %d branch(es) · %d task(s) wrote no code\n",
               num("commits"), num("reverts"), num("branches"), num("nothing_to_commit")

      emit("Shifts:", "A", num("shifts"))
      emit("Completed:", "B", num("tasks_done"))
      emit("Failed and Retried:", "C", num("tasks_failed") + num("retried") + num("gave_up"))
      emit("Blocked:", "D", num("blocked_now"))
      emit("Gates Waiting:", "E", num("gates_open"))
      emit("Bugs Filed:", "F", num("bugs_filed"))
      emit("Findings Filed:", "K", num("findings_filed"))
      emit("Git:", "G", num("commits") + num("reverts") + num("branches") + num("nothing_to_commit"))

      # ---- what to do about it --------------------------------------------------------
      #
      # The report ends by handing back the decision, because a gate is the one thing a
      # shift can never do for you (design 6.4, 8.2). The node id is a flattened, clipped
      # value from the meta channel — the same gate `guild gates` and `guild shift` name.
      gnode = metaval("gate")
      gkind = metaval("gate_kind")
      print ""
      if (gnode != "" && metaval("gate_ready") == "1") {
        print "The decision waiting on you:"
        if (gkind == "select-findings")
          printf "  guild gate %s --approve --decision '\''F-12,F-14'\''   (or --decision none)\n", gnode
        else
          printf "  guild gate %s --approve\n", gnode
        printf "  guild gate %s --reject --decision '\''why'\''\n", gnode
        print ""
      } else if (gnode != "") {
        printf "Next gate %s is not ready — the guild is still working behind it.\n\n", gnode
      }
      print "  guild brief                  where the project stands now"
      print "  guild gates --pending        every decision waiting on you"
      print "  guild git shift-status       what the shift did to the working tree"
    }
  ' "$1"
}

# ---- the JSON renderer -----------------------------------------------------------------

# _rep_json <rows-file> — the same rows as one JSON document.
#
# Every value was escaped by the engine's json_object(), so awk only assembles arrays and
# never touches a value — `_brief_json`'s division of labour exactly. The `summary` object is
# built from the `H` counts, whose values are validated as digit strings before they are
# emitted unquoted: they are COUNT() results, so this can only ever pass, and it means no
# path exists by which a non-number reaches a JSON number position.
_rep_json() {
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
      arr("shifts",    "A")
      arr("completed", "B")
      arr("failed",    "C")
      arr("blocked",   "D")
      arr("gates",     "E")
      arr("bugs",      "F")
      arr("findings",  "K")
      # last array: no trailing comma
      if (n["G"] + 0 == 0) {
        print "  \"git\": []"
      } else {
        print "  \"git\": ["
        for (i = 1; i <= n["G"]; i++)
          printf "    %s%s\n", row["G", i], (i < n["G"] ? "," : "")
        print "  ]"
      }
      print "}"
    }
  ' "$1"
}

# ---- the command -------------------------------------------------------------------

# cmd_shift_report [--since DATE] [--json] — design §8.5, the "what happened while I was
# away" surface.
#
#   guild shift-report              the human read
#   guild shift-report --json       the same facts for a notifier or a skill
#   guild shift-report --since 2026-08-01   override the window
#
# ONE db_exec. Reads only — nothing here writes a row, a journal line or an event.
cmd_shift_report() {
  local mode="text" since="" nl nowlit sincelit rows sqlf
  nl=$'\n'

  while [ $# -gt 0 ]; do
    case "$1" in
      --json) mode="json" ;;
      --since)
        shift
        [ $# -gt 0 ] ||
          die "guild: shift-report --since needs a date (e.g. --since 2026-08-01)"
        since="$1"
        ;;
      --since=*) since="${1#--since=}" ;;
      -*)
        die "guild: unknown option '$1' for shift-report.

  guild shift-report [--since YYYY-MM-DD] [--json]

With no --since the window opens where the LAST SHIFT began, which is the question this
command exists to answer. For where the project stands right now, that is 'guild brief'."
        ;;
      *)
        die "guild: shift-report takes no positional arguments (got '$(_render_flat_arg "$1")')"
        ;;
    esac
    shift
  done

  # The cutoff is compared against stored timestamps AS A STRING — ISO-8601 sorts
  # lexicographically, which is why `2026-08-01` correctly admits `2026-08-01T09:14:00Z`.
  # That also means a value that is not a date fails SILENTLY AND WRONGLY: `--since
  # yesterday` sorts above every timestamp this century, so every section reports nothing
  # and the report looks like a quiet night. So the shape is checked rather than trusted.
  #
  # A date PREFIX is all that is required, so a full timestamp is accepted unchanged. The
  # resolved window is printed in the header either way, so what was actually used is
  # always visible. `guild brief` checks its own `--since` the same way, in the same words.
  case "$since" in
    "") ;;
    *"$nl"*) die "guild: shift-report --since must be a single line" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) ;;
    *) die "guild: shift-report --since must start with a YYYY-MM-DD date (got '$(_render_flat_arg "$since")')" ;;
  esac

  db_require_init

  nowlit="$(sql_str "$(db_now)")"
  sincelit="$(sql_text "$since" '--since')"

  rows="$(_render_tmp shift-report)"
  sqlf="$(_render_tmp shift-report-sql)"
  _rep_sql "$mode" "$nowlit" "$sincelit" >"$sqlf"
  _render_query "$sqlf" "$rows" "guild: could not read the shift report from the database"

  if [ "$mode" = json ]; then
    _rep_json "$rows"
  else
    _rep_text "$rows"
  fi
  rm -f "$rows"
}
