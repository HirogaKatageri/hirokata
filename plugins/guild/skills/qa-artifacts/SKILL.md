---
name: qa-artifacts
description: >
  Pre-loaded QA artifact formats for the qa-strategist and qa-tester agents.
  Defines the evergreen `.guild/qa/` files — charter (quality definition, risk map,
  coverage matrix, oracle ledger), missions (scope, what-if input matrix, oracle
  sources), the bug ledger, session logs, and the regression manifest that points
  at committed e2e specs in the repo. Load this skill before writing any QA
  artifact. Trigger phrases include "qa artifacts", "qa charter", "qa mission",
  "bug ledger", "regression manifest", "qa session log".
version: 1.0.0
---

# QA Artifacts & File Formats

The QA discipline keeps its persistent state under `.guild/qa/`. These artifacts
are **evergreen** — like `.guild/docs/`, they survive releases and `clear-board`.
Committed test specs do NOT live here; they live in the project's real e2e dir and
run in CI. `.guild/qa/` holds the *thinking and the index*, not the test code.

```
.guild/qa/
  charter.md            # strategist: what quality means + risk map + coverage matrix
  missions/             # strategist: one MISSION-{slug}.md per feature area
  sessions/             # tester: one SESSION-{slug}-{date}.md per run
  ledger.md             # tester: standing bug ledger (known issues + status)
  regression.md         # tester: manifest pointing at committed specs in the repo
```

## charter.md (qa-strategist, evergreen — update in place)

```markdown
---
title: "QA Charter"
requirement: REQ-NNN
created: {original date}
last-updated: {today}
---

# QA Charter

## Quality Definition
{What "good" means for this product — the qualities that matter and why.}

## Risk Map
| Area | Likelihood | Impact | Risk | Notes |
|------|-----------|--------|------|-------|
| Checkout | high | high | critical | payment + money movement |
| Auth | medium | high | high | session/expiry edge cases |
| Marketing pages | low | low | low | smoke only |

## Coverage Matrix
| Area | Scenario classes to cover | Depth |
|------|---------------------------|-------|
| Checkout | happy path, payment failure, input matrix, concurrency | full |
| Auth | login, logout, expiry, wrong-role, IDOR | full |
| Marketing pages | renders, links resolve | smoke |

## Oracle Ledger
| Area | Oracle source | Open questions |
|------|---------------|----------------|
| Checkout | REQ-003 + Linear PAY-12 | refund window unclear |
| Auth | code + running app | empty-email behavior — ask user |
```

## missions/MISSION-{slug}.md (qa-strategist, self-contained)

```markdown
---
id: MISSION-checkout
area: Checkout
requirement: REQ-NNN
risk: critical
created: {today}
---

# Mission: Checkout

## Scope
{What's in / out of this mission.}

## User Journeys
1. {Journey — steps a real user takes}
2. ...

## What-If Input Matrix
| Field / step | Cases to exercise | Expected | Oracle |
|--------------|-------------------|----------|--------|
| Card number | valid, invalid, empty, boundary | … | REQ-003 |
| Quantity | 0, 1, max, max+1, negative | … | code (open: negative?) |

## Regression Candidates
{Which confirmed-good scenarios warrant a committed e2e spec, by risk.}

## Open Oracle Questions
- {Ambiguous behavior the tester must confirm with the user at run time.}
```

## ledger.md (qa-tester, evergreen — append, update status)

```markdown
# QA Bug Ledger

## BUG-{slug} — {short title}
- **Status:** open | fix-filed | fixed | wontfix
- **Severity:** critical | major | minor
- **Area:** {feature area}
- **Found:** {date} (SESSION-{slug}-{date})
- **Repro:**
  1. {step}
  2. {step}
- **Expected:** {what should happen + oracle source}
- **Actual:** {what happens}
- **Fix task:** TASK-NNN (once filed)
```

Severity: **critical** = crash / data loss / money or security impact;
**major** = wrong result or broken flow; **minor** = unlikely or cosmetic.

## sessions/SESSION-{slug}-{date}.md (qa-tester, per run)

```markdown
---
mission: MISSION-checkout
date: {today}
---

# QA Session: Checkout — {date}

## Scenarios Run
| Scenario | Expected | Actual | Verdict |
|----------|----------|--------|---------|
| valid card checkout | order placed | order placed | pass → spec authored |
| quantity = 0 | rejected | order placed for 0 | BUG-zero-qty |

## Oracle Questions Resolved
- {question} → {user's answer} → {now recorded in charter}

## Specs Authored
- {repo path}::{test name} — {journey}

## Bugs Filed
- BUG-zero-qty (major) → fix task declared
```

## regression.md (qa-tester, manifest — points at real specs)

```markdown
# Regression Manifest

| Spec (repo path) | Journey | Risk tier | Guards bug |
|------------------|---------|-----------|------------|
| e2e/checkout.spec.ts::happy path | place an order | critical | — |
| e2e/checkout.spec.ts::rejects qty 0 | quantity guard | major | BUG-zero-qty |
```

One row per committed spec. Every fixed bug adds a row — this is the mechanism by
which the suite accumulates protection instead of resetting each pass.
