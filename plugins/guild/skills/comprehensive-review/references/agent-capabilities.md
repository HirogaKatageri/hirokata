# Agent Capabilities Reference

Quick reference for understanding what each review agent analyzes and how to interpret its output. For full agent details, see the agent definition files in `agents/`.

## Agent Summary

| Agent | Focus | Key Metric | Severity Levels |
|---|---|---|---|
| product-reviewer | Requirements compliance | Implementation % | Not Implemented / Partial / Fully Implemented |
| reviewer-business-logic | Testability & test coverage | Test coverage % | Untestable / Missing Tests / Partial Coverage |
| reviewer-edge-case | Unhandled edge cases | Critical count | Critical / Warning / Info |
| reviewer-architecture | Clean architecture alignment | Dependency compliance % | Critical Violations / Warnings / Recommendations |
| reviewer-security | OWASP Top 10 vulnerabilities | Vulnerability count by severity | Critical / High / Medium / Low / Info |

## Cross-Agent Insights

### Issue Overlap
Some issues appear in multiple reports:
- **Business logic in UI:** Flagged by architecture agent (layer violation) and business-logic agent (testability issue)
- **Untestable external dependencies:** Flagged by business-logic agent (testability) and architecture agent (tight coupling)
- **Missing validation:** Flagged by edge-case agent (unhandled inputs), architecture agent (responsibility misplacement), and security agent (injection risk)
- **Authentication flaws:** Flagged by security agent (vulnerability) and potentially architecture agent (layer violation)

### Complementary Analysis
Agents provide different perspectives on the same code:
- Product reviewer: "Is feature X implemented?"
- Business-logic reviewer: "Is feature X testable and tested?"
- Edge-case reviewer: "Does feature X handle all edge cases?"
- Architecture reviewer: "Is feature X in the right layer?"
- Security reviewer: "Is feature X safe from attack?"

### Priority Determination
When consolidating reports, prioritize:
1. **Critical + Critical:** Issue flagged as critical by multiple agents
2. **Security critical + any other critical:** Security issues always take precedence
3. **Requirement gap + Architecture violation:** Missing feature with structural problems
4. **Untestable + Missing tests:** Code that can't be tested and isn't tested
5. **Edge case + Architecture issue:** Safety concern with design problem

## Using Agent Reports Together

### Step 1: Review Executive Summary
Check overall status across all five dimensions.

### Step 2: Address Critical Issues First
Focus on: missing critical requirements, untestable business logic, critical edge cases, architectural dependency violations, security vulnerabilities.

### Step 3: Plan Medium-Priority Work
Address: partially implemented requirements, missing test coverage, warning-level edge cases, architectural warnings.

### Step 4: Consider Long-Term Improvements
Evaluate: architectural recommendations, defensive programming improvements, test coverage enhancements, refactoring opportunities.

## Agent Limitations

- Cannot fix issues automatically or make architectural decisions
- Cannot understand business context without documentation
- Cannot detect runtime-only issues or evaluate UX/design quality
- Supplement with domain expertise, performance profiling, penetration testing, and human UX review as needed

## Performance Characteristics

- **Parallel execution:** All 5 agents run concurrently, total time ~2-3 minutes
- **All review agents use Haiku model:** Cost-effective and fast for structured analysis
- **Scalability:** Small changes ~2-3 min, medium ~3-5 min, large ~5-10 min
