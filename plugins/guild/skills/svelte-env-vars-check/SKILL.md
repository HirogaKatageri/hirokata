---
name: svelte-env-vars-check
description: >
  This skill should be used when the user says "check svelte env vars",
  "check environment variables", "validate env vars", "check env var patterns",
  "audit environment variables", "audit env vars", "check SvelteKit env",
  "svelte env check", or any phrase asking to audit or validate SvelteKit
  environment variable usage patterns.
version: 1.0.0
user-invocable: true
---

# SvelteKit Env Vars Check

Audit SvelteKit environment variable usage for PUBLIC/PRIVATE pattern compliance
and `process.env` violations, then optionally migrate to correct patterns.

## SvelteKit Env Var Rules

| Pattern | Module | Who can use it |
|---------|--------|----------------|
| `PUBLIC_*` vars | `$env/static/public` or `$env/dynamic/public` | Client and server |
| Non-public vars | `$env/static/private` or `$env/dynamic/private` | Server only |
| `process.env.*` | — | **Never** — not supported by SvelteKit |

**Violations:**
1. **Client-side using PRIVATE** — a client file imports from `$env/static/private` or `$env/dynamic/private`
2. **Server-side not using PRIVATE** — a server file accesses env vars through `process.env` instead of `$env/static/private` or `$env/dynamic/private`
3. **`process.env` anywhere** — any file using `process.env.*` instead of SvelteKit env modules

---

## Phase 1: Discover Files

### 1.1 Identify client-side files

Client-side files are those that run in the browser. In SvelteKit:

- `src/**/*.svelte` (all Svelte components and pages)
- `src/**/+page.ts` and `src/**/+layout.ts` (universal loaders — run on both client and server)
- `src/lib/**/*.ts` and `src/lib/**/*.js` **not** inside a `server/` subdirectory

Run:
```bash
find src -type f \( -name "*.svelte" -o -name "+page.ts" -o -name "+layout.ts" \) | sort
find src/lib -type f \( -name "*.ts" -o -name "*.js" \) | grep -v '/server/' | sort
```

### 1.2 Identify server-side files

Server-side files only run on the server. In SvelteKit:

- `src/**/+page.server.ts` and `src/**/+layout.server.ts`
- `src/**/+server.ts` (API routes / form actions)
- `src/lib/server/**/*` (server-only library code)

Run:
```bash
find src -type f \( -name "+page.server.ts" -o -name "+layout.server.ts" -o -name "+server.ts" \) | sort
find src/lib/server -type f 2>/dev/null | sort
```

---

## Phase 2: Scan for Violations

### 2.1 Scan for `process.env` usage (any file)

```bash
grep -rn "process\.env\." src/ --include="*.ts" --include="*.js" --include="*.svelte"
```

Record each match: file path, line number, full line, env var name extracted from `process.env.SOME_VAR`.

### 2.2 Scan for PRIVATE imports in client-side files

```bash
grep -rn "\$env/static/private\|\$env/dynamic/private" src/ --include="*.svelte" --include="*.ts" --include="*.js"
```

Cross-reference results against the client-side file list from Phase 1. Any match in a client-side file is a violation.

### 2.3 Scan for missing PRIVATE pattern in server-side files

```bash
grep -rn "\$env/static/public\|\$env/dynamic/public\|process\.env\." src/ --include="*.ts" --include="*.js"
```

Cross-reference results against the server-side file list from Phase 1. Both of the following are hard violations:
- A server file using `process.env` instead of a private import
- A server file importing from `$env/static/public` or `$env/dynamic/public`

Server-side code must exclusively use `$env/static/private` or `$env/dynamic/private` for all env vars. If a var needs to be accessible on the server, it should not carry a `PUBLIC_` prefix — rename it and move it to the private module.

### 2.4 Collect all env var names

From all matches above, extract the env var names:
- From `process.env.SOME_VAR` → `SOME_VAR`
- From `import { SOME_VAR } from '$env/...'` → `SOME_VAR`

---

## Phase 3: Build and Display the Violations Report

Group findings into three categories and display them:

```
SvelteKit Env Vars Audit Report
================================

Violation 1 — Client-side using PRIVATE pattern
------------------------------------------------
Files that import from $env/static/private or $env/dynamic/private:

  src/routes/dashboard/+page.svelte:12
    import { SECRET_KEY } from '$env/static/private'

  [list each violation]

  Total: N violation(s)

Violation 2 — Server-side not using PRIVATE pattern
----------------------------------------------------
Server files using process.env or importing from $env/*/public instead of $env/static/private or $env/dynamic/private:

  src/routes/api/+server.ts:8
    const key = process.env.API_KEY

  src/routes/data/+server.ts:3
    import { PUBLIC_API_URL } from '$env/static/public'

  [list each violation]

  Total: N violation(s)

Violation 3 — process.env usage
--------------------------------
Any file using process.env instead of SvelteKit env modules:

  src/lib/utils.ts:22
    if (process.env.NODE_ENV === 'production')

  [list each violation]

  Total: N violation(s)

Summary
-------
  Client PRIVATE violations:  N
  Server non-PRIVATE violations: N
  process.env violations:     N
  Total violations:           N
```

If there are no violations in a category, show:
```
  (none found)
```

If there are zero total violations across all categories:
```
No violations found. All env var usage follows SvelteKit PUBLIC/PRIVATE patterns.
```
Stop here — do not ask about migration.

---

## Phase 4: Ask About Migration

After displaying the report, ask:

```
Would you like to migrate these violations to the correct SvelteKit env var patterns?

Migration will:
  • Replace process.env.VAR in client files → import PUBLIC_VAR from $env/static/public (or dynamic)
  • Replace process.env.VAR in server files → import VAR from $env/static/private (or dynamic)
  • Move private imports from client files → advise moving logic to server side
  • Update .env variable names where PUBLIC_ prefix is needed

Note: Migrations that cannot be automated safely (e.g., private vars used in client
components that need architectural changes) will be flagged for manual review instead.

Proceed with migration? (yes / no)
```

If **no**: skip to Phase 6 (final table only).

### 4.1 Ask About Timing

If the user answers **yes**, ask a follow-up before proceeding:

```
Should env vars be compile-time (static) or runtime (dynamic)?

  [1] static  — $env/static/public  and $env/static/private
                Values are inlined at build time. Faster, but the app must be
                rebuilt to pick up .env changes.

  [2] dynamic — $env/dynamic/public and $env/dynamic/private
                Values are read at request time. The app picks up .env changes
                without a rebuild, but vars are not tree-shaken.

  [3] mixed   — I will specify per-variable.

Choice (1 / 2 / 3):
```

**If 1 (static):** use `$env/static/public` and `$env/static/private` throughout migration.

**If 2 (dynamic):** use `$env/dynamic/public` and `$env/dynamic/private` throughout migration.

**If 3 (mixed):** before migrating each distinct env var, ask:
```
  VAR_NAME — static or dynamic? (s / d)
```
Record the choice and apply it consistently wherever that var is imported.

---

## Phase 5: Perform Migration

Use the timing choice from Phase 4.1 to determine which module to import from:
- Static public  → `$env/static/public`
- Dynamic public → `$env/dynamic/public`
- Static private  → `$env/static/private`
- Dynamic private → `$env/dynamic/private`

Work through violations file by file. For each file, read it first, then apply changes.

### 5.1 Migrate `process.env.VAR` in client-side files

**Action:** Replace `process.env.VAR` with the imported public variable.

Steps:
1. For each `process.env.VAR` occurrence in a client file:
   - Determine the new name: `PUBLIC_VAR` (add `PUBLIC_` prefix if not already present)
   - Resolve the module based on the timing choice (e.g., `$env/static/public` or `$env/dynamic/public`)
   - Add an import at the top of the file:
     ```ts
     import { PUBLIC_VAR } from '$env/<timing>/public';
     ```
   - Replace all `process.env.VAR` occurrences with `PUBLIC_VAR`
2. If the file already imports from the same module, add `PUBLIC_VAR` to the existing import destructure.
3. Note: The user must also add `PUBLIC_VAR=<value>` to their `.env` file (flag this).

### 5.2 Migrate `process.env.VAR` in server-side files

**Action:** Replace `process.env.VAR` with the imported private variable.

