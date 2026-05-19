---
name: daily-summary
description: >
  This skill should be used when the user says "daily summary", "summarize today",
  "generate daily summary", "what did I do today", "today's summary", "daily report",
  "summarize all projects today", or any phrase asking for a summary of all work done
  across projects today. Searches all subdirectories for .logs/YYYY-MM-DD-log.md files,
  summarizes each project's sessions, and saves a grouped report to
  .logs/YYYY-MM-DD-daily-summary.md.
version: 1.0.0
user-invocable: true
---

# Session Tracker — Daily Summary

Spawn the `session-tracker:summarizer` agent to find today's log files across all
subdirectories, group them by project, and write a daily summary.

## Step 1: Spawn the Summarizer

```
Agent(
  subagent_type: "session-tracker:summarizer",
  description: "Generate daily summary across all projects"
)
```

No prompt required — the summarizer is self-directed.

## Step 2: Relay the Confirmation

After the summarizer returns, surface its confirmation line to the user:

```
{summarizer confirmation line}
```

If the summarizer reports an error, surface it as-is. Do not retry.
