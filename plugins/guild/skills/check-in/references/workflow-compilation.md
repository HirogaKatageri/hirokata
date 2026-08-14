# Compiling a segment into a run (design §7)

Read this when you are about to run a segment and want the Workflow tool, or when a run
crashed and you need to know what is recoverable. **The hot path in `SKILL.md` does not
need it** — the fallback (parallel `Agent` calls in one message) is complete on its own,
and this document exists so the good path is available, not so it is required.

---

## The input

```bash
"$GUILD" segment REQ-007 --json
```

```json
{
  "requirement": "REQ-007",
  "template": "standard",
  "batches": [
    { "parallel": true,  "nodes": ["REQ-007/implement.auth-service",
                                   "REQ-007/implement.session-store"],
      "agents": ["developer", "developer"],
      "tasks":  ["TASK-011", "TASK-012"] },
    { "parallel": false, "nodes": ["REQ-007/implement.migrations"],
      "agents": ["developer"], "tasks": ["TASK-013"] },
    { "parallel": false, "nodes": ["REQ-007/test-plan"],
      "agents": [null], "tasks": [null] },
    { "parallel": true,  "nodes": ["REQ-007/review.reviewer-security",
                                   "REQ-007/review.reviewer-architecture",
                                   "REQ-007/review.reviewer-business-logic",
                                   "REQ-007/review.reviewer-edge-case"],
      "agents": [null, null, null, null], "tasks": [null, null, null, null] }
  ],
  "next_gate": {
    "node": "REQ-007/gate-repairs",
    "kind": "select-findings",
    "status": "pending",
    "decision": null,
    "prompt": "Findings and bugs from REQ-007 — approve which get repaired."
  }
}
```

Three properties of this document that the compiler depends on:

- **`batches` is ordered.** Batch *n+1* may depend on batch *n*; nothing in batch *n*
  depends on anything in batch *n+1*. That is the whole contract.
- **`parallel` is a hard fact, not a hint.** `false` means these nodes must not run
  concurrently. `true` means the guild has already asserted they may — disjoint file sets
  from the architect's `plan slice --files`, and no two `serial` members in one batch
  (`guild segment` exits 1 rather than emitting such a batch at all).
- **`agents[i]` / `tasks[i]` line up with `nodes[i]`**, and either may be `null`. `null`
  means the node carries no ticket yet, which is ordinary — `guild graph new` binds a
  ticket only where the correspondence is unambiguous. You resolve those yourself (SKILL.md
  Step 3.3) and record the binding with `guild node <NODE> running --task TASK-NNN`.

---

## The output, when the Workflow tool is available

**Workflow needs explicit user opt-in, and a skill whose instructions direct the
orchestrator to call it satisfies that** — these instructions do, plainly, so no separate
permission dance is needed. If the tool is not present, skip to *Graceful degradation*.

```js
export const meta = {
  name: 'guild-REQ-007-seg1',
  description: 'REQ-007 — implement, test-plan, test-write, review',
  phases: [{ title: 'Implement' }, { title: 'Test planning' },
           { title: 'Test authoring' }, { title: 'Review' }],
}

// Independent slice chains PIPELINE. A fast slice is not held behind a slow one.
await pipeline([
  () => agent(dispatch('REQ-007/implement.auth-service'), { phase: 'Implement' }),
  () => agent(dispatch('REQ-007/implement.session-store'), { phase: 'Implement' }),
])

// A barrier, and it is the right one: test-plan inventories the WHOLE diff.
await agent(dispatch('REQ-007/test-plan'), { phase: 'Test planning' })
```

### The five rules

1. **Prefer `pipeline()` over `parallel()`.** A barrier is only right when a stage
   genuinely needs *all* prior results together. In the `standard` template exactly one
   stage does — `test-plan`, because it inventories the whole diff — and `review` after it.
   Independent slice chains should pipeline so a fast slice is not held behind a slow one.
   `parallel()` where `pipeline()` would do costs wall-clock time for nothing.

2. **A barrier only where a stage needs everything before it.** Read it off the graph
   rather than guessing: a node whose predecessors are the *whole* of a fanned-out key is a
   barrier. `guild graph REQ-007` prints each node's `after:` column, and `test-plan`'s
   lists every `implement.*` instance. That is what a barrier looks like in the data.

3. **Every agent reports through the CLI.** `guild log`, `guild finding`, `guild bug new`.
   The workflow's return value is a summary; **the database is the record**. This is what
   makes a crashed workflow recoverable: node status lives in `graph_node`, so re-running
   `guild segment` simply excludes what finished. Never carry state between batches in the
   script.

4. **Serial agents are never batched — and the compiler fails loudly if asked to.**
   `qa-tester` carries `serial: true`: Playwright is heavy and each tester drives its own
   dev server, so two at once collide on ports and thrash the machine. `guild segment`
   already refuses to emit such a batch (exit 1, naming both nodes and the agent), so if
   you ever see `"parallel": true` on a batch holding two serial members, something
   upstream is wrong — **stop and report it, do not silently serialize.** A template
   requesting illegal concurrency is a bug worth surfacing at compile time.

5. **The workflow may not ask the user anything.** Subagents cannot call
   `AskUserQuestion`; only this orchestrator session can. That is *why* a segment stops
   before a gate rather than containing one — the segment boundary and the "stop and ask"
   boundary are the same line, by construction.

### `dispatch(node)` — what goes in the prompt

The same prompt SKILL.md Step 3.3 uses. Compose it in the orchestrator, not in the
workflow: resolving the member is `guild match`'s job and it needs the CLI.

---

## Graceful degradation — the path that always works

**If the Workflow tool is unavailable, unpermitted, or fails to start, fall back to v4
behavior: parallel `Agent` calls in a single message.** Same batches, same order, same
results — no deterministic control flow, and you drive the sequencing yourself:

```
for each batch in segment.batches, in order:
    if batch.parallel:  one Agent call per node, ALL IN ONE MESSAGE
    else:               one Agent call per node, one message each, in order
    wait for all of them
    record results (SKILL.md Step 3.4)
```

**The design does not depend on Workflow being present.** Nothing in the graph, the
segment, or the gates knows whether a workflow ran — `graph_node.status` is the only state,
and both paths write it through `guild node`. Choosing the fallback costs you deterministic
retry and a nicer progress display; it costs the guild nothing.

---

## After a crash

A workflow that died mid-batch leaves the board in a state the CLI can read:

```bash
"$GUILD" graph REQ-007        # every node and its status
"$GUILD" segment REQ-007      # what is still runnable
```

- Nodes moved to `done` are finished; `guild segment` will not re-emit them.
- A node left `running` is the crash site. Its agent is gone. Drain its ticket
  (`guild spool drain TASK-NNN`), read the work log, and decide as at SKILL.md Step 1.3:
  nothing logged → `guild node <NODE> pending`; work logged and complete → finish it
  (`guild node <NODE> done`); work logged and partial → re-dispatch with the RESUMED-TASK
  prompt.
- A node left `running` **holds everything behind it** — that is deliberate, and it is why
  a crash produces a stalled segment rather than a review of half-written code.

Never repair a crash by editing the database. Every state above is reachable with
`guild node`, and every one of those calls is journaled.
