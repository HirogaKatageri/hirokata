---
name: dashboard
description: >
  This skill should be used when the user asks for "the dashboard", "guild dashboard",
  "open the dashboard", "show me the dashboard", "build the dashboard", "visualize the
  board", "the roadmap", "show the roadmap", "a visual view of the guild", "the coverage
  view", "the activity feed", or wants to see the guild's state as a page rather than as
  text. Builds and opens the self-contained .guild/dashboard.html, and can optionally
  publish it as a shareable Artifact link.
version: 5.0.0
user-invocable: true
---

# Guild Dashboard — the whole board as one page

Read-only. Builds a file; changes no state. `guild dashboard` writes no journal line and no
`event` row, for the same reason `guild brief` does not: rendering the board is not a change
to it.

## Step 1 — is there a guild?

```bash
GUILD="${CLAUDE_PLUGIN_ROOT}/scripts/guild"
[ -f .guild/config.yaml ] || echo "no guild here"
```

If it is missing:

```
No guild board found. Run /guild:check-in to initialize and start your first work session.
```

Stop there.

## Step 2 — build it, and open it

```bash
"$GUILD" dashboard --open
```

That writes `.guild/dashboard.html` and hands it to `open` / `xdg-open`. It prints the path
it wrote.

| Flag | When |
|------|------|
| `--open` | The default choice. Drop it only if the user said "just build it" or you are on a box with no desktop. |
| `--out PATH` | The user names a destination. PATH is the **file** to write (`docs/guild.html`), never the folder to write it into — if they name a directory they serve, append a filename yourself (`--out public/guild.html`). `--out <directory>` is refused. |
| `--json` | The user wants the underlying data, not the page. Writes no file. Cannot be combined with `--out` or `--open`. |

`--open` **never fails the command**. On a headless box or a Linux without `xdg-utils` it
prints the path to stderr and still exits 0 — the file was written, which is the part that
matters. If you see that message, relay the path; do not report the build as failed.

## Step 3 — say what is in it

One file: all CSS and JS inline, the board data inlined as JSON. No server, no build step,
no network — it works offline and from `file://`. Seven views (design §9):

| View | Answers |
|------|---------|
| **Roadmap** | goals → phases → requirements, with live progress |
| **Board** | tasks by status, coloured by priority, with blockers |
| **Graph** | the execution graph — **empty until Stage 4**; the view says so rather than drawing a blank chart |
| **Bugs** | open defects by severity, linked to their fix tasks |
| **Findings** | what reviewers flagged and whether it was ever fixed — grouped by severity, unresolved first, filterable to the resolved ones |
| **Coverage** | quality areas by risk — "what has nobody looked at in a month?" |
| **Activity** | the `event` feed |

Point the user at whichever view answers what they actually asked. If they said "the
roadmap", say the page opened on it; do not recite all seven.

**Every summary tile is a link to the view behind it.** `Open findings` lands on Findings,
`Open bugs` on Bugs, `In flight` and `Todo` on Board. A number the reader cannot click
through to a list of names is the failure this page exists to fix — so when a user asks
"which findings?", the answer is the Findings view (or `guild brief`, which names them in
text), never the count again.

The output is **deterministic** — the same state produces byte-identical bytes, so the file
diffs cleanly if it is committed. Nothing in it embeds a wall clock: it carries only stored
timestamps, and every "3 days ago" is computed in the browser at view time. `guild init`
gitignores it by default; if the user wants it committed, that is their call and it will
diff sanely.

## Step 4 — offer the shareable link, do not take it

The local file is the mechanism. Publishing it as an Artifact is a **convenience, and it is
never automatic** — the page carries the project's real requirement titles, task bodies, bug
reports and activity history, and a link is a different disclosure decision from a file on
the user's own disk.

So: build the file, report the path, and then offer once —

> Want a shareable link for this? I can publish it as an Artifact.

Publish **only** if they say yes. Then:

1. Read the generated HTML file.
2. Publish it with the Artifact tool, passing that file's path.
3. Hand back the URL.

Do not publish on your own initiative, do not publish "so it's ready", and do not re-publish
on a later rebuild unless asked again. If they decline, or say nothing about it, the local
path is the deliverable and you are done.

## Rules

- **Read-only.** `guild dashboard` is the only command this skill runs. Never `move`, `new`,
  `checkin`, `export`, `rebuild` or `spool drain` from here, and never touch
  `.guild/guild.db` or `.guild/journal.ndjson`.
- **Never hand-edit `dashboard.tmpl.html`.** It is a generated-page template holding exactly
  one `@@GUILD_DASHBOARD_DATA@@` line, and `guild dashboard` refuses to build if that line
  is missing or duplicated. `$GUILD_DASHBOARD_TEMPLATE` overrides its location if a
  different page is genuinely wanted.
- **Never hand-edit `.guild/dashboard.html`.** Every build overwrites it wholesale.
- **Do not narrate the numbers.** The page shows them. If the user wants a spoken summary,
  that is `guild:brief` — offer it rather than duplicating it here.
