# Graph deviations — kinds, rules, and what enforces each

Load this at Step 6b, when the work genuinely calls for departing from the template. A clean
instantiation needs none of this.

A deviation is the node/edge change **plus** a `graph_deviation` row recording it. Write both:

```bash
r=$(printf '%s' "the payments provider's webhook API is undocumented in the repo and no doc row
covers it; implementing against a guess is the largest risk in this plan" | xxd -p | tr -d '\n')
{ printf "PRAGMA foreign_keys = ON;\n"
  printf "UPDATE guild_state SET value = 'strategist' WHERE key = 'actor';\n"
  printf "INSERT INTO graph_deviation (requirement_id, kind, node_key, reason, created_at)
          SELECT r.id, 'add-node', 'research', CAST(x'$r' AS TEXT),
                 strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now')
            FROM requirement r WHERE r.id='REQ-NNN'
          RETURNING id;\n"
} | tursodb -q -m list "$DB"
```

The four kinds, and what each is for:

| Kind | Use it when | What you also write |
|---|---|---|
| `add-node` | the work needs a step the template does not have — a `research` node ahead of `implement` for an unfamiliar API | the `graph_node` row, its `graph_edge`s, and a ticket declaring the capability |
| `drop-node` | a template step is genuinely inapplicable — dropping `test-plan` for a docs-only change | **stitch the predecessors to the successors yourself** — nothing does it for you, and an unstitched drop severs the graph |
| `reshape` | the step stays but its width or waves change — fanning `review` wider for a UI-heavy requirement; splitting `implement` into sequential waves because the file sets are not disjoint | the extra/fewer nodes, and the `parallel_group` labels that express the waves |
| `add-gate` | **never** | — |

The rules, and **who enforces each one — read this before you trust it:**

| rule | enforced by |
|---|---|
| `kind ∈ ('work','gate')`, the status vocabulary, `reason` non-empty, no self-edge | **the database**, via CHECK — cannot be bypassed |
| node id uniqueness, edge uniqueness, one gate row per gate node | **the database**, via PRIMARY KEY |
| readiness, the review gate, the board | **the database**, via views — one definition, not one per reader |
| "no third gate", "no dropped required node", "add-node names a capability somebody has", "the graph is acyclic" | **you**, by running the template's §8 queries and reading the output |

- **A gate may never be added and never dropped.** `graph_node` will happily accept a third
  one. Adding a gate is the subtle failure: it reads as caution and it quietly turns an
  unattended run into a session that stops every twenty minutes waiting for a human who is
  asleep. If work needs a decision, it belongs at `gate-repairs`. An `add-gate` deviation row
  is a failure however good the reason — the template's check (c) looks for exactly that.
- **A `required: true` node may be reshaped, never dropped.** `gate-plan`, `implement`,
  `review`, `gate-repairs` and `document` are required — that is the exact set G8 asserts, and
  `document` is the one people forget, so a `standard` graph missing it returns
  `dropped-required-node | REQ-nnn | document`. (`maintenance` carries no `document`; an
  inspection produces bugs and specs, not new subsystem knowledge.) Review always happens; how
  wide it fans out is negotiable. Dropping it is a judgement about the guild's standards, which
  is not yours to make.
- **`add-node` must name a capability some available subagent declares.** A node nobody is
  eligible for is a node the run stalls at forever, discovered mid-shift. Check before you
  insert:
  ```bash
  python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py" --covers {cap}
  ```
  No output means a roster gap — Step 3.6, not a workaround.
- **An empty reason is refused by a CHECK**, and whitespace-only counts as empty. Write it for
  the person who diffs this graph against the template six weeks from now: what about *this*
  requirement made the standard shape wrong.
- **Declare every edge backwards in template order** — `to_node` must be a node declared after
  `from_node`. With no `WITH RECURSIVE` there is no traversal that can detect a cycle, and a
  cycle makes `v_ready_nodes` return nothing for the whole loop: a **silent stall**, not an
  error. Edges that all point backwards in declaration order cannot form one, and that is the
  only protection there is.
- **Every template key gets at least one node.** That is what makes "dropped" unambiguous — a
  key with zero rows was dropped, full stop, with no *"unless its fan-out happened to be
  empty"* to hide behind. It is why `implement` has a no-tickets fallback and why `test-write`
  and `repair` are anchors.
