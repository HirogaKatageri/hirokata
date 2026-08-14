# shellcheck shell=bash
#
# lib/graph.sh — guild v5 Stage 4: THE EXECUTION GRAPH (design §6.1-§6.3).
#
#   > Template + justified deviation.
#
# In v4 (and in Stage 1-3 of v5) the chain is hardcoded: requirement -> plan -> developer
# tickets -> test-planner -> reviewers, with a special-cased review gate in `guild next`.
# In v5 that chain is DATA — two YAML templates shipped with the plugin — instantiated
# per requirement into `graph_node` / `graph_edge` rows the rest of Stage 4 reads.
#
#   guild graph new <REQ-NNN> [--template standard|maintenance]   instantiate
#   guild graph <REQ-NNN> [--explain]     render; --explain diffs template vs actual
#   guild graph validate <REQ-NNN>        the deviation rules, with teeth
#   guild graph deviate <REQ-NNN> --kind K --node KEY --reason "..."   [+ extras]
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` (scripts/guild owns those).
# Bash 3.2 compatible: no associative arrays, no `declare -A`, no `mapfile`, no ${var^^}.
#
# Depends on lib/db.sh       : die, db_fail, db_require_init, db_exec, db_query, db_now,
#                              sql_str, sql_text
#          on lib/journal.sh : journal_preflight, journal_append
#          on lib/artifacts.sh: _art_actor, _art_json_row, _art_next_id_expr,
#                              _art_capability, _art_capability_rows, _art_capability_sql,
#                              _art_capability_payload, _art_created_event_sql,
#                              _art_defuse_body
#          on lib/records.sh : _rec_check_slug (THE identifier alphabet)
#          on lib/render.sh  : _render_flat, _render_flat_arg, _render_col, _render_tmp,
#                              _render_query
#
# THOSE DEPENDENCIES ARE DELIBERATE REUSE, NOT CONVENIENCE — the rule lib/records.sh,
# lib/quality.sh and lib/roster.sh all state in their headers. Three of them matter here
# in particular:
#
#   * `_art_capability` IS the capability alphabet `guild new task --needs` enforces.
#     `graph deviate --kind add-node --needs` writes a `task_capability` row that the
#     matcher will later compare for EQUALITY against an agent's declaration, so a second
#     alphabet here would be a capability that can be required and never declared.
#   * `_art_capability_sql` / `_art_created_event_sql` locate a task the script has just
#     inserted but whose id did not exist when the script was composed. `add-node` creates
#     a real ticket, so it speaks that protocol rather than inventing a second one — and
#     it must compose the two IN THAT ORDER, because the capability insert's exactness
#     guard is "this task has not been announced yet".
#   * `_render_col` / `_render_flat` are the output-channel discipline, applied below to
#     a marker channel of this module's own (see THE MARKER CHANNEL).
#
# ---------------------------------------------------------------------------------
# HARD RULES honored throughout (§2.2, §2.2.1, §3.0):
#
#   * ONE db_exec PER LOGICAL COMMAND. `graph new` composes ONE script covering every
#     node, every edge, both gates, the template record, the event and the journal
#     markers, and runs it once. The statement count grows with the TEMPLATE (8 nodes
#     today), never with the board — the distinction lib/db.sh's header draws. Nothing
#     here loops over data and calls the driver inside the loop.
#
#     THE THREE COMMANDS THAT NEED A BASELINE TAKE ONE PRIOR ROUND TRIP, and it is not a
#     loophole: `--explain`, `validate` and `deviate` must know WHICH TEMPLATE built the
#     graph before they can compose anything, because that answer decides which file the
#     shell opens and parses. It cannot be folded into the mutation, since the mutation's
#     shape depends on it. Everything after that read is still exactly one script.
#
#   * sql_text FOR ALL FREE TEXT; sql_str ONLY for known-safe alphabets. A gate PROMPT, a
#     deviation REASON and a ticket TITLE are paragraphs somebody typed, and a reason
#     routinely quotes the code it is about — a line ending in `;` tears a quoted literal
#     in half (§2.2.1), so all three travel as hex. Only values validated here against a
#     closed alphabet (a node key, a template name, a capability, an agent name, a REQ id,
#     an enum) reach SQL through sql_str.
#
#   * NEVER `WITH RECURSIVE` — and this is the stage where that bites, because a
#     dependency graph is the textbook recursive-CTE query. IT IS NOT NEEDED: a node is
#     READY WHEN ALL OF ITS DIRECT PREDECESSORS ARE DONE, which is a plain join
#     (`_graph_ready_where`). Readiness propagates ONE NODE AT A TIME as the segment runs,
#     rather than being computed transitively up front. Every traversal in this file —
#     readiness, the render's predecessor column, drop-node's edge stitching — is
#     ONE HOP. The template's own acyclicity is guaranteed at PARSE time instead, by
#     requiring every `after:` reference to name a node declared EARLIER in the file: a
#     graph whose edges all point backwards in declaration order cannot contain a cycle,
#     and that is a linear check rather than a traversal.
#
#   * A VALUE MUST NEVER IMPERSONATE A STRUCTURAL TOKEN. See THE MARKER CHANNEL below.
#
#   * EVERY MUTATION IS JOURNALED AND EMITS AN `event` ROW. journal_preflight runs BEFORE
#     any SQL, so an unwritable journal is a refusal that says nothing was written rather
#     than a board change `guild rebuild` silently undoes.
#
#   * No quadratic string handling. The template file is size-capped and line-capped at
#     parse time, marker lines are split by `read` with a fixed variable list (which is
#     one linear pass and leaves the free-text remainder in the LAST variable), and no
#     `${v#*pat}` is ever applied to an unbounded value.
#
# ---------------------------------------------------------------------------------
# THE MARKER CHANNEL
#
# Every command here gets its result back from the driver as pipe-separated marker lines:
#
#   EXISTS|<n>              pre-state, emitted FIRST so it describes the world before
#                           any INSERT in the same script landed
#   MISS|<ref>              a referenced row does not exist
#   OK|<n>|<n>|<n>          the command's counts
#   FAIL|<code>|<detail>    a validation failure
#   R|<table>|<op>|<json>   a row to journal
#
# THE ONLY FIELD THAT MAY CONTAIN A PIPE IS THE LAST ONE, and every reader splits on a
# FIXED NUMBER of leading delimiters rather than on all of them (`IFS='|' read -r a b c d`
# puts the whole remainder, delimiters intact, in `d`). That is lib/render.sh's rule
# applied to an internal channel: `_graph_field` — `_render_col` plus a pipe replacement —
# wraps every value in a non-final position, so a plan-slice slug or an agent name cannot
# forge a field boundary, a blank or a line break. `json_object` escapes control
# characters, so an `R|` row is always exactly one line, which is also what
# `journal_append` requires.
#
# ---------------------------------------------------------------------------------
# INSTANTIATION, AND THE ONE INVARIANT THAT MAKES `validate` MEAN ANYTHING
#
# EVERY TEMPLATE NODE KEY GETS AT LEAST ONE `graph_node` ROW. Fanout decides how many:
#
#   fixed                  one node per named agent in `agents:`; ONE unfanned node when
#                          the template names none (`test-plan`, `qa-plan`)
#   per-slice              one node per `plan_slice` of the requirement's plans — and ONE
#                          unfanned node when the plan has no slices yet
#   per-declaration        ONE node now; the test-planner's declarations add siblings at
#   per-approved-finding   run time, as the gate's selections and the strategist's
#   per-mission            missions become known
#
# The alternative — leaving a `per-declaration` key with zero rows until run time — breaks
# the graph in a way that is silent and dangerous: `review` is `after: [test-write]`, so
# with no `test-write` row there is no edge into `review`, `review` has no unfinished
# direct predecessor, and IT IS IMMEDIATELY READY. Review would run before anything was
# written. So the key is always present as its own barrier anchor and grows siblings
# beside it.
#
# The invariant is also what makes "dropped" unambiguous for `guild graph validate`:
# a template key with no instance was DROPPED, full stop, with no "unless its fanout
# happened to be empty" caveat for an architect to hide behind.
#
# TASK BINDING IS BEST-EFFORT AND DELIBERATELY NARROW. `graph_node.task_id` is set only
# where the correspondence is UNAMBIGUOUS — a per-slice node binds the ticket carrying
# that plan slice, a fixed-with-agents node binds the ticket pinned to that agent. Every
# other node starts with a NULL task and is bound when it is dispatched. Binding a
# `needs: [qa-planning]` node by capability was tried and abandoned: `maintenance` has
# THREE such nodes and one qa-strategist ticket, so all three would bind the same task and
# the graph would claim a correspondence that does not exist. A NULL is honest; a wrong
# link is read as fact by everything downstream.
#
# ---------------------------------------------------------------------------------
# DEVIATION, WITH TEETH (§6.3) — WHAT IS REFUSED, AND WHERE
#
# Each rule is enforced TWICE, at the point of attempt and again by `validate`, because
# `graph_deviation` and `graph_node` rows can also arrive by journal replay from another
# machine — and a rule that only lives in an argument parser is not a rule about the
# board, it is a rule about this process.
#
#   a gate may never be DROPPED     `deviate --kind drop-node` refuses a gate key;
#                                   `validate` fails a template gate key with no instance
#   NO NEW GATE MAY BE ADDED        `deviate --kind add-gate` is refused OUTRIGHT, always,
#                                   whatever the reason; `validate` fails any `add-gate`
#                                   deviation row and any `kind = 'gate'` node whose key
#                                   is not one of the template's own
#   `required: true` never dropped  refused at attempt; `validate` fails a missing one
#   a NON-EMPTY reason, always      whitespace-only is empty; refused at attempt, and
#                                   `validate` fails a stored row that is blank
#   add-node names a REAL capability  `--needs` is mandatory, alphabet-checked, and the
#                                   INSERT itself is conditioned on an ACTIVE roster
#                                   member declaring every one of them
#
# WHY ADDING A GATE IS THE ONE THAT GETS THE FLAT REFUSAL. Dropping a gate is the obvious
# failure mode and reads as an attack. Adding one reads as caution — "I would like to
# check in before the migrations run" — and it is the more expensive mistake: gates are
# the boundary at which unattended operation stops and notifies (§8), so a third gate
# quietly converts a shift that runs overnight into a session that stops every twenty
# minutes waiting for a human who is asleep. There is no reason good enough, because the
# cost is not paid at the moment of the decision.

# ---- the alphabets ------------------------------------------------------------------

# _graph_check_req <id> — die unless <id> is a requirement id this file may CONCATENATE.
#
# Stricter than the `case "$id" in REQ-*)` the rest of the CLI uses, and deliberately so:
# a node's primary key is BUILT from this value (`REQ-007/implement.auth-service`), so it
# is not merely a lookup key here. Validating it to `REQ-` plus digits is what justifies
# sending it to SQL through `sql_str` and what keeps every node id blank-free at the
# source rather than repairing it on the way out.
_graph_check_req() {
  local v="${1-}"
  local LC_ALL=C
  [ -n "$v" ] || die "guild: this command requires a requirement id (REQ-NNN)"
  case "$v" in
    REQ-[0-9]*)
      case "${v#REQ-}" in
        *[!0-9]*) die "guild: '$v' is not a requirement id (expected REQ-NNN)" ;;
      esac
      ;;
    *) die "guild: '$v' is not a requirement id (expected REQ-NNN)" ;;
  esac
  [ "${#v}" -le 32 ] || die "guild: '$v' is not a requirement id (expected REQ-NNN)"
}

# _graph_check_key <key> <what> — die unless <key> is a well-formed NODE KEY.
#
# Lowercase, digits and hyphen, leading letter — `_roster_check_cap`'s alphabet rather
# than `_rec_check_slug`'s, and for the same reason that function gives: a node key is
# compared for EQUALITY (against the template, against `graph_node.node_key`, against a
# deviation's `node_key`) and never normalized, so `Test-Plan` and `test-plan` would be
# two keys that read as one and `validate` would report a dropped node that is right
# there. It is also concatenated into a primary key, so it must be blank-free at source.
_graph_check_key() {
  local v="${1-}" what="${2:---node}"
  local LC_ALL=C
  [ -n "$v" ] || die "guild: $what requires a node key (for example 'implement')"
  [ "${#v}" -le 64 ] ||
    die "guild: that node key is ${#v} characters; the limit is 64 — a key is a name, not a sentence"
  case "$v" in
    [a-z]*) ;;
    *) die "guild: '$v' is not a valid node key for $what — it must start with a lowercase letter" ;;
  esac
  case "$v" in
    *[!a-z0-9-]*)
      die "guild: '$v' is not a valid node key for $what.

