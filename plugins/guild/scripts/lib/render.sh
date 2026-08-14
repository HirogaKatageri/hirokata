# shellcheck shell=bash
#
# lib/render.sh — rendering: the live board and the export (markdown + JSON).
#
# Design doc §2.3 (the export) and the v4 board format (v4 `cmd_board`, mirrored in
# skills/check-in/SKILL.md Step 2).
#
# NOT here: rendering ONE artifact as markdown. `guild read` is lib/artifacts.sh's
# `cmd_read`, which reproduces the v4 document byte for byte and shares its frontmatter
# projection with `guild meta`. This module carried a second, divergent renderer
# (full ISO timestamps in `created:`, a different work-log line shape, an extra
# `## Review Findings` section); it is gone rather than reconciled, because two
# renderings of the same row is the bug, not the formatting.
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` — scripts/guild owns those.
# Depends on lib/db.sh: db_query, die, db_fail, db_require_init, GUILD_DIR.
#
# Bash 3.2 compatible: no associative arrays, no `declare -A`, no `mapfile`,
# no `${var^^}`.
#
# ---------------------------------------------------------------------------------
# HARD RULE (§2.2): ONE db_query per logical command. Every function below composes a
# single SQL script — several statements, or one compound SELECT — and runs it once.
# In cloud mode each invocation is a network round trip.
#
# PORTABILITY (§3.0): STRICT tables, RETURNING, plain (non-RECURSIVE) CTEs, JSON
# functions and printf() are fair game. FTS5, WITH RECURSIVE, generated columns and
# the lag/lead/ntile/percent_rank/cume_dist window functions are NOT used here.
#
# PARSING (§2.2) — THE OUTPUT-CHANNEL RULE. `-m list` output is pipe-separated, and
# titles / bodies / log entries are free text that can contain pipes AND NEWLINES.
# Pipes are handled by selecting exactly ONE column in every query here, so the driver
# never inserts a separator. Newlines are the dangerous half: a value that spans lines
# can impersonate any structural token the reader recognizes in-band — a leading section
# digit, a `@@MARKER@@` line. Both were live injections (a title `evil\n3   TASK-999: X`
# fabricated a board row; a body carrying `@@GUILD-EXPORT@@ FILE REQ-666` created a
# phantom export file and truncated the real one).
#
# The rule is therefore: A VALUE MUST NEVER BE ABLE TO IMPERSONATE A STRUCTURAL TOKEN,
# and that is enforced at the source, not with a smarter regex. Two mechanisms, chosen
# per surface by whether the value is allowed to be multi-line at all:
#
#   * BOARD — `_render_flat` wraps every free-text expression in `replace()` so CR and
#     LF are gone before the value leaves the engine. Each row is then exactly one
#     output line, and no attacker text can ever sit at the start of a line. Untagged
#     lines are dropped, not folded: with flattening there is nothing legitimate to fold.
#
#   * EXPORT — the body must keep its newlines, so instead the transport is made
#     unambiguous with a LENGTH PREFIX. Each row is emitted as a header line
#     `@@GUILD-EXPORT@@ <lines> <REQ-ID>` followed by exactly `<lines>` lines of value.
#     awk consumes those lines by COUNT, never by inspection, so content is never
#     examined for structure and cannot be mistaken for a header. The count is computed
#     in SQL from the very string that is emitted (`length` minus `length(replace(…))`).
#
#     THE HEADER'S OWN FIELDS ARE PART OF THE HEADER, and the id is one of them: an
#     unflattened `req` split the header line in two, the reader's id regex saw only the
#     first half and passed, and every following line was off by one — reproduced as a
#     phantom `REQ-666.md` plus the SILENT LOSS of the real requirement, exit 0. So the
#     id is flattened like every other structural field. Flattening does not merely
#     shorten the attack: a newline anywhere in an id turns into a space, the reader's
#     `^REQ-[A-Za-z0-9_.-]+$` rejects a space, and the whole export fails closed with a
#     message rather than writing a file under a forged name.
#
# `export_json` needs neither: `json_object()` escapes newlines, so one row is one line.
#
# ---------------------------------------------------------------------------------
# CONTRACT WITH THE CREATION COMMANDS (`guild new req|task|plan`)
#
# Both the export here and `cmd_read` in lib/artifacts.sh reconstruct a document as:
# frontmatter / heading (projected from columns) + `body` + generated sections. So:
#
#   * `<kind>.body` holds the document body ONLY — for a task that is the
#     `## Objective` / `## Context` / `## Acceptance Criteria` sections, and it must
#     NOT contain the `## Work Log` or `## Follow-up Tasks` headings. Those are
#     rendered from `work_log` (and left empty, as v4 left them). Storing them in
#     `body` would render them twice.
#   * `body` never contains the `---` frontmatter fences; those are rebuilt from the
#     columns so `guild meta` and `guild read` cannot disagree.
#   * `task.objective` is a projection for `guild meta`, not a second body. It is not
#     rendered separately — the body's `## Objective` section is the rendered form.
# ---------------------------------------------------------------------------------