Steps:
1. For each `process.env.VAR` occurrence in a server file:
   - Keep the same name: `VAR` (no prefix change needed for private vars)
   - Resolve the module based on the timing choice (e.g., `$env/static/private` or `$env/dynamic/private`)
   - Add an import at the top of the file:
     ```ts
     import { VAR } from '$env/<timing>/private';
     ```
   - Replace all `process.env.VAR` occurrences with `VAR`
2. If the file already imports from the same module, add `VAR` to the existing import destructure.

### 5.3 Migrate `$env/*/public` imports in server-side files

**Action:** Replace public imports with private imports and strip the `PUBLIC_` prefix from the var name.

Steps:
1. For each `import { PUBLIC_VAR } from '$env/*/public'` in a server file:
   - Rename the imported binding: `PUBLIC_VAR` → `VAR` (strip `PUBLIC_` prefix)
   - Resolve the module based on the timing choice (e.g., `$env/static/private` or `$env/dynamic/private`)
   - Replace the import with:
     ```ts
     import { VAR } from '$env/<timing>/private';
     ```
   - Replace all usages of `PUBLIC_VAR` in that file with `VAR`
2. Note: The user must also add `VAR=<value>` (without `PUBLIC_` prefix) to their `.env` file — flag this.
3. If the same var is still needed in client-side files under its `PUBLIC_` name, those client imports remain valid and are untouched.

### 5.4 Handle PRIVATE imports in client-side files

These require architectural changes that cannot be automated safely.

For each client file with a private import:
```
⚠️  Cannot auto-migrate: src/routes/dashboard/+page.svelte

  This file imports private env vars (PRIVATE pattern) but runs on the client.
  Private vars must not be exposed to the client.

  Options:
  a) Move the logic that uses this var to a +page.server.ts or +server.ts file
     and pass the result as page data.
  b) If the var is safe to expose publicly, rename it to PUBLIC_VAR and import
     from $env/static/public instead.

  Flagged for manual review.
```

### 5.5 Handle `process.env.VAR` in universal files (`+page.ts`, `+layout.ts`)

Universal loaders run on both server and client. Flag these for manual review:
```
⚠️  Universal file (runs on client + server): src/routes/+page.ts

  process.env.VAR at line N needs manual review.
  - If VAR should be public: use $env/static/public with PUBLIC_ prefix
  - If VAR should be private: move this logic to +page.server.ts
```

### 5.6 After each file migration

State what was changed:
```
✓ Migrated: src/routes/api/+server.ts
  - Replaced process.env.API_KEY → import { API_KEY } from '$env/static/private'
  - Replaced process.env.DB_URL  → import { DB_URL } from '$env/static/private'
```

---

## Phase 6: Final Report Table

After the audit (and migration if performed), output a table of all env vars found:

```
Environment Variables Inventory
================================

| Name of Env Var | Description |
|-----------------|-------------|
| PUBLIC_API_URL  | Public API base URL — used in client-side fetch calls (src/lib/api.ts). Visibility: client and server. Timing: static. |
| API_KEY         | Private API authentication key — used in server route src/routes/api/+server.ts. Visibility: server only. Timing: dynamic. |
| DB_URL          | Database connection string — used in src/lib/server/db.ts. Visibility: server only. Timing: static. |
| PUBLIC_APP_NAME | Application display name — used in layout component. Visibility: client and server. Timing: static. |
```

**Description column should include:**
- What the var is used for (inferred from context)
- Where it appears (file path)
- Visibility: `Client and server` (PUBLIC_*) or `Server only` (private)
- Timing: `static` (`$env/static/*`) or `dynamic` (`$env/dynamic/*`)

If migration was performed, mark migrated vars:
- `[migrated]` — successfully auto-migrated
- `[manual review]` — flagged for architectural change

---

## Rules

- **Never modify files without user confirmation** — always ask first (Phase 4).
- **Read each file before editing** — never blindly apply replacements without reading current content.
- **Preserve existing import structure** — merge into existing import statements rather than adding duplicate imports.
- **Flag, don't guess** — if the correct migration for a var is ambiguous, flag it for manual review instead of guessing.
- **Stay in `src/`** — only scan and modify files under the `src/` directory.
- **`.env` changes are out of scope** — tell the user which `.env` variables need to be renamed (e.g., `VAR → PUBLIC_VAR`) but do not modify `.env` files automatically.
