# Storytelling Plugin

Turn any idea, pitch, update, or decision into a message that **lands** — using six proven
storytelling frameworks, inside Claude Code.

Most communication fails not because the idea is weak but because it's delivered in the wrong shape.
A board wants the answer first; a team wants a reason to care; a customer wants to be the hero. This
plugin diagnoses the situation, picks the framework that fits, and drafts the message in it — and,
when the framing is uncertain, drafts it **several ways in parallel** so you can feel which one lands.

Inspired by [Eric Partaker's rundown of six CEO storytelling frameworks](https://www.linkedin.com/posts/ericpartaker_ceos-love-to-focus-on-the-numbers-but-its-share-7478317065133658112-ICRZ/).

---

## Installation

```bash
/plugin install storytelling@hirokata
```

---

## Quick Start

```
help me tell the story of our new analytics product to a room of investors
```

The `storytelling` skill asks (only if needed) who it's for and what you want them to do,
recommends the right framework, and drafts it. Or, if you already know the frame:

```
turn this into an ABT
frame our mission with the golden circle
structure this post-mortem as what / so what / now what
```

---

## The Six Frameworks

| Framework | Shape | Strongest for | Origin |
|---|---|---|---|
| **Golden Circle** | Why → How → What | Rallying a team, brand & vision | Simon Sinek |
| **Pyramid Principle** | Answer first → grouped evidence | Boards, execs, investors, decision memos | Barbara Minto |
| **Pixar Pitch** | Once upon a time → Every day → Until finally | Transformation & journey stories | Emma Coats |
| **StoryBrand** | Customer = hero, you = guide | Marketing, sales, landing pages, value props | Donald Miller |
| **What / So What / Now What** | Fact → impact → action | Post-mortems, retros, status, incidents | Borton / Rolfe |
| **ABT** | Setup → tension → resolution | Elevator pitch, one-liner, <30s hook | Randy Olson |

---

## What's Inside

### The main skill

**`storytelling`** — the router and coach. It:

```
Message + audience + goal + medium
 └─ Diagnose → recommend the framework that fits the job
 └─ Draft it (single mode) — or draft 2–3 frameworks in parallel (panel mode)
 └─ Optionally sharpen with the story-critic
 └─ Deliver the message + why that frame lands
```

Trigger it with `help me tell the story of <X>`, `how should I pitch <X>`, `make this message
land`, `I need to present <X> to <audience>`, or `which storytelling framework fits <X>`.

### Six standalone framework skills

Each framework is also its own user-invocable skill — full explanation, the template/spine, when to
use it (and when not), a worked example, and the quality bar / common mistakes:

| Skill | Invoke when you already know you want… |
|---|---|
| **`golden-circle`** | to lead with *why*, for vision and rallying |
| **`pyramid-principle`** | to lead with the *answer*, for decision-makers |
| **`pixar-pitch`** | a *transformation* arc, before → after |
| **`storybrand`** | *marketing/sales* copy where the customer is the hero |
| **`what-so-what-now-what`** | a clean *debrief / post-mortem / status* |
| **`abt`** | a *punchy one-liner* or elevator hook |

### Two sub-agents

| Agent | Model | Role |
|---|---|---|
| **`story-drafter`** | Sonnet | Drafts the message in **one** framework. Spawned in parallel (one per framework) for side-by-side "panel mode" comparison. Returns the draft inline. |
| **`story-critic`** | Opus | Audits a draft against its framework + audience, scores framework-fit / clarity / impact, and returns a tightened rewrite. Used for high-stakes messages. |

---

## How It Works

**Single mode** (default) — Claude picks the framework and drafts the message directly in your main
session.

**Panel mode** (when the framing is genuinely uncertain, or you ask for options) — the `storytelling`
skill fans out the `story-drafter` agent once per candidate framework **in parallel**, then presents
the drafts side by side with a one-line trade-off each, so you pick — or combine. This mirrors the
same parallel-fan-out philosophy as the [`research`](../research) plugin: the work happens off your
main context window and you get the comparison, not the raw labor.

**Sharpening** — for a keynote, an investor pitch, or a launch, hand the chosen draft to
`story-critic` for a scored audit and a tighter rewrite.

---

## Design Notes

**Why a router skill *and* six standalone skills?**
Picking the right frame is half the battle, so the `storytelling` skill diagnoses and recommends.
But when you already know the frame, you shouldn't have to go through triage — so each framework is a
first-class skill you can invoke directly. They share the same underlying specs, so a diagnosis flows
straight into the right skill's depth.

**Why parallel drafting?**
The best way to know whether your pitch should be a Golden Circle or an ABT is to *see both*. Drafting
candidate frames concurrently — rather than one, then reconsidering — turns "which framework?" from a
guess into a comparison.

**Why Opus for the critic, Sonnet for the drafter?**
Drafting is a breadth task that benefits from speed and parallelism (Sonnet). Judging whether a draft
truly lands — and rewriting it tighter — is a reasoning task (Opus). Swap either model in the agent's
frontmatter.

**The frame is a scaffold, not a cage.**
Every skill and agent is built to produce a message that reads like a human wrote it — the framework
structures the thinking, then the prose is written naturally, not as a template with the blanks
filled in.

---

## Limitations

These frameworks structure and sharpen a message; they don't supply substance. A well-framed weak
idea is still weak. The plugin reasons over what you tell it — it can't verify your facts, know your
audience better than you, or guarantee persuasion. Treat every draft as a strong first version to
make your own, not a finished script to read verbatim.

---

## Credits

- **The six-framework framing** — adapted from **Eric Partaker's** LinkedIn post on CEO storytelling
  frameworks ([post](https://www.linkedin.com/posts/ericpartaker_ceos-love-to-focus-on-the-numbers-but-its-share-7478317065133658112-ICRZ/)).
- **The frameworks themselves** — Simon Sinek (*Start With Why*), Barbara Minto (*The Minto Pyramid
  Principle*), Emma Coats (Pixar story spine), Donald Miller (*Building a StoryBrand*), the
  Borton/Rolfe reflective model (*What? / So What? / Now What?*), and Randy Olson (*Houston, We Have a
  Narrative* — the ABT template).

This plugin is an independent implementation of these publicly documented frameworks as Claude Code
skills and agents, not affiliated with or endorsed by any of the above.
