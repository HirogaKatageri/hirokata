# Session Tracker Plugin

Automatically summarize and persist your Claude Code work sessions. When you finish for the day, one phrase generates a structured entry appended to a daily log file — written by a dedicated Claude Haiku logger sub-agent so the main context stays clean.

---

## Installation

```bash
/plugin install session-tracker@hirokata
```

Or copy manually after cloning the marketplace:

```bash
git clone https://github.com/hirogakatageri/hirokata-cc-marketplace.git
cp -r hirokata-cc-marketplace/plugins/session-tracker /path/to/your-project/.claude-plugin/session-tracker
```

---

## Usage

At the end of any session, say one of the trigger phrases:

```
end session
wrap up
I'm done for today
let's wrap up
calling it a day
save the session
```

The plugin will:

1. Collect today's git commits and uncommitted changes
2. Compress the conversation into a structured context summary
3. Spawn the **`session-tracker:logger`** sub-agent (Claude Haiku) with that summary
4. The logger appends a new session entry to `.logs/YYYY-MM-DD-log.md`
5. Confirm the saved file

---

## Log File Format

Summaries accumulate in `.logs/YYYY-MM-DD-log.md`. Multiple sessions in the same day are appended with a `---` separator:

```markdown
# Log — 2026-05-19

## Session — 14:30

### What We Worked On
Added a session-tracker plugin to the marketplace. Focus was on the skill
structure, Haiku delegation pattern, and daily log format.

### Completed
- Created plugins/session-tracker/skills/end-session/SKILL.md
- Created plugins/session-tracker/agents/logger.md
- Created plugins/session-tracker/.claude-plugin/plugin.json

### Files Changed
- plugins/session-tracker/skills/end-session/SKILL.md (created)
- plugins/session-tracker/agents/logger.md (created)
- plugins/session-tracker/README.md (created)

### Next Steps
- Update marketplace CHANGELOG.md and bump version

---

## Session — 17:45

### What We Worked On
...
```

Sections with no content are omitted automatically.

---

## Storage

Logs are written to `.logs/` in the **current working directory** (your project root). Add to `.gitignore` to keep them local, or commit to share session history across the team:

```
.logs/
```

---

## Design Notes

**Why a logger sub-agent?**
The `session-tracker:logger` agent is pinned to Claude Haiku and handles all file I/O (read, append-or-create, write). The main model compresses the conversation into a concise context block and passes it over — the actual writing never inflates the main context window.

**Why append to a daily file instead of one file per session?**
A single file per day makes it easy to review everything you worked on in one place, without navigating dozens of timestamped files. Sessions within a day are separated by `---` and a `## Session — HH:MM` header.

**Why skill-based, not a Stop hook?**
A `Stop` hook fires after every AI turn — far too noisy for session summaries. A user-invoked skill fires exactly when you mean it to: at the end of a focused work block.
