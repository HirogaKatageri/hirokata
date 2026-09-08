---
name: daily-handoff
description: This skill should be used when the user asks for a "daily handoff", "handoff document", "handoff note", "end of day summary", "EOD report", "daily summary", "what did I do today", "what did I work on", "standup notes", "write my handoff", "handoff for tomorrow", or wants a plain-language status document covering the last 24 hours. Gathers merged and open GitHub PRs the user authored, comments the user left, recent Claude Code / Codex / OpenCode sessions, and uncommitted local changes, then sorts everything into Done, Ready for Merging, In Progress and What's Next, and writes it to ~/YYYY-MM-DD-handoff.md.
version: 0.1.0
user-invocable: true
arguments:
  - name: hours
    description: How far back to look, in hours. Defaults to 24.
    required: false
  - name: scan-root
    description: Directory to scan for local git checkouts. Defaults to ~/Projects.
    required: false
  - name: output
    description: Where to write the document. Defaults to ~/YYYY-MM-DD-handoff.md using today's local date.
    required: false
---

# Daily Handoff

Turn the last 24 hours of scattered activity — pull requests, review comments, AI coding
sessions, and half-finished local work — into one handoff document a teammate can read
without asking follow-up questions.

## Purpose

At the end of a working day the record of what happened is spread across GitHub, several
local checkouts, and the transcripts of whatever AI coding tools were used. None of those
tell a colleague what is finished, what is waiting on them, and what to pick up next.

This skill collects all four sources, sorts them into four buckets, and writes the result
as plain-language markdown aimed at a reader who was not there.

## Who the document is for

Write for a **teammate who does not know this work**. That single decision drives every
other rule in this skill:

- They do not know the codebase, so name things by what they do, not by their symbol names.
- They do not know the jargon, so spell it out. See `references/plain-language.md`.
- They cannot ask a follow-up question, so anything they must act on has to be complete
  on the page.

## Workflow

### Step 1 — Set the window and the output path

Default to a 24-hour lookback and today's local date.

```bash
HOURS=24
TODAY=$(date +%Y-%m-%d)
OUT="$HOME/${TODAY}-handoff.md"
```

Honour the `hours`, `scan-root` and `output` arguments if the user supplied them. If the
user asked for "yesterday" or "this week", translate that into hours (24, 168) rather than
inventing a different window.

### Step 2 — Run the three collectors

They are independent. Run them together, and do not stop if one comes back empty — an
empty section is itself information.

```bash
SKILL_DIR="<this skill's directory>"
TMP=$(mktemp -d)

bash   "$SKILL_DIR/scripts/collect-github.sh"  "$HOURS"                > "$TMP/github.json"
bash   "$SKILL_DIR/scripts/collect-repos.sh"   "$HOME/Projects" "$HOURS" > "$TMP/repos.json"
python3 "$SKILL_DIR/scripts/collect-sessions.py" --hours "$HOURS"       > "$TMP/sessions.json"
```

| Script | Covers | Notes |
|--------|--------|-------|
| `collect-github.sh` | Merged PRs, open PRs, closed-unmerged PRs, and every comment the user left | Needs an authenticated `gh`. Takes ~15s; the per-PR detail calls are what make the summaries specific. |
| `collect-repos.sh` | Uncommitted changes, unpushed commits, stashes | Read-only. Scans `~/Projects` six levels deep, which reaches agent worktrees under `.claude/worktrees/`. |
| `collect-sessions.py` | Claude Code, Codex CLI and OpenCode sessions | Reads only the user's own prompts. A tool that is not installed is silently absent. |

Every collector reports its own failures in an `errors` array instead of exiting non-zero.
**Read those arrays.** If `gh` was not authenticated, the handoff must say the GitHub half
is missing rather than implying the day was quiet.

### Step 3 — Read the raw material for meaning, not just for titles

A PR title is a label, not a summary. Before writing anything, understand what actually
changed:

- For each **merged and open PR**: read `body`, `files`, and the additions/deletions counts.
  If the body is thin and the change is not obvious, run
  `gh pr diff <number> --repo <owner/repo>` and read it.
