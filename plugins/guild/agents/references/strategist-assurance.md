# Assurance — deciding what gets tested and what gets reviewed

Load this at **Step 3.7**, after you have designed the tickets and before you write the plan.

**The guild does not assume that every piece of work is tested and reviewed.** Testing and review
cost agent time and attention, and for some work they buy nothing: a research note has no
behaviour to pin, a draft article has no attack surface, a renamed file has nothing a second
reader would catch. Running a test-planner over a post produced a plan of 22 checks and 0 tests;
running four code reviewers over it produced 0 findings. That is not assurance, it is ceremony —
and ceremony teaches everyone to skim the real findings.

So the question is asked **first**, per piece of work, and answered on the record. You are not
choosing between "careful" and "fast". You are choosing the cheapest assurance that would actually
catch a defect in *this* deliverable.

## The two questions

Ask both of every producing ticket (the `implement` tickets — whatever the domain calls them: code,
an article, a diagram, a migration).

### 1. Verification — can running something catch a defect here?

| Answer | Means | Graph effect |
|---|---|---|
| **`tests`** | The deliverable has **behaviour a test can pin**: logic, branching, state, parsing, an integration seam, a contract other code depends on. | `test-plan` and `test-write` run. |
| **`checks`** | No behaviour to pin, but a defect can still be caught by **running a command or walking a checklist** against the acceptance criteria — a build, a linter, a link check, a word count, a schema validation, a render. Someone must *plan* those checks because they are many or non-obvious. | `test-plan` runs and **declares no test-writer tickets**. `test-write` is skipped. |
| **`none`** | Nothing to run, or the acceptance criteria are already checkable by the author in one pass and the ticket's own **Acceptance Criteria** say how. | `test-plan` and `test-write` are skipped. |

**Signals for `tests`:** it computes, decides, stores, parses, validates, authenticates, routes or
migrates. A bug in it would be a wrong *answer*, not a wrong *sentence*.

**Signals for `checks`:** content or configuration with machine-checkable rules — an article with a
word limit and a citation format, a config file with a schema, a diagram with required labels.

**Signals for `none`:** research notes, a decision record, a rename, a comment-only change, a
one-line copy edit, a diagram whose only criterion is "it exists and matches the template".

**The requirement may have already decided.** If the requirement or the repository's own rules say
"must have tests" or "tests must not pin content", that is the answer — record it as given rather
than re-deciding it.

### 2. Review — would a second reader catch something the author could not?

| Answer | Means | Graph effect |
|---|---|---|
| **`full`** | Work where a missed defect is costly or silent: security-relevant, data-touching, public-facing and hard to retract, a shared contract, non-trivial logic. | All four reviewers run. |
| **`focused`** | A second reader is worth it, but not every lens applies. Name the lenses that do. | Only the named reviewers run; the others are skipped. |
| **`none`** | The deliverable is easy to inspect and reverse, nobody depends on it yet, and the author's own checks already cover the acceptance criteria. | All four reviewer nodes are skipped. |

The four lenses and what each is *for*, so you can choose rather than guess:

| Reviewer | Worth keeping when the work… |
|---|---|
| `reviewer-security` | handles input, secrets, authentication, authorization, third-party hosts, or personal data |
| `reviewer-architecture` | adds or reshapes structure other work will build on, or must follow plan-level decisions |
| `reviewer-business-logic` | must satisfy acceptance criteria or rules that someone could mis-implement (this includes "does the article say what the brief required") |
| `reviewer-edge-case` | takes variable input, has boundaries, failure paths or concurrency |

### Never `none` for review when…

- the work touches **authentication, authorization, secrets, money, personal data, or production
  data**, or ships a **migration**;
- the effect is **hard to undo** once released — a published artifact, a sent message, a deploy,
  a schema change;
- the requirement **asks for review** (or for tests) in so many words;
- **you cannot say why it is safe to skip.** A reason you cannot write down is not a reason.

**When in doubt, keep the step.** A step skipped on a guess costs more than a step kept. The guild
master sees every decision here at `gate-plan` and can overrule it, so a decision you made
cautiously costs one sentence of attention, and one you made boldly and wrongly costs a defect
that shipped.

## A mixed requirement is decided per ticket, then taken as a union

The graph is per requirement but the work is per ticket. A requirement with a service change and a
documentation page needs tests for the first and not the second.

1. Decide both questions **for each producing ticket** and write the answer in that ticket's
   `## Assurance` section (below).
2. The graph keeps a step if **any** ticket needs it: `test-write` runs if any ticket is `tests`;
   `review` runs if any ticket is `full` or `focused`; the reviewer set is the union of lenses.
3. The step then works **only on the tickets that asked for it.** Write that scope into the plan's
   Assurance table — the test-planner and the reviewers read it and leave the other tickets alone.

## Where the decision is written

Three places, so it is findable, enforceable and reversible.

**1. The plan overview** carries an `## Assurance` section — the table the guild master reads at
`gate-plan`:

```markdown
## Assurance

| Ticket | Verification | Review | Why |
|---|---|---|---|
| TASK-126 execution-graph figure | none | none | A static SVG compared against the template by its author; nothing to run, nothing secret, trivially reversible. |
| TASK-127 research post | checks | focused: business-logic, edge-case | Rules are machine-checkable (word count, citations, build) but there is no behaviour to pin; no input or secrets, so no security lens. Draft only, not published. |

Graph effect: `test-plan` runs (checks only, no test-writer tickets); `test-write` skipped;
`review` runs with 2 of 4 reviewers.
```

