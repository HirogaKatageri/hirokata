# Commit Patterns and Anti-Patterns

## Common Scenarios and Best Practices

### Scenario 1: Multiple Related File Changes

**Situation:** Changed 5 files all related to adding user authentication.

**Anti-Pattern:**
```
❌ Commit 1: feat(auth): add login form
❌ Commit 2: feat(auth): add validation
❌ Commit 3: feat(auth): add API call
❌ Commit 4: feat(auth): add error handling
❌ Commit 5: feat(auth): add tests
```

**Better Pattern:**
```
✅ Commit 1: feat(auth): add user login feature

Implement complete login flow including form validation,
API integration, and error handling.

- Add login form component with email/password fields
- Implement client-side validation
- Integrate with authentication API
- Add comprehensive error messages
- Include unit and integration tests

Closes #123
```

**When to split:** If tests, documentation, and implementation are substantial, consider:
```
✅ Commit 1: feat(auth): add user login feature
✅ Commit 2: test(auth): add login flow test coverage
✅ Commit 3: docs(auth): document authentication flow
```

### Scenario 2: Bug Fix with Test

**Anti-Pattern:**
```
❌ fix: fixed a bug
```

**Better Pattern:**
```
✅ fix(parser): prevent null pointer exception on empty input

Add validation to check for null/undefined before parsing.
Previously, passing null would crash the parser.

- Add null check in parse() function
- Return empty result for null input
- Add test case for null input

Fixes #456
```

### Scenario 3: Refactoring Without Behavior Change

**Anti-Pattern:**
```
❌ refactor: code cleanup
```

**Better Pattern:**
```
✅ refactor(auth): extract token validation into separate module

Move token validation logic from AuthService to new
TokenValidator class for better separation of concerns
and testability. No behavior changes.

- Create TokenValidator class
- Update AuthService to use TokenValidator
- Update tests to match new structure
```

**Key:** Emphasize "no behavior change" to assure reviewers.

### Scenario 4: Multiple Unrelated Changes

**Anti-Pattern:**
```
❌ chore: fix login bug, update dependencies, improve docs
```

**Better Pattern (separate commits):**
```
✅ Commit 1: fix(auth): resolve session timeout issue
✅ Commit 2: build(deps): update lodash to 4.17.21
✅ Commit 3: docs(readme): clarify installation steps
```

**Why:** Each commit can be reviewed, reverted, or cherry-picked independently.

### Scenario 5: Work in Progress

**Anti-Pattern:**
```
❌ Commit 1: WIP
❌ Commit 2: WIP still working
❌ Commit 3: almost done
❌ Commit 4: done for real this time
```

**Better Pattern:**
```
✅ Use interactive rebase to squash WIP commits before pushing:

git rebase -i HEAD~4
# Squash commits 2-4 into commit 1
# Edit final commit message to be meaningful

Result: feat(dashboard): add analytics visualization widget
```

### Scenario 6: Emergency Hotfix

**Acceptable (time-sensitive):**
```
✅ fix(critical): patch security vulnerability in auth

CVE-2024-XXXX: Update jsonwebtoken to 9.0.2 to fix
token signature verification bypass.

SECURITY: Immediate deployment required
Fixes #999
```

**Key:** Even in emergencies, provide context. Security fixes need clear documentation.

### Scenario 7: Configuration Changes

**Anti-Pattern:**
```
❌ chore: update config
```

**Better Pattern:**
```
✅ ci(github): add automated security scanning

Add Dependabot and CodeQL to GitHub Actions workflow
to automatically detect dependency vulnerabilities and
code security issues.

- Configure Dependabot for daily checks
- Add CodeQL for JavaScript and TypeScript
- Set up notifications for security findings
```

### Scenario 8: Dependency Updates

**Anti-Pattern:**
```
❌ chore: npm update
```

**Better Patterns:**

**Security update:**
```
✅ build(deps): update express to 4.18.2 for security fix

Addresses CVE-2024-XXXX vulnerability in body-parser.
Breaking changes: None
Migration needed: No
```

**Breaking dependency update:**
```
✅ build(deps)!: upgrade React to version 18

BREAKING CHANGE: React 18 introduces automatic batching
and new concurrent features. Some lifecycle methods are
deprecated.

Migration guide: docs/react-18-migration.md

- Update all React packages to 18.x
- Replace deprecated componentWillMount calls
- Update testing utilities
```

