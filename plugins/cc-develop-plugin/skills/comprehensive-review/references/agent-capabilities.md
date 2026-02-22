# Agent Capabilities Reference

This document provides detailed information about each review agent's capabilities, analysis methods, and output formats.

## Product Reviewer Agent

### Purpose
Verifies that implementation satisfies all documented requirements from master plans, phase plans, and requirements documents.

### What It Analyzes
- Master plan files in `docs/` or `planning/`
- Phase plan files (phase-1.md through phase-7.md)
- Requirements documents in `requirements/` directory
- Recent git commits and changes
- Feature implementation completeness

### Analysis Process
1. Locates and reads all planning documents
2. Extracts requirements, user stories, and acceptance criteria
3. Reviews recent code changes via git
4. Maps requirements to implemented features
5. Identifies missing or incomplete functionality

### Report Structure
- **Summary:** Counts of implemented/partial/missing requirements
- **Fully Implemented:** Requirements with complete implementation
- **Partially Implemented:** Requirements with incomplete implementation
- **Not Implemented:** Requirements with no corresponding code
- **Recommendations:** Prioritized actions to close gaps

### Key Metrics
- Total requirements count
- Implementation percentage
- Partial implementation count
- Missing requirements count

### When It Flags Issues
- Required feature has no implementation
- Acceptance criteria not met
- Partial implementation without completion path
- Requirements documents modified but features unchanged

## Code Reviewer - Business Logic Agent

### Purpose
Ensures business logic is designed for testability and has adequate unit test coverage.

### What It Analyzes
- Business logic changes in services, models, rules, utilities
- Unit test files (*.test.ts, *.spec.ts, *_test.go, test_*.py)
- Testability patterns and anti-patterns
- Dependency injection and coupling
- Test coverage adequacy

### Analysis Process
1. Identifies business logic changes via git diff
2. Assesses code testability (DI, coupling, side effects)
3. Locates corresponding unit test files
4. Evaluates test coverage and quality
5. Identifies untestable code patterns

### Report Structure
- **Summary:** Test coverage statistics
- **Testability Issues:** Untestable code patterns with refactoring suggestions
- **Test Coverage Analysis:**
  - Well Tested: Complete coverage
  - Partially Tested: Missing test scenarios
  - Not Tested: No unit tests
- **Recommendations:** Prioritized by severity
- **Statistics:** Coverage ratios and metrics

### Key Metrics
- Business logic changes count
- Test coverage percentage
- Untestable code patterns count
- Missing test scenarios count

### When It Flags Issues
- Business logic has no unit tests
- Code has testability anti-patterns (hard-coded dependencies, static calls)
- Tests exist but don't cover key scenarios
- Integration tests only, no unit tests
- Business logic mixed with side effects

### Common Testability Anti-Patterns
- Static method calls to external systems
- Direct instantiation of dependencies (new SomeService())
- Hidden dependencies
- Global state modification
- Non-deterministic behavior (random, time-dependent)
- Tight coupling to frameworks or databases

## Code Reviewer - Edge Case Agent

### Purpose
Identifies unhandled edge cases, boundary conditions, error scenarios, and exceptional situations.

### What It Analyzes
- Input validation and handling
- Null/undefined/empty checks
- Numeric boundaries (zero, negative, max/min values)
- Collection edge cases (empty, single element, very large)
- Error scenarios (network, database, filesystem)
- Date/time edge cases
- Concurrency issues

### Analysis Process
1. Identifies changed code via git diff
2. Analyzes input handling and validation
3. Reviews data structure operations
4. Checks error scenario handling
5. Identifies boundary conditions
6. Reviews logic edge cases

### Report Structure
- **Summary:** Counts by severity
- **Critical Edge Cases:** High likelihood, high impact
- **Warning Edge Cases:** Medium likelihood/impact
- **Info Edge Cases:** Low likelihood/impact
- **Edge Cases Handled Well:** Positive examples
- **Recommendations:** Immediate actions and improvements
- **Testing Suggestions:** Specific test cases to add

### Key Metrics
- Critical edge cases count
- Warning edge cases count
- Info edge cases count
- Files reviewed count

### When It Flags Issues
- Null/undefined dereferencing without checks
- Empty collection access
- Division by zero possibility
- Array out-of-bounds access
- Unhandled exceptions or errors
- Missing input validation
- Boundary condition not handled

