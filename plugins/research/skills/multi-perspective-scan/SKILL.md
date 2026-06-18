---
name: multi-perspective-scan
description: >
  Use this skill when the user wants a fast multi-angle read of a topic without the full STORM
  pipeline — phrases like "multi-perspective scan", "give me 5 perspectives on <topic>",
  "analyze <topic> from multiple angles", "what would different experts say about <topic>",
  "perspective scan", "5 expert views", "steelman the different takes on <topic>", or
  "what are the different viewpoints on <topic>". Fans out the five STORM persona agents
  (practitioner, skeptic, economist, historian, academic) in parallel and presents their views.
  This is STORM Phase 1 standalone — the reusable heart of the method.
version: 1.0.0
user-invocable: true
---

# Multi-Perspective Scan — The Five Lenses, Standalone

When you ask one question, you get the **majority view** — one framing, the surface. The
breakthrough behind Stanford's STORM is simple: ask the same topic from **five independent
expert lenses** and you catch the blind spots a single pass never sees. This skill runs just
that fan-out — fast, when you don't need the full contradiction map / synthesis / peer-review
pipeline (for that, use `storm-research`).

The five lenses, and what each uniquely catches:

| Lens | Sees what others miss |
|---|---|
| **Practitioner** | The theory–practice gap; what actually works in the field |
| **Skeptic** | Overclaims, hidden flaws, the buried failure cases |
| **Economist** | Who profits, who pays, the misaligned incentives |
| **Historian** | The pattern that repeated before; where we are in the cycle |
| **Academic** | What the evidence actually shows, including conflicting findings |

## Workflow

### Step 0 — Scope

1. **Get the topic.** If vague or sprawling, ask one sharpening question. A tight topic yields
   sharper perspectives.
2. **Derive a slug** and **set the workspace** `.storm/{slug}/`. Create it: `mkdir -p .storm/{slug}`.
3. **Tune the panel if a swap clearly helps** (e.g. add a Clinician / Regulator / End User via a
   Task call using the same persona output contract). Default to the standard five.

### Step 1 — Fan Out (parallel)

Launch all five persona agents in a **single message** with five **Task** calls. Each gets the
topic, the workspace path, and its output file. Per-agent prompt:

> "Topic: **{topic}**. Workspace: `.storm/{slug}/`. Write your analysis to
> `.storm/{slug}/{persona}.md` per your output contract. Gather real evidence with
> WebSearch/WebFetch and cite it."

Targets: `practitioner.md`, `skeptic.md`, `economist.md`, `historian.md`, `academic.md`.
Each agent writes its file and returns a one-line confirmation. If one fails, note it and
continue with the rest.

### Step 2 — Present the Five Views

Read the five files and present a compact digest — the bottom line and 2–3 sharpest insights per
lens, plus where you already see them diverging:

```
Multi-Perspective Scan — {topic}
=================================
Workspace: .storm/{slug}/

🛠  Practitioner — {bottom line}
    • {top insight}  • {top insight}
🔍  Skeptic — {bottom line}
    • {top flaw [FATAL/CAVEAT]}  • {…}
💰  Economist — {bottom line}
    • {top incentive}  • {…}
📜  Historian — {bottom line}
    • {top parallel}  • {…}
🎓  Academic — {bottom line}
    • {top finding [STRONG/MIXED/…]}  • {…}

Early signal: {one line on the most interesting disagreement you already notice}

Full analyses: .storm/{slug}/{persona}.md
```

### Step 3 — Offer the Next Step

Suggest the natural follow-ups:
- **Map where they disagree** → run `contradiction-map` on this workspace
- **Go all the way to a briefing** → run `storm-research` (adds synthesis + peer review)
- **Drill into one lens** → ask that persona a follow-up

## Notes

- This is intentionally lighter than `storm-research`: five views, no synthesis. Use it to scan
  fast, then escalate only if the topic warrants the full pipeline.
- The workspace it produces is directly consumable by `contradiction-map` and `storm-research`
  (Phases 2–4), so a scan is never wasted work.
