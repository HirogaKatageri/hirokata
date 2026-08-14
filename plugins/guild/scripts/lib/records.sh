# shellcheck shell=bash
#
# lib/records.sh — guild v5 Stage 2: bugs and docs as FIRST-CLASS RECORDS (design §3.2,
# §4 "New", §13 Stage 2).
#
# Two tables that already exist in schema.sql and had no writer until now:
#
#   bug   BUG-NNN, a defect. Found inside a requirement or outside one; linked to the
#         task that fixes it; closed as fixed or wontfix.
#   doc   slug-keyed, the researcher's EVERGREEN knowledge base. It survives releases
#         and board resets, `guild init` carries a v4 `.guild/docs/` tree into it, and
#         the ARCHITECT READS IT WHEN PLANNING — so this is load-bearing storage, not a
#         notes drawer.
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` (scripts/guild owns those).
# Bash 3.2 compatible: no associative arrays, no `declare -A`, no `mapfile`, no ${var^^}.
#
# Depends on lib/db.sh      : die, db_fail, db_require_init, db_exec, db_query, db_now,
#                             sql_str, sql_text, utf8_valid_file
#          on lib/journal.sh : journal_preflight, journal_append
#          on lib/artifacts.sh : _art_actor, _art_created_expr (the --date rule),
#                             _art_defuse_body / _art_defuse_lines (the neutralizer),
#                             _art_create_run / _art_update_run (the OK|/MISS| protocol),
#                             _art_json_row, _art_tmpfile, _art_first_line
#          on lib/render.sh  : _render_flat, _render_flat_arg, _render_col,
#                             _render_yaml_dq, _render_yaml_scalar
#          on lib/init.sh    : _init_read_body (the verbatim --file slurp)
#
# THOSE DEPENDENCIES ARE DELIBERATE REUSE, NOT CONVENIENCE. Stage 1 spent four
# review rounds arriving at exactly one answer per problem — one --date rule, one
# neutralizer, one flattener, one YAML escaper — and every one of those answers exists
# because a second, divergent copy of it was the bug. A local reimplementation here
# would be that second copy. Every module is sourced before any command runs, so the
# call order is not a concern.
#
# ---------------------------------------------------------------------------------
# HARD RULES honored throughout (§2.2, §2.2.1, §3.0), each with its local consequence:
#
#   * ONE db_exec PER LOGICAL COMMAND. Every command below composes a single SQL script
#     — insert/update, the diagnostic MISS selects, and the `event` row — and runs it
#     once. Never a loop of db_exec calls: in cloud mode each one is a network trip.
#
#   * sql_text FOR ALL FREE TEXT; sql_str ONLY for known-safe alphabets. Titles, bodies,
#     repro steps, doc bodies, sources, search queries, --found-by, --date and every ID
#     that arrives as unvalidated argv travel as `CAST(x'…' AS TEXT)`, because tursodb's
#     script splitter ends a statement at a `;` that TERMINATES A LINE even inside an
#     open string literal — and a bug's repro steps or a doc's body is the likeliest
#     carrier of a fenced code block in the whole guild. sql_str is used only for values
#     this file generated (timestamps, table names) or validated against a fixed set (a
#     severity checked against _rec_severities, a status against _rec_statuses, a slug
#     against _rec_check_slug's alphabet).
#
#   * A VALUE MUST NEVER BE ABLE TO IMPERSONATE A STRUCTURAL TOKEN. Applied per surface,
#     with the mechanism chosen by what that surface's structure is — the discipline
#     lib/render.sh established, not a second one:
#       · `bug list` / `doc list` / `doc search` are COLUMNAR (awk-filterable), so every
#         leading column is `_render_col` (no blank can survive inside a field) and the
#         one free-text column, the title, is `_render_flat` and comes LAST on the line.
#         Fixed field count, one record per line, always.
#       · `bug show` is a DOCUMENT with `---` fences and `## ` headings, so the body and
#         the repro are NEUTRALIZED AT WRITE TIME (_rec_defuse_body) — the same two-space
#         indent `_art_defuse_body` uses, extended to this document's own headings.
#       · `doc get` prints the body VERBATIM and emits no structure at all, which is why
#         a doc body is the one free-text value here that is neither flattened nor
#         defused. See the comment on cmd_doc_get; that is a design choice with a reason,
#         not an omission.
#       · `bug new`'s `<ID> <title>` echo is flattened, so the line cannot become two.
#
#   * EVERY MUTATION IS JOURNALED AND EMITS AN `event` ROW. `guild brief` and the
#     dashboard's activity feed are both built on `event`; a mutation that records none
#     is invisible to Stage 2's entire reason for existing. journal_preflight runs
#     BEFORE any SQL, so an unwritable or conflict-marked journal is a refusal that says
#     nothing was written rather than a board change `guild rebuild` silently undoes.
#
#   * NO full-text index, no WITH RECURSIVE, no generated columns, none of the five
#     banned window functions. `doc search` is `LIKE` — see _rec_like_pattern for the
#     metacharacter escaping and why the alternative is unavailable here.

# ---- vocabularies ------------------------------------------------------------------
#
# Both are closed sets, and that is what lets a validated value reach SQL through
# sql_str instead of sql_text. Validation is also the better error: an unknown severity
# is a typo far more often than it is a deliberate filter for nothing, and v4's "accept
# any word and match nothing" answer left the caller staring at empty output.

# _rec_severities — the bug severity vocabulary (design §3.2: critical | major | minor).
# `review_finding.severity` additionally allows `nit`; a bug is not a nit, so this set is
# deliberately the shorter one.
_rec_severities() {
  printf 'critical major minor\n'
}

# _rec_statuses — the bug status vocabulary. `open` on creation, `fixing` once a fix task
# is linked, then `fixed` or `wontfix`.
_rec_statuses() {
  printf 'open fixing fixed wontfix\n'
}

# _rec_in_set <value> <set...> — 0 when <value> is one of the remaining words.
_rec_in_set() {
  local v="${1-}" w
  shift
  for w in "$@"; do
    [ "$w" = "$v" ] || continue
    return 0
  done
  return 1
}

