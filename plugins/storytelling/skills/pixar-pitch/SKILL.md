---
name: pixar-pitch
description: >
  Use this skill to structure a message with the Pixar story spine — "Once upon a time... Every
  day... Until finally." Best for transformation and journey narratives: before/after, old world →
  new world, the arc of a change, product origin stories, case studies. Triggers on "pixar pitch",
  "story spine", "tell this as a journey", "before and after story", "narrate the transformation",
  "make this change story compelling", or "once upon a time". Turns raw material into a narrative
  arc with a status quo, an inciting turn, and a new resolution.
version: 1.0.0
user-invocable: true
---

# The Pixar Pitch — Once Upon a Time, Until Finally

**Emma Coats, former Pixar storyboard artist (rule #4 of her "22 Rules of Storytelling").** Every
Pixar film hangs on the same skeleton — a stable world, a change that upends it, escalating
consequences, and a new normal. It's the most natural shape for any story of *transformation*.

## The Spine

> **Once upon a time** there was ___.
> **Every day**, ___.
> **One day**, ___.
> **Because of that**, ___.
> **Because of that**, ___.
> **Until finally**, ___.

Beat by beat:

1. **Once upon a time** — the setup: who/what this is about, the starting world.
2. **Every day** — the status quo, the stable-but-flawed normal. (This is where the *problem*
   quietly lives.)
3. **One day** — the inciting incident: the change, insight, decision, or disruption that breaks
   the routine. **This is the hinge of the whole pitch.**
4. **Because of that** — the first consequence. Cause and effect, not a jump-cut.
5. **Because of that** — the escalation; stakes rise. (Repeatable — chain as many as the story
   needs.)
6. **Until finally** — the resolution: the new world, the payoff, the transformation complete.

The post's short version — *"Once upon a time. Every day. Until finally."* — is the compressed
three-beat form: **status quo → turn → new reality.** Use the full spine when you have room to build
cause and effect.

## When to use it (and when not)

**Use it for:** transformation stories, product origin and journey narratives, customer case
studies (their world before → after you), change-management and vision-of-the-future comms,
fundraising "here's the world we're building" arcs, conference talk openers.

**Reach for something else when:** the audience wants the decision first (→ `pyramid-principle`),
it's a factual debrief (→ `what-so-what-now-what`), or you need one punchy line (→ `abt`). The Pixar
Pitch trades speed for emotional arc — don't use it when there's no real "before and after".

## How to build it

1. **Find the transformation.** What was the world like *before*, and what is it like *after*? If
   nothing genuinely changes, this isn't the right frame.
2. **Make "Every day" ache a little.** The status quo should carry the unspoken problem so the turn
   feels earned.
3. **Nail the "One day".** One clear inciting moment. Vague turns produce flat pitches.
4. **Chain "Because of that".** Consequences must follow causally — earned, not listed.
5. **Land "Until finally" on the payoff**, ideally echoing the ache from "Every day".

## Worked example

**Raw material:** a company that adopted your analytics tool and cut their reporting time from days
to minutes.

**As a Pixar Pitch:**
> **Once upon a time**, a 40-person finance team ran the numbers for the whole company.
> **Every day**, they stitched reports together by hand across twelve spreadsheets — and every
> month-end, someone stayed until midnight.
> **One day**, they connected their data to a tool that built the reports itself.
> **Because of that**, the midnight month-ends stopped.
> **Because of that**, the team stopped *producing* numbers and started *questioning* them.
> **Until finally**, the report that used to take three days now takes three minutes — and finance
> became the team that sees around corners instead of the team stuck in the rearview mirror.

## Quality bar / common mistakes

- **No "One day".** A story with only "Every day" is a description, not a narrative. There must be a
  turn.
- **"And then, and then".** Sequential events without causal "because of that" links read as a list,
  not a story. Make each beat cause the next.
- **A flat "Every day".** If the status quo has no tension, the transformation has nothing to
  transform. Let the problem live there.
- **Resolution that doesn't pay off the setup.** "Until finally" should resolve the specific ache
  you planted, not introduce a new topic.

## Compose

- Have the `story-drafter` agent draft in this framework (the `storytelling` skill uses it for
  parallel comparison).
- Audit an existing draft with the `story-critic` agent, targeting `pixar-pitch`.
- Not sure this is the right frame? Start from the `storytelling` skill and let it recommend.
