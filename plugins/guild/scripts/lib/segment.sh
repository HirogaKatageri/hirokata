# shellcheck shell=bash
#
# lib/segment.sh — guild v5 Stage 4: SEGMENTS AND GATES (design §6.4, §7).
#
#   > A SEGMENT is the maximal set of nodes runnable from the current state up to, but
#   > NOT including, the next unresolved gate.
#
# lib/graph.sh turns a template into `graph_node` / `graph_edge` / `gate` rows. This file
# turns those rows into RUNNABLE WORK: the ordered batches an orchestrator compiles into
# one workflow (§7), and the two-decision control surface — approve, reject — that the
# guild master owns and no subagent can reach.
#
#   guild segment <REQ-NNN> [--json]     the next gate-free run of node batches
#   guild node <NODE-ID> <status> [--task TASK-NNN]   the WORK node writer (dispatch/finish)
#   guild gate <NODE-ID> --approve [--decision X] | --reject [--decision X]
#   guild gates [--pending] [--json]     the gates awaiting the guild master
#
# THREE WRITERS, ONE RULE. The orchestrator owns every status transition (§1) and there are
# exactly three commands that make one: `guild move` for an artifact, `guild node` for a work
# node, `guild gate` for a gate. Nothing else writes a status, and no agent calls any of the
# three. `guild node` was missing from the first cut of Stage 4 and its absence was total:
# `guild segment`'s sweep treats `done`/`skipped` as finished, so with no way to finish a
# node the first batch was the only batch a requirement would ever produce — the same work,
# re-emitted forever, and `gate-repairs` never becoming ready. It is not a convenience; it is
# the thing that makes readiness propagate.
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` (scripts/guild owns those).
# Bash 3.2 compatible: no associative arrays, no `declare -A`, no `mapfile`, no ${var^^}.
#
# Depends on lib/db.sh       : die, db_fail, db_require_init, db_exec, db_query, db_now,
#                              sql_str, sql_text
#          on lib/journal.sh : journal_preflight
#          on lib/artifacts.sh: _art_actor, _art_json_row (THE ONE PROJECTION REGISTRY —
#                              `gate` and `graph_node` are arms of it, not of a private copy)
#          on lib/render.sh  : _render_flat, _render_flat_arg, _render_col, _render_tmp,
#                              _render_query
#          on lib/brief.sh   : _brief_txt (clip, then flatten — the human free-text gate)
#          on lib/graph.sh   : _graph_check_req, _graph_check_key, _graph_field,
#                              _graph_ready_where, _graph_state_key,
#                              _graph_journal_markers
#          on lib/roster.sh  : _roster_top_agent (THE matcher — rank 1, pin and fallback)
#          on lib/template.sh: template_load (the flat form — a PROJECTION of lib/graph.sh's
#                              scanner, which is the CLI's only YAML parser)
#
# THOSE DEPENDENCIES ARE DELIBERATE REUSE, NOT CONVENIENCE — the rule lib/records.sh,
# lib/quality.sh, lib/roster.sh and lib/graph.sh all state in their headers. Three of
# them are load-bearing here in particular:
#
#   * `_graph_ready_where` IS readiness. `guild graph`'s render, this file's simulation
#     and (next) the dispatcher must agree about what "ready" means; two spellings of
#     readiness is two answers to "what runs next". It is called, never restated.
#   * `_roster_top_agent` IS rank 1 — the pin, then §5.2's ranking, then the no-capability
#     fallback. `guild segment` names the agent each node dispatches to, and if it picked
#     that agent by any other rule then `guild match` and `guild segment` would name two
#     different members for one ticket.
#   * `template_load` IS the template reader. This file needs TWO facts the database does
#     not carry — a node key's declared `parallel:` mode, and its declaration ordinal — and
#     it gets them from lib/template.sh rather than growing a second parser. Note where that
#     chain actually ends: lib/template.sh is itself a projection of lib/graph.sh's scanner,
#     so `guild graph new` and `guild segment` cannot disagree about what a template file
#     says. They did, briefly, and the failure mode was invisible — see lib/template.sh's
#     header for what a divergence here costs.
#
# ---------------------------------------------------------------------------------
# HARD RULES honored throughout (§2.2, §2.2.1, §3.0):
#
#   * ONE db_exec PER LOGICAL COMMAND. `guild segment` reads the requirement, the template
#     record, every node, every edge and every gate in ONE script; the batching then runs
#     entirely in awk over rows already in hand. `guild gate` writes the gate row, the
#     graph node, the event and both journal markers in ONE script. Nothing here loops
#     over data and calls the driver inside the loop.
#
#     `guild segment` ALSO READS A FILE — the template — and that is not a second round
#     trip: it is a file open, it happens AFTER the single query, and it is the same
#     baseline `guild graph --explain` and `guild graph validate` take one round trip to
#     locate. It is also NON-FATAL (see `_seg_modes`): a graph outlives the template file
#     that shaped it, and a segment that refuses to run because a YAML file was renamed
#     would be worse than one that runs conservatively.
#
#   * sql_text FOR ALL FREE TEXT; sql_str ONLY for known-safe alphabets. A `--decision` is
#     a paragraph the guild master typed — routinely a list of findings with quoted code —
#     so it travels as hex. A NODE ID does not: it is validated here as `REQ-<digits>` plus
#     a node key plus an optional `.`-suffix drawn from the CLI's one key alphabet, which
#     is what lets it reach SQL through `sql_str` and be CONCATENATED into an error message.
#
#   * NEVER `WITH RECURSIVE`, AND THIS IS THE FILE WHERE THAT BITES. A segment is a
#     forward traversal of a dependency graph — the textbook recursive-CTE query. THE SQL
#     NEVER TRAVERSES. It asks one question per node, ONE HOP deep (`_graph_ready_where`:
#     "no direct predecessor is unfinished"), and hands the shell a flat node list and a
#     flat edge list. The multi-batch LOOK-AHEAD then runs in awk over those two lists —
#     an in-memory level sweep over a few dozen rows, not a query. See THE LEVEL SWEEP.
#
#   * A VALUE MUST NEVER IMPERSONATE A STRUCTURAL TOKEN. Two output channels, two
#     disciplines — see THE MARKER CHANNEL and THE JSON CHANNEL below. The second one is
#     the stricter and the more important: `--json` is what an orchestrator EXECUTES.
#
#   * No quadratic string handling. Marker lines are split by `read`/`split` with a FIXED
#     field count so the free-text remainder lands in the last variable untouched; the
#     template's flat form is reduced by one awk pass rather than by `${v%%pat*}` per line;
#     no `${v#*pat}` is ever applied to an unbounded value.
#
#   * EVERY MUTATION IS JOURNALED AND EMITS AN `event` ROW. `guild gate` is the only
#     mutation in this file, and it writes an `approved`/`rejected` event plus journal
#     lines for BOTH rows it changes. journal_preflight runs BEFORE any SQL, so an
#     unwritable journal is a refusal that says nothing was written rather than a decision
#     `guild rebuild` silently undoes. `guild segment` and `guild gates` mutate NOTHING.
#
# ---------------------------------------------------------------------------------
# THE MARKER CHANNEL
#
# `guild segment` gets its rows back as pipe-separated marker lines:
#
#   Q|<status>|<json-req-id>|<title>      the requirement (title is free text, LAST)
#   T|<template>|<json-template>          which template built this graph
#   N|<id>|<key>|<kind>|<status>|<group>|<serial>|<agent>|<task>|<jagent>|<jtask>|<jid>
#   P|<from>|<to>                         one edge, successor side already filtered
#   G|<id>|<gstatus>|<gkind>|<jid>|<jgstatus>|<jgkind>
#   GP|<id>|<prompt>                      the gate prompt      (free text, LAST)
#   GD|<id>|<decision>                    the recorded decision (free text, LAST)
#
# THE ONLY FIELD THAT MAY CONTAIN A PIPE IS THE LAST ONE, and every reader splits on a
# FIXED number of leading delimiters rather than on all of them. That is why the two
# genuinely free-text values — a gate's prompt and its decision — get LINES OF THEIR OWN
# keyed by node id, instead of two more fields on the `G|` line where only one of them
# could have been last. `_graph_field` (lib/graph.sh: `_render_col` plus a pipe
# replacement) wraps every value in a non-final position.
#
# ---------------------------------------------------------------------------------
# THE JSON CHANNEL — the one an orchestrator EXECUTES
#
# §7: the orchestrator reads `guild segment --json` and emits a workflow script from it.
# A value that could forge a token in that document does not corrupt a report, it changes
# what runs. So the rule here is stronger than "escape on the way out":
#
#   NOT ONE VALUE IN THE JSON DOCUMENT IS INTERPOLATED BY THE SHELL OR BY AWK.
#
# Every string in it — the requirement id, the template name, each node id, each agent
# name, each task id, each gate field, the prompt — arrives from the driver ALREADY
# ESCAPED, as a complete JSON literal produced by `json_object()` (see `_seg_json_str`).
# awk concatenates literals with commas and brackets and never touches a character of a
# value; the shell never sees one. The only things this file writes into the document are
# structural: `{`, `}`, `[`, `]`, `,`, the fixed key names, and `true`/`false`.
#
# That is `guild brief --json` and `guild export --json`'s division of labour, applied to
# the one surface where the consequence of getting it wrong is execution rather than
# display.
#
# ---------------------------------------------------------------------------------
# THE LEVEL SWEEP — how a one-hop predicate produces a multi-batch look-ahead
#
# `_graph_ready_where` answers "is this node ready RIGHT NOW". A segment is more than
# that: §6.4's example shows five batches, of which only the first is ready now — the rest
# become ready AS THE SEGMENT RUNS. Computing that in SQL is transitive closure, which is
# `WITH RECURSIVE`, which tursodb does not have (§3.0) and which would have failed on local
# mode only, the worst kind of bug to find late.
#
# So it is computed in awk, over the node list and the edge list the one query returned:
#
#   avail[] starts as the nodes that are already `done` or `skipped`
#   repeat:
#     newly = every candidate node whose EVERY DIRECT PREDECESSOR is in avail[]
#     if newly is empty: stop
#     the gates in newly are RECORDED and NEVER SATISFIED  <- this is the segment boundary
#     the work in newly is cut into batches and added to avail[]
#
# Each pass is the same one-hop question the SQL asks, asked again against a hypothetical
# future. Two consequences worth stating:
#
#   * A GATE IS A WALL, NOT A STOP. Marking a gate "never available" is what makes the
#     segment end before it — and it is also what keeps the segment MAXIMAL, because work
#     that does NOT descend from that gate keeps being scheduled in later passes. On the
#     two shipped templates the graph is a chain and the two readings coincide; on a
#     deviated graph with a parallel branch, "stop at the first gate" would silently drop
#     runnable work and "never satisfy a gate" does not.
#   * A CYCLE CANNOT HANG IT. A node in a cycle never has all its predecessors available,
#     so it simply never enters `newly` and the sweep terminates on its own. (Templates are
#     proved acyclic at parse time; this is about deviated graphs.)
#
# CANDIDATES, AND WHY `running` AND `failed` BLOCK:
#
#   work node    a candidate when `pending` or `ready`.
#                `running` means an agent already has it — re-emitting it would dispatch
#                the same ticket twice — and `failed` means it did not finish. NEITHER is
#                available, so successors of either stay out of the segment. That is the
#                honest answer: a segment is a list of things to RUN, and running work
#                whose predecessor never finished is how a half-built slice gets reviewed.
#                Both are reported in the text render rather than passed over in silence.
#   gate node    a candidate whenever it is not `done`/`skipped` — INCLUDING `failed`,
#                which is what a REJECTED gate is. A rejected gate is the thing most
#                obviously awaiting the guild master, and a `next_gate` that hid it would
#                report "nothing to run" with no explanation.
#
# ---------------------------------------------------------------------------------
# BATCHING, AND THE TWO INDEPENDENT MECHANISMS THAT KEEP ONE TESTER RUNNING AT A TIME
#
# Within one level, nodes are grouped into batches by (node key, parallel group) and the
# key's declared `parallel:` mode decides what a batch means:
#
#   never       EVERY NODE IS ITS OWN BATCH OF ONE. Not "grouped and marked sequential" —
#               one node, one batch. §6.2 calls this an INVARIANT, NOT A TUNING KNOB, and
#               the strict form is what makes it impossible for a downstream compiler to
#               read a multi-node batch as concurrent because it skimmed the flag.
#   by-group    nodes sharing a `parallel_group` batch together and run concurrently — the
#               architect asserted their file sets are disjoint (`guild plan slice --files`).
#               A group of one runs alone. Nodes with NO group under this mode are NOT
#               concurrent with anything: they collect into one sequential batch.
#   all         every instance of the key shares the group `graph new` wrote (the key
#               itself), so this is `by-group` with one group. No special case.
#
# THE MODE COMES FROM THE TEMPLATE; THE GROUPING COMES FROM THE DATA. That split is not
# arbitrary — it is what makes both halves mean something:
#
#   * `guild graph deviate --kind reshape --group G` writes `graph_node.parallel_group`
#     and nothing else. If the batcher took its grouping from the template, reshape would
#     be a no-op and an architect could not widen or narrow concurrency at all.
#   * `parallel: never` is a template fact with no representation in the data — a NULL
#     group is indistinguishable from "by-group, not yet grouped". If the batcher took the
#     mode from the data, `qa-execute` could be made concurrent by setting a group, and
#     §6.2's invariant would be exactly the tuning knob it says it is not.
#
# So the template is the CEILING (never means never, whatever the group says) and the data
# is the GROUPING (within a concurrent mode, the group is the truth).
#
# AND THEN, INDEPENDENTLY, THE SERIAL-AGENT RULE. `qa-tester` carries `serial: 1` in the
# roster: Playwright is heavy and each tester drives its own dev server, so two at once
# collide on ports and thrash the machine. §7 makes this a HARD COMPILER INVARIANT:
#
#   NEVER TWO SERIAL AGENTS IN ONE PARALLEL BATCH — AND FAIL LOUDLY, NEVER SILENTLY
#   SERIALIZE, because a template that requests illegal concurrency is a bug worth
#   surfacing at compile time rather than papering over at run time.
#
# `guild segment` therefore DIES, naming both nodes and the agent, rather than quietly
# splitting the batch. It never reaches the orchestrator, so no workflow is compiled from
# a shape the roster forbids.
#
# WHY BOTH MECHANISMS EXIST, AND WHY NEITHER IS REDUNDANT (§6.2: "two independent
# mechanisms, because a single missed check here produces confusing, intermittent failures
# rather than a clean error"):
#
#   * The template rule fires with NO ROSTER AT ALL. A `qa-execute` node is usually not yet
#     bound to a ticket, so there is no task, so there is no rank-1 agent, so its serial
#     flag reads 0. `parallel: never` covers exactly that blind spot.
#   * The roster rule fires on nodes the template said nothing about — an `add-node`
#     deviation, a project's own template, a key reshaped into a group. There is no
#     `parallel:` line to consult for those, and there is still an agent.
#
# Each covers the other's blind spot, which is the property that makes two checks worth
# more than one careful one.
#
# ---------------------------------------------------------------------------------
# GATES: WHAT `guild gate` REFUSES, AND WHY EACH REFUSAL EARNS ITS KEEP
#
#   the gate is not READY        refused. Approving `gate-repairs` before `review` ran
#                                would set the gate node `done`, and `repair` — whose only
#                                predecessor IS the gate — would become ready immediately.
#                                Repairs would run against findings nobody had produced.
#                                This is the one refusal that protects the GRAPH rather
#                                than the record.
#   already APPROVED             refused. An approval has already unblocked its successors
#                                and a segment may already have run against it; re-deciding
#                                would rewrite the reason for work that is finished. A
#                                REJECTED gate, by contrast, may be decided again — reject
#                                the plan, let the architect revise it, then approve. That
#                                loop is the whole point of the plan gate.
#   `select-findings` with       refused. `--decision` is what `repair` fans out over
#   no `--decision`              (`fanout: per-approved-finding`); approving without one is
#                                indistinguishable from forgetting, and the failure is
#                                silent — a repair node that fans out to nothing and a
#                                requirement that closes over live findings. `--decision
#                                none` is how you say "approve, repair nothing" out loud.
#
# Every one of those is evaluated INSIDE the single write script, as a marker plus a guard
# on every statement — so a refused decision writes no event, no row and no journal line,
# and the marker is what separates "refused" from "no such gate", which are otherwise both
# an empty result. That is `cmd_move`'s blocked->done pattern, applied to three conditions.
#
# THE STATEMENT ORDER IS LOAD-BEARING, AND IT IS CHOSEN SO THAT NO `UPDATE` READS ITS OWN
# TABLE. §3.0's compatibility matrix is an ALLOWLIST — "if the code depends on it, it has a
# row" — and a subquery over the table being updated has no row on it. The existing CLI has
# verified self-referencing subqueries in INSERT (lib/roster.sh's capability insert,
# lib/graph.sh's edge stitch) and none in UPDATE, so this file does not introduce the first
# one. The order that avoids it:
#
#   1. the markers, which only SELECT
#   2. the `event` INSERT, reading `gate` and `graph_node` while both are untouched
#   3. UPDATE `gate`     — its guard reads `gate`'s OWN COLUMNS directly (no subquery on
#                          gate) and reaches `graph_node`/`graph_edge` for readiness
#   4. UPDATE `graph_node` — conditioned on the gate having LANDED in step 3, which reads
#                          `gate`: a different table, and a witness rather than a repeat of
#                          the guard. It matches on `decided_at = <this run's timestamp>`,
#                          so step 4 cannot fire off a decision some earlier run made.
#
# So each statement's predicate reads only tables it does not write, every predicate is
# evaluated against state no earlier statement in the script disturbed, and a refusal at any
# of the four conditions stops all four. `_graph_fresh_guard` (lib/graph.sh) documents the
# same class of trap — a guard that its own script falsifies halfway through.
#
# WHY A REJECTION SETS THE NODE `failed` AND NOT `skipped`. `_graph_ready_where` counts
# `skipped` as finished — that is deliberate, so a node the architect waived does not hold
# its successors forever. A rejected gate must do the opposite: hold everything behind it
# until it is decided again. `failed` is the status that does that, and it is already in
# `graph_node`'s enum.

# ---- the alphabets -------------------------------------------------------------------

# _seg_check_node <id> — die unless <id> is a graph node id this file may CONCATENATE.
#
# A node id is `REQ-007/gate-repairs` — and, for a fanned node, `REQ-007/implement.auth`
# or `REQ-007/review.reviewer-security`. Every component is already drawn from a closed
# alphabet at the point the node was WRITTEN (`_graph_check_req` for the requirement,
# `_graph_check_key` for the key, `_rec_check_slug` for a plan-slice slug or an agent
# name), so this validates the same shape on the way back IN — which is what lets the value
# reach SQL through `sql_str` and appear inside an error message unescaped.
#
# The suffix is checked against `_rec_check_slug`'s alphabet (letters, digits, `.`, `_`,
# `-`) rather than the key alphabet, because that IS what a slug and an agent name are
# allowed to be. Prefix-checking alone would not do: this value is compared for equality
# against a primary key AND printed, so a blank or a quote in it is a forged column on one
# surface and a torn literal on the other.
_seg_check_node() {
  local v="${1-}" req key rest
  local LC_ALL=C

  [ -n "$v" ] ||
    die "guild: this command requires a gate's NODE ID — for example REQ-007/gate-plan.

List the ones awaiting a decision with 'guild gates --pending'."
  [ "${#v}" -le 220 ] ||
    die "guild: '${v}' is ${#v} characters; a node id is at most 220"

  case "$v" in
    */*) ;;
    *)
      die "guild: '$v' is not a node id.

A node id is the requirement and the node key joined by '/' — 'REQ-007/gate-plan',
'REQ-007/gate-repairs'. See them with 'guild gates --pending' or 'guild graph REQ-007'."
      ;;
  esac

  req="${v%%/*}"
  rest="${v#*/}"
  _graph_check_req "$req"

  # The key is everything before the first '.', the fanout suffix everything after. A
  # gate never fans out, so in practice `rest` IS the key — but this function guards every
  # node id the file handles, not only gate ids.
  key="${rest%%.*}"
  _graph_check_key "$key" 'a node id'
  case "$rest" in
    *.*)
      rest="${rest#*.}"
      [ -n "$rest" ] ||
        die "guild: '$v' is not a node id (it ends in '.')"
      case "$rest" in
        *[!A-Za-z0-9._-]*)
          die "guild: '$v' is not a node id.

