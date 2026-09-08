#!/usr/bin/env bash
# Collect GitHub activity for the authenticated user within a lookback window.
#
# Usage: collect-github.sh [HOURS]        (default: 24)
#
# Output: a single JSON object on stdout:
#   { "since": ISO8601, "login": str, "merged": [...], "open": [...],
#     "closed_unmerged": [...], "comments": [...], "errors": [...] }
#
# Never fails the caller: if gh is missing or unauthenticated it returns empty
# lists and an entry in "errors" so the handoff can say so out loud.
#
# Requires: gh (authenticated), jq

set -uo pipefail

HOURS="${1:-24}"
SINCE_TS="$(date -u -d "${HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)"
# GitHub search date qualifiers are day-granular, so widen the search by a day
# and post-filter on the exact timestamp below.
SINCE_DAY="$(date -u -d "${HOURS} hours ago - 1 day" +%Y-%m-%d)"

empty_result() {
  jq -n --arg since "$SINCE_TS" --arg err "$1" \
    '{since:$since, login:null, merged:[], open:[], closed_unmerged:[],
      comments:[], errors:[$err]}'
}

command -v gh >/dev/null 2>&1 || {
  empty_result "gh CLI is not installed - no GitHub activity could be collected"
  exit 0
}
command -v jq >/dev/null 2>&1 || {
  echo '{"errors":["jq is not installed"]}'
  exit 0
}
gh auth status >/dev/null 2>&1 || {
  empty_result "gh CLI is not authenticated (run: gh auth login)"
  exit 0
}

LOGIN="$(gh api user --jq .login 2>/dev/null || echo "")"
[ -n "$LOGIN" ] || {
  empty_result "could not resolve the GitHub login for the current token"
  exit 0
}

PR_FIELDS='number,title,repository,url,updatedAt,createdAt,state,isDraft,body,labels,commentsCount'

# ---------------------------------------------------------------------------
# 1. Merged PRs authored by the user
# ---------------------------------------------------------------------------
MERGED="$(gh search prs --author="$LOGIN" --merged --merged-at=">=$SINCE_DAY" \
  --limit 50 --json "$PR_FIELDS" 2>/dev/null || echo '[]')"
[ -n "$MERGED" ] || MERGED='[]'

# The search payload has no merge timestamp or diff size; fetch both so the
# window is exact and the summary can say how big the change was.
ENRICHED='[]'
for row in $(jq -r '.[] | @base64' <<<"$MERGED"); do
  item="$(base64 -d <<<"$row")"
  repo="$(jq -r '.repository.nameWithOwner' <<<"$item")"
  num="$(jq -r '.number' <<<"$item")"
  meta="$(gh api "repos/$repo/pulls/$num" \
    --jq '{mergedAt:.merged_at, baseRef:.base.ref, headRef:.head.ref,
           additions, deletions, changedFiles:.changed_files,
           mergedBy:(.merged_by.login // null)}' 2>/dev/null || echo '{}')"
  files="$(gh api "repos/$repo/pulls/$num/files" --paginate \
    --jq '[.[] | .filename] | .[0:40]' 2>/dev/null || echo '[]')"
  ENRICHED="$(jq -c --argjson a "$item" --argjson b "$meta" --argjson f "$files" \
    '. + [$a + $b + {files:$f}]' <<<"$ENRICHED")"
done
MERGED="$(jq -c --arg since "$SINCE_TS" \
  '[ .[] | select((.mergedAt == null) or (.mergedAt >= $since)) ]' <<<"$ENRICHED")"

# ---------------------------------------------------------------------------
# 2. Open PRs authored by the user and touched in the window
# ---------------------------------------------------------------------------
OPEN="$(gh search prs --author="$LOGIN" --state=open --updated=">=$SINCE_DAY" \
  --limit 50 --json "$PR_FIELDS" 2>/dev/null || echo '[]')"
[ -n "$OPEN" ] || OPEN='[]'
OPEN="$(jq -c --arg since "$SINCE_TS" '[ .[] | select(.updatedAt >= $since) ]' <<<"$OPEN")"

# Attach review state and mergeability, so "this is blocked on someone" shows.
ENRICHED='[]'
for row in $(jq -r '.[] | @base64' <<<"$OPEN"); do
  item="$(base64 -d <<<"$row")"
  repo="$(jq -r '.repository.nameWithOwner' <<<"$item")"
  num="$(jq -r '.number' <<<"$item")"
  meta="$(gh api "repos/$repo/pulls/$num" \
    --jq '{baseRef:.base.ref, headRef:.head.ref, mergeable,
           mergeableState:.mergeable_state, additions, deletions,
           changedFiles:.changed_files,
           requestedReviewers:[.requested_reviewers[]?.login]}' \
    2>/dev/null || echo '{}')"
  reviews="$(gh api "repos/$repo/pulls/$num/reviews" \
    --jq '[.[] | {user:.user.login, state, submittedAt:.submitted_at}]' \
    2>/dev/null || echo '[]')"
  checks="$(gh api "repos/$repo/commits/$(jq -r '.headRef // ""' <<<"$meta")/check-runs" \
    --jq '[.check_runs[]? | {name, conclusion}]' 2>/dev/null || echo '[]')"
  files="$(gh api "repos/$repo/pulls/$num/files" --paginate \
    --jq '[.[] | .filename] | .[0:40]' 2>/dev/null || echo '[]')"
  ENRICHED="$(jq -c --argjson a "$item" --argjson b "$meta" --argjson r "$reviews" \
    --argjson c "$checks" --argjson f "$files" \
    '. + [$a + $b + {reviews:$r, checks:$c, files:$f}]' <<<"$ENRICHED")"
