# Compiling a batch into a run

Read this when you are about to run a batch and want the **Workflow** tool, or when a run
crashed and you need to know what is recoverable. **The hot path in `SKILL.md` does not need
it** — parallel `Agent` calls in one message are complete on their own, and this document
exists so the good path is available, not so it is required.

---

## The input

The segment query in SKILL.md Step 3.1. One row per ready node, already carrying its ticket,
its rank-1 member and that member's `serial` flag:

```json
{"node":"REQ-007/implement.auth-service","key":"implement","kind":"work","group":"wave-1",
 "task":"TASK-011","agent":"developer","serial":0,"gate":"","gate_kind":"","prompt":""}
{"node":"REQ-007/implement.session-store","key":"implement","kind":"work","group":"wave-1",
 "task":"TASK-012","agent":"developer","serial":0,"gate":"","gate_kind":"","prompt":""}
```

Three properties the compiler depends on:

- **It is the state right now, not a plan.** There is no multi-batch look-ahead any more and
  none is needed: readiness is a one-hop join, so it propagates as the batch finishes. Run
  one batch, record it, ask again. A compiler that queued the whole graph would be compiling
  a future it cannot see.
- **Concurrency is a decision you make from the template plus the data**, per SKILL.md 3.2 —
  the template's `parallel:` is the ceiling, `group` is the grouping, and no two `serial = 1`
  members may share a concurrent batch.
- **`task` and `agent` may be empty.** An unbound node is ordinary — the architect binds a
  ticket only where the correspondence is unambiguous. You resolve those yourself (3.3) and
  record the binding with `UPDATE graph_node SET status='running', task_id='TASK-NNN'`.

---

## The output, when the Workflow tool is available

**Workflow needs explicit user opt-in, and a skill whose instructions direct the orchestrator
to call it satisfies that** — these instructions do, plainly. If the tool is not present, skip
to *Graceful degradation*.

```js
export const meta = {
  name: 'guild-REQ-007-implement',
  description: 'REQ-007 — the implement wave',
  phases: [{ title: 'Implement' }],
}

// Independent slice chains PIPELINE. A fast slice is not held behind a slow one.
await pipeline([
  () => agent(dispatch('REQ-007/implement.auth-service'), { phase: 'Implement' }),
  () => agent(dispatch('REQ-007/implement.session-store'), { phase: 'Implement' }),
])
```

### The five rules

1. **Prefer `pipeline()` over `parallel()`.** A barrier is only right when a stage genuinely
   needs *all* prior results together. In the `standard` template exactly one does —
   `test-plan`, because it inventories the whole diff — and `review` after it. `parallel()`
   where `pipeline()` would do costs wall-clock time for nothing.
2. **A barrier only where a stage needs everything before it.** Read it off the graph rather
   than guessing: a node whose predecessors are the *whole* of a fanned-out key is a barrier.
   `v_ready_nodes.predecessors` lists them, and `test-plan`'s lists every `implement.*`.
3. **Every agent reports into the database.** `work_log`, `review_finding`, `bug`. The
   workflow's return value is a summary; **the rows are the record.** That is what makes a
   crashed workflow recoverable — node status lives in `graph_node`, so re-running the
   segment query simply excludes what finished. Never carry state between batches in the
   script.
4. **Serial agents are never batched.** `qa-tester` carries `serial = 1`: Playwright is heavy
   and each tester drives its own dev server, so two at once collide on ports. If you find
   yourself compiling a concurrent batch with two of them, **stop and report it — do not
   silently serialize.** A shape that requests illegal concurrency is a bug worth surfacing at
   compile time rather than papering over at run time.
5. **The workflow may not ask the user anything.** Subagents cannot call `AskUserQuestion`;
   only the orchestrator session can. That is *why* a run stops before a gate rather than
   containing one — the batch boundary and the "stop and ask" boundary are the same line.

### `dispatch(node)` — what goes in the prompt

The same prompt SKILL.md Step 3.3 uses. Compose it in the orchestrator, not in the workflow:
resolving the member is a query against `v_task_top_agent`, and the ticket move must happen
before the agent starts.

---

## Graceful degradation — the path that always works

**If the Workflow tool is unavailable, unpermitted, or fails to start, fall back to parallel
`Agent` calls in a single message.** Same batch, same order, same results:

```
loop:
    read the segment query
    if the batch is concurrent:  one Agent call per node, ALL IN ONE MESSAGE
    else:                        one Agent call, one message, per node in order
    wait for all of them
    record results (SKILL.md 3.4), then read the segment query again
```

**Nothing in the graph or the gates knows whether a workflow ran** — `graph_node.status` is
the only state, and both paths write it with the same UPDATE. Choosing the fallback costs you
deterministic retry and a nicer progress display; it costs the guild nothing.

---

## After a crash

A run that died mid-batch leaves the board in a state you can read:

```sql
SELECT id, node_key, status FROM graph_node WHERE requirement_id = 'REQ-007' ORDER BY id;
SELECT json_object('ts', ts, 'agent', agent, 'entry', entry)
  FROM work_log WHERE task_id = 'TASK-011' ORDER BY ts, id;
```

- Nodes at `done` are finished; the segment query will not re-emit them.
- A node left `running` is the crash site. Its agent is gone. Read its ticket's work log and
  decide as at SKILL.md Step 1.3: nothing logged → `pending`; work logged and complete →
  finish it; work logged and partial → re-dispatch with the RESUMED-TASK prompt.
- A node left `running` **holds everything behind it** — deliberately. That is why a crash
  produces a stalled segment rather than a review of half-written code.

Repairing a crash is ordinary SQL, but keep it to the two status columns. Editing rows to
make the board *look* consistent invents history the `event` feed will contradict.
