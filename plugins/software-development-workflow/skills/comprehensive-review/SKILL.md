---
name: comprehensive-review
description: This skill should be used when the user asks to "review my changes", "run comprehensive review", "review against requirements", "check all my code", "run all reviewers", "comprehensive code review", or wants a complete analysis of recent changes including requirements compliance, test coverage, edge cases, and architecture alignment.
version: 0.1.0
---

# Comprehensive Review

This skill orchestrates a complete multi-dimensional review of code changes against requirements, running five specialized review agents in parallel to provide comprehensive feedback on implementation quality.

## Purpose

Provide a thorough analysis of recent code changes across five critical dimensions:
1. **Requirements Compliance** - Verify all requirements are implemented
2. **Test Coverage** - Ensure business logic is testable and tested
3. **Edge Case Handling** - Identify unhandled edge cases and boundary conditions
4. **Architectural Alignment** - Check compliance with clean architecture principles
5. **Security** - Identify security vulnerabilities and risks

## When to Use This Skill

Use this skill when:
- Completing a development phase and need full validation
- Preparing for a pull request or code review
- Finishing implementation of requirements and want to verify completeness
- Need to ensure code quality across multiple dimensions before deployment
- Want to catch issues early before they reach production

## Review Workflow

### Step 1: Identify Review Scope

First, determine what needs to be reviewed:

1. **Check for requirements documents:**
   - Look in `requirements/` directory
   - Check for master plan files (typically in `docs/` or `planning/`)
   - Find phase plan files (phase-1.md through phase-7.md)
   - Ask user to specify if no requirements found

2. **Identify recent changes:**
   - Use `git log` to see recent commits
   - Use `git diff` to understand scope of changes
   - Determine which files and features were modified

3. **Confirm scope with user:**
   - If unclear which requirements to review against, ask user
   - If unsure about which commits to include, ask for clarification
   - Confirm if specific areas should be excluded from review

### Step 2: Launch Review Agents in Parallel

Execute all five review agents concurrently for maximum efficiency:

```markdown
Launch the following agents in parallel using multiple Task tool invocations in a single message:

1. **product-reviewer** agent
   - Prompt: "Review recent changes against [requirements file/master plan/phase plan]. Verify all requirements are implemented and identify any missing functionality."

2. **code-reviewer-business-logic** agent
   - Prompt: "Review recent changes for business logic testability and test coverage. Identify untestable code patterns and missing unit tests."

3. **code-reviewer-edge-case** agent
   - Prompt: "Review recent changes for unhandled edge cases, boundary conditions, and error scenarios. Identify potential edge case issues."

4. **code-reviewer-architecture** agent
   - Prompt: "Review recent changes for architectural alignment with clean architecture principles and the 8-phase structure. Identify architectural violations and provide recommendations."

5. **code-reviewer-security** agent
   - Prompt: "Review recent changes for security vulnerabilities including injection flaws, authentication issues, sensitive data exposure, access control weaknesses, and cryptographic misconfigurations. Identify all security risks and provide remediation guidance."
```

**Important:** Launch all five agents in a single message with multiple Task tool calls to maximize parallelization and reduce total review time.

### Step 3: Collect Agent Reports

As each agent completes:
1. Capture the full report from each agent
2. Store reports for consolidation
3. Note any critical issues flagged by agents

### Step 4: Present Consolidated Report

Provide a comprehensive summary to the user:

```markdown
# Comprehensive Review Report

## Executive Summary

**Review Scope:**
- Requirements: [which documents]
- Changes: [commit range or scope]
- Files Reviewed: [count]

**Overall Status:** [Pass/Pass with Warnings/Needs Attention/Critical Issues]

**Critical Issues:** [count]
**Warnings:** [count]
**Recommendations:** [count]

## Review Dimensions Summary

### ✅ Requirements Compliance
- Implemented: [X]%
- Missing: [count] requirements
- Status: [Good/Needs Work]
- [Link to detailed report below]

### ✅ Test Coverage
- Business Logic Changes: [count]
- Tested: [X]%
- Missing Tests: [count]
- Status: [Good/Needs Work]
- [Link to detailed report below]

### ✅ Edge Case Handling
- Critical Edge Cases: [count]
- Warning Edge Cases: [count]
- Status: [Good/Needs Work]
- [Link to detailed report below]

### ✅ Architecture Alignment
- Critical Violations: [count]
- Architectural Warnings: [count]
- Status: [Good/Needs Work]
- [Link to detailed report below]

### ✅ Security
- Critical Vulnerabilities: [count]
- High Vulnerabilities: [count]
- Medium Vulnerabilities: [count]
- Status: [Secure/Needs Attention/At Risk/Critical Risk]
- [Link to detailed report below]

## Priority Actions

List the most critical items across all reviews:

### Must Fix Immediately
1. [Critical issue from any agent]
2. [Critical issue from any agent]

### Should Fix Soon
1. [Important issue from any agent]
2. [Important issue from any agent]

### Consider for Future
1. [Recommendation from any agent]
2. [Recommendation from any agent]

---

## Detailed Reports

### 1. Requirements Compliance Report

[Full product-reviewer agent report]

---

### 2. Test Coverage Report

[Full code-reviewer-business-logic agent report]

---

### 3. Edge Case Analysis Report

[Full code-reviewer-edge-case agent report]

---

### 4. Architecture Review Report

[Full code-reviewer-architecture agent report]

---

### 5. Security Review Report

[Full code-reviewer-security agent report]

---

## Next Steps

Recommended actions based on all reviews:
1. [Prioritized action]
2. [Prioritized action]
3. [Prioritized action]
```

