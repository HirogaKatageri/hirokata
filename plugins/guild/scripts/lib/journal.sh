# shellcheck shell=bash
#
# lib/journal.sh — the durability layer (v5 design §2.3).
#
# The journal is a CHANGE LOG, not a command log: every line records the RESULTING
# ROW STATE of one mutation. Replaying row states is version-proof; replaying
# commands diverges the moment command semantics change between releases.
#
# ---------------------------------------------------------------------------------
# Line format — `.guild/journal.ndjson`, one JSON object per line, append-only:
#
#   {"seq":142,"ts":"2026-08-13T09:14:02Z","actor":"orchestrator","op":"upsert","table":"task","row":{...}}
#
# The five scalar fields always appear FIRST and in THIS ORDER, and `row` is always
# LAST. That is a load-bearing property, and it is now ENFORCED rather than assumed:
# every reader parses the line left to right from that fixed prefix (`jparse` in the
# shared awk library below), so a value can never impersonate a structural token. The
# old readers used `index($0, ",\"row\":")` and a regex for `"op":"..."`, both of which
# a free-text `actor` — or a `row` body — could forge.
#
#   seq    monotonic integer, derived from the last line of the file (never a counter
#          file — a counter can desync from the journal it counts).
#   ts     ISO-8601 UTC, second resolution.
#   actor  'orchestrator' | agent name | 'user' | 'compact'.  $GUILD_ACTOR overrides.
#   op     'upsert' | 'delete'.
#   table  a bare SQL identifier (validated).
#   row    a JSON object of column -> value for ONE row. For 'delete' it need only
#          carry the primary-key columns.
#
# The canonical way to produce `row` is from the database itself, in the same
# statement that performs the mutation, so column types round-trip exactly:
#
#   db_query <<SQL
#   UPDATE task SET status = $(sql_str "$new") WHERE id = $(sql_text "$id")
#     RETURNING json_object('id',id,'title',title,'status',status, ...);
#   SQL
#
# `journal_row` below is the fallback for hand-built rows, and `journal_capture` is the
# bulk form: pipe it N `json_object(...)` rows and it journals every one of them.
#
# ---------------------------------------------------------------------------------
# DURABILITY GUARANTEES — read these before changing anything here.
#
# Each one below says exactly what it covers and exactly where it stops. Two earlier
# versions of this block stated 1 and 2 unconditionally and a reviewer demonstrated both
# failing; an acknowledged gap is fine, a stated guarantee that does not hold is not.
#
#   1. A mutation is never SILENTLY lost.  Callers write to the database first and
#      journal second, so the window that matters is "committed, not yet journaled".
#      Four mechanisms close it, in order:
#        · journal_preflight — callers invoke it BEFORE the SQL. If the journal is
#          unwritable, if its tail is unreadable (a git merge conflict is the common
#          case), or if it does not end in a newline (a torn append, or a merge that
#          dropped the final byte), the command dies before touching the database and
#          says plainly that nothing was written and how to repair the file.
#        · the advisory lock — taken by journal_preflight and held to process exit, so
#          one command's database write and journal append are one critical section and
#          two agents cannot interleave their appends. See _journal_lock.
#        · journal.pending  — if the append fails anyway, the line is quarantined to
#          `.guild/journal.pending` and the failure is reported LOUDLY. Nothing is
#          lost; the next successful append (or `journal_recover`) folds it back in.
#        · journal_sync     — the append-only record tables (work_log, review_finding,
#          event) are reconciled from the database into the journal on demand, and
#          automatically at the start of `guild rebuild`. The reconciliation compares
#          ROW IDENTITY, not id high-water marks, so it stays exact across a journal
#          merged from another machine (see jident and journal_sync).
#      THIS IS NOT ATOMICITY. There is no two-phase commit between a SQLite file and a
#      text file. What holds is that divergence is prevented, or recorded, or reported.
#      WHERE IT STOPS — three places, all of them narrow and all of them named:
#        · a mutation whose caller neither journals nor writes to a table journal_sync
#          covers is outside every mechanism: this module cannot know about a write it
#          is never told about. `event` is covered, so today the only rows in that
#          category are the schema.sql seeds, which the schema recreates anyway.
#        · a caller that skips journal_preflight gets the post-commit mechanisms only.
#          journal_append still refuses to glue onto an unterminated tail (it quarantines
#          instead), but the refusal then arrives AFTER the database was written.
#        · the lock is ADVISORY and between guild processes. Another program editing
#          journal.ndjson concurrently is not covered by anything here.
#      What is NOT claimed: that the journal is well-formed. It is checked on the way in
#      (preflight, above) and on the way out (guarantee 2, and journal_rebuild refuses a
#      journal with no parseable line and warns loudly about partially unreadable ones) —
#      but a file this parser cannot read is a REFUSAL, not a repair.
#
#   2. Compaction refuses to drop a row the journal describes.  `journal_compact`
#      replaces the one artifact git carries, so before installing a baseline it checks
#      that every (table, identity) pair the existing journal still implies is present
#      in the candidate — and names the ones that are not. It is an IDENTITY comparison,
#      not a row count: counts compare different universes (the database holds seed and
#      `event` rows nothing journals) and hide a real loss inside their slack. It ALSO
#      counts the lines it could not parse and refuses on a non-zero count, because an
#      unreadable line contributes no identity and would otherwise score as "nothing to
#      lose" — which is how an entirely unreadable journal used to be overwritten.
#      WHERE IT STOPS: identities, not contents. A database holding the same rows with
#      DIFFERENT values in them passes this check, because that is indistinguishable
#      from legitimate edits. `--force` overrides it entirely, by design.
#
#   3. The previous journal is always kept, and backups are never overwritten.  Backup
#      directory names are claimed with `mkdir`, which is atomic, and disambiguated with
#      a counter — two rebuilds in the same second cannot have the second one back up
#      the database the first just wrote, over the real one. If the copy of the previous
#      journal into that directory FAILS, compaction aborts rather than proceeding with
#      an empty backup: the claim is a fact, not a message.
#
#   4. `guild rebuild` is local-only.  It refuses outright in cloud mode rather than
#      merging a local journal into a shared database (see journal_rebuild).
#
# ---------------------------------------------------------------------------------
#
# Depends on lib/db.sh: db_exec, db_apply_schema, guild_schema_path, json_escape, die,
#                       db_fail, db_path, GUILD_DIR, GUILD_DB_PATH, GUILD_DB_MODE
#
# There is no lib/schema.sh — the schema is scripts/schema.sql, applied through
# db_apply_schema.
#
# Functions only. No top-level side effects, no `set -e` here (the dispatcher owns it).
# Bash 3.2 compatible: no associative arrays, no mapfile, no ${var^^}.

# ---- paths and small helpers -----------------------------------------------------

# journal_path — the journal file for the current guild root.
journal_path() {
  printf '%s\n' "${GUILD_DIR:-.guild}/journal.ndjson"
}

# journal_pending_path — the quarantine file. Holds journal lines whose append FAILED
# after the database had already been written: the record of a mutation that is in the
# database but not yet in the journal. Lines carry `"seq":0`; journal_recover
# re-sequences them onto the end of the real journal.
#
# It is a repair artifact, not board state — it belongs in .gitignore next to
# `guild.db` (see the report accompanying this module).
journal_pending_path() {
  printf '%s\n' "${GUILD_DIR:-.guild}/journal.pending"
}

# _journal_is_ident <name> — accept only bare SQL identifiers. Table names reach SQL
# as identifiers, where sql_str (a *literal* quoter) cannot protect them; validation
# is the protection. Anything else is a corrupt or hostile journal and must not run.
_journal_is_ident() {
  case "${1-}" in
    "" | *[!A-Za-z0-9_]*) return 1 ;;
    [0-9]*) return 1 ;;
  esac
  return 0
}

# _journal_now — ISO-8601 UTC, second resolution.
_journal_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# _journal_apply_schema — (re)create the schema in the current database. The schema is
# scripts/schema.sql and every statement in it is idempotent, so this is safe to run
# against a fresh file or an existing one.
_journal_apply_schema() {
  db_apply_schema "$(guild_schema_path)" >/dev/null
}

# _journal_backup_dir — create and echo a fresh backup directory under the guild root.
#
# The name is claimed with `mkdir`, which fails if it is taken; on collision a counter
# is appended. Second-resolution timestamps are NOT unique, and `mv` into an existing
# directory silently replaces same-named files — so two rebuilds in the same second
# used to have the second one back up the freshly rebuilt database over the real one,
# destroying the only copy of the pre-rebuild state. `backup-*/` is already gitignored,
# which is also why compaction stages its work in here.
_journal_backup_dir() {
  local root base dir n
  root="${GUILD_DIR:-.guild}"
  mkdir -p "$root" || die "guild: could not create $root"
  base="$root/backup-$(date -u +%Y%m%dT%H%M%SZ)"
  n=0
  while [ "$n" -lt 1000 ]; do
    if [ "$n" = 0 ]; then dir="$base"; else dir="$base.$n"; fi
    if mkdir "$dir" 2>/dev/null; then
      printf '%s\n' "$dir"
      return 0
    fi
    [ -e "$dir" ] || die "guild: could not create a backup directory at $dir"
    n=$((n + 1))
  done
  die "guild: too many backup directories at $base.*"
}