# _rec_check_severity <value> — die unless the value is a known severity.
_rec_check_severity() {
  local set
  set="$(_rec_severities)"
  # Unquoted on purpose: the set is a space-separated word list this file wrote.
  # shellcheck disable=SC2086
  _rec_in_set "${1-}" $set ||
    die "guild: unknown severity '${1-}' (allowed: $set)"
}

# _rec_check_status <value> — die unless the value is a known bug status.
_rec_check_status() {
  local set
  set="$(_rec_statuses)"
  # shellcheck disable=SC2086
  _rec_in_set "${1-}" $set ||
    die "guild: unknown bug status '${1-}' (allowed: $set)"
}

# ---- identifiers -------------------------------------------------------------------

# _rec_check_bug_id <ID> — prefix-check a BUG id, in the shape art_kind_of_id checks the
# other three. It is a PREFIX check and nothing more, so the value is still argv free
# text everywhere it reaches SQL (§2.2.1).
_rec_check_bug_id() {
  case "${1-}" in
    BUG-*) return 0 ;;
    '') die "guild: this command requires a BUG id" ;;
    *) die "guild: unrecognized id '${1-}' (expected BUG-NNN)" ;;
  esac
}

# _rec_check_task_id <ID> — the same, for the `--task` a fix links to.
_rec_check_task_id() {
  case "${1-}" in
    TASK-*) return 0 ;;
    '') die "guild: bug fix requires --task TASK-NNN" ;;
    *) die "guild: unrecognized id '${1-}' (expected TASK-NNN)" ;;
  esac
}

# _rec_check_req_id <ID> — the same, for the optional `--req`.
_rec_check_req_id() {
  case "${1-}" in
    REQ-*) return 0 ;;
    *) die "guild: unrecognized id '${1-}' (expected REQ-NNN)" ;;
  esac
}

# _rec_check_slug <slug> — a doc slug must be a filename-shaped token.
#
# THE SLUG IS THE ONE FREE-TEXT-LOOKING VALUE HERE THAT IS VALIDATED RATHER THAN
# ESCAPED, and there are three reasons, in increasing order of importance:
#
#   1. It is a KEY. `guild doc get <slug>` has to reproduce it exactly, and a key a human
#      cannot retype is not a key. `guild init`'s carry-over already generates slugs from
#      [a-z0-9-] (_init_slug), so this alphabet is a superset of what is already stored.
#   2. It is a COLUMN on two columnar surfaces (`doc list`, `doc search`) and the
#      `subject_id` of every doc event. Validation is what keeps those fields whitespace-
#      free at the SOURCE, rather than relying on `_render_col` to repair them on the way
#      out. Both defences are in place; this is the one that also keeps the key readable.
#   3. Rejecting is honest. Slugifying silently — the obvious alternative — means
#      `doc put 'My Notes'` stores `my-notes` and the next `doc get 'My Notes'` reports
#      not-found, which reads as data loss.
#
# A leading `-` is refused so a mistyped flag (`guild doc get --title`) is reported as a
# bad slug rather than looked up as one. The 120-character cap keeps a slug a key rather
# than a paragraph; _init_slug caps at 60, so nothing carried over can hit it.
#
# `local LC_ALL=C` IS LORE-BEARING, NOT DECORATION, and without it this check was
# LOCALE-DEPENDENT. `A-Za-z` in a bash bracket expression is a COLLATION range, not a
# byte range, so under the ordinary `LANG=en_US.UTF-8` an accented letter collates
# INSIDE `a-z` and `*[!A-Za-z0-9._-]*` does not match it — `guild doc put café` was
# accepted on a developer's machine and refused under `LC_ALL=C` in CI, from the same
# journal. That is the §2.2.1 failure mode wearing a different hat: a value whose
# legality depends on the environment produces two different boards from one file that
# git carries. (Whitespace, punctuation and emoji never leaked — they collate outside
# `a-z` — so the escape was letters only, which is precisely why it went unnoticed.)
#
# It also has to hold for the reason `cmd_doc_put` states: the slug is the ONE value in
# this module emitted through `sql_str` rather than `sql_text`, and the justification for
# that is "it passed _rec_check_slug's alphabet". An alphabet that is only enforced in
# some locales is not an alphabet. `_init_slug` — the GENERATOR this validator is meant
# to be a superset of — is `LC_ALL=C` at every one of its four stages; the validator is
# now too.
#
# THE TWO OPTIONAL ARGUMENTS ARE NOUNS, NOT BEHAVIOR. Stage 2b gave `coverage` a writer
# (lib/quality.sh) whose area id is a key for all three of the reasons above, so it needs
# THIS alphabet and not a near-copy of it — a second bracket expression is exactly the
# divergence this function's own comment is about, and it would be the one that decides
# whether `guild init`'s carried-over `checkout` and a strategist's `checkout` are the
# same row. What differs between the two callers is only what to CALL the thing and which
# flag holds its human-readable form, so those are parameters and the check is not.
_rec_check_slug() {
  local slug="${1-}" noun="${2:-doc slug}" human="${3:---title}"
  local LC_ALL=C
  [ -n "$slug" ] || die "guild: this command requires a $noun"
  case "$slug" in
    -*)
      die "guild: '$slug' is not a $noun (it starts with '-'; did you mean a flag?)"
      ;;
    *[!A-Za-z0-9._-]*)
      die "guild: '$slug' is not a valid $noun.

It is a key you retype, so it is limited to letters, digits, '.', '_' and '-'.
Rename it — 'sveltekit-form-actions', 'auth-token-refresh' — and put the human-readable
form in $human, which takes any text at all."
      ;;
  esac
  [ "${#slug}" -le 120 ] ||
    die "guild: that $noun is ${#slug} characters; the limit is 120 (put the long form in $human)"
}

# ---- row projections ---------------------------------------------------------------

# THERE IS NO `_rec_json_row`. `bug` and `doc` are two more cases of `_art_json_row`
# (lib/artifacts.sh), which is the ONE registry of "what does a journal line for table X
# contain". The projection must stay full and in schema order, because the journal is a
# change log of RESULTING ROW STATE (§2.3) and `guild rebuild` re-inserts every column
# from it — so a projection that goes stale silently drops a column on replay, and a
# second registry is exactly how one goes stale while the other does not. json_object
# preserves types and NULLs, which the STRICT tables demand.

