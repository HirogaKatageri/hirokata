# shellcheck shell=bash
#
# lib/direction.sh — guild v5 Stage 2: DIRECTION, the layer above requirements
# (design doc §3.1 "the hierarchy", §3.2 DDL, §4 "New").
#
#   goal ──< phase ──< requirement ──< plan ──< plan_slice
#
# A `goal` is long-lived intent with a priority. A `phase` is an ordered stage of one
# goal. A `requirement` MAY belong to a phase — `requirement.phase_id` is NULLABLE BY
# DESIGN and unaffiliated work is legal, so nothing here ever requires a phase, and
# `guild req assign <REQ> none` puts a requirement back to unaffiliated. Both tables
# already exist in schema.sql; Stage 2 adds commands and presentation over them, never
# a migration.
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` (scripts/guild owns those).
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no ${var^^}.
#
# Depends on lib/db.sh      : die, db_fail, db_require_init, db_exec, db_query, db_now,
#                             sql_str, sql_text
#          on lib/journal.sh: journal_preflight, journal_append
#          on lib/artifacts.sh: _art_actor, _art_created_expr, _art_defuse_body,
#                             _art_defuse_lines, _art_create_run, _art_update_run,
#                             _art_json_row, _art_tmpfile, _art_first_line
#          on lib/render.sh : _render_flat, _render_flat_arg, _render_col,
#                             _render_linecount, _render_nl, _render_tmp, _render_query
#
# WHAT IS DELIBERATELY REUSED, AND WHY (the "do not invent a second scheme" rule):
#
#   * IDs are derived in SQL inside the insert, via RETURNING — `_dir_next_id_expr` is
#     `_art_next_id_expr` with a second prefix table, not a second scheme. `guild goal
#     new` and `guild phase new` therefore have no read-then-write race, exactly like
#     `guild new req`.
#   * The create scripts have the shape lib/artifacts.sh established — INSERT … SELECT
#     … FROM <the rows that must exist>, RETURNING an `OK|id|row` marker, plus `MISS|…`
#     diagnostic SELECTs — and are parsed by `_art_create_run` itself. A `phase new`
#     naming a goal that does not exist selects zero rows, so nothing is inserted and
#     the MISS line says which reference was missing.
#   * The `created` event uses `_dir_created_event_sql`, which carries over BOTH of
#     `_art_created_event_sql`'s guards (same-timestamp AND not-already-announced), so
#     a failed create cannot stamp an event on the previous row.
#   * Free text is flattened with lib/render.sh's `_render_flat` / `_render_col` and
#     never with a local regex. See "the output-channel rule" below.
#
# HARD RULES honored throughout:
#
#   * `sql_text` for ALL free text (titles, bodies, and every ID/status/date that
#     arrives as unvalidated argv); `sql_str` only for values from a known-safe
#     alphabet — here that is the timestamp this file generated and a status already
#     checked against `_dir_statuses`. `--priority` and `--ordinal` are validated to
#     digits and emitted BARE, because they land in INTEGER columns of STRICT tables.
#   * ONE `db_exec` per logical command. Every command below composes a single SQL
#     script and runs it once; there is no loop of db_exec calls anywhere in this file.
#   * Every mutation calls `journal_preflight` BEFORE its SQL, writes an `event` row in
#     the same script, and `journal_append`s the resulting row afterwards. `guild brief`
#     and the dashboard activity feed read `event`; a mutation with no event is
#     invisible to both.
#   * No FTS5, no WITH RECURSIVE, no generated columns, no lag/lead/ntile/percent_rank/
#     cume_dist. `goal show` walks goal → phase → requirement, which is two DIRECT
#     joins, not a traversal — the hierarchy is fixed-depth, so recursion is never
#     needed here.
#   * No quadratic string handling: nothing in this file applies `${v%%pat*}` or
#     `${v##*pat}` to a value that can be a whole document. The one place a marker line
#     is split (`_art_update_run`) strips a FIXED literal prefix, which is a constant
#     comparison, and the flattening of a title for echo goes through `tr`.
#
# THE OUTPUT-CHANNEL RULE (§2.2.2), as it applies to this module. Every surface here is
# line-oriented, and a goal title, a phase title or a goal body is free text that can
# contain newlines and pipes. So:
#
#   * `goal new` / `phase new` echo `<ID> <title>`: the title is the TAIL of the line
#     and is flattened before it is printed, so it cannot become a second line. The
#     stored column is untouched and byte-exact.
#   * `goal list` / `phase list` are awk-filterable COLUMN surfaces, so every column
#     before the last goes through `_render_col` (blanks become `_`, fixed field count)
#     and only the trailing title — which no filter indexes — is merely flattened.
#     That is `guild list`'s discipline, unchanged.
#   * `goal show` is a DOCUMENT, and a document has to carry a body verbatim. It is
#     transported exactly the way `guild export` transports requirement bodies: each
#     chunk is preceded by a `@@GUILD-GOAL@@ <line-count>` header and the reader
#     consumes that many lines BY COUNT, never inspecting them. A body line therefore
#     cannot be read as a header no matter what it says.
#   * The rendered document adds a second layer, because a human (and `guild:brief`)
#     reads the text rather than the transport: every structural line `goal show`
#     generates has its free text flattened, the goal body is the ONLY verbatim region
#     and it sits ABOVE the `## Phases` heading, and `## Phases` is defused out of goal
#     bodies at creation (`_dir_defuse_body`). So everything below the `## Phases`
#     anchor was written by this file, and the anchor itself cannot be forged.

# ---- kind configuration ------------------------------------------------------------
#
# lib/artifacts.sh maps req|task|plan to a table; this is the same mapping for the two
# direction kinds. They are NOT added to art_table(): `guild move GOAL-001 done` would
# then dispatch into cmd_move, whose error text ("allowed: todo in-progress done") and
# whose v4-parity status sets are pinned by the harness. Direction gets its own verbs —
# `guild goal move`, `guild phase move` — exactly as the Stage 2 scope lists them.

# _dir_table <kind> — goal|phase (upper or lower) -> table name.
_dir_table() {
  case "${1-}" in
    goal | GOAL) printf 'goal\n' ;;
    phase | PHASE) printf 'phase\n' ;;
    *) die "guild: unknown direction kind '${1-}'" ;;
  esac
}

# _dir_prefix <kind> — kind -> ID prefix.
_dir_prefix() {
  case "${1-}" in
    goal | GOAL) printf 'GOAL\n' ;;
    phase | PHASE) printf 'PHASE\n' ;;
    *) die "guild: unknown direction kind '${1-}'" ;;
  esac
}