# ---- the shared awk parsing library ----------------------------------------------
#
# Emitted to a file and loaded with `awk -f lib.awk -f program.awk`, because three
# readers need it (rebuild, compact's safety check, sync's high-water mark) and one
# parser is the whole point.
#
# THE OUTPUT-CHANNEL RULE: free text (titles, bodies, work-log entries, an actor name
# out of $GUILD_ACTOR) can contain anything at all, including `,"row":{`, `"op":
# "delete"` and newlines. None of it may ever be able to look like structure. So
# nothing here searches for a marker; everything is parsed positionally from the fixed
# prefix, and a string is skipped by walking its escapes rather than by matching a
# quote. A value that does not sit where the grammar says it sits is not a value.
_journal_awk_lib() {
  cat <<'AWKLIB'
  # jsend(s, i) — index of the closing quote of the JSON string starting at s[i] (which
  # must be `"`), honouring backslash escapes. 0 if the string is unterminated.
  function jsend(s, i,   n, c) {
    if (substr(s, i, 1) != "\"") return 0
    n = length(s)
    i++
    while (i <= n) {
      c = substr(s, i, 1)
      if (c == "\\") { i += 2; continue }
      if (c == "\"") return i
      i++
    }
    return 0
  }

  # jvend(s, i) — index of the LAST byte of the JSON value starting at s[i]. Handles
  # strings, numbers / true / false / null, and nested objects and arrays. 0 if
  # malformed.
  function jvend(s, i,   n, c, depth) {
    n = length(s)
    c = substr(s, i, 1)
    if (c == "\"") return jsend(s, i)
    if (c == "{" || c == "[") {
      depth = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\"") {
          i = jsend(s, i)
          if (!i) return 0
        } else if (c == "{" || c == "[") {
          depth++
        } else if (c == "}" || c == "]") {
          depth--
          if (depth == 0) return i
        }
        i++
      }
      return 0
    }
    while (i <= n) {
      c = substr(s, i, 1)
      if (c == "," || c == "}" || c == "]") return i - 1
      i++
    }
    return n
  }

  # jfield(obj, key) — the RAW value token for `key` in the JSON object `obj`; strings
  # keep their surrounding quotes. "" when the key is absent or the object is
  # unparseable. Raw tokens are only ever compared with other raw tokens, and both sides
  # of every such comparison are produced by json_object(), so the escaping matches.
  function jfield(obj, key,   n, i, e, k, v) {
    n = length(obj)
    if (substr(obj, 1, 1) != "{") return ""
    i = 2
    while (i <= n) {
      if (substr(obj, i, 1) == "}") return ""
      e = jsend(obj, i)
      if (!e) return ""
      k = substr(obj, i + 1, e - i - 1)
      i = e + 1
      if (substr(obj, i, 1) != ":") return ""
      i++
      e = jvend(obj, i)
      if (!e) return ""
      v = substr(obj, i, e - i + 1)
      i = e + 1
      if (k == key) return v
      if (substr(obj, i, 1) == ",") { i++; continue }
      return ""
    }
    return ""
  }

  # jparse(line) — parse one journal line, strictly, left to right. Sets J_seq, J_op,
  # J_table and J_row (the row object WITH its braces). Returns 1 on success, 0 on
  # anything that is not exactly a journal line.
  #
  # LINE-ENDING NORMALIZATION LIVES HERE, AND ONLY HERE. jparse requires the line's last
  # byte to be `}`, so a CR before the newline makes every line unparseable. That is the
  # Git-for-Windows default (`core.autocrlf=true`) and it is what any `* text=auto`
  # produces. It used to be stripped by exactly ONE of the four readers — the replay
  # pass — so `guild rebuild` discovered its tables with a parser that saw nothing and
  # then replayed with a parser that saw everything, decided every table was "not in the
  # current schema", and left an empty board at exit 0. Normalizing inside the shared
  # parser is what makes the four readers agree: there is now one answer to "is this a
  # journal line", and trailing whitespace cannot forge structure in any case.
  function jparse(line,   i, e, c) {
    J_seq = 0; J_op = ""; J_table = ""; J_row = ""
    sub(/[ \t\r]+$/, "", line)
    if (substr(line, 1, 7) != "{\"seq\":") return 0
    i = 8
    while (i <= length(line)) {
      c = substr(line, i, 1)
      if (index("0123456789", c) == 0 || c == "") break
      i++
    }
    if (i == 8) return 0
    J_seq = substr(line, 8, i - 8) + 0
    if (substr(line, i, 7) != ",\"ts\":\"") return 0
    i += 6; e = jsend(line, i); if (!e) return 0; i = e + 1
    if (substr(line, i, 10) != ",\"actor\":\"") return 0
    i += 9; e = jsend(line, i); if (!e) return 0; i = e + 1
    if (substr(line, i, 7) != ",\"op\":\"") return 0
    i += 6; e = jsend(line, i); if (!e) return 0
    J_op = substr(line, i + 1, e - i - 1); i = e + 1
    if (substr(line, i, 10) != ",\"table\":\"") return 0
    i += 9; e = jsend(line, i); if (!e) return 0
    J_table = substr(line, i + 1, e - i - 1); i = e + 1
    if (substr(line, i, 7) != ",\"row\":") return 0
    i += 7
    # everything from here to the line's final `}` (the OUTER object's) is the row
    if (i > length(line)) return 0
    if (substr(line, length(line), 1) != "}") return 0
    J_row = substr(line, i, length(line) - i)
    if (substr(J_row, 1, 1) != "{") return 0
    if (substr(J_row, length(J_row), 1) != "}") return 0
    # the row must be the WHOLE remainder — no trailing bytes after its closing brace
    if (jvend(J_row, 1) != length(J_row)) return 0
    return 1
  }

  # ---- table metadata and ROW IDENTITY -------------------------------------------
  #
  # jmeta(line) consumes one line of `_journal_table_meta` output and fills the shared
  # M_* arrays; jident(table, row) answers the one question all three journal readers
  # ask: WHICH ROW IS THIS. Both live here because sync, compact and replay must agree
  # on the answer — three definitions of identity is three different databases.
  #
  #   M_known[t]        1 for every table in the metadata
  #   M_col[t, name]    1 for every column of t; M_nc[t] how many
  #   M_npk[t]          number of primary-key columns; M_pk[t, i] their names
  #   M_nid[t]          number of IDENTITY columns; M_id[t, i] their names.
  #                     Non-zero only for a surrogate-key table (see the `I` lines
  #                     emitted by _journal_table_meta).
  #   M_pure[t]         1 when the identity columns are ALL the non-key columns, i.e.
  #                     the table has no mutable state and is strictly INSERT-only.
  function jmeta(line,   n, f, t, i, c) {
    n = split(line, f, " ")
    if (n < 2) return 0
    t = f[2]
    if (f[1] == "C") {
      if (n < 5) return 0
      M_known[t] = 1
      if (!((t, f[3]) in M_col)) M_nc[t]++
      M_col[t, f[3]] = 1
      if (f[5] + 0 > 0) {
        M_pk[t, f[5] + 0] = f[3]
        if (f[5] + 0 > M_npk[t] + 0) M_npk[t] = f[5] + 0
      }
      return 1
    }
    if (f[1] == "I") {
      # `I` lines follow all `C` lines, so M_col is complete here: an identity column
      # the current schema no longer has is dropped rather than compared as absent.
      if (!(t in M_known)) return 1
      for (i = 3; i <= n; i++) {
        c = f[i]
        if (!((t, c) in M_col)) continue
        M_id[t, ++M_nid[t]] = c
      }
      # No column outside the identity means no column a later line can change, so
      # every line for this table is a NEW record rather than a restatement of one.
      # Conservative by construction: a dropped identity column makes this 0, which
      # only costs precision, never a row.
      M_pure[t] = (M_nid[t] + 0 == M_nc[t] - M_npk[t]) ? 1 : 0
      return 1
    }
    return 0
  }

  # jident(t, row, ns) — the MERGE-STABLE identity of `row` in table `t`, or "" if it
  # has none. `ns` names a counting namespace; see the ordinal rule below.
  #
  # For an ordinary table the identity is the primary key: `REQ-001` names the same
  # requirement on every machine. For a SURROGATE-KEY table (work_log, review_finding,
  # event) it is emphatically NOT the primary key: those ids come from an autoincrement
  # counter local to one database, so two machines both allocate id 1 and the two rows
  # are not the same row. Their identity is their CONTENT — the immutable columns on the
  # `I` line — which is the same on every machine that carries the row.
  #
  # THE ORDINAL, and why only some tables get it. Content alone cannot tell two
  # byte-identical rows apart, so `guild log` twice in the same second with the same
  # text would collapse to one row on replay. For a table with no mutable columns
  # (M_pure) that is fixable: the Nth occurrence of a content is a different record from
  # the (N+1)th, so the occurrence number joins the key and both rows survive. A table
  # that DOES have mutable columns cannot use it — a review_finding filed and later
  # re-dispositioned is one row described twice, and counting occurrences would split it
  # in two. So the ordinal is applied exactly where it is sound.
  #
  # Occurrences are counted per NAMESPACE, because every caller compares two streams
  # (journal vs database, journal vs candidate) and each stream must count from zero.
  # Order within a stream does not matter: the rows an ordinal separates are, by
  # definition, byte-identical and therefore interchangeable.
  #
  # Values are the RAW tokens out of jfield(), and every side of every comparison is
  # produced by json_object(), so the escaping matches byte for byte.
  function jident(t, row, ns,   i, v, key, n) {
    key = t
    if (M_nid[t] + 0 > 0) {
      for (i = 1; i <= M_nid[t]; i++) key = key SUBSEP jfield(row, M_id[t, i])
      if (M_pure[t]) key = key SUBSEP (++M_occ[ns, key])
      return key
    }
    n = M_npk[t] + 0
    if (n == 0) return ""
    for (i = 1; i <= n; i++) {
      v = jfield(row, M_pk[t, i])
      if (v == "") return ""
      key = key SUBSEP v
    }
    return key
  }
AWKLIB
}

# _journal_awk_lib_file <path> — materialize the library.
_journal_awk_lib_file() {
  _journal_awk_lib >"$1" || die "guild: could not write the journal parser to $1"
}

# ---- JSON emission ---------------------------------------------------------------
#
# json_escape / json_str live in lib/db.sh — the spool needs them too, and one escaper
# is the whole point. journal_row below is the only thing here that builds JSON.

# _journal_is_json_number <s> — is <s> spelled exactly as a JSON number?
#
# STRICTER THAN "starts with a digit", and the difference is a real data-loss bug. The
# old guard was `case "$v" in null|true|false|-[0-9]*|[0-9]*)`, which accepts `007` and
# `12a` — neither of which is valid JSON. `guild finding --line 007` therefore wrote
# `"line":007` into the spool, exited 0, and said nothing; `json_valid()` in _spool_sql
# then rejected the whole line at drain time and the finding was quarantined instead of
# filed. The reviewer was told it had worked.
#
# JSON's grammar for an integer: an optional `-`, then either `0` or a non-zero digit
# followed by digits. No leading zeros, no trailing junk. Fractions and exponents are
# deliberately NOT accepted — every '#' call site in this CLI is an integer column of a
# STRICT table, and widening the guard to shapes nothing emits only widens the hole.
_journal_is_json_number() {
  local v="${1-}"
  case "$v" in
    -*) v="${v#-}" ;;
  esac
  case "$v" in
    '' | *[!0-9]*) return 1 ;;
    0) return 0 ;;
    0*) return 1 ;;
  esac
  return 0
}

# journal_row <key> <value> [<key> <value> ...] — build a flat JSON object.
#
# A key prefixed with '#' emits its value RAW (unquoted) and the value must be a JSON
# number, true, false or null. Everything else is emitted as a JSON string. The '#'
# form exists because types matter on replay: a value inserted into an INTEGER column
# of a STRICT table must arrive as a JSON number, not a string.
#
#   journal_row id TASK-014 title "Fix the thing" '#priority' 3 '#claimed_by' null
journal_row() {
  local out="{" first=1 k v
  while [ $# -gt 0 ]; do
    k="$1"
    shift
    [ $# -gt 0 ] || die "journal_row: key '$k' has no value"
    v="$1"
    shift
    [ "$first" = 1 ] || out="$out,"
    first=0
    case "$k" in
      '#'*)
        case "$v" in
          null | true | false) : ;;
          *)
            _journal_is_json_number "$v" ||
              die "journal_row: raw key '$k' needs a JSON number/true/false/null (got '$v')"
            ;;
        esac
        out="$out\"$(json_escape "${k#\#}")\":$v"
        ;;
      *)
        out="$out\"$(json_escape "$k")\":\"$(json_escape "$v")\""
        ;;
    esac
  done
  printf '%s}\n' "$out"
}

