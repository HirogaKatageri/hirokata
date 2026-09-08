# Handoff document structure

Fill this in. Keep the headings even when a section is empty — write one honest line
instead of deleting it.

The **waiting-on block** appears in three of the four sections below, not just one. Detail is
decided by whether another person has to act, never by which section the item landed in.

---

```markdown
# <Title naming the day's actual theme>

**<Weekday, D Month YYYY>** · covering the last <N> hours · written for whoever picks this up next

## The short version

<Three to five sentences. What moved, what is waiting, and the one thing someone else
should pick up first. A reader who stops here should still know where things stand.>

---

## Done (Merged)

<Work that is merged and live. One entry per piece of work, not one per pull request —
if three PRs delivered one thing, that is one entry.

Nobody has to act on anything in this section, so nothing here carries a waiting-on block
and nothing here runs long. Summary voice only.>

### <What it does, in plain words>

<One to three sentences on what changed and who notices the difference. No file paths, no
asides the reader cannot act on.>

*<owner/repo> · [#<number>](<url>) · merged <time> · <N> files*

---

## Ready for Merging

<Finished, but not in the main branch yet. Each entry says what is finished and what is
holding it.>

### <What it does, in plain words>

<One to three sentences on what it delivers.>

**Waiting on:** <person or role>
**What they need to do:** <the exact action — open the link, approve, answer the question,
run the command. Include the link and the branch name.>
**Why it matters:** <what stays blocked until it happens.>
**Urgency:** <how soon, and the deadline if there is one. Say "no deadline" rather than
inventing one.>

*<owner/repo> · [#<number>](<url>) · <branch> → <base> · <N> files*

---

## In Progress (Uncommitted)

<Started but not finished: uncommitted changes, stashes, draft pull requests, and
sessions that ended without producing anything.>

### <What is being built, in plain words>

<One to three sentences: what it is meant to do, and how far it got. Resist re-explaining
the whole feature — the next person needs to restart it, not review it.>

**Where it lives:** <full path, plus the branch. Say explicitly if it is inside an agent
worktree under `.claude/worktrees/` — that is easy to lose.>
**State:** <N files changed, roughly what they cover. Say if it is mid-refactor and would
not build right now.>
**To resume:** <the first thing the next person should do.>

<If this item is also blocked on someone else, add the waiting-on block here — the four
bold lines from Ready for Merging, unchanged.>

---

## What's Next

<Everything the day implies but nobody has started.

Two shapes, and the choice is not stylistic. Anything that needs another person — a
review, a decision, a credential, a manual step outside the code, a warning someone must
receive — gets its own `###` heading and the full waiting-on block. These come first.
Everything the next person can simply go and do stays a one-line bullet, below them.>

### <The thing that needs someone, named as an outcome>

<One to three sentences on what the situation is.>

**Waiting on:** <person or role>
**What they need to do:** <the exact action.>
**Why it matters:** <what breaks or stalls otherwise.>
**Urgency:** <how soon, and the deadline if there is one.>

- **<Thing the next person can just do>** — <why, in one sentence.> <Link if there is one.>

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

**Length.** Done (Merged) entries are capped at three sentences and carry no aside nobody
acts on. In Progress entries run one to three sentences before their bold lines. Waiting-on
blocks run as long as they need to — the person reading them has to act without asking.

**The test, applied per item.** Before writing an entry, ask: does someone other than the
author have to do something? If yes, it gets the block, whichever section it is in. If no,
it gets a summary and nothing more. A document where the merged work is the longest section
and the blockers are bullets has the rule backwards.