A node key is compared for equality against the template and never normalized, so it is
limited to lowercase letters, digits and '-' — 'implement', 'test-plan', 'gate-repairs'."
      ;;
  esac
}

# _graph_check_template_name <name> — die unless <name> can safely become a FILENAME.
#
# This value is joined to a directory and opened, so the alphabet is the whole defence:
# no `/`, no `.`, hence no `..`. `_rec_check_slug` is not reused here precisely because it
# ADMITS `.` — correct for a doc slug, wrong for a path component.
_graph_check_template_name() {
  local v="${1-}"
  local LC_ALL=C
  [ -n "$v" ] || die "guild: --template requires a template name (standard or maintenance)"
  [ "${#v}" -le 64 ] || die "guild: that template name is ${#v} characters; the limit is 64"
  case "$v" in
    [a-z]*) ;;
    *) die "guild: '$v' is not a valid template name — it must start with a lowercase letter" ;;
  esac
  case "$v" in
    *[!a-z0-9-]*)
      die "guild: '$v' is not a valid template name.

A template name is a FILE NAME (templates/<name>.yaml), so it is limited to lowercase
letters, digits and '-'. The two that ship are 'standard' and 'maintenance'."
      ;;
  esac
}

# _graph_check_reason <reason> — die unless the reason has non-whitespace content.
#
# §6.3: "Every deviation writes a `graph_deviation` row carrying a NON-EMPTY reason."
# Whitespace-only is empty — a reason of `" "` satisfies a `[ -n ]` test and tells the
# guild master nothing six months later, which is the entire value of the record. The
# same question is asked again in SQL by `validate`, over `replace()` rather than `trim()`
# because only `replace` is on §3.0's verified list.
_graph_check_reason() {
  local v="${1-}" stripped
  stripped="$(printf '%s' "$v" | LC_ALL=C tr -d '[:space:]')"
  [ -n "$stripped" ] && return 0
  die "guild: --reason is required and must not be blank.

A deviation from the template is a decision somebody will have to understand later —
'the API is undocumented, so research goes ahead of implement', 'docs-only change, no
test plan'. That sentence IS the record; the graph without it is just a bespoke shape
nobody can diff against a baseline (design 6.3)."
}

# ---- the templates: locating them ----------------------------------------------------

# _graph_templates_dirs — the search path for `<name>.yaml`, most specific first.
#
#   $GUILD_TEMPLATES_DIR      an explicit override, for tests and for one-off shapes
#   $GUILD_DIR/templates      THE PROJECT OVERRIDE — §6.1: "shipped with the plugin,
#                             overridable per project at .guild/templates/"
#   <plugin>/templates        what ships
#
# Resolved the way `guild_schema_path` resolves schema.sql, and for its reason: this file
# is sourced from an arbitrary cwd and the plugin may be symlinked onto $PATH.
_graph_templates_dirs() {
  local here=""
  [ -z "${GUILD_TEMPLATES_DIR:-}" ] || printf '%s\n' "$GUILD_TEMPLATES_DIR"
  printf '%s\n' "${GUILD_DIR:-.guild}/templates"
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || here=""
  fi
  [ -z "$here" ] || printf '%s\n' "$here/../../templates"
  [ -z "${CLAUDE_PLUGIN_ROOT:-}" ] || printf '%s\n' "$CLAUDE_PLUGIN_ROOT/templates"
}

# _graph_template_path <name> — the first readable `<name>.yaml` on that path.
_graph_template_path() {
  local name="${1-}" d tried=""
  _graph_check_template_name "$name"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ -f "$d/$name.yaml" ]; then
      printf '%s\n' "$d/$name.yaml"
      return 0
    fi
    tried="$tried  $d/$name.yaml
"
  done <<EOF
$(_graph_templates_dirs)
EOF
  die "guild: no template named '$name' — looked in:

$tried
Two templates ship with the plugin: 'standard' (build a requirement) and 'maintenance'
(inspect what was built). A project may override either, or add its own, by dropping a
file at ${GUILD_DIR:-.guild}/templates/$name.yaml."
}

# ---- the templates: the parser -------------------------------------------------------

# _graph_parser_src — the awk program that reads the template YAML SUBSET.
#
# THERE IS NO YAML LIBRARY AND THERE MAY NOT BE ONE: this CLI depends on the turso
# binaries and coreutils, and nothing else — no python, no jq, no node, no yq. So the
# subset is small, closed, and REFUSED BY NAME AND LINE NUMBER when a file steps outside
# it, which is the only honest way to hand-parse a format with a real specification. What
# is accepted:
#
#   name: <scalar>            top level, before `nodes:`
#   description: <scalar>
#   nodes:
#     - key: <scalar>         a node begins; 2-space indent, `- ` marker
#       kind: work|gate       4-space indent thereafter
#       required: true|false
#       fanout: fixed|per-slice|per-declaration|per-approved-finding|per-mission
#       parallel: all|by-group|never
#       needs: [cap, cap]     inline lists only
#       agents: [name, name]
#       after: [key, key]
#       prompt: "<text>"      gates only
#       kind_detail: approve|select-findings
#
# A scalar is bare, 'single-quoted' or "double-quoted" (with \" and \\ understood). A `#`
# begins a comment on its own line, or after a bare scalar when preceded by a space —
# never inside quotes. TABS AND CARRIAGE RETURNS ARE REFUSED OUTRIGHT rather than
# tolerated: YAML forbids tabs for indentation, and a file whose meaning depends on
# whether the reader expands them is a file that means two things.
#
# EVERY VALUE IS VALIDATED HERE, not merely extracted. Enums are checked against their
# closed sets, keys and list tokens against their alphabets — which is what lets the shell
# send all of them to SQL through `sql_str`. The prompt is the ONE free-text value, and it
# is the last field on the emitted line for exactly that reason.
#
# ACYCLICITY IS A PARSE-TIME PROPERTY. Every `after:` reference must name a node declared
# EARLIER in the file. A graph whose every edge points backwards in declaration order
# cannot contain a cycle, so the template is proved acyclic by a linear scan — which is
# how this stage avoids the `WITH RECURSIVE` cycle check that §3.0 forbids and that would
# have failed on local mode only.
#
# Output, one line per node then one for the template, all fields alphabet-validated
# except the last:
#
#   NODE|<ord>|<key>|<kind>|<required>|<fanout>|<parallel>|<needs>|<agents>|<after>|<detail>|<prompt>
#   TPL|<name>|<description>
#
# Failure is `E|<line>|<message>` and exit status 3, so the shell can `die` with the
# file and the line rather than reporting an empty template.
_graph_parser_src() {
  cat <<'PARSER'
function fail(msg) { printf("E|%d|%s\n", NR, msg); failed = 1; exit 3 }
function bad(msg)  { printf("E|0|%s\n", msg); failed = 1; exit 3 }
function trim(s) { sub(/^[ ]+/, "", s); sub(/[ ]+$/, "", s); return s }
function keyok(s) { return (s ~ /^[a-z][a-z0-9-]*$/) && length(s) <= 64 }
function tokok(s) { return (s ~ /^[a-z][a-z0-9._-]*$/) && length(s) <= 64 }

# scalar(s) — one YAML scalar off the front of s.
function scalar(s,   c, i, n, out, ch, nx, rest) {
  s = trim(s)
  if (s == "") return ""
  c = substr(s, 1, 1)
  if (c == "\"" || c == "'") {
    out = ""; n = length(s); i = 2
    while (i <= n) {
      ch = substr(s, i, 1)
      if (c == "\"" && ch == "\\") {
        nx = substr(s, i + 1, 1)
        if (nx == "\"" || nx == "\\") { out = out nx; i += 2; continue }
        fail("unsupported escape \\" nx " inside a quoted value")
      }
      if (ch == c) {
        rest = trim(substr(s, i + 1))
        if (rest != "" && substr(rest, 1, 1) != "#") fail("trailing text after a quoted value")
        return out
      }
      out = out ch
      i++
    }
    fail("unterminated quoted value")
  }
  i = index(s, " #")
  if (i > 0) s = substr(s, 1, i - 1)
  return trim(s)
}

# listv(s, field) — an inline [a, b] list, validated and comma-joined.
function listv(s, field,   i, inner, n, parts, k, tok, joined, rest) {
  s = trim(s)
  if (substr(s, 1, 1) != "[") fail("field '" field "' must be an inline list, like [a, b]")
  i = index(s, "]")
  if (i == 0) fail("field '" field "' has no closing ']' on the same line")
  rest = trim(substr(s, i + 1))
  if (rest != "" && substr(rest, 1, 1) != "#") fail("trailing text after the '" field "' list")
  inner = trim(substr(s, 2, i - 2))
  if (inner == "") return ""
  n = split(inner, parts, ",")
  joined = ""
  for (k = 1; k <= n; k++) {
    tok = trim(parts[k])
    if (tok == "") fail("empty item in the '" field "' list (a doubled or trailing comma?)")
    if (!tokok(tok)) fail("'" tok "' is not a valid '" field "' item — lowercase letters, digits, '.', '_' and '-' only")
    joined = joined (joined == "" ? "" : ",") tok
  }
  return joined
}

function setfield(o, t,   i, f, v) {
  i = index(t, ":")
  if (i == 0) fail("expected 'field: value'")
  f = trim(substr(t, 1, i - 1))
  v = substr(t, i + 1)
  if (f == "key")         { if (nkey[o] != "") fail("duplicate 'key:' in one node"); nkey[o] = scalar(v); return }
  if (f == "kind")        { nkind[o]   = scalar(v); return }
  if (f == "fanout")      { nfan[o]    = scalar(v); return }
  if (f == "parallel")    { npar[o]    = scalar(v); return }
  if (f == "required")    { nreq[o]    = scalar(v); return }
  if (f == "kind_detail") { ndet[o]    = scalar(v); return }
  if (f == "prompt")      { nprompt[o] = scalar(v); return }
  if (f == "needs")       { nneeds[o]  = listv(v, "needs");  return }
  if (f == "agents")      { nagents[o] = listv(v, "agents"); return }
  if (f == "after")       { nafter[o]  = listv(v, "after");  return }
  fail("unknown node field '" f "' (expected key, kind, required, fanout, parallel, needs, agents, after, prompt, kind_detail)")
}

BEGIN { ord = 0; state = "top"; failed = 0 }

{
  if (index($0, "\t")) fail("tab characters are not allowed in a template (YAML forbids them for indentation)")
  if (index($0, "\r")) fail("carriage returns are not allowed in a template")
  if (length($0) > 4096) fail("this line is longer than 4096 characters")
  line = $0
  t = line
  sub(/^[ ]*/, "", t)
  if (t == "" || substr(t, 1, 1) == "#") next
  ind = length(line) - length(t)

  if (ind == 0) {
    i = index(t, ":")
    if (i == 0) fail("expected 'field: value' at the top level")
    f = trim(substr(t, 1, i - 1))
    v = substr(t, i + 1)
    if (f == "nodes") {
      if (trim(v) != "" && substr(trim(v), 1, 1) != "#") fail("'nodes:' takes no value on its own line")
      state = "nodes"
      next
    }
    if (state == "nodes") fail("top-level field '" f "' appears after 'nodes:'; it must come before")
    if (f == "name")        { tplname = scalar(v); next }
    if (f == "description") { tpldesc = scalar(v); next }
    fail("unknown top-level field '" f "' (expected name, description, nodes)")
  }

  if (state != "nodes") fail("indented line before 'nodes:'")

  if (ind == 2) {
    if (substr(t, 1, 2) != "- ") fail("a node begins with '- key: <name>' at two spaces of indent")
    ord++
    setfield(ord, trim(substr(t, 3)))
    if (nkey[ord] == "") fail("the first field of a node must be 'key:'")
    next
  }
  if (ind == 4) {
    if (ord == 0) fail("a node field appears before any '- key:' item")
    setfield(ord, t)
    next
  }
  fail("unexpected indent of " ind " spaces (a node is at 2, its fields at 4)")
}

END {
  if (failed) exit 3
  if (tplname == "") bad("the template has no 'name:'")
  if (ord == 0) bad("the template declares no nodes")

  for (i = 1; i <= ord; i++) {
    k = nkey[i]
    if (!keyok(k)) bad("'" k "' is not a valid node key (lowercase letters, digits and '-', starting with a letter)")
    if (k in seen) bad("duplicate node key '" k "'")
    seen[k] = i

    if (nkind[i] == "") nkind[i] = "work"
    if (nkind[i] != "work" && nkind[i] != "gate") bad("node '" k "': kind must be 'work' or 'gate' (got '" nkind[i] "')")

    if (nfan[i] == "") nfan[i] = "fixed"
    if (nfan[i] !~ /^(fixed|per-slice|per-declaration|per-approved-finding|per-mission)$/)
      bad("node '" k "': fanout must be fixed, per-slice, per-declaration, per-approved-finding or per-mission (got '" nfan[i] "')")

    if (npar[i] == "") npar[i] = "never"
    if (npar[i] !~ /^(all|by-group|never)$/)
      bad("node '" k "': parallel must be all, by-group or never (got '" npar[i] "')")

    if (nreq[i] == "") nreq[i] = "false"
    if (nreq[i] != "true" && nreq[i] != "false")
      bad("node '" k "': required must be true or false (got '" nreq[i] "')")

    if (nkind[i] == "gate") {
      if (ndet[i] == "") ndet[i] = "approve"
      if (ndet[i] != "approve" && ndet[i] != "select-findings")
        bad("gate '" k "': kind_detail must be 'approve' or 'select-findings' (got '" ndet[i] "')")
      if (nprompt[i] == "") bad("gate '" k "' has no 'prompt:' — a gate is a question the guild master answers")
      if (nfan[i] != "fixed") bad("gate '" k "' cannot fan out; a gate is one decision")
      if (nagents[i] != "") bad("gate '" k "' cannot name agents; a gate is answered by the guild master")
      if (nneeds[i] != "") bad("gate '" k "' cannot declare capabilities; a gate is answered by the guild master")
    } else {
      ndet[i] = ""
      if (nprompt[i] != "") bad("node '" k "' is not a gate, so it cannot carry a 'prompt:'")
    }
  }

  # Acyclicity, proved by declaration order — see the header. Every `after:` must name a
  # node declared EARLIER, so every edge points backwards and no cycle can exist.
  for (i = 1; i <= ord; i++) {
    if (nafter[i] == "") continue
    n = split(nafter[i], p, ",")
    for (j = 1; j <= n; j++) {
      if (!(p[j] in seen)) bad("node '" nkey[i] "' has after: [" p[j] "], but no node is named '" p[j] "'")
      if (seen[p[j]] >= i) bad("node '" nkey[i] "' depends on '" p[j] "', which is declared at or after it — a template's edges must point backwards, which is what proves it acyclic")
    }
  }

  for (i = 1; i <= ord; i++)
    printf("NODE|%d|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", i, nkey[i], nkind[i], nreq[i], nfan[i],
           npar[i], nneeds[i], nagents[i], nafter[i], ndet[i], nprompt[i])
  printf("TPL|%s|%s\n", tplname, tpldesc)
}
PARSER
}

