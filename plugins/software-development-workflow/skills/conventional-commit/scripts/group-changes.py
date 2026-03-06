#!/usr/bin/env python3
"""
Analyze git changes and suggest logical groupings for conventional commits.

Usage:
    python group-changes.py
    python group-changes.py --verbose
"""

import subprocess
import sys
import re
from pathlib import Path
from collections import defaultdict
from typing import Dict, List, Set, Tuple

class ChangeGrouper:
    """Analyzes git changes and suggests commit groupings."""

    # Conventional commit types
    COMMIT_TYPES = {
        'feat': 'New feature',
        'fix': 'Bug fix',
        'docs': 'Documentation',
        'style': 'Code style/formatting',
        'refactor': 'Code refactoring',
        'perf': 'Performance improvement',
        'test': 'Tests',
        'build': 'Build system/dependencies',
        'ci': 'CI/CD configuration',
        'chore': 'Maintenance/tooling'
    }

    # File patterns for type detection
    TYPE_PATTERNS = {
        'test': [r'test/', r'\.test\.', r'\.spec\.', r'__tests__/', r'tests/'],
        'docs': [r'\.md$', r'docs/', r'README', r'CHANGELOG'],
        'ci': [r'\.github/', r'\.gitlab-ci', r'\.circleci/', r'jenkinsfile', r'\.travis'],
        'build': [r'package\.json', r'package-lock\.json', r'yarn\.lock', r'Gemfile',
                  r'requirements\.txt', r'pom\.xml', r'build\.gradle', r'Makefile',
                  r'Dockerfile', r'docker-compose'],
        'style': [r'\.prettierrc', r'\.eslintrc', r'\.editorconfig']
    }

    def __init__(self, verbose: bool = False):
        self.verbose = verbose
        self.changed_files: List[str] = []
        self.file_status: Dict[str, str] = {}  # file -> status (M, A, D, etc.)

    def log(self, message: str):
        """Print message if verbose mode is enabled."""
        if self.verbose:
            print(f"[DEBUG] {message}")

    def run_git_command(self, cmd: List[str]) -> str:
        """Run a git command and return output."""
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=True
            )
            return result.stdout.strip()
        except subprocess.CalledProcessError as e:
            print(f"Error running git command: {e}", file=sys.stderr)
            return ""

    def get_changed_files(self):
        """Get list of changed files (staged and unstaged)."""
        # Get status for all changed files
        status_output = self.run_git_command(['git', 'status', '--porcelain'])

        for line in status_output.split('\n'):
            if not line:
                continue

            # Parse status line: "XY filename"
            status = line[:2]
            filename = line[3:].strip()

            # Handle renames (format: "old -> new")
            if ' -> ' in filename:
                filename = filename.split(' -> ')[1]

            self.changed_files.append(filename)
            self.file_status[filename] = status.strip()

        self.log(f"Found {len(self.changed_files)} changed files")

    def detect_file_type(self, filepath: str) -> str:
        """Detect the likely commit type based on file path."""
        filepath_lower = filepath.lower()

        for commit_type, patterns in self.TYPE_PATTERNS.items():
            for pattern in patterns:
                if re.search(pattern, filepath_lower):
                    return commit_type

        return 'feat'  # Default to feature

    def extract_scope(self, filepath: str) -> str:
        """Extract a scope from the file path."""
        path_parts = Path(filepath).parts

        # Skip common prefixes
        skip_parts = {'src', 'lib', 'app', 'components', 'pages', 'api', 'tests', 'test', '__tests__'}

        # Find first meaningful part
        for part in path_parts:
            if part not in skip_parts and not part.startswith('.'):
                # Remove file extension
                scope = Path(part).stem
                # Convert to lowercase and remove special chars
                scope = re.sub(r'[^a-z0-9-]', '', scope.lower())
                return scope

        return 'core'

    def group_by_directory(self) -> Dict[str, List[str]]:
        """Group files by their parent directory."""
        groups = defaultdict(list)

        for filepath in self.changed_files:
            directory = str(Path(filepath).parent)
            if directory == '.':
                directory = 'root'
            groups[directory].append(filepath)

        return dict(groups)

    def group_by_type(self) -> Dict[str, List[str]]:
        """Group files by detected commit type."""
        groups = defaultdict(list)

        for filepath in self.changed_files:
            file_type = self.detect_file_type(filepath)
            groups[file_type].append(filepath)

        return dict(groups)

    def group_by_scope(self) -> Dict[str, List[str]]:
        """Group files by extracted scope."""
        groups = defaultdict(list)

        for filepath in self.changed_files:
            scope = self.extract_scope(filepath)
            groups[scope].append(filepath)

        return dict(groups)

    def suggest_groupings(self) -> List[Dict]:
        """Suggest commit groupings based on analysis."""
        suggestions = []

        # Group by type first
        type_groups = self.group_by_type()

        for commit_type, files in type_groups.items():
            # Further group by scope within each type
            scope_groups = defaultdict(list)
            for filepath in files:
                scope = self.extract_scope(filepath)
                scope_groups[scope].append(filepath)

            # Create suggestion for each type+scope combination
            for scope, scope_files in scope_groups.items():
                suggestions.append({
                    'type': commit_type,
                    'scope': scope,
                    'files': scope_files,
                    'description': self.COMMIT_TYPES.get(commit_type, 'Change')
                })

        return suggestions

    def print_analysis(self):
        """Print analysis of changes and grouping suggestions."""
        print("=" * 70)
        print("Conventional Commit Grouping Analysis")
        print("=" * 70)
        print()

        print(f"Total changed files: {len(self.changed_files)}")
        print()

        # Show file status breakdown
        status_counts = defaultdict(int)
        for status in self.file_status.values():
            status_key = status[0] if status else '?'
            status_counts[status_key] += 1

        print("Status breakdown:")
        status_labels = {
            'M': 'Modified',
            'A': 'Added',
            'D': 'Deleted',
            'R': 'Renamed',
            '?': 'Untracked'
        }
        for status, count in sorted(status_counts.items()):
            label = status_labels.get(status, 'Unknown')
            print(f"  {label}: {count}")
        print()

        # Show grouping suggestions
        suggestions = self.suggest_groupings()

        print(f"Suggested commit groups: {len(suggestions)}")
        print()

        for i, suggestion in enumerate(suggestions, 1):
            commit_type = suggestion['type']
            scope = suggestion['scope']
            files = suggestion['files']
            description = suggestion['description']

            print(f"Group {i}: {commit_type}({scope})")
            print(f"  Type: {description}")
            print(f"  Files ({len(files)}):")
            for filepath in sorted(files):
                status = self.file_status.get(filepath, '??')
                print(f"    [{status}] {filepath}")
            print()

        # Provide recommendations
        print("=" * 70)
        print("Recommendations")
        print("=" * 70)
        print()

        num_groups = len(suggestions)

        if num_groups == 1:
            print("✓ Single logical group detected")
            print("  → Consider: Single large commit")
            print()
        elif num_groups <= 3:
            print("✓ Small number of groups detected")
            print("  → Recommended: Combined medium commits")
            print("  → Alternative: Separate small commits for detailed history")
            print()
        else:
            print("✓ Multiple distinct groups detected")
            print("  → Recommended: Separate small commits")
            print("  → Consider combining related groups if appropriate")
            print()

        # Show example commit messages
        print("Example commit messages:")
        print()

        for i, suggestion in enumerate(suggestions, 1):
            commit_type = suggestion['type']
            scope = suggestion['scope']

            # Generate example subject
            if commit_type == 'feat':
                subject = f"add {scope} feature"
            elif commit_type == 'fix':
                subject = f"resolve {scope} issues"
            elif commit_type == 'test':
                subject = f"add {scope} test coverage"
            elif commit_type == 'docs':
                subject = f"update {scope} documentation"
            else:
                subject = f"update {scope}"

            print(f"{i}. {commit_type}({scope}): {subject}")

        print()

def main():
    """Main entry point."""
    verbose = '--verbose' in sys.argv or '-v' in sys.argv

    # Check if we're in a git repository
    try:
        subprocess.run(
            ['git', 'rev-parse', '--git-dir'],
            capture_output=True,
            check=True
        )
    except subprocess.CalledProcessError:
        print("Error: Not a git repository", file=sys.stderr)
        sys.exit(1)

    # Create grouper and analyze
    grouper = ChangeGrouper(verbose=verbose)
    grouper.get_changed_files()

    if not grouper.changed_files:
        print("No changed files detected.")
        print("Run 'git status' to see the current state.")
        sys.exit(0)

    grouper.print_analysis()

if __name__ == '__main__':
    main()
