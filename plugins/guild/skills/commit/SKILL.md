---
name: commit
description: >
  This skill should be used when the user asks to "commit the guild work",
  "commit recent tasks", "guild commit", "commit done tasks", "make a commit
  from the board", or wants to generate a conventional commit message from
  developer tasks completed since the last commit. Produces a conventional
  commit grouped by requirement, shows a preview, and commits on confirmation.
version: 1.0.0
user-invocable: true
---

# Guild Commit — Conventional Commits from Completed Tasks

Generate a conventional commit message from recently completed developer tasks and commit the staged work. Does not push.

## Steps

### 1. Preconditions

Check that we are in a git repository and that the guild board exists:

1. Run `git rev-parse --is-inside-work-tree`. If it fails, stop with:
   ```
   Not inside a git repository. Guild commit requires git.
   ```
2. Read `.guild/BOARD.md`. If missing, stop with:
   ```
   No guild board found. Nothing to commit from the guild.
   ```

### 2. Gather Changes

Run these in parallel:
- `git status --short` — see what is staged and unstaged
- `git diff --cached --stat` — see staged changes
- `git diff --stat` — see unstaged changes
- `git log -1 --format=%H` — current HEAD commit hash

If there are no staged AND no unstaged changes, stop with:
```
No changes to commit. Working tree is clean.
```

If there are unstaged changes but nothing staged, ask the user:
```
You have unstaged changes but nothing is staged. Stage all tracked changes? (yes / no)
```
- **"yes"** → run `git add -u` (stages modifications and deletions to tracked files only, NEVER `git add .` or `-A`)
- **"no"** → stop with "Stage your changes first, then run /guild:commit again."

### 3. Identify Relevant Completed Tasks

Read BOARD.md's Done section and find developer and test-writer tasks completed since the last commit. Approach:

1. Get the date of the last commit: `git log -1 --format=%cs` (YYYY-MM-DD).
2. From BOARD.md Done table, collect rows where:
   - `Agent` is `developer` or `test-writer`
   - `Completed` date is equal to or newer than the last commit date
3. For each such TASK-NNN, read `.guild/tasks/TASK-NNN.md` frontmatter to get its `requirement` and `title`.

If no relevant completed tasks are found, fall back to: use the staged diff only and craft a commit message from it. Skip to step 5 with empty task list.

### 4. Group by Requirement

Group the collected tasks by their `requirement` field. For each requirement, read `.guild/requirements/REQ-NNN.md` frontmatter for its `title`.

Each group becomes one logical change in the commit.

### 5. Determine Commit Type and Scope

Inspect the requirement titles and task titles to infer conventional commit type:

| Signal | Type |
|--------|------|
| Title contains "fix", "bug", "issue", "error" | `fix` |
| Title contains "doc", "readme", "documentation" | `docs` |
| Title contains "test", "spec" only | `test` |
| Title contains "refactor", "cleanup", "reorganize" | `refactor` |
| Title contains "performance", "optimize", "speed up" | `perf` |
| Default (new capability) | `feat` |

If multiple requirements are included and their types differ, use the most impactful type in this order: `feat > fix > perf > refactor > test > docs`.

For **scope**, infer from the files changed (`git diff --cached --name-only`):
- If all changes are under one top-level directory like `src/auth/`, scope is that directory basename (`auth`)
- If changes span multiple areas, omit scope
- Scope should be a single lowercase word

### 6. Draft the Commit Message

Format:

```
{type}({scope}): {short summary, <=72 chars, lowercase start, no period}

{body}

Refs: REQ-NNN[, REQ-MMM]
```

The **short summary**:
- If only one requirement: use a tight paraphrase of its title
- If multiple: use the most prominent requirement's title, suffixed with `(+N more)`

The **body** describes what shipped. One bullet per requirement:
```
- REQ-NNN {requirement title}: {one-line summary drawn from completed task titles}
```

Omit the body if there is only one requirement with a single task.

### 7. Preview and Confirm

Show the user:

```
Proposed commit
===============
{full message}

Files to commit:
  {git diff --cached --name-only output}

Stats:
  {git diff --cached --shortstat output}

Tasks included:
  TASK-NNN: {title} (REQ-NNN)
  TASK-MMM: {title} (REQ-NNN)

Commit? (yes / no / edit)
```

- **"yes"** → proceed to step 8
- **"no"** → stop without committing
- **"edit"** → ask user for the message they want, then use their exact wording

### 8. Create the Commit

Run `git commit` with the message passed via HEREDOC to preserve formatting:

```bash
git commit -m "$(cat <<'EOF'
{type}({scope}): {summary}

{body}

Refs: REQ-NNN
EOF
)"
```

Do NOT pass `--no-verify`. If pre-commit hooks fail, surface the error to the user and stop — they must fix the underlying issue.

### 9. Report Result

After a successful commit:

```
Committed {short-hash}: {summary}

{N} file(s) changed, {+X} insertions, {-Y} deletions
Tasks recorded: TASK-NNN, TASK-MMM

Not pushed. Push with `git push` when ready.
```

## Rules

- **Never push** — commit only; the user decides when to push
- **Never skip hooks** — do not pass `--no-verify` unless the user explicitly asks for it in the edit step
- **Never amend** — always create a new commit; amending published history is destructive
- **Never `git add -A` or `git add .`** — only `git add -u` to stage tracked changes, and only after asking
- **Do not update BOARD.md** — this skill is read-only on the board
- **Do not modify task files** — this skill is read-only on tasks
- **Respect empty diffs** — if nothing is staged after the optional `git add -u`, stop cleanly
