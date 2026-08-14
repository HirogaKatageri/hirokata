# shellcheck shell=bash
#
# lib/template.sh — guild v5 Stage 4: THE TEMPLATES, AS A READABLE SURFACE (design §6.1, §6.2).
#
#   > Two templates ship with the plugin: `standard` (build a requirement) and
#   > `maintenance` (inspect what was built). BOTH ARE DATA, both run on the same
#   > machinery, and both end at `gate-repairs`.
#
# "Both are data" is the sentence this file exists to make true on the READ side. In v4 the
# chain was compiled into the skills: `check-in` knew that review follows test-write, and
# changing that meant editing prose in three places. Here the chain is
# `templates/standard.yaml`, lib/graph.sh instantiates it into `graph_node` / `graph_edge` /
# `gate` rows, and this module is how everything else LOOKS AT it:
#
#   template_list                              what templates exist, and from where
#   template_load <name>                       the whole template, as the flat form below
#   template_node_field <name> <key> <field>   one field of one node, BYTE-EXACT
#   cmd_templates / cmd_template               the same three, as CLI commands
#
# A project overrides a shipped template BY NAME by dropping its own copy at
# `.guild/templates/<name>.yaml`. That is the whole extension mechanism: no registry, no
# merge, no inheritance — the file that wins is the whole answer, so `guild graph` never
# runs a chain that is half yours and half ours.
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` (scripts/guild owns those).
# Bash 3.2 compatible: no associative arrays, no `declare -A`, no `mapfile`, no ${var^^}.
#
# Depends on lib/db.sh    : die
#          on lib/render.sh: _render_tmp, _render_flat_arg
#          on lib/graph.sh : _graph_check_template_name (THE template-name alphabet),
#                            _graph_templates_dirs, _graph_template_path,
#                            _graph_parse_template, _graph_tpl_name  (THE YAML scanner)
#
# ---------------------------------------------------------------------------------
# THERE IS EXACTLY ONE YAML PARSER IN THIS PLUGIN, AND IT IS NOT IN THIS FILE.
#
# It was, briefly. Stage 4 was written by five authors in parallel and two of them wrote a
# scanner for the same two files — this module's, and `_graph_parser_src` in lib/graph.sh.
# They agreed on the shipped templates and DISAGREED about everything a project override
# would hit first: one defaulted `fanout:` to `none` and the other to `fixed`; one accepted
# `fanout: none` as a spelling and the other refused it; one allowed any indent and the other
# required exactly two and four spaces; one understood `\"` inside a double-quoted scalar and
# the other refused the escape.
#
# THAT DIVERGENCE IS WORSE THAN EITHER PARSER BEING WRONG, because of where each one is
# read. lib/graph.sh's parser decides what `guild graph new` INSTANTIATES. This module's
# output decides what `guild segment` believes about CONCURRENCY (`_seg_modes` reads the
# `parallel` tag), and `_seg_modes` is deliberately NON-FATAL — a template it cannot read
# degrades silently to "one node per batch". So a project template that lib/graph.sh happily
# instantiated and this file refused would have produced a correct graph that never ran
# anything in parallel, with a warning on stderr as the only symptom.
#
# So: lib/graph.sh's scanner is THE scanner — it is the one four command paths already
# depend on, and it carries the size cap, the UTF-8 check and the tab/CR refusal — and this
# module is a PROJECTION of it. `template_load` runs it and rewrites its output into the
# flat form below. One grammar, one set of defaults, one set of error messages.
#
# ---------------------------------------------------------------------------------
# WHERE THE HARD RULES LAND IN A MODULE THAT TOUCHES NO DATABASE
#
# This module runs no SQL, writes no row and mutates nothing — it turns a file into lines.
# So "one db_exec per logical command", "journal every mutation" and "sql_text for all free
# text" have no call site here. They have a HANDOFF, and it is the reason the flat form is
# shaped the way it is:
#
#   EVERY VALUE IN THE FLAT FORM EXCEPT `desc` AND `prompt` HAS PASSED A CLOSED ALPHABET
#   IN THE PARSER AND IS SAFE FOR `sql_str`. `desc` AND `prompt` ARE FREE TEXT AND MUST
#   REACH SQL THROUGH `sql_text`.
#
# THE OUTPUT SIDE, WHICH IS THE RULE THAT DOES APPLY DIRECTLY (§2.2.2). The flat form is a
# STRUCTURED LINE FORMAT whose structural token is THE FIRST WORD OF A LINE, so a value must
# never be able to become one. Two properties give that, and both are properties of the
# parser rather than of an escaper:
#
#   * A VALUE CANNOT CONTAIN A NEWLINE. The scanner reads lines and every value is a
#     substring of one, so no value can split a line in two. This is why the free-text
#     values need no flattening: there is nothing to flatten.
#   * A FREE-TEXT VALUE IS THE WHOLE REMAINDER OF ITS LINE, and it is the LAST field
#     emitted for its record. `prompt Findings and bugs …` is read by taking everything
#     after the first blank, so a prompt containing the word `node` or a `|` or a tab
#     arrives intact and cannot be mistaken for structure.
#
# The same discipline as lib/render.sh's `_render_col` / `_render_flat` split, reached by
# construction instead of by repair, because here we own the grammar on both sides.
#
# ---------------------------------------------------------------------------------
# THE ACCEPTED YAML SUBSET — deliberately tiny, because WE author these files
#
# Documented in full at `_graph_parser_src` (lib/graph.sh), which is the code that enforces
# it. The shape, so a reader of this file is not sent away for the summary:
#
#   name: <scalar>            top level, before `nodes:`
#   description: <scalar>
#   nodes:
#     - key: <scalar>         a node begins; two spaces of indent, `- ` marker
#       kind: work|gate       four spaces thereafter
#       required: true|false                                   (default false)
#       fanout: fixed|per-slice|per-declaration|
#               per-approved-finding|per-mission               (default fixed)
#       parallel: all|by-group|never                           (default never)
#       needs: [cap, cap]     INLINE lists only
#       agents: [name, name]
#       after: [key, key]     must name a node declared EARLIER — that backwards-only
#                             rule is what proves the template acyclic in a linear scan,
#                             which is how this stage avoids the `WITH RECURSIVE` §3.0
#                             forbids
#       prompt: "<text>"      gates only, and the ONE free-text value
#       kind_detail: approve|select-findings                   (gates only, default approve)
#
# NOT CHECKED, ON PURPOSE: whether a `needs:` capability exists in the roster vocabulary,
# and whether a named agent is on the roster. Both live in the database, this module never
# opens it, and `guild graph validate` (§6.3) is where a graph is measured against the
# roster anyway. The alphabet is enforced; the vocabulary is not.
#
# ---------------------------------------------------------------------------------
# THE FLAT FORM — what `template_load` prints, and what lib/segment.sh consumes
#
# One line per fact. The tag is the first word, the value is the whole remainder of the line
# after exactly one blank. Node records are delimited by `node` lines and end at the next
# `node` or at EOF; fields appear in the fixed order below, so a consumer may either switch
# on the tag or rely on the order.
#
#   tpl <name>              once, first. The template's own name.
#   desc <text>             once, optional. FREE TEXT.
#   node <key>              starts a node record. Declaration order is graph order.
#   kind <work|gate>        always emitted
#   fanout <token>          always emitted (`fixed` when the YAML did not say)
#   parallel <token>        always emitted (`never` when the YAML did not say)
#   required <0|1>          always emitted (`0` when the YAML did not say)
#   gate-kind <token>       gates only: approve | select-findings
#   after <node-key>        zero or more, in declaration order
#   needs <capability>      zero or more, in declaration order
#   agent <agent-name>      zero or more, in declaration order
#   prompt <text>           gates only, LAST in the record. FREE TEXT.
#
# THE DEFAULTS ARE MATERIALIZED, NOT IMPLIED. `kind`, `fanout`, `parallel` and `required`
# are emitted for every node whether or not the YAML mentioned them, so a consumer never has
# to know what a default is. Two modules holding one default is how they drift — and note
# that the default `fanout` is `fixed`, which is the scanner's, not the `none` an earlier
# draft of this file invented. `fixed` with no `agents:` means ONE unfanned node, which is
# what `test-plan` and `qa-check` are.
#
# Example (`template_load standard`, first two records):
#
#   tpl standard
#   desc Plan-gated feature chain — approve the plan, then run to completion.
#   node gate-plan
#   kind gate
#   fanout fixed
#   parallel never
#   required 1
#   gate-kind approve
#   prompt Plan for {requirement} is ready for review. Approve implementation?
#   node implement
#   kind work
#   fanout per-slice
#   parallel by-group
#   required 1
#   after gate-plan
#   needs implement
#
# NOTE THAT `{requirement}` IS NOT SUBSTITUTED HERE. The template is the template; the
# substitution happens once, in `guild graph new`, at the moment the `gate` row is written
# for a named requirement. A reader of `guild template standard` should see the placeholder.
#
# `template_node_field` is the byte-exact single-value channel over the same data — the same
# relationship `guild meta <ID> <field>` has to `guild board` (§2.2.2). It prints the value
# alone, one line per element for the list-valued fields, and nothing at all for a field the
# node does not carry.
# ---------------------------------------------------------------------------------