# _dir_num_offset <kind> — 1-based substr() offset of the numeric part of an ID.
# 'GOAL-001' -> 6, 'PHASE-001' -> 7.
_dir_num_offset() {
  case "${1-}" in
    goal | GOAL) printf '6\n' ;;
    phase | PHASE) printf '7\n' ;;
    *) die "guild: unknown direction kind '${1-}'" ;;
  esac
}

# _dir_statuses <kind> — space-separated valid statuses.
#
# The requirement/plan set, verbatim: todo | in-progress | done. Deliberately not
# widened — `blocked`, `waived` and an "abandoned" goal all belong to later stages
# (§6.4 gates, §13), and a status this CLI can write but nothing renders is worse than
# no status at all. The board, `goal list` and `goal show` all print these three.
_dir_statuses() {
  case "${1-}" in
    goal | GOAL | phase | PHASE) printf 'todo in-progress done\n' ;;
    *) die "guild: unknown direction kind '${1-}'" ;;
  esac
}

# _dir_kind_of_id <ID> — 'PHASE-003' -> phase.
_dir_kind_of_id() {
  case "${1-}" in
    GOAL-*) printf 'goal\n' ;;
    PHASE-*) printf 'phase\n' ;;
    *) die "guild: unrecognized direction id '${1-}'" ;;
  esac
}

# THERE IS NO `_dir_json_row`. `goal` and `phase` are two more cases of `_art_json_row`
# (lib/artifacts.sh), which is the ONE registry of "what does a journal line for table X
# contain". The journal records resulting ROW STATE and `guild rebuild` re-inserts every
# column, so a projection that goes stale silently drops a column on replay — and a
# second registry is exactly how one goes stale while the other does not. json_object
# preserves types, which the STRICT tables demand: priority and ordinal must replay as
# JSON numbers, not strings.

# _dir_next_id_expr <kind> — SQL producing the next 'PREFIX-NNN' (§3.3).
# Used INSIDE the insert, so the derivation and the write are one statement.
_dir_next_id_expr() {
  local kind="${1-}" table prefix off
  table="$(_dir_table "$kind")" || exit 1
  prefix="$(_dir_prefix "$kind")"
  off="$(_dir_num_offset "$kind")" || exit 1
  printf "'%s-' || printf('%%03d', COALESCE((SELECT MAX(CAST(substr(id,%s) AS INTEGER)) FROM %s),0) + 1)" \
    "$prefix" "$off" "$table"
}

# _dir_created_event_sql <kind> <now-literal> <actor-literal> — the `created` event for
# a row inserted EARLIER IN THE SAME SCRIPT.
#
# Carried over from `_art_created_event_sql` with both of its guards, which are not
# optional. The script is composed before the ID exists, so the event finds the row
# instead of naming it: run right after the insert, the highest ID of that kind IS the
# row just written. `updated_at = <this invocation's now>` alone is not enough, because
# db_now has second resolution and a scripted burst puts several rows in one second; the
# second guard — no `created` event for that id yet — is exact, since a genuinely new ID
# cannot already have been announced. A create that inserted nothing (a bad `--goal`)
# therefore finds its predecessor already announced and writes no event.
_dir_created_event_sql() {
  local kind="${1-}" nowlit="${2-}" actorlit="${3-}" table prefix off tablit
  table="$(_dir_table "$kind")" || exit 1
  prefix="$(_dir_prefix "$kind")"
  off="$(_dir_num_offset "$kind")" || exit 1
  tablit="$(sql_str "$table")"
  printf "INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT %s, %s, 'created', %s, id, '{}'
FROM %s
WHERE id = (SELECT '%s-' || printf('%%03d', MAX(CAST(substr(id,%s) AS INTEGER))) FROM %s)
  AND updated_at = %s
  AND NOT EXISTS (SELECT 1 FROM event e
                   WHERE e.verb = 'created'
                     AND e.subject_type = %s
                     AND e.subject_id = %s.id);
" "$nowlit" "$actorlit" "$tablit" "$table" "$prefix" "$off" "$table" "$nowlit" "$tablit" "$table"
}

# ---- flag parsing ------------------------------------------------------------------

# _dir_parse_flags <args...> — the direction flag set.
#
# Sets dir_title dir_body dir_date dir_priority dir_goal dir_ordinal, always resetting
# them first so a second call cannot inherit the first one's values. Unknown `--flags`
# consume their value and are ignored, and bare words are skipped — the behaviour
# `_art_parse_flags` established, kept identical so the two parsers cannot surprise a
# caller differently.
#
# A SEPARATE PARSER, not a call into `_art_parse_flags`: that one silently swallows any
# flag it does not know, so `--priority 1` would have been consumed and dropped and the
# goal would have been created at the default priority with no error at all.
_dir_parse_flags() {
  dir_title=""
  dir_body=""
  dir_date=""
  dir_priority=""
  dir_goal=""
  dir_ordinal=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --title) shift; dir_title="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --body) shift; dir_body="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --date) shift; dir_date="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --priority) shift; dir_priority="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --goal) shift; dir_goal="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --ordinal) shift; dir_ordinal="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --*) shift; if [ $# -gt 0 ]; then shift; fi ;;
      *) shift ;;
    esac
  done
}

# _dir_require_priority <value> — echo a validated 1..5, or die.
#
# The schema comments the column as "1 highest .. 5 lowest" and `guild goal priority`
# is documented as taking 1-5, so the range is checked here rather than stored and
# rendered as nonsense later. Validated to a SINGLE CHARACTER from a five-element set,
# which is why the caller may emit it bare into the INTEGER column of a STRICT table.
_dir_require_priority() {
  case "${1-}" in
    [1-5]) printf '%s\n' "$1" ;;
    *) die "guild: priority must be 1-5 (1 highest, 5 lowest), got '${1-}'" ;;
  esac
}

# _dir_require_ordinal <value> — echo a validated ordinal, or die.
#
# Digits only, at most nine of them: `phase.ordinal` is an INTEGER column and the value
# is emitted BARE, so it must be a number and it must not be able to overflow into a
# float on either engine. A leading zero is accepted and normalized by the engine
# ('007' -> 7); an empty value is the caller's signal to derive the next one instead.
_dir_require_ordinal() {
  case "${1-}" in
    '' | *[!0-9]*) die "guild: --ordinal must be a whole number, got '${1-}'" ;;
  esac
  case "${#1}" in
    1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9) printf '%s\n' "$1" ;;
    *) die "guild: --ordinal is too large: '${1}'" ;;
  esac
}