# ---- small helpers ---------------------------------------------------------------
#
# NO `export_path`, and no `guild path`. In v4 the path WAS the storage, so handing an
# agent a path handed it a file it could edit. In v5 only requirements get an export
# file, `export_all` rebuilds the whole directory from the database on every run, and
# nothing ever reads those files back — so a returned path is a place where work goes
# to be silently discarded. `.guild/export/` is a generated, PR-reviewable snapshot and
# nothing else. Callers read with `guild read` / `guild meta` / `guild slice`.

# _render_nl — a SQL string literal containing exactly one newline. Used to build
# multi-line values by concatenation. Deliberately NOT char(10): char() is not on the
# verified-portable list in §3.0, whereas a literal newline inside a quoted string is
# plain SQL text that both engines parse.
_render_nl() {
  printf "'\n'"
}

# _render_cr — the same, for a carriage return. Same reasoning, same portability note.
_render_cr() {
  printf "'\r'"
}

# _render_flat <sql-expression> — wrap an expression so its value CANNOT SPAN LINES.
#
# This is the board's half of the output-channel rule (see the header). CR is deleted
# rather than turned into a space so that a CRLF pair collapses to the single space the
# LF replacement produces, instead of two. `replace()` and `length()` are plain SQL
# string functions, verified against tursodb 0.7.2.
_render_flat() {
  printf "replace(replace(%s, %s, ''), %s, ' ')" "$1" "$(_render_cr)" "$(_render_nl)"
}

# _render_flat_arg <value> — `_render_flat`'s SHELL-SIDE TWIN: CR deleted, LF turned into
# a space, so the value cannot span lines.
#
# It exists because a create command ECHOES BACK a title it has just stored (`guild goal
# new` and `guild bug new` both print `<ID> <title>`), and that title is argv the process
# already holds — a second round trip to read it back would answer with the same bytes.
# The stored column is never touched; this is presentation, applied at the one place where
# a free-text value shares a line with a structural field.
#
# It lives HERE, beside `_render_flat`, because it is the same rule stated on the other
# side of the driver, and two modules needed it: lib/direction.sh and lib/records.sh each
# grew a private, byte-identical copy under a different name, which is precisely the
# "second copy of the one answer" this file's header exists to prevent.
#
# `tr` rather than a `${v//…}` loop: parameter expansion over a large value is quadratic
# under bash 3.2 (measured: 92s at 400 KB for `${v#*|}` with no match), and a title is
# unvalidated argv that may legally be document-sized. tr is one linear pass.
_render_flat_arg() {
  printf '%s' "${1-}" | LC_ALL=C tr -d '\r' | LC_ALL=C tr '\n' ' '
}

# _render_byte <2-hex-digits> — a SQL string literal holding exactly that one byte.
#
# The transport of §2.2.1 turned inward: `CAST(x'09' AS TEXT)` is the only way to name a
# control character in a script that must stay one physical line per statement, and it is
# the construct the whole CLI already rests on (§3.0). Deliberately NOT char(9): char() is
# now verified too, but a second spelling of the same idea is a second thing to trust.
_render_byte() {
  printf "CAST(x'%s' AS TEXT)" "$1"
}

# _render_linecount <sql-expression> — the number of LF-delimited lines in a value.
#
# The export's half of the rule: the reader consumes exactly this many lines verbatim,
# so it never has to recognize where a value ends by looking at it.
_render_linecount() {
  printf "(length(%s) - length(replace(%s, %s, '')) + 1)" "$1" "$1" "$(_render_nl)"
}

# _render_col <sql-expression> — flatten a value into ONE WHITESPACE-FREE COLUMN.
#
# `_render_flat` is the right shape for a surface whose only structural token is the START
# OF A LINE (the board, the frontmatter block). It is NOT enough for a surface whose
# structural token is the FIELD BOUNDARY, and `guild list task` is one: `guild help`
# documents the orchestrator filtering it with `awk '$3 == "reviewer" && $4 == "REQ-001"'`,
# and awk's default separator is any run of blanks. Flattening alone turned the newline
# attack into a SPACE attack — `--agent 'reviewer REQ-001'` on REQ-002 printed
#
#   TASK-002 todo reviewer REQ-001 REQ-002
#
# which that filter matched, so a ticket forged its own requirement; and a benign
# multi-word agent (`developer svelte`) broke the same filter in the other direction by
# shifting `$4`. No separator can fix this, because argv can contain any byte but NUL —
# so the FIELDS are made unable to contain the separator instead.
#
# Every blank becomes `_`. That is lossy, on purpose and only here: this surface is a
# FILTER, not a round trip. The byte-exact value is one round trip away in
# `guild meta <ID> agent`, which is not columnar and is therefore not flattened at all.
#
# Space and TAB are what POSIX awk splits on; CR/LF are already handled by `_render_flat`
# underneath; VT and FF are included because some awks treat them as blanks too and the
# cost of covering them is one replace() each.
_render_col() {
  local e hx
  e="$(_render_flat "$1")"
  for hx in 09 0b 0c; do
    e="replace($e, $(_render_byte "$hx"), '_')"
  done
  printf "replace(%s, ' ', '_')" "$e"
}

