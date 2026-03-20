---
name: start-request-monitoring
description: This skill should be used when the user asks to "start request monitoring", "monitor requests", "watch requests", "start watching for requests", "auto-process requests", "check requests every hour", or "start the orchestrator on a schedule". Schedules the Project Orchestrator to automatically check requests/todo/ every hour and process any pending request files.
version: 1.0.0
---

# Start Request Monitoring

Schedule the Project Orchestrator to automatically check `requests/todo/` every hour and process any pending requests.

## Steps

### 1. Schedule the cron job

Use `CronCreate` with these exact parameters:

- **cron**: `7 * * * *` (every hour at :07)
- **recurring**: `true`
- **prompt**:
  ```
  Check requests/todo/ for pending request files and process them using the project-management:project-orchestrator agent behavior:
  1. List all files in requests/todo/
  2. If empty, stop silently.
  3. For each file: read it, understand the request, delegate to the appropriate agent or skill, then move the file from requests/todo/ to requests/done/.
  ```

### 2. Save the job ID

The `CronCreate` call returns a job ID. Store it for the user.

### 3. Confirm to user

```
Request monitoring started!

  Schedule:   Every hour at :07
  Watching:   requests/todo/
  Completed:  requests/done/

  Job ID: {job-id}

  ⚠  Session-only: monitoring stops when Claude exits.
  ⚠  Auto-expires after 7 days.

  To stop monitoring early, run:
  /project-management:stop-request-monitoring {job-id}
```

## Rules

- **Only one job**: before creating, inform the user if they run this twice — each call creates a new independent job
- **Do not process requests immediately** on start — let the first scheduled fire handle it; only start the cron job
