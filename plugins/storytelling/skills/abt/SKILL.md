---
name: abt
description: >
  Use this skill to structure a message as ABT — And, But, Therefore: setup, tension, resolution in
  three beats. Best for elevator pitches, one-liners, hooks, openers, and landing a point in under
  30 seconds. Triggers on "abt", "and but therefore", "elevator pitch", "one-liner", "give me a
  hook", "make this punchy", "tighten this to one sentence", or "how do I open this". Turns raw
  material into a single tight arc: agreement → problem → solution.
version: 1.0.0
user-invocable: true
---

# ABT — And, But, Therefore

**Randy Olson's narrative template** (from *Houston, We Have a Narrative*), distilled from the shape
underneath most great storytelling. Three words carry the whole arc: **And** (setup), **But**
(tension), **Therefore** (resolution). It's the fastest way to make a point *feel like a story*
instead of a list — and it fits in one breath.

```
   AND            BUT             THEREFORE
   setup    →     tension    →    resolution
   agreement      the problem     the solution / action
   "here's        "here's what    "here's what
    the world"     went wrong"     we do about it"
```

## The Three Beats

1. **And — the setup.** The context everyone already agrees on. The stable "here's how things are."
   (Often *implied* rather than starting with the literal word "and".)
2. **But — the tension.** The problem, twist, or conflict that breaks the agreement. **This is the
   engine.** No "but", no story — just a list of facts.
3. **Therefore — the resolution.** What follows: the consequence, the solution, the call to action.
   The payoff the tension set up.

The post frames it as **Agreement → Problem → Solution.** Same three beats.

## When to use it (and when not)

**Use it for:** elevator pitches, cold-email openers, headlines, the first line of a talk or memo,
a Slack message that needs to land fast, boiling any longer story down to its spine.

**Reach for something else when:** you have room to build an arc (→ `pixar-pitch`), you're
presenting a full decision (→ `pyramid-principle`), or you're writing conversion copy (→
`storybrand`). ABT is the compression format — it's a scalpel, not a canvas.

## How to build it

1. **Find the "But".** Start here — the tension is the whole point. If there's no conflict,
   twist, or problem, there's no story to tell.
2. **Set up only what the "But" needs.** Keep "And" to the minimum context that makes the tension
   land. Over-long setup kills the pace.
3. **Let "Therefore" pay off the exact tension** you raised — the solution should answer *that*
   problem, not a different one.
4. **Test for "And, And, And".** If you can't find a "But", you have information, not a story. Keep
   digging for the tension.
5. **Say it out loud.** ABT should sound natural in one breath. Trim until it does.

## Worked examples

**A product pitch:**
> "Finance teams have more data than ever, **and** the tools to store it, **but** they still lose
> nights hand-building reports every month-end — **therefore** we built analytics that assemble the
> report for them, so month-end takes minutes, not days."

**A strategy point:**
> "We doubled signups this quarter, **but** activation stayed flat — **therefore** our next bet is
> onboarding, not acquisition."

**Compressed to a hook:**
> "Everyone's adding AI features, but nobody's asking if users want them — so we did."

## Quality bar / common mistakes

- **"And, And, And."** All setup, no tension. This is the #1 failure — a pile of facts with no
  turn. Find the "But".
- **A "But" that doesn't connect.** The tension must contradict or complicate the setup, not
  introduce an unrelated fact.
- **A "Therefore" that doesn't resolve *that* tension.** The payoff must answer the specific problem
  you raised.
- **Too much setup.** The longer the "And", the weaker the punch. Compress.

## Compose

- Have the `story-drafter` agent draft in this framework (the `storytelling` skill uses it for
  parallel comparison).
- Audit an existing draft with the `story-critic` agent, targeting `abt`.
- Not sure this is the right frame? Start from the `storytelling` skill and let it recommend.