# ---- YAML ------------------------------------------------------------------------
#
# The frontmatter `guild meta <ID>` and `guild read <ID>` print is YAML, and every skill
# and agent in the plugin parses it. Flattening makes it UNFORGEABLE — no value can start
# a line — but unforgeable is not the same as VALID, and the two failures are different:
#
#   title: "C:\path\new"     → ScannerError: unknown escape character 'p'
#   title: "Real title" ..." → ParserError: expected <block end>
#   title: "a\nb"            → a real newline again, silently undoing the flattening
#
# A Windows path in a title is not adversarial input, so this is an ordinary-use bug.

# _render_yaml_esc <sql-expression> — the value as the CONTENTS of a double-quoted YAML
# scalar (no surrounding quotes).
#
# Backslash first, then the quote, then every character YAML 1.2 forbids raw inside a
# double-quoted scalar (`nb-json` is TAB plus U+0020 and above, so the C0 controls and DEL
# must be escaped). Order is load-bearing: `\` is doubled before anything else introduces
# one, so no escape is escaped twice. CR and LF are handled defensively — `_render_flat`
# has already removed them by the time this wraps a real field — because a helper that is
# correct only in the presence of another helper is a trap for the next caller.
_render_yaml_esc() {
  local e="${1-}" hx
  e="replace($e, '\\', '\\\\')"
  e="replace($e, '\"', '\\\"')"
  e="replace($e, $(_render_byte 09), '\\t')"
  e="replace($e, $(_render_byte 0a), '\\n')"
  e="replace($e, $(_render_byte 0d), '\\r')"
  for hx in 01 02 03 04 05 06 07 08 0b 0c 0e 0f \
            10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f 7f; do
    e="replace($e, $(_render_byte "$hx"), '\\x$hx')"
  done
  printf '%s' "$e"
}

# _render_yaml_dq <sql-expression> — a complete double-quoted YAML scalar.
_render_yaml_dq() {
  printf "'\"' || %s || '\"'" "$(_render_yaml_esc "$1")"
}

# _render_yaml_scalar <sql-expression> — quote ONLY when the value is not already a safe
# plain scalar.
#
# v4 wrote most frontmatter fields bare (`agent: developer`, `parallel-group: impl`,
# `plan: null`) and quoted only `title`, and that shape is pinned by the harness as v4
# parity — so this cannot simply quote everything. It does not need to: a value drawn from
# `[A-Za-z0-9_.-]` is a plain scalar in any YAML reader, which is every id, date, status,
# roster agent name and the literal `null`. Anything else — a space, a `:`, a `#`, a
# leading `-`, a control byte, any non-ASCII — is quoted and escaped, which is always
# valid and always round-trips. The benign output is therefore byte-identical to v4's and
# only the values that used to produce a parse error change.
#
# An empty value stays bare: `agent: ` with nothing after it is v4's output and is valid
# YAML (an empty plain scalar is null), and GLOB reports it as safe.
#
# `GLOB` with a negated class is verified against tursodb 0.7.2 (§3.0); `-` is last in the
# class so it is a literal rather than a range.
_render_yaml_scalar() {
  printf "CASE WHEN %s GLOB '*[^A-Za-z0-9_.-]*' THEN %s ELSE %s END" \
    "$1" "$(_render_yaml_dq "$1")" "$1"
}

# _render_tmp <label> — create a temp file, or die.
_render_tmp() {
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/guild-${1:-render}.XXXXXX")" ||
    die "guild: could not create a temporary file"
  printf '%s\n' "$f"
}

# _render_query <sql-file> <out-file> <errmsg> — run one SQL script, capture rows.
#
# Two deliberate choices, both about not losing errors:
#   * The SQL is staged in a FILE and db_query is called with a redirect, never as the
#     right-hand side of a pipe. On the right of a pipe db_query runs in a subshell, so
#     the `die` inside db_require_binary would exit only that subshell — the caller
#     would sail on with an empty result set. With a redirect, that die ends the
#     process with its own precise message (the install instructions, say).
#   * The rows are staged in a FILE rather than piped straight into awk, because in a
#     pipeline the exit status is awk's: a failed query would silently render an empty
#     board or an empty export while reporting success.
#   * On failure the captured buffer is RELAYED to stderr before dying: tursodb writes
#     its diagnostics to stdout, which is this function's `$out` file, so discarding it
#     turns an engine error into a bare one-line message with no cause attached.
_render_query() {
  local sql="$1" out="$2" msg="$3" diag
  if ! db_query <"$sql" >"$out"; then
    diag="$(cat "$out" 2>/dev/null || true)"
    rm -f "$sql" "$out"
    db_fail "${msg#guild: }" "$diag"
  fi
  rm -f "$sql"
}