# ---- append ----------------------------------------------------------------------

# _journal_last_seq — highest `seq` in the journal's tail, or 0 for an empty/absent
# journal. Derived from the file so the journal is its own counter; the tail window
# tolerates a line torn by a crash mid-append.
_journal_last_seq() {
  local f
  f="$(journal_path)"
  if [ ! -s "$f" ]; then
    printf '0\n'
    return 0
  fi
  tail -n 5 "$f" | LC_ALL=C awk '
    { if (substr($0, 1, 7) == "{\"seq\":") { n = substr($0, 8) + 0; if (n > m) m = n } }
    END { print m + 0 }
  '
}

# _journal_tail_terminated — does the journal end in a newline? True for an empty or
# absent file.
#
# WHY THIS IS A DATA-LOSS CHECK AND NOT A TIDINESS ONE. journal_append writes with
# `printf ... >>`, which starts at whatever byte the file currently ends on. If that
# byte is not `\n`, the new entry is CONCATENATED onto the previous one, and the result
# is a single line that parses as neither — so `guild rebuild` counts it as one
# unparseable line and BOTH mutations are gone. The mutation that did the gluing
# returned its id on stdout and exited 0.
#
# Two triggers that need no user error: a SIGKILL or a full disk part-way through
# appending a large row (a 290 KB body is a ~580 KB line and many write(2) calls), and
# any git merge resolution or editor that drops the trailing newline on a text file git
# carries. `_journal_last_seq` reads the tail window and TOLERATES such a line; it is
# the next append that destroys it.
#
# `od -An -v -tx1` rather than `[ -n "$(tail -c1 ...)" ]`: command substitution strips
# NUL bytes as well as newlines, so a journal truncated onto a NUL would read as
# terminated. `-v` is required — without it od collapses repeats (§ the same flag the
# hex encoder needs).
_journal_tail_terminated() {
  local f last
  f="$(journal_path)"
  [ -s "$f" ] || return 0
  last="$(tail -c 1 "$f" | LC_ALL=C od -An -v -tx1 2>/dev/null | tr -d ' \n')"
  [ "$last" = "0a" ]
}

# ---- the advisory mutation lock ---------------------------------------------------
#
# WHY THERE IS A LOCK AT ALL. The guild's whole model is parallel agents, and two of
# them mutating at once failed in two distinct ways:
#
#   · THE JOURNAL APPEND IS NOT ATOMIC. `printf >>` is atomic only within one stdio
#     buffer. Four processes appending five 300 KB rows each tore 8 of 20 lines — and by
#     _journal_tail_terminated's logic above, a torn line swallows its successor.
#   · TURSODB TAKES AN EXCLUSIVE FILE LOCK and fails rather than waits, so four of six
#     concurrent `guild move` calls died with `Locking error`. Nothing was corrupted and
#     the failure was loud — but an agent that reads rc=1 as "the board rejected my
#     move" draws exactly the wrong conclusion.
#
# Both are the same missing thing: nothing serialized one guild mutation against
# another. journal_preflight is where every mutating command already announces "I am
# about to write", so that is where the lock is taken, and it is held until the process
# exits — which puts the database write and the journal append inside one critical
# section instead of two unrelated ones.
#
# MECHANISM, AND WHY THIS ONE. There is no flock(1) on macOS and no dependency budget to
# add one. `mkdir` is atomic on every POSIX filesystem, so the lock is a DIRECTORY whose
# `owner` file records the pid that claimed it and the epoch second it did.
#
# A CRASH MUST NOT WEDGE THE GUILD FOREVER. Three independent ways out, in order:
#   1. normal exit, including `die` — an EXIT trap releases it;
#   2. the holder's pid is gone (`kill -0` fails) — the next command breaks it
#      immediately. Same liveness test the export staging sweep already uses;
#   3. the claim is older than $GUILD_LOCK_STALE (default 900s) — broken regardless,
#      which covers pid reuse and a lock left behind by another machine.
# Breaking is done by RENAMING the lock aside and then deleting it, so two processes
# that both judge it stale cannot both proceed: only the one whose rename won does.
#
# WHERE IT STOPS — this is ADVISORY, and best-effort. It serializes guild processes on
# one machine that go through journal_preflight. It does not protect journal.ndjson from
# an editor or another program, it cannot survive pid reuse inside the stale window, and
# `mkdir` atomicity on NFS is not something this file can promise. It narrows a real
# race; it is not a mutex, and nothing above should be read as one.
#
# The lock lives at $GUILD_DIR/journal.ndjson.tmp.lock, and the name is deliberate: the
# .gitignore `guild init` writes already carries `journal.ndjson.tmp.*`, so neither the
# lock nor a `.stale.*` fragment can ever surface in `git status`.
_journal_lock_path() {
  printf '%s\n' "${GUILD_DIR:-.guild}/journal.ndjson.tmp.lock"
}

# _journal_lock_break <lockdir> — move a lock believed stale out of the way. Returns 0
# only when THIS process is the one that removed it, so a lost race falls back to
# waiting rather than to a second claimant.
_journal_lock_break() {
  local lock="$1" aside
  aside="$lock.stale.$$"
  rm -rf "$aside" 2>/dev/null || true
  mv "$lock" "$aside" 2>/dev/null || return 1
  rm -rf "$aside" 2>/dev/null || true
  return 0
}

# _journal_lock_stale <lockdir> <waited-ms> — is the holder gone? 0 = yes, break it.
_journal_lock_stale() {
  local lock="$1" waited="$2" owner pid claimed now limit
  limit="${GUILD_LOCK_STALE:-900}"
  case "$limit" in '' | *[!0-9]*) limit=900 ;; esac
  owner="$(cat "$lock/owner" 2>/dev/null || true)"

  # No owner record yet: the holder is either between its mkdir and its write (a window
  # of microseconds) or it died inside that window. Wait first, then assume the latter.
  if [ -z "$owner" ]; then
    [ "$waited" -ge 5000 ] || return 1
    return 0
  fi

  pid="${owner%% *}"
  claimed="${owner##* }"

  case "$pid" in
    '' | *[!0-9]*) : ;;
    *)
      if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
      ;;
  esac

  case "$claimed" in
    '' | *[!0-9]*) return 1 ;;
  esac
  now="$(date -u +%s 2>/dev/null || printf '0')"
  case "$now" in
    '' | *[!0-9]*) return 1 ;;
  esac
  if [ "$((now - claimed))" -ge "$limit" ]; then return 0; fi
  return 1
}

# _journal_lock [soft] — claim the advisory mutation lock.
#
# RE-ENTRANT. Only the 0 -> 1 depth transition claims anything, and a subshell inherits
# the depth — which is what keeps journal_append -> journal_recover -> journal_preflight
# from deadlocking against its own parent, and keeps a release inside `$( ... )` from
# dropping a lock the parent still holds.
#
# With `soft`, a timeout RETURNS 1 instead of dying. Callers that have already written
# to the database use it: losing the mutation to a lock timeout would be worse than
# appending unserialized.
_journal_lock() {
  local mode="${1-}" lock dir owner waited delay maxwait depth

  depth="${_GUILD_LOCK_DEPTH:-0}"
  if [ "$depth" -gt 0 ]; then
    _GUILD_LOCK_DEPTH=$((depth + 1))
    return 0
  fi

  lock="$(_journal_lock_path)"
  dir="$(dirname "$lock")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true
  # An unwritable guild directory is not this function's failure to report: the caller is
  # about to fail on the write it actually wanted, with a message about that write.
  # Proceeding unlocked is strictly better than dying here with the wrong explanation.
  [ -w "$dir" ] || return 0

  # Validated, not interpolated: `$(( $GUILD_LOCK_WAIT * 1000 ))` on a non-numeric value
  # is a bash arithmetic syntax error, which under the dispatcher's `set -e` would abort
  # the whole command over a typo in an environment variable.
  maxwait="${GUILD_LOCK_WAIT:-30}"
  case "$maxwait" in '' | *[!0-9]*) maxwait=30 ;; esac
  maxwait=$((maxwait * 1000))
  waited=0
  delay=20
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s %s\n' "$$" "$(date -u +%s 2>/dev/null || printf '0')" \
        >"$lock/owner" 2>/dev/null || true
      _GUILD_LOCK_DEPTH=1
      if [ "${_GUILD_LOCK_TRAPPED:-0}" != "1" ]; then
        _GUILD_LOCK_TRAPPED=1
        trap '_journal_lock_release' EXIT
      fi
      return 0
    fi

    # ALREADY OURS. `$$` is the same inside `$( ... )` and `( ... )` — bash 3.2 has no
    # BASHPID — so a lock claimed inside a subshell leaves _GUILD_LOCK_DEPTH set only in
    # that subshell's copy of the environment, and the parent would then wait 30s for
    # itself. Adopting the lock is both correct (one process cannot race itself) and the
    # thing that makes the trap fire: the depth and the EXIT trap end up in the shell
    # that will actually outlive the region.
    owner="$(cat "$lock/owner" 2>/dev/null || true)"
    if [ -n "$owner" ] && [ "${owner%% *}" = "$$" ]; then
      _GUILD_LOCK_DEPTH=1
      if [ "${_GUILD_LOCK_TRAPPED:-0}" != "1" ]; then
        _GUILD_LOCK_TRAPPED=1
        trap '_journal_lock_release' EXIT
      fi
      return 0
    fi

    if _journal_lock_stale "$lock" "$waited"; then
      if _journal_lock_break "$lock"; then continue; fi
    fi

    if [ "$waited" -ge "$maxwait" ]; then
      [ "$mode" != "soft" ] || return 1
      owner="$(cat "$lock/owner" 2>/dev/null || printf 'unknown')"
      die "guild: another guild command has held the board lock for $(( maxwait / 1000 ))s.

Nothing was written. Guild serializes mutations with an advisory lock so that parallel
agents queue instead of colliding inside the database driver.

  lock   $lock
  owner  $owner   (pid and the epoch second it was claimed)

A lock whose owning process has exited is broken automatically on the next command, so
this means the holder is still running. Wait for it, or raise the wait with
\$GUILD_LOCK_WAIT (seconds). If you are certain no guild command is running, remove the
lock directory by hand:

  rm -rf $lock"
    fi

    sleep "$(printf '0.%03d' "$delay")"
    waited=$((waited + delay))
    delay=$((delay * 2))
    [ "$delay" -le 500 ] || delay=500
  done
}

# _journal_unlock — drop one level; the last level releases.
_journal_unlock() {
  local lock depth
  depth="${_GUILD_LOCK_DEPTH:-0}"
  [ "$depth" -gt 0 ] || return 0
  depth=$((depth - 1))
  _GUILD_LOCK_DEPTH="$depth"
  [ "$depth" -eq 0 ] || return 0
  lock="$(_journal_lock_path)"
  rm -f "$lock/owner" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
  return 0
}

