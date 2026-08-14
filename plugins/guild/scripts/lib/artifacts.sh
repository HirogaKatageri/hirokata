# shellcheck shell=bash
#
# lib/artifacts.sh — guild v5 Stage 1: the v4 CRUD surface, reimplemented against the
# database (design doc §3 schema, §4 "Unchanged contracts").
#
# Every command here keeps v4's SIGNATURE, and its STDOUT wherever that stdout is still
# true. What changed underneath is only where the bytes come from: the board is rows, not
# directories, and `guild read` RENDERS the markdown v4 used to `cat`.
#
# The one stdout break is the trailing `<path>` on `new`/`move`/`next`, which named a file
# that either never existed or was about to be deleted — see "paths" below.
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` (scripts/guild owns those).
# Bash 3.2 compatible: no associative arrays, no `declare -A`, no `mapfile`, no ${var^^}.
#
# Depends on lib/db.sh      : die, db_fail, db_require_init, db_exec, db_query, db_now,
#                             sql_str, sql_text, utf8_valid_file, guild_root, spool_path,
#                             spool_append, spool_drain
#          on lib/journal.sh : journal_preflight, journal_append, journal_row, journal_sync
#          on lib/render.sh  : _render_flat, _render_flat_arg, _render_col
#          on lib/init.sh    : _init_read_body (the verbatim --file slurp)
#          on lib/records.sh : _rec_check_slug (the ONE key alphabet — see cmd_plan_slice)
#
# THE LAST THREE ARE FORWARD REFERENCES, and they are deliberate reuse rather than a
# layering accident. scripts/guild sources every module before it dispatches anything, so
# a function defined in a later module is resolvable by the time any command runs; this
# file has reached into lib/render.sh for `_render_flat` since Stage 1 for exactly the
# reason the other two are here now — ONE implementation of "flatten a value", "slurp a
# file verbatim" and "is this a valid key" is worth more than a local copy of each, and
# the copies are what drift.
#
# THE JOURNAL ORDERING CONTRACT (lib/journal.sh, durability guarantee 1). Every command
# below that mutates then journals calls `journal_preflight` FIRST, before any SQL. The
# journal is committed to git, so a merge conflict in it is a routine event and it is
# exactly what makes the tail unreadable — and a caller that discovers this AFTER the
# UPDATE has committed has already changed the board in a way `guild rebuild` will
# silently undo. Preflighting turns that divergence into a refusal that says nothing was
# written. (If the append still fails afterwards, journal.sh quarantines the line to
# .guild/journal.pending and says so loudly; nothing is lost either way.)
#
# The one thing this module takes from lib/render.sh is `_render_flat`, the SQL
# expression that strips CR/LF from a value (`export_path` is gone with `guild path`).
# That is a dependency on purpose: the frontmatter block, the list rows and the board all
# face the same threat — free text impersonating a structural token on a line-oriented
# channel — and ONE implementation of the answer is worth more than a local copy. Every
# module is sourced before any command runs, so the call order is not a concern.
#
# Also here, and NOT in v4: the agent write path (§2.4) — `guild log` and `guild finding`
# append to the per-task spool, `guild spool drain` folds a spool into the database as
# the single writer — plus `guild checkin` (the only writer of `last-checkin`) and
# `guild retitle` (v4 retitled by editing the ticket file's frontmatter; there is no
# file now). `guild path` is GONE: see the note under "paths" below.
#
# HARD RULES honored throughout (§2.2, §3.0):
#   * ONE db_exec per logical command. Multi-step work is composed into a single SQL
#     script whose statements print marker-prefixed rows; the shell then parses one
#     buffer. Never a loop of db_exec calls — in cloud mode each one is a round trip.
#   * EVERY user-supplied value goes through an escaper; no raw interpolation. FREE TEXT
#     (title, body, objective, desc, agent, slice, group, date, and every ID or status
#     that arrives as unvalidated argv) goes through sql_text — `CAST(x'…' AS TEXT)`,
#     §2.2.1 — because a quoted literal whose line ends in `;` is torn in two by the
#     script splitter. sql_str is kept for values this file GENERATED (timestamps, table
#     names) or validated against a fixed set (a status checked against art_statuses).
#   * No FTS5, no WITH RECURSIVE, no generated columns, no lag/lead/ntile/percent_rank/
#     cume_dist. Nothing here needs them: the only graph-ish query (`next`'s review gate)
#     is a direct-predecessor style EXISTS join, not a traversal.
#
# PIPE FOOTGUN (§2.2): `-m list` output is pipe-separated, and titles/bodies can contain
# pipes. So no query here selects free text as one of several columns. Reads either
# select a SINGLE composed value (the rendered document IS the row), or prefix a marker
# and are split on the FIRST pipe only — which is safe because IDs never contain one.

# ---- artifact-type configuration --------------------------------------------------
#
# v4 mapped a kind to a DIRECTORY; v5 maps it to a TABLE. The valid-status lists are
# v4's, because `guild move` validates against them and its error text is part of the
# contract — with ONE Stage 3 addition, `blocked` on a task, whose consequences are set
# out under THE BLOCKED CONTRACT below.

# art_table <kind> — kind token (req|task|plan, upper or lower) -> table name.
art_table() {
  case "${1-}" in
    req | REQ) printf 'requirement\n' ;;
    task | TASK) printf 'task\n' ;;
    plan | PLAN) printf 'plan\n' ;;
    # Stage 2 added four record kinds with verbs of their OWN (`guild goal list`,
    # `guild bug list`, …), deliberately: `guild move GOAL-001 done` would otherwise
    # dispatch into cmd_move, whose v4-parity status sets and error text the harness
    # pins. Naming the right command is the difference between "this CLI cannot do
    # that" and "that lives one word over", and only this file knows both families.
    goal | GOAL | phase | PHASE)
      die "guild: '${1-}' is direction, not an artifact kind — it has its own verbs:
  guild ${1-} list   ·   guild ${1-} new   ·   guild ${1-} move
'guild list' takes req|task|plan."
      ;;
    bug | BUG)
      die "guild: bugs have their own verbs — 'guild bug list [status] [--severity S]'.
'guild list' takes req|task|plan."
      ;;
    doc | DOC)
      die "guild: docs have their own verbs — 'guild doc list' and 'guild doc search Q'.
'guild list' takes req|task|plan."
      ;;
    *) die "guild: unknown kind '${1-}'" ;;
  esac
}

# art_prefix <kind> — kind token -> ID prefix.
art_prefix() {
  case "${1-}" in
    req | REQ) printf 'REQ\n' ;;
    task | TASK) printf 'TASK\n' ;;
    plan | PLAN) printf 'PLAN\n' ;;
    *) die "guild: unknown kind '${1-}'" ;;
  esac
}

# ============================ THE BLOCKED CONTRACT (§5.2) ============================
#
# Stage 3 adds ONE word to ONE vocabulary: a task may be `blocked`. §5.2 defines it
# exactly — "no eligible agent -> task moves to blocked ... that is a roster gap, and it
# should be loud". It is not a general-purpose "stuck" flag: it means NOBODY ON THE
# ROSTER CAN TAKE THIS BOUNTY.
#
# A new status is cheap to add and expensive to add THOUGHTLESSLY, because six things in
# this CLI read `task.status` and each of them has to answer for it. The decisions, and
# why each one is the way round it is:
#
#   1. `guild next` NEVER RETURNS A BLOCKED TASK.
#      Free: cmd_next asks for `in-progress` then `todo`, and blocked is neither. The
#      point is stated here so nobody "fixes" it by widening that query — a blocked task
#      is by definition one no agent can be dispatched for, so returning it would hand
#      the orchestrator a ticket with nobody to give it to.
#
#   2. A BLOCKED TASK HOLDS THE REVIEW GATE CLOSED. cmd_next's gate keeps a `reviewer`
#      ticket waiting while any non-reviewer task for its requirement is open, and
#      `blocked` counts as open (`o.status IN ('todo','in-progress','blocked')`).
#      This is the decision with a real cost on both sides, so: a review that certifies a
#      requirement whose implementation slice was never dispatched is a FALSE GREEN, and
#      a false green is silent — it looks exactly like a real one, and the requirement
#      then closes with a hole in it. A held gate is not silent: the blocked task is on
#      the board, in the briefing and on the dashboard, saying which capability nobody
#      has. Between a failure mode that hides and a failure mode that shouts, take the
#      one that shouts.
#      `failed` deliberately stays OUT of the gate, and the asymmetry is the point:
#      `failed` has already been ruled on by a human (the orchestrator sets it and
#      immediately asks retry-or-skip, lib/brief.sh `_brief_waived`), while `blocked` is
#      a machine verdict nobody has looked at yet. Adjudicated work stops blocking;
#      un-adjudicated work does not.
#      lib/brief.sh's `_brief_bounty_where` is the same predicate spelled a second time
#      and its own header forbids divergence — the two must be changed together.
#
#   3. FOR REQUIREMENT COMPLETION, `blocked` IS LIKE `todo`, NOT LIKE `failed`.
#      Nothing in the CLI closes a requirement — the skills do, with `guild move REQ-NNN
#      done` — so this is a rule those skills must honor, and the reason is the same
#      asymmetry as (2): `failed` means an agent tried and a human decided to live with
#      it; `blocked` means nothing was ever attempted. A requirement completed over a
#      blocked task ships an un-attempted slice and nobody ever finds out.
#
#   4. `blocked` MUST NEVER BE A QUIET DEAD END, so it is visible on every surface:
#      `guild list task blocked` (the status filter is free text and needs no change),
#      `guild board`'s Blocked section (lib/render.sh), the briefing's Blocked section
#      (lib/brief.sh `_brief_blocked_where`, which already reads it), and the dashboard.
#
#   5. cmd_move REFUSES EXACTLY ONE TRANSITION, `blocked -> done`. See its header.
#
#   6. `guild batch` still excludes blocked members. A blocked member cannot dispatch,
#      and a parallel group's slices are disjoint by construction, so the members that
#      CAN run should run — holding the whole group would convert one roster gap into a
#      stalled batch without telling anyone anything new.
#
# BACKWARD COMPATIBILITY. Nothing above changes a board that has no blocked tasks: every
# predicate that grew `'blocked'` grew it as an extra OR-term, so a database in which no
# row carries that status produces byte-identical output to Stage 2. A guild that never
# runs `guild sync-agents` never gets a blocked task, because nothing else writes one.

# art_statuses <kind> — space-separated valid statuses.
#
# req and plan are v4's sets verbatim. `task` gains `blocked` (§5.2, and see THE BLOCKED
# CONTRACT above); it is appended LAST so the "allowed: ..." error text keeps v4's four
# words in v4's order and only grows a fifth.
#
# `waived` is still absent on purpose. The schema admits it and lib/brief.sh's dependency
# predicate already treats it as finished, but it is the Stage 4 GATE's word for
# "deliberately skipped" and no command writes it — a status the CLI can set but nothing
# produces or renders is worse than no status at all.
art_statuses() {
  case "${1-}" in
    req | REQ) printf 'todo in-progress done\n' ;;
    task | TASK) printf 'todo in-progress done failed blocked\n' ;;
    plan | PLAN) printf 'todo in-progress done\n' ;;
    *) die "guild: unknown kind '${1-}'" ;;
  esac
}

# art_num_offset <kind> — 1-based substr() offset of the numeric part of an ID.
# 'REQ-001' -> 5, 'TASK-001' -> 6, 'PLAN-001' -> 6.
art_num_offset() {
  case "${1-}" in
    req | REQ) printf '5\n' ;;
    task | TASK) printf '6\n' ;;
    plan | PLAN) printf '6\n' ;;
    *) die "guild: unknown kind '${1-}'" ;;
  esac
}

# art_kind_of_id <ID> — 'TASK-003' -> task. v4's wording on failure, verbatim.
#
# The three Stage 2 prefixes get a POINTER instead of that wording, for art_table's
# reason: `guild read BUG-001` and `guild move GOAL-001 done` are the two mistakes two
# verb families guarantee, and "unrecognized id" reads as "no such thing" when the thing
# exists one command over. Anything genuinely unrecognized still gets v4's sentence, which
# is what the harness pins.
art_kind_of_id() {
  case "${1-}" in
    REQ-*) printf 'req\n' ;;
    TASK-*) printf 'task\n' ;;
    PLAN-*) printf 'plan\n' ;;
    GOAL-* | PHASE-*)
      die "guild: '${1-}' is a direction id, which 'guild read/meta/status/move/retitle' do not take.
  read it     guild goal show <GOAL-ID>   ·   guild goal list   ·   guild phase list
  move it     guild goal move <GOAL-ID> <status>   ·   guild phase move <PHASE-ID> <status>
  reprioritize  guild goal priority <GOAL-ID> 1-5"
      ;;
    BUG-*)
      die "guild: '${1-}' is a bug, which 'guild read/meta/status/move/retitle' do not take.
  read it     guild bug show <BUG-ID>   ·   guild bug list
  move it     guild bug fix <BUG-ID> --task TASK-NNN   ·   guild bug close <BUG-ID> [--wontfix]"
      ;;
    *) die "guild: unrecognized id '${1-}'" ;;
  esac
}

# ---- paths -------------------------------------------------------------------------
#
# `guild path` IS GONE — the command is removed, not deprecated. In v4 the path WAS the
# storage, so an agent could resolve a path and Edit it. In v5 only requirements get an
# export file, that file is generated output, and `guild export` does `rm -rf` on the
# whole directory before rewriting it — so any agent that Edited a returned path lost
# its work silently. Nothing here hands out a writable-looking path any more.
#
# Reads go through `guild read` / `guild meta` / `guild slice`; writes go through
# `guild log`, `guild finding`, `guild retitle`, `guild move`.
#
# STDOUT CHANGE, and it is the one place this file breaks v4's output rather than its
# storage. v4's `new` printed "<ID> <path>", `move` and `next` printed a path. Those all
# print the BARE ID now (`next` still prints `none` when there is nothing). lib/render.sh
# no longer defines `export_path` — the path was the thing that made agents Edit files
# `guild export` was about to delete, so the whole concept is gone, not just the command
# that reported it. Callers that already did `${out%% *}` to take the ID are unaffected.

# ---- small internals ---------------------------------------------------------------

# _art_tmpfile — a scratch file for byte-exact output staging.
#
# Reads that must be byte-identical to v4 (`read`, `meta`, `slice`) are staged through a
# file rather than a command substitution: `$(...)` strips trailing newlines, and the
# trailing blank line of a v4 task file is part of the contract.
_art_tmpfile() {
  mktemp "${TMPDIR:-/tmp}/guild-artifact.XXXXXX" ||
    die "guild: could not create a temporary file"
}

# _art_actor — who the event/journal rows are attributed to.
_art_actor() {
  printf '%s\n' "${GUILD_ACTOR:-orchestrator}"
}

