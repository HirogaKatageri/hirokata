---
name: create-workflow
description: >
  This skill should be used when the user asks to "create a workflow",
  "generate a workflow", "add a GitHub Actions workflow", "create a CI/CD pipeline",
  "write a script workflow", "automate a task", "set up automation", or wants to
  build any kind of automated workflow (GitHub Actions, Python scripts, Node.js
  scripts, shell scripts, Makefiles, etc.). Interactively gathers goals and
  configuration, suggests file names, job names, and step names, then generates
  a complete ready-to-use workflow file.
version: 1.0.0
user-invocable: true
---

# Create Workflow

Interactively design and generate automation workflows — GitHub Actions pipelines,
Python scripts, Node.js scripts, shell scripts, Makefiles, and more.

## Purpose

Guide the user through designing a workflow by asking about their goal and preferred
type, detecting the project's tech stack to suggest relevant steps, then generating
a complete ready-to-use workflow file with sensible defaults.

---

## Workflow

### Step 1: Silently Scan the Project

Before asking the user anything, run these in parallel to detect context:

```bash
# Detect tech stack indicators
ls package.json requirements.txt Cargo.toml go.mod pom.xml build.gradle Gemfile pyproject.toml 2>/dev/null

# Check for existing workflows (avoid conflicts)
ls .github/workflows/ 2>/dev/null

# Check for existing scripts
ls Makefile scripts/ bin/ 2>/dev/null
```

Use the findings to:
- Pre-select sensible step suggestions (e.g., `npm test` for Node, `pytest` for Python)
- Surface a warning if a similar workflow file already exists
- Inform file path suggestions in later steps

### Step 2: Ask Core Questions

Use `AskUserQuestion` to ask both questions at once:

**Question 1 — Goal:**
> "What do you want this workflow to accomplish?"
>
> Examples: run tests on every PR, deploy to staging on push to main, lint code,
> build a Docker image, send a nightly report, sync data between services.

**Question 2 — Workflow type:**

| Option | Description |
|--------|-------------|
| GitHub Actions | YAML pipeline triggered by push, PR, schedule, or manual dispatch |
| Python Script | Standalone `.py` script, optionally called from CI |
| Node.js Script | Standalone `.js` / `.ts` script, runnable with `node` |
| Shell / Bash Script | Portable `.sh` script for system or CI tasks |
| Makefile | `make` targets for local dev and CI tasks |
| Other | User describes a custom format |

### Step 3: Gather Type-Specific Details

Based on the chosen type, ask follow-up questions with `AskUserQuestion`.

#### GitHub Actions

**Trigger(s)** — ask the user to pick one or more:

| Trigger | When to recommend |
|---------|-------------------|
| `push` to main | Run on every commit to the default branch |
| `pull_request` | Run on every PR open / update |
| `schedule` (cron) | Recurring job — nightly, weekly, etc. |
| `workflow_dispatch` | Manual trigger with optional inputs |
| `release` | Run when a release is published |

**Runner:**

| Runner | Use case |
|--------|----------|
| `ubuntu-latest` | Most compatible — recommended default |
| `macos-latest` | iOS / macOS builds, Apple toolchain |
| `windows-latest` | Windows-specific builds |
| Self-hosted | Custom hardware or private infra |

**Jobs** — suggest based on the detected stack and stated goal:
- Common jobs: `lint`, `test`, `build`, `deploy`, `release`, `notify`
- Ask whether to use multiple jobs (parallel, with dependencies) or one job with multiple steps

**Caching** — offer to add dependency caching if detected:
- `actions/cache` for npm / yarn / pnpm, pip, cargo, gradle, etc.

#### Python Script

- Does it accept command-line arguments?
- Does it need external packages (from `requirements.txt`)?
- Will it run on a schedule (suggest adding a cron wrapper or GitHub Actions caller)?
- Should it log output to a file?

#### Node.js Script

- JavaScript or TypeScript?
- Does it use top-level `await` (ESM module)?
- Should it be registered as an npm script in `package.json`?

#### Shell / Bash Script

- POSIX-compatible (`sh`) or bash-specific?
- Should it use `set -euo pipefail` for strict error handling?
- Called from CI only, or also run locally?

#### Makefile

- Which targets? Suggest: `all`, `install`, `build`, `test`, `lint`, `clean`, `deploy`
- Should all targets be `.PHONY`?
- Extending an existing Makefile, or creating fresh?

### Step 4: Suggest Names

Present 3–4 suggestions for each naming decision and let the user pick or enter a custom name.

**File name:**

| Type | Suggestions |
|------|-------------|
| GitHub Actions | `.github/workflows/ci.yml`, `.github/workflows/test.yml`, `.github/workflows/deploy.yml`, `.github/workflows/nightly.yml` |
| Python script | `scripts/run.py`, `scripts/<goal>.py` |
| Node.js script | `scripts/run.js`, `scripts/<goal>.js` |
| Shell script | `scripts/run.sh`, `scripts/<goal>.sh`, `bin/<goal>` |
| Makefile | `Makefile` (root), `scripts/Makefile` |

**Job names** (GitHub Actions):
- Derived from the goal: `run-tests`, `lint-and-format`, `build-image`, `deploy-staging`

