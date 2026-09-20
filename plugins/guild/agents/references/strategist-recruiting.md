# Recruiting — when the plan needs a capability nobody declares

Load this when Step 3.5's scan comes back empty for something the plan genuinely needs
(`rust`, `embedded`, `terraform`, `ios`) — a roster gap.

A roster gap found at *dispatch* time is already a failure: the plan is approved, work is
underway, and a bounty has nobody to take it. So you resolve it **here, at plan time, while
nothing has been built yet** — and you do **not** quietly route it to the nearest generalist.

Do this, in this order:

**1. Confirm the gap is real.** One command, and it is the same one that will run at dispatch:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py" --covers implement,rust
```

Empty output is a gap. **Any output at all is not** — read the row before you conclude
anything, because a member you had not thought of may already declare the word.

**THERE IS NO `capability_request` TABLE.** A row whose only job is to admit a word to a
vocabulary is pure bookkeeping when the vocabulary is just "what the agent files say" — **the
fix for a missing capability is writing the agent file, and nothing precedes it.**

**So the gap lives in two places, both of which the guild master actually reads:**

- **your plan's Technical Decisions**, as a named gap with the rationale and the member you
  propose. The plan goes through `gate-plan`, so this is what puts the decision in front of
  them — write it down even if you also raise it live, because your session does not survive
  the gate and the plan does.
- **the board**, if a ticket needing it is created anyway: it goes `blocked` at dispatch with
  `who = needs:implement+rust`, and check-in reports it by name. Louder than a request row ever
  was, because it names the ticket that is actually stuck.

**2. Stop and ask. You may not create an agent, and neither may the orchestrator without the
user.** Raise it through the normal relay — this is exactly what `NEEDS INPUT:` is for:

```
NEEDS INPUT:
1. ROSTER GAP — this plan needs a capability no available subagent declares: `rust`
   Confirmed with: roster.py --covers implement,rust  (no rows).
   Rationale: three implement tickets are Rust crates; `developer` has no Rust idiom guidance.
   Proposed member: developer-rust — Sonnet · tools Read/Grep/Glob/Write/Edit/Bash ·
   owns Rust implementation tickets, follows the plan's crate boundaries.

   Options:
   (a) Create the agent — I then require `implement,rust` on those tickets
   (b) Assign to `developer` anyway — I pin `agent = 'developer'`, still require
       `implement,rust`, and record the pin as a deviation in Technical Decisions
   (c) Revise the plan so the capability is not needed — tell me how and I will redraw the tickets
```

**Why you raise it live rather than leaving it for the gate.** The gap written into Technical
Decisions **surfaces at `gate-plan`** with the plan, so the guild master sees it whether or not
you say anything. But you cannot write the affected ticket until you know the answer, and your
session does not survive the gate, so the decision has to be made while you are still here. The
gate then shows what was decided. **An agent is never created behind the guild master's back**
— not by you, not by the orchestrator, not at the gate.

**3. Do not create the affected ticket until the answer comes back.** A ticket written before
the decision is one you would have to fix by hand afterwards — and the honest way to fix a
mis-declared ticket is to drop it and create it again, because its id has already been handed
to the graph and to sibling `task_dependency` rows. Create every *unaffected* ticket as normal;
hold the ones that turn on the gap. The same holds for the graph: **do not instantiate it while
a ticket is still held** (Step 6 explains why the order matters).

**4. Act on the answer:**

- **(a) create** — the orchestrator scaffolds the agent file from your proposed spec and the
  user reviews it. **That is the entire recruitment**: writing `capabilities: [implement, rust]`
  in the frontmatter is what admits the word, and there is nothing to sync afterwards. Confirm
  with `roster.py --covers implement,rust`, then write the tickets requiring `implement,rust`
  as you would any other. **Verified end to end:** with the file in place the scan returns
  `developer-rust`, and the ticket dispatches on the next check-in instead of going `blocked`.
- **(b) assign anyway** — pin `agent = 'developer'`, still require `implement,rust`, and write
  the pin into Technical Decisions with the reason. The gap stays open in the briefing, which
  is correct: the guild still cannot do this work well, and the record says so. Note in your
  report that the ticket **is** dispatchable — a pin wins the match outright and is never
  reported as a gap — so nobody parks it by mistake.
- **(c) revise** — redraw the tickets so the capability is not required, and say in Technical
  Decisions what you gave up.