# _art_json_row <table> — the json_object(...) expression capturing a FULL row.
#
# Full, not partial: the journal is a change log of resulting row state (§2.3), and
# replay re-inserts every column. json_object also preserves types, which STRICT tables
# demand — an INTEGER column must come back as a JSON number, not a string.
#
# THIS IS THE ONE PROJECTION REGISTRY. Every table any command journals is listed here,
# including Stage 2's goal, phase, bug and doc: lib/direction.sh and lib/records.sh each
# arrived with a private `_dir_json_row` / `_rec_json_row` doing the identical job for
# their own two tables, which made three places to look for "what does a journal line for
# table X contain" and three places for a column added later to be forgotten in two of
# them. `journal_append <table> upsert <row>` takes one table name; there is one function
# that answers what a row of it looks like.
#
# STAGE 4 FOLDED IN THE LAST TWO STRAYS. lib/roster.sh shipped `_roster_json_row` and
# lib/graph.sh shipped `_graph_json_row`, each with a header saying in capitals that it
# belonged here and was a stopgap because this file was owned by another author that phase.
# Both are gone: their seven cases are the roster and graph arms below, and their call sites
# call this. The rule the strays were breaking is the one that matters most for a table
# nobody looks at often — `guild rebuild` re-inserts every column from the journal, so a
# projection that goes stale silently drops a column on replay, and a SECOND registry is
# exactly how one goes stale while the other does not.
_art_json_row() {
  case "${1-}" in
    requirement)
      printf "json_object('id',id,'phase_id',phase_id,'title',title,'body',body,'status',status,'priority',priority,'created_at',created_at,'updated_at',updated_at)"
      ;;
    plan)
      printf "json_object('id',id,'requirement_id',requirement_id,'task_id',task_id,'title',title,'body',body,'status',status,'created_at',created_at,'updated_at',updated_at)"
      ;;
    task)
      printf "json_object('id',id,'requirement_id',requirement_id,'plan_id',plan_id,'plan_slice_id',plan_slice_id,'plan_slice',plan_slice,'parallel_group',parallel_group,'node_key',node_key,'title',title,'objective',objective,'body',body,'status',status,'priority',priority,'agent',agent,'claimed_by',claimed_by,'claimed_at',claimed_at,'created_at',created_at,'updated_at',updated_at)"
      ;;
    task_capability)
      printf "json_object('task_id',task_id,'capability',capability,'required',required)"
      ;;
    work_log)
      printf "json_object('id',id,'task_id',task_id,'ts',ts,'agent',agent,'entry',entry)"
      ;;
    review_finding)
      printf "json_object('id',id,'task_id',task_id,'reviewer',reviewer,'severity',severity,'summary',summary,'detail',detail,'file',file,'line',line,'disposition',disposition,'fix_task_id',fix_task_id,'created_at',created_at)"
      ;;
    guild_state)
      printf "json_object('key',key,'value',value)"
      ;;
    goal)
      printf "json_object('id',id,'title',title,'body',body,'status',status,'priority',priority,'created_at',created_at,'updated_at',updated_at)"
      ;;
    phase)
      printf "json_object('id',id,'goal_id',goal_id,'title',title,'ordinal',ordinal,'status',status,'created_at',created_at,'updated_at',updated_at)"
      ;;
    bug)
      printf "json_object('id',id,'title',title,'body',body,'repro',repro,'severity',severity,'status',status,'found_by',found_by,'requirement_id',requirement_id,'fix_task_id',fix_task_id,'created_at',created_at,'updated_at',updated_at)"
      ;;
    doc)
      printf "json_object('slug',slug,'title',title,'body',body,'source',source,'updated_at',updated_at)"
      ;;
    coverage)
      printf "json_object('id',id,'area',area,'risk',risk,'spec_path',spec_path,'last_inspected_at',last_inspected_at,'notes',notes)"
      ;;
    plan_slice)
      printf "json_object('id',id,'plan_id',plan_id,'slug',slug,'title',title,'body',body,'files',files)"
      ;;
    # ---- the roster (Stage 3; folded in from `_roster_json_row` in Stage 4) ----
    #
    # `active`, `serial`, `required` and `capability_request.id` are INTEGER columns on
    # STRICT tables, and json_object preserves their type — which is what keeps a replayed
    # row insertable rather than a string where a number belongs.
    agent)
      printf "json_object('name',name,'model',model,'description',description,'active',active,'serial',serial)"
      ;;
    agent_capability)
      printf "json_object('agent',agent,'capability',capability)"
      ;;
    capability_request)
      printf "json_object('id',id,'capability',capability,'requirement_id',requirement_id,'rationale',rationale,'proposed_agent',proposed_agent,'proposed_spec',proposed_spec,'status',status,'created_at',created_at)"
      ;;
    # ---- the execution graph (Stage 4; folded in from `_graph_json_row`) ----
    graph_node)
      printf "json_object('id',id,'requirement_id',requirement_id,'node_key',node_key,'kind',kind,'task_id',task_id,'parallel_group',parallel_group,'status',status)"
      ;;
    graph_edge)
      printf "json_object('from_node',from_node,'to_node',to_node)"
      ;;
    graph_deviation)
      printf "json_object('id',id,'requirement_id',requirement_id,'kind',kind,'node_key',node_key,'reason',reason,'created_at',created_at)"
      ;;
    gate)
      printf "json_object('node_id',node_id,'prompt',prompt,'kind',kind,'status',status,'decision',decision,'decided_at',decided_at)"
      ;;
    *) die "guild: no row projection for table '${1-}'" ;;
  esac
}

# _art_created_expr <date-flag> <now-literal> — the created_at value for a new row.
#
# --date when given, otherwise NOW. That is the whole rule, and the second half of it is
# a deliberate break with v4.
#
# v4 defaulted `created:` to state.yaml's `last-checkin`. An earlier draft of this file
# reproduced that (--date, else last-checkin, else now) and it was wrong in v5 for a
# reason v4 did not have: v4's check-in skill rewrote `last-checkin` every session by
# editing state.yaml, so the fallback was "roughly today". In v5 `last-checkin` is a
# guild_state row that ONLY `guild init` and `guild checkin` write — and until
# `cmd_checkin` existed (below), nothing wrote it after init. The measured result was
# that every artifact ever created carried the init date: two artifacts created minutes
# apart both stamped 2026-01-01. A creation timestamp that does not advance is worse
# than useless — later stages sort and age on it.
#
# `created:` renders as substr(created_at,1,10), so an explicit --date still round-trips
# exactly and the skills that pass `--date {today}` are unaffected.
#
# `--date` is unvalidated argv, so it is FREE TEXT and travels as hex (§2.2.1): a `--date`
# whose value ends a line with `;` would otherwise tear the create script in half.
_art_created_expr() {
  local d
  d="$(sql_text "${1-}" '--date')"
  printf "COALESCE(NULLIF(%s,''), %s)" "$d" "${2-}"
}

# _art_next_id_expr <kind> — SQL producing the next 'PREFIX-NNN' for a kind (§3.3).
# Used INSIDE the insert so the derivation and the write are one statement.
_art_next_id_expr() {
  local kind="${1-}" table prefix off
  table="$(art_table "$kind")" || exit 1
  prefix="$(art_prefix "$kind")"
  off="$(art_num_offset "$kind")" || exit 1
  printf "'%s-' || printf('%%03d', COALESCE((SELECT MAX(CAST(substr(id,%s) AS INTEGER)) FROM %s),0) + 1)" \
    "$prefix" "$off" "$table"
}

# _art_created_event_sql <kind> <table> <now-literal> <actor-literal> — the `created`
# event for a row inserted EARLIER IN THE SAME SCRIPT.
#
# The script is composed before the ID exists, so the event cannot name it directly. It
# finds it instead: run right after the insert, the highest ID of that kind IS the row
# just written (new = max + 1, and §2.4 guarantees a single writer).
#
# Two guards, because the obvious one is not enough. `updated_at` must equal this
# invocation's timestamp, so an insert that selected no rows (a missing `--req`) does not
# stamp an event on somebody else's artifact — but db_now has second resolution, and a
# scripted burst of creates puts several rows in the same second, which measurably DID
# produce an event for the previous artifact when a later create failed. So the row must
# ALSO have no `created` event yet. That one is exact rather than probabilistic: a genuinely
# new ID cannot already have been announced, and a failed create finds its predecessor
# already announced and writes nothing.
#
# The OPTIONAL FIFTH ARGUMENT is a SQL expression for the event's payload, defaulting to
# the empty object this has always written. `new task --needs …` uses it to record what
# the task asked the roster for (`_art_capability_payload`), so the history says what was
# required and not merely that a ticket appeared. It is an EXPRESSION, never free text:
# every caller composes it from values validated against a fixed alphabet.
_art_created_event_sql() {
  local kind="${1-}" table="${2-}" nowlit="${3-}" actorlit="${4-}" payload="${5-}"
  local prefix off tablit
  prefix="$(art_prefix "$kind")"
  off="$(art_num_offset "$kind")" || exit 1
  tablit="$(sql_str "$table")"
  [ -n "$payload" ] || payload="'{}'"
  # The payload is a printf ARGUMENT, not spliced into the format string: today's callers
  # compose it from the capability alphabet, which has no '%', but a format string that
  # depends on that staying true is a trap laid for whoever adds the next payload.
  printf "INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT %s, %s, 'created', %s, id, %s
FROM %s
WHERE id = (SELECT '%s-' || printf('%%03d', MAX(CAST(substr(id,%s) AS INTEGER))) FROM %s)
  AND updated_at = %s
  AND NOT EXISTS (SELECT 1 FROM event e
                   WHERE e.verb = 'created'
                     AND e.subject_type = %s
                     AND e.subject_id = %s.id);
" "$nowlit" "$actorlit" "$tablit" "$payload" "$table" "$prefix" "$off" "$table" "$nowlit" \
    "$tablit" "$table"
}

# _art_first_line <file> — the first line of a staged result, '' when empty.
_art_first_line() {
  LC_ALL=C awk 'NR == 1 { print; exit }' "${1-}"
}

# ---- capabilities (§5.1-5.2) --------------------------------------------------------
#
# A task declares WHAT IT NEEDS; `guild match` decides WHO GETS IT. The rows live in
# `task_capability (task_id, capability, required)` — required = 1 for `--needs`, 0 for
# `--prefers` — and they are written by the same single script that inserts the task.
#
# THE CAPABILITY ALPHABET IS THE WHOLE REASON THESE VALUES ARE `sql_str`-SAFE. Rule: free
# text travels as hex (§2.2.1); only a value validated against a fixed alphabet may be a
# quoted literal. `_art_capability` is that validation, and it is deliberately strict —
# lowercase ASCII letters, digits and internal hyphens, starting with a letter, at most 64
# bytes. Nothing in that set can close a string literal, end a statement, or span a line,
# so a capability can be interpolated into SQL, into a `json_array(...)` payload and into
# a `guild board` column without any of the three escapers this file otherwise depends on.
#
# THE VOCABULARY (§5.3) IS NOT ENFORCED HERE, and that is a decision rather than an
# oversight. §5.3 keeps a small closed list precisely so `e2e` and `end-to-end` cannot
# both exist — but the roster is what knows the list, and a second copy of it in this file
# is a second thing to forget when §5.4 admits a new member. A capability nobody declares
# simply matches no agent, which is the designed feedback path: the task goes `blocked`
# and the board says which capability nobody has. A typo is therefore loud within one
# dispatch, which is better than a refusal here that has to be kept in sync forever.

# _art_capability <token> <flag> — echo a validated capability token, or die.
#
# The length check comes FIRST, before any pattern work: the flag is unvalidated argv and
# the adversarial matrix puts 100 KB through every one of them, and `${v%%[![:space:]]*}`
# is O(n²) on bash 3.2 (rule 4). Bounding the token to 64 bytes makes the trim that
# follows free. The trim itself exists because `--needs "implement, backend"` is what a
# person types and refusing it teaches nothing.
_art_capability() {
  local v="${1-}" flag="${2-}"
  # `local LC_ALL=C` IS THE WHOLE VALIDATOR, and it is not decoration — this function was
  # written without it and MEASURABLY ACCEPTED `--needs Rust`. `a-z` in a bash bracket
  # expression is a COLLATION range, not a byte range, so under the ordinary
  # `LANG=en_US.UTF-8` an uppercase letter collates INSIDE it and `*[!a-z0-9-]*` does not
  # match. lib/records.sh `_rec_check_slug` carries the same line and the same scar, for
  # the same reason: the justification for sending these values to SQL through `sql_str`
  # instead of `sql_text` is "they passed this alphabet", and an alphabet enforced only in
  # some locales is not an alphabet. It would also have split the roster — `Rust` and
  # `rust` are two capabilities to the matcher and one to the person who typed them.
  local LC_ALL=C
  if [ ${#v} -gt 64 ]; then
    die "guild: $flag capability names are at most 64 characters (got ${#v})"
  fi
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    "")
      die "guild: $flag has an empty capability name — check for a doubled or trailing comma."
      ;;
    [a-z]*) ;;
    *)
      die "guild: $flag capability '$v' must start with a lowercase letter.
Capabilities are a small fixed vocabulary (design §5.3): implement, frontend, backend,
svelte, sveltekit, test-planning, test-authoring, e2e, review, security, architecture,
business-logic, edge-case, research, qa-planning, qa-execution, requirements."
      ;;
  esac
  case "$v" in
    *[!a-z0-9-]*)
      die "guild: $flag capability '$v' may contain only lowercase letters, digits and hyphens.
One spelling per capability is what makes the matcher work — 'e2e' and 'end-to-end' as
two tags is exactly the drift design §5.3 exists to prevent."
      ;;
  esac
  printf '%s\n' "$v"
}

