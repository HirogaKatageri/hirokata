---
name: research-peer-review
description: >
  Use this skill when the user wants to rigorously audit a piece of research, a briefing, a
  report, or an argument before relying on it — phrases like "peer review this", "self-critique
  this", "audit my research", "red team this report", "fact-check this", "find the weak claims",
  "is this trustworthy", "grade this research", "what's wrong with this analysis", or "review my
  briefing for bias". Spawns the peer-reviewer agent to run a fact-check & hallucination audit,
  bias detection, completeness check, contradiction-handling check, and actionability review,
  then assign a reliability grade. This is STORM Phase 4 standalone.
version: 1.0.0
user-invocable: true
---

# Research Peer Review — Audit Before You Rely

Every confident research output hides weak claims, quiet biases, and missing angles. STORM's own
documented weakness is that it doesn't self-critique — so source bias and *fact misassociation*
(a real source bolted to a claim it doesn't actually make) slip through. This skill is the fix,
usable on **any** research artifact, not just STORM output. Real peer review takes months; this
runs an honest, adversarial version in minutes.

## What It Checks

1. **Fact-check & hallucination audit** — unsupported, exaggerated, or fabricated claims;
   citations that don't support what they're attached to; spot-checked against live sources.
2. **Bias detection** — over-/under-represented views; default tilt toward mainstream/academic framing.
3. **Completeness** — missing angles, stakeholders, counterexamples, recent developments.
4. **Contradiction handling** — was dissent represented fairly, or quietly buried? Are reliability
   ratings honest?
5. **Actionability & clarity** — are conclusions specific and justified, or vague and overstated?

Output: a dimension-by-dimension assessment, a ranked list of required fixes, and an overall
**reliability grade (A–F)**.

## Workflow

### Step 1 — Locate the Artifact

Identify what to review:
- **STORM briefing:** `.storm/{slug}/briefing.md` (with its perspective files and contradiction
  map as supporting evidence).
- **A document/report:** the user names a path or pastes the content.
- **An argument in the conversation:** the claims are already in context.

Establish a topic label and, for file-based runs, the workspace `.storm/{slug}/` for the output.
If the target is ambiguous, ask one question to pin it down.

### Step 2 — Spawn the Peer Reviewer

Launch the **peer-reviewer** agent with one **Task** call:

> "Topic: **{topic}**. Review {artifact path OR pasted content} across all five dimensions.
> Supporting evidence (if present): {perspective files, contradiction map}. Spot-check the
> highest-stakes claims with WebSearch/WebFetch before flagging. Write
> `.storm/{slug}/peer-review.md` with a reliability grade and ranked required fixes."

For pasted content with no workspace, instruct the agent to return the review inline.

### Step 3 — Present the Verdict

```
Peer Review — {topic}
=====================
Grade: {A–F}  |  Reliability: {High/Medium/Low}
Verdict: {would you trust this to make a real decision? why}

Required fixes (ranked)
  1. {must-fix — what's wrong, how to fix}
  2. {…}

Top factual flags
  • ⚠ {claim} — {issue, spot-check result}

Full review: .storm/{slug}/peer-review.md
```

### Step 4 — Offer to Act on It

If reviewing a STORM briefing graded C or below (or with high-severity factual flags), offer a
revision pass: feed the review back to the `synthesizer` to fix the ranked issues, then re-review.
For external documents, offer to draft the fixes or hand the reviewer's notes back to the user.

## Notes

- **Specific, named flags only.** "Some claims are weak" is noise; the reviewer quotes the claim,
  locates it, and states the problem — and spot-checks the important ones rather than just
  suspecting.
- **Honest grading.** The reviewer does not default to a pass. If the artifact would mislead a
  decision-maker, it says so and grades down.
- This skill audits and recommends; it does not silently rewrite the source. Fixes are applied
  only on a follow-up the user approves.