### Edge Case Categories
1. **Null/Undefined/Nil:** Missing null checks
2. **Empty Collections:** Empty array/string/object operations
3. **Numeric Boundaries:** Zero, negative, overflow, precision
4. **String Edge Cases:** Empty, very long, special characters, Unicode
5. **Date/Time:** Invalid dates, time zones, DST, leap years
6. **Concurrency:** Race conditions, deadlocks, stale reads
7. **External Dependencies:** Timeouts, rate limits, connection loss
8. **Array/Collection Access:** Off-by-one, out of bounds
9. **State Management:** Invalid transitions, uninitialized state
10. **Resource Management:** Leaks, exhaustion

## Code Reviewer - Architecture Agent

### Purpose
Reviews code for alignment with clean architecture principles and the 8-phase development structure.

### What It Analyzes
- Layer dependencies and dependency direction
- Architectural patterns and violations
- Code placement in correct layer/phase
- Clean architecture principle compliance
- Separation of concerns
- Framework coupling
- Interface design

### Analysis Process
1. Understands current architecture (reads README, docs)
2. Identifies changed code via git diff
3. Analyzes layer dependencies (imports/includes)
4. Reviews layer responsibilities
5. Identifies architectural anti-patterns
6. Checks architectural best practices

### Report Structure
- **Summary:** Counts and health assessment
- **Critical Violations:** Dependency rule violations
- **Architectural Warnings:** Anti-patterns and concerns
- **Layer Misplacements:** Code in wrong layer
- **Positive Patterns:** Good architectural decisions
- **Recommendations:** Immediate/important/long-term
- **Architecture Metrics:** Compliance scores
- **Debt Assessment:** Current debt level and paydown strategy

### Key Metrics
- Dependency direction compliance percentage
- Layer separation score
- Coupling level (low/medium/high)
- Code in correct layers percentage
- Architectural debt level

### When It Flags Issues
- Inner layer depends on outer layer (dependency rule violation)
- Business logic in UI components
- Data access in business logic (should be in repositories)
- Framework-specific code in domain models
- Circular dependencies
- God classes with too many responsibilities
- Tight coupling to frameworks

### Clean Architecture Principles Checked
1. **Dependency Rule:** Dependencies point inward
2. **Layer Separation:** Clear boundaries with interfaces
3. **Business Logic Independence:** No framework coupling
4. **Testability:** Inner layers easily testable

### 8-Phase Architecture Structure
- **Phase 1 - Foundational:** Config, constants, infrastructure (no business logic)
- **Phase 2 - Models/Entities:** Domain models (no external dependencies)
- **Phase 3 - Services/Use Cases:** Business logic (no UI/framework)
- **Phase 4 - Data Layer:** Repositories, API clients (implements Phase 3 interfaces)
- **Phase 5 - Business Rules:** Validation, authorization (pure rules)
- **Phase 6 - State Management:** Orchestration (delegates to Services)
- **Phase 7 - UI/Presentation:** Controllers, views (no business logic)
- **Phase 8 - Tests:** Unit tests, integration tests, e2e tests, test utilities (test code only)

### Common Architectural Anti-Patterns
- **Tight Coupling:** Direct instantiation instead of DI
- **Leaky Abstractions:** Implementation details in interfaces
- **Framework Lock-In:** Business logic coupled to framework
- **Anemic Domain Model:** Models with only getters/setters
- **Big Ball of Mud:** No clear structure
- **Circular Dependencies:** Modules depend on each other
- **God Class:** Single class handling too many concerns
- **Feature Envy:** Class using another class's data more than its own

## Code Reviewer - Security Agent

### Purpose
Identifies security vulnerabilities, weaknesses, and anti-patterns in code changes aligned with OWASP Top 10 and security best practices.

### What It Analyzes
- Injection vulnerabilities (SQL, command, LDAP, template injection)
- Authentication and session management flaws
- Sensitive data exposure (unencrypted PII, secrets in code, logging)
- Broken access control and authorization issues
- Security misconfigurations and weak cryptography
- Input validation and output encoding (XSS, CSRF)
- Hardcoded secrets, API keys, and credentials
- Insecure dependencies and transitive vulnerabilities

### Analysis Process
1. Identifies changed code via git diff
2. Scans for injection vulnerability patterns
3. Reviews authentication and authorization logic
4. Audits sensitive data handling and storage
5. Checks cryptographic usage and key management
6. Inspects error handling for information disclosure
7. Searches for hardcoded secrets

