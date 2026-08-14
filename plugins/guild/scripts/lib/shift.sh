# shellcheck shell=bash
#
# lib/shift.sh — guild v5 Stage 5: THE UNATTENDED SHIFT (design §8).
#
#   > The guild must be able to work a shift while the guild master is away. The two-gate
#   > model is what makes this coherent: RUN UNTIL THE NEXT GATE, THEN STOP AND NOTIFY.
#   > The segment boundary and the stop boundary are the same line, so unattended mode
#   > needs no separate notion of "how far may it go."
#
# Stage 4 built the thing that can stop itself: `guild segment` says what runs, `guild gate`
# is the one decision a subagent physically cannot make. This file is the LOOP around them,
# and the loop is deliberately the last thing built — an autonomous run against a chain that
# could not stop itself is the failure mode the whole rollout order exists to avoid (§13).
#
#   guild shift [--max-tasks N] [--max-minutes M] [--requirement REQ-NNN]
#               [--dry-run] [--json]        one turn of the loop: a DIRECTIVE
#   guild shift --end [--reason R] [--note "..."]   close the open shift, with its reason
#   guild shift --policy [--json]           the may / may-not table, in full
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` (scripts/guild owns those).
# Bash 3.2 compatible: no associative arrays, no `declare -A`, no `mapfile`, no ${var^^}.
#
# Depends on lib/db.sh        : die, db_fail, db_require_init, db_exec, db_query, db_now,
#                               sql_str, sql_text
#          on lib/journal.sh  : journal_preflight
#          on lib/artifacts.sh: _art_actor, _art_json_row (THE ONE PROJECTION REGISTRY)
#          on lib/render.sh   : _render_flat, _render_flat_arg, _render_col, _render_tmp,
#                               _render_query
#          on lib/brief.sh    : _brief_txt (clip, then flatten — the human free-text gate)
#          on lib/graph.sh    : _graph_check_req, _graph_ready_where, _graph_field,
#                               _graph_state_key, _graph_journal_markers
#          on lib/roster.sh   : _roster_has_caps, _roster_super_where (THE matcher's own
#                               eligibility test — `guild bounties`' third arm, reused)
#          on lib/segment.sh  : _seg_check_node, _seg_json_str
#
# ---------------------------------------------------------------------------------
# THE GOVERNING SHAPE: `guild shift` IS THE LOOP'S CONTROLLER, NOT ITS RUNNER
#
# A shell script cannot dispatch an agent. The ORCHESTRATOR does that, and the orchestrator
# is a Claude session. So `guild shift` is called once per turn of the loop and answers one
# question — WHAT NOW — with one of two answers:
#
#   run   this requirement is actionable; go read `guild segment REQ-NNN --json` and
#         dispatch its first batch, then call `guild shift` again
#   stop  the shift is over, and here is the reason, recorded as an `event` row
#
# NOTE WHAT IT DOES NOT DO: it does not re-emit the batches. `guild segment` already
# produces that document, the workflow compiler already reads it
# (skills/check-in/references/workflow-compilation.md), and a second copy of the level
# sweep in this file would be a second answer to "what runs next" — the divergence every
# module header in this CLI is written to prevent. The shift decides WHICH requirement and
# WHETHER TO CONTINUE; `guild segment` decides WHAT RUNS. One question each.
#
# That split is also what keeps this file inside the one-round-trip rule: a step is ONE
# `db_exec`, and the batch list is a different logical command the orchestrator issues
# itself.
#
# ---------------------------------------------------------------------------------
# THE SHIFT RECORD LIVES IN `event`, AND ONLY IN `event`
#
# §8.5: "The guild master should be able to reconstruct the whole shift from the `event`
# log." Taken literally, that is also the cheapest correct design — the shift needs durable
# state (its identity, its clock, its budget, how much of it is spent), and every candidate
# store for that state is a table this file would then have to UPDATE with a guard that
# reads the very table it writes. `guild gate`'s header sets out why that is a trap and why
# the CLI has verified self-referencing subqueries in INSERT but none in UPDATE.
#
# So there is no shift table and no `guild_state` key. There are four verbs:
#
#   started  subject_type 'shift', subject_id SHIFT-<utc-stamp>,
#            payload {max_tasks, max_minutes, requirement} — THE BUDGET, fixed here
#   stepped  subject_type 'shift', payload {step, used, minutes, stall, requirement}
#   ended    subject_type 'shift', payload {reason, note, tasks, minutes, steps}
#            (the step's own close adds `requirement`; `--end` leaves it off, because the
#             scope is already on the `started` row and that is where readers take it from)
#   retried / gave-up (subject_type 'graph_node') and blocked (subject_type 'task') —
#            the failure policy's three records
#
# TWO WRITERS PRODUCE `ended` — the step's stop condition and `guild shift --end` — and they
# must agree key for key, because `guild shift-report` reads one row without knowing which
# wrote it. That is why `steps` is computed in both.
#
# and every derived fact is a scalar subquery over them:
#
#   the open shift   the newest `started` with no matching `ended`   (_shift_open_evt)
#   its clock        that event's `ts`
#   its budget       json_extract of that event's payload
#   tasks used       distinct graph nodes MOVED since that ts        (_shift_used_expr)
#   the step number  count of `stepped` rows for it
#
# INSERT-ONLY STATE HAS A SECOND PAYOFF: a crashed shift is not a corrupt row, it is a
# `started` with no `ended`, which the next `guild shift` resumes and `guild shift --end`
# closes. There is nothing to repair and nothing to hand-edit.
#
# ---------------------------------------------------------------------------------
# HARD RULES honored throughout (§2.2, §2.2.1, §3.0):
#
#   * ONE db_exec PER LOGICAL COMMAND. A step reads the shift record, applies the whole
#     failure policy, computes the stop reason, writes the `stepped` or `ended` event and
#     emits every render marker in ONE script. `--end` is one script. `--policy` touches
#     no database at all.
#
#   * sql_text FOR ALL FREE TEXT; sql_str ONLY FOR KNOWN-SAFE ALPHABETS. Exactly one value
#     this file handles is free text — `--end --note`, a sentence the guild master typed —
#     and it travels as hex. Everything else is a `REQ-NNN`, a node id that passed
#     `_seg_check_node`, an integer this file parsed digit by digit, a UTC timestamp, or a
#     word from a closed vocabulary this file itself defines.
#
#   * NEVER `WITH RECURSIVE`. Readiness here is `_graph_ready_where` — CALLED, never
#     restated — which is one hop over `graph_edge`. The shift asks "is there ready work in
#     this requirement", which is a COUNT over that predicate, not a traversal. No CTE of
#     any kind is used, recursive or not: a non-recursive `WITH` is verified for SELECT
#     (§3.0) but not for the INSERT and UPDATE guards this file also needs it in, and one
#     spelling of a predicate that works everywhere beats two that each work somewhere.
#
#   * A VALUE MUST NEVER IMPERSONATE A STRUCTURAL TOKEN. Two output channels, two
#     disciplines, both inherited unchanged from lib/segment.sh: marker lines split on a
#     FIXED number of leading pipes with the free text LAST and alone (THE MARKER CHANNEL),
#     and a JSON document in which NOT ONE VALUE IS WRITTEN BY THE SHELL OR BY AWK — every
#     string arrives from the driver as a complete literal from `_seg_json_str`.
#
#   * NO QUADRATIC STRING HANDLING. Marker lines are split by `read`/`split` with a fixed
#     field count so the free-text remainder lands untouched in the last variable; no
#     `${v%%pat*}` is ever applied to an unbounded value.
#
#   * EVERY MUTATION IS JOURNALED AND WRITES AN `event` ROW. This file makes four kinds of
#     mutation — the shift's own four verbs, a retried node, a given-up node's ticket, and a
#     roster-gapped ticket — and each writes its event and its `R|<table>|upsert|<json>`
#     journal marker. journal_preflight runs BEFORE any SQL, so an unwritable journal is a
#     refusal that wrote nothing rather than a shift `guild rebuild` silently undoes.
#     `--dry-run` and `--policy` mutate NOTHING and take no preflight.
#
# ---------------------------------------------------------------------------------
# WHAT A SHIFT PICKS UP, IN ORDER (§8.1)
#
#   1. Open build bounties whose dependencies are satisfied — the `standard` template.
#   2. Nodes of an inspection THE GUILD MASTER ALREADY STARTED — the `maintenance` template.
#   3. Nothing left → the shift ends.
#
# Implemented as a TIER on each requirement that owns a graph:
#
#   tier 1   its recorded template is `standard`               — may be picked up cold
#   tier 2   anything else (`maintenance`, a project's own)    — ONLY IF ALREADY STARTED
#
# and "already started" is `EXISTS a node of that graph whose status is not 'pending'` —
# something has run, or a gate has been decided. A freshly instantiated `maintenance` graph
# is all-pending, so a shift will not touch it: §6.2 makes QA manual-trigger-only because a
# full inspection runs the real product one mission at a time, and firing that automatically
# would quietly multiply what a requirement costs. AN IDLE SHIFT ENDS IDLE RATHER THAN
# INVENTING WORK — the conservative default while unattended operation is new.
#
# THE DEFAULT FOR AN UNKNOWN TEMPLATE IS TIER 2, AND THAT DIRECTION IS THE POINT. A project
# that drops its own YAML into `.guild/templates/` gets the cautious treatment until a human
# starts the first node, because this file cannot know whether that template's first step is
# cheap. Guessing tier 1 would make "never start an inspection" true only for the two
# templates that happen to ship.
#
# Within a tier the order is `requirement.priority` then id — the board's own order, so a
# shift works the same queue a guild master would.
#
# ---------------------------------------------------------------------------------
# THE POLICY IS A TABLE, AND THE TABLE IS LOAD-BEARING (§8.2)
#
# `_shift_policy` is the whole of §8.2's two columns, one line each, and `_shift_may` is the
# only way this file asks whether it is allowed to do something. The three places that could
# act — the retry, the give-up, the roster-gap block — each ask first, so moving a row from
# MAY to MAY NOT changes behavior rather than only documentation. `guild shift --policy`
# prints it, and every `run` directive carries it, so the contract the orchestrator is being
# handed is the same string the CLI enforces.
#
# THE ASYMMETRY IS THE WHOLE DESIGN: an unattended guild CAN DO WORK AND RECORD PROBLEMS,
# BUT EVERY JUDGMENT CALL WAITS FOR THE GUILD MASTER.
#
# BE HONEST ABOUT THE HALF NO SHELL FUNCTION CAN ENFORCE. The orchestrator is a Claude
# session holding Bash; it could run `git push` or write an `agents/*.md` file with tools
# this CLI never sees, and nothing here can stop it. What the CLI *can* do it does, and the
# door is locked in the module that owns each door rather than re-implemented here:
#
#   decide a gate            `guild node` refuses a gate node outright  (lib/segment.sh)
#   push, or commit to the   `guild git` has no push/fetch/pull/remote verb at all, and its
#   default branch           git wrapper is an ALLOWLIST, so no later edit can reach one by
#                            accident; committing to a protected branch is refused
#                            (lib/gitsafe.sh)
#   create a guild member    `guild capability-request` writes a row and stops, because
#                            §5.4's last line is that an unattended shift may never create
#                            an agent                                    (lib/roster.sh)
#
# This file's own contribution is that the denial list travels WITH the work: every `run`
# directive prints it, and `guild shift --policy` is the same table from the same source.
#
# ---------------------------------------------------------------------------------
# THE FAILURE POLICY (§8.3) — A SHIFT MUST NEVER DEADLOCK ON ONE BAD BOUNTY
#
#   task fails         retry ONCE with a fresh agent. Still failing → leave it `failed`,
#                      record why, fail its ticket, CONTINUE with other independent
#                      bounties.
#   no eligible agent  mark the ticket `blocked` and continue. It surfaces as a roster gap
#                      in `guild brief` and in `guild bounties`.
#   file collision     mark the batch failed, DO NOT reconcile the tree, STOP the shift.
#                      Not safely automatable, so it is not automated: the orchestrator
#                      reports it with `guild shift --end --reason collision`.
#   gate reached       the gate is already `pending`; notify and end cleanly.
#
# "RETRY ONCE" IS COUNTED FROM THE EVENT LOG, NOT FROM A COUNTER. A node may be retried
# once per shift, and the test is `NOT EXISTS a 'retried' event for this node since this
# shift's start`. That is durable across a crash, needs no extra column, and resets on the
# next shift — which is the right grain: a bounty that failed twice last night deserves a
# fresh attempt tonight, and one that fails twice tonight deserves to be left alone.
#
# "A FRESH AGENT" MEANS A FRESH AGENT INSTANCE, NOT A DIFFERENT ROSTER MEMBER. The retry
# sets the node back to `pending`; the orchestrator dispatches it again and gets a new
# subagent with a clean context. It does NOT re-pick the member, because `_roster_top_agent`
# is deterministic and would return the same one — and silently routing work to the roster's
# second choice because the first failed is a matcher nobody could reason about.
#
# A RETRY COSTS NOTHING FROM THE TASK BUDGET, because the budget counts DISTINCT graph nodes
# moved and a retried node was already counted. That is what makes "retry once" affordable
# rather than a way to halve `--max-tasks`.
#
# A GIVE-UP AND A ROSTER GAP BOTH HAVE TO CHANGE THE BOARD, NOT ONLY THE LOG. A node left
# `failed` holds its successors (`_graph_ready_where` counts only `done` and `skipped` as
# finished), so the requirement's remaining independent work keeps being offered and the
# dead branch does not. A ticket nobody can take is different: its NODE is still `pending`
# and still ready, so without a board change the shift would select the same requirement,
# emit the same directive and spin. So `_shift_ready_work` excludes nodes whose ticket is
# `blocked` or `failed`, and the block is what makes the loop move on. The stall detector
# below is the backstop for the case this reasoning misses.
#
# ---------------------------------------------------------------------------------
# STOP CONDITIONS AND BUDGET (§8.4) — AN UNATTENDED LOOP WITH NO CEILING IS A RUNAWAY
#
# A shift ends on the FIRST of these, evaluated in this precedence:
#
#   1. gate            no candidate has runnable work and an unresolved gate is READY
#   2. infrastructure  the loop is not progressing (see THE STALL DETECTOR)
#   3. max-tasks       default 10
#   4. max-minutes     default 60
#   5. idle            no candidate has runnable work and no gate is waiting either
#
# and, only by explicit report from the orchestrator (`guild shift --end --reason`):
#
#   6. collision       a parallel file collision — §8.3's one un-automatable failure
#   7. operator        the guild master ended it
#
# WHY `gate` OUTRANKS THE CEILINGS. Reaching a gate is the shift SUCCEEDING; a budget stop
# is the shift being cut short. If both are true at once the morning read should say "a
# decision is waiting", not "out of budget" — the first is actionable and the second is
# noise. The two are only ever simultaneous at the last step anyway.
#
# WHY `infrastructure` OUTRANKS THEM TOO. A stalled loop reported as `max-tasks` is a lie
# that costs a whole night: the brief would say the shift did its ten and stopped, when in
# fact it did nothing ten times. Naming the fault is the entire value of recording a reason.
#
# EVERY EXIT WRITES AN `event` ROW WITH ITS REASON (§8.4, last line), which is what lets
# `guild brief --since <last-checkin>` say why the shift stopped.
#
# THE TASK BUDGET'S UNIT IS A GRAPH NODE THIS SHIFT MOVED, counted once however many times
# it moves. `running` then `done` is one task, not two; a retry is not a second one. Read
# from `event` (`verb='moved'`, `subject_type='graph_node'`), which is the row `guild node`
# writes — so the budget counts work the orchestrator actually dispatched, never work this
# file merely planned. A shift that emits ten directives nobody acts on spends nothing and
# is caught by the stall detector instead.
#
# THE BUDGET IS FIXED WHEN THE SHIFT OPENS, AND A LATER STEP MAY NOT CHANGE IT. Passing
# `--max-tasks 10` on every turn of a loop is fine — it matches. Passing a DIFFERENT value
# to a shift already in progress is REFUSED, with nothing written, because a ceiling you can
# raise from inside the loop is not a ceiling. That refusal is a guard on every write
# statement in the step script and a marker beside them, so a refused step leaves no event,
# no row and no journal line (`cmd_gate`'s protocol).
#
# THE STALL DETECTOR is §8.4's "repeated infrastructure failure", made mechanical. Each
# `stepped` event records the budget used at that moment. If a step finds the SAME count as
# the previous step, nothing moved between them and the loop is spinning; two of those in a
# row ends the shift as `infrastructure`. The threshold is two rather than one because one
# is reachable honestly — a step whose whole contribution was a retry moves no node.
#
# ---------------------------------------------------------------------------------
# GIT SAFETY (§8.6) — WHY IT IS A SIBLING MODULE AND NOT THIS ONE
#
# A shift works on `guild/REQ-NNN`, commits per completed task, never pushes and never
# commits to the default branch. Stage 5 gave that its OWN module, `lib/gitsafe.sh`
# (`guild git branch-for | commit-task | revert-task | shift-status`), for the reason this
# file would otherwise have had to solve twice: unattended git access is only safe if there
# is exactly ONE place a reader has to audit to know what the guild can do to a repository,
# and that place is `_gs_git`'s allowlist. A second git call site in the controller would
# make the audit two files wide on the first day.
#
# So this file still contains no git, and the split is the design rather than an omission:
#
#   lib/shift.sh    decides WHICH requirement is next and WHETHER to continue
#   lib/segment.sh  decides WHAT RUNS inside it
#   lib/gitsafe.sh  is the only thing that touches the tree
#
# What this file contributes to §8.6 is the two things that make the rule followable — it
# NAMES the branch in every directive (`guild/REQ-NNN`, the same spelling `_gs_branch_name`
# produces, so the orchestrator never has to invent one), and it carries the two git denials
# in the policy table it hands over with the work.

# ---- the alphabets -------------------------------------------------------------------

# _shift_check_int <value> <flag> — die unless <value> is a positive decimal integer that
# may be CONCATENATED into SQL.
#
# The budget flags are the only numbers this file takes from argv, and they end up inside a
# comparison in an INSERT guard, so they are validated to digits rather than escaped. Zero
# is refused along with everything non-numeric: `--max-tasks 0` is a shift that stops before
# it starts, which is `--dry-run` spelled confusingly. The upper bound is a sanity rail, not
# a policy — six digits of tasks or minutes is already far past any shift a person meant.
_shift_check_int() {
  local v="${1-}" flag="${2-}"
  local LC_ALL=C

  [ -n "$v" ] ||
    die "guild: $flag requires a number — for example '$flag 10'"
  case "$v" in
    *[!0-9]*)
      die "guild: '$(_render_flat_arg "$v")' is not a number ($flag takes a positive integer)"
      ;;
  esac
  [ "${#v}" -le 6 ] ||
    die "guild: $flag is limited to six digits — '$(_render_flat_arg "$v")' is not a budget"
  [ "$v" -gt 0 ] ||
    die "guild: $flag must be greater than zero.

A budget of 0 is a shift that ends before it begins. If you want to see the plan without
running anything, that is what --dry-run is for:

  guild shift --dry-run"
}

# _shift_reasons — the CLOSED vocabulary of stop reasons, blank-separated.
#
# ONE list, for the same reason `art_statuses` and `_seg_node_statuses` are each one list:
# it is both what `--end --reason` accepts and what the step's own CASE can produce, and a
# second copy is a reason one surface writes and another cannot read. `event.verb` and this
# vocabulary are the whole of what `guild brief` has to narrate a shift from.
_shift_reasons() {
  printf 'gate infrastructure max-tasks max-minutes idle collision operator\n'
}

# _shift_check_reason <value> — die unless <value> is in that vocabulary.
_shift_check_reason() {
  local v="${1-}"
  case " $(_shift_reasons) " in
    *" $v "*) return 0 ;;
  esac
  die "guild: '$(_render_flat_arg "$v")' is not a stop reason.

The vocabulary is: $(_shift_reasons)

A shift ends on its own for the first five. The two you pass by hand are the ones only the
orchestrator can see:

  guild shift --end --reason collision --note 'REQ-007 slices both touched src/auth.ts'
        two parallel slices wrote the same file — design 8.3's one un-automatable failure,
        so the tree is left exactly as it is for the guild master to reconcile
  guild shift --end --reason operator
        you are back; the shift is over"
}

# _shift_tmp <label> — a temp file, or die. Delegates; there is one of these in the CLI.
_shift_tmp() {
  _render_tmp "shift-${1:-work}"
}

# _shift_id <now> — SHIFT-20260815T031200Z, derived from the UTC timestamp `db_now` gives.
#
# Derived rather than random so a shift id SORTS and so the same value can be read out of
# the `started` event's `ts` by eye. The result is digits, `T` and `Z` — an alphabet
# `sql_str` may carry and an error message may concatenate.
#
# `${v//[-:]/}` over a fixed 20-character timestamp, not over an unbounded value, so rule 5
# is not in play. THE DASH IS FIRST INSIDE THE BRACKETS ON PURPOSE: `[:-]` would be read as
# a range from `:` (0x3A) down to `-` (0x2D), which is reversed and, in the `tr` spelling of
# the same idea, silently swallows every digit.
_shift_id() {
  local v="${1-}"
  printf 'SHIFT-%s\n' "${v//[-:]/}"
}

# ============================ the policy table (§8.2) =================================

# _shift_policy — §8.2's two columns, one row per line:
#
#   MAY|<verb>|<what it means>
#   NOT|<verb>|<what it means>
#
# THIS IS THE FILE'S ONE STATEMENT OF WHAT AN UNATTENDED GUILD IS ALLOWED TO DO, and the
# code consults it rather than restating it — see `_shift_may`. Encoding §8.2 as scattered
# `if` statements was the alternative and it is how a permission quietly widens: nobody
# reviewing a diff notices a missing condition three functions away, and everybody notices a
# row moving from NOT to MAY.
#
# THE TEXT IS A FIXED LITERAL, NEVER INPUT, AND CONTAINS NO QUOTE, BACKSLASH OR PIPE. That
# is what lets `--policy --json` emit it without an escaper — the same property, and the
# same reasoning, as `_brief_fact_select`'s fixed heredoc. If you add a row, keep it plain.
_shift_policy() {
  cat <<'POLICY'
MAY|claim-bounty|claim any open bounty whose dependencies are satisfied
MAY|run-segment|run whole segments, and compile and run workflows from them
MAY|retry-task|retry a failed task once, with a fresh agent
MAY|fail-task|mark a task failed, record why, and move on
MAY|block-task|mark a task blocked when no member is eligible, and move on
MAY|file-bug|file bugs and review findings against what it ran
MAY|write-record|write to event, work_log and review_finding
MAY|commit-branch|commit per completed task, on the branch guild/REQ-NNN
NOT|approve-gate|approve a gate, or reject one — that is the guild master's decision
NOT|pass-gate|proceed past an unresolved gate
NOT|create-gate|create a gate, or drop one
NOT|close-requirement|mark a requirement done past an unresolved gate
NOT|delete|delete anything, or rewrite history
NOT|push|push to a remote
NOT|commit-default|commit to the default branch
NOT|change-direction|change goals, phases or priorities
NOT|create-agent|create a guild member (design 5.4)
POLICY
}

# _shift_may <verb> — 0 when the policy table permits <verb>, 1 otherwise.
#
# THE ONLY WAY THIS FILE ASKS PERMISSION. Every action a step can take is guarded by a call
# to this, so the table above is enforcement and not commentary. An unknown verb is DENIED:
# a typo must fail closed, because the failure mode of failing open is an unattended process
# doing something nobody wrote down.
_shift_may() {
  local want="${1-}" tag verb rest
  [ -n "$want" ] || return 1
  while IFS='|' read -r tag verb rest; do
    [ "$verb" = "$want" ] || continue
    [ "$tag" = "MAY" ] && return 0
    return 1
  done <<EOF
$(_shift_policy)
EOF
  return 1
}

# _shift_policy_text — the table, as the human surface prints it.
_shift_policy_text() {
  printf 'What an unattended shift may do\n'
  printf '===============================\n\n'
  LC_ALL=C awk -F'|' '
    $1 == "MAY" { printf("  may      %-18s %s\n", $2, $3) }
  ' <<EOF
$(_shift_policy)
EOF
  printf '\nWhat it may not do — every one of these waits for the guild master\n'
  printf -- '-----------------------------------------------------------------\n\n'
  LC_ALL=C awk -F'|' '
    $1 == "NOT" { printf("  MAY NOT  %-18s %s\n", $2, $3) }
  ' <<EOF
$(_shift_policy)
EOF
  cat <<'TAIL'

The asymmetry is the point: an unattended guild can do work and record problems, but every
judgment call waits for you (design 8.2).

Where the CLI is the only door, the door is locked: 'guild node' refuses a gate node,
'guild gate' is the sole writer of a decision, 'guild git' has no push verb and refuses
the default branch, and 'guild capability-request' files a row rather than creating an
agent. Where it is not — a session can run bare 'git push' with tools this CLI never sees
— the prohibition travels with the work instead: 'guild shift' hands this table to the
orchestrator with every directive.
TAIL
}

# _shift_policy_json — the table as one JSON object.
#
# Values are the fixed literals above — no quote, no backslash, no control character — so
# awk assembles them directly. That is only safe BECAUSE the strings are a constant in this
# file; if a row ever grows a quote, it needs an escaper, not a bug report.
_shift_policy_json() {
  LC_ALL=C awk -F'|' '
    $1 == "MAY" { m[++nm] = $2; md[nm] = $3; next }
    $1 == "NOT" { d[++nd] = $2; dd[nd] = $3; next }
    END {
      print "{"
      print "  \"may\": ["
      for (i = 1; i <= nm; i++)
        printf("    { \"action\": \"%s\", \"means\": \"%s\" }%s\n", m[i], md[i], (i < nm ? "," : ""))
      print "  ],"
      print "  \"may_not\": ["
      for (i = 1; i <= nd; i++)
        printf("    { \"action\": \"%s\", \"means\": \"%s\" }%s\n", d[i], dd[i], (i < nd ? "," : ""))
      print "  ]"
      print "}"
    }
  ' <<EOF
$(_shift_policy)
EOF
}

# ============================ the shift record, as SQL ================================
#
# Every fragment below is a SCALAR SUBQUERY over `event`, usable unchanged in a SELECT, in
# an INSERT's WHERE and in an UPDATE's guard. That uniformity is deliberate: a non-recursive
# CTE would read better in the SELECTs and is verified there (§3.0), but it is NOT verified
# for the INSERT and UPDATE guards this file also needs, and one spelling that works
# everywhere beats two that each work somewhere.
#
# THEY ARE ALSO DELIBERATELY UN-NESTED. `_shift_open_evt` takes the COLUMN it wants, so the
# id, the clock and the budget are three sibling subqueries rather than three levels of
# subquery inside each other. Composing them the other way would have produced a query whose
# size grew multiplicatively with each derived fact.

# _shift_open_evt <column> — that column of THE OPEN SHIFT's `started` event, or NULL.
#
# The open shift is the newest `started` that has no `ended` carrying the same subject_id.
# Expressed as a NOT EXISTS rather than as a status column, because there is no status
# column — the log IS the state (see the header). `ORDER BY ts DESC, id DESC LIMIT 1` is the
# same "take rank 1 without a window function" shape `_roster_top_agent` uses, and the `id`
# tiebreak matters: two events can share a timestamp to the second.
_shift_open_evt() {
  printf "(SELECT eo.%s FROM event eo
            WHERE eo.subject_type = 'shift' AND eo.verb = 'started'
              AND NOT EXISTS (SELECT 1 FROM event ec
                               WHERE ec.subject_type = 'shift' AND ec.verb = 'ended'
                                 AND ec.subject_id = eo.subject_id)
            ORDER BY eo.ts DESC, eo.id DESC LIMIT 1)" "${1-subject_id}"
}

# _shift_json_int <json-expression> <key> — an integer out of an event payload.
#
# `json_extract` RAISES on malformed JSON and a raised error aborts the whole script, so it
# is wrapped in the `CASE WHEN json_valid(x)` guard lib/db.sh's `_spool_sql` established and
# lib/brief.sh reuses. A payload this file did not write (a hand-edited journal line, a v4
# carry-over that somehow reached `subject_type='shift'`) degrades to NULL, and every caller
# COALESCEs NULL to its own default rather than propagating it.
_shift_json_int() {
  printf "CASE WHEN json_valid(%s) THEN CAST(json_extract(%s, '\$.%s') AS INTEGER) END" \
    "${1-}" "${1-}" "${2-}"
}

# _shift_used_expr — TASKS SPENT: the number of DISTINCT graph nodes moved since the open
# shift started. 0 when no shift is open.
#
# `COUNT(*)` over a `GROUP BY` derived table rather than `COUNT(DISTINCT …)`, because §3.0's
# matrix is an ALLOWLIST and `COUNT(DISTINCT …)` has no row on it while `GROUP BY` and a
# derived table in FROM both do (lib/roster.sh's `_roster_req_caps` is the same shape). The
# rule the matrix states — if the code depends on it, it has a row — cuts both ways: the
# cheapest way to honor it is to not depend on anything new.
#
# The comparison against a NULL clock is what makes "no shift is open" answer 0 rather than
# "every move ever made": `ts >= NULL` is NULL, the WHERE selects nothing, COUNT is 0.
_shift_used_expr() {
  printf "(SELECT COUNT(*) FROM (SELECT em.subject_id FROM event em
            WHERE em.subject_type = 'graph_node' AND em.verb = 'moved'
              AND em.ts >= %s
            GROUP BY em.subject_id))" "$(_shift_open_evt ts)"
}

# _shift_minutes_expr <now-literal> — MINUTES SPENT, as an integer. 0 when nothing is open.
#
# The same julianday arithmetic `_brief_age` uses, so the CLI has one clock; only the
# projection differs, because a stop condition needs a number to compare and a briefing
# needs a phrase to read.
_shift_minutes_expr() {
  printf "COALESCE(CAST((julianday(%s) - julianday(%s)) * 1440 AS INTEGER), 0)" \
    "${1-}" "$(_shift_open_evt ts)"
}

# _shift_step_expr — which step this is: the count of `stepped` events for the open shift,
# plus one. 1 on the turn that opens the shift.
_shift_step_expr() {
  printf "(SELECT COUNT(*) FROM event es
            WHERE es.subject_type = 'shift' AND es.verb = 'stepped'
              AND es.subject_id = %s) + 1" "$(_shift_open_evt subject_id)"
}

# _shift_prev_expr <column> — that column of the PREVIOUS `stepped` event of this shift.
# NULL on the first step. The stall detector's whole input.
_shift_prev_expr() {
  printf "(SELECT ep.%s FROM event ep
            WHERE ep.subject_type = 'shift' AND ep.verb = 'stepped'
              AND ep.subject_id = %s
            ORDER BY ep.ts DESC, ep.id DESC LIMIT 1)" \
    "${1-payload}" "$(_shift_open_evt subject_id)"
}

# ============================ the board, as SQL =======================================

# _shift_template_expr <requirement-alias> — the template that built this graph, or ''.
#
# The KEY PREFIX COMES FROM `_graph_state_key` rather than being spelled here. `guild graph
# new` writes that row and `guild graph --explain` reads it back one requirement at a time;
# this file needs the same fact for a SET of requirements, which is a concatenation rather
# than a lookup — and taking the prefix from the function that defines it is what keeps
# "where the template name is recorded" a single fact rather than a convention two files
# happen to share.
_shift_template_expr() {
  printf "COALESCE((SELECT gt.value FROM guild_state gt WHERE gt.key = %s || %s.id), '')" \
    "$(sql_str "$(_graph_state_key '')")" "${1-r}"
}

# _shift_tier_expr <requirement-alias> — §8.1's pick-up order as a sortable integer.
# 1 = a build graph, which a shift may start; 2 = everything else, which it may only
# continue. See WHAT A SHIFT PICKS UP in the header for why the default is the cautious one.
_shift_tier_expr() {
  printf "CASE WHEN %s = 'standard' THEN 1 ELSE 2 END" "$(_shift_template_expr "${1-r}")"
}

# _shift_started_expr <requirement-alias> — has this graph been started by a human?
#
# One node past `pending` is the witness, and it is the right one because every way a
# requirement legitimately starts moves one: approving `gate-plan` sets that gate node
# `done`, and dispatching any node sets it `running`. An all-pending graph has been
# instantiated and nothing more.
_shift_started_expr() {
  printf "EXISTS (SELECT 1 FROM graph_node gt WHERE gt.requirement_id = %s.id
                    AND gt.status <> 'pending')" "${1-r}"
}

# _shift_ready_work_expr <requirement-alias> — how many nodes of this graph are runnable
# RIGHT NOW.
#
# `_graph_ready_where` is CALLED, never restated: `guild graph`'s render, `guild segment`'s
# level sweep, `guild gate`'s refusal and this count must agree about what "ready" means,
# and two spellings of readiness is two answers to "what runs next".
#
# THE TICKET FILTER IS NOT AN OPTIMIZATION. A node whose bounty is `blocked` or `failed` is
# ready by the graph's rules and unrunnable in fact — that is exactly the state the roster-
# gap rule creates — so counting it would make the shift select the same requirement, emit
# the same directive and spin. A node with NO ticket passes: that is the ordinary case for
# anything `guild graph new` could not bind unambiguously, and the orchestrator binds it at
# dispatch.
_shift_ready_work_expr() {
  local a="${1-r}"
  printf "(SELECT COUNT(*) FROM graph_node w
            WHERE w.requirement_id = %s.id AND w.kind <> 'gate'
              AND w.status IN ('pending','ready')
              AND %s
              AND NOT EXISTS (SELECT 1 FROM task tb WHERE tb.id = w.task_id
                               AND tb.status IN ('blocked','failed')))" \
    "$a" "$(_graph_ready_where w)"
}

# _shift_node_count_expr <requirement-alias> <status> — nodes of this graph in one status.
# Used for the two the directive reports beside the runnable count: `running` (out with an
# agent, or a crashed dispatch) and `failed` (adjudicated and holding its successors).
_shift_node_count_expr() {
  printf "(SELECT COUNT(*) FROM graph_node wc
            WHERE wc.requirement_id = %s.id AND wc.kind <> 'gate' AND wc.status = %s)" \
    "${1-r}" "$(sql_str "${2-running}")"
}

# _shift_candidate_where <requirement-alias> <req-filter-clause> — §8.1's eligibility, whole.
#
# A requirement is a candidate when it owns a graph, is not already done, and is either a
# build graph or an inspection somebody started. `<req-filter-clause>` is `--requirement`'s
# narrowing, composed by the caller because only the caller knows whether the flag was passed.
_shift_candidate_where() {
  local a="${1-r}" filt="${2-}"
  printf "EXISTS (SELECT 1 FROM graph_node gh WHERE gh.requirement_id = %s.id)
      AND %s.status <> 'done'
      AND (%s = 1 OR %s)%s" \
    "$a" "$a" "$(_shift_tier_expr "$a")" "$(_shift_started_expr "$a")" "$filt"
}

# _shift_gate_ready_expr <node-alias> — the gate is ready for a decision. Same predicate
# `guild gates`' readiness column prints and `guild gate` refuses on, one command earlier.
_shift_gate_ready_expr() {
  printf "%s" "$(_graph_ready_where "${1-n}")"
}

# ============================ the failure policy, as SQL ==============================
#
# Each of the three rules is ONE predicate, defined once and used TWICE — as the guard on
# the statement that acts, and as the SELECT that reports what would happen under
# `--dry-run`. That is what makes the dry run trustworthy: it is not a description of the
# policy, it is the policy, run with the writes left out.

# _shift_retry_where <node-alias> <filter> — §8.3 rule 1, first half: a failed work node
# this shift has not yet retried.
_shift_retry_where() {
  local a="${1-n}" filt="${2-}"
  printf "%s.kind <> 'gate' AND %s.status = 'failed'
      AND EXISTS (SELECT 1 FROM requirement r WHERE r.id = %s.requirement_id AND %s)
      AND NOT EXISTS (SELECT 1 FROM event er
                       WHERE er.subject_type = 'graph_node' AND er.verb = 'retried'
                         AND er.subject_id = %s.id AND er.ts >= %s)" \
    "$a" "$a" "$a" "$(_shift_candidate_where r "$filt")" "$a" "$(_shift_open_evt ts)"
}

# _shift_giveup_where <node-alias> <filter> — §8.3 rule 1, second half: a failed work node
# this shift ALREADY retried, and has not yet given up on.
#
# The node stays `failed` — it already is — so the mutation here is the RECORD (the event)
# and the ticket (below). Recording it once per shift is what the second NOT EXISTS buys:
# without it every later step of the same shift would re-announce the same dead bounty.
_shift_giveup_where() {
  local a="${1-n}" filt="${2-}"
  printf "%s.kind <> 'gate' AND %s.status = 'failed'
      AND EXISTS (SELECT 1 FROM requirement r WHERE r.id = %s.requirement_id AND %s)
      AND EXISTS (SELECT 1 FROM event er
                   WHERE er.subject_type = 'graph_node' AND er.verb = 'retried'
                     AND er.subject_id = %s.id AND er.ts >= %s)
      AND NOT EXISTS (SELECT 1 FROM event eg
                       WHERE eg.subject_type = 'graph_node' AND eg.verb = 'gave-up'
                         AND eg.subject_id = %s.id AND eg.ts >= %s)" \
    "$a" "$a" "$a" "$(_shift_candidate_where r "$filt")" \
    "$a" "$(_shift_open_evt ts)" "$a" "$(_shift_open_evt ts)"
}

# _shift_gap_where <task-alias> <filter> — §8.3 rule 2: an open ticket, bound to a node this
# shift is about to hand out, that NOBODY ON THE ROSTER CAN TAKE.
#
# `_roster_has_caps` and `_roster_super_where` are CALLED, so "eligible" means here exactly
# what it means in `guild match` and `guild bounties`. Restating eligibility would let the
# shift block a ticket the matcher would happily have filled.
#
# THE PIN ARM COMES FIRST AND IT MATTERS, for `guild bounties`' reason: a PINNED ticket is
# workable by definition and is never a roster gap, even when the roster cannot independently
# cover its capabilities. Blocking one would be the shift overruling a human's assignment.
#
# SCOPED TO WORK THE SHIFT WAS ACTUALLY ABOUT TO DISPATCH — a ready node in a candidate
# requirement — and not to the board at large. A shift that swept every uncoverable ticket on
# the board into `blocked` would be changing far more than its own shift, and §8.2 gives it
# no such licence.
_shift_gap_where() {
  local a="${1-t}" filt="${2-}"
  printf "%s.status = 'todo' AND COALESCE(%s.agent,'') = ''
      AND %s
      AND NOT EXISTS (SELECT 1 FROM agent ag WHERE ag.active = 1 AND %s)
      AND EXISTS (SELECT 1 FROM graph_node ng JOIN requirement r ON r.id = ng.requirement_id
                   WHERE ng.task_id = %s.id AND ng.kind <> 'gate'
                     AND ng.status IN ('pending','ready') AND %s AND %s)" \
    "$a" "$a" \
    "$(_roster_has_caps "$a.id")" \
    "$(_roster_super_where ag "$a.id")" \
    "$a" "$(_graph_ready_where ng)" "$(_shift_candidate_where r "$filt")"
}

# ============================ the stop reason, as SQL =================================

# _shift_reason_expr <now-literal> <filter> <max-tasks-literal> <max-minutes-literal> —
# §8.4's precedence, as ONE CASE. NULL means "keep going".
#
# COMPUTED IN SQL, NOT IN THE SHELL, and that is the load-bearing choice in this file. The
# step's script both RECORDS the outcome (an `ended` event or a `stepped` one) and REPORTS it
# (the `SH|` marker the renderer reads). If the shell decided, the decision would have to be
# made from markers the same script produced and then written by a SECOND round trip — two
# db_execs for one command, and a window in which a shift is over according to stdout and
# still open according to the database. One expression, evaluated inside one transaction,
# cannot disagree with itself.
#
# The budget literals are digits validated by `_shift_check_int`, or the recorded budget when
# a shift is already open. `COALESCE(recorded, passed)` is what makes the fixed-at-opening
# rule true for the reason as well as for the refusal: a resumed shift is judged against the
# ceiling it was opened with.
_shift_reason_expr() {
  local nowlit="$1" filt="$2" mt="$3" mm="$4"
  local used minutes prev prevused prevstall stall noWork readyGate mtx mmx

  used="$(_shift_used_expr)"
  minutes="$(_shift_minutes_expr "$nowlit")"
  prev="$(_shift_prev_expr payload)"
  prevused="$(_shift_json_int "$prev" used)"
  prevstall="$(_shift_json_int "$prev" stall)"

  # The stall counter: same budget spent as the previous step means nothing moved between
  # them. NULL-safe by construction — on the first step `prev` is NULL, `prevused` is NULL,
  # the equality is NULL, the CASE falls to 0.
  stall="CASE WHEN $prevused IS NOT NULL AND $prevused = $used
              THEN COALESCE($prevstall, 0) + 1 ELSE 0 END"

  noWork="NOT EXISTS (SELECT 1 FROM requirement r
                       WHERE $(_shift_candidate_where r "$filt")
                         AND $(_shift_ready_work_expr r) > 0)"

  readyGate="EXISTS (SELECT 1 FROM gate g
                       JOIN graph_node n ON n.id = g.node_id
                       JOIN requirement r ON r.id = n.requirement_id
                      WHERE n.status NOT IN ('done','skipped')
                        AND $(_shift_gate_ready_expr n)
                        AND $(_shift_candidate_where r "$filt"))"

  mtx="COALESCE($(_shift_json_int "$(_shift_open_evt payload)" max_tasks), $mt)"
  mmx="COALESCE($(_shift_json_int "$(_shift_open_evt payload)" max_minutes), $mm)"

  printf "CASE
            WHEN (%s) AND (%s) THEN 'gate'
            WHEN (%s) >= 2 THEN 'infrastructure'
            WHEN (%s) >= (%s) THEN 'max-tasks'
            WHEN (%s) >= (%s) THEN 'max-minutes'
            WHEN (%s) THEN 'idle'
          END" \
    "$noWork" "$readyGate" "$stall" "$used" "$mtx" "$minutes" "$mmx" "$noWork"
}

# _shift_budget_ok <max-tasks-literal> <max-minutes-literal> <passed-tasks> <passed-minutes>
# — "the caller is not trying to move the ceiling of a shift already in progress".
#
# `<passed-*>` are 1 when the flag was given on THIS invocation and 0 otherwise; only a flag
# that was actually passed can conflict. Vacuously true when no shift is open (the recorded
# value is NULL) — which is the turn that SETS the budget.
_shift_budget_ok() {
  local mt="$1" mm="$2" gotmt="$3" gotmm="$4" rec_mt rec_mm out
  rec_mt="$(_shift_json_int "$(_shift_open_evt payload)" max_tasks)"
  rec_mm="$(_shift_json_int "$(_shift_open_evt payload)" max_minutes)"
  out="1 = 1"
  [ "$gotmt" = 0 ] || out="$out AND ($rec_mt IS NULL OR $rec_mt = $mt)"
  [ "$gotmm" = 0 ] || out="$out AND ($rec_mm IS NULL OR $rec_mm = $mm)"
  printf '%s' "$out"
}

# ============================ guild shift — the step ==================================
#
# THE MARKER CHANNEL — the step's rows come back as pipe-separated marker lines:
#
#   SH|<open>|<id>|<started>|<step>|<used>|<max-tasks>|<minutes>|<max-minutes>|<reason>
#   SJ|<json-id>|<json-started>           the reason is NOT here — see step 7 for why
#   RUN|<req>|<template>|<status>|<priority>|<ready>|<running>|<failed>
#      |<jreq>|<jtemplate>|<jstatus>|<jbranch>
#   RT|<req>|<title>                 the requirement's title  (free text, LAST)
#   GT|<node>|<kind>|<gstatus>|<ready>|<req>|<jnode>|<jkind>|<jgstatus>|<jreq>
#   GP|<node>|<prompt>               the gate's prompt        (free text, LAST)
#   ACT|<verb>|<id>|<json-id>        what the failure policy DID this step
#   WOULD|<verb>|<id>|<json-id>      what it WOULD do   (--dry-run only)
#   BUDGET|<recorded-tasks>|<recorded-minutes>   the refusal marker
#
# THE ONLY FIELD THAT MAY CONTAIN A PIPE IS THE LAST ONE, and every reader splits on a FIXED
# number of leading delimiters. That is why the two genuinely free-text values — the
# requirement's title and the gate's prompt — get LINES OF THEIR OWN keyed by id, rather than
# two more fields on a line where only one of them could have been last. lib/segment.sh's
# discipline, unchanged, because it is the same channel.

# _shift_sql <mode> <write> <now-literal> <id-literal> <filter> <mt> <mm> <gotmt> <gotmm>
#            <requirement-or-empty> — THE WHOLE STEP, as one script.
#
# <mode> selects the PROJECTION of the two free-text values only — `_brief_txt` for the human
# surface, `_seg_json_str` for the machine one — exactly as `_brief_sql` and `_seg_sql` do.
# <write> is 0 for `--dry-run`, which turns every mutation into the SELECT that reports what
# it would have done.
#
# THE STATEMENT ORDER IS LOAD-BEARING, and there are three separate reasons for it:
#
#   1. THE POLICY MUTATIONS COME BEFORE THE READS. A retry turns a `failed` node back to
#      `pending`, and a roster-gap block takes a ready node out of the running; both change
#      what is runnable. The directive must describe the board AFTER the policy ran, or the
#      orchestrator would be handed work the shift just withdrew.
#
#   2. THE READS COME BEFORE THE CLOSE. `ended` is what makes a shift stop being the open
#      one, so every fragment built on `_shift_open_evt` — the id, the clock, the budget, the
#      step number — goes NULL the instant it lands. All of them are read first.
#
#   3. NO `UPDATE` READS ITS OWN TABLE. §3.0's matrix is an allowlist and a subquery over the
#      table being updated has no row on it; the CLI has verified self-referencing subqueries
#      in INSERT and none in UPDATE, and this file does not introduce the first. So each pair
#      is EVENT FIRST, ROW SECOND, and the row's guard is a WITNESS of the event that just
#      landed — matched on `ts = <this run's timestamp>`, so it can never fire off a decision
#      an earlier run made. That is `cmd_gate`'s step-3/step-4 pattern, applied three times.
_shift_sql() {
  local mode="$1" write="$2" nowlit="$3" idlit="$4" filt="$5"
  local mt="$6" mm="$7" gotmt="$8" gotmm="$9" scopelit
  local actorlit go reason openid started rec_mt rec_mm txt
  local usedx minx stepx prev prevstall stallx

  # The requirement `--requirement` scoped this shift to, recorded in the `started` and
  # `ended` payloads so the morning brief can say what the shift was pointed at. It already
  # passed `_graph_check_req`, so sql_str; '' becomes NULL through NULLIF at the call site.
  scopelit="$(sql_str "${10-}")"

  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  openid="$(_shift_open_evt subject_id)"
  started="$(_shift_open_evt ts)"
  rec_mt="$(_shift_json_int "$(_shift_open_evt payload)" max_tasks)"
  rec_mm="$(_shift_json_int "$(_shift_open_evt payload)" max_minutes)"
  usedx="$(_shift_used_expr)"
  minx="$(_shift_minutes_expr "$nowlit")"
  stepx="$(_shift_step_expr)"
  prev="$(_shift_prev_expr payload)"
  prevstall="$(_shift_json_int "$prev" stall)"
  stallx="CASE WHEN $(_shift_json_int "$prev" used) IS NOT NULL
                AND $(_shift_json_int "$prev" used) = $usedx
           THEN COALESCE($prevstall, 0) + 1 ELSE 0 END"
  reason="$(_shift_reason_expr "$nowlit" "$filt" "$mt" "$mm")"
  go="$(_shift_budget_ok "$mt" "$mm" "$gotmt" "$gotmm")"

  if [ "$write" = 1 ]; then
    printf 'BEGIN;\n'
  fi

  # ---- 1. open the shift, if none is open ------------------------------------------
  #
  # The one statement that carries no budget guard, because it is the statement that SETS
  # the budget. `SELECT <values> WHERE NOT EXISTS (…)` over `event` is the shape schema.sql
  # and lib/roster.sh already use; the guard is what makes a second concurrent `guild shift`
  # resume this shift rather than open a rival one.
  if [ "$write" = 1 ]; then
    printf "INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT %s, %s, 'started', 'shift', %s,
       json_object('max_tasks', %s, 'max_minutes', %s, 'requirement', NULLIF(%s, ''))
 WHERE %s IS NULL;\n" \
      "$nowlit" "$actorlit" "$idlit" "$mt" "$mm" "$scopelit" "$openid"
  fi

  # ---- 2. the budget-change refusal marker -----------------------------------------
  printf "SELECT 'BUDGET|' || COALESCE(%s, -1) || '|' || COALESCE(%s, -1)
 WHERE %s IS NOT NULL AND NOT (%s);\n" "$rec_mt" "$rec_mm" "$openid" "$go"

  # ---- 3-5. THE FAILURE POLICY (§8.3) ------------------------------------------------
  #
  # EACH RULE IS EMITTED ONLY IF `_shift_policy` PERMITS IT. That is what makes §8.2 a table
  # the code obeys rather than a comment beside code that does something else: move
  # `retry-task` to the NOT column and the retry statements stop being generated, here and
  # in the dry run, in one edit.
  # ---- 3. §8.3 rule 1a — retry once, with a fresh agent -------------------------------
  if _shift_may retry-task; then
    if [ "$write" = 1 ]; then
      printf "INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT %s, %s, 'retried', 'graph_node', n.id,
       json_object('shift', %s, 'requirement', n.requirement_id, 'node_key', n.node_key,
                   'attempt', 2, 'task', n.task_id)
  FROM graph_node n WHERE %s AND (%s);\n" \
        "$nowlit" "$actorlit" "$openid" "$(_shift_retry_where n "$filt")" "$go"

      # THE WITNESS, NOT THE PREDICATE AGAIN. The row moves because the event above LANDED,
      # matched on this run's timestamp — so this UPDATE can never fire off a retry an
      # earlier run recorded, and its guard reads a table it does not write (`cmd_gate`'s
      # step-3/step-4 rule). `IN (SELECT …)` rather than a correlated EXISTS naming
      # `graph_node` back: an uncorrelated subquery over `event` is the shape
      # lib/graph.sh and lib/roster.sh already use inside an UPDATE, and it keeps the
      # target table out of its own guard entirely.
      printf "UPDATE graph_node SET status = 'pending'
 WHERE id IN (SELECT ew.subject_id FROM event ew
               WHERE ew.subject_type = 'graph_node' AND ew.verb = 'retried'
                 AND ew.ts = %s)
RETURNING 'R|graph_node|upsert|' || %s;\n" "$nowlit" "$(_art_json_row graph_node)"
    else
      printf "SELECT 'WOULD|retried|' || %s || '|' || %s FROM graph_node n
 WHERE %s ORDER BY n.id;\n" \
        "$(_graph_field 'n.id')" "$(_seg_json_str 'n.id')" "$(_shift_retry_where n "$filt")"
    fi
  fi

  # ---- 4. §8.3 rule 1b — give up, and fail the ticket ---------------------------------
  #
  # The node is already `failed`; what changes is the RECORD and the TICKET. A ticket left
  # `in-progress` behind a dead node is a lie the board tells every reader — `guild board`,
  # `guild brief`, `guild bounties` — and §8.2 puts "mark tasks failed and move on" in the
  # MAY column precisely so the shift can stop telling it.
  if _shift_may fail-task; then
    if [ "$write" = 1 ]; then
      printf "INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT %s, %s, 'gave-up', 'graph_node', n.id,
       json_object('shift', %s, 'requirement', n.requirement_id, 'node_key', n.node_key,
                   'reason', 'failed twice', 'task', n.task_id)
  FROM graph_node n WHERE %s AND (%s);\n" \
        "$nowlit" "$actorlit" "$openid" "$(_shift_giveup_where n "$filt")" "$go"

      # `done`, `failed` and `waived` are excluded on the target's OWN columns: a ticket that
      # already finished is not retroactively failed because one of its nodes gave up, and a
      # waived one was waived deliberately. A NULL `task_id` in the list is harmless — `IN`
      # simply never matches it, which is the right answer for an unbound node.
      printf "UPDATE task SET status = 'failed', updated_at = %s
 WHERE status NOT IN ('done','failed','waived')
   AND id IN (SELECT ng.task_id FROM event ew JOIN graph_node ng ON ng.id = ew.subject_id
               WHERE ew.subject_type = 'graph_node' AND ew.verb = 'gave-up'
                 AND ew.ts = %s)
RETURNING 'R|task|upsert|' || %s;\n" "$nowlit" "$nowlit" "$(_art_json_row task)"
    else
      printf "SELECT 'WOULD|gave-up|' || %s || '|' || %s FROM graph_node n
 WHERE %s ORDER BY n.id;\n" \
        "$(_graph_field 'n.id')" "$(_seg_json_str 'n.id')" "$(_shift_giveup_where n "$filt")"
    fi
  fi

  # ---- 5. §8.3 rule 2 — no eligible agent: block, and continue ------------------------
  if _shift_may block-task; then
    if [ "$write" = 1 ]; then
      printf "INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT %s, %s, 'blocked', 'task', t.id,
       json_object('shift', %s, 'requirement', t.requirement_id,
                   'reason', 'no-eligible-agent', 'from', t.status, 'to', 'blocked')
  FROM task t WHERE %s AND (%s);\n" \
        "$nowlit" "$actorlit" "$openid" "$(_shift_gap_where t "$filt")" "$go"

      printf "UPDATE task SET status = 'blocked', updated_at = %s
 WHERE id IN (SELECT ew.subject_id FROM event ew
               WHERE ew.subject_type = 'task' AND ew.verb = 'blocked'
                 AND ew.ts = %s)
RETURNING 'R|task|upsert|' || %s;\n" "$nowlit" "$nowlit" "$(_art_json_row task)"
    else
      printf "SELECT 'WOULD|blocked|' || %s || '|' || %s FROM task t
 WHERE %s ORDER BY t.id;\n" \
        "$(_graph_field 't.id')" "$(_seg_json_str 't.id')" "$(_shift_gap_where t "$filt")"
    fi
  fi

  # ---- 6. what the policy DID, by id --------------------------------------------------
  #
  # Read back from the events this run just wrote, witnessed by the timestamp — the same
  # trick the two UPDATE guards use, so the report and the mutation cannot describe
  # different rows.
  if [ "$write" = 1 ]; then
    printf "SELECT 'ACT|' || %s || '|' || %s || '|' || %s
  FROM event ea
 WHERE ea.ts = %s AND ea.verb IN ('retried','gave-up','blocked')
 ORDER BY ea.verb, ea.subject_id;\n" \
      "$(_graph_field 'ea.verb')" "$(_graph_field 'ea.subject_id')" \
      "$(_seg_json_str 'ea.subject_id')" "$nowlit"
  fi

  # ---- 7. the shift's own numbers ---------------------------------------------------
  #
  # Emitted whether or not a shift is open: under `--dry-run` with nothing running, this is
  # the answer to "what would a shift do if I started one now", which is the question the
  # flag exists for.
  printf "SELECT 'SH|' || (CASE WHEN %s IS NULL THEN '0' ELSE '1' END)
            || '|' || COALESCE(%s, %s) || '|' || COALESCE(%s, %s)
            || '|' || (%s) || '|' || (%s) || '|' || COALESCE(%s, %s)
            || '|' || (%s) || '|' || COALESCE(%s, %s)
            || '|' || COALESCE(%s, '-');\n" \
    "$openid" \
    "$(_graph_field "$openid")" "$idlit" \
    "$(_graph_field "$started")" "$nowlit" \
    "$stepx" "$usedx" "$rec_mt" "$mt" \
    "$minx" "$rec_mm" "$mm" \
    "$reason"

  # The shift id and the clock as JSON literals; the REASON is not among them, and that is
  # the one deliberate exemption from THE JSON CHANNEL's rule in this file. A reason is a
  # word from `_shift_reasons` — a closed vocabulary this file defines and this file's own
  # CASE produces — so awk may quote it directly, exactly as `_brief_fact_select` emits its
  # fixed key names. The exemption also costs nothing to justify and saves a great deal:
  # `_seg_json_str` evaluates its argument TWICE, and the reason expression is the largest
  # in the file.
  printf "SELECT 'SJ|' || %s || '|' || %s;\n" \
    "$(_seg_json_str "COALESCE($openid, $idlit)")" \
    "$(_seg_json_str "COALESCE($started, $nowlit)")"

  # ---- 8. the requirement this step hands out --------------------------------------
  #
  # ONE row: the first candidate with runnable work, in §8.1's order — tier, then the
  # board's own priority, then id. A shift works one requirement per step, because the
  # batches inside it are `guild segment`'s answer and dispatching across two requirements
  # at once is concurrency nobody asserted the file-disjointness of.
  printf "SELECT 'RUN|' || %s || '|' || %s || '|' || %s || '|' || %s || '|' || (%s)
            || '|' || (%s) || '|' || (%s)
            || '|' || %s || '|' || %s || '|' || %s || '|' || %s
  FROM requirement r
 WHERE %s AND %s > 0
 ORDER BY %s, r.priority, r.id LIMIT 1;\n" \
    "$(_graph_field 'r.id')" "$(_graph_field "$(_shift_template_expr r)")" \
    "$(_graph_field 'r.status')" "$(_graph_field 'r.priority')" \
    "$(_shift_ready_work_expr r)" \
    "$(_shift_node_count_expr r running)" "$(_shift_node_count_expr r failed)" \
    "$(_seg_json_str 'r.id')" "$(_seg_json_str "$(_shift_template_expr r)")" \
    "$(_seg_json_str 'r.status')" "$(_seg_json_str "'guild/' || r.id")" \
    "$(_shift_candidate_where r "$filt")" "$(_shift_ready_work_expr r)" \
    "$(_shift_tier_expr r)"

  # ---- 9. the gate the shift stops at (or would stop at next) -----------------------
  #
  # A READY gate sorts before a waiting one, because a ready gate is the one actually
  # awaiting the guild master — the distinction `guild gates`' readiness column exists to
  # make, and the one `guild gate` refuses on.
  printf "SELECT 'GT|' || %s || '|' || %s || '|' || %s
            || '|' || (CASE WHEN %s THEN 'ready' ELSE 'waiting' END)
            || '|' || %s || '|' || %s || '|' || %s || '|' || %s || '|' || %s
  FROM gate g JOIN graph_node n ON n.id = g.node_id
              JOIN requirement r ON r.id = n.requirement_id
 WHERE n.status NOT IN ('done','skipped') AND %s
 ORDER BY (CASE WHEN %s THEN 0 ELSE 1 END), %s, r.priority, n.id LIMIT 1;\n" \
    "$(_graph_field 'n.id')" "$(_graph_field 'g.kind')" "$(_graph_field 'g.status')" \
    "$(_shift_gate_ready_expr n)" \
    "$(_graph_field 'r.id')" \
    "$(_seg_json_str 'n.id')" "$(_seg_json_str 'g.kind')" "$(_seg_json_str 'g.status')" \
    "$(_seg_json_str 'r.id')" \
    "$(_shift_candidate_where r "$filt")" \
    "$(_shift_gate_ready_expr n)" "$(_shift_tier_expr r)"

  # ---- 10. the two free-text values, each ALONE on its own line and LAST on it ------
  if [ "$mode" = json ]; then
    txt="$(_seg_json_str 'r.title')"
  else
    txt="$(_brief_txt 'r.title' 90)"
  fi
  printf "SELECT 'RT|' || %s || '|' || %s FROM requirement r
 WHERE %s ORDER BY %s, r.priority, r.id;\n" \
    "$(_graph_field 'r.id')" "$txt" "$(_shift_candidate_where r "$filt")" \
    "$(_shift_tier_expr r)"

  if [ "$mode" = json ]; then
    txt="$(_seg_json_str 'g.prompt')"
  else
    txt="$(_brief_txt 'g.prompt' 300)"
  fi
  printf "SELECT 'GP|' || %s || '|' || %s
  FROM gate g JOIN graph_node n ON n.id = g.node_id
              JOIN requirement r ON r.id = n.requirement_id
 WHERE n.status NOT IN ('done','skipped') AND %s ORDER BY n.id;\n" \
    "$(_graph_field 'n.id')" "$txt" "$(_shift_candidate_where r "$filt")"

  if [ "$write" = 1 ]; then
    # ---- 11. the close, then the step ----------------------------------------------
    #
    # EXACTLY ONE OF THESE TWO FIRES, and the SQL is what decides — see `_shift_reason_expr`.
    # The order is what enforces the exclusivity for free: `ended` closes the shift, so by
    # the time `stepped` is evaluated `$openid` is NULL and its guard cannot hold. Its
    # `reason IS NULL` clause is the second lock on the same door, kept because the failure
    # it prevents is a shift that is simultaneously over and mid-step.
    printf "INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT %s, %s, 'ended', 'shift', %s,
       json_object('reason', (%s), 'tasks', (%s), 'minutes', (%s), 'steps', (%s) - 1,
                   'requirement', NULLIF(%s, ''), 'note', NULL)
 WHERE %s IS NOT NULL AND (%s) AND (%s) IS NOT NULL;\n" \
      "$nowlit" "$actorlit" "$openid" "$reason" "$usedx" "$minx" "$stepx" \
      "$scopelit" "$openid" "$go" "$reason"

    printf "INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT %s, %s, 'stepped', 'shift', %s,
       json_object('step', (%s), 'used', (%s), 'minutes', (%s), 'stall', (%s),
                   'requirement', (SELECT r.id FROM requirement r
                                    WHERE %s AND %s > 0
                                    ORDER BY %s, r.priority, r.id LIMIT 1))
 WHERE %s IS NOT NULL AND (%s) AND (%s) IS NULL;\n" \
      "$nowlit" "$actorlit" "$openid" "$stepx" "$usedx" "$minx" "$stallx" \
      "$(_shift_candidate_where r "$filt")" "$(_shift_ready_work_expr r)" \
      "$(_shift_tier_expr r)" \
      "$openid" "$go" "$reason"

    printf 'COMMIT;\n'
  fi
}

# _shift_awk — the renderer, both surfaces, one program.
#
# `-v MODE=text|json`, because the assembly is the part worth getting right once. It reads
# ONE input, the marker file, and every line is told apart by its leading token — a closed
# alphabet this file writes, never a value.
#
# `tailafter(s, k)` walks past exactly k delimiters and returns the rest VERBATIM: how a gate
# prompt containing a pipe survives. The leading fields come from `split`, which over-splits
# that tail into fields nobody reads.
#
# THE JSON SURFACE, AGAIN: not one value below is written by this program. Every string is a
# complete JSON literal the engine produced (`_seg_json_str`). awk contributes brackets,
# commas, the fixed key names, integers it parsed from the driver's own digits, and
# `true`/`false`. A value that could forge a token in this document does not corrupt a
# report — it changes what an unattended orchestrator does next.
_shift_awk() {
  cat <<'SHIFTAWK'
function tailafter(s, k,   i, p) {
  for (i = 1; i <= k; i++) { p = index(s, "|"); if (p == 0) return ""; s = substr(s, p + 1) }
  return s
}
# jstr(v) — a stop reason as a JSON literal, or `null`.
#
# THE ONE PLACE THIS PROGRAM QUOTES A VALUE ITSELF, and it is safe for a reason that has to
# be checked rather than assumed: `v` is only ever a word from `_shift_reasons` — the closed
# vocabulary lib/shift.sh defines and lib/shift.sh's own CASE produces — so it holds no
# quote, no backslash and no control character. It is validated against that same list on
# the way IN (`_shift_check_reason`) and produced from a literal CASE on the way out, so
# there is no path by which a board value reaches it. Every OTHER string in this document
# arrives already escaped from the engine.
function jstr(v) {
  if (v == "") return "null"
  return "\"" v "\""
}

BEGIN { nact = 0; haverun = 0; havegate = 0 }

substr($0, 1, 7) == "BUDGET|" { split($0, p, "|"); bmt = p[2]; bmm = p[3]; next }

substr($0, 1, 3) == "SH|" {
  split($0, p, "|")
  isopen = p[2] + 0; sid = p[3]; sstarted = p[4]; sstep = p[5] + 0; sused = p[6] + 0
  smaxt = p[7] + 0; smin = p[8] + 0; smaxm = p[9] + 0
  sreason = (p[10] == "-" ? "" : p[10])
  next
}
substr($0, 1, 3) == "SJ|" { split($0, p, "|"); jid = p[2]; jstarted = p[3]; next }

substr($0, 1, 4) == "RUN|" {
  split($0, p, "|")
  haverun = 1
  rid = p[2]; rtpl = p[3]; rstat = p[4]; rprio = p[5] + 0
  rready = p[6] + 0; rrunning = p[7] + 0; rfailed = p[8] + 0
  jrid = p[9]; jrtpl = p[10]; jrstat = p[11]; jrbranch = p[12]
  next
}
substr($0, 1, 3) == "RT|" { split($0, p, "|"); rtitle[p[2]] = tailafter($0, 2); next }

substr($0, 1, 3) == "GT|" {
  split($0, p, "|")
  havegate = 1
  gnode = p[2]; gkind = p[3]; gstat = p[4]; gready = p[5]; greq = p[6]
  jgnode = p[7]; jgkind = p[8]; jgstat = p[9]; jgreq = p[10]
  next
}
substr($0, 1, 3) == "GP|" { split($0, p, "|"); gprompt[p[2]] = tailafter($0, 2); next }

substr($0, 1, 4) == "ACT|" {
  split($0, p, "|")
  nact++; averb[nact] = p[2]; aid[nact] = p[3]; ajid[nact] = p[4]; adid[nact] = 1
  next
}
substr($0, 1, 6) == "WOULD|" {
  split($0, p, "|")
  nact++; averb[nact] = p[2]; aid[nact] = p[3]; ajid[nact] = p[4]; adid[nact] = 0
  next
}

END {
  if (bmt != "") {
    # The budget-change refusal. Emitted as a line the shell recognizes rather than as a
    # sentence, so the message — which has to name the recorded ceiling — is composed
    # where the ceiling's provenance is known.
    printf("!BUDGET|%s|%s\n", bmt, bmm)
    exit 3
  }
  action = (sreason == "" ? "run" : "stop")
  if (MODE == "json") { emit_json() } else { emit_text() }
}

# ---- the machine surface ------------------------------------------------------------
function emit_json(   i, first) {
  print "{"
  printf("  \"shift\": %s,\n", (jid == "" ? "null" : jid))
  printf("  \"open\": %s,\n", (isopen ? "true" : "false"))
  printf("  \"started\": %s,\n", (jstarted == "" ? "null" : jstarted))
  printf("  \"step\": %d,\n", sstep)
  printf("  \"action\": \"%s\",\n", action)
  printf("  \"reason\": %s,\n", jstr(sreason))
  printf("  \"dry_run\": %s,\n", (DRY ? "true" : "false"))
  printf("  \"budget\": { \"tasks_used\": %d, \"max_tasks\": %d, \"minutes_used\": %d, \"max_minutes\": %d },\n",
         sused, smaxt, smin, smaxm)

  if (!haverun) {
    print "  \"requirement\": null,"
    print "  \"segment_command\": null,"
    print "  \"branch\": null,"
  } else {
    print "  \"requirement\": {"
    printf("    \"id\": %s,\n", jrid)
    printf("    \"title\": %s,\n", (rid in rtitle ? rtitle[rid] : "null"))
    printf("    \"template\": %s,\n", jrtpl)
    printf("    \"status\": %s,\n", jrstat)
    printf("    \"priority\": %d,\n", rprio)
    printf("    \"runnable_nodes\": %d,\n", rready)
    printf("    \"running_nodes\": %d,\n", rrunning)
    printf("    \"failed_nodes\": %d\n", rfailed)
    print "  },"
    printf("  \"segment_command\": [\"segment\", %s, \"--json\"],\n", jrid)
    printf("  \"branch\": %s,\n", jrbranch)
  }

  if (!havegate) {
    print "  \"next_gate\": null,"
  } else {
    print "  \"next_gate\": {"
    printf("    \"node\": %s,\n", jgnode)
    printf("    \"requirement\": %s,\n", jgreq)
    printf("    \"kind\": %s,\n", jgkind)
    printf("    \"status\": %s,\n", jgstat)
    printf("    \"ready\": %s,\n", (gready == "ready" ? "true" : "false"))
    printf("    \"prompt\": %s\n", (gnode in gprompt ? gprompt[gnode] : "null"))
    print "  },"
  }

  printf("  \"policy_actions\": [")
  first = 1
  for (i = 1; i <= nact; i++) {
    printf("%s\n    { \"action\": \"%s\", \"subject\": %s, \"applied\": %s }",
           (first ? "" : ","), averb[i], ajid[i], (adid[i] ? "true" : "false"))
    first = 0
  }
  printf("%s],\n", (first ? "" : "\n  "))

  # The notification §8.5 asks for — "a push notification on gate arrival, the one moment
  # the guild genuinely needs you". STRUCTURED, NOT A SENTENCE, and that is the rule-4
  # decision rather than a style one: a sentence would have to be concatenated here, in awk,
  # out of values that arrived as JSON literals, and awk splicing a value into a string is
  # exactly the escaper this file does not have. The notifier composes the prose; this emits
  # the facts, each still the literal the engine produced.
  if (action == "stop" && sreason == "gate" && havegate) {
    print "  \"notify\": {"
    print "    \"kind\": \"gate\","
    printf("    \"requirement\": %s,\n", jgreq)
    printf("    \"node\": %s,\n", jgnode)
    printf("    \"gate_kind\": %s\n", jgkind)
    print "  }"
  } else if (action == "stop") {
    print "  \"notify\": {"
    print "    \"kind\": \"ended\","
    printf("    \"shift\": %s,\n", (jid == "" ? "null" : jid))
    printf("    \"reason\": %s\n", jstr(sreason))
    print "  }"
  } else {
    print "  \"notify\": null"
  }
  print "}"
}

# ---- the human surface --------------------------------------------------------------
function emit_text(   i, head, bar, lbl) {
  head = "Shift " sid " — " (action == "run" ? "step " sstep : "ended")
  print head
  bar = ""
  for (i = 0; i < length(head); i++) bar = bar "="
  print bar
  print ""
  if (DRY) {
    print "DRY RUN — nothing below was written, dispatched or decided."
    print ""
  }

  printf("action       %s\n", action)
  if (action == "stop") printf("reason       %s\n", sreason)
  printf("budget       %d/%d task(s) · %d/%d minute(s)\n", sused, smaxt, smin, smaxm)

  if (haverun) {
    printf("requirement  %s [%s] %s, priority %d\n", rid, rstat, rtpl, rprio)
    if (rid in rtitle) printf("             %s\n", rtitle[rid])
    printf("runnable     %d node(s) ready now", rready)
    if (rrunning > 0) printf(" · %d still running", rrunning)
    if (rfailed > 0)  printf(" · %d failed", rfailed)
    print ""
    printf("branch       guild/%s\n", rid)
  }
  if (havegate) {
    printf("next gate    %s (%s, %s, %s)\n", gnode, gkind, gstat, gready)
    if (gnode in gprompt) printf("             %s\n", gprompt[gnode])
  }

  if (nact > 0) {
    print ""
    print (DRY ? "The failure policy WOULD:" : "The failure policy, this step:")
    for (i = 1; i <= nact; i++) {
      lbl = averb[i]
      if (lbl == "retried") lbl = "retry"
      else if (lbl == "gave-up") lbl = "give up on"
      else if (lbl == "blocked") lbl = "block"
      printf("  %-12s %s\n", lbl, aid[i])
    }
    print "  retry: one fresh agent instance, same ticket, same member (design 8.3)"
    print "  give up: the node stays failed and its ticket is failed with it"
    print "  block: nobody on the roster is eligible — a roster gap, in 'guild brief'"
  }

  print ""
  if (action == "run") {
    print "Do this, then run 'guild shift' again:"
    printf("  guild git branch-for %s      once per requirement, before any code\n", rid)
    printf("  guild segment %s --json      the batches, in order — dispatch batch 1\n", rid)
    print "  guild node <NODE-ID> running --task TASK-NNN"
    print "  guild node <NODE-ID> done | failed"
    print "  guild git commit-task TASK-NNN   on done · revert-task on failed (design 8.6)"
    print ""
    print "MAY NOT: approve or pass a gate, close a requirement past one, delete anything,"
    print "push, commit to the default branch, change goals or priorities, create an agent."
    print "  guild shift --policy        the full table"
    if (DRY) {
      print ""
      print "Nothing has started. Drop --dry-run to open the shift."
    }
    exit 0
  }

  # ---- the stop ---------------------------------------------------------------------
  printf("Worked %d task(s) over %d minute(s), %d step(s).\n", sused, smin, sstep - 1)
  print ""
  if (sreason == "gate" && havegate) {
    print "The one decision a subagent cannot make (design 6.4):"
    if (gkind == "select-findings")
      printf("  guild gate %s --approve --decision 'F-12,F-14'   (or --decision none)\n", gnode)
    else
      printf("  guild gate %s --approve\n", gnode)
    printf("  guild gate %s --reject --decision 'why'\n", gnode)
  } else if (sreason == "infrastructure") {
    print "The loop stopped progressing: two steps in a row moved no node. Something is"
    print "dispatching and not reporting back, or every ticket is unrunnable for a reason"
    print "the graph cannot see."
    printf("  guild graph %s              which node is holding it\n", (haverun ? rid : "REQ-NNN"))
    print "  guild bounties               what cannot be worked, and why"
  } else if (sreason == "max-tasks" || sreason == "max-minutes") {
    print "A ceiling, not a fault — the shift stopped where you told it to."
    print "  guild shift --max-tasks 20 --max-minutes 120     a longer one"
  } else if (sreason == "idle") {
    print "Nothing was runnable and no gate was waiting. An idle shift ends idle rather"
    print "than inventing work: a shift never starts an inspection (design 6.2, 8.1)."
    print "  guild bounties               what is open, and what is blocked"
    print "  guild gates --pending        decisions waiting on you"
  }
  print ""
  print "  guild shift-report           what happened while you were away"
  print "  guild brief                  where the project stands now"
}
SHIFTAWK
}

# cmd_shift [--max-tasks N] [--max-minutes M] [--requirement REQ-NNN] [--dry-run] [--json]
#           | --end [--reason R] [--note "..."] | --policy [--json]
#
# ONE db_exec for a step, one for `--end`, none for `--policy`.
#
# EXIT STATUS. 0 for a step and 0 for a clean stop — "the shift is over" is an answer, not a
# failure, and the reason is in the directive and in the `event` row rather than encoded in a
# number a caller would have to guess the meaning of. The non-zero exits are refusals: an
# unparseable flag, a budget the caller tried to move mid-shift, `--end` with no shift open.
cmd_shift() {
  local mode="text" dry=0 want_end=0 want_policy=0
  local mt="" mm="" req="" reason="" note="" have_note=0
  local gotmt=0 gotmm=0 now nowlit idlit filt sqlf rows outf rc=0 a b

  while [ $# -gt 0 ]; do
    case "$1" in
      --json)     mode="json" ;;
      --dry-run)  dry=1 ;;
      --policy)   want_policy=1 ;;
      --end)      want_end=1 ;;
      --max-tasks)   shift; mt="${1-}";   gotmt=1; [ $# -eq 0 ] || shift; continue ;;
      --max-tasks=*) mt="${1#--max-tasks=}"; gotmt=1 ;;
      --max-minutes)   shift; mm="${1-}"; gotmm=1; [ $# -eq 0 ] || shift; continue ;;
      --max-minutes=*) mm="${1#--max-minutes=}"; gotmm=1 ;;
      --requirement)   shift; req="${1-}"; [ $# -eq 0 ] || shift; continue ;;
      --requirement=*) req="${1#--requirement=}" ;;
      --reason)   shift; reason="${1-}"; [ $# -eq 0 ] || shift; continue ;;
      --reason=*) reason="${1#--reason=}" ;;
      --note)   shift; note="${1-}"; have_note=1; [ $# -eq 0 ] || shift; continue ;;
      --note=*) note="${1#--note=}"; have_note=1 ;;
      -*)
        die "guild: unknown option '$1' for shift.

  guild shift [--max-tasks N] [--max-minutes M] [--requirement REQ-NNN] [--dry-run] [--json]
  guild shift --end [--reason $(_shift_reasons | tr ' ' '|')] [--note '...']
  guild shift --policy"
        ;;
      *)
        die "guild: shift takes no positional arguments (got '$(_render_flat_arg "$1")').

Did you mean --requirement?

  guild shift --requirement $(_render_flat_arg "$1")"
        ;;
    esac
    shift
  done

  # ---- guild shift --policy ---------------------------------------------------------
  #
  # Answered without touching the database, deliberately: the contract an unattended run
  # operates under must be readable on a machine with no board at all.
  if [ "$want_policy" = 1 ]; then
    [ "$want_end" = 0 ] ||
      die "guild: --policy and --end are different questions — ask one"
    if [ "$mode" = json ]; then _shift_policy_json; else _shift_policy_text; fi
    return 0
  fi

  # ---- guild shift --end ------------------------------------------------------------
  if [ "$want_end" = 1 ]; then
    [ "$dry" = 0 ] ||
      die "guild: --end --dry-run would be a shift that is over and also not over. Pick one."
    [ "$gotmt" = 0 ] && [ "$gotmm" = 0 ] ||
      die "guild: --end takes no budget. The budget belongs to the shift that is ending,
and it was fixed when that shift opened."
    [ -n "$reason" ] || reason="operator"
    _shift_check_reason "$reason"
    _shift_end "$reason" "$note" "$have_note" "$mode"
    return $?
  fi

  [ -z "$reason" ] ||
    die "guild: --reason belongs to 'guild shift --end' — a running shift's reason is not
something you assert, it is what the stop condition turned out to be (design 8.4)."
  [ "$have_note" = 0 ] ||
    die "guild: --note belongs to 'guild shift --end'"

  # ---- the defaults (§8.4) ----------------------------------------------------------
  [ -n "$mt" ] || mt="10"
  [ -n "$mm" ] || mm="60"
  _shift_check_int "$mt" "--max-tasks"
  _shift_check_int "$mm" "--max-minutes"

  # §8.2's CENTRAL DENIAL, ASSERTED RATHER THAN ASSUMED. Everything below is built on "a
  # gate is where the shift stops", and that is true only because the policy table forbids
  # deciding one. If either row ever moved to the MAY column, this file would need a
  # decision-maker it does not have and cannot have — only the orchestrator session can ask
  # the guild master anything (§6.4). Fail loudly at the top rather than behave differently
  # at the bottom.
  if _shift_may approve-gate || _shift_may pass-gate; then
    die "guild: the shift policy table permits a gate decision, and nothing in this CLI can
make one on the guild master's behalf (design 6.4, 8.2). Fix _shift_policy in lib/shift.sh."
  fi

  filt=""
  if [ -n "$req" ]; then
    _graph_check_req "$req"
    filt=$'\n      AND r.id = '"$(sql_str "$req")"
  fi

  db_require_init
  [ "$dry" = 1 ] || journal_preflight

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  idlit="$(sql_str "$(_shift_id "$now")")"

  sqlf="$(_shift_tmp sql)"
  rows="$(_shift_tmp rows)"
  if [ "$dry" = 1 ]; then
    _shift_sql "$mode" 0 "$nowlit" "$idlit" "$filt" "$mt" "$mm" "$gotmt" "$gotmm" "$req" >"$sqlf"
    _render_query "$sqlf" "$rows" "guild: could not read the shift"
  else
    _shift_sql "$mode" 1 "$nowlit" "$idlit" "$filt" "$mt" "$mm" "$gotmt" "$gotmm" "$req" >"$sqlf"
    if ! db_exec <"$sqlf" >"$rows"; then
      a="$(cat "$rows" 2>/dev/null || true)"
      rm -f "$sqlf" "$rows"
      db_fail "could not run the shift" "$a"
    fi
    rm -f "$sqlf"
    # Every `R|<table>|upsert|<json>` the retry and the two ticket moves returned. Folded
    # BEFORE anything is printed: a mutation that reached the database and not the journal
    # is a mutation `guild rebuild` silently undoes.
    _graph_journal_markers "$rows" >/dev/null
  fi

  outf="$(_shift_tmp out)"
  LC_ALL=C awk -v MODE="$mode" -v DRY="$dry" "$(_shift_awk)" "$rows" >"$outf" || rc=$?
  rm -f "$rows"

  if [ "$rc" != 0 ]; then
    # `read` with a FIXED variable list: the last variable takes the remainder, so no
    # `${v#*|}` is ever applied to an unbounded value (rule 5).
    IFS='|' read -r _ a b <"$outf" || true
    rm -f "$outf"
    [ -n "$a" ] || die "guild: could not compute the shift"
    die "guild: this shift's budget is already fixed at ${a} task(s) and ${b} minute(s) —
nothing was written.

A ceiling you can raise from inside the loop is not a ceiling, and an unattended loop with
no ceiling is a runaway token burn (design 8.4). The budget is set when the shift OPENS and
is not negotiable afterwards: passing the SAME values again on every turn is fine, which is
what a '/loop' entry does.

  guild shift --max-tasks ${a} --max-minutes ${b}     carry on with this shift
  guild shift --end                                    close it, then open a new one"
  fi

  cat "$outf"
  rm -f "$outf"
}

# _shift_end <reason> <note> <have-note> <mode> — close the open shift.
#
# ONE db_exec: the refusal marker, the event and the closing numbers are one script. A
# refusal — there is no shift to end — matches no row anywhere, so nothing is written and
# nothing has to be undone.
#
# THE NOTE IS THE ONLY FREE TEXT IN THIS FILE, and it travels as hex (§2.2.1): a `--note`
# describing a file collision is routinely a path list with quotes in it, and one that ended
# a line with `;` would otherwise tear the script in half. It reaches the event payload
# through `json_object`, which is the one escaper §3.0 verifies.
_shift_end() {
  local reason="$1" note="$2" have_note="$3" mode="$4"
  local now nowlit actorlit reasonlit notelit openid usedx minx stepsx sql markers out line

  db_require_init
  journal_preflight

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  # `reason` passed `_shift_check_reason`'s closed vocabulary, so sql_str; the note is a
  # sentence somebody typed, so hex.
  reasonlit="$(sql_str "$reason")"
  if [ "$have_note" = 1 ] && [ -n "$note" ]; then
    notelit="$(sql_text "$note" '--note')"
  else
    notelit="NULL"
  fi

  openid="$(_shift_open_evt subject_id)"
  usedx="$(_shift_used_expr)"
  minx="$(_shift_minutes_expr "$nowlit")"
  # THE SAME FIVE KEYS THE STEP'S OWN `ended` CARRIES, and `steps` is why this line exists:
  # `guild shift-report` reads `$.steps` off whichever `ended` row closed the shift and
  # cannot tell "ended by hand" from "ended after zero steps" if one of the two writers
  # omits the key. `_shift_step_expr` is the step this WOULD have been, so the number of
  # steps actually taken is one less — the step arithmetic `_shift_sql` uses, unchanged.
  stepsx="($(_shift_step_expr)) - 1"

  sql="BEGIN;
SELECT 'MISS|1' WHERE $openid IS NULL;
SELECT 'END|' || $(_graph_field "$openid") || '|' || ($usedx) || '|' || ($minx)
 WHERE $openid IS NOT NULL;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $actorlit, 'ended', 'shift', $openid,
       json_object('reason', $reasonlit, 'note', $notelit,
                   'tasks', ($usedx), 'minutes', ($minx), 'steps', ($stepsx))
 WHERE $openid IS NOT NULL;
COMMIT;
"

  markers="$(_shift_tmp end)"
  if ! printf '%s' "$sql" | db_exec >"$markers"; then
    out="$(cat "$markers" 2>/dev/null || true)"
    rm -f "$markers"
    db_fail "could not end the shift" "$out"
  fi

  if LC_ALL=C grep -q '^MISS|' "$markers"; then
    rm -f "$markers"
    die "guild: no shift is open — nothing was written.

A shift is open from the first 'guild shift' until something ends it, and it ends on its own
at the first stop condition (design 8.4). If you are looking for what the last one did:

  guild shift-report           what the last shift did, and why it stopped
  guild shift --dry-run        what a new shift would pick up"
  fi

  line="$(LC_ALL=C awk -F'|' '$1 == "END" { print $2 "|" $3 "|" $4; exit }' "$markers")"
  rm -f "$markers"

  # The event is the record; this is the receipt. Ids and integers only — nothing here is
  # free text, so the columnar surface and the JSON one carry the same fields.
  if [ "$mode" = json ]; then
    printf '{ "shift": %s, "action": "stop", "reason": %s, "tasks": %s, "minutes": %s }\n' \
      "$(json_str "${line%%|*}")" "$(json_str "$reason")" \
      "$(printf '%s' "$line" | LC_ALL=C awk -F'|' '{ print $2 + 0 }')" \
      "$(printf '%s' "$line" | LC_ALL=C awk -F'|' '{ print $3 + 0 }')"
  else
    printf '%s ended (%s) — %s task(s), %s minute(s)\n' \
      "${line%%|*}" "$reason" \
      "$(printf '%s' "$line" | LC_ALL=C awk -F'|' '{ print $2 + 0 }')" \
      "$(printf '%s' "$line" | LC_ALL=C awk -F'|' '{ print $3 + 0 }')"
  fi
}