# _art_capability_rows <needs> <prefers> — the deduplicated capability set, as lines of
# "<required> <capability>", in first-mentioned order.
#
# REQUIRED WINS. `--needs a --prefers a` is one row with required = 1, not two rows and
# not a primary-key collision: a capability that is genuinely required does not become
# optional because it was also listed as nice to have. Deduplication happens HERE rather
# than as an `ON CONFLICT` clause because the shell already has to walk the list to
# validate it, and a task being created cannot have pre-existing rows to conflict with —
# so an upsert would be buying nothing with an engine feature.
#
# awk does the set work: bash 3.2 has no associative arrays, and the alternative is a
# nested loop over two lists. Tokens are validated before they reach it, so they contain
# no space and `$1`/`$2` splitting is exact.
#
# THE SPLIT IS `tr`, NOT `IFS=','; set -- $list`, and that is a correctness choice rather
# than a style one. The IFS form needs `set -f` wrapped around it (this CLI runs with
# globbing on and a capability list is not a glob context), it leaves the shell's IFS and
# `-f` to be restored by hand on every path out, and it still reads to shellcheck as an
# unquoted expansion — which can only be quietened with a `disable` directive. A disabled
# lint is a lint nobody ever looks at again, and the two lines that carried one here were
# the two lines doing the delicate work.
#
# `tr` is one pass, and the loop reads from a HEREDOC rather than a pipe: `die` on the
# right-hand side of a pipe kills only the subshell, so a rejected capability would
# otherwise be reported and then ignored. Behaviour is identical to the IFS form on every
# input that matters, including the two that decide whether a typo is loud:
#   `--needs a,`     one token   (a heredoc's trailing newline is consumed by read, and
#                                 `$(...)` strips the one `tr` produced — same as IFS
#                                 splitting, which drops a trailing empty field)
#   `--needs a,,b`   three, the middle one empty, which _art_capability refuses by name
_art_capability_rows() {
  local needs="${1-}" prefers="${2-}" tok out

  out=""
  if [ -n "$needs" ]; then
    # `|| exit 1`, not a bare call: _art_capability dies, and a `die` inside `$(...)` only
    # kills the substitution subshell — the caller would otherwise sail on with an empty
    # token and store a capability nobody asked for. Every caller of this function applies
    # the same `|| exit 1` for the same reason.
    while IFS= read -r tok; do
      tok="$(_art_capability "$tok" '--needs')" || exit 1
      out="${out}1 $tok
"
    done <<EOF
$(printf '%s' "$needs" | LC_ALL=C tr ',' '
')
EOF
  fi

  if [ -n "$prefers" ]; then
    while IFS= read -r tok; do
      tok="$(_art_capability "$tok" '--prefers')" || exit 1
      out="${out}0 $tok
"
    done <<EOF
$(printf '%s' "$prefers" | LC_ALL=C tr ',' '
')
EOF
  fi

  [ -n "$out" ] || return 0
  printf '%s' "$out" | LC_ALL=C awk '
    NF == 2 {
      if (!($2 in seen)) { seen[$2] = $1; ord[++n] = $2 }
      else if ($1 > seen[$2]) seen[$2] = $1
    }
    END { for (i = 1; i <= n; i++) print seen[ord[i]] " " ord[i] }'
}

# _art_capability_sql <rows> <now-literal> — the INSERT that attaches those rows to the
# task this script has just created, or '' when there are none.
#
# IT FINDS THE TASK THE SAME WAY `_art_created_event_sql` DOES, and must run BEFORE it:
# the id does not exist when the script is composed, so the row is located as "the highest
# TASK id", with the same two guards — `updated_at` is this invocation's timestamp, and
# the row has not been announced yet. The second guard is the exact one, and it is why the
# ordering matters: once the `created` event is written, this statement's WHERE can no
# longer be true, so composing the two in the wrong order would silently attach nothing.
# A create that inserted no task (a missing `--req`) finds its predecessor already
# announced and writes nothing, rather than tagging somebody else's ticket.
#
# One statement for the whole set, not one per capability (rule: one db_exec per logical
# command, and never a loop). The values arrive as an inline `SELECT ... UNION ALL`
# relation joined to the task — every token already validated against the capability
# alphabet, so `sql_str` is correct here and hex would only obscure it.
_art_capability_sql() {
  local rows="${1-}" nowlit="${2-}" values="" r c
  [ -n "$rows" ] || return 0

  while IFS=' ' read -r r c; do
    [ -n "$c" ] || continue
    if [ -z "$values" ]; then
      values="SELECT $(sql_str "$c") AS cap, $r AS req"
    else
      values="$values
       UNION ALL SELECT $(sql_str "$c"), $r"
    fi
  done <<EOF
$rows
EOF
  [ -n "$values" ] || return 0

  printf "INSERT INTO task_capability (task_id, capability, required)
SELECT t.id, v.cap, v.req
FROM task t, ( %s ) v
WHERE t.id = (SELECT 'TASK-' || printf('%%03d', MAX(CAST(substr(id,6) AS INTEGER))) FROM task)
  AND t.updated_at = %s
  AND NOT EXISTS (SELECT 1 FROM event e
                   WHERE e.verb = 'created'
                     AND e.subject_type = 'task'
                     AND e.subject_id = t.id);
" "$values" "$nowlit"
}

# _art_capability_payload <rows> — the `created` event's payload expression: the two
# capability sets, so the history says what the task asked for and not merely that it
# existed. '{}' (the default) when the task declares nothing.
#
# Written as `json_object('needs', json_array(...), 'prefers', json_array(...))` so the
# payload column holds real JSON arrays rather than a flattened string a later reader has
# to re-split. Tokens are alphabet-validated, hence `sql_str`.
_art_capability_payload() {
  local rows="${1-}" needs="" prefers="" r c
  [ -n "$rows" ] || { printf "'{}'"; return 0; }

  while IFS=' ' read -r r c; do
    [ -n "$c" ] || continue
    if [ "$r" = "1" ]; then
      needs="$needs${needs:+,}$(sql_str "$c")"
    else
      prefers="$prefers${prefers:+,}$(sql_str "$c")"
    fi
  done <<EOF
$rows
EOF

  printf "json_object('needs', json_array(%s), 'prefers', json_array(%s))" "$needs" "$prefers"
}

# ---- flag parsing ------------------------------------------------------------------

# _art_parse_flags <args...> — v4's parse_flags, with the flag set spelled out.
#
# Sets art_title art_desc art_body art_date art_agent art_req art_plan art_slice art_group
# art_objective art_task art_needs art_prefers, always resetting them first so a second
# call cannot inherit the first one's values. Unknown `--flags` consume their value and
# are ignored, and bare words are skipped — both exactly as v4 behaved.
#
# `--needs` / `--prefers` are Stage 3 (§5.1-5.2): comma-separated capability lists that
# say WHAT THE WORK REQUIRES instead of WHO DOES IT. They are parsed for every kind and
# used only by `new task`, which is the same way `--agent` and `--plan-slice` have always
# been handled here.
#
# `--body` is the one flag with no v4 counterpart, because v4 did not need one: the
# artifact was a FILE, so the product-owner wrote its requirement document by Editing that
# file and the architect wrote its plan the same way. There is no file now, and Stage 1
# ships no post-creation body writer — so without `--body` those documents have nowhere at
# all to live, and `guild export` publishes the template's placeholders into the PR
# snapshot forever. `--body` REPLACES the template outright; `--desc` fills one section of
# it. They are alternatives, and `--body` wins if both are given.
_art_parse_flags() {
  art_title=""
  art_desc=""
  art_body=""
  art_date=""
  art_agent=""
  art_req=""
  art_plan=""
  art_slice=""
  art_group=""
  art_objective=""
  art_task=""
  art_needs=""
  art_prefers=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --title) shift; art_title="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --needs) shift; art_needs="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --prefers) shift; art_prefers="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --desc) shift; art_desc="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --body) shift; art_body="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --date) shift; art_date="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --agent) shift; art_agent="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --req) shift; art_req="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --plan) shift; art_plan="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --plan-slice) shift; art_slice="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --parallel-group) shift; art_group="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --objective) shift; art_objective="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --task) shift; art_task="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --*) shift; if [ $# -gt 0 ]; then shift; fi ;;
      *) shift ;;
    esac
  done
}

# ---- create ------------------------------------------------------------------------
#
# Shape shared by all three creates, and the reason each is ONE round trip:
#
#   INSERT ... SELECT <derived id>, ... FROM <the rows that must exist>
#     RETURNING 'OK|' || id || '|' || json_object(<the whole row>);
#   SELECT 'MISS|<ref>' WHERE NOT EXISTS (<ref exists>);   -- diagnostics, 0 or 1 rows
#   INSERT INTO event ... ;                                -- silent
#
# The FROM clause is the referential check: `new task --req REQ-404` selects zero rows,
# so nothing is inserted, RETURNING prints nothing, and the MISS line says which
# reference was missing. That is deliberately not a WHERE on an aggregate query — an
# aggregate with a false WHERE still returns one row (with NULLs) and would have inserted
# a row with a bogus ID.

# _art_body_or <template> — the body to store: `--body` verbatim when given, else the
# template the caller composed.
#
# The guard is the render contract (lib/render.sh, "CONTRACT WITH THE CREATION COMMANDS"):
# `## Work Log` and `## Follow-up Tasks` are RENDERED, from work_log rows, by both
# `guild read` and the export. A body that also contains those headings renders them
# twice — and worse, the orchestrator parses `## Follow-up Tasks` back out of a ticket to
# decide what work to materialize, so an agent that put one in its own body would be
# writing the orchestrator's input. `--body` is the one place free text becomes a whole
# document, so it is the one place that has to be checked.
_art_body_or() {
  local nl=$'\n'
  if [ -z "$art_body" ]; then
    printf '%s' "${1-}"
    return 0
  fi
  case "$nl$art_body$nl" in
    *"$nl## Work Log$nl"* | *"$nl## Follow-up Tasks$nl"*)
      die "guild: --body must not contain a '## Work Log' or '## Follow-up Tasks' heading.

Those two sections are RENDERED from the board, not stored: 'guild read' builds them from
the task's work-log entries, which agents append with 'guild log'. A body carrying them
would render them twice and would let a document impersonate the orchestrator's own input.

Write the document without them; the log fills in as agents report."
      ;;
  esac
  printf '%s' "$art_body"
}

# _art_defuse_body <text> — indent any line that IS a line `guild read` GENERATES: the
# `---` frontmatter fence, and the `## Work Log` / `## Follow-up Tasks` headings.
#
# `_art_body_or` above guards the ONE door it can guard: a whole document handed in as
# `--body`. It is not the only door, and it is not even the usual one. Every create
# composes a TEMPLATE body out of free text first — `--objective`, `--plan-slice`,
# `--desc`, and the title itself (`# <title>` for req/plan, and for a task the title is
# the default objective) — so a structural line arriving in any of those reached the
# stored body without ever passing the guard. Two live consequences, both reproduced:
#
#   * `## Follow-up Tasks` in a task body is not a cosmetic duplicate, it is the
#     orchestrator's INPUT: check-in reads that section back out of a rendered ticket to
#     decide what work to materialize next.
#   * a bare `---` line closes the document's frontmatter as far as any reader that
#     splits on the fence is concerned, so everything after it is attacker-authored.
#
# Refusing is not available here the way it is for `--body`: `--title` is mandatory, an
# objective is prose that may legitimately quote a ticket, and the flag is how the
# architect delivers a brief. So this NEUTRALIZES instead — the same answer, and the same
# two spaces, that the work-log renderer already uses on entry continuation lines
# (`_art_read_sql` step 2). The indent is chosen because it costs the reader nothing:
# CommonMark still reads `  ## X` as a heading and `  ---` as a thematic break (up to
# three leading spaces are insignificant), while `^## ` and `^---$` parsers — which is
# what every consumer of these documents is — no longer match.
#
# `--body` keeps its refusal rather than being defused: it is a whole document the caller
# authored deliberately, and silently rewriting one is worse than telling the caller no.
#
# BOTH HEADINGS, not just `## Follow-up Tasks`. An earlier round defused only that one, on
# the argument that it is READ BACK by the orchestrator while `## Work Log` merely labels a
# section rendered from `work_log` rows. The argument does not hold: `skills/check-in`
# triages on an EMPTY Work Log — "never started, move it back to todo" — so a body that
# plants
#
#   ## Work Log
#   - fake entry claiming the work is done
#
# above the real, empty, rendered one is also writing the orchestrator's input, for a
# "first heading wins" reader. The stated blocker was that the harness pins such a value
# byte-exact through `guild read`; that was the same blocker `## Follow-up Tasks` had, and
# it is resolved the same way — the harness computes the expected transformation itself
# (`_adv_defused`), so the indent is asserted rather than assumed away. Verbatim and
# unforgeable really are mutually exclusive on a line-oriented channel; this file chooses
# unforgeable for every line it generates, and `guild meta <ID> title` remains the byte-
# exact channel for anyone who needs the original.
#
# Bash 3.2: `${v//pat/rep}` in a loop, because a global replace does not rescan the text
# it just consumed — two adjacent forged headings share the newline between them, so the
# second needs another pass. Each pass strictly reduces the count, so the loop ends.
# The value is padded with newlines first so that a heading at the very start or the very
# end of the text is matched by the same pattern as one in the middle.
_art_defuse_body() {
  _art_defuse_lines "${1-}" '## Follow-up Tasks' '## Work Log' '---'
}

# _art_defuse_lines <text> <line>... — THE neutralizer. Indent by two spaces every whole
# line of <text> that is exactly one of the given structural lines.
#
# It is the mechanism `_art_defuse_body` used to inline, lifted out because Stage 2's
# documents generate structural lines of their own and each of its two modules arrived
# with a private copy of this loop: `guild goal show` has a `## Phases` anchor, and
# `guild bug show` has `## Details` and `## Reproduction`. One mechanism with three
# heading LISTS is right; three copies of the mechanism is how they drift — and the two
# copies had already drifted, one padding the value once per call and the other once per
# heading.
#
# A wrapper composes rather than re-implements:
#
#   _dir_defuse_body = _art_defuse_body + '## Phases'
#   _rec_defuse_body = _art_defuse_body + '## Details' + '## Reproduction'
#
# Bash 3.2: `${v//pat/rep}` in a loop, because a global replace does not rescan the text
# it just consumed — two adjacent forged headings share the newline between them, so the
# second needs another pass. Each pass strictly reduces the count, so the loop ends. The
# value is padded with newlines first so a heading at the very start or the very end of
# the text is matched by the same pattern as one in the middle.
_art_defuse_lines() {
  local nl=$'\n' v h
  v="$nl${1-}$nl"
  shift
  for h in "$@"; do
    while :; do
      case "$v" in
        *"$nl$h$nl"*) v="${v//"$nl$h$nl"/$nl  $h$nl}" ;;
        *) break ;;
      esac
    done
  done
  v="${v#"$nl"}"
  v="${v%"$nl"}"
  printf '%s' "$v"
}

# _art_create_run <label> <sql> — run a create script, parse `OK|<id>|<row-json>`.
# Echoes "<id> <row-json>" on success; dies with the missing reference otherwise.
#
# THE FAILURE PATH PRINTS THE DRIVER'S OUTPUT. tursodb writes its diagnostics to STDOUT,
# which is the buffer captured here as data — so discarding it (as this did) turned every
# engine-level rejection into rc=1 with an empty stdout AND an empty stderr. That is how
# §2.2.1's torn-statement bug stayed invisible for two review rounds. db_fail relays it.
_art_create_run() {
  local label="${1-}" sql="${2-}" out line rest id row miss
  if ! out="$(printf '%s' "$sql" | db_exec)"; then
    db_fail "could not create $label" "$out"
  fi
  line="$(printf '%s' "$out" | head -n1)"
  case "$line" in
    'OK|'*)
      rest="${line#OK|}"
      id="${rest%%|*}"
      row="${rest#*|}"
      case "$row" in
        '{'*'}') ;;
        *) die "guild: could not create $label (unexpected database output)" ;;
      esac
      printf '%s %s\n' "$id" "$row"
      return 0
      ;;
  esac
  miss="$(printf '%s\n' "$out" | LC_ALL=C awk -F'|' '$1 == "MISS" { print $2; exit }')"
  [ -z "$miss" ] || die "guild: $miss not found"
  die "guild: could not create $label"
}

# _art_update_run <id> <what> <sql> — run an UPDATE script, print the resulting row JSON.
#
# THE UPDATE HALF OF THE SAME PROTOCOL `_art_create_run` speaks, and the reason it lives
# here rather than in either Stage 2 module: `guild goal move`, `guild goal priority`,
# `guild phase move`, `guild req assign`, `guild bug fix` and `guild bug close` all have
# one shape and one set of outcomes, and they arrived as TWO parsers that disagreed about
# the marker — one `OK|<row>`, the other `OK|<id>|<row>` with the id stripped back off.
# Two spellings of one protocol is two places for the MISS handling to drift.
#
#   OK|<row-json>    the row was updated; the JSON is what journal_append records
#   MISS|<ref>       a referenced row does not exist; <ref> names it
#   nothing          <id> itself does not exist
#
# THE MARKER CARRIES THE ROW ONLY, never `OK|<id>|<row>`. The caller already knows the id
# it passed, so the second field buys nothing — and `${line#OK|}` is a FIXED literal
# prefix, which is a constant-length compare, where pulling a variable middle field out
# needs `${row#*|}`. That is bounded here only because the delimiter happens to sit near
# the start; it is measurably catastrophic when it does not (92s at 400 KB under bash
# 3.2), and a marker shape nobody has to reason about is better than one that is safe by
# coincidence.
#
# THE FAILURE PATH RELAYS THE DRIVER'S OUTPUT, for `_art_create_run`'s reason: tursodb
# writes its diagnostics to STDOUT, which is the buffer captured here as data, so
# discarding it turns an engine-level rejection into rc=1 with nothing printed anywhere.
_art_update_run() {
  local id="${1-}" what="${2-}" sql="${3-}" out line row miss
  if ! out="$(printf '%s' "$sql" | db_exec)"; then
    db_fail "could not $what" "$out"
  fi
  line="$(printf '%s' "$out" | head -n1)"
  case "$line" in
    'OK|'*)
      row="${line#OK|}"
      case "$row" in
        '{'*'}') ;;
        *) die "guild: could not $what (unexpected database output)" ;;
      esac
      printf '%s\n' "$row"
      return 0
      ;;
  esac
  miss="$(printf '%s\n' "$out" | LC_ALL=C awk -F'|' '$1 == "MISS" { print $2; exit }')"
  [ -z "$miss" ] || die "guild: $miss not found"
  die "guild: $id not found"
}

