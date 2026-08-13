# shellcheck shell=bash
#
# lib/db.sh — guild v5 driver layer (design doc §2.1, §2.2, §2.4).
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` — scripts/guild owns those.
# Sourced by scripts/guild; every other lib module depends on this one.
#
# Bash 3.2 compatible: no associative arrays, no `declare -A`, no `mapfile`,
# no `${var^^}`, no `readarray`, no process substitution in hot paths.
#
# Globals established by db_load_config():
#   GUILD_DIR            guild root (env override, default ./.guild)
#   GUILD_DB_MODE        local | cloud
#   GUILD_DB_PATH        $GUILD_DIR/guild.db   (local mode)
#   GUILD_DB_URL_ENV     NAME of the env var holding the cloud URL
#   GUILD_DB_TOKEN_ENV   NAME of the env var holding the cloud auth token
#   GUILD_CONFIG_LOADED  memo flag; db_load_config is a no-op once set
#
# config.yaml stores env var NAMES, never secret values (§2.1). That is enforced, not
# just documented: db_is_env_name() rejects anything that is not an identifier, at the
# flag-parsing boundary (lib/init.sh) AND when reading the file back here. A value that
# fails the check is NEVER echoed — the whole point is that it might be a token.
#
# ROUND-TRIP RULE (§2.2): one db_exec per LOGICAL COMMAND. Compose one SQL script; do
# not loop calling db_exec, because in cloud mode every invocation is a network round
# trip. What the rule forbids is a trip count that GROWS WITH THE DATA — one db_exec per
# row, per file, per journal line.
#
# THERE IS EXACTLY ONE EXCEPTION, and it is about SIZE, not about rows. journal_rebuild
# (lib/journal.sh) replays a journal that can be thousands of statements and tens of
# megabytes; handing that to the engine as a single script is not something any engine
# should be asked to do. So it compiles the journal to numbered chunk files — a chunk
# closes at a statement or byte budget — and applies each chunk with one db_exec. The
# loop is bounded by total SIZE and each trip carries thousands of rows, which is the
# opposite of the per-row chatter the rule exists to prevent. Nothing else in the CLI
# may loop, and a new caller wanting to must justify itself the same way.
#
# CLOUD MODE IS GATED AS UNVERIFIED (see db_refuse_cloud_mode below). The driver code
# is intact; the entrance — `guild init --mode cloud` — refuses.

# ---- errors ----------------------------------------------------------------------

# die <msg...> — print to stderr, exit 1. Callers supply the full wording, including
# the `guild: ` prefix, so v4's exact error strings can be reproduced verbatim.
die() {
  printf '%s\n' "$*" >&2
  exit 1
}

# ---- paths -----------------------------------------------------------------------

# guild_root — resolve the guild root: $GUILD_DIR if set, else ./.guild. Sets the
# global as a side effect AND echoes it, so both `guild_root` and `$(guild_root)`
# are usable.
guild_root() {
  GUILD_DIR="${GUILD_DIR:-.guild}"
  printf '%s\n' "$GUILD_DIR"
}

# db_config_path — echo the path to config.yaml.
db_config_path() {
  guild_root >/dev/null
  printf '%s\n' "$GUILD_DIR/config.yaml"
}

# db_path — echo the local database file. Meaningful in local mode; in cloud mode the
# board lives at the URL named by $GUILD_DB_URL_ENV and this path is unused. The one
# accessor for it, so no other module has to know the filename.
db_path() {
  db_load_config
  printf '%s\n' "$GUILD_DB_PATH"
}

# db_now — UTC timestamp in the schema's TEXT format. Computed in the shell rather
# than SQL so no engine datetime-function support is assumed.
db_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# ---- config ----------------------------------------------------------------------

# _db_cfg_get <key> <file> — read a `key: value` line from the fixed tiny YAML shape
# below, at any indentation, stripping trailing `# comments` and surrounding quotes.
# Empty string if absent. awk only; no YAML dependency.
#
#   version: 5
#   db:
#     mode: local            # local | cloud
#     url_env: TURSO_DATABASE_URL
#     token_env: TURSO_AUTH_TOKEN
_db_cfg_get() {
  awk -v k="$1" '
    BEGIN { trim = "[ \t\"" sprintf("%c", 39) "]+" }
    {
      line = $0
      sub(/#.*$/, "", line)
      if (match(line, "^[ \t]*" k "[ \t]*:")) {
        v = substr(line, RSTART + RLENGTH)
        sub("^" trim, "", v)
        sub(trim "$", "", v)
        print v
        exit
      }
    }
  ' "$2"
}

# db_is_env_name <s> — is <s> a plausible environment variable NAME, i.e. does it match
# ^[A-Za-z_][A-Za-z0-9_]*$ ? Nothing else may be stored in config.yaml's url_env /
# token_env: a URL contains `://`, a token contains `.` or `-`, and both would be
# written verbatim into a file that is committed to git.
#
# `case` rather than a regex so this stays bash 3.2 clean, and so the value never has
# to be passed to an external command that might log it.
db_is_env_name() {
  local s="${1-}"
  [ -n "$s" ] || return 1
  case "$s" in
    [!A-Za-z_]*) return 1 ;;
  esac
  case "$s" in
    *[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

# _db_cfg_require_env_name <key> <value> <file> — die unless <value> is an env var name.
#
# The message NEVER contains the value. If the check fails, the likeliest explanation is
# that someone ran `--token-env "$TURSO_AUTH_TOKEN"` and the file now holds a live
# credential; printing it here would copy it into stderr and into every agent transcript.
_db_cfg_require_env_name() {
  db_is_env_name "$2" && return 0
  die "guild: $3 has a db.$1 that is not an environment variable NAME.

config.yaml is committed to git and stores the NAME of the variable holding the
credential, never the credential itself (design 2.1). The stored value is not printed
here, because it may be a live token.

Edit $3 so it reads, for example:

  db:
    mode: cloud
    url_env: TURSO_DATABASE_URL
    token_env: TURSO_AUTH_TOKEN

and if it did hold a real token, rotate it — it is in your git history."
}

# db_refuse_cloud_mode — cloud mode is NOT yet verified and must not be entered.
#
# `turso db shell` is passed no machine-readable output flag (db_exec below), while every
# parser in the CLI assumes the pipe-separated `-m list` shape that local mode produces:
# `[ "$out" = "E" ]`, `'OK|'*`, `awk -F'|'`, `index($0,"|")`. `turso db shell` renders a
# bordered table with a header row instead, so every read would silently report "not
# found" and every write would be journaled as if it had landed. Nobody has a Turso Cloud
# account to test against, so this is gated rather than guessed at.
#
# The driver code path stays in place. This is the entrance, and only the entrance.
db_refuse_cloud_mode() {
  die "guild: cloud mode is not yet verified, so 'guild init --mode cloud' will not run it.

The cloud driver shells out to 'turso db shell', which has no machine-readable output
flag; every parser in this CLI expects the pipe-separated rows that local mode's
'tursodb -q -m list' produces. Initializing a cloud board would give you a guild whose
reads all come back empty and whose writes look like they succeeded.

Use local mode, which is the default and is fully verified:

  guild init

The board then lives in .guild/guild.db, and .guild/journal.ndjson (committed to git)
is what rebuilds it anywhere — 'guild rebuild'. Nothing was written."
}

# db_load_config — establish the globals above. Memoized: safe to call from every
# entry point. Tolerates a missing config.yaml (defaults to local mode) so that
# `guild init` can run before one exists; use db_require_init to demand a real guild.
db_load_config() {
  local cfg mode url_env token_env

  guild_root >/dev/null
  [ -z "${GUILD_CONFIG_LOADED:-}" ] || return 0

  cfg="$GUILD_DIR/config.yaml"
  mode=""
  url_env=""
  token_env=""

  if [ -f "$cfg" ]; then
    mode="$(_db_cfg_get mode "$cfg")"
    url_env="$(_db_cfg_get url_env "$cfg")"
    token_env="$(_db_cfg_get token_env "$cfg")"
    # A config written before these names were validated (or hand-edited since) can
    # hold a URL or a token here. Refuse to load it, and do not echo what it holds.
    [ -z "$url_env" ]   || _db_cfg_require_env_name url_env "$url_env" "$cfg"
    [ -z "$token_env" ] || _db_cfg_require_env_name token_env "$token_env" "$cfg"
  fi

  GUILD_DB_MODE="${mode:-local}"
  GUILD_DB_URL_ENV="${url_env:-TURSO_DATABASE_URL}"
  GUILD_DB_TOKEN_ENV="${token_env:-TURSO_AUTH_TOKEN}"
  GUILD_DB_PATH="$GUILD_DIR/guild.db"

  case "$GUILD_DB_MODE" in
    local|cloud) ;;
    *) die "guild: invalid db mode '$GUILD_DB_MODE' in $cfg (expected local|cloud)" ;;
  esac

  GUILD_CONFIG_LOADED=1
}