# _journal_lock_release — the EXIT trap. A command that ends while holding the lock —
# including one that `die`s — releases it immediately rather than leaving it for the
# stale timeout. Every step is failure-tolerant: this runs during shell exit, where a
# non-zero status under `set -e` would replace the exit code the command meant to give.
_journal_lock_release() {
  if [ "${_GUILD_LOCK_DEPTH:-0}" -gt 0 ]; then
    _GUILD_LOCK_DEPTH=1
    _journal_unlock || true
  fi
  return 0
}

# journal_preflight — verify the journal can be appended to, BEFORE the caller mutates
# the database. THIS IS THE ORDERING FIX for "committed but unjournaled": a caller that
# runs this first turns a divergence into a refusal, and a refusal is honest.
#
# It also TAKES THE ADVISORY MUTATION LOCK, held until the process exits, so that the
# caller's database write and its journal append happen inside one critical section.
#
# Every message here ends with "nothing was written", because at this point nothing
# has been — that is the entire contract of this function. Call it at the top of any
# command that will mutate and then journal:
#
#   journal_preflight            # dies if the journal is not appendable
#   ... run the SQL ...
#   journal_append task upsert "$row"
journal_preflight() {
  local f dir
  f="$(journal_path)"
  dir="$(dirname "$f")"

  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null ||
      die "guild: no guild directory at $dir and it could not be created; nothing was written"
  fi

  if [ -e "$f" ]; then
    [ -f "$f" ] ||
      die "guild: $f is not a regular file; refusing to mutate the board (nothing was written)"
    [ -w "$f" ] ||
      die "guild: the journal $f is not writable; refusing to mutate the board (nothing was written)"
    if [ -s "$f" ] && [ "$(_journal_last_seq)" = "0" ]; then
      die "guild: the journal tail at $f is unreadable — refusing to mutate the board.

Nothing was written. The last lines of the journal carry no sequence number, which
usually means an unresolved git merge conflict (<<<<<<< / ======= / >>>>>>>) or a
truncated file. Repair those lines and re-run this command."
    fi
    if ! _journal_tail_terminated; then
      die "guild: $f does not end in a newline — refusing to mutate the board.

Nothing was written. An append would start on the same line as the last entry and glue
the two together, and a glued line parses as NEITHER — 'guild rebuild' would then count
it as one unparseable line and BOTH mutations would be gone. This happens when a write
was interrupted (a crash or a full disk part-way through a large row) or when a merge
resolution dropped the file's trailing newline.

Look at the last line first:

  tail -n 1 $f

  · if it is a COMPLETE entry (it starts with {\"seq\": and ends with }), the newline is
    all that is missing — put it back and nothing is lost:

      printf '\\n' >> $f

  · if it is TRUNCATED mid-entry, that mutation was never fully recorded. Drop the
    partial line, then replay to be sure the board matches what is left:

      sed '\$d' $f > $f.repaired && mv $f.repaired $f
      guild rebuild"
    fi
  else
    [ -w "$dir" ] ||
      die "guild: cannot create the journal in $dir (not writable); nothing was written"
  fi

  _journal_lock

  return 0
}

# _journal_quarantine <line> <reason> — record a journal line whose append failed AFTER
# the database was already written, and say so at the top of its voice.
#
# The failure this handles is real and routine: journal.ndjson is committed to git, so
# a merge conflict in it is a normal event, and it is exactly what makes the tail
# unreadable. The old behaviour was to die with "refusing to append" — which reads as
# "nothing happened" while the board had in fact changed and the change was gone
# forever. Now the change is preserved and the operator is told what to do about it.
#
# Returns 0 when the line was quarantined (the caller may continue and report success
# for the mutation, which DID happen); dies when even the quarantine failed, because
# at that point the divergence is real and unrecorded.
_journal_quarantine() {
  local line="${1-}" reason="${2-}" p
  p="$(journal_pending_path)"

  if mkdir -p "$(dirname "$p")" 2>/dev/null && printf '%s\n' "$line" >>"$p" 2>/dev/null; then
    {
      printf 'guild: WARNING — the database was updated but the journal was NOT.\n'
      printf '       reason: %s\n' "$reason"
      printf '       The change has been saved to %s, so nothing is lost.\n' "$p"
      printf '       Repair the journal, then fold it back in with:  guild journal recover\n'
      printf '       (the next successful mutation folds it in automatically).\n'
    } >&2
    return 0
  fi

  die "guild: the database was updated but the change could NOT be recorded anywhere.
       reason: $reason
       Quarantine at $p also failed. The database and $(journal_path) have DIVERGED:
       re-running 'guild rebuild' now would discard this change. Copy the database
       aside before doing anything else."
}

# journal_append <table> <op> <json-row> — append one NDJSON line.
journal_append() {
  local table="${1-}" op="${2-}" row="${3-}"
  local f dir prev seq ts actor nl line
  nl=$'\n'

  _journal_is_ident "$table" || die "journal_append: '$table' is not a table name"
  case "$op" in
    upsert | delete) : ;;
    *) die "journal_append: op must be 'upsert' or 'delete' (got '$op')" ;;
  esac
  case "$row" in
    '{'*'}') : ;;
    *) die "journal_append: row must be a JSON object" ;;
  esac
  case "$row" in
    *"$nl"*) die "journal_append: row contains a newline; NDJSON is one line per entry" ;;
  esac

  f="$(journal_path)"
  dir="$(dirname "$f")"
  [ -d "$dir" ] || mkdir -p "$dir"

  # Self-healing: anything quarantined by an earlier failure is folded in FIRST, so
  # the journal keeps mutation order. Best effort — a still-broken journal simply
  # sends this line to the same quarantine.
  if [ -s "$(journal_pending_path)" ]; then
    ( journal_recover >/dev/null 2>&1 ) || true
  fi

  ts="$(_journal_now)"
  actor="${GUILD_ACTOR:-orchestrator}"

  # Read the sequence and write the line inside the lock, or two processes allocate the
  # same seq and their `printf >>` calls interleave. Soft: the database has been written
  # by now, so a lock timeout must not cost the mutation — an unserialized append is
  # worse than serialized, and far better than none.
  _journal_lock soft || true

  # A tail with no newline would make this append glue onto the previous entry and
  # destroy both. journal_preflight refuses outright; here the database has ALREADY been
  # written, so the line goes to the quarantine instead — same direction as every other
  # post-commit failure in this module: preserve the mutation, say so loudly.
  if ! _journal_tail_terminated; then
    line="$(printf '{"seq":0,"ts":"%s","actor":"%s","op":"%s","table":"%s","row":%s}' \
      "$ts" "$(json_escape "$actor")" "$op" "$table" "$row")"
    _journal_quarantine "$line" "$f does not end in a newline; appending would glue this entry onto the last one and destroy both"
    _journal_unlock
    return 0
  fi

  prev="$(_journal_last_seq)"
  if [ -s "$f" ] && [ "$prev" = "0" ]; then
    line="$(printf '{"seq":0,"ts":"%s","actor":"%s","op":"%s","table":"%s","row":%s}' \
      "$ts" "$(json_escape "$actor")" "$op" "$table" "$row")"
    _journal_quarantine "$line" "the journal tail at $f is unreadable (an unresolved merge conflict?)"
    _journal_unlock
    return 0
  fi

  seq=$((prev + 1))
  if ! printf '{"seq":%s,"ts":"%s","actor":"%s","op":"%s","table":"%s","row":%s}\n' \
    "$seq" "$ts" "$(json_escape "$actor")" "$op" "$table" "$row" >>"$f"; then
    line="$(printf '{"seq":0,"ts":"%s","actor":"%s","op":"%s","table":"%s","row":%s}' \
      "$ts" "$(json_escape "$actor")" "$op" "$table" "$row")"
    _journal_quarantine "$line" "the journal $f could not be written"
    _journal_unlock
    return 0
  fi

  _journal_unlock
  return 0
}

# journal_recover — fold `.guild/journal.pending` back into the journal.
#
# Quarantined lines are re-sequenced onto the end of the real journal, in the order
# they were quarantined. The pending file is unlinked only AFTER the append lands, so
# an interruption re-runs the fold: upserts and pk-scoped deletes are idempotent, and
# a duplicate line costs nothing, while a lost one costs a mutation. Same direction as
# the spool (§2.4).
journal_recover() {
  local f p prev tmpd n
  f="$(journal_path)"
  p="$(journal_pending_path)"

  if [ ! -s "$p" ]; then
    rm -f "$p" 2>/dev/null || true
    printf 'Nothing to recover — no quarantined journal entries at %s\n' "$p"
    return 0
  fi

  journal_preflight
  prev="$(_journal_last_seq)"

  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/guild-recover.XXXXXX")" \
    || die "guild: could not create a temporary directory"

  LC_ALL=C awk -v START="$prev" '
    {
      if (substr($0, 1, 7) != "{\"seq\":") next
      i = 8
      while (i <= length($0)) {
        c = substr($0, i, 1)
        if (index("0123456789", c) == 0 || c == "") break
        i++
      }
      rest = substr($0, i)
      if (substr(rest, 1, 1) != ",") next
      n++
      printf "{\"seq\":%d%s\n", START + n, rest
    }
    END { print n + 0 > (OUT "/n") }
  ' OUT="$tmpd" "$p" >"$tmpd/lines" \
    || { rm -rf "$tmpd"; die "guild: could not re-sequence $p"; }

  n="$(LC_ALL=C awk 'END { print $0 + 0 }' "$tmpd/n" 2>/dev/null || printf '0')"
  if [ "$n" = "0" ]; then
    rm -rf "$tmpd"
    die "guild: $p holds no recoverable journal lines — inspect it by hand, then delete it"
  fi

  cat "$tmpd/lines" >>"$f" || { rm -rf "$tmpd"; die "guild: could not append to $f"; }
  rm -f "$p" || true
  rm -rf "$tmpd"

  printf 'Recovered %s quarantined entr%s into %s\n' "$n" "$([ "$n" = 1 ] && printf 'y' || printf 'ies')" "$f"
}

