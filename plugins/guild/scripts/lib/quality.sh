# shellcheck shell=bash
#
# lib/quality.sh — guild v5 Stage 2b: the `coverage` table gets a WRITER (design §6.2,
# §11, §13 Stage 2).
#
# Stage 2 shipped `coverage` as a READ surface — `guild brief`'s "N area(s) due for
# inspection" section and the dashboard's Coverage view, which carries the only computed
# insight on the whole page ("5 never inspected, 0 overdue"). It shipped no way to put a
# row there. The single producer was `carry_over_qa` in lib/init.sh, which runs ONCE at
# `guild init` off a v4 `.guild/qa/charter.md`, so a greenfield v5 guild could never have
# a coverage row at all and the section was frozen in amber from day one on every other
# guild. This module is that missing half.
#
# WHY THIS IS LOAD-BEARING AND NOT A CONVENIENCE. `coverage.last_inspected_at` + `risk`
# is what makes "what needs inspecting?" a QUERY rather than a feeling — the maintenance
# cycle's `qa-check` node (§6.2) ends the cycle early when nothing qualifies, and it can
# only do that against rows somebody wrote. A coverage table that only `guild init` fills
# makes Stage 4's maintenance template unimplementable, which is why the writer lands
# now rather than with the template that consumes it.
#
#   guild coverage set <area-id> --area T [--risk high|medium|low] [--spec PATH]
#                                [--notes N]          upsert one quality area
#   guild coverage inspect <area-id> [--date YYYY-MM-DD]   stamp last_inspected_at
#   guild coverage list [--risk R] [--due]                 columnar, awk-filterable
#   guild coverage show <area-id>                          one area as markdown
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` (scripts/guild owns those).
# Bash 3.2 compatible: no associative arrays, no `declare -A`, no `mapfile`, no ${var^^}.
#
# Depends on lib/db.sh        : die, db_fail, db_require_init, db_exec, db_query, db_now,
#                               sql_str, sql_text
#          on lib/journal.sh  : journal_preflight, journal_append
#          on lib/artifacts.sh: _art_actor, _art_created_expr, _art_json_row,
#                               _art_update_run, _art_tmpfile
#          on lib/records.sh  : _rec_in_set, _rec_check_slug (the shared id alphabet)
#          on lib/render.sh   : _render_flat, _render_col, _render_yaml_dq,
#                               _render_yaml_scalar
#          on lib/brief.sh    : _brief_coverage_where (the staleness thresholds)
#
# THOSE DEPENDENCIES ARE DELIBERATE REUSE, NOT CONVENIENCE — lib/records.sh's header
# states the rule and the reason, and both apply verbatim here. Two places that answer
# "when is an area stale?" is how the CLI and the brief start disagreeing about which
# areas are due, so `coverage list --due` calls `_brief_coverage_where` rather than
# restating 14/30/90.
#
# ---------------------------------------------------------------------------------
# HARD RULES honored throughout (§2.2, §2.2.1, §3.0):
#
#   * ONE db_exec PER LOGICAL COMMAND. `set` and `inspect` each compose a single script
#     — the `event` row, the write, and the RETURNING marker — and run it once.
#
#   * sql_text FOR ALL FREE TEXT; sql_str ONLY for known-safe alphabets. `--area`,
#     `--spec`, `--notes` and `--date` are unvalidated argv and travel as
#     `CAST(x'…' AS TEXT)`. A SPEC PATH IS THE LIKELIEST CARRIER HERE: it is pasted from
#     a test runner's output and can hold any byte a filesystem allows. Only the area id
#     (validated against _rec_check_slug's alphabet) and the risk word (validated against
#     _qa_risks) reach SQL through sql_str.
#
#   * A VALUE MUST NEVER IMPERSONATE A STRUCTURAL TOKEN. `coverage list` is COLUMNAR and
#     awk-filterable, so every leading column is `_render_col` and the one free-text
#     column — the human area name — is `_render_flat` and comes LAST. `coverage show` is
#     a `---`-fenced document, so its frontmatter goes through the same two YAML helpers
#     `guild meta` and `guild bug show` use.
#
#   * EVERY MUTATION IS JOURNALED AND EMITS AN `event` ROW. journal_preflight runs BEFORE
#     any SQL. `guild rebuild` needs no new case for this: journal replay discovers its
#     tables from the schema, and `guild init`'s carry-over has been journaling
#     `coverage upsert` lines since Stage 1 — the one registry that did need the table is
#     `_art_json_row`, where it now sits beside bug and doc.

# ---- vocabulary --------------------------------------------------------------------

# _qa_risks — the coverage risk vocabulary. Closed and small, and matched EXACTLY to what
# `_brief_coverage_where` branches on (high -> 14 days, low -> 90, everything else -> 30)
# and to `_init_risk`'s mapping of a v4 charter's risk words. A fourth word here would be
# silently treated as `medium` by both readers, which is the shape of a bug that never
# reports itself.
_qa_risks() {
  printf 'high medium low\n'
}

# _qa_check_risk <value> — die unless the value is a known risk level.
_qa_check_risk() {
  local set
  set="$(_qa_risks)"
  # Unquoted on purpose: the set is a space-separated word list this file wrote.
  # shellcheck disable=SC2086
  _rec_in_set "${1-}" $set ||
    die "guild: unknown risk '${1-}' (allowed: $set)"
}

# _qa_check_area_id <id> — a coverage area id is a filename-shaped token.
#
# It is `_rec_check_slug` with this command's nouns, NOT a second alphabet. The reasons
# that function gives for validating rather than escaping hold here one for one: the id
# is a KEY the strategist retypes on the next pass to update the same row rather than
# fork a duplicate; it is a COLUMN on `coverage list` and the `subject_id` of every
# coverage event; and slugifying silently would make `coverage set 'Checkout Flow'` write
# `checkout-flow` and the next `coverage inspect 'Checkout Flow'` report not-found.
#
# It is also what makes the ids `guild init`'s carry-over generates (`_init_slug`, which
# emits [a-z0-9-]) and the ids a strategist types the SAME NAMESPACE — so a v4 guild's
# `checkout` area is updated by a later pass rather than shadowed by a near-miss.
_qa_check_area_id() {
  _rec_check_slug "${1-}" 'coverage area id' '--area'
}

# ---- flags -------------------------------------------------------------------------

# _qa_parse_flags — fill qa_* from argv. Same shape and same reasons as
# `_rec_parse_flags`: an unknown `--flag` consumes its value rather than falling through
# to the positional slot, so a typo is not silently read as an area id.
#
# NO COMMAND HERE TAKES A POSITIONAL BEYOND THE AREA ID, which each command has already
# shifted off before calling this. So a leftover positional is always a mistake, `qa_rest`
# holds the first one, and `_qa_no_positional` reports it — `guild coverage set checkout
# "Checkout flow"` (the --area forgotten) is the shape this catches, and the alternative
# is a row silently stored with the wrong human name.
_qa_parse_flags() {
  qa_area=""
  qa_risk=""
  qa_spec=""
  qa_spec_set=0
  qa_notes=""
  qa_date=""
  qa_due=0
  qa_rest=""
  qa_rest_n=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --area) shift; qa_area="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --risk) shift; qa_risk="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --spec) shift; qa_spec="${1-}"; qa_spec_set=1; if [ $# -gt 0 ]; then shift; fi ;;
      --notes) shift; qa_notes="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --date) shift; qa_date="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --due) qa_due=1; shift ;;
      --*) shift; if [ $# -gt 0 ]; then shift; fi ;;
      *)
        qa_rest_n=$((qa_rest_n + 1))
        if [ "$qa_rest_n" = 1 ]; then qa_rest="$1"; fi
        shift
        ;;
    esac
  done
}

