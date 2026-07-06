---
name: storybrand
description: >
  Use this skill to structure a message with Donald Miller's StoryBrand (SB7) framework — make the
  customer the hero and position yourself as the guide. Best for marketing, sales, landing pages,
  value propositions, cold outreach, and product messaging. Triggers on "storybrand", "sb7", "make
  the customer the hero", "write a landing page / value prop / sales page", "clarify our marketing
  message", "why should a customer buy this", or "our messaging is confusing". Turns raw material
  into a hero's-journey message where the customer wins and you guide.
version: 1.0.0
user-invocable: true
---

# StoryBrand (SB7) — The Customer Is the Hero, You Are the Guide

**Donald Miller, *Building a StoryBrand*.** The mistake most brands make is casting *themselves* as
the hero. In every story that works, the hero is the one with the problem — the *customer* — and the
brand plays the **guide** (Yoda, not Luke) who hands them a plan and calls them to act. "If you
confuse, you lose."

## The Seven Parts (SB7)

1. **A Character** — the customer, the hero. Open with *them* and what they *want*, not with you.
2. **has a Problem** — on three levels:
   - **External:** the tangible obstacle ("my reports take three days").
   - **Internal:** how it makes them feel ("I feel behind and disorganized").
   - **Philosophical:** why it's *wrong* ("finance teams shouldn't be stuck doing manual work").
   Great messaging speaks to the internal problem — that's what people actually buy relief from.
3. **and meets a Guide** — you. Show two things: **empathy** ("we get it") and **authority**
   (proof you can help — results, testimonials, credentials).
4. **who gives them a Plan** — a simple path, usually 3 steps. It removes the fear of "how does this
   work / what do I have to do?"
5. **and calls them to Action** — one clear, direct call to action (a *direct* CTA like "Start free"
   plus optionally a *transitional* one like "Download the guide"). Heroes don't act unless
   challenged to.
6. **that helps them avoid Failure** — name the stakes. What's at risk if they *don't* act? (Use
   sparingly — a little loss aversion, not fear-mongering.)
7. **and ends in Success** — paint the resolution. Show them the transformed life on the other side.

## When to use it (and when not)

**Use it for:** landing pages, homepages, value propositions, sales and pitch decks, cold emails,
ad copy, onboarding, any customer-facing message that needs to convert.

**Reach for something else when:** the audience is internal leadership deciding (→
`pyramid-principle`), you're rallying your own team on mission (→ `golden-circle`), or you just need
a one-line hook (→ `abt`). StoryBrand is aimed outward, at the buyer.

## How to build it

1. **Start with what the customer wants**, in their words — never with your company.
2. **Name the internal problem**, not just the external one. That's the emotional hook.
3. **Position yourself as guide, not hero:** empathy first, then authority. Resist the urge to
   headline your features.
4. **Give a dead-simple plan** (3 steps) and **one** primary CTA. Clarity beats cleverness.
5. **Bracket it with stakes and success** — what they avoid, and what they gain.

## Worked example

**Raw material:** "We sell analytics software with real-time dashboards and integrations."

**As StoryBrand:**
> **(Character + want):** You want to walk into every meeting already knowing the numbers.
> **(Problem — external/internal/philosophical):** But your reports take days to build, you feel a
> step behind the questions people ask, and honestly — a finance team shouldn't be trapped doing a
> robot's job.
> **(Guide — empathy + authority):** We've helped 300 finance teams get their time back; we know
> exactly how painful month-end is.
> **(Plan):** Connect your data, pick a dashboard, get answers in real time.
> **(Call to action):** Start free today.
> **(Failure → Success):** Stop losing nights to spreadsheets — and become the team that sees the
> business clearly, before anyone has to ask.

Notice: the customer is "you" throughout; the company is the guide, never the star.

## Quality bar / common mistakes

- **Making yourself the hero.** "We're the leading platform…" fails. Lead with the customer's want.
- **Only the external problem.** Features fix external problems; people buy relief from the
  *internal* one. Name the feeling.
- **No clear CTA, or too many.** A confused hero does nothing. One primary call to action.
- **All authority, no empathy** (arrogant) or **all empathy, no authority** (unconvincing). You need
  both to be a trusted guide.

## Compose

- Have the `story-drafter` agent draft in this framework (the `storytelling` skill uses it for
  parallel comparison).
- Audit an existing draft with the `story-critic` agent, targeting `storybrand`.
- Not sure this is the right frame? Start from the `storytelling` skill and let it recommend.
