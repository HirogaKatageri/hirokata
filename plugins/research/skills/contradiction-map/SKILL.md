---
name: contradiction-map
description: >
  Use this skill when the user wants to find where sources, viewpoints, or perspectives disagree
  — phrases like "contradiction map", "where do these disagree", "map the conflicts", "find the
  disagreements", "where do the experts clash", "compare these viewpoints", "what do they agree
  on", or "find the gaps nobody covered". Works on an existing STORM workspace
  (.storm/{slug}/), on a set of files/documents, or on viewpoints pasted into the conversation.
  Spawns the contradiction-mapper agent. This is STORM Phase 2 standalone.
version: 1.0.0
user-invocable: true
---

# Contradiction Map — Find Where Understanding Lives

The most valuable understanding lives where credible sources **disagree**. Consensus is
comfortable; contradiction is where the real questions are — and the angle nobody covered is
often the gap in the entire field. This skill maps disagreement, agreement, and blind spots
across any set of viewpoints. It's STORM Phase 2, usable on its own.

## When to Use vs. `storm-research`

Use this directly when you **already have** the viewpoints to compare:
- A prior `multi-perspective-scan` left a workspace at `.storm/{slug}/`
- The user has several documents, reports, or articles to reconcile
- The user pastes a handful of competing positions and wants them mapped

For generating the perspectives first, then mapping them, use `multi-perspective-scan` or the
full `storm-research`.

## Workflow

### Step 1 — Locate the Inputs

Determine what's being compared:
- **STORM workspace:** if `.storm/{slug}/` exists with perspective files, use those.
- **Files/documents:** the user names paths or a directory — gather the relevant files.
- **Pasted viewpoints:** the positions are in the conversation — you'll pass them to the agent
  directly in the prompt.

If the source is unclear, ask one question to pin it down. Establish (or derive) a topic label
and, for file-based runs, a workspace `.storm/{slug}/` for the output (`mkdir -p` it).

### Step 2 — Spawn the Contradiction Mapper

Launch the **contradiction-mapper** agent with one **Task** call:

> "Topic: **{topic}**. Workspace: `.storm/{slug}/`. Inputs: {list of files, OR the pasted
> viewpoints inline}. Read every input in full and write `.storm/{slug}/contradiction-map.md`
> per your output contract — major contradictions with verdicts, the reliable core of
> agreement, and the blind spots none of the inputs addressed."

For purely pasted viewpoints with no workspace, instruct the agent to return the map inline
instead of writing a file.

### Step 3 — Present the Map

Surface the highlights and point to the full artifact:

```
Contradiction Map — {topic}
============================
Top contradictions
  1. {dispute} — verdict: {stronger side / unresolved}
  2. {…}

Reliable core (independent lenses converge)
  • {insight}

⚠ Blind spots (addressed by none)
  • {missing angle — why it matters}

Full map: .storm/{slug}/contradiction-map.md
```

Then offer to continue to synthesis (a briefing) via `storm-research`, or to investigate a
specific contradiction further.

## Notes

- **Blind spots are the high-value output.** A question none of the sources raised may be a gap
  in the whole field, not just in this set — flag those prominently.
- **Verdicts, not just a catalog.** The map judges each contradiction (or declares it unresolved
  and says what would settle it). A bare list of differences is half the job.
