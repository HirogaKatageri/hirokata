# Example: PR Readiness Review

This example demonstrates using the comprehensive-review skill before creating a pull request for a feature branch.

## User Request

```
"Review my feature branch before I create a PR"
```

## Context

- Feature: User authentication with OAuth
- Branch: feature/oauth-authentication
- Base: main
- Requirements: requirements/authentication.md

## Skill Execution Steps

### Step 1: Identify Review Scope

```bash
# Check branch status
git status
# On branch feature/oauth-authentication
# Your branch is ahead of 'origin/main' by 8 commits

# Review changes
git log main..feature/oauth-authentication --oneline
# f1e2d3c Add OAuth provider integration
# a4b5c6d Implement token exchange flow
# d7e8f9g Add OAuth callback handler
# g0h1i2j Create OAuth configuration
# j3k4l5m Add OAuth user sync
# m6n7o8p Update authentication service
# p9q0r1s Add OAuth tests
# s2t3u4v Update documentation

# Check requirements
ls requirements/authentication.md  # Found

# Diff summary
git diff main..feature/oauth-authentication --stat
# 12 files changed, 856 insertions(+), 124 deletions(-)
```

### Step 2: Launch Review Agents in Parallel

All five agents launched simultaneously:

```markdown
1. product-reviewer: "Review feature/oauth-authentication branch against requirements/authentication.md. Verify OAuth authentication implementation is complete."

2. reviewer-business-logic: "Review OAuth authentication implementation for testability and test coverage."

3. reviewer-edge-case: "Review OAuth flow for unhandled edge cases (invalid tokens, provider failures, state mismatch)."

4. reviewer-architecture: "Review OAuth implementation for clean architecture compliance and proper layer separation."

5. reviewer-security: "Review OAuth implementation for security vulnerabilities: CSRF (state parameter validation), token handling, injection flaws, sensitive data exposure, and authentication issues. Reference OWASP Top 10."
```

### Step 3: Agent Reports (Summarized)

**Product Reviewer Report:**
- 9/10 requirements implemented (90%)
- 1 requirement incomplete:
  - Multi-provider support (only Google implemented, GitHub/Microsoft pending)
- All core OAuth flow requirements met
- Documentation updated

**Business Logic Reviewer Report:**
- 82% test coverage
- OAuth flow well tested with mocks
- Token exchange fully tested
- 1 testability concern: OAuthProvider uses hard-coded HTTP client
- User sync service fully tested

**Edge Case Reviewer Report:**
- 1 critical edge case:
  - State parameter validation missing (CSRF vulnerability)
- 3 warning edge cases:
  - Token refresh failure not handled
  - Provider rate limiting not handled
  - Invalid callback URL not validated
- 6 info edge cases

**Architecture Reviewer Report:**
- No critical violations
- OAuth logic properly in service layer
- Repository pattern used correctly
- 1 warning: Direct environment variable access in OAuthConfig
- Overall: Clean architecture followed well

### Step 4: Consolidated Report

```markdown
# Comprehensive Review Report - OAuth Authentication PR

## Executive Summary

**Review Scope:**
- Requirements: requirements/authentication.md (OAuth section)
- Branch: feature/oauth-authentication vs main
- Files Changed: 12 files
- Lines Changed: +856/-124

**Overall Status:** PASS WITH CRITICAL ISSUE

**Critical Issues:** 1 (Security)
**Warnings:** 4
**Recommendations:** 5

## Review Dimensions Summary

### Requirements Compliance
- Implemented: 90% (9/10 requirements)
- Missing: Multi-provider support (only Google done)
- Status: Good - Core OAuth complete
- Details: See Section 1

### Test Coverage
- Changes: 12 files
- Tested: 82% coverage
- Status: Good - Well tested
- Details: See Section 2

### Edge Case Handling
- Critical Edge Cases: 1 (SECURITY)
- Warning Edge Cases: 3
- Status: CRITICAL - Must fix before merge
- Details: See Section 3

### Architecture Alignment
- Critical Violations: 0
- Warnings: 1
- Status: Good - Clean architecture
- Details: See Section 4

## Priority Actions

### Must Fix Before PR (BLOCKING)
1. **[SECURITY]** Add state parameter validation to prevent CSRF attacks
   - Impact: Security vulnerability
   - Location: src/services/oauth-service.ts:67
   - Severity: CRITICAL
   - Estimated fix: 30 minutes

### Should Fix Before Merge
1. **[Edge Case]** Handle token refresh failures gracefully
   - Impact: User experience degradation
   - Location: src/services/token-service.ts:45
   - Severity: High

2. **[Edge Case]** Add rate limiting handling for OAuth providers
   - Impact: Service failures during high traffic
   - Location: src/providers/google-oauth-provider.ts:89

3. **[Architecture]** Remove direct environment variable access
   - Impact: Testability and configuration management
   - Location: src/config/oauth-config.ts:12

### Document for PR Description
1. **[Requirements]** Multi-provider support coming in follow-up PR
   - GitHub and Microsoft OAuth providers
   - Timeline: Next sprint

---

## PR Readiness Assessment

### Checklist

- Requirements: 90% implemented, 10% documented for next PR
- Tests: 82% coverage, well tested
- Security: CRITICAL issue - state validation missing
- Architecture: Clean architecture followed
- Edge Cases: 3 warning-level issues

### Recommendation: FIX SECURITY ISSUE FIRST

**Status:** NOT READY TO MERGE

**Blocking Issue:** CSRF vulnerability due to missing state validation

**Time to Fix:** ~30-45 minutes

**After Fix:**
1. Re-run tests
2. Add test for state validation
3. Ready to create PR

---

## Next Steps

### Before Creating PR

1. **Fix state validation (BLOCKING)**
   - Implement state storage and verification
   - Add tests for state validation
   - Test CSRF protection

2. **Run tests**
   - Ensure all tests pass including new state validation tests

3. **Optional improvements** (Can be follow-up)
   - Add token refresh failure handling
   - Add rate limiting handling
   - Refactor environment variable access

### After PR Created

1. Request security review (mention CSRF protection)
2. Highlight multi-provider support coming in next PR
3. Link follow-up issues for GitHub/Microsoft providers

---

## Summary

OAuth implementation is solid with good test coverage and clean architecture. However, **CRITICAL security issue** (missing state validation) must be fixed before creating PR.

**Estimated time to PR-ready:** 30-45 minutes (fix + tests)

After fixing state validation, this PR will be a high-quality addition with proper OAuth 2.0 security.
```

## Key Takeaways

1. **PR Blocker Identified:** Found critical security vulnerability (CSRF) via the security reviewer before creating PR
2. **Clear Action Plan:** Specific fix required with code examples
3. **Documentation Ready:** PR title and description prepared
4. **Follow-up Planned:** Multi-provider support documented for next PR
5. **Time Estimate:** Realistic estimate for becoming PR-ready (30-45 min)
6. **Prevented Production Bug:** CSRF vulnerability caught in review, not production