**Routine updates:**
```
✅ build(deps): update development dependencies

Update testing and build tools to latest versions.
No production dependencies changed.

- jest: 27.0.0 → 28.1.0
- eslint: 8.0.0 → 8.25.0
- prettier: 2.5.0 → 2.7.1
```

## Grouping Strategies

### Strategy 1: By Feature Track

**Use when:** Implementing a complete feature with multiple components.

```
Commit 1: feat(api): add user profile endpoints
Commit 2: feat(ui): add user profile page
Commit 3: test(profile): add profile feature test suite
Commit 4: docs(api): document profile endpoints
```

**Benefits:**
- Clear feature boundary
- Easy to review feature implementation
- Can revert entire feature if needed

### Strategy 2: By Layer

**Use when:** Changes affect multiple layers of architecture.

```
Commit 1: feat(models): add Comment model and schema
Commit 2: feat(services): add comment business logic
Commit 3: feat(api): add comment REST endpoints
Commit 4: feat(ui): add comment display component
Commit 5: test: add comment feature test coverage
```

**Benefits:**
- Follows clean architecture principles
- Each layer can be reviewed independently
- Clear dependencies between commits

### Strategy 3: By Type

**Use when:** Making similar changes across codebase.

```
Commit 1: refactor(core): standardize error handling
Commit 2: refactor(api): apply new error handling
Commit 3: refactor(ui): apply new error handling
Commit 4: test: update tests for new error handling
```

**Benefits:**
- Easy to understand the scope of change
- Consistent pattern across commits

### Strategy 4: Atomic Commits

**Use when:** Each change is independently useful.

```
Commit 1: fix(auth): prevent token expiration race condition
Commit 2: perf(db): add index on user.email for faster lookup
Commit 3: docs(api): add examples for pagination
```

**Benefits:**
- Each commit is independently revertable
- Easier bisecting for bugs
- Cleaner git history

## Commit Size Guidelines

### Too Small
```
❌ Commit 1: add file
❌ Commit 2: add another file
❌ Commit 3: fix typo
❌ Commit 4: add missing semicolon
```

**Problem:** Cluttered history, hard to review, meaningless on their own.

### Too Large
```
❌ Commit 1: feat: implement entire e-commerce platform
(150 files changed, 10,000+ lines)
```

**Problem:** Impossible to review, hard to debug, can't revert safely.

### Just Right
```
✅ Commit 1: feat(cart): add shopping cart functionality
(8 files changed, 450 lines)

- Add cart model and state management
- Create add/remove/update cart components
- Implement cart persistence in localStorage
- Add cart summary and checkout button

Tests and documentation included.
```

**Sweet spot:** 1 logical feature, reviewable in 10-15 minutes.

## Type Selection Guide

### feat vs fix vs refactor

**feat:** Adds new capability users can see/use
```
✅ feat(ui): add dark mode toggle
✅ feat(api): add export to PDF functionality
```

**fix:** Repairs broken functionality
```
✅ fix(ui): correct button alignment in mobile view
✅ fix(api): handle timeout errors gracefully
```

**refactor:** Improves code without changing functionality
```
✅ refactor(auth): simplify token validation logic
✅ refactor(db): extract query builders to separate module
```

**Edge cases:**

Performance improvement that changes behavior:
```
✅ perf(search): add caching to reduce load time by 80%
```

Performance improvement by refactoring:
```
✅ perf(parser): optimize regex patterns for faster parsing

Refactor regex compilation to happen once at initialization
rather than on each parse call.
```

### test vs feat with tests

**Standalone test commits:**
```
✅ test(auth): add missing test coverage for edge cases
✅ test(api): add integration tests for error scenarios
```

**Tests with feature:**
```
✅ feat(profile): add user avatar upload

Implementation includes comprehensive test coverage.
```

**Guideline:** If tests are added significantly after feature implementation, use separate `test:` commit. If developed together, include in feature commit.

### docs vs feat with docs

**Standalone documentation:**
```
✅ docs(api): add comprehensive API reference
✅ docs(readme): update installation guide
```

**Docs with feature:**
```
✅ feat(webhooks): add webhook notification system

Includes API documentation and webhook setup guide.
```