# cmd_new_req --title T [--desc D | --body B] [--date YYYY-MM-DD]
# Prints the new ID (v4 also printed a path; see the "paths" note above).
cmd_new_req() {
  local now nowlit actorlit created idexpr rowexpr body sql result id row
  _art_parse_flags "$@"
  [ -n "$art_title" ] || die "guild: new req requires --title"
  db_require_init
  journal_preflight

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  created="$(_art_created_expr "$art_date" "$nowlit")"
  idexpr="$(_art_next_id_expr req)"
  rowexpr="$(_art_json_row requirement)"

  # v4's requirements/todo/REQ-NNN.md template, minus the frontmatter (which `read`
  # renders from columns) and minus the trailing newline (which the row terminator adds).
  body="# $art_title

## Summary

${art_desc:-_To be gathered by the product-owner._}

## User Stories

_To be gathered by the product-owner._

## Technical Considerations

_To be determined._

## Out of Scope

_To be determined._"
  # `--title` and `--desc` are interpolated above, so the composed body is defused before
  # it is stored; the template's own lines contain nothing this can touch.
  body="$(_art_body_or "$(_art_defuse_body "$body")")" || exit 1

  sql="BEGIN;
INSERT INTO requirement (id, title, body, status, priority, created_at, updated_at)
SELECT $idexpr, $(sql_text "$art_title" '--title'), $(sql_text "$body" '--desc'), 'todo', 3, $created, $nowlit
RETURNING 'OK|' || id || '|' || $rowexpr;
$(_art_created_event_sql req requirement "$nowlit" "$actorlit")
COMMIT;
"

  result="$(_art_create_run 'the requirement' "$sql")" || exit 1
  id="${result%% *}"
  row="${result#* }"
  journal_append requirement upsert "$row"
  printf '%s\n' "$id"
}

# cmd_new_task --title T --req REQ-NNN (--agent A | --needs cap,cap) [--prefers cap,cap]
#              [--plan PLAN-NNN] [--plan-slice slug] [--parallel-group LABEL]
#              [--objective O | --body B] [--date YYYY-MM-DD]
# Prints the new ID (v4 also printed a path; see the "paths" note above).
#
# STAGE 3 CHANGES ONE REQUIREMENT AND ADDS TWO FLAGS. `--agent` was mandatory; now
# `--agent` OR `--needs` is. This is the whole point of §5: "adding agents/developer-rust.md
# with the right tags should make it eligible for work with no skill edits" only works if a
# ticket is allowed to describe the WORK rather than name the WORKER.
#
# WHAT DID NOT CHANGE, and this is the part that matters more:
#
#   * `--agent A` with no `--needs` writes exactly the row Stage 1 wrote, journals exactly
#     the line Stage 1 journaled, and emits the `created` event with Stage 1's `{}`
#     payload. Not "equivalent" — the composed SQL is character-for-character the same,
#     because `_art_capability_sql` and `_art_capability_payload` both return their
#     Stage 1 values for an empty capability set. Every existing skill, every existing
#     board and every existing test is on that path.
#   * `task.agent` is untouched and still free text. Naming an agent is not deprecated:
#     §5.2 keeps it for when it genuinely matters, and giving BOTH pins the member and
#     still records what the work needs — which is what makes the pin reviewable later.
#   * A task with neither is refused, and the refusal names BOTH alternatives. That error
#     is the first thing anyone hits when a calling convention shifts under them, so it
#     has to teach the new spelling rather than restate the old rule.
#
# The capability rows are written by the SAME script that inserts the task — see
# `_art_capability_sql` for how it finds a row whose id did not exist when the script was
# composed, and why it must precede the `created` event.
cmd_new_task() {
  local now nowlit actorlit created idexpr rowexpr body objective sql result id row
  local planexpr slicelit grouplit agentlit from misses caprows capsql cappayload r c
  _art_parse_flags "$@"
  [ -n "$art_title" ] || die "guild: new task requires --title"
  if [ -z "$art_agent" ] && [ -z "$art_needs" ]; then
    die "guild: new task requires --agent or --needs

  --agent developer             give the bounty to a named guild member. Still valid,
                                still the v4 spelling, still what a pinned assignment
                                looks like.
  --needs implement,backend     describe the WORK and let the roster answer: 'guild match'
                                ranks the members whose capabilities cover it, and the
                                task goes 'blocked' — loudly — if nobody's do.

Give both to pin a member AND record what the work actually needed.
Capabilities come from the fixed vocabulary in design §5.3; add '--prefers a,b' for the
ones that break a tie rather than decide eligibility."
  fi
  [ -n "$art_req" ] || die "guild: new task requires --req"
  # Validated BEFORE db_require_init and journal_preflight, like every other argument
  # check here: a misspelled capability must cost nothing and touch nothing.
  caprows="$(_art_capability_rows "$art_needs" "$art_prefers")" || exit 1
  db_require_init
  journal_preflight

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  created="$(_art_created_expr "$art_date" "$nowlit")"
  idexpr="$(_art_next_id_expr task)"
  rowexpr="$(_art_json_row task)"
  objective="${art_objective:-$art_title}"

  body="## Objective

$objective

## Context

- Requirement: $art_req"
  if [ -n "$art_plan" ]; then
    body="$body
- Plan: $art_plan"
  fi
  if [ -n "$art_slice" ]; then
    body="$body
- Plan slice: $art_slice"
  fi
  body="$body

## Acceptance Criteria

- [ ] Task completed successfully"
  # Defuse the COMPOSED body, not just `--objective`: `--plan-slice` and `--plan` are
  # interpolated into it too, and the template's own text contains no rendered heading,
  # so the only lines this can touch are the ones that arrived as free text.
  body="$(_art_body_or "$(_art_defuse_body "$body")")" || exit 1

  # `--plan` is validated by joining it in, so a bad PLAN id inserts nothing instead of
  # tripping a raw foreign-key error.
  from="FROM requirement r WHERE r.id = $(sql_text "$art_req" '--req')"
  planexpr="NULL"
  misses="SELECT 'MISS|' || $(sql_text "$art_req" '--req')
  WHERE NOT EXISTS (SELECT 1 FROM requirement WHERE id = $(sql_text "$art_req" '--req'));
"
  if [ -n "$art_plan" ]; then
    from="FROM requirement r, plan p WHERE r.id = $(sql_text "$art_req" '--req') AND p.id = $(sql_text "$art_plan" '--plan')"
    planexpr="p.id"
    misses="$misses
SELECT 'MISS|' || $(sql_text "$art_plan" '--plan')
  WHERE NOT EXISTS (SELECT 1 FROM plan WHERE id = $(sql_text "$art_plan" '--plan'));
"
  fi

  slicelit="NULL"
  [ -z "$art_slice" ] || slicelit="$(sql_text "$art_slice" '--plan-slice')"
  grouplit="NULL"
  [ -z "$art_group" ] || grouplit="$(sql_text "$art_group" '--parallel-group')"
  # NULL rather than '' for an absent `--agent`, matching how `--plan-slice` and
  # `--parallel-group` already record absence. It is the difference between "this bounty
  # names no member" and "this bounty names a member whose name is the empty string", and
  # every reader in the CLI already spells the test `COALESCE(agent,'') <> ''`, so both
  # forms read identically — but only one of them is honest in the journal.
  agentlit="NULL"
  [ -z "$art_agent" ] || agentlit="$(sql_text "$art_agent" '--agent')"

  # Both return their Stage 1 values ('' and "'{}'") for an empty capability set, so a
  # `--agent`-only create composes character-for-character the Stage 1 script.
  capsql="$(_art_capability_sql "$caprows" "$nowlit")" || exit 1
  cappayload="$(_art_capability_payload "$caprows")" || exit 1

  # STATEMENT ORDER IS LOAD-BEARING: the capability insert must come BEFORE the `created`
  # event, because both locate the new task by "highest id that has not been announced
  # yet" and the event is what ends that window. `$misses` is only SELECTs, so it may sit
  # between them, but the capability insert may not sit after the event.
  sql="BEGIN;
INSERT INTO task (id, requirement_id, plan_id, plan_slice, parallel_group,
                  title, objective, body, status, priority, agent, created_at, updated_at)
SELECT $idexpr, r.id, $planexpr, $slicelit, $grouplit,
       $(sql_text "$art_title" '--title'), $(sql_text "$objective" '--objective'), $(sql_text "$body" '--body'),
       'todo', 3, $agentlit, $created, $nowlit
$from
RETURNING 'OK|' || id || '|' || $rowexpr;
$capsql$misses
$(_art_created_event_sql task task "$nowlit" "$actorlit" "$cappayload")
COMMIT;
"

  result="$(_art_create_run 'the task' "$sql")" || exit 1
  id="${result%% *}"
  row="${result#* }"
  journal_append task upsert "$row"
  # The capability rows are journaled from the SET THE SHELL VALIDATED, not from a
  # read-back. That is exact, not a shortcut: `_art_create_run` returning OK proves the
  # task row was inserted, and the capability statement's WHERE is true for precisely that
  # case — so the rows in the database are these rows. A read-back would cost a second
  # round trip to learn something already known. (Rule: every mutation is journaled; a
  # capability row that `guild rebuild` cannot replay would make the roster gap vanish on
  # the one recovery path that is supposed to preserve it.)
  if [ -n "$caprows" ]; then
    while IFS=' ' read -r r c; do
      [ -n "$c" ] || continue
      journal_append task_capability upsert \
        "$(journal_row task_id "$id" capability "$c" '#required' "$r")"
    done <<EOF
$caprows
EOF
  fi
  printf '%s\n' "$id"
}

# cmd_new_plan --title T --req REQ-NNN [--desc D | --body B] [--task TASK-NNN] [--date YYYY-MM-DD]
# Prints the new ID (v4 also printed a path; see the "paths" note above).
#
# `--desc` is the plan's Architecture Overview, and it is here for the same reason
# `new req --desc` exists: in v4 the architect wrote the overview by Editing the plan
# FILE, and v5 has no file and no body writer. Without it, every plan keeps the
# template's `_High-level design decisions._` placeholder forever — and `guild export`
# publishes that placeholder into the PR-reviewable snapshot. It takes multi-line text,
# so the whole overview goes in at creation: `--desc "$(cat overview.md)"`.
#
# v4 also created an empty PLAN-NNN/ slice directory here. v5 has no slice files: slices
# are `plan_slice` rows, written after the plan exists with `guild plan slice` (below).
# Nothing is created here, deliberately — a plan's slices are the architect's decomposition
# and an empty placeholder set would be indistinguishable from a decomposition of one.
cmd_new_plan() {
  local now nowlit actorlit created idexpr rowexpr body sql result id row
  local taskexpr from misses
  _art_parse_flags "$@"
  [ -n "$art_title" ] || die "guild: new plan requires --title"
  [ -n "$art_req" ] || die "guild: new plan requires --req"
  db_require_init
  journal_preflight

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  created="$(_art_created_expr "$art_date" "$nowlit")"
  idexpr="$(_art_next_id_expr plan)"
  rowexpr="$(_art_json_row plan)"

  body="# $art_title

## Architecture Overview

${art_desc:-_High-level design decisions._}

## Implementation Tasks

_Specific developer tasks — transcribed into the originating task's Follow-up Tasks._

## Technical Decisions

_Key choices and rationale._

## Risks

_Identified risks and mitigations._"
  # Same as `new req`: `--title` and `--desc` reach the composed body, so defuse it.
  body="$(_art_body_or "$(_art_defuse_body "$body")")" || exit 1

  from="FROM requirement r WHERE r.id = $(sql_text "$art_req" '--req')"
  taskexpr="NULL"
  misses="SELECT 'MISS|' || $(sql_text "$art_req" '--req')
  WHERE NOT EXISTS (SELECT 1 FROM requirement WHERE id = $(sql_text "$art_req" '--req'));
"
  if [ -n "$art_task" ]; then
    from="FROM requirement r, task t WHERE r.id = $(sql_text "$art_req" '--req') AND t.id = $(sql_text "$art_task" '--task')"
    taskexpr="t.id"
    misses="$misses
SELECT 'MISS|' || $(sql_text "$art_task" '--task')
  WHERE NOT EXISTS (SELECT 1 FROM task WHERE id = $(sql_text "$art_task" '--task'));
"
  fi

  sql="BEGIN;
INSERT INTO plan (id, requirement_id, task_id, title, body, status, created_at, updated_at)
SELECT $idexpr, r.id, $taskexpr, $(sql_text "$art_title" '--title'), $(sql_text "$body" '--body'),
       'todo', $created, $nowlit
$from
RETURNING 'OK|' || id || '|' || $rowexpr;
$misses
$(_art_created_event_sql plan plan "$nowlit" "$actorlit")
COMMIT;
"

  result="$(_art_create_run 'the plan' "$sql")" || exit 1
  id="${result%% *}"
  row="${result#* }"
  journal_append plan upsert "$row"
  printf '%s\n' "$id"
}

# cmd_new <req|task|plan> [flags...] — v4's `guild new` sub-dispatch. This is THE
# implementation; scripts/guild routes `new` straight here and defines no cmd_new of
# its own.
cmd_new() {
  local sub="${1-}"
  [ $# -ge 1 ] || die "guild: unknown 'new' target '' (req|task|plan)"
  shift
  case "$sub" in
    req) cmd_new_req "$@" ;;
    task) cmd_new_task "$@" ;;
    plan) cmd_new_plan "$@" ;;
    *) die "guild: unknown 'new' target '$sub' (req|task|plan)" ;;
  esac
}

# ---- resolve / read ----------------------------------------------------------------
#
# There is no cmd_path. `guild meta <ID> id` is the existence probe it used to double as:
# it dies with the same `guild: <ID> not found` on an unknown ID and prints the ID on a
# known one, in exactly one round trip.

# _art_meta_block_expr <kind> — SQL producing the frontmatter block (no `---` fences),
# byte-identical to what v4 wrote between them.
#
# Field order, quoting and the `null` placeholders are all v4's: `title` is quoted here
# but NOT by the single-field form, because v4's `fm` stripped surrounding quotes.
# Optional lines appear only when they have a value, exactly as v4 only wrote them then.
#
# THE OUTPUT-CHANNEL RULE (§2.2.1, lib/render.sh's header) APPLIES HERE, and this block
# is the sharpest instance of it in the CLI. The frontmatter is a `key: value` block
# between `---` fences, one field per LINE, and `guild meta` / `guild read` are what
# every skill and agent parses to learn what a ticket is. An unflattened title therefore
# forged two things at once — a field (`title: "X"\nagent: reviewer-security` put a
# second `agent:` line ABOVE the real one, and line-order parsers take the first) and the
# fence itself (`title: "X"\n---` closed the frontmatter early, making the rest of the
# document attacker-authored).
#
# The mechanism is render.sh's `_render_flat` — the SAME one the board uses, deliberately
# not a second escaping scheme of this module's own. Every field on this block is a
# ONE-LINE field by definition, so flattening is exactly the right shape: CR/LF are gone
# before the value leaves the engine, and a structural line can only ever be one the SQL
# wrote. The single-field form (`guild meta ID title`) is NOT flattened, and must not be:
# its whole stdout is one value, there is no structural token to impersonate, and callers
# rely on it round-tripping byte-exactly.
#
# Everything interpolated is flattened, including the ids and `created_at`: ids are
# replayed from the journal, which lives in git, and `created_at` can come straight from
# an unvalidated `--date`.
#
# FLATTENING MAKES THE BLOCK UNFORGEABLE; IT DOES NOT MAKE IT VALID YAML, and this is
# where the second half is done. `title` was interpolated between two literal quote
# characters, so a title containing `"` ended the scalar early and a title containing `\`
# opened an escape sequence that does not exist — `title: "C:\path\new"` is a YAML
# ScannerError, and a Windows path in a title is not adversarial input. Worse, a literal
# `\n` in a title was decoded by the reader back into a REAL newline, silently undoing the
# flattening on the far side. So the quoted field is escaped (`_render_yaml_dq`) and the
# bare fields are quoted only when they are not already safe plain scalars
# (`_render_yaml_scalar`) — which keeps v4's `agent: developer` / `plan: null` /
# `parallel-group: impl` byte-identical and changes only the values that used to produce a
# parse error. See lib/render.sh's YAML section for why the split is drawn there.
_art_meta_block_expr() {
  local id_e ti_e cr_e ag_e rq_e pl_e sl_e pg_e tk_e
  id_e="$(_render_yaml_scalar "$(_render_flat 'id')")"
  ti_e="$(_render_yaml_dq "$(_render_flat 'title')")"
  cr_e="$(_render_yaml_scalar "$(_render_flat 'substr(created_at,1,10)')")"
  case "${1-}" in
    req)
      printf "%s" "'id: ' || $id_e || '