# _rec_next_bug_id — SQL producing the next 'BUG-NNN' (§3.3). Used INSIDE the insert so
# the derivation and the write are one statement: there is no read-then-write race and
# no counter to maintain. substr(id,5) is the numeric part of 'BUG-001'.
_rec_next_bug_id() {
  printf "'BUG-' || printf('%%03d', COALESCE((SELECT MAX(CAST(substr(id,5) AS INTEGER)) FROM bug),0) + 1)"
}

# THERE IS NO `_rec_actor`. Who a mutation is attributed to is `_art_actor` (lib/
# artifacts.sh) — `${GUILD_ACTOR:-orchestrator}` — and this module had a byte-identical
# copy of it under a second name. Two spellings of one answer is the shape every rule in
# the header warns about: the day the default changes, one of them changes.

# _rec_bug_created_event <now-literal> <actor-literal> — the `created` event for the bug
# inserted EARLIER IN THE SAME SCRIPT.
#
# The script is composed before the ID exists, so the event cannot name it directly. It
# finds it instead: run right after the insert, the highest BUG id IS the row just
# written (new = max + 1, single writer per §2.4). This is _art_created_event_sql's
# mechanism, re-expressed rather than called because that function resolves its prefix
# through art_prefix, which knows req/task/plan and dies on anything else.
#
# BOTH GUARDS ARE KEPT, because the obvious one is not enough on its own. `updated_at`
# must equal this invocation's timestamp, so an insert that selected no rows (a `--req`
# that does not exist) cannot stamp an event on somebody else's bug — but db_now has
# second resolution and a scripted burst puts several rows in the same second. The second
# guard is exact rather than probabilistic: a genuinely new ID cannot already have been
# announced, so a failed create finds its predecessor already announced and writes
# nothing at all.
_rec_bug_created_event() {
  local nowlit="${1-}" actorlit="${2-}"
  printf "INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT %s, %s, 'created', 'bug', id, json_object('severity', severity, 'requirement_id', requirement_id)
FROM bug
WHERE id = (SELECT 'BUG-' || printf('%%03d', MAX(CAST(substr(id,5) AS INTEGER))) FROM bug)
  AND updated_at = %s
  AND NOT EXISTS (SELECT 1 FROM event e
                   WHERE e.verb = 'created'
                     AND e.subject_type = 'bug'
                     AND e.subject_id = bug.id);
" "$nowlit" "$actorlit" "$nowlit"
}

# ---- neutralizing free text for `bug show` -----------------------------------------

# _rec_defuse_body <text> — indent any line that IS a line `guild bug show` GENERATES.
#
# `bug show` reconstructs a document out of columns: a `---` frontmatter fence, then
# `## Details` and `## Reproduction` sections holding `body` and `repro`. Both of those
# are free text — `--body`, `--repro`, and (for a bug filed by an agent) text that agent
# composed — so without this, a repro step reading
#
#   ---
#   severity: critical
#
# closes the frontmatter as far as any reader that splits on the fence is concerned, and
# everything after it is attacker-authored; and a body carrying its own `## Reproduction`
# heading makes the rendered document contain two, where a "first heading wins" reader
# takes the forged one.
#
# Refusing is not available here the way `_art_body_or` refuses a whole `--body` document:
# a bug report is prose, and prose about a bug in a markdown renderer legitimately quotes
# `---`. So this NEUTRALIZES instead, with the same two-space indent and for the same
# stated reason as `_art_defuse_body` — CommonMark still reads `  ## X` as a heading and
# `  ---` as a thematic break (up to three leading spaces are insignificant), while the
# `^## ` and `^---$` parsers that every consumer of these documents actually is no longer
# match.
#
# It DELEGATES the shared half to `_art_defuse_body` (`---`, `## Work Log`,
# `## Follow-up Tasks`) and adds only this document's own two headings. One mechanism,
# two heading lists — not two mechanisms.
#
# The indenting loop itself is `_art_defuse_lines` (lib/artifacts.sh), not a copy of it.
# This is the ONE mechanism handed a second heading list, which is exactly the shape that
# helper takes; see its comment for the bash 3.2 rescanning subtlety it has to handle.
_rec_defuse_body() {
  _art_defuse_lines "$(_art_defuse_body "${1-}")" '## Details' '## Reproduction'
}

# THERE IS NO `_rec_flat_arg`. The `<BUG-ID> <title>` line `bug new` echoes back is
# flattened by `_render_flat_arg` (lib/render.sh) — the shell-side twin of `_render_flat`,
# which is where that rule already lives. This module and lib/direction.sh each grew a
# private, byte-identical copy of it under a different name.
#
# The reasoning it carried is now stated once, at the shared definition: the title this
# process just stored IS the title it holds, so a round trip to read it back would answer
# with the same bytes; and that line's structure is "an id, a space, the rest", so a title
# containing a newline would print a second line that a caller reading the output as a
# record list takes for another bug.

# ---- verbatim output ----------------------------------------------------------------

# _rec_emit_body <file> — print a one-value result BYTE FOR BYTE: drop the leading
# existence-marker line and the ONE newline the driver appends after the value.
#
# THIS IS WHY `doc get` ROUND-TRIPS AND `tail -n +2` WOULD NOT. `-m list` terminates
# every row with exactly one LF — verified byte for byte on tursodb 0.7.2 against a value
# with no trailing newline (`abc` → `abc\n`), one (`abc\n` → `abc\n\n`), two, and the
# empty string (`` → `\n`). That terminator is the driver's, not the document's, so
# printing the raw tail hands back a body one newline longer than the one that was
# stored. Harmless once; the researcher's actual workflow is a CYCLE —
#
#   guild doc get notes > notes.md   # edit it   # guild doc put notes --file notes.md
#
# — and a byte the read adds and the write keeps is a blank line PER CYCLE, forever.
# `_init_read_body` exists for the mirror-image reason on the way in (command
# substitution strips trailing newlines at the call site); this is the same guarantee
# honored on the way out.
#
# Because the terminator is exactly one byte in every case, dropping exactly one byte is
# exact in every case, INCLUDING an empty body (3 bytes in, nothing out) and a body that
# genuinely ends in a newline. The marker line is exactly `E` + LF, hence the 2-byte
# offset and the 3-byte total.
#
# Byte offsets, not line counts: a line-oriented tool cannot express "the value did not
# end in a newline", which is the very distinction being preserved. `tail -c +N` and
# `head -c N` are BSD and GNU both; neither is a new dependency.
_rec_emit_body() {
  local f="${1-}" n
  n="$(LC_ALL=C wc -c <"$f" 2>/dev/null | LC_ALL=C tr -d ' ')"
  case "$n" in
    '' | *[!0-9]*) return 0 ;;
  esac
  [ "$n" -gt 3 ] || return 0
  LC_ALL=C tail -c "+3" "$f" | LC_ALL=C head -c "$((n - 3))"
}