# ============================ the board ===========================================
#
# Reproduces v4 `guild board` byte for byte:
#
#   Guild Board
#   ===========
#
#   In Progress:
#     TASK-003: Implement auth service (developer)
#
#   Backlog:
#     (none)
#
#   Recently Completed:
#     TASK-002: Implement signup endpoint (developer)
#
#   Failed:                       <- only when at least one task is `failed`
#     TASK-009: Broken thing (developer)
#
#   Requirements:
#     REQ-001: User Authentication — in-progress (3/6 done)
#
#   Last check-in: 2026-08-13
#
# ONE query. Six statements in a single script, each tagging its rows with a leading
# section digit; statement order fixes section order, each statement's own ORDER BY
# fixes row order within a section. Free text is the tail of the single output column,
# so pipes in titles are harmless — and every free-text expression is wrapped in
# `_render_flat`, so newlines in titles are harmless too: a row is always exactly one
# line and the leading digit can only ever be the one the SQL put there.
#
# v4 PARITY NOTE: the four statuses v4 could express (todo, in-progress, done, failed)
# are the four the board renders. `task.status` also admits `blocked` and `waived` — a
# task in either is invisible here, exactly as it would have been in v4, which had no
# directory for it. Surfacing those is a later stage's job (§5.2 roster gaps), not a
# silent widening of a command whose output is specified as identical to v4's.

_render_board_sql() {
  # 1 in-progress · 2 todo (Backlog) · 3 done (newest 20) · 4 failed
  # 5 requirements (with live N/M counters) · 6 last check-in
  #
  # Every textual column is flattened. Ids are flattened too, cheaply: they are
  # generated by `guild new` today, but `guild rebuild` replays them from a file that
  # lives in git, and a structural token must not depend on who wrote that file.
  local tid_expr ttitle_expr tagent_expr rid_expr rtitle_expr rstatus_expr checkin_expr
  tid_expr="$(_render_flat 'id')"
  ttitle_expr="$(_render_flat 'title')"
  tagent_expr="$(_render_flat "COALESCE(agent, '')")"
  rid_expr="$(_render_flat 'r.id')"
  rtitle_expr="$(_render_flat 'r.title')"
  rstatus_expr="$(_render_flat 'r.status')"
  checkin_expr="$(_render_flat 'value')"

  cat <<SQL
SELECT '1 ' || '  ' || $tid_expr || ': ' || $ttitle_expr || ' (' || $tagent_expr || ')'
  FROM task WHERE status = 'in-progress' ORDER BY id;

SELECT '2 ' || '  ' || $tid_expr || ': ' || $ttitle_expr || ' (' || $tagent_expr || ')'
  FROM task WHERE status = 'todo' ORDER BY id;

SELECT '3 ' || line FROM (
  SELECT id AS id,
         '  ' || $tid_expr || ': ' || $ttitle_expr || ' (' || $tagent_expr || ')' AS line
    FROM task WHERE status = 'done' ORDER BY id DESC LIMIT 20
) ORDER BY id DESC;

SELECT '4 ' || '  ' || $tid_expr || ': ' || $ttitle_expr || ' (' || $tagent_expr || ')'
  FROM task WHERE status = 'failed' ORDER BY id;

SELECT '5 ' || '  ' || $rid_expr || ': ' || $rtitle_expr || ' — ' || $rstatus_expr || ' ('
       || COALESCE(SUM(CASE WHEN t.status = 'done' THEN 1 ELSE 0 END), 0)
       || '/' || COUNT(t.id) || ' done)'
  FROM requirement r
  LEFT JOIN task t ON t.requirement_id = r.id
 GROUP BY r.id, r.title, r.status
 ORDER BY CASE r.status
            WHEN 'todo' THEN '1'
            WHEN 'in-progress' THEN '2'
            WHEN 'done' THEN '3'
            ELSE '4'
          END, r.id;

SELECT '6 ' || $checkin_expr FROM guild_state WHERE key = 'last-checkin';
SQL
}