# _journal_write_lines — bulk append. Reads `<table>|<json object>` lines on stdin and
# appends one upsert line per row, in ONE pass, under a single sequence allocation.
#
# The `|` split is on the FIRST pipe only and the table name is a validated identifier,
# so a pipe inside the JSON is just data; json_object() escapes newlines, so a row is
# always exactly one line. Same transport discipline as journal_compact.
#
# On failure the whole batch is quarantined rather than half-written.
_journal_write_lines() {
  local f tmpd prev ts actor n
  f="$(journal_path)"
  journal_preflight

  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/guild-jwrite.XXXXXX")" \
    || die "guild: could not create a temporary directory"
  cat >"$tmpd/in" || { rm -rf "$tmpd"; die "guild: could not stage journal input"; }

  prev="$(_journal_last_seq)"
  ts="$(_journal_now)"
  actor="$(json_escape "${GUILD_ACTOR:-orchestrator}")"

  LC_ALL=C awk -v START="$prev" -v TS="$ts" -v ACTOR="$actor" '
    {
      p = index($0, "|")
      if (p < 2) next
      t = substr($0, 1, p - 1)
      row = substr($0, p + 1)
      if (t !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next
      if (substr(row, 1, 1) != "{") next
      if (substr(row, length(row), 1) != "}") next
      n++
      printf "{\"seq\":%d,\"ts\":\"%s\",\"actor\":\"%s\",\"op\":\"upsert\",\"table\":\"%s\",\"row\":%s}\n", \
        START + n, TS, ACTOR, t, row
    }
    END { print n + 0 > (OUT "/n") }
  ' OUT="$tmpd" "$tmpd/in" >"$tmpd/lines" \
    || { rm -rf "$tmpd"; die "guild: could not compose journal entries"; }

  n="$(LC_ALL=C awk 'END { print $0 + 0 }' "$tmpd/n" 2>/dev/null || printf '0')"
  if [ "$n" = "0" ]; then
    rm -rf "$tmpd"
    printf '0\n'
    return 0
  fi

  if ! cat "$tmpd/lines" >>"$f"; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      _journal_quarantine "$line" "the journal $f could not be written"
    done <"$tmpd/lines"
    rm -rf "$tmpd"
    printf '0\n'
    return 0
  fi

  rm -rf "$tmpd"
  printf '%s\n' "$n"
}

# journal_capture <table> — journal MANY rows at once. Reads one `json_object(...)` row
# per line on stdin and appends an upsert line for each. Prints the count.
#
# This is the API for the commands that write the append-only record tables. Write and
# journal in one statement, exactly as the single-row path does:
#
#   printf '%s' "$sql" | db_exec | journal_capture work_log
#
# where $sql ends in
#   INSERT INTO work_log (...) VALUES (...)
#     RETURNING json_object('id',id,'task_id',task_id,'ts',ts,'agent',agent,'entry',entry);
#
# Call journal_preflight before the SQL, as always.
journal_capture() {
  local table="${1-}" tmpd n
  _journal_is_ident "$table" || die "journal_capture: '$table' is not a table name"

  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/guild-capture.XXXXXX")" \
    || die "guild: could not create a temporary directory"
  LC_ALL=C awk -v T="$table" '
    substr($0, 1, 1) == "{" && substr($0, length($0), 1) == "}" { print T "|" $0 }
  ' >"$tmpd/lines" || { rm -rf "$tmpd"; die "guild: could not stage rows for the journal"; }

  n="$(_journal_write_lines <"$tmpd/lines")"
  rm -rf "$tmpd"
  printf '%s\n' "$n"
}

# ---- table metadata --------------------------------------------------------------
#
# Both rebuild and compact need each table's columns. Rather than duplicating the
# schema here (where it would silently drift), it is read back from the database with
# PRAGMA table_info — one db_exec for ALL tables, marker lines identifying each block.
#
# Emits normalized lines:
#   C <table> <column> <notnull> <pk-position> <default-sql>
#   I <table> <identity-column> ...            (surrogate-key tables only, see below)

# _journal_identity_spec — the SURROGATE-KEY TABLES and the columns that identify a row
# in them.
#
# WHY THIS LIST IS HAND-WRITTEN AND CANNOT BE READ FROM THE CATALOG. `PRAGMA table_info`
# tells you that work_log.id and schema_version.id are both INTEGER PRIMARY KEY. It
# cannot tell you that work_log.id is a meaningless counter allocated by whichever
# database happened to be open, while schema_version.id is the literal number 1 and
# means something. That difference is semantic, and journal.ndjson is committed to git,
# so it decides whether a merge of two journals keeps both machines' work or silently
# keeps one:
#
#   alice: work_log id 1 = "fixed the parser"
#   bob:   work_log id 1 = "wrote the tests"
#   merge + replay keyed on id -> one row survives, and nothing says so.
#
# So for the tables below a row is identified by its CONTENT, not by its id. The listed
# columns are the IMMUTABLE ones — the ones a later update never touches. Everything
# else in the row is mutable state that the newest journal line for the same identity
# overwrites (review_finding.disposition is the live example: a finding is filed once
# and re-dispositioned later, and those two lines are ONE row, not two).
#
# Adding a table with an INTEGER PRIMARY KEY? If it is an append-only record, add it
# here. If you do not, it replays keyed on its integer id, which is correct on one
# machine and lossy across a merge. Tables NOT listed here keep the primary-key
# behaviour, which is right for every text-keyed table (REQ-001 is REQ-001 everywhere).
_journal_identity_spec() {
  cat <<'IDSPEC'
I work_log task_id ts agent entry
I review_finding task_id reviewer severity summary detail file line created_at
I event ts actor verb subject_type subject_id payload
I capability_request capability requirement_id rationale proposed_agent proposed_spec created_at
I graph_deviation requirement_id kind node_key reason created_at
IDSPEC
}

# Takes a FILE of table names, one per line — not a splat of arguments. A file keeps
# the `die` below in the calling shell (a name list piped in would put this function on
# the right of a pipe, where die exits only the subshell) and needs no word splitting.
_journal_table_meta() {
  local names="${1-}" sql="" t raw out
  [ -f "$names" ] || die "guild: _journal_table_meta needs a file of table names"
  while IFS= read -r t || [ -n "$t" ]; do
    [ -n "$t" ] || continue
    _journal_is_ident "$t" || die "guild: refusing to introspect '$t' — not a table name"
    sql="${sql}SELECT '#T ${t}';
PRAGMA table_info(${t});
"
  done <"$names"
  [ -n "$sql" ] || return 0

  # Staged through a file rather than piped straight into awk: in a pipeline the exit
  # status is awk's, so a failed db_exec would silently yield empty metadata and a
  # rebuild that skips every row while reporting success.
  raw="$(mktemp "${TMPDIR:-/tmp}/guild-meta.XXXXXX")" \
    || die "guild: could not create a temporary file"
  if ! printf '%s' "$sql" | db_exec >"$raw"; then
    out="$(cat "$raw" 2>/dev/null || true)"
    rm -f "$raw"
    db_fail "could not read table metadata from the database" "$out"
  fi

  # FS is a literal '|' because that is the driver's format, fixed by `-m list` (§2.2).
  LC_ALL=C awk -F'|' '
    {
      if (substr($0, 1, 3) == "#T ") { t = substr($0, 4); next }
      if (t == "" || NF < 6) next
      if ($1 !~ /^[0-9]+$/) next          # skip a header row if one is ever emitted
      name = $2; notnull = $4; pk = $NF
      dflt = ""
      for (i = 5; i <= NF - 1; i++) dflt = dflt (i > 5 ? FS : "") $i
      print "C " t " " name " " notnull " " pk " " dflt
    }
  ' "$raw"
  rm -f "$raw"

  # The identity spec goes LAST, after every C line, because jmeta() drops an identity
  # column the current schema no longer has and needs the column list to do it.
  _journal_identity_spec
}

# _journal_live_tables — every user table in the database, sorted. Read from the
# catalog rather than from a hardcoded list, so a schema that grows a table needs no
# edit here.
_journal_live_tables() {
  printf "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%%' ORDER BY name;\n" \
    | db_exec
}

# ---- sync: the append-only record tables -----------------------------------------

# journal_sync [table ...] — reconcile append-only tables from the database INTO the
# journal. Defaults to work_log, review_finding and event. Prints the count appended.
#
# WHY THIS EXISTS. `guild rebuild` moves the database aside and replays the journal, so
# anything the journal does not carry is destroyed by the recovery path. work_log,
# review_finding and event are the append-only record of what agents actually did —
# the crash-safe-resume record §2.4 is built to protect — and losing them on a recovery
# run is exactly backwards. Their writers should journal as they go (that is what
# journal_capture is for), but this module cannot depend on every writer remembering:
# a durability layer that only works when its callers cooperate is not a durability
# layer. So rebuild reconciles first.
#
# HOW THE MISSING SET IS COMPUTED — and why it is no longer a high-water mark. The old
# version took the highest `id` per table already present in the journal and selected
# `id > that` from the database. It assumed the journal's ids and the database's ids
# come from one sequence. journal.ndjson is committed to git, so they stop being one
# sequence the moment anyone pulls:
#
#   teammate's work_log ids 1..3 arrive by git pull; my database has no work_log at all
#   guild log TASK-001 ... -> my row gets id 1, which is <= the mark, so sync skips it
#   guild rebuild          -> "journaled 3 un-journaled record row(s)" ... and my row is
#                             gone, destroyed by the recovery path, silently
#
# So the comparison is now by IDENTITY (jident, in the awk library above): every row in
# the database whose identity the journal does not already carry, regardless of id. For
# the surrogate-key record tables that identity is the row's content, which is exactly
# the thing that survives a merge.
#
# WHAT THIS COSTS, PRECISELY. For a table with mutable columns (review_finding,
# capability_request, graph_deviation) two rows with byte-identical IMMUTABLE columns are
# one identity, so an indistinguishable duplicate is journaled once — the same collapse
# replay performs, deliberately. For a PURE table (work_log and event: every non-key
# column is an identity column) the occurrence ordinal in jident separates them, so
# `guild log` run twice in the same second with the same text yields two rows here and
# two rows after a replay. Earlier drafts of this comment claimed the collapse applied
# everywhere; it does not, and the difference is exactly M_pure.
#
# Two db_exec calls: one PRAGMA batch for the column lists, one dump. Nothing loops.
journal_sync() {
  local tables t tmpd f sql n out
  tables="$*"
  [ -n "$tables" ] || tables="work_log review_finding event"

  f="$(journal_path)"
  [ -f "$f" ] || return 0

  # Held for the whole compare-then-append, so the set of identities the journal carries
  # cannot change between the comparison and the write.
  _journal_lock

  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/guild-sync.XXXXXX")" \
    || die "guild: could not create a temporary directory"

  : >"$tmpd/tables"
  for t in $tables; do
    _journal_is_ident "$t" || { rm -rf "$tmpd"; die "guild: '$t' is not a table name"; }
    printf '%s\n' "$t" >>"$tmpd/tables"
  done

  _journal_table_meta "$tmpd/tables" >"$tmpd/meta" \
    || { rm -rf "$tmpd"; die "guild: could not read table metadata from the database"; }
  if [ ! -s "$tmpd/meta" ]; then
    rm -rf "$tmpd"
    printf '0\n'
    return 0
  fi

  # The whole table, in primary-key order. No WHERE: the journal decides what is
  # missing, and it decides it on identity, which SQL here cannot express.
  sql="$(LC_ALL=C awk -v SQ="'" '
    $1 == "C" && NF >= 5 {
      t = $2; name = $3; pk = $5 + 0
      if (!(t in seen)) { seen[t] = 1; order[++nt] = t }
      obj[t] = obj[t] (obj[t] == "" ? "" : ",") SQ name SQ ",\"" name "\""
      if (pk > 0) {
        pkname[t SUBSEP pk] = name
        if (pk > npk[t]) npk[t] = pk
      }
    }
    END {
      for (i = 1; i <= nt; i++) {
        t = order[i]
        ob = ""
        for (k = 1; k <= npk[t] + 0; k++) ob = ob (ob == "" ? " ORDER BY " : ",") "\"" pkname[t SUBSEP k] "\""
        print "SELECT " SQ t "|" SQ " || json_object(" obj[t] ") FROM \"" t "\"" ob ";"
      }
    }
  ' "$tmpd/meta")"

  if [ -z "$sql" ]; then
    rm -rf "$tmpd"
    printf '0\n'
    return 0
  fi

  if ! printf '%s\n' "$sql" | db_exec >"$tmpd/rows"; then
    out="$(cat "$tmpd/rows" 2>/dev/null || true)"
    rm -rf "$tmpd"
    db_fail "could not read the append-only tables from the database" "$out"
  fi

  _journal_awk_lib_file "$tmpd/lib.awk"
  cat >"$tmpd/missing.awk" <<'AWKMISSING'
  FILENAME == META { jmeta($0); next }

  # the journal: which identities does it already carry?
  FILENAME == JF {
    if (!jparse($0)) next
    if (!(J_table in M_known)) next
    k = jident(J_table, J_row, "journal")
    if (k == "") next
    if (J_op == "upsert") seen[k] = 1
    else if (J_op == "delete") delete seen[k]
    next
  }

  # the database dump: `<table>|<json row>`, split on the FIRST pipe so a pipe inside
  # the JSON is just data.
  {
    p = index($0, "|")
    if (p < 2) next
    t = substr($0, 1, p - 1)
    row = substr($0, p + 1)
    if (!(t in M_known)) next
    if (substr(row, 1, 1) != "{" || substr(row, length(row), 1) != "}") next
    k = jident(t, row, "db")
    if (k == "") next
    if (k in seen) next
    seen[k] = 1
    print t "|" row
  }
AWKMISSING

  LC_ALL=C awk -v META="$tmpd/meta" -v JF="$f" \
      -f "$tmpd/lib.awk" -f "$tmpd/missing.awk" "$tmpd/meta" "$f" "$tmpd/rows" \
      >"$tmpd/lines" \
    || { rm -rf "$tmpd"; die "guild: could not compare the database against the journal"; }

  n="$(_journal_write_lines <"$tmpd/lines")"
  rm -rf "$tmpd"
  printf '%s\n' "$n"
}

# ---- rebuild ---------------------------------------------------------------------

# journal_rebuild — replay the journal into a fresh database.
#
# Batching: the journal is compiled to SQL by ONE awk pass that writes numbered chunk
# files, then each chunk is applied with one db_exec. A chunk closes at whichever
# comes first — GUILD_JOURNAL_BATCH statements (default 200) or
# GUILD_JOURNAL_BATCH_BYTES of SQL (default 256 KiB). Two bounds, because either alone
# fails: 200 statements of task bodies can be megabytes, and 256 KiB of tiny event
# rows is thousands of statements. Each chunk is one transaction, so a failure leaves
# a clean prefix rather than a half-applied batch.
#
# Foreign keys are OFF during replay: rows are re-inserted in journal order and
# INSERT OR REPLACE deletes-then-inserts, either of which can transiently violate a
# constraint that the final state satisfies.
#
# BEFORE anything is moved or overwritten, two reconciliations run against the database
# that is about to be replaced — folding in quarantined entries, and capturing the
# append-only record tables. Both are non-fatal: a database too broken to read is
# precisely the case rebuild exists for.
#
# REBUILD IS LOCAL-ONLY, AND IT REFUSES RATHER THAN WARNS. Against a cloud database
# there is nothing to move aside: the replay would INSERT OR REPLACE one machine's local
# journal straight into a database other machines are writing to, with no prompt and no
# backup, and in cloud mode the journal is by design only a local audit tail (§2.3) — so
# what it would install is a partial history over a complete one. Cloud mode is gated as
# unverified at the entrance (db_refuse_cloud_mode); this is the same call for the one
# operation that destroys.
journal_rebuild() {
  local f tmp meta tables maxstmt maxbyte bak dbf c stats applied skipped bad synced out nbad

  if [ "${GUILD_DB_MODE:-local}" = "cloud" ]; then
    die "guild: 'guild rebuild' will not run against a cloud database.

Rebuild replays THIS machine's journal over the database. In cloud mode the journal is
a local audit tail, not the whole history — other machines write to the same database
and their mutations were never in your .guild/journal.ndjson. Replaying it would write
a partial history over a shared one, with no backup to go back to, because a cloud
database cannot be moved aside the way a local file can.

Nothing was written. For cloud recovery use Turso's own facilities:

  turso db branch      — branch the database to a point in time
  turso db shell ...   — inspect before you change anything

'guild journal sync' and 'guild journal compact' still work in cloud mode; only the
destructive replay is refused."
  fi

  f="$(journal_path)"
  [ -f "$f" ] || die "guild: no journal at $f"

  # Rebuild moves the live database aside and rewrites it. Serialize it against every
  # other guild process before anything is read, and hold the lock to process exit.
  _journal_lock

  maxstmt="${GUILD_JOURNAL_BATCH:-200}"
  maxbyte="${GUILD_JOURNAL_BATCH_BYTES:-262144}"

  # 1. Quarantined mutations first — they are in the database and not yet in the
  #    journal, and a replay would otherwise be the thing that finally loses them.
  if [ -s "$(journal_pending_path)" ]; then
    journal_recover
  fi

  # 2. work_log / review_finding / event. Non-fatal — a database too broken to read is
  #    exactly the case rebuild exists for — but never SILENT, because a failure here
  #    means the replay is about to drop those rows.
  dbf="$(db_path)"
  if [ -f "$dbf" ]; then
    if synced="$( ( journal_sync work_log review_finding event requirement task plan ) 2>/dev/null )" &&
       case "$synced" in ''|*[!0-9]*) false ;; *) true ;; esac
    then
      [ "$synced" = "0" ] ||
        printf 'guild: journaled %s un-journaled record row(s) before rebuilding\n' "$synced"
    else
      printf 'guild: WARNING — could not read work_log/review_finding/event from the\n' >&2
      printf '       database, so they could not be reconciled into the journal. Any of\n' >&2
      printf '       those rows the journal does not already carry will NOT survive this\n' >&2
      printf '       rebuild. The previous database is kept under .guild/backup-*/.\n' >&2
    fi
  fi

  # 3. READ THE JOURNAL BEFORE ANYTHING IS MOVED.
  #
  # Tables come from the journal itself, not from the catalog: only what is actually
  # replayed needs metadata, and a table the current schema dropped is then skipped
  # loudly instead of failing the whole replay.
  #
  # THIS PASS USED TO RUN AFTER the database had already been renamed into backup-*/ and
  # a fresh schema applied — so a journal this parser could not read produced an empty
  # table list, printed "journal is empty — nothing to replay", and left an empty board
  # at exit 0. One CRLF clone was enough. Nothing is now moved until we know the journal
  # can be read, and a journal that yields no parseable line at all is a REFUSAL.
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/guild-rebuild.XXXXXX")" \
    || die "guild: could not create a temporary directory"
  _journal_awk_lib_file "$tmp/lib.awk"

  cat >"$tmp/tables.awk" <<'AWKTABLES'
  {
    if (jparse($0)) { print "T " J_table; next }
    line = $0
    sub(/[ \t\r]+$/, "", line)
    if (line != "") print "X"
  }