# ---- the LIKE search (§3.0: there is no full-text index on TursoDB) ----------------

# _rec_like_pattern <sql-text-literal> — a `%…%` LIKE pattern with the user's query
# escaped so its METACHARACTERS ARE LITERAL.
#
# THE PROBLEM. `LIKE` gives `%` and `_` meaning. Left alone, a search for `100%` matches
# every doc in the base (`%100%%` is "…100 then anything"), and a search for `a_b`
# quietly also matches `axb`. Both are wrong answers reported as results, which is worse
# than an error: the researcher's knowledge base is exactly where a silently over-broad
# answer gets believed.
#
# THE ESCAPING, and the order, which is load-bearing:
#
#   lower(q)  ->  replace \  with \\      the escape character itself, FIRST, so that no
#                                          escape introduced below is escaped again
#             ->  replace %  with \%      the wildcard
#             ->  replace _  with \_      the single-character wildcard
#   pattern   =   '%' || <that> || '%'
#   predicate =   lower(<column>) LIKE <pattern> ESCAPE '\'
#
# Doing it in SQL rather than in the shell is deliberate on two counts: the query reaches
# the engine as hex (sql_text) and is never re-quoted, and `replace()` is O(n) where the
# bash equivalent `${q//%/\\%}` is quadratic under 3.2 (rule 4).
#
# `ESCAPE '\'` is VERIFIED against tursodb 0.7.2, not assumed — `'100% off'` matched by
# `100%` and not by `100`+anything, `'a_b'` matched by `a_b` while `'axb'` was not, and a
# query containing a literal backslash (`:\pa` against `C:\path\x`) matched. A backslash
# inside a SQL string literal is just a backslash on both engines; SQLite-family string
# literals have no escape sequences of their own.
#
# CASE-INSENSITIVITY is `lower()` on BOTH sides rather than a reliance on LIKE's default,
# so the behavior does not depend on the engine's `case_sensitive_like` setting. Its one
# honest limit: `lower()` is ASCII-only, so `Ä` and `ä` are different characters to this
# search. That is SQLite-family behavior everywhere and is not something a shell CLI can
# fix without ICU.
_rec_like_pattern() {
  local e="lower(${1-})"
  e="replace($e, '\\', '\\\\')"
  e="replace($e, '%', '\\%')"
  e="replace($e, '_', '\\_')"
  printf "'%%' || %s || '%%'" "$e"
}

# _rec_like_match <column-expression> <pattern-expression> — the predicate itself.
#
# The escape character is passed as an ARGUMENT rather than written into the format
# string, and that is not style. `printf "… ESCAPE '\\'"` looks right and is not: bash
# collapses `\\` to `\` while parsing the double-quoted word, printf then reads the
# lone `\` as the start of an escape sequence and DROPS IT — the emitted clause is
# `ESCAPE ''`, which tursodb rejects. Measured, not reasoned about. `%s` never
# reinterprets its argument.
_rec_like_match() {
  local bs
  bs="\\"
  printf "lower(%s) LIKE %s ESCAPE '%s'" "${1-}" "${2-}" "$bs"
}

# ---- flag parsing ------------------------------------------------------------------

# _rec_parse_flags <args...> — the flag set for every command in this module.
#
# Sets rec_title rec_body rec_repro rec_severity rec_req rec_found rec_date rec_task
# rec_file rec_source rec_wontfix, always resetting them first so a second call cannot
# inherit the first one's values. `--wontfix` is a BOOLEAN and consumes no value; every
# other flag takes one. Unknown `--flags` consume their value and are ignored, and bare
# words are collected into rec_rest — the shape `_art_parse_flags` established, plus the
# positional capture these commands need (`bug list [status]`, `doc put <slug>`).
_rec_parse_flags() {
  rec_title=""
  rec_body=""
  rec_body_set=0
  rec_repro=""
  rec_severity=""
  rec_req=""
  rec_found=""
  rec_date=""
  rec_task=""
  rec_file=""
  rec_source=""
  rec_wontfix=0
  rec_rest=""
  rec_rest_n=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --title) shift; rec_title="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --body) shift; rec_body="${1-}"; rec_body_set=1; if [ $# -gt 0 ]; then shift; fi ;;
      --repro) shift; rec_repro="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --severity) shift; rec_severity="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --req) shift; rec_req="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --found-by) shift; rec_found="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --date) shift; rec_date="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --task) shift; rec_task="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --file) shift; rec_file="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --source) shift; rec_source="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --wontfix) rec_wontfix=1; shift ;;
      --*) shift; if [ $# -gt 0 ]; then shift; fi ;;
      *)
        rec_rest_n=$((rec_rest_n + 1))
        if [ "$rec_rest_n" = 1 ]; then rec_rest="$1"; fi
        shift
        ;;
    esac
  done
}

# ---- bug: create -------------------------------------------------------------------