# THERE IS NO `_dir_flat_text`. The shell-side twin of `_render_flat` — used here for
# exactly one thing, the title `goal new` / `phase new` echo back — is `_render_flat_arg`,
# which lives in lib/render.sh beside the SQL-side flattener it mirrors. This module and
# lib/records.sh each grew a private, byte-identical copy of it under a different name;
# they now share the one. The stored column is still never touched, and `guild goal show`
# re-flattens in SQL, so this remains presentation and not a second escaping scheme.

# _dir_defuse_body <text> — neutralize the ONE line `guild goal show` generates that a
# goal body could otherwise forge.
#
# `_art_defuse_body` is called first and does the shared work (`---`, `## Work Log`,
# `## Follow-up Tasks`); this adds `## Phases`, which is `goal show`'s anchor: every
# line below it in that document is generated by this file, so a body able to plant a
# second one could append arbitrary phases and requirements to what a reader — human or
# `guild:brief` — takes for board state.
#
# Indented, not refused. A direction document with a `## Phases` section of its own is
# ORDINARY, not adversarial, so refusing would reject good input; and CommonMark still
# reads `  ## Phases` as a heading (up to three leading spaces are insignificant) while
# an `^## ` parser no longer matches it. That is the same two spaces, and the same
# trade, `_art_defuse_body` already makes.
#
# The indenting loop itself is `_art_defuse_lines` (lib/artifacts.sh), not a copy of it.
# This is the ONE mechanism handed a second heading list, which is exactly the shape that
# helper takes; see its comment for the bash 3.2 rescanning subtlety it has to handle.
_dir_defuse_body() {
  _art_defuse_lines "$(_art_defuse_body "${1-}")" '## Phases'
}

# THERE IS NO `_dir_update_row`. The mutating commands here (goal move, goal priority,
# phase move, req assign) all speak the `OK|<row-json>` / `MISS|<ref>` / nothing protocol,
# and its runner is `_art_update_run` (lib/artifacts.sh) — beside `_art_create_run`, whose
# create half of the same protocol they already use. lib/records.sh arrived with a second
# parser for it, disagreeing about whether the marker carries the id; there is now one.

# ---- goal: create ------------------------------------------------------------------

# cmd_goal_new --title T [--body B] [--priority 1-5] [--date YYYY-MM-DD]
#
# Prints "<ID> <title>" — the id first so `cut -d' ' -f1` or `${out%% *}` on a short
# line gets it, the flattened title after it so a caller creating several goals in a
# script can read back what it made without a second round trip. The title is the tail
# of the line and has been flattened, so the output is ALWAYS exactly one line.
cmd_goal_new() {
  local now nowlit actorlit created idexpr rowexpr body prio sql result id row
  _dir_parse_flags "$@"
  [ -n "$dir_title" ] || die "guild: goal new requires --title"
  prio=3
  [ -z "$dir_priority" ] || prio="$(_dir_require_priority "$dir_priority")" || exit 1
  db_require_init
  journal_preflight

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  created="$(_art_created_expr "$dir_date" "$nowlit")"
  idexpr="$(_dir_next_id_expr goal)" || exit 1
  rowexpr="$(_art_json_row goal)"

  # A goal has no template: unlike a requirement it is a statement of intent, and there
  # is no product-owner section list to prefill. An empty body is normal and `goal show`
  # simply omits the region. What IS done to it is the defusing above, because the body
  # is the one verbatim region of `goal show`.
  body=""
  [ -z "$dir_body" ] || body="$(_dir_defuse_body "$dir_body")"

  sql="BEGIN;
INSERT INTO goal (id, title, body, status, priority, created_at, updated_at)
SELECT $idexpr, $(sql_text "$dir_title" '--title'), $(sql_text "$body" '--body'), 'todo', $prio, $created, $nowlit
RETURNING 'OK|' || id || '|' || $rowexpr;
$(_dir_created_event_sql goal "$nowlit" "$actorlit")
COMMIT;
"

  result="$(_art_create_run 'the goal' "$sql")" || exit 1
  id="${result%% *}"
  row="${result#* }"
  journal_append goal upsert "$row"
  printf '%s %s\n' "$id" "$(_render_flat_arg "$dir_title")"
}

# ---- goal: read --------------------------------------------------------------------

