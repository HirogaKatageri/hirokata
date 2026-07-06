# Changelog

All notable changes to the Storytelling Plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-07-03

### Added
- **storytelling skill** — User-invocable router and coach. Captures the message, audience, desired
  outcome, and medium; recommends the framework that fits using a decision guide; then drafts the
  message. Supports **single mode** (draft directly) and **panel mode** (draft 2–3 frameworks in
  parallel via the `story-drafter` agent for side-by-side comparison), with an optional sharpening
  pass through the `story-critic`. Includes a self-contained one-paragraph spec for each of the six
  frameworks for routing and briefing.
- **golden-circle skill** — Simon Sinek's Why → How → What. For vision, brand, and rallying.
- **pyramid-principle skill** — Barbara Minto's answer-first structure with MECE arguments and an
  optional SCQA opener. For boards, execs, and decision memos.
- **pixar-pitch skill** — Emma Coats' story spine (Once upon a time → Every day → One day → Because
  of that → Until finally). For transformation and journey narratives.
- **storybrand skill** — Donald Miller's SB7 (customer as hero, brand as guide). For marketing,
  sales, and value props.
- **what-so-what-now-what skill** — The Borton/Rolfe reflective model (fact → impact → action). For
  post-mortems, retros, and status updates.
- **abt skill** — Randy Olson's And, But, Therefore (setup → tension → resolution). For elevator
  pitches, one-liners, and hooks.
  - Each framework skill is user-invocable and includes the spine/template, when-to-use guidance, a
    worked example, and a quality bar of common failure modes.
- **story-drafter agent** (Sonnet) — Drafts a message in one specified framework, fitted to audience,
  outcome, and medium. Spawned in parallel for panel-mode comparison; returns the draft inline and
  never invents facts (uses `[placeholder: …]` instead).
- **story-critic agent** (Opus) — Audits a draft against its target framework and audience, scores
  framework-fit / clarity / impact, and returns a tightened rewrite. Used for high-stakes messages.

### Notes
- Inspired by Eric Partaker's LinkedIn post on six CEO storytelling frameworks. The frameworks are the
  publicly documented work of Simon Sinek, Barbara Minto, Emma Coats, Donald Miller, Borton/Rolfe,
  and Randy Olson. This plugin is an independent implementation, not affiliated with or endorsed by
  any of them.