**Step names** (GitHub Actions):
- Scaffold from detected stack + goal
- Node.js CI example: `Checkout code`, `Set up Node.js`, `Install dependencies`, `Run linter`, `Run tests`, `Upload coverage report`
- Python CI example: `Checkout code`, `Set up Python`, `Install dependencies`, `Run linter`, `Run tests`

Let the user rename or reorder before generating.

### Step 5: Secrets and Environment Variables

Ask:
> "Does this workflow need any secrets or environment variables?"

Provide common examples:
- `GITHUB_TOKEN` — auto-provided by GitHub Actions, no setup needed
- Cloud credentials: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `GCP_SA_KEY`
- Container registry: `DOCKER_USERNAME`, `DOCKER_PASSWORD`, `GHCR_TOKEN`
- Database / service URLs: `DATABASE_URL`, `REDIS_URL`
- Third-party API keys

Tell the user where each should be stored:
- GitHub Actions → **Settings → Secrets and variables → Actions**
- Local scripts → **`.env` file** (remind them to add `.env` to `.gitignore`)

### Step 6: Generate and Preview

Generate the complete workflow file and display it **before writing**:

```
Preview: .github/workflows/ci.yml
──────────────────────────────────
<file content>
──────────────────────────────────
Does this look right? Say yes to write, or describe any changes.
```

Apply any requested changes and show the updated preview before writing.

### Step 7: Write the File

Once the user confirms:

1. Create any necessary directories with `mkdir -p`
2. Write the file with the Write tool
3. For shell scripts, make executable: `chmod +x <path>`
4. Confirm the file was written successfully

### Step 8: Post-Creation Next Steps

Provide a concise summary with what to do next:

**GitHub Actions example:**
```
Created .github/workflows/ci.yml

Next steps:
- Add secrets in GitHub → Settings → Secrets → Actions:
    DOCKER_USERNAME, DOCKER_PASSWORD
- Push this file to trigger the first run
- Monitor at: github.com/<owner>/<repo>/actions
```

**Script example:**
```
Created scripts/deploy.sh  (executable)

Run it with:
    ./scripts/deploy.sh staging
```

---

## Templates

Use these as starting points and fill in specifics based on user answers.

### GitHub Actions — Node.js CI

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    name: Lint & Test
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Run linter
        run: npm run lint

      - name: Run tests
        run: npm test
```

### GitHub Actions — Python CI

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    name: Lint & Test
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.12'
          cache: 'pip'

      - name: Install dependencies
        run: pip install -r requirements.txt

      - name: Run linter
        run: ruff check .

      - name: Run tests
        run: pytest
```

### GitHub Actions — Scheduled Job

```yaml
name: Nightly Job

on:
  schedule:
    - cron: '0 2 * * *'  # 2 AM UTC daily
  workflow_dispatch:

jobs:
  run:
    name: Run scheduled task
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Run script
        env:
          API_KEY: ${{ secrets.API_KEY }}
        run: python scripts/nightly.py
```

### GitHub Actions — Deploy on Release

```yaml
name: Deploy

on:
  release:
    types: [published]

jobs:
  deploy:
    name: Deploy to production
    runs-on: ubuntu-latest
    environment: production

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Deploy
        env:
          DEPLOY_KEY: ${{ secrets.DEPLOY_KEY }}
        run: ./scripts/deploy.sh production
```

### Python Script

```python
#!/usr/bin/env python3
"""Brief description of what this script does."""

import argparse
import logging
import sys

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
log = logging.getLogger(__name__)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    # parser.add_argument("--env", default="staging")
    args = parser.parse_args()

    log.info("Starting...")
    # Main logic here

    return 0


if __name__ == "__main__":
    sys.exit(main())
```

### Node.js Script

```javascript
#!/usr/bin/env node
// Brief description of what this script does.

const [, , ...args] = process.argv;

async function main() {
  // Main logic here
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

### Shell Script

```bash
#!/usr/bin/env bash
set -euo pipefail

# Brief description of what this script does.

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

main() {
  # Main logic here
  log "Done."
}

main "$@"
```

### Makefile

```makefile
.PHONY: all install build test lint clean

all: install build test

install:
	# Install dependencies

build:
	# Build the project

test:
	# Run tests

lint:
	# Run linter

clean:
	# Remove build artifacts
```

---

## Naming Conventions

| Context | Convention | Examples |
|---------|-----------|---------|
| GitHub Actions file | `kebab-case.yml` | `ci.yml`, `deploy-staging.yml` |
| Job name (YAML key) | `kebab-case` | `run-tests`, `build-image` |
| Step `name:` | Title case sentence | `Checkout code`, `Run linter` |
| Python script | `snake_case.py` | `generate_report.py` |
| Node.js script | `kebab-case.js` | `sync-data.js` |
| Shell script | `kebab-case.sh` | `deploy.sh` |
| Makefile target | `kebab-case` | `build`, `run-dev` |

---

## Rules

**You MUST:**
- Scan the project silently before asking any questions
- Ask both the goal and workflow type in a single `AskUserQuestion` call
- Show a full file preview before writing anything
- Wait for user confirmation before writing any file
- Create necessary directories before writing
- Make shell scripts executable after writing
- Include a next-steps summary after creation

**You MUST NOT:**
- Write any file without the user approving the preview
- Use deprecated GitHub Actions versions (default to `@v4` or latest)
- Hardcode secrets or credentials in workflow files
- Skip the secrets discussion when the workflow clearly needs them
- Over-engineer the workflow — match complexity to the stated goal
