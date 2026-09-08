# Handoff document structure

Fill this in. Keep the headings even when a section is empty — write one honest line
instead of deleting it.

---

```markdown
# <Title naming the day's actual theme>

**<Weekday, D Month YYYY>** · covering the last <N> hours · written for whoever picks this up next

## The short version

<Three to five sentences. What moved, what is waiting, and the one thing someone else
should pick up first. A reader who stops here should still know where things stand.>

---

## Done

<Work that is merged and live. One entry per piece of work, not one per pull request —
if three PRs delivered one thing, that is one entry.>

### <What it does, in plain words>

<One to three sentences on what changed and who notices the difference. No file paths.>

*<owner/repo> · [#<number>](<url>) · merged <time> · <N> files*

---

## Ready for merging

<Finished, but not in the main branch yet. Each entry says what is finished and what is
holding it. Anything waiting on a person gets the detailed treatment below.>

### <What it does, in plain words>

<One to three sentences on what it delivers.>

**Waiting on:** <person or role>
**What they need to do:** <the exact action — open the link, approve, answer the question,
run the command. Include the link and the branch name.>
**Why it matters:** <what stays blocked until it happens.>
**Urgency:** <how soon, and the deadline if there is one.>

*<owner/repo> · [#<number>](<url>) · <branch> → <base> · <N> files*

---

## In progress

<Started but not finished: uncommitted changes, stashes, draft pull requests, and
sessions that ended without producing anything.>

### <What is being built, in plain words>

<One to three sentences: what it is meant to do, and how far it got.>

**Where it lives:** <full path, plus the branch. Say explicitly if it is inside an agent
worktree under `.claude/worktrees/` — that is easy to lose.>
**State:** <N files changed, roughly what they cover. Say if it is mid-refactor and would
not build right now.>
**To resume:** <the first thing the next person should do.>

---

## What's next

<Everything the day implies but nobody has started. Ordered so the most important is
first. Anything needing another person carries the full waiting-on block.>

- **<Thing to do>** — <why, in one sentence.> <Link if there is one.>

---

## Gaps in this handoff

<Only if something could not be collected. Name it plainly so a partial picture is not
mistaken for a complete one.>

- <e.g. "GitHub activity is missing — the `gh` command was not signed in when this ran.">
```

---

## Rules for filling it in

**Titles.** A heading is what the work *does*, not what the branch is called. "Users stay
signed in when they switch accounts" beats "feat(auth): session cache eviction".

**Links.** Every GitHub item carries its link. Every local item carries its full path and
branch. A reader should never have to search for the thing being described.

**Metadata lines.** Keep the italic trailing line — repo, number, link, timing, size. It is
the technical detail a reader can ignore, kept out of the prose where it would get in the way.

**One entry per piece of work.** Merge related PRs, commits and sessions into a single
entry under the bucket the work has actually reached. Do not report the same thing twice.

**Empty sections.** "Nothing merged in this window." is a complete and useful sentence.

**Length.** Done and Ready-for-merging entries run one to three sentences each. Waiting-on
blocks run as long as they need to — the person reading them has to act without asking.