# _qa_no_positional <usage> — die when `_qa_parse_flags` collected a stray positional.
# The value is flattened into the message: it is unvalidated argv, and this line's
# structure is the sentence around it.
_qa_no_positional() {
  [ "$qa_rest_n" = 0 ] ||
    die "guild: unexpected argument '$(_render_flat_arg "$qa_rest")'

  ${1-}"
}

# ---- neutralizing free text for `coverage show` -------------------------------------

# _qa_defuse_notes <text> — indent any line that IS a line `coverage show` GENERATES.
#
# `coverage show` reconstructs a document out of columns — a `---` frontmatter fence,
# then a `## Notes` section holding the free-text `notes` — so without this, a note
# reading
#
#   ---
#   risk: low
#
# closes the frontmatter as far as any reader that splits on the fence is concerned, and
# everything after it is author-supplied rather than column-derived. That is not a
# hypothetical: the harness's forgery payload is exactly those two lines, and it broke
# this document the first time it was rendered.
#
# NEUTRALIZE, DON'T REFUSE, for `_rec_defuse_body`'s reason: a note about a quality area
# legitimately quotes `---` (a markdown table rule, a pasted frontmatter). The two-space
# indent leaves CommonMark reading `  ---` as a thematic break and `  ## X` as a heading,
# while the `^---$` and `^## ` parsers every consumer of these documents actually is stop
# matching.
#
# It DELEGATES the shared half to `_art_defuse_body` and adds only this document's own
# heading — the same one-mechanism-two-heading-lists shape `_rec_defuse_body` has.
_qa_defuse_notes() {
  _art_defuse_lines "$(_art_defuse_body "${1-}")" '## Notes'
}