# db_set_config <mode> <url_env> <token_env> — establish the driver globals directly,
# bypassing config.yaml, and mark the config loaded.
#
# `guild init` is the one caller: it must check for the binary belonging to the mode it
# is ABOUT TO WRITE, before that file exists. It used to reach in and assign these
# globals itself, which meant lib/init.sh owned four of this module's internals; this
# is the same operation with the ownership the right way round.
db_set_config() {
  local mode="${1-}"
  case "$mode" in
    local|cloud) ;;
    *) die "guild: invalid db mode '$mode' (expected local|cloud)" ;;
  esac
  guild_root >/dev/null
  # Same rule as the file: NAMES only, and a rejected value is never echoed.
  if [ -n "${2-}" ] && ! db_is_env_name "$2"; then
    die "guild: the database URL environment variable NAME is not an identifier.
config.yaml stores the NAME of the variable, never its value (design 2.1). The value
is not printed here because it may be a credential."
  fi
  if [ -n "${3-}" ] && ! db_is_env_name "$3"; then
    die "guild: the auth token environment variable NAME is not an identifier.
config.yaml stores the NAME of the variable, never its value (design 2.1). The value
is not printed here because it may be a credential."
  fi
  GUILD_DB_MODE="$mode"
  GUILD_DB_URL_ENV="${2:-TURSO_DATABASE_URL}"
  GUILD_DB_TOKEN_ENV="${3:-TURSO_AUTH_TOKEN}"
  GUILD_DB_PATH="$GUILD_DIR/guild.db"
  GUILD_CONFIG_LOADED=1
}

# db_require_init — die unless this directory holds an initialized v5 guild.
db_require_init() {
  db_load_config
  [ -f "$GUILD_DIR/config.yaml" ] ||
    die "guild: no guild found at $GUILD_DIR (run 'guild init')"
  if [ "$GUILD_DB_MODE" = "local" ] && [ ! -f "$GUILD_DB_PATH" ]; then
    die "guild: database not found at $GUILD_DB_PATH (run 'guild init')"
  fi
}

# ---- binaries --------------------------------------------------------------------

# db_require_binary — the two modes need two DIFFERENT binaries (§2.2). Die with the
# exact install line for the current mode. This is the function that guarantees a raw
# "command not found" never reaches the user.
db_require_binary() {
  db_load_config
  case "$GUILD_DB_MODE" in
    local)
      command -v tursodb >/dev/null 2>&1 || die "guild: 'tursodb' not found — local mode needs the TursoDB engine shell.

Install it with:

  curl --proto '=https' --tlsv1.2 -LsSf \\
    https://github.com/tursodatabase/turso/releases/latest/download/turso_cli-installer.sh | sh

Then re-run this command. (Cloud mode uses a different binary, 'turso'.)"
      ;;
    cloud)
      command -v turso >/dev/null 2>&1 || die "guild: 'turso' not found — cloud mode needs the Turso Cloud CLI.

Install it with:

  brew install tursodatabase/tap/turso

or:

  curl -sSfL https://get.tur.so/install.sh | bash

Then re-run this command. (Local mode uses a different binary, 'tursodb'.)"
      ;;
    *)
      die "guild: invalid db mode '$GUILD_DB_MODE' (expected local|cloud)"
      ;;
  esac
}

