# shellcheck shell=bash
#
# lib/dashboard.sh — `guild dashboard`: the whole project as one self-contained HTML file
# (design §9, Stage 2).
#
#   guild dashboard            write .guild/dashboard.html
#   guild dashboard --open     ... and open it in the default browser
#   guild dashboard --out P    ... write it to P instead
#   guild dashboard --json     print the inlined data document and write nothing
#
# Seven views, all fed by ONE query: Roadmap (goals → phases → requirements), Board (tasks
# by status, coloured by priority), Graph (the execution graph — EMPTY until Stage 4, and
# this view says so rather than drawing an empty chart), Bugs, Findings (what reviewers
# flagged, and whether it was ever fixed), Coverage ("what has nobody looked at in a
# month?") and Activity (the `event` feed).
#
# FINDINGS IS THE VIEW THE HEADLINE NUMBERS USED TO POINT NOWHERE. `guild brief` says
# "2 unresolved review finding(s)" and the summary tile says "2 Open findings", and until
# this view existed neither named a single one — the count was the whole surface, and the
# rows behind it were reachable only by hand-writing SQL. §1 of the design doc calls this
# out as a v4→v5 win ("what did reviewers flag that we never fixed?" becomes a query), and
# a count is not an answer to that question. So the tile is a LINK now, and this is where
# it lands.
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` — scripts/guild owns those.
# Depends on lib/db.sh (die, db_require_init, db_query, db_fail, sql_str), lib/render.sh
# (_render_tmp, _render_query) and lib/brief.sh (_brief_clip for the free-text clip,
# _brief_fact_select for the shared `H` count transport, _brief_severity_rank for the
# worst-first ordering, _brief_subject_title for the activity feed's subject). Bash 3.2
# compatible.
#
# THE SHARED HELPERS ARE NOT A CONVENIENCE. `guild brief` and this page answer the same two
# questions about the same two tables — "what did reviewers flag that nobody fixed" and
# "which bugs are worst" — and a hand-copied CASE ladder in each is how the tile that says
# `2 Open findings` and the section that lists them end up disagreeing about which two.
# Severity order, the open-disposition set (`open`, `fixing`) and the `H` count transport
# have exactly ONE definition between the two surfaces.
#
# It MUTATES NOTHING — no journal line, no `event` row. Same reasoning as `guild brief`
# and `guild export`: rendering the board is not a change to it, and an activity feed that
# filled up with "the dashboard was rendered" would drown the work it exists to show.
#
# ---------------------------------------------------------------------------------
# ONE db_exec (§2.2). Twelve statements, one script, one invocation — the mechanism
# `render_board` and `brief` already use. Statement order is section order; each
# statement's own ORDER BY fixes row order, and every ORDER BY ends in a unique column so
# the order is TOTAL (see DETERMINISM).
#
#   M  meta      H  counts     A  goals      B  phases    C  requirements  D  tasks
#   E  bugs      R  findings   F  coverage   G  activity  N  graph nodes   X  graph edges
#
# ---------------------------------------------------------------------------------
# THE OUTPUT CHANNEL IS AN HTML DOCUMENT, AND THAT IS A NEW INJECTION SURFACE.
#
# Design rule 3, one medium further on. Stage 1 had a title forge a board section, a list
# column, a frontmatter field and an export filename; inlining the same title into HTML
# gives it three more channels at once — the JSON, the element, and the DOM. A requirement
# titled `</script><script>alert(1)</script>` must be shown, not run.
#
# THE STRUCTURAL TOKEN HERE IS `<` — because that is the only byte that can end the
# `<script type="application/json">` element the data sits in. HTML's tokenizer does not
# care that `</script>` is inside a JSON string: it ends the element there, and everything
# after it is markup. So a JSON encoder alone — however correct — is NOT a defense, and
# `json_object()` demonstrably leaves `<` raw (verified on tursodb 0.7.2):
#
#   SELECT json_object('t', CAST(x'3c2f7363726970743e' AS TEXT));
#   → {"t":"</script>"}
#
# The mechanism, and why it is total rather than a best effort:
#
#   1. The engine emits every row as `json_object(...)`, so quotes, backslashes, newlines
#      and control characters are escaped by the database — the same division of labour
#      `export_json` and `brief --json` use, and awk never touches a value.
#   2. `_dash_jsafe` then rewrites EVERY `<`, `>` and `&` byte in the finished document as
#      the six-character JSON escape for it — `<` becomes `\u003c`, `>` becomes `\u003e`,
#      `&` becomes `\u0026`. THOSE THREE ESCAPE SEQUENCES ARE THE LOAD-BEARING PART OF THIS
#      PARAGRAPH; a version of this comment in which they have collapsed back into the bare
#      characters they denote is describing an identity transform, and is wrong.
#      The rewrite is lossless and unambiguous because **none of those three bytes appears
#      in any JSON structural token** — JSON structure is built from `{ } [ ] : ,`, the
#      string quote, whitespace, numbers and the three bare words true/false/null. So every
#      `<` in the document is necessarily inside a string, where `<` means exactly the
#      same thing to every JSON parser on earth.
#      The result: the emitted document contains NO `<` byte AT ALL, and therefore cannot
#      close the script element or open a tag — not by any encoding, nesting or trick.
#   3. The page renders every value with `textContent`. `innerHTML`, `insertAdjacentHTML`,
#      `document.write`, `eval` and `new Function` appear nowhere in the template.
#
# Three independent layers, each sufficient alone; the second is the one that makes the
# guarantee provable rather than probable.
#
# ---------------------------------------------------------------------------------
# DETERMINISM. The same database state must produce a BYTE-IDENTICAL file, because the
# file may be committed and a diff full of moved rows and a moving clock is worthless.
# Three rules, all load-bearing:
#
#   * NO WALL CLOCK IN THE OUTPUT. Not in the meta, not in a rendered "3 days ago", not
#     in a "generated at". The file carries only timestamps the database stored, and the
#     page computes every relative age in the browser at view time. (`guild export` has
#     the same property and a harness check that re-exports a second later to prove it.)
#   * EVERY `ORDER BY` ENDS IN A UNIQUE COLUMN. `ORDER BY b.severity` alone leaves ties in
#     whatever order the engine happens to produce; every ordering here ends in the row's
#     primary key.
#   * THE TEMP FILE IS NEVER THE OUTPUT. The document is composed into a staging file and
#     renamed over the target, so an interrupted run leaves the previous dashboard intact
#     rather than a half-written one — and the target's path never leaks into its content.
#
# LIMITS. Every list is capped, and the cap is stated in the SQL rather than passed in, so
# no variable reaches the query. The `H` counts are NOT capped, so the page can say
# "showing 300 of 4,812 events" honestly. A dashboard that renders a 60 MB file because a
# CI loop wrote 400,000 events is not a dashboard.
#
# PORTABILITY (§3.0). json_object(), scalar subqueries, group_concat, COALESCE, NULLIF and
# plain ORDER BY/LIMIT only. No FTS5, no WITH RECURSIVE, no generated columns, none of the
# five banned window functions — "the newest 300 events" is an ORDER BY inside a subquery.

# ---- the template -------------------------------------------------------------------

# guild_dashboard_template — locate scripts/dashboard.tmpl.html. $GUILD_DASHBOARD_TEMPLATE
# wins; otherwise it sits one directory above this file, exactly like schema.sql.
#
# The page is a TEMPLATE FILE rather than a heredoc for the same reason schema.sql is a
# file: it is ~700 lines of another language, and a heredoc would put shell quoting rules
# between the author and every `$`, every backtick and every `\` in the CSS and the
# JavaScript. A file has no such hazard, and it can be opened directly in a browser or an
# editor with its own syntax highlighting.
guild_dashboard_template() {
  local here c
  if [ -n "${GUILD_DASHBOARD_TEMPLATE:-}" ]; then
    [ -f "$GUILD_DASHBOARD_TEMPLATE" ] ||
      die "guild: dashboard template not found: $GUILD_DASHBOARD_TEMPLATE"
    printf '%s' "$GUILD_DASHBOARD_TEMPLATE"
    return 0
  fi
  here=""
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || here=""
  fi
  for c in \
    "${here:+$here/../dashboard.tmpl.html}" \
    "${here:+$here/dashboard.tmpl.html}" \
    "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/dashboard.tmpl.html}"
  do
    [ -n "$c" ] || continue
    if [ -f "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  die "guild: dashboard.tmpl.html not found next to scripts/schema.sql
Set \$GUILD_DASHBOARD_TEMPLATE to its path, or re-clone the plugin — the dashboard
template ships with it."
}

# ---- the single query -----------------------------------------------------------------

# _dash_sql — the whole dashboard as one script. Takes no arguments, and deliberately: a
# dashboard has no cutoff, no filter and no clock, so there is nothing to pass in and
# nothing that can vary between two runs over the same state.
_dash_sql() {
  local meta_sql hsel goal_expr phase_expr req_expr task_expr
  local bug_expr find_expr cov_expr act_expr node_expr edge_expr

  # Free text is CLIPPED, never truncated silently: `_brief_clip` marks the cut with an
  # ellipsis. The harness proves a 500 KB body round-trips, and one such title inlined
  # whole would be the entire page. The byte-exact value is one round trip away in
  # `guild meta <ID> title`.
  meta_sql="SELECT 'M ' || json_object(
      'schema_version', (SELECT version FROM schema_version WHERE id = 1),
      'last_checkin', (SELECT NULLIF(value, 'null') FROM guild_state WHERE key = 'last-checkin'),
      'latest_event_at', (SELECT MAX(ts) FROM event),
      'limit_requirements', 500, 'limit_tasks', 2000, 'limit_bugs', 500,
      'limit_findings', 500,
      'limit_coverage', 300, 'limit_activity', 300, 'limit_graph', 2000)"

  goal_expr="json_object('id', g.id, 'title', $(_brief_clip 'g.title' 200), 'status', g.status,
      'priority', g.priority, 'created_at', g.created_at, 'updated_at', g.updated_at,
      'phases_total', (SELECT COUNT(*) FROM phase p WHERE p.goal_id = g.id),
      'phases_done',  (SELECT COUNT(*) FROM phase p WHERE p.goal_id = g.id AND p.status = 'done'),
      'req_total',    (SELECT COUNT(*) FROM requirement r JOIN phase p ON p.id = r.phase_id WHERE p.goal_id = g.id),
      'req_done',     (SELECT COUNT(*) FROM requirement r JOIN phase p ON p.id = r.phase_id WHERE p.goal_id = g.id AND r.status = 'done'))"

  phase_expr="json_object('id', p.id, 'goal_id', p.goal_id, 'title', $(_brief_clip 'p.title' 200),
      'ordinal', p.ordinal, 'status', p.status,
      'req_total', (SELECT COUNT(*) FROM requirement r WHERE r.phase_id = p.id),
      'req_done',  (SELECT COUNT(*) FROM requirement r WHERE r.phase_id = p.id AND r.status = 'done'))"

  req_expr="json_object('id', r.id, 'phase_id', r.phase_id, 'title', $(_brief_clip 'r.title' 200),
      'status', r.status, 'priority', r.priority, 'created_at', r.created_at, 'updated_at', r.updated_at,
      'tasks_total', (SELECT COUNT(*) FROM task t WHERE t.requirement_id = r.id),
      'tasks_done',  (SELECT COUNT(*) FROM task t WHERE t.requirement_id = r.id AND t.status IN ('done','waived')),
      'bugs_open',   (SELECT COUNT(*) FROM bug b WHERE b.requirement_id = r.id AND b.status IN ('open','fixing')))"

  # `waiting_on` is DIRECT predecessors only, never recursive (§3.0) — a transitively
  # blocked task surfaces through the one it actually waits on.
  task_expr="json_object('id', t.id, 'requirement_id', t.requirement_id, 'title', $(_brief_clip 't.title' 200),
      'status', t.status, 'priority', t.priority, 'agent', t.agent, 'claimed_by', t.claimed_by,
      'claimed_at', t.claimed_at, 'updated_at', t.updated_at, 'plan_id', t.plan_id,
      'plan_slice', t.plan_slice, 'parallel_group', t.parallel_group, 'node_key', t.node_key,
      'waiting_on', (SELECT group_concat(x, ' ') FROM (SELECT b.id AS x FROM task_dependency d
                        JOIN task b ON b.id = d.depends_on
                       WHERE d.task_id = t.id AND b.status NOT IN ('done','waived') ORDER BY b.id)),
      'findings_open', (SELECT COUNT(*) FROM review_finding f
                         WHERE f.task_id = t.id AND f.disposition IN ('open','fixing')))"

  bug_expr="json_object('id', b.id, 'title', $(_brief_clip 'b.title' 200), 'severity', b.severity,
      'status', b.status, 'found_by', b.found_by, 'requirement_id', b.requirement_id,
      'fix_task_id', b.fix_task_id, 'created_at', b.created_at, 'updated_at', b.updated_at)"

  # A finding without its task is a sentence with no subject: `review_finding` stores
  # `task_id` and nothing else about it, so a page built from the row alone repeats
  # `TASK-007` down a column and never says what TASK-007 is. `task_title` is a LEFT JOIN
  # — left, because the finding is the record and must be listed even if the task it was
  # filed against has since been deleted; an inner join would make a dangling finding
  # vanish from the one view that exists to find forgotten ones.
  #
  # `reviewer` is CLIPPED like every other free-text column here, and it is the column
  # most easily forgotten: `guild finding --reviewer` takes arbitrary text, and an
  # unclipped one would be inlined whole into a page whose whole size discipline is the
  # clip. `summary` and `detail` get the widest clips on the page (300 / 600) because a
  # finding IS its prose — a 60-character clip would turn this view back into the count
  # it replaces — and both are still bounded.
  find_expr="json_object('id', f.id, 'task_id', f.task_id,
      'task_title', $(_brief_clip 't.title' 200),
      'reviewer', $(_brief_clip 'f.reviewer' 120), 'severity', f.severity,
      'summary', $(_brief_clip 'f.summary' 300), 'detail', $(_brief_clip 'f.detail' 600),
      'file', $(_brief_clip 'f.file' 200), 'line', f.line,
      'disposition', f.disposition, 'fix_task_id', f.fix_task_id,
      'created_at', f.created_at)"

  cov_expr="json_object('id', $(_brief_clip 'c.id' 80), 'area', $(_brief_clip 'c.area' 160), 'risk', c.risk,
      'spec_path', $(_brief_clip 'c.spec_path' 200), 'last_inspected_at', c.last_inspected_at,
      'notes', $(_brief_clip 'c.notes' 300))"

  # `subject_title` is what turns the Activity view from a table of ids into a feed of
  # sentences: an event row names `task TASK-001` and nothing else, so two consecutive
  # status moves render identically and neither says which task. The expression is
  # `_brief_subject_title` (lib/brief.sh), shared with the brief for the same reason the
  # `H` counts are.
  act_expr="json_object('ts', e.ts, 'actor', e.actor, 'verb', e.verb, 'subject_type', e.subject_type,
      'subject_id', e.subject_id,
      'subject_title', $(_brief_clip "$(_brief_subject_title 'e.subject_type' 'e.subject_id')" 200),
      'payload', $(_brief_clip 'e.payload' 300))"

  node_expr="json_object('id', n.id, 'requirement_id', n.requirement_id, 'node_key', n.node_key,
      'kind', n.kind, 'task_id', n.task_id, 'parallel_group', n.parallel_group, 'status', n.status)"

  edge_expr="json_object('from', x.from_node, 'to', x.to_node)"

  # ---- the counts ------------------------------------------------------------------
  #
  # `H key=<integer>` lines. Every value is a COUNT, so there is nothing to escape and
  # nothing that can carry a value: the page's summary tiles and its "showing N of M"
  # footers are composed from these integers and never from a queried string. Uncapped by
  # design — they are what makes the capped lists honest.
  #
  # The transport is `_brief_fact_select` (lib/brief.sh), shared with `guild brief`, which
  # emits the identical `H` line shape; only the LIST below is this command's own. For the
  # harness's interpolation audit: every key and expression here is fixed text from this
  # heredoc, never from input.
  hsel="$(
    _brief_fact_select <<FACTS
goals_total (SELECT COUNT(*) FROM goal)
goals_open (SELECT COUNT(*) FROM goal WHERE status <> 'done')
phases_total (SELECT COUNT(*) FROM phase)
phases_open (SELECT COUNT(*) FROM phase WHERE status <> 'done')
req_total (SELECT COUNT(*) FROM requirement)
req_done (SELECT COUNT(*) FROM requirement WHERE status = 'done')
req_unattached (SELECT COUNT(*) FROM requirement WHERE phase_id IS NULL)
tasks_total (SELECT COUNT(*) FROM task)
tasks_todo (SELECT COUNT(*) FROM task WHERE status = 'todo')
tasks_in_progress (SELECT COUNT(*) FROM task WHERE status = 'in-progress')
tasks_blocked (SELECT COUNT(*) FROM task WHERE status = 'blocked')
tasks_done (SELECT COUNT(*) FROM task WHERE status = 'done')
tasks_failed (SELECT COUNT(*) FROM task WHERE status = 'failed')
tasks_waived (SELECT COUNT(*) FROM task WHERE status = 'waived')
plans_total (SELECT COUNT(*) FROM plan)
findings_total (SELECT COUNT(*) FROM review_finding)
findings_open (SELECT COUNT(*) FROM review_finding WHERE disposition IN ('open','fixing'))
bugs_total (SELECT COUNT(*) FROM bug)
bugs_open (SELECT COUNT(*) FROM bug WHERE status IN ('open','fixing'))
bugs_critical (SELECT COUNT(*) FROM bug WHERE status IN ('open','fixing') AND severity = 'critical')
coverage_total (SELECT COUNT(*) FROM coverage)
coverage_never (SELECT COUNT(*) FROM coverage WHERE COALESCE(last_inspected_at,'') = '')
coverage_specced (SELECT COUNT(*) FROM coverage WHERE COALESCE(spec_path,'') <> '')
inspections_total (SELECT COUNT(*) FROM inspection)
docs_total (SELECT COUNT(*) FROM doc)
events_total (SELECT COUNT(*) FROM event)
graph_nodes (SELECT COUNT(*) FROM graph_node)
graph_edges (SELECT COUNT(*) FROM graph_edge)
FACTS
  )"

  cat <<SQL
$meta_sql;

SELECT line FROM ($hsel) ORDER BY o;

SELECT 'A ' || $goal_expr
  FROM goal g
 ORDER BY g.priority, g.id
 LIMIT 200;

SELECT 'B ' || $phase_expr
  FROM phase p
 ORDER BY p.goal_id, p.ordinal, p.id
 LIMIT 500;

SELECT 'C ' || $req_expr
  FROM requirement r
 ORDER BY r.id
 LIMIT 500;

SELECT 'D ' || $task_expr
  FROM task t
 ORDER BY t.id
 LIMIT 2000;

SELECT 'E ' || $bug_expr
  FROM bug b
 WHERE b.status IN ('open','fixing')
 ORDER BY $(_brief_severity_rank 'b.severity'), b.id
 LIMIT 500;

-- Findings are NOT filtered to the unresolved ones the way bugs are: a fixed finding is
-- the evidence that the flag was answered, and a view that showed only open rows could
-- not tell "nobody ever looked" apart from "somebody looked and fixed it". They are
-- ORDERED unresolved-first instead, which is what makes the cap honest — when a guild has
-- more than 500 findings, the 500 that survive are the ones still owed work.
--
-- NOTE: this heredoc is UNQUOTED, so a backtick or a bare dollar in a comment here is
-- executed by the shell, not written to the SQL. Comments in this block stay plain.
--
-- open and fixing lead, in that order, and everything else follows -- the SAME set the
-- findings_open count above uses, the same set the Review Findings section of guild brief
-- uses, and the same set the filter on the page itself opens on. Severity comes from
-- _brief_severity_rank, the one ladder both surfaces share.
SELECT 'R ' || $find_expr
  FROM review_finding f
  LEFT JOIN task t ON t.id = f.task_id
 ORDER BY CASE f.disposition WHEN 'open' THEN 1 WHEN 'fixing' THEN 2 ELSE 3 END,
          $(_brief_severity_rank 'f.severity'),
          f.id
 LIMIT 500;

SELECT 'F ' || $cov_expr
  FROM coverage c
 ORDER BY CASE c.risk WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END,
          CASE WHEN COALESCE(c.last_inspected_at,'') = '' THEN 0 ELSE 1 END,
          c.last_inspected_at, c.id
 LIMIT 300;

SELECT 'G ' || line FROM (
  SELECT e.ts AS ts, e.id AS eid, $act_expr AS line
    FROM event e
   ORDER BY e.ts DESC, e.id DESC
   LIMIT 300
) ORDER BY ts DESC, eid DESC;

SELECT 'N ' || $node_expr
  FROM graph_node n
 ORDER BY n.requirement_id, n.node_key, n.id
 LIMIT 2000;

SELECT 'X ' || $edge_expr
  FROM graph_edge x
 ORDER BY x.from_node, x.to_node
 LIMIT 2000;
SQL
}

# ---- the data document ------------------------------------------------------------------

# _dash_json <rows-file> — fold the tagged rows into the JSON document that gets inlined.
#
# awk assembles arrays and objects; it never composes a VALUE, because every value arrived
# pre-escaped from json_object(). The one transformation it applies is `jsafe`, which is
# the whole HTML-safety argument (see THE OUTPUT CHANNEL in the header): after it, the
# document holds no `<`, `>` or `&` byte anywhere.
#
# jsafe walks the string with match()/substr() and CONCATENATES the replacement, rather
# than gsub()-ing it in: a gsub replacement string treats `\` specially and POSIX leaves
# `\uXXXX` there undefined. `json_escape` in lib/db.sh made the same choice for the same
# reason — one discipline, not two.
#
# Rows that do not begin with a tag are driver noise (a banner, a blank line between
# statements) and are DROPPED, never folded onto the previous row: folding is how the
# Stage 1 injections landed, and a json_object row is always exactly one line, so no
# legitimate continuation line exists.
_dash_json() {
  LC_ALL=C awk '
    BEGIN {
      esc["<"] = "\\u003c"
      esc[">"] = "\\u003e"
      esc["&"] = "\\u0026"
    }
    # jsafe — rewrite every <, > and & as its \uXXXX escape. Lossless: none of the three
    # appears in a JSON structural token, so every occurrence is inside a string.
    function jsafe(s,   out, c) {
      out = ""
      while (match(s, /[<>&]/)) {
        c = substr(s, RSTART, 1)
        out = out substr(s, 1, RSTART - 1) esc[c]
        s = substr(s, RSTART + 1)
      }
      return out s
    }

    /^[A-Z] / {
      tag = substr($0, 1, 1)
      txt = substr($0, 3)
      if (tag == "M") { if (substr(txt, 1, 1) == "{") meta = jsafe(txt); next }
      if (tag == "H") {
        eq = index(txt, "=")
        if (eq > 1) { hk[++hn] = substr(txt, 1, eq - 1); hv[hn] = substr(txt, eq + 1) }
        next
      }
      if (substr(txt, 1, 1) != "{") next
      n[tag]++
      row[tag, n[tag]] = jsafe(txt)
      next
    }
    { next }

    function arr(name, tag, comma,   i) {
      if (n[tag] + 0 == 0) { printf "  \"%s\": []%s\n", name, comma; return }
      printf "  \"%s\": [\n", name
      for (i = 1; i <= n[tag]; i++)
        printf "    %s%s\n", row[tag, i], (i < n[tag] ? "," : "")
      printf "  ]%s\n", comma
    }

    END {
      print "{"
      printf "  \"meta\": %s,\n", (meta == "" ? "{}" : meta)
      # The summary values are COUNT() results, so the digit check can only ever pass —
      # which is the point: no path exists by which a non-number reaches a JSON number.
      printf "  \"summary\": {"
      for (i = 1; i <= hn; i++) {
        v = hv[i]
        if (v !~ /^-?[0-9]+$/) v = "0"
        printf "%s\n    \"%s\": %s", (i > 1 ? "," : ""), hk[i], v
      }
      print (hn > 0 ? "\n  }," : "},")
      arr("goals",        "A", ",")
      arr("phases",       "B", ",")
      arr("requirements", "C", ",")
      arr("tasks",        "D", ",")
      arr("bugs",         "E", ",")
      arr("findings",     "R", ",")
      arr("coverage",     "F", ",")
      arr("activity",     "G", ",")
      print "  \"graph\": {"
      if (n["N"] + 0 == 0) {
        print "    \"nodes\": [],"
      } else {
        print "    \"nodes\": ["
        for (i = 1; i <= n["N"]; i++) printf "      %s%s\n", row["N", i], (i < n["N"] ? "," : "")
        print "    ],"
      }
      if (n["X"] + 0 == 0) {
        print "    \"edges\": []"
      } else {
        print "    \"edges\": ["
        for (i = 1; i <= n["X"]; i++) printf "      %s%s\n", row["X", i], (i < n["X"] ? "," : "")
        print "    ]"
      }
      print "  }"
      print "}"
    }
  ' "$1"
}

# _dash_data <out-file> — run the query once and write the data document.
_dash_data() {
  local out="$1" rows sqlf
  rows="$(_render_tmp dash-rows)"
  sqlf="$(_render_tmp dash-sql)"
  _dash_sql >"$sqlf"
  _render_query "$sqlf" "$rows" "guild: could not read the dashboard data from the database"
  _dash_json "$rows" >"$out"
  rm -f "$rows"
}

# ---- composing the page -------------------------------------------------------------------

# _dash_compose <template> <data-file> <out-file> — substitute the data into the template.
#
# Streamed by awk, one line at a time, so a large data document costs no quadratic string
# handling (rule 4: `${var%%pattern*}` over a 400 KB value takes 24 seconds under bash 3.2).
# The marker is matched as a WHOLE LINE with `==`, never as a substring and never as a
# regex, so nothing in the template or the data can be mistaken for it — and the data is
# emitted verbatim, since it has already been made safe for this element.
_dash_compose() {
  local tmpl="$1" data="$2" out="$3" hits
  hits="$(LC_ALL=C grep -c -x '@@GUILD_DASHBOARD_DATA@@' "$tmpl" 2>/dev/null || true)"
  case "$hits" in
    1) ;;
    *)
      die "guild: the dashboard template must hold exactly ONE @@GUILD_DASHBOARD_DATA@@ line, and $tmpl has ${hits:-0}.
It is a generated-page template, not a document to edit by hand."
      ;;
  esac

  if ! LC_ALL=C awk -v DATA="$data" '
      $0 == "@@GUILD_DASHBOARD_DATA@@" {
        while ((getline line < DATA) > 0) print line
        close(DATA)
        next
      }
      { print }
    ' "$tmpl" >"$out"
  then
    rm -f -- "$out"
    die "guild: could not compose the dashboard from $tmpl"
  fi
}

# _dash_open <file> — hand the file to the desktop, and NEVER fail the command for it.
#
# `--open` is a convenience on top of a file that has already been written successfully;
# a headless box, a container or a Linux without xdg-utils must get the path and a zero
# exit, not an error about a missing opener.
_dash_open() {
  local f="$1"
  if command -v open >/dev/null 2>&1; then
    if open "$f" >/dev/null 2>&1; then return 0; fi
    printf 'guild: could not open %s — open it yourself.\n' "$f" >&2
    return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    if xdg-open "$f" >/dev/null 2>&1; then return 0; fi
    printf 'guild: could not open %s — open it yourself.\n' "$f" >&2
    return 0
  fi
  printf 'guild: no open or xdg-open on PATH — open it yourself:\n  %s\n' "$f" >&2
  return 0
}

# _dash_is_dirname <path> — true when the path names a DIRECTORY rather than a file: it
# either is one on disk, or it ends in `/`, which says so whether or not it exists yet.
_dash_is_dirname() {
  [ -d "$1" ] && return 0
  case "$1" in
    */) return 0 ;;
  esac
  return 1
}

# dashboard_run <mode> <out-path> <open-flag> — the command, minus argument parsing.
#
#   mode `json`  print the data document, write no file
#   mode `html`  compose the page into <out-path> atomically, then optionally open it
dashboard_run() {
  local mode="$1" out="$2" want_open="$3" tmpl data stage dir
  db_require_init

  # `--out` NAMES THE FILE, NOT THE FOLDER IT GOES IN — and a directory has to be refused
  # here rather than discovered by `mv`. Without this check `--out site` staged
  # `site.tmp.$$` beside the directory and then renamed it INTO it, so the command printed
  # "Dashboard written to site", exited 0, and left the staging file as the only output —
  # under its temp name, which is the one filename nothing will ever serve or open. That is
  # exactly the "THE TEMP FILE IS NEVER THE OUTPUT" rule in this file's header, broken at
  # the one input that invites it: the dashboard skill's own `--out` table suggests "a
  # directory they serve".
  #
  # A TRAILING SLASH IS A DIRECTORY NAME WHETHER OR NOT THE DIRECTORY EXISTS. `-d` alone
  # answers only the half of that question the filesystem knows about: `--out site/` was
  # caught when `site` was already there, and `--out nosuch/` walked straight past it,
  # because `dirname -- "nosuch/"` answers `.` — which exists, so nothing was created — and
  # the staging redirect then failed in the SHELL's voice (`line 440: nosuch/.tmp.70657: No
  # such file or directory`) before the guild printed a second, vaguer error of its own. Two
  # messages, the louder one not ours, for an input the `-d` test already knows how to
  # explain in one. `_dash_is_dirname` answers both spellings, so both get that one answer.
  if [ "$mode" != json ] && _dash_is_dirname "$out"; then
    die "guild: dashboard --out names the FILE to write, and '$out' is a directory.