title: ' || $ti_e || '
created: ' || $cr_e"
      ;;
    task)
      ag_e="$(_render_yaml_scalar "$(_render_flat "COALESCE(agent,'')")")"
      rq_e="$(_render_yaml_scalar "$(_render_flat 'requirement_id')")"
      pl_e="$(_render_yaml_scalar "$(_render_flat "COALESCE(plan_id,'null')")")"
      sl_e="$(_render_yaml_scalar "$(_render_flat 'plan_slice')")"
      pg_e="$(_render_yaml_scalar "$(_render_flat 'parallel_group')")"
      printf "%s" "'id: ' || $id_e || '
title: ' || $ti_e || '
agent: ' || $ag_e || '
requirement: ' || $rq_e || '
plan: ' || $pl_e ||
CASE WHEN COALESCE(plan_slice,'') <> '' THEN '
plan-slice: ' || $sl_e ELSE '' END ||
CASE WHEN COALESCE(parallel_group,'') <> '' THEN '
parallel-group: ' || $pg_e ELSE '' END || '
created: ' || $cr_e"
      ;;
    plan)
      rq_e="$(_render_yaml_scalar "$(_render_flat 'requirement_id')")"
      tk_e="$(_render_yaml_scalar "$(_render_flat "COALESCE(task_id,'null')")")"
      printf "%s" "'id: ' || $id_e || '
title: ' || $ti_e || '
requirement: ' || $rq_e || '
task: ' || $tk_e || '
created: ' || $cr_e"
      ;;
    *) die "guild: unknown kind '${1-}'" ;;
  esac
}

# _art_meta_field_stmt <kind> <field> <id-literal> — the SELECT for one frontmatter
# field, or '' when the field does not exist for this kind.
#
# An empty result is the point: v4's `fm` printed NOTHING for a key absent from the
# frontmatter, so an unknown field emits no statement at all, and an optional field that
# is empty is filtered out by its own WHERE rather than printing a blank line.
#
# DELIBERATELY NOT FLATTENED, unlike the block form above. One field is the command's
# ENTIRE stdout: there is no second field for it to forge, no fence to close, and no
# in-band token at all — the value is the message. Flattening here would instead break
# the contract callers do rely on, that `guild meta ID title` returns the stored title
# byte for byte.
_art_meta_field_stmt() {
  local kind="${1-}" field="${2-}" idlit="${3-}" table
  table="$(art_table "$kind")" || exit 1
  # Kinds are spelled out rather than globbed: a `*/id` pattern would also match an
  # absurd field name like `a/id` and answer with the ID instead of nothing.
  case "$kind/$field" in
    req/id | task/id | plan/id)
      printf 'SELECT id FROM %s WHERE id = %s;\n' "$table" "$idlit"
      ;;
    req/title | task/title | plan/title)
      printf 'SELECT title FROM %s WHERE id = %s;\n' "$table" "$idlit"
      ;;
    req/created | task/created | plan/created)
      printf 'SELECT substr(created_at,1,10) FROM %s WHERE id = %s;\n' "$table" "$idlit"
      ;;
    task/agent) printf "SELECT COALESCE(agent,'') FROM task WHERE id = %s;\n" "$idlit" ;;
    task/requirement | plan/requirement)
      printf 'SELECT requirement_id FROM %s WHERE id = %s;\n' "$table" "$idlit"
      ;;
    task/plan) printf "SELECT COALESCE(plan_id,'null') FROM task WHERE id = %s;\n" "$idlit" ;;
    task/plan-slice)
      printf "SELECT plan_slice FROM task WHERE id = %s AND COALESCE(plan_slice,'') <> '';\n" "$idlit"
      ;;
    task/parallel-group)
      printf "SELECT parallel_group FROM task WHERE id = %s AND COALESCE(parallel_group,'') <> '';\n" "$idlit"
      ;;
    plan/task) printf "SELECT COALESCE(task_id,'null') FROM plan WHERE id = %s;\n" "$idlit" ;;
    *) : ;;
  esac
}

# cmd_meta <ID> [field] — the frontmatter block, or one field's value.
cmd_meta() {
  local id="${1-}" field="${2-}" kind table idlit sql tmp out
  [ -n "$id" ] || die "guild: meta requires an ID"
  kind="$(art_kind_of_id "$id")" || exit 1
  table="$(art_table "$kind")" || exit 1
  db_require_init
  # An ID is only prefix-checked (art_kind_of_id), never matched against a safe
  # alphabet — so it is argv free text and travels as hex like any other (§2.2.1).
  idlit="$(sql_text "$id" 'the ID argument')"

  # An existence marker leads, so "not found" and "found, but this field is empty" stay
  # distinguishable in one round trip.
  sql="SELECT 'E' FROM $table WHERE id = $idlit;
"
  if [ -n "$field" ]; then
    sql="$sql$(_art_meta_field_stmt "$kind" "$field" "$idlit")"
  else
    sql="${sql}SELECT $(_art_meta_block_expr "$kind") FROM $table WHERE id = $idlit;
"
  fi

  tmp="$(_art_tmpfile)" || exit 1
  if ! printf '%s' "$sql" | db_exec >"$tmp"; then
    out="$(cat "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    db_fail "could not read $id" "$out"
  fi
  if [ "$(_art_first_line "$tmp")" != "E" ]; then
    rm -f "$tmp"
    die "guild: $id not found"
  fi
  tail -n +2 "$tmp"
  rm -f "$tmp"
}

# _art_read_sql <kind> <ID> — the script whose stdout IS the rendered document.
#
# v4's `read` was `cat` of a file; agents parse that shape, so the rendering reproduces it
# byte for byte: the `---` frontmatter block, a blank line, the body, and — for tasks —
# `## Work Log` and `## Follow-up Tasks`, including v4's trailing blank line.
#
# The work log is emitted as its own statement rather than group_concat: statement output
# concatenates in order, ORDER BY is explicit, and no aggregate-with-ORDER-BY support is
# assumed (§3.0 keeps to the intersection of both engines).
#
# Every statement is guarded on the row existing, so a missing ID produces NO output at
# all and the caller can report v4's `guild: <ID> not found`.
_art_read_sql() {
  local kind="${1-}" id="${2-}" idlit table
  idlit="$(sql_text "$id" 'the ID argument')"
  table="$(art_table "$kind")" || exit 1

  if [ "$kind" != "task" ]; then
    printf "SELECT '---
' || %s || '
---

' || body FROM %s WHERE id = %s;\n" "$(_art_meta_block_expr "$kind")" "$table" "$idlit"
    return 0
  fi

  # 1. frontmatter + body + the Work Log heading (the row terminator supplies the blank
  #    line that follows the heading, matching an empty v4 log exactly).
  printf "SELECT '---
' || %s || '
---

' || body || '

## Work Log
' FROM task WHERE id = %s;\n" "$(_art_meta_block_expr task)" "$idlit"
  # 2. one line per work-log entry, oldest first — every entry INDENTED INTO ITS BULLET.
  #
  # `ts` and `agent` are single tokens, so an embedded newline in either is folded to a
  # space. `entry` is prose and may legitimately be several lines, so its newlines survive
  # but every continuation line is indented two spaces. Both are the output-channel rule
  # (§2.2) applied to the one document the orchestrator parses back: without the indent, an
  # agent could put `## Follow-up Tasks` on its own line inside a work-log entry and forge a
  # section of its own ticket, which check-in reads to decide what work to materialize next.
  # Two spaces is also simply correct markdown for a continuation inside a list item.
  printf "SELECT '- ' || replace(ts, '
', ' ') || ' ' || replace(agent, '
', ' ') || ': ' || replace(entry, '
', '
  ') FROM work_log WHERE task_id = %s ORDER BY id;\n" "$idlit"
  # 3. a separating blank line, only when entries were printed.
  printf "SELECT '' WHERE EXISTS (SELECT 1 FROM work_log WHERE task_id = %s);\n" "$idlit"
  # 4. the Follow-up Tasks heading; v4's file ended with its trailing blank line.
  printf "SELECT '## Follow-up Tasks
' WHERE EXISTS (SELECT 1 FROM task WHERE id = %s);\n" "$idlit"
}

# cmd_read <ID> — render the artifact as markdown, from the database.
cmd_read() {
  local id="${1-}" kind tmp out
  [ -n "$id" ] || die "guild: read requires an ID"
  kind="$(art_kind_of_id "$id")" || exit 1
  db_require_init
  tmp="$(_art_tmpfile)" || exit 1
  if ! _art_read_sql "$kind" "$id" | db_exec >"$tmp"; then
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

# cmd_status <ID> — the artifact's status.
cmd_status() {
  local id="${1-}" kind table out
  [ -n "$id" ] || die "guild: status requires an ID"
  kind="$(art_kind_of_id "$id")" || exit 1
  table="$(art_table "$kind")" || exit 1
  db_require_init
  if ! out="$(printf 'SELECT status FROM %s WHERE id = %s;\n' "$table" "$(sql_text "$id" 'the ID argument')" | db_exec)"; then
    db_fail "could not read the status of $id" "$out"
  fi
  [ -n "$out" ] || die "guild: $id not found"
  printf '%s\n' "$out"
}

# cmd_slice <PLAN-ID> <slug> — the plan slice.
#
# v4 printed a PATH to a slice FILE the architect had written. v5 stores slices as
# `plan_slice` rows, so there is no file to point at and this prints the slice body —
# the same thing the caller was going to read. Both v4 spellings of the argument are
# accepted (`auth`, `slice-auth`, `slice-auth.md`) so existing call sites keep working;
# the normalization is `_art_slice_slug`, which `guild plan slice` writes through, so
# reader and writer cannot disagree about what a slug IS.
#
# STAGE 4 GAVE THIS COMMAND ITS WRITER. Through Stage 3 nothing wrote `plan_slice` while
# the architect always set `--plan-slice {slug}` on a developer ticket and the developer
# agents called this as their "primary brief" — so the only reachable answer on the hot
# path was the miss, and the error had to explain a gap. `guild plan slice` (below) is
# that writer, so the miss is now an ordinary miss: this plan has no slice by that name.
# It still names where a brief lives when there is no slice row, because nine agent
# files call this first and a bare `not found` sends them looking for a file.
cmd_slice() {
  local plan="${1-}" slug="${2-}" planlit sluglit sql tmp l1 l2 out
  [ -n "$plan" ] || die "guild: slice requires a PLAN id"
  [ -n "$slug" ] || die "guild: slice requires a slug"
  case "$plan" in
    PLAN-*) ;;
    *) die "guild: unrecognized id '$plan'" ;;
  esac

  slug="$(_art_slice_slug "$slug")"

  db_require_init
  planlit="$(sql_text "$plan" 'the PLAN id')"
  sluglit="$(sql_text "$slug" 'the slice slug')"

  sql="SELECT 'P' FROM plan WHERE id = $planlit;
SELECT 'S' FROM plan_slice WHERE plan_id = $planlit AND slug = $sluglit;
SELECT body FROM plan_slice WHERE plan_id = $planlit AND slug = $sluglit;
"
  tmp="$(_art_tmpfile)" || exit 1
  if ! printf '%s' "$sql" | db_exec >"$tmp"; then
    out="$(cat "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    db_fail "could not read $plan/$slug" "$out"
  fi
  l1="$(_art_first_line "$tmp")"
  l2="$(LC_ALL=C awk 'NR == 2 { print; exit }' "$tmp")"
  if [ "$l1" != "P" ]; then
    rm -f "$tmp"
    die "guild: $plan not found"
  fi
  if [ "$l2" != "S" ]; then
    rm -f "$tmp"
    die "guild: $plan/$slug not found

The slices this plan does have:

  guild plan slices $plan

If the architect wrote no slice for it, the brief is the ticket's own '## Objective'
section — 'guild read TASK-NNN' — which is where the plan-slice frontmatter field
points when there is no row. The architect files one with:

  guild plan slice $plan --slug $slug --title T --body '...' --files 'a.ts,b.ts'"
  fi
  tail -n +3 "$tmp"
  rm -f "$tmp"
}

# ============================ PLAN SLICES — THE WRITER (§6.1) ========================
#
#   guild plan slice  <PLAN-NNN> --slug SLUG --title T [--body B | --file F]
#                                [--files "a,b,c"]
#   guild plan slices <PLAN-NNN> [--files]
#
# WHY THIS BLOCKS STAGE 4, stated once so nobody removes it as a convenience. The
# standard template's `implement` node carries `fanout: per-slice` and
# `parallel: by-group`: the graph compiler asks a plan how many implementation nodes it
# has, and the answer is its slice rows. Through Stage 3 there were none — `plan_slice`
# was a table with a reader (`guild slice`, above), nine agent files instructing agents
# to call that reader, and no way at all to put a row there. `fanout: per-slice` over an
# empty set is one node or none, so the whole fan-out half of §6.1 was unreachable.
#
# THE FILE SET IS THE POINT, not decoration. `--files` records the slice's files as a
# JSON array, and that array IS the architect's disjoint-file assertion — the claim that
# these slices touch no file in common and may therefore run concurrently. §6.3 lists
# "splitting `implement` into three sequential waves because the slices are not disjoint"
# as a legitimate deviation, which is a decision somebody has to be able to CHECK. A file
# set that lives only in a prose brief cannot be checked by anything.
#
# UPSERT, LIKE `doc put` AND `coverage set`. A slice is refined — the architect writes the
# brief, then comes back with the file set once the shape is settled — and re-running with
# the same slug must not be a primary-key error or a second row. What is NOT passed is
# PRESERVED (the body, the file set), which is why `--files ''` exists as the explicit
# clear: "this slice turned out to touch nothing" and "I did not restate the file list"
# are different statements and only one of them should empty the column.
#
# THE BODY IS STORED VERBATIM — neither defused nor guarded, exactly as `cmd_doc_put`
# stores a doc body and for the identical reason. `guild slice` prints it ALONE, with no
# frontmatter, no headings and no markers around it, so that channel has no structural
# token for a value to impersonate; neutralizing it would corrupt real briefs (a slice
# brief legitimately contains fenced code, `---` rules and headings of its own) to defend
# against nothing. The columnar surface (`plan slices`) never emits the body at all.

# _art_slice_slug <slug> — THE canonical form of a slice slug.
#
# One normalizer, called by the reader AND the writer, because a slug the writer stores
# and the reader cannot find is the worst possible failure here: the developer agent asks
# for its primary brief and is told the plan is broken. v4 wrote slice FILES, so its call
# sites spell the argument three ways (`auth`, `slice-auth`, `slice-auth.md`) and all
# three still have to land on the same row.
#
# Both strips are ANCHORED fixed-literal parameter expansions (`%.md`, `#slice-`), so they
# are constant-time and rule 5 (no `${v%%pat*}` on unbounded text) is not in play.
_art_slice_slug() {
  local slug="${1-}"
  slug="${slug%.md}"
  case "$slug" in
    slice-*) slug="${slug#slice-}" ;;
  esac
  printf '%s\n' "$slug"
}

