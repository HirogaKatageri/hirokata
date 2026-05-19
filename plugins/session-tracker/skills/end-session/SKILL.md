---
name: end-session
description: >
  This skill should be used when the user says "end session", "wrap up", "I'm done for today",
  "close the session", "session complete", "log off", "signing off", "finish the session",
  "that's it for today", "done for now", "calling it a day", "let's wrap up", "save the session",
  "session summary", or any phrase indicating they are ending or wrapping up their current
  work session. Spawns the session-tracker:logger agent to record the session.
version: 1.0.0
user-invocable: true
---

# Session Tracker — End Session

Spawn the `session-tracker:logger` agent. It handles everything: querying git activity,
synthesizing the summary, and writing to the log.

## Step 1: Spawn the Logger

```
Agent(
  subagent_type: "session-tracker:logger",
  description: "Record session to daily log"
)
```

No prompt required — the logger is self-directed.

## Step 2: Relay the Confirmation

After the logger returns, surface its confirmation line to the user:

```
{logger confirmation line}
```

If the logger reports an error, surface it as-is. Do not retry.