## Best Practices

### Efficient Agent Usage

- **Parallel execution:** Always launch all five agents in parallel
- **Clear prompts:** Provide specific requirements file paths to agents
- **Scope clarity:** Be explicit about what commits or changes to review

### Report Presentation

- **Executive summary first:** Give user high-level status immediately
- **Prioritized issues:** Combine findings across all reviews into priority order
- **Detailed reports below:** Include full agent reports for deep analysis
- **Actionable next steps:** Provide clear recommendations

### Handling Edge Cases

**No requirements found:**
```markdown
Could not locate requirements documents. Please specify:
- Path to requirements file, or
- Path to master plan/phase plans, or
- Confirm if requirements review should be skipped
```

**No recent changes:**
```markdown
No recent changes detected. Please specify:
- Commit range to review (e.g., main..feature-branch), or
- Specific files to review, or
- Whether to review all uncommitted changes
```

**One or more agents fail:**
```markdown
Unable to complete [agent-name] review: [reason]
Continuing with remaining reviews...

[Present reports from successful agents]

Note: [agent-name] review incomplete. May need to run separately.
```

**Security review not applicable:**
```markdown
No security-sensitive code detected in recent changes.
Security review skipped. If this is incorrect, specify which files to review.
```

## Tips for Effective Reviews

### Before Running Review

1. **Commit your changes:** Ensures git diff captures all work
2. **Identify requirements:** Know which requirements document to validate against
3. **Check scope:** Confirm if reviewing specific branch or commit range

### Interpreting Results

1. **Focus on Critical items first:** Address high-priority issues before warnings
2. **Cross-reference findings:** Same issue may appear in multiple reports
3. **Balance thoroughness with pragmatism:** Not every recommendation needs immediate action

### After Review

1. **Create tasks:** Convert findings into actionable tasks
2. **Prioritize fixes:** Address critical issues before proceeding
3. **Update requirements:** If requirements changed, update documentation

## Common Usage Patterns

### Pattern 1: Phase Completion Review

```
User: "I've completed Phase 3, run comprehensive review against phase-3.md"

Expected flow:
1. Locate docs/phase-3.md
2. Get recent changes since Phase 3 started
3. Launch all 5 agents with phase-3.md as requirements
4. Present consolidated report
```

### Pattern 2: Pre-PR Review

```
User: "Review my feature branch before I create a PR"

Expected flow:
1. Determine feature branch and base branch
2. Get changes: git diff main..feature-branch
3. Find relevant requirements in requirements/ or plans/
4. Launch all 5 agents
5. Present consolidated report with PR readiness assessment
```

### Pattern 3: Post-Implementation Validation

```
User: "Check if my authentication feature implementation is complete"

Expected flow:
1. Look for authentication requirements in requirements/
2. Find authentication-related changes in recent commits
3. Launch all 5 agents focused on authentication code
4. Present findings specifically about authentication implementation
```

## Agent Descriptions

For reference, the five agents provide:

- **product-reviewer:** Compares implementation against requirements documents, identifies missing or incomplete features
- **code-reviewer-business-logic:** Verifies business logic is testable and has proper unit test coverage
- **code-reviewer-edge-case:** Identifies unhandled edge cases, boundary conditions, and error scenarios
- **code-reviewer-architecture:** Reviews architectural alignment with clean architecture and 8-phase structure
- **code-reviewer-security:** Identifies security vulnerabilities (OWASP Top 10), authentication flaws, injection risks, sensitive data exposure, and provides remediation guidance

## Performance Notes

- **Parallel execution:** All agents run simultaneously, total time ≈ slowest agent (not sum of all)
- **Average review time:** 2-5 minutes depending on change scope
- **Token efficiency:** Agents use Haiku model for cost-effective reviews

## Additional Resources

### Reference Files

For understanding individual agent capabilities:
- **`references/agent-capabilities.md`** - Detailed description of each agent's analysis
- **`references/review-interpretation.md`** - How to interpret and act on findings

### Example Reviews

Working examples in `examples/`:
- **`phase-completion-review.md`** - Example of phase completion review
- **`pr-readiness-review.md`** - Example of pre-PR review

## Limitations

This skill cannot:
- Fix issues automatically (only identifies them)
- Modify code or tests
- Make architectural decisions (only provides recommendations)
- Replace human code review (complements it)

Use this skill as part of a comprehensive quality assurance process, not as a replacement for human judgment and testing.