AWKTABLES
  LC_ALL=C awk -f "$tmp/lib.awk" -f "$tmp/tables.awk" "$f" >"$tmp/scan" \
    || { rm -rf "$tmp"; die "guild: could not read $f; nothing was changed"; }
  tables="$(LC_ALL=C awk '$1 == "T" { print $2 }' "$tmp/scan" | sort -u)"
  nbad="$(LC_ALL=C awk '$1 == "X" { n++ } END { print n + 0 }' "$tmp/scan")"

  if [ -z "$tables" ] && [ "$nbad" -gt 0 ]; then
    rm -rf "$tmp"
    die "guild: refusing to rebuild — not one of the $nbad non-blank line(s) in $f is a
journal entry this parser can read.

NOTHING WAS CHANGED. Rebuild replaces the database with whatever the journal replays, so
an unreadable journal replays to an EMPTY BOARD. That is why this is a refusal and not a
warning.

The usual cause is line endings. Check:

  file $f
  head -n 1 $f | od -c | tail -n 2

  · CRLF (\\r\\n) means the file was checked out with core.autocrlf=true or a
    '* text=auto' rule. Fix it for good with a .gitattributes at the repo root:

      echo 'journal.ndjson -text' >> .gitattributes
      git rm --cached $f && git checkout -- $f

  · otherwise the file is truncated, encrypted, an LFS pointer, or simply not a guild
    journal. A copy of the last good one is under ${GUILD_DIR:-.guild}/backup-*/."
  fi

  if [ -z "$tables" ]; then
    rm -rf "$tmp"
    printf 'guild: journal is empty — nothing to replay (the database was left alone)\n'
    return 0
  fi

  if [ "$nbad" -gt 0 ]; then
    printf 'guild: WARNING — %s line(s) in %s could not be parsed and will NOT be\n' "$nbad" "$f" >&2
    printf '       replayed. Any mutation they recorded is dropped by this rebuild. The\n' >&2
    printf '       previous database is kept under %s/backup-*/.\n' "${GUILD_DIR:-.guild}" >&2
  fi

  # A genuinely fresh database: move the old one aside with its WAL sidecars, so a
  # stale WAL cannot resurrect the state we are rebuilding away from. The backup
  # directory name is CLAIMED with mkdir, never merged into: two rebuilds in the same
  # second must not have the second one overwrite the first one's copy.
  if [ -e "$dbf" ]; then
    bak="$(_journal_backup_dir)"
    for c in "$dbf" "$dbf"-*; do
      if [ -e "$c" ]; then mv "$c" "$bak/"; fi
    done
    printf 'guild: previous database moved to %s\n' "$bak"
  fi

  _journal_apply_schema

  meta="$tmp/meta"
  printf '%s\n' "$tables" >"$tmp/tables"
  _journal_table_meta "$tmp/tables" >"$meta"

  cat >"$tmp/replay.awk" <<'AWKREPLAY'
  function flushchunk() {
    if (cf != "") { print "COMMIT;" > cf; close(cf); cf = "" }
  }
  function openchunk() {
    nchunk++
    cf = sprintf("%s/chunk.%06d.sql", OUTDIR, nchunk)
    print "PRAGMA foreign_keys = OFF;" > cf
    print "BEGIN;" > cf
    stmts = 0; bytes = 0
  }
  function emit(sql) {
    if (cf == "") openchunk()
    print sql > cf
    stmts++; bytes += length(sql) + 1
    if (stmts >= MAXSTMT + 0 || bytes >= MAXBYTE + 0) flushchunk()
  }

  # issurro(t) — does t get merge-stable ids? Only a table the identity spec lists AND
  # whose primary key is a single column (the surrogate counter we are replacing).
  function issurro(t) {
    return (M_nid[t] + 0 > 0 && npk[t] + 0 == 1)
  }

  # surrocols(t) — the column and value lists for t WITHOUT its surrogate primary key,
  # which is supplied per row by assignid() instead of coming out of the journal.
  function surrocols(t,   i, nm) {
    if (t in SCdone) return
    SCdone[t] = 1
    SC[t] = "\"" pkname[t SUBSEP 1] "\""
    SV[t] = ""
    for (i = 1; i <= nc[t]; i++) {
      nm = cn[t, i]
      if (nm == pkname[t SUBSEP 1]) continue
      SC[t] = SC[t] "," "\"" nm "\""
      SV[t] = SV[t] (SV[t] == "" ? "" : ",") cv[t, i]
    }
  }

  # assignid(t, row) — the id this row gets in the REBUILT database.
  #
  # Replay starts from an empty database (rebuild moves the old one aside and re-applies
  # the schema), so this bookkeeping is the whole truth about which ids are taken. Rows
  # sharing an identity share an id — a review_finding filed and later re-dispositioned
  # is ONE row, and the later line replaces the earlier one. Rows with DIFFERENT
  # identities never share an id: the first claims the id the journal names, and every
  # later claimant is moved to a fresh one instead of overwriting its predecessor. That
  # is the whole fix for two machines both allocating work_log id 1.
  function assignid(t, row,   k, jid, nid) {
    k = jident(t, row, "replay")
    if (k in RID) return RID[k]
    jid = jfield(row, pkname[t SUBSEP 1])
    if (jid ~ /^"[0-9]+"$/) jid = substr(jid, 2, length(jid) - 2)
    nid = ""
    if (jid ~ /^[0-9]+$/ && !((t, jid + 0) in RUSED)) nid = jid + 0
    if (nid == "") nid = RMAX[t] + 1
    RUSED[t, nid] = 1
    if (nid > RMAX[t] + 0) RMAX[t] = nid
    RID[k] = nid
    return nid
  }

  # ---- pass 1: column metadata ----
  FILENAME == META {
    jmeta($0)
    if ($1 != "C" || NF < 5) next
    t = $2; name = $3; notnull = $4; pk = $5 + 0
    dflt = ""
    if (NF >= 6) { dflt = $6; for (i = 7; i <= NF; i++) dflt = dflt " " $i }
    known[t] = 1
    cols[t] = cols[t] (cols[t] == "" ? "" : ",") "\"" name "\""
    e = "json_extract(j," SQ "$." name SQ ")"
    # A NOT NULL column absent from an older journal line falls back to its declared
    # default, so adding a column with a default does not invalidate the journal.
    if (notnull == "1" && dflt != "") e = "COALESCE(" e "," dflt ")"
    vals[t] = vals[t] (vals[t] == "" ? "" : ",") e
    nc[t]++; cn[t, nc[t]] = name; cv[t, nc[t]] = e
    if (pk > 0) {
      pkname[t SUBSEP pk] = name
      if (pk > npk[t]) npk[t] = pk
    }
    next
  }

  # ---- pass 2: the journal ----
  {
    line = $0
    sub(/[ \t\r]+$/, "", line)
    if (line == "") next
    if (!jparse(line)) { bad++; next }

    tb = J_table
    if (J_op != "upsert" && J_op != "delete") { bad++; next }
    if (!(tb in known)) {
      if (!(tb in warned)) {
        warned[tb] = 1
        print "guild: warning — journal table " tb " is not in the current schema; skipping its entries" > "/dev/stderr"
      }
      skipped++; next
    }

    # The row is a JSON object out of an NDJSON line, so it is single-line by
    # construction (journal_append refuses one that is not). That is what makes a
    # quoted literal safe HERE where §2.2.1 forbids it elsewhere: the splitter's trap
    # is a `;` at END OF LINE inside an open literal, and this literal has no line to
    # end. Quotes are doubled exactly as sql_str does it.
    esc = J_row
    gsub(SQ, SQ SQ, esc)

    if (issurro(tb)) {
      surrocols(tb)
      if (J_op == "upsert") {
        emit("INSERT OR REPLACE INTO \"" tb "\" (" SC[tb] ") SELECT " assignid(tb, J_row) \
             "," SV[tb] " FROM (SELECT " SQ esc SQ " AS j);")
        applied++
      } else {
        # A pure INSERT-only table has no meaningful delete-by-content: its identities
        # are occurrence-numbered, so asking for "the" row would allocate a new ordinal
        # rather than name an existing row. Nothing emits such a delete; skip it loudly
        # in the stats rather than guessing.
        if (M_pure[tb]) { skipped++; next }
        k = jident(tb, J_row, "replay")
        if (!(k in RID)) { skipped++; next }
        emit("DELETE FROM \"" tb "\" WHERE \"" pkname[tb SUBSEP 1] "\" = " RID[k] ";")
        delete RID[k]
        applied++
      }
      next
    }

    if (J_op == "upsert") {
      emit("INSERT OR REPLACE INTO \"" tb "\" (" cols[tb] ") SELECT " vals[tb] \
           " FROM (SELECT " SQ esc SQ " AS j);")
      applied++
    } else {
      if (npk[tb] + 0 == 0) { skipped++; next }
      w = ""
      for (i = 1; i <= npk[tb]; i++) {
        nm = pkname[tb SUBSEP i]
        w = w (w == "" ? "" : " AND ") "\"" nm "\" = json_extract(" SQ esc SQ "," SQ "$." nm SQ ")"
      }
      emit("DELETE FROM \"" tb "\" WHERE " w ";")
      applied++
    }
  }

  END {
    flushchunk()
    print applied + 0, skipped + 0, bad + 0 > (OUTDIR "/stats")
  }
