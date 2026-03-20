---
name: stop-request-monitoring
description: This skill should be used when the user asks to "stop request monitoring", "stop watching requests", "cancel request monitoring", "stop the orchestrator schedule", or "stop-request-monitoring {job-id}". Cancels the hourly request monitoring cron job that was started by start-request-monitoring.
version: 1.0.0
arguments:
  - name: job-id
    description: The job ID returned when monitoring was started
    required: false
---

# Stop Request Monitoring

Cancel the hourly request monitoring cron job.

## Steps

### 1. Resolve the job ID

If `job-id` is provided in `$ARGUMENTS`, use it directly.

If not provided:
- Use `CronList` to list all active cron jobs in the session
- Present the list to the user and ask which job to cancel
- If no jobs are found: inform the user — "No active monitoring jobs found." — and stop

### 2. Cancel the job

Use `CronDelete` with the resolved job ID.

### 3. Confirm to user

```
Request monitoring stopped.

  Job ID: {job-id}

  No further automatic checks will run.
  To restart, run /project-management:start-request-monitoring
```

## Rules

- **If job ID is invalid**: inform the user that the ID was not found and show the current job list via `CronList`
- **Do not process any pending requests** when stopping — leave `requests/todo/` untouched