**Guideline:** Major documentation overhauls → separate commit. Inline documentation with feature → include in feature commit.

### chore vs build vs ci

**chore:** Miscellaneous maintenance
```
✅ chore: update license year to 2024
✅ chore(scripts): add utility script for database seeding
```

**build:** Build system or dependencies
```
✅ build(webpack): optimize bundle size configuration
✅ build(deps): update production dependencies
```

**ci:** Continuous Integration changes
```
✅ ci(github): add automated deployment workflow
✅ ci(jest): configure code coverage reporting
```

## Scope Best Practices

### Consistent Scopes

**Define project scopes upfront:**
```
Frontend: ui, components, styles, layout
Backend: api, services, models, database
Infrastructure: ci, build, docker, deploy
Features: auth, profile, cart, search, admin
```

### Hierarchical Scopes

**For large projects, use hierarchy:**
```
feat(api/auth): add OAuth2 support
feat(api/users): add user search endpoint
feat(ui/auth): add login form
feat(ui/dashboard): add analytics widgets
```

### Multiple Scopes

**When change affects multiple scopes:**

**Option 1: Most significant scope**
```
✅ feat(api): add user profile with UI components
```

**Option 2: Multiple scopes (less common)**
```
✅ feat(api,ui): add user profile feature
```

**Option 3: Separate commits (preferred)**
```
✅ Commit 1: feat(api): add user profile endpoints
✅ Commit 2: feat(ui): add user profile page
```

### No Scope

**When no clear scope:**
```
✅ chore: update copyright year
✅ docs: fix typos across documentation
✅ style: apply prettier formatting
```

**Guideline:** Use scope when it adds meaningful context, omit when change is global or trivial.

## Footer Patterns

### Issue References

**Multiple issues:**
```
Fixes #123, Fixes #456
Closes #789
Related to #234, #567
```

**Complex relationships:**
```
Fixes #123 (login bug)
Closes #456 (password reset feature)
Related to #789 (authentication refactor)
```

### Breaking Changes

**Simple breaking change:**
```
BREAKING CHANGE: Remove deprecated /api/v1 endpoints
```

**Detailed breaking change:**
```
BREAKING CHANGE: Redesign authentication flow

The following endpoints are removed:
- POST /auth/login → Use POST /oauth/token
- GET /auth/user → Use GET /api/v2/users/me

Migration guide: docs/migration/oauth.md
Migration support until: 2024-12-31
```

### Co-Authors

**Pair programming:**
```
Co-authored-by: Jane Doe <jane@example.com>
Co-authored-by: Claude Sonnet 4.5 <noreply@anthropic.com>
```

### Review Information

**Additional context:**
```
Reviewed-by: Senior Dev <senior@example.com>
Tested-by: QA Team <qa@example.com>
Performance: 2x improvement in load time
Security: Addresses OWASP A1 injection vulnerability
```

## Review Checklist

Before committing, verify:

**Structure:**
- [ ] Type is appropriate and accurate
- [ ] Scope matches project conventions
- [ ] Subject is imperative, lowercase, under 50 chars
- [ ] Body explains what and why (if needed)
- [ ] Footer includes issue references and breaking changes

**Content:**
- [ ] Commit represents one logical change
- [ ] All tests pass
- [ ] Code builds successfully
- [ ] No unrelated changes included
- [ ] No WIP or temporary code

**Message Quality:**
- [ ] Subject is clear and descriptive
- [ ] Body provides sufficient context
- [ ] Breaking changes are clearly documented
- [ ] Commit would be understandable in 6 months

## Summary

**Golden Rules:**

1. **One commit, one logical change**
2. **Write for future developers (including yourself)**
3. **Explain what and why, not how**
4. **Be consistent with project conventions**
5. **Make commits that can be safely reverted**
6. **Test before committing**
7. **Review your own commits before pushing**

**Quick Decision Tree:**

```
Is this a new feature?
├─ Yes → feat:
└─ No → Is it fixing a bug?
    ├─ Yes → fix:
    └─ No → Is it changing behavior?
        ├─ Yes → refactor: or perf:
        └─ No → Is it tests/docs/deps?
            ├─ Tests → test:
            ├─ Docs → docs:
            ├─ Deps → build:
            └─ Other → chore: or ci: or style:
```