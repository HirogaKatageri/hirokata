---
name: storytelling
description: >
  Use this skill when the user has something to communicate — an idea, a pitch, a product,
  a strategy, an update, a decision, a launch, an ask — and wants it to actually land. Triggers
  on things like "help me tell the story of <X>", "how should I pitch <X>", "make this message
  land", "I need to present <X> to <audience>", "reframe this so it's compelling", "turn this
  into a story", "help me write my <keynote / investor update / launch post / all-hands / cold
  email>", "which storytelling framework fits <X>", or "make this more persuasive". Diagnoses the
  audience and goal, recommends the right framework from six proven ones, drafts the message, and
  can draft it several ways in parallel so the user picks the version that lands.
version: 1.0.0
user-invocable: true
---

# Storytelling — Pick the Right Frame, Then Make It Land

Most communication fails not because the idea is weak but because it is delivered in the wrong
shape. A board wants the answer first; a team wants a reason to care; a customer wants to be the
hero. **This skill diagnoses the situation, picks the framework that fits, and drafts the
message in it** — and, when it helps, drafts it several ways at once so you can feel which one
lands.

It draws on six battle-tested storytelling frameworks, each strong for a different job:

| Framework | Shape | Strongest for |
|---|---|---|
| **Golden Circle** (Sinek) | Why → How → What | Rallying a team, brand & vision, "why we exist" |
| **Pyramid Principle** (Minto) | Answer first → grouped evidence | Boards, execs, investors, decision memos |
| **Pixar Pitch** (Coats) | Once upon a time → Every day → Until finally | Transformation, journeys, change stories |
| **StoryBrand** (Miller) | Customer = hero, you = guide | Marketing, sales, landing pages, value props |
| **What / So What / Now What** | Fact → impact → action | Post-mortems, retros, status, incident reviews |
| **ABT** (And, But, Therefore) | Setup → tension → resolution | Elevator pitch, one-liner, hook in <30s |

Each framework is also a standalone skill (`golden-circle`, `pyramid-principle`, `pixar-pitch`,
`storybrand`, `what-so-what-now-what`, `abt`) if the user already knows which one they want.

## Workflow

### Step 1 — Get the raw material (don't over-interview)

You need four things. Take whatever the user gave you and ask, in **one** short message, only for
what's missing:

1. **The message** — what are you actually trying to say? (the idea, ask, update, or point)
2. **The audience** — who receives it, and what do they care about?
3. **The outcome** — what should they think, feel, or do afterward?
4. **The medium & length** — a Slack post? a 2-minute pitch? a keynote? a landing page? one line?

If the user already made these clear, skip the questions and go straight to Step 2.

### Step 2 — Diagnose and recommend a framework

Match the situation to the framework using this decision guide:

- Goal is to **inspire / rally / explain why we exist / set a vision** → **Golden Circle**
- Audience is a **board / execs / investors** and wants **the decision fast** → **Pyramid Principle**
- You're selling a **transformation or journey** (before → after, old world → new) → **Pixar Pitch**
- It's **customer-facing marketing / sales** and needs a clear value prop → **StoryBrand**
- It's a **debrief / post-mortem / retro / status update** → **What / So What / Now What**
- You need a **punchy hook, elevator pitch, or one-liner in under 30 seconds** → **ABT**

State your recommendation in one sentence with the *why* (e.g. "Your audience is the board and you
want a yes on funding — that's a Pyramid Principle job: lead with the ask, then the three reasons").
If two frameworks fit, say so and offer the panel (Step 3, panel mode).

The one-paragraph specs for all six frameworks are in the **Framework Reference** at the bottom of
this skill — use them to route and to brief the drafter. For depth on any one, read its skill.

### Step 3 — Draft the message

Two modes. Default to **single** unless the user wants options or the choice is genuinely close.

**Single mode.** Draft the message yourself in the recommended framework, following that
framework's spine and quality bar (from the Framework Reference, or the framework's own skill for
detail). Match the medium and length. Then go to Step 4.

**Panel mode (powerful when the framing is uncertain).** Draft the *same* message in 2–3 candidate
frameworks **in parallel** so the user can compare. Launch the `story-drafter` agent once per
framework in a **single message** with multiple `Task` calls so they run concurrently. Give each:

