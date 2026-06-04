# TDD Fix — Phase 4 Instructions

This reference covers the test-driven fix phase. It is entered after the user has selected a **non-infrastructure** solution from the solution proposal (US-4). Inputs: the selected solution, the error artifact string, and the identified root cause.

## Step 1: Detect the Test Framework (US-5 AC-1)

**Monorepo check:** Before inspecting any manifest, check whether the project is a monorepo. Signs include multiple `package.json` files in subdirectories, a `lerna.json` or `pnpm-workspace.yaml` at the root, or `packages/` / `services/` directories. If any of these are present, ask the user to confirm which package or service the bug is in. Use that package's directory for all framework detection steps below — not the root.

Check project manifests in this order — stop at the first hit:

1. **`package.json`** — inspect `devDependencies` and `dependencies` for `vitest`, `jest`, or `mocha`. Read the test script using this priority order — use the first match found: (1) `scripts.test`, (2) `scripts["test:unit"]`, (3) `scripts["test:integration"]`.
2. **`pyproject.toml` / `setup.cfg` / `pytest.ini` / `tox.ini`** — presence of any of these with pytest configuration indicates `pytest`.
3. **`Gemfile`** — presence of `rspec` gem indicates RSpec; invoked as `bundle exec rspec`.
4. **Other common manifests:**
   - `go.mod` → `go test ./...`
   - `Cargo.toml` → `cargo test`
5. **Language fallback** — if no manifest is found, detect the project language and propose a framework (see No Framework Detected below).

