# The bug-fix short-circuit — creating the tail tickets yourself

Load this when, during the interview, it becomes clear this is a **simple bug fix with no real
design decisions** (not a feature needing the strategist's planning).

Use your **Bash** tool to create the tail tickets directly (you have no ticket of your own to
declare follow-ups on, so create them yourself). Create them **in this order** — the cursor
walks the board in id order, so the fix gets the lowest id and the reviewer the highest:

```bash
REQ=REQ-0NN

# 1. the fix — pass NULL for `agent` and declare the CAPABILITY instead, so the matcher
#    routes it and a roster gap would be visible rather than silently mis-routed
t=$(printf '%s' "Fix: {bug description}" | xxd -p | tr -d '\n')
{ printf "PRAGMA foreign_keys = ON;\n"
  printf "INSERT INTO task (id, requirement_id, title, priority, agent, created_at, updated_at)
          SELECT 'TASK-' || printf('%%03d',
                   (SELECT COALESCE(MAX(CAST(substr(id, instr(id,'-')+1) AS INTEGER)),0)+1
                      FROM task)),
                 r.id, CAST(x'$t' AS TEXT), 2, NULL,
                 strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now'),
                 strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now')
            FROM requirement r WHERE r.id='$REQ'
          RETURNING id;\n"
} | tursodb -q -m list "$DB"        # → TASK-0AA

{ printf "PRAGMA foreign_keys = ON;\n"
  printf "INSERT INTO task_capability (task_id, capability, required)
          SELECT t.id, value, 1 FROM task t
            JOIN json_each(json_array('implement','backend')) ON t.id='TASK-0AA'
          ON CONFLICT DO NOTHING;\n"
} | tursodb -q -m list "$DB"

# 2. the tests — the same two statements, title "Write unit tests for {fix}",
#    capabilities json_array('test-authoring')

# 3. the review — identical, EXCEPT `agent` is the literal 'reviewer' instead of NULL,
#    plus capabilities json_array('review')
```

`FROM requirement r WHERE r.id='$REQ'` **is** the referential check: a bad REQ id yields zero
rows and no partial write, which matters because a failing statement does not stop the script.
Read each `RETURNING id` before writing that ticket's capabilities — the ids are derived, not
chosen.

**The review ticket must carry `agent = 'reviewer'` literally.** `v_task_actionable` — the
review gate — is keyed on that exact string: a review ticket without it is offered immediately,
while the fix is still open, and a review that certifies code nobody wrote is a green you
cannot tell from a real one. Declare `review` as its capability too, so the record says what
the work required, but the pin is what closes the gate.

Report this in your final message so the orchestrator knows not to spawn the strategist at all —
no plan is needed. Do **not** move any of these tickets: the orchestrator owns status
transitions, and with the CLI gone that is a convention nothing enforces.