> "Raw material: {message}. Audience: {audience}. Desired outcome: {outcome}. Medium & length:
> {medium}. Draft this in the **{framework}** framework. Framework spine and rules: {paste the
> framework's one-paragraph spec from the Framework Reference}. Return only the finished draft
> plus one line on the single biggest risk of using this framing here."

Collect the drafts and present them side by side (Step 4).

### Step 4 — Tighten and deliver

Optionally sharpen the chosen draft with the `story-critic` agent (a single `Task` call): it
scores the draft on framework-fit, clarity, and impact, then returns a tightened version and
specific fixes. Use it for high-stakes messages (keynote, investor pitch, launch) or when the user
asks to "make it better".

Deliver the result cleanly:

```
Framework: {name}  — {one line on why it fits}

{the finished message, formatted for its medium}

Why this lands
  • {1–3 bullets: the specific move the framework makes for this audience}

Want it another way? I can draft it as {alternative framework} too, or tighten this one.
```

In **panel mode**, present each version under its framework name with a one-line trade-off, then
recommend one and ask which to keep or combine.

## Notes

- **The frame is a scaffold, not a cage.** Use it to structure the message, then write like a
  human. If a draft reads like a template with the blanks filled in, rewrite it in a natural voice.
- **One story, one job.** Don't stack frameworks in a single message. If the communication has two
  jobs (rally *and* decide), split it — a Golden Circle intro, then a Pyramid body — rather than
  blending them into mush.
- **Match length to the frame.** ABT is one breath; the Pixar Pitch is a paragraph; StoryBrand can
  be a whole landing page. Don't force a one-liner framework into a keynote or vice versa.
- **Composability.** For a known framework, invoke its skill directly. For a quick multi-frame read
  without the full workflow, ask for "panel mode". To audit an *existing* draft, hand it to
  `story-critic` with the framework it's aiming for.

## Framework Reference (one-paragraph specs for routing & briefing)

**Golden Circle** (Simon Sinek, *Start With Why*). Order: **Why → How → What.** Open with the
belief or purpose — *why this exists and why anyone should care* — before any product or feature.
Then **How** — the distinct approach or values that make the Why real. Then **What** — the tangible
offering as proof of the belief. People buy the Why, not the What. Best for vision, brand, and
rallying. Failure mode: leading with What (features) and never earning the Why.

**Pyramid Principle** (Barbara Minto). **Answer first, then grouped evidence.** State the single
governing thought (the recommendation/answer) up top. Support it with 3–5 mutually exclusive,
collectively exhaustive (MECE) arguments, each backed by data. Optionally open with SCQA:
Situation → Complication → Question → (your) Answer. Best for busy decision-makers who want the
bottom line now. Failure mode: building up to the point instead of leading with it.

**Pixar Pitch** (Emma Coats' story spine). **"Once upon a time ___. Every day ___. One day ___.
Because of that ___. Because of that ___. Until finally ___."** A setup, a stable status quo, an
inciting change, escalating consequences, and a new resolution. Best for transformation and
journey narratives — before/after, old world → new world. Failure mode: a flat list of facts with
no "One day" turn and no stakes.

**StoryBrand** (Donald Miller, SB7). **The customer is the hero; you are the guide.** A *character*
with a *problem* meets a *guide* (you — shown with empathy + authority) who gives them a *plan* and
a *call to action*, helping them avoid *failure* and reach *success*. Best for marketing, sales,
and value props. Failure mode: making your company the hero instead of the customer.

**What / So What / Now What** (Borton/Rolfe reflective model). **Fact → impact → action.**
*What:* what happened, observed neutrally. *So What:* why it matters — the impact and meaning.
*Now What:* the concrete recommended next step. Best for post-mortems, retros, incident reviews,
and status updates. Failure mode: stopping at "So What" with no clear "Now What" action.

**ABT — And, But, Therefore** (Randy Olson's narrative template). **Setup → tension → resolution
in three beats.** *And:* the agreed-upon context. *But:* the problem or twist that creates tension.
*Therefore:* the consequence, solution, or call to action. One sentence to a short paragraph;
lands a point in under 30 seconds. Best for hooks, elevator pitches, and openers. Failure mode:
"And, And, And" — all context, no tension, no turn.

## Limitations

These frameworks structure and sharpen a message; they don't supply substance. A well-framed weak
idea is still a weak idea. The skill reasons over what you tell it — it can't verify your facts,
know your audience better than you do, or guarantee persuasion. Treat the draft as a strong first
version to make yours, not a finished script to read verbatim.