# cmd_goal_list [status]
#
#   <GOAL-ID> <status> <priority> <phases-done>/<phases-total> <title>
#   GOAL-001 in-progress 2 1/3 Ship the visibility stage
#
# Ordered by priority then id, because that is the order the guild should pick work up
# in. Prints nothing when nothing matches, exactly as `guild list` does.
#
# THE COLUMN CONTRACT, which is `guild list`'s (§2.2.2) and not a new one: every field
# except the last goes through `_render_col`, so it holds no blank at all and the field
# count is FIXED — `awk '$2 == "in-progress"'` cannot be shifted by a status or an id
# replayed from the journal. The title is last, is indexed by no filter, and is merely
# flattened, so it keeps its spaces and stays readable. Counting on the untrusted side:
# a caller wanting the title takes `$5` through end of line, never `$5` alone.
cmd_goal_list() {
  local filter="${1-}" cols where
  [ $# -le 1 ] || die "guild: goal list takes at most one status"
  db_require_init

  cols="$(_render_col 'g.id') || ' ' || $(_render_col 'g.status') || ' ' || g.priority || ' '"
  cols="$cols || (SELECT COUNT(*) FROM phase p WHERE p.goal_id = g.id AND p.status = 'done')"
  cols="$cols || '/' || (SELECT COUNT(*) FROM phase p WHERE p.goal_id = g.id)"
  cols="$cols || ' ' || $(_render_flat 'g.title')"

  where=""
  # Not validated, for `cmd_list`'s reason: v4 accepted any word as a status filter and
  # simply matched nothing. Unvalidated argv is free text (§2.2.1).
  [ -z "$filter" ] || where=" WHERE g.status = $(sql_text "$filter" 'the status filter')"

  printf 'SELECT %s FROM goal g%s ORDER BY g.priority, g.id;\n' "$cols" "$where" | db_query
}

# _dir_goal_show_sql <goal-id-literal> — the one query behind `guild goal show`.
#
# Chunks, in document order, each transported with a `@@GUILD-GOAL@@ <line-count>`
# header the reader consumes by count — `_export_sql`'s mechanism, unchanged, because
# the goal BODY has to arrive verbatim and a verbatim value on a line-oriented channel
# is exactly what that mechanism exists for.
#
#   sec 1  the goal: heading, fields, and the body
#   sec 2  the '## Phases' anchor (ALWAYS emitted, even for a goal with no phases, so
#          that a reader can rely on it being there)
#   sec 3  one chunk per phase (subsec 0), then one per requirement of that phase
#          (subsec 1), or a placeholder when the phase has none
#   sec 4  the 'no phases yet' placeholder
#
# Every chunk opens with a newline — that is what produces the blank line before it —
# EXCEPT the requirement bullets, which nest directly under the phase's
# `- **Requirements:**` field and would otherwise be double-spaced.
#
# ORDERING IS EXPLICIT, never the database's return order: `sec`, then `sub` — a phase's
# zero-padded ordinal followed by its id, so phases appear in the order the goal intends
# and ties break deterministically — then `subsec`, then the requirement id. `sub` is a
# sort key only and is never printed.
#
# Two DIRECT joins (requirement -> phase -> goal), no recursion (§3.0): the hierarchy is
# fixed-depth, so the recursive CTE this shape invites is not needed and would not run.
#
# Every free-text column that lands on a GENERATED line is wrapped in `_render_flat`,
# ids included — ids are generated by this CLI today, but `guild rebuild` replays them
# from a file that lives in git, and a structural line must not depend on who wrote that
# file. The goal body is the one exception and the one thing the length-prefix protects.
_dir_goal_show_sql() {
  local g="${1-}" nl len
  nl="$(_render_nl)"
  len="$(_render_linecount "COALESCE(txt,'')")"

  cat <<SQL
WITH parts AS (
  SELECT 1 AS sec, '' AS sub, 0 AS subsec, '' AS ord,
         '# ' || $(_render_flat 'g.id') || ' — ' || $(_render_flat 'g.title')
         || $nl || $nl || '- **Status:** ' || $(_render_flat 'g.status')
         || $nl || '- **Priority:** ' || g.priority
         || $nl || '- **Created:** ' || $(_render_flat 'g.created_at')
         || $nl || '- **Updated:** ' || $(_render_flat 'g.updated_at')
         || $nl || '- **Phases:** '
            || (SELECT COUNT(*) FROM phase p WHERE p.goal_id = g.id AND p.status = 'done')
            || '/' || (SELECT COUNT(*) FROM phase p WHERE p.goal_id = g.id) || ' done'
         || $nl || '- **Requirements:** '
            || (SELECT COUNT(*) FROM requirement r JOIN phase p ON p.id = r.phase_id
                 WHERE p.goal_id = g.id AND r.status = 'done')
            || '/' || (SELECT COUNT(*) FROM requirement r JOIN phase p ON p.id = r.phase_id
                        WHERE p.goal_id = g.id) || ' done'
         || CASE WHEN g.body = '' THEN '' ELSE $nl || $nl || g.body END AS txt
    FROM goal g WHERE g.id = $g

  UNION ALL
  SELECT 2, '', 0, '', $nl || '## Phases'
    FROM goal g WHERE g.id = $g

  UNION ALL
  SELECT 3, printf('%012d', p.ordinal) || ' ' || p.id, 0, '',
         $nl || '### ' || $(_render_flat 'p.id') || ' — ' || $(_render_flat 'p.title')
         || ' (ordinal ' || p.ordinal || ')'
         || $nl || $nl || '- **Status:** ' || $(_render_flat 'p.status')
         || $nl || '- **Requirements:** '
            || (SELECT COUNT(*) FROM requirement r WHERE r.phase_id = p.id AND r.status = 'done')
            || '/' || (SELECT COUNT(*) FROM requirement r WHERE r.phase_id = p.id) || ' done'
    FROM phase p WHERE p.goal_id = $g

  UNION ALL
  SELECT 3, printf('%012d', p.ordinal) || ' ' || p.id, 1, r.id,
         '  - ' || $(_render_flat 'r.id') || ' — ' || $(_render_flat 'r.title')
         || ' [' || $(_render_flat 'r.status') || ']'
    FROM requirement r JOIN phase p ON p.id = r.phase_id
   WHERE p.goal_id = $g

  UNION ALL
  SELECT 3, printf('%012d', p.ordinal) || ' ' || p.id, 1, '',
         '  - _no requirements yet_'
    FROM phase p
   WHERE p.goal_id = $g
     AND NOT EXISTS (SELECT 1 FROM requirement r WHERE r.phase_id = p.id)

  UNION ALL
  SELECT 4, '', 0, '', $nl || '_No phases yet._'
    FROM goal g
   WHERE g.id = $g
     AND NOT EXISTS (SELECT 1 FROM phase p WHERE p.goal_id = g.id)
)
SELECT '@@GUILD-GOAL@@ ' || $len || $nl || COALESCE(txt, '')
  FROM parts
 ORDER BY sec, sub, subsec, ord;
SQL
}

# cmd_goal_show <GOAL-ID> — the goal, its phases, and their requirements.
#
# The rendered shape, which is a contract: `guild:brief` parses it and a human reads it.
#
#   # GOAL-001 — Ship the visibility stage
#
#   - **Status:** in-progress
#   - **Priority:** 2
#   - **Created:** 2026-08-14T09:00:00Z
#   - **Updated:** 2026-08-14T09:12:44Z
#   - **Phases:** 1/2 done
#   - **Requirements:** 2/3 done
#
#   <the goal body, verbatim, when it is not empty>
#
#   ## Phases
#
#   ### PHASE-001 — Foundations (ordinal 1)
#
#   - **Status:** done
#   - **Requirements:** 2/2 done
#     - REQ-001 — Turso-backed CLI [done]
#     - REQ-002 — The journal [done]
#
#   ### PHASE-002 — Visibility (ordinal 2)
#
#   - **Status:** in-progress
#   - **Requirements:** 0/1 done
#     - REQ-003 — The dashboard [todo]
#
# Requirements with no phase do not appear: they belong to no goal, which is legal and
# is what `guild board` and `guild list req` are for.
#
# WHY THE BODY IS ABOVE `## Phases` AND NOT BELOW. The body is the only region of this
# document that is not generated, so it is the only region a title, a heading or a
# bullet can be forged in. Placing it above the anchor means a reader that finds the
# structure by locating `## Phases` — which `_dir_defuse_body` has already made
# unforgeable from inside a body — reads nothing but generated lines afterwards. The
# transport is safe on its own (lines are consumed by count), but the RENDERED document
# has readers that never see the transport.
cmd_goal_show() {
  local id="${1-}" rows sqlf rc
  [ -n "$id" ] || die "guild: goal show requires a GOAL-ID"
  [ $# -le 1 ] || die "guild: goal show takes one GOAL-ID"
  case "$id" in
    GOAL-*) ;;
    *) die "guild: unrecognized direction id '$id' (expected GOAL-NNN)" ;;
  esac
  db_require_init

  rows="$(_render_tmp goal-show)"
  sqlf="$(_render_tmp goal-show-sql)"
  _dir_goal_show_sql "$(sql_text "$id" 'the GOAL-ID argument')" >"$sqlf"
  _render_query "$sqlf" "$rows" "guild: could not read $id from the database"

  # The reader, in `export_all`'s two states — and the whole safety property is in the
  # second one:
  #   want == 0  expecting a header. Only a line the SQL wrote can be here, because the
  #              previous chunk was consumed to its exact last line.
  #   want  > 0  inside a value. Lines are printed VERBATIM and counted down, never
  #              matched against anything, so no body can be read as structure.
  # A header is matched WHOLE and anchored, so it carries no free text at all and $2 is
  # always the count the SQL computed.
  rc=0
  LC_ALL=C awk '
    want > 0 { print; want--; next }
    /^@@GUILD-GOAL@@ [0-9]+$/ { want = $2 + 0; seen = 1; next }
    { next }
    END {
      if (!seen) exit 3
      if (want > 0) exit 4
    }
  ' "$rows" || rc=$?
  rm -f "$rows"

  case "$rc" in
    0) return 0 ;;
    3) die "guild: $id not found" ;;
    4) die "guild: $id rendered short; the database returned a truncated record" ;;
    *) die "guild: could not render $id" ;;
  esac
}