# ---- coverage: upsert ---------------------------------------------------------------

# cmd_coverage_set <area-id> --area T [--risk R] [--spec PATH] [--notes N]
#
# Prints "<area-id> <area>" — the id first so `${out%% *}` takes it, the flattened human
# name after so the line reads in a check-in transcript. Same echo shape as `bug new`.
#
# IT IS AN UPSERT AND IT PRESERVES WHAT IT WAS NOT ASKED TO CHANGE. The qa-strategist
# re-runs a survey over a product that already has a risk surface, and the two things it
# must not do are fork a near-duplicate row (which would double-count every "due"
# number) and reset the inspection clock (which would make an area that was inspected
# yesterday look freshly inspected today merely because somebody retyped its risk).
# So:
#
#   area                always overwritten — it is required, and it is the one field the
#                       caller is unambiguously restating
#   risk / notes        the new value if given, else the STORED value, else the column
#                       default ('medium' / '')
#   spec_path           the new value if given, else the stored one. `--spec ''` is an
#                       explicit clear (qa_spec_set), because a spec can be deleted from
#                       the repo and "" is the only way to say so
#   last_inspected_at   NEVER touched here. `coverage inspect` is the only writer, which
#                       is what keeps the staleness clock honest
#
# The COALESCE chain expresses all four in ONE statement, so there is no read-then-write
# race and no branch in bash that could disagree with the SQL. `WHERE 1=1` is not
# decoration: SQLite's grammar cannot otherwise tell a trailing `ON CONFLICT` from a join
# `ON` in an `INSERT … SELECT`, and the parse it picks is the wrong one.
#
# The event's verb comes from whether the row existed BEFORE the upsert, which is why the
# event is written first — "a new area entered the risk surface" and "an area's risk was
# re-rated" are different facts, and `guild brief` narrates them differently.
cmd_coverage_set() {
  local id="${1-}" idlit now nowlit actorlit rowexpr sql out line row
  local arealit risklit speclit noteslit riskexpr specexpr notesexpr
  _qa_check_area_id "$id"
  shift
  _qa_parse_flags "$@"
  _qa_no_positional "guild coverage set <area-id> --area T [--risk high|medium|low] [--spec PATH] [--notes N]"
  [ -n "$qa_area" ] || die "guild: coverage set requires --area (the human-readable name)"
  [ -z "$qa_risk" ] || _qa_check_risk "$qa_risk"

  db_require_init
  journal_preflight

  # The id passed _rec_check_slug's alphabet, so it is a known-safe value; it is also the
  # one value here that must read back identically in an error message, a journal line
  # and an event's subject_id.
  idlit="$(sql_str "$id")"
  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  rowexpr="$(_art_json_row coverage)"

  # Neutralized before storage, not on the way out: `coverage show` renders the notes
  # into a fenced, sectioned document, and the stored value is what a later reader sees.
  arealit="$(sql_text "$qa_area" '--area')"
  qa_notes="$(_qa_defuse_notes "$qa_notes")"
  # Validated against _qa_risks above, so sql_str is correct for it; an omitted --risk is
  # the empty string, which NULLIF turns into "keep what is stored".
  risklit="$(sql_str "$qa_risk")"
  speclit="$(sql_text "$qa_spec" '--spec')"
  noteslit="$(sql_text "$qa_notes" '--notes')"

  riskexpr="COALESCE(NULLIF($risklit,''), (SELECT risk FROM coverage WHERE id = $idlit), 'medium')"
  notesexpr="COALESCE(NULLIF($noteslit,''), (SELECT notes FROM coverage WHERE id = $idlit), '')"
  if [ "$qa_spec_set" = 1 ]; then
    # An explicit --spec, including the empty string. '' clears the column to NULL,
    # which is what every reader already means by "no committed spec".
    specexpr="NULLIF($speclit,'')"
  else
    specexpr="(SELECT spec_path FROM coverage WHERE id = $idlit)"
  fi

  sql="BEGIN;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $actorlit,
       CASE WHEN EXISTS (SELECT 1 FROM coverage WHERE id = $idlit) THEN 'updated' ELSE 'created' END,
       'coverage', $idlit, json_object('risk', $riskexpr, 'spec_path', $specexpr);
INSERT INTO coverage (id, area, risk, spec_path, last_inspected_at, notes)
SELECT $idlit, $arealit, $riskexpr, $specexpr,
       (SELECT last_inspected_at FROM coverage WHERE id = $idlit), $notesexpr
WHERE 1=1
ON CONFLICT(id) DO UPDATE SET
  area = excluded.area,
  risk = excluded.risk,
  spec_path = excluded.spec_path,
  last_inspected_at = excluded.last_inspected_at,
  notes = excluded.notes
RETURNING 'OK|' || $rowexpr;
COMMIT;
"
  if ! out="$(printf '%s' "$sql" | db_exec)"; then
    db_fail "could not record the coverage area '$id'" "$out"
  fi
  line="$(printf '%s' "$out" | head -n1)"
  case "$line" in
    'OK|{'*'}') ;;
    *) die "guild: could not record the coverage area '$id' (unexpected database output)" ;;
  esac
  row="${line#OK|}"

  journal_append coverage upsert "$row"
  printf '%s %s\n' "$id" "$(_render_flat_arg "$qa_area")"
}

