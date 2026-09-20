---
name: dashboard
description: >
  This skill should be used when the user asks for "the dashboard", "guild dashboard",
  "open the dashboard", "show me the dashboard", "build the dashboard", "visualize the
  board", "the roadmap", "show the roadmap", "a visual view of the guild", "the coverage
  view", "the activity feed", or wants to see the guild's state as a page rather than as
  text. Queries the warehouse and writes the self-contained .guild/dashboard.html, then
  opens it — and can optionally publish it as a shareable Artifact link.
version: 6.0.0
user-invocable: true
---

# Guild Dashboard — the whole board as one page

Read-only. You build a file; you change no state. **There is no generator script** — you query
the warehouse and write the page yourself. Load `guild:warehouse` for the connection ritual.

Two rules make this page safe, and they are not style preferences. **The board holds text the
guild master and four kinds of agent typed** — requirement titles, bug reports, review
findings, work logs — and a page that executes a requirement title is a real security defect.
Read them before you write a line:

1. **The data crosses as a JSON island with `<`, `>` and `&` escaped**, because `</script>` is
   valid inside a JSON string and still closes the element.
2. **Everything renders through `textContent`.** Never `innerHTML`.

## Step 1 — is there a guild?

```bash
[ -f .guild/config.yaml ] || echo "no guild here"
```

If it is missing, say this and stop:

```
No guild board found. Run /guild:check-in to initialize and start your first work session.
```

## Step 2 — get the data, as one escaped JSON document

One query, one row, one column — so `-m list` never inserts a separator, and free text stays
byte-exact. It is checked in as `scripts/dashboard.sql` rather than retyped, so a query this
long is never at risk of a transcription slip in the heredoc. The three `replace()`s do the
escaping **inside the engine**, before the value ever touches a shell:

```bash
export PATH="$HOME/.turso:$PATH"
tursodb -q -m list .guild/guild.db < "${CLAUDE_PLUGIN_ROOT}/skills/dashboard/scripts/dashboard.sql" \
  > /tmp/guild-data.json
```

**`char(92)` is the backslash**, written that way on purpose: a literal `'<'` in a SQL
file is one shell quoting mistake away from a page that renders raw markup, and `char(92)`
cannot be mangled by anything between here and the engine. Verify before you build:

```bash
grep -c '<' /tmp/guild-data.json      # must be 0
```

Zero means no value in the board can close the `<script>` element that will hold this. If it is
not zero, **stop** — the escape did not run, and building the page anyway is the defect this
step exists to prevent.

The board holds no wall clock: `json_object` carries only stored timestamps, so the same state
produces the same bytes and the file diffs cleanly if the user commits it. Every "3 days ago"
is computed in the browser at view time.

## Step 3 — write the page

Build it in three pieces so no escaping question ever arises — the data file is concatenated
in, never substituted into a template:

```bash
cat > /tmp/dash-head.html <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>Guild Dashboard</title>
<style> /* … all CSS inline … */ </style>
</head><body>
<header>…</header><nav id="views">…</nav><main id="root"></main>
<script type="application/json" id="guild-data">
HTML

cat > /tmp/dash-tail.html <<'HTML'
</script>
<script>
const DATA = JSON.parse(document.getElementById('guild-data').textContent);
/* … render … */
</script>
</body></html>
HTML

cat /tmp/dash-head.html /tmp/guild-data.json /tmp/dash-tail.html > .guild/dashboard.html
```

### The rendering rule

**Build every node with `createElement` and set text with `textContent`.** One helper, used for
everything:

```js
const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined && text !== null) n.textContent = String(text);
  return n;
};
```

**Banned outright, with no exception for "this field is just an id":** `innerHTML`,
`outerHTML`, `insertAdjacentHTML`, `document.write`, `eval`, `new Function`, and any
`element.setAttribute('on…', …)`. Attribute values that come from the data (a `title=`, an
`href`) are equally untrusted — prefer not to put board text in an attribute at all. Check the
built file:

```bash
grep -n 'innerHTML\|outerHTML\|insertAdjacentHTML\|document\.write\|eval(\|new Function' .guild/dashboard.html
```

Nothing printed is the passing result.

### What the page must be

- **Self-contained.** All CSS and JS inline, the data inline. No CDN, no external font, no
  `fetch`, no network of any kind — it works offline and from `file://`.
- **Theme-aware and readable at a glance.** Severity and status carry colour; nothing depends on
  colour alone.