**2. Each ticket brief** carries a short `## Assurance` section — two lines, so a developer, writer
or reviewer sees what is expected of the deliverable without opening the plan:

```markdown
## Assurance
- Verification: checks — `pnpm post check`, `pnpm build`, word count 1,500–3,000
- Review: focused (business-logic, edge-case)
```

**3. The graph**, as a `graph_deviation` row **per step you skip or narrow**, with the reason. This
is what makes a skip auditable, and `G8` asserts it exists.

## Recording it in the graph

**A skipped step is KEPT in the graph, born `skipped`.** It is not deleted and no edge is stitched.
`done` and `skipped` both count as finished, so a successor of a skipped node becomes ready the
moment its other predecessors finish, with no repair of the edges. Node and edge counts stay at
**N + 10 / 2N + 11**, every template key still has a node, and the board shows the decision as a
visible `skipped` rather than a hole.

**This is the one status write you make.** You still never move a node as work progresses — that
is the orchestrator's. Marking an assurance skip is part of *building* the graph, before
`gate-plan` is decided, and it is why the statement below carries `AND status = 'pending'`: it
cannot touch a node that has started.

Write the reason first, as hex (it is free text — see the warehouse skill):

```bash
r=$(printf '%s' "Assurance: TASK-126 and TASK-127 are prose and a static figure. Their rules are checkable by the author with the site's own commands and nothing in them has behaviour a test could pin; the repository forbids tests that depend on post content." | xxd -p | tr -d '\n')
```

**Verification `none`** — skip both test steps:

```bash
{ printf "PRAGMA foreign_keys = ON;\n"
  printf "UPDATE guild_state SET value = 'strategist' WHERE key = 'actor';\n"
  printf "UPDATE graph_node SET status = 'skipped'
           WHERE requirement_id = 'REQ-NNN' AND node_key IN ('test-plan','test-write')
             AND status = 'pending' RETURNING id, status;\n"
  printf "INSERT INTO graph_deviation (requirement_id, kind, node_key, reason, created_at)
          SELECT r.id, 'drop-node', k.value, CAST(x'$r' AS TEXT),
                 strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now')
            FROM requirement r JOIN json_each(json_array('test-plan','test-write')) k
           WHERE r.id = 'REQ-NNN' RETURNING id, node_key;\n"
} | tursodb -q -m list "$DB"
```

**Verification `checks`** — skip `test-write` only. Change the `IN (...)` list and the
`json_array(...)` to `'test-write'` alone. `test-plan` stays and plans the checks.

**Review `none`** — skip the four reviewer nodes:

```bash
{ printf "PRAGMA foreign_keys = ON;\n"
  printf "UPDATE guild_state SET value = 'strategist' WHERE key = 'actor';\n"
  printf "UPDATE graph_node SET status = 'skipped'
           WHERE requirement_id = 'REQ-NNN' AND node_key = 'review'
             AND status = 'pending' RETURNING id, status;\n"
  printf "INSERT INTO graph_deviation (requirement_id, kind, node_key, reason, created_at)
          SELECT r.id, 'drop-node', 'review', CAST(x'$r' AS TEXT),
                 strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now')
            FROM requirement r WHERE r.id = 'REQ-NNN' RETURNING id;\n"
} | tursodb -q -m list "$DB"
```

**Review `focused`** — skip only the lenses you did *not* name, and record a `reshape`. Here
security is the lens being left out:

```bash
{ printf "PRAGMA foreign_keys = ON;\n"
  printf "UPDATE guild_state SET value = 'strategist' WHERE key = 'actor';\n"
  printf "UPDATE graph_node SET status = 'skipped'
           WHERE id IN ('REQ-NNN/review.reviewer-security','REQ-NNN/review.reviewer-architecture')
             AND status = 'pending' RETURNING id, status;\n"
  printf "INSERT INTO graph_deviation (requirement_id, kind, node_key, reason, created_at)
          SELECT r.id, 'reshape', 'review', CAST(x'$r' AS TEXT),
                 strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now')
            FROM requirement r WHERE r.id = 'REQ-NNN' RETURNING id;\n"
} | tursodb -q -m list "$DB"
```

Use a separate hex reason for each step you skip when the reasons differ. A reason that would fit
any requirement ("not needed") is the same as no reason.

**The four reviewer nodes always stay four**, some of them `skipped`. Never delete one, and never
add a fifth here.

### What you create, and do not create

A skipped step gets **no ticket**, because a ticket with no node that will ever run is an open
ticket that blocks the requirement from closing.

| Outcome | Test-planner ticket | Reviewer ticket |
|---|---|---|
| `tests` | create | create if review is not `none` |
| `checks` | create | create if review is not `none` |
| `none` verification | **do not create** | create if review is not `none` |
| review `none` | create if verification is not `none` | **do not create** |
| both `none` | **do not create** | **do not create** |

The reviewer ticket is still **one** ticket with `agent = 'reviewer'` however many lenses you
kept — the graph fans it out, you do not. The librarian ticket is unaffected.

## When nothing is left to review or test

If you skip both, the run goes `implement → document`, with `gate-repairs` still in between.
**That gate stays** — gates are never dropped — and the orchestrator presents it as a short
confirmation when nothing was collected (check-in §3.5). If the *whole requirement* is something
you would not want a human stopped for twice, say so in your report; that is a case for the guild
master to weigh, not for you to engineer around.

## Report it

In your final report (Step 7), list **every assurance decision**: for each ticket, verification and
review with the one-line reason, and which graph steps you skipped. If you skipped nothing, say
"every step kept" and why — for code that is the expected answer.