The part after '.' is a plan-slice slug or an agent name, so it is limited to letters,
digits, '.', '_' and '-'."
          ;;
      esac
      ;;
  esac
}

# _seg_tmp <label> — a temp file, or die. Delegates; there is one of these in the CLI.
_seg_tmp() {
  _render_tmp "segment-${1:-work}"
}

# ---- shared SQL fragments ------------------------------------------------------------

# _seg_json_str <sql-expression> — the value as a COMPLETE JSON LITERAL, escaped by the
# engine: `"a \"quoted\" slug"`, or the bare word `null` when the value is NULL.
#
# THIS IS THE WHOLE OF THE JSON CHANNEL'S SAFETY (see the header). `json_object()` is the
# one escaper §3.0 verifies — it escapes quotes, backslashes and control characters, so a
# row is always exactly one line — but it produces an OBJECT, and the segment document
# needs bare strings inside arrays. So the object is built and then unwrapped:
#
#   json_object('v', x)  ->  {"v":"…"}
#   substr(j, 6, len-6)  ->        "…"        (drops the 5-byte `{"v":` and the `}`)
#
# The offsets are constants, not a search: `{"v":` is five bytes for every value, so no
# `instr()` and no assumption about the content. Only `json_object`, `substr` and `length`
# are used, all three on §3.0's verified list.
#
# The alternative — teaching awk to escape JSON — was rejected for the reason the header
# gives: awk would then be the thing standing between a plan-slice slug and a document an
# orchestrator EXECUTES, and there would be two escapers in the CLI where §2.2.2 says
# there is one per structural token.
_seg_json_str() {
  printf "substr(json_object('v', %s), 6, length(json_object('v', %s)) - 6)" "$1" "$1"
}