# _graph_parse_template <path> <outfile> — parse, or die naming the file and the line.
#
# The template is READ INTO A SIZE CAP FIRST. A template is a page of YAML; anything
# larger is a mistake or a pointed file, and the parser's per-line work would otherwise be
# unbounded on an unbounded input.
_graph_parse_template() {
  local path="${1-}" out="${2-}" prog rc=0 err bytes line
  [ -f "$path" ] || die "guild: template file not found: $path"

  bytes="$(LC_ALL=C wc -c <"$path" 2>/dev/null | LC_ALL=C tr -d ' ')"
  case "$bytes" in
    '' | *[!0-9]*) bytes=0 ;;
  esac
  [ "$bytes" -le 65536 ] ||
    die "guild: the template $path is $bytes bytes; the limit is 65536.

A template is a page of YAML describing a dozen nodes. A file this size is not one."

  utf8_valid_file "$path" ||
    die "guild: the template $path is not valid UTF-8.

Every value in it is stored in the board as text, and an invalid byte would be corrupted
differently by the two engines that can replay the journal (design 2.2.1)."

  prog="$(_graph_parser_src)"
  LC_ALL=C awk "$prog" "$path" >"$out" || rc=$?
  if [ "$rc" != 0 ]; then
    err="$(LC_ALL=C awk -F'|' '$1 == "E" { sub(/^E\|[0-9]*\|/, ""); print $0; exit }' "$out" 2>/dev/null || true)"
    [ -n "$err" ] || err="the file could not be parsed"
    line="$(LC_ALL=C awk -F'|' '$1 == "E" { print $2; exit }' "$out" 2>/dev/null || true)"
    rm -f "$out"
    if [ -n "$line" ] && [ "$line" != "0" ]; then
      die "guild: $path, line $line: $err"
    fi
    die "guild: $path: $err"
  fi
  [ -s "$out" ] || { rm -f "$out"; die "guild: $path produced no nodes"; }
  return 0
}

# _graph_tpl_name <parsed> — the template's declared `name:`.
_graph_tpl_name() {
  LC_ALL=C awk -F'|' '$1 == "TPL" { print $2; exit }' "${1-}"
}

# _graph_tpl_desc <parsed> — the template's `description:` (free text; last on its line).
_graph_tpl_desc() {
  LC_ALL=C awk '
    substr($0, 1, 4) == "TPL|" {
      s = substr($0, 5)
      i = index(s, "|")
      if (i > 0) print substr(s, i + 1)
      exit
    }' "${1-}"
}

# _graph_tpl_keys <parsed> [filter] — node keys, in declaration order.
# filter: '' every node | 'gate' | 'required' | 'work'
_graph_tpl_keys() {
  LC_ALL=C awk -F'|' -v f="${2-}" '
    $1 != "NODE" { next }
    f == "gate"     && $4 != "gate" { next }
    f == "work"     && $4 != "work" { next }
    f == "required" && $5 != "true" { next }
    { print $3 }' "${1-}"
}

# ---- shared SQL fragments -------------------------------------------------------------

# _graph_ready_where <node-alias> — THE READINESS PREDICATE (§3.0's `WITH RECURSIVE` trap).
#
# A node is READY when every one of its DIRECT predecessors is finished. That is a plain
# join over `graph_edge`, one hop, no traversal — and readiness then propagates one node
# at a time as the segment runs, which is the whole reason the transitive closure is never
# needed. `WITH RECURSIVE` is unsupported on tursodb and would have failed on local mode
# only, which is the worst kind of bug to find late.
#
# Expressed as "no direct predecessor is unfinished", which is the universal quantifier
# written as a NOT EXISTS — vacuously true for a root node, which is correct: a node with
# no predecessors is ready the moment the graph exists.
#
# `done` and `skipped` both count as finished. A node the architect deliberately skipped
# must not hold its successors forever; that is the graph's spelling of `task.waived`.
#
# IT IS A FRAGMENT, NOT A QUERY, because more than one command must agree about what
# "ready" means — this file's render, `guild segment`, and the dispatcher. Two spellings
# of readiness is two answers to "what runs next".
_graph_ready_where() {
  printf "NOT EXISTS (SELECT 1 FROM graph_edge ge JOIN graph_node gp ON gp.id = ge.from_node
                       WHERE ge.to_node = %s.id AND gp.status NOT IN ('done','skipped'))" "${1-n}"
}

# _graph_preds <node-alias> — the direct predecessors of a node, comma-joined, for the
# render's "after:" column. Ids only; wrapped by the caller for the columnar surface.
_graph_preds() {
  printf "COALESCE((SELECT group_concat(x, ',') FROM (SELECT ge.from_node AS x FROM graph_edge ge
            WHERE ge.to_node = %s.id ORDER BY ge.from_node)), '')" "${1-n}"
}

# _graph_field <sql-expression> — a value safe for a NON-FINAL marker field.
#
# `_render_col` first (no blank, no line break can survive inside a field), then the pipe
# replaced, because the pipe is THIS channel's field boundary and `_render_col` knows
# nothing about it. Both halves are needed and neither is redundant: a plan-slice slug
# reaches a node id, and a slug is free text that has never passed an alphabet.
_graph_field() {
  printf "replace(%s, '|', '!')" "$(_render_col "$1")"
}

# _graph_state_key <req> — the guild_state key recording which template built the graph.
#
# The template name is not a column on `graph_node`, and `--explain` and `validate` are
# both meaningless without a baseline to diff against — so it is recorded as a
# `guild_state` row, which is an existing table, already journaled, already replayed, and
# already the place this CLI keeps small facts about the board (`last-checkin`).
_graph_state_key() {
  printf 'graph-template:%s' "${1-}"
}

# _graph_fresh_guard <req-literal> <state-key-literal> — "this graph has not been
# instantiated yet".
#
# EVERY INSERT IN `graph new` HANGS OFF THIS ONE PREDICATE, and it deliberately does NOT
# ask `graph_node` whether rows exist: the first INSERT in the script would make that
# false and the remaining nodes would silently not be written, leaving a one-node graph
# and a success message. Both witnesses it does ask about — the `instantiated` event and
# the `guild_state` template record — are written LATE in the script, so the predicate is
# STABLE across every statement: false throughout a fresh run, true throughout a second
# one. It is `_art_created_event_sql`'s trick, inverted.
#
# TWO WITNESSES RATHER THAN ONE because they can be separated by replay: a journal that
# carries the nodes and the template record but lost the event would otherwise pass the
# guard and re-insert every node, and the first primary-key collision would surface as a
# raw engine error instead of "this requirement already has a graph".
_graph_fresh_guard() {
  printf "NOT EXISTS (SELECT 1 FROM event e WHERE e.verb = 'instantiated'
                       AND e.subject_type = 'graph' AND e.subject_id = %s)
  AND NOT EXISTS (SELECT 1 FROM guild_state gs WHERE gs.key = %s)" "${1-}" "${2-}"
}

# _graph_tmp <label> — a temp file, or die. Delegates; there is one of these in the CLI.
_graph_tmp() {
  _render_tmp "graph-${1:-work}"
}

# _graph_journal_markers <file> — fold every `R|<table>|<op>|<json>` line into the journal.
#
# Split by `read` with a FIXED variable list: with IFS='|' the fourth variable receives
# the whole remainder, delimiters intact, so a JSON value containing a pipe survives
# byte-exact and no `${v#*|}` is ever applied to an unbounded value (rule 5). The loop
# reads from a FILE rather than a pipe, so a `die` inside `journal_append` ends the
# process instead of a subshell.
_graph_journal_markers() {
  local f="${1-}" tag table op row n=0
  [ -f "$f" ] || return 0
  while IFS='|' read -r tag table op row; do
    [ "$tag" = "R" ] || continue
    case "$row" in
      '{'*'}') ;;
      *) continue ;;
    esac
    journal_append "$table" "$op" "$row"
    n=$((n + 1))
  done <"$f"
  printf '%s\n' "$n"
}

# ============================ guild graph new =========================================

