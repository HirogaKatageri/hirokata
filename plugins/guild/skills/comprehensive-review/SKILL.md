---
name: comprehensive-review
description: Use this skill when the user wants to review code changes, verify implementation quality, or check readiness before a PR or deployment. Trigger on phrases like "review my changes", "run comprehensive review", "check all my code", "am I ready for PR", "before I create a PR", "before I merge", "code audit", "quality check", "verify my implementation", "is my feature complete", "run all reviewers", "check if my implementation is complete", "deep code review", "deep review", or any multi-dimensional code analysis request. Also use proactively when the user says they've finished a phase, completed a feature, or are wrapping up work — even if they don't explicitly ask for a "review". Covers requirements compliance, test coverage, edge cases, architecture alignment, and security.
version: 0.3.0
user-invocable: true
---

# Comprehensive Review

Orchestrates five specialized review agents in parallel to provide a complete, multi-dimensional analysis of recent code changes:

1. **Requirements Compliance** — Verifies all requirements are implemented
2. **Test Coverage** — Ensures business logic is testable and tested
3. **Edge Case Handling** — Identifies unhandled edge cases and boundary conditions
4. **Architectural Alignment** — Checks compliance with clean architecture principles
5. **Security** — Identifies vulnerabilities and risks (OWASP Top 10)

## Review Workflow

### Step 1: Identify Review Scope

1. **Find requirements documents** — check the guild board first. If `.guild/config.yaml` exists,
   the board is a database, not a directory tree; read it with SQL (load `guild:warehouse` for
   the rules, notably that a body comes back byte-exact only when it is the **one** column you
   select):

   ```bash
   export PATH="$HOME/.turso:$PATH"
   printf "SELECT id, status, title FROM requirement ORDER BY id;\n" | tursodb -q -m list .guild/guild.db
   printf "SELECT body FROM requirement WHERE id = 'REQ-007';\n" | tursodb -q -m list .guild/guild.db
   printf "SELECT body FROM plan WHERE requirement_id = 'REQ-007';\n" | tursodb -q -m list .guild/guild.db
   ```

   Keep `-m list` even for a single column: the default `pretty` mode draws a box and
   **truncates long values with an ellipsis**, which would silently hand you a clipped
   requirement to review against.

   Otherwise fall back to `requirements/`, `docs/`, `planning/`, or phase plan files. If none
   found, ask the user.
2. **Identify recent changes** — use `git log` and `git diff` to understand scope
3. **Confirm scope** — if unclear which requirements or commits to include, ask

> Board-driven review of a guild requirement is normally handled by the check-in pipeline's
> `reviewer` gate; this skill is the read-only, on-demand surface for ad-hoc "am I ready?" checks.

### Step 2: Launch All Five Agents in Parallel

Launch all agents in a **single message** using multiple Task tool calls. Include specific file paths and context in each prompt so agents don't waste time on discovery.

**product-reviewer:**
> "Review recent changes against [requirements-file]. Map each requirement to its implementation. Flag anything missing or partially implemented. [State the project's architecture conventions only if a plan or phase document actually defines them.]"

**reviewer-business-logic:**
> "Review recent changes for business logic testability and unit test coverage. Focus on services, use cases, and domain logic. Flag untestable patterns (hard-coded dependencies, global state, non-determinism) and missing unit tests."

**reviewer-edge-case:**
> "Review recent changes for unhandled edge cases: null/undefined access, empty collections, boundary values, error scenarios (network timeout, DB failure, API errors), date/time issues, and concurrency problems."

**reviewer-architecture:**
> "Review recent changes for architecture compliance. Check dependency direction (inner layers must not depend on outer), layer separation (business logic out of UI), and consistency with the project's established structure. [Cite the plan's architectural decisions or the project's documented conventions — do not assume a phase methodology unless a plan document defines one.]"

**reviewer-security:**
> "Review recent changes for security vulnerabilities: injection flaws (SQL, command, template), authentication/authorization issues, sensitive data exposure, hardcoded secrets, weak cryptography (MD5/SHA1/DES), XSS, CSRF, and missing input validation. Reference OWASP Top 10."

### Step 3: Collect Agent Reports

Wait for all five agents. Capture full reports and note critical issues.

### Step 4: Present Consolidated Report

Use the following structure. Status icons reflect actual findings — do not default to ✅ if there are issues.

```markdown
# Comprehensive Review Report

## Executive Summary

**Review Scope:**
- Requirements: [which documents]
- Changes: [commit range or files]
- Files Reviewed: [count]

**Overall Status:** [Pass / Pass with Warnings / Needs Attention / Critical Issues]

**Critical Issues:** [count] | **Warnings:** [count] | **Recommendations:** [count]

## Review Dimensions

| Dimension | Status | Summary |
|---|---|---|
| Requirements Compliance | [✅/⚠️/❌] | [X]% implemented, [N] missing |
| Test Coverage | [✅/⚠️/❌] | [X]% coverage, [N] untestable |
| Edge Case Handling | [✅/⚠️/❌] | [N] critical, [N] warning |
| Architecture Alignment | [✅/⚠️/❌] | [N] violations, [N] warnings |
| Security | [✅/⚠️/❌] | [N] critical, [N] high |

**Status icons:** ✅ Good | ⚠️ Needs Attention | ❌ Critical Issues

## Priority Actions

### Must Fix Immediately
1. [Critical issue — source agent, file:line]

### Should Fix Soon
1. [Important issue]

### Consider for Future
1. [Recommendation]

---

## Detailed Reports

### 1. Requirements Compliance
[Full product-reviewer report]

### 2. Test Coverage
[Full reviewer-business-logic report]

### 3. Edge Case Analysis
[Full reviewer-edge-case report]

### 4. Architecture Review
[Full reviewer-architecture report]

### 5. Security Review
[Full reviewer-security report]

---

## Next Steps
[Prioritized action list based on combined findings]
```

## Handling Special Cases

**No requirements found:**
Ask the user to provide a requirements file path, master plan, or confirm whether to skip the requirements review.

**No recent changes detected:**
Ask the user for a commit range (e.g., `main..feature-branch`) or specific files to review.

**An agent fails:**
Note the failure, continue with the remaining agents, and present a partial report. Suggest running the failed review separately.

## Reference Files

- **`references/agent-capabilities.md`** — Read this when you need to understand what a specific agent analyzes or how to interpret its metrics (e.g., what "critical" vs "warning" means per dimension).
- **`references/review-interpretation.md`** — Read this when consolidating findings: contains decision matrices for go/no-go decisions, cross-cutting patterns (issues appearing in multiple reports), and how to prioritize fixes across dimensions.

## Limitations

This skill identifies issues but cannot fix them, modify code, or replace human judgment. Use it as part of your quality process, not as a substitute for it.