# _art_slice_file <path> — echo one validated, trimmed member of `--files`, or die.
#
# The length bound comes FIRST, before any trim, for `_art_capability`'s reason: the trim
# is `${v#"${v%%[![:space:]]*}"}`, which is O(n²) under bash 3.2 (rule 5), and this flag
# is unvalidated argv that the adversarial matrix will happily hand 100 KB. Bounding a
# path to 1024 bytes makes the trim free — and no repository has a 1 KB path.
#
# The CR/LF refusal is NOT here — it is on the whole list, in `_art_slice_files_expr`,
# and that placement is the whole point. The split is `tr ',' '\n'` followed by `read`, so
# by the time a token reaches this function an embedded newline has ALREADY become a
# second path: `--files 'a<LF>b,c'` would silently assert three files where the caller
# named two. A check here would never fire; a check before the split refuses it.
_art_slice_file() {
  local v="${1-}"
  if [ ${#v} -gt 1024 ]; then
    die "guild: --files entries are at most 1024 characters (got ${#v})"
  fi
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    "")
      die "guild: --files has an empty path — check for a doubled or trailing comma."
      ;;
  esac
  printf '%s\n' "$v"
}

# _art_slice_files_expr <csv> — the SQL expression for `plan_slice.files`: a real JSON
# array built by the engine, or `'[]'`.
#
# json_array() rather than a string this shell concatenates, for the reason
# `_art_capability_payload` uses it: the column must hold JSON that a later reader can
# parse, and a shell that builds JSON by hand is a shell that has to implement JSON
# STRING ESCAPING by hand — for paths containing quotes, backslashes and non-ASCII. Each
# element still travels as `sql_text` (§2.2.1): a path is free text.
#
# The split is `tr` + a HEREDOC, not `IFS=','; set -- $list`, for `_art_capability_rows`'s
# two reasons — the IFS form needs `set -f` restored on every path out, and a `die` on the
# right of a PIPE kills only the subshell, so a rejected path would be reported and then
# ignored. Trailing comma yields one fewer token (`$( )` strips tr's trailing newline);
# `a,,b` yields an empty middle token, which `_art_slice_file` refuses by name.
#
# THE COUNT IS CAPPED at 200. The cap bounds the composed statement (each element is a
# hex-encoded literal) and it bounds the append loop below, whose `out="$out…"` is the one
# shape in this function that could go quadratic. It is also a statement about the data: a
# "slice" naming more than 200 files is not a unit of parallel work, and saying so at the
# flag is kinder than a 400 KB SQL script that fails somewhere else.
#
# CR AND LF ARE REFUSED ON THE WHOLE LIST, before the split, because after the split they
# are indistinguishable from a comma: `tr` turns commas into newlines and `read` consumes
# newlines, so an embedded LF would quietly become an extra path in the assertion. A path
# cannot legitimately contain either, and the file set is read back on line-oriented
# surfaces — json_array() escapes control characters, so this is belt and braces, but "the
# value could not have contained the token" beats "the encoder escaped it".
_art_slice_files_expr() {
  local list="${1-}" out="" tok n=0 nl=$'\n' cr=$'\r'
  [ -n "$list" ] || { printf "'[]'"; return 0; }
  case "$list" in
    *"$cr"* | *"$nl"*)
      die "guild: --files may not contain a newline or a carriage return.
Paths are separated by commas: --files 'src/auth/session.ts,src/auth/index.ts'.
The file set is the architect's disjoint-file assertion and it is read back a line at a
time ('guild plan slices --files'); a path that can span lines could forge another
slice's entry, and a newline inside one would silently split it into two files."
      ;;
  esac

  while IFS= read -r tok; do
    tok="$(_art_slice_file "$tok")" || exit 1
    n=$((n + 1))
    [ "$n" -le 200 ] ||
      die "guild: --files lists more than 200 paths.
A slice is a unit of parallel work with a disjoint file set; at that size it is a plan,
not a slice. Split it into several slices, each with its own --slug."
    out="$out${out:+, }$(sql_text "$tok" '--files')"
  done <<EOF
$(printf '%s' "$list" | LC_ALL=C tr ',' '
')
EOF

  [ -n "$out" ] || { printf "'[]'"; return 0; }
  printf 'json_array(%s)' "$out"
}

# _art_slice_parse_flags <args...> — the `plan slice` flag set.
#
# Sets ps_slug ps_title ps_body ps_body_set ps_file ps_files ps_files_set, resetting them
# first so a second call cannot inherit the first one's values.
#
# UNKNOWN FLAGS ARE REFUSED HERE, where `_art_parse_flags` and `_qa_parse_flags` swallow
# them. That is not inconsistency for its own sake: those two carry v4 signatures whose
# tolerance is part of the contract, this command has no v4 counterpart, and the flag most
# likely to be mistyped is `--files` — whose silent loss does not fail, it produces a slice
# that ASSERTS IT TOUCHES NO FILES and therefore runs concurrently with everything. A
# swallowed flag that widens parallelism is not a flag worth being permissive about.
# `guild phase list` already refuses unknown flags for the same class of reason.
_art_slice_parse_flags() {
  ps_slug=""
  ps_title=""
  ps_body=""
  ps_body_set=0
  ps_file=""
  ps_files=""
  ps_files_set=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --slug) shift; ps_slug="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --title) shift; ps_title="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --body) shift; ps_body="${1-}"; ps_body_set=1; if [ $# -gt 0 ]; then shift; fi ;;
      --file) shift; ps_file="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --files) shift; ps_files="${1-}"; ps_files_set=1; if [ $# -gt 0 ]; then shift; fi ;;
      *)
        die "guild: unexpected argument '$(_render_flat_arg "$1")'

  guild plan slice <PLAN-NNN> --slug SLUG --title T [--body B | --file F] [--files \"a,b,c\"]"
        ;;
    esac
  done
}

# _art_slice_body — resolve the slice brief from --body or --file into `ps_body`, or
# leave `ps_body_set` at 0 so the caller preserves what is stored.
#
# `--file` is here for `doc put --file`'s reason and it is the architect's actual
# workflow: a slice brief is drafted as a file, and `--body "$(cat brief.md)"` loses every
# trailing newline to command substitution. `_init_read_body`'s out-parameter form exists
# precisely so that "the body is stored verbatim" actually holds at the CALL SITE.
#
# The UTF-8 check is explicit rather than left to sql_text so the error can name the PATH
# rather than the flag: `--file` is something the caller typed and may have several of.
_art_slice_body() {
  [ -n "$ps_file" ] || return 0
  [ "$ps_body_set" = 0 ] ||
    die "guild: plan slice takes --body or --file, not both"
  [ -e "$ps_file" ] || die "guild: no such file: $ps_file"
  [ -f "$ps_file" ] || die "guild: not a regular file: $ps_file"
  [ -r "$ps_file" ] || die "guild: cannot read $ps_file (permission denied)"
  utf8_valid_file "$ps_file" ||
    die "guild: $ps_file is not valid UTF-8, so it was not stored.

The guild stores text as UTF-8; re-encode the file and re-run —

  iconv -f latin1 -t utf8 '$ps_file' > t && mv t '$ps_file'

An invalid byte would not survive the trip: free text reaches SQL as bytes cast to TEXT,
and tursodb substitutes U+FFFD where libSQL keeps the byte (design 2.2.1)."
  _init_read_body ps_body "$ps_file"
  ps_body_set=1
  return 0
}

# cmd_plan_slice <PLAN-NNN> --slug SLUG --title T [--body B | --file F] [--files "a,b,c"]
# Upserts one slice. Prints the slice id, `PLAN-001/auth-service`.
#
# ONE SCRIPT, ONE ROUND TRIP, FOUR STATEMENTS:
#
#   INSERT INTO event …          (verb chosen from whether the row existed BEFORE)
#   UPDATE plan_slice … RETURNING 'OK|' || <row json>;   -- fires iff it already existed
#   INSERT INTO plan_slice … SELECT … FROM plan p WHERE p.id = <plan>
#                              AND NOT EXISTS (<the slice>)
#                        RETURNING 'OK|' || <row json>;  -- fires iff it did not
#   SELECT 'MISS|<plan>' WHERE NOT EXISTS (<the plan>);  -- diagnostics
#
# EXACTLY ONE OF THE TWO WRITES FIRES, so exactly one `OK|` line comes back and the caller
# parses one protocol. `FROM plan p WHERE p.id = …` is the referential check, in this
# file's usual shape: a slug filed against a plan that does not exist selects zero rows,
# nothing is written, and the MISS line names what was missing.
#
# WHY NOT `ON CONFLICT(id) DO UPDATE`, which `doc put` and `coverage set` both use.
# `plan_slice` carries TWO coincident unique constraints — `id` (the primary key) and
# `UNIQUE (plan_id, slug)` — and because the id IS `plan_id || '/' || slug`, re-filing a
# slug violates BOTH AT ONCE. An upsert handles a conflict on its named target and RAISES
# on any other, so which of the two the engine notices first decides whether this command
# updates a row or dies with `UNIQUE constraint failed`. That ordering is an engine
# implementation detail, it is not on §3.0's verified list for either engine, and it is
# the kind of difference that would show up on one engine only — the worst kind to find
# late. UPDATE-then-guarded-INSERT depends on no constraint-detection order at all.
#
# OMITTED MEANS PRESERVE, and with two statements that needs no cleverness: the UPDATE
# simply does not name a column the caller did not pass, and the INSERT supplies the
# column default ('' / '[]'). The earlier single-statement form had to read the old value
# back with a scalar subquery against the very row it was writing; not needing to is the
# second reason this shape is the right one.
#
# The id is COMPOSED IN SQL as `<plan> || '/' || <slug>` (§3.2: `PLAN-001/auth-service`),
# not in the shell, because the plan id is unvalidated argv and must travel as hex — so
# there is no shell-side string to concatenate that would still be safe to interpolate.
cmd_plan_slice() {
  local plan="${1-}" slug idexpr planlit sluglit titlelit setlist
  local bodyexpr filesexpr payloadexpr now nowlit actorlit rowexpr sql row
  [ -n "$plan" ] || die "guild: plan slice requires a PLAN id"
  case "$plan" in
    PLAN-*) ;;
    *) die "guild: unrecognized id '$(_render_flat_arg "$plan")' (expected PLAN-NNN)" ;;
  esac
  shift
  _art_slice_parse_flags "$@"
  [ -n "$ps_slug" ] || die "guild: plan slice requires --slug

The slug is the name the developer ticket carries in --plan-slice and the name the
developer agent reads back with 'guild slice $plan <slug>'. Keep it short and typeable:
'auth-service', 'migrations'."
  [ -n "$ps_title" ] || die "guild: plan slice requires --title"
  slug="$(_art_slice_slug "$ps_slug")"
  # The slug is a KEY somebody retypes — into `--plan-slice`, into `guild slice`, into the
  # composed `PLAN-001/<slug>` id — so it takes the CLI's one key alphabet rather than a
  # near-copy of it. `_rec_check_slug` lives in lib/records.sh; every module is sourced
  # before any command runs (scripts/guild), and this file already reaches the same way
  # into lib/render.sh for `_render_flat`. A second bracket expression here is exactly the
  # divergence that function's own comment is about, and it would decide whether the
  # architect's `auth-service` and the developer's `auth-service` are one row.
  _rec_check_slug "$slug" 'slice slug' '--title'
  _art_slice_body

  # Validated before any connection is opened, like every other argument check here: a
  # mistyped path must cost nothing and touch nothing.
  filesexpr=""
  [ "$ps_files_set" = 0 ] || filesexpr="$(_art_slice_files_expr "$ps_files")" || exit 1

  db_require_init
  journal_preflight

  planlit="$(sql_text "$plan" 'the PLAN id')"
  # The slug passed `_rec_check_slug`'s alphabet, so it is a known-safe value and sql_str
  # is right for it — it is also the one value that must read back identically in the id,
  # the error text and the journal line.
  sluglit="$(sql_str "$slug")"
  idexpr="$planlit || '/' || $sluglit"
  titlelit="$(sql_text "$ps_title" '--title')"
  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  rowexpr="$(_art_json_row plan_slice)"

  # The two column values, and the UPDATE's SET list. A column the caller did not pass is
  # absent from the SET list — that is what "omitted means preserve" costs here — and gets
  # the schema's own default on the INSERT path, where there is nothing to preserve.
  # `--title` is always restated: it is required, so it is the one field the caller is
  # unambiguously asserting on every call (`coverage set --area` works the same way).
  bodyexpr="''"
  [ "$ps_body_set" = 0 ] || bodyexpr="$(sql_text "$ps_body" "${ps_file:---body}")"
  setlist="title = $titlelit"
  [ "$ps_body_set" = 0 ] || setlist="$setlist,
    body = $bodyexpr"
  if [ -n "$filesexpr" ]; then
    # `--files ''` is an explicit clear and reaches here as '[]'.
    setlist="$setlist,
    files = $filesexpr"
  fi

  # THE PAYLOAD RECORDS THE ASSERTION, AND ONLY WHEN ONE WAS MADE. `--files` given: the
  # event carries the array, because "the architect claimed these files are disjoint" is
  # exactly the fact a later reader wants dated and attributed. `--files` omitted: the key
  # is ABSENT rather than restating what is already stored — this command did not assert
  # it, and an event log that cannot tell an assertion from an echo is one nobody can
  # audit the disjointness claim from.
  payloadexpr="json_object('slug', $sluglit, 'title', $titlelit)"
  [ -z "$filesexpr" ] ||
    payloadexpr="json_object('slug', $sluglit, 'title', $titlelit, 'files', $filesexpr)"
  [ -n "$filesexpr" ] || filesexpr="'[]'"

  sql="BEGIN;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $actorlit,
       CASE WHEN EXISTS (SELECT 1 FROM plan_slice WHERE id = $idexpr) THEN 'updated' ELSE 'created' END,
       'plan_slice', $idexpr, $payloadexpr
FROM plan WHERE id = $planlit;
UPDATE plan_slice SET $setlist
WHERE id = $idexpr
  AND EXISTS (SELECT 1 FROM plan WHERE id = $planlit)
RETURNING 'OK|' || $rowexpr;
INSERT INTO plan_slice (id, plan_id, slug, title, body, files)
SELECT $idexpr, p.id, $sluglit, $titlelit, $bodyexpr, $filesexpr
FROM plan p
WHERE p.id = $planlit
  AND NOT EXISTS (SELECT 1 FROM plan_slice WHERE id = $idexpr)
RETURNING 'OK|' || $rowexpr;
SELECT 'MISS|' || $planlit
  WHERE NOT EXISTS (SELECT 1 FROM plan WHERE id = $planlit);
COMMIT;
"

  row="$(_art_update_run "$plan" "write $plan/$slug" "$sql")" || exit 1
  journal_append plan_slice upsert "$row"
  printf '%s/%s\n' "$(_render_flat_arg "$plan")" "$slug"
}

# cmd_plan_slices <PLAN-NNN> [--files] — a plan's slices.
#
#   guild plan slices PLAN-001
#     auth-service Extract the session store
#     migrations Add the token table
#
#   guild plan slices PLAN-001 --files
#     auth-service ["src/auth/session.ts","src/auth/index.ts"]
#     migrations ["db/migrations/003_tokens.sql"]
#
# TWO SURFACES RATHER THAN ONE WIDE ONE, and the reason is the output-channel rule
# (§2.2.2) rather than taste. A title is free text with spaces in it, so it can only ever
# be the LAST field on a line; a JSON file set also contains spaces (inside its strings),
# so it too can only be last. They cannot both be last, and a line carrying them both
# would have a field boundary that neither value is forbidden to contain.
#
# The slug is `_render_col`-flattened even though the writer validated its alphabet: ids
# and slugs are replayed from `.guild/journal.ndjson`, which lives in git, and a
# structural field must not depend on who wrote that file. The file set is `_render_flat`
# on top of json_array's own escaping — belt and braces on a value that must not span
# lines. The body is never emitted here; `guild slice` is the reader for that.
#
# An existence marker leads the script so "no such plan" and "a plan with no slices"
# remain distinguishable in ONE round trip; the marker line is then dropped.
cmd_plan_slices() {
  local plan="${1-}" want_files=0 planlit cols sql tmp out
  [ -n "$plan" ] || die "guild: plan slices requires a PLAN id"
  case "$plan" in
    PLAN-*) ;;
    *) die "guild: unrecognized id '$(_render_flat_arg "$plan")' (expected PLAN-NNN)" ;;
  esac
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --files) want_files=1; shift ;;
      *) die "guild: plan slices takes a PLAN-NNN and optionally --files" ;;
    esac
  done

  db_require_init
  planlit="$(sql_text "$plan" 'the PLAN id')"
  if [ "$want_files" = 1 ]; then
    cols="$(_render_col 'slug') || ' ' || $(_render_flat 'files')"
  else
    cols="$(_render_col 'slug') || ' ' || $(_render_flat 'title')"
  fi

  sql="SELECT 'P' FROM plan WHERE id = $planlit;
