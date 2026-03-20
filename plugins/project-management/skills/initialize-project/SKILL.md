---
name: initialize-project
description: This skill should be used when the user asks to "initialize project", "set up project", "init project", "create project structure", "prepare project folders", or "set up workspace". Creates the standard project directory structure with folders for requirements, tasks, and requests.
version: 2.0.0
---

# Initialize Project

Set up the standard project directory structure for the software development workflow.

## What This Creates

```
requirements/        # Store requirements documents here
tasks/               # Workflow output: plans, TASKS.md, summary
requests/
├── todo/            # New requests waiting to be processed
└── done/            # Requests that have been executed
```

## Steps

### 1. Create directories

```bash
mkdir -p requirements
mkdir -p tasks
mkdir -p requests/todo
mkdir -p requests/done
```

### 2. Confirm to user

```
Project initialized!

  requirements/       — place your requirements .md files here
  tasks/              — workflow output goes here (plans, TASKS.md, summary)
  requests/todo/      — drop request files here to queue them for the orchestrator
  requests/done/      — executed requests are moved here automatically

Next steps:
  1. Add your requirements file to requirements/
  2. Create a request with /project-management:create-request
  3. Run /project-management:project-orchestrator to process pending requests
```

## Rules

- **Idempotent**: if the directories already exist, the command succeeds silently — do not warn or error
- **No other files**: only create the directories, nothing else
