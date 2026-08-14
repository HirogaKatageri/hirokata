# shellcheck shell=bash
#
# lib/roster.sh — guild v5 Stage 3: THE ROSTER (design §5).
#
#   > Tasks stop naming an agent and start naming a required capability.
#
# That one sentence is the whole stage. In v4 (and in Stage 1/2 of v5) a ticket carries
# `--agent developer-svelte`, which hardcodes the roster into the skills and the chain.
# In v5 a ticket declares `needs: [implement, svelte]` and ANY agent whose capabilities
# cover that set is eligible — so adding `agents/developer-rust.md` with the right tags
# makes it claimable with no skill edits and no chain rewiring.
#
#   guild sync-agents [--dry-run]        agents/*.md frontmatter -> agent + agent_capability
#   guild match <TASK-ID> [--json]       the ranked eligible agents (§5.2, exactly)
#   guild bounties [--json]              what can be worked right now, and what cannot
#   guild capability-request <cap> ...   file a roster gap (§5.4)
#   guild capability-requests [--open]   list the gaps awaiting a decision
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` (scripts/guild owns those).
# Bash 3.2 compatible: no associative arrays, no `declare -A`, no `mapfile`, no ${var^^}.
#
# Depends on lib/db.sh       : die, db_fail, db_require_init, db_exec, db_query, db_now,
#                              sql_str, sql_text
#          on lib/journal.sh : journal_preflight, journal_append
#          on lib/artifacts.sh: _art_actor, _art_tmpfile, _art_first_line
#          on lib/records.sh : _rec_check_slug (THE identifier alphabet)
#          on lib/render.sh  : _render_flat, _render_flat_arg, _render_col, _render_tmp,
#                              _render_query
#          on lib/brief.sh   : _brief_bounty_where, _brief_blocked_where, _brief_clip
#
# THOSE DEPENDENCIES ARE DELIBERATE REUSE, NOT CONVENIENCE — the rule lib/records.sh and
# lib/quality.sh both state in their headers, for the reason Stage 1's four review rounds
# earned it. Two of them are load-bearing here in particular:
#
#   * `_brief_bounty_where` IS `guild next`'s candidate rule. `guild bounties` must not
#     offer work `guild next` would refuse to hand out, or refuse work it would offer, so
#     it calls that predicate rather than restating it. When Stage 4 teaches `cmd_next`
#     about `task_dependency`, all three change together because there is one of them.
#   * `_rec_check_slug` is THE identifier alphabet (and the reason it is `LC_ALL=C`).
#     An agent NAME is a key of exactly its kind, so it gets that function, not a near-copy.
#     A CAPABILITY token gets a stricter one — see `_roster_check_cap` for why the extra
#     restriction is the point rather than an oversight.
#
# ---------------------------------------------------------------------------------
# HARD RULES honored throughout (§2.2, §2.2.1, §3.0):
#
#   * ONE db_exec PER LOGICAL COMMAND. `sync-agents` composes ONE script covering every
#     agent file — the diagnostics, the upserts, the capability replacement, the
#     deactivations, the events — and runs it once. The statement count grows with the
#     ROSTER (14 files today), never with the data; that is the distinction lib/db.sh's
#     header draws. Every other command here is a single statement group as well — the
#     insert, its diagnostics and its `event` row travel together, so a refusal and its
#     reason arrive in the same buffer.
#
#   * sql_text FOR ALL FREE TEXT; sql_str ONLY for known-safe alphabets. An agent's
#     `model:` and `description:` are whatever somebody typed into a markdown file, and a
#     `--rationale` is a paragraph that routinely quotes code — all hex. Only the values
#     validated here against a closed alphabet (an agent name, a capability token, a
#     serial digit) reach SQL through sql_str.
#
#   * A VALUE MUST NEVER IMPERSONATE A STRUCTURAL TOKEN. Every surface in this file is
#     COLUMNAR and awk-filterable, so every leading column is `_render_col` (no blank can
#     survive inside a field) and the one free-text column — a title, a rationale — is
#     `_render_flat` and comes LAST on the line. The internal marker channel
#     (`R|<table>|<op>|<json>`) puts the only value that can hold a pipe LAST and is split
#     on the first two pipes, never on all of them.
#
#   * EVERY MUTATION IS JOURNALED AND EMITS AN `event` ROW. `guild brief`'s Roster Gaps
#     section and the dashboard's activity feed are both built on those rows; a mutation
#     that records no event is invisible to the entire reason Stage 2 exists.
#     journal_preflight runs BEFORE any SQL.
#
#   * No FTS5, no WITH RECURSIVE, no generated columns, none of the five banned window
#     functions. RANK IS NOT A WINDOW FUNCTION HERE: §5.2's ordering is expressed as an
#     `ORDER BY` and the rank is the ROW'S POSITION, assigned by the reader. That is why
#     `guild match` can be deterministic without `row_number()`.
#
# ---------------------------------------------------------------------------------
# THE FALLBACK, WHICH IS THE WHOLE OF BACKWARD COMPATIBILITY
#
# Every board that exists today was built by Stage 1/2: every task carries
# `task.agent = 'developer'` and NOT ONE has a `task_capability` row, and no guild has
# ever run `guild sync-agents`, so the `agent` table is empty as well.
#
#   A TASK WITH NO `task_capability` ROWS AT ALL MATCHES ITS `task.agent`, DIRECTLY.
#
# Not "falls back if the capability match finds nothing" — that would be wrong, because a
# task with an empty REQUIRED set is vacuously covered by every agent in the roster and
# would match all of them. The switch is the PRESENCE of any `task_capability` row for the
# task, required or preferred:
#
#   no rows      -> `guild match` prints exactly one candidate, `task.agent`, source
#                   `ticket`. It does not consult the `agent` table at all, so it works on
#                   a guild that has never synced and on an agent that has no file.
#   any row      -> §5.2 runs in full, and `task.agent` is NOT a rescue: a task that
#                   declared capabilities and covers none of them has no eligible agent
#                   and is a roster gap, which is the entire point of declaring them.
#
# So an existing board behaves exactly as it does today, and `guild bounties` on it is
# `guild next`'s candidate set with the ticket's own agent beside each row. Nothing about
# Stage 3 is opt-out; it is opt-IN, one `--needs` at a time.
#
# THE PIN IS A THIRD CASE, AND IT IS NOT THE FALLBACK. §5.2's last paragraph: "The
# architect may still pin a specific agent when it genuinely matters." `guild new task`
# accepts `--agent A` and `--needs …` TOGETHER and documents that combination as exactly
# that — pin a member AND record what the work needed. So:
#
#   agent set    -> `guild match` ranks `task.agent` FIRST, source `pin`, and the eligible
#   AND rows        members follow it (minus the pinned one) so the deviation is visible
#                   rather than merely obeyed. Rank 1 is still what the orchestrator
#                   dispatches, so the pin is what runs.
#
# WITHOUT THIS THE CLI CONTRADICTED ITSELF ON ONE TICKET: `guild list` and `guild board`
# print `task.agent` when it is set, while the matcher ignored it whenever any capability
# row existed — so a ticket pinned to `developer-svelte` listed as `developer-svelte` and
# dispatched to `developer`. Two surfaces, two answers to "who has this bounty".
#
# A PINNED TICKET IS NEVER A ROSTER GAP. The pin is somebody the guild master named; that
# the roster cannot independently cover the capabilities is a deviation to review, not a
# bounty nobody can take. `guild bounties` therefore treats a pinned ticket as workable
# and never reports `no-eligible-agent` for it.
# ---------------------------------------------------------------------------------

# ---- the vocabulary (§5.3) -----------------------------------------------------------

# _roster_seed_vocab — the seed capability vocabulary, verbatim from §5.3.
#
# KEPT SMALL ON PURPOSE. "A sprawling vocabulary makes matching mushy" is the design's
# wording, and the failure it names is concrete: two agents tagged `e2e` and `end-to-end`
# and a matcher that quietly stops working. So this list is closed, and the ONLY door into
# it is §5.4 — a `capability_request` row. That is enforced, not documented: see
# `_roster_vocab_expr`.
_roster_seed_vocab() {
  printf '%s\n' \
    implement frontend backend svelte sveltekit \
    test-planning test-authoring e2e \
    review security architecture business-logic edge-case \
    research qa-planning qa-execution requirements
}

# _roster_vocab_expr — the LIVE vocabulary, as a SQL expression usable on the right of
# `IN (...)`: the seed words above, UNION every capability that has a `capability_request`
# row which was not declined.
#
# THIS IS §5.4's ENFORCEMENT POINT, AND IT IS WHY RECRUITING IS MACHINERY RATHER THAN A
# CONVENTION. `agents/developer-rust.md` declaring `capabilities: [implement, rust]` is
# REFUSED by `guild sync-agents` until somebody has filed the gap — which is exactly the
# ceremony §5.4 asks for, arriving at the cheapest moment (the file is on disk, nothing
# has been built) instead of at dispatch time. Once the request exists, `rust` is a real
# capability of this guild forever: `sync-agents` moves the request `open -> created`
# rather than deleting it, so the row that legitimizes the word outlives the recruitment.
#
# DELIBERATELY NOT `SELECT capability FROM agent_capability`. Sourcing the vocabulary from
# the roster itself would be self-approving — one typo'd tag, once synced, becomes legal
# forever — and it would also make the vocabulary shrink mid-script, since `sync-agents`
# DELETES an agent's stale capability rows before inserting its new ones. Two independent
# reasons for the same answer.
_roster_vocab_expr() {
  local w out=""
  while read -r w; do
    [ -n "$w" ] || continue
    out="$out${out:+ UNION ALL }SELECT '$w' AS c"
  done <<VOCAB
$(_roster_seed_vocab)
VOCAB
  printf "SELECT c FROM (%s) UNION SELECT capability FROM capability_request WHERE status <> 'declined'" "$out"
}

# _roster_check_cap <token> — die unless <token> is a well-formed capability WORD.
#
# LOWERCASE, DIGITS AND HYPHEN ONLY, and that is stricter than `_rec_check_slug`'s
# alphabet ON PURPOSE rather than by omission. A capability is compared for EQUALITY by
# the matcher and by nothing else — there is no normalization step anywhere in §5.2 — so
# `E2E` and `e2e` would be two different capabilities that read as one, which is the same
# failure §5.3 names for `e2e` vs `end-to-end` wearing a different hat. A `.` or a `_`
# would do the same for `qa_planning`. The narrow alphabet is what makes "declared" and
# "required" comparable at all, so it is validated rather than escaped, and the value can
# therefore reach SQL through `sql_str`.
#
# `LC_ALL=C` for `_rec_check_slug`'s reason, stated in full there: `a-z` in a bash bracket
# expression is a COLLATION range, so under an ordinary UTF-8 locale an accented letter
# collates INSIDE it and the check silently passes. An alphabet enforced only in some
# locales is not an alphabet.
#
# THE ALPHABET IS THE SAME ONE `_art_capability` (lib/artifacts.sh) ENFORCES ON `--needs`,
# down to the leading-letter rule and the 64-byte cap, and it has to be: that function
# guards the value a TASK requires and this one guards the value an AGENT declares, and the
# matcher compares them for equality. An alphabet one side admits and the other refuses is
# a capability that can be declared and never required, or required and never declared.
# The two are separate functions because artifacts.sh and roster.sh must be sourceable
# independently; if they are ever merged, merge them.
#
# WHAT THE TWO DELIBERATELY DISAGREE ABOUT IS THE VOCABULARY, NOT THE ALPHABET.
# `_art_capability` does not check §5.3's word list, on the argument that a task requiring
# an unknown capability simply matches no agent and goes `blocked` — loud within one
# dispatch. This function's callers DO check it (`_roster_vocab_expr`), because the roster
# is the side that DEFINES what a capability is: an agent quietly tagged `end-to-end`
# matches nothing and says nothing, forever. Refusing on the declaring side and reporting
# on the requiring side is the same judgment applied to two different failure modes.
_roster_check_cap() {
  local v="${1-}"
  local LC_ALL=C
  [ -n "$v" ] || die "guild: a capability cannot be empty"
  # Length FIRST, before any pattern work: `${#v}` is O(1) and a bracket-expression scan
  # over an unbounded value is not (rule 4).
  [ "${#v}" -le 64 ] ||
    die "guild: that capability is ${#v} characters; the limit is 64 — a capability is a tag, not a sentence"
  case "$v" in
    [a-z]*) ;;
    *)
      die "guild: '$v' is not a valid capability — it must start with a lowercase letter.