# _seg_agent_expr <node-alias> — the agent this node dispatches to: rank 1 for the ticket
# bound to it, NULL when no ticket is bound and '' when nothing on the roster is eligible.
#
# `_roster_top_agent` is CALLED, not restated. It carries the pin, §5.2's ranking and the
# no-capability fallback in one expression, and `guild match` / `guild bounties` are built
# on the same one — so all three name the same member for one ticket. Restating "the best
# agent" here is exactly the divergence lib/roster.sh's fragment section exists to prevent.
#
# A NULL agent is the ordinary case, not a fault: `graph_node.task_id` is bound only where
# the correspondence is unambiguous (lib/graph.sh), so `test-plan` and every gate carry no
# ticket until they are dispatched. The distinction that matters is NULL (no ticket yet)
# versus '' (a ticket nobody can take), and both surfaces keep it.
_seg_agent_expr() {
  local n="${1-n}"
  printf "(SELECT %s FROM task tsel WHERE tsel.id = %s.task_id)" \
    "$(_roster_top_agent tsel)" "$n"
}

# _seg_serial_expr <agent-expression> — 1 when that agent may never share a parallel batch.
#
# Reads `agent.serial`, which `guild sync-agents` writes from the agent file's frontmatter.
# COALESCE to 0: an unknown agent, an unbound node and a guild that has never synced all
# mean "nothing is known about concurrency here", and the template's `parallel:` mode is
# what covers that case (see the header's two-mechanisms note).
_seg_serial_expr() {
  printf "COALESCE((SELECT asel.serial FROM agent asel WHERE asel.name = %s), 0)" "${1-}"
}

# ---- the template's contribution: one fact per node key --------------------------------

# _seg_modes <template-name> <out-file> — write `M <key> <mode> <ordinal>` for every node
# the template declares. Returns non-zero, having written nothing, when the template cannot
# be read.
#
# TWO FACTS ARE TAKEN FROM THE TEMPLATE AND NO OTHERS: a key's `parallel:` mode, and its
# DECLARATION ORDINAL. Everything else about the graph — which nodes exist, what depends on
# what, which group each node is in — is in the database, where deviations have already
# been applied. Taking anything more from the file would make `guild segment` describe the
# template rather than the graph.
#
# The ordinal is not decoration: it is the batch ORDER for nodes that become available in
# the same level. Sorting by key name would put `review` before `test-plan` on a run where
# both opened at once, which reads as a bug in the graph rather than as alphabetical order.
#
# NON-FATAL BY CONSTRUCTION. `template_load` dies on a missing or malformed file — correct
# for `guild graph new`, wrong here, because a graph OUTLIVES the file that shaped it and a
# renamed YAML must not make a half-run requirement unrunnable. So it is called in a
# SUBSHELL (`_roster_name_ok`'s pattern) and the caller degrades to the conservative
# default: an unknown mode is `never`, which means one node per batch, which is always
# safe and never wrong about concurrency — it only ever costs wall-clock time, and it says
# so on stderr rather than pretending.
#
# The reduction is ONE awk pass over the flat form rather than a bash loop with
# `${line%% *}` per line: a template prompt is a long line, and parameter expansion over
# unbounded values is what rule 5 is about.
_seg_modes() {
  local tpl="${1-}" out="${2-}" flat rc=0
  : >"$out"
  [ -n "$tpl" ] || return 1

  flat="$(_seg_tmp modes-flat)"
  ( template_load "$tpl" ) >"$flat" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$flat"
    return 1
  fi

  LC_ALL=C awk '
    {
      p = index($0, " ")
      t = (p > 0 ? substr($0, 1, p - 1) : $0)
      v = (p > 0 ? substr($0, p + 1) : "")
    }
    t == "node" {
      if (k != "") printf("M %s %s %d\n", k, (pl == "" ? "never" : pl), o)
      o++
      k = v
      pl = ""
      next
    }
    t == "parallel" { pl = v; next }
    END { if (k != "") printf("M %s %s %d\n", k, (pl == "" ? "never" : pl), o) }
  ' "$flat" >"$out"
  rm -f "$flat"
  return 0
}

# ============================ guild segment ===========================================