AWKREPLAY

  LC_ALL=C awk -v META="$meta" -v OUTDIR="$tmp" -v SQ="'" \
      -v MAXSTMT="$maxstmt" -v MAXBYTE="$maxbyte" \
      -f "$tmp/lib.awk" -f "$tmp/replay.awk" "$meta" "$f"

  for c in "$tmp"/chunk.*.sql; do
    [ -f "$c" ] || continue
    # >/dev/null would send tursodb's own diagnostics there too, so capture instead:
    # a replay that fails must say WHY, not just which chunk.
    if ! out="$(db_exec <"$c")"; then
      db_fail "journal replay failed on $c (generated SQL kept there for inspection)" "$out"
    fi
  done

  applied=0; skipped=0; bad=0
  stats="$tmp/stats"
  if [ -f "$stats" ]; then
    read -r applied skipped bad <"$stats" || true
  fi
  rm -rf "$tmp"

  printf 'Replayed %s entries from %s (%s skipped, %s unparseable)\n' \
    "${applied:-0}" "$f" "${skipped:-0}" "${bad:-0}"
}

# ---- compact ---------------------------------------------------------------------

# _journal_lost_identities <journal> <candidate> <meta> <lib.awk> — which rows the
# EXISTING journal describes that the CANDIDATE baseline would not carry.
#
# THIS IS THE GUARD, AND IT COMPARES LIKE WITH LIKE. The previous version compared two
# row COUNTS: identities the journal describes, against every live row in the database.
# Those are different universes. `event` rows and the guild_state / schema_version seeds
# are in the database and are not journaled at write time, so the live count runs ahead
# of the implied count by a slack that grows with every command — and inside that slack
# a real loss hides:
#
#   4 requirements of mine (+ 4 unjournaled event rows), 8 requirements in a pulled
#   journal -> 10 candidate rows vs 8 implied -> "no shrink", compact, teammate's four
#   requirements deleted from the one artifact git carries. Exit 0.
#
# Counting cannot see that, because the missing rows and the extra rows are different
# rows. So nothing is counted: an upsert adds a (table, identity) pair, a delete removes
# it, and the answer is the pairs the journal still has that the candidate does not.
# EXTRA rows in the candidate are fine and expected — that is what a snapshot is for.
# MISSING ones are the loss, and they are now named rather than inferred.
#
# Identity is jident(): the primary key for an ordinary table, the immutable content for
# a surrogate-key one. That second case matters here too — replay may legitimately
# renumber a work_log row, and a guard keyed on the integer id would then refuse a
# perfectly good compaction forever.
#
# Entries whose table is gone from the schema are excluded, because compaction cannot
# reproduce them either — comparing against them would refuse forever.
#
# IT ALSO COUNTS WHAT IT COULD NOT READ, and that count is as important as the first
# one. A line this parser rejects contributes NO identity, so a journal it cannot read at
# all yields `lost = 0` — "nothing would be lost" — and compaction proceeds to overwrite
# the file. That is not a hypothetical: a CRLF checkout of a journal describing three
# requirements compacted to a two-line baseline at exit 0, with a cheerful message. So
# unreadable lines are reported separately and journal_compact refuses on them.
#
# Prints "<lost> <unreadable>" on line 1, then up to 8 lost identities, one per line.
_journal_lost_identities() {
  local jf="$1" cand="$2" meta="$3" lib="$4" prog
  prog="$(dirname "$lib")/lost.awk"
  cat >"$prog" <<'AWKLOST'
  FILENAME == META { jmeta($0); next }

  FILENAME == JF {
    if (!jparse($0)) {
      line = $0
      sub(/[ \t\r]+$/, "", line)
      if (line != "") unread++
      next
    }
    if (!(J_table in M_known)) next
    k = jident(J_table, J_row, "journal")
    if (k == "") next
    if (J_op == "upsert") { live[k] = 1; label[k] = J_table " " jfield(J_row, M_pk[J_table, 1]) }
    else if (J_op == "delete") delete live[k]
    next
  }

  # the candidate baseline — journal lines too, so the same parser reads them
  {
    if (!jparse($0)) next
    if (!(J_table in M_known)) next
    k = jident(J_table, J_row, "candidate")
    if (k != "") have[k] = 1
  }

  END {
    n = 0
    for (k in live) {
      if (k in have) continue
      n++
      if (n <= 8) ex[n] = label[k]
    }
    print n " " unread + 0
    for (i = 1; i <= n && i <= 8; i++) print ex[i]
  }
AWKLOST
  LC_ALL=C awk -v META="$meta" -v JF="$jf" -f "$lib" -f "$prog" "$meta" "$jf" "$cand"
}

