# Recruiting — the strategist hit a roster gap

This runs **only** when the strategist's `NEEDS INPUT:` block opens with `ROSTER GAP`. The
plan needs a capability no available subagent declares, and it is now the **guild master's
decision** — the roster is their layer, exactly like goals and projects.

> **Nothing here creates an agent without the user saying so.** Not you, not the strategist,
> not on a "reasonable inference". An agent file is a permanent addition to the guild.

**Why live rather than at `gate-plan`.** The gap is written into the plan's Technical
Decisions, so it **also** surfaces at `gate-plan` — but the strategist cannot write the
affected ticket until it knows the answer, and its session does not survive the gate.

**1. Verify the gap before you ask.** The strategist's block is a claim; this is the check:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py" --covers implement,rust
```

**Any output at all means there is no gap** — somebody already declares it, and the strategist
should simply use them. Only empty output justifies the question below.

**2. Ask once, with AskUserQuestion**, putting the rationale and the proposed spec in the
question body so the decision is informed:

| Choice | What it means |
|---|---|
| **Create `{proposed-agent}`** | The guild grows a permanent new member. The next requirement needing this capability finds it already there. |
| **Assign to `{existing member}` anyway** | The work goes to a generalist. The gap stays on the record, because the guild still cannot do this work well. |
| **Revise the plan** | The strategist redraws the tickets so the capability is not needed. Collect what the user wants changed. |

**3a. On "create":**

1. Scaffold the agent file from the strategist's proposed spec, in the guild's agents directory
   (`$GUILD_AGENTS_DIR` if set, else `${CLAUDE_PLUGIN_ROOT}/agents/{name}.md`):

   ```markdown
   ---
   name: developer-rust
   model: sonnet
   color: orange
   tools: ["Read", "Grep", "Glob", "Write", "Edit", "Bash"]
   capabilities: [implement, backend, rust]
   serial: false
   description: |
     Use this agent when the guild needs idiomatic Rust implementation. …
   ---

   # Rust Developer — Guild Agent
   {the role, the workflow, the close-out protocol — mirror an existing agent of the same shape}
   ```

   `plugin-dev:agent-development` is the skill to load for help writing the body well.
2. **Show the user the file and get their sign-off before syncing.** They asked for a member,
   not for whatever you wrote; this is a review, not a notification.
3. **Writing the file IS the recruitment.** There is nothing to admit, sync or close — the
   capability is legal the moment the frontmatter declares it.
4. Confirm with the scan, which is now the only check there is:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py" --covers implement,rust
   ```

   No output means the file's `capabilities:` does not actually say what you think — a typo, a
   malformed list, or a file in a directory the scan does not reach. Fix the file.
5. `SendMessage` the strategist: `"Roster gap resolved: developer-rust exists and declares
   [implement, backend, rust]. Create the held tickets requiring implement + rust."`

   **A newly added agent file is in the roster immediately, but the `Agent` tool resolves
   `subagent_type: "guild:{name}"` from the plugin manifest the session loaded at startup.** If
   a later dispatch reports an unknown subagent type, that is what happened: tell the user to
   restart Claude Code, and until they do, the ticket is dispatchable only by pinning it to an
   existing member.

**3b. On "assign anyway":** `SendMessage` the strategist the member's name and let *it* write
the tickets — pin `agent` **and** declare the capabilities, so the board records both the pin
and what the work actually required. Two things to say out loud, because both look like
problems later and neither is:

- **The gap does not go away.** Nothing but a real agent file closes it, so it stays in the
  plan's Technical Decisions as the record that the guild still cannot do this work well.
- **The pinned ticket dispatches normally.** A pin skips the capability match entirely, so it
  will not go `blocked` and it will not appear as a gap on the board. The record of what the
  work actually required is the `task_capability` rows the strategist wrote alongside the pin —
  that is what makes the pin reviewable later.

**3c. On "revise the plan":** `SendMessage` the strategist what the user wants changed and let
it redraw them. The same note about the request staying open applies.

**4. Never do any of these:** write an agent file the user did not approve; create or re-create
a ticket to work around a gap; or treat "the user did not answer" as consent. If the answer is
ambiguous, ask again rather than picking.
