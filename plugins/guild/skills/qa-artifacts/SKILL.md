---
name: qa-artifacts
description: >
  Pre-loaded QA artifact reference for the qa-strategist and qa-tester agents. Says
  which QA output is a DATABASE ROW (bugs via `guild bug new`, quality areas via
  `guild coverage set`) and which stays prose under `.guild/qa/` (charter, missions,
  session logs, regression manifest) — with the exact field mapping and file format for
  each. Load this skill before writing any QA artifact or filing any bug. Trigger phrases
  include "qa artifacts", "qa charter", "qa mission", "file a bug", "guild bug new",
  "coverage area", "guild coverage set", "regression manifest", "qa session log".
version: 3.0.0
---

# QA Artifacts — What Is a Row, What Is Prose

QA produces four kinds of output, and **two of them are database rows now**. This is the
Stage 2 change and it is the whole point of this skill: a defect written into a markdown
file is invisible to `guild brief`, to the dashboard's Bugs view, to `guild bug list`, and
to every human who looks at the board — so the record has to live where the board can see
it. The care you put into *describing* the defect does not change. Only where it lands.

| Output | Lives in | Written by |
|--------|----------|------------|
| **A defect** | the `bug` table | `guild bug new` (qa-tester) |
| **A quality area + its risk + its spec** | the `coverage` table | `guild coverage set` / `guild coverage inspect` (qa-strategist plans, qa-tester stamps) |
| Quality definition, oracle ledger | `.guild/qa/charter.md` | qa-strategist |
| A mission (scope, journeys, what-if matrix) | `.guild/qa/missions/MISSION-{slug}.md` | qa-strategist |
| A session log (what was run, what happened) | `.guild/qa/sessions/SESSION-{slug}-{date}.md` | qa-tester |
| The committed-spec index | `.guild/qa/regression.md` | qa-tester |

**There is no `.guild/qa/ledger.md` any more.** It was the bug ledger; bugs are rows. If a
project still has one from v4, treat it as history — read it, do not append to it.

`.guild/qa/` remains **evergreen** — like `.guild/docs/`, these files survive releases and
`clear-board`. Committed test specs do NOT live here; they live in the project's real e2e
dir and run in CI.

```
.guild/qa/
  charter.md            # strategist: what quality means + where the oracle comes from
  missions/             # strategist: one MISSION-{slug}.md per quality area
  sessions/             # tester: one SESSION-{slug}-{date}.md per run
  regression.md         # tester: index of committed specs in the repo
```

---

## Bugs are rows — `guild bug new`

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"

BUG=$("$GUILD" bug new \
  --title "Checkout accepts quantity 0 and places an order for nothing" \
  --severity major \
  --req REQ-003 \
  --found-by qa-tester \
  --repro "1. Add any item to the cart
2. Set the quantity field to 0
3. Press Checkout
Expected: the quantity is rejected before payment (REQ-003 'quantity must be >= 1')
Actual:   the order is placed, total \$0.00, confirmation email sent" \
  --body "Area: Checkout · Mission: MISSION-checkout · Session: SESSION-checkout-2026-08-14
Oracle: REQ-003 acceptance criteria.
The client-side guard exists but the server route does not re-check, so any client
that skips the form (or a replayed request) reaches the payment step with qty 0.
Committed as a skipped spec: e2e/checkout/quantity.spec.ts::rejects qty 0 (test.fixme)."
)
```

`bug new` prints `<BUG-ID> <title>`; take the id with `${BUG%% *}`.

| Flag | Holds | Notes |
|------|-------|-------|
| `--title` | one line, the defect stated as an observable fact | required. Not "checkout bug" — what is *wrong* |
| `--severity` | `critical` \| `major` \| `minor` | defaults to `major`. **critical** = crash / data loss / money or security impact; **major** = wrong result or broken flow; **minor** = unlikely or cosmetic |
| `--repro` | numbered steps, then **Expected** and **Actual** | the single most valuable field. Multi-line is fine |
| `--body` | area, mission, session, oracle source, diagnosis, spec status | the context a developer needs before touching code |
| `--req` | `REQ-NNN` when the defect belongs to a requirement | **optional, and deliberately so** — a QA pass finds defects outside any requirement's scope all the time. Do not invent a requirement to have something to point at. A bad REQ id is refused, nothing is written |
| `--found-by` | `qa-tester` | who observed it |

**Write the whole report in the one call.** There is no bug-body editor: `guild bug`
has `fix` and `close`, and neither rewrites the text. Anything you leave out stays out.

**The pairing rules have not changed** — a bug still gets a `developer` fix follow-up and
a `qa-tester` re-verify follow-up, declared in that order. See the qa-tester agent for the
exact shape; what changed is that the follow-up now cites `BUG-NNN` instead of a markdown
anchor, and once the orchestrator files the fix task you link it:

```bash
"$GUILD" bug fix "$BUG" --task TASK-NNN     # moves the bug to `fixing`
```

---

## Quality areas are rows — `guild coverage set`

The `coverage` table is the **risk map and the coverage matrix**, which is why neither is a
markdown table in the charter any more. One row per quality area:

```bash
"$GUILD" coverage set checkout --area "Checkout flow" --risk high \
  --spec "e2e/checkout/place-order.spec.ts" \
  --notes "Payment + money movement. Full what-if matrix; mission MISSION-checkout."
"$GUILD" coverage set marketing --area "Marketing pages" --risk low \
  --notes "Smoke only — renders and links resolve."
```

| Field | Holds |
|-------|-------|
| `<area-id>` | the key you retype: letters, digits, `.`, `_`, `-`. `checkout`, `auth`, `cart-persistence` |
| `--area` | the human name, any text. Required |
| `--risk` | `high` \| `medium` \| `low` — `likelihood of failure × cost of failure`. Defaults to `medium` |
| `--spec` | the committed e2e spec that guards this area, if one exists. `--spec ""` clears it |
| `--notes` | why the risk is what it is, the depth of coverage, the mission that covers it |

**It is an upsert and it preserves what you do not pass.** Re-surveying a product means
calling `coverage set` on the ids that already exist — same id, updated risk or spec —
never a new id for the same area. A near-duplicate row double-counts the area in every
"what is due" number the guild computes.

**`last_inspected_at` is not settable here, on purpose.** Only one command moves it:

```bash
"$GUILD" coverage inspect checkout    # "somebody actually looked at this, today"
```

The **qa-tester** calls that, once per area it genuinely exercised — never for an area it
planned to reach and did not, because the stamp is a claim. `risk` + `last_inspected_at`
is what turns "what has nobody looked at?" into a query (`guild coverage list --due`;
high-risk areas go stale at 14 days, medium at 30, low at 90) instead of a thing somebody
has to remember. Populating this table is what makes a QA cadence possible at all.

Read it back with `guild coverage list`, `guild coverage list --due`, `guild coverage show
<area-id>`.

---

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

> Do not restate the risk map here. It is `guild coverage list`, it is live, and a second
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
- `guild coverage inspect checkout`
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
instead of resetting each pass. When an area's primary spec changes, update the row **and**
`guild coverage set <area-id> --area "<the same human name>" --spec <path>` so the board agrees
with the repo. (`--area` is required on **every** `coverage set`, updates included — an upsert
that guessed it would be an upsert that could rename an area by omission.)
