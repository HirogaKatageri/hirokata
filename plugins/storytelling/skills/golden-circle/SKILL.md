---
name: golden-circle
description: >
  Use this skill to structure a message with Simon Sinek's Golden Circle — Why → How → What. Best
  for rallying a team, framing a brand or mission, launching a company or product with meaning, or
  any "why we exist" moment. Triggers on "golden circle", "start with why", "help me articulate our
  why", "make our mission compelling", "frame our vision", "rally the team around <X>", or "why
  should anyone care about <X>". Turns raw material into a Why-first narrative that earns belief
  before it names features.
version: 1.0.0
user-invocable: true
---

# Golden Circle — Start With Why

**Simon Sinek, *Start With Why* (2009).** "People don't buy *what* you do; they buy *why* you do
it." Most messages start at the outside of the circle — *What* we make — and never reach the
center. Inspiring ones start at the center and work out: **Why → How → What.**

```
        ┌─────────────┐
        │    WHY       │   the belief / purpose / cause
        │  ┌───────┐   │
        │  │ HOW   │   │   the distinct approach that makes it real
        │  │ ┌───┐ │   │
        │  │ │WHAT│ │   │   the tangible offering — proof of the belief
        │  │ └───┘ │   │
        │  └───────┘   │
        └─────────────┘
```

## The Three Rings

1. **WHY — the purpose.** Not "to make money" (that's a result). The belief, cause, or conviction
   that makes this worth doing. Why does this exist? Why should anyone care? This is emotional and
   comes first.
2. **HOW — the differentiators.** The specific values, principles, or approach that bring the Why
   to life and set you apart. The "how we're different, and why that follows from the Why."
3. **WHAT — the proof.** The products, services, features, or results. Real and concrete, but framed
   as *evidence of the Why*, not as the headline.

## When to use it (and when not)

**Use it for:** vision and mission statements, brand and company narratives, product launches that
need meaning, keynotes, recruiting and rallying a team, investor "why now / why us" framing.

**Reach for something else when:** the audience wants a decision *now* (→ `pyramid-principle`), it's
a debrief or status update (→ `what-so-what-now-what`), or you need a fast one-line hook
(→ `abt`). The Golden Circle earns belief; it is not the fastest path to a yes.

## How to build it

1. **Find the real Why.** Ask "why does this matter?" repeatedly until you hit a belief, not a
   feature. Test: your Why should still be true if the product changed.
2. **Derive How from Why.** The differentiators must *follow* from the belief — 2–4 of them.
3. **Attach What as proof.** List the concrete offering, framed as the belief made tangible.
4. **Write it Why-first.** Open with the belief. Let How and What land as the natural consequence.

## Worked example

**Raw material:** "We sell project-management software with Gantt charts and time tracking."

**As a Golden Circle:**
> **Why:** We believe teams do their best work when the plan gets out of the way — that people
> should spend their energy on the work, not on managing the tool that manages the work.
> **How:** So we design for one-glance clarity: every view answers "what's next and who's blocked"
> without a manual, and the software does the busywork of updating itself.
> **What:** That's why our Gantt charts rebuild themselves as reality changes, and time tracking
> happens in the background — proof that the plan should serve the team, not the other way around.

Notice the features arrive *last*, as evidence — and now they mean something.

## Quality bar / common mistakes

- **Leading with What.** If your first sentence is a feature or a product name, you've started at
  the wrong ring. Rewrite so belief comes first.
- **A Why that's really a What.** "To be the market leader" or "to grow revenue" are outcomes, not
  purposes. Keep asking why until you reach a conviction.
- **How that doesn't follow from Why.** The differentiators must be consequences of the belief, not
  a random feature list wearing a values costume.
- **Belief with no proof.** Inspiration without a concrete What feels like empty mission-speak.
  Ground it.

## Compose

- Have the `story-drafter` agent draft in this framework (the `storytelling` skill uses it for
  parallel comparison).
- Audit an existing draft with the `story-critic` agent, targeting `golden-circle`.
- Not sure this is the right frame? Start from the `storytelling` skill and let it recommend.