# cmd_bug_new --title T [--body B] [--repro R] [--severity S] [--req REQ-NNN]
#             [--found-by WHO] [--date YYYY-MM-DD]
#
# Prints "<BUG-ID> <title>" — the id first so `${out%% *}` takes it, the flattened title
# after so the line is also readable in a check-in transcript.
#
# `--req` IS OPTIONAL AND THAT IS THE POINT. Bugs are found outside a requirement's scope
# all the time — during a QA pass, in production, by a reviewer reading unrelated code —
# and a defect tracker that cannot record one until somebody invents a requirement for it
# is a defect tracker people route around. With `--req` the reference is checked by
# JOINING it in, so a bad REQ id inserts nothing and reports which reference was missing
# instead of tripping a raw foreign-key error; without it the insert has no FROM clause at
# all (a SELECT with no FROM returns exactly one row — verified on tursodb 0.7.2).
cmd_bug_new() {
  local now nowlit actorlit created idexpr rowexpr body repro sev sql result id row
  local from misses reqexpr foundexpr
  _rec_parse_flags "$@"
  [ -n "$rec_title" ] || die "guild: bug new requires --title"
  sev="${rec_severity:-major}"
  _rec_check_severity "$sev"
  [ -z "$rec_req" ] || _rec_check_req_id "$rec_req"

  db_require_init
  journal_preflight

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  created="$(_art_created_expr "$rec_date" "$nowlit")"
  idexpr="$(_rec_next_bug_id)"
  rowexpr="$(_art_json_row bug)"

  # Neutralized before storage, not on the way out: `bug show` renders both of these into
  # a fenced, sectioned document, and the stored value is what a later reader sees.
  body="$(_rec_defuse_body "$rec_body")"
  repro="$(_rec_defuse_body "$rec_repro")"

  # An omitted --found-by is NULL, not '' — the column is nullable and `null` is what
  # `bug show` prints for "nobody recorded this".
  foundexpr="NULLIF($(sql_text "$rec_found" '--found-by'),'')"

  from=""
  reqexpr="NULL"
  misses=""
  if [ -n "$rec_req" ]; then
    from="FROM requirement r WHERE r.id = $(sql_text "$rec_req" '--req')"
    reqexpr="r.id"
    # The id is flattened inside the diagnostic: it is unvalidated argv beyond its
    # prefix, and this line's structure is the tag plus the whole rest of the line.
    misses="SELECT 'MISS|' || $(_render_flat "$(sql_text "$rec_req" '--req')")
  WHERE NOT EXISTS (SELECT 1 FROM requirement WHERE id = $(sql_text "$rec_req" '--req'));
"
  fi

  sql="BEGIN;
INSERT INTO bug (id, title, body, repro, severity, status, found_by,
                 requirement_id, created_at, updated_at)
SELECT $idexpr, $(sql_text "$rec_title" '--title'), $(sql_text "$body" '--body'),
       $(sql_text "$repro" '--repro'), $(sql_str "$sev"), 'open', $foundexpr,
       $reqexpr, $created, $nowlit
$from
RETURNING 'OK|' || id || '|' || $rowexpr;
$misses
$(_rec_bug_created_event "$nowlit" "$actorlit")
COMMIT;
"

  # `_art_create_run` is the shared parser for the `OK|<id>|<row-json>` + `MISS|<ref>`
  # protocol every create in this CLI speaks — including the part that is easy to get
  # wrong and was, for two review rounds: RELAYING the driver's diagnostics, which
  # tursodb writes to STDOUT where this call site captures them as data. A second copy
  # of that parser would be a second place for that to regress.
  result="$(_art_create_run 'the bug' "$sql")" || exit 1
  id="${result%% *}"
  row="${result#* }"

  journal_append bug upsert "$row"
  printf '%s %s\n' "$id" "$(_render_flat_arg "$rec_title")"
}

# ---- bug: status transitions --------------------------------------------------------

# _rec_bug_update <BUG-ID> <status-literal> <extra-set> <verb> <payload-extra> <label>
#                 <task-literal-or-empty>
#
# The one UPDATE shape `bug fix` and `bug close` share: write the event FIRST (so its
# payload can carry BOTH ends of the transition — after the update, `status` is only the
# destination), then update and let RETURNING yield the resulting row for the journal.
# Same ordering, and same reason, as `cmd_move` and `cmd_retitle`.
#
# When <task-literal-or-empty> is non-empty the transition is ALSO conditional on that
# task existing, and a MISS line names it. Linking a fix to a task that is not on the
# board would put a dangling `fix_task_id` in front of the dashboard's "Bugs → linked to
# fix tasks" view, which is the one thing that view is for.
#
# The `OK|<row-json>` / `MISS|<ref>` / nothing protocol is parsed by `_art_update_run`
# (lib/artifacts.sh), which lib/direction.sh's four mutating commands use too. This
# function arrived with its own copy of that parser, over a marker that additionally
# carried the id — so it had to strip a variable middle field back off with `${row#*|}`,
# which is the quadratic expansion rule 4 forbids and is bounded here only because the
# delimiter happens to land near the start of the line. The marker now carries the row
# and nothing else, and the strip is a fixed literal prefix.
_rec_bug_update() {
  local id="${1-}" statuslit="${2-}" extra="${3-}" verb="${4-}" payextra="${5-}"
  local label="${6-}" tasklit="${7-}"
  local idlit now nowlit actorlit rowexpr sql row guard misses

  db_require_init
  journal_preflight

  idlit="$(sql_text "$id" 'the BUG id')"
  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  rowexpr="$(_art_json_row bug)"

  guard=""
  misses=""
  if [ -n "$tasklit" ]; then
    guard="
  AND EXISTS (SELECT 1 FROM task WHERE id = $tasklit)"
    misses="SELECT 'MISS|' || $(_render_flat "$tasklit")
  WHERE NOT EXISTS (SELECT 1 FROM task WHERE id = $tasklit);
"
  fi

  sql="BEGIN;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $actorlit, $(sql_str "$verb"), 'bug', id,
       json_object('from', status, 'to', $statuslit$payextra)
FROM bug WHERE id = $idlit$guard;
UPDATE bug SET status = $statuslit,$extra
    updated_at = $nowlit
WHERE id = $idlit$guard
RETURNING 'OK|' || $rowexpr;
$misses
COMMIT;
"
  # A MISS line names the reference that was not there (the --task); with no MISS, the
  # bug itself is the thing that does not exist. Both are `_art_update_run`'s job.
  row="$(_art_update_run "$id" "$label $id" "$sql")" || exit 1

  journal_append bug upsert "$row"
  printf '%s\n' "$id"
}