# _db_cloud_url — resolve the cloud URL from the env var NAMED in config.yaml.
#
# The die below interpolates the NAME, never the resolved value: $GUILD_DB_URL_ENV has
# passed db_is_env_name at both boundaries (flag parsing and config load), so it cannot
# be a URL carrying `?authToken=`. The resolved URL itself is never printed anywhere.
_db_cloud_url() {
  local v
  v="$(printenv "$GUILD_DB_URL_ENV" 2>/dev/null || true)"
  [ -n "$v" ] ||
    die "guild: \$$GUILD_DB_URL_ENV is not set — cloud mode reads the database URL from that environment variable (named in $GUILD_DIR/config.yaml)"
  printf '%s' "$v"
}

# ---- execution -------------------------------------------------------------------

# db_exec — read a SQL script on stdin, write result rows to stdout. Rows are
# pipe-separated (sqlite "list" mode). ONE invocation per logical command.
#
#   local: tursodb -q -m list .guild/guild.db
#   cloud: turso db shell "$TURSO_DATABASE_URL"
#
# Local mode gets a `PRAGMA foreign_keys = ON;` preamble because that pragma is
# per-connection and every CLI invocation is a fresh connection. The set form of a
# boolean pragma returns no rows, so it cannot pollute stdout. `busy_timeout` is
# deliberately NOT in the preamble: its set form DOES return a row in SQLite, which
# would corrupt the first line of every result set. The spool (§2.4) already
# guarantees a single writer, so busy_timeout is belt-and-braces we can do without.
#
# TWO KNOWN DIFFERENCES BETWEEN THE MODES — both reasons cloud mode is gated as
# unverified at the entrance (db_refuse_cloud_mode):
#
#   1. FK ENFORCEMENT DIFFERS. The `PRAGMA foreign_keys = ON;` preamble is prepended in
#      the LOCAL branch only. The cloud branch sends the caller's script as-is, so
#      whatever `turso db shell` defaults to is what applies — a work_log row naming a
#      task that does not exist is rejected locally and may be accepted in the cloud.
#      spool_drain's "the file is unlinked only after the SQL succeeds" guarantee is
#      built on that rejection.
#   2. OUTPUT SHAPE DIFFERS. Local gets `-m list` (pipe-separated, no header); cloud is
#      passed no format flag at all and renders a bordered table. Every parser in this
#      CLI assumes the former.
#
# The cloud branch also passes the URL in argv, which is world-readable in `ps` on
# Linux, and libsql URLs commonly embed `?authToken=`. The token itself is correctly
# passed through the environment. Fix that before ungating cloud mode.
db_exec() {
  local url token
  db_load_config
  db_require_binary
  case "$GUILD_DB_MODE" in
    local)
      { printf 'PRAGMA foreign_keys = ON;\n'; cat; } | tursodb -q -m list "$GUILD_DB_PATH"
      ;;
    cloud)
      # Reachable only from a hand-written config.yaml — `guild init --mode cloud`
      # refuses. Say so rather than returning quietly wrong answers.
      printf 'guild: WARNING — cloud mode is unverified; its output shape is not the one this CLI parses.\n' >&2
      printf 'guild: reads may come back empty and writes may be journaled as if they landed.\n' >&2
      url="$(_db_cloud_url)"
      token="$(printenv "$GUILD_DB_TOKEN_ENV" 2>/dev/null || true)"
      if [ -n "$token" ]; then
        TURSO_AUTH_TOKEN="$token" turso db shell "$url"
      else
        turso db shell "$url"
      fi
      ;;
  esac
}

# db_query — identical mechanism to db_exec; a separate name so SELECT call sites read
# as reads. Same hard rule: compose one script, call once.
db_query() {
  db_exec
}