# _graph_new_nodes_sql — the INSERTs for one template node, appended to `sql`.
#
# Reads the caller's parsed fields as locals; writes to the caller's `sql`. Split out so
# `cmd_graph_new` reads as the shape of the script rather than as string plumbing.
#
# THE FANOUT CASES, and the one guard that is not obvious: `per-slice` emits TWO
# statements — one per slice, and one unfanned node CONDITIONED ON THE PLAN HAVING NO
# SLICES. They are mutually exclusive by construction, and together they are what makes
# "every template key gets at least one node" true (see the header) rather than "unless
# the architect has not written the slices yet", which is the state every board is in the
# moment `graph new` runs.
_graph_new_node_sql() {
  local req="$1" reqlit="$2" key="$3" kind="$4" fanout="$5" parallel="$6" agents="$7" guard="$8"
  local keylit idprefix pgroup out="" a
  keylit="$(sql_str "$key")"
  idprefix="$(sql_str "$req/$key")"

  # parallel_group is a LABEL, not the strategy: `all` puts every instance of the key in
  # one batch, `by-group` inherits the ticket's own v4 parallel-group, `never` is NULL.
  case "$parallel" in
    all) pgroup="$(sql_str "$key")" ;;
    *) pgroup="NULL" ;;
  esac

  if [ "$kind" = "gate" ]; then
    out="INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT $idprefix, r.id, $keylit, 'gate', NULL, NULL, 'pending'
FROM requirement r WHERE r.id = $reqlit AND $guard;
"
    printf '%s' "$out"
    return 0
  fi

  case "$fanout" in
    per-slice)
      local slicegroup="NULL" slicetask
      slicetask="(SELECT MIN(t.id) FROM task t
                   WHERE t.requirement_id = r.id
                     AND (t.plan_slice_id = s.id
                          OR (t.plan_slice_id IS NULL AND t.plan_slice = s.slug)))"
      [ "$parallel" != "by-group" ] || slicegroup="(SELECT MIN(t.parallel_group) FROM task t
                   WHERE t.requirement_id = r.id
                     AND (t.plan_slice_id = s.id
                          OR (t.plan_slice_id IS NULL AND t.plan_slice = s.slug)))"
      [ "$parallel" != "all" ] || slicegroup="$pgroup"
      out="INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT $idprefix || '.' || s.slug, r.id, $keylit, 'work', $slicetask, $slicegroup, 'pending'
FROM requirement r
JOIN plan p ON p.requirement_id = r.id
JOIN plan_slice s ON s.plan_id = p.id
WHERE r.id = $reqlit AND $guard;
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT $idprefix, r.id, $keylit, 'work', NULL, $pgroup, 'pending'
FROM requirement r
WHERE r.id = $reqlit AND $guard
  AND NOT EXISTS (SELECT 1 FROM plan p2 JOIN plan_slice s2 ON s2.plan_id = p2.id
                   WHERE p2.requirement_id = r.id);
"
      printf '%s' "$out"
      return 0
      ;;
  esac

  # `fixed` with named agents: one node per agent, bound to that agent's ticket when the
  # requirement has one. Every other fanout (`per-declaration`, `per-approved-finding`,
  # `per-mission`) starts as ONE unfanned anchor node and grows siblings at run time.
  if [ "$fanout" = "fixed" ] && [ -n "$agents" ]; then
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      out="$out
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT $(sql_str "$req/$key.$a"), r.id, $keylit, 'work',
       (SELECT MIN(t.id) FROM task t WHERE t.requirement_id = r.id AND t.agent = $(sql_str "$a")),
       $pgroup, 'pending'
FROM requirement r WHERE r.id = $reqlit AND $guard;"
    done <<EOF
$(printf '%s' "$agents" | LC_ALL=C tr ',' '
')
EOF
    printf '%s\n' "$out"
    return 0
  fi

  out="INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT $idprefix, r.id, $keylit, 'work', NULL, $pgroup, 'pending'
FROM requirement r WHERE r.id = $reqlit AND $guard;
"
  printf '%s' "$out"
}

# cmd_graph_new <REQ-NNN> [--template NAME] — instantiate the graph. Prints
# "<REQ> <template> <nodes> nodes <edges> edges".
#
# ONE db_exec: every node, every edge, both gate rows, the template record, the event and
# the journal markers are one script. The statement count grows with the TEMPLATE.
#
# THREE REFUSALS, all evaluated as part of that same script rather than as prior reads:
#
#   EXISTS  the requirement already has a graph. Re-instantiating would either duplicate
#           the nodes or silently discard the deviations already recorded against them.
#           `EXISTS|<n>` is the FIRST statement in the script, so it reports the world
#           before any INSERT in the same script could have changed it.
#   MISS    the requirement does not exist. The FROM clause is the referential check.
#   (guard) a second run finds the `instantiated` event and the template record already
#           written and inserts NOTHING AT ALL — not one node, not one edge, not one gate
#           row — rather than half a graph or a primary-key collision reported as a raw
#           engine error. See `_graph_fresh_guard` for why the predicate is stable.
cmd_graph_new() {
  local req="" tpl="standard" path parsed rc=0
  local now nowlit actorlit reqlit statekey guard sql out markers
  local tag key kind fanout parallel agents after detail prompt
  local declared line nodes edges gates a

  while [ $# -gt 0 ]; do
    case "$1" in
      --template) shift; tpl="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --template=*) tpl="${1#--template=}"; shift ;;
      -*) die "guild: unknown option '$1' for 'graph new' (try 'guild graph new REQ-NNN [--template standard|maintenance]')" ;;
      *)
        [ -z "$req" ] || die "guild: 'graph new' takes one requirement id (got '$req' and '$(_render_flat_arg "$1")')"
        req="$1"
        shift
        ;;
    esac
  done

  _graph_check_req "$req"
  _graph_check_template_name "$tpl"
  path="$(_graph_template_path "$tpl")"
  parsed="$(_graph_tmp tpl)"
  _graph_parse_template "$path" "$parsed"

  declared="$(_graph_tpl_name "$parsed")"
  if [ "$declared" != "$tpl" ]; then
    rm -f "$parsed"
    die "guild: $path declares 'name: $declared' but was loaded as '$tpl'.

The name in the file and the name of the file must agree, or 'guild graph REQ --explain'
would diff the actual graph against a template it was not built from."
  fi

  db_require_init
  journal_preflight

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  reqlit="$(sql_str "$req")"
  statekey="$(sql_str "$(_graph_state_key "$req")")"
  guard="$(_graph_fresh_guard "$reqlit" "$statekey")"

  sql="BEGIN;
SELECT 'EXISTS|' || COUNT(*) FROM graph_node WHERE requirement_id = $reqlit;
SELECT 'MISS|' || m.x FROM (SELECT $reqlit AS x) m WHERE NOT EXISTS (SELECT 1 FROM requirement WHERE id = $reqlit);
"

  # ---- the nodes -----------------------------------------------------------------
  while IFS='|' read -r tag _ key kind _ fanout parallel _ agents _; do
    [ "$tag" = "NODE" ] || continue
    sql="$sql$(_graph_new_node_sql "$req" "$reqlit" "$key" "$kind" "$fanout" "$parallel" "$agents" "$guard")"
  done <"$parsed"

  # ---- the edges -----------------------------------------------------------------
  #
  # One statement per (successor key, predecessor key) pair — template-sized, never
  # board-sized — and it is a CROSS JOIN over the instances of the two keys, so a fanned
  # predecessor becomes a real barrier: `test-plan` waits for every `implement.<slice>`,
  # because it inventories the whole diff.
  while IFS='|' read -r tag _ key _ _ _ _ _ _ after _; do
    [ "$tag" = "NODE" ] || continue
    [ -n "$after" ] || continue
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      sql="$sql
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = $reqlit AND t.requirement_id = $reqlit
  AND f.node_key = $(sql_str "$a") AND t.node_key = $(sql_str "$key")
  AND f.id <> t.id AND $guard;"
    done <<EOF
$(printf '%s' "$after" | LC_ALL=C tr ',' '
')
EOF
  done <"$parsed"

  # ---- the gates -----------------------------------------------------------------
  #
  # `{requirement}` is the one substitution a prompt gets. The value is a REQ id that has
  # passed `_graph_check_req`, so it cannot introduce anything structural; the prompt
  # itself is free text and travels as hex.
  while IFS='|' read -r tag _ key kind _ _ _ _ _ _ detail prompt; do
    [ "$tag" = "NODE" ] || continue
    [ "$kind" = "gate" ] || continue
    prompt="${prompt//\{requirement\}/$req}"
    sql="$sql
INSERT INTO gate (node_id, prompt, kind, status, decision, decided_at)
SELECT g.id, $(sql_text "$prompt" "the '$key' prompt"), $(sql_str "$detail"), 'pending', NULL, NULL
FROM graph_node g WHERE g.requirement_id = $reqlit AND g.node_key = $(sql_str "$key") AND $guard;"
  done <"$parsed"

  # ---- the template record, the event, and the journal markers --------------------
  #
  # The `guild_state` row is one of the guard's two witnesses (see `_graph_fresh_guard`),
  # so it is written HERE — after every node, edge and gate — and never earlier.
  sql="$sql
INSERT INTO guild_state (key, value)
SELECT $statekey, $(sql_str "$tpl")
WHERE EXISTS (SELECT 1 FROM graph_node WHERE requirement_id = $reqlit)
  AND NOT EXISTS (SELECT 1 FROM guild_state WHERE key = $statekey);
SELECT 'OK|' || (SELECT COUNT(*) FROM graph_node WHERE requirement_id = $reqlit)
            || '|' || (SELECT COUNT(*) FROM graph_edge x
                        WHERE x.to_node IN (SELECT id FROM graph_node WHERE requirement_id = $reqlit))
            || '|' || (SELECT COUNT(*) FROM gate y
                        WHERE y.node_id IN (SELECT id FROM graph_node WHERE requirement_id = $reqlit));
SELECT 'R|guild_state|upsert|' || $(_art_json_row guild_state) FROM guild_state
 WHERE key = $statekey;
SELECT 'R|graph_node|upsert|' || $(_art_json_row graph_node) FROM graph_node
 WHERE requirement_id = $reqlit ORDER BY id;
SELECT 'R|graph_edge|upsert|' || $(_art_json_row graph_edge) FROM graph_edge
 WHERE to_node IN (SELECT id FROM graph_node WHERE requirement_id = $reqlit)
 ORDER BY from_node, to_node;
SELECT 'R|gate|upsert|' || $(_art_json_row gate) FROM gate
 WHERE node_id IN (SELECT id FROM graph_node WHERE requirement_id = $reqlit) ORDER BY node_id;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $actorlit, 'instantiated', 'graph', $reqlit,
       json_object('template', $(sql_str "$tpl"),
                   'nodes', (SELECT COUNT(*) FROM graph_node WHERE requirement_id = $reqlit))
WHERE EXISTS (SELECT 1 FROM graph_node WHERE requirement_id = $reqlit) AND $guard;
COMMIT;
"
  rm -f "$parsed"

  markers="$(_graph_tmp markers)"
  if ! printf '%s' "$sql" | db_exec >"$markers"; then
    out="$(cat "$markers" 2>/dev/null || true)"
    rm -f "$markers"
    db_fail "could not instantiate the graph for $req" "$out"
  fi

  line="$(LC_ALL=C awk -F'|' '$1 == "EXISTS" { print $2; exit }' "$markers")"
  case "$line" in
    '' | 0) ;;
    *)
      rm -f "$markers"
      die "guild: $req already has an execution graph ($line node(s)).

Nothing was written. Re-instantiating would either duplicate every node or discard the
deviations already recorded against the ones that are there. Read it with
'guild graph $req --explain'; change its shape with 'guild graph deviate'."
      ;;
  esac

  line="$(LC_ALL=C awk -F'|' '$1 == "MISS" { print $2; exit }' "$markers")"
  if [ -n "$line" ]; then
    rm -f "$markers"
    die "guild: $req not found"
  fi

  line="$(LC_ALL=C awk -F'|' '$1 == "OK" { print $2 " " $3 " " $4; exit }' "$markers")"
  nodes="${line%% *}"
  edges="${line#* }"
  gates="${edges#* }"
  edges="${edges%% *}"
  if [ -z "$nodes" ] || [ "$nodes" = "0" ]; then
    rm -f "$markers"
    die "guild: could not instantiate the graph for $req (nothing was written)"
  fi

  _graph_journal_markers "$markers" >/dev/null
  rm -f "$markers"

  printf '%s %s %s nodes %s edges %s gates\n' "$req" "$tpl" "$nodes" "$edges" "$gates"
}

