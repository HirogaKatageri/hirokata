---
name: pyramid-principle
description: >
  Use this skill to structure a message with Barbara Minto's Pyramid Principle — answer first, then
  grouped evidence. Best for boards, executives, investors, and decision memos where the reader
  wants the bottom line now. Triggers on "pyramid principle", "minto", "bottom line up front",
  "BLUF", "structure this exec summary / board deck / decision memo", "make this investor update
  tighter", "lead with the answer", or "get to the point for leadership". Turns sprawling material
  into a governing thought supported by MECE arguments and data.
version: 1.0.0
user-invocable: true
---

# Pyramid Principle — Lead With the Answer

**Barbara Minto (McKinsey).** Busy decision-makers don't want your reasoning journey — they want
the conclusion, then the support if they choose to dig. So invert the natural order: **state the
answer first, then the grouped arguments, then the data underneath.** Ideas form a pyramid where
every level summarizes the level below.

```
              ┌──────────────────────────┐
              │   GOVERNING THOUGHT        │   the answer / recommendation
              └──────────────────────────┘
             ╱            │            ╲
     ┌──────────┐  ┌──────────┐  ┌──────────┐
     │ Argument │  │ Argument │  │ Argument │   3–5, MECE
     └──────────┘  └──────────┘  └──────────┘
       │  │  │        │  │  │        │  │  │
     data data      data data      data data     evidence
```

## The Structure

1. **Governing thought.** The single main message — usually a recommendation or answer. One
   sentence. Everything below exists to support it.
2. **Key arguments (3–5), MECE.** *Mutually Exclusive* (no overlap) and *Collectively Exhaustive*
   (nothing important missing). Each argument is itself a mini-conclusion, not a topic label.
3. **Evidence.** Data, facts, and examples supporting each argument. This is where detail lives —
   out of the reader's way until they want it.

**The SCQA opener** (optional but powerful) sets up the governing thought in a way the reader
already agrees with:
- **Situation** — the stable context everyone accepts.
- **Complication** — what changed or went wrong that demands a response.
- **Question** — the question the complication raises (often implicit).
- **Answer** — your governing thought. Then the pyramid unfolds beneath it.

## When to use it (and when not)

**Use it for:** board and exec presentations, investor updates, decision and recommendation memos,
strategy docs, executive summaries, any "we need a yes/no" moment.

**Reach for something else when:** you want to inspire or set a vision (→ `golden-circle`), you're
telling a transformation story (→ `pixar-pitch`), or you need a 30-second hook (→ `abt`). The
Pyramid is for clarity and decisions, not for emotion.

## How to build it

1. **Write the governing thought first.** If you can't state your answer in one sentence, you're not
   ready to present.
2. **Group your reasons into 3–5 MECE buckets.** Test each pair: do they overlap? Together, do they
   cover the case? Fix gaps and overlaps before writing prose.
3. **Make each argument a claim, not a category.** "Cost" is a label; "It pays back in 9 months" is
   an argument.
4. **Push detail down.** Data supports arguments; it never competes with them at the top.
5. **Add an SCQA lead-in** if the reader needs context to feel the question before the answer.

## Worked example

**Raw material:** notes arguing to migrate off a legacy billing system — reliability incidents,
engineer time lost, a vendor price hike, a 9-month payback.

**As a Pyramid:**
> **(S)** Billing runs on a system we've used for eight years. **(C)** It caused three revenue-
> impacting outages last quarter and the vendor just raised prices 40%. **(Q)** *[Do we keep
> patching it or replace it?]* **(A — governing thought):** We should replace it this year; it pays
> for itself in nine months.
> 1. **It's costing us revenue.** Three outages last quarter, ~$180k in delayed invoices.
> 2. **It's costing us engineering.** ~30% of platform time goes to keeping it alive.
> 3. **The economics now favor replacement.** The 40% price hike closes the payback gap to 9 months.

Three arguments, no overlap, covering revenue, cost, and timing — MECE.

## Quality bar / common mistakes

- **Burying the lead.** If the recommendation shows up on slide 12, restructure. Answer first.
- **Topic labels instead of arguments.** Each supporting point must assert something, not name a
  theme.
- **Not MECE.** Overlapping points feel repetitive; gaps get exposed in Q&A. Pressure-test the set.
- **Data at the top.** A wall of numbers before the point makes the reader do your synthesis. Lead
  with the conclusion, keep the numbers underneath.

## Compose

- Have the `story-drafter` agent draft in this framework (the `storytelling` skill uses it for
  parallel comparison).
- Audit an existing draft with the `story-critic` agent, targeting `pyramid-principle`.
- Not sure this is the right frame? Start from the `storytelling` skill and let it recommend.
