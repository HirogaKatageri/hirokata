#!/usr/bin/env bash
# Find local git checkouts with work that is not on the remote yet.
#
# Usage: collect-repos.sh [ROOT] [HOURS] [MAX_DEPTH]
#        ROOT       directory to scan for git checkouts   (default: ~/Projects)
#        HOURS      only report repos touched this recently (default: 24)
#        MAX_DEPTH  how deep to look for .git             (default: 6,
#                   deep enough to reach .claude/worktrees/<name>)
#
# Output: a single JSON object on stdout:
#   { "root": str, "since": ISO8601, "repos": [ { ... } ], "errors": [...] }
#
# For each repo it reports the current branch, uncommitted file changes
# (staged, unstaged, untracked), commits that exist locally but not on the
# upstream branch, and stashes. These are the three ways work hides.
#
# Read-only: runs no command that writes to any repository.

set -uo pipefail

ROOT="${1:-$HOME/Projects}"
HOURS="${2:-24}"
MAX_DEPTH="${3:-6}"
SINCE_TS="$(date -u -d "${HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)"
SINCE_EPOCH="$(date -u -d "${HOURS} hours ago" +%s)"

command -v jq >/dev/null 2>&1 || { echo '{"errors":["jq is not installed"]}'; exit 0; }

if [ ! -d "$ROOT" ]; then
  jq -n --arg root "$ROOT" --arg since "$SINCE_TS" \
    '{root:$root, since:$since, repos:[], errors:["scan root does not exist"]}'
  exit 0
fi

REPOS='[]'

# Worktrees under .claude/worktrees are agent scratch space; they are scanned
# too, but tagged so the handoff can name them for what they are.
while IFS= read -r gitdir; do
  repo="$(dirname "$gitdir")"

  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  [ -n "$branch" ] || continue

  porcelain="$(git -C "$repo" status --porcelain=v1 2>/dev/null || echo "")"
  stashes="$(git -C "$repo" stash list 2>/dev/null | wc -l | tr -d ' ')"

  upstream="$(git -C "$repo" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo "")"
  # Format is "<sha> <iso-date> <subject>" so jq can split it with one regex
  # that keeps any separator characters inside the subject intact.
  if [ -n "$upstream" ]; then
    unpushed="$(git -C "$repo" log --format='%H %cI %s' "$upstream..HEAD" 2>/dev/null || echo "")"
  else
    # No upstream: show commits not reachable from any remote branch at all.
    unpushed="$(git -C "$repo" log --format='%H %cI %s' --not --remotes HEAD 2>/dev/null || echo "")"
  fi

  last_commit="$(git -C "$repo" log -1 --format='%cI' 2>/dev/null || echo "")"
  last_commit_epoch="$(git -C "$repo" log -1 --format='%ct' 2>/dev/null || echo 0)"

  # Most recent modification time among tracked-dirty and untracked files.
  newest_dirty_epoch=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    f="${line:3}"
    f="${f##* -> }"
    f="${f%\"}"
    f="${f#\"}"
    [ -f "$repo/$f" ] || continue
    m="$(stat -c %Y "$repo/$f" 2>/dev/null || echo 0)"
    [ "$m" -gt "$newest_dirty_epoch" ] && newest_dirty_epoch="$m"
  done <<<"$porcelain"

  has_dirty=0
  [ -n "$porcelain" ] && has_dirty=1
  has_unpushed=0
  [ -n "$unpushed" ] && has_unpushed=1

  # Report only repos that are actually carrying something, and only if they
  # were touched inside the window.
  if [ "$has_dirty" -eq 0 ] && [ "$has_unpushed" -eq 0 ] && [ "$stashes" -eq 0 ]; then
    continue
  fi
  if [ "$newest_dirty_epoch" -lt "$SINCE_EPOCH" ] && [ "$last_commit_epoch" -lt "$SINCE_EPOCH" ]; then
    continue
  fi

  # Line-level size of the uncommitted work, so a one-character tweak is not
  # written up like a rewrite.
  diffstat="$(git -C "$repo" diff --shortstat HEAD 2>/dev/null || echo "")"

  changes="$(jq -R -s -c 'split("\n") | map(select(length > 3))
    | map({status: .[0:2], path: .[3:]})' <<<"$porcelain")"
  commits="$(jq -R -s -c 'split("\n") | map(select(length > 0))
    | map(capture("^(?<sha>[0-9a-f]+) (?<committedAt>\\S+) (?<subject>.*)$"))' <<<"$unpushed")"
  origin="$(git -C "$repo" remote get-url origin 2>/dev/null || echo "")"

  is_agent_worktree=false
  case "$repo" in *"/.claude/worktrees/"*) is_agent_worktree=true ;; esac

  REPOS="$(jq -c \
    --arg path "$repo" --arg branch "$branch" --arg origin "$origin" \
    --arg upstream "$upstream" --arg diffstat "$diffstat" \
    --arg lastCommit "$last_commit" --argjson stashes "$stashes" \
    --argjson changes "$changes" --argjson commits "$commits" \
    --argjson agentWorktree "$is_agent_worktree" \
    '. + [{path:$path, branch:$branch, origin:$origin, upstream:$upstream,
           diffstat:$diffstat, lastCommitAt:$lastCommit, stashCount:$stashes,
           uncommitted:$changes, unpushedCommits:$commits,
           isAgentWorktree:$agentWorktree}]' <<<"$REPOS")"
done < <(find "$ROOT" -maxdepth "$MAX_DEPTH" -name .git -print 2>/dev/null)

jq -n --arg root "$ROOT" --arg since "$SINCE_TS" --argjson repos "$REPOS" \
  '{root:$root, since:$since, repos:($repos | sort_by(.path)), errors:[]}'
