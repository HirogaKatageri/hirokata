---
name: save-log
description: >
  Internal skill used by the session-tracker logger agent to append a session
  entry to .logs/YYYY-MM-DD-log.md, creating the file and directory if needed.
  Not user-invocable.
version: 1.0.0
user-invocable: false
---

# Save Session Log

Persist a session entry to the daily log file.

## File Path

Resolve the path from the current date:

```
.logs/{YYYY-MM-DD}-log.md
```

Example: `.logs/2026-05-19-log.md`

## Step 1: Ensure Directory

```bash
mkdir -p .logs
```

## Step 2: Check Whether Today's File Exists

```bash
test -f .logs/{date}-log.md && echo "exists" || echo "new"
```

## Step 3: Write

**File does not exist** — create it:

```markdown
# Log — {YYYY-MM-DD}

{session entry}
```

**File exists** — read the current content, then write the full updated file with the
new entry appended:

```
{existing content}

---

{session entry}
```

Do this in a single Write call — read first, then write the complete updated content.

## Session Entry Format

```markdown
## Session — {HH:MM}

### Summary
{2–4 sentence narrative synthesized from the git activity — what changed and why,
inferred from commit messages and file names}

### Committed Changes
- {hash} {subject}
- {hash} {subject}
(write "None" if no commits in the window)

### Files Changed
- {filepath} ({change type: added/modified/deleted})
(omit section if no committed file changes)

### Uncommitted Changes
- {status} {filepath}
(omit section entirely if working tree is clean and nothing is staged)
```

## Rules

- **Never overwrite** — always preserve all prior sessions in the file
- **One write call** — read existing content first, then write the complete updated file
- **Omit empty sections** — do not include a heading with no content beneath it