# ============================ guild graph <REQ> =======================================

# _graph_show_sql <req> — the ONE query behind both the plain render and `--explain`.
#
# Every field but the last on each line is `_graph_field` (see THE MARKER CHANNEL): a node
# id can carry a plan-slice slug, which is free text that has never passed an alphabet.
# The free-text values — a gate prompt, a deviation reason — are `_render_flat` and come
# LAST, so they cannot forge a field boundary or a second line.
_graph_show_sql() {
  local reqlit="$1" statekey="$2"
  printf "SELECT 'T|' || %s FROM guild_state WHERE key = %s;
SELECT 'Q|' || %s || '|' || %s FROM requirement WHERE id = %s;
SELECT 'N|' || %s || '|' || %s || '|' || %s || '|' || %s || '|' || %s || '|' || %s || '|' || %s
  FROM graph_node n WHERE n.requirement_id = %s ORDER BY n.node_key, n.id;
SELECT 'G|' || %s || '|' || %s || '|' || %s || '|' || %s
  FROM gate g JOIN graph_node n ON n.id = g.node_id
 WHERE n.requirement_id = %s ORDER BY n.id;
SELECT 'D|' || d.id || '|' || %s || '|' || %s || '|' || %s || '|' || %s
  FROM graph_deviation d WHERE d.requirement_id = %s ORDER BY d.id;
" \
    "$(_graph_field 'value')" "$statekey" \
    "$(_graph_field 'status')" "$(_render_flat 'title')" "$reqlit" \
    "$(_graph_field 'n.id')" "$(_graph_field 'n.node_key')" "$(_graph_field 'n.kind')" \
    "$(_graph_field 'n.status')" "$(_graph_field "COALESCE(n.task_id,'-')")" \
    "$(_graph_field "COALESCE(n.parallel_group,'-')")" \
    "$(_graph_field "CASE WHEN $(_graph_preds n) = '' THEN '-' ELSE $(_graph_preds n) END")" \
    "$reqlit" \
    "$(_graph_field 'n.id')" "$(_graph_field 'g.status')" "$(_graph_field 'g.kind')" \
    "$(_render_flat 'g.prompt')" "$reqlit" \
    "$(_graph_field 'd.kind')" "$(_graph_field 'd.node_key')" \
    "$(_graph_field 'substr(d.created_at,1,10)')" "$(_render_flat 'd.reason')" \
    "$reqlit"
}

# _graph_render_awk — the plain render: the graph as a document.
#
# `tailafter(s, k)` walks past exactly k delimiters and returns the rest VERBATIM, which
# is how a prompt or a reason containing a pipe survives the surface it is printed on. The
# leading fields are read from `split`, which over-splits that tail into fields nobody
# reads — harmless, and it keeps the common case a single pass.
_graph_render_awk() {
  cat <<'RENDER'
function tailafter(s, k,   i, p) {
  for (i = 1; i <= k; i++) { p = index(s, "|"); if (p == 0) return ""; s = substr(s, p + 1) }
  return s
}
BEGIN { tpl = "-"; reqstatus = "-"; reqtitle = ""; nn = 0; ng = 0; nd = 0 }
substr($0, 1, 2) == "T|" { tpl = substr($0, 3); next }
substr($0, 1, 2) == "Q|" { split($0, p, "|"); reqstatus = p[2]; reqtitle = tailafter($0, 2); next }
substr($0, 1, 2) == "N|" {
  nn++
  split($0, p, "|")
  nid[nn] = p[2]; nkey[nn] = p[3]; nkind[nn] = p[4]; nstat[nn] = p[5]
  ntask[nn] = p[6]; ngrp[nn] = p[7]; npred[nn] = p[8]
  cnt[p[5]]++
  next
}
substr($0, 1, 2) == "G|" {
  ng++
  split($0, p, "|")
  gid[ng] = p[2]; gstat[ng] = p[3]; gkind[ng] = p[4]; gprompt[ng] = tailafter($0, 4)
  next
}
substr($0, 1, 2) == "D|" {
  nd++
  split($0, p, "|")
  did[nd] = p[2]; dkind[nd] = p[3]; dkey[nd] = p[4]; ddate[nd] = p[5]; dreason[nd] = tailafter($0, 5)
  next
}
END {
  head = "Graph " req
  print head
  bar = ""
  for (i = 0; i < length(head); i++) bar = bar "="
  print bar
  print ""
  printf("requirement: %s [%s]\n", (reqtitle == "" ? "(not found)" : reqtitle), reqstatus)
  printf("template:    %s\n", tpl)
  if (nn == 0) {
    print ""
    print "No execution graph. Instantiate one with:"
    printf("  guild graph new %s --template standard\n", req)
    exit 0
  }
  order = "pending ready running done failed skipped"
  n = split(order, o, " ")
  line = ""
  for (i = 1; i <= n; i++)
    if (cnt[o[i]] > 0) line = line (line == "" ? "" : ", ") cnt[o[i]] " " o[i]
  for (s in cnt) {
    known = 0
    for (i = 1; i <= n; i++) if (o[i] == s) known = 1
    if (!known) line = line (line == "" ? "" : ", ") cnt[s] " " s
  }
  printf("nodes:       %d (%s)\n", nn, line)
  print ""
  print "Nodes:"
  for (i = 1; i <= nn; i++)
    printf("  %-11s %-5s %-34s task:%-9s group:%-10s after: %s\n",
           "[" nstat[i] "]", nkind[i], nid[i], ntask[i], ngrp[i], npred[i])
  print ""
  print "Gates:"
  if (ng == 0) print "  (none — a graph with no gate is not a guild graph; run 'guild graph validate')"
  for (i = 1; i <= ng; i++) {
    printf("  [%s] %s (%s)\n", gstat[i], gid[i], gkind[i])
    printf("      %s\n", gprompt[i])
  }
  print ""
  print "Deviations:"
  if (nd == 0) print "  (none — this graph is the template)"
  for (i = 1; i <= nd; i++) {
    printf("  #%s %s %s (%s)\n", did[i], dkind[i], dkey[i], ddate[i])
    printf("      %s\n", dreason[i])
  }
}
RENDER
}

# _graph_explain_awk — the `--explain` render: TEMPLATE vs ACTUAL, side by side, with each
# deviation's reason (§6.3).
#
# The point of this surface: "when a run goes wrong you diff against a known baseline
# instead of staring at a bespoke graph." So every template key is printed even when the
# actual graph has nothing for it — an absent key is the single most important thing this
# view can say, and a view that only lists what exists cannot say it.
_graph_explain_awk() {
  cat <<'EXPLAIN'
function tailafter(s, k,   i, p) {
  for (i = 1; i <= k; i++) { p = index(s, "|"); if (p == 0) return ""; s = substr(s, p + 1) }
  return s
}
BEGIN { tpl = "-"; nt = 0; nd = 0 }
# The template, fed in first: TPLNODE|<ord>|<key>|<kind>|<required>|<fanout>|<parallel>|<after>
substr($0, 1, 8) == "TPLNODE|" {
  nt++
  split($0, p, "|")
  tord[nt] = p[2]; tkey[nt] = p[3]; tkind[nt] = p[4]; treq[nt] = p[5]
  tfan[nt] = p[6]; tpar[nt] = p[7]; taft[nt] = (p[8] == "" ? "-" : p[8])
  tseen[p[3]] = nt
  next
}
substr($0, 1, 2) == "T|" { tpl = substr($0, 3); next }
substr($0, 1, 2) == "N|" {
  split($0, p, "|")
  k = p[3]
  acount[k]++
  astat[k] = astat[k] (astat[k] == "" ? "" : ",") p[5]
  akind[k] = p[4]
  if (!(k in tseen)) { if (!(k in extraseen)) { extraseen[k] = 1; ne++; extra[ne] = k } }
  next
}
substr($0, 1, 2) == "D|" {
  nd++
  split($0, p, "|")
  did[nd] = p[2]; dkind[nd] = p[3]; dkey[nd] = p[4]; ddate[nd] = p[5]; dreason[nd] = tailafter($0, 5)
  dfor[p[4]] = dfor[p[4]] (dfor[p[4]] == "" ? "" : " ") nd
  next
}
END {
  head = "Graph " req " — template vs actual"
  print head
  print "==================================================="
  printf("template: %s\n", tpl)
  print ""
  printf("  %-16s %-30s %s\n", "NODE", "TEMPLATE", "ACTUAL")
  printf("  %-16s %-30s %s\n", "----", "--------", "------")
  for (i = 1; i <= nt; i++) {
    k = tkey[i]
    spec = tkind[i] "/" tfan[i] "/" tpar[i] (treq[i] == "true" ? "/required" : "")
    if (acount[k] > 0) act = acount[k] " node(s): " astat[k]
    else act = "*** ABSENT ***" (treq[i] == "true" ? "  (REQUIRED — this is a violation)" : "")
    printf("  %-16s %-30s %s\n", k, spec, act)
    printf("  %-16s %-30s\n", "", "after: " taft[i])
    if (k in dfor) {
      n = split(dfor[k], ds, " ")
      for (j = 1; j <= n; j++)
        printf("  %-16s -> %s: %s\n", "", dkind[ds[j]], dreason[ds[j]])
    }
  }
  if (ne > 0) {
    print ""
    print "  Added — not in the template:"
    for (i = 1; i <= ne; i++) {
      k = extra[i]
      printf("  %-16s %-30s %s\n", k, "(added)", acount[k] " node(s): " astat[k])
      if (k in dfor) {
        n = split(dfor[k], ds, " ")
        for (j = 1; j <= n; j++)
          printf("  %-16s -> %s: %s\n", "", dkind[ds[j]], dreason[ds[j]])
      } else
        printf("  %-16s -> NO DEVIATION RECORDED — 'guild graph validate %s' will fail\n", "", req)
    }
  }
  print ""
  print "Deviations, in order:"
  if (nd == 0) print "  (none — this graph is the template)"
  for (i = 1; i <= nd; i++) {
    printf("  #%s %s %s (%s)\n", did[i], dkind[i], dkey[i], ddate[i])
    printf("      %s\n", dreason[i])
  }
}
EXPLAIN
}

# cmd_graph_show <REQ-NNN> [--explain] — render the graph.
cmd_graph_show() {
  local req="" explain=0 reqlit statekey sqlf outf tplname path parsed prog
  local tag ord key kind required fanout parallel after

  while [ $# -gt 0 ]; do
    case "$1" in
      --explain) explain=1 ;;
      -*) die "guild: unknown option '$1' for 'graph' (try 'guild graph REQ-NNN [--explain]')" ;;
      *)
        [ -z "$req" ] || die "guild: 'graph' takes one requirement id (got '$req' and '$(_render_flat_arg "$1")')"
        req="$1"
        ;;
    esac
    shift
  done
  _graph_check_req "$req"
  db_require_init

  reqlit="$(sql_str "$req")"
  statekey="$(sql_str "$(_graph_state_key "$req")")"
  sqlf="$(_graph_tmp sql)"
  outf="$(_graph_tmp rows)"
  _graph_show_sql "$reqlit" "$statekey" >"$sqlf"
  _render_query "$sqlf" "$outf" "guild: could not read the graph for $req"

  if [ "$explain" = 0 ]; then
    LC_ALL=C awk -v req="$req" "$(_graph_render_awk)" "$outf"
    rm -f "$outf"
    return 0
  fi

  # --explain needs the BASELINE, which is the template the graph was built from. It is
  # recorded in guild_state; a graph with no record cannot be diffed against anything, and
  # saying so is more useful than diffing against a guess.
  tplname="$(LC_ALL=C awk 'substr($0,1,2) == "T|" { print substr($0,3); exit }' "$outf")"
  if [ -z "$tplname" ]; then
    rm -f "$outf"
    die "guild: $req has no recorded template, so there is no baseline to diff against.