Give it a filename — e.g. --out ${out%/}/dashboard.html"
  fi

  data="$(_render_tmp dash-data)"
  _dash_data "$data"

  if [ "$mode" = json ]; then
    cat "$data"
    rm -f "$data"
    return 0
  fi

  tmpl="$(guild_dashboard_template)"

  # EVERY UTILITY THAT TOUCHES `$out` GETS `--`. The path is argv, and argv can start with
  # a dash: `--out -weird.html` made `dirname` print `dirname: illegal option -- w` and
  # exit 1, which is a coreutils error message wearing the guild's exit code. `--` ends
  # option parsing, so a leading dash is a filename again and any failure that remains is
  # the guild's own, phrased in the guild's voice.
  dir="$(dirname -- "$out")"
  [ -d "$dir" ] || mkdir -p -- "$dir" || die "guild: cannot create $dir"

  # Staged next to the target so the rename is on one filesystem and therefore atomic:
  # an interrupted run leaves the PREVIOUS dashboard in place rather than a half-written
  # file that a browser would happily render.
  stage="$out.tmp.$$"
  rm -f -- "$stage"
  _dash_compose "$tmpl" "$data" "$stage"
  rm -f "$data"
  mv -f -- "$stage" "$out" || { rm -f -- "$stage"; die "guild: could not write $out"; }

  printf 'Dashboard written to %s\n' "$out"
  # An `if`, never `[ ... ] && ...`: under `set -euo pipefail` an AND-list whose test
  # fails IS a failed command, and the dispatcher would exit 1 on a successful render
  # that simply was not asked to open anything.
  if [ "$want_open" = 1 ]; then _dash_open "$out"; fi
  return 0
}

