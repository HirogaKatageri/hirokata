# Writing the handoff in plain language

The reader is a teammate who does not know this codebase and may not write code at all.
They should finish the document knowing what happened and what to do, without looking
anything up.

## The test

Read a sentence back and ask: **would someone outside the team understand this?** If it
needs a glossary, rewrite it.

## Say what it does, not what it is

| Instead of | Write |
|---|---|
| Refactored the auth middleware | Cleaned up the code that checks who is signed in — nothing changes for users |
| Added Redis caching to the org-switch endpoint | Switching between companies is faster now, because the app remembers the answer for a few minutes |
| Fixed a null-pointer in the invoice serializer | Fixed a crash that happened when an invoice had no billing address |
| Bumped the dependency to 4.2.1 | Updated an outside library we rely on, to pick up its security fix |
| Migrated the schema to add a `tenant_id` column | Changed how the database stores records so each company's data is kept separate |
| Implemented optimistic locking on the booking flow | Stopped two people from booking the same slot at the same moment |

## Words to spell out

Keep these only when the sentence would be wrong without them, and explain on first use.

| Term | Say instead |
|---|---|
| PR / pull request | proposed change *(or keep "pull request" — it is unavoidable, but link it)* |
| merged to main | now live for everyone / now part of the main version |
| staging | the practice copy of the site, used for checking before it goes live |
| uncommitted | not saved into the project history yet |
| branch | a separate copy of the code where one job is being done |
| worktree | a separate folder holding a copy of the project |
| endpoint / route | a page or a request the app answers |
| migration | a change to how the database is organised |
| CI / checks failing | the automatic tests that run on every change are reporting a problem |
| deploy | put the new version onto the real site |
| revert | undo a change that was already released |
| flaky | fails sometimes for no clear reason |
| regression | something that used to work and now does not |
| refactor | tidying the code without changing what it does |

## Keep the specifics that matter

Plain does not mean vague. The reader still needs:

- **Names of the things they can click** — repository, pull request number, link.
- **Names of the things they can open** — full folder path, branch name.
- **Numbers that convey size** — "34 files" tells them whether this is a tweak or a rewrite.
- **Names of people** when someone is waiting or being waited on.

Put those in the italic metadata line or the waiting-on block, so the prose stays readable
and the detail is still one glance away.

## Two levels, on purpose

**Summary voice** — for anything finished and unblocked:

> Finished the sign-in work. People who belong to more than one company can now switch
> between them without being signed out.

**Detail voice** — for anything that needs another person. Complete, specific, actionable:

> **Waiting on:** whoever reviews backend changes
> **What they need to do:** open <link>, read the change, and approve it or say what needs
> fixing. It is 6 files and touches only the sign-in path.
> **Why it matters:** the account-switching fix cannot go live until this is approved, and
> two customers have already reported the problem.
> **Urgency:** this week — there is no hard deadline, but the bug is visible to customers.

## Sentence habits

- One idea per sentence. Two short sentences beat one long one.
- Active voice, and name the actor: "Nobody has reviewed this yet" beats "This has not
  been reviewed".
- Lead with the outcome, then the cause: "Sign-in was breaking for multi-company users
  because the app cached the wrong company."
- Say plainly when something is uncertain: "I am not sure this covers the case where a
  user belongs to more than three companies." Hedged language reads as false confidence.
- No filler openers — "Additionally", "It should be noted that", "In terms of".

## Never do this

- Do not paste error messages, stack traces, or diffs into the prose. Describe the effect
  and link to where the detail lives.
- Do not describe implementation as an achievement in itself. "Extracted three modules" is
  not an outcome; "the code is now easier to change and nothing behaves differently" is.
- Do not report the same work under two headings. Pick the furthest-along bucket.
- Do not soften a blocker. If someone must act or the work stalls, say so directly.
