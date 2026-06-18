# Changelog

All notable changes to the Research Plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-06-18

### Added
- **storm-research skill** — User-invocable; orchestrates the full four-phase STORM pipeline:
  parallel five-persona fan-out, contradiction mapping, synthesis into a cited briefing, and an
  adversarial peer review with an optional revision loop. Each phase runs in a dedicated sub-agent
  so the heavy reading stays off the main context window.
- **multi-perspective-scan skill** — User-invocable; STORM Phase 1 standalone. Fans out the five
  persona agents in parallel for a fast multi-angle read of a topic.
- **contradiction-map skill** — User-invocable; STORM Phase 2 standalone. Maps disagreements,
  the reliable core of agreement, and blind spots across a workspace, a set of documents, or
  pasted viewpoints.
- **research-peer-review skill** — User-invocable; STORM Phase 4 standalone. Audits any research
  artifact for hallucinations, bias, completeness, fair contradiction handling, and actionability,
  then assigns a reliability grade.
- **Five persona agents** (Sonnet) — `practitioner`, `skeptic`, `economist`, `historian`,
  `academic`; each with an owned worldview and owned bias, gathering cited evidence via web search
  and writing a structured analysis to the run workspace.
- **contradiction-mapper agent** (Sonnet) — STORM Phase 2 analyst; finds contradictions with
  verdicts, the reliable core, and blind spots.
- **synthesizer agent** (Opus) — STORM Phase 3 analyst; weaves all lenses into one cited briefing
  with High/Medium/Low reliability ratings and concrete recommendations.
- **peer-reviewer agent** (Opus) — STORM Phase 4 auditor; closes STORM's known no-self-critique
  weakness with a five-dimension audit, spot-checked fact verification, and a reliability grade.
- Runs write to a reusable `.storm/{topic-slug}/` workspace (gitignored by default).