# _journal_reject_candidate <candidate> — park a refused baseline where the operator can
# look at it, and echo the path (or an explanation of why there is none).
#
# ONE FIXED PATH, never a timestamped backup directory: a refusal must not claim a
# `backup-<ts>/` name, or repeated refusals litter the guild root with directories that
# hold nothing but a rejected guess.
_journal_reject_candidate() {
  local cand="$1" bak
  bak="${GUILD_DIR:-.guild}/backup-rejected"
  if mkdir -p "$bak" 2>/dev/null && cp "$cand" "$bak/journal.candidate" 2>/dev/null; then
    printf '%s\n' "$bak/journal.candidate"
  else
    printf '%s\n' "(the candidate could not be saved — $bak is not writable)"
  fi
}

# journal_compact [--force] — snapshot current database state as a new baseline journal.
#
# One upsert line per live row across all tables, re-sequenced from 1. Rows are
# rendered by SQLite's json_object() rather than by parsing pipe-separated output:
# a task body full of markdown pipes and newlines would shred a list-mode parser,
# while json_object emits exactly one line per row with every control character
# already escaped — and it preserves column types, which the replay depends on.
#
# COMPACTION IS THE ONLY DESTRUCTIVE OPERATION IN THIS CLI. It replaces the single
# artifact git carries with a snapshot of whatever database happens to be present, and
# `guild.db` is gitignored — so on a fresh clone the database is EMPTY, and the naive
# version of this function would cheerfully write a two-line baseline over the entire
# project history and hand it to the user to commit. (Reproduced: clone, `guild init`,
# `guild journal compact` → "Compacted to 2 baseline entries", everything gone.) A row
# count > 0 does not catch it either, because schema.sql always seeds guild_state and
# schema_version.
#
# So: every row identity the existing journal describes must still be present in the
# candidate baseline, or compaction is refused unless --force. And the previous journal
# is copied into a fresh `.guild/backup-*/` directory (already gitignored) before the
# swap, every time — which is also where the candidate is staged, so the mv is
# same-filesystem and atomic and no stray temp file is left beside the journal for git
# to pick up. A REFUSED compaction claims no timestamped backup directory at all: it
# leaves its candidate at the single fixed path `.guild/backup-rejected/`, overwritten
# on the next attempt, so repeated refusals cannot litter the guild root.
journal_compact() {
  local f force tmpd bak meta ts actor sql count lost unread examples out
  force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force | -f) force=1; shift ;;
      *) die "guild: journal compact: unknown option '$1' (--force)" ;;
    esac
  done

  f="$(journal_path)"
  [ -d "$(dirname "$f")" ] || die "guild: no guild directory at $(dirname "$f")"

  # Compaction REPLACES the artifact git carries. Serialize it against every other guild
  # process for the whole read-compare-install, held to process exit.
  _journal_lock

  if [ -s "$(journal_pending_path)" ]; then
    die "guild: there are quarantined journal entries at $(journal_pending_path).
Compacting now would drop them from the comparison and could shrink the journal past
real work. Run 'guild journal recover' first."
  fi

  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/guild-compact.XXXXXX")" \
    || die "guild: could not create a temporary directory"

  _journal_live_tables >"$tmpd/raw-tables" \
    || { rm -rf "$tmpd"; die "guild: could not list tables; is the database initialized?"; }
  LC_ALL=C awk '/^[A-Za-z_][A-Za-z0-9_]*$/ { print }' "$tmpd/raw-tables" \
    | sort -u >"$tmpd/tables"
  [ -s "$tmpd/tables" ] || { rm -rf "$tmpd"; die "guild: no tables found — run 'guild init' first"; }

  meta="$tmpd/meta"
  _journal_table_meta "$tmpd/tables" >"$meta"

  # Build one SELECT per table: '<table>|<json row>'. The table name is prefixed
  # explicitly (rather than relying on the driver's column separator) and split on
  # its FIRST pipe, so pipes inside the JSON are harmless.
  sql="$(LC_ALL=C awk -v SQ="'" '
    $1 == "C" && NF >= 5 {
      t = $2; name = $3; pk = $5 + 0
      if (!(t in seen)) { seen[t] = 1; order[++nt] = t }
      obj[t] = obj[t] (obj[t] == "" ? "" : ",") SQ name SQ ",\"" name "\""
      if (pk > 0) {
        pkname[t SUBSEP pk] = name
        if (pk > npk[t]) npk[t] = pk
      }
    }
    END {
      for (i = 1; i <= nt; i++) {
        t = order[i]
        ob = ""
        if (npk[t] + 0 > 0) {
          for (k = 1; k <= npk[t]; k++) ob = ob (ob == "" ? " ORDER BY " : ",") "\"" pkname[t SUBSEP k] "\""
        }
        print "SELECT " SQ t "|" SQ " || json_object(" obj[t] ") FROM \"" t "\"" ob ";"
      }
    }
  ' "$meta")"

  if [ -z "$sql" ]; then
    rm -rf "$tmpd"
    die "guild: could not read table metadata; is the database initialized?"
  fi

  # Same staging rule as the metadata read: a failing db_exec must not be masked by a
  # downstream awk that happily produces an empty snapshot.
  if ! printf '%s\n' "$sql" | db_exec >"$tmpd/rows"; then
    out="$(cat "$tmpd/rows" 2>/dev/null || true)"
    rm -rf "$tmpd"
    db_fail "could not read the database; journal left unchanged" "$out"
  fi

  ts="$(_journal_now)"
  actor="${GUILD_ACTOR:-compact}"

  # The candidate is staged in the temp directory, NOT in a backup directory: a backup
  # directory is only claimed once this is going to be installed, so a refusal leaves
  # nothing behind to accumulate.
  LC_ALL=C awk -v TS="$ts" -v ACTOR="$(json_escape "$actor")" '
    {
      p = index($0, "|")
      if (p < 2) next
      t = substr($0, 1, p - 1)
      row = substr($0, p + 1)
      if (t !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next
      if (substr(row, 1, 1) != "{") next          # ignore banners and blank lines
      if (substr(row, length(row), 1) != "}") next
      seq++
      printf "{\"seq\":%d,\"ts\":\"%s\",\"actor\":\"%s\",\"op\":\"upsert\",\"table\":\"%s\",\"row\":%s}\n", \
        seq, TS, ACTOR, t, row
    }
  ' "$tmpd/rows" >"$tmpd/journal.candidate" \
    || { rm -rf "$tmpd"; die "guild: compaction failed; journal left unchanged"; }

  count="$(LC_ALL=C awk 'END { print NR + 0 }' "$tmpd/journal.candidate")"

  # ---- the guard: every identity the journal describes must survive ----
  lost=0
  unread=0
  examples=""
  if [ -s "$f" ]; then
    _journal_awk_lib_file "$tmpd/lib.awk"
    _journal_lost_identities "$f" "$tmpd/journal.candidate" "$meta" "$tmpd/lib.awk" \
      >"$tmpd/lost" \
      || { rm -rf "$tmpd"; die "guild: could not compare the candidate baseline against $f; journal left unchanged"; }
    lost="$(LC_ALL=C awk 'NR == 1 { print $1 + 0; exit }' "$tmpd/lost")"
    unread="$(LC_ALL=C awk 'NR == 1 { print $2 + 0; exit }' "$tmpd/lost")"
    case "$lost" in ''|*[!0-9]*) lost=0 ;; esac
    case "$unread" in ''|*[!0-9]*) unread=0 ;; esac
    examples="$(LC_ALL=C awk 'NR > 1 { print "    " $0 }' "$tmpd/lost")"
  fi

  # UNREADABLE LINES ARE A REFUSAL, NOT A ZERO. A line the parser rejects describes no
  # identity, so it cannot appear in `lost` — which means a journal that is entirely
  # unreadable scores a perfect zero and used to be overwritten at exit 0. "I could not
  # read it" is not "there was nothing there", and this is the one operation where the
  # difference is the whole project history.
  if [ "$force" = "0" ] && [ "$unread" -gt 0 ]; then
    out="$(_journal_reject_candidate "$tmpd/journal.candidate")"
    rm -rf "$tmpd"
    die "guild: refusing to compact — $unread line(s) of $f are not journal entries this
parser can read.

The journal is UNCHANGED. Compaction replaces it with a snapshot of the database, and
this check exists to prove nothing the journal describes is dropped by that swap. A line
it cannot read describes nothing, so it cannot be checked — proceeding would overwrite
history the guard never got to look at.

The usual cause is line endings. Check:

  file $f
  head -n 1 $f | od -c | tail -n 2

  · CRLF (\\r\\n) means the file was checked out with core.autocrlf=true or a
    '* text=auto' rule. Fix it for good with a .gitattributes at the repo root:

      echo 'journal.ndjson -text' >> .gitattributes
      git rm --cached $f && git checkout -- $f

  · a git merge can also leave conflict markers (<<<<<<< / ======= / >>>>>>>) in it.
    Resolve them, keeping BOTH sides' entries — journal entries are idempotent on
    replay, so keeping too many costs nothing and keeping too few costs work.

The rejected candidate is kept for inspection at
  $out
and 'guild journal compact --force' overrides this check."
  fi

  if [ "$force" = "0" ] && [ "$lost" -gt 0 ]; then
    out="$(_journal_reject_candidate "$tmpd/journal.candidate")"
    rm -rf "$tmpd"
    die "guild: refusing to compact — the snapshot would LOSE data.

  $lost row(s) the journal describes are NOT in the database:

$examples

  the database holds      $count row(s)

The journal is what git carries; the database is derived state and is gitignored. Rows
the journal has and the database does not mean it is empty, partially applied, or simply
not the one this journal describes — a fresh clone before 'guild rebuild', or a pulled
journal carrying a teammate's work, are the usual causes. Compacting would write this
snapshot over that history.

  1. run 'guild rebuild' to replay the journal into the database
  2. then compact

The rejected candidate is kept for inspection at
  $out
and 'guild journal compact --force' overrides this check."
  fi

  # Only now is a backup directory claimed, and the previous journal MUST land in it: a
  # failed copy used to be swallowed and replaced with an empty file, which turned
  # "the previous journal is always kept" into a message rather than a fact.
  bak="$(_journal_backup_dir)"
  if [ -e "$f" ]; then
    cp "$f" "$bak/journal.ndjson" \
      || { rm -rf "$tmpd"; die "guild: could not copy the existing journal to $bak/journal.ndjson — refusing to replace a journal we cannot back up. Nothing was changed."; }
  else
    : >"$bak/journal.ndjson"
  fi

  # Staged inside .guild so the install is a same-filesystem (atomic) rename; $tmpd may
  # be on another volume, where mv is copy-then-unlink and a crash truncates the journal.
  cp "$tmpd/journal.candidate" "$bak/journal.candidate" \
    || { rm -rf "$tmpd"; die "guild: could not stage the compacted journal in $bak (nothing was changed; $f is intact)"; }
  mv "$bak/journal.candidate" "$f" \
    || { rm -rf "$tmpd"; die "guild: could not install the compacted journal (the previous one is intact at $f, and copied to $bak)"; }
  rm -rf "$tmpd"

  printf 'Compacted %s to %s baseline entries (previous journal kept at %s)\n' \
    "$f" "$count" "$bak/journal.ndjson"
}
