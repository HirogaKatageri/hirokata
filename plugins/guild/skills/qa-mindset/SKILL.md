---
name: qa-mindset
description: >
  Pre-loaded QA discipline for the qa-strategist and qa-tester agents. Covers the
  five QA pillars (validation over verification, disconfirmation, empiricism, the
  oracle problem, risk-based triage), the hybrid oracle rule for testing existing
  products, the layered oracle resolution order, the what-if input/state/sequence
  catalog, and the exploration-vs-automation distinction. Load this skill before
  planning or running any QA pass. Trigger phrases include "qa mindset",
  "what-if testing", "test strategy", "oracle", "exploratory testing",
  "regression strategy".
version: 1.0.0
---

# The QA Mindset

This is the discipline shared by the `qa-strategist` and `qa-tester`. It is what
separates QA from the chain's reviewers: the reviewers verify that the code matches
the plan; QA validates that the *product* behaves correctly, including in the cases
nobody specified.

## The Five Pillars

1. **Validation over verification.** Verification asks "did we build the thing
   right?" Validation asks "did we build the right thing, and what did nobody
   specify?" The most dangerous bugs live in the gap between the requirement and
   reality. QA's home turf is *unspecified behavior*.

2. **Disconfirmation, not confirmation.** A developer wants the code to pass. QA
   wants to find where it breaks, and treats "the tests pass" as the start of the
   investigation, not the end. This includes distrusting tests themselves: a test
   that never fails when the code is wrong is theater.

3. **Empiricism over reasoning.** Reading code tells you what it *should* do.
   Running it tells you what it *does*. QA exercises the running system and
   believes the observation over the source.

4. **The oracle problem.** Before you can test, answer "how would I know this is
   wrong?" Half of bad QA is running scenarios with no defined expected outcome.
   Always state the expected result *before* observing the actual one.

5. **Risk-based triage.** You cannot test everything. Prioritize by
   `likelihood of failure × cost of failure`. Auth and payments get hammered; the
   about-page copy gets a smoke check. Risk sets *depth*, not whether to cover.

## The Hybrid Oracle (testing an existing product)

When auto-authoring tests against software that already exists, the trap is
deciding what counts as "correct". The guild uses the **hybrid** rule:

- **Lock current behavior** as the regression baseline *when* it agrees with an
  oracle (spec/ticket/user) or is clearly sane.
- **Flag, don't assert** when current behavior contradicts the oracle or fails a
  what-if sanity check — file a bug instead of encoding the bug as "expected".
- **Ask the user** when behavior is ambiguous and no oracle exists; record the
  answer so it becomes the oracle.

Characterization (asserting whatever the app does) detects future *change* but
silently bakes in today's bugs. The hybrid rule keeps the speed of
characterization while refusing to canonize defects.

### Oracle resolution order

1. Internal specs — `.guild/requirements/`, `.guild/docs/`
2. External board — Linear / Jira / etc. via an MCP connector, *if configured*
3. Code + the running app — inferred intent
4. The user — for what stays ambiguous. You can't call `AskUserQuestion` yourself
   (subagent), so end your turn with a `NEEDS INPUT:` block and let the
   orchestrator relay it and resume you with the answer.

## The What-If Catalog

Systematic scenario generation. For each input, state, and sequence, ask "what if
it were…". This catalog is the seed; extend it per feature.

### Input values (per field)
- valid / typical
- invalid / wrong type / wrong format
- boundary: min, max, min−1, max+1, exactly-at-limit
- empty, whitespace-only, missing entirely
- malformed: bad dates, emails, URLs, numbers
- unicode, emoji, RTL text, combining characters
- oversized: very long strings, huge uploads, many rows
- injection-shaped: `<script>`, quotes, SQL-ish, template syntax, path traversal
- leading/trailing whitespace, mixed case, duplicate submission

### State
- acting on already-deleted / expired / archived resources
- operations before prerequisites are met (skip-ahead)
- idempotency: the same action twice (double-click submit)
- partially completed multi-step flows
- stale data: a resource changed in another tab/session

### Sequence & timing
- out-of-order steps in a wizard/flow
- back/forward/refresh mid-flow
- navigating away and returning
- slow network, request timeout, request failure mid-operation
- concurrent actions on the same resource

### Identity & authorization
- unauthenticated access to protected routes/actions
- wrong role / insufficient permission
- session expiry mid-session
- access to another user's resource by ID (IDOR-shaped)

### Environment
- empty states (no data yet) and overflow states (too much data)
- error responses from dependencies (5xx, malformed payloads)
- feature flags / config in unexpected combinations

## Exploration vs Automation

- **Exploration** finds *unknown* failures — unscripted, output is bug reports.
- **Automation** prevents *known-good* behavior from regressing — output is specs.

They are different activities. Explore first (judgment), then automate the
confirmed-good, high-risk paths. Every fixed bug earns a regression spec so the
suite accumulates protection over time instead of resetting.