**Runner command inspection:** After extracting the runner command, inspect it for shell metacharacters (`|`, `&`, `;`, `$(`, `` ` ``, `>`, `<`) or patterns that differ significantly from known safe forms (`npx vitest`, `jest`, `npm test`, `pytest`, `bundle exec rspec`, `go test`, `cargo test`). If the command looks unusual or potentially unsafe, display it to the user and ask for confirmation before executing it.

**Non-standard runner command:** If the manifest's `scripts.test` contains a custom invocation (e.g., `"test": "cross-env NODE_ENV=test node scripts/run-tests.js"`), use that exact command. Never substitute a hardcoded default like `npx vitest` or `jest` when the manifest specifies otherwise.

**No framework detected (US-5 AC-3):** Suggest a framework appropriate to the detected language:
- SvelteKit / TypeScript project → Vitest
- Python project → pytest
- Ruby project → RSpec
- Go project → go test (built-in)
- Rust project → cargo test (built-in)

State the suggestion clearly and ask the user to confirm before writing any test. Do not write a test until the user confirms.

## Step 2: Write ONE Failing Test (US-5 AC-2)

Write exactly one test that:

- **Targets the specific module, function, or component** where the bug lives — not a higher-level integration entry point.
- **Reproduces the exact bug scenario** described by the error artifact and root cause — not a broad coverage test.
- **Placement:** If the module already has a test file, add the test there. If not, create a new test file following the project's naming convention (e.g., `*.test.ts`, `*_test.go`, `test_*.py`, `*_spec.rb`).

Before writing, read a neighboring test file in the same directory to match:
- Import style and test runner API (`describe`/`it`, `test`, `func Test...`, etc.)
- Assertion library and its syntax
- Module mock or fixture patterns in use

Mirror that style precisely. Do not introduce new patterns or libraries.

## Step 3: Confirm the Test FAILS (Hard Gate)

Run the test using the detected command, scoped to the affected file where the framework supports it (e.g., `npm test -- path/to/file.test.ts`, `pytest path/to/test_module.py`, `go test ./pkg/...`).

**This is a hard STOP gate — do not proceed until it is satisfied:**

- **Test fails as expected** → report the failure output, then proceed to Step 4.
- **Test passes immediately without any fix** → the test did not reproduce the bug. Report this outcome and **STOP**. Do not apply the fix. (The test must be rewritten to correctly target the bug before any fix can proceed.)

**Assertion failure vs setup error:** When the test fails, verify it is a genuine assertion failure. Look for language like `AssertionError`, `expected X but got Y`, or `assert` in the output. If instead the output shows a syntax error, import error, missing dependency, or other framework-level problem, this is a setup error — not a reproducible bug failure. Report: "Test has a syntax or setup error — please fix the test itself before applying the fix." and **STOP**.

**Exit code vs output divergence:** Check both the exit code and the test output summary. A non-zero exit code combined with an "all tests passed" summary line indicates warnings only — this is acceptable and the gate is satisfied. Only treat the run as a failure if the summary explicitly states test failures or shows failed assertions.

> Rule: A test that passes without a fix is evidence that the test is wrong, not that the bug is gone. Never apply the fix until a genuine failing test is observed.

## Step 4: Apply the Fix (US-5 AC-4)

**Scope boundary check (hard rule):** Before making any edits, confirm that the solution requires changes only to the buggy source module and its test file. If applying the fix would also require changes to lockfiles, dependency manifests (`package.json` dependencies section, `requirements.txt`, `Gemfile`), build config files (`webpack.config.js`, `tsconfig.json`, `vite.config.ts`), CI/CD files, or any infrastructure or environment files — **STOP** and escalate to the user. Do not proceed autonomously when the fix scope exceeds the source and test files.

- Read each file before editing it.
- Modify only what the selected solution requires to resolve the bug.
- Do not refactor, rename variables, restructure modules, or make style changes beyond what the fix demands.

**Modification scope — touch only:**
- The source file(s) where the bug originates.
- The test file for the affected module (already modified in Step 2).

**Never modify:**
- Lockfiles (`package-lock.json`, `yarn.lock`, `Cargo.lock`, `go.sum`, etc.)
- Environment files (`.env`, `.env.local`, `.env.production`, etc.)
- Unrelated configuration files or infrastructure definitions.

## Step 5: Run and Verify (US-5 AC-5)

Run the test suite — at minimum the affected test file — with the detected command. If the framework supports it, disable parallel execution to get deterministic output order (e.g., add `--runInBand` for Jest, `--no-parallel` for Vitest, `-p 1` for pytest). Parse the final summary line (e.g., `5 passed, 1 failed`) rather than individual test output to determine the result.

Evaluate the result:

- **Target test passes and no regressions** → declare the fix complete and proceed to Step 6.
- **Target test still fails** → report the full failure output and **STOP**. Do not attempt a second autonomous fix. Present the failure to the user and ask how they want to proceed.
- **Fix causes existing tests to fail (regressions)** → report the regression failures and **STOP**. Do not attempt to fix the regressions autonomously. Present the regressions to the user.

> Rule: On any failure outcome (target still fails, or regressions introduced), the flow ends with a report. No further autonomous changes are made.

## Step 6: Summary (US-5 AC-6)

Present the final summary using this template:

```
## Fix Summary

**Original error:**
{First 2-3 lines of the error artifact from Phase 1}

**Root cause identified:**
{Root cause statement from Phase 3}

**Files changed:**
- `{path/to/source-file}` — {one-line description of change}
- `{path/to/test-file}` — added test: `{test name}`

**Test now passing:**
`{test name}` in `{path/to/test-file}`

**Root cause and fix:**
{One sentence: what caused the bug and what was changed to resolve it.}
```

## Edge Cases

- **Non-standard runner command** — If `package.json` (or another manifest) specifies a custom test script, use that command verbatim. Do not substitute `npx vitest`, `jest`, or any other hardcoded default.

- **Failing test passes immediately without a fix** — The test did not reproduce the bug. Report this and stop. The test needs to be revised before any fix is applied.

- **Regressions introduced by the fix** — Report all regressing tests and stop. Do not attempt to fix regressions autonomously.

- **No clear unit-testable boundary** — If the affected code is a server-rendered route, a side-effectful middleware, or otherwise difficult to isolate as a pure unit, note the limitation explicitly. Write the best approximation of a unit test that isolates the core logic (e.g., extract and test the handler function in isolation). Flag the approximation for the user's review before running the test.