# ---- coverage: the inspection stamp -------------------------------------------------

# cmd_coverage_inspect <area-id> [--date YYYY-MM-DD] — record that somebody looked.
#
# THIS IS THE COMMAND THE MAINTENANCE CYCLE TURNS ON. Everything else about coverage is
# description; `last_inspected_at` is the only column that decays, and it is what makes
# "which areas are overdue" answerable without a human remembering. A qa-tester calls it
# once per area it actually exercised — not once per mission, and never for an area it
# planned to reach and did not, because a stamp is a claim that the area was looked at.
#
# `--date` reuses `_art_created_expr`'s rule (the flag when given, else now) rather than
# restating it, so a tester back-dating a session stamps the same way every other create
# in the CLI does. The stored value feeds `julianday()` in `_brief_coverage_where`, which
# reads a bare date and a full timestamp identically.
#
# The event is written BEFORE the update so its payload can carry BOTH ends of the
# transition — after the update, `last_inspected_at` is only the destination. Same
# ordering, and same reason, as `cmd_move` and `_rec_bug_update`.
cmd_coverage_inspect() {
  local id="${1-}" idlit now nowlit actorlit rowexpr stamp sql row
  _qa_check_area_id "$id"
  shift
  _qa_parse_flags "$@"
  _qa_no_positional "guild coverage inspect <area-id> [--date YYYY-MM-DD]"

  db_require_init
  journal_preflight

  idlit="$(sql_str "$id")"
  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  rowexpr="$(_art_json_row coverage)"
  stamp="$(_art_created_expr "$qa_date" "$nowlit")"

  sql="BEGIN;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $actorlit, 'inspected', 'coverage', id,
       json_object('from', last_inspected_at, 'to', $stamp, 'risk', risk)
FROM coverage WHERE id = $idlit;
UPDATE coverage SET last_inspected_at = $stamp
WHERE id = $idlit
RETURNING 'OK|' || $rowexpr;
COMMIT;
"
  # No MISS line is possible: this command references nothing but the area itself, so an
  # empty result means the area does not exist and `_art_update_run` says exactly that.
  row="$(_art_update_run "$id" "stamp the coverage area $id" "$sql")" || exit 1

  journal_append coverage upsert "$row"
  printf '%s\n' "$id"
}

# ---- coverage: read -----------------------------------------------------------------