# cmd_bug_fix <BUG-ID> --task TASK-NNN — link the fix task and move the bug to `fixing`.
# Prints the BUG id.
#
# This is the join that makes the dashboard's bug view worth having: a defect with a
# named, trackable piece of work against it, rather than a list of complaints. The task
# is NOT created here — the orchestrator files it (`guild new task`) and links it, which
# keeps the "orchestrator owns every transition" rule intact.
cmd_bug_fix() {
  local id="${1-}" tasklit
  _rec_check_bug_id "$id"
  shift
  _rec_parse_flags "$@"
  # `bug fix BUG-001 TASK-004` is the shape a hurried caller reaches for; accept it.
  [ -n "$rec_task" ] || rec_task="$rec_rest"
  _rec_check_task_id "$rec_task"
  tasklit="$(sql_text "$rec_task" '--task')"

  _rec_bug_update "$id" "'fixing'" " fix_task_id = $tasklit," 'moved' \
    ", 'fix_task_id', $tasklit" 'link a fix task to' "$tasklit"
}

# cmd_bug_close <BUG-ID> [--wontfix] — close the bug as `fixed`, or as `wontfix`.
# Prints the BUG id.
#
# `wontfix` is a real outcome, not a lesser `fixed`: "we looked, and we are choosing not
# to" is the answer a triage pass most needs to be able to record, and collapsing it into
# `fixed` would make the coverage question ("what is still actually broken?") unanswerable
# from the board. The two statuses are separate rows in every count.
cmd_bug_close() {
  local id="${1-}" statuslit
  _rec_check_bug_id "$id"
  shift
  _rec_parse_flags "$@"
  if [ "$rec_wontfix" = 1 ]; then statuslit="'wontfix'"; else statuslit="'fixed'"; fi

  _rec_bug_update "$id" "$statuslit" "" 'moved' "" 'close' ""
}

# ---- bug: read ----------------------------------------------------------------------

# cmd_bug_list [status] [--severity S] — "<BUG-ID> <status> <severity> <req> <title>".
#
# COLUMNAR, and shaped by the same finding that shaped `guild list task`: this output is
# ROWS with WHITESPACE-SEPARATED FIELDS, and callers filter it with awk
# (`awk '$3 == "critical"'`). So the four leading columns go through `_render_col`, which
# leaves no blank inside a field — the row count is then always the bug count AND the
# field count is always the column count, whatever a title or a requirement id contains.
#
# The title is `_render_flat` and comes LAST. Last is what makes it safe to keep its
# spaces: nothing follows it, so it can shift no field and forge no column. It cannot
# span lines, so it can forge no row either. The byte-exact title is one round trip away
# in `guild bug show`.
#
# `<req>` prints `null` for a bug filed outside any requirement, matching the `plan: null`
# convention `guild meta` already uses for an absent reference.
#
# BOTH FILTERS ARE VALIDATED, unlike `guild list`'s status. v4's silent "accept any word
# and match nothing" was defensible for a surface with no closed vocabulary; `open |
# fixing | fixed | wontfix` and `critical | major | minor` are closed and small, so a typo
# is a typo and saying so beats printing nothing. Validation is also what lets both reach
# SQL through sql_str.
cmd_bug_list() {
  local status severity cols where
  _rec_parse_flags "$@"
  status="$rec_rest"
  severity="$rec_severity"
  [ -z "$status" ] || _rec_check_status "$status"
  [ -z "$severity" ] || _rec_check_severity "$severity"
  db_require_init

  cols="$(_render_col 'id') || ' ' || $(_render_col 'status')"
  cols="$cols || ' ' || $(_render_col 'severity')"
  cols="$cols || ' ' || $(_render_col "COALESCE(requirement_id,'null')")"
  cols="$cols || ' ' || $(_render_flat 'title')"

  where=""
  [ -z "$status" ] || where=" WHERE status = $(sql_str "$status")"
  if [ -n "$severity" ]; then
    if [ -z "$where" ]; then where=" WHERE"; else where="$where AND"; fi
    where="$where severity = $(sql_str "$severity")"
  fi

  printf 'SELECT %s FROM bug%s ORDER BY id;\n' "$cols" "$where" | db_query
}

# cmd_bug_show <BUG-ID> — render the bug as markdown, in the shape `guild read` renders
# the other artifacts: a `---` frontmatter block, a blank line, then the document.
#
# The frontmatter is YAML and every skill parses it, so it goes through the same two
# helpers `guild meta` uses: `_render_yaml_dq` for the title (always quoted, always
# escaped — a Windows path in a bug title is ordinary input, not an attack) and
# `_render_yaml_scalar` for the ids, the enums and the date, which quotes only when the
# value is not already a safe plain scalar and therefore keeps the benign output
# byte-identical to the rest of the CLI's.
#
# Every optional reference prints `null` rather than vanishing, so the block has a fixed
# set of keys and a parser never has to ask whether a field is missing or empty.
#
# The two sections always appear, with a placeholder when empty, for the same reason: a
# reader looking for reproduction steps gets an explicit "none recorded" instead of
# silence. Their contents were neutralized at write time (_rec_defuse_body).
#
# ONE statement, guarded on the row existing, so a missing id produces NO output at all
# and the caller reports v4's `guild: <ID> not found`.
cmd_bug_show() {
  local id="${1-}" idlit sql tmp out
  _rec_check_bug_id "$id"
  db_require_init
  idlit="$(sql_text "$id" 'the BUG id')"

  sql="SELECT '---
id: ' || $(_render_yaml_scalar "$(_render_flat 'id')") || '
title: ' || $(_render_yaml_dq "$(_render_flat 'title')") || '
severity: ' || $(_render_yaml_scalar "$(_render_flat 'severity')") || '
status: ' || $(_render_yaml_scalar "$(_render_flat 'status')") || '
requirement: ' || $(_render_yaml_scalar "$(_render_flat "COALESCE(requirement_id,'null')")") || '
fix-task: ' || $(_render_yaml_scalar "$(_render_flat "COALESCE(fix_task_id,'null')")") || '
found-by: ' || $(_render_yaml_scalar "$(_render_flat "COALESCE(found_by,'null')")") || '
created: ' || $(_render_yaml_scalar "$(_render_flat 'substr(created_at,1,10)')") || '
updated: ' || $(_render_yaml_scalar "$(_render_flat 'substr(updated_at,1,10)')") || '
---

# ' || $(_render_flat 'title') || '

## Details

' || CASE WHEN trim(body) = '' THEN '_No details recorded._' ELSE body END || '

## Reproduction

' || CASE WHEN trim(repro) = '' THEN '_No reproduction steps recorded._' ELSE repro END || '
'
FROM bug WHERE id = $idlit;
"
  tmp="$(_art_tmpfile)" || exit 1
  if ! printf '%s' "$sql" | db_exec >"$tmp"; then
    out="$(cat "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    db_fail "could not read $id" "$out"
  fi
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    die "guild: $id not found"
  fi
  cat "$tmp"
  rm -f "$tmp"
}

