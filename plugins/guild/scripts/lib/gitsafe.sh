# shellcheck shell=bash
#
# lib/gitsafe.sh — guild v5 Stage 5: GIT SAFETY FOR UNATTENDED WORK (design §8.6).
#
#   guild git branch-for   <REQ-NNN>    ensure and switch to `guild/REQ-NNN`
#   guild git commit-task  <TASK-NNN>   commit that task's work
#   guild git revert-task  <TASK-NNN>   discard a failed task's partial edits
#   guild git shift-status              what a shift has done to the tree
#
# THIS IS THE HIGHEST-RISK FILE IN THE DESIGN, and the reason is one sentence: every other
# module writes rows, this one writes the guild master's SOURCE TREE. A wrong row is
# recoverable from the journal; a wrong `git restore` is somebody's afternoon. So the
# posture here is different from the rest of the CLI — where another module would pick the
# most likely interpretation and proceed, this one REFUSES AND SAYS WHY.
#
# ---------------------------------------------------------------------------------
# THE FOUR INVARIANTS. Everything below is machinery for these.
#
#   1. A SHIFT WORKS ON A DEDICATED BRANCH — `guild/REQ-NNN`, created if absent.
#      `commit-task` and `revert-task` refuse on any other branch, by NAME, and the name
#      must match the requirement the task belongs to. That single check subsumes the
#      default-branch refusal (a default branch is never called `guild/REQ-007`), but the
#      default branch is ALSO detected and refused by name, because "you are on main" is
#      the message that stops a human in their tracks and "the branch is not guild/REQ-007"
#      is not.
#
#   2. NEVER PUSH, NEVER COMMIT TO THE DEFAULT BRANCH. Publishing stays a guild-master
#      action. `push` is not implemented, is not on `_gs_git`'s allowlist, and
#      `guild git push` is a NAMED REFUSAL rather than an unknown-subcommand error — the
#      person typing it deserves the reason, not a typo message.
#
#   3. ONE COMMIT PER COMPLETED TASK, with the task id in the trailer. A bad overnight run
#      is then bisectable and revertible task by task, and `git log` becomes a second
#      record of the shift beside the `event` table (§8.6). The two records are kept in
#      correspondence deliberately: every commit carries `Guild-Task:`, and every commit
#      writes a `committed` event, so either one can be checked against the other.
#
#   4. NOTHING IS COMMITTED FOR A `failed` TASK. `revert-task` discards its partial edits
#      before the next bounty starts, so one bad task cannot contaminate the next.
#
# ---------------------------------------------------------------------------------
# THE FIFTH RULE, WHICH THE DESIGN STATES AND WHICH TURNS OUT TO NEED MACHINERY:
# REFUSE TO OPERATE ON A DIRTY TREE THE SHIFT DID NOT CREATE.
#
# A guild master's uncommitted work must never be swept into a shift commit or thrown away
# by a shift revert. "Is this dirt ours?" is not answerable from the tree — a modified file
# looks the same whichever hand modified it — so the shift RECORDS ITS BASELINE and answers
# the question from that record.
#
# The baseline is the SHIFT STAMP: five `guild_state` rows written by `branch-for`.
#
#   git-shift:requirement   REQ-007
#   git-shift:branch        guild/REQ-007
#   git-shift:base          <sha the branch started from>
#   git-shift:head          <sha the tree was clean at — advanced by every commit>
#   git-shift:started       <UTC timestamp>
#
# `branch-for` writes the stamp ONLY from a clean tree (the guild directory excepted, see
# below), so the stamp is a promise: "at `head`, on `branch`, the tree held nothing but
# committed work." A later `commit-task` or `revert-task` re-derives that promise —
# the stamp's branch must be the branch checked out now, and its `head` must be an ancestor
# of the current `HEAD` — and REFUSES IF IT CANNOT. No stamp means no proof the dirt is the
# shift's, and with no proof neither command touches a byte.
#
# `guild_state` rather than a file under `.guild/`: it is an existing table, already
# journaled, already replayed by `guild rebuild`, and already where this CLI keeps small
# facts about the board (`last-checkin`, `graph-template:REQ-NNN`). A dotfile would have
# been a sixth durability story for five short strings — and would have needed a
# `.gitignore` entry in a file this module does not own.
#
# WHY FIVE KEYS AND NOT ONE JSON BLOB. `shift-status` asks the database for the events
# since the shift began, which means SQL has to compare against `started` — trivial against
# its own row, a `json_extract` and a nested-JSON journal line against a blob. Five rows
# also read back as five plain marker lines instead of needing a shell-side JSON parser,
# and this file has enough parsing in it already.
#
# ---------------------------------------------------------------------------------
# THE GUILD DIRECTORY IS EXCLUDED FROM EVERY WRITE OPERATION, and this is not a detail.
#
# `.guild/journal.ndjson` and `.guild/export/` are tracked files that the guild's own
# commands rewrite constantly — running `guild move` dirties the tree. A literal "refuse
# unless `git status` is empty" would therefore refuse ALWAYS, on every board, forever. So
# every tree-facing operation in this file is scoped `-- . ':(exclude)<guild-dir>'`:
#
#   * the dirty check ignores the board, so the guild's own bookkeeping never reads as the
#     guild master's uncommitted work;
#   * staging ignores the board, so a task commit is CODE and nothing else — the journal is
#     board state and the guild master commits it deliberately, as its own change;
#   * restore and quarantine ignore the board, which is the load-bearing half: a
#     `git restore -- .` would roll `journal.ndjson` back to the last commit and DESTROY
#     the record of everything the shift journaled since, and a `git clean` would delete
#     the in-flight agent spool. The one command whose job is to undo a task's work would
#     have undone the guild's memory of the whole shift.
#
# ---------------------------------------------------------------------------------
# NOTHING THIS FILE DOES IS UNRECOVERABLE. `revert-task` is the only destructive command,
# and before it restores anything it writes `git diff HEAD` to a patch file and MOVES (not
# deletes) untracked files into `.guild/backup-revert-<TASK>-<ts>/`. `backup-*/` is already
# gitignored by `guild init`, so the quarantine neither dirties the tree nor gets committed
# by anyone. If the guard was wrong and the edits were somebody's, they are still there.
#
# ---------------------------------------------------------------------------------
# HARD RULES honored throughout (§2.2, §2.2.1, §3.0, and the four review rounds):
#
#   * sql_text FOR ALL FREE TEXT. Task titles, requirement titles, branch names, commit
#     subjects, quarantine paths — everything that reaches SQL from git or from a human
#     travels as hex. sql_str is used only for this file's own generated tokens (a verb, a
#     status word, a `git-shift:` key).
#
#   * NEVER `WITH RECURSIVE`. There is no traversal here at all; the only join is a task to
#     its requirement.
#
#   * ROUND TRIPS. Each command is TWO db calls, not one, and the count is FIXED — it never
#     grows with the data. This is the one place in the CLI where one call is impossible,
#     and the reason is structural rather than lazy: THE MUTATION IS NOT IN THE DATABASE.
#     A `guild gate` can guard its write inside the statement that performs it, because the
#     guard and the write are both SQL. Here the write is `git commit`, so the sequence is
#     necessarily: read the preconditions, do the git work, record what actually happened.
#     Folding the record into the read would journal a commit before knowing whether git
#     made one — an event that lies is worse than an extra round trip. Both halves are one
#     composed script each; nothing loops over rows calling the driver.
#
#   * EVERY MUTATION IS RECORDED. Four verbs, all against `subject_type` `task` except the
#     first: `branched` (requirement), `committed`, `nothing-to-commit`, `reverted`. The
#     third is not bookkeeping noise — see `_gs_commit_task`, where its ABSENCE would have
#     deadlocked every requirement containing a node that writes no code.
#     `event` rows are journaled by `guild journal sync`, as they are everywhere else in
#     this CLI (there is deliberately no `event` arm in `_art_json_row`); the `guild_state`
#     stamp rows ARE journaled here, in the same script that writes them.
#
#   * No quadratic string handling. Marker lines are split by `read` with a fixed field
#     count so free text lands last and untouched; the commit log is reduced by ONE awk
#     pass over record-separated output; no `${v%%pat*}` is applied to an unbounded value.
#
#   * Bash 3.2. No associative arrays, no `mapfile`, no `${var^^}`. No arrays at all, in
#     fact: `"${a[@]}"` on an empty array is an unbound-variable error under `set -u` in
#     3.2, and the pathspec suffix this file appends to half its git calls is exactly the
#     "sometimes empty" case that trips it. `_gs_scoped` passes the two positional forms
#     explicitly instead.
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` — scripts/guild owns those.
#
# Depends on lib/db.sh       : die, db_fail, db_require_init, db_exec, db_query, db_now,
#                              guild_root, sql_str, sql_text
#          on lib/journal.sh : journal_preflight, journal_append
#          on lib/artifacts.sh: _art_actor, _art_json_row (THE ONE PROJECTION REGISTRY)
#          on lib/render.sh  : _render_flat, _render_flat_arg, _render_tmp
#          on lib/graph.sh   : _graph_check_req, _graph_field, _graph_journal_markers
#
# WIRING (scripts/guild): `gitsafe` in the module list, and `git) cmd_git "$@" ;;` in the
# dispatcher. This module defines `cmd_git` and nothing else at the top level.

# ---- globals set by _gs_setup ------------------------------------------------------
#
# GS_ROOT     the repository's top level, resolved physically
# GS_EXCL     the pathspec that excludes the guild directory, or '' when it is outside
# GS_BRANCH   the branch checked out now, or '' when HEAD is detached
# GS_DEFAULT  the detected default branch, or '' when it could not be determined
#
# and by _gs_stamp_load:
#
# GS_ST_REQ GS_ST_BRANCH GS_ST_BASE GS_ST_HEAD GS_ST_STARTED   ('' when there is no stamp)

# ============================ the git wrapper =========================================

# _gs_git <args...> — run git, safely, from the repository root.
#
# EVERY git INVOCATION IN THIS FILE GOES THROUGH HERE. That is what makes the safety
# properties auditable: there is one place to read to know what this module can do to a
# repository, and one place a future edit has to get past to add something.
#
# The allowlist is the point. `push`, `reset`, `rebase`, `merge`, `cherry-pick`, `clean`,
# `gc`, `filter-branch`, `remote`, `fetch`, `pull` and `tag` are not on it, so no edit to
# the commands below can reach them by accident — a typo becomes a loud internal error
# instead of a published branch. `clean` in particular is absent BY DESIGN: this file
# quarantines untracked files with `mv` rather than deleting them (see `_gs_revert_task`),
# so it never needs the one git command that destroys work git has never seen.
#
# The flag denylist is the second layer, against the arguments rather than the verb.
# `-f` / `--force` / `-D` / `--hard` / `--amend` / `--force-with-lease` are refused
# wherever they appear. None of the calls below wants any of them: `add -f` would stage
# ignored files, `--amend` would rewrite history the design forbids rewriting, and `-D`
# would delete a branch this module has no business deleting.
#
# The fixed options are unattended-operation hygiene, and each one is a hang this file
# would otherwise inherit at 3am:
#
#   --no-pager / GIT_PAGER=cat   a `log` or `diff` that opens `less` and waits forever
#   GIT_TERMINAL_PROMPT=0        a credential prompt on a repository with a hook that
#                                talks to a remote; fail fast instead of blocking
#   -c commit.gpgsign=false      a GPG passphrase prompt — and, more than that, a
#                                CORRECTNESS point: a machine commit made by a shift must
#                                not carry the guild master's signature. It is not their
#                                commit. They sign what they publish.
#   -C "$GS_ROOT"                every pathspec in this file is `.`-anchored, and `.` from
#                                a subdirectory silently scopes the whole command to that
#                                subdirectory. Anchoring at the top level makes `.` mean
#                                what it reads as.
#
# HOOKS ARE NOT BYPASSED. `--no-verify` is deliberately NOT passed: a repository's own
# pre-commit checks are exactly the kind of safety this file exists to respect, and
# silently skipping them while claiming to be the careful component would be incoherent.
# A hook that blocks is a refusal the guild master gets to see in the morning.
_gs_git() {
  local sub="${1-}" a
  [ -n "$sub" ] || die "guild: internal error — _gs_git called with no subcommand"

  # The allowlist is EXACTLY what the four commands below call — not a generous list of
  # harmless-looking verbs. Adding one means having a call site for it.
  case "$sub" in
    rev-parse | status | symbolic-ref | merge-base | log | diff | version | \
      config | rev-list | show-ref | var | worktree | switch | add | commit | restore) ;;
    *)
      die "guild: internal error — 'git $sub' is not on the guild's allowlist.

lib/gitsafe.sh may run only the commands it needs to branch, stage, commit and restore.
push, fetch, pull, merge, rebase, reset, cherry-pick, clean, tag and gc are not among
them: publishing and history rewriting are guild-master actions (design 8.6)."
      ;;
  esac

  for a in "$@"; do
    case "$a" in
      -f | --force | --force-with-lease | -D | --hard | --amend | -x | --no-verify)
        die "guild: internal error — 'git $sub' was passed '$a', which lib/gitsafe.sh refuses.

Forcing, hard resets, amending and bypassing hooks are all ways to destroy work that git
would otherwise have kept. None of this module's operations needs one."
        ;;
    esac
  done

  GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat \
    git --no-pager -C "${GS_ROOT:-.}" -c commit.gpgsign=false "$@"
}

# _gs_git_q <args...> — the same, discarding stdout and stderr, for predicate calls.
# Used where git's own message is noise and the exit status is the answer.
_gs_git_q() {
  _gs_git "$@" >/dev/null 2>&1
}

# ============================ repository facts ========================================

# _gs_setup — establish GS_ROOT / GS_EXCL / GS_BRANCH / GS_DEFAULT, or die.
#
# Called first by every command. It is also where the repository is checked for the states
# in which NO automated git operation is safe: a half-finished merge, rebase, cherry-pick,
# revert or bisect. Committing into one of those produces a commit nobody asked for on a
# ref nobody expected, and restoring inside one can lose the conflict resolution somebody
# was half-way through. Both are refusals, not warnings.
_gs_setup() {
  local root gitdir op

  GS_ROOT=""
  if ! root="$(git rev-parse --show-toplevel 2>/dev/null)" || [ -z "$root" ]; then
    die "guild: this is not a git repository (or git is not installed).

'guild git' manages a shift's branch and commits, so it needs one. Run it from inside the
repository the guild is working on."
  fi
  # Resolve physically so the prefix test against the guild directory below compares like
  # with like: on macOS /tmp is a symlink to /private/tmp and `pwd -P` disagrees with git
  # about which spelling is the path.
  GS_ROOT="$(cd "$root" 2>/dev/null && pwd -P)" || GS_ROOT="$root"

  if ! _gs_git_q rev-parse --verify HEAD; then
    die "guild: this repository has no commits yet — there is nothing for a shift to branch from.

Make the first commit yourself, then run 'guild git branch-for REQ-NNN'."
  fi

  gitdir="$(_gs_git rev-parse --git-dir 2>/dev/null || true)"
  case "$gitdir" in
    /*) ;;
    *) gitdir="$GS_ROOT/$gitdir" ;;
  esac
  op=""
  [ ! -e "$gitdir/MERGE_HEAD" ] || op="a merge"
  [ ! -d "$gitdir/rebase-merge" ] || op="a rebase"
  [ ! -d "$gitdir/rebase-apply" ] || op="a rebase"
  [ ! -e "$gitdir/CHERRY_PICK_HEAD" ] || op="a cherry-pick"
  [ ! -e "$gitdir/REVERT_HEAD" ] || op="a revert"
  [ ! -e "$gitdir/BISECT_LOG" ] || op="a bisect"
  [ -z "$op" ] ||
    die "guild: $op is in progress in this repository — refusing every git operation.

Nothing was written. A shift must not commit into a half-finished $op or restore over a
conflict resolution somebody is part-way through. Finish or abort it first, then re-run."

  GS_BRANCH="$(_gs_git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  GS_DEFAULT="$(_gs_default_branch)"
  GS_GUILD_REL="$(_gs_guild_rel)"
  GS_EXCL=""
  [ -z "$GS_GUILD_REL" ] || GS_EXCL=":(exclude)$GS_GUILD_REL"
}

# _gs_guild_rel — the guild directory RELATIVE TO THE REPOSITORY ROOT, or the empty string
# when it is not inside this repository.
#
# Two callers want it in two forms: as `:(exclude)<rel>` (every tree operation, see the
# header) and as a plain pathspec (the staged-board check in `_gs_commit_task`). It is
# derived once in `_gs_setup` and both forms are globals, because deriving it twice means a
# `cd` and a `pwd -P` per git call.
#
# The failure mode the exclusion prevents is the worst one in this file: `revert-task`
# rolling `journal.ndjson` back to the last commit and taking the record of the whole shift
# with it.
_gs_guild_rel() {
  local g abs rel
  guild_root >/dev/null
  g="$GUILD_DIR"
  if [ -d "$g" ]; then
    abs="$(cd "$g" 2>/dev/null && pwd -P)" || abs=""
  else
    case "$g" in
      /*) abs="$g" ;;
      *) abs="$PWD/$g" ;;
    esac
  fi
  [ -n "$abs" ] || return 0
  [ -n "${GS_ROOT:-}" ] || return 0

  if [ "$abs" = "$GS_ROOT" ]; then
    die "guild: the guild directory IS the repository root ($abs).

Every tree operation in 'guild git' excludes the guild directory, so with those two the
same path there is nothing left to commit or restore, and a shift cannot tell the board's
own files from the code it is meant to be writing. Move the board into a subdirectory
(the default is .guild/) or set \$GUILD_DIR."
  fi

  case "$abs" in
    "$GS_ROOT"/*)
      # The pattern is QUOTED inside the expansion. A repository path containing '[' or '*'
      # is a glob pattern otherwise, and the prefix then fails to strip — leaving an
      # absolute path in a pathspec, which git reads as a path outside the repository.
      rel="${abs#"$GS_ROOT"/}"
      printf '%s\n' "$rel"
      ;;
    *)
      # The board lives outside the repository. Nothing to exclude, and nothing to warn
      # about: git will never see it.
      ;;
  esac
}

# _gs_scoped <git args...> — run a git command over the working tree, with the guild
# directory excluded.
#
# The two-branch spelling is bash 3.2's fault, and deliberate: an array would be the
# natural way to carry an optional trailing pathspec, and `"${a[@]}"` on an empty array is
# an unbound-variable error under `set -u` in 3.2. Writing both forms out is uglier and
# cannot break.
_gs_scoped() {
  if [ -n "${GS_EXCL:-}" ]; then
    _gs_git "$@" -- . "$GS_EXCL"
  else
    _gs_git "$@" -- .
  fi
}

# _gs_default_branch — the repository's default branch, or '' if it cannot be determined.
#
# DETECTED, NEVER ASSUMED (design §8.6). Three sources, most authoritative first:
#
#   1. `refs/remotes/origin/HEAD` — what the remote itself says. Set by `git clone`, and
#      refreshable with `git remote set-head origin -a`.
#   2. `init.defaultBranch` — what this user's git creates by default, when such a branch
#      actually exists locally.
#   3. The conventional names, when exactly ONE of them exists locally. Two candidates is
#      not a tie to break — it is an ambiguity, and this function answers '' rather than
#      guessing.
#
# '' is a safe answer everywhere it is used, because detection is a SECOND line of defence:
# the first is that a shift may only ever commit on a branch named `guild/REQ-NNN`, which
# no default branch is. What detection buys is the message — "you are on main" stops a
# reader, "the branch is not guild/REQ-007" makes them work it out.
_gs_default_branch() {
  local ref name c found=""

  ref="$(_gs_git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  case "$ref" in
    origin/?*)
      printf '%s\n' "${ref#origin/}"
      return 0
      ;;
  esac

  name="$(_gs_git config --get init.defaultBranch 2>/dev/null || true)"
  if [ -n "$name" ] && _gs_git_q show-ref --verify "refs/heads/$name"; then
    printf '%s\n' "$name"
    return 0
  fi

  for c in main master trunk development; do
    if _gs_git_q show-ref --verify "refs/heads/$c"; then
      [ -z "$found" ] || return 0 # two candidates: ambiguous, answer nothing
      found="$c"
    fi
  done
  [ -z "$found" ] || printf '%s\n' "$found"
}

# _gs_protected <branch> — is committing to <branch> forbidden outright?
#
# The detected default, plus the conventional names whether or not detection found them,
# plus anything under `release/`. Belt and braces: `_gs_require_shift_branch` has already
# refused every name that is not `guild/REQ-NNN` by the time this is consulted, and this
# exists so the REFUSAL MESSAGE can be the loud one.
_gs_protected() {
  local b="${1-}"
  [ -n "$b" ] || return 1
  [ "$b" != "${GS_DEFAULT:-}" ] || return 0
  case "$b" in
    main | master | trunk | development | develop | release | release/*) return 0 ;;
  esac
  return 1
}

# _gs_branch_name <REQ-NNN> — the shift branch for a requirement. One spelling, one place.
_gs_branch_name() {
  printf 'guild/%s\n' "${1-}"
}

# _gs_branch_exists <branch>
_gs_branch_exists() {
  _gs_git_q show-ref --verify "refs/heads/${1-}"
}

# _gs_branch_worktree <branch> — the path of ANOTHER worktree that has <branch> checked
# out, or ''.
#
# A branch checked out elsewhere cannot be switched to, and git's own error for it is
# accurate but arrives after the shift has already decided it is on the branch. Asking
# first turns a mid-command failure into a refusal that names the directory.
_gs_branch_worktree() {
  local b="${1-}" tmp hit res
  [ -n "$b" ] || return 0
  tmp="$(_render_tmp gitsafe-wt)"
  if ! _gs_git worktree list --porcelain >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  # A branch can be checked out in at most one worktree, so the first match is the answer.
  # `substr` rather than field splitting: a worktree path may contain spaces.
  hit="$(LC_ALL=C awk -v want="refs/heads/$b" '
    substr($0, 1, 9)  == "worktree " { p = substr($0, 10) }
    substr($0, 1, 7)  == "branch "   { if (substr($0, 8) == want) { print p; exit } }
  ' "$tmp")"
  rm -f "$tmp"
  [ -n "$hit" ] || return 0
  # Resolve before comparing: git reports the worktree's configured path, which may differ
  # from GS_ROOT only by a symlink. Reporting "checked out elsewhere" for THIS worktree
  # would refuse a perfectly ordinary resume.
  res="$(cd "$hit" 2>/dev/null && pwd -P)" || res="$hit"
  [ "$res" != "$GS_ROOT" ] || return 0
  printf '%s\n' "$hit"
}

# _gs_require_switch_restore — refuse rather than improvise on git older than 2.23.
#
# `git switch` and `git restore` both landed in 2.23, and they are what the design names.
# Their older equivalents are `git checkout` (one overloaded verb doing both jobs, with the
# footgun that `git checkout <path>` silently discards a working-tree file) and `git reset`
# — neither is on `_gs_git`'s allowlist, and neither ever will be. A refusal naming the
# version is better than a fallback path nobody will ever exercise on a machine where it
# matters.
_gs_require_switch_restore() {
  local v major minor
  v="$(_gs_git version 2>/dev/null || git --version 2>/dev/null || true)"
  v="${v##* }"
  major="${v%%.*}"
  minor="${v#*.}"
  minor="${minor%%.*}"
  case "$major$minor" in
    *[!0-9]* | '')
      # Unparseable version. Do not guess in either direction — ask the command itself.
      # `git restore -h` exits 129 (usage) when it EXISTS and 1 when it does not, so the
      # exit status is useless as a predicate and the text is what answers; the `|| true`
      # keeps that 129 from ending the whole pipeline under `set -o pipefail`.
      if { _gs_git restore -h 2>&1 || true; } | LC_ALL=C grep -q 'git restore'; then
        return 0
      fi
      die "guild: this git has no 'git switch' / 'git restore' (needs git 2.23 or newer).

'guild git' will not improvise with 'git checkout' or 'git reset' on somebody's working
tree. Upgrade git, or drive the shift's branch and reverts by hand."
      ;;
  esac
  if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 23 ]; }; then
    die "guild: git $v has no 'git switch' / 'git restore' (needs 2.23 or newer).

'guild git' will not improvise with 'git checkout' or 'git reset' on somebody's working
tree. Upgrade git, or drive the shift's branch and reverts by hand."
  fi
}

# _gs_require_identity — refuse to commit with no configured author.
#
# `git commit` would fail on its own, with a long block of advice about `--global` config.
# Catching it first means nothing has been staged when the refusal lands, and the message
# can say what a shift needs rather than what an interactive user needs.
_gs_require_identity() {
  _gs_git_q var GIT_AUTHOR_IDENT ||
    die "guild: git has no author identity configured, so a shift cannot commit.

Nothing was staged. Set one in the repository, or globally:

  git config user.name  'Your Name'
  git config user.email 'you@example.com'"
}

# ---- the working tree ---------------------------------------------------------------

# _gs_status_z <out-file> — `git status --porcelain -z -uall`, guild directory excluded.
#
# `-uall` rather than the default: the default collapses an untracked DIRECTORY to one
# entry with a trailing slash, and `revert-task` moves untracked paths one file at a time.
# `-z` because a path is free text — a filename may contain a newline, and every other
# separator this CLI trusts is one a filename may also contain. NUL is the only one it
# cannot.
_gs_status_z() {
  local out="${1-}"
  if ! _gs_scoped status --porcelain -z --untracked-files=all >"$out" 2>/dev/null; then
    die "guild: 'git status' failed in $GS_ROOT — refusing to go further (nothing was written)."
  fi
}

# _gs_status_counts <status-file> — "<tracked> <untracked>" over a `-z` status file.
#
# A `read -d ''` LOOP AND NOT AWK, and the reason is a portability trap worth naming.
# Setting `RS` to NUL is the obvious way to parse `-z` output, and it does not work: awk
# holds strings as C strings, so `RS="\0"` becomes `RS=""` — which is PARAGRAPH MODE, a
# completely different parse that silently produces plausible-looking wrong numbers. bash's
# `read -d ''` handles NUL correctly, and the loop is bounded by the number of changed
# files, not by the size of the board, so it is not the per-row chatter §2.2 forbids.
#
# The rename/copy records (`R`/`C`) carry a SECOND NUL-terminated field holding the source
# path; it is skipped with a flag rather than by re-splitting, so the scan stays linear.
_gs_status_counts() {
  local f="${1-}" t=0 u=0 skip=0 rec
  while IFS= read -r -d '' rec; do
    if [ "$skip" = 1 ]; then
      skip=0
      continue
    fi
    [ -n "$rec" ] || continue
    case "${rec:0:2}" in
      '??')
        u=$((u + 1))
        continue
        ;;
      R* | C*) skip=1 ;;
    esac
    t=$((t + 1))
  done <"$f"
  printf '%d %d\n' "$t" "$u"
}

# _gs_dirty — is the working tree dirty, the guild directory excepted?
_gs_dirty() {
  local f counts
  f="$(_render_tmp gitsafe-status)"
  _gs_status_z "$f"
  counts="$(_gs_status_counts "$f")"
  rm -f "$f"
  [ "$counts" != "0 0" ]
}

# ============================ ids =====================================================

# _gs_check_task <TASK-NNN> — die unless <v> is a well-formed task id.
#
# The closed alphabet is what lets a task id reach SQL through `sql_str` and be
# concatenated into a message; every other value this file handles is free text.
_gs_check_task() {
  local v="${1-}"
  local LC_ALL=C
  [ -n "$v" ] || die "guild: this command requires a task id (TASK-NNN)"
  case "$v" in
    TASK-[0-9]*)
      case "${v#TASK-}" in
        *[!0-9]*) die "guild: '$v' is not a task id (expected TASK-NNN)" ;;
      esac
      ;;
    *) die "guild: '$v' is not a task id (expected TASK-NNN)" ;;
  esac
  [ "${#v}" -le 32 ] || die "guild: '$v' is not a task id (expected TASK-NNN)"
}

# _gs_req_of_branch <branch> — 'guild/REQ-007' -> 'REQ-007', or '' for any other name.
_gs_req_of_branch() {
  local b="${1-}"
  case "$b" in
    guild/REQ-[0-9]*)
      b="${b#guild/}"
      case "${b#REQ-}" in
        *[!0-9]*) return 0 ;;
      esac
      printf '%s\n' "$b"
      ;;
  esac
}

# ============================ the shift stamp =========================================

# _gs_state_key <field> — the `guild_state` key for one stamp field. One spelling.
_gs_state_key() {
  printf 'git-shift:%s\n' "${1-}"
}

# _gs_stamp_select — the SELECT that reads the whole stamp back as marker lines.
#
# Every value in it was generated by this file from a closed alphabet (a requirement id, a
# branch name built from one, two hex shas, one ISO timestamp), so the pipe-separated
# marker cannot be forged from outside. The LIKE pattern is a literal.
_gs_stamp_select() {
  printf "SELECT 'GS|' || key || '|' || value FROM guild_state WHERE key LIKE 'git-shift:%%' ORDER BY key;\n"
}

# _gs_stamp_reset — clear the loaded stamp globals.
_gs_stamp_reset() {
  GS_ST_REQ=""
  GS_ST_BRANCH=""
  GS_ST_BASE=""
  GS_ST_HEAD=""
  GS_ST_STARTED=""
}

# _gs_stamp_load <marker-file> — fill the GS_ST_* globals from `GS|key|value` lines.
_gs_stamp_load() {
  local f="${1-}" tag key val
  _gs_stamp_reset
  [ -f "$f" ] || return 0
  while IFS='|' read -r tag key val; do
    [ "$tag" = "GS" ] || continue
    case "$key" in
      git-shift:requirement) GS_ST_REQ="$val" ;;
      git-shift:branch) GS_ST_BRANCH="$val" ;;
      git-shift:base) GS_ST_BASE="$val" ;;
      git-shift:head) GS_ST_HEAD="$val" ;;
      git-shift:started) GS_ST_STARTED="$val" ;;
    esac
  done <"$f"
}

# _gs_stamp_valid — does the loaded stamp describe THIS branch and THIS history?
#
# THE WHOLE OF THE "IS THIS DIRT OURS?" ANSWER (see the header). Three conditions, and all
# three are necessary:
#
#   * the stamp names a branch, and it is the branch checked out now — otherwise the stamp
#     describes a different piece of work;
#   * the stamp's `head` still resolves in this repository — otherwise the stamp came from
#     another clone through the journal, and says nothing about this tree;
#   * the stamp's `head` is an ancestor of the current HEAD — otherwise history moved under
#     the shift (someone reset, rebased or checked out something else) and the promise
#     "the tree was clean at `head`" no longer covers what is in front of us.
_gs_stamp_valid() {
  [ -n "${GS_ST_BRANCH:-}" ] || return 1
  [ -n "${GS_BRANCH:-}" ] || return 1
  [ "$GS_ST_BRANCH" = "$GS_BRANCH" ] || return 1
  [ -n "${GS_ST_HEAD:-}" ] || return 1
  _gs_git_q rev-parse --verify --quiet "${GS_ST_HEAD}^{commit}" || return 1
  _gs_git_q merge-base --is-ancestor "$GS_ST_HEAD" HEAD || return 1
  return 0
}

# _gs_stamp_sql <req> <branch> <base> <head> <started> — the five upserts and their
# journal markers, as one SQL fragment.
#
# `guild_state` is journaled at the point of writing (it has a `_art_json_row` arm), unlike
# `event`, which `guild journal sync` folds in later. So each upsert RETURNs its full row.
_gs_stamp_sql() {
  local req="${1-}" branch="${2-}" base="${3-}" head="${4-}" started="${5-}"
  local proj k v out=""
  proj="$(_art_json_row guild_state)"
  for k in requirement branch base head started; do
    case "$k" in
      requirement) v="$req" ;;
      branch) v="$branch" ;;
      base) v="$base" ;;
      head) v="$head" ;;
      started) v="$started" ;;
    esac
    out="${out}INSERT INTO guild_state (key, value) VALUES ($(sql_str "$(_gs_state_key "$k")"), $(sql_text "$v" "the shift stamp's $k"))
ON CONFLICT(key) DO UPDATE SET value = excluded.value
RETURNING 'R|guild_state|upsert|' || $proj;
"
  done
  printf '%s' "$out"
}

# _gs_stamp_head_sql <head> — advance ONLY the head field. What a commit writes.
_gs_stamp_head_sql() {
  printf "INSERT INTO guild_state (key, value) VALUES (%s, %s)
ON CONFLICT(key) DO UPDATE SET value = excluded.value
RETURNING 'R|guild_state|upsert|' || %s;\n" \
    "$(sql_str "$(_gs_state_key head)")" \
    "$(sql_text "${1-}" 'the shift stamp head')" \
    "$(_art_json_row guild_state)"
}

# _gs_journal_markers <file> — journal every `R|table|op|{json}` line.
#
# ONE LINE, because there is ONE of these in the CLI. `_graph_journal_markers` is the whole
# implementation — the fixed-field `read` that keeps a JSON value containing a pipe intact,
# the `{…}` shape check, the loop reading from a FILE so a `die` inside `journal_append`
# ends the process rather than a subshell. It prints a count that this file has no use for,
# which is the only difference and is what the redirect is for; lib/shift.sh discards it the
# same way. An earlier draft of this module re-derived the loop instead, and a second copy
# of the journal write path is exactly the duplication `scripts/README.md` says is the bug.
_gs_journal_markers() {
  _graph_journal_markers "${1-}" >/dev/null
}

# _gs_run_sql <sql> <marker-file> <errmsg> — one db_exec, rows captured, failure relayed.
#
# The rows are staged in a FILE rather than piped into the parser for `_render_query`'s
# reason: in a pipeline the exit status belongs to the parser, so a failed query would be
# read as an empty result set and reported as success.
#
# stderr is deliberately NOT folded into the marker file: tursodb writes its diagnostics to
# stdout (which is why the captured buffer is what gets relayed on failure), and merging
# stderr would let a driver warning land in the middle of the markers and be parsed as one.
_gs_run_sql() {
  local sql="${1-}" out="${2-}" msg="${3-}" diag
  if ! printf '%s' "$sql" | db_exec >"$out"; then
    diag="$(cat "$out" 2>/dev/null || true)"
    rm -f "$out"
    db_fail "$msg" "$diag"
  fi
}

# ============================ guild git branch-for ====================================

# _gs_branch_for <REQ-NNN> [--from <ref>] — ensure `guild/REQ-NNN` exists and is checked
# out, and record the shift's baseline. Prints "<branch> <created|switched|current> <head>".
#
# THE CLEAN-TREE REFUSAL LIVES HERE, and it is the reason the other two commands can be
# confident later. `git switch` CARRIES uncommitted changes onto the branch it moves to —
# which is a feature when a human does it deliberately and a disaster when a shift does it
# at 3am to somebody's half-finished refactor. So: a dirty tree is refused unless the stamp
# already proves the dirt is this shift's own, mid-task work being resumed.
_gs_branch_for() {
  local req="" from="" branch created="" base head other markers sql
  local now started nowlit actorlit

  while [ $# -gt 0 ]; do
    case "$1" in
      --from)
        shift
        from="${1-}"
        [ $# -eq 0 ] || shift
        continue
        ;;
      --from=*) from="${1#--from=}" ;;
      -*) die "guild: unknown option '$1' for 'git branch-for' (try 'guild git branch-for REQ-NNN')" ;;
      *)
        [ -z "$req" ] ||
          die "guild: 'git branch-for' takes one requirement id (got '$req' and '$(_render_flat_arg "$1")')"
        req="$1"
        ;;
    esac
    shift
  done

  _graph_check_req "$req"
  branch="$(_gs_branch_name "$req")"

  db_require_init
  journal_preflight
  _gs_setup
  _gs_require_switch_restore

  # The shift branch must never BE the protected branch. It cannot be, given the `guild/`
  # prefix — unless someone has configured a default branch by that name, in which case the
  # invariant is genuinely at risk and a refusal is the only safe answer.
  if _gs_protected "$branch"; then
    die "guild: '$branch' is this repository's default (or a protected) branch — refusing.

A shift never commits to the branch you publish from (design 8.6). Rename the default
branch, or run the guild against a repository whose default is not 'guild/REQ-NNN'."
  fi

  # ---- read: does the requirement exist, and what does the stamp say? ---------------
  # The trailing newline after the substitution is LOAD-BEARING, here and in every other
  # composed script in this file: `$(...)` strips trailing newlines, and tursodb's script
  # splitter ends a statement at a `;` that ENDS A LINE (§2.2.1). Glue two statements onto
  # one line and the second is silently swallowed by the first.
  markers="$(_render_tmp gitsafe-branch)"
  sql="SELECT 'REQ|' || r.id FROM requirement r WHERE r.id = $(sql_str "$req");
$(_gs_stamp_select)
"
  _gs_run_sql "$sql" "$markers" "could not read the board before branching for $req"

  if ! LC_ALL=C grep -q "^REQ|$req\$" "$markers"; then
    rm -f "$markers"
    die "guild: there is no requirement '$req' — refusing to create a branch for it.

  guild list req        what exists
  guild new req --title '...'    if this is new work"
  fi
  _gs_stamp_load "$markers"
  rm -f "$markers"

  # ---- the dirty-tree gate ----------------------------------------------------------
  if _gs_dirty; then
    if _gs_stamp_valid && [ "$GS_BRANCH" = "$branch" ]; then
      : # our own mid-task work on our own branch; resuming is exactly the point
    else
      die "guild: the working tree has uncommitted changes that this shift did not make — refusing.

Nothing was written, and no branch was created or switched to. 'git switch' CARRIES
uncommitted changes onto the branch it moves to, so continuing would drag somebody's
work-in-progress onto '$branch' and put it in reach of a shift commit.

  git status                  what is uncommitted
  git stash                   set it aside, then re-run this command
  guild git shift-status      what the guild believes it has done to this tree

(The guild's own directory is ignored by this check — the board's journal and export are
expected to be dirty while the guild is running.)"
    fi
  fi

  # ---- ensure the branch, and switch to it ------------------------------------------
  if [ "${GS_BRANCH:-}" = "$branch" ]; then
    created="current"
  elif _gs_branch_exists "$branch"; then
    other="$(_gs_branch_worktree "$branch")"
    if [ -n "$other" ]; then
      die "guild: '$branch' is checked out in another worktree — refusing to switch.

  $other

Nothing was written. Two worktrees cannot hold one branch, and a shift must not guess which
of them is the one you meant. Run the shift there, or remove that worktree."
    fi
    _gs_git switch "$branch" >/dev/null 2>&1 ||
      die "guild: could not switch to '$branch' — nothing was written.

  git switch $branch     run it yourself to see git's own diagnosis"
    created="switched"
  else
    if [ -n "$from" ]; then
      _gs_git_q rev-parse --verify --quiet "${from}^{commit}" ||
        die "guild: --from '$(_render_flat_arg "$from")' does not name a commit in this repository."
      _gs_git switch -c "$branch" "$from" >/dev/null 2>&1 ||
        die "guild: could not create '$branch' from '$(_render_flat_arg "$from")' — nothing was written."
    else
      # No --from: branch from where the guild master left the repository. A DETACHED HEAD
      # is refused rather than captured, because it almost always means a bisect or a
      # half-finished operation, and a shift branch quietly rooted at one is a confusing
      # thing to find in the morning.
      [ -n "${GS_BRANCH:-}" ] ||
        die "guild: HEAD is detached, so there is no obvious place to branch from — refusing.

Nothing was written. Check out a branch first, or say explicitly where the shift starts:

  guild git branch-for $req --from <ref>"
      _gs_git switch -c "$branch" >/dev/null 2>&1 ||
        die "guild: could not create '$branch' — nothing was written.

  git switch -c $branch     run it yourself to see git's own diagnosis"
    fi
    created="created"
  fi

  GS_BRANCH="$(_gs_git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [ "$GS_BRANCH" = "$branch" ] ||
    die "guild: git reports HEAD on '$(_render_flat_arg "${GS_BRANCH:-detached}")' after switching to '$branch' — refusing to go on.

Nothing was recorded. This should not happen; do not run a shift until it is understood."

  head="$(_gs_git rev-parse HEAD 2>/dev/null || true)"
  [ -n "$head" ] || die "guild: could not resolve HEAD on '$branch' — nothing was recorded."

  # The base is where this branch's work starts. On a branch we just created that is HEAD;
  # on one we resumed it is whatever the stamp already recorded, and failing that the merge
  # base with the default branch — never re-derived as HEAD, which would erase the shift's
  # own commits from `shift-status`'s range.
  if [ "$created" = "created" ]; then
    base="$head"
  elif [ -n "${GS_ST_BASE:-}" ] && [ "${GS_ST_BRANCH:-}" = "$branch" ] &&
    _gs_git_q rev-parse --verify --quiet "${GS_ST_BASE}^{commit}"; then
    base="$GS_ST_BASE"
  elif [ -n "${GS_DEFAULT:-}" ] && _gs_branch_exists "$GS_DEFAULT"; then
    base="$(_gs_git merge-base "$GS_DEFAULT" HEAD 2>/dev/null || true)"
    [ -n "$base" ] || base="$head"
  else
    base="$head"
  fi

  # ---- write: the stamp and the event ------------------------------------------------
  #
  # `started` is PRESERVED when this is a resume of the same branch rather than reset to
  # now. It is the window `shift-status` counts events over, so restarting it would make an
  # interrupted shift look like it had done nothing — which is exactly the shift whose
  # history somebody most needs to read.
  now="$(db_now)"
  started="$now"
  if [ -n "${GS_ST_STARTED:-}" ] && [ "${GS_ST_BRANCH:-}" = "$branch" ]; then
    started="$GS_ST_STARTED"
  fi
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  markers="$(_render_tmp gitsafe-branch-w)"
  sql="BEGIN;
$(_gs_stamp_sql "$req" "$branch" "$base" "$head" "$started")
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
VALUES ($nowlit, $actorlit, 'branched', 'requirement', $(sql_str "$req"),
        json_object('branch', $(sql_text "$branch" 'the branch name'),
                    'base', $(sql_text "$base" 'the base commit'),
                    'head', $(sql_text "$head" 'the head commit'),
                    'how', $(sql_str "$created")));
COMMIT;
"
  _gs_run_sql "$sql" "$markers" "could not record the shift branch for $req"
  _gs_journal_markers "$markers"
  rm -f "$markers"

  printf '%s %s %s\n' "$branch" "$created" "$head"
}

# ============================ guild git commit-task ===================================

# _gs_commit_type <node-key> — the conventional-commit type for a task, from the graph node
# that produced it.
#
# `chore` is the default ON PURPOSE. Guessing `feat` would inflate the next release's
# version number from an unattended run nobody watched; guessing `chore` understates a
# feature, which a human fixes at release time by reading the commit. `--type` is how the
# orchestrator says what it actually knows.
_gs_commit_type() {
  case "${1-}" in
    implement | implement.*) printf 'feat\n' ;;
    repair | repair.* | fix | fix.* | bug | bug.*) printf 'fix\n' ;;
    test-write | test-write.* | test-plan | test-plan.* | qa* | inspect*) printf 'test\n' ;;
    doc | docs | docs.*) printf 'docs\n' ;;
    *) printf 'chore\n' ;;
  esac
}

# _gs_subject <text> — a one-line commit subject, trimmed at a WORD boundary.
#
# Truncation is at a space, never mid-word, and that is a UTF-8 correctness point rather
# than a style one: awk's `length()` is bytes in some awks and characters in others, so a
# byte-count cut can land inside a multi-byte character and produce an invalid UTF-8 commit
# message. Cutting only at ASCII spaces cannot, whichever awk this is.
_gs_subject() {
  printf '%s' "${1-}" | LC_ALL=C tr -d '\r' | LC_ALL=C tr '\n\t' '  ' |
    LC_ALL=C awk '
      {
        out = ""
        n = split($0, w, " ")
        for (i = 1; i <= n; i++) {
          if (w[i] == "") continue
          cand = (out == "") ? w[i] : out " " w[i]
          if (out != "" && length(cand) > 64) { out = out "..."; break }
          out = cand
        }
        print out
      }
    '
}

# _gs_commit_task <TASK-NNN> [--path P]... [--all] [--type T] [--scope S] [--subject S]
#                 [--dry-run]
#
# Prints "<TASK-NNN> <sha> <files>", or "<TASK-NNN> nothing-to-commit 0".
#
# ---------------------------------------------------------------------------------
# THE SIBLING GUARD, which is the one piece of this command that is not obvious.
#
# A parallel batch dispatches several developers at once against disjoint files (§6.4).
# They finish together, so at the moment the first one is committed the working tree holds
# THREE tasks' edits and `git add` cannot tell them apart. Committing anyway would produce
# a commit whose `Guild-Task:` trailer names one task and whose diff contains three — and
# then the other two commit nothing, so the log says work happened that the log cannot
# locate. Bisectability, the entire justification for committing per task, is gone.
#
# So: this command REFUSES when another task of the same requirement is `in-progress` or
# `done` and has no `committed` / `nothing-to-commit` / `reverted` event of its own. The
# two ways forward are both explicit, and both are recorded in the event payload:
#
#   --path P   stage only these paths. This is the architect's disjoint-file assertion
#              (`plan_slice.files`, §6.4) applied at commit time, and it is the right
#              answer for a parallel batch.
#   --all      stage the whole tree into this task's commit, knowing it may carry a
#              sibling's work. Honest, recorded, and available at 3am when a shift has no
#              other way forward.
#
# The assertion is NOT read from the database and applied automatically, and that is a
# decision rather than an omission. It is an ASSERTION — the architect's claim about which
# files a slice touches — not a guarantee, and an agent that also edited a file outside it
# would have that edit silently left behind, uncommitted, to be swept into the NEXT task's
# commit. Mis-attributing work to the following commit is a worse failure than refusing,
# because nothing about it is visible. The caller passes what it is willing to assert.
#
# WHY `nothing-to-commit` IS AN EVENT AND NOT A SHRUG. `test-plan` and `review` nodes
# complete without writing a line of code. With no record of that, they would sit forever
# in the sibling query as "done and uncommitted", and the guard above would refuse EVERY
# subsequent commit on that requirement. The verb that says "this task was accounted for
# and there was nothing to commit" is what keeps the guard from deadlocking the shift it
# is protecting.
_gs_commit_task() {
  local task="" want_all=0 dry=0 type="" scope="" subject="" npaths=0
  local markers sql line status req node group title reqtitle
  local branch head sha files msg mode sib="" now nowlit actorlit

  while [ $# -gt 0 ]; do
    case "$1" in
      --path)
        shift
        _gs_add_path "${1-}"
        [ $# -eq 0 ] || shift
        continue
        ;;
      --path=*) _gs_add_path "${1#--path=}" ;;
      --all) want_all=1 ;;
      --dry-run) dry=1 ;;
      --type)
        shift
        type="${1-}"
        [ $# -eq 0 ] || shift
        continue
        ;;
      --type=*) type="${1#--type=}" ;;
      --scope)
        shift
        scope="${1-}"
        [ $# -eq 0 ] || shift
        continue
        ;;
      --scope=*) scope="${1#--scope=}" ;;
      --subject)
        shift
        subject="${1-}"
        [ $# -eq 0 ] || shift
        continue
        ;;
      --subject=*) subject="${1#--subject=}" ;;
      -*) die "guild: unknown option '$1' for 'git commit-task' (try 'guild git commit-task TASK-NNN')" ;;
      *)
        [ -z "$task" ] ||
          die "guild: 'git commit-task' takes one task id (got '$task' and '$(_render_flat_arg "$1")')"
        task="$1"
        ;;
    esac
    shift
  done

  _gs_check_task "$task"
  npaths="$GS_NPATHS"
  [ "$npaths" = 0 ] || [ "$want_all" = 0 ] ||
    die "guild: --path and --all are exclusive — pass one.

--path stages exactly what you name; --all stages the whole working tree into this task's
commit. Saying both says nothing."

  case "$type" in
    "" | feat | fix | docs | test | chore | refactor | perf | build | ci | style | revert) ;;
    *)
      die "guild: '$(_render_flat_arg "$type")' is not a conventional-commit type.

  feat fix docs test chore refactor perf build ci style revert"
      ;;
  esac
  case "$scope" in
    "") ;;
    *[!a-z0-9._-]*)
      die "guild: a commit scope is limited to lowercase letters, digits, '.', '_' and '-'."
      ;;
  esac

  db_require_init
  journal_preflight
  _gs_setup
  _gs_require_identity

  # ---- read: the ticket, its requirement, its siblings, the stamp -------------------
  markers="$(_render_tmp gitsafe-commit)"
  sql="$(_gs_task_read_sql "$task")"
  _gs_run_sql "$sql" "$markers" "could not read $task before committing"

  if LC_ALL=C grep -q '^MISS|' "$markers"; then
    rm -f "$markers"
    die "guild: there is no task '$task'.

  guild list task     what exists"
  fi

  line="$(LC_ALL=C awk -F'|' '$1 == "T" { print; exit }' "$markers")"
  status="$(printf '%s' "$line" | cut -d'|' -f3)"
  req="$(printf '%s' "$line" | cut -d'|' -f4)"
  node="$(printf '%s' "$line" | cut -d'|' -f5)"
  group="$(printf '%s' "$line" | cut -d'|' -f6)"
  title="$(LC_ALL=C awk -F'|' '$1 == "TT" { sub(/^TT\|/, ""); print; exit }' "$markers")"
  reqtitle="$(LC_ALL=C awk -F'|' '$1 == "RT" { sub(/^RT\|/, ""); print; exit }' "$markers")"
  _gs_stamp_load "$markers"

  if LC_ALL=C grep -q '^DONE|' "$markers"; then
    line="$(LC_ALL=C awk -F'|' '$1 == "DONE" { print $2; exit }' "$markers")"
    rm -f "$markers"
    die "guild: $task has already been committed ('$line') — refusing to commit it twice.

Nothing was written. History is not rewritten here: there is no --amend, and a second
commit for one task would put the same ticket in the log twice with different diffs.

  guild git shift-status     the commits this shift has made"
  fi

  sib="$(LC_ALL=C awk -F'|' '$1 == "SIB" { printf "%s ", $2 }' "$markers")"
  rm -f "$markers"

  # ---- the ticket must be finished, and not failed ----------------------------------
  case "$status" in
    done) ;;
    failed)
      die "guild: $task is 'failed' — nothing is ever committed for a failed task (design 8.3, 8.6).

Its partial edits are discarded instead, so one bad task cannot contaminate the next:

  guild git revert-task $task"
      ;;
    blocked)
      die "guild: $task is 'blocked' — no guild member could take the bounty, so there is
nothing of it to commit. Nothing was written."
      ;;
    *)
      die "guild: $task is '$status', not 'done' — refusing to commit unfinished work.

A commit per COMPLETED task is what makes a bad overnight run revertible task by task
(design 8.6); committing one mid-flight puts a half-written change in the log under a
ticket that is still moving.

  guild move $task done      when it really is finished"
      ;;
  esac

  # ---- the branch must be this requirement's shift branch ---------------------------
  branch="$(_gs_branch_name "$req")"
  _gs_require_shift_branch "$branch" "$req" "commit"

  _gs_stamp_valid ||
    die "guild: this shift's baseline is missing or stale — refusing to commit.

Nothing was written. 'guild git branch-for $req' records the commit the tree was last clean
at, and every later commit checks that record before staging anything. Without it there is
no way to tell YOUR uncommitted work from the shift's, and 'git add' does not ask.

  guild git branch-for $req      establish the baseline (it refuses on a dirty tree)
  guild git shift-status         what the guild believes about this tree"

  # ---- the sibling guard -------------------------------------------------------------
  if [ -n "$sib" ] && [ "$npaths" = 0 ] && [ "$want_all" = 0 ]; then
    die "guild: other tasks of $req are finished but uncommitted, so the working tree may hold
more than $task's work — refusing to guess.

  ${sib% }

Nothing was written. A commit per task is only worth making if its diff IS that task
(design 8.6), and 'git add' cannot tell one agent's edits from another's. Say which:

  guild git commit-task $task --path src/auth --path src/session
      stage exactly these paths — the plan slice's disjoint-file assertion, applied
  guild git commit-task $task --all
      stage everything, accepting that this commit may carry a sibling's work
      (recorded as such in the event and in the commit message)"
  fi

  # ---- the board must not already be staged ------------------------------------------
  #
  # Every operation in this file EXCLUDES the guild directory, but `git commit` commits the
  # INDEX, not this file's pathspec — so a `.guild/journal.ndjson` that somebody staged by
  # hand before the shift started would ride into a task commit that is supposed to be code
  # and nothing else. Unstaging it is not this command's call (somebody staged it on
  # purpose), so this is a refusal.
  if [ -n "${GS_GUILD_REL:-}" ] &&
    [ -n "$({ _gs_git diff --cached --name-only -- "$GS_GUILD_REL" 2>/dev/null || true; })" ]; then
    die "guild: the guild's own directory ($GS_GUILD_REL) has staged changes — refusing to commit.

Nothing was written. A task commit is code: the board's journal and export are the guild's
bookkeeping and belong in a commit you make deliberately. 'git commit' commits the whole
index, so this one would carry them under $task's trailer.

  git -C $GS_ROOT commit -- $GS_GUILD_REL      commit the board on its own, first
  git -C $GS_ROOT restore --staged $GS_GUILD_REL   or unstage it"
  fi

  # ---- what would be staged ------------------------------------------------------------
  mode="paths"
  if [ "$npaths" = 0 ]; then
    mode="tree"
    [ "$want_all" = 0 ] || mode="tree-all"
  fi

  # --dry-run RETURNS BEFORE STAGING, and that is a correctness point rather than a
  # nicety: `git add` writes the index, so a dry run that staged in order to count would
  # leave the tree staged behind it — and the next `git commit` anyone ran, by hand or by
  # shift, would pick that up. The report is read out of `git status` over the same
  # argument list a real run would stage.
  if [ "$dry" = 1 ]; then
    if [ "$npaths" -gt 0 ]; then
      line="$({ _gs_paths_git status --porcelain --untracked-files=all 2>/dev/null || true; })"
    else
      line="$({ _gs_scoped status --porcelain --untracked-files=all 2>/dev/null || true; })"
    fi
    if [ -z "$line" ]; then
      printf '%s would-record nothing-to-commit (%s)\n' "$task" "$mode"
    else
      printf '%s would-commit %s\n' "$task" "$(printf '%s\n' "$line" | LC_ALL=C wc -l | LC_ALL=C tr -d ' ')"
      printf '%s\n' "$line" | LC_ALL=C sed 's/^/  /'
    fi
    return 0
  fi

  # ---- stage -------------------------------------------------------------------------
  if [ "$npaths" -gt 0 ]; then
    _gs_stage_paths
  else
    _gs_scoped add -A >/dev/null ||
      die "guild: 'git add' failed — nothing was committed."
  fi

  if _gs_git diff --cached --quiet -- . 2>/dev/null; then
    # Nothing staged. Not an error: a `test-plan` or `review` node completes without
    # writing code, and a shift must not stall on it. Recorded so the sibling guard above
    # does not read this task as work still waiting to be committed.
    _gs_write_event "$task" 'nothing-to-commit' \
      "json_object('requirement', $(sql_text "$req" 'the requirement id'),
                   'branch', $(sql_text "$branch" 'the branch name'),
                   'staged', $(sql_str "$mode"))" ""
    printf '%s nothing-to-commit 0\n' "$task"
    return 0
  fi

  files="$(_gs_staged_count)"

  # ---- commit -------------------------------------------------------------------------
  [ -n "$type" ] || type="$(_gs_commit_type "$node")"
  [ -n "$subject" ] || subject="$title"
  subject="$(_gs_subject "$subject")"
  [ -n "$subject" ] || subject="$task"

  msg="$(_render_tmp gitsafe-msg)"
  {
    if [ -n "$scope" ]; then
      printf '%s(%s): %s\n' "$type" "$scope" "$subject"
    else
      printf '%s: %s\n' "$type" "$subject"
    fi
    printf '\n'
    [ -z "$reqtitle" ] || printf '%s\n\n' "$reqtitle"
    if [ "$mode" = "tree-all" ] && [ -n "$sib" ]; then
      printf 'Staged with --all while %s\nwere finished and uncommitted; this commit may carry their work too.\n\n' "${sib% }"
    fi
    printf 'Guild-Task: %s\n' "$task"
    printf 'Guild-Requirement: %s\n' "$req"
    [ "$node" = "-" ] || [ -z "$node" ] || printf 'Guild-Node: %s\n' "$node"
    [ "$group" = "-" ] || [ -z "$group" ] || printf 'Guild-Group: %s\n' "$group"
    printf 'Guild-Actor: %s\n' "$(_render_flat_arg "$(_art_actor)")"
  } >"$msg"

  if ! _gs_git commit -F "$msg" >/dev/null 2>&1; then
    rm -f "$msg"
    die "guild: 'git commit' failed for $task — NOTHING WAS RECORDED, and the changes are
still staged in the working tree.

A repository hook may have rejected it (hooks are deliberately not bypassed here). Run it
yourself to see git's own diagnosis:

  git -C $GS_ROOT commit"
  fi
  rm -f "$msg"

  sha="$(_gs_git rev-parse HEAD 2>/dev/null || true)"
  [ -n "$sha" ] ||
    die "guild: the commit for $task landed but its sha could not be read — nothing was recorded.
Reconcile by hand before running another shift: 'git -C $GS_ROOT log -1'."

  # ---- record: the event, and the advanced baseline ----------------------------------
  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  markers="$(_render_tmp gitsafe-commit-w)"
  sql="BEGIN;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
VALUES ($nowlit, $actorlit, 'committed', 'task', $(sql_str "$task"),
        json_object('requirement', $(sql_text "$req" 'the requirement id'),
                    'branch', $(sql_text "$branch" 'the branch name'),
                    'commit', $(sql_text "$sha" 'the commit sha'),
                    'files', ${files:-0},
                    'staged', $(sql_str "$mode")));
$(_gs_stamp_head_sql "$sha")
COMMIT;
"
  _gs_run_sql "$sql" "$markers" "the commit $sha landed but could not be recorded for $task"
  _gs_journal_markers "$markers"
  rm -f "$markers"

  printf '%s %s %s\n' "$task" "$sha" "$files"
}

# _gs_task_read_sql <task> — the ONE read behind `commit-task` and `revert-task`.
#
# Free text is flattened by `_render_flat` and placed LAST on its own marker line, so a
# title containing a pipe cannot fabricate a field: the parser reads two fields and takes
# the remainder whole. Structural columns (`node_key`, `parallel_group`) go through
# `_graph_field`, which is `_render_col` plus a pipe replacement — they sit BETWEEN other
# fields, so they must not contain the separator at all.
_gs_task_read_sql() {
  local t="${1-}" lit
  lit="$(sql_str "$t")"
  printf "SELECT 'MISS|1' WHERE NOT EXISTS (SELECT 1 FROM task WHERE id = %s);
SELECT 'T|' || t.id || '|' || t.status || '|' || t.requirement_id || '|'
       || COALESCE(%s, '-') || '|' || COALESCE(%s, '-')
  FROM task t WHERE t.id = %s;
SELECT 'TT|' || %s FROM task t WHERE t.id = %s;
SELECT 'RT|' || %s FROM requirement r JOIN task t ON t.requirement_id = r.id WHERE t.id = %s;
SELECT 'DONE|' || e.verb FROM event e
 WHERE e.subject_type = 'task' AND e.subject_id = %s
   AND e.verb IN ('committed', 'nothing-to-commit') LIMIT 1;
SELECT 'SIB|' || t2.id FROM task t2
 WHERE t2.requirement_id = (SELECT requirement_id FROM task WHERE id = %s)
   AND t2.id <> %s
   AND t2.status IN ('in-progress', 'done')
   AND NOT EXISTS (SELECT 1 FROM event e2
                    WHERE e2.subject_type = 'task' AND e2.subject_id = t2.id
                      AND e2.verb IN ('committed', 'nothing-to-commit', 'reverted'))
 ORDER BY t2.id LIMIT 6;
%s
" \
    "$lit" \
    "$(_graph_field 't.node_key')" "$(_graph_field 't.parallel_group')" "$lit" \
    "$(_render_flat 't.title')" "$lit" \
    "$(_render_flat 'r.title')" "$lit" \
    "$lit" \
    "$lit" "$lit" \
    "$(_gs_stamp_select)"
}

# _gs_require_shift_branch <branch> <req> <verb> — die unless HEAD is on <branch>.
#
# INVARIANT 1 AND INVARIANT 2, in one place. The protected-branch case is called out
# separately for the reason the header gives: "you are on main" is the sentence that stops
# somebody, and it is worth two extra lines of code to be able to say it.
_gs_require_shift_branch() {
  local branch="${1-}" req="${2-}" verb="${3-}"
  if [ -z "${GS_BRANCH:-}" ]; then
    die "guild: HEAD is detached — refusing to $verb.

Nothing was written. A shift's work belongs on '$branch' and nowhere else (design 8.6).

  guild git branch-for $req"
  fi
  [ "$GS_BRANCH" != "$branch" ] || return 0

  if _gs_protected "$GS_BRANCH"; then
    die "guild: HEAD IS ON '$GS_BRANCH' — THIS REPOSITORY'S DEFAULT (OR A PROTECTED) BRANCH.

Refusing to $verb anything, and nothing was written. A shift never commits to the branch
you publish from, and never pushes: publishing is a guild-master action, made while
looking at the diff (design 8.2, 8.6). $req's work belongs on '$branch'.

  guild git branch-for $req      create it and switch to it"
  fi

  die "guild: HEAD is on '$(_render_flat_arg "$GS_BRANCH")', not on '$branch' — refusing to $verb.

Nothing was written. $req's work belongs on its own branch so a bad overnight run is
revertible in one move (design 8.6).

  guild git branch-for $req"
}

# ---- --path handling ---------------------------------------------------------------
#
# EIGHT SLOTS, NOT AN ARRAY, and that is bash 3.2 again: `"${a[@]}"` on an empty array is an
# unbound-variable error under `set -u`, and this list is legitimately empty most of the
# time. Eight is not a limit anyone will reach honestly — a plan slice's disjoint-file
# assertion is a handful of directories — and the refusal past it says so.

# _gs_paths_reset — clear the slots.
_gs_paths_reset() {
  GS_NPATHS=0
  GS_P1=""
  GS_P2=""
  GS_P3=""
  GS_P4=""
  GS_P5=""
  GS_P6=""
  GS_P7=""
  GS_P8=""
}

# _gs_add_path <path> — validate and store one --path value.
#
# The validation is about SCOPE, not about characters: a path must stay inside the
# repository and must not be a pathspec-magic string. `..` is refused outright rather than
# normalized, because normalizing it correctly requires resolving symlinks and getting that
# subtly wrong means staging something outside the tree.
_gs_add_path() {
  local p="${1-}"
  [ -n "$p" ] || die "guild: --path needs a value (a file or directory inside the repository)"
  case "$p" in
    :*)
      die "guild: --path does not take a git pathspec ('$(_render_flat_arg "$p")').

Pass a plain path. The guild directory is excluded from staging automatically."
      ;;
    /*)
      die "guild: --path must be relative to the repository root (got '$(_render_flat_arg "$p")')."
      ;;
    .. | ../* | */../* | */..)
      die "guild: --path may not leave the repository ('$(_render_flat_arg "$p")')."
      ;;
  esac
  GS_NPATHS="${GS_NPATHS:-0}"
  GS_NPATHS=$((GS_NPATHS + 1))
  case "$GS_NPATHS" in
    1) GS_P1="$p" ;;
    2) GS_P2="$p" ;;
    3) GS_P3="$p" ;;
    4) GS_P4="$p" ;;
    5) GS_P5="$p" ;;
    6) GS_P6="$p" ;;
    7) GS_P7="$p" ;;
    8) GS_P8="$p" ;;
    *)
      die "guild: more than eight --path values.

That is more than a disjoint-file assertion usually needs; if a task really touches this
much of the tree, commit it with --all and say so in the record."
      ;;
  esac
}

# _gs_paths_git <git args...> — run one git command over the --path slots, with the guild
# directory still excluded.
#
# `set --` REBUILDS THE ARGUMENT LIST, which is how a bash-3.2 function takes a variable
# number of leading arguments AND a variable number of trailing ones without an array. One
# invocation, not one per path: one index lock and one atomic view of the tree.
#
# Two callers, and that is the point of it being a function rather than inline `git add`:
# `--dry-run` must report exactly what a real run would stage, and the only way to be sure
# of that is for both to build the same argument list.
_gs_paths_git() {
  local n="${GS_NPATHS:-0}"
  set -- "$@" --
  [ "$n" -lt 1 ] || set -- "$@" "$GS_P1"
  [ "$n" -lt 2 ] || set -- "$@" "$GS_P2"
  [ "$n" -lt 3 ] || set -- "$@" "$GS_P3"
  [ "$n" -lt 4 ] || set -- "$@" "$GS_P4"
  [ "$n" -lt 5 ] || set -- "$@" "$GS_P5"
  [ "$n" -lt 6 ] || set -- "$@" "$GS_P6"
  [ "$n" -lt 7 ] || set -- "$@" "$GS_P7"
  [ "$n" -lt 8 ] || set -- "$@" "$GS_P8"
  [ -z "${GS_EXCL:-}" ] || set -- "$@" "$GS_EXCL"
  _gs_git "$@"
}

# _gs_stage_paths — stage exactly the --path slots.
#
# A path that matches nothing makes git fail, and that failure is PASSED ON rather than
# swallowed: a `--path` naming a file the agent never wrote almost always means the agent
# wrote somewhere else, and a commit made anyway would be missing the work it claims to
# carry.
_gs_stage_paths() {
  _gs_paths_git add -A >/dev/null ||
    die "guild: 'git add' failed for the paths given — nothing was committed.

A --path that matches nothing is an error on purpose: it usually means the work landed
somewhere else, and committing anyway would produce a commit missing the very change its
Guild-Task trailer claims."
}

# _gs_staged_count — how many paths are staged.
#
# Line-counted WITHOUT `-z`, which is the correct way round here: without `-z` git QUOTES a
# path containing a control character (`core.quotePath`), so a filename with a newline in it
# still occupies exactly one line. With `-z` the count would have to come from counting NUL
# bytes, and `tr -dc '\000'` is one of the few places BSD and GNU tr genuinely differ.
_gs_staged_count() {
  local n
  n="$({ _gs_git diff --cached --name-only -- . 2>/dev/null || true; } |
    LC_ALL=C wc -l | LC_ALL=C tr -d ' ')"
  printf '%s' "${n:-0}"
}

# _gs_write_event <subject-id> <verb> <payload-sql> <extra-sql> — one event, one db_exec.
#
# The payload arrives as a composed `json_object(...)` expression, already escaped by the
# caller through sql_text; this function never touches free text itself.
_gs_write_event() {
  local subject="${1-}" verb="${2-}" payload="${3-}" extra="${4-}"
  local now nowlit actorlit markers sql
  now="$(db_now)"
  nowlit="$(sql_str "$now")"
  actorlit="$(sql_text "$(_art_actor)" "\$GUILD_ACTOR")"
  markers="$(_render_tmp gitsafe-event)"
  sql="BEGIN;
INSERT INTO event (ts, actor, verb, subject_type, subject_id, payload)
VALUES ($nowlit, $actorlit, $(sql_str "$verb"), 'task', $(sql_str "$subject"),
        $payload);
${extra}COMMIT;
"
  _gs_run_sql "$sql" "$markers" "could not record '$verb' for $subject"
  _gs_journal_markers "$markers"
  rm -f "$markers"
}

# ============================ guild git revert-task ===================================

# _gs_revert_task <TASK-NNN> [--dry-run] — discard a failed task's partial edits.
#
# Prints "<TASK-NNN> reverted <tracked> <untracked> <quarantine>".
#
# THE ONLY DESTRUCTIVE COMMAND IN THE GUILD, and everything about its shape follows from
# that:
#
#   * It runs ONLY for a `failed` task. A `done` task's edits are somebody's finished work;
#     a `todo` task has not started. `failed` is the one state where the design says the
#     edits must not survive (§8.3, §8.6).
#   * It runs ONLY with a valid shift stamp, so the tree it is about to clear is provably
#     the shift's own. Without one it refuses and touches nothing.
#   * It runs ONLY on `guild/REQ-NNN` for that task's requirement.
#   * It refuses if the task has already been committed — the edits are in history, and
#     clearing the tree would destroy something ELSE while leaving the failure in the log.
#   * NOTHING IT DOES IS UNRECOVERABLE. Tracked modifications are written to a patch file
#     before being restored; untracked files are MOVED, not deleted. That is why `git clean`
#     is not on `_gs_git`'s allowlist: this command has no use for the one git verb that
#     destroys files git has never recorded.
#
# The quarantine lives at `.guild/backup-revert-<TASK>-<ts>/`, matching the `backup-*/`
# pattern `guild init` already writes into `.guild/.gitignore` — so it neither dirties the
# tree it just cleaned nor gets committed by the next person to run `git add`.
_gs_revert_task() {
  local task="" dry=0
  local markers sql line status req branch quarantine rel
  local counts tracked untracked moved=0 f rec

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      -*) die "guild: unknown option '$1' for 'git revert-task' (try 'guild git revert-task TASK-NNN')" ;;
      *)
        [ -z "$task" ] ||
          die "guild: 'git revert-task' takes one task id (got '$task' and '$(_render_flat_arg "$1")')"
        task="$1"
        ;;
    esac
    shift
  done

  _gs_check_task "$task"
  db_require_init
  journal_preflight
  _gs_setup
  _gs_require_switch_restore

  markers="$(_render_tmp gitsafe-revert)"
  sql="$(_gs_task_read_sql "$task")"
  _gs_run_sql "$sql" "$markers" "could not read $task before reverting"

  if LC_ALL=C grep -q '^MISS|' "$markers"; then
    rm -f "$markers"
    die "guild: there is no task '$task'."
  fi
  line="$(LC_ALL=C awk -F'|' '$1 == "T" { print; exit }' "$markers")"
  status="$(printf '%s' "$line" | cut -d'|' -f3)"
  req="$(printf '%s' "$line" | cut -d'|' -f4)"
  _gs_stamp_load "$markers"
  if LC_ALL=C grep -q '^DONE|committed' "$markers"; then
    rm -f "$markers"
    die "guild: $task has already been committed — refusing to revert the working tree for it.

Nothing was written. Its edits are in history, so clearing the tree now would destroy
whatever has been written SINCE, and the commit would still be there. Undo a landed commit
yourself, deliberately:

  git -C $GS_ROOT revert <sha>      the non-destructive way
  guild git shift-status            which commit belongs to $task"
  fi
  rm -f "$markers"

  [ "$status" = "failed" ] ||
    die "guild: $task is '$status', not 'failed' — refusing to discard its edits.

Nothing was written. This command exists for one case: a task that failed, whose partial
edits must not contaminate the next bounty (design 8.3). Anything else in the working tree
is either finished work or work in flight, and throwing either away is not a machine's
decision.

  guild move $task failed     if that is what happened"

  branch="$(_gs_branch_name "$req")"
  _gs_require_shift_branch "$branch" "$req" "revert"

  _gs_stamp_valid ||
    die "guild: this shift's baseline is missing or stale — refusing to touch the working tree.

Nothing was written. Without the baseline that 'guild git branch-for $req' records, there
is no evidence the uncommitted changes here were made by the shift, and this command
DELETES uncommitted changes. It will not do that on somebody else's work.

  guild git shift-status     what the guild believes about this tree"

  # ---- what is there to revert? ------------------------------------------------------
  markers="$(_render_tmp gitsafe-revert-st)"
  _gs_status_z "$markers"
  counts="$(_gs_status_counts "$markers")"
  tracked="${counts%% *}"
  untracked="${counts##* }"

  if [ "$tracked" = 0 ] && [ "$untracked" = 0 ]; then
    rm -f "$markers"
    printf '%s clean 0 0 -\n' "$task"
    return 0
  fi

  if [ "$dry" = 1 ]; then
    printf '%s would-revert %s %s -\n' "$task" "$tracked" "$untracked"
    while IFS= read -r -d '' rec; do
      [ -n "$rec" ] || continue
      printf '  %s\n' "$rec"
    done <"$markers"
    rm -f "$markers"
    return 0
  fi

  # ---- quarantine, then restore -------------------------------------------------------
  guild_root >/dev/null
  rel="backup-revert-$task-$(date -u +%Y%m%dT%H%M%SZ)"
  quarantine="$GUILD_DIR/$rel"
  mkdir -p "$quarantine" ||
    die "guild: could not create the quarantine directory $quarantine — nothing was reverted.

This command never discards anything it has not first saved a copy of."

  # The patch is written BEFORE anything is restored, and a failure to write it aborts the
  # whole command: an unrecoverable revert is not an outcome this file offers.
  if ! _gs_scoped diff HEAD >"$quarantine/tracked.patch" 2>/dev/null; then
    rm -rf "$quarantine"
    die "guild: could not capture the current diff — nothing was reverted."
  fi

  # Untracked files are MOVED into the quarantine, preserving their paths, before the
  # tracked restore runs. `-z` throughout: a filename is free text and NUL is the only
  # separator it cannot contain.
  while IFS= read -r -d '' f; do
    case "$f" in
      '??'*) ;;
      *) continue ;;
    esac
    f="${f#?? }"
    [ -n "$f" ] || continue
    mkdir -p "$quarantine/untracked/$(dirname "$f")" 2>/dev/null || continue
    if mv "$GS_ROOT/$f" "$quarantine/untracked/$f" 2>/dev/null; then
      moved=$((moved + 1))
    fi
  done <"$markers"
  rm -f "$markers"

  if ! _gs_scoped restore --source=HEAD --staged --worktree >/dev/null 2>&1; then
    die "guild: 'git restore' failed — the tree is in an UNKNOWN state and nothing was recorded.

Your changes are saved: $quarantine/tracked.patch holds the diff, and
$quarantine/untracked/ holds every untracked file that was moved. Reconcile by hand before
running another shift."
  fi

  # Verify rather than assume. A revert that half-worked and reported success would hand
  # the next bounty a contaminated tree, which is the exact failure this command exists to
  # prevent.
  if _gs_dirty; then
    die "guild: the working tree is still dirty after reverting $task — stopping the shift.

Nothing was recorded. A copy of everything is in $quarantine. Inspect 'git status' before
dispatching anything else: continuing would build the next task on top of a tree this
command was supposed to have cleared."
  fi

  _gs_write_event "$task" 'reverted' \
    "json_object('requirement', $(sql_text "$req" 'the requirement id'),
                 'branch', $(sql_text "$branch" 'the branch name'),
                 'tracked', $tracked,
                 'untracked', $moved,
                 'quarantine', $(sql_text "$rel" 'the quarantine directory'))" ""

  printf '%s reverted %s %s %s\n' "$task" "$tracked" "$moved" "$quarantine"
}

# ============================ guild git shift-status ==================================

# _gs_shift_status — what a shift has done to this tree. Reads only; writes nothing.
#
# Line-oriented, one fact per line, `<key> <value>` with any free text LAST — the same
# discipline `guild list` and `guild gates` follow, for the same reason: this is a surface
# an orchestrator filters with awk, and a commit subject is somebody's prose.
#
# There is deliberately no `--json`. The CLI has exactly one JSON escaper on the output
# side — `json_object()`, in the engine (§2.2.2) — and half of what this command reports
# comes from git, not from SQL. A JSON emitter here would be a SECOND escaper standing
# between a commit subject and a document an orchestrator parses, which is precisely the
# arrangement §2.2.2 exists to forbid. The fields below are fixed-position and blank-free
# until the last one, which is enough.
_gs_shift_status() {
  local markers sql tmp base range n counts tracked untracked
  local head protected

  db_require_init
  _gs_setup

  # The fallback is a timestamp NOTHING can be greater than or equal to, not `''`: with no
  # stamp there is no shift to count, and `''` would silently report the board's lifetime
  # totals as if they belonged to a shift that never started.
  markers="$(_render_tmp gitsafe-status-r)"
  sql="$(_gs_stamp_select)
SELECT 'EV|' || e.verb || '|' || COUNT(*) FROM event e
 WHERE e.verb IN ('branched', 'committed', 'nothing-to-commit', 'reverted')
   AND e.ts >= COALESCE((SELECT value FROM guild_state WHERE key = 'git-shift:started'), '9999-12-31T23:59:59Z')
 GROUP BY e.verb ORDER BY e.verb;
"
  _gs_run_sql "$sql" "$markers" "could not read the shift record"
  _gs_stamp_load "$markers"

  head="$(_gs_git rev-parse HEAD 2>/dev/null || true)"
  protected=no
  ! _gs_protected "${GS_BRANCH:-}" || protected=yes

  printf 'repo %s\n' "$GS_ROOT"
  printf 'branch %s\n' "${GS_BRANCH:-(detached)}"
  printf 'default %s\n' "${GS_DEFAULT:-(undetermined)}"
  printf 'protected %s\n' "$protected"
  printf 'head %s\n' "${head:--}"

  if _gs_stamp_valid; then
    printf 'shift %s\n' "${GS_ST_REQ:--}"
    printf 'started %s\n' "${GS_ST_STARTED:--}"
    printf 'base %s\n' "${GS_ST_BASE:--}"
    printf 'baseline %s\n' "${GS_ST_HEAD:--}"
    base="$GS_ST_BASE"
  else
    printf 'shift none\n'
    if [ -n "${GS_ST_BRANCH:-}" ]; then
      printf 'stamp stale %s\n' "$GS_ST_BRANCH"
    else
      printf 'stamp none\n'
    fi
    base=""
    if [ -n "${GS_DEFAULT:-}" ] && _gs_branch_exists "${GS_DEFAULT:-}"; then
      base="$(_gs_git merge-base "$GS_DEFAULT" HEAD 2>/dev/null || true)"
    fi
    printf 'base %s\n' "${base:--}"
  fi

  # ---- the tree ----------------------------------------------------------------------
  tmp="$(_render_tmp gitsafe-status-t)"
  _gs_status_z "$tmp"
  counts="$(_gs_status_counts "$tmp")"
  rm -f "$tmp"
  tracked="${counts%% *}"
  untracked="${counts##* }"
  if [ "$tracked" = 0 ] && [ "$untracked" = 0 ]; then
    printf 'tree clean\n'
  else
    printf 'tree dirty\n'
  fi
  printf 'modified %s\n' "$tracked"
  printf 'untracked %s\n' "$untracked"

  # ---- what the board recorded --------------------------------------------------------
  LC_ALL=C awk -F'|' '$1 == "EV" { printf "events %s %s\n", $2, $3 }' "$markers"
  rm -f "$markers"

  # ---- the commits --------------------------------------------------------------------
  if [ -n "$base" ] && _gs_git_q rev-parse --verify --quiet "${base}^{commit}"; then
    range="$base..HEAD"
    n="$(_gs_git rev-list --count "$range" 2>/dev/null || printf '0')"
    printf 'commits %s\n' "$n"
    if [ "$n" != 0 ]; then
      _gs_commit_lines "$range"
    fi
  else
    printf 'commits -\n'
  fi
}

# _gs_commit_lines <range> — "commit <sha> <TASK-NNN|-> <subject>", newest first, capped.
#
# ONE awk pass over ONE `git log`, using ASCII record (0x1e) and unit (0x1f) separators, so
# the whole log is parsed without a loop that calls git per commit. The `Guild-Task:`
# trailer is read out of the raw body rather than through `%(trailers:key=…,valueonly)`,
# which needs git 2.24 and would make the output shape depend on the git version.
#
# The subject is flattened inside awk before printing: `%s` is git's subject line, and a
# message whose first paragraph wraps can carry a newline into it. It is printed LAST, so
# even then it cannot forge a field — but it can forge a LINE, and this surface is lines.
_gs_commit_lines() {
  { _gs_git log --format='%H%x1f%s%x1f%B%x1e' "${1-}" 2>/dev/null || true; } |
    LC_ALL=C awk -v RS=$'\036' -v FS=$'\037' -v cap=20 '
      {
        rec = $0
        sub(/^[\n\r]+/, "", rec)
        if (rec == "") next
        n = split(rec, f, FS)
        if (n < 2) next
        sha = f[1]
        subj = f[2]
        body = (n >= 3) ? f[3] : ""
        gsub(/[\r\n]/, " ", subj)
        task = "-"
        m = split(body, lines, "\n")
        for (i = 1; i <= m; i++) {
          if (substr(lines[i], 1, 12) == "Guild-Task: ") {
            task = substr(lines[i], 13)
            gsub(/[ \t\r]/, "", task)
          }
        }
        shown++
        if (shown > cap) { extra++; next }
        printf "commit %s %s %s\n", sha, (task == "" ? "-" : task), subj
      }
      END { if (extra > 0) printf "commit ... %d more\n", extra }
    '
}

# ============================ dispatch ================================================

# cmd_git <subcommand> [args] — the one entry point scripts/guild dispatches to.
#
# `push`, `pull`, `merge` and the rest get a NAMED refusal rather than "unknown
# subcommand", because somebody typing `guild git push` has a reason and deserves to be
# told the actual policy instead of being left to think they mistyped.
cmd_git() {
  local sub="${1-}"
  [ $# -eq 0 ] || shift

  _gs_paths_reset
  _gs_stamp_reset

  case "$sub" in
    branch-for) _gs_branch_for "$@" ;;
    commit-task) _gs_commit_task "$@" ;;
    revert-task) _gs_revert_task "$@" ;;
    shift-status) _gs_shift_status "$@" ;;
    "" | -h | --help | help) _gs_help ;;
    push | pull | fetch | remote | tag)
      die "guild: 'guild git $sub' does not exist, and will not.

A shift never publishes. Branching, committing to its own branch and reverting its own
failures is the whole of what unattended git access is allowed to be (design 8.2, 8.6) —
what leaves this machine is a guild-master decision, made while looking at the diff.

  guild git shift-status     what the shift has done, before you push it yourself"
      ;;
    merge | rebase | reset | cherry-pick | clean | stash | amend)
      die "guild: 'guild git $sub' does not exist, and will not.

Rewriting history and clearing the tree wholesale are not things an unattended process
should be able to do. The two tree operations the guild has are narrow on purpose:

  guild git commit-task TASK-NNN     commit one completed task
  guild git revert-task TASK-NNN     discard one FAILED task's partial edits, into a
                                     recoverable quarantine under .guild/"
      ;;
    *)
      die "guild: unknown 'guild git' subcommand '$(_render_flat_arg "$sub")'.

  guild git branch-for REQ-NNN     ensure and switch to guild/REQ-NNN
  guild git commit-task TASK-NNN   commit that task's work
  guild git revert-task TASK-NNN   discard a failed task's partial edits
  guild git shift-status           what this shift has done to the tree"
      ;;
  esac
}

# _gs_help — the subcommand list, in `guild help`'s voice.
_gs_help() {
  cat <<'EOF'
guild git — the only git a shift may do (design 8.6).

  guild git branch-for <REQ-NNN> [--from REF]
        Ensure `guild/REQ-NNN` exists and switch to it, recording the commit the tree was
        clean at as this shift's baseline. REFUSES on a working tree the shift did not
        create: `git switch` carries uncommitted changes with it, and a guild master's
        work-in-progress must never be dragged onto a shift branch. The guild's own
        directory is ignored by that check — the board is expected to be dirty.

  guild git commit-task <TASK-NNN> [--path P]... [--all] [--type T] [--scope S]
                                   [--subject S] [--dry-run]
        Commit one COMPLETED task, as `<type>: <subject>` with `Guild-Task: TASK-NNN` in
        the trailer, so a bad overnight run is bisectable and revertible task by task.
        Refuses a task that is not `done`, a task already committed, a branch that is not
        this requirement's, and a tree whose baseline the guild cannot vouch for. When
        other finished tasks of the same requirement are still uncommitted the tree may
        hold their work too, and it refuses rather than mis-attribute the diff: say
        `--path` (the plan slice's disjoint-file assertion) or `--all` (recorded as such).
        A task that wrote no code records `nothing-to-commit` and moves on.

  guild git revert-task <TASK-NNN> [--dry-run]
        Discard a FAILED task's partial edits so it cannot contaminate the next bounty.
        Nothing is deleted: the diff is written to `.guild/backup-revert-<TASK>-<ts>/`
        and untracked files are MOVED there. Runs only for a `failed`, uncommitted task,
        on its own shift branch, with a valid baseline.

  guild git shift-status
        Repository, branch, default branch, baseline, working-tree state, the events the
        board recorded for this shift, and the commits it has made with the task each one
        belongs to. Reads only.

NEVER: push, pull, fetch, merge, rebase, reset, cherry-pick, clean, amend, or any commit
to the default branch. Publishing is a guild-master action, made while looking at the
diff — not something a process does at 3am.
EOF
}
