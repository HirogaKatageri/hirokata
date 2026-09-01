# Guild state format — what is on disk

The board is a **Turso database** at `.guild/guild.db`. An artifact's status is a **column**;
`last-checkin` is a row in `guild_state`. The "board" is a **view** (`v_board`) rendered on
demand, never a stored artifact — there is no `BOARD.md`, no `state.yaml`, no ticket file and
no status directory.

**There is no guild CLI.** `tursodb` executes SQL, so the guild does not ship a second tool
that does the same thing. Every member reaches the warehouse the same way — load
`guild:warehouse` and write SQL.

```
.guild/
  config.yaml         # committed. version + storage mode; env var NAMES only, never a credential
  guild.db            # gitignored. THE BOARD
  docs/               # evergreen researcher knowledge (the `doc` table is the primary copy)
  qa/                 # evergreen QA artifacts — charter, missions, bug ledger, session logs
  reviews/REQ-NNN.md  # per-requirement review records, appended per round
  dashboard.html      # gitignored. regenerated wholesale by guild:dashboard
  templates/*.yaml    # optional. a project's override of the shipped execution templates
  v4-archive*/        # a v4 board moved aside — never parsed, never deleted
```

`config.yaml` is what says a guild exists here. Minimal form:

```yaml
version: 5
db:
  mode: local
```

`mode: cloud` adds `url_env:` and `token_env:` — the **names** of environment variables, never
their values. The file is committed to git and must never hold a credential.

## The database is the durable board

There is no journal any more. **`event` is the record**, written by triggers on every
meaningful mutation, and it lives in the same database as everything else — so
`guild.db` is not derived state that can be thrown away and rebuilt. It is gitignored because
a binary file is a bad thing to merge, which means the board is **machine-local** unless the
guild is running in cloud mode.

What git carries instead is the human-readable residue: `config.yaml`, `.guild/docs/`,
`.guild/qa/`, `.guild/reviews/`, and the repo's own `CHANGELOG.md`.

## Applying the schema

```bash
export PATH="$HOME/.turso:$PATH"
tursodb .guild/guild.db < "${CLAUDE_PLUGIN_ROOT}/schema.sql"
```

**Idempotent, and it is how a rule change reaches a live board.** Tables are
`CREATE TABLE IF NOT EXISTS` so data survives; views and triggers are dropped and recreated,
so a corrected view or a new trigger lands on the next run. Seed rows are guarded by
`WHERE NOT EXISTS`.

One honest limit: `CREATE TABLE IF NOT EXISTS` sees an existing table and moves on, so
applying the file over a database created by an **earlier** v5 stage lands the views and
triggers but **not** the CHECK constraints. A board that wants them rebuilds.

## Cloud mode

When `config.yaml` says `mode: cloud`, the binary and the target change and nothing else does:

```bash
turso db shell "$(printenv TURSO_DATABASE_URL)"
```

The SQL is the same SQL. Cloud mode has not been verified end to end — treat a cloud board as
unproven, not as broken.