# cmd_coverage_list [--risk R] [--due] — the risk surface, one area per line.
#
# "<id> <risk> <last-inspected|never> <spec|none> <area>" — four `_render_col` columns
# then the human name flattened and LAST, which is `bug list`'s and `doc list`'s shape
# and for their reason: a fixed field count survives `awk '$2=="high" && $3=="never"'`.
#
# `--due` IS `_brief_coverage_where`, CALLED, not restated. The thresholds (high 14 days,
# medium 30, low 90) are a judgment, and a judgment stated in two files is a judgment
# that will be revised in one of them — leaving `guild brief` and `guild coverage list`
# disagreeing about which areas need work, which is the single question this table
# exists to answer.
cmd_coverage_list() {
  local cols where nowlit
  _qa_parse_flags "$@"
  _qa_no_positional "guild coverage list [--risk high|medium|low] [--due]"
  [ -z "$qa_risk" ] || _qa_check_risk "$qa_risk"
  db_require_init

  nowlit="$(sql_str "$(db_now)")"

  cols="$(_render_col 'c.id') || ' ' || $(_render_col 'c.risk')"
  cols="$cols || ' ' || $(_render_col "COALESCE(NULLIF(substr(c.last_inspected_at,1,10),''),'never')")"
  cols="$cols || ' ' || $(_render_col "COALESCE(NULLIF(c.spec_path,''),'none')")"
  cols="$cols || ' ' || $(_render_flat 'c.area')"

  where=""
  [ -z "$qa_risk" ] || where=" WHERE c.risk = $(sql_str "$qa_risk")"
  if [ "$qa_due" = 1 ]; then
    if [ -z "$where" ]; then where=" WHERE"; else where="$where AND"; fi
    where="$where ($(_brief_coverage_where "$nowlit" | tr '\n' ' '))"
  fi

  printf 'SELECT %s FROM coverage c%s ORDER BY c.id;\n' "$cols" "$where" | db_query
}

# cmd_coverage_show <area-id> — one area as markdown, in `guild bug show`'s shape.
#
# A `---` frontmatter block every skill can parse, then the notes. The frontmatter goes
# through the same two helpers `guild meta` uses — `_render_yaml_dq` for the human name
# (always quoted, always escaped) and `_render_yaml_scalar` for the id, the risk word,
# the date and the path, which quotes only when the value is not already a safe plain
# scalar. Every optional field prints `null` rather than vanishing, so the block has a
# fixed key set and a parser never has to ask whether a field is missing.
#
# ONE statement, guarded on the row existing, so a missing id produces NO output and the
# caller reports `guild: <id> not found`.
cmd_coverage_show() {
  local id="${1-}" idlit sql tmp out
  _qa_check_area_id "$id"
  db_require_init
  idlit="$(sql_str "$id")"

  sql="SELECT '---
id: ' || $(_render_yaml_scalar "$(_render_flat 'id')") || '
area: ' || $(_render_yaml_dq "$(_render_flat 'area')") || '
risk: ' || $(_render_yaml_scalar "$(_render_flat 'risk')") || '
spec: ' || $(_render_yaml_scalar "$(_render_flat "COALESCE(NULLIF(spec_path,''),'null')")") || '
last-inspected: ' || $(_render_yaml_scalar "$(_render_flat "COALESCE(NULLIF(substr(last_inspected_at,1,10),''),'null')")") || '
---

# ' || $(_render_flat 'area') || '

## Notes

' || CASE WHEN trim(notes) = '' THEN '_No notes recorded._' ELSE notes END || '
'
FROM coverage WHERE id = $idlit;
"
  tmp="$(_art_tmpfile)" || exit 1
  if ! printf '%s' "$sql" | db_exec >"$tmp"; then
    out="$(cat "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    db_fail "could not read the coverage area '$id'" "$out"
  fi
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    die "guild: $id not found"
  fi
  cat "$tmp"
  rm -f "$tmp"
}

# ---- coverage: the subcommand -------------------------------------------------------

cmd_coverage() {
  local sub="${1-}"
  [ $# -eq 0 ] || shift
  case "$sub" in
    set) cmd_coverage_set "$@" ;;
    inspect) cmd_coverage_inspect "$@" ;;
    list) cmd_coverage_list "$@" ;;
    show) cmd_coverage_show "$@" ;;
    '')
      die "guild: coverage needs a subcommand

  guild coverage set <area-id> --area T [--risk high|medium|low] [--spec PATH] [--notes N]
  guild coverage inspect <area-id> [--date YYYY-MM-DD]
  guild coverage list [--risk high|medium|low] [--due]
  guild coverage show <area-id>"
      ;;
    *) die "guild: unknown coverage subcommand '$sub' (set|inspect|list|show)" ;;
  esac
}