# _seg_sql <mode> <req-literal> <state-key-literal> — the WHOLE read, as one script.
#
# <mode> selects the PROJECTION of the two free-text values only — `_render_flat` for the
# human surface, `_seg_json_str` for the machine one — exactly as `_brief_sql` does, and
# for its reason: the rows a document is assembled from should already be in the shape that
# document needs, so awk assembles and never escapes.
#
# Everything else is emitted in BOTH shapes on every run: the columnar fields the batching
# reads, and the JSON literals the document prints. That costs one extra `json_object` per
# node and buys one SQL shape and one awk program instead of two of each — and the level
# sweep, which is the part worth getting right once, is then provably the same code on both
# surfaces.
_seg_sql() {
  local mode="$1" reqlit="$2" statekey="$3"
  local ag ser

  ag="$(_seg_agent_expr n)"
  ser="$(_seg_serial_expr "$ag")"

  # The requirement. Its own existence marker: "no such requirement" and "no graph yet" are
  # different problems with different fixes, and one empty result cannot say which.
  printf "SELECT 'Q|' || %s || '|' || %s || '|' || %s FROM requirement WHERE id = %s;\n" \
    "$(_graph_field 'status')" "$(_seg_json_str 'id')" "$(_render_flat 'title')" "$reqlit"

  # Which template built this graph — the baseline `_seg_modes` needs, and the one value
  # `guild graph new` recorded in `guild_state` precisely so it could be found again.
  printf "SELECT 'T|' || %s || '|' || %s FROM guild_state WHERE key = %s;\n" \
    "$(_graph_field 'value')" "$(_seg_json_str 'value')" "$statekey"

  # Every node. ORDER BY is stable and total (key, then id) so a segment computed twice
  # from an unchanged board is byte-identical — which is what makes `--json` diffable and
  # what lets a crashed workflow be re-compiled and compared against what it ran.
  printf "SELECT 'N|' || %s || '|' || %s || '|' || %s || '|' || %s || '|' || %s || '|' || %s
             || '|' || %s || '|' || %s || '|' || %s || '|' || %s || '|' || %s
  FROM graph_node n WHERE n.requirement_id = %s ORDER BY n.node_key, n.id;\n" \
    "$(_graph_field 'n.id')" "$(_graph_field 'n.node_key')" "$(_graph_field 'n.kind')" \
    "$(_graph_field 'n.status')" "$(_graph_field "COALESCE(n.parallel_group, '-')")" \
    "$ser" \
    "$(_graph_field "COALESCE(NULLIF($ag, ''), '-')")" \
    "$(_graph_field "COALESCE(n.task_id, '-')")" \
    "$(_seg_json_str "NULLIF($ag, '')")" "$(_seg_json_str 'n.task_id')" \
    "$(_seg_json_str 'n.id')" \
    "$reqlit"

  # Every edge INTO this requirement's nodes. The join is the filter: an edge whose
  # successor belongs to another requirement is not this graph's edge, and the whole point
  # of shipping the edge list to awk is that awk must be able to trust it is complete.
  printf "SELECT 'P|' || %s || '|' || %s
  FROM graph_edge e JOIN graph_node t ON t.id = e.to_node
 WHERE t.requirement_id = %s ORDER BY e.to_node, e.from_node;\n" \
    "$(_graph_field 'e.from_node')" "$(_graph_field 'e.to_node')" "$reqlit"

  printf "SELECT 'G|' || %s || '|' || %s || '|' || %s || '|' || %s || '|' || %s || '|' || %s
  FROM gate g JOIN graph_node n ON n.id = g.node_id
 WHERE n.requirement_id = %s ORDER BY n.id;\n" \
    "$(_graph_field 'n.id')" "$(_graph_field 'g.status')" "$(_graph_field 'g.kind')" \
    "$(_seg_json_str 'n.id')" "$(_seg_json_str 'g.status')" "$(_seg_json_str 'g.kind')" \
    "$reqlit"

  # The two free-text values, each ALONE on its own line and LAST on it (see THE MARKER
  # CHANNEL). A prompt is a sentence somebody wrote and a decision is a list of findings;
  # neither can be a field of a line that has fields after it.
  if [ "$mode" = json ]; then
    printf "SELECT 'GP|' || %s || '|' || %s
  FROM gate g JOIN graph_node n ON n.id = g.node_id
 WHERE n.requirement_id = %s ORDER BY n.id;
SELECT 'GD|' || %s || '|' || %s
  FROM gate g JOIN graph_node n ON n.id = g.node_id
 WHERE n.requirement_id = %s AND g.decision IS NOT NULL ORDER BY n.id;\n" \
      "$(_graph_field 'n.id')" "$(_seg_json_str 'g.prompt')" "$reqlit" \
      "$(_graph_field 'n.id')" "$(_seg_json_str 'g.decision')" "$reqlit"
  else
    printf "SELECT 'GP|' || %s || '|' || %s
  FROM gate g JOIN graph_node n ON n.id = g.node_id
 WHERE n.requirement_id = %s ORDER BY n.id;
SELECT 'GD|' || %s || '|' || %s
  FROM gate g JOIN graph_node n ON n.id = g.node_id
 WHERE n.requirement_id = %s AND g.decision IS NOT NULL ORDER BY n.id;\n" \
      "$(_graph_field 'n.id')" "$(_brief_txt 'g.prompt' 400)" "$reqlit" \
      "$(_graph_field 'n.id')" "$(_brief_txt 'g.decision' 400)" "$reqlit"
  fi
}

