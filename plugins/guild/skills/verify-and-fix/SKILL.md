---
name: verify-and-fix
description: >
  This skill should be used when the user reports an error, bug, or unexpected
  behavior and wants it diagnosed and fixed. Trigger on phrases like "check this
  error", "check this bug", "here's an error", "here's a bug", "I have an error",
  "I have a bug", "found a bug", "got an error", "debug this", "this is broken",
  "fix this error", "verify and fix", or any message that includes a stack trace
  or error output. Runs a structured workflow: gather context, investigate
  configured log/code sources, report root cause with ranked solutions, then
  apply a test-driven fix.
version: 1.0.0
user-invocable: true
---

# Verify and Fix

Diagnoses and fixes reported errors through a structured end-to-end workflow: gather context via your error-verification guide, investigate configured log and code sources, propose ranked solutions, then apply a test-driven fix.

## Workflow Overview

The skill runs five phases in sequence:

- **Phase 0** — Guide Gate: detect or create the project's error-verification guide in `CLAUDE.md`
- **Phase 1** — Error Input: collect the error artifact from the triggering message
- **Phase 2** — Investigation: read `references/investigation.md` and perform source investigation
- **Phase 3** — Solution Proposal: produce a findings report, then a ranked solution set (defined in the same reference)
- **Phase 4** — TDD Fix: read `references/tdd-fix.md` and apply a test-driven fix for the selected solution

Phases 2–4 are detailed in the reference files. Read each reference when you reach it — do not read them in advance.

---

## Phase 0: Guide Gate (US-1, US-6)

### 0.1 Detect the Guide

1. Read `CLAUDE.md` if it exists. Look for a level-2 heading exactly `## Error Verification Guide`.
2. If that heading is absent (or `CLAUDE.md` does not exist), read `AGENTS.md` if it exists and look for the same heading. Treat `AGENTS.md` as read-only — never write to it.

### 0.2 Branch on Detection Result

- **Guide found in `CLAUDE.md` and well-formed** → state "Using your existing error-verification guide." and skip to Phase 1.
- **Guide found in `AGENTS.md` but not in `CLAUDE.md`** → use it for this invocation, but inform the user that the guide belongs in `CLAUDE.md` and offer to copy it there.
- **Guide found in both with conflicting content** → prefer the `CLAUDE.md` version, note the conflict, and suggest removing the `AGENTS.md` duplicate.
- **Guide missing, empty, or malformed in all locations** → run the setup interview (§ 0.3).
- **User explicitly asked to update** (phrases like "update my error guide", "re-run error setup") → run the setup interview pre-filled with current values, then overwrite the `## Error Verification Guide` section in `CLAUDE.md`.

**Structure validation:** When the `## Error Verification Guide` heading is found, parse the section to verify that all three required subsections — `### Monitoring Services`, `### Issue Tracker`, and at least one of `### Frontend` or `### Backend` — are present and non-empty. If any required subsection is missing or contains only whitespace, treat the guide as malformed and run the setup interview with the message: "Guide section found but malformed. Running setup to regenerate it."

### 0.3 Setup Interview

Ask all questions in **one single message** using the verbatim fenced block below. Do not ask questions one at a time.

> **Security notice:** Never include actual API keys, authentication tokens, passwords, or secret credentials in your answers. Your responses will be stored in plaintext in `CLAUDE.md`. For monitoring services, provide the project URL rather than authenticated DSNs — for example:
> - Safe: `Sentry — https://sentry.io/organizations/myorg/projects/myproject/`
> - Unsafe: `Sentry — https://abc123secret@o123456.ingest.sentry.io/789012`
>
> Store any sensitive values in your `.env` file or a secrets manager and reference only the variable name or location in your answers (e.g. "Sentry DSN stored in `SENTRY_DSN` env var").

```
To set up your error-verification guide, please answer the following:

1. Log / monitoring services  [required]
   Which services do you use? (e.g. Sentry, Railway, Datadog, local files)
   Include project URLs — do NOT include API keys, tokens, or authenticated DSNs.

2. Issue tracker  [required]
   Which issue tracker do you use? (e.g. GitHub Issues, Linear, Jira)
   Include the base URL.

3. Stack  [required]
   Do you have a frontend, backend, or both?
   For each layer, what language and framework are you using?
   (At least one concrete framework/language pair is required.)

4. Log file paths (optional)
   Are there specific log files on disk the model should read?
   (Leave blank to skip.)

5. Environment URLs (optional)
   Do you have a staging and/or production URL?
   (Leave blank to skip.)
```

**Required field validation:** Questions 1, 2, and 3 are required. If the user's answer to any required question is only whitespace or a dismissive placeholder (`none`, `n/a`, `unknown`, `-`, etc.), re-ask that question before proceeding. For question 3, at least one of frontend or backend must have a concrete framework and language pair — a vague answer like "both" alone is not sufficient.

### 0.4 Write the Guide

After the user answers, write the guide to `CLAUDE.md` under `## Error Verification Guide` using the Guide Schema (see § Interface Contract).