# ---- goal: mutate ------------------------------------------------------------------

# cmd_goal_move <GOAL-ID> <status> — set status to todo|in-progress|done. Prints the ID.
#
# `cmd_move`'s shape exactly: the event is written BEFORE the update so its payload can
# carry BOTH ends of the transition, and the update's RETURNING then yields the
# resulting row for the journal. One script, one round trip.
cmd_goal_move() {
  _dir_move_kind goal "$@"
}

# cmd_phase_move <PHASE-ID> <status> — the same, for a phase.
cmd_phase_move() {
  _dir_move_kind phase "$@"
}

# _dir_move_kind <kind> <ID> <status> — the body of both move commands.
#
# One implementation, because the two differ only in the table: a second copy would be a
# second place for the status-set and the event verb to drift.
_dir_move_kind() {
  local kind="${1-}" id="${2-}" target="${3-}" table statuses ok st
  local idlit now nowlit rowexpr sql row
  [ -n "$id" ] || die "guild: $kind move requires an ID"
  [ -n "$target" ] || die "guild: $kind move requires a status"
  [ $# -le 3 ] || die "guild: $kind move takes an ID and a status"
  table="$(_dir_table "$kind")" || exit 1
  statuses="$(_dir_statuses "$kind")" || exit 1
  [ "$(_dir_kind_of_id "$id")" = "$kind" ] ||
    die "guild: $id is not a $kind id"

  ok=0
  for st in $statuses; do
    if [ "$st" = "$target" ]; then ok=1; fi
  done
  [ "$ok" = 1 ] ||
    die "guild: invalid status '$target' for $kind (allowed: $statuses)"

  db_require_init
  journal_preflight
  # `$target` is sql_str because it was just validated against a fixed, known-safe set.
  # `$id` is only prefix-checked, so it is free text (§2.2.1).
  idlit="$(sql_text "$id" 'the ID argument')"
  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  rowexpr="$(_art_json_row "$table")" || exit 1

  sql="BEGIN;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $(sql_text "$(_art_actor)" "\$GUILD_ACTOR"), 'moved', $(sql_str "$table"), id,
       json_object('from', status, 'to', $(sql_str "$target"))
FROM $table WHERE id = $idlit;
UPDATE $table SET status = $(sql_str "$target"), updated_at = $nowlit
WHERE id = $idlit
RETURNING 'OK|' || $rowexpr;
COMMIT;
"

  row="$(_art_update_run "$id" "move $id" "$sql")" || exit 1
  journal_append "$table" upsert "$row"
  printf '%s\n' "$id"
}

# cmd_goal_priority <GOAL-ID> <1-5> — repriority a goal. Prints the ID.
#
# A separate verb rather than a flag on `move`, because status and priority are
# independent axes: a `todo` goal can be the most urgent thing on the board, and
# folding them together would make one unsettable without restating the other.
#
# The event verb is `reprioritized` with a {from,to} payload, so the activity feed can
# say what changed rather than only that something did.
cmd_goal_priority() {
  local id="${1-}" prio="${2-}" idlit now nowlit rowexpr sql row
  [ -n "$id" ] || die "guild: goal priority requires a GOAL-ID"
  [ -n "$prio" ] || die "guild: goal priority requires a priority (1-5)"
  [ $# -le 2 ] || die "guild: goal priority takes a GOAL-ID and a priority"
  [ "$(_dir_kind_of_id "$id")" = "goal" ] || die "guild: $id is not a goal id"
  prio="$(_dir_require_priority "$prio")" || exit 1

  db_require_init
  journal_preflight
  idlit="$(sql_text "$id" 'the GOAL-ID argument')"
  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  rowexpr="$(_art_json_row goal)"

  sql="BEGIN;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $(sql_text "$(_art_actor)" "\$GUILD_ACTOR"), 'reprioritized', 'goal', id,
       json_object('from', priority, 'to', $prio)
FROM goal WHERE id = $idlit;
UPDATE goal SET priority = $prio, updated_at = $nowlit
WHERE id = $idlit
RETURNING 'OK|' || $rowexpr;
COMMIT;
"

  row="$(_art_update_run "$id" "reprioritize $id" "$sql")" || exit 1
  journal_append goal upsert "$row"
  printf '%s\n' "$id"
}

# ---- the roll-up -------------------------------------------------------------------
#
# `guild goal rollup [GOAL-NNN]` — recompute goal and phase status from the requirements
# beneath them.
#
# WHY THIS EXISTS. Stage 2 shipped `goal.status` and `phase.status` as columns only a
# HUMAN could move (`guild goal move`, `guild phase move`), while the requirements under
# them advance constantly through `guild move REQ-001 done`. Nothing connected the two, so
# in practice nothing ever moved them: a goal whose every requirement was finished still
# read `todo` on the brief's Direction section and on the dashboard's roadmap, forever.
# A product reviewer called it the only element on either surface that is RELIABLY WRONG,
# which is the worst kind of wrong — a status that is sometimes stale is read with
# suspicion, a status that is always stale is read as truth by anyone who has not yet been
# burned by it.
#
# THE RULE, in full:
#
#   a phase with at least one requirement
#       done          every requirement is `done`
#       in-progress   at least one requirement has left `todo`
#       todo          otherwise
#   a phase with NO requirements          UNTOUCHED
#   a goal with at least one phase        the same three tests, over its phases
#   a goal with NO phases                 UNTOUCHED
#
# CHILDLESS ROWS ARE LEFT ALONE, and that is the rule that makes this safe to run at any
# time. An empty phase has no evidence of completion, so deriving one would be inventing
# it — and a goal or phase that has not been decomposed yet is precisely where a human's
# `guild goal move` is the only information there is. Deriving over it would silently
# overwrite the guild master. The consequence is stated rather than hidden: a goal holding
# one empty placeholder phase never reaches `done`, because one stage of it demonstrably
# has nothing in it.
#
# IT MOVES BACKWARD TOO. A requirement reopened from `done` pulls its phase back to
# `in-progress` and, through it, its goal. "Recompute from the requirements beneath" means
# the status is a FUNCTION of the children, and a function that only ever increases is not
# one — it is a high-water mark, and a high-water mark would report a goal as finished
# while work under it was reopened. That is the same false-green this CLI refuses
# elsewhere.
#
# IDEMPOTENT BY CONSTRUCTION: every statement carries `status <> (<computed>)`, so a
# second run selects no rows, writes nothing, journals nothing and prints nothing.
#
# NO RECURSION, and this is where the temptation is strongest (§3.0: `WITH RECURSIVE`
# FAILS on tursodb). The hierarchy is FIXED-DEPTH — requirement -> phase -> goal — so it
# is two ordinary aggregate passes, in order, in one script. Phases are updated first and
# the goal pass then reads the phase rows the previous statement just wrote, which is what
# makes a single round trip enough for both levels.

# cmd_goal_rollup [GOAL-NNN] — recompute status for every goal and phase, or for one goal
# and its phases. Prints one line per CHANGE, and nothing at all when nothing moved:
#
#   PHASE-002 todo -> in-progress
#   GOAL-001 todo -> in-progress
#
# ONE SCRIPT, ONE ROUND TRIP, SIX STATEMENTS, in this order — the order is the algorithm:
#
#   1. 'G'  existence probe            (scoped runs only)
#   2. CHG  the phase changes, as text — SELECTED BEFORE THE UPDATE, because RETURNING
#           yields the NEW row and there is no OLD.* in SQLite's RETURNING, so this is
#           the only place the previous status still exists
#   3.      the phase `event` rows     (payload carries both ends of each move)
#   4.      UPDATE phase … RETURNING the resulting row, for the journal
#   5-6.    the same three for goals, AFTER the phase update, so a goal is computed from
#           the phase statuses this command just wrote and not from the stale ones
#
# THE MARKERS ARE PREFIX-STRIPPED WITH FIXED LITERALS (`CHG|`, `OK|phase|`, `OK|goal|`),
# never with `${v%%|*}`: a row's JSON carries a title, a title can carry a pipe, and
# `%%pat*` scans from the end and is O(n²) under bash 3.2 (rule 5). A constant-length
# prefix compare has neither problem, and the table name is one of exactly two known
# words, so it is matched as a literal rather than parsed out as a field.
cmd_goal_rollup() {
  local goal="${1-}" goallit probe pcalc gcalc pwhere gwhere
  local now nowlit actorlit prow grow sql tmp line row out
  [ $# -le 1 ] || die "guild: goal rollup takes at most one GOAL-ID"

  goallit=""
  probe=""
  if [ -n "$goal" ]; then
    [ "$(_dir_kind_of_id "$goal")" = "goal" ] || die "guild: $goal is not a goal id"
    goallit="$(sql_text "$goal" 'the GOAL-ID argument')"
    probe="SELECT 'G' FROM goal WHERE id = $goallit;
"
  fi

  db_require_init
  journal_preflight

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  prow="$(_art_json_row phase)"
  grow="$(_art_json_row goal)"

  # The computed status. Three branches, not four: the "no children" case is handled by
  # the EXISTS guard in the WHERE below, so by the time these are evaluated the row is
  # known to have at least one child and `no requirement is not done` means `all done`.
  # An unrecognized child status (one replayed from a hand-edited journal) is not `done`
  # and is not `todo`, so it reads as started — which is the safe direction: it can delay
  # a `done`, never manufacture one.
  pcalc="CASE
         WHEN NOT EXISTS (SELECT 1 FROM requirement r WHERE r.phase_id = phase.id AND r.status <> 'done') THEN 'done'
         WHEN EXISTS (SELECT 1 FROM requirement r WHERE r.phase_id = phase.id AND r.status <> 'todo') THEN 'in-progress'
         ELSE 'todo' END"
  gcalc="CASE
         WHEN NOT EXISTS (SELECT 1 FROM phase p WHERE p.goal_id = goal.id AND p.status <> 'done') THEN 'done'
         WHEN EXISTS (SELECT 1 FROM phase p WHERE p.goal_id = goal.id AND p.status <> 'todo') THEN 'in-progress'
         ELSE 'todo' END"

  pwhere="EXISTS (SELECT 1 FROM requirement r WHERE r.phase_id = phase.id)
   AND phase.status <> ($pcalc)"
  gwhere="EXISTS (SELECT 1 FROM phase p WHERE p.goal_id = goal.id)
   AND goal.status <> ($gcalc)"
  if [ -n "$goallit" ]; then
    pwhere="$pwhere
   AND phase.goal_id = $goallit"
    gwhere="$gwhere
   AND goal.id = $goallit"
  fi

  # Ids and stored statuses are `_render_col`-flattened on the CHG lines even though this
  # CLI generates both: `guild rebuild` replays them from .guild/journal.ndjson, which
  # lives in git, and a line somebody may `awk` must not depend on who wrote that file.
  # The computed status needs no wrapper — it is one of three literals in this script.
  sql="BEGIN;
${probe}SELECT 'CHG|' || $(_render_col 'phase.id') || ' ' || $(_render_col 'phase.status') || ' -> ' || ($pcalc)
FROM phase WHERE $pwhere;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $actorlit, 'moved', 'phase', phase.id,
       json_object('from', phase.status, 'to', ($pcalc), 'by', 'rollup')
FROM phase WHERE $pwhere;
UPDATE phase SET status = ($pcalc), updated_at = $nowlit
WHERE $pwhere
RETURNING 'OK|phase|' || $prow;
SELECT 'CHG|' || $(_render_col 'goal.id') || ' ' || $(_render_col 'goal.status') || ' -> ' || ($gcalc)
FROM goal WHERE $gwhere;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $actorlit, 'moved', 'goal', goal.id,
       json_object('from', goal.status, 'to', ($gcalc), 'by', 'rollup')
FROM goal WHERE $gwhere;
UPDATE goal SET status = ($gcalc), updated_at = $nowlit
WHERE $gwhere
RETURNING 'OK|goal|' || $grow;
COMMIT;
"

  # Staged through a file, not a pipe, for `_render_query`'s reason: on the right of a
  # pipe the loop below runs in a subshell, so a `die` inside it — and every
  # `journal_append` failure path — would end that subshell and let the caller sail on
  # reporting success.
  tmp="$(_art_tmpfile)" || exit 1
  if ! printf '%s' "$sql" | db_exec >"$tmp"; then
    out="$(cat "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    db_fail "could not roll up${goal:+ $goal}" "$out"
  fi
  if [ -n "$goallit" ] && [ "$(_art_first_line "$tmp")" != "G" ]; then
    rm -f "$tmp"
    die "guild: $goal not found"
  fi

  # A MALFORMED ROW IS FATAL, not skipped. The write has already committed by the time
  # this loop runs, so a row this cannot journal is a mutation the journal does not carry
  # — and `guild rebuild` would silently undo it. Saying so loudly is the only honest
  # answer; `_art_update_run` refuses on the same shape for the same reason.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'CHG|'*)
        printf '%s\n' "${line#CHG|}"
        ;;
      'OK|phase|'*)
        row="${line#OK|phase|}"
        _dir_rollup_journal phase "$row"
        ;;
      'OK|goal|'*)
        row="${line#OK|goal|}"
        _dir_rollup_journal goal "$row"
        ;;
    esac
  done <"$tmp"
  rm -f "$tmp"
}

# _dir_rollup_journal <table> <row-json> — journal one rolled-up row, or die naming what
# the database returned instead. Split out of the loop above so the refusal is written
# once for both tables rather than twice with room to disagree.
_dir_rollup_journal() {
  local table="${1-}" row="${2-}"
  case "$row" in
    '{'*'}') ;;
    *)
      die "guild: the roll-up changed a $table row the database then described unusably,