# render_board — print the live board. v4 parity, one query.
render_board() {
  local rows sqlf
  db_require_init
  rows="$(_render_tmp board)"
  sqlf="$(_render_tmp board-sql)"
  _render_board_sql >"$sqlf"
  _render_query "$sqlf" "$rows" "guild: could not read the board from the database"

  LC_ALL=C awk '
    # A row is a tagged line "<digit> <text>", and — because the SQL flattened every
    # free-text column — a row is ALWAYS exactly one line. So the leading digit can
    # only have been written by the SQL, never by a title.
    /^[0-9] / {
      sec = substr($0, 1, 1) + 0
      txt = substr($0, 3)
      if (sec == 6) { lc = txt; next }
      n[sec]++
      buf[sec, n[sec]] = txt
      next
    }
    # Anything else is driver noise (a banner, a blank line between statements). It is
    # DROPPED, not folded onto the previous row: there is no longer any such thing as a
    # legitimate continuation line, and folding is how the injection used to land.
    { next }

    function emit(heading, s,   i) {
      print heading
      if (n[s] + 0 == 0) { print "  (none)"; return }
      for (i = 1; i <= n[s]; i++) print buf[s, i]
    }

    END {
      print "Guild Board"
      print "==========="
      print ""
      emit("In Progress:", 1)
      print ""
      emit("Backlog:", 2)
      print ""
      emit("Recently Completed:", 3)
      if (n[4] + 0 > 0) {
        print ""
        print "Failed:"
        for (i = 1; i <= n[4]; i++) print buf[4, i]
      }
      print ""
      emit("Requirements:", 5)
      print ""
      printf "Last check-in: %s\n", lc
    }
  ' "$rows"

  rm -f "$rows"
}