# cmd_dashboard [--open] [--out PATH] [--json] — the dispatcher entry point (design §9).
cmd_dashboard() {
  local mode="html" want_open=0 out="" nl
  nl=$'\n'
  while [ $# -gt 0 ]; do
    case "$1" in
      --open | -o) want_open=1 ;;
      --json) mode="json" ;;
      --out)
        shift
        [ $# -gt 0 ] || die "guild: dashboard --out needs a path (e.g. --out docs/guild.html)"
        out="$1"
        ;;
      --out=*) out="${1#--out=}" ;;
      -*) die "guild: unknown option '$1' for dashboard (try 'guild dashboard [--open] [--out PATH] [--json]')" ;;
      *) die "guild: dashboard takes no positional arguments (got '$1')" ;;
    esac
    shift
  done

  # A path is a shell-facing value, not board state: it is never stored and never
  # rendered, but an empty or multi-line one would produce a file nobody can name.
  case "$out" in
    *"$nl"*) die "guild: dashboard --out must be a single line" ;;
  esac
  if [ "$mode" = json ] && [ -n "$out" ]; then
    die "guild: dashboard --json prints the data and writes no file — drop --out, or drop --json"
  fi
  if [ "$mode" = json ] && [ "$want_open" = 1 ]; then
    die "guild: dashboard --json prints the data and writes no file — there is nothing to open"
  fi
  [ -n "$out" ] || out="$GUILD_DIR/dashboard.html"

  dashboard_run "$mode" "$out" "$want_open"
}
