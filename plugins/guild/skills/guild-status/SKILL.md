---
name: guild-status
description: >
  Deprecated alias — the v4 name for what is now guild:brief. It claims NO natural-language
  trigger phrases; "guild status", "board status", "what's happening", "project status" and
  every other status phrasing belong to guild:brief and must route there. Invoke this only
  when the user explicitly types the old slash command /guild:guild-status.
version: 5.0.0
user-invocable: true
---

# guild-status → guild:brief

This skill was rebuilt as **`guild:brief`** in v5 (design §10). v4's status was "list the
directories"; the brief is one query — `SELECT fact, value FROM v_brief` — that answers
direction, what is in flight, what is blocked, what moved since the last check-in, open bugs,
coverage due for inspection, and what to do next.

**Do this now:** load the `guild:brief` skill and follow it. Do not re-implement it here, and do
not substitute `SELECT * FROM v_board` — the board view is correct and is part of what the brief
reads, but on its own it shows tasks only, which is the narrower view this skill used to offer.

Mention the new name once, in passing, so the next invocation goes straight there:

> (`guild:brief` is what this is called now.)

## Why this file still exists

Only to keep the typed slash command `/guild:guild-status` working. It deliberately carries
**no trigger phrases** — they all moved to `guild:brief`'s description. Two skills
advertising "guild status" would make every status request a coin flip between them, and
the whole point of the rename is that one of the two answers is better.