so it could not be journaled.

THE CHANGE IS COMMITTED and the journal does not carry it, which means 'guild rebuild'
would undo it. Re-running the roll-up will NOT fix that — it recomputes, finds the status
already correct, and writes nothing. Snapshot the live board as a new baseline instead:

  guild goal list      # confirm the statuses are what you expect
  guild journal compact"
      ;;
  esac
  journal_append "$table" upsert "$row"
}

# ---- phase -------------------------------------------------------------------------

# cmd_phase_new --goal GOAL-NNN --title T [--ordinal N] [--date YYYY-MM-DD]
#
# Prints "<ID> <title>", the same shape `goal new` prints and for the same reasons.
#
# `--ordinal` is DERIVED when it is not given: the next one within that goal,
# `COALESCE(MAX(ordinal),0) + 1`, computed in the same statement as the insert so there
# is no read-then-write race — exactly how the id itself is derived. Passing `--ordinal`
# explicitly is how a phase is inserted between two existing ones; nothing here forces
# the ordinals of one goal to be unique or contiguous, because renumbering the rest of a
# goal's phases to keep them so would be several writes hiding inside one command.
# Ties break by id, deterministically, everywhere they are ordered.
cmd_phase_new() {
  local now nowlit actorlit created idexpr rowexpr ordexpr goallit sql result id row
  _dir_parse_flags "$@"
  [ -n "$dir_title" ] || die "guild: phase new requires --title"
  [ -n "$dir_goal" ] || die "guild: phase new requires --goal"
  case "$dir_goal" in
    GOAL-*) ;;
    *) die "guild: --goal must be a GOAL-NNN id, got '$dir_goal'" ;;
  esac
  db_require_init
  journal_preflight

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  created="$(_art_created_expr "$dir_date" "$nowlit")"
  idexpr="$(_dir_next_id_expr phase)" || exit 1
  rowexpr="$(_art_json_row phase)"
  goallit="$(sql_text "$dir_goal" '--goal')"

  if [ -n "$dir_ordinal" ]; then
    ordexpr="$(_dir_require_ordinal "$dir_ordinal")" || exit 1
  else
    ordexpr="(SELECT COALESCE(MAX(ordinal), 0) + 1 FROM phase WHERE goal_id = $goallit)"
  fi

  # `FROM goal g WHERE g.id = …` IS the referential check: a `--goal` that does not
  # exist selects zero rows, so nothing is inserted, RETURNING prints nothing, and the
  # MISS line below names the missing reference. Deliberately not a WHERE on an
  # aggregate — an aggregate with a false WHERE still returns one row, of NULLs, and
  # would have inserted a phase with a bogus id.
  sql="BEGIN;