done
OPEN="$ENRICHED"

# ---------------------------------------------------------------------------
# 3. Closed but NOT merged, so abandoned work never silently disappears
# ---------------------------------------------------------------------------
CLOSED="$(gh search prs --author="$LOGIN" --state=closed --updated=">=$SINCE_DAY" \
  --limit 50 --json "$PR_FIELDS" 2>/dev/null || echo '[]')"
[ -n "$CLOSED" ] || CLOSED='[]'
CLOSED="$(jq -c --arg since "$SINCE_TS" \
  '[ .[] | select(.updatedAt >= $since) | select(.state != "merged") ]' <<<"$CLOSED")"

# ---------------------------------------------------------------------------
# 4. Comments the user left in the window
# ---------------------------------------------------------------------------
# Search finds candidate threads; the REST API supplies the bodies and the
# exact timestamps that the day-granular search cannot.
CAND_PRS="$(gh search prs --commenter="$LOGIN" --updated=">=$SINCE_DAY" --limit 50 \
  --json number,title,repository,url,state 2>/dev/null || echo '[]')"
CAND_ISSUES="$(gh search issues --commenter="$LOGIN" --updated=">=$SINCE_DAY" --limit 50 \
  --json number,title,repository,url,state 2>/dev/null || echo '[]')"
[ -n "$CAND_PRS" ] || CAND_PRS='[]'
[ -n "$CAND_ISSUES" ] || CAND_ISSUES='[]'
CANDIDATES="$(jq -c -s 'add | unique_by(.url)' <<<"$CAND_PRS $CAND_ISSUES")"

COMMENTS='[]'
for row in $(jq -r '.[] | @base64' <<<"$CANDIDATES"); do
  item="$(base64 -d <<<"$row")"
  repo="$(jq -r '.repository.nameWithOwner' <<<"$item")"
  num="$(jq -r '.number' <<<"$item")"

  issue_c="$(gh api "repos/$repo/issues/$num/comments" --paginate \
    --jq '[.[] | {kind:"conversation", user:.user.login, createdAt:.created_at,
                  body:.body, url:.html_url}]' 2>/dev/null || echo '[]')"
  review_c="$(gh api "repos/$repo/pulls/$num/comments" --paginate \
    --jq '[.[] | {kind:"code-review", user:.user.login, createdAt:.created_at,
                  body:.body, url:.html_url, path:.path}]' 2>/dev/null || echo '[]')"
  reviews="$(gh api "repos/$repo/pulls/$num/reviews" \
    --jq '[.[] | select((.body // "") != "")
           | {kind:"review-summary", user:.user.login, createdAt:.submitted_at,
              body:.body, url:.html_url, state:.state}]' 2>/dev/null || echo '[]')"

  mine="$(jq -c -s --arg me "$LOGIN" --arg since "$SINCE_TS" \
    '[ add[] | select(.user == $me) | select(.createdAt >= $since) ]' \
    <<<"$issue_c $review_c $reviews")"

  if [ "$(jq 'length' <<<"$mine")" -gt 0 ]; then
    COMMENTS="$(jq -c --arg repo "$repo" --argjson n "$num" \
      --arg title "$(jq -r '.title' <<<"$item")" \
      --arg url "$(jq -r '.url' <<<"$item")" \
      --arg state "$(jq -r '.state' <<<"$item")" \
      --argjson c "$mine" \
      '. + [{repository:$repo, number:$n, title:$title, url:$url,
             state:$state, comments:$c}]' <<<"$COMMENTS")"
  fi
done

jq -n --arg since "$SINCE_TS" --arg login "$LOGIN" \
  --argjson merged "$MERGED" --argjson open "$OPEN" --argjson closed "$CLOSED" \
  --argjson comments "$COMMENTS" \
  '{since:$since, login:$login, merged:$merged, open:$open,
    closed_unmerged:$closed, comments:$comments, errors:[]}'
