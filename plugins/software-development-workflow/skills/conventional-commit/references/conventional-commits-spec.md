# Conventional Commits Specification

## Summary

The Conventional Commits specification is a lightweight convention on top of commit messages. It provides an easy set of rules for creating an explicit commit history, which makes it easier to write automated tools on top of.

## Full Specification

### Commit Message Structure

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

### Components

#### Type (Required)

The type communicates the intent of the change:

**Primary Types:**
- `feat`: A new feature (correlates with MINOR in SemVer)
- `fix`: A bug fix (correlates with PATCH in SemVer)

**Additional Types (from Angular convention):**
- `build`: Changes affecting build system or external dependencies (webpack, npm, etc.)
- `ci`: Changes to CI configuration files and scripts (GitHub Actions, CircleCI, etc.)
- `docs`: Documentation only changes
- `perf`: Performance improvements
- `refactor`: Code change that neither fixes a bug nor adds a feature
- `style`: Changes that don't affect code meaning (white-space, formatting, semicolons, etc.)
- `test`: Adding missing tests or correcting existing tests
- `chore`: Other changes that don't modify src or test files (updating dependencies, etc.)
- `revert`: Reverts a previous commit

#### Scope (Optional)

A scope provides additional contextual information about the affected component or module:

**Examples:**
- `feat(parser): add ability to parse arrays`
- `fix(api): handle null pointer exception`
- `docs(readme): update installation steps`
- `refactor(auth): simplify token validation logic`

**Scope Guidelines:**
- Use lowercase
- Keep it short (one word when possible)
- Be consistent across your project
- Common scopes: `api`, `ui`, `auth`, `db`, `parser`, `core`, `cli`

#### Description/Subject (Required)

The description is a short summary of the code change:

**Rules:**
- Use imperative, present tense: "change" not "changed" nor "changes"
- Don't capitalize the first letter
- No period (.) at the end
- Maximum 50 characters (hard limit: 72 characters)
- Be concise but descriptive

**Good Examples:**
- `add user authentication endpoint`
- `fix memory leak in connection pool`
- `update dependencies to latest versions`

**Bad Examples:**
- `Added user authentication endpoint` (past tense)
- `Fix Memory Leak In Connection Pool` (capitalized)
- `updates` (too vague)
- `Fix bug` (not descriptive enough)

#### Body (Optional)

The body provides additional context about the change:

**When to include:**
- The change is complex or non-obvious
- Need to explain the motivation for the change
- Need to contrast current behavior with previous behavior
- Multiple related changes in one commit

**Guidelines:**
- Wrap at 72 characters per line
- Use imperative mood like in subject
- Explain what and why, not how (code explains how)
- Separate from subject with a blank line
- Can use bullet points (use `-` or `*`)

**Example:**
```
feat(api): add rate limiting to API endpoints

Add configurable rate limiting to prevent abuse and ensure
fair usage across all clients. Uses token bucket algorithm
with Redis for distributed rate limit tracking.

- Support per-user and per-IP rate limits
- Configurable limits via environment variables
- Return standard 429 Too Many Requests responses
```

#### Footer (Optional)

The footer contains additional information:

**Breaking Changes:**
```
BREAKING CHANGE: <description>
```

Breaking changes must be indicated in the footer or by appending `!` after type/scope:
```
feat!: remove deprecated API endpoints

BREAKING CHANGE: The /api/v1/users endpoint has been removed.
Clients should use /api/v2/users instead.
```

**Issue References:**
```
Fixes #123
Closes #456, #789
Resolves #234
Related to #567
```

**Other Footers:**
```
Reviewed-by: John Doe
Co-authored-by: Jane Smith <jane@example.com>
Signed-off-by: Developer Name <dev@example.com>
```

### Complete Examples

#### Simple Feature
```
feat(auth): add password reset functionality
```

#### Bug Fix with Body
```
fix(parser): prevent crash on malformed JSON input

Add validation to check for null bytes before parsing.
Previously, null bytes would cause the parser to crash
with an unhandled exception.

Fixes #456
```

#### Breaking Change
```
feat(api)!: redesign authentication flow

BREAKING CHANGE: The authentication endpoints have been
redesigned to use OAuth 2.0 instead of custom tokens.
Clients must update to use the new /oauth/token endpoint.

Migration guide: docs/migration/oauth.md

Closes #789
```

#### Chore with Multiple Changes
```
chore(deps): update production dependencies

- Update express from 4.17.1 to 4.18.2
- Update mongoose from 6.0.0 to 6.8.0
- Update dotenv from 10.0.0 to 16.0.3

All updates tested in staging environment.
```

#### Refactor with Explanation
```
refactor(database): optimize query performance

Rewrite user lookup queries to use indexed fields and
reduce database roundtrips from 3 to 1 per request.

Performance improvements:
- Average response time: 250ms → 45ms
- 95th percentile: 800ms → 120ms

Related to #567
```

## Breaking Changes

Breaking changes must be clearly indicated:

**Option 1: Use `!` after type/scope**
```
feat(api)!: remove support for API v1
```