Capabilities are a small fixed vocabulary (design 5.3): implement, frontend, backend,
svelte, sveltekit, test-planning, test-authoring, e2e, review, security, architecture,
business-logic, edge-case, research, qa-planning, qa-execution, requirements."
      ;;
  esac
  case "$v" in
    *[!a-z0-9-]*)
      die "guild: '$v' is not a valid capability.

A capability is compared for equality and never normalized, so it is limited to lowercase
letters, digits and '-' — 'test-authoring', 'qa-execution', 'svelte'. Two spellings of one
capability ('e2e' and 'E2E') are two capabilities that read as one, and the matcher then
quietly stops working (design 5.3)."
      ;;
  esac
}

# _roster_name_ok <value> — is <value> a well-formed agent name? 0 yes, non-zero no.
#
# THE ALPHABET IS STATED ONCE, IN `_rec_check_slug`, and this is a PREDICATE over it
# rather than a second copy of the bracket expression — the divergence that function's own
# header exists to prevent. It is run in a subshell because `_rec_check_slug` reports by
# dying, and `guild sync-agents` needs to name the FILE the bad name came from, which that
# message cannot know. One fork per agent file, on a command that already opened every one
# of them.
_roster_name_ok() {
  ( _rec_check_slug "${1-}" 'agent name' 'the description' ) >/dev/null 2>&1
}

# _roster_check_agent_name <value> <flag> — die unless <value> is a well-formed agent name,
# for a value that arrived on a FLAG (so the message can name the flag).
_roster_check_agent_name() {
  _rec_check_slug "${1-}" 'agent name' "${2:---proposes}"
}

# ---- row projections (A STOPGAP — see below) ------------------------------------------

# _roster_json_row <table> — the `json_object(...)` expression capturing a FULL row of one
# of the four roster tables.
#
# THIS BELONGS IN `_art_json_row` (lib/artifacts.sh), WHICH IS "THE ONE PROJECTION
# REGISTRY", AND IT IS HERE ONLY BECAUSE THAT FILE IS OWNED BY ANOTHER AGENT THIS PHASE.
# lib/records.sh's header states the rule as "THERE IS NO `_rec_json_row`" and gives the
# reason: the journal is a change log of RESULTING ROW STATE (§2.3), `guild rebuild`
# re-inserts every column from it, and a projection that goes stale silently drops a column
# on replay — which is precisely what a SECOND registry guarantees, because only one of the
# two gets updated. So this function is a stopgap with a deadline, not a design:
#
#   FOLD THESE FOUR CASES INTO `_art_json_row` AND DELETE THIS FUNCTION.
#
# Column order is schema order (scripts/schema.sql), and every column is present, because
# both of those are what replay depends on. `active`, `serial`, `required` and
# `capability_request.id` are INTEGER columns on STRICT tables, and json_object preserves
# their type, which is what keeps a replayed row insertable.
_roster_json_row() {
  case "${1-}" in
    agent)
      printf "json_object('name',name,'model',model,'description',description,'active',active,'serial',serial)"
      ;;
    agent_capability)
      printf "json_object('agent',agent,'capability',capability)"
      ;;
    task_capability)
      # NOT DUPLICATED. `task_capability` already has its case in `_art_json_row`, because
      # lib/artifacts.sh is what writes those rows (`guild new task --needs`). Delegating
      # rather than restating is the whole point of the registry rule; this arm exists so a
      # caller here does not have to know which of the two functions owns which table.
      _art_json_row task_capability
      ;;
    capability_request)
      printf "json_object('id',id,'capability',capability,'requirement_id',requirement_id,'rationale',rationale,'proposed_agent',proposed_agent,'proposed_spec',proposed_spec,'status',status,'created_at',created_at)"
      ;;
    *) die "guild: no roster row projection for table '${1-}'" ;;
  esac
}

# ---- the matcher, as SQL fragments (§5.2) ---------------------------------------------
#
# Written as fragments rather than as one query because THREE commands must agree about
# what "eligible" and "rank 1" mean — `guild match`, `guild bounties`, and (Stage 4) the
# dispatcher. Two spellings of the ranking is two answers to "who gets this bounty".

# _roster_has_caps <task-id-expression> — does this task declare ANY capability?
# THE FALLBACK SWITCH. See the header.
_roster_has_caps() {
  printf "EXISTS (SELECT 1 FROM task_capability tc0 WHERE tc0.task_id = %s)" "$1"
}

# _roster_pin_expr <task-id-expression> — the pinned member, or '' when nothing is pinned.
#
# A SCALAR SUBQUERY rather than a column reference, so the same fragment reads correctly
# from a statement that has no `task` in scope (`guild match` selects FROM agent) and from
# one that does (`guild bounties` selects FROM task). The alias is `tp0`, unused elsewhere.
#
# `task.agent`, not `task.claimed_by`: §5.2 names `claimed_by`, but the Stage 1-3 CLI has
# never written that column — `guild new task --agent A` writes `task.agent`, which is the
# v4 spelling every board and every skill already uses. Stage 4 can widen this to
# COALESCE(claimed_by, agent) in ONE place when the graph starts presetting it.
_roster_pin_expr() {
  printf "COALESCE((SELECT tp0.agent FROM task tp0 WHERE tp0.id = %s), '')" "$1"
}

# _roster_is_pinned <task-id-expression> — the pin predicate.
_roster_is_pinned() {
  printf "%s <> ''" "$(_roster_pin_expr "$1")"
}

# _roster_super_where <agent-alias> <task-id-expression> — §5.2 step 1: this agent's
# capabilities are a SUPERSET of the task's REQUIRED set.
#
# Expressed as "there is no required capability this agent lacks", which is the superset
# test written with two NOT EXISTS and no aggregate — so it is a direct-row join, never a
# traversal, and §3.0's `WITH RECURSIVE` ban never comes near it. An empty required set
# makes the outer NOT EXISTS vacuously true, which is correct set theory AND the reason
# the fallback switch above is presence-of-any-row rather than emptiness-of-required.
_roster_super_where() {
  printf "NOT EXISTS (SELECT 1 FROM task_capability tcr
                       WHERE tcr.task_id = %s AND tcr.required = 1
                         AND NOT EXISTS (SELECT 1 FROM agent_capability acr
                                          WHERE acr.agent = %s.name
                                            AND acr.capability = tcr.capability))" "$2" "$1"
}

# _roster_pcov <agent-name-expression> <task-id-expression> — §5.2 step 2, first key: how
# many of the task's PREFERRED capabilities this agent covers. Higher is better.
_roster_pcov() {
  printf "(SELECT COUNT(*) FROM task_capability tcp
            WHERE tcp.task_id = %s AND tcp.required = 0
              AND EXISTS (SELECT 1 FROM agent_capability acp
                           WHERE acp.agent = %s AND acp.capability = tcp.capability))" "$2" "$1"
}

# _roster_ptot <task-id-expression> — how many preferred capabilities there are to cover.
# Not a ranking key; it is the denominator that makes `2/3` readable.
_roster_ptot() {
  printf "(SELECT COUNT(*) FROM task_capability tcq WHERE tcq.task_id = %s AND tcq.required = 0)" "$1"
}

# _roster_total <agent-name-expression> — §5.2 step 2, second key: the agent's TOTAL
# capability count. LOWER is better, so a specialist beats a generalist — the design's
# words, and the reason the sort is ASC on a number that looks like it should be DESC.
_roster_total() {
  printf "(SELECT COUNT(*) FROM agent_capability act WHERE act.agent = %s)" "$1"
}

# _roster_order_by <agent-alias> <task-id-expression> — §5.2's ranking, EXACTLY:
#   preferred covered DESC -> total capability count ASC -> name ASC
# The third key is not a tiebreak of convenience: it is what makes the answer DETERMINISTIC,
# which is the property that lets the orchestrator dispatch rank 1 without model judgment.
_roster_order_by() {
  printf "ORDER BY %s DESC, %s ASC, %s.name ASC" \
    "$(_roster_pcov "$1.name" "$2")" "$(_roster_total "$1.name")" "$1"
}