SELECT $cols FROM plan_slice WHERE plan_id = $planlit ORDER BY slug;
"
  tmp="$(_art_tmpfile)" || exit 1
  if ! printf '%s' "$sql" | db_exec >"$tmp"; then
    out="$(cat "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    db_fail "could not list the slices of $plan" "$out"
  fi
  if [ "$(_art_first_line "$tmp")" != "P" ]; then
    rm -f "$tmp"
    die "guild: $plan not found"
  fi
  tail -n +2 "$tmp"
  rm -f "$tmp"
}

# cmd_plan <slice|slices> [args...] — the `guild plan` namespace.
#
# `guild new plan` still CREATES a plan; this namespace is about what is INSIDE one. They
# are deliberately not folded together: `new` takes `--title/--req` and prints a new
# PLAN-NNN, while these take an existing plan and address a slice within it, and
# overloading `new` would have made `guild new plan --slug` mean something in one flag
# combination and nothing in another.
cmd_plan() {
  local sub="${1-}"
  [ $# -eq 0 ] || shift
  case "$sub" in
    slice) cmd_plan_slice "$@" ;;
    slices) cmd_plan_slices "$@" ;;
    new)
      die "guild: a plan is created with 'guild new plan' —

  guild new plan --title T --req REQ-NNN [--desc D | --body B] [--task TASK-NNN]

'guild plan' addresses what is inside an existing plan: slice, slices."
      ;;
    '')
      die "guild: plan needs a subcommand

  guild plan slice  <PLAN-NNN> --slug SLUG --title T [--body B | --file F] [--files \"a,b,c\"]
  guild plan slices <PLAN-NNN> [--files]

A slice is one unit of parallel implementation work. --files is the architect's
disjoint-file assertion: the files this slice touches, and nothing else touches."
      ;;
    *) die "guild: unknown plan subcommand '$sub' (slice|slices)" ;;
  esac
}

# cmd_next_id <req|task|plan> — the next numeric ID for a kind, zero-padded to 3 digits
# and WITHOUT the prefix, as v4 printed it.
cmd_next_id() {
  local kind="${1-}" table off
  table="$(art_table "$kind")" || exit 1
  off="$(art_num_offset "$kind")" || exit 1
  db_require_init
  printf "SELECT printf('%%03d', COALESCE(MAX(CAST(substr(id,%s) AS INTEGER)),0) + 1) FROM %s;\n" \
    "$off" "$table" | db_exec
}

# ---- status transitions ------------------------------------------------------------

# cmd_move <ID> <status> — validate the status against the kind, update, journal it.
# Prints the ID (v4 printed the destination file's path; there is no such file now).
#
# THE ONE REFUSED TRANSITION: `blocked -> done`. Everything else stays as it always was —
# any valid status to any valid status, no state machine — and that restraint is
# deliberate: a transition matrix nobody asked for is a set of rules people forget, and
# v4 had none.
#
# This one earns the exception because it is the exact shape of the failure mode §5.2
# warns about. `blocked` means NO GUILD MEMBER CAN TAKE THIS BOUNTY. `done` means it is
# finished. One command turning the first into the second is how a roster gap becomes a
# closed requirement in silence — and it is a plausible mistake, not an adversarial one:
# a skill sweeping "everything on this requirement" to done, or a user clearing a board.
# It cannot arrive from the normal path, because `guild next` never hands out a blocked
# task, so nothing legitimate is being taken away.
#
# The refusal names all three legitimate exits, because the guiding rule for this status
# is that it must never be a quiet dead end — and an error that only says "no" is exactly
# that. Note that `blocked -> todo -> done` remains available in two commands: the point
# is not to make it impossible, it is to make it deliberate and to leave two events
# behind instead of one.
#
# IT COSTS NO EXTRA ROUND TRIP. The rule needs the row's CURRENT status, which is a read,
# and a read before the write would be a second db_exec — the one thing this file never
# does. So the rule is carried by the write instead: when the target is `done` on a task,
# both the event insert and the UPDATE grow `AND status <> 'blocked'`, and one guarded
# `SELECT 'BLOCKED'` joins the same script. A refused move therefore matches no row
# anywhere — no event, no update, no journal line, nothing to undo — and the marker is
# what separates "refused" from "no such ID", which are otherwise both an empty result.
#
# The guard is on the EVENT as well as the UPDATE, and that is not belt-and-braces: the
# event is written first, so without it a refused move would announce a `moved` event for
# a transition that never happened. Verified: after a refused `blocked -> done` the event
# table holds exactly the earlier `moved` to blocked, and journal.ndjson is unchanged.
cmd_move() {
  local id="${1-}" target="${2-}" kind table statuses ok st idlit now nowlit rowexpr
  local sql out line row guard probe
  [ -n "$id" ] || die "guild: move requires an ID"
  [ -n "$target" ] || die "guild: move requires a status"
  kind="$(art_kind_of_id "$id")" || exit 1
  table="$(art_table "$kind")" || exit 1
  statuses="$(art_statuses "$kind")" || exit 1

  ok=0
  for st in $statuses; do
    if [ "$st" = "$target" ]; then ok=1; fi
  done
  [ "$ok" = 1 ] ||
    die "guild: invalid status '$target' for $kind (allowed: $statuses)"

  db_require_init
  journal_preflight
  # `$target` is sql_str because it was just validated against art_statuses — a fixed,
  # known-safe set. `$id` is only prefix-checked, so it is free text (§2.2.1).
  idlit="$(sql_text "$id" 'the ID argument')"
  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  rowexpr="$(_art_json_row "$table")" || exit 1

  # The blocked->done guard, and the probe that tells the two empty results apart. Both
  # are empty for every other kind and every other target, so a task moving to any other
  # status — and a requirement or plan moving at all — composes the exact Stage 2 script.
  guard=""
  probe=""
  if [ "$table" = "task" ] && [ "$target" = "done" ]; then
    guard=" AND status <> 'blocked'"
    probe="SELECT 'BLOCKED' FROM task WHERE id = $idlit AND status = 'blocked';
"
  fi

  # The event is written BEFORE the update so its payload can carry both ends of the
  # transition; the update's RETURNING then yields the resulting row for the journal.
  # The event carries the SAME guard as the update — otherwise a refused move would
  # announce a transition that never happened.
  sql="BEGIN;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $(sql_text "$(_art_actor)" "\$GUILD_ACTOR"), 'moved', $(sql_str "$table"), id,
       json_object('from', status, 'to', $(sql_str "$target"))
FROM $table WHERE id = $idlit$guard;
UPDATE $table SET status = $(sql_str "$target"), updated_at = $nowlit
WHERE id = $idlit$guard
RETURNING 'OK|' || id || '|' || $rowexpr;
$probe
COMMIT;
"
  if ! out="$(printf '%s' "$sql" | db_exec)"; then
    db_fail "could not move $id" "$out"
  fi
  line="$(printf '%s' "$out" | head -n1)"
  # The refusal is recognized by scanning the WHOLE buffer for the exact line, not by
  # reading line 1: when the UPDATE matches nothing there is no RETURNING row, and what
  # precedes the probe's output is then whatever the driver felt like emitting. The
  # marker cannot be forged — it is a bare literal in the SQL, and the only other line
  # this script can produce is a `json_object` row, whose newlines are escaped as `\n`.
  if [ "${line#OK|}" = "$line" ] &&
    printf '%s\n' "$out" | LC_ALL=C grep -qx 'BLOCKED'; then
    die "guild: $id is blocked — it cannot move straight to 'done'.

'blocked' means no guild member can take this bounty, so nothing has ever been attempted
and there is nothing to call finished. Marking it done would close the requirement over an
un-attempted slice, and nobody would ever hear about it.

Three ways out, each of which leaves a record:

  guild move $id todo
      you recruited someone for it — add the agent file, run guild sync-agents, and this
      puts the bounty back on the board
  guild move $id in-progress
      you are giving it to a member in spite of the gap
  guild move $id failed
      you are giving up on it. 'failed' is the adjudicated status: it stops holding the
      requirement's review gate, which is exactly what 'blocked' does not do.

If you really do mean 'this slice turned out not to be needed', say so through 'todo'
first — two commands and two events, rather than one that erases the gap."
  fi
  case "$line" in
    'OK|'*) ;;
    *) die "guild: $id not found" ;;
  esac
  row="${line#OK|}"
  row="${row#*|}"
  case "$row" in
    '{'*'}') ;;
    *) die "guild: could not move $id (unexpected database output)" ;;
  esac

  journal_append "$table" upsert "$row"
  printf '%s\n' "$id"
}

# ---- edits -------------------------------------------------------------------------

# cmd_retitle <ID> <new title>   (also accepts `cmd_retitle <ID> --title "new title"`)
#
# v4's check-in "adjust the backlog" step retitled a ticket by editing the `title:` line
# of its file's frontmatter. v5 has no file and `title` is a column, so this is the
# replacement. Prints the ID.
#
# It also fixes up the body's `# <title>` heading, which the `new req` / `new plan`
# templates write from the title: without this, retitling leaves `guild read` showing a
# heading that contradicts the frontmatter directly above it. The rewrite fires ONLY when
# the body's first line is exactly `# <old title>`, so a body an agent has since rewritten
# is left alone. Task bodies start `## Objective`, so they never match — the same
# expression is used for all three kinds because it is self-guarding, not because tasks
# need it.
#
# The old title is available to the SET clause: in an UPDATE, every right-hand side sees
# the row's PRE-UPDATE values, so `title` inside the CASE is the old title even though the
# same statement assigns the new one. Verified against tursodb 0.7.2, not assumed.
cmd_retitle() {
  local id="${1-}" title kind table idlit now nowlit titlelit rowexpr sql out line row
  [ -n "$id" ] || die "guild: retitle requires an ID"
  kind="$(art_kind_of_id "$id")" || exit 1
  table="$(art_table "$kind")" || exit 1
  shift
  if [ "${1-}" = "--title" ]; then
    shift
    title="${1-}"
  else
    title="${1-}"
  fi
  [ -n "$title" ] || die "guild: retitle requires a new title"

  db_require_init
  journal_preflight
  idlit="$(sql_text "$id" 'the ID argument')"
  titlelit="$(sql_text "$title" 'the new title')"
  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  rowexpr="$(_art_json_row "$table")" || exit 1

  # The event goes first so its payload can carry the old title, exactly as cmd_move
  # writes the `moved` event before the status changes.
  sql="BEGIN;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $(sql_text "$(_art_actor)" "\$GUILD_ACTOR"), 'retitled', $(sql_str "$table"), id,
       json_object('from', title, 'to', $titlelit)
FROM $table WHERE id = $idlit;
UPDATE $table
SET body = CASE
             WHEN substr(body, 1, length('# ' || title) + 1) = '# ' || title || '
'            THEN '# ' || $titlelit || substr(body, length('# ' || title) + 1)
             ELSE body
           END,
    title = $titlelit,
    updated_at = $nowlit
WHERE id = $idlit
RETURNING 'OK|' || id || '|' || $rowexpr;
COMMIT;
"
  if ! out="$(printf '%s' "$sql" | db_exec)"; then
    db_fail "could not retitle $id" "$out"
  fi
  line="$(printf '%s' "$out" | head -n1)"
  case "$line" in
    'OK|'*) ;;
    *) die "guild: $id not found" ;;
  esac
  row="${line#OK|}"
  row="${row#*|}"
  case "$row" in
    '{'*'}') ;;
    *) die "guild: could not retitle $id (unexpected database output)" ;;
  esac

  journal_append "$table" upsert "$row"
  printf '%s\n' "$id"
}

# ---- session state -----------------------------------------------------------------

# cmd_checkin [DATE] — set `last-checkin` to DATE (default: today, UTC). Prints the date.
#
# v4's check-in skill wrote this every session by editing `.guild/state.yaml`. v5 moved it
# to a `guild_state` row and then shipped no writer for it, so `guild board`'s
# `Last check-in:` was pinned to the init date forever. This is that writer.
#
# Upsert rather than UPDATE: schema.sql seeds the row, but a guild rebuilt from a journal
# that predates the seed would not have it, and an upsert costs nothing.
cmd_checkin() {
  local date_arg="${1-}" now nowlit datelit sql out line row nl
  nl=$'\n'
  db_require_init
  journal_preflight
  [ -n "$date_arg" ] || date_arg="$(date -u +%Y-%m-%d)"
  case "$date_arg" in
    *"$nl"*) die "guild: check-in date must be a single line" ;;
  esac

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  datelit="$(sql_text "$date_arg" 'the check-in date')"

  sql="BEGIN;
INSERT INTO guild_state (key, value) VALUES ('last-checkin', $datelit)
ON CONFLICT(key) DO UPDATE SET value = excluded.value
RETURNING 'OK|' || $(_art_json_row guild_state);
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
VALUES ($nowlit, $(sql_text "$(_art_actor)" "\$GUILD_ACTOR"), 'checked-in', 'guild_state', 'last-checkin',
        json_object('date', $datelit));
COMMIT;
"
  if ! out="$(printf '%s' "$sql" | db_exec)"; then
    db_fail "could not record the check-in" "$out"
  fi
  line="$(printf '%s' "$out" | head -n1)"
  case "$line" in
    'OK|{'*'}') ;;
    *) die "guild: could not record the check-in (unexpected database output)" ;;
  esac
  row="${line#OK|}"

  journal_append guild_state upsert "$row"
  printf '%s\n' "$date_arg"
}

# ---- query -------------------------------------------------------------------------

# cmd_list <kind> [status] — "<ID> <status>" lines, sorted by ID; task lines carry the
# extra "<agent> <requirement>" columns the orchestrator filters on with awk.
#
# The whole line is composed in SQL, so the pipe-separated transport never has to be
# parsed. An empty agent yields v4's double space, because v4 interpolated an empty
# `$(fm ... agent)` in exactly the same position.
#
# EVERY COLUMN IS `_render_col`, NOT `_render_flat`, and the difference is the whole
# finding. This output is ROWS — one artifact per line, WHITESPACE-SEPARATED FIELDS — and
# `guild help` documents the orchestrator filtering it with
# `awk '$3 == "reviewer" && $4 == "REQ-001"'`. Flattening alone fixed only half of it:
# a multi-line `--agent` no longer prints a second line that awk reads as a whole extra
# artifact, but flattening turns those newlines into SPACES, and on a whitespace-separated
# surface a space is the same attack one field to the right:
#
#   guild new task --agent 'reviewer REQ-001' --req REQ-002
#   TASK-002 todo reviewer REQ-001 REQ-002      <- that filter MATCHES; the truth is REQ-002
#
# and a benign multi-word agent (`developer svelte`) breaks the same filter the other way
# by shifting `$4`. A fabricated match here is immediately actionable — the orchestrator
# dispatches on it. `_render_col` therefore leaves no blank inside a field, so the row
# count is always the artifact count AND the field count is always the column count.
# The price is that this surface is a filter rather than a round trip; the byte-exact
# value is `guild meta <ID> agent`, one round trip away.
cmd_list() {
  local kind="${1-}" filter="${2-}" table cols where
  table="$(art_table "$kind")" || exit 1
  db_require_init

  if [ "$table" = "task" ]; then
    # `_render_task_who`, not `COALESCE(agent,'')`: Stage 3 made `--agent` optional, and an
    # EMPTY third field does not print as an empty field on a whitespace-separated row —
    # it collapses, and every `awk '$3 == "reviewer" && $4 == "REQ-001"'` in the plugin
    # starts reading the requirement id as the agent. A capability-routed ticket reports
    # `needs:implement+rust` here instead. See _render_task_who in lib/render.sh.
    cols="$(_render_col 'id') || ' ' || $(_render_col 'status') || ' '"
    cols="$cols || $(_render_col "$(_render_task_who 'task.id')") || ' ' || $(_render_col 'requirement_id')"
  else
    cols="$(_render_col 'id') || ' ' || $(_render_col 'status')"
  fi
  where=""
  # The status filter is NOT validated here (v4 accepted any word and simply matched
  # nothing), so it is argv free text.
  [ -z "$filter" ] || where=" WHERE status = $(sql_text "$filter" 'the status filter')"

  printf 'SELECT %s FROM %s%s ORDER BY id;\n' "$cols" "$table" "$where" | db_exec
}