- **Nine views**, switched client-side:

  | View | Answers | From |
  |------|---------|------|
  | **Roadmap** | goals → projects → requirements, with live progress. A project shows whether it is **runnable** and, when `isolation` is `worktree`, the checkout its tasks run in; sibling projects that are runnable at the same time render side by side rather than as a queue | `goals`, `projects`, `requirements` |
  | **Board** | tasks by section, coloured by priority, blocked ones tagged with their reason | `tasks`, `blocked` |
  | **Graph** | each requirement's execution graph, node status and the gates — plus the plans still waiting on a human, including any with no gate node behind them | `nodes`, `edges`, `gates`, `approvals` |
  | **Bugs** | open defects by severity, linked to their fix tasks | `bugs` |
  | **Findings** | what reviewers flagged and whether it was ever fixed — grouped by severity, unresolved first, filterable to the resolved | `findings` |
  | **Coverage** | quality areas by risk, and how long since anyone looked | `coverage` |
  | **Decisions** | the ADR log, newest first — what this project chose, what each one replaced and what replaced it, and which work it governs. A superseded decision renders struck through rather than hidden: the chain **is** the content | `decisions` |
  | **Library** | every current page by `kind` and `area`, with its revision and edge counts; stale pages flagged with the subject that moved, and finished requirements nobody documented listed beside them | `docs`, `links`, `docs_stale`, `undocumented` |
  | **Activity** | the event feed, newest first | `activity` |

- **Every summary tile is a link to the view behind it.** `Open findings` lands on Findings,
  `Open bugs` on Bugs, `In flight` and `Todo` on Board. A number the reader cannot click through
  to a list of names is the failure this page exists to fix.
- **An area with no `last` is "never inspected", not "0 days ago".** Rendering it as fresh lies
  about the state of the product.
- **Draw the decision chain, not just the list.** A `decision` row carries `supersedes` and
  `superseded_by` as space-separated slugs, which is enough to render each chain in order with
  no layout engine — the same way the graph view renders predecessors. The reason this view
  exists is that "we tried X, then moved to Y, for this reason" is the single hardest thing to
  recover from a repository, and it is one `json` field away here.
- **`links` carries every edge, including the ones into the work.** That is what lets the
  Library view answer "what governs REQ-004" by filtering client-side, with no second query.
- **A stale page is a warning, never an error.** Amber, not red — nothing is broken, a page just
  needs re-reading. Red is for defects.
- **Roster gaps belong on the Board view, next to the blocked tasks they explain** — the two are
  one story.

The graph view does not need a layout engine: nodes grouped by requirement, in id order, each
showing its status and its predecessors from `edges`, reads perfectly well as a list. Draw
something fancier only if the user asks.

## Step 4 — open it

```bash
open .guild/dashboard.html 2>/dev/null || xdg-open .guild/dashboard.html 2>/dev/null \
  || echo "built: .guild/dashboard.html"
```

**A failure to open is not a failure to build.** On a headless box the file is still there —
report the path and move on. Point the user at whichever view answers what they actually asked;
if they said "the roadmap", say the page opened on it rather than reciting all seven.

## Step 5 — offer the shareable link, do not take it

The local file is the mechanism. Publishing it as an Artifact is a **convenience, and it is
never automatic** — the page carries the project's real requirement titles, task bodies, bug
reports and activity history, and a link is a different disclosure decision from a file on the
user's own disk.

So: build the file, report the path, and then offer once —

> Want a shareable link for this? I can publish it as an Artifact.

Publish **only** if they say yes: read the generated file, publish it with the Artifact tool
passing that path, and hand back the URL. Do not publish on your own initiative, do not publish
"so it's ready", and do not re-publish on a later rebuild unless asked again.

## Step 6 — verify against §6

Run `guild:validate dashboard`. §6 of `docs/expectations.md` asserts over the **artifact**,
not the board: §6.a–§6.b are the escape and the `</script>` closer count, §6.c that every
view key is present and empty means `[]` rather than `null`, §6.d that no banned sink and no
external request survived. Three of those are security, not cosmetics. **Report any failure
with its rows and do not open a page that failed one.**

## Rules

- **Read-only.** Every statement is a `SELECT`. Never `UPDATE`, `INSERT` or `DELETE` from here,
  never stamp `last-checkin`, and never open the database with anything but `tursodb`.
- **The escape and the `textContent` rule are the two non-negotiables.** Board text is
  untrusted input. If you find yourself reaching for `innerHTML` to render a badge, build the
  badge with `createElement` instead.
- **Never interpolate a value into the HTML source.** Board data reaches the page through the
  JSON island and nowhere else — not into a `<title>`, not into a CSS string, not into an
  `href`. The island is the only door, which is what makes one escape sufficient.
- **`.guild/dashboard.html` is rewritten wholesale** on every build. Never hand-edit it; the
  next build discards the edit.
- **Read the view, do not re-derive the rule.** Board sections, blocked reasons, goal progress
  and the standup counts each have exactly one definition, and it is a view. Recomputing one in
  JavaScript gives the guild two answers to one question.
- **Do not narrate the numbers.** The page shows them. If the user wants a spoken summary, that
  is `guild:brief` — offer it rather than duplicating it here.
