---
name: list-request-monitoring
description: This skill should be used when the user asks to "list request monitoring", "show monitoring jobs", "what monitoring is running", "show active schedules", "list cron jobs", or "what's scheduled". Lists all active request monitoring cron jobs in the current session.
version: 1.0.0
---

# List Request Monitoring

Show all active request monitoring jobs in the current session.

## Steps

### 1. Fetch active jobs

Use `CronList` to retrieve all scheduled cron jobs.

### 2. Present results

**If no jobs are active:**

```
No active monitoring jobs.

To start monitoring, run /project-management:start-request-monitoring
```

**If jobs are found:**

```
Active request monitoring jobs:

  #  Job ID       Schedule
  1  {job-id}     Every hour at :07

To stop a job: /project-management:stop-request-monitoring {job-id}
```

## Rules

- Show **all** jobs returned by `CronList` — do not filter
- If there are multiple jobs (user ran start-request-monitoring more than once), show all of them so the user can identify duplicates
