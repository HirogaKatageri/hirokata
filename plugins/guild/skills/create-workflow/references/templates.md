# Workflow templates

Starting points for Step 6 (Generate and Preview). Fill in specifics based on the user's
answers from Steps 2–5 rather than writing a file from scratch.

## GitHub Actions — Node.js CI

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

## GitHub Actions — Python CI

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

## GitHub Actions — Scheduled Job

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

## GitHub Actions — Deploy on Release

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

## Python Script

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

## Node.js Script

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

## Shell Script

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

## Makefile

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