# _roster_top_agent <task-alias> — the rank-1 agent for a task, as a scalar expression,
# INCLUDING the pin and the fallback. '' when nothing is eligible.
#
# `ORDER BY ... LIMIT 1` inside a correlated scalar subquery is how rank 1 is taken without
# `row_number()` (§3.0 bans five window functions and this file uses none).
#
# THE THREE BRANCHES ARE IN THE SAME ORDER `guild match` EMITS ITS ROWS, and they have to
# be: this expression IS "what rank 1 would say", and if it disagreed with `guild match`
# then `guild bounties` would name one member and `guild match` another for one ticket.
# The pin arm subsumes the old no-capabilities arm — a ticket with no capability rows and
# no agent has nobody either way — so the ELSE is now reached only by a capability ticket
# that nothing covers.
_roster_top_agent() {
  local t="$1"
  printf "CASE WHEN %s THEN %s.agent
          WHEN %s THEN
            COALESCE((SELECT a1.name FROM agent a1
                       WHERE a1.active = 1 AND %s
                       %s LIMIT 1), '')
          ELSE '' END" \
    "COALESCE($t.agent,'') <> ''" "$t" \
    "$(_roster_has_caps "$t.id")" \
    "$(_roster_super_where a1 "$t.id")" \
    "$(_roster_order_by a1 "$t.id")"
}

# _roster_req_caps <task-id-expression> — the task's REQUIRED capabilities as a
# comma-joined list, for the "needs [rust, embedded]" half of §5.2's loud message.
# Capabilities passed `_roster_check_cap`, so the joined value has no blank and no pipe.
_roster_req_caps() {
  printf "COALESCE((SELECT group_concat(c, ',') FROM (SELECT tcl.capability AS c FROM task_capability tcl
            WHERE tcl.task_id = %s AND tcl.required = 1 ORDER BY tcl.capability)), '')" "$1"
}

# _roster_deps_ok <task-alias> — every DIRECT predecessor is finished.
#
# Direct predecessors only, never a traversal (§3.0's `WITH RECURSIVE` trap): readiness
# propagates one node at a time as the work runs. This is the second half of
# `_brief_blocked_where`, negated — the same predicate, so `guild brief`'s Blocked section
# and `guild bounties` cannot disagree about which tasks are waiting on what.
_roster_deps_ok() {
  printf "NOT EXISTS (SELECT 1 FROM task_dependency dd JOIN task bb ON bb.id = dd.depends_on
                       WHERE dd.task_id = %s.id AND bb.status NOT IN ('done','waived'))" "$1"
}

# _roster_blockers <task-alias> — the unfinished predecessors, comma-joined. Ids only, so
# `_render_col` keeps them blank-free on the columnar surface.
_roster_blockers() {
  printf "COALESCE((SELECT group_concat(x, ',') FROM (SELECT bb.id AS x
            FROM task_dependency dd JOIN task bb ON bb.id = dd.depends_on
           WHERE dd.task_id = %s.id AND bb.status NOT IN ('done','waived') ORDER BY bb.id)), '')" "$1"
}

# ---- reading agent frontmatter (§5.1) -------------------------------------------------
#
# "Adding an agent file is the entire process of adding a guild member." That sentence is
# only true if the READER is honest about what it cannot parse. The frontmatter is YAML,
# this CLI has no YAML library and may not acquire one (rule 6: no python/jq/node), and a
# hand-rolled scanner that guesses is worse than one that refuses — a mis-parsed
# `capabilities:` does not fail, it silently produces an agent that matches the wrong work.
#
# SO THE SUPPORTED SHAPE IS STATED, AND EVERYTHING ELSE IS AN ERROR THAT NAMES THE FILE:
#
#   ---
#   name: developer-svelte                     required
#   model: sonnet                              optional, defaults to 'sonnet'
#   capabilities: [implement, frontend]        optional — inline array, ONE line
#   capabilities:                              …or a block list
#     - implement
#     - frontend
#   serial: false                              optional, true|false|1|0, defaults to false
#   description: |                             optional, block scalar or inline
#     Use this agent when …
#   ---
#
# `capabilities:` BEING OPTIONAL IS LOAD-BEARING, NOT LENIENCY. It is half of the fallback
# (see this file's header): an agent with no declared capabilities is a real roster member
# that simply cannot be reached by the matcher, only by a ticket naming it. That is exactly
# what every v4-era agent was, so "no capabilities" must mean "as before", never "broken".
#
# A key is a line at COLUMN 0. That is what keeps `product-reviewer.md`'s `<example>` block
# — which contains lines reading `user: "…"` and `assistant: "…"` — from being read as
# frontmatter keys: they are indented, so they are continuation text, which is what YAML
# says they are too.

# _roster_scan_awk <path> — write the frontmatter scanner to <path>.
#
# The output is LINE-ORIENTED AND TAGGED, one record per file, because that is the only
# transport that cannot be confused by a description containing any delimiter anyone might
# have picked:
#
#   F <path>        starts a file's record
#   E <message>     this file could not be read; no other lines follow
#   N <name>   M <model>   S <0|1>   D <description, clipped>   C <capability>  (repeated)
#
# Every value is the whole remainder of its line, so a value can contain `|`, `:`, quotes
# or a tab and still arrive intact. It cannot contain a newline, because awk records are
# lines — which is also why the description is JOINED with spaces rather than kept as-is.
_roster_scan_awk() {
  cat >"$1" <<'SCANNER'
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function unquote(s,   q) {
    s = trim(s)
    if (length(s) >= 2) {
      q = substr(s, 1, 1)
      if ((q == "\"" || q == "'") && substr(s, length(s), 1) == q) s = substr(s, 2, length(s) - 2)
    }
    return s
  }
  function reset() {
    infm = 0; closed = 0; key = ""; descblock = 0
    name = ""; model = ""; serial = "0"; desc = ""; ncap = 0; err = ""
    capmode = ""; capseen = 0
    # Per-file reset. Without this the dedupe set leaks across agent files and would
    # silently DROP a capability the next agent legitimately declares — a far worse
    # bug than the one the set exists to fix. `split("", arr)` is the portable clear
    # (BSD awk on macOS predates reliable `delete arr`).
    split("", capseen_set)
  }
  function addcap(v) {
    v = unquote(v)
    if (v == "") return
    # Dedupe within the file. `agent_capability` is keyed (agent, capability), so a
    # repeated entry stores one row while an undeduped scan emits two — and the
    # change-detection then reports `changed` on every single run, forever.
    if (v in capseen_set) { capseen = 1; return }
    capseen_set[v] = 1
    ncap++; cap[ncap] = v; capseen = 1
  }
  function emit(   i) {
    if (started == 0) return
    printf "F %s\n", file
    if (err == "" && infm == 1)
      err = "the YAML frontmatter is never closed by a second '---' line"
    if (err == "" && closed == 0)
      err = "no YAML frontmatter (the file does not start with a '---' line)"
    if (err == "" && name == "")
      err = "the frontmatter has no 'name:' field"
    if (err == "" && capmode == "block" && capseen == 0)
      err = "'capabilities:' has an empty value and no '- item' lines follow it"
    if (err != "") { printf "E %s\n", err; return }
    printf "N %s\n", name
    printf "M %s\n", (model == "" ? "sonnet" : model)
    printf "S %s\n", serial
    if (desc != "") printf "D %s\n", substr(desc, 1, 300)
    for (i = 1; i <= ncap; i++) printf "C %s\n", cap[i]
  }
  FNR == 1 {
    emit(); reset(); started = 1; file = FILENAME
    line = $0; sub(/\r$/, "", line)
    if (line ~ /^---[ \t]*$/) infm = 1
    else err = "no YAML frontmatter (the file does not start with a '---' line)"
    next
  }
  err != "" { next }
  closed == 1 { next }
  infm == 0 { next }
  {
    line = $0
    sub(/\r$/, "", line)
    if (line ~ /^---[ \t]*$/) { infm = 0; closed = 1; next }

    # A KEY IS A LINE AT COLUMN 0. Anything indented belongs to the key above it, which is
    # what keeps an <example> block's `user:` / `assistant:` lines out of the key space.
    if (line ~ /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:/) {
      p = index(line, ":")
      key = trim(substr(line, 1, p - 1))
      val = trim(substr(line, p + 1))
      descblock = 0
      if (key == "name") name = unquote(val)
      else if (key == "model") model = unquote(val)
      else if (key == "serial") {
        sv = unquote(val)
        if (sv == "true" || sv == "yes" || sv == "1") serial = "1"
        else if (sv == "false" || sv == "no" || sv == "0" || sv == "") serial = "0"
        else err = "'serial:' must be true or false (got '" sv "')"
      }
      else if (key == "description") {
        # A block scalar header is `|`, `>` and their chomping/indent variants. Anything
        # else on the line IS the value.
        if (val ~ /^[|>][-+0-9]*$/) { descblock = 1; desc = "" }
        else desc = unquote(val)
      }
      else if (key == "capabilities") {
        if (val == "") capmode = "block"
        else if (substr(val, 1, 1) == "[") {
          cb = index(val, "]")
          if (cb == 0) {
            # REFUSED RATHER THAN GUESSED. A multi-line inline array is legal YAML and this
            # scanner cannot read it; continuing would silently take a prefix of the list,
            # which is an agent quietly missing half its capabilities.
            err = "'capabilities:' opens an inline array that does not close on the same line. Put the whole array on one line ('capabilities: [a, b]') or use a block list of '- item' lines"
          } else {
            capmode = "inline"
            inner = substr(val, 2, cb - 2)
            nparts = split(inner, parts, ",")
            for (pi = 1; pi <= nparts; pi++) addcap(parts[pi])
          }
        }
        else err = "'capabilities:' must be an inline array ('capabilities: [a, b]') or a block list of '- item' lines (got '" val "')"
      }
      next
    }

    if (line ~ /^[ \t]*$/) next
    if (key == "description" && descblock) { desc = desc (desc == "" ? "" : " ") trim(line); next }
    if (key == "capabilities" && capmode == "block") {
      if (line ~ /^[ \t]*-[ \t]*/) { cv = line; sub(/^[ \t]*-[ \t]*/, "", cv); addcap(cv) }
      else err = "'capabilities:' is a block list, so every line under it must be '- item' (got '" trim(line) "')"
      next
    }
    next
  }
  END { emit() }
SCANNER
}

# _roster_agents_dir — where `agents/*.md` lives.
#
# Three sources, in order, and the first that exists wins:
#   $GUILD_AGENTS_DIR    an explicit override (the harness uses it; so can a project that
#                        keeps its roster somewhere else)
#   $CLAUDE_PLUGIN_ROOT/agents   how every skill invocation reaches the plugin
#   <this file>/../../agents     the checkout layout: scripts/lib/roster.sh -> agents/
#
# The last one is what makes `./scripts/guild sync-agents` work from a plain clone with no
# environment at all, which is the same guarantee `guild_schema_path` gives schema.sql.
_roster_agents_dir() {
  local here c
  if [ -n "${GUILD_AGENTS_DIR:-}" ]; then
    [ -d "$GUILD_AGENTS_DIR" ] ||
      die "guild: \$GUILD_AGENTS_DIR is set to '$GUILD_AGENTS_DIR', which is not a directory"
    printf '%s\n' "$GUILD_AGENTS_DIR"
    return 0
  fi
  here=""
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || here=""
  fi
  for c in \
    "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/agents}" \
    "${here:+$here/../../agents}"
  do
    [ -n "$c" ] || continue
    if [ -d "$c" ]; then (cd "$c" && pwd); return 0; fi
  done
  die "guild: could not find the agents/ directory.

'guild sync-agents' reads the roster out of the plugin's agent definitions. Set
\$GUILD_AGENTS_DIR to the directory holding them, or run the command from a checkout
where scripts/ and agents/ are siblings."
}