# ---- where templates live --------------------------------------------------------
#
# THE SEARCH PATH IS `_graph_templates_dirs` AND NOTHING ELSE. An earlier draft of this file
# had its own two-directory resolver with a different override rule; the same argument as the
# parser applies, and more sharply — a `guild templates` listing that named a file
# `guild graph new` would not open is worse than no listing at all.

# _tpl_name_ok <name> — predicate form of the template-name alphabet, for the listing.
#
# `_graph_check_template_name` reports by dying, and a stray file in a templates directory
# must not take down `template_list`; one fork per file, on a command that is about to open
# every one of them anyway.
_tpl_name_ok() {
  (_graph_check_template_name "${1-}") >/dev/null 2>&1
}

# _tpl_source_label <index> — `project` or `shipped` for the Nth line of the search path.
#
# `_graph_templates_dirs` emits, in order: `$GUILD_TEMPLATES_DIR` (only when set), then
# `$GUILD_DIR/templates`, then the checkout's own `templates/`, then
# `$CLAUDE_PLUGIN_ROOT/templates`. The first one or two are the PROJECT layer and the rest
# are what SHIPS, so the label is a function of the index and of whether the override
# variable is set — which is the only place that fact is needed.
_tpl_source_label() {
  local i="${1-0}" nproject=1
  [ -z "${GUILD_TEMPLATES_DIR:-}" ] || nproject=2
  if [ "$i" -le "$nproject" ]; then
    printf 'project\n'
  else
    printf 'shipped\n'
  fi
}