'guild graph new' records which template it instantiated; a graph without that record was
not built by it. 'guild graph $req' still renders the actual shape."
  fi
  _graph_check_template_name "$tplname"
  path="$(_graph_template_path "$tplname")"
  parsed="$(_graph_tmp tpl)"
  _graph_parse_template "$path" "$parsed"

  prog="$(_graph_explain_awk)"
  {
    while IFS='|' read -r tag ord key kind required fanout parallel _ _ after _; do
      [ "$tag" = "NODE" ] || continue
      printf 'TPLNODE|%s|%s|%s|%s|%s|%s|%s\n' "$ord" "$key" "$kind" "$required" "$fanout" "$parallel" "$after"
    done <"$parsed"
    cat "$outf"
  } | LC_ALL=C awk -v req="$req" "$prog"

  rm -f "$parsed" "$outf"
}

# ============================ guild graph validate ====================================

# _graph_inline_keys — a one-column relation of node keys, for a WHERE ... IN.
#
# Keys arrive on STDIN, one per line, rather than as arguments: an argument list would
# have to be produced by an unquoted expansion of a space-joined string, which is a real
# hazard (this CLI runs with globbing on, and `set -f` around it has to be undone on every
# path out) as well as a lint nobody can quieten without disabling it. One `read` loop is
# the same answer lib/artifacts.sh gives for capability lists, for the same reasons.
#
# Keys have passed the node-key alphabet, so `sql_str` is correct and hex would obscure.
# Prints nothing when the list is empty, which every caller tests for.
_graph_inline_keys() {
  local out="" k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    out="$out${out:+ UNION ALL }SELECT $(sql_str "$k") AS k"
  done
  printf '%s' "$out"
}

# _graph_blank_expr <column> — "this text is empty or nothing but whitespace", in SQL.
#
# `replace()` rather than the three-argument `trim()`: §3.0's rule is that if the code
# depends on a construct, that construct has a VERIFIED row in the table, and `replace` and
# `length` do while `trim(x, chars)` does not. The byte literals are `_render_byte`, which
# is the one spelling of a control character this CLI uses.
_graph_blank_expr() {
  local e="${1-}" hx
  e="replace($e, ' ', '')"
  for hx in 09 0a 0d 0b 0c; do
    e="replace($e, $(_render_byte "$hx"), '')"
  done
  printf "%s = ''" "$e"
}

# cmd_graph_validate <REQ-NNN> — the deviation rules, enforced against what is STORED.
#
# ONE db_exec: every check is a statement in one script emitting `FAIL|<code>|<detail>`,
# and the shell turns those into a report. Exit 1 if anything failed, 0 and one line if
# not, so a skill can branch on the status.
#
# WHY THE CHECKS ARE HERE AND NOT ONLY IN `deviate`. `graph_deviation` and `graph_node`
# rows also arrive by JOURNAL REPLAY, from a teammate's machine or from `guild rebuild`,
# and a hand-edited journal is a supported thing to have (it is committed to git and gets
# merged). A rule enforced only in an argument parser is a rule about this process, not
# about the board.
#
# WHAT IT REJECTS — the list is exhaustive and each code is a section of §6.3:
#
#   no-graph              the requirement has no nodes at all
#   unknown-template      no `guild_state` record of which template built it, so nothing
#                         below that needs a baseline can be judged
#   empty-reason          a deviation whose reason is empty or nothing but whitespace
#   unknown-kind          a deviation whose kind is not one of the four
#   added-gate            an `add-gate` deviation row, OR a `kind = 'gate'` node whose key
#                         is not one of the template's own — THE SUBTLE FAILURE (§6.3)
#   dropped-gate          a template gate key with no instance in the graph
#   dropped-required      a template node marked `required: true` with no instance
#   dropped-node-no-reason  a template key with no instance and no `drop-node` deviation
#   unknown-capability    an `add-node` whose node names a capability no ACTIVE roster
#                         member declares — a node that exists and cannot ever run
#   uncapable-add-node    an `add-node` whose node has no ticket and no capability at all
#   added-node-no-reason  a node key not in the template with no `add-node` deviation
#   cross-requirement-edge  an edge joining this graph to another requirement's
#   self-edge             an edge from a node to itself: a one-node cycle, and the only
#                         cycle that can be found without recursion
cmd_graph_validate() {
  local req="" reqlit statekey sqlf outf tplname path parsed
  local gatekeys="" reqkeys="" allkeys="" rel
  local tag key kind required
  local fails

  while [ $# -gt 0 ]; do
    case "$1" in
      -*) die "guild: unknown option '$1' for 'graph validate' (try 'guild graph validate REQ-NNN')" ;;
      *)
        [ -z "$req" ] || die "guild: 'graph validate' takes one requirement id"
        req="$1"
        ;;
    esac
    shift
  done
  _graph_check_req "$req"
  db_require_init

  reqlit="$(sql_str "$req")"
  statekey="$(sql_str "$(_graph_state_key "$req")")"

  # The baseline. Read first, because every template-relative check needs it and because
  # its absence is itself a finding rather than a reason to skip the rest.
  sqlf="$(_graph_tmp sql)"
  outf="$(_graph_tmp rows)"
  printf "SELECT 'T|' || %s FROM guild_state WHERE key = %s;
SELECT 'C|' || COUNT(*) FROM graph_node WHERE requirement_id = %s;
" "$(_graph_field 'value')" "$statekey" "$reqlit" >"$sqlf"
  _render_query "$sqlf" "$outf" "guild: could not read the graph for $req"
  tplname="$(LC_ALL=C awk 'substr($0,1,2) == "T|" { print substr($0,3); exit }' "$outf")"
  fails="$(LC_ALL=C awk -F'|' '$1 == "C" { print $2; exit }' "$outf")"
  rm -f "$outf"

  if [ -z "$fails" ] || [ "$fails" = "0" ]; then
    printf 'FAIL no-graph %s has no execution graph — run: guild graph new %s\n' "$req" "$req" >&2
    printf 'guild: %s is INVALID (1 problem)\n' "$req" >&2
    return 1
  fi
  if [ -z "$tplname" ]; then
    printf 'FAIL unknown-template %s has no recorded template, so its shape cannot be judged\n' "$req" >&2
    printf 'guild: %s is INVALID (1 problem)\n' "$req" >&2
    return 1
  fi
  _graph_check_template_name "$tplname"
  path="$(_graph_template_path "$tplname")"
  parsed="$(_graph_tmp tpl)"
  _graph_parse_template "$path" "$parsed"

  # Three fields decide the checks below; `_` holds the field POSITIONS of the rest.
  while IFS='|' read -r tag _ key kind required _; do
    [ "$tag" = "NODE" ] || continue
    allkeys="$allkeys$key
"
    [ "$kind" != "gate" ] || gatekeys="$gatekeys$key
"
    [ "$required" != "true" ] || reqkeys="$reqkeys$key
"
  done <"$parsed"
  rm -f "$parsed"

  sqlf="$(_graph_tmp sql)"
  outf="$(_graph_tmp rows)"
  {
    # -- a reason that says nothing is no reason at all (§6.3)
    printf "SELECT 'FAIL|empty-reason|deviation #' || d.id || ' (' || %s || ' ' || %s || ') carries a blank reason'
  FROM graph_deviation d WHERE d.requirement_id = %s AND %s;\n" \
      "$(_graph_field 'd.kind')" "$(_graph_field 'd.node_key')" "$reqlit" \
      "$(_graph_blank_expr 'd.reason')"

    printf "SELECT 'FAIL|unknown-kind|deviation #' || d.id || ' has kind ' || %s
  FROM graph_deviation d WHERE d.requirement_id = %s
   AND d.kind NOT IN ('add-node','drop-node','reshape','add-gate');\n" \
      "$(_graph_field 'd.kind')" "$reqlit"

    # -- NO NEW GATE. Both spellings: the recorded intent, and the node itself.
    printf "SELECT 'FAIL|added-gate|deviation #' || d.id || ' adds a gate at ' || %s ||
       ' — gates are the guild master control surface and are fixed at two'
  FROM graph_deviation d WHERE d.requirement_id = %s AND d.kind = 'add-gate';\n" \
      "$(_graph_field 'd.node_key')" "$reqlit"

    rel="$(printf '%s' "$gatekeys" | _graph_inline_keys)"
    if [ -n "$rel" ]; then
      printf "SELECT 'FAIL|added-gate|' || %s || ' is a gate the template does not have'
  FROM graph_node n WHERE n.requirement_id = %s AND n.kind = 'gate'
   AND n.node_key NOT IN (SELECT k FROM (%s));\n" \
        "$(_graph_field 'n.id')" "$reqlit" "$rel"
      # -- a gate may never be dropped
      printf "SELECT 'FAIL|dropped-gate|the gate ' || t.k || ' has no node in this graph'
  FROM (%s) t WHERE NOT EXISTS (SELECT 1 FROM graph_node n
        WHERE n.requirement_id = %s AND n.node_key = t.k);\n" "$rel" "$reqlit"
    else
      printf "SELECT 'FAIL|added-gate|' || %s || ' is a gate and the template declares none'
  FROM graph_node n WHERE n.requirement_id = %s AND n.kind = 'gate';\n" \
        "$(_graph_field 'n.id')" "$reqlit"
    fi

    # -- a `required: true` node may be reshaped but never dropped
    rel="$(printf '%s' "$reqkeys" | _graph_inline_keys)"
    if [ -n "$rel" ]; then
      printf "SELECT 'FAIL|dropped-required|the required node ' || t.k || ' has no node in this graph'
  FROM (%s) t WHERE NOT EXISTS (SELECT 1 FROM graph_node n
        WHERE n.requirement_id = %s AND n.node_key = t.k);\n" "$rel" "$reqlit"
    fi

    # -- any other template key that is gone must have a drop-node deviation with a reason
    rel="$(printf '%s' "$allkeys" | _graph_inline_keys)"
    if [ -n "$rel" ]; then
      printf "SELECT 'FAIL|dropped-node-no-reason|' || t.k || ' is in the template, has no node, and no drop-node deviation explains it'
  FROM (%s) t
 WHERE NOT EXISTS (SELECT 1 FROM graph_node n WHERE n.requirement_id = %s AND n.node_key = t.k)
   AND NOT EXISTS (SELECT 1 FROM graph_deviation d WHERE d.requirement_id = %s
                    AND d.kind = 'drop-node' AND d.node_key = t.k);\n" "$rel" "$reqlit" "$reqlit"
      # -- and any key that is NOT in the template must have an add-node deviation
      printf "SELECT 'FAIL|added-node-no-reason|' || %s || ' is not in the template and no add-node deviation explains it'
  FROM graph_node n WHERE n.requirement_id = %s
   AND n.node_key NOT IN (SELECT k FROM (%s))
   AND NOT EXISTS (SELECT 1 FROM graph_deviation d WHERE d.requirement_id = %s
                    AND d.kind = 'add-node' AND d.node_key = n.node_key);\n" \
        "$(_graph_field 'n.id')" "$reqlit" "$rel" "$reqlit"
    fi

    # -- every add-node names a capability that EXISTS in the roster (§6.3). Otherwise the
    #    graph cannot run: the node has no eligible member and never will.
    printf "SELECT 'FAIL|unknown-capability|' || %s || ' (added at ' || %s || ') needs the capability ' || %s ||
       ', which no active guild member declares'
  FROM graph_deviation d
  JOIN graph_node n ON n.requirement_id = d.requirement_id AND n.node_key = d.node_key
  JOIN task_capability tc ON tc.task_id = n.task_id AND tc.required = 1
 WHERE d.requirement_id = %s AND d.kind = 'add-node'
   AND NOT EXISTS (SELECT 1 FROM agent_capability ac JOIN agent a ON a.name = ac.agent
                    WHERE a.active = 1 AND ac.capability = tc.capability);\n" \
      "$(_graph_field 'n.id')" "$(_graph_field 'd.node_key')" "$(_graph_field 'tc.capability')" "$reqlit"

    printf "SELECT 'FAIL|uncapable-add-node|' || %s || ' was added but names no capability at all, so nobody can be dispatched to it'
  FROM graph_deviation d
  JOIN graph_node n ON n.requirement_id = d.requirement_id AND n.node_key = d.node_key
 WHERE d.requirement_id = %s AND d.kind = 'add-node'
   AND NOT EXISTS (SELECT 1 FROM task_capability tc WHERE tc.task_id = n.task_id AND tc.required = 1);\n" \
      "$(_graph_field 'n.id')" "$reqlit"

    # -- structural sanity the schema's foreign keys do not cover
    printf "SELECT 'FAIL|cross-requirement-edge|' || %s || ' -> ' || %s || ' joins two requirements'
  FROM graph_edge e JOIN graph_node f ON f.id = e.from_node JOIN graph_node t ON t.id = e.to_node
 WHERE (f.requirement_id = %s OR t.requirement_id = %s) AND f.requirement_id <> t.requirement_id;\n" \
      "$(_graph_field 'e.from_node')" "$(_graph_field 'e.to_node')" "$reqlit" "$reqlit"

    printf "SELECT 'FAIL|self-edge|' || %s || ' depends on itself'
  FROM graph_edge e JOIN graph_node n ON n.id = e.from_node
 WHERE n.requirement_id = %s AND e.from_node = e.to_node;\n" \
      "$(_graph_field 'e.from_node')" "$reqlit"
  } >"$sqlf"

  _render_query "$sqlf" "$outf" "guild: could not validate the graph for $req"

  fails="$(LC_ALL=C awk -F'|' '$1 == "FAIL" { n++ } END { print n + 0 }' "$outf")"
  if [ "$fails" = "0" ]; then
    rm -f "$outf"
    printf 'guild: %s is valid against the %s template\n' "$req" "$tplname"
    return 0
  fi
  LC_ALL=C awk '
    function tailafter(s, k,   i, p) {
      for (i = 1; i <= k; i++) { p = index(s, "|"); if (p == 0) return ""; s = substr(s, p + 1) }
      return s
    }
    substr($0, 1, 5) == "FAIL|" {
      split($0, p, "|")
      printf("FAIL %s %s\n", p[2], tailafter($0, 2))
    }' "$outf" >&2
  rm -f "$outf"
  printf 'guild: %s is INVALID (%s problem(s)) against the %s template\n' "$req" "$fails" "$tplname" >&2
  return 1
}

