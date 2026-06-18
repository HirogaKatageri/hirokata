---
name: storm-research
description: >
  Use this skill when the user wants deep, PhD-level, multi-perspective research on a topic
  and says things like "storm research <topic>", "run STORM on <topic>", "deep research
  <topic>", "research <topic> from every angle", "multi-perspective deep dive", "give me a
  PhD-level briefing on <topic>", "research <topic> properly", "I need to really understand
  <topic>", or "brief me on <topic> before I decide/invest/write/present". Orchestrates five
  expert persona agents, a contradiction map, a synthesized cited briefing, and an adversarial
  peer review. Inspired by Stanford's STORM method.
version: 1.0.0
user-invocable: true
---

# STORM Research — Multi-Perspective Deep Research Orchestrator

Run the full STORM pipeline on a topic. One prompt asks one question and returns the majority
view — the surface. STORM asks the same topic from **five independent expert lenses**, maps
where they fight, synthesizes a briefing no single expert could write, then red-teams its own
output. In Stanford's peer-reviewed testing, multi-perspective articles were ~25% more
organized and ~10% broader than single-pass research. This skill operationalizes that with
dedicated sub-agents so the heavy reading happens off the main context window.

## The Pipeline

```
Topic
 └─ Phase 1  FAN-OUT (parallel): practitioner · skeptic · economist · historian · academic
 └─ Phase 2  CONTRADICTION MAP: contradiction-mapper reads all 5 → finds clashes/agreement/gaps
 └─ Phase 3  SYNTHESIS: synthesizer reads 5 + map → cited research briefing
 └─ Phase 4  PEER REVIEW: peer-reviewer audits the briefing → reliability grade + fixes
 └─ Present consolidated result to the user
```

## Workflow

### Step 0 — Scope the Topic

1. **Get the topic.** If the user supplied one (`storm research <topic>`), use it. If it's vague
   or sprawling (e.g. "AI", "the economy"), ask **one** sharpening question to narrow it — a
   tight topic produces a far better briefing than a broad one.
2. **Capture the audience and angle if offered** (deciding / investing / writing / presenting /
   learning). It tunes the synthesizer's recommendations. Don't interrogate — one optional ask.
3. **Derive a slug** (lowercase, hyphenated, canonical: e.g. `lab-grown-meat-viability`).
4. **Set the workspace:** `.storm/{slug}/`. Create it: `mkdir -p .storm/{slug}`.

### Step 0.5 — Tune the Panel (optional, powerful)

The five default personas fit most topics. For some topics, a swap sharpens the analysis —
e.g. add a **Clinician** for a medical topic, a **Regulator** for a policy topic, an **End User**
for a product topic. If a swap clearly helps, mention it to the user and spawn the extra persona
with the **Task** tool using the same output contract as the built-in agents (worldview + owned
bias + evidence-gathering + structured file with sources). Keep the panel at 5–6; more dilutes.
Default to the standard five if unsure.

### Step 1 — Fan Out the Five Perspectives (parallel)

Launch all five persona agents in a **single message** with five **Task** tool calls so they run
concurrently. Give each the topic, the workspace path, and its output filename. Example prompt
per agent:

> "Topic: **{topic}**. Workspace: `.storm/{slug}/`. Write your analysis to
> `.storm/{slug}/{persona}.md` following your output contract. Audience for downstream use:
> {audience}. Gather real evidence with WebSearch/WebFetch and cite it."

- `practitioner` → `.storm/{slug}/practitioner.md`
- `skeptic` → `.storm/{slug}/skeptic.md`
- `economist` → `.storm/{slug}/economist.md`
- `historian` → `.storm/{slug}/historian.md`
- `academic` → `.storm/{slug}/academic.md`

Each agent writes its own file and returns only a one-line confirmation, keeping your context
lean. **If a persona agent fails,** note it and continue — the pipeline degrades gracefully with
four perspectives; tell the downstream agents which files exist.

### Step 2 — Map the Contradictions

When all perspective files exist, spawn the **contradiction-mapper** agent (single Task call):

> "Topic: **{topic}**. Workspace: `.storm/{slug}/`. Read the perspective files that exist
> ({list}) and write `.storm/{slug}/contradiction-map.md` per your output contract."

### Step 3 — Synthesize the Briefing

Spawn the **synthesizer** agent (single Task call):

> "Topic: **{topic}**. Workspace: `.storm/{slug}/`. Read all perspective files and
> `contradiction-map.md`; write the research briefing to `.storm/{slug}/briefing.md`.
> Audience: {audience}. Carry citations forward."

### Step 4 — Peer Review (close STORM's blind spot)

Spawn the **peer-reviewer** agent (single Task call):

> "Topic: **{topic}**. Workspace: `.storm/{slug}/`. Audit `briefing.md` against the perspective
> files and contradiction map; spot-check shaky claims with WebSearch; write
> `.storm/{slug}/peer-review.md` with a reliability grade and ranked fixes."

### Step 4.5 — Optional Revision Loop

If the peer review returns a grade of **C or below**, or flags high-severity factual problems,
offer the user a single revision pass: re-spawn the synthesizer with the peer review attached and
instructions to fix the ranked issues, then re-run the peer review. Do this only if the user
wants it — don't loop unprompted.

### Step 5 — Present the Result

Read `briefing.md` and `peer-review.md` and present a tight consolidated summary in chat (not the
full files — point to them):

```
STORM Research Complete — {topic}
==================================
Workspace: .storm/{slug}/

Reliability grade: {grade} ({High/Medium/Low})

Headline finding
  {1–2 sentences from the executive summary}

Central tension
  {the key contradiction and how to think about it}

Top recommendation
  {the headline action, tuned to the audience}

⚠ Peer-review flags
  • {top 1–3 required fixes, if any}

Artifacts
  • .storm/{slug}/briefing.md          ← the full cited briefing
  • .storm/{slug}/contradiction-map.md ← where the experts disagree
  • .storm/{slug}/peer-review.md       ← reliability audit + fixes
  • .storm/{slug}/{persona}.md ×5      ← raw perspective analyses
```

Then ask whether they want the full briefing inline, a revision pass, or a deeper dive on any
single perspective.

## Notes

- **Why sub-agents, not four prompts?** The original STORM-in-Claude method is four sequential
  pastes that flood one context window. Delegating each phase to a dedicated agent keeps the main
  context clean, runs the five perspectives in true parallel, and lets each persona stay in
  character without bleeding into the others.
- **Model choice matters.** Perspective quality scales with reasoning ability — the personas run
  on Sonnet, the synthesizer and peer-reviewer on Opus. Adjust in the agent frontmatter if needed.
- **The workspace is reusable.** Re-running on the same slug overwrites prior artifacts. Copy a run
  elsewhere before re-running if you want to keep it. `.storm/` is gitignored by default.
- **Partial use.** For just the five views, use the `multi-perspective-scan` skill; for just the
  contradiction map or just an audit of existing research, use `contradiction-map` or
  `research-peer-review`.

## Limitations

This skill researches and reasons over public sources and the model's knowledge; it cannot access
paywalled literature, guarantee every citation, or replace domain expertise for high-stakes
decisions. The peer-review phase reduces — but does not eliminate — hallucination and bias. Treat
the briefing as a rigorous starting point, not a final authority.