INSERT INTO phase (id, goal_id, title, ordinal, status, created_at, updated_at)
SELECT $idexpr, g.id, $(sql_text "$dir_title" '--title'), $ordexpr, 'todo', $created, $nowlit
FROM goal g WHERE g.id = $goallit
RETURNING 'OK|' || id || '|' || $rowexpr;
SELECT 'MISS|' || $goallit
  WHERE NOT EXISTS (SELECT 1 FROM goal WHERE id = $goallit);
$(_dir_created_event_sql phase "$nowlit" "$actorlit")
COMMIT;
"

  result="$(_art_create_run 'the phase' "$sql")" || exit 1
  id="${result%% *}"
  row="${result#* }"
  journal_append phase upsert "$row"
  printf '%s %s\n' "$id" "$(_render_flat_arg "$dir_title")"
}

# cmd_phase_list [--goal GOAL-NNN]
#
#   <PHASE-ID> <GOAL-ID> <ordinal> <status> <reqs-done>/<reqs-total> <title>
#   PHASE-002 GOAL-001 2 in-progress 0/1 Visibility
#
# Ordered by goal, then ordinal, then id — the order the phases are meant to run in.
# Same column contract as `goal list`: every field but the trailing title is
# `_render_col`-flattened, so the field count is fixed and awk filters cannot be shifted.
cmd_phase_list() {
  local goal="" cols where
  while [ $# -gt 0 ]; do
    case "$1" in
      --goal) shift; goal="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --*) die "guild: phase list takes only --goal GOAL-NNN" ;;
      *) die "guild: phase list takes only --goal GOAL-NNN" ;;
    esac
  done
  db_require_init

  cols="$(_render_col 'p.id') || ' ' || $(_render_col 'p.goal_id') || ' ' || p.ordinal"
  cols="$cols || ' ' || $(_render_col 'p.status') || ' '"
  cols="$cols || (SELECT COUNT(*) FROM requirement r WHERE r.phase_id = p.id AND r.status = 'done')"
  cols="$cols || '/' || (SELECT COUNT(*) FROM requirement r WHERE r.phase_id = p.id)"
  cols="$cols || ' ' || $(_render_flat 'p.title')"

  where=""
  [ -z "$goal" ] || where=" WHERE p.goal_id = $(sql_text "$goal" '--goal')"

  printf 'SELECT %s FROM phase p%s ORDER BY p.goal_id, p.ordinal, p.id;\n' \
    "$cols" "$where" | db_query
}

