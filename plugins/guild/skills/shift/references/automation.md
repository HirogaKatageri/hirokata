# Arming a shift, and notifying on it

Two opt-in features layered on top of the core loop: running shifts on a recurring cadence,
and pushing a notification when one needs the user. Neither is part of running a single shift
— set them up only when the user asks.

## Arming it on a cadence — opt-in, per project

A shift is one loop; a cadence is what makes it a night's work. Both of these arm **this
skill**.

```
/loop 10m /guild:shift              # this session, on an interval
```

or a scheduled agent (the `schedule` skill) running `/guild:shift` on a cron expression.

**Only set one up when the user asks, and only for the project they asked about.** Say what it
will do and how it stops: each run works until the next gate, the budget applies per run, and a
gate arrival ends the run rather than pausing it. Tell them how to disarm it in the same
breath.

## Notifications — the one moment a shift genuinely needs a human

A gate is that moment. Nothing else is.

**Opt-in per project.** The marker is a file, so it is a fact and not a memory:

```bash
[ -f .guild/shift.notify ] && echo "notifications on"
```

Create it only when the user says yes, with the one line they agreed to inside it. Absent
means **never notify**.

When it exists, send **PushNotification** on exactly two events: **a gate arrived** (stop
reason `gate`), and **an abnormal stop** (`infrastructure` or `collision`, because both mean
the night ended early and something is wrong). One line, under 200 characters, leading with
what they would act on:

> `REQ-007 repairs gate ready — 3 findings, 2 bugs, 1 failed task. 5 tasks done, 42 min.`

Never notify on `max-tasks`, `max-minutes`, `idle`, `operator`, or on per-task progress. A
shift that pushes for every event trains the user to mute it, and then the gate notification —
the one that mattered — arrives silenced.