**Option 2: Use BREAKING CHANGE in footer**
```
feat(api): update authentication endpoints

BREAKING CHANGE: API v1 endpoints have been removed.
All clients must migrate to API v2.
```

**Option 3: Both**
```
feat(api)!: remove deprecated endpoints

BREAKING CHANGE: The following endpoints are no longer available:
- POST /api/v1/users (use POST /api/v2/users)
- GET /api/v1/auth (use GET /api/v2/oauth)
```

## Benefits

### For Humans

1. **Clarity**: Quickly understand the nature of changes
2. **Navigation**: Easy to scan git log for specific types
3. **Context**: Commit message provides motivation and reasoning
4. **History**: Better understanding of project evolution

### For Tools

1. **Automated Changelogs**: Generate changelogs from commit history
2. **Semantic Versioning**: Automatically determine version bumps
3. **Release Notes**: Auto-generate release notes
4. **CI/CD**: Trigger different pipelines based on commit type
5. **Code Review**: Filter commits by type for focused reviews

## Common Patterns

### Feature Development
```
feat(auth): add OAuth 2.0 support
test(auth): add OAuth flow integration tests
docs(auth): document OAuth configuration
```

### Bug Fix
```
fix(api): handle timeout errors gracefully
test(api): add timeout error test cases
```

### Refactoring
```
refactor(core): extract validation logic to separate module
test(core): update tests for refactored validation
```

### Documentation
```
docs(api): add examples for all endpoints
docs(readme): update quick start guide
```

### Dependency Management
```
build(deps): update all non-breaking dependencies
build(deps-dev): update development dependencies
```

## Anti-Patterns

### Too Vague
```
❌ fix: fix bug
❌ chore: update stuff
❌ feat: improvements
```

**Better:**
```
✅ fix(parser): handle empty input arrays
✅ chore(deps): update lodash to 4.17.21
✅ feat(ui): add dark mode toggle
```

### Past Tense
```
❌ feat: added new feature
❌ fix: fixed the bug
❌ docs: updated readme
```

**Better:**
```
✅ feat: add new feature
✅ fix: resolve race condition
✅ docs: update installation guide
```

### Too Long Subject
```
❌ feat(api): add a new endpoint that allows users to reset their password by sending an email with a reset link
```

**Better:**
```
✅ feat(api): add password reset endpoint

Send password reset email with time-limited token.
Users can reset password using link in email.
```

### Mixed Changes
```
❌ feat: add login feature and fix header bug and update docs
```

**Better (separate commits):**
```
✅ feat(auth): add login feature
✅ fix(ui): correct header alignment
✅ docs: update authentication guide
```

### Missing Context
```
❌ fix: update function
```

**Better:**
```
✅ fix(auth): prevent token expiration race condition

Add 5-second grace period when validating tokens to
account for clock skew between servers.
```

## Commit Frequency

### Good Practices

**Commit often:**
- Each logical change should be a separate commit
- Easier to review
- Easier to revert if needed
- Better git bisect experience

**Not too often:**
- Avoid commits like "fix typo", "oops forgot file"
- Use `git commit --amend` for fixing the last commit
- Consider squashing related WIP commits before merging

**Ideal commit:**
- Represents one complete, logical change
- Passes all tests
- Builds successfully
- Can be reverted without breaking the codebase

## Semantic Versioning Correlation

Conventional commits enable automated semantic versioning:

- `fix:` → PATCH version (0.0.X)
- `feat:` → MINOR version (0.X.0)
- `BREAKING CHANGE:` or `!` → MAJOR version (X.0.0)

**Example version progression:**

```
1.0.0 → Initial release

fix(api): handle null responses
1.0.1 → Patch version bump

feat(ui): add export button
1.1.0 → Minor version bump

feat(api)!: redesign authentication
2.0.0 → Major version bump
```

## Tools and Integrations

### Commitizen
Interactive commit message builder:
```bash
npm install -g commitizen
git cz  # Interactive commit
```

### Commitlint
Lint commit messages:
```bash
npm install --save-dev @commitlint/cli @commitlint/config-conventional
```

### Standard Version
Automated versioning and changelog:
```bash
npm install --save-dev standard-version
npm run release
```

### Semantic Release
Fully automated versioning and publishing:
```bash
npm install --save-dev semantic-release
```

### Conventional Changelog
Generate changelogs:
```bash
npm install -g conventional-changelog-cli
conventional-changelog -p angular -i CHANGELOG.md -s
```

## Project-Specific Conventions

Teams can extend the specification:

**Custom types:**
```
security: security improvements
a11y: accessibility improvements
i18n: internationalization changes
```

**Custom scopes:**
```
feat(mobile-app): add offline mode
feat(web-app): add offline mode
feat(api-gateway): add rate limiting
```

**Footer conventions:**
```
Reviewed-by: Team Lead <lead@example.com>
Tested-by: QA Team <qa@example.com>
Performance: 2x faster than previous implementation
```

## References

- Official Specification: https://www.conventionalcommits.org/
- Angular Commit Guidelines: https://github.com/angular/angular/blob/main/CONTRIBUTING.md
- Semantic Versioning: https://semver.org/