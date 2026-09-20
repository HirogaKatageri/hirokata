---
name: qa-artifacts
description: >
  Pre-loaded QA artifact reference for the qa-strategist and qa-tester agents. Says
  which QA output is a DATABASE ROW (defects in the `bug` table, quality areas in the
  `coverage` table) and which stays prose under `.guild/qa/` (charter, missions,
  session logs, regression manifest) — with the exact SQL and file format for each.
  Load this skill before writing any QA artifact or filing any bug. Trigger phrases
  include "qa artifacts", "qa charter", "qa mission", "file a bug", "bug row",
  "coverage area", "coverage row", "regression manifest", "qa session log".
version: 5.0.0
allowed-tools: Bash(tursodb *)
---

# QA Artifacts — What Is a Row, What Is Prose

QA produces four kinds of output, and **two of them are database rows**. That is the whole
point of this skill: a defect written into a markdown file is invisible to `v_brief`, to the
dashboard's Bugs view, to `v_open_bugs`, and to every human who looks at the board — so the
record has to live where the board can see it. The care you put into *describing* the defect
does not change. Only where it lands.

**Load `guild:warehouse` before writing any of the SQL below.** Every free-text value on this
page — a bug title, a repro, a coverage note — crosses as `CAST(x'<hex>' AS TEXT)`, because a
repro step ending in `;` at end of line tears the statement in half.

| Output | Lives in | Written by |
|--------|----------|------------|
| **A defect** | the `bug` table | qa-tester |
| **A quality area + its risk + its spec** | the `coverage` table | qa-strategist plans, qa-tester stamps |
| Quality definition, oracle ledger | `.guild/qa/charter.md` | qa-strategist |
| A mission (scope, journeys, what-if matrix) | `.guild/qa/missions/MISSION-{slug}.md` | qa-strategist |
| A session log (what was run, what happened) | `.guild/qa/sessions/SESSION-{slug}-{date}.md` | qa-tester |
| The committed-spec index | `.guild/qa/regression.md` | qa-tester |

**There is no `.guild/qa/ledger.md`.** Bugs are rows.

`.guild/qa/` remains **evergreen** — like the `doc` and `coverage` tables, these files outlive any
one board. Nothing in the guild deletes them, and nothing deletes the rows either (G11); a fresh
board is a fresh database file and `.guild/qa/` carries straight across. Committed test specs do
NOT live here; they live in the project's real e2e dir and run in CI.

```
.guild/qa/
  charter.md            # qa-strategist: what quality means + where the oracle comes from
  missions/             # qa-strategist: one MISSION-{slug}.md per quality area
  sessions/             # tester: one SESSION-{slug}-{date}.md per run
  regression.md         # tester: index of committed specs in the repo
```

---

## Bugs are rows — the `bug` table

Free text goes in as hex. Write the three long values to files first, so their content never
passes through the shell at all:

```bash
export PATH="$HOME/.turso:$PATH"
hex() { xxd -p < "$1" | tr -d '\n'; }        # or: LC_ALL=C od -An -v -tx1 < "$1" | tr -d ' \n'
T=$(hex /tmp/bug-title); R=$(hex /tmp/bug-repro); B=$(hex /tmp/bug-body)
```

```sql
PRAGMA foreign_keys = ON;

INSERT INTO bug (id, title, body, repro, severity, status, found_by, requirement_id,
                 created_at, updated_at)
SELECT 'BUG-' || printf('%03d', COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)),0)+1),
       CAST(x'<T>' AS TEXT), CAST(x'<B>' AS TEXT), CAST(x'<R>' AS TEXT),
       'major', 'open', 'qa-tester', 'REQ-003',
       strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now')
  FROM bug
RETURNING id, severity, status;
```

`RETURNING id` is how you learn the `BUG-NNN` — there is no other way, and the id is derived
inside the same statement so two testers filing at once cannot collide.

| Column | Holds | Notes |
|--------|-------|-------|
| `title` | one line, the defect stated as an observable fact | required. Not "checkout bug" — what is *wrong* |
| `severity` | `critical` \| `major` \| `minor` | **critical** = crash / data loss / money or security impact; **major** = wrong result or broken flow; **minor** = unlikely or cosmetic. There is deliberately **no `nit`** — a bug is not a nit |
| `repro` | numbered steps, then **Expected** and **Actual** | the single most valuable field. Multi-line is fine — that is what the hex transport is for |
| `body` | area, mission, session, oracle source, diagnosis, spec status | the context a developer needs before touching code |
| `requirement_id` | `REQ-NNN` when the defect belongs to one | **nullable, and deliberately so** — a QA pass finds defects outside any requirement's scope all the time. Do not invent a requirement to have something to point at. Because the id is a literal here, verify it exists first, or the FK refuses the row |
| `found_by` | `qa-tester` (or `'user'`) | who observed it. It is also what the creation event is attributed to, so set it honestly |

Worked example of what those three files hold:

```
title: Checkout accepts quantity 0 and places an order for nothing

repro:  1. Add any item to the cart
        2. Set the quantity field to 0
        3. Press Checkout
        Expected: the quantity is rejected before payment (REQ-003 'quantity must be >= 1')
        Actual:   the order is placed, total $0.00, confirmation email sent

body:   Area: Checkout · Mission: MISSION-checkout · Session: SESSION-checkout-2026-08-14
        Oracle: REQ-003 acceptance criteria.
        The client-side guard exists but the server route does not re-check, so any client
        that skips the form (or a replayed request) reaches the payment step with qty 0.
        Committed as a skipped spec: e2e/checkout/quantity.spec.ts::rejects qty 0 (test.fixme).
```

**Write the whole report in the one INSERT.** Nothing rewrites `title`, `repro` or `body`
afterwards; anything you leave out stays out.

**The pairing rules have not changed** — a bug still gets a `developer` fix follow-up and a
`qa-tester` re-verify follow-up, declared in that order, and the follow-up cites `BUG-NNN`.
Once the fix ticket exists, link it:

```sql
UPDATE bug SET fix_task_id = 'TASK-051', status = 'fixing'
 WHERE id = 'BUG-014' AND status = 'open'
RETURNING id, status, fix_task_id;

-- and, once the re-verify tester has empirically confirmed it
UPDATE bug SET status = 'fixed'
 WHERE id = 'BUG-014' AND status IN ('open','fixing')
RETURNING id, status;
```

Guard on the status you expect and always `RETURNING`. Zero rows back means somebody already
moved it — information, not an error. Never set `updated_at` yourself; a trigger stamps it.

Read them back with the view, never by re-deriving "which bugs are open":

```sql
SELECT id, severity, status, found_by, requirement_id, fix_task_id, title FROM v_open_bugs;
```

---

## Quality areas are rows — the `coverage` table

The `coverage` table is the **risk map and the coverage matrix**, which is why neither is a
markdown table in the charter. One row per quality area, upserted:

```sql
INSERT INTO coverage (id, area, risk, spec_path, notes)
VALUES ('checkout', 'Checkout flow', 'high', 'e2e/checkout/place-order.spec.ts',
        CAST(x'<hex-notes>' AS TEXT))
ON CONFLICT(id) DO UPDATE SET
  area      = excluded.area,
  risk      = excluded.risk,
  spec_path = excluded.spec_path,
  notes     = excluded.notes
RETURNING id, risk, spec_path;
```

| Column | Holds |
|--------|-------|
| `id` | the key you retype: letters, digits, `.`, `_`, `-`. `checkout`, `auth`, `cart-persistence` |
| `area` | the human name, any text. Required |
| `risk` | `high` \| `medium` \| `low` — `likelihood of failure × cost of failure`. Defaults to `medium` |
| `spec_path` | the committed e2e spec that guards this area, if one exists. `NULL` when none |
| `notes` | why the risk is what it is, the depth of coverage, the mission that covers it |

**`DO UPDATE SET` overwrites every column it names**, so pass the values you want kept — an
upsert that omits `area` would rename the area to whatever you happened to type. That is the
one difference from the old CLI, which preserved what you did not pass. **Re-survey by upserting
the ids that already exist**, never by inventing a new id for the same area: a near-duplicate
row double-counts it in every "what is due" number the guild computes.

**`last_inspected_at` is not in that upsert, on purpose.** It moves in a statement of its own:

```sql
UPDATE coverage SET last_inspected_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE id = 'checkout'
RETURNING id, last_inspected_at;
```

The **qa-tester** runs that, once per area it genuinely exercised — never for an area it planned
to reach and did not, because the stamp is a claim. Keeping it out of the upsert is what stops
re-saving a risk or a note from making a stale area read as fresh; a trigger fires on that column
alone. `risk` + `last_inspected_at` is what turns "what has nobody looked at?" into a query
instead of a thing somebody has to remember, and populating this table is what makes a QA cadence
possible at all.

```sql
SELECT id, area, risk, spec_path, last_inspected_at, notes FROM coverage ORDER BY id;
SELECT id, risk, interval_days, days_since, spec_path, area FROM v_coverage_due;
```

`v_coverage_due` holds the thresholds — high goes stale at 14 days, medium at 30, low at 90 —
in one place. Do not re-derive them. **`days_since` is NULL for an area never inspected**, which
is not "0 days ago"; render it as `never`, not as a number.

---

## The four prose artifacts

`charter.md`, `missions/MISSION-{slug}.md`, `sessions/SESSION-{slug}-{date}.md`, and
`regression.md` all stay markdown under `.guild/qa/` — their exact format, front matter, and
the write conventions for each (the charter is evergreen and updated in place; a session is
per-run evidence; the regression manifest is per-*test*, not a duplicate of
`coverage.spec_path`) are in `references/prose-artifacts.md`. Load it when actually writing one
of these files.