# ---- the flat-form projection ----------------------------------------------------

# _tpl_flat_awk — rewrite `_graph_parse_template`'s output into the flat form.
#
# Its input is the scanner's line format, which is pipe-separated with the free-text prompt
# LAST (lib/graph.sh, THE MARKER CHANNEL):
#
#   NODE|<ord>|<key>|<kind>|<required>|<fanout>|<parallel>|<needs>|<agents>|<after>|<detail>|<prompt>
#   TPL|<name>|<description>
#
# `tailafter(s, k)` walks past exactly k delimiters and returns the rest VERBATIM, which is
# how a prompt containing a pipe survives. The leading fields come from `split`, which
# over-splits that tail into fields nobody reads — harmless, and it keeps the common case a
# single pass. No `${v#*|}` is applied to an unbounded value anywhere (rule 5).
#
# The records are BUFFERED because the scanner emits `TPL|` LAST and the flat form declares
# `tpl` FIRST. A template is a page of YAML — a dozen nodes — so holding it is not the
# unbounded accumulation rule 5 is about.
_tpl_flat_awk() {
  cat <<'FLAT'
function tailafter(s, k,   i, p) {
  for (i = 1; i <= k; i++) { p = index(s, "|"); if (p == 0) return ""; s = substr(s, p + 1) }
  return s
}
function emitlist(v, tag,   n, a, j) {
  if (v == "") return
  n = split(v, a, ",")
  for (j = 1; j <= n; j++) if (a[j] != "") printf("%s %s\n", tag, a[j])
}
substr($0, 1, 4) == "TPL|" {
  s = substr($0, 5)
  i = index(s, "|")
  if (i > 0) { tname = substr(s, 1, i - 1); tdesc = substr(s, i + 1) } else { tname = s }
  next
}
substr($0, 1, 5) == "NODE|" {
  nn++
  split($0, p, "|")
  nkey[nn] = p[3]; nkind[nn] = p[4]; nreq[nn] = p[5]; nfan[nn] = p[6]; npar[nn] = p[7]
  nneed[nn] = p[8]; nagt[nn] = p[9]; naft[nn] = p[10]; ndet[nn] = p[11]
  nprompt[nn] = tailafter($0, 11)
  next
}
END {
  if (tname == "") exit 0
  printf("tpl %s\n", tname)
  if (tdesc != "") printf("desc %s\n", tdesc)
  for (i = 1; i <= nn; i++) {
    printf("node %s\n", nkey[i])
    printf("kind %s\n", nkind[i])
    printf("fanout %s\n", nfan[i])
    printf("parallel %s\n", npar[i])
    printf("required %d\n", (nreq[i] == "true" ? 1 : 0))
    if (nkind[i] == "gate") printf("gate-kind %s\n", ndet[i])
    emitlist(naft[i],  "after")
    emitlist(nneed[i], "needs")
    emitlist(nagt[i],  "agent")
    # FREE TEXT, AND THEREFORE LAST IN THE RECORD (§2.2.2).
    if (nkind[i] == "gate" && nprompt[i] != "") printf("prompt %s\n", nprompt[i])
  }
}
FLAT
}

# ---- the public surface ----------------------------------------------------------

# template_load <name> — print the template in the flat form documented above.
#
# One file open and one scanner run. `_graph_parse_template` dies naming the file and the
# line when the YAML steps outside the subset, which is what makes this safe to call from a
# subshell and test the status (lib/segment.sh's `_seg_modes` does exactly that, and treats
# a failure as "batch every node alone" rather than as a reason to refuse to run).
#
# THE NAME AND THE FILENAME MUST AGREE, checked here rather than only in `guild graph new`:
# `--explain` and `validate` both diff a graph against the template `guild_state` says built
# it, and a file that answers to a name it does not declare is a baseline nobody can trust.
template_load() {
  local name="${1-}" path parsed declared
  _graph_check_template_name "$name"
  path="$(_graph_template_path "$name")"
  parsed="$(_render_tmp tplload)"
  _graph_parse_template "$path" "$parsed"

  declared="$(_graph_tpl_name "$parsed")"
  if [ "$declared" != "$name" ]; then
    rm -f "$parsed"
    die "guild: $path declares 'name: $declared' but was asked for as '$name'.

The name in the file and the name of the file must agree — the filename is how a template is
asked for, and 'guild graph REQ --explain' diffs an actual graph against the template
'guild_state' recorded, by name."
  fi

  LC_ALL=C awk "$(_tpl_flat_awk)" "$parsed"
  rm -f "$parsed"
}

# template_list — the templates that exist, one per line: `<name> <source>`.
#
# COLUMNAR, therefore awk-filterable, therefore both columns are closed alphabets: a name
# that passed the template-name alphabet cannot contain a blank, and the source is one of
# two literals. The PATH is deliberately not a column — it is the one value here that can
# contain a blank, and the rule (§2.2.2) is that such a value goes last or not at all.
#
# Project first, shipped second, ONE ROW PER NAME: an overridden template appears once, as
# `project`, because that is the file `_graph_template_path` would open. A shadowed shipped
# file is not a second answer to report; it is a file nothing reads.
template_list() {
  local dir out base f i=0 src seen=" "
  out="$(_render_tmp tpllist)"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    i=$((i + 1))
    [ -d "$dir" ] || continue
    src="$(_tpl_source_label "$i")"
    for f in "$dir"/*.yaml; do
      [ -f "$f" ] || continue
      base="${f##*/}"
      base="${base%.yaml}"
      if ! _tpl_name_ok "$base"; then
        printf "guild: skipping '%s' — its filename is not a usable template name (lowercase letters, digits and '-')\n" "$f" >&2
        continue
      fi
      # Bounded by the number of template FILES (two, today), so a membership test over a
      # string is the right size of mechanism — this is not the unbounded accumulation
      # rule 5 is about.
      case "$seen" in
        *" $base "*) continue ;;
      esac
      seen="$seen$base "
      printf '%s %s\n' "$base" "$src" >>"$out"
    done
    # A `.yml` file would be INVISIBLE rather than wrong, which is the worse failure.
    for f in "$dir"/*.yml; do
      [ -f "$f" ] || continue
      printf "guild: ignoring '%s' — templates are '<name>.yaml', not '.yml'\n" "$f" >&2
    done
  done <<EOF
$(_graph_templates_dirs)
EOF
  LC_ALL=C sort "$out"
  rm -f "$out"
}

# template_node_field <name> <key> <field> — one field of one node, BYTE-EXACT.
#
# The single-value channel over the flat form, and the same relationship `guild meta <ID>
# <field>` has to `guild board` (§2.2.2): the columnar surface is unforgeable, this one is
# verbatim, and no surface tries to be both. A list-valued field prints one element per
# line, in declaration order. A field the node does not carry prints NOTHING and exits 0 —
# absence is an answer, not an error, and a caller wanting to distinguish them tests for the
# empty string rather than the exit status.
#
# <field> is the YAML spelling, not the flat-form tag: `kind_detail`, not `gate-kind`. The
# template is the vocabulary a reader already has in front of them.
template_node_field() {
  local name="${1-}" key="${2-}" field="${3-}" flat tag found

  [ -n "$key" ] ||
    die "guild: this command needs a node key — 'guild template <name> <node-key> <field>'"
  [ -n "$field" ] ||
    die "guild: this command needs a field name (one of: key kind prompt kind_detail required needs after fanout parallel agents)"

  case "$field" in
    key)         tag="node" ;;
    kind)        tag="kind" ;;
    prompt)      tag="prompt" ;;
    kind_detail) tag="gate-kind" ;;
    required)    tag="required" ;;
    fanout)      tag="fanout" ;;
    parallel)    tag="parallel" ;;
    needs)       tag="needs" ;;
    after)       tag="after" ;;
    agents)      tag="agent" ;;
    *)
      die "guild: '$field' is not a template node field.

The fields are: key kind prompt kind_detail required needs after fanout parallel agents"
      ;;
  esac

  # One parse, staged in a file rather than piped, so `template_load`'s `die` ends the
  # process with its own message instead of exiting a subshell and leaving this function to
  # report an empty template as a missing node.
  flat="$(_render_tmp tplfield)"
  template_load "$name" >"$flat"

  found="$(LC_ALL=C awk -v want="$key" -v tag="$tag" '
    {
      p = index($0, " ")
      if (p == 0) { t = $0; v = "" } else { t = substr($0, 1, p - 1); v = substr($0, p + 1) }
      if (t == "node") { inn = (v == want); if (inn) seen = 1; next }
      if (!inn) next
      if (t == tag) print v
    }
    END { exit seen ? 0 : 1 }
  ' "$flat" && printf 'y')" || {
    rm -f "$flat"
    die "guild: template '$name' has no node named '$key'"
  }
  rm -f "$flat"

  # `$found` ends in the 'y' the subshell appended, which is what keeps command substitution
  # from eating a trailing blank line the value legitimately has. The `node` tag is the key
  # itself, which the flat form does not repeat as a field.
  found="${found%y}"
  if [ "$tag" = "node" ]; then
    printf '%s\n' "$key"
    return 0
  fi
  [ -z "$found" ] || printf '%s' "$found"
}

# ---- the commands ----------------------------------------------------------------

# cmd_templates — `guild templates`. The listing, and nothing else.
#
# Reads only, opens no database: a template is a file, and knowing which ones exist is a
# question you can ask before `guild init` has ever run. That is deliberate — `guild graph
# new --template <name>` is the first thing an architect types, and "what may I type here"
# should not require a board.
cmd_templates() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -*) die "guild: unknown option '$1' for templates (try 'guild templates')" ;;
      *) die "guild: templates takes no arguments (got '$(_render_flat_arg "$1")').

  guild templates                              what exists, and from where
  guild template <name>                        the whole template
  guild template <name> <node-key> <field>     one field, byte-exact" ;;
    esac
  done
  template_list
}

# cmd_template <name> [<node-key> <field>] — `guild template`. One template, or one field.
cmd_template() {
  local name="" key="" field="" n=0

  while [ $# -gt 0 ]; do
    case "$1" in
      -*) die "guild: unknown option '$1' for template (try 'guild template <name> [<node-key> <field>]')" ;;
      *)
        n=$((n + 1))
        case "$n" in
          1) name="$1" ;;
          2) key="$1" ;;
          3) field="$1" ;;
          *)
            die "guild: template takes at most three arguments (got '$(_render_flat_arg "$1")').

  guild template <name>                        the whole template
  guild template <name> <node-key> <field>     one field, byte-exact"
            ;;
        esac
        ;;
    esac
    shift
  done

  [ -n "$name" ] ||
    die "guild: template requires a template name.

  guild templates                              what exists, and from where
  guild template standard                      the whole template
  guild template standard review parallel      one field, byte-exact"

  if [ -n "$key" ] && [ -z "$field" ]; then
    die "guild: naming a node also requires a field.

  guild template $name $key kind
  guild template $name $key needs

The fields are: key kind prompt kind_detail required needs after fanout parallel agents"
  fi

  if [ -n "$key" ]; then
    template_node_field "$name" "$key" "$field"
    return 0
  fi
  template_load "$name"
}