# ============================ guild graph deviate =====================================

# _graph_parse_deviate_flags — sets gd_kind gd_node gd_reason gd_needs gd_prefers gd_after
# gd_title gd_group gd_rest gd_rest_n. Reset first, so a second call cannot inherit the
# first one's values. An unknown `--flag` CONSUMES its value rather than falling through
# to the positional slot, so a typo is not silently read as the requirement id.
_graph_parse_deviate_flags() {
  gd_kind=""
  gd_node=""
  gd_reason=""
  gd_needs=""
  gd_prefers=""
  gd_after=""
  gd_title=""
  gd_group=""
  gd_rest=""
  gd_rest_n=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) shift; gd_kind="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --node) shift; gd_node="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --reason) shift; gd_reason="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --needs) shift; gd_needs="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --prefers) shift; gd_prefers="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --after) shift; gd_after="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --title) shift; gd_title="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --parallel-group) shift; gd_group="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --*) shift; if [ $# -gt 0 ]; then shift; fi ;;
      *)
        gd_rest_n=$((gd_rest_n + 1))
        [ "$gd_rest_n" != 1 ] || gd_rest="$1"
        shift
        ;;
    esac
  done
}

# _graph_deviation_sql <reqlit> <kindlit> <keylit> <reasonlit> <nowlit> <extra-where> —
# the deviation row and its marker. Shared by all three kinds, because the record is the
# same record; <extra-where> is the kind's PRECONDITION, evaluated against the pre-state.
#
# THE DEVIATION ROW IS THE TRANSACTION'S OWN PRECONDITION TOKEN, and it is written FIRST.
# That inversion is not stylistic. The obvious order — mutate, then record why — writes a
# `graph_deviation` row unconditionally, so a refused deviation (`add-node` for a key that
# already exists, `drop-node` for a key that does not) still left a permanent, committed
# justification for a change that never happened. The shell then printed "nothing was
# written", which was false, and `guild graph --explain` grew a reason attached to
# nothing.
#
# Writing the record first, guarded by the precondition, and then guarding every mutation
# on THAT ROW (`_graph_dev_guard`) makes the two atomic in the only direction that
# matters: no deviation without its change, no change without its reason.
_graph_deviation_sql() {
  printf "INSERT INTO graph_deviation (requirement_id, kind, node_key, reason, created_at)
SELECT %s, %s, %s, %s, %s
FROM requirement r WHERE r.id = %s %s
RETURNING 'R|graph_deviation|upsert|' || %s;
" "$1" "$2" "$3" "$4" "$5" "$1" "${6-}" "$(_art_json_row graph_deviation)"
}

# _graph_dev_guard <reqlit> <kindlit> <keylit> <nowlit> — "this invocation's deviation row
# was accepted". Every mutation in `graph deviate` hangs off it; see above.
_graph_dev_guard() {
  printf "EXISTS (SELECT 1 FROM graph_deviation d WHERE d.requirement_id = %s
                   AND d.kind = %s AND d.node_key = %s AND d.created_at = %s)" \
    "$1" "$2" "$3" "$4"
}

# cmd_graph_deviate <REQ-NNN> --kind K --node KEY --reason "..." [extras]
#
#   add-node   --needs cap[,cap] is MANDATORY  [--prefers c,c] [--after KEY[,KEY]]
#              [--title T] [--parallel-group G]
#              Creates the ticket, its capability rows, the node and its edges. A node
#              with no ticket and no capability is a node nothing can ever be dispatched
#              to, which is why `--needs` is not optional.
#   drop-node  Removes every instance of KEY and STITCHES its direct predecessors to its
#              direct successors, so the chain does not fall apart around the hole. One
#              hop on each side — no traversal (§3.0).
#   reshape    Records the justification, and applies `--parallel-group` when given.
#              Reshaping is how a required node stays while its width changes.
#   add-gate   REFUSED, ALWAYS. See the header.
#
# ONE db_exec per invocation. Everything a kind needs — the diagnostics, the mutation, the
# deviation row, the event and the journal markers — is one script.
cmd_graph_deviate() {
  local req="" now nowlit actorlit reqlit kindlit keylit reasonlit sql markers out line
  local caprows capsql cappayload capok a rel tplname path parsed sqlf
  local devguard haskey dropsel grouplit
  local tag key kind required
  local istemplate=0 isgate=0 isrequired=0

  while [ $# -gt 0 ]; do
    case "$1" in
      -*) break ;;
      *)
        [ -z "$req" ] || break
        req="$1"
        shift
        ;;
    esac
  done
  _graph_check_req "$req"
  _graph_parse_deviate_flags "$@"
  [ "$gd_rest_n" = 0 ] ||
    die "guild: unexpected argument '$(_render_flat_arg "$gd_rest")'

  guild graph deviate REQ-NNN --kind add-node|drop-node|reshape --node KEY --reason '...'"

  # -- add-gate is refused before anything else is even looked at ---------------------
  case "$gd_kind" in
    add-gate)
      die "guild: a gate may never be added — refused (design 6.3).

The guild has exactly two gates and their placement is the whole model: approve the plan,
then run to completion, then approve the repairs. A third gate is the SUBTLE failure, not
the obvious one — it reads as caution and it quietly turns unattended operation into a
session that stops every twenty minutes waiting for a human who is asleep, because a gate
is precisely where a shift stops and notifies (design 8).

If work genuinely needs a decision, put it at 'gate-repairs': findings are COLLECTED
during the run and judged together there, which is one decision instead of N."
      ;;
    add-node | drop-node | reshape) ;;
    '')
      die "guild: graph deviate requires --kind add-node|drop-node|reshape

  guild graph deviate REQ-NNN --kind add-node --node research --reason '...' --needs research"
      ;;
    *)
      die "guild: '$gd_kind' is not a deviation kind (expected add-node, drop-node or reshape).

'add-gate' is a kind the schema records and this command refuses; see design 6.3."
      ;;
  esac

  _graph_check_key "$gd_node" '--node'
  _graph_check_reason "$gd_reason"

  db_require_init

  # -- the baseline, because three of the refusals are template-relative -------------
  #
  # This IS a second round trip, and it is the one place in the file that takes one. It
  # buys the difference between refusing a bad deviation and recording it: whether
  # `--node gate-plan` names a gate, and whether it is `required: true`, are facts about
  # the TEMPLATE FILE, so they cannot be asked of the mutation script. Refusing before any
  # SQL runs is also what makes the refusal messages honest — they say nothing was written
  # because nothing had been.
  #
  # Staged through `_render_query` rather than `printf | db_query`: on the right of a pipe
  # the driver runs in a subshell, so the `die` inside `db_require_binary` would exit only
  # that subshell and this function would sail on with an empty result and report "no
  # execution graph" for a missing tursodb.
  reqlit="$(sql_str "$req")"
  sqlf="$(_graph_tmp sql)"
  markers="$(_graph_tmp state)"
  printf "SELECT 'T|' || %s FROM guild_state WHERE key = %s;\n" \
    "$(_graph_field 'value')" "$(sql_str "$(_graph_state_key "$req")")" >"$sqlf"
  _render_query "$sqlf" "$markers" "guild: could not read the graph for $req"
  tplname="$(LC_ALL=C awk 'substr($0,1,2) == "T|" { print substr($0,3); exit }' "$markers")"
  rm -f "$markers"
  [ -n "$tplname" ] ||
    die "guild: $req has no execution graph (run 'guild graph new $req' first)"
  _graph_check_template_name "$tplname"
  path="$(_graph_template_path "$tplname")"
  parsed="$(_graph_tmp tpl)"
  _graph_parse_template "$path" "$parsed"
  # Only three of the eleven template fields decide anything here, so the rest are read
  # into `_` — a placeholder that keeps the FIELD POSITIONS exact (the whole point of
  # reading with a fixed variable list) without leaving named variables nobody uses.
  while IFS='|' read -r tag _ key kind required _; do
    [ "$tag" = "NODE" ] || continue
    [ "$key" = "$gd_node" ] || continue
    istemplate=1
    [ "$kind" != "gate" ] || isgate=1
    [ "$required" != "true" ] || isrequired=1
  done <"$parsed"
  rm -f "$parsed"

  case "$gd_kind" in
    drop-node)
      [ "$isgate" = 0 ] ||
        die "guild: '$gd_node' is a GATE and a gate may never be dropped — refused (design 6.3).

Gates are the guild master's control surface, fixed at two. Dropping one removes the only
point at which the plan can be redirected before anything is built, or the only point at
which findings are judged before repairs run. There is no reason good enough, because the
cost is not paid at the moment of the decision."
      [ "$isrequired" = 0 ] ||
        die "guild: '$gd_node' is marked 'required: true' in the $tplname template and may be
RESHAPED but never DROPPED — refused (design 6.3).

Review always happens; how wide it fans out is negotiable. If the shape is wrong, say so:

  guild graph deviate $req --kind reshape --node $gd_node --reason '...'"
      ;;
    add-node)
      [ "$istemplate" = 0 ] ||
        die "guild: '$gd_node' is already a node in the $tplname template — it cannot be ADDED.

If its shape is wrong, reshape it:
  guild graph deviate $req --kind reshape --node $gd_node --reason '...'"
      [ -n "$gd_needs" ] ||
        die "guild: --kind add-node requires --needs <capability>[,<capability>] (design 6.3).

A node names the capability it needs, and that capability must exist in the roster —
otherwise you get a graph that cannot run: no member is eligible, the bounty is never
taken, and the segment stalls at a node nobody can be dispatched to.

  guild graph deviate $req --kind add-node --node research --needs research \\
      --after gate-plan --reason 'the payments API is undocumented'"
      ;;
    reshape)
      [ "$istemplate" = 1 ] || [ -n "$gd_group" ] ||
        printf 'guild: note — %s is not a node in the %s template; recording the reshape anyway.\n' \
          "$gd_node" "$tplname" >&2
      ;;
  esac

  journal_preflight
  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  kindlit="$(sql_str "$gd_kind")"
  keylit="$(sql_str "$gd_node")"
  reasonlit="$(sql_text "$gd_reason" '--reason')"

  devguard="$(_graph_dev_guard "$reqlit" "$kindlit" "$keylit" "$nowlit")"
  haskey="EXISTS (SELECT 1 FROM graph_node WHERE requirement_id = $reqlit AND node_key = $keylit)"
  dropsel="(SELECT id FROM graph_node WHERE requirement_id = $reqlit AND node_key = $keylit)"
  grouplit="NULLIF($(sql_text "$gd_group" '--parallel-group'), '')"

  sql="BEGIN;