# guild_schema_path — locate scripts/schema.sql. $GUILD_SCHEMA wins; otherwise it sits
# one directory above this file (scripts/schema.sql next to scripts/lib/db.sh).
#
# Lives here, next to db_apply_schema, because two independent callers need it —
# `guild init` (apply the DDL) and `guild rebuild` (build a fresh database before
# replaying the journal). It used to live in lib/init.sh, which meant lib/journal.sh
# reached for a `lib/schema.sh` module that does not exist; the schema is a .sql file,
# not a shell module.
guild_schema_path() {
  local here c
  if [ -n "${GUILD_SCHEMA:-}" ]; then
    [ -f "$GUILD_SCHEMA" ] || die "guild: schema file not found: $GUILD_SCHEMA"
    printf '%s' "$GUILD_SCHEMA"
    return 0
  fi
  here=""
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || here=""
  fi
  for c in \
    "${here:+$here/../schema.sql}" \
    "${here:+$here/schema.sql}" \
    "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/schema.sql}"
  do
    [ -n "$c" ] || continue
    if [ -f "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  die "guild: schema.sql not found (set \$GUILD_SCHEMA to its path)"
}

# db_apply_schema [path] — pipe the schema file through db_exec in a single invocation.
# With no argument it applies the schema guild_schema_path resolves.
#
# Its stdout is captured so a FAILURE can be reported: callers write `db_apply_schema
# >/dev/null`, and tursodb prints its diagnostics to stdout — straight into /dev/null,
# leaving `guild init` to abort with no message at all. Rows the schema does emit are
# re-printed on success, so the redirect still means what it says.
db_apply_schema() {
  local schema="${1-}" out
  [ -n "$schema" ] || schema="$(guild_schema_path)"
  [ -f "$schema" ] || die "guild: schema file not found: $schema"
  db_load_config
  db_require_binary
  if ! out="$(db_exec < "$schema")"; then
    db_fail "could not apply the schema from $schema" "$out"
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

# ---- literals --------------------------------------------------------------------

# THERE ARE TWO ESCAPERS AND THE DISTINCTION IS LOAD-BEARING (§2.2.1).
#
#   sql_str  — identifiers, IDs, enums, dates, timestamps: values from a KNOWN-SAFE
#              alphabet, or values this CLI generated itself. `'...'`, quotes doubled.
#   sql_text — ALL FREE TEXT: titles, bodies, objectives, descriptions, work-log
#              entries, findings, doc bodies, file paths, spool payloads — anything a
#              human or an agent typed. `CAST(x'…' AS TEXT)`.
#
# Free text may NOT go through sql_str. See the comment on sql_text for the mechanism;
# the short version is that a quoted literal containing a line that ENDS in `;` is torn
# in half by tursodb's script splitter, and code fragments do that in ordinary use.
# sql_text is also correct for known-safe values — just more verbose — so when in doubt,
# use sql_text.

# sql_str <value> — render a value as a SQL single-quoted literal, doubling internal
# single quotes. For KNOWN-SAFE alphabets only (see above). Preserves newlines and
# trailing whitespace (pure parameter expansion, no command substitution, which would
# strip trailing newlines).
sql_str() {
  local v="${1-}"
  local q="'"
  v="${v//$q/$q$q}"
  printf '%s' "$q$v$q"
}

# ---- UTF-8 validation, and the hex encoder that carries it (§2.2.1) -----------------
#
# `CAST(x'…' AS TEXT)` is byte-exact ONLY FOR VALID UTF-8, and the two engines disagree
# on everything else. Verified directly on `caf\xe9 \xff\xfe bad`:
#
#   tursodb 0.7.2   636166 EFBFBD 20 EFBFBDEFBFBD 20626164   — U+FFFD substituted
#   sqlite3         636166 E9     20 FFFE         20626164   — bytes preserved
#
# So a latin-1 byte does not fail: it is SILENTLY CORRUPTED, differently per engine, and
# a `guild rebuild` on the other engine then produces a different board. Before the hex
# transport tursodb rejected the whole stream loudly; this section buys that loudness
# back, with a message that says which byte and where.
#
# WHERE THE CHECK LIVES, and why it is not at the flag boundary. The design note suggests
# validating where a flag is parsed, so the error can name `--title`. Free text enters
# this CLI at roughly fifty sites across five modules and most are NOT flags — a doc body
# read off disk, an agent's spool line, a v4 charter table cell, a filename. Only a
# minority could name a flag, so the enforcement point is sql_text: the ONE gate every
# free-text value must pass to reach SQL, which makes the guarantee total rather than
# per-call-site. sql_text takes an OPTIONAL SECOND ARGUMENT naming the value, so a caller
# that does know the flag passes it and gets the better message; the rest get "a text
# value". Callers that MUST NOT die on bad input — the v4 carry-over, the spool drain —
# call utf8_valid / utf8_valid_file first and skip the item instead.
#
# ---------------------------------------------------------------------------------
# WHY NOT iconv, THE OBVIOUS DETECTOR. Two independent reasons, both measured here
# (macOS 15, /usr/bin/iconv, bash 3.2):
#
#   1. `-f UTF-8 -t UTF-8` IS TOO PERMISSIVE. It passes codepoints above U+10FFFF and
#      5-byte sequences straight through — F4 90 80 80, F5 80 80 80 and F8 88 80 80 80
#      all exit 0 — and tursodb replaces every one of those with U+FFFD. `-t UTF-16BE`
#      does reject them, since UTF-16 cannot represent them. So far, so fixable.
#
#   2. IT REPORTS FALSE POSITIVES ON VALID UTF-8, which is disqualifying. With stdout on
#      /dev/null, /usr/bin/iconv fails with `iconv(): Inappropriate ioctl for device`
#      (ENOTTY — a stale errno) on input that Python and the scanner below both accept.
#      Whether it fires depends on where multi-byte sequences fall relative to its
#      internal buffer: padding one valid 20 KB file with N leading ASCII bytes and
#      converting it for N = 0..63, the runs at N = 6, 7, 8, 11, 12, 14, 15, 17 and 18
#      failed and the other 55 succeeded — same bytes, same command, one shifted offset.
#      Redirecting the identical input to a regular file instead of /dev/null succeeds
#      every time. It was found the honest way: `guild new req` with a 400 KB Japanese
#      body started refusing itself.
#
#      A detector that randomly refuses a valid Japanese requirement body is worse than
#      no detector: it turns "the guild refuses bad input" into "the guild sometimes
#      refuses good input", and nobody can tell which one they are looking at.
#
# So the detector is _utf8_hex_stream below — awk, no new dependency, and it costs NO
# EXTRA PROCESS because it replaces the `tr -d '\n'` that _sql_hex already ran. Validating
# and hex-encoding are the same pass. Verified against: valid ASCII, 日本語 🎯, a lone
# continuation byte 0x80, the overlongs C0 AF and E0 80 AF, a truncated sequence at end of
# input, the empty string, latin-1 `café`, a surrogate ED A0 80, F4 90 80 80, F5 80 80 80,
# the 5-byte F8 form, and 0xFF — agreeing with Python's utf-8 codec on every one.
# ---------------------------------------------------------------------------------

# _utf8_alt — build GUILD_UTF8_ALT: the UTF-8 well-formedness alternation, expressed over
# HEX PAIRS. Memoized, and passed to awk with `-v`, so the two scanners below share one
# definition without a fork or a quoting puzzle.
#
# The scan runs on HEX rather than on the bytes themselves so the pattern is pure ASCII:
# awk implementations differ on whether a bracket range may hold a byte >= 0x80, and the
# one-true-awk that ships with macOS is one of the ones that cannot be trusted with it.
# Two hex characters per byte sidesteps the question entirely.
#
# This is RFC 3629's table, which already excludes overlongs (C0/C1 absent, E0 restricted
# to A0-BF, F0 to 90-BF), surrogates (ED restricted to 80-9F) and everything above
# U+10FFFF (F4 restricted to 80-8F, F5-FF absent). It contains no backslash, which matters:
# `awk -v` interprets escape sequences in the value it is given.
_utf8_alt() {
  local c
  # The memo is INTERNAL state, never an inherited knob: a value arriving from the
  # environment would silently widen the UTF-8 gate and reinstate the R3-1 corruption
  # (`GUILD_UTF8_ALT='([0-9a-f][0-9a-f])'` accepts every byte). Build it once per
  # process, from a known-clean start.
  [ -z "${GUILD_UTF8_ALT_BUILT:-}" ] || return 0
  GUILD_UTF8_ALT=""
  GUILD_UTF8_ALT_BUILT=1
  c='[89ab][0-9a-f]'
  GUILD_UTF8_ALT="([0-7][0-9a-f]"
  GUILD_UTF8_ALT="$GUILD_UTF8_ALT|(c[2-9a-f]|d[0-9a-f])$c"
  GUILD_UTF8_ALT="$GUILD_UTF8_ALT|e0(a[0-9a-f]|b[0-9a-f])$c"
  GUILD_UTF8_ALT="$GUILD_UTF8_ALT|e[1-9a-c]$c$c"
  GUILD_UTF8_ALT="$GUILD_UTF8_ALT|ed(8[0-9a-f]|9[0-9a-f])$c"
  GUILD_UTF8_ALT="$GUILD_UTF8_ALT|e[ef]$c$c"
  GUILD_UTF8_ALT="$GUILD_UTF8_ALT|f0(9[0-9a-f]|a[0-9a-f]|b[0-9a-f])$c$c"
  GUILD_UTF8_ALT="$GUILD_UTF8_ALT|f[1-3]$c$c$c"
  GUILD_UTF8_ALT="$GUILD_UTF8_ALT|f48[0-9a-f]$c$c)"
}

# _utf8_hex_stream — read hex records on stdin (`xxd -p` output: 60 characters a line,
# always an even number, so a byte never straddles a line). Write the same hex back as ONE
# line with no trailing newline. Exit 0 if those bytes are well-formed UTF-8, 2 if not.
#
# STREAMING, not "collect it all and match once", because this is on every write path and
# the value can be a whole document. Per record it takes the longest valid prefix of
# `carry + record` — POSIX leftmost-longest makes RLENGTH exactly that — and carries the
# remainder forward. A remainder is a legitimately incomplete sequence only while it is
# shorter than 8 hex characters, since the longest UTF-8 sequence is 4 bytes; a remainder
# that reaches 8 is proof of an invalid byte, and a non-empty remainder at end of input is
# a truncated sequence. Memory stays bounded and the cost is linear.
#
# Measured on a 480 KB value: 0.07 s streaming, against 0.52 s for the same pattern applied
# to the whole hex string in one END block, which is quadratic in the record count.
_utf8_hex_stream() {
  _utf8_alt
  LC_ALL=C awk -v ALT="$GUILD_UTF8_ALT" '
    BEGIN { carry = ""; rc = 0 }
    {
      if (rc) next
      printf "%s", $0
      s = carry $0
      if (match(s, "^" ALT "*")) n = RLENGTH; else n = 0
      carry = substr(s, n + 1)
      if (length(carry) >= 8) rc = 2
    }
    END {
      if (rc == 0 && carry != "") rc = 2
      exit rc
    }
  '
}

# _utf8_hex_where — read hex on stdin; print `<byte-offset> <HEXBYTE>` for the first
# invalid byte. FAILURE PATH ONLY, so it may buffer: naming the byte is worth one
# non-streaming pass over input already known to be bad. RLENGTH of the `^ALT*` match is
# the length of the valid PREFIX, so the offset is exact and costs no second scan.
_utf8_hex_where() {
  _utf8_alt
  LC_ALL=C awk -v ALT="$GUILD_UTF8_ALT" '
    { s = s $0 }
    END {
      if (s == "") exit 0
      if (s ~ ("^" ALT "*$")) exit 0
      if (match(s, "^" ALT "*")) n = RLENGTH; else n = 0
      printf "%d %s\n", n / 2, toupper(substr(s, n + 1, 2))
      exit 2
    }
  '
}

# _sql_hex — read stdin, write its bytes as one line of lowercase hex, no newline.
# EXIT 2 IF THOSE BYTES ARE NOT VALID UTF-8 (see the section header); exit 1 if there is
# no hex tool at all.
#
# `xxd -p` where available (present on macOS and every Linux with vim-common), else
# `od -An -v -tx1`. The `-v` is not optional: without it od collapses repeated lines into
# `*` and the encoding silently loses data. No new dependency either way, and no
# python/jq/node (§ "no deps beyond turso binaries + coreutils").
#
# The partial hex written before an invalid byte is NOT a hazard: every caller checks the
# status, and _utf8_hex_where is deliberately fed this truncated stream, because the first
# invalid byte is inside the part that was written.
_sql_hex() {
  if command -v xxd >/dev/null 2>&1; then
    LC_ALL=C xxd -p | _utf8_hex_stream
  elif command -v od >/dev/null 2>&1; then
    LC_ALL=C od -An -v -tx1 | LC_ALL=C tr -d ' \n' | _utf8_hex_stream
  else
    return 1
  fi
}

# utf8_valid <value> — 0 if the value is well-formed UTF-8, non-zero otherwise. Silent.
# The empty string is valid. Costs exactly what hex-encoding the value costs and nothing
# more, because it IS the hex encoder with its output thrown away.
utf8_valid() {
  [ -n "${1-}" ] || return 0
  printf '%s' "$1" | _sql_hex >/dev/null 2>&1
}

# utf8_valid_file <path> — the same question about a whole FILE, without reading it into a
# shell variable. A missing file is not an error here; callers test existence first.
#
# Worth its own function because of what it saves: a file that is valid UTF-8 has valid
# UTF-8 on EVERY line, since lines split on 0x0A and 0x0A never occurs inside a multi-byte
# sequence. So one call clears a whole spool or a whole doc, and the per-line or per-row
# check is only ever paid on a file that already failed.
utf8_valid_file() {
  [ -f "${1-}" ] || return 0
  _sql_hex <"$1" >/dev/null 2>&1
}

# utf8_require <label> <value> — die unless <value> is valid UTF-8. <label> names the value
# in the message ("--title", "the DATE argument"); empty falls back to "a text value".
#
# Both scans here run ONLY on the failure path — sql_text calls this after its own encode
# has already failed — so naming the byte costs nothing in the normal case.
utf8_require() {
  local label="${1-}" v="${2-}" at off byte
  [ -n "$v" ] || return 0
  utf8_valid "$v" && return 0
  [ -n "$label" ] || label='a text value'

  at="$(printf '%s' "$v" | _sql_hex 2>/dev/null | _utf8_hex_where)" || true
  off=""
  byte=""
  case "$at" in
    [0-9]*' '*)
      off="${at%% *}"
      byte="${at##* }"
      ;;
  esac

  if [ -n "$byte" ]; then
    die "guild: $label is not valid UTF-8 (invalid byte 0x$byte at offset $off).
       The guild stores text as UTF-8; re-encode with 'iconv -f latin1 -t utf8'.

       It is refused rather than stored because it would not survive the trip: free text
       reaches SQL as bytes cast to TEXT, and on an invalid byte tursodb substitutes
       U+FFFD while sqlite3 keeps the byte — so the value would be corrupted silently,
       and differently depending on which engine replayed the journal (design 2.2.1)."
  fi
  die "guild: $label is not valid UTF-8.
       The guild stores text as UTF-8; re-encode with 'iconv -f latin1 -t utf8'.
       An invalid byte would be silently corrupted on the way into the board (design 2.2.1)."
}

# sql_text <value> [label] — render FREE TEXT as `CAST(x'<hex>' AS TEXT)` (§2.2.1).
#
# [label] names the value if it has to be refused for not being UTF-8 — pass the flag
# ("--title") wherever the call site knows it. See the UTF-8 section above for why the
# check lives here rather than at every flag.
#
# WHY NOT A QUOTED LITERAL. tursodb's stdin script splitter ends a statement at a `;`
# that terminates a line, EVEN INSIDE AN OPEN STRING LITERAL:
#
#   INSERT INTO t VALUES('code:
#       const x = 1;        <- the splitter ends the statement HERE
#       doThing();
#   done');
#   → × non-terminated literal
#
# An INLINE semicolon ('has; semicolon') is harmless; it is specifically a `;` at
# end-of-line. Requirement bodies, plan slices and task objectives routinely carry code,
# so this fires in ORDINARY use — and it fired silently, because tursodb writes the parse
# error to STDOUT where callers capture it as data (hence db_fail, below).
#
# Hex is unambiguous and, critically, ALWAYS SINGLE-LINE, so the splitter cannot tear it
# and there is no escaping left to get wrong. Verified byte-exact for multi-line code with
# trailing semicolons and for `日本語 🎯 a|b it's "q" \ back;`.
#
# EMPTY VALUE → `''`, not `CAST(x'' AS TEXT)`. Both yield a zero-length TEXT (verified on
# tursodb 0.7.2: typeof 'text', length 0, `= ''` true), but `''` is what a reader expects
# and it keeps `NULLIF(x,'')` call sites obvious.
# ONE PASS DOES BOTH JOBS. _sql_hex validates while it encodes and exits 2 on a value that
# is not UTF-8, so the happy path costs exactly what it cost before the check existed —
# there is no separate validation pipeline. utf8_require is called only to DIE WELL: it
# re-scans the bad value to name the byte and the offset, which is affordable precisely
# because it is the last thing this process does.
sql_text() {
  local v="${1-}" hex rc
  [ -n "$v" ] || { printf "''"; return 0; }
  rc=0
  hex="$(printf '%s' "$v" | _sql_hex)" || rc=$?
  if [ "$rc" = 2 ]; then
    utf8_require "${2-}" "$v"
    # utf8_require always dies on a value _sql_hex rejected; belt and braces if it ever
    # disagreed, because falling through would store the truncated prefix.
    die "guild: ${2:-a text value} is not valid UTF-8 and was not stored (design 2.2.1)."
  fi
  case "$hex" in
    '' | *[!0-9a-fA-F]*)
      die "guild: could not hex-encode a text value for SQL — neither 'xxd' nor 'od' produced usable output.
Both ship with macOS and with coreutils/vim-common on Linux; one of them must be on PATH."
      ;;
  esac
  printf "CAST(x'%s' AS TEXT)" "$hex"
}