# _seg_awk — THE LEVEL SWEEP, the batcher, and both renderers.
#
# One program, `-v MODE=text|json`, because the sweep is the part worth getting right once
# and two copies of it would be two answers to "what runs next". The renderers diverge only
# in the END block's last thirty lines.
#
# It reads TWO inputs, told apart by their first bytes and never by argument position: the
# `M <key> <mode> <ord>` lines this file derives from the template, and the `X|` marker
# lines the driver returned. Both alphabets are closed, so no line of one can be mistaken
# for a line of the other.
#
# `tailafter(s, k)` walks past exactly k delimiters and returns the rest VERBATIM — how a
# prompt containing a pipe survives. The leading fields come from `split`, which over-splits
# that tail into fields nobody reads: harmless, and it keeps the common case one pass.
#
# Failure is `!SERIAL|<node>|<agent>|<node>|<agent>` and exit 3, so the shell composes the
# message with the two node ids in it rather than awk printing a sentence.
_seg_awk() {
  cat <<'SEGAWK'
function tailafter(s, k,   i, p) {
  for (i = 1; i <= k; i++) { p = index(s, "|"); if (p == 0) return ""; s = substr(s, p + 1) }
  return s
}

# sortkey(i) — the total order batches are cut in: template declaration order, then key
# name (for nodes the template never declared), then group, then id. Every component is
# blank- and pipe-free, so a plain string compare is the whole comparator.
#
# An UNDECLARED key sorts after every declared one (999999) rather than interleaving: an
# added node is a deviation, and reading the segment top to bottom should show the template's
# spine first and the additions where they attach.
#
# A node with NO group sorts after the grouped ones within its key ("1" > "0"), which is
# what puts `implement.migrations` under the concurrent slices instead of between them.
function sortkey(i,   o, g) {
  o = (nkey[i] in ord) ? ord[nkey[i]] : 999999
  g = (ngrp[i] == "-" ? "1" : "0" ngrp[i])
  return sprintf("%06d|%s|%s|%s", o, nkey[i], g, nid[i])
}

# batch(lo, hi, par) — cut wk[lo..hi] into one batch.
#
# THE SERIAL INVARIANT IS ENFORCED HERE AND NOWHERE ELSE, at the one moment a batch is
# declared concurrent — so there is no path that creates a parallel batch without passing
# through this check. It DIES rather than splitting the batch: §7 requires failing loudly
# over silently serializing, because a template asking for illegal concurrency is a bug
# that must surface at compile time, not an inconvenience to route around at run time.
function batch(lo, hi, par,   j, s, sa, sb) {
  if (par) {
    s = 0
    for (j = lo; j <= hi; j++) {
      if (!nser[wk[j]]) continue
      s++
      if (s == 1) sa = wk[j]
      else if (s == 2) sb = wk[j]
    }
    if (s >= 2) {
      printf("!SERIAL|%s|%s|%s|%s\n", nid[sa], nag[sa], nid[sb], nag[sb])
      exit 3
    }
  }
  nb++
  bpar[nb] = par
  bn[nb] = 0
  for (j = lo; j <= hi; j++) { bn[nb]++; bm[nb, bn[nb]] = wk[j] }
}

BEGIN { nn = 0; ne = 0; nb = 0; gate1 = 0 }

# ---- the template's two facts ----------------------------------------------------
/^M / {
  if (split($0, f, " ") < 4) next
  mode[f[2]] = f[3]
  ord[f[2]] = f[4] + 0
  next
}

# ---- the driver's rows -----------------------------------------------------------
substr($0, 1, 2) == "Q|" {
  split($0, p, "|")
  rstat = p[2]; rjson = p[3]; rtitle = tailafter($0, 3)
  next
}
substr($0, 1, 2) == "T|" { split($0, p, "|"); tpl = p[2]; tjson = p[3]; next }
substr($0, 1, 2) == "N|" {
  nn++
  split($0, p, "|")
  nid[nn] = p[2]; nkey[nn] = p[3]; nkind[nn] = p[4]; nstat[nn] = p[5]
  ngrp[nn] = p[6]; nser[nn] = p[7] + 0; nag[nn] = p[8]; ntask[nn] = p[9]
  jag[nn] = p[10]; jtask[nn] = p[11]; jid[nn] = p[12]
  next
}
substr($0, 1, 2) == "P|" { ne++; split($0, p, "|"); ef[ne] = p[2]; et[ne] = p[3]; next }
substr($0, 1, 3) == "GP|" { split($0, p, "|"); gprompt[p[2]] = tailafter($0, 2); next }
substr($0, 1, 3) == "GD|" { split($0, p, "|"); gdec[p[2]] = tailafter($0, 2); next }
substr($0, 1, 2) == "G|" {
  split($0, p, "|")
  gstat[p[2]] = p[3]; gkind[p[2]] = p[4]
  gjid[p[2]] = p[5]; gjstat[p[2]] = p[6]; gjkind[p[2]] = p[7]
  next
}

END {
  # ---- the starting state -------------------------------------------------------
  #
  # `done` and `skipped` are finished — the same pair `_graph_ready_where` counts, and it
  # has to be the same pair or the SQL and the sweep would disagree about the first level.
  for (i = 1; i <= nn; i++) {
    fin = (nstat[i] == "done" || nstat[i] == "skipped")
    avail[nid[i]] = fin
    if (nkind[i] == "gate") cand[i] = (fin ? 0 : 1)
    else cand[i] = (nstat[i] == "pending" || nstat[i] == "ready")
    if (nkind[i] != "gate" && nstat[i] == "running") nrun++
    if (nkind[i] != "gate" && nstat[i] == "failed")  nfail++
  }

  # ---- the sweep ----------------------------------------------------------------
  for (pass = 0; pass < 500; pass++) {
    m = 0
    split("", newly)
    for (i = 1; i <= nn; i++) {
      if (!cand[i] || sched[i]) continue
      ok = 1
      for (k = 1; k <= ne; k++) {
        if (et[k] != nid[i]) continue
        if (!avail[ef[k]]) { ok = 0; break }
      }
      if (ok) newly[++m] = i
    }
    if (m == 0) break

    # Gates are RECORDED and never satisfied — the segment boundary (see the header).
    # The earliest one wins, and within a level the one the template declares first, so
    # `next_gate` is deterministic on a graph with a parallel branch.
    work = 0
    split("", wk)
    for (j = 1; j <= m; j++) {
      i = newly[j]
      if (nkind[i] == "gate") {
        sched[i] = 1
        if (gate1 == 0 || sortkey(i) < sortkey(gate1)) gate1 = i
        continue
      }
      wk[++work] = i
    }
    if (work == 0) continue

    # Insertion sort: a level is a handful of nodes, and the order is the batch order.
    for (a = 2; a <= work; a++) {
      v = wk[a]
      kv = sortkey(v)
      b = a - 1
      while (b >= 1 && sortkey(wk[b]) > kv) { wk[b + 1] = wk[b]; b-- }
      wk[b + 1] = v
    }

    a = 1
    while (a <= work) {
      i = wk[a]
      md = (nkey[i] in mode) ? mode[nkey[i]] : "never"
      if (md != "by-group" && md != "all") {
        # `never`, and every unknown mode: ONE NODE, ONE BATCH. §6.2's invariant, in the
        # strict form — not "batched and marked sequential", which a compiler can skim.
        batch(a, a, 0)
        a++
        continue
      }
      # A concurrent mode: the sort has already put same-key, same-group nodes adjacent,
      # so the batch is the run.
      b = a
      while (b + 1 <= work && nkey[wk[b + 1]] == nkey[i] && ngrp[wk[b + 1]] == ngrp[i]) b++
      if (ngrp[i] == "-") batch(a, b, 0)
      else batch(a, b, (b > a) ? 1 : 0)
      a = b + 1
    }

    for (j = 1; j <= work; j++) { sched[wk[j]] = 1; avail[nid[wk[j]]] = 1 }
  }

  if (MODE == "json") { emit_json(); exit 0 }
  emit_text()
}

# ---- the machine surface (§6.4, §7) ------------------------------------------------
#
# Not one value below is written by this program: every string is a complete JSON literal
# the engine produced (`_seg_json_str`). awk contributes brackets, commas, the fixed key
# names and `true`/`false`, and nothing else. See THE JSON CHANNEL.
function emit_json(   i, j, x, first) {
  print "{"
  printf("  \"requirement\": %s,\n", (rjson == "" ? "null" : rjson))
  printf("  \"template\": %s,\n", (tjson == "" ? "null" : tjson))
  if (nb == 0) {
    print "  \"batches\": [],"
  } else {
    print "  \"batches\": ["
    for (i = 1; i <= nb; i++) {
      printf("    { \"parallel\": %s,\n", (bpar[i] ? "true" : "false"))
      printf("      \"nodes\": [")
      for (j = 1; j <= bn[i]; j++) printf("%s%s", (j > 1 ? ", " : ""), jid[bm[i, j]])
      print "],"
      printf("      \"agents\": [")
      for (j = 1; j <= bn[i]; j++) printf("%s%s", (j > 1 ? ", " : ""), jag[bm[i, j]])
      print "],"
      printf("      \"tasks\": [")
      for (j = 1; j <= bn[i]; j++) printf("%s%s", (j > 1 ? ", " : ""), jtask[bm[i, j]])
      printf("] }%s\n", (i < nb ? "," : ""))
    }
    print "  ],"
  }
  if (gate1 == 0) {
    print "  \"next_gate\": null"
  } else {
    x = nid[gate1]
    print "  \"next_gate\": {"
    printf("    \"node\": %s,\n", gjid[x])
    printf("    \"kind\": %s,\n", (gjkind[x] == "" ? "null" : gjkind[x]))
    printf("    \"status\": %s,\n", (gjstat[x] == "" ? "null" : gjstat[x]))
    printf("    \"decision\": %s,\n", (x in gdec ? gdec[x] : "null"))
    printf("    \"prompt\": %s\n", (x in gprompt ? gprompt[x] : "null"))
    print "  }"
  }
  print "}"
}

# ---- the human surface --------------------------------------------------------------
#
# Columnar within a batch, and the one free-text value — the gate prompt — is printed on
# a line of its own, indented, where it cannot be read as a column.
function emit_text(   i, j, x, head, bar, n, lbl) {
  head = "Segment " REQ
  print head
  bar = ""
  for (i = 0; i < length(head); i++) bar = bar "="
  print bar
  print ""
  printf("requirement: %s [%s]\n", (rtitle == "" ? "(not found)" : rtitle), rstat)
  printf("template:    %s\n", (tpl == "" ? "(not recorded)" : tpl))
  printf("nodes:       %d\n", nn)
  print ""

  if (nb == 0) {
    if (gate1 > 0)
      print "No batches — the next thing that happens is a decision, below."
    else if (nrun > 0 || nfail > 0)
      print "No batches — every remaining node is behind work that is still running or that failed."
    else
      print "No batches — this graph has nothing left to run."
  }
  for (i = 1; i <= nb; i++) {
    lbl = (bpar[i] ? "parallel" : "sequential")
    printf("Batch %d — %s, %d node(s)\n", i, lbl, bn[i])
    for (j = 1; j <= bn[i]; j++) {
      x = bm[i, j]
      printf("  %-42s %-18s %-10s%s\n", nid[x], nag[x], ntask[x],
             (nser[x] ? "  [serial]" : ""))
    }
  }

  if (nrun > 0 || nfail > 0) {
    print ""
    print "Holding the graph:"
    for (i = 1; i <= nn; i++) {
      if (nkind[i] == "gate") continue
      if (nstat[i] != "running" && nstat[i] != "failed") continue
      printf("  [%-7s] %-42s %s\n", nstat[i], nid[i], nag[i])
    }
    if (nrun > 0)
      print "  a 'running' node is out with an agent; its successors stay out of the segment"
    if (nfail > 0)
      print "  a 'failed' node needs adjudicating before anything behind it can run"
  }

  n = 0
  for (i = 1; i <= nb; i++)
    for (j = 1; j <= bn[i]; j++)
      if (nag[bm[i, j]] == "-") n++
  if (n > 0) {
    print ""
    printf("%d node(s) in this segment have no agent yet ('-' above).\n", n)
    print "  a node with no ticket is bound when it is dispatched; a ticket with no eligible"
    print "  member is a roster gap — 'guild bounties' names it, 'guild match' explains it"
  }

  print ""
  if (gate1 == 0) {
    print "Next gate: (none — nothing after this segment waits on a decision)"
    exit 0
  }
  x = nid[gate1]
  printf("Next gate: %s (%s, %s)\n", x, gkind[x], gstat[x])
  if (x in gprompt) printf("  %s\n", gprompt[x])
  if (x in gdec)    printf("  last decision: %s\n", gdec[x])
  print ""
  if (gkind[x] == "select-findings")
    printf("  guild gate %s --approve --decision 'F-12,F-14'   (or --decision none)\n", x)
  else
    printf("  guild gate %s --approve\n", x)
  printf("  guild gate %s --reject --decision 'why'\n", x)
}
SEGAWK
}

# cmd_segment <REQ-NNN> [--json] — print the next gate-free run of node batches.
#
# ONE db_exec, then one file read, then one awk pass. It MUTATES NOTHING: a segment is a
# question, and the orchestrator that runs it owns every status transition (§2.4).
#
# Exit status is 0 for an empty segment as well as a full one. "Nothing to run" is an
# answer — the graph is finished, or it is waiting at a gate, or something is still out
# with an agent — and each of those is printed with its reason rather than signalled by a
# status a caller would have to guess the meaning of. The one non-zero exit is the serial
# invariant, which is a refusal.
cmd_segment() {
  local req="" mode="text" reqlit statekey sqlf rows modes outf tpl rc=0
  local a b c d

  while [ $# -gt 0 ]; do
    case "$1" in
      --json) mode="json" ;;
      -*) die "guild: unknown option '$1' for segment (try 'guild segment REQ-NNN [--json]')" ;;
      *)
        [ -z "$req" ] ||
          die "guild: segment takes one requirement id (got '$req' and '$(_render_flat_arg "$1")')"
        req="$1"
        ;;
    esac
    shift
  done

  _graph_check_req "$req"
  db_require_init

  reqlit="$(sql_str "$req")"
  statekey="$(sql_str "$(_graph_state_key "$req")")"
  sqlf="$(_seg_tmp sql)"
  rows="$(_seg_tmp rows)"
  _seg_sql "$mode" "$reqlit" "$statekey" >"$sqlf"
  _render_query "$sqlf" "$rows" "guild: could not read the segment for $req"

  if ! LC_ALL=C grep -q '^Q|' "$rows"; then
    rm -f "$rows"
    die "guild: $req not found"
  fi
  if ! LC_ALL=C grep -q '^N|' "$rows"; then
    rm -f "$rows"
    die "guild: $req has no execution graph.

