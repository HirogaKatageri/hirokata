# The umbrella requirement's body

Full document for Step 4's one-time INSERT (only needed the first time a guild seeds a QA
pass — every later pass finds the existing row and skips this).

```markdown
# Product QA & E2E Regression

## Summary

Umbrella for the guild's independent QA discipline: risk-based coverage planning, empirical
testing of the running product, end-to-end regression specs, and defect findings. Standing —
not tied to a single feature.

## User Stories

### US-1: Risk-based coverage
**As a** maintainer **I want** the highest-risk product areas covered first
**So that** a regression in something that matters is caught before release.

### US-2: Committed e2e regression
**As a** maintainer **I want** e2e specs committed to the project's test dir and run in CI
**So that** the suite keeps working without a QA pass.

## Technical Considerations

- e2e specs live in the project's real test dir and run in CI.
- Defects are `bug` rows and quality areas are `coverage` rows — both on the board.
- The charter, missions, session logs and regression manifest live under `.guild/qa/`.

## Out of Scope

- Unit and integration tests — owned by `test-writer`, planned by `test-planner`.
```