# _roster_sql_list — read validated tokens on stdin, write `'a','b','c'` (no newline).
# The tokens have passed a closed alphabet, so there is nothing to escape; awk rather
# than a shell loop because appending to a shell string in a loop is the quadratic shape
# rule 4 forbids.
_roster_sql_list() {
  LC_ALL=C awk '{ printf "%s%c%s%c", (NR > 1 ? "," : ""), 39, $0, 39 }'
}

# _roster_sql_values — the same tokens as a one-column relation, for `IN (...)` and for the
# vocabulary guard: `SELECT 'a' AS c UNION ALL SELECT 'b'`.
_roster_sql_values() {
  LC_ALL=C awk '{ if (NR == 1) printf "SELECT %c%s%c AS c", 39, $0, 39; else printf " UNION ALL SELECT %c%s%c", 39, $0, 39 }'
}

# ---- guild sync-agents ----------------------------------------------------------------
#
# Scan agents/*.md, reconcile the roster, report what changed. IDEMPOTENT: a second run
# with nothing changed writes no row, no event and NO JOURNAL LINE — which matters more
# than it sounds, because journal.ndjson is a file git carries and a command that appends
# fourteen lines every time it is run turns every PR into noise.
#
# RECONCILIATION, and the one rule that is not symmetric:
#
#   a file appears        -> the agent is inserted, active = 1
#   a file changes        -> model / description / serial are updated, active forced to 1
#                            (a returning agent is re-enlisted, not left retired)
#   a file disappears     -> the agent is DEACTIVATED, never deleted. `task.claimed_by`
#                            REFERENCES agent(name), and a finished task may name an agent
#                            whose file was removed a year ago; deleting the row would
#                            either fail the constraint or orphan the history. `active = 0`
#                            removes it from every match while keeping the record readable.
#   capabilities          -> REPLACED, not merged. The file is the declaration; a capability
#                            deleted from it must stop matching, which a merge cannot do.
#
# THE VOCABULARY GUARD IS GLOBAL AND ALL-OR-NOTHING. Every write below carries
# `AND <guard>`, where the guard is "no scanned capability is outside the live vocabulary".
# So one unknown tag anywhere means NOTHING is written — not "that agent is skipped" —
# and the `V|` diagnostics name every offending word. A partially-synced roster is a
# matcher that dispatches wrongly and says nothing; a refused sync is a message.
cmd_sync_agents() {
  local dry=0 dir prog scan names caps sqlf rows out line
  local f nfiles
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      -*) die "guild: unknown option '$1' for sync-agents (try 'guild sync-agents [--dry-run]')" ;;
      *) die "guild: sync-agents takes no positional arguments (got '$1')" ;;
    esac
    shift
  done

  db_require_init
  [ "$dry" = 1 ] || journal_preflight

  dir="$(_roster_agents_dir)" || exit 1

  # ---- scan ------------------------------------------------------------------------
  prog="$(_render_tmp roster-scanner)"
  scan="$(_render_tmp roster-scan)"
  _roster_scan_awk "$prog"

  nfiles=0
  : >"$scan"
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    nfiles=$((nfiles + 1))
    # An EMPTY file never reaches awk's FNR == 1 rule, so it would be silently skipped.
    # It is reported instead, for this command's governing reason: a roster that quietly
    # loses a member is worse than one that refuses to sync.
    if [ ! -s "$f" ]; then
      printf 'F %s\nE the file is empty\n' "$f" >>"$scan"
      continue
    fi
    LC_ALL=C awk -f "$prog" "$f" >>"$scan" ||
      { rm -f "$prog" "$scan"; die "guild: could not read the agent definition $f"; }
  done
  rm -f "$prog"

  if [ "$nfiles" = 0 ]; then
    rm -f "$scan"
    die "guild: no agent definitions found in $dir

