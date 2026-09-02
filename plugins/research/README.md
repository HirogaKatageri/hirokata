# Research Plugin

PhD-level, multi-perspective research inside Claude Code — inspired by Stanford's **STORM**
method (*Synthesis of Topic Outlines through Retrieval and Multi-perspective Question Asking*,
NAACL 2024, Stanford OVAL Lab).

A single prompt returns the **majority view** — one framing, the surface. STORM asks the same
topic from **five independent expert lenses**, maps where they fight, synthesizes a cited
briefing no single expert could write, then red-teams its own output. In Stanford's
peer-reviewed testing, multi-perspective articles were ~25% more organized and ~10% broader than
single-pass research.

This plugin operationalizes STORM as **dedicated sub-agents** — so the heavy reading runs in
parallel, off your main context window, and each persona stays in character instead of bleeding
into the others.

---

## Installation

```bash
/plugin install research@hirokata
```

---

## Quick Start

```
storm research lab-grown meat viability by 2030
```

That runs the full pipeline and leaves a complete research dossier in `.storm/{slug}/`.

---

## What's Inside

### The main skill

**`storm-research`** — the full four-phase pipeline:

```
Topic
 └─ Phase 1  FAN-OUT (parallel): practitioner · skeptic · economist · historian · academic
 └─ Phase 2  CONTRADICTION MAP: find clashes, agreement, and blind spots
 └─ Phase 3  SYNTHESIS: a cited research briefing with reliability ratings
 └─ Phase 4  PEER REVIEW: adversarial audit + reliability grade + ranked fixes
```

Trigger it with `storm research <topic>`, `run STORM on <topic>`, `deep research <topic>`,
`research <topic> from every angle`, or `brief me on <topic> before I decide`.

### Standalone skills (the reusable STORM patterns)

Each STORM phase is also useful on its own, so each is its own skill:

| Skill | Phase | Use when |
|---|---|---|
| **`multi-perspective-scan`** | 1 | You want a fast five-lens read, no full pipeline |
| **`contradiction-map`** | 2 | You already have viewpoints/sources to reconcile |
| **`research-peer-review`** | 4 | You want to audit *any* research, briefing, or argument |

They share the same `.storm/{slug}/` workspace, so a scan flows straight into a map, a briefing,
and a review without redoing work.

### The persona sub-agents (the five lenses)

| Agent | Model | Sees what others miss |
|---|---|---|
| **practitioner** | Sonnet | The theory–practice gap; what actually works in the field |
| **skeptic** | Sonnet | Overclaims, hidden flaws, the buried failure cases |
| **economist** | Sonnet | Who profits, who pays, the misaligned incentives |
| **historian** | Sonnet | The pattern that repeated before; where we are in the cycle |
| **academic** | Sonnet | What the evidence actually shows, including conflicting findings |

Each persona has an owned worldview *and an owned bias*, gathers real evidence via web search,
and writes a structured, cited analysis to the workspace.

### The analytical sub-agents (Phases 2–4)

| Agent | Model | Role |
|---|---|---|
| **contradiction-mapper** | Sonnet | Maps disagreements (with verdicts), the reliable core, and blind spots |
| **synthesizer** | Opus | Weaves all lenses into one cited briefing with reliability ratings |
| **peer-reviewer** | Opus | Adversarial audit: hallucination, bias, completeness, fairness, actionability |

---

## The Workspace

Every run writes to `.storm/{topic-slug}/`:

```
.storm/lab-grown-meat-viability/
├── practitioner.md        # raw perspective analyses (Phase 1)
├── skeptic.md
├── economist.md
├── historian.md
├── academic.md
├── contradiction-map.md   # where the lenses clash / agree / miss (Phase 2)
├── briefing.md            # the cited research briefing (Phase 3)
└── peer-review.md         # reliability grade + ranked fixes (Phase 4)
```

`.storm/` is gitignored by default. Re-running the same slug overwrites the prior artifacts —
copy a run elsewhere first if you want to keep it.

---

## Design Notes

**Why sub-agents instead of four pasted prompts?**
The popular "STORM in Claude" method is four sequential prompts pasted into one chat — which
floods a single context window and lets the personas blur together. Delegating each phase to a
dedicated agent keeps the main context clean, runs the five perspectives in *true* parallel, and
lets each lens stay sharply in character.

**Why the standalone skills?**
The STORM phases are reusable patterns in their own right. "Five lenses on a topic", "map where
these sources disagree", and "peer-review this research" are valuable far beyond a single
pipeline run — so each is a first-class skill that composes with the others.

**Why Opus for synthesis and review?**
Perspective and critique quality scale with reasoning ability. The personas run on Sonnet for
breadth and speed; the synthesizer and peer-reviewer run on Opus where the reasoning load is
highest. Adjust any agent's `model` in its frontmatter.

**Why a peer-review phase?**
Stanford's researchers flagged that STORM does not self-critique — source bias and fact
misassociation slip through. Phase 4 is the fix: an adversarial auditor that spot-checks claims,
detects bias, and grades reliability before you act on the briefing.

---

## Limitations

This plugin reasons over public sources and the model's knowledge. It cannot reach paywalled
literature, guarantee every citation, or replace domain expertise on high-stakes decisions. The
peer-review phase *reduces* but does not eliminate hallucination and bias. Treat the output as a
rigorous starting point, not a final authority.

---

## Credits

- **The "STORM in Claude" four-prompt method** — adapted from the X thread *"STORM in Claude: 4
  Prompts for PhD-Level Research in 5 Minutes"* by **Nav Toor** ([@heynavtoor](https://x.com/heynavtoor)),
  June 17, 2026 — [original post](https://x.com/heynavtoor/status/2067194761446920264). This plugin
  refines that method into parallel sub-agents and reusable skills.
- **The underlying STORM research method** — Stanford OVAL Lab, *Synthesis of Topic Outlines through
  Retrieval and Multi-perspective Question Asking* (NAACL 2024) —
  [github.com/stanford-oval/storm](https://github.com/stanford-oval/storm).

This plugin is an independent reimagining of the above as Claude Code skills and agents, not
affiliated with or endorsed by either source.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).

## Author

**Gian Patrick Quintana** — <gian.quintana@hirokata.dev> — [@HirogaKatageri](https://github.com/HirogaKatageri)