### Report Structure
- **Summary:** Vulnerability counts by severity and overall security posture
- **Critical Vulnerabilities:** RCE, auth bypass, direct data breach risks
- **High Vulnerabilities:** Privilege escalation, SQL injection, significant exposure
- **Medium Vulnerabilities:** XSS, CSRF, information disclosure, weak crypto
- **Low / Informational:** Security header gaps, verbose errors, best practice improvements
- **Secrets Audit:** Hardcoded credentials and sensitive data in logs
- **Security Strengths:** Good security practices already in use
- **Remediation Priority:** Prioritized action list with code examples

### Key Metrics
- Critical vulnerability count
- High vulnerability count
- Medium vulnerability count
- Overall security posture (Secure/Needs Attention/At Risk/Critical Risk)
- Secrets found (count)

### Severity Classification
- **Critical:** Remote code execution, authentication bypass, direct data breach
- **High:** Privilege escalation, SQL injection, significant data exposure
- **Medium:** XSS, CSRF, information disclosure, weak cryptography
- **Low:** Missing security headers, verbose errors, minor misconfigurations
- **Info:** Best practice improvements, defense-in-depth recommendations

### When It Flags Issues
- String concatenation in SQL queries or shell commands
- Missing authentication or authorization checks on protected resources
- Hardcoded passwords, API keys, or tokens in source code
- Use of deprecated cryptographic algorithms (MD5, SHA1, DES)
- Sensitive data (PII, credentials) written to logs
- Missing input validation on user-controlled data
- Insecure randomness for security-sensitive operations

## Cross-Agent Insights

### Issue Overlap
Some issues may appear in multiple reports:
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

## Interpreting Severity Levels

### Product Reviewer
- **Not Implemented:** High severity - missing required functionality
- **Partially Implemented:** Medium severity - incomplete features
- **Fully Implemented:** Good - requirements met

### Business Logic Reviewer
- **Untestable Code:** High severity - requires refactoring
- **Missing Tests:** Medium severity - needs test implementation
- **Partial Coverage:** Low severity - needs additional test cases

### Edge Case Reviewer
- **Critical:** High likelihood × high impact
- **Warning:** Medium likelihood or medium impact
- **Info:** Low likelihood and low impact

### Architecture Reviewer
- **Critical Violations:** Breaks architectural principles
- **Warnings:** Concerning patterns that should be addressed
- **Recommendations:** Improvements for long-term maintainability

## Using Agent Reports Together

### Step 1: Review Executive Summary
Check overall status across all four dimensions.

### Step 2: Address Critical Issues First
Focus on:
- Missing critical requirements
- Untestable business logic
- Critical edge cases (high likelihood + high impact)
- Architectural dependency violations

### Step 3: Plan Medium-Priority Work
Address:
- Partially implemented requirements
- Missing test coverage
- Warning-level edge cases
- Architectural warnings

### Step 4: Consider Long-Term Improvements
Evaluate:
- Architectural recommendations
- Defensive programming improvements
- Test coverage enhancements
- Refactoring opportunities

## Agent Limitations

### What Agents Cannot Do
- Fix issues automatically
- Make architectural decisions for you
- Understand business context without documentation
- Detect runtime-only issues
- Evaluate UX or design quality

### When to Supplement Agent Reviews
- **Business context:** Agents rely on documented requirements
- **Domain expertise:** Some edge cases require domain knowledge
- **Performance:** Agents don't profile or benchmark
- **Advanced security:** Penetration testing, threat modeling, and runtime security require human expertise beyond code analysis
- **UX/Design:** Human evaluation required

## Performance Characteristics

### Review Speed
- **Product reviewer:** ~1-2 minutes (depends on requirements size)
- **Business-logic reviewer:** ~1-2 minutes (depends on code changes)
- **Edge-case reviewer:** ~2-3 minutes (more thorough analysis)
- **Architecture reviewer:** ~1-2 minutes (depends on codebase size)
- **Security reviewer:** ~2-3 minutes (thorough vulnerability scanning)

**Parallel execution:** Total time ≈ slowest agent (~2-3 minutes)

### Token Efficiency
All agents use Haiku model:
- Cost-effective for routine reviews
- Fast response times
- Adequate for structured analysis tasks

### Scalability
Agents work well with:
- Small changes (single feature): Complete review in 2-3 minutes
- Medium changes (phase implementation): Complete review in 3-5 minutes
- Large changes (major refactor): May take 5-10 minutes

For very large changesets, consider reviewing in smaller chunks.