# ---- requirement -> phase ----------------------------------------------------------

# cmd_req_assign <REQ-NNN> <PHASE-NNN|none> — attach a requirement to a phase, or (with
# the literal `none`) detach it. Prints the REQ id.
#
# `requirement.phase_id` IS NULLABLE BY DESIGN and this command must never change that.
# Unaffiliated work is legal — a bug fix, a chore, anything a user files directly — so
# there is no `guild new req --phase`, nothing here validates that a requirement HAS a
# phase, and `none` exists so that assigning is not a one-way door. Without it the first
# assignment would permanently remove a requirement from the unaffiliated pool, which
# would make "unaffiliated work is legal" true only until someone filed it under a goal
# by mistake.
#
# The phase is checked by an EXISTS guard rather than left to the foreign key: a raw FK
# violation from the engine is a parse error in a buffer this CLI reads as data, whereas
# a guarded UPDATE that matches nothing lets the MISS line say which reference was bad.
cmd_req_assign() {
  local req="${1-}" phase="${2-}" reqlit phaselit phaseexpr now nowlit rowexpr
  local guard misses toexpr sql row
  [ -n "$req" ] || die "guild: req assign requires a REQ-NNN"
  [ -n "$phase" ] || die "guild: req assign requires a PHASE-NNN (or 'none' to detach)"
  [ $# -le 2 ] || die "guild: req assign takes a REQ-NNN and a PHASE-NNN"
  case "$req" in
    REQ-*) ;;
    *) die "guild: unrecognized id '$req' (expected REQ-NNN)" ;;
  esac
  case "$phase" in
    PHASE-* | none) ;;
    *) die "guild: '$phase' is not a PHASE-NNN id (use 'none' to detach)" ;;
  esac

  db_require_init
  journal_preflight
  reqlit="$(sql_text "$req" 'the REQ-NNN argument')"
  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  rowexpr="$(_art_json_row requirement)" || exit 1

  if [ "$phase" = "none" ]; then
    phaseexpr="NULL"
    toexpr="''"
    guard=""
    misses=""
  else
    phaselit="$(sql_text "$phase" 'the PHASE-NNN argument')"
    phaseexpr="$phaselit"
    toexpr="$phaselit"
    guard="
  AND EXISTS (SELECT 1 FROM phase WHERE id = $phaselit)"
    misses="SELECT 'MISS|' || $phaselit
  WHERE NOT EXISTS (SELECT 1 FROM phase WHERE id = $phaselit);
"
  fi

  # The event first, so its payload carries both ends of the move; the update's
  # RETURNING then yields the resulting row for the journal. Both statements carry the
  # same guard, so a bad phase writes neither.
  sql="BEGIN;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $(sql_text "$(_art_actor)" "\$GUILD_ACTOR"), 'assigned', 'requirement', id,
       json_object('from', COALESCE(phase_id, ''), 'to', $toexpr)
FROM requirement WHERE id = $reqlit$guard;
UPDATE requirement SET phase_id = $phaseexpr, updated_at = $nowlit
WHERE id = $reqlit$guard
RETURNING 'OK|' || $rowexpr;
${misses}SELECT 'MISS|' || $reqlit
  WHERE NOT EXISTS (SELECT 1 FROM requirement WHERE id = $reqlit);
COMMIT;
"

  row="$(_art_update_run "$req" "assign $req" "$sql")" || exit 1
  journal_append requirement upsert "$row"
  printf '%s\n' "$req"
}

# ---- subcommand dispatch -----------------------------------------------------------
#
# scripts/guild routes `goal`, `phase` and `req` here; the second word selects the verb,
# the same two-level shape `guild new <kind>` and `guild journal <verb>` already use.
# An unknown verb names the ones that exist rather than saying only "unknown".

# cmd_goal <new|list|show|move|priority> [args...]
#
# The bare-command case prints the usage BLOCK rather than a one-line "needs a
# subcommand", which is `cmd_bug` / `cmd_doc`'s shape in lib/records.sh: `guild goal` with
# nothing after it is somebody asking what the verbs are, and the answer that names them
# with their flags is the one that ends the question. The two Stage 2 modules arrived
# disagreeing about this; they agree now.
cmd_goal() {
  local sub="${1-}"
  [ $# -eq 0 ] || shift
  case "$sub" in
    new) cmd_goal_new "$@" ;;
    list) cmd_goal_list "$@" ;;
    show) cmd_goal_show "$@" ;;
    move) cmd_goal_move "$@" ;;
    priority) cmd_goal_priority "$@" ;;
    rollup) cmd_goal_rollup "$@" ;;
    '')
      die "guild: goal needs a subcommand

  guild goal new --title T [--body B] [--priority 1-5] [--date YYYY-MM-DD]
  guild goal list [todo|in-progress|done]
  guild goal show <GOAL-ID>
  guild goal move <GOAL-ID> todo|in-progress|done
  guild goal priority <GOAL-ID> 1-5
  guild goal rollup [GOAL-ID]   Recompute goal/phase status from the requirements beneath"
      ;;
    *) die "guild: unknown goal subcommand '$sub' (new|list|show|move|priority|rollup)" ;;
  esac
}

# cmd_phase <new|list|move> [args...]
cmd_phase() {
  local sub="${1-}"
  [ $# -eq 0 ] || shift
  case "$sub" in
    new) cmd_phase_new "$@" ;;
    list) cmd_phase_list "$@" ;;
    move) cmd_phase_move "$@" ;;
    '')
      die "guild: phase needs a subcommand

  guild phase new --goal GOAL-NNN --title T [--ordinal N] [--date YYYY-MM-DD]
  guild phase list [--goal GOAL-NNN]
  guild phase move <PHASE-ID> todo|in-progress|done"
      ;;
    *) die "guild: unknown phase subcommand '$sub' (new|list|move)" ;;
  esac
}

# cmd_req <assign> [args...]
#
# A namespace with one verb today. It is not folded into `guild move` or `guild new`:
# `guild new req` creates a requirement and `guild move REQ-001 done` sets its status,
# while this sets a different column, so sharing either name would overload a command
# whose output and error text the harness pins.
cmd_req() {
  local sub="${1-}"
  [ $# -eq 0 ] || shift
  case "$sub" in
    assign) cmd_req_assign "$@" ;;
    '')
      die "guild: req needs a subcommand

  guild req assign <REQ-NNN> <PHASE-NNN|none>"
      ;;
    *) die "guild: unknown req subcommand '$sub' (assign)" ;;
  esac
}
