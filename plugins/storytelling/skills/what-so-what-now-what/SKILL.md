---
name: what-so-what-now-what
description: >
  Use this skill to structure a message as What / So What / Now What — state the fact, explain the
  impact, recommend the action. Best for post-mortems, retros, incident reviews, status updates,
  debriefs, and any "here's what happened and what we should do" moment. Triggers on "what so what
  now what", "structure this post-mortem / retro / incident review / status update", "help me
  debrief <X>", "what's the takeaway and action", or "run this post-mortem cleanly". Turns raw
  observations into a crisp fact → impact → action arc.
version: 1.0.0
user-invocable: true
---

# What / So What / Now What — Fact, Impact, Action

**The Borton/Rolfe reflective model.** Three questions, asked in order, turn a pile of observations
into a decision. It keeps debriefs from drifting into blame or rambling: separate *what happened*
from *what it means* from *what we do next*, and each stays clean.

```
   WHAT            →     SO WHAT           →     NOW WHAT
   the fact              the impact              the action
   (observe)            (interpret)             (decide)
   neutral, specific     why it matters          concrete next step
```

## The Three Moves

1. **What — the fact.** What happened, observed neutrally and specifically. Data, events, the
   observable record. **No interpretation and no blame yet** — just the ground truth everyone can
   agree on.
2. **So What — the impact.** Why it matters. The consequences, the meaning, the significance. What
   did this cost / risk / reveal? This is the analysis layer — connect the fact to something the
   audience cares about.
3. **Now What — the action.** The concrete recommendation or next step. Specific, owned, and
   time-bound where possible. This is the payoff; a debrief without a "Now What" is just a
   complaint.

## When to use it (and when not)

**Use it for:** post-mortems and incident reviews, sprint retros, project debriefs, status updates,
research/experiment readouts, performance conversations, "lessons learned" write-ups.

**Reach for something else when:** you're pitching or selling (→ `storybrand`, `abt`), inspiring on
vision (→ `golden-circle`), or presenting a decision to a board (→ `pyramid-principle`, which leads
with the recommendation rather than building to it). This frame is for *reflection that produces
action*.

## How to build it

1. **Separate the layers ruthlessly.** Keep opinion out of "What" and keep facts from re-litigating
   in "Now What". Mixing them is what makes debriefs go sideways.
2. **Make "What" blameless and specific.** "The deploy at 14:02 dropped the checkout service for 18
   minutes," not "someone broke prod."
3. **Make "So What" quantify impact** where you can — cost, users affected, risk, what it exposed.
4. **Make "Now What" an owned action**, not a vague intention. "X will add a deploy check by Friday,"
   not "we should be more careful."
5. **Repeat the trio per finding** for a multi-point review; keep each self-contained.

## Worked example

**Raw material:** a checkout outage after a deploy, caused by an untested config change.

**As What / So What / Now What:**
> **What:** At 14:02 a config change was deployed that pointed checkout at the wrong payment
> endpoint. Checkout returned errors for 18 minutes until we rolled back.
> **So What:** ~1,200 customers hit a failed checkout; we estimate ~$14k in abandoned carts and a
> spike in support tickets. It also revealed that config changes bypass our staging tests entirely.
> **Now What:** (1) Priya adds config changes to the staging test gate by Friday. (2) We add a
> checkout smoke test to the deploy pipeline this sprint. (3) Rollback runbook gets linked in the
> deploy channel today.

Facts everyone accepts, an impact that's quantified, and actions with owners — no blame, all signal.

## Quality bar / common mistakes

- **Interpretation smuggled into "What".** If a reader could disagree with your "What", it's not a
  fact yet — move the opinion to "So What".
- **Stopping at "So What".** Analysis with no action is the most common failure. Always land the
  "Now What".
- **Vague "Now What".** "We should improve testing" isn't an action. Name who, what, and by when.
- **Blame instead of system.** Good debriefs fix the system, not the person. Keep "What" neutral.

## Compose

- Have the `story-drafter` agent draft in this framework (the `storytelling` skill uses it for
  parallel comparison).
- Audit an existing draft with the `story-critic` agent, targeting `what-so-what-now-what`.
- Not sure this is the right frame? Start from the `storytelling` skill and let it recommend.
