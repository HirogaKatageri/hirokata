# The prose artifacts — charter, missions, sessions, regression manifest

The four QA outputs that stay markdown under `.guild/qa/`, with their exact format. The two
that are database rows (`bug`, `coverage`) are covered in the main skill, not here.

## charter.md (qa-strategist, evergreen — update in place)

What is left after the risk map and the coverage matrix became rows: the **judgment** that
does not fit in a column. Keep it short; it is read before every pass.

```markdown
---
title: "QA Charter"
requirement: REQ-NNN
created: {original date}
last-updated: {today}
---

# QA Charter

## Quality Definition
{What "good" means for *this* product — the qualities that matter and why. The thing a
coverage row's `risk` column is an opinion about.}

## Oracle Ledger
| Area (coverage id) | Oracle source | Open questions |
|--------------------|---------------|----------------|
| checkout | REQ-003 + Linear PAY-12 | refund window unclear |
| auth | code + running app | empty-email behavior — ask user |

## Notes
{Anything a later pass needs and no column holds: known-flaky surfaces, environment
quirks, areas deliberately out of scope and why.}
```

The **Area** column is the `coverage` id, so the ledger joins to the rows by hand. That is
the seam between the two halves; keep the ids identical.

> Do not restate the risk map here. It is `SELECT * FROM coverage`, it is live, and a second
> copy is one that will be right on the day it is written and wrong a month later.

## missions/MISSION-{slug}.md (qa-strategist, self-contained)

Unchanged and still prose — a mission is a *plan for an exploration*, and the what-if input
matrix is a table of hypotheses, not a record of anything. Name the file after the coverage
area id so a tester can go from a row to its mission.

```markdown
---
id: MISSION-checkout
coverage: checkout          # the coverage area id this mission exercises
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

(The catalog these are drawn from lives in the `guild:qa-mindset` skill.)

## Regression Candidates
{Which confirmed-good scenarios warrant a committed e2e spec, by risk.}

## Open Oracle Questions
- {Ambiguous behavior the tester must confirm with the user at run time.}
```

## sessions/SESSION-{slug}-{date}.md (qa-tester, per run)

Still prose, and still per-run: this is the **evidence trail** — expected-vs-actual for
every scenario, including the ones that passed. A bug row records a defect; the session
records that the work happened, which is what makes an interrupted run resumable.

```markdown
---
mission: MISSION-checkout
coverage: checkout
date: {today}
---

# QA Session: Checkout — {date}

## Scenarios Run
| Scenario | Expected | Actual | Verdict |
|----------|----------|--------|---------|
| valid card checkout | order placed | order placed | pass → spec authored |
| quantity = 0 | rejected | order placed for 0 | BUG-014 |

## Oracle Questions Resolved
- {question} → {user's answer} → {now recorded in the charter's oracle ledger}

## Specs Authored
- {repo path}::{test name} — {journey}

## Bugs Filed
- BUG-014 (major) — quantity 0 accepted → fix + re-verify follow-ups declared

## Coverage Stamped
- `checkout` — last_inspected_at set to {date}
```

The Verdict column cites the real `BUG-NNN` the CLI printed. That is the join between the
prose evidence and the board.

## regression.md (qa-tester, manifest — points at real specs)

Still prose, and it is **not** a duplicate of `coverage.spec_path`. A coverage row holds
*one* primary spec per area because it answers "is this area guarded at all"; the manifest
is per-*test*, and its `Guards` column is what makes the suite visibly accumulate.

```markdown
# Regression Manifest

| Spec (repo path) | Journey | Coverage area | Risk tier | Guards |
|------------------|---------|---------------|-----------|--------|
| e2e/checkout/place-order.spec.ts::happy path | place an order | checkout | critical | — |
| e2e/checkout/quantity.spec.ts::rejects qty 0 | quantity guard | checkout | major | BUG-014 |
```

One row per committed spec. Every fixed bug adds a row, and its `Guards` cell is the
`BUG-NNN` the fix closed — this is the mechanism by which the suite accumulates protection
instead of resetting each pass. When an area's primary spec changes, update the row **and** the
board, so the two agree:

```sql
INSERT INTO coverage (id, area, risk, spec_path, notes)
VALUES ('checkout', 'Checkout flow', 'high', 'e2e/checkout/place-order.spec.ts',
        CAST(x'<hex-notes>' AS TEXT))
ON CONFLICT(id) DO UPDATE SET
  area = excluded.area, risk = excluded.risk,
  spec_path = excluded.spec_path, notes = excluded.notes
RETURNING id, spec_path;
```

Read the row first and pass its current `area`, `risk` and `notes` back through — `DO UPDATE SET`
overwrites every column it names, so an upsert that guessed at `area` is an upsert that renames
an area by omission.
