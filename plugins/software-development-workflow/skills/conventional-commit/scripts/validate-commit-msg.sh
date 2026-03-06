#!/bin/bash
# Validate conventional commit message format
#
# Usage:
#   ./validate-commit-msg.sh "feat(auth): add login feature"
#   echo "fix: resolve bug" | ./validate-commit-msg.sh
#   ./validate-commit-msg.sh < commit-msg.txt

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get commit message from argument or stdin
if [ -n "$1" ]; then
    COMMIT_MSG="$1"
else
    COMMIT_MSG=$(cat)
fi

# Extract first line (subject)
SUBJECT=$(echo "$COMMIT_MSG" | head -n1)

# Conventional commit pattern
# Format: type(scope): subject
# Type: feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert
# Scope: optional, alphanumeric with hyphens
# Subject: required, starts with lowercase

TYPE_PATTERN="^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)"
SCOPE_PATTERN="(\([a-z0-9-]+\))?"
BREAKING_PATTERN="!?"
SEPARATOR=": "
SUBJECT_PATTERN=".+"

FULL_PATTERN="${TYPE_PATTERN}${SCOPE_PATTERN}${BREAKING_PATTERN}${SEPARATOR}${SUBJECT_PATTERN}"

# Validation flags
VALID=true
ERRORS=()
WARNINGS=()

echo "Validating commit message..."
echo ""
echo "Subject: $SUBJECT"
echo ""

# Check if subject matches pattern
if ! echo "$SUBJECT" | grep -Eq "$FULL_PATTERN"; then
    VALID=false
    ERRORS+=("Subject does not match conventional commit format")
    ERRORS+=("Expected: <type>(<scope>): <subject>")
    ERRORS+=("Example: feat(auth): add login feature")
fi

# Check subject length (recommended: ≤50, hard limit: ≤72)
SUBJECT_LENGTH=${#SUBJECT}
if [ $SUBJECT_LENGTH -gt 72 ]; then
    VALID=false
    ERRORS+=("Subject line too long: $SUBJECT_LENGTH chars (max: 72)")
elif [ $SUBJECT_LENGTH -gt 50 ]; then
    WARNINGS+=("Subject line longer than recommended: $SUBJECT_LENGTH chars (recommended: ≤50)")
fi

# Extract components if pattern matches
if echo "$SUBJECT" | grep -Eq "$FULL_PATTERN"; then
    # Extract type
    TYPE=$(echo "$SUBJECT" | sed -E 's/^([a-z]+).*/\1/')

    # Extract scope if present
    if echo "$SUBJECT" | grep -q '('; then
        SCOPE=$(echo "$SUBJECT" | sed -E 's/^[a-z]+\(([^)]+)\).*/\1/')
    else
        SCOPE=""
    fi

    # Check for breaking change indicator
    if echo "$SUBJECT" | grep -q '!:'; then
        HAS_BREAKING_INDICATOR=true
    else
        HAS_BREAKING_INDICATOR=false
    fi

    # Extract description after ': '
    DESCRIPTION=$(echo "$SUBJECT" | sed -E 's/^[^:]+: //')

    echo "Type: $TYPE"
    [ -n "$SCOPE" ] && echo "Scope: $SCOPE" || echo "Scope: (none)"
    [ "$HAS_BREAKING_INDICATOR" = true ] && echo "Breaking change indicator: yes"
    echo "Description: $DESCRIPTION"
    echo ""

    # Check description starts with lowercase
    FIRST_CHAR=$(echo "$DESCRIPTION" | cut -c1)
    if echo "$FIRST_CHAR" | grep -q '[A-Z]'; then
        WARNINGS+=("Description should start with lowercase letter")
    fi

    # Check description doesn't end with period
    if echo "$DESCRIPTION" | grep -q '\.$'; then
        WARNINGS+=("Description should not end with a period")
    fi

    # Check for imperative mood (heuristic: should not end with 'ed' or 's')
    FIRST_WORD=$(echo "$DESCRIPTION" | awk '{print $1}')
    if echo "$FIRST_WORD" | grep -Eq '(ed|es|s)$'; then
        WARNINGS+=("Use imperative mood in description (e.g., 'add' not 'added' or 'adds')")
    fi
fi

# Check body (if present)
BODY=$(echo "$COMMIT_MSG" | tail -n +3)
if [ -n "$BODY" ]; then
    echo "Body: present"

    # Check for blank line after subject
    SECOND_LINE=$(echo "$COMMIT_MSG" | sed -n '2p')
    if [ -n "$SECOND_LINE" ]; then
        WARNINGS+=("Missing blank line between subject and body")
    fi

    # Check body line lengths
    while IFS= read -r line; do
        LINE_LENGTH=${#line}
        if [ $LINE_LENGTH -gt 72 ]; then
            WARNINGS+=("Body line exceeds 72 characters: '$line'")
        fi
    done <<< "$BODY"

    # Check for breaking change in footer
    if echo "$BODY" | grep -q '^BREAKING CHANGE:'; then
        echo "Breaking change: documented in footer"
    fi
fi

echo ""

# Print warnings
if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo -e "${YELLOW}⚠ Warnings:${NC}"
    for warning in "${WARNINGS[@]}"; do
        echo -e "  ${YELLOW}•${NC} $warning"
    done
    echo ""
fi

# Print errors
if [ ${#ERRORS[@]} -gt 0 ]; then
    echo -e "${RED}✗ Errors:${NC}"
    for error in "${ERRORS[@]}"; do
        echo -e "  ${RED}•${NC} $error"
    done
    echo ""
fi

# Final result
if [ "$VALID" = true ]; then
    if [ ${#WARNINGS[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ Commit message is valid${NC}"
        exit 0
    else
        echo -e "${YELLOW}✓ Commit message is valid (with warnings)${NC}"
        exit 0
    fi
else
    echo -e "${RED}✗ Commit message is invalid${NC}"
    exit 1
fi