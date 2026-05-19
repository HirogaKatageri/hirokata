---
name: query-changes
description: >
  Internal skill used by the session-tracker logger agent to query git for
  committed and uncommitted changes in the past 28 hours. Not user-invocable.
version: 1.0.0
user-invocable: false
---

# Query Session Changes

Gather all git activity for the current session window (last 28 hours).

## Commands

Run all of these in parallel:

```bash
# Commits in the last 28 hours with file stats
git log --stat --since="28 hours ago" --format="commit %h %s" 2>/dev/null || echo "no-git"

# Staged (index) changes not yet committed
git diff --cached --stat 2>/dev/null

# Unstaged working tree changes
git status --short 2>/dev/null
```

## Output Contract

Return a structured block with four fields. Use `none` for any field with no data.

```
COMMITS:
{one line per commit — hash + subject, e.g. "abc1234 feat: add logger agent"}

FILES_CHANGED:
{aggregated list of files touched by commits, from the --stat output}

STAGED:
{files staged but not yet committed — short status format}

UNSTAGED:
{files with working tree changes — short status format}
```

## Edge Cases

- **Not a git repo**: all fields are `none`; do not error, continue to summary step
- **No activity in 28 hours**: COMMITS and FILES_CHANGED are `none`; still capture STAGED and UNSTAGED
- **Detached HEAD**: run commands as normal; they will still return valid output