# ---- driver failures ---------------------------------------------------------------

# db_fail <what> [captured-output...] — a SQL command failed; say why and exit 1.
#
# tursodb writes its diagnostics to STDOUT, which every call site here captures as DATA
# (`out="$(... | db_exec)"`, or a redirect into a temp file). Dropping that buffer on the
# failure path is what made §2.2.1's torn-statement bug invisible for two rounds: `guild
# new req` exited 1 with an empty stdout AND an empty stderr, so an agent could not tell a
# rejection from a crash. Every command that runs SQL routes its failure through here.
# A silent failure is worse than a crash.
db_fail() {
  local what="${1-}"
  shift
  local out
  for out in "$@"; do
    if [ -n "$out" ]; then
      printf 'guild: the database reported:\n%s\n' "$out" >&2
    fi
  done
  die "guild: $what"
}

# json_escape <value> — escape a value for embedding inside a JSON string. Prints the
# escaped text WITHOUT surrounding quotes.
#
# Escapes: backslash, double quote, backspace, formfeed, newline, carriage return,
# tab, and every remaining control character as \u00XX (plus DEL, harmlessly). Bytes
# >= 0x80 pass through untouched, so UTF-8 survives intact — JSON permits raw UTF-8.
#
# Implementation notes, both deliberate:
#   * LC_ALL=C — byte semantics, so awk never chokes on an invalid multibyte sequence.
#   * Escapes are applied by CONCATENATION through a lookup table, never by gsub()
#     replacement text. A gsub replacement treats backslash specially and POSIX leaves
#     sequences like "\t" undefined there; concatenation has no such semantics.
#   * An 'X' sentinel is appended before the pipe and stripped from the last record,
#     because awk's record splitting silently drops one trailing newline.
#
# This is the ONE JSON escaper in the CLI. It lives here rather than in lib/journal.sh
# because two subsystems need it — the journal (row states) and the spool (agent log
# and finding lines) — and a second, weaker copy in the driver was the original shape.
json_escape() {
  printf '%sX' "${1-}" | LC_ALL=C awk '
    BEGIN {
      RS = "\n"
      map["\\"] = "\\\\"
      map["\""] = "\\\""
      map["\b"] = "\\b"
      map["\f"] = "\\f"
      map["\n"] = "\\n"
      map["\r"] = "\\r"
      map["\t"] = "\\t"
      for (i = 1; i < 32; i++) {
        c = sprintf("%c", i)
        if (!(c in map)) map[c] = sprintf("\\u%04x", i)
      }
      map[sprintf("%c", 127)] = "\\u007f"
      have = 0
    }
    function esc(s,   out, c) {
      out = ""
      while (match(s, /[[:cntrl:]"\\]/)) {
        c = substr(s, RSTART, 1)
        out = out substr(s, 1, RSTART - 1) ((c in map) ? map[c] : "")
        s = substr(s, RSTART + 1)
      }
      return out s
    }
    { if (have) printf "%s\\n", esc(prev); prev = $0; have = 1 }
    END {
      if (!have) exit
      sub(/X$/, "", prev)
      printf "%s", esc(prev)
    }
  '
}

# json_str <value> — json_escape, wrapped in double quotes. Used to build the spool
# lines that spool_append takes, so agent-supplied text with quotes, backslashes or
# control characters cannot break the NDJSON.
json_str() {
  printf '"%s"' "$(json_escape "${1-}")"
}

# ---- spool (§2.4) ----------------------------------------------------------------
#
# Agents never write to the database. `guild log` and `guild finding` append one NDJSON
# line to .guild/spool/<TASK-ID>.ndjson — a plain filesystem append with no
# cross-process contention. The orchestrator drains spools as the single writer.
#
#   {"ts":"...","kind":"log","agent":"developer","entry":"Implemented token refresh"}
#   {"ts":"...","kind":"finding","reviewer":"reviewer-security","severity":"major",
#    "summary":"...","detail":"...","file":"src/a.ts","line":42}

# spool_dir — echo the spool directory path.
spool_dir() {
  guild_root >/dev/null
  printf '%s\n' "$GUILD_DIR/spool"
}

# _spool_check_id <ID> — reject anything that is not a bare PREFIX-NNN id, since the id
# becomes a filename.
_spool_check_id() {
  local id="${1-}"
  case "$id" in
    ''|*/*|*\\*|.*|*' '*) die "guild: invalid id '$id'" ;;
  esac
  case "$id" in
    [A-Za-z]*-[0-9]*) ;;
    *) die "guild: invalid id '$id'" ;;
  esac
}

# spool_path <TASK-ID> — echo the spool file path for a task.
spool_path() {
  local id="${1-}"
  _spool_check_id "$id"
  printf '%s\n' "$(spool_dir)/$id.ndjson"
}

# spool_append <TASK-ID> <json-line> — append one NDJSON entry. Embedded newlines are
# folded to spaces so one entry is always exactly one line; callers should build the
# line with json_str, which escapes them properly in the first place.
spool_append() {
  local id="${1-}" line="${2-}" dir path
  _spool_check_id "$id"
  [ -n "$line" ] || die "guild: spool_append requires a JSON line"
  line="${line//$'\r'/ }"
  line="${line//$'\n'/ }"
  dir="$(spool_dir)"
  mkdir -p "$dir" || die "guild: cannot create spool directory $dir"
  path="$dir/$id.ndjson"
  printf '%s\n' "$line" >> "$path" || die "guild: cannot write spool file $path"
}

# _spool_sql <TASK-ID> <spool-path> — emit ONE SQL script folding every spool entry into
# work_log / review_finding.
#
# Field extraction is done by the engine's JSON functions rather than by parsing JSON in
# awk: the whole line goes in as a single SQL literal and json_extract picks it apart, so
# quoting is handled once, by sql_text. The line is agent-authored free text (an entry, a
# finding's detail), so it is hex — even though spool_append guarantees one physical line,
# which would already survive the splitter (§2.2.1). Cheap, and it cannot regress.
#
# The `CASE WHEN json_valid(x) THEN x END` wrapper is not decoration. json_extract() raises
# "malformed JSON" on a torn line (a crash mid-append), and a raised error means the drain
# never succeeds, which means the spool is never unlinked, which means that task's log is
# stuck on disk forever. Verified against sqlite3: a bare `WHERE json_valid(j) AND ...` does
# not reliably protect, because the subquery flattens and json_extract is still evaluated;
# the CASE turns an unparseable line into a NULL, and json_extract(NULL, path) is NULL
# rather than an error. Bad lines are therefore skipped and the rest of the drain lands.
#
# Every text extraction is CAST(... AS TEXT) and line is CAST(... AS INTEGER) because the
# target tables are STRICT and json_extract returns the JSON value's own type.
#
# NOTHING IS DROPPED SILENTLY. Four kinds of line import nowhere: one that is not shaped
# `{...}`, one that is not valid UTF-8, one that is not valid JSON (a crash mid-append),
# and one whose `kind` is neither "log" nor "finding". Each emits `UNKNOWN|<line-number>`
# on stdout — the first two from the shell, the other two from a SELECT the engine
# evaluates alongside the inserts, so the accounting costs no extra round trip.
# spool_drain quarantines exactly those lines before it unlinks the spool.
#
# THE UTF-8 CHECK IS A SKIP, NOT A DEATH, and that is deliberate. sql_text refuses a
# value that is not UTF-8 (§2.2.1), and letting that refusal fire here would abort the
# drain — which keeps the spool on disk, which means every later drain hits the same bad
# line and that task's work log is stuck forever. Quarantining is the same treatment a
# torn JSON line already gets, for the same reason.
#
# It costs ONE scan of the whole file in the normal case: a file that is valid UTF-8
# has valid UTF-8 on every line, because lines split on 0x0A and 0x0A cannot occur inside
# a multi-byte sequence. Only a file that already failed pays the per-line check.
#
# The marker carries a LINE NUMBER, never the line's text: `-m list` output is
# pipe-separated and agent-supplied text contains pipes and newlines, so a value echoed
# into this channel could impersonate a marker. An integer cannot.
#
# A wholly EMPTY line is the one thing skipped without a report, because it carries no
# entry to lose — a stray newline is not an agent's work log.
_spool_sql() {
  local id="$1" path="$2" tid now line lit ln perline
  # The task id arrives as argv and _spool_check_id only checks its shape, so it is free
  # text; the timestamp is generated here, so it is not. One encode per DRAIN, not per line.
  tid="$(sql_text "$id" 'the task id')"
  now="$(sql_str "$(db_now)")"
  ln=0

  # One scan clears the whole file; the per-line check below is only armed if it fails.
  perline=0
  utf8_valid_file "$path" || perline=1

  printf 'BEGIN;\n'
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    case "$line" in
      '{'*'}') ;;
      '') continue ;;
      *) printf "SELECT 'UNKNOWN|%s';\n" "$ln"; continue ;;
    esac
    if [ "$perline" = 1 ] && ! utf8_valid "$line"; then
      printf "SELECT 'UNKNOWN|%s';\n" "$ln"
      continue
    fi
    lit="$(sql_text "$line")"
    cat <<SQL
INSERT INTO work_log (task_id, ts, agent, entry)
SELECT $tid,
       COALESCE(CAST(json_extract(j, '\$.ts') AS TEXT), $now),
       COALESCE(CAST(json_extract(j, '\$.agent') AS TEXT), ''),
       COALESCE(CAST(json_extract(j, '\$.entry') AS TEXT), '')
FROM (SELECT CASE WHEN json_valid(x) THEN x END AS j FROM (SELECT $lit AS x))
WHERE json_extract(j, '\$.kind') = 'log';
INSERT INTO review_finding
  (task_id, reviewer, severity, summary, detail, file, line, disposition, created_at)
SELECT $tid,
       COALESCE(CAST(json_extract(j, '\$.reviewer') AS TEXT), ''),
       COALESCE(CAST(json_extract(j, '\$.severity') AS TEXT), 'minor'),
       COALESCE(CAST(json_extract(j, '\$.summary') AS TEXT), ''),
       COALESCE(CAST(json_extract(j, '\$.detail') AS TEXT), ''),
       CAST(json_extract(j, '\$.file') AS TEXT),
       CAST(json_extract(j, '\$.line') AS INTEGER),
       'open',
       COALESCE(CAST(json_extract(j, '\$.ts') AS TEXT), $now)
FROM (SELECT CASE WHEN json_valid(x) THEN x END AS j FROM (SELECT $lit AS x))
WHERE json_extract(j, '\$.kind') = 'finding';
SELECT 'UNKNOWN|$ln'
FROM (SELECT CASE WHEN json_valid(x) THEN x END AS j FROM (SELECT $lit AS x))
WHERE j IS NULL OR COALESCE(CAST(json_extract(j, '\$.kind') AS TEXT), '') NOT IN ('log', 'finding');
SQL
  done < "$path"
  printf 'COMMIT;\n'
}

# spool_drain <TASK-ID> — fold a task's spool into the database, then remove the spool
# file. Silent on success; a task with no spool is a no-op.
#
# ORDERING IS LOAD-BEARING: the file is unlinked only AFTER the SQL succeeds, so a crash
# mid-drain leaves the spool on disk and the next drain re-runs it. That direction — a
# possible replay rather than possible loss — is the one the design asks for (§2.4).
#
# The replay is NOT exactly-once, and the BEGIN/COMMIT wrapper does not make it so. Measured
# against sqlite3: the shell does not abort a script on a statement error, so the statements
# that succeeded before a failing one are still inside the transaction when COMMIT runs and
# are committed. BEGIN/COMMIT is here for the fsync win on a multi-entry drain, not for
# atomicity. So a drain that fails on a real database error (an unknown task_id violating the
# work_log FK, a full disk) may double-post the entries that succeeded when it is retried.
# Duplicated log lines beat lost ones, which is the trade §2.4 chose. Malformed spool lines,
# the one failure that would otherwise wedge a spool permanently, are handled in _spool_sql
# instead and never reach this path.
#
# NOTHING IS DROPPED SILENTLY. _spool_sql reports every line that imported nowhere as
# `UNKNOWN|<line-number>`; those exact lines are COPIED VERBATIM into
# .guild/spool/rejected/<TASK-ID>.ndjson and named on stderr BEFORE the spool is
# unlinked. An entry is therefore either in the database or in the rejects file — never
# neither. The copy is appended, never truncated, so two drains in the same second
# cannot overwrite each other, and a failure to write it aborts the unlink.
#
# The exit status of the driver is what makes the unlink safe. Verified against tursodb
# 0.7.2: a statement error prints `Error: Runtime error: ...` and exits 1, even though
# later statements in the same script still run. So a real database failure keeps the
# spool on disk, as §2.4 requires.
spool_drain() {
  local id="${1-}" path out line bad n word qdir qpath
  _spool_check_id "$id"
  db_load_config
  path="$(spool_path "$id")"
  [ -f "$path" ] || return 0
  if [ ! -s "$path" ]; then
    rm -f "$path"
    return 0
  fi
  db_require_binary
  if ! out="$(_spool_sql "$id" "$path" | db_exec)"; then
    db_fail "spool drain failed for $id — spool kept at $path" "$out"
  fi

  bad="|"
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'UNKNOWN|'[0-9]*)
        bad="$bad${line#UNKNOWN|}|"
        n=$((n + 1))
        ;;
    esac
  done <<UNIMPORTED
$out
UNIMPORTED

  if [ "$n" -gt 0 ]; then
    qdir="$(spool_dir)/rejected"
    mkdir -p "$qdir" || die "guild: cannot create $qdir — spool kept at $path"
    qpath="$qdir/$id.ndjson"
    LC_ALL=C awk -v want="$bad" 'index(want, "|" FNR "|") > 0' "$path" >>"$qpath" ||
      die "guild: could not quarantine unimported spool entries — spool kept at $path"
    word='entries'
    if [ "$n" = 1 ]; then word='entry'; fi
    printf 'guild: %s spool %s for %s could not be imported (not JSON, not valid UTF-8, or an unknown kind).\n' \
      "$n" "$word" "$id" >&2
    printf 'guild: kept verbatim at %s — nothing was discarded.\n' "$qpath" >&2
  fi

  rm -f "$path"
}
