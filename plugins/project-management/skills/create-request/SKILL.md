---
name: create-request
description: This skill should be used when the user asks to "create a request", "add a request", "queue a request", "submit a request", "new request", or "make a request for the orchestrator". Creates a structured request file in requests/todo/ that the Project Orchestrator can pick up and execute.
version: 1.0.0
arguments:
  - name: title
    description: Short title for the request
    required: false
  - name: details
    description: What the request is asking for
    required: false
---

# Create Request

Create a structured request file in `requests/todo/` for the Project Orchestrator to process.

## Arguments

Parse from `$ARGUMENTS` or ask the user interactively:

| Argument | Description |
|---|---|
| `title` | Short title for the request (used as filename) |
| `details` | Full description of what needs to be done |

If either argument is missing, ask the user for it before proceeding.

## Steps

### 1. Gather request details

If `title` is not provided:
```
What is the title of this request? (e.g. "Implement authentication", "Generate requirements for checkout")
```

If `details` is not provided:
```
Describe what this request should do. Be as specific as possible — the orchestrator will use this to determine which agents to involve.
```

### 2. Generate filename

- Slugify the title: lowercase, replace spaces with hyphens, strip special characters
- Prefix with today's date: `YYYY-MM-DD`
- Full filename: `requests/todo/YYYY-MM-DD-{slug}.md`

Example: title "Implement authentication" on 2026-03-20 → `requests/todo/2026-03-20-implement-authentication.md`

### 3. Write request file

```markdown
---
title: {title}
created: {YYYY-MM-DD}
status: todo
---

# {title}

## Details

{details}
```

### 4. Confirm to user

```
Request created!

  File: requests/todo/YYYY-MM-DD-{slug}.md
  Title: {title}
  Status: todo

Run /project-management:project-orchestrator to process pending requests.
```

## Rules

- **Never overwrite** an existing file — if the filename already exists, append `-2`, `-3`, etc.
- **Minimal frontmatter**: only `title`, `created`, `status` — no extra fields
- **status is always `todo`** when created — the orchestrator manages status by moving the file
