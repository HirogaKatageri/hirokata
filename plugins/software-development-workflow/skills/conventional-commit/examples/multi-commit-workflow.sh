#!/bin/bash
# Example: Creating multiple conventional commits for a feature

# Scenario: Adding user authentication feature with separate commits
# for implementation, tests, and documentation

echo "=== Multi-Commit Workflow Example ==="
echo ""

# Step 1: Check current status
echo "Step 1: Check what needs to be committed"
git status

echo ""
echo "Step 2: Review changes"
git diff
git diff --cached

echo ""
echo "Step 3: Review recent commit style"
git log --oneline -10

echo ""
echo "=== Commit 1: Implementation ==="
echo "Staging implementation files..."

# Stage only implementation files
git add src/auth/login.ts
git add src/auth/session.ts
git add src/auth/token.ts

# Create commit with proper conventional format
git commit -m "$(cat <<'EOF'
feat(auth): add JWT-based authentication system

Implement complete authentication flow with login, session
management, and token refresh capabilities.

- Add login endpoint with email/password validation
- Implement JWT token generation and validation
- Add session management with Redis storage
- Implement automatic token refresh mechanism
- Add logout functionality

Closes #123

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
EOF
)"

echo "✓ Created implementation commit"
echo ""

echo "=== Commit 2: Tests ==="
echo "Staging test files..."

# Stage test files
git add tests/auth/login.test.ts
git add tests/auth/session.test.ts
git add tests/auth/token.test.ts

# Create test commit
git commit -m "$(cat <<'EOF'
test(auth): add comprehensive authentication test suite

Add unit and integration tests for authentication system
covering login, session, and token management.

- Add login endpoint tests (success, invalid credentials)
- Add session management tests (create, validate, destroy)
- Add token tests (generation, validation, refresh, expiry)
- Add integration tests for complete auth flows
- Achieve 95% code coverage for auth module

Related to #123

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
EOF
)"

echo "✓ Created test commit"
echo ""

echo "=== Commit 3: Documentation ==="
echo "Staging documentation files..."

# Stage documentation
git add docs/authentication.md
git add README.md

# Create documentation commit
git commit -m "$(cat <<'EOF'
docs(auth): add authentication system documentation

Document authentication flow, API endpoints, and
configuration options for the new auth system.

- Add authentication flow diagrams
- Document all auth API endpoints
- Add configuration guide for JWT settings
- Include troubleshooting section
- Update README with auth setup instructions

Related to #123

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
EOF
)"

echo "✓ Created documentation commit"
echo ""

# Verify all commits
echo "=== Verification ==="
echo "Recent commits:"
git log --oneline -3

echo ""
echo "Detailed view of commits:"
git log -3 --pretty=format:"%h %s%n%b%n" --stat

echo ""
echo "=== Workflow Complete ==="
echo "✓ Created 3 separate commits for implementation, tests, and docs"
echo "✓ All commits follow Conventional Commits format"
echo "✓ Each commit is independently reviewable"