A segment is a run of the graph's nodes, so there has to be a graph first:

  guild graph new $req --template standard      build a requirement
  guild graph new $req --template maintenance   inspect what was built"
  fi

  # The baseline. A graph with no template record, or one whose template file has since
  # been renamed, still runs — one node per batch, and it says so. See `_seg_modes`.
  tpl="$(LC_ALL=C awk -F'|' '$1 == "T" { print $2; exit }' "$rows")"
  modes="$(_seg_tmp modes)"
  if ! _seg_modes "$tpl" "$modes"; then
    if [ -n "$tpl" ]; then
      printf "guild: WARNING — the '%s' template could not be read; every node is batched alone.\n" "$tpl" >&2
      printf "       The graph itself is unaffected. Concurrency is the only thing lost.\n" >&2
    else
      printf "guild: WARNING — %s has no template record; every node is batched alone.\n" "$req" >&2
    fi
  fi

  outf="$(_seg_tmp out)"
  LC_ALL=C awk -v MODE="$mode" -v REQ="$req" "$(_seg_awk)" "$modes" "$rows" >"$outf" || rc=$?
  rm -f "$modes" "$rows"

  if [ "$rc" != 0 ]; then
    # `read` with a FIXED variable list: the last variable takes the remainder, so no
    # `${v#*|}` is ever applied to an unbounded value (rule 5).
    IFS='|' read -r _ a b c d <"$outf" || true
    rm -f "$outf"
    [ -n "$a" ] ||
      die "guild: could not compute the segment for $req"
    die "guild: refusing to emit a parallel batch containing two serial agents.

  $a ($b)
  $c ($d)

An agent marked 'serial: true' in the roster may never run beside another serial agent:
qa-tester drives its own dev server, so two at once collide on ports and thrash the
machine, and the failures that produces are intermittent rather than clean (design 6.2).

Nothing was serialized silently, because a template that asks for illegal concurrency is a
bug worth surfacing here rather than papering over at run time (design 7). Fix the shape:

  guild graph deviate $req --kind reshape --node <key> --group '' --reason '...'
      put those nodes in separate groups, or none at all

or, if the template itself is wrong, give the node 'parallel: never' — which is what the
shipped 'maintenance' template does for qa-execute, and why that node never reaches here."
  fi

  cat "$outf"
  rm -f "$outf"
}

# ============================ guild gate ==============================================

# _seg_gate_open <column-prefix> <decision-clause> — "this gate may still be decided",
# over the `gate` row's own columns.
#
# ALIAS-PARAMETERIZED RATHER THAN WRITTEN TWICE, which is `_roster_super_where`'s shape and
# its reason: two statements need this predicate against two different bindings — an `UPDATE
# gate`, where the columns are bare, and an `EXISTS` over `gate gg`, where they are
# qualified — and two spellings of "may this gate be decided" is two answers to the only
# question this command asks.
#
# `<decision-clause>` is empty except on an approval with no `--decision`, where it adds the
# `select-findings` refusal. It is composed by the caller because only the caller knows
# whether `--decision` was passed; the SQL cannot see an absent flag.
_seg_gate_open() {
  local p="${1-}" decclause="${2-}"
  printf "%sstatus <> 'approved'%s" "$p" "$decclause"
}

# _seg_gate_ready <node-literal> — "every direct predecessor of this gate is finished".
#
# `_graph_ready_where` is CALLED, so this is the same readiness the render, the segment
# sweep and the dispatcher use — one hop, no recursion (§3.0). Wrapped in an EXISTS over
# `graph_node nn` so it can be attached to a statement that has no `graph_node` in scope,
# which is what lets the `UPDATE gate` carry it WITHOUT a subquery over `gate` itself.
_seg_gate_ready() {
  printf "EXISTS (SELECT 1 FROM graph_node nn WHERE nn.id = %s AND %s)" \
    "${1-}" "$(_graph_ready_where nn)"
}

# cmd_gate <NODE-ID> --approve|--reject [--decision X] — record the guild master's
# decision. Prints "<NODE-ID> <approved|rejected>".
#
# ONE db_exec: the four refusal markers, the event, both row updates and both journal
# markers are one script. A refused decision matches no row anywhere — no event, no update,
# no journal line, nothing to undo — and the markers are what tell the four refusals apart
# from "no such gate", which are otherwise all an empty result.
#
# APPROVAL IS WHAT UNBLOCKS THE SUCCESSORS, and it does it by setting the gate NODE to
# `done` — not by any special case in the readiness predicate. That is the whole reason
# readiness can stay a plain one-hop join (§3.0's `WITH RECURSIVE` trap): a gate is an
# ordinary node whose status a human writes instead of an agent.
cmd_gate() {
  local node="" action="" decision="" have_dec=0
  local nodelit declit decguard decguard_g ready guard now nowlit actorlit
  local nstatus gstatus verb sql markers out line

  while [ $# -gt 0 ]; do
    case "$1" in
      --approve)
        [ -z "$action" ] || die "guild: --approve and --reject are exclusive — pass one"
        action="approve"
        ;;
      --reject)
        [ -z "$action" ] || die "guild: --approve and --reject are exclusive — pass one"
        action="reject"
        ;;
      --decision)
        shift
        decision="${1-}"
        have_dec=1
        [ $# -eq 0 ] || shift
        continue
        ;;
      --decision=*)
        decision="${1#--decision=}"
        have_dec=1
        ;;
      -*) die "guild: unknown option '$1' for gate (try 'guild gate <NODE-ID> --approve|--reject')" ;;
      *)
        [ -z "$node" ] ||
          die "guild: gate takes one node id (got '$node' and '$(_render_flat_arg "$1")')"
        node="$1"
        ;;
    esac
    shift
  done

  _seg_check_node "$node"
  [ -n "$action" ] || die "guild: gate requires --approve or --reject.

  guild gate $node --approve
  guild gate $node --approve --decision 'F-12,F-14'   (a select-findings gate)
  guild gate $node --reject  --decision 'the plan splits the migration wrong'

A gate is the guild master's control surface — the one decision a subagent physically
cannot make, because only the orchestrator session can ask you anything (design 6.4)."

  # An empty --decision is not a decision. `--decision ''` and no flag at all mean the same
  # thing, and treating them differently would let a `select-findings` gate be approved
  # with an empty selection by anyone who quoted a shell variable that happened to be unset.
  [ -n "$decision" ] || have_dec=0

  db_require_init
  journal_preflight

  if [ "$action" = approve ]; then
    verb="approved"
    gstatus="approved"
    nstatus="done"
  else
    verb="rejected"
    gstatus="rejected"
    nstatus="failed"
  fi

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  # The node id passed `_seg_check_node`'s closed alphabet, so sql_str. The decision is a
  # paragraph somebody typed — a list of findings, a reason — so it is hex (§2.2.1).
  nodelit="$(sql_str "$node")"
  if [ "$have_dec" = 1 ]; then
    declit="$(sql_text "$decision" '--decision')"
  else
    declit="NULL"
  fi

  # The `select-findings` rule applies to APPROVAL ONLY: a rejection needs no selection,
  # because nothing is being approved for repair. The clause is composed in two bindings —
  # bare for the `UPDATE gate`, qualified for the `EXISTS` over `gate gg` — from the one
  # fragment, so there is still only one statement of the rule.
  decguard=""
  decguard_g=""
  if [ "$action" = approve ] && [ "$have_dec" = 0 ]; then
    decguard=" AND kind <> 'select-findings'"
    decguard_g=" AND gg.kind <> 'select-findings'"
  fi
  ready="$(_seg_gate_ready "$nodelit")"
  # For statements that write a table OTHER than `gate`: the same predicate, reached
  # through an EXISTS so it can hang off any FROM clause.
  guard="EXISTS (SELECT 1 FROM gate gg WHERE gg.node_id = $nodelit
                  AND $(_seg_gate_open 'gg.' "$decguard_g")) AND $ready"

  sql="BEGIN;
SELECT 'MISS|1' WHERE NOT EXISTS (SELECT 1 FROM gate WHERE node_id = $nodelit);
SELECT 'WAS|' || g.status || '|' || g.kind FROM gate g WHERE g.node_id = $nodelit;
SELECT 'NOTREADY|1' FROM graph_node n WHERE n.id = $nodelit AND NOT ($(_graph_ready_where n));
"
  if [ "$action" = approve ] && [ "$have_dec" = 0 ]; then
    sql="${sql}SELECT 'NEEDDEC|1' FROM gate g WHERE g.node_id = $nodelit AND g.kind = 'select-findings';
"
  fi

  # THE ORDER IS LOAD-BEARING (see the header): event, then the GATE, then the NODE — the
  # order in which no UPDATE's predicate reads the table that UPDATE writes. The node's
  # update hangs off the gate having LANDED, matched on this run's timestamp, rather than
  # off a second evaluation of the guard the gate update has by then falsified.
  sql="$sql
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $actorlit, $(sql_str "$verb"), 'gate', g.node_id,
       json_object('requirement', n.requirement_id, 'kind', g.kind, 'decision', $declit)
FROM gate g JOIN graph_node n ON n.id = g.node_id
WHERE g.node_id = $nodelit AND $guard;
UPDATE gate SET status = $(sql_str "$gstatus"), decision = $declit, decided_at = $nowlit
 WHERE node_id = $nodelit AND $(_seg_gate_open '' "$decguard") AND $ready
RETURNING 'R|gate|upsert|' || $(_art_json_row gate);
UPDATE graph_node SET status = $(sql_str "$nstatus")
 WHERE id = $nodelit
   AND EXISTS (SELECT 1 FROM gate gw WHERE gw.node_id = $nodelit
                AND gw.status = $(sql_str "$gstatus") AND gw.decided_at = $nowlit)
RETURNING 'R|graph_node|upsert|' || $(_art_json_row graph_node);
SELECT 'NOW|' || g.status FROM gate g WHERE g.node_id = $nodelit;
COMMIT;
"

  markers="$(_seg_tmp gate)"
  if ! printf '%s' "$sql" | db_exec >"$markers"; then
    out="$(cat "$markers" 2>/dev/null || true)"
    rm -f "$markers"
    db_fail "could not record the decision on $node" "$out"
  fi

  if LC_ALL=C grep -q '^MISS|' "$markers"; then
    rm -f "$markers"
    die "guild: there is no gate at '$node'.

  guild gates --pending      the gates awaiting a decision, board-wide
  guild graph ${node%%/*}    this requirement's graph, gates included"
  fi

  if LC_ALL=C grep -q '^NEEDDEC|' "$markers"; then
    rm -f "$markers"
    die "guild: '$node' is a select-findings gate and --decision is required — nothing was written.

The decision IS the fan-out: 'repair' creates one task per approved finding, so approving
without a selection produces a repair node that fans out to nothing and a requirement that
closes over live findings — silently (design 6.1, 6.4).

  guild gate $node --approve --decision 'F-12,F-14'
  guild gate $node --approve --decision none      approve, and repair nothing

Read what you are deciding on first:

  guild brief --json     review_findings, and the open bugs beside them"
  fi

  if LC_ALL=C grep -q '^NOTREADY|' "$markers"; then
    rm -f "$markers"
    die "guild: '$node' is not ready — nothing was written.

A gate is ready when every one of its direct predecessors is done or skipped. Deciding one
early sets the gate node 'done', and everything behind it becomes runnable immediately —
so approving 'gate-repairs' before review has run would dispatch repairs for findings
nobody has filed yet.

  guild segment ${node%%/*}    what still has to run before this gate opens
  guild graph ${node%%/*}      the nodes and their statuses"
  fi

  line="$(LC_ALL=C awk -F'|' '$1 == "WAS" { print $2; exit }' "$markers")"
  if [ "$line" = approved ]; then
    rm -f "$markers"
    die "guild: '$node' is already approved — nothing was written.

An approval has already unblocked the nodes behind it, and a segment may already have run
against it; re-deciding would rewrite the reason for work that is finished.

A REJECTED gate can be decided again — reject the plan, let the architect revise it, then
approve — which is the loop the plan gate exists for. An approved one cannot."
  fi

  if ! LC_ALL=C grep -q '^R|gate|' "$markers"; then
    out="$(cat "$markers" 2>/dev/null || true)"
    rm -f "$markers"
    db_fail "could not record the decision on $node" "$out"
  fi

  _graph_journal_markers "$markers" >/dev/null
  line="$(LC_ALL=C awk -F'|' '$1 == "NOW" { print $2; exit }' "$markers")"
  rm -f "$markers"

  printf '%s %s\n' "$node" "${line:-$gstatus}"
}

# ============================ guild node ==============================================

# _seg_node_statuses — the `graph_node.status` vocabulary, as a blank-separated list.
#
# It lives in ONE place for the reason `art_statuses` (lib/artifacts.sh) does: the column
# carries no CHECK constraint — deliberately, so the vocabulary can widen without rewriting
# the table on every live guild — which means this list IS the enforcement. A second copy
# is a status one command accepts and another rejects.
#
# `ready` is in the vocabulary and the orchestrator never needs it: `_seg_awk` treats
# `pending` and `ready` identically as candidates, so the working loop is
# pending -> running -> done. It stays legal because a future dispatcher may want to mark
# what it is ABOUT to run, and because the schema comment already names it.
_seg_node_statuses() {
  printf 'pending ready running done failed skipped\n'
}

# cmd_node <NODE-ID> <status> [--task TASK-NNN] — move a WORK node. Prints
# "<NODE-ID> <status>".
#
# ONE db_exec: the four refusal markers, the event, the update and the journal marker are one
# script, and every statement hangs off the same guard — so a refused move writes no event,
# no row and no journal line, and the markers are what tell the refusals apart from "no such
# node", which are otherwise all an empty result. `cmd_move`'s protocol, on the graph.
#
# A GATE IS REFUSED, AND THAT IS THE POINT OF THE COMMAND HAVING A GUARD AT ALL.
# `guild gate --approve` sets a gate node `done`, and `done` is what unblocks its successors
# (§6.4: a gate is an ordinary node whose status a human writes instead of an agent). If this
# command could write a gate node, `guild node REQ-007/gate-plan done` would be an approval
# with no `gate` row, no decision, no event and no record of who decided — the guild master's
# control surface, bypassed by the one process that is supposed to be enforcing it.
#
# `--task` IS THE DISPATCH-TIME BINDING, and it is narrow on purpose. `guild graph new` binds
# `graph_node.task_id` only where the correspondence is unambiguous — a per-slice node to its
# slice's ticket, an agent-named node to that agent's ticket — and leaves every other node
# NULL (lib/graph.sh). This is how a node acquires its ticket later, when the orchestrator
# knows which one it dispatched. It is refused when another node of the SAME KEY already
# binds that ticket, because `graph_node` is UNIQUE (requirement_id, node_key, task_id) and
# the collision it protects against is real: the `review` node fans out to four instances and
# the `standard` chain has ONE reviewer ticket, so binding it four times would violate the
# constraint on the second call and surface as a raw engine error. Four nodes sharing one
# ticket is a correspondence that does not exist; a NULL is the honest answer.
cmd_node() {
  local node="" status="" task="" positional=0
  local nodelit tasklit statuslit guard now nowlit actorlit sql markers out line

  while [ $# -gt 0 ]; do
    case "$1" in
      --task)
        shift
        task="${1-}"
        [ $# -eq 0 ] || shift
        continue
        ;;
      --task=*) task="${1#--task=}" ;;
      -*) die "guild: unknown option '$1' for node (try 'guild node <NODE-ID> <status> [--task TASK-NNN]')" ;;
      *)
        positional=$((positional + 1))
        case "$positional" in
          1) node="$1" ;;
          2) status="$1" ;;
          *)
            die "guild: node takes a node id and a status (got a third argument '$(_render_flat_arg "$1")').

  guild node REQ-007/implement.auth-service running --task TASK-011
  guild node REQ-007/implement.auth-service done"
            ;;
        esac
        ;;
    esac
    shift
  done

  _seg_check_node "$node"
  [ -n "$status" ] || die "guild: node requires a status ($(_seg_node_statuses)).

  guild node $node running --task TASK-NNN     dispatching it
  guild node $node done                        the agent reported done
  guild node $node failed                      the agent reported failed
  guild node $node skipped                     deliberately not run; successors are NOT held

The orchestrator owns every status transition — an agent never moves its own node."

  case " $(_seg_node_statuses) " in
    *" $status "*) ;;
    *)
      die "guild: '$(_render_flat_arg "$status")' is not a graph node status.

The vocabulary is: $(_seg_node_statuses)

'done' and 'skipped' both count as FINISHED, so both release the successors behind this
node. 'failed' and 'running' hold them — which is the honest answer, because a segment is a
list of things to run and running work behind an unfinished predecessor is how a half-built
slice gets reviewed."
      ;;
  esac

  if [ -n "$task" ]; then
    case "$task" in
      TASK-[0-9]*)
        case "${task#TASK-}" in
          *[!0-9]*) die "guild: '$(_render_flat_arg "$task")' is not a task id (expected TASK-NNN)" ;;
        esac
        ;;
      *) die "guild: '$(_render_flat_arg "$task")' is not a task id (expected TASK-NNN)" ;;
    esac
  fi

  db_require_init
  journal_preflight

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  # The node id passed `_seg_check_node`'s closed alphabet and the task id is `TASK-` plus
  # digits, so both reach SQL through sql_str. Nothing here is free text.
  nodelit="$(sql_str "$node")"
  statuslit="$(sql_str "$status")"
  tasklit="NULL"
  [ -z "$task" ] || tasklit="$(sql_str "$task")"

  # The guard, in one place because five statements need it: the node exists, it is not a
  # gate, and — when --task was passed — the ticket exists, belongs to this node's
  # requirement, and is not already bound to a sibling instance of the same key.
  guard="EXISTS (SELECT 1 FROM graph_node gg WHERE gg.id = $nodelit AND gg.kind <> 'gate')"
  if [ -n "$task" ]; then
    guard="$guard
  AND EXISTS (SELECT 1 FROM task t2 JOIN graph_node g2 ON g2.id = $nodelit
               WHERE t2.id = $tasklit AND t2.requirement_id = g2.requirement_id)
  AND NOT EXISTS (SELECT 1 FROM graph_node g3 JOIN graph_node g4 ON g4.id = $nodelit
                   WHERE g3.id <> g4.id AND g3.requirement_id = g4.requirement_id
                     AND g3.node_key = g4.node_key AND g3.task_id = $tasklit)"
  fi

  sql="BEGIN;
SELECT 'MISS|1' WHERE NOT EXISTS (SELECT 1 FROM graph_node WHERE id = $nodelit);
SELECT 'WAS|' || n.status || '|' || n.kind FROM graph_node n WHERE n.id = $nodelit;
"
  if [ -n "$task" ]; then
    sql="${sql}SELECT 'NOTASK|1' WHERE NOT EXISTS (SELECT 1 FROM task WHERE id = $tasklit);
SELECT 'XREQ|' || $(_graph_field 't.requirement_id')
  FROM task t JOIN graph_node n ON n.id = $nodelit
 WHERE t.id = $tasklit AND t.requirement_id <> n.requirement_id;
SELECT 'DUP|' || $(_graph_field 'g3.id')
  FROM graph_node g3 JOIN graph_node g4 ON g4.id = $nodelit
 WHERE g3.id <> g4.id AND g3.requirement_id = g4.requirement_id
   AND g3.node_key = g4.node_key AND g3.task_id = $tasklit;
"
  fi

  # The event first, then the UPDATE — the order `cmd_gate`'s header sets out, and for its
  # reason: the event's predicate reads `graph_node`, which the UPDATE writes, so it has to
  # be evaluated against state the UPDATE has not yet disturbed. `COALESCE(<task>, task_id)`
  # means an omitted --task PRESERVES the binding rather than clearing it; there is no
  # spelling here that unbinds a node, because `guild graph deviate` owns shape changes.
  sql="$sql
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $actorlit, 'moved', 'graph_node', n.id,
       json_object('requirement', n.requirement_id, 'node_key', n.node_key,
                   'from', n.status, 'to', $statuslit, 'task', COALESCE($tasklit, n.task_id))
FROM graph_node n WHERE n.id = $nodelit AND $guard;
UPDATE graph_node SET status = $statuslit, task_id = COALESCE($tasklit, task_id)
 WHERE id = $nodelit AND $guard
RETURNING 'R|graph_node|upsert|' || $(_art_json_row graph_node);
SELECT 'NOW|' || n.status FROM graph_node n WHERE n.id = $nodelit;
COMMIT;
"

  markers="$(_seg_tmp node)"
  if ! printf '%s' "$sql" | db_exec >"$markers"; then
    out="$(cat "$markers" 2>/dev/null || true)"
    rm -f "$markers"
    db_fail "could not move the node $node" "$out"
  fi

  if LC_ALL=C grep -q '^MISS|' "$markers"; then
    rm -f "$markers"
    die "guild: there is no graph node at '$node'.

  guild graph ${node%%/*}      the nodes this requirement has, and their statuses
  guild segment ${node%%/*}    the ones that are runnable right now"
  fi

  line="$(LC_ALL=C awk -F'|' '$1 == "WAS" { print $3; exit }' "$markers")"
  if [ "$line" = gate ]; then
    rm -f "$markers"
    die "guild: '$node' is a GATE — refused. Nothing was written.

A gate's status is the guild master's decision, and it is recorded with the decision, the
timestamp and the event that names who made it:

  guild gate $node --approve
  guild gate $node --reject --decision 'why'

Writing the node directly would set it 'done' with no gate row, no decision and no record —
an approval nobody made. Gates are the control surface (design 6.4); this command is for the
work between them."
  fi

  if LC_ALL=C grep -q '^NOTASK|' "$markers"; then
    rm -f "$markers"
    die "guild: $task not found — nothing was written."
  fi

  line="$(LC_ALL=C awk -F'|' '$1 == "XREQ" { print $2; exit }' "$markers")"
  if [ -n "$line" ]; then
    rm -f "$markers"
    die "guild: $task belongs to $line, and '$node' belongs to ${node%%/*} — nothing was written.

A node binds a ticket of its own requirement. Binding across requirements would make
'guild segment' report work that is not this requirement's, and 'guild graph validate' reads
a cross-requirement link as a broken graph."
  fi

  line="$(LC_ALL=C awk -F'|' '$1 == "DUP" { print $2; exit }' "$markers")"
  if [ -n "$line" ]; then
    rm -f "$markers"
    die "guild: $task is already bound to '$line', which is another instance of the same node
key — nothing was written.

'graph_node' is UNIQUE (requirement_id, node_key, task_id), and the constraint is protecting
a real confusion: the 'review' node fans out to four instances and the standard chain has ONE
reviewer ticket, so binding it to each of them would claim a correspondence that does not
exist. Leave the fanned nodes unbound and move them by id:

  guild node $node running
  guild node $node done"
  fi

  if ! LC_ALL=C grep -q '^R|graph_node|' "$markers"; then
    out="$(cat "$markers" 2>/dev/null || true)"
    rm -f "$markers"
    db_fail "could not move the node $node" "$out"
  fi

  _graph_journal_markers "$markers" >/dev/null
  line="$(LC_ALL=C awk -F'|' '$1 == "NOW" { print $2; exit }' "$markers")"
  rm -f "$markers"

  printf '%s %s\n' "$node" "${line:-$status}"
}

# ============================ guild gates =============================================

# cmd_gates [--pending] [--json] — the gates, board-wide, and whether each is actionable.
#
#   guild gates
#   REQ-007/gate-plan    REQ-007 approved approve         ready   Plan for REQ-007 is ...
#   REQ-007/gate-repairs REQ-007 pending  select-findings waiting Findings and bugs ...
#
# Six whitespace-separated columns, fixed count, free text LAST — `guild bounties`' shape,
# so `awk '$3 == "pending" && $5 == "ready"'` is "what is actually waiting on me":
#
#   1  node id        `_render_col`
#   2  requirement    `_render_col`
#   3  status         pending | approved | rejected
#   4  kind           approve | select-findings
#   5  readiness      `ready` | `waiting`
#   6  prompt         `_render_flat`, clipped, and last because it is the only free text
#
# THE READINESS COLUMN IS THE POINT, not decoration. A pending gate whose predecessors are
# still running is not awaiting the guild master — it is awaiting the guild. Listing the
# two identically is how a board grows a queue of decisions that cannot be made, and it is
# also what `guild gate` refuses (see cmd_gate), so this column is the same fact one
# command before the refusal.
#
# `--pending` narrows to `status = 'pending'`. The default is EVERY gate, including decided
# ones: a rejected gate is the most important row on this surface, and the record of what
# was approved and when is the audit trail the two-gate model exists to produce.
cmd_gates() {
  local only_pending=0 mode="text" cols where sqlf rows

  while [ $# -gt 0 ]; do
    case "$1" in
      --pending) only_pending=1 ;;
      --json) mode="json" ;;
      -*) die "guild: unknown option '$1' for gates (try 'guild gates [--pending] [--json]')" ;;
      *) die "guild: gates takes no positional arguments (got '$(_render_flat_arg "$1")')" ;;
    esac
    shift
  done
  db_require_init

  where=""
  [ "$only_pending" = 0 ] || where=" AND g.status = 'pending'"

  if [ "$mode" = json ]; then
    cols="json_object('node', n.id, 'requirement', n.requirement_id, 'status', g.status,
                      'kind', g.kind,
                      'ready', CASE WHEN $(_graph_ready_where n) THEN 1 ELSE 0 END,
                      'prompt', g.prompt, 'decision', g.decision, 'decided_at', g.decided_at)"
    sqlf="$(_seg_tmp gates-sql)"
    rows="$(_seg_tmp gates)"
    printf "SELECT 'G|' || %s
  FROM gate g JOIN graph_node n ON n.id = g.node_id
 WHERE 1 = 1%s ORDER BY n.requirement_id, n.id;\n" "$cols" "$where" >"$sqlf"
    _render_query "$sqlf" "$rows" "guild: could not read the gates"
    # awk assembles the array and never touches a value — json_object escaped every one of
    # them, so a `G|` row is always exactly one line (§3.0).
    LC_ALL=C awk '
      substr($0, 1, 2) == "G|" { row[++n] = substr($0, 3) }
      END {
        if (n == 0) { print "{ \"gates\": [] }"; exit 0 }
        print "{"
        print "  \"gates\": ["
        for (i = 1; i <= n; i++) printf("    %s%s\n", row[i], (i < n ? "," : ""))
        print "  ]"
        print "}"
      }' "$rows"
    rm -f "$rows"
    return 0
  fi

  cols="$(_render_col 'n.id') || ' ' || $(_render_col 'n.requirement_id')"
  cols="$cols || ' ' || $(_render_col 'g.status') || ' ' || $(_render_col 'g.kind')"
  cols="$cols || ' ' || CASE WHEN $(_graph_ready_where n) THEN 'ready' ELSE 'waiting' END"
  cols="$cols || ' ' || $(_brief_txt 'g.prompt' 160)"

  printf "SELECT %s FROM gate g JOIN graph_node n ON n.id = g.node_id
 WHERE 1 = 1%s ORDER BY n.requirement_id, n.id;\n" "$cols" "$where" | db_query
}