# ---- bug: the subcommand ------------------------------------------------------------

cmd_bug() {
  local sub="${1-}"
  [ $# -eq 0 ] || shift
  case "$sub" in
    new) cmd_bug_new "$@" ;;
    list) cmd_bug_list "$@" ;;
    show) cmd_bug_show "$@" ;;
    fix) cmd_bug_fix "$@" ;;
    close) cmd_bug_close "$@" ;;
    '')
      die "guild: bug needs a subcommand

  guild bug new --title T [--body B] [--repro R] [--severity critical|major|minor]
                [--req REQ-NNN] [--found-by WHO] [--date YYYY-MM-DD]
  guild bug list [open|fixing|fixed|wontfix] [--severity critical|major|minor]
  guild bug show <BUG-ID>
  guild bug fix <BUG-ID> --task TASK-NNN
  guild bug close <BUG-ID> [--wontfix]"
      ;;
    *) die "guild: unknown bug subcommand '$sub' (new|list|show|fix|close)" ;;
  esac
}

# ---- doc: write ---------------------------------------------------------------------

# _rec_doc_body — resolve the doc body from --body or --file into `rec_body`.
#
# `--file` IS THE RESEARCHER'S ACTUAL WORKFLOW: research gets written as a file and then
# filed, and `--body "$(cat notes.md)"` loses every trailing newline to command
# substitution and mangles anything that looks like a flag. So the CLI reads the file
# itself, verbatim — `_init_read_body`'s `printf -v` out-parameter exists precisely
# because the obvious `body="$(cat f)"` strips trailing newlines AT THE CALL SITE, and
# "the body is stored verbatim" (§11) has to actually hold.
#
# THE ERROR NAMES THE FILE, NOT THE FLAG. `--file` is a path the caller typed and may
# well have several of; "guild: --file is not valid UTF-8" sends them back to re-read
# their own command line, while naming the path sends them to the file. The UTF-8 check
# is explicit here rather than left to sql_text for exactly that reason — sql_text would
# refuse correctly, but it would refuse under the label it was handed.
_rec_doc_body() {
  if [ -n "$rec_file" ]; then
    [ "$rec_body_set" = 0 ] ||
      die "guild: doc put takes --body or --file, not both"
    [ -e "$rec_file" ] ||
      die "guild: no such file: $rec_file"
    [ -f "$rec_file" ] ||
      die "guild: not a regular file: $rec_file"
    [ -r "$rec_file" ] ||
      die "guild: cannot read $rec_file (permission denied)"
    utf8_valid_file "$rec_file" ||
      die "guild: $rec_file is not valid UTF-8, so it was not stored.

The guild stores text as UTF-8; re-encode the file and re-run —

  iconv -f latin1 -t utf8 '$rec_file' > t && mv t '$rec_file'

An invalid byte would not survive the trip: free text reaches SQL as bytes cast to TEXT,
and tursodb substitutes U+FFFD where libSQL keeps the byte, so the document would be
corrupted silently and differently depending on which engine replayed the journal
(design 2.2.1)."
    _init_read_body rec_body "$rec_file"
    return 0
  fi
  [ "$rec_body_set" = 1 ] || die "guild: doc put requires --body or --file

A doc is written to be read back, and 'doc put' is an UPSERT — filing a slug with no body
would overwrite an existing document's contents with nothing. Pass the text with --body,
or the file with --file."
  return 0
}

# cmd_doc_put <slug> --title T [--body B | --file F] [--source S] — upsert a doc.
# Prints the slug.
#
# THE BODY IS STORED VERBATIM AND IS NEITHER FLATTENED NOR DEFUSED, and that is a choice
# with a reason rather than an omission. A doc is a whole markdown document — the v4
# `.guild/docs/*.md` files `guild init` carries in already contain `---` thematic breaks,
# YAML front matter of their own and fenced code blocks — and the only surface that emits
# a body is `guild doc get`, which prints it ALONE, with no frontmatter, no headings and
# no markers around it. There is no structural token in that channel for a value to
# impersonate, so neutralizing the text would corrupt real documents to defend against
# nothing. The columnar surfaces (`doc list`, `doc search`) never emit the body at all.
#
# `--source` is provenance — who or what produced this ("researcher", a URL, a path — the
# carry-over stores the file it came from). An omitted `--source` on an UPDATE keeps the
# existing one rather than clearing it (`COALESCE(NULLIF(excluded.source,''), source)`;
# a bare column reference in DO UPDATE SET is the pre-update row's value, verified on
# tursodb 0.7.2). With `--file` and no `--source` the path becomes the source, which is
# exactly what `guild init`'s carry-over records.
#
# The event's verb is chosen from whether the row existed BEFORE the upsert, which is why
# it is written first: `created` and `updated` are different entries in the activity feed,
# and "the knowledge base grew" and "a document changed under me" are different facts.
cmd_doc_put() {
  local slug="${1-}" sluglit now nowlit actorlit rowexpr srclit sql out line row
  _rec_check_slug "$slug"
  shift
  _rec_parse_flags "$@"
  [ -n "$rec_title" ] || die "guild: doc put requires --title"
  _rec_doc_body

  [ -n "$rec_source" ] || rec_source="$rec_file"

  db_require_init
  journal_preflight

  # The slug passed _rec_check_slug's alphabet, so it is a known-safe value and sql_str
  # is correct for it — it is also the one value here that must read back identically in
  # an error message, a journal line and an event's subject_id.
  sluglit="$(sql_str "$slug")"
  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  rowexpr="$(_art_json_row doc)"
  srclit="$(sql_text "$rec_source" '--source')"

  sql="BEGIN;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $actorlit,
       CASE WHEN EXISTS (SELECT 1 FROM doc WHERE slug = $sluglit) THEN 'updated' ELSE 'created' END,
       'doc', $sluglit, json_object('title', $(sql_text "$rec_title" '--title'), 'source', $srclit);
INSERT INTO doc (slug, title, body, source, updated_at)
VALUES ($sluglit, $(sql_text "$rec_title" '--title'), $(sql_text "$rec_body" "${rec_file:---body}"),
        $srclit, $nowlit)
ON CONFLICT(slug) DO UPDATE SET
  title = excluded.title,
  body = excluded.body,
  source = COALESCE(NULLIF(excluded.source,''), source),
  updated_at = excluded.updated_at
RETURNING 'OK|' || $rowexpr;
COMMIT;
"
  if ! out="$(printf '%s' "$sql" | db_exec)"; then
    db_fail "could not store the doc '$slug'" "$out"
  fi
  line="$(printf '%s' "$out" | head -n1)"
  case "$line" in
    'OK|{'*'}') ;;
    *) die "guild: could not store the doc '$slug' (unexpected database output)" ;;
  esac
  row="${line#OK|}"

  journal_append doc upsert "$row"
  printf '%s\n' "$slug"
}