SELECT 'MISS|' || m.x FROM (SELECT $reqlit AS x) m WHERE NOT EXISTS (SELECT 1 FROM requirement WHERE id = $reqlit);
SELECT 'EXISTS|' || COUNT(*) FROM graph_node WHERE requirement_id = $reqlit;
SELECT 'HASKEY|' || COUNT(*) FROM graph_node WHERE requirement_id = $reqlit AND node_key = $keylit;
"

  case "$gd_kind" in
    add-node)
      caprows="$(_art_capability_rows "$gd_needs" "$gd_prefers")" || exit 1
      [ -n "$caprows" ] || die "guild: --needs named no usable capability"
      capsql="$(_art_capability_sql "$caprows" "$nowlit")"
      cappayload="$(_art_capability_payload "$caprows")"

      # EVERY REQUIRED CAPABILITY MUST BE DECLARED BY AN ACTIVE MEMBER, and the check is
      # part of the deviation's own precondition rather than a prior read: a node whose
      # capability nobody has is a node the dispatcher can never fill, so neither it nor
      # the record justifying it may come into existence. The NOCAP diagnostic below names
      # the ones that are missing, in the same buffer as the refusal.
      rel=""
      while IFS=' ' read -r a key; do
        [ "$a" = "1" ] || continue
        [ -n "$key" ] || continue
        rel="$rel${rel:+ UNION ALL }SELECT $(sql_str "$key") AS c"
      done <<EOF
$caprows
EOF
      capok="NOT EXISTS (SELECT 1 FROM ($rel) v
                   WHERE NOT EXISTS (SELECT 1 FROM agent_capability ac JOIN agent a ON a.name = ac.agent
                                      WHERE a.active = 1 AND ac.capability = v.c))"

      sql="$sql
SELECT 'NOCAP|' || v.c FROM ($rel) v
 WHERE NOT EXISTS (SELECT 1 FROM agent_capability ac JOIN agent a ON a.name = ac.agent
                    WHERE a.active = 1 AND ac.capability = v.c);
$(_graph_deviation_sql "$reqlit" "$kindlit" "$keylit" "$reasonlit" "$nowlit" \
    "AND EXISTS (SELECT 1 FROM graph_node WHERE requirement_id = $reqlit)
  AND NOT $haskey
  AND $capok")
INSERT INTO task (id, requirement_id, plan_id, plan_slice_id, plan_slice, parallel_group,
                  node_key, title, objective, body, status, priority, agent,
                  claimed_by, claimed_at, created_at, updated_at)
SELECT $(_art_next_id_expr task), r.id, NULL, NULL, NULL, $grouplit,
       $keylit, $(sql_text "${gd_title:-$gd_node}" '--title'),
       $(sql_text "$(_art_defuse_body "$gd_reason")" '--reason'), '', 'todo', 3, NULL,
       NULL, NULL, $nowlit, $nowlit
FROM requirement r
WHERE r.id = $reqlit AND $devguard
RETURNING 'R|task|upsert|' || $(_art_json_row task);
$capsql
INSERT INTO graph_node (id, requirement_id, node_key, kind, task_id, parallel_group, status)
SELECT $(sql_str "$req/$gd_node"), t.requirement_id, $keylit, 'work', t.id, $grouplit, 'pending'
FROM task t
WHERE t.id = (SELECT 'TASK-' || printf('%03d', MAX(CAST(substr(id,6) AS INTEGER))) FROM task)
  AND t.requirement_id = $reqlit AND t.node_key = $keylit AND t.updated_at = $nowlit
  AND $devguard
  AND NOT EXISTS (SELECT 1 FROM event e
                   WHERE e.verb = 'created' AND e.subject_type = 'task' AND e.subject_id = t.id)
RETURNING 'R|graph_node|upsert|' || $(_art_json_row graph_node);
$(_art_created_event_sql task task "$nowlit" "$actorlit" "$cappayload")"

      # The edges. `--after` names existing node KEYS; EVERY instance of each becomes a
      # predecessor, which is `graph new`'s edge rule and must be — otherwise an added node
      # would start ready while a fanned predecessor was still running.
      if [ -n "$gd_after" ]; then
        while IFS= read -r a; do
          [ -n "$a" ] || continue
          _graph_check_key "$a" '--after'
          sql="$sql
INSERT INTO graph_edge (from_node, to_node)
SELECT f.id, t.id FROM graph_node f, graph_node t
WHERE f.requirement_id = $reqlit AND t.requirement_id = $reqlit
  AND f.node_key = $(sql_str "$a") AND t.node_key = $keylit AND f.id <> t.id
  AND $devguard
RETURNING 'R|graph_edge|upsert|' || $(_art_json_row graph_edge);"
        done <<EOF
$(printf '%s' "$gd_after" | LC_ALL=C tr ',' '
')
EOF
      fi
      ;;

    drop-node)
      # THE DELETE MARKERS COME FIRST, while the rows still exist — and the STITCH comes
      # before the deletes, so each direct predecessor of the dropped node is joined to
      # each of its direct successors and the chain does not fall apart around the hole.
      # Both sides are ONE HOP: predecessors of X, successors of X, joined pairwise. No
      # traversal, no recursion (§3.0).
      #
      # Every statement here — the markers included — carries $devguard, so a drop that
      # was refused emits no journal line claiming rows were removed.
      sql="$sql
$(_graph_deviation_sql "$reqlit" "$kindlit" "$keylit" "$reasonlit" "$nowlit" "AND $haskey")
SELECT 'R|graph_node|delete|' || json_object('id', n.id) FROM graph_node n
 WHERE n.requirement_id = $reqlit AND n.node_key = $keylit AND $devguard;
SELECT 'R|graph_edge|delete|' || json_object('from_node', e.from_node, 'to_node', e.to_node)
  FROM graph_edge e
 WHERE (e.from_node IN $dropsel OR e.to_node IN $dropsel) AND $devguard;
INSERT INTO graph_edge (from_node, to_node)
SELECT p.from_node, s.to_node
  FROM graph_edge p, graph_edge s
 WHERE p.to_node   IN $dropsel
   AND s.from_node IN $dropsel
   AND p.from_node <> s.to_node
   AND p.from_node NOT IN $dropsel
   AND s.to_node   NOT IN $dropsel
   AND $devguard
   AND NOT EXISTS (SELECT 1 FROM graph_edge x WHERE x.from_node = p.from_node AND x.to_node = s.to_node);
DELETE FROM graph_edge
 WHERE (from_node IN $dropsel OR to_node IN $dropsel) AND $devguard;
DELETE FROM gate WHERE node_id IN $dropsel AND $devguard;
DELETE FROM graph_node
 WHERE requirement_id = $reqlit AND node_key = $keylit AND $devguard;
SELECT 'R|graph_edge|upsert|' || $(_art_json_row graph_edge) FROM graph_edge
 WHERE to_node IN (SELECT id FROM graph_node WHERE requirement_id = $reqlit) AND $devguard
 ORDER BY from_node, to_node;"
      ;;

    reshape)
      sql="$sql
$(_graph_deviation_sql "$reqlit" "$kindlit" "$keylit" "$reasonlit" "$nowlit" "AND $haskey")"
      if [ -n "$gd_group" ]; then
        sql="$sql
UPDATE graph_node SET parallel_group = $grouplit
 WHERE requirement_id = $reqlit AND node_key = $keylit AND $devguard
RETURNING 'R|graph_node|upsert|' || $(_art_json_row graph_node);"
      fi
      ;;
  esac

  sql="$sql
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $actorlit, 'deviated', 'graph', $reqlit,
       json_object('kind', $kindlit, 'node_key', $keylit)
WHERE $devguard;
COMMIT;
"

  markers="$(_graph_tmp markers)"
  if ! printf '%s' "$sql" | db_exec >"$markers"; then
    out="$(cat "$markers" 2>/dev/null || true)"
    rm -f "$markers"
    db_fail "could not record the deviation on $req" "$out"
  fi

  line="$(LC_ALL=C awk -F'|' '$1 == "MISS" { print $2; exit }' "$markers")"
  if [ -n "$line" ]; then rm -f "$markers"; die "guild: $req not found"; fi

  line="$(LC_ALL=C awk -F'|' '$1 == "EXISTS" { print $2; exit }' "$markers")"
  if [ -z "$line" ] || [ "$line" = "0" ]; then
    rm -f "$markers"
    die "guild: $req has no execution graph (run 'guild graph new $req' first)"
  fi

  line="$(LC_ALL=C awk -F'|' '$1 == "NOCAP" { printf "%s%s", (n++ ? ", " : ""), $2 } END { print "" }' "$markers")"
  if [ -n "$line" ]; then
    rm -f "$markers"
    die "guild: no active guild member declares: $line

Nothing was written. An added node names the capability it needs and that capability must
EXIST in the roster (design 6.3) — a node nobody is eligible for is a node the segment
stalls at forever. Either tag a member with it in agents/<name>.md and run
'guild sync-agents', or file the gap so the guild master can decide:

  guild capability-request $line --req $req --rationale '...' --proposes developer-x"
  fi

  line="$(LC_ALL=C awk -F'|' '$1 == "HASKEY" { print $2; exit }' "$markers")"
  case "$gd_kind" in
    add-node)
      if [ -n "$line" ] && [ "$line" != "0" ]; then
        rm -f "$markers"
        die "guild: $req already has a node keyed '$gd_node' — nothing was written.

Reshape it instead:
  guild graph deviate $req --kind reshape --node $gd_node --reason '...'"
      fi
      ;;
    drop-node | reshape)
      if [ -z "$line" ] || [ "$line" = "0" ]; then
        rm -f "$markers"
        die "guild: $req has no node keyed '$gd_node' — nothing was written.

Read the graph with 'guild graph $req' to see the keys it does have."
      fi
      ;;
  esac

  if ! LC_ALL=C grep -q '^R|graph_deviation|' "$markers"; then
    out="$(cat "$markers" 2>/dev/null || true)"
    rm -f "$markers"
    db_fail "could not record the deviation on $req" "$out"
  fi

  _graph_journal_markers "$markers" >/dev/null
  rm -f "$markers"

  printf '%s %s %s\n' "$req" "$gd_kind" "$gd_node"
}

# ============================ dispatch ================================================

# cmd_graph — `guild graph <subcommand|REQ-NNN> ...`.
#
# The bare form takes a requirement id, so the subcommand namespace and the id namespace
# have to be told apart. They cannot collide: a subcommand is lowercase and a requirement
# id starts with `REQ-`, which `_graph_check_req` enforces. Anything else is named in the
# error rather than guessed at.
cmd_graph() {
  local sub="${1-}"
  case "$sub" in
    '')
      die "guild: graph requires a requirement id or a subcommand

  guild graph new <REQ-NNN> [--template standard|maintenance]
  guild graph <REQ-NNN> [--explain]
  guild graph validate <REQ-NNN>
  guild graph deviate <REQ-NNN> --kind add-node|drop-node|reshape --node KEY --reason '...'"
      ;;
    new) shift; cmd_graph_new "$@" ;;
    validate) shift; cmd_graph_validate "$@" ;;
    deviate) shift; cmd_graph_deviate "$@" ;;
    REQ-*) cmd_graph_show "$@" ;;
    -*) die "guild: unknown option '$sub' for graph (try 'guild graph REQ-NNN [--explain]')" ;;
    *)
      die "guild: '$(_render_flat_arg "$sub")' is neither a requirement id nor a graph subcommand.

  guild graph new <REQ-NNN> [--template standard|maintenance]
  guild graph <REQ-NNN> [--explain]
  guild graph validate <REQ-NNN>
  guild graph deviate <REQ-NNN> --kind add-node|drop-node|reshape --node KEY --reason '...'"
      ;;
  esac
}