# cmd_board — the dispatcher entry point. v4's `guild board` took no arguments.
cmd_board() {
  [ $# -eq 0 ] || die "guild: board takes no arguments"
  render_board
}

# ============================ the export (§2.3) ===================================
#
# `.guild/export/REQ-NNN.md` — one markdown file per requirement with its plans,
# slices and tasks inlined. Committed and diffed in PRs, so it MUST be deterministic:
# a re-run with no state change produces a byte-identical tree.
#
# What determinism costs here, concretely:
#   * Every list is ordered EXPLICITLY in SQL (`ORDER BY req, sec, sub, subsec, ord`);
#     database return order is never relied on.
#   * Nothing in the output is "now" — every timestamp printed is a stored column
#     (created_at / updated_at / work_log.ts), i.e. state, not clock.
#   * The tree is rebuilt into a temp directory and swapped in, so a requirement that
#     disappears leaves no stale file behind. A stale file would make the tree depend
#     on export history rather than on current state.
#   * The `$$` in the temp directory name never reaches the output.

_export_sql() {
  local nl body_expr len_expr req_expr
  nl="$(_render_nl)"

  # One compound SELECT, ordered once, so the rows arrive already grouped per
  # requirement in document order. Sections:
  #   1 requirement header+body · 2 "## Plans" · 3 plan (+slices)
  #   4 "## Tasks" · 5 task (+work log, +findings)
  # `sub` is the plan/task id, `subsec` the block within it, `ord` the row within that
  # block. Every chunk begins with a newline (except the requirement header, which is
  # the first thing in the file) — that is what produces the blank line before it.
  #
  # There is NO section 0 and no in-band file marker any more. The file a chunk belongs
  # to is carried in the length-prefix header the outer SELECT writes, which body text
  # cannot reach; the reader switches files when that header's requirement id changes.
  body_expr="COALESCE(txt, '')"
  len_expr="$(_render_linecount "$body_expr")"
  # The id shares the header line with the count, so it is a STRUCTURAL FIELD and gets
  # the board's treatment, not the body's: flattened, never counted. `guild rebuild`
  # replays ids from a file that lives in git, so this is not a hypothetical column.
  req_expr="$(_render_flat 'req')"

  cat <<SQL
WITH parts AS (
  SELECT r.id AS req, 1 AS sec, '' AS sub, 0 AS subsec, '' AS ord,
         '# ' || r.id || ' — ' || r.title
         || $nl || $nl || '- **Status:** ' || r.status
         || $nl || '- **Priority:** ' || r.priority
         || $nl || '- **Created:** ' || r.created_at
         || $nl || '- **Updated:** ' || r.updated_at
         || $nl || '- **Tasks:** '
            || COALESCE(SUM(CASE WHEN t.status = 'done' THEN 1 ELSE 0 END), 0)
            || '/' || COUNT(t.id) || ' done'
         || CASE WHEN r.body = '' THEN '' ELSE $nl || $nl || r.body END AS txt
    FROM requirement r
    LEFT JOIN task t ON t.requirement_id = r.id
   GROUP BY r.id, r.title, r.body, r.status, r.priority, r.created_at, r.updated_at

  UNION ALL
  SELECT p.requirement_id, 2, '', 0, '', $nl || '## Plans'
    FROM plan p GROUP BY p.requirement_id

  UNION ALL
  SELECT p.requirement_id, 3, p.id, 0, '',
         $nl || '### ' || p.id || ' — ' || p.title
         || $nl || $nl || '- **Status:** ' || p.status
         || CASE WHEN COALESCE(p.task_id, '') = '' THEN ''
                 ELSE $nl || '- **Task:** ' || p.task_id END
         || $nl || '- **Created:** ' || p.created_at
         || CASE WHEN p.body = '' THEN '' ELSE $nl || $nl || p.body END
    FROM plan p

  UNION ALL
  SELECT p.requirement_id, 3, p.id, 1, s.slug,
         $nl || '#### Slice \`' || s.slug || '\` — ' || s.title
         || $nl || $nl || '- **Files:** \`' || s.files || '\`'
         || CASE WHEN s.body = '' THEN '' ELSE $nl || $nl || s.body END
    FROM plan_slice s
    JOIN plan p ON p.id = s.plan_id

  UNION ALL
  SELECT t.requirement_id, 4, '', 0, '', $nl || '## Tasks'
    FROM task t GROUP BY t.requirement_id

  UNION ALL
  SELECT t.requirement_id, 5, t.id, 0, '',
         $nl || '### ' || t.id || ' — ' || t.title
         || $nl || $nl || '- **Status:** ' || t.status
         || CASE WHEN COALESCE(t.agent, '') = '' THEN ''
                 ELSE $nl || '- **Agent:** ' || t.agent END
         || CASE WHEN COALESCE(t.plan_id, '') = '' THEN ''
                 ELSE $nl || '- **Plan:** ' || t.plan_id END
         || CASE WHEN COALESCE(t.plan_slice, '') = '' THEN ''
                 ELSE $nl || '- **Plan slice:** ' || t.plan_slice END
         || CASE WHEN COALESCE(t.parallel_group, '') = '' THEN ''
                 ELSE $nl || '- **Parallel group:** ' || t.parallel_group END
         || $nl || '- **Created:** ' || t.created_at
         || CASE WHEN t.body = '' THEN '' ELSE $nl || $nl || t.body END
    FROM task t

  UNION ALL
  SELECT t.requirement_id, 5, w.task_id, 1, '', $nl || '#### Work Log'
    FROM work_log w
    JOIN task t ON t.id = w.task_id
   GROUP BY t.requirement_id, w.task_id

  UNION ALL
  SELECT t.requirement_id, 5, w.task_id, 2, w.ts || ' ' || printf('%012d', w.id),
         $nl || '- \`' || w.ts || '\` **' || w.agent || '** — ' || w.entry
    FROM work_log w
    JOIN task t ON t.id = w.task_id

  UNION ALL
  SELECT t.requirement_id, 5, f.task_id, 3, '', $nl || '#### Findings'
    FROM review_finding f
    JOIN task t ON t.id = f.task_id
   GROUP BY t.requirement_id, f.task_id

  UNION ALL
  SELECT t.requirement_id, 5, f.task_id, 4,
         f.created_at || ' ' || printf('%012d', f.id),
         $nl || '- **' || f.severity || '** \`' || f.disposition || '\` ('
         || f.reviewer || ') — ' || f.summary
         || CASE WHEN COALESCE(f.file, '') = '' THEN ''
                 ELSE ' [' || f.file
                      || CASE WHEN f.line IS NULL THEN '' ELSE ':' || f.line END
                      || ']' END
         || CASE WHEN f.detail = '' THEN '' ELSE $nl || '  - ' || f.detail END
    FROM review_finding f
    JOIN task t ON t.id = f.task_id
)
SELECT '@@GUILD-EXPORT@@ ' || $len_expr || ' ' || $req_expr || $nl || $body_expr
  FROM parts
 ORDER BY req, sec, sub, subsec, ord;
SQL
}

# export_all — regenerate .guild/export/ from current state.
export_all() {
  local out tmpd rows count stale pid diag
  db_require_init

  out="$GUILD_DIR/export"
  tmpd="$GUILD_DIR/.export.tmp.$$"

  # A run killed mid-flight leaves its staging directory behind; clear the stragglers
  # so they cannot accumulate. Only directories whose PID suffix belongs to no live
  # process are removed: the old blanket `rm -rf .export.tmp.*` deleted a CONCURRENT
  # export's staging tree out from under it, so two overlapping runs corrupted each
  # other. An unmatched glob stays literal, and the -d test skips it.
  for stale in "$GUILD_DIR"/.export.tmp.*; do
    [ -d "$stale" ] || continue
    pid="${stale##*.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if kill -0 "$pid" 2>/dev/null; then continue; fi
    rm -rf "$stale"
  done
  rm -rf "$tmpd"
  mkdir -p "$tmpd/export" || die "guild: cannot create $tmpd"
  rows="$tmpd/rows"

  _export_sql >"$tmpd/query.sql"
  if ! db_query <"$tmpd/query.sql" >"$rows"; then
    diag="$(cat "$rows" 2>/dev/null || true)"
    rm -rf "$tmpd"
    db_fail "export query failed; $out left unchanged" "$diag"
  fi

  # The reader. Two states, and the whole safety property lives in the second one:
  #
  #   want == 0  — expecting a header. Only a line the SQL wrote can be here, because
  #                the previous row was consumed to its exact last line.
  #   want  > 0  — inside a value. Lines are written out VERBATIM and counted down.
  #                They are never matched against anything, so no body, objective,
  #                title or work-log entry can be read as structure.
  #
  # One file open at a time: rows arrive grouped by requirement, so the previous file
  # is closed the moment the header's id changes. POSIX awk has a low open-file limit.
  if ! LC_ALL=C awk -v OUTDIR="$tmpd/export" -v CNT="$tmpd/count" '
    function closefile() {
      if (cur != "") { close(cur); cur = "" }
      pending = 0
    }
    function emit(line) {
      # Trailing blank lines are held back and dropped at end of file, so a body with
      # stray trailing newlines cannot change where the file ends.
      if (line ~ /^[ \t]*$/) { pending++; return }
      while (pending > 0) { printf "\n" > cur; pending-- }
      printf "%s\n", line > cur
    }

    want > 0 { emit($0); want--; next }

    # Header state. Parsed with substr, not fields, so that the id is taken as the
    # WHOLE remainder of the line: an id containing a space then fails the regex and
    # dies, instead of making the header look malformed, fall through to the drop rule,
    # and leave the rows body lines to be inspected as headers. Fail closed, never
    # desync. The id is validated even though it comes from `requirement.id`, because
    # `guild rebuild` replays ids from a file that lives in git; the regex also rejects
    # `/`, so the export can never be written outside OUTDIR. It is the SECOND layer:
    # the SQL flattened the id, so a multi-line id arrives here as one line containing a
    # space and this regex rejects it — the header can no longer be split in two.
    /^@@GUILD-EXPORT@@ [0-9]+ / {
      rest = substr($0, 18)                 # past "@@GUILD-EXPORT@@ "
      sp   = index(rest, " ")
      want = substr(rest, 1, sp - 1) + 0
      id   = substr(rest, sp + 1)
      if (id !~ /^REQ-[A-Za-z0-9_.-]+$/) {
        print "guild: refusing to export malformed requirement id " id > "/dev/stderr"
        bad = 1
        exit 1
      }
      if (cur != OUTDIR "/" id ".md") {
        closefile()
        cur = OUTDIR "/" id ".md"
        files++
        printf "" > cur          # create the file even if every chunk is blank
      }
      next
    }

    # Not a header and not inside a value: a driver banner or a blank line between
    # statements. Dropped.
    { next }

    END {
      closefile()
      if (bad) exit 1
      if (want > 0) {
        print "guild: export ended mid-record; refusing to install" > "/dev/stderr"
        exit 1
      }
      printf "%d\n", files + 0 > CNT
      close(CNT)
    }
  ' "$rows"; then
    rm -rf "$tmpd"
    die "guild: export rendering failed; $out left unchanged"
  fi

  count=0
  if [ -f "$tmpd/count" ]; then read -r count <"$tmpd/count"; fi

  # The swap. Never `rm -rf "$out"` before the replacement is in place: on a failed
  # install that leaves the user with NEITHER export, while the error message ("could
  # not install") implies the old one survived. Instead move the old tree aside inside
  # our own staging directory — same filesystem, so it is a rename — install the new
  # one, and put the old one back if that fails.
  if [ -e "$out" ]; then
    if ! mv "$out" "$tmpd/old"; then
      rm -rf "$tmpd"
      die "guild: could not set aside the existing export at $out; it is unchanged"
    fi
  fi
  if ! mv "$tmpd/export" "$out"; then
    if [ -e "$tmpd/old" ] && mv "$tmpd/old" "$out"; then
      rm -rf "$tmpd"
      die "guild: could not install the export at $out; the previous export is intact"
    fi
    die "guild: could not install the export at $out; the previous export is at $tmpd/old and the new one at $tmpd/export"
  fi
  rm -rf "$tmpd"

  printf 'Exported %s requirement(s) to %s\n' "${count:-0}" "$out"
}

# ============================ the JSON dump =======================================
#
# export_json — board state as JSON on stdout, for the Stage 2 dashboard.
#
# Escaping is done by the engine's json_object(), the same choice journal.sh makes in
# journal_compact and for the same reason: a task body full of markdown pipes and
# newlines would shred any shell- or awk-side quoting, while json_object emits exactly
# one line per row with every control character already escaped, and preserves column
# types. awk only assembles the arrays; it never touches the values.
#
# One db_query: statements run in order, so the tag order is fixed by the script, and
# each statement carries its own ORDER BY.

_export_json_sql() {
  # `json_object(key, value)` uses a COLUMN as the label, which is ordinary SQLite
  # semantics (the odd argument of each pair is the label expression) and is what lets
  # guild_state render as a real object rather than a list of {key,value} pairs. If an
  # engine ever rejects a computed label, the fallback is
  # `json_object('key', key, 'value', value)` plus an array shape for `state`.
  cat <<'SQL'
SELECT 'state|' || json_object(key, value) FROM guild_state ORDER BY key;

SELECT 'requirement|' || json_object(
         'id', id, 'phase_id', phase_id, 'title', title, 'body', body,
         'status', status, 'priority', priority,
         'created_at', created_at, 'updated_at', updated_at)
  FROM requirement ORDER BY id;

SELECT 'plan|' || json_object(
         'id', id, 'requirement_id', requirement_id, 'task_id', task_id,
         'title', title, 'body', body, 'status', status,
         'created_at', created_at, 'updated_at', updated_at)
  FROM plan ORDER BY id;

SELECT 'plan_slice|' || json_object(
         'id', id, 'plan_id', plan_id, 'slug', slug, 'title', title,
         'body', body, 'files', files)
  FROM plan_slice ORDER BY plan_id, slug;

SELECT 'task|' || json_object(
         'id', id, 'requirement_id', requirement_id, 'plan_id', plan_id,
         'plan_slice_id', plan_slice_id, 'plan_slice', plan_slice,
         'parallel_group', parallel_group, 'node_key', node_key,
         'title', title, 'objective', objective, 'body', body,
         'status', status, 'priority', priority, 'agent', agent,
         'claimed_by', claimed_by, 'claimed_at', claimed_at,
         'created_at', created_at, 'updated_at', updated_at)
  FROM task ORDER BY id;

SELECT 'work_log|' || json_object(
         'id', id, 'task_id', task_id, 'ts', ts, 'agent', agent, 'entry', entry)
  FROM work_log ORDER BY task_id, ts, id;

SELECT 'finding|' || json_object(
         'id', id, 'task_id', task_id, 'reviewer', reviewer, 'severity', severity,
         'summary', summary, 'detail', detail, 'file', file, 'line', line,
         'disposition', disposition, 'fix_task_id', fix_task_id,
         'created_at', created_at)
  FROM review_finding ORDER BY task_id, created_at, id;
SQL
}

export_json() {
  local rows sqlf
  db_require_init
  rows="$(_render_tmp json)"
  sqlf="$(_render_tmp json-sql)"
  _export_json_sql >"$sqlf"
  _render_query "$sqlf" "$rows" "guild: could not read the database"

  LC_ALL=C awk '
    {
      p = index($0, "|")
      if (p < 2) next
      tag = substr($0, 1, p - 1)
      obj = substr($0, p + 1)
      if (substr(obj, 1, 1) != "{") next     # skip banners and blank lines
      n[tag]++
      row[tag, n[tag]] = obj
    }

    # merge one-key objects into a single JSON object body
    function merged(tag,   i, s, inner) {
      s = ""
      for (i = 1; i <= n[tag] + 0; i++) {
        inner = substr(row[tag, i], 2, length(row[tag, i]) - 2)
        if (inner == "") continue
        s = s (s == "" ? "" : ", ") inner
      }
      return s
    }

    function arr(name, tag, last,   i) {
      if (n[tag] + 0 == 0) { printf "  \"%s\": []%s\n", name, (last ? "" : ","); return }
      printf "  \"%s\": [\n", name
      for (i = 1; i <= n[tag]; i++)
        printf "    %s%s\n", row[tag, i], (i < n[tag] ? "," : "")
      printf "  ]%s\n", (last ? "" : ",")
    }

    END {
      print "{"
      printf "  \"state\": {%s},\n", merged("state")
      arr("requirements", "requirement", 0)
      arr("plans",        "plan",        0)
      arr("plan_slices",  "plan_slice",  0)
      arr("tasks",        "task",        0)
      arr("work_log",     "work_log",    0)
      arr("findings",     "finding",     1)
      print "}"
    }
  ' "$rows"

  rm -f "$rows"
}

# cmd_export [--json] — the dispatcher entry point (design §4).
#
#   guild export          regenerate .guild/export/*.md
#   guild export --json   board state as JSON on stdout (Stage 2's dashboard input)
cmd_export() {
  case "${1-}" in
    "")
      export_all
      ;;
    --json)
      shift
      [ $# -eq 0 ] || die "guild: export --json takes no further arguments"
      export_json
      ;;
    *)
      die "guild: unknown option '$1' for export (try 'guild export [--json]')"
      ;;
  esac
}