# cmd_next — v4's cursor rule:
#   1. resume the lowest-ID in-progress task;
#   2. else the lowest-ID todo task, with the review gate;
#   3. else "none".
#
# A BLOCKED TASK IS NOT ACTIONABLE and neither query can return one: they ask for
# `in-progress` and `todo` by name. That is not an accident to be tidied up later —
# `blocked` means no roster member can take the bounty (§5.2), so handing it to the
# orchestrator would produce a dispatch with nobody to dispatch to.
#
# A BLOCKED TASK DOES, HOWEVER, HOLD THE REVIEW GATE (decision 2 of THE BLOCKED CONTRACT
# at the top of this file). See the gate note below.
#
# The review gate: a task whose `agent` is exactly `reviewer` is skipped while any
# NON-REVIEWER task for its requirement is still todo or in-progress. `reviewer` is
# matched exactly, not by prefix, because v4 matched exactly and the check-in skill files
# ONE ticket with `--agent reviewer` which it then fans out to the four specialized
# reviewer agents at dispatch; matching `reviewer-security` and friends here would gate
# tickets that never exist.
#
# THE `AND COALESCE(o.agent,'') <> 'reviewer'` IN THE GATE IS A DELIBERATE v4 BEHAVIOR
# CHANGE. v4 (and this file's first draft) excluded every other OPEN task, reviewers
# included, so two `reviewer` tickets on one requirement gated each other and `guild next`
# answered `none` forever — a real, reproducible deadlock, not a theoretical one, and the
# comment that used to sit here claimed exact matching made it impossible. It does not.
# Ignoring other reviewers in the gate means: reviewers wait for all the work, then run
# one at a time in ID order (ORDER BY t.id LIMIT 1 picks the lowest). With the one
# reviewer ticket per requirement the skills actually file, the behavior is bit-identical
# to v4 — the extra predicate can only matter when a second reviewer ticket exists, which
# is precisely the case v4 hung on.
#
# `blocked` IS IN THE GATE'S OPEN SET (`todo`, `in-progress`, `blocked`) and `failed` is
# not. The full argument is decision 2 of THE BLOCKED CONTRACT; the short version is that
# `failed` has been ruled on by a human and `blocked` has not, and a review that runs over
# an un-attempted slice produces a green that looks exactly like a real one. This is the
# ONE predicate in the CLI that lib/brief.sh copies verbatim (`_brief_bounty_where`), and
# that file's header forbids the two from diverging: change both or neither.
#
# It cannot deadlock the way the two-reviewers case did. A blocked task has three exits,
# all one command away and all named by cmd_move's refusal message, and every surface the
# guild has says a blocked task is sitting there. The gate waits for a human; it does not
# wait for nothing.
#
# Both candidates are asked for in one script; the shell picks the first that answered.
# NOT EXISTS over direct rows, no recursion (§3.0).
#
# The two candidates are tagged `A|` / `B|`, so the tag is a structural token and the id
# is flattened before it joins one — and the shell reads the id with substr past the tag
# rather than splitting on `|`, so an id containing a pipe is returned whole instead of
# truncated. Ids are generated here, but `guild rebuild` replays them from the journal,
# which is a file in git; a forged second line would have made `guild next` answer with a
# task that does not exist, which the orchestrator then dispatches.
cmd_next() {
  local sql out id
  db_require_init

  sql="SELECT 'A|' || $(_render_flat 'id') FROM task WHERE status = 'in-progress' ORDER BY id LIMIT 1;
SELECT 'B|' || $(_render_flat 't.id') FROM task t
WHERE t.status = 'todo'
  AND ( COALESCE(t.agent,'') <> 'reviewer'
        OR NOT EXISTS (SELECT 1 FROM task o
                        WHERE o.requirement_id = t.requirement_id
                          AND o.id <> t.id
                          AND o.status IN ('todo','in-progress','blocked')
                          AND COALESCE(o.agent,'') <> 'reviewer') )
ORDER BY t.id LIMIT 1;
"
  if ! out="$(printf '%s' "$sql" | db_exec)"; then
    db_fail "could not read the next task from the database" "$out"
  fi

  id="$(printf '%s\n' "$out" | LC_ALL=C awk '/^A\|/ { print substr($0, 3); exit }')"
  if [ -z "$id" ]; then
    id="$(printf '%s\n' "$out" | LC_ALL=C awk '/^B\|/ { print substr($0, 3); exit }')"
  fi
  if [ -z "$id" ]; then
    printf 'none\n'
    return 0
  fi
  printf '%s\n' "$id"
}

# cmd_batch <TASK-ID> — the task IDs that must dispatch together: every todo/in-progress
# task sharing this one's `parallel-group` AND `requirement`. A task with no group is a
# batch of one.
#
# A BLOCKED MEMBER IS EXCLUDED, and the group still dispatches without it (decision 6 of
# THE BLOCKED CONTRACT). It cannot be dispatched — that is what blocked means — and a
# parallel group's slices are disjoint-file by construction, so the members that can run
# have no reason to wait. Holding the whole batch would convert one roster gap into a
# stalled group while telling the user nothing they did not already see on the board.
# The review gate is where a blocked slice is accounted for; the batch is not.
#
# The group is reported alongside the members in the same round trip, because "no rows"
# is otherwise ambiguous between "ungrouped" (print the task itself, v4's batch of one)
# and "grouped, but no member is still open" (print nothing, which v4 also did).
#
# `parallel_group` IS FREE TEXT — `--parallel-group` is unvalidated argv — and it shares
# this marker-tagged channel with the member ids, so it is flattened. Unflattened, a
# group named `x<newline>G|TASK-999` printed a second line the member parser read as a
# member, and `guild batch` is the command the orchestrator uses to decide which tasks to
# dispatch TOGETHER: a fabricated member is a dispatched ghost. Member ids are flattened
# for the same reason and read with substr past the tag, so a pipe cannot truncate one.
cmd_batch() {
  local id="${1-}" idlit sql out grp members
  [ -n "$id" ] || die "guild: batch requires a TASK id"
  case "$id" in
    TASK-*) ;;
    *) die "guild: unrecognized id '$id'" ;;
  esac
  db_require_init
  idlit="$(sql_text "$id" 'the ID argument')"

  sql="SELECT 'P|' || $(_render_flat "COALESCE(parallel_group,'')") FROM task WHERE id = $idlit;
SELECT 'G|' || $(_render_flat 't2.id') FROM task t2, task t1
WHERE t1.id = $idlit
  AND COALESCE(t1.parallel_group,'') <> ''
  AND t2.parallel_group = t1.parallel_group
  AND t2.requirement_id = t1.requirement_id
  AND t2.status IN ('todo','in-progress')
ORDER BY t2.id;
"
  if ! out="$(printf '%s' "$sql" | db_exec)"; then
    db_fail "could not read the batch for $id" "$out"
  fi

  if ! printf '%s\n' "$out" | LC_ALL=C grep -q '^P|'; then
    die "guild: $id not found"
  fi
  grp="$(printf '%s\n' "$out" | LC_ALL=C awk '/^P\|/ { print substr($0, 3); exit }')"
  if [ -z "$grp" ]; then
    printf '%s\n' "$id"
    return 0
  fi
  members="$(printf '%s\n' "$out" | LC_ALL=C awk '/^G\|/ { print substr($0, 3) }')"
  [ -z "$members" ] || printf '%s\n' "$members"
}

# ---- the agent write path (§2.4) ---------------------------------------------------
#
# This is what v4 did by having agents Edit the `## Work Log` section of their ticket
# file. There is no ticket file, and there is no second writer to the database either:
# in local mode every CLI invocation is its own tursodb process and multi-process WAL is
# an unstable opt-in (§2.4), so seven concurrent agents writing rows is exactly the case
# that does not work.
#
# So: `guild log` and `guild finding` APPEND ONE LINE TO A FILE — `.guild/spool/<ID>.ndjson`,
# a plain O_APPEND write with no cross-process contention and no database connection at
# all. The orchestrator later runs `guild spool drain <ID>`, as the single writer, and
# that is where the rows and the journal lines appear.
#
# Nothing here journals: a spool entry is not a row yet, and the journal records resulting
# ROW STATE (§2.3). cmd_spool_drain journals what the drain produced.
#
# Why this matters beyond tidiness: with no writer for `work_log`, check-in's triage rule
# "empty Work Log -> never started -> move it back to todo" fires on EVERY resumed task,
# so every session resets all in-flight work and redoes it. Crash-safe resume, which §1
# lists as surviving v4 unchanged, does not exist without these three commands.

# _art_parse_report_flags <args...> — flags for `log` and `finding`.
#
# Kept separate from _art_parse_flags rather than folded into it: that function's flag set
# and its reset list are v4's `new` contract, and these commands are new. Same shape,
# same "unknown --flag consumes its value" tolerance.
_art_parse_report_flags() {
  art_r_agent=""
  art_r_entry=""
  art_r_reviewer=""
  art_r_severity=""
  art_r_summary=""
  art_r_detail=""
  art_r_file=""
  art_r_line=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) shift; art_r_agent="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --entry) shift; art_r_entry="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --reviewer) shift; art_r_reviewer="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --severity) shift; art_r_severity="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --summary) shift; art_r_summary="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --detail) shift; art_r_detail="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --file) shift; art_r_file="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --line) shift; art_r_line="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --*) shift; if [ $# -gt 0 ]; then shift; fi ;;
      *) shift ;;
    esac
  done
}

# _art_require_task_id <ID> <command-name> — shape check only.
#
# Deliberately NOT an existence check: an existence check is a database read, and the
# whole point of the spool is that an agent's report never opens a connection. A bad ID
# surfaces at drain time, where the work_log foreign key rejects it and spool_drain keeps
# the spool file rather than dropping the entries.
_art_require_task_id() {
  local id="${1-}" what="${2-}"
  [ -n "$id" ] || die "guild: $what requires a TASK id"
  case "$id" in
    TASK-*) ;;
    *) die "guild: unrecognized id '$id'" ;;
  esac
}

# cmd_log <TASK-ID> --agent A --entry "..." — append one work-log entry to the spool.
# Silent on success.
cmd_log() {
  local id="${1-}" now
  _art_require_task_id "$id" log
  shift
  _art_parse_report_flags ${1+"$@"}
  [ -n "$art_r_agent" ] || die "guild: log requires --agent"
  [ -n "$art_r_entry" ] || die "guild: log requires --entry"

  db_require_init
  now="$(db_now)"
  # journal_row is the one flat-JSON builder in the CLI (lib/journal.sh); it escapes
  # through json_escape, so an entry containing quotes, backslashes or newlines cannot
  # break the NDJSON line. The name says journal; the job is JSON.
  spool_append "$id" \
    "$(journal_row ts "$now" kind log agent "$art_r_agent" entry "$art_r_entry")"
}

# cmd_finding <TASK-ID> --reviewer R --severity S --summary "..." [--detail D]
#             [--file F] [--line N]
# Append one review finding to the spool. Silent on success.
cmd_finding() {
  local id="${1-}" now
  _art_require_task_id "$id" finding
  shift
  _art_parse_report_flags ${1+"$@"}
  [ -n "$art_r_reviewer" ] || die "guild: finding requires --reviewer"
  [ -n "$art_r_severity" ] || die "guild: finding requires --severity"
  [ -n "$art_r_summary" ] || die "guild: finding requires --summary"
  case "$art_r_severity" in
    critical | major | minor | nit) ;;
    *) die "guild: invalid severity '$art_r_severity' (allowed: critical major minor nit)" ;;
  esac
  if [ -n "$art_r_line" ]; then
    case "$art_r_line" in
      *[!0-9]*) die "guild: --line must be a whole number (got '$art_r_line')" ;;
    esac
    # STRIP LEADING ZEROS, and it is not cosmetic. `--line 007` is what an agent quoting
    # a diff hunk or a padded log writes. It passes the digits-only check above and used
    # to be emitted RAW into the spool as `"line":007` — which is not valid JSON, so
    # json_valid() rejected the whole entry at drain time and the finding was quarantined
    # while `guild finding` had already exited 0 in silence. Normalizing here means the
    # value the reviewer meant is the value that is stored. `10#` arithmetic is avoided
    # deliberately: it overflows on a long run of digits, and this cannot fail.
    while [ "${art_r_line#0}" != "$art_r_line" ] && [ -n "${art_r_line#0}" ]; do
      art_r_line="${art_r_line#0}"
    done
  fi

  db_require_init
  now="$(db_now)"
  # Optional fields are OMITTED rather than sent empty: _spool_sql maps a missing key to
  # SQL NULL for `file`/`line`, which is what "no location" means in review_finding, while
  # an empty string would claim a file named ''. `#line` emits a JSON number, because the
  # column is INTEGER in a STRICT table.
  set -- ts "$now" kind finding \
    reviewer "$art_r_reviewer" severity "$art_r_severity" \
    summary "$art_r_summary" detail "$art_r_detail"
  [ -z "$art_r_file" ] || set -- "$@" file "$art_r_file"
  [ -z "$art_r_line" ] || set -- "$@" '#line' "$art_r_line"
  spool_append "$id" "$(journal_row "$@")"
}

# cmd_spool_drain <TASK-ID> — orchestrator side: fold the task's spool into the database
# and journal what landed. Silent on success; a task with no spool is a no-op that touches
# nothing at all.
#
# spool_drain (lib/db.sh) owns the SQL and the ordering guarantee (the file is unlinked
# only after the SQL succeeds). What it does not do is journal, and `guild rebuild` moves
# the live database aside before replaying — so without the second half of this function
# every work-log entry and every review finding is destroyed by the documented recovery
# path.
#
# THAT SECOND HALF IS lib/journal.sh's `journal_sync`, NOT A SECOND COPY OF IT HERE. An
# earlier draft of this function did its own read-back: one query for the task's work_log
# and review_finding rows, then a journal_append per row. It worked, but it was a second
# mechanism for a job the journal module already owns, and it journaled ALL of the task's
# rows on every drain — so draining a task three times wrote its whole log into the
# journal three times, and the journal is the file git carries.
#
# journal_sync is exact instead: it compares ROW IDENTITY — for these surrogate-key tables
# that is the row's immutable CONTENT, not its integer id — and journals only what the
# journal does not already carry. (It is deliberately NOT an id high-water mark: journal.ndjson
# is committed to git, so the journal's ids and this database's ids stop being one sequence
# the moment anyone pulls, and a high-water mark then skips a local row and `guild rebuild`
# destroys it. See journal_sync's own header.) Re-draining costs nothing. It also has one
# caller-visible difference — it reconciles EVERY task's un-journaled rows, not just this
# one's — which is strictly the direction we want from a durability step, and is the same
# call `guild rebuild` makes before replaying.
#
# It spends two round trips (a PRAGMA batch and a dump) where the old read-back spent one.
# A drain is an orchestrator-side maintenance step, not a hot path, and correctness of the
# one file git carries outranks a round trip here.
cmd_spool_drain() {
  local id="${1-}" spath
  _art_require_task_id "$id" 'spool drain'
  db_require_init
  journal_preflight
  spath="$(spool_path "$id")"
  [ -f "$spath" ] || return 0

  spool_drain "$id"
  # `event` is deliberately NOT in this list, even though the drain now writes event rows
  # (lib/db.sh `_spool_sql`). No command journals its events inline — the whole table is
  # reconciled on demand, and `journal_rebuild`'s own preflight syncs `event` before it
  # moves the database aside, so the drain's rows are protected by the same mechanism that
  # protects every other command's. Naming it here instead would make one drain flush every
  # un-journaled event on the board into git, which is a different operation wearing this
  # one's name.
  journal_sync work_log review_finding >/dev/null
}

# cmd_spool <drain> <TASK-ID> — the `guild spool` sub-dispatch, shaped like cmd_new.
cmd_spool() {
  local sub="${1-}"
  [ $# -ge 1 ] || die "guild: unknown 'spool' target '' (drain)"
  shift
  case "$sub" in
    drain) cmd_spool_drain "$@" ;;
    *) die "guild: unknown 'spool' target '$sub' (drain)" ;;
  esac
}