- For each **uncommitted change set**: run `git -C <repo> diff --stat` and, where the
  change is small enough to matter, `git -C <repo> diff` to see what it does.
- For each **session**: the prompts are the intent. A session whose prompts never turned
  into a commit or a PR is unfinished work, and belongs in *In Progress* or *What's Next*.

Cross-reference the three sources. The same piece of work usually appears in all of them —
a session prompt, then a branch, then a PR. Report it **once**, in the furthest-along
bucket, and use the other sources for detail.

### Step 4 — Sort into the four buckets

| Bucket | What goes in it |
|--------|-----------------|
| **Done (Merged)** | PRs authored by the user and merged inside the window. |
| **Ready for Merging** | Work that is finished but not in `main`/`staging` yet: open non-draft PRs, and local branches with commits that are pushed or ready to push but have no PR. |
| **In Progress (Uncommitted)** | Uncommitted file changes, stashes, and draft PRs. Also sessions that ended without producing a commit. |
| **What's Next** | Everything the work implies but nobody has started: follow-ups named in PR bodies or comments, failing checks, review feedback not yet answered, PRs closed without merging, and stated intentions from sessions. |

Judgment calls:

- An open PR with an approving review and passing checks is **Ready for Merging**, not
  In Progress. An open PR with requested changes is **In Progress**, and the requested
  changes belong in *What's Next*.
- A draft PR is **In Progress** regardless of its review state.
- Unpushed commits on a feature branch are **Ready for Merging** only if the branch is
  coherent on its own. Mid-refactor commits are **In Progress**.
- Work inside `.claude/worktrees/` is real work — an agent produced it — but say where it
  lives, because it is easy to lose. It is also usually **In Progress**.
- A PR closed without merging goes under *What's Next* with a note that it was dropped, so
  the decision is visible rather than silent.

### Step 5 — Write at two levels of detail

This is the rule that makes the document useful:

> **General information is summarized. Anything that needs another person is detailed.**

**Summarize** — one to three sentences, no file paths, no function names:

> Finished the login work. Users now stay signed in when they switch between the two
> company accounts they belong to, instead of being kicked back to the sign-in page.

**Detail** — anything that is blocked on, or waiting for, someone else. Give each its own
block and answer all five questions:

1. **What** is waiting.
2. **Who** it is waiting on (a name if the data has one, a role if not).
3. **What exactly** they need to do — the link, the branch, the command, the decision.
4. **Why it matters** — what stays stuck until it happens.
5. **How urgent** it is, and what the deadline is if there is one.

Things that always get the detailed treatment: a PR waiting on review, a failing check, a
review comment not yet answered, a decision the user cannot make alone, anything sitting
in a worktree another person would not think to look in, and any credential, access or
environment problem.

### Step 6 — Give the day a title and a summary

Open the document with a title naming the day's actual theme — not "Daily Handoff". If the
day had one dominant thread ("Sign-in and account switching"), use it. If it had three
unrelated threads, name the largest and say there were others.

Follow it with a three-to-five sentence summary a reader can stop after: what moved, what
is waiting, and the single most important thing for someone else to pick up.

### Step 7 — Write the file and report

Write to `$OUT` using the structure in `references/handoff-template.md`. Then tell the user
the path and give a two-line spoken summary — do not paste the whole document back.

If a section is genuinely empty, keep its heading and write one honest line
("Nothing merged in this window."). A missing heading reads like an oversight; an empty one
reads like a fact.

## Supporting files

- `scripts/collect-github.sh` — merged, open and closed PRs, plus the user's own comments.
- `scripts/collect-repos.sh` — uncommitted changes, unpushed commits, stashes.
- `scripts/collect-sessions.py` — Claude Code, Codex and OpenCode sessions.
- `references/handoff-template.md` — the document structure to fill in.
- `references/plain-language.md` — how to say technical things without technical words.

## Requirements

- `gh` on `PATH` and authenticated (`gh auth status`) for the GitHub half.
- `jq` for the shell collectors.
- `python3` 3.9+ for the session collector.
- `git` for the local scan.

Any missing piece degrades the document rather than stopping it — but must be stated in
the *Gaps in this handoff* section so nobody reads a partial picture as a complete one.
