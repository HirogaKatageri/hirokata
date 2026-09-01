---
name: dashboard
description: >
  This skill should be used when the user asks for "the dashboard", "guild dashboard",
  "open the dashboard", "show me the dashboard", "build the dashboard", "visualize the
  board", "the roadmap", "show the roadmap", "a visual view of the guild", "the board
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
byte-exact. The three `replace()`s do the escaping **inside the engine**, before the value ever
touches a shell:

```bash
export PATH="$HOME/.turso:$PATH"
cat > /tmp/guild-dash.sql <<'SQL'
SELECT replace(replace(replace(json_object(
  'brief', (SELECT json_group_array(json_object('fact',fact,'value',value)) FROM v_brief),
  'goals', (SELECT json_group_array(json_object('id',id,'status',status,'priority',priority,
              'phase',COALESCE(current_phase_id,''),'phase_title',COALESCE(current_phase_title,''),
              'done',requirements_done,'total',requirements_total,'title',title))
            FROM (SELECT * FROM v_goal_progress ORDER BY priority, id)),
  'phases', (SELECT json_group_array(json_object('id',id,'goal',goal_id,'ordinal',ordinal,
              'status',status,'title',title))
            FROM (SELECT * FROM phase ORDER BY goal_id, ordinal)),
  'requirements', (SELECT json_group_array(json_object('id',id,'phase',COALESCE(phase_id,''),
              'status',status,'priority',priority,'total',tasks_total,'done',tasks_done,
              'open',tasks_open,'blocked',tasks_blocked,'failed',tasks_failed,'title',title))
            FROM (SELECT * FROM v_requirement_progress)),
  'tasks', (SELECT json_group_array(json_object('section',section,'n',section_no,'id',id,
              'status',status,'who',who,'req',requirement_id,'priority',priority,'title',title))
            FROM (SELECT * FROM v_board)),
  'blocked', (SELECT json_group_array(json_object('id',id,'reason',reason))
            FROM (SELECT * FROM v_blocked_tasks)),
  'gaps', (SELECT json_group_array(json_object('cap',capability,'req',COALESCE(requirement_id,''),
              'proposed',COALESCE(proposed_agent,''),'covered',covered_by,'why',rationale))
            FROM (SELECT * FROM v_roster_gaps)),
  'nodes', (SELECT json_group_array(json_object('id',id,'req',requirement_id,'key',node_key,
              'kind',kind,'status',status,'task',COALESCE(task_id,''),
              'group',COALESCE(parallel_group,'')))
            FROM (SELECT * FROM graph_node ORDER BY requirement_id, id)),
  'edges', (SELECT json_group_array(json_object('from',from_node,'to',to_node))
            FROM (SELECT * FROM graph_edge ORDER BY from_node, to_node)),
  'gates', (SELECT json_group_array(json_object('node',node_id,'kind',kind,'status',status,
              'prompt',prompt,'decision',COALESCE(decision,''),'decided',COALESCE(decided_at,'')))
            FROM (SELECT * FROM gate ORDER BY node_id)),
  'bugs', (SELECT json_group_array(json_object('id',id,'severity',severity,'status',status,
              'by',found_by,'req',COALESCE(requirement_id,''),'fix',COALESCE(fix_task_id,''),
              'created',created_at,'title',title))
            FROM (SELECT * FROM bug ORDER BY id)),
  'findings', (SELECT json_group_array(json_object('id',id,'task',task_id,'reviewer',reviewer,
              'severity',severity,'disposition',disposition,'file',COALESCE(file,''),
              'line',COALESCE(line,0),'fix',COALESCE(fix_task_id,''),'created',created_at,
              'summary',summary,'detail',COALESCE(detail,'')))
            FROM (SELECT * FROM review_finding ORDER BY id)),
              'spec',COALESCE(spec_path,''),'last',COALESCE(last_inspected_at,''),
              'notes',COALESCE(notes,'')))
  'activity', (SELECT json_group_array(json_object('ts',ts,'actor',actor,'verb',verb,
              'type',subject_type,'subject',subject_id,'title',subject_title,'phrase',phrase))
            FROM (SELECT * FROM v_recent_activity LIMIT 200))
),
  '&', char(92) || 'u0026'),
  '<', char(92) || 'u003c'),
  '>', char(92) || 'u003e');
SQL
tursodb -q -m list .guild/guild.db < /tmp/guild-dash.sql > /tmp/guild-data.json
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
- **Seven views**, switched client-side:

  | View | Answers | From |
  |------|---------|------|
  | **Roadmap** | goals → phases → requirements, with live progress | `goals`, `phases`, `requirements` |
  | **Board** | tasks by section, coloured by priority, blocked ones tagged with their reason | `tasks`, `blocked` |
  | **Graph** | each requirement's execution graph, node status and the gates | `nodes`, `edges`, `gates` |
  | **Bugs** | open defects by severity, linked to their fix tasks | `bugs` |
  | **Findings** | what reviewers flagged and whether it was ever fixed — grouped by severity, unresolved first, filterable to the resolved | `findings` |
  | **Activity** | the event feed, newest first | `activity` |

- **Every summary tile is a link to the view behind it.** `Open findings` lands on Findings,
  `Open bugs` on Bugs, `In flight` and `Todo` on Board. A number the reader cannot click through
  to a list of names is the failure this page exists to fix.
- **An area with no `last` is "never inspected", not "0 days ago".** Rendering it as fresh lies
  about the state of the product.
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
