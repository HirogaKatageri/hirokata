# Example: Phase Completion Review

This example demonstrates using the comprehensive-review skill after completing Phase 3 (Services/Use Cases).

## User Request

```
"I've completed Phase 3 implementation, run comprehensive review against phase-3.md"
```

## Skill Execution Steps

### Step 1: Identify Review Scope

```bash
# Locate phase plan
ls docs/phase-3.md  # Found

# Check recent changes
git log --oneline -10
# a1b2c3d Implement user authentication service
# d4e5f6g Add order processing service
# g7h8i9j Create payment validation service
# j0k1l2m Add service unit tests
# m3n4o5p Update service interfaces

# Determine scope
# Reviewing: All changes since phase 3 started
# Requirements: docs/phase-3.md
```

### Step 2: Launch Review Agents in Parallel

All five agents launched simultaneously:

```markdown
1. product-reviewer: "Review changes against docs/phase-3.md. Verify all Phase 3 services are implemented."

2. reviewer-business-logic: "Review Phase 3 service layer for testability and test coverage."

3. reviewer-edge-case: "Review Phase 3 services for unhandled edge cases in business logic."

4. reviewer-architecture: "Review Phase 3 implementation for clean architecture compliance, verify services don't depend on outer layers."

5. reviewer-security: "Review Phase 3 services for security vulnerabilities: injection flaws, authentication issues, sensitive data exposure, hardcoded secrets, and missing input validation. Reference OWASP Top 10."
```

### Step 3: Agent Reports (Summarized)

**Product Reviewer Report:**
- 8/10 services implemented (80%)
- 2 services partially implemented:
  - Notification Service (missing email provider integration)
  - Analytics Service (missing event tracking)
- All core business logic services complete

**Business Logic Reviewer Report:**
- 75% test coverage
- 6 services fully tested
- 2 services partially tested (missing error case tests)
- 1 testability issue: PaymentService has hard-coded API client
- Recommendation: Inject API client dependency

**Edge Case Reviewer Report:**
- 2 critical edge cases:
  - AuthenticationService doesn't handle expired token refresh
  - OrderService doesn't validate inventory before processing
- 5 warning edge cases (mostly null handling)
- 8 info edge cases

**Architecture Reviewer Report:**
- No critical violations
- Services correctly depend on Models (Phase 2)
- Services correctly define repository interfaces
- 1 warning: OrderService directly imports database config (should use repository)
- Overall architecture compliance: 95%

### Step 4: Consolidated Report

```markdown
# Comprehensive Review Report - Phase 3 Completion

## Executive Summary

**Review Scope:**
- Requirements: docs/phase-3.md
- Changes: Last 15 commits (Phase 3 implementation)
- Files Reviewed: 18 service files, 12 test files

**Overall Status:** PASS WITH WARNINGS

**Critical Issues:** 2
**Warnings:** 6
**Recommendations:** 8

## Review Dimensions Summary

### Requirements Compliance
- Implemented: 80% (8/10 services)
- Partially Implemented: 2 services
- Status: Good - Core complete, supplementary features incomplete
- Details: See Section 1 below

### Test Coverage
- Business Logic Changes: 10 services
- Tested: 75% coverage
- Missing Tests: 2 services need error case tests
- Status: Good - Most services well tested
- Details: See Section 2 below

### Edge Case Handling
- Critical Edge Cases: 2
- Warning Edge Cases: 5
- Status: Needs Attention - 2 critical cases must be fixed
- Details: See Section 3 below

### Architecture Alignment
- Critical Violations: 0
- Architectural Warnings: 1
- Status: Good - Clean architecture followed
- Details: See Section 4 below

## Priority Actions

### Must Fix Immediately
1. **[Edge Case]** AuthenticationService: Handle expired token refresh scenario
   - Impact: Production auth failures
   - Location: src/services/auth-service.ts:45

2. **[Edge Case]** OrderService: Validate inventory before order processing
   - Impact: Order fulfillment failures
   - Location: src/services/order-service.ts:78

### Should Fix Soon
1. **[Requirements]** Complete Notification Service email provider integration
   - Partially implemented, missing SendGrid integration

2. **[Tests]** Add error case tests for PaymentService and NotificationService
   - Coverage: 65% -> 85% with these tests

3. **[Architecture]** Refactor OrderService database config dependency
   - Should use repository pattern, not direct DB access

### Consider for Future
1. **[Testability]** Inject PaymentService API client dependency
2. **[Edge Cases]** Add null checks for 5 warning-level scenarios
3. **[Requirements]** Complete Analytics Service event tracking

---

## Next Steps

### Immediate Actions (Before PR)
1. Fix 2 critical edge cases:
   - Add expired token handling to AuthenticationService
   - Add inventory validation to OrderService
2. Refactor OrderService database config dependency
3. Add error case tests for PaymentService

### Before Phase 4
1. Complete Notification Service email integration
2. Add remaining test coverage
3. Address 5 warning-level edge cases

### Long-Term
1. Complete Analytics Service event tracking
2. Improve PaymentService testability
3. Consider implementing circuit breaker for external APIs

---

## Review Complete

Phase 3 is substantially complete with good quality. After addressing 2 critical edge cases and 1 architecture warning, ready to proceed to Phase 4 (Data Layer).

**Recommendation:** Fix critical issues (estimated 2-3 hours), then create PR for Phase 3.
```

## Key Takeaways

1. **Parallel Execution:** All five agents ran simultaneously, total time ~3 minutes
2. **Comprehensive View:** Got five different perspectives on same code
3. **Prioritized Actions:** Clear list of must-fix vs nice-to-have
4. **Ready to Proceed:** After fixing critical issues, Phase 3 complete
5. **Evidence-Based:** Specific file paths, line numbers, code examples