'guild sync-agents' reconciles the roster against agents/*.md. With no files to read it
would deactivate every member of the guild, so it refuses instead. If the roster really
is meant to be empty, say so by removing the agents one at a time."
  fi

  # ---- validate, and report every bad file at once ---------------------------------
  _roster_validate_scan "$scan" || { rm -f "$scan"; exit 1; }

  names="$(_render_tmp roster-names)"
  caps="$(_render_tmp roster-caps)"
  LC_ALL=C awk '/^N /{ print substr($0, 3) }' "$scan" >"$names"
  LC_ALL=C awk '/^C /{ print substr($0, 3) }' "$scan" | LC_ALL=C sort -u >"$caps"

  # ---- compose ONE script, run it ONCE ---------------------------------------------
  sqlf="$(_render_tmp roster-sync-sql)"
  rows="$(_render_tmp roster-sync-rows)"
  _roster_sync_sql "$scan" "$names" "$caps" "$dry" >"$sqlf"
  _render_query "$sqlf" "$rows" "guild: could not sync the roster"
  rm -f "$scan" "$names"

  # An unknown capability means the guard fired and NOTHING was written. Say which words,
  # and say what to do about them — that path is §5.4 and it is not obvious.
  out="$(LC_ALL=C awk '/^V\|/ { print substr($0, 3) }' "$rows")"
  if [ -n "$out" ]; then
    rm -f "$rows" "$caps"
    die "guild: the roster declares $(printf '%s\n' "$out" | LC_ALL=C wc -l | tr -d ' ') capability(ies) the guild's vocabulary does not have:

$(printf '%s\n' "$out" | LC_ALL=C sed 's/^/  /')

Nothing was written. A capability enters the vocabulary through a roster gap, not by being
typed into an agent file (design 5.3) — otherwise two agents end up tagged 'e2e' and
'end-to-end' and the matcher quietly stops working. File the gap, then sync again:

  guild capability-request <capability> --req REQ-NNN --rationale '...' --proposes NAME

If it is a typo, fix the agent file instead."
  fi
  rm -f "$caps"

  # ---- journal what landed ---------------------------------------------------------
  # A loop of journal_append calls, which is a FILE APPEND per row and not a db_exec —
  # the round-trip rule (§2.2) is about the driver, and this side of it never opens one.
  if [ "$dry" = 0 ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        'R|'*) _roster_journal_marker "$line" ;;
      esac
    done <"$rows"
  fi

  _roster_sync_report "$rows" "$dir" "$nfiles" "$dry"
  rm -f "$rows"
}

# WHEN DOES `sync-agents` RUN? BOTH — at `guild init`, and on demand. See
# `_init_seed_roster` in lib/init.sh, which is where the init half lives (it is a step of
# init, not a command of the roster) and where the reasoning is written down.
#
# The short version, because it is the decision this file's fallback depends on: init makes
# an EMPTY roster impossible on any guild created from Stage 3 onward, and this command
# keeps a STALE one from being permanent — adding `agents/developer-rust.md` must never
# require re-initializing anything (§5.1). A guild initialized BEFORE Stage 3 has an empty
# `agent` table and will never run init again; that board is covered by the fallback (every
# ticket on it names an agent) and by `_roster_match_none`, which ends with "check the
# roster is loaded at all: 'guild sync-agents'" — so the first capability ticket that
# cannot be placed is an error message, not a silent shrug.

# _roster_validate_scan <scan-file> — check every scanned agent, and REPORT THEM ALL.
#
# One `die` per bad file would make fixing a roster a fourteen-round game, so every fault
# is collected and printed together. Values are flattened into the message with
# `_render_flat_arg`: a `name:` read out of a markdown file is free text, and this message
# is a line-oriented channel like any other.
_roster_validate_scan() {
  local scan="$1" tag val file line bad=0
  file=""
  while IFS= read -r line || [ -n "$line" ]; do
    tag="${line%% *}"
    val="${line#* }"
    case "$tag" in
      F) file="$val" ;;
      E)
        printf 'guild: %s\n         %s\n' "$(_render_flat_arg "$file")" "$(_render_flat_arg "$val")" >&2
        bad=1
        ;;
      N)
        if ! _roster_name_ok "$val"; then
          printf "guild: %s\n         'name: %s' is not a usable agent name — it is a key the board stores and\n         a column every roster listing prints, so it is limited to letters, digits,\n         '.', '_' and '-'.\n" \
            "$(_render_flat_arg "$file")" "$(_render_flat_arg "$val")" >&2
          bad=1
        fi
        ;;
      C)
        if ! ( _roster_check_cap "$val" ) >/dev/null 2>&1; then
          printf "guild: %s\n         capability '%s' is not a valid capability word — lowercase letters, digits\n         and '-' only (design 5.3).\n" \
            "$(_render_flat_arg "$file")" "$(_render_flat_arg "$val")" >&2
          bad=1
        fi
        ;;
    esac
  done <"$scan"
  [ "$bad" = 0 ] || die "guild: the roster was NOT synced — nothing was written."
  return 0
}

# _roster_sync_sql <scan-file> <names-file> <caps-file> <dry-run> — the WHOLE sync, as one
# script on stdout.
#
# Statement order is the design:
#
#   1. `V|`  every scanned capability outside the live vocabulary            (diagnostic)
#   2. `S|`  per agent: new / changed / (nothing), and per retiree: retired  (diagnostic)
#   3. the writes, each guarded by the vocabulary guard AND by "something actually changed"
#   4. `T|`  the resulting active-member count
#
# THE DIAGNOSTICS MUST PRECEDE THE WRITES, because both of them ask about the PRE-WRITE
# state: after the upsert, "is this agent new?" is always false. That is `cmd_move`'s rule
# (the event is written before the update so its payload can carry both ends) applied to a
# whole command.
#
# EVERY WRITE IS ALSO GUARDED ON HAVING SOMETHING TO DO. A `RETURNING` row is a journal
# line, and journal.ndjson is a file git carries, so an unconditional upsert would append
# fourteen lines to it on every run and make `guild sync-agents` unrunnable in a PR. With
# the guard, a no-op sync produces no `R|` rows at all — the command is idempotent in the
# journal, not merely in the database.
_roster_sync_sql() {
  local scan="$1" namesf="$2" capsf="$3" dry="$4"
  local guard nameslist capsvals allcaps now nowlit actorlit
  local tag val file name model serial desc capsfile line
  local agentrow caprow

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  agentrow="$(_roster_json_row agent)"
  caprow="$(_roster_json_row capability_request)"

  nameslist="$(_roster_sql_list <"$namesf")"
  capsvals="$(_roster_sql_values <"$capsf")"
  allcaps="$(_roster_sql_list <"$capsf")"

  # THE GUARD. "No scanned capability sits outside the live vocabulary." With no
  # capabilities scanned at all there is nothing to check and the guard is the constant
  # true — spelled `1 = 1` rather than left out, so every write below can carry the same
  # `AND (guard)` text and no statement is a special case.
  if [ -n "$capsvals" ]; then
    guard="NOT EXISTS (SELECT 1 FROM ($capsvals) gv WHERE gv.c NOT IN ($(_roster_vocab_expr)))"
    printf "SELECT 'V|' || gv.c FROM (%s) gv WHERE gv.c NOT IN (%s) ORDER BY gv.c;\n" \
      "$capsvals" "$(_roster_vocab_expr)"
  else
    guard="1 = 1"
  fi

  # ---- per-agent: diagnostics, then writes ----------------------------------------
  #
  # Read the scan file ONCE, buffering one agent at a time. The buffer is a handful of
  # capability words, never a document, so plain string append is safe here (rule 4 is
  # about values that can be megabytes).
  capsfile="$(_render_tmp roster-agent-caps)"
  name=""
  : >"$capsfile"
  while IFS= read -r line || [ -n "$line" ]; do
    tag="${line%% *}"
    val="${line#* }"
    case "$tag" in
      F)
        [ -z "$name" ] || _roster_agent_sql "$name" "$model" "$serial" "$desc" "$capsfile" \
          "$guard" "$nowlit" "$actorlit" "$agentrow" "$dry"
        name=""; model=""; serial="0"; desc=""; : >"$capsfile"
        file="$val"
        ;;
      N) name="$val" ;;
      M) model="$val" ;;
      S) serial="$val" ;;
      D) desc="$val" ;;
      C) printf '%s\n' "$val" >>"$capsfile" ;;
    esac
  done <"$scan"
  [ -z "$name" ] || _roster_agent_sql "$name" "$model" "$serial" "$desc" "$capsfile" \
    "$guard" "$nowlit" "$actorlit" "$agentrow" "$dry"
  rm -f "$capsfile"

  # ---- retirees --------------------------------------------------------------------
  #
  # DEACTIVATED, NEVER DELETED. `task.claimed_by REFERENCES agent(name)`, and a done task
  # from six months ago may name an agent whose file was removed since; a DELETE would
  # either be refused by the constraint or orphan the history that explains the board.
  printf "SELECT 'S|' || name || '|retired' FROM agent WHERE active = 1 AND name NOT IN (%s) ORDER BY name;\n" \
    "$nameslist"
  if [ "$dry" = 0 ]; then
    printf "INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT %s, %s, 'retired', 'agent', name, json_object('reason', 'no agent file')
FROM agent WHERE active = 1 AND name NOT IN (%s) AND (%s);
UPDATE agent SET active = 0 WHERE active = 1 AND name NOT IN (%s) AND (%s)
RETURNING 'R|agent|upsert|' || %s;
" "$nowlit" "$actorlit" "$nameslist" "$guard" "$nameslist" "$guard" "$agentrow"

    # ---- §5.4's other half: a gap that the roster now covers is CLOSED ---------------
    #
    # "On create, the guild scaffolds agents/developer-rust.md … then `guild sync-agents`
    # admits it to the roster and the bounty becomes claimable." Admission is what closes
    # the request, so there is no separate verb to remember and no way to end up with a
    # capability the guild HAS still listed as a gap in `guild brief`.
    #
    # `open -> created`, never deleted: the row is what keeps the word in the vocabulary
    # (`_roster_vocab_expr`), so removing it would un-admit the capability on the next sync.
    if [ -n "$allcaps" ]; then
      printf "INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT %s, %s, 'recruited', 'capability_request', CAST(id AS TEXT),
       json_object('capability', capability, 'proposed_agent', proposed_agent)
FROM capability_request WHERE status = 'open' AND capability IN (%s) AND (%s);
UPDATE capability_request SET status = 'created'
 WHERE status = 'open' AND capability IN (%s) AND (%s)
RETURNING 'R|capability_request|upsert|' || %s;
" "$nowlit" "$actorlit" "$allcaps" "$guard" "$allcaps" "$guard" "$caprow"
    fi
  fi

  printf "SELECT 'T|' || COUNT(*) FROM agent WHERE active = 1;\n"
}

# _roster_agent_sql <name> <model> <serial> <desc> <caps-file> <guard> <now> <actor>
#                   <agent-row-expr> <dry-run> — one agent's share of the script.
#
# `<name>` and `<serial>` were validated against closed alphabets, so they are `sql_str`.
# `<model>` and `<desc>` are whatever a human typed into a markdown file, so they are
# `sql_text` — a description is prose that can legitimately contain a line ending in `;`,
# which is the exact shape that tears a quoted literal in half (§2.2.1).
_roster_agent_sql() {
  local name="$1" model="$2" serial="$3" desc="$4" capsf="$5"
  local guard="$6" nowlit="$7" actorlit="$8" agentrow="$9" dry="${10}"
  local n m d s ncaps capsin notin changed isnew cap

  n="$(sql_str "$name")"
  m="$(sql_text "$model" 'the agent model')"
  d="$(sql_text "$desc" 'the agent description')"
  case "$serial" in 0 | 1) s="$serial" ;; *) s=0 ;; esac
  ncaps="$(LC_ALL=C awk 'END { print NR + 0 }' <"$capsf")"
  capsin="$(_roster_sql_list <"$capsf")"

  # `NOT IN ()` is not legal SQL, so an agent that declares NOTHING gets the predicate that
  # means the same thing: every capability row it has is stale.
  if [ -n "$capsin" ]; then
    notin="capability NOT IN ($capsin)"
  else
    notin="1 = 1"
  fi

  isnew="NOT EXISTS (SELECT 1 FROM agent WHERE name = $n)"
  # CHANGED = new, or a scalar field differs, or the CAPABILITY SET differs. The set
  # comparison is exact without a set-difference operator: with a composite primary key the
  # rows are distinct, so "nothing stored is outside the declared list AND the counts match"
  # is equality in both directions.
  changed="( $isnew
      OR EXISTS (SELECT 1 FROM agent a WHERE a.name = $n
                  AND (a.model <> $m OR a.description <> $d OR a.serial <> $s OR a.active <> 1))
      OR (SELECT COUNT(*) FROM agent_capability WHERE agent = $n) <> $ncaps
      OR EXISTS (SELECT 1 FROM agent_capability WHERE agent = $n AND $notin) )"

  printf "SELECT 'S|' || %s || '|new' WHERE %s;\n" "$n" "$isnew"
  printf "SELECT 'S|' || %s || '|changed' WHERE NOT (%s) AND %s;\n" "$n" "$isnew" "$changed"
  [ "$dry" = 0 ] || return 0

  # The event goes FIRST so it can still tell 'enlisted' from 'updated' — after the upsert
  # the row always exists. Same ordering, same reason, as cmd_move.
  printf "INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT %s, %s, CASE WHEN %s THEN 'enlisted' ELSE 'updated' END, 'agent', %s,
       json_object('capabilities', %s, 'serial', %s)
WHERE (%s) AND %s;
" "$nowlit" "$actorlit" "$isnew" "$n" "$ncaps" "$s" "$guard" "$changed"

  printf "INSERT INTO agent (name, model, description, active, serial)
SELECT %s, %s, %s, 1, %s WHERE (%s) AND %s
ON CONFLICT(name) DO UPDATE SET
  model = excluded.model,
  description = excluded.description,
  active = 1,
  serial = excluded.serial
RETURNING 'R|agent|upsert|' || %s;
" "$n" "$m" "$d" "$s" "$guard" "$changed" "$agentrow"

  # CAPABILITIES ARE REPLACED, NOT MERGED: the file is the declaration. The delete is
  # announced first so the removal reaches the journal as a `delete` op — without it,
  # `guild rebuild` would replay the original upsert and resurrect a capability the roster
  # deliberately dropped.
  printf "SELECT 'R|agent_capability|delete|' || json_object('agent',agent,'capability',capability)
  FROM agent_capability WHERE agent = %s AND %s AND (%s);
DELETE FROM agent_capability WHERE agent = %s AND %s AND (%s);
" "$n" "$notin" "$guard" "$n" "$notin" "$guard"

  while IFS= read -r cap || [ -n "$cap" ]; do
    [ -n "$cap" ] || continue
    printf "INSERT INTO agent_capability (agent, capability)
SELECT %s, '%s' WHERE (%s)
  AND EXISTS (SELECT 1 FROM agent WHERE name = %s)
  AND NOT EXISTS (SELECT 1 FROM agent_capability WHERE agent = %s AND capability = '%s')
RETURNING 'R|agent_capability|upsert|' || json_object('agent',agent,'capability',capability);
" "$n" "$cap" "$guard" "$n" "$n" "$cap"
  done <"$capsf"
}

# _roster_journal_marker <line> — journal one `R|<table>|<op>|<json>` row.
#
# Split on the FIRST TWO pipes only, taking the remainder as the JSON. The table and the op
# are literals this file wrote into the SQL, so they are safe to compare; the row is
# `json_object()` output, which the engine escaped, so it is exactly one line and may
# contain any number of pipes. Putting the only pipe-bearing value LAST is the same rule
# `guild next` and `guild batch` apply to their marker channels.
_roster_journal_marker() {
  local rest="${1#R|}" table op row
  table="${rest%%|*}"
  rest="${rest#*|}"
  op="${rest%%|*}"
  row="${rest#*|}"
  case "$table" in
    agent | agent_capability | capability_request) ;;
    *) return 0 ;;
  esac
  case "$op" in
    upsert | delete) ;;
    *) return 0 ;;
  esac
  case "$row" in
    '{'*'}') ;;
    *) return 0 ;;
  esac
  journal_append "$table" "$op" "$row"
}

# _roster_sync_report <rows-file> <dir> <file-count> <dry-run> — say what changed.
#
# Human, not columnar: this is a maintenance command a person runs, and the machine-readable
# view of the roster is `guild match` / `guild bounties`. Names come from the `S|` markers,
# which the SQL composed out of validated identifiers, so nothing here can begin a line.
_roster_sync_report() {
  local rows="$1" dir="$2" nfiles="$3" dry="$4"
  LC_ALL=C awk -v DIR="$dir" -v NFILES="$nfiles" -v DRY="$dry" '
    /^S\|/ {
      s = substr($0, 3)
      p = index(s, "|")
      if (p < 2) next
      nm = substr(s, 1, p - 1)
      st = substr(s, p + 1)
      n[st]++
      list[st, n[st]] = nm
      next
    }
    /^T\|/ { active = substr($0, 3) + 0; next }
    function emit(label, st,   i) {
      for (i = 1; i <= n[st] + 0; i++) printf "  %-9s %s\n", label, list[st, i]
    }
    END {
      printf "guild: %d agent definition(s) in %s\n", NFILES, DIR
      emit("new",     "new")
      emit("changed", "changed")
      emit("retired", "retired")
      changed = n["new"] + n["changed"] + n["retired"] + 0
      if (changed == 0) {
        print "  the roster is already up to date — nothing was written"
      } else if (DRY == 1) {
        printf "  --dry-run: %d change(s) NOT written\n", changed
      }
      printf "guild: %d active member(s)\n", active
    }
  ' "$rows"
}

# ---- guild match (§5.2) ----------------------------------------------------------------
#
#   guild match TASK-014
#   1 developer-svelte 1/1 4 capability
#   2 developer 0/1 3 capability
#
# Five whitespace-separated columns, fixed count, so the orchestrator can take rank 1 with
# `awk 'NR == 1 { print $2 }'`:
#
#   1  rank                assigned by the READER from row order — see below
#   2  agent               `_render_col`, so it is one blank-free field even on the
#                          fallback path where the value is `--agent` free text
#   3  preferred covered   `<covered>/<total>`, ranking key 1 (higher wins)
#   4  capabilities        the agent's total, ranking key 2 (LOWER wins: a specialist
#                          beats a generalist)
#   5  source              `capability` (§5.2 ran) or `ticket` (the fallback)
#
# THE RANK IS THE ROW'S POSITION AND NOTHING ELSE. §3.0 bans five window functions, and
# `row_number()` would be the obvious way to number a ranked list — but the ordering is
# already total and deterministic (the third key is the name), so the row's position IS its
# rank and the reader can count. That is why this command needs no window function rather
# than working around the absence of one.
#
# NO ELIGIBLE AGENT IS AN ERROR, LOUDLY, AND IT DOES NOT MUTATE. §5.2 says the task moves
# to `blocked`; the ORCHESTRATOR owns every status transition (§2.4, and v4's rule before
# that), so this command reports and exits 1 with the required capabilities named, and the
# caller runs `guild move <TASK> blocked`. A read command that silently moved a ticket
# would be a second writer, which is the one thing the whole storage design forbids.
cmd_match() {
  local id="" mode="text" idlit sql rows sqlf out
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) mode="json" ;;
      -*) die "guild: unknown option '$1' for match (try 'guild match <TASK-ID> [--json]')" ;;
      *)
        [ -z "$id" ] || die "guild: match takes one TASK id (got '$1' as well as '$id')"
        id="$1"
        ;;
    esac
    shift
  done
  [ -n "$id" ] || die "guild: match requires a TASK id"
  case "$id" in
    TASK-*) ;;
    *) die "guild: unrecognized id '$id' (expected TASK-NNN)" ;;
  esac

  db_require_init
  # Prefix-checked only, so still argv free text (§2.2.1).
  idlit="$(sql_text "$id" 'the TASK id')"

  rows="$(_render_tmp roster-match)"
  sqlf="$(_render_tmp roster-match-sql)"
  _roster_match_sql "$mode" "$idlit" >"$sqlf"
  _render_query "$sqlf" "$rows" "guild: could not match $id"

  if ! LC_ALL=C grep -q '^E' "$rows"; then
    rm -f "$rows"
    die "guild: $id not found"
  fi

  if [ "$mode" = json ]; then
    _roster_match_json "$rows" "$id"
  else
    _roster_match_text "$rows"
  fi
  out="$(LC_ALL=C awk '/^A /{ n++ } END { print n + 0 }' "$rows")"
  if [ "$out" = 0 ]; then
    _roster_match_none "$rows" "$id"
    rm -f "$rows"
    return 1
  fi
  rm -f "$rows"
  return 0
}

# _roster_match_sql <mode> <task-id-literal> — the whole match as one script.
#
#   E              the task exists (an existence marker, so "not found" and "found, but
#                  nothing is eligible" stay distinguishable in one round trip)
#   S <source>     `pin`, `capability` or `ticket` — WHICH RULE PRODUCED RANK 1, reported
#                  so the caller never has to infer it
#   Q <cap>        required capabilities, for the error message and for --json
#   P <cap>        preferred capabilities
#   A <row>        one candidate, ALREADY RANKED by §5.2's ORDER BY
#
# The `A` rows are composed IN SQL in both modes — flattened columns for the human surface,
# `json_object()` for the machine one — so awk assembles a document and never touches a
# value. That is `guild brief`'s division of labour, for its reason.
#
# THE THREE `A` STATEMENTS EMIT IN RANK ORDER, and that is the whole ranking mechanism:
# statement output concatenates in script order, so the reader numbers the lines and never
# sorts (`_roster_match_text`). Hence the pin's statement is written FIRST — a pinned
# ticket dispatches to the pin, and the members it would otherwise have gone to follow it
# so the deviation is on screen instead of merely obeyed.
_roster_match_sql() {
  local mode="$1" idlit="$2" hascaps pin arow
  hascaps="$(_roster_has_caps "$idlit")"
  pin="$(_roster_pin_expr "$idlit")"

  printf "SELECT 'E' FROM task WHERE id = %s;\n" "$idlit"
  printf "SELECT 'S ' || CASE WHEN COALESCE(agent,'') <> '' AND %s THEN 'pin'
                              WHEN %s THEN 'capability' ELSE 'ticket' END
     FROM task WHERE id = %s;\n" "$hascaps" "$hascaps" "$idlit"
  printf "SELECT 'Q ' || capability FROM task_capability WHERE task_id = %s AND required = 1 ORDER BY capability;\n" "$idlit"
  printf "SELECT 'P ' || capability FROM task_capability WHERE task_id = %s AND required = 0 ORDER BY capability;\n" "$idlit"

  # THE PIN, AND THE FALLBACK, WHICH ARE ONE STATEMENT because they are one question:
  # "does the ticket name somebody?" A task with NO task_capability rows matches its own
  # `task.agent` without consulting the roster at all — which is what keeps a guild that
  # has never run `sync-agents` working exactly as it does today — and a task that names
  # somebody AND declares capabilities is §5.2's pin. The two differ only in what the row
  # is CALLED, so they differ only in that one CASE. An empty `agent` is not a candidate
  # either way: a ticket that names nobody and needs nothing has no one to give it to.
  #
  # `preferred_covered` is computed for the pin too, rather than hardcoded — it is how you
  # see at a glance that the pinned member covers 0 of 2 preferred capabilities. On the
  # fallback path there are no preferred capabilities at all, so it renders `0/0` exactly
  # as it did before the pin existed.
  if [ "$mode" = json ]; then
    arow="json_object('agent', t.agent, 'preferred_covered', $(_roster_pcov 't.agent' "$idlit"), 'preferred_total', $(_roster_ptot "$idlit"), 'capabilities', $(_roster_total 't.agent'), 'serial', COALESCE((SELECT a2.serial FROM agent a2 WHERE a2.name = t.agent), 0), 'source', CASE WHEN $hascaps THEN 'pin' ELSE 'ticket' END)"
  else
    arow="$(_render_col 't.agent') || ' ' || $(_roster_pcov 't.agent' "$idlit") || '/' || $(_roster_ptot "$idlit") || ' ' || $(_roster_total 't.agent') || CASE WHEN $hascaps THEN ' pin' ELSE ' ticket' END"
  fi
  printf "SELECT 'A ' || %s FROM task t
 WHERE t.id = %s AND COALESCE(t.agent,'') <> '';\n" \
    "$arow" "$idlit"

  if [ "$mode" = json ]; then
    arow="json_object('agent', a.name, 'preferred_covered', $(_roster_pcov 'a.name' "$idlit"), 'preferred_total', $(_roster_ptot "$idlit"), 'capabilities', $(_roster_total 'a.name'), 'serial', a.serial, 'source', 'capability')"
  else
    arow="$(_render_col 'a.name') || ' ' || $(_roster_pcov 'a.name' "$idlit") || '/' || $(_roster_ptot "$idlit") || ' ' || $(_roster_total 'a.name') || ' capability'"
  fi

  # §5.2 step 1 and 2, on the capability path. `a.name <> pin` is what stops a pinned
  # member who is ALSO independently eligible from appearing twice — once as rank 1 and
  # again three lines down, which read as two candidates with the same name.
  printf "SELECT 'A ' || %s FROM agent a
 WHERE a.active = 1 AND %s AND %s AND a.name <> %s
 %s;\n" \
    "$arow" "$hascaps" "$(_roster_super_where a "$idlit")" "$pin" "$(_roster_order_by a "$idlit")"

  # §5.2's ORDER BY lives on the CAPABILITY statement only. The pin statement yields at
  # most one row and precedes it, so the output concatenates into one ranked list without
  # a compound ORDER BY that would have to sort two differently-shaped projections.
}

# _roster_match_text <rows-file> — number the ranked rows.
_roster_match_text() {
  LC_ALL=C awk '/^A / { printf "%d %s\n", ++r, substr($0, 3) }' "$1"
}

# _roster_match_json <rows-file> <task-id> — the same, as one JSON document.
#
# `"rank": N` is spliced in by replacing the row's leading `{`, which is safe because the
# `{` is a byte json_object() emitted, not one that came from a value — every value inside
# was escaped by the engine. The task id is emitted through the same escaper the rest of
# the CLI uses rather than being interpolated raw.
_roster_match_json() {
  LC_ALL=C awk -v TASK="$2" '
    /^S /  { src = substr($0, 3); next }
    /^Q /  { req[++nq] = substr($0, 3); next }
    /^P /  { pre[++np] = substr($0, 3); next }
    /^A / {
      row = substr($0, 3)
      if (substr(row, 1, 1) != "{") next
      # `na` is incremented on its own line, NOT as `cand[++na] = ... na ...`: awk evaluates
      # the right-hand side before the subscript, so the rank spliced into the first row
      # came out EMPTY and the document was not valid JSON. Found by running it.
      na++
      cand[na] = "{\"rank\":" na "," substr(row, 2)
      next
    }
    function jarr(a, n,   i, out) {
      out = "["
      for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") "\"" a[i] "\""
      return out "]"
    }
    END {
      printf "{\n"
      printf "  \"task\": \"%s\",\n", TASK
      printf "  \"source\": \"%s\",\n", (src == "" ? "ticket" : src)
      printf "  \"required\": %s,\n", jarr(req, nq)
      printf "  \"preferred\": %s,\n", jarr(pre, np)
      if (na + 0 == 0) { print "  \"eligible\": []" }
      else {
        print "  \"eligible\": ["
        for (i = 1; i <= na; i++) printf "    %s%s\n", cand[i], (i < na ? "," : "")
        print "  ]"
      }
      print "}"
    }
  ' "$1"
}

# _roster_match_none <rows-file> <task-id> — §5.2 step 4, said out loud.
#
# "no guild member can take this bounty: needs [rust, embedded]" is the design's own
# wording, and the two follow-ups are the two things that resolve it — recruit, or move the
# ticket to `blocked` so it stops looking claimable. Written to STDERR so a caller reading
# stdout for the winner reads nothing at all rather than a sentence.
_roster_match_none() {
  local rows="$1" id="$2" needs src
  needs="$(LC_ALL=C awk '/^Q /{ printf "%s%s", (n++ ? ", " : ""), substr($0, 3) } END { print "" }' "$rows")"
  src="$(LC_ALL=C awk '/^S /{ print substr($0, 3); exit }' "$rows")"
  if [ "$src" = ticket ]; then
    printf 'guild: no guild member can take %s — the ticket declares no capabilities and names no agent.\n' "$id" >&2
    printf '       Give it one: guild new task ... --agent NAME   or   --needs cap1,cap2\n' >&2
  else
    printf 'guild: no guild member can take this bounty: %s needs [%s]\n' "$id" "$needs" >&2
    printf '       That is a roster gap. Either recruit for it —\n' >&2
    printf '         guild capability-request <capability> --req REQ-NNN --rationale "..." --proposes NAME\n' >&2
    printf '       — or park the ticket so it stops reading as claimable:\n' >&2
    printf '         guild move %s blocked\n' "$id" >&2
    printf "       (and check the roster is loaded at all: 'guild sync-agents')\n" >&2
  fi
}

# ---- guild bounties --------------------------------------------------------------------
#
# "What can be worked right now" — and, immediately underneath, what cannot and why. The
# second half is not a courtesy: a bounty board that lists only the claimable work answers
# "what is next" and hides "why is nothing next", which is the question a stalled guild
# actually has.
#
#   guild bounties
#   TASK-003 ready developer-svelte REQ-001 - Implement the token refresh
#   TASK-009 blocked - REQ-002 no-eligible-agent:rust,embedded Port the codec
#   TASK-011 blocked - REQ-002 deps:TASK-009 Wire the codec into the pipeline
#   TASK-014 blocked reviewer REQ-003 status-blocked Review the auth slice
#
# Six whitespace-separated columns, fixed count, free text LAST:
#
#   1  task id          `_render_col`
#   2  state            `ready` | `blocked`
#   3  agent            rank-1 match, or `-` when there is none
#   4  requirement      `_render_col`
#   5  reason           `-` when ready; otherwise `status-blocked`, `deps:<ids>` or
#                       `no-eligible-agent:<capabilities>` — a single blank-free token, so
#                       `awk '$5 ~ /^no-eligible-agent/'` is the roster-gap query
#   6  title            `_render_flat`, and last, because it is the only free-text column
#
# READY IS `guild next`'s CANDIDATE RULE PLUS DEPENDENCIES. `_brief_bounty_where` is CALLED,
# not restated — it is the same predicate `cmd_next` and `guild brief` use, including the
# reviewer gate, so this command cannot offer work `guild next` would refuse to hand out.
# The dependency clause is the extra half `guild bounties` is specified to add and that
# `cmd_next` will grow in Stage 4; when it does, the predicate moves into
# `_brief_bounty_where` and this file loses the `AND`.
#
# THIS COMMAND MUTATES NOTHING, and in particular it does not move a no-agent task to
# `blocked`. It REPORTS the condition §5.2 says should cause that move; the orchestrator,
# which owns every status transition, does the moving. So a task can appear here as
# `blocked / no-eligible-agent` while its stored status is still `todo` — that is the
# board telling you what it would do, one command before it does it.
cmd_bounties() {
  local mode="text" rows sqlf
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) mode="json" ;;
      -*) die "guild: unknown option '$1' for bounties (try 'guild bounties [--json]')" ;;
      *) die "guild: bounties takes no positional arguments (got '$1')" ;;
    esac
    shift
  done
  db_require_init

  rows="$(_render_tmp roster-bounties)"
  sqlf="$(_render_tmp roster-bounties-sql)"
  _roster_bounties_sql "$mode" >"$sqlf"
  _render_query "$sqlf" "$rows" "guild: could not read the bounty board"

  if [ "$mode" = json ]; then
    _roster_bounties_json "$rows"
  else
    LC_ALL=C awk '/^[BX] / { print substr($0, 3) }' "$rows"
  fi
  rm -f "$rows"
}

# _roster_bounties_sql <mode> — two tagged statements, `B` (ready) then `X` (blocked).
#
# Two statements rather than one compound SELECT with a sort key, because the two halves
# ask different questions and statement output concatenates in order anyway — which is the
# same reason `guild brief` is ten statements and one round trip.
_roster_bounties_sql() {
  local mode="$1" bounty blocked deps top eligible reason brow xrow
  bounty="$(_brief_bounty_where | tr '\n' ' ')"
  blocked="$(_brief_blocked_where | tr '\n' ' ')"
  deps="$(_roster_deps_ok t)"
  top="$(_roster_top_agent t)"

  # "Somebody can take this": the ticket names somebody (a pin, or the v4 fallback), or an
  # eligible member exists on the capability path. Written as its own expression because
  # BOTH halves of the command need it — the ready list excludes what nobody can take, and
  # the blocked list is where those tasks go instead.
  #
  # THE PIN ARM COMES FIRST AND IT MATTERS: a pinned ticket is workable BY DEFINITION, so
  # it is never reported as a roster gap even when the roster cannot independently cover
  # its capabilities. It is a deviation to review, not a bounty nobody can take — and the
  # arm order here is the same one `_roster_top_agent` uses, so the two cannot disagree
  # about whether a row belongs in the ready list or beside a `no-eligible-agent` reason.
  eligible="CASE WHEN COALESCE(t.agent,'') <> '' THEN 1
                 WHEN $(_roster_has_caps 't.id')
                 THEN EXISTS (SELECT 1 FROM agent a2 WHERE a2.active = 1 AND $(_roster_super_where a2 't.id'))
                 ELSE 0 END"

  # One blank-free token, so column 5 stays one field. Order matters: an explicitly blocked
  # task says so even if it also has unfinished dependencies, because that status was a
  # human decision and the dependency is a fact about the graph.
  reason="CASE
            WHEN t.status = 'blocked' THEN 'status-blocked'
            WHEN NOT ($deps) THEN 'deps:' || $(_roster_blockers t)
            WHEN NOT ($eligible) AND $(_roster_has_caps 't.id')
              THEN 'no-eligible-agent:' || $(_roster_req_caps 't.id')
            WHEN NOT ($eligible) THEN 'no-eligible-agent:unassigned'
            ELSE '-' END"

  if [ "$mode" = json ]; then
    brow="json_object('id', t.id, 'state', 'ready', 'agent', NULLIF($top,''), 'requirement_id', t.requirement_id, 'reason', NULL, 'priority', t.priority, 'parallel_group', t.parallel_group, 'title', $(_brief_clip 't.title'))"
    xrow="json_object('id', t.id, 'state', 'blocked', 'agent', NULLIF($top,''), 'requirement_id', t.requirement_id, 'reason', $reason, 'status', t.status, 'priority', t.priority, 'title', $(_brief_clip 't.title'))"
  else
    brow="$(_render_col 't.id') || ' ready ' || $(_render_col "COALESCE(NULLIF($top,''),'-')") || ' ' || $(_render_col 't.requirement_id') || ' - ' || $(_render_flat "$(_brief_clip 't.title' 100)")"
    xrow="$(_render_col 't.id') || ' blocked ' || $(_render_col "COALESCE(NULLIF($top,''),'-')") || ' ' || $(_render_col 't.requirement_id') || ' ' || $(_render_col "$reason") || ' ' || $(_render_flat "$(_brief_clip 't.title' 100)")"
  fi

  printf "SELECT 'B ' || %s FROM task t
 WHERE (%s) AND %s AND (%s)
 ORDER BY t.priority, t.id;\n" "$brow" "$bounty" "$deps" "$eligible"

  # Everything that is open but cannot be worked: explicitly blocked, waiting on a
  # predecessor, or a roster gap. The third arm is the one Stage 3 adds, and it is the
  # reason this command exists rather than `guild brief` covering it — brief's Blocked
  # section reads `task.status`, and a roster gap is not a status until somebody moves it.
  printf "SELECT 'X ' || %s FROM task t
 WHERE (%s)
    OR ( (%s) AND (%s) AND NOT (%s) )
 ORDER BY t.id;\n" "$xrow" "$blocked" "$bounty" "$deps" "$eligible"
}

# _roster_bounties_json <rows-file> — the two lists as one document. Values were escaped by
# json_object() in the engine, so awk only assembles arrays.
_roster_bounties_json() {
  LC_ALL=C awk '
    /^[BX] / {
      tag = substr($0, 1, 1); row = substr($0, 3)
      if (substr(row, 1, 1) != "{") next
      n[tag]++; buf[tag, n[tag]] = row
      next
    }
    function arr(name, tag, last,   i) {
      if (n[tag] + 0 == 0) { printf "  \"%s\": []%s\n", name, (last ? "" : ","); return }
      printf "  \"%s\": [\n", name
      for (i = 1; i <= n[tag]; i++) printf "    %s%s\n", buf[tag, i], (i < n[tag] ? "," : "")
      printf "  ]%s\n", (last ? "" : ",")
    }
    END {
      print "{"
      arr("bounties", "B", 0)
      arr("blocked",  "X", 1)
      print "}"
    }
  ' "$1"
}

# ---- recruiting (§5.4) ------------------------------------------------------------------
#
#   guild capability-request rust --req REQ-012 --rationale "..." --proposes developer-rust
#                                 [--spec "Sonnet · tools Read/Grep/... · owns Rust slices"]
#   guild capability-requests [--open]
#
# "A roster gap found at DISPATCH time is already a failure — the plan is approved, work is
# underway, and a bounty has nobody to take it." So the architect files the gap while it is
# still cheap, and the request does three jobs at once:
#
#   1. it is the RECORD of a decision the guild master has not made yet;
#   2. it is what `guild brief`'s Roster Gaps section reads — that section has existed and
#      been unreachable since Stage 2, because nothing wrote this table. THIS COMMAND IS
#      WHAT MAKES IT REACHABLE. There is no gate here: gates are Stage 4, and §5.4's
#      `gate-plan` surface arrives with them. In Stage 3 the two surfaces are `guild brief`
#      and `guild:new-requirement`, which can ask the user directly;
#   3. it EXTENDS THE VOCABULARY (`_roster_vocab_expr`), which is what lets
#      `guild sync-agents` admit `agents/developer-rust.md` afterwards and refuse it before.
#
# AN UNATTENDED SHIFT MAY NEVER CREATE AN AGENT (§5.4, last line). Nothing here does: this
# command writes a row and stops. The agent file is written by a human, or by a human
# asking for one; `guild sync-agents` is what admits it.
_roster_parse_request_flags() {
  rq_req=""
  rq_rationale=""
  rq_proposes=""
  rq_spec=""
  rq_rest=""
  rq_rest_n=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --req) shift; rq_req="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --rationale) shift; rq_rationale="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --proposes) shift; rq_proposes="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      --spec) shift; rq_spec="${1-}"; if [ $# -gt 0 ]; then shift; fi ;;
      # An unknown `--flag` consumes its value rather than falling through to the
      # positional slot, so a typo is not silently read as the capability name.
      --*) shift; if [ $# -gt 0 ]; then shift; fi ;;
      *)
        rq_rest_n=$((rq_rest_n + 1))
        if [ "$rq_rest_n" = 1 ]; then rq_rest="$1"; fi
        shift
        ;;
    esac
  done
}

# cmd_capability_request <capability> --req R --rationale T --proposes NAME [--spec S]
#
# Prints the new request's id. ONE db_exec: the insert, its three diagnostics and the event
# are one script, and the FROM clause is the referential check — `--req REQ-404` selects no
# rows, so nothing is inserted and the `MISS|` line says which reference was missing.
#
# THREE REFUSALS, all evaluated as part of the same script rather than as prior reads:
#
#   HAVE  an ACTIVE member already declares this capability. Then it is not a gap, and
#         filing one would put a permanent entry in `guild brief` for work the guild can
#         already do. The message names the members, because the likeliest cause is that
#         the architect did not know they existed.
#   DUP   an open request for this capability already exists. Re-planning the same
#         requirement, or a second requirement needing the same thing, must not file a
#         second gap: the guild master has one decision to make, not N.
#   MISS  the requirement does not exist.
cmd_capability_request() {
  local cap="${1-}" now nowlit actorlit rowexpr sql out line rest id row
  local caplit reqlit ratlit proplit speclit vocabmiss
  [ -n "$cap" ] || die "guild: capability-request requires a capability

  guild capability-request <capability> --req REQ-NNN --rationale '...' --proposes NAME [--spec '...']"
  case "$cap" in
    -*) die "guild: capability-request requires a capability before its flags (got '$cap')" ;;
  esac
  shift
  _roster_parse_request_flags "$@"
  [ "$rq_rest_n" = 0 ] ||
    die "guild: unexpected argument '$(_render_flat_arg "$rq_rest")'

  guild capability-request <capability> --req REQ-NNN --rationale '...' --proposes NAME [--spec '...']"

  _roster_check_cap "$cap"
  # A SEED CAPABILITY IS NOT A GAP. §5.3's list is what the guild is defined to understand;
  # a request for one of those words is a request for something already in the vocabulary,
  # and admitting it would let the seed list be re-litigated one row at a time.
  if _roster_seed_vocab | LC_ALL=C grep -qx -- "$cap"; then
    die "guild: '$cap' is already in the guild's capability vocabulary (design 5.3), so it is not a roster gap.

If no member declares it, that is a ROSTER problem rather than a vocabulary one: tag an
agent with it in agents/<name>.md and run 'guild sync-agents'."
  fi
  case "$rq_req" in
    REQ-*) ;;
    '') die "guild: capability-request requires --req REQ-NNN (the requirement that needs it)" ;;
    *) die "guild: unrecognized id '$rq_req' (expected REQ-NNN)" ;;
  esac
  [ -n "$rq_rationale" ] ||
    die "guild: capability-request requires --rationale — why the existing members cannot cover it.

That sentence is the whole value of the record: it is what the guild master reads at
approval time, months after the plan that needed it (design 5.4)."
  [ -n "$rq_proposes" ] ||
    die "guild: capability-request requires --proposes NAME (the suggested new member, e.g. developer-rust)"
  _roster_check_agent_name "$rq_proposes" '--proposes'

  db_require_init
  journal_preflight

  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  rowexpr="$(_roster_json_row capability_request)"
  # Validated against a closed alphabet above, so sql_str is correct for both.
  caplit="$(sql_str "$cap")"
  proplit="$(sql_str "$rq_proposes")"
  # Everything else is argv free text — a rationale quotes plan prose and a spec quotes a
  # tools list, either of which can end a line with `;` (§2.2.1).
  reqlit="$(sql_text "$rq_req" '--req')"
  ratlit="$(sql_text "$rq_rationale" '--rationale')"
  speclit="$(sql_text "$rq_spec" '--spec')"

  sql="BEGIN;
INSERT INTO capability_request
  (capability, requirement_id, rationale, proposed_agent, proposed_spec, status, created_at)
SELECT $caplit, r.id, $ratlit, $proplit, $speclit, 'open', $nowlit
FROM requirement r
WHERE r.id = $reqlit
  AND NOT EXISTS (SELECT 1 FROM capability_request q
                   WHERE q.capability = $caplit AND q.status = 'open')
  AND NOT EXISTS (SELECT 1 FROM agent_capability ac JOIN agent a ON a.name = ac.agent
                   WHERE a.active = 1 AND ac.capability = $caplit)
RETURNING 'OK|' || id || '|' || $rowexpr;
SELECT 'MISS|' || $(_render_col 'r.id') FROM (SELECT $reqlit AS id) r
 WHERE NOT EXISTS (SELECT 1 FROM requirement WHERE id = $reqlit);
SELECT 'DUP|' || q.id FROM capability_request q
 WHERE q.capability = $caplit AND q.status = 'open' ORDER BY q.id LIMIT 1;
SELECT 'HAVE|' || $(_render_col 'a.name') FROM agent_capability ac JOIN agent a ON a.name = ac.agent
 WHERE a.active = 1 AND ac.capability = $caplit ORDER BY a.name LIMIT 5;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
SELECT $nowlit, $actorlit, 'requested', 'capability_request', CAST(q.id AS TEXT),
       json_object('capability', q.capability, 'requirement_id', q.requirement_id,
                   'proposed_agent', q.proposed_agent)
FROM capability_request q
WHERE q.id = (SELECT MAX(id) FROM capability_request)
  AND q.created_at = $nowlit
  AND NOT EXISTS (SELECT 1 FROM event e
                   WHERE e.verb = 'requested' AND e.subject_type = 'capability_request'
                     AND e.subject_id = CAST(q.id AS TEXT));
COMMIT;
"
  if ! out="$(printf '%s' "$sql" | db_exec)"; then
    db_fail "could not file the capability request" "$out"
  fi
  line="$(printf '%s' "$out" | head -n1)"
  case "$line" in
    'OK|'*)
      rest="${line#OK|}"
      id="${rest%%|*}"
      row="${rest#*|}"
      case "$row" in
        '{'*'}') ;;
        *) die "guild: could not file the capability request (unexpected database output)" ;;
      esac
      journal_append capability_request upsert "$row"
      printf '%s\n' "$id"
      return 0
      ;;
  esac

  # Nothing was inserted. The three diagnostics say which of the three reasons it was; they
  # are checked in the order that makes the most actionable one win.
  vocabmiss="$(printf '%s\n' "$out" | LC_ALL=C awk -F'|' '$1 == "HAVE" { printf "%s%s", (n++ ? ", " : ""), $2 } END { print "" }')"
  if [ -n "$vocabmiss" ]; then
    die "guild: the guild already has '$cap' — it is declared by: $vocabmiss

That is not a roster gap. If those members cannot actually do the work, the fix is a new
member with a DIFFERENT capability, or a correction to their agent file."
  fi
  vocabmiss="$(printf '%s\n' "$out" | LC_ALL=C awk -F'|' '$1 == "DUP" { print $2; exit }')"
  if [ -n "$vocabmiss" ]; then
    die "guild: '$cap' is already an open roster gap (CAP-REQ $vocabmiss).

One capability is one decision for the guild master, however many requirements need it.
Read it with 'guild capability-requests --open'; it is also in 'guild brief'."
  fi
  vocabmiss="$(printf '%s\n' "$out" | LC_ALL=C awk -F'|' '$1 == "MISS" { print $2; exit }')"
  [ -z "$vocabmiss" ] || die "guild: $vocabmiss not found"
  die "guild: could not file the capability request"
}

# cmd_capability_requests [--open] — the gaps, one per line.
#
#   <id> <status> <capability> <requirement> <proposed-agent> <rationale>
#
# Five `_render_col` columns then the rationale flattened and LAST, which is `bug list`'s
# and `coverage list`'s shape and for their reason: a fixed field count survives
# `awk '$2 == "open"'`. The id is an INTEGER on a STRICT table, so it concatenates
# unescaped.
cmd_capability_requests() {
  local only_open=0 cols where
  while [ $# -gt 0 ]; do
    case "$1" in
      --open) only_open=1 ;;
      -*) die "guild: unknown option '$1' for capability-requests (try 'guild capability-requests [--open]')" ;;
      *) die "guild: capability-requests takes no positional arguments (got '$1')" ;;
    esac
    shift
  done
  db_require_init

  cols="q.id || ' ' || $(_render_col 'q.status') || ' ' || $(_render_col 'q.capability')"
  cols="$cols || ' ' || $(_render_col 'q.requirement_id') || ' ' || $(_render_col 'q.proposed_agent')"
  cols="$cols || ' ' || $(_render_flat "$(_brief_clip 'q.rationale' 160)")"

  where=""
  [ "$only_open" = 0 ] || where=" WHERE q.status = 'open'"

  printf 'SELECT %s FROM capability_request q%s ORDER BY q.id;\n' "$cols" "$where" | db_query
}