Edge cases:
- **`CLAUDE.md` does not exist** → create it with the guide section only.
- **`AGENTS.md` exists but `CLAUDE.md` does not** → still create `CLAUDE.md`; do not touch `AGENTS.md`.
- **User skipped optional questions** → omit those sections entirely; do not block on missing optional fields.
- **Overwriting an existing or malformed section** → replace only the `## Error Verification Guide` block; leave the rest of `CLAUDE.md` intact. Read the file first, then edit.
- **Filesystem errors** → if `CLAUDE.md` cannot be created or read due to permission errors or filesystem issues, report the specific error to the user and ask them to verify file permissions or provide an alternative location. Do not proceed to Phase 1 until the guide is successfully written.
- **File encoding and line endings** → when reading an existing `CLAUDE.md`, detect its encoding and line-ending style (LF vs CRLF) and replicate both when writing. If the file is not UTF-8, report this to the user and ask to convert it to UTF-8 before proceeding.

### 0.5 Continue Without Re-triggering

After writing the guide, immediately continue to Phase 1 using the error that triggered this invocation. Do not require the user to repeat themselves.

---

## Phase 1: Error Input (US-2)

Determine the error artifact from the triggering message:

- **Inline text or stack trace present** → use it directly.
- **File path provided** (e.g. `/tmp/app.log`, `./logs/error.log`) → resolve the path relative to the project root. If the resolved path falls outside the project directory (i.e. it does not start with the project root after normalization), warn the user that the path points outside the project and ask for confirmation before reading — this prevents accidental exposure of system files. If the file does not exist, report the missing path and ask the user to re-check. Do not silently fail.
- **External URL** (GitHub issue, Sentry event, etc.) → treat as a reference. Attempt to read only if directly fetchable; otherwise ask the user to paste the relevant content. Do not silently fail. Auto-fetching external URLs is out of scope.
- **Nothing provided** → ask verbatim:

  ```
  Please share the error — you can paste it here, provide a file path, or share a link to the issue.
  ```

- **Multiple artifacts in one message** → process the first one; note that one error is handled per invocation.
- **Ambiguous text** → proceed anyway, treating it as the error description.

Once the error artifact is established, proceed to Phase 2.

---

## Phase 2–4: Dispatch to References

When the error artifact is established, the model must:

1. **Read `references/investigation.md`** — then perform Phase 2 (investigation using the guide's configured sources) and Phase 3 (findings report, then ranked solution proposal as a separate step). Wait for the user to select a solution.
2. **If the selected solution is classified as infrastructure**, escalate per the rules in that reference and stop. Do not enter Phase 4.
3. **Read `references/tdd-fix.md`** — then perform Phase 4 (TDD fix: write a failing test, apply the fix, run the test, deliver a final summary).

## Reference Files

- **`references/investigation.md`** — Read this when you reach Phase 2. Contains investigation steps, source-query order, infrastructure escalation rules, findings report format, and ranked solution format.
- **`references/tdd-fix.md`** — Read this when you reach Phase 4 (after a non-infrastructure solution is selected). Contains the TDD fix flow, test requirements, and final summary format.

---

## Interface Contract

These contracts are also restated in the reference files. Keep them identical.

### Guide Schema

The section written by Phase 0 to `CLAUDE.md` and consumed by Phase 2. Optional sections are omitted when the user skips them.

```markdown
## Error Verification Guide

### Monitoring Services
- <Name> — <URL or DSN>   (repeatable; "None" if none)

### Issue Tracker
- <Name> — <base URL>     ("None" if none)

### Frontend
- <framework> / <language>   (or "None")

### Backend
- <framework> / <language>   (or "None")

### Log File Paths        (omit section if not provided)
- <path>

### Environments          (omit section if not provided)
- staging: <url>
- production: <url>
```

### Dispatch Contract

- **To `references/investigation.md` (Phase 2/3):** inputs are (a) the parsed Guide Schema fields and (b) the error artifact string from Phase 1. Output: a findings report, then — as a separate step — a ranked solution set, then a user-selected solution (which may be an infrastructure escalation that terminates the flow).
- **To `references/tdd-fix.md` (Phase 4):** input is the user-selected non-infrastructure solution plus the error artifact and root cause. Output: a failing test, applied fix, test run result, and a final summary. The TDD reference must not be entered for infrastructure-classified solutions.

---

## Rules

- **Guide is written to `CLAUDE.md` only** — never modify `AGENTS.md`.
- **`CLAUDE.md` may be committed to version control or visible in logs** — never store actual credentials, API keys, tokens, or passwords in the guide. Store sensitive details in `.env` or a secrets manager and reference only the variable name or location in the guide (e.g. "Sentry DSN stored in `SENTRY_DSN` env var").
- **One error per invocation** — if multiple artifacts are present, process the first and note the limitation.
- **Never auto-fetch external URLs** — if an external URL is provided and not directly readable, ask the user to paste the relevant content.
- **Infrastructure fixes are escalated, never applied** — any fix requiring `gcloud`, `aws`, `railway`, `az`, `terraform`, `pulumi`, equivalent CLIs, or changes to `.env` or secret managers is described in plain language and handed to the user. Full handling is defined in `references/investigation.md`.
- **File modification scope** — only the bug source file(s), the affected module's test file, and `CLAUDE.md`. Never lockfiles, `.env`, or unrelated config.
- **Read before editing** any file.
- **Findings and solutions are separate steps** — never show solution options inside the findings report; present them only after the findings are complete and acknowledged.