# ---- doc: read ----------------------------------------------------------------------

# cmd_doc_get <slug> — print the doc's body, VERBATIM.
#
# Not a rendered document with a frontmatter block, deliberately. Two reasons, and the
# second is the one that decided it:
#
#   1. This is what the caller wants. `guild doc get sveltekit-form-actions > notes.md`
#      should reproduce the researcher's file, and the architect reading it while planning
#      wants the document, not a wrapper around it. `guild slice` prints a slice body the
#      same way for the same reason.
#   2. Wrapping it would be UNSOUND. A doc body legitimately contains `---` (a thematic
#      break, or its own YAML front matter) — the v4 files `guild init` carries in are
#      full of them — so a `---` fence around it would be closed by the content on any
#      reader that splits on the fence. The alternatives are to neutralize real documents
#      or to emit a channel that can be forged; printing the body alone has neither
#      problem, because a channel with no structural token cannot be forged.
#
# The metadata lives on the columnar surface instead: `guild doc list` prints slug,
# updated date and title.
#
# An existence marker leads the script so "no such doc" and "a doc whose body is empty"
# stay distinguishable in ONE round trip; the marker line is then dropped.
cmd_doc_get() {
  local slug="${1-}" sluglit sql tmp out
  _rec_check_slug "$slug"
  db_require_init
  sluglit="$(sql_str "$slug")"

  sql="SELECT 'E' FROM doc WHERE slug = $sluglit;
SELECT body FROM doc WHERE slug = $sluglit;
"
  tmp="$(_art_tmpfile)" || exit 1
  if ! printf '%s' "$sql" | db_exec >"$tmp"; then
    out="$(cat "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    db_fail "could not read the doc '$slug'" "$out"
  fi
  if [ "$(_art_first_line "$tmp")" != "E" ]; then
    rm -f "$tmp"
    die "guild: doc '$slug' not found (list them with 'guild doc list')"
  fi
  _rec_emit_body "$tmp"
  rm -f "$tmp"
}

# _rec_doc_columns — the one composed line `doc list` and `doc search` both print:
# "<slug> <updated> <title>".
#
# ONE definition for both, because two commands printing "the same" shape from two
# expressions is how they stop being the same shape. Same rule as `bug list`: the two
# leading columns are `_render_col` (whitespace-free, so the field count is fixed even
# for a slug that predates _rec_check_slug or was inserted directly), and the title is
# `_render_flat` and LAST.
_rec_doc_columns() {
  local cols
  cols="$(_render_col 'slug') || ' ' || $(_render_col 'substr(updated_at,1,10)')"
  cols="$cols || ' ' || $(_render_flat 'title')"
  printf '%s' "$cols"
}

# cmd_doc_list — every doc, oldest slug first. "<slug> <updated> <title>".
cmd_doc_list() {
  db_require_init
  printf 'SELECT %s FROM doc ORDER BY slug;\n' "$(_rec_doc_columns)" | db_query
}

# cmd_doc_search <query> — case-insensitive substring search over TITLE AND BODY.
# Same three columns as `doc list`, so one parser reads both.
#
# `LIKE`, NOT A FULL-TEXT INDEX. FTS5 does not exist on TursoDB (§3.0, verified: the
# `CREATE VIRTUAL TABLE … USING fts5` fails outright), and the Tantivy-backed
# `CREATE INDEX … USING fts` that replaces it is itself experimental — so an index-backed
# search would work on the cloud engine and fail on the default local one, which is the
# worst possible split. Substring matching over a knowledge base measured in dozens of
# documents costs nothing; see _rec_like_pattern for the metacharacter escaping, which is
# the part that actually needed care.
#
# The query is REQUIRED and may not be empty: an empty query escapes to `%%`, which
# matches every row, and a search that silently answers "everything" is `doc list` wearing
# a disguise.
cmd_doc_search() {
  local query="${1-}" qlit pattern where
  [ -n "$query" ] || die "guild: doc search requires a query (list them all with 'guild doc list')"
  db_require_init

  qlit="$(sql_text "$query" 'the search query')"
  pattern="$(_rec_like_pattern "$qlit")"
  where="$(_rec_like_match 'title' "$pattern") OR $(_rec_like_match 'body' "$pattern")"

  printf 'SELECT %s FROM doc WHERE %s ORDER BY slug;\n' "$(_rec_doc_columns)" "$where" | db_query
}

# ---- doc: the subcommand ------------------------------------------------------------

cmd_doc() {
  local sub="${1-}"
  [ $# -eq 0 ] || shift
  case "$sub" in
    put) cmd_doc_put "$@" ;;
    get) cmd_doc_get "$@" ;;
    list) cmd_doc_list "$@" ;;
    search) cmd_doc_search "$@" ;;
    '')
      die "guild: doc needs a subcommand

  guild doc put <slug> --title T [--body B | --file F] [--source S]
  guild doc get <slug>
  guild doc list
  guild doc search <query>"
      ;;
    *) die "guild: unknown doc subcommand '$sub' (put|get|list|search)" ;;
  esac
}
