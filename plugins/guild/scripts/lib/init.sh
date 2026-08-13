# shellcheck shell=bash
#
# lib/init.sh — `guild init`, v4 archival, evergreen carry-over, and the two journal
# wrappers (design doc §2.1 config, §2.3 journal, §11 migration).
#
# FUNCTIONS ONLY. No top-level side effects, no `set -e` — scripts/guild owns those.
# Sourced by scripts/guild after lib/db.sh and lib/journal.sh.
#
# Bash 3.2 compatible: indexed arrays only (no `declare -A`), no `mapfile`,
# no `${var^^}`, no `nextfile`.
#
# ---------------------------------------------------------------------------------
# SAFETY CONTRACT — this code runs against a user's real project state.
#
#   * NOTHING here deletes user data. The only `rm` calls target temporary
#     directories this file created with `mktemp -d`.
#   * Archival is a `mv` into `.guild/v4-archive/`, never a delete. If that directory
#     already exists, a fresh timestamped one is used rather than merging into it, so
#     an interrupted first run can never be overwritten by a second.
#   * Files are only ever written when they do not already exist (config.yaml,
#     .gitignore, journal.ndjson). An existing file is left exactly as it is.
#   * Archival is REFUSED unless $GUILD_DIR genuinely looks like a v4 guild root
#     (_init_v4_evidence), and the exact list of entries is printed first — with a
#     confirmation prompt when stdin is a terminal. `GUILD_DIR=. guild init` used to
#     restructure a whole repository on the strength of a directory called `plans`.
#   * Carry-over rows are inserted with `WHERE NOT EXISTS`, so a re-run can never
#     overwrite a doc or coverage row the guild has since edited. The guard is the
#     ROW's existence, so a lost database re-imports; it is not a "have we done this
#     before" flag, which would be answered from the gitignored database.
#   * A mode switch on an already-initialized guild is refused, not performed.
#   * `--url-env` / `--token-env` must be environment variable NAMES. A value that
#     looks like a URL or a token is refused BEFORE any file is written, and is never
#     echoed back — config.yaml is committed to git and must never hold a credential.
#   * Cloud mode is refused outright: it is not verified (lib/db.sh).
#
# ---------------------------------------------------------------------------------
# ROUND-TRIP BUDGET (§2.2: one db_exec per logical command, never in a loop).
#
# `guild init` has two genuine database phases and makes exactly two calls:
#
#   1. db_apply_schema     — the DDL, one invocation.
#   2. one composed script — last-checkin, every carried-over doc row, every
#                            carried-over coverage row, the carry-over marker, and
#                            the read-back SELECTs. One invocation.
#
# That is why carry_over_docs / carry_over_qa EMIT SQL on stdout instead of running
# it: cmd_init concatenates both into a single script. They also record what they
# emitted in shell arrays, so the journal lines can be written afterwards without a
# second read of the database.
# ---------------------------------------------------------------------------------

# ---- v4 layout -------------------------------------------------------------------

# _init_v4_entries — the complete set of names `guild init` will move into the
# archive. An ALLOWLIST on purpose: a denylist would sweep up v5 files (config.yaml,
# guild.db, journal.ndjson, spool/, export/) the first time someone adds a new one.
#
# A function rather than a constant because lib modules define functions only — a
# top-level assignment is a side effect of sourcing. One name per line, so the caller
# iterates without relying on word splitting.
_init_v4_entries() {
  printf '%s\n' requirements tasks plans reviews archive docs qa state.yaml BOARD.md
}

# _init_has_v4 — does this guild root hold a v4 board? Any of the three status-
# directory trees, or the pre-3.0 BOARD.md, is the signal (§11 step 1).
#
# This is the TRIGGER, not the authorization. `requirements/`, `tasks/`, `plans/` and
# `docs/` are ordinary directory names; a repository can hold them for reasons that have
# nothing to do with the guild. _init_v4_evidence below decides whether the trigger is
# allowed to move anything.
_init_has_v4() {
  local d
  for d in requirements tasks plans; do
    if [ -d "$GUILD_DIR/$d" ]; then return 0; fi
  done
  if [ -f "$GUILD_DIR/BOARD.md" ]; then return 0; fi
  return 1
}

# _init_guild_dir_abs — the absolute path of $GUILD_DIR, so the basename test below is
# meaningful for `GUILD_DIR=.` and `GUILD_DIR=../thing/.guild` alike. Falls back to the
# literal value when the directory does not exist yet (nothing to archive in that case).
_init_guild_dir_abs() {
  local d=""
  if [ -d "$GUILD_DIR" ]; then
    d="$(cd "$GUILD_DIR" 2>/dev/null && pwd)" || d=""
  fi
  printf '%s' "${d:-$GUILD_DIR}"
}

# _init_v4_evidence — echo `strong` or `weak`: does $GUILD_DIR genuinely look like a v4
# GUILD ROOT, as opposed to an ordinary directory that happens to contain a `plans/`?
#
# THIS IS THE GUARD ON A MASS `mv` OF THE USER'S TREE. `GUILD_DIR` is a documented,
# supported environment variable, and archive_v4 moves nine top-level names. Pointed at
# a repository root — `GUILD_DIR=. guild init` — the old trigger-only test restructured
# the whole checkout on the strength of a directory called `plans`. Nothing was deleted,
# but nobody asked for it either.
#
# Strong evidence, any one of:
#   * the directory is named `.guild` — the conventional and default location, and the
#     only place `guild` itself ever puts a board;
#   * `state.yaml` or `BOARD.md` sits beside at least one status tree — v4 wrote both,
#     and neither name occurs next to `requirements/` by accident;
#   * a status SUBDIRECTORY exists (`requirements/todo`, `tasks/in-progress`, ...) —
#     that two-level shape is v4's layout and is what makes the tree a board rather
#     than a folder of markdown.
#
# Anything else is weak, and cmd_init refuses rather than moving anything.
_init_v4_evidence() {
  local base d s trees
  base="$(basename "$(_init_guild_dir_abs)")"
  if [ "$base" = ".guild" ]; then printf 'strong'; return 0; fi

  trees=0
  for d in requirements tasks plans; do
    if [ -d "$GUILD_DIR/$d" ]; then trees=$((trees + 1)); fi
  done

  if [ "$trees" -gt 0 ]; then
    if [ -f "$GUILD_DIR/state.yaml" ] || [ -f "$GUILD_DIR/BOARD.md" ]; then
      printf 'strong'
      return 0
    fi
  fi

  for d in requirements tasks plans; do
    for s in todo in-progress 'done' failed; do
      if [ -d "$GUILD_DIR/$d/$s" ]; then printf 'strong'; return 0; fi
    done
  done

  printf 'weak'
}

# _init_v4_present — the v4 names actually present in $GUILD_DIR, space separated. Used
# by the refusal message so the user can see exactly what triggered it.
_init_v4_present() {
  local entry out=""
  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -n "$entry" ] || continue
    if [ -e "$GUILD_DIR/$entry" ]; then out="$out $entry"; fi
  done <<ENTRIES
$(_init_v4_entries)
ENTRIES
  printf '%s' "${out# }"
}

# _init_confirm_archive — print exactly what archive_v4 is about to move, and when stdin
# is a terminal, require a yes. v4's migration asked first (through the check-in skill);
# v5's `is-legacy` always answers "no", so this is now the only place a human is asked.
# Non-interactive callers (every agent) proceed, but the list is printed either way, so
# the move is never invisible.
_init_confirm_archive() {
  local reply
  printf 'A v4 board is present at %s. This init will MOVE these into %s/v4-archive/:\n' \
    "$GUILD_DIR" "$GUILD_DIR"
  printf '  %s\n' "$(_init_v4_present)"
  printf 'They are moved, never deleted, and stay readable as plain markdown.\n'
  if [ -t 0 ] && [ "${GUILD_ASSUME_YES:-0}" != 1 ]; then
    printf 'Archive them now? [y/N] '
    IFS= read -r reply || reply=""
    case "$reply" in
      y | Y | yes | Yes | YES) return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# ---- small helpers ---------------------------------------------------------------

# _init_slug <text> — a stable lowercase identifier for a quality area or a doc.
# Non-alphanumerics collapse to single dashes; the result is trimmed and capped, so a
# 90-character table cell cannot become a 90-character primary key.
_init_slug() {
  printf '%s' "${1-}" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//' \
    | LC_ALL=C cut -c1-60 \
    | LC_ALL=C sed -e 's/-*$//'
}

# _init_read_body <varname> <file> — assign the file's contents, VERBATIM, to the
# named variable. Trailing newlines included.
#
# This is a two-argument out-parameter rather than the obvious `body="$(slurp f)"`
# because command substitution strips trailing newlines, and it does so at the CALL
# SITE — a slurp helper that is itself perfectly correct still loses them the moment
# someone wraps it in `$( )`. Doing the assignment here with `printf -v` means there
# is no `$( )` to strip anything, and "body verbatim" (§11) actually holds. The `x`
# sentinel protects the one inner substitution that remains.
_init_read_body() {
  local _v
  _v="$(cat "$2"; printf 'x')"
  printf -v "$1" '%s' "${_v%x}"
}

# _init_first_heading <file> — the text of the first ATX heading, or empty.
_init_first_heading() {
  LC_ALL=C awk '
    /^[ \t]*#+[ \t]+/ {
      line = $0
      sub(/^[ \t]*#+[ \t]+/, "", line)
      sub(/[ \t]*#+[ \t]*$/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line != "") { print line; exit }
    }
  ' "$1"
}

# _init_seen <list> <slug> — is <slug> in the `|a|b|`-delimited list? Bash 3.2 has no
# associative arrays; this is the dedupe mechanism.
_init_seen() {
  case "$1" in
    *"|$2|"*) return 0 ;;
  esac
  return 1
}

# _init_risk <v4-risk> — map a v4 charter risk word onto the `coverage.risk` domain
# (high | medium | low). v4's `critical` has no v5 equivalent, so it becomes `high`
# and the original word is preserved in `notes` rather than being silently lost.
_init_risk() {
  case "$(printf '%s' "${1-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')" in
    critical|high) printf 'high' ;;
    low|smoke)     printf 'low' ;;
    *)             printf 'medium' ;;
  esac
}

# ---- archival (§11) --------------------------------------------------------------

# archive_v4 — move the entire existing v4 tree into `.guild/v4-archive/`, untouched.
#
# NEVER deletes. NEVER parses. Per §11 there is no history import: old requirements,
# plans, tasks, work logs and reviews stay readable as plain markdown forever — they
# just stop being queryable.
#
# Sets, for the caller's summary:
#   GUILD_V4_ARCHIVE_DIR  the directory everything moved into ('' if nothing moved)
#   GUILD_V4_ARCHIVED     space-separated names that were moved
archive_v4() {
  local dest entry src

  guild_root >/dev/null
  GUILD_V4_ARCHIVE_DIR=""
  GUILD_V4_ARCHIVED=""

  # An existing archive is never merged into — that is exactly how a second run could
  # clobber the first run's copy of a file. Take a fresh, timestamped directory.
  dest="$GUILD_DIR/v4-archive"
  if [ -e "$dest" ]; then
    dest="$GUILD_DIR/v4-archive-$(date -u +%Y%m%dT%H%M%SZ)"
    if [ -e "$dest" ]; then
      die "guild: archive destination $dest already exists; refusing to overwrite it"
    fi
  fi

  # A here-doc rather than `for entry in $(...)`: the loop must run in THIS shell so
  # GUILD_V4_ARCHIVED survives it, and reading lines does not depend on word splitting.
  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -n "$entry" ] || continue
    src="$GUILD_DIR/$entry"
    [ -e "$src" ] || continue
    if [ ! -d "$dest" ]; then
      mkdir -p "$dest" || die "guild: cannot create $dest"
    fi
    if [ -e "$dest/$entry" ]; then
      die "guild: $dest/$entry already exists; refusing to overwrite it"
    fi
    mv "$src" "$dest/$entry" || die "guild: could not archive $src to $dest/$entry"
    GUILD_V4_ARCHIVED="$GUILD_V4_ARCHIVED $entry"
  done <<ENTRIES
$(_init_v4_entries)
ENTRIES

  GUILD_V4_ARCHIVED="${GUILD_V4_ARCHIVED# }"
  if [ -n "$GUILD_V4_ARCHIVED" ]; then
    GUILD_V4_ARCHIVE_DIR="$dest"
  fi
  return 0
}

# _init_dir_has_content <dir> — does <dir> exist AND hold at least one entry? An empty
# directory is not a source: `guild init` now RE-CREATES docs/, qa/ and reviews/ after
# archiving them, so "the directory exists" stopped meaning "there is something in it".
_init_dir_has_content() {
  local d="${1-}" e
  [ -n "$d" ] && [ -d "$d" ] || return 1
  for e in "$d"/* "$d"/.[!.]*; do
    if [ -e "$e" ]; then return 0; fi
  done
  return 1
}

# _init_carry_src <name> — where to read an evergreen v4 directory from. Empty if there
# is nowhere to read it from.
#
# RESUMABILITY (this is the fix for "init is idempotent but not resumable"). The search
# order matters because the database is gitignored and the archive is not:
#
#   1. the archive THIS run just created — the normal first-init path;
#   2. $GUILD_DIR/<name> — a v5 guild where someone simply dropped files in, or a v4
#      board that has not been archived yet;
#   3. any EARLIER archive, $GUILD_DIR/v4-archive*/<name>.
#
# Step 3 is the one that was missing. After a successful first init the content lives at
# .guild/v4-archive/docs, `_init_has_v4` is false, and the "already carried over" marker
# lives in guild.db — which git does not carry. So on a fresh clone, or after the
# database is lost, init used to look in two places that no longer hold anything and
# report "no .guild/docs or .guild/qa content was found" while it sat in the archive.
#
# Oldest archive first: plain `v4-archive` is the original board; `v4-archive-<ts>` came
# from a later run, and the ISO timestamps sort chronologically.
_init_carry_src() {
  local n="$1" c
  if [ -n "${GUILD_V4_ARCHIVE_DIR:-}" ] && _init_dir_has_content "$GUILD_V4_ARCHIVE_DIR/$n"; then
    printf '%s' "$GUILD_V4_ARCHIVE_DIR/$n"
    return 0
  fi
  if _init_dir_has_content "$GUILD_DIR/$n"; then
    printf '%s' "$GUILD_DIR/$n"
    return 0
  fi
  for c in "$GUILD_DIR"/v4-archive "$GUILD_DIR"/v4-archive-*; do
    if _init_dir_has_content "$c/$n"; then
      printf '%s' "$c/$n"
      return 0
    fi
  done
  return 0
}

# ---- carry-over: docs (§11) ------------------------------------------------------

# carry_over_docs [SRC_DIR] — `.guild/docs/*.md` -> the `doc` table.
#
#   slug   the filename without its .md extension, slugified
#   title  the first heading in the file, falling back to the filename
#   body   the file verbatim
#   source the path it came from, so provenance survives
#
# EMITS SQL ON STDOUT (see the round-trip budget above) and records what it emitted in
# GUILD_DOC_SLUG / _TITLE / _PATH / _SOURCE for the journal pass. Returns 1 with no
# output when there is nothing to carry.
#
# TWO FILES CAN SLUGIFY TO THE SAME KEY — `Form Actions.md` and `form-actions.md` both
# become `form-actions` — and that used to make `guild rebuild` CHANGE the knowledge
# base. The INSERT is guarded on the slug, so the DATABASE kept the first file's body;
# the journal pass wrote one line per FILE, and replay is INSERT OR REPLACE, so the
# JOURNAL yielded the last. A recovery run silently rewrote a researcher's document.
# The `seen` list below is the same dedupe carry_over_qa already used: the first file
# wins in both places, and the loser is named on stderr rather than dropped quietly.
# It is still sitting in the archive, unmodified.
#
# The row-existence guard is the ONLY guard on the INSERT. It used to also require the
# `v4-carryover` marker to be absent, which asked "have we ever carried over?" — a
# question answered from the gitignored database. After a fresh clone the answer was
# wrong in the dangerous direction. `NOT EXISTS (SELECT 1 FROM doc WHERE slug = ...)`
# asks whether the data is actually there, which is the question that matters, and it
# still cannot overwrite a doc the guild has since edited.
#
# RETURNING reports the slugs this run really inserted, so the journal pass and the
# summary count rows EMITTED rather than files scanned. slug is [a-z0-9-] only, so it
# cannot forge a marker in the pipe-separated result stream.
#
# A FILE THAT IS NOT VALID UTF-8 IS SKIPPED, NOT FATAL — and that distinction is the
# whole reason this check is here rather than being left to sql_text. sql_text REFUSES a
# non-UTF-8 value (§2.2.1), correctly, because tursodb would silently replace the bytes
# with U+FFFD. But by the time carry-over runs, archive_v4 has ALREADY MOVED the v4 board
# into v4-archive/. A die here would abort init after the move, and every re-run would
# abort at the same file — a guild permanently un-initializable because one document was
# saved as latin-1. So the file is named on stderr, counted, and left exactly where it
# is; the other docs carry over normally and the skipped one can be re-encoded and picked
# up by a later `guild init`, which is resumable by design.
#
# ONE scan per file covers title and body both: the title is a heading taken out of the
# same bytes. The path is checked separately because it comes from the filesystem, not
# from the file.
carry_over_docs() {
  local src ts f base slug title body n seen

  src="${1-}"
  if [ -z "$src" ]; then src="$(_init_carry_src docs)"; fi
  GUILD_DOC_N=0
  GUILD_DOC_SKIPPED=0
  GUILD_DOC_SLUG=()
  GUILD_DOC_TITLE=()
  GUILD_DOC_PATH=()
  GUILD_DOC_SOURCE=()
  if [ -z "$src" ] || [ ! -d "$src" ]; then return 1; fi

  ts="${GUILD_CARRY_TS:-$(db_now)}"
  n=0
  seen="|"
  for f in "$src"/*.md; do
    [ -f "$f" ] || continue
    if ! utf8_valid_file "$f" || ! utf8_valid "$f"; then
      printf 'guild: skipping %s — not valid UTF-8, so it was not imported.\n' "$f" >&2
      printf 'guild: nothing was deleted; the file is still there. Re-encode it —\n' >&2
      printf "guild:   iconv -f latin1 -t utf8 '%s' > t && mv t '%s'\n" "$f" "$f" >&2
      printf "guild: — and re-run 'guild init'; the carry-over is resumable.\n" >&2
      GUILD_DOC_SKIPPED=$((GUILD_DOC_SKIPPED + 1))
      continue
    fi
    base="$(basename "$f" .md)"
    slug="$(_init_slug "$base")"
    [ -n "$slug" ] || continue
    if _init_seen "$seen" "$slug"; then
      printf 'guild: two v4 docs both slugify to %s; keeping the first and skipping %s\n' \
        "$slug" "$f" >&2
      printf 'guild: nothing was deleted — %s is still there, unmodified.\n' "$f" >&2
      continue
    fi
    seen="$seen$slug|"
    title="$(_init_first_heading "$f")"
    [ -n "$title" ] || title="$base"
    _init_read_body body "$f"

    GUILD_DOC_SLUG[n]="$slug"
    GUILD_DOC_TITLE[n]="$title"
    GUILD_DOC_PATH[n]="$f"
    GUILD_DOC_SOURCE[n]="$f"
    n=$((n + 1))

    # The doc BODY is a whole v4 markdown file — the single likeliest carrier of a fenced
    # code block, and therefore of a line ending in `;`. Before §2.2.1 that tore the init
    # script in half AFTER the v4 board had already been moved to v4-archive/, leaving the
    # guild permanently un-initializable. Title and source path are free text too (a
    # heading an author wrote, a filename on disk); only `slug` ([a-z0-9-], produced by
    # _init_slug) and the generated timestamp are known-safe.
    printf 'INSERT INTO doc (slug, title, body, source, updated_at)\n'
    printf 'SELECT %s, %s, %s, %s, %s\n' \
      "$(sql_str "$slug")" "$(sql_text "$title")" "$(sql_text "$body")" \
      "$(sql_text "$f")" "$(sql_str "$ts")"
    printf 'WHERE NOT EXISTS (SELECT 1 FROM doc WHERE slug = %s)\n' "$(sql_str "$slug")"
    printf "RETURNING 'DOCROW|' || slug;\n"
  done

  GUILD_DOC_N=$n
  if [ "$n" -gt 0 ]; then return 0; fi
  return 1
}

# ---- carry-over: qa (§11) --------------------------------------------------------

# _init_charter_rows <charter.md> <sep> — normalize the v4 charter's two tables into
#   risk SEP area SEP risk-word SEP notes
#   cov  SEP area SEP depth     SEP scenario-classes
# Header rows, separator rows and non-table lines are dropped.
_init_charter_rows() {
  LC_ALL=C awk -v SEP="$2" '
    function trim(s) {
      gsub(/\t/, " ", s)
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      return s
    }
    /^##[ \t]/ {
      h = trim(substr($0, 3))
      sec = (h == "Risk Map") ? "risk" : ((h == "Coverage Matrix") ? "cov" : "")
      next
    }
    sec == "" { next }
    /^[ \t]*\|/ {
      n = split($0, f, "|")
      if (n < 3) next
      a = trim(f[2])
      if (a == "") next
      if (tolower(a) == "area") next          # header row
      if (a ~ /^[-: ]+$/) next                # separator row
      if (sec == "risk")
        print "risk" SEP a SEP (n >= 5 ? trim(f[5]) : "") SEP (n >= 6 ? trim(f[6]) : "")
      else
        print "cov"  SEP a SEP (n >= 4 ? trim(f[4]) : "") SEP (n >= 3 ? trim(f[3]) : "")
    }
  ' "$1"
}

# _init_mission_rows <sep> <mission.md>... — the `area:` and `risk:` frontmatter of
# each v4 mission, as  area SEP risk. Missions declaring no area are skipped.
_init_mission_rows() {
  local sep="$1"
  shift
  LC_ALL=C awk -v SEP="$sep" '
    function trim(s) {
      gsub(/\t/, " ", s)
      sub(/^[ \t"'"'"']+/, "", s)
      sub(/[ \t"'"'"']+$/, "", s)
      return s
    }
    FNR == 1 { fm = 0; area = ""; risk = "" }
    /^---[ \t]*$/ {
      fm++
      if (fm == 2 && area != "") { print area SEP risk; area = "" }
      next
    }
    fm == 1 {
      if ($0 ~ /^area[ \t]*:/)      area = trim(substr($0, index($0, ":") + 1))
      else if ($0 ~ /^risk[ \t]*:/) risk = trim(substr($0, index($0, ":") + 1))
    }
  ' "$@"
}

# _init_spec_paths <regression.md> — the spec paths from the v4 regression manifest,
# one per line, with any `::test name` suffix removed.
_init_spec_paths() {
  LC_ALL=C awk '
    function trim(s) { sub(/^[ \t`]+/, "", s); sub(/[ \t`]+$/, "", s); return s }
    /^[ \t]*\|/ {
      n = split($0, f, "|")
      if (n < 3) next
      p = trim(f[2])
      if (p == "") next
      if (p ~ /^[-: ]+$/) next
      if (tolower(p) ~ /^spec/) next
      i = index(p, "::")
      if (i > 0) p = substr(p, 1, i - 1)
      p = trim(p)
      if (p != "") print p
    }
  ' "$1"
}

# _init_cov_scen <cov-file> <sep> <slug> — the Coverage Matrix depth and scenario
# classes for the area matching <slug>, or empty. Matching is containment either way,
# because the charter's two tables name the same areas with different wording
# ("Orchestrator chain dispatch" vs "Orchestrator chain dispatch (check-in work
# cycle)"). Used for enrichment only: a miss costs a sentence of notes, nothing more.
_init_cov_scen() {
  LC_ALL=C awk -F"$2" -v WANT="$3" '
    function slug(s) {
      s = tolower(s)
      gsub(/[^a-z0-9]+/, "-", s)
      sub(/^-+/, "", s)
      sub(/-+$/, "", s)
      return s
    }
    {
      s = slug($2)
      if (s == "" || WANT == "") next
      if (index(WANT, s) > 0 || index(s, WANT) > 0) {
        out = ""
        if ($3 != "") out = "depth: " $3 "."
        if ($4 != "") out = out (out == "" ? "" : " ") "scenarios: " $4
        if (out != "") print out
        exit
      }
    }
  ' "$1"
}

# carry_over_qa [SRC_DIR] — `.guild/qa/` -> the `coverage` table (§11).
#
# Each v4 quality AREA becomes one coverage row carrying its risk level and, when the
# regression manifest names a spec whose path contains the area's slug, that spec
# path. `last_inspected_at` is deliberately left NULL, so every area reads as due on
# day one. Past QA *sessions* are history: archive_v4 already moved them aside and
# they are NOT imported.
#
# ONE source of areas, chosen by availability — NOT a union:
#   1. charter.md `## Risk Map`        — area + risk + notes. The authoritative shape,
#                                        and the only v4 artifact that carries a risk
#                                        level per area, which is what §11 asks for.
#   2. charter.md `## Coverage Matrix` — only if there is no Risk Map. Risk defaults
#                                        to medium.
#   3. missions/MISSION-*.md           — only if the charter yielded nothing at all.
#
# Unioning them was the obvious first design and it is wrong: v4's charter restates
# the same areas in both tables and again in each mission's `area:`, with the wording
# drifting slightly each time, so a union turns 12 real quality areas into 27 near
# duplicates — and every duplicate then reads as its own un-inspected area forever.
# The Coverage Matrix is instead folded into the matching Risk Map row's notes.
#
# EMITS SQL ON STDOUT and records rows in GUILD_COV_*. Returns 1 when there is
# nothing to carry.
#
# Like carry_over_docs, the INSERT is guarded on the ROW's existence alone (not on the
# `v4-carryover` marker) so a lost database re-imports what is missing, and RETURNING
# names the ids actually inserted so the journal pass records exactly those.
carry_over_qa() {
  local src tmpd n kind area risk notes depth scen slug spec f m mrisk low extra
  local pick seen
  # Field separator for the awk -> shell streams below. A control character, not a
  # tab: with a whitespace IFS, `read` collapses runs of delimiters and drops leading
  # ones, which silently shifts every field after an empty table cell.
  local sep=$'\037'

  src="${1-}"
  if [ -z "$src" ]; then src="$(_init_carry_src qa)"; fi
  GUILD_COV_N=0
  GUILD_COV_SLUG=()
  GUILD_COV_AREA=()
  GUILD_COV_RISK=()
  GUILD_COV_SPEC=()
  GUILD_COV_NOTES=()
  GUILD_COV_SPECS_MATCHED=0
  GUILD_COV_SKIPPED=0
  if [ -z "$src" ] || [ ! -d "$src" ]; then return 1; fi

  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/guild-qa.XXXXXX")" \
    || die "guild: could not create a temporary directory"

  : >"$tmpd/rows"
  if [ -f "$src/charter.md" ]; then
    _init_charter_rows "$src/charter.md" "$sep" >"$tmpd/rows"
  fi
  LC_ALL=C awk -F"$sep" '$1 == "risk"' "$tmpd/rows" >"$tmpd/risk"
  LC_ALL=C awk -F"$sep" '$1 == "cov"'  "$tmpd/rows" >"$tmpd/cov"

  : >"$tmpd/missions"
  if [ -d "$src/missions" ]; then
    for f in "$src/missions"/*.md; do
      [ -f "$f" ] || continue
      _init_mission_rows "$sep" "$f" >>"$tmpd/missions"
    done
  fi

  : >"$tmpd/specs"
  if [ -f "$src/regression.md" ]; then
    _init_spec_paths "$src/regression.md" >"$tmpd/specs"
  fi

  n=0
  seen="|"

  if   [ -s "$tmpd/risk" ]; then pick=risk
  elif [ -s "$tmpd/cov"  ]; then pick=cov
  elif [ -s "$tmpd/missions" ]; then pick=mission
  else pick=none
  fi
  GUILD_COV_SOURCE="$pick"

  # ---- source 1: the Risk Map ----
  if [ "$pick" = risk ]; then
    while IFS="$sep" read -r kind area depth scen || [ -n "$kind" ]; do
      [ -n "$area" ] || continue
      slug="$(_init_slug "$area")"
      [ -n "$slug" ] || continue
      if _init_seen "$seen" "$slug"; then continue; fi
      seen="$seen$slug|"
      risk="$(_init_risk "$depth")"
      notes="$scen"
      low="$(printf '%s' "$depth" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      if [ "$low" = "critical" ]; then
        notes="${notes:+$notes }(v4 risk: critical)"
      fi
      extra="$(_init_cov_scen "$tmpd/cov" "$sep" "$slug")"
      if [ -n "$extra" ]; then notes="${notes:+$notes }$extra"; fi
      GUILD_COV_SLUG[n]="$slug"
      GUILD_COV_AREA[n]="$area"
      GUILD_COV_RISK[n]="$risk"
      GUILD_COV_NOTES[n]="$notes"
      GUILD_COV_SPEC[n]=""
      n=$((n + 1))
    done <"$tmpd/risk"
  fi

  # ---- source 2: the Coverage Matrix, only when there is no Risk Map ----
  if [ "$pick" = cov ]; then
    while IFS="$sep" read -r kind area depth scen || [ -n "$kind" ]; do
      [ -n "$area" ] || continue
      slug="$(_init_slug "$area")"
      [ -n "$slug" ] || continue
      if _init_seen "$seen" "$slug"; then continue; fi
      seen="$seen$slug|"
      GUILD_COV_SLUG[n]="$slug"
      GUILD_COV_AREA[n]="$area"
      GUILD_COV_RISK[n]='medium'
      GUILD_COV_NOTES[n]="${depth:+depth: $depth. }$scen"
      GUILD_COV_SPEC[n]=""
      n=$((n + 1))
    done <"$tmpd/cov"
  fi

  # ---- source 3: missions, only when the charter yielded nothing ----
  if [ "$pick" = mission ]; then
    while IFS="$sep" read -r area mrisk || [ -n "$area" ]; do
      [ -n "$area" ] || continue
      slug="$(_init_slug "$area")"
      [ -n "$slug" ] || continue
      if _init_seen "$seen" "$slug"; then continue; fi
      seen="$seen$slug|"
      GUILD_COV_SLUG[n]="$slug"
      GUILD_COV_AREA[n]="$area"
      GUILD_COV_RISK[n]="$(_init_risk "$mrisk")"
      GUILD_COV_NOTES[n]='carried over from a v4 QA mission'
      GUILD_COV_SPEC[n]=""
      n=$((n + 1))
    done <"$tmpd/missions"
  fi

  # ---- spec paths, matched by slug ----
  # The v4 regression manifest has no area column, so the only honest link between a
  # committed spec and a coverage area is the area's slug appearing in the spec path.
  # A miss leaves spec_path NULL, which is precisely what "no committed spec" means.
  if [ -s "$tmpd/specs" ]; then
    m=0
    while [ "$m" -lt "$n" ]; do
      spec="$(LC_ALL=C grep -iF -m1 -e "${GUILD_COV_SLUG[$m]}" "$tmpd/specs" 2>/dev/null || true)"
      if [ -n "$spec" ]; then
        GUILD_COV_SPEC[m]="$spec"
        GUILD_COV_SPECS_MATCHED=$((GUILD_COV_SPECS_MATCHED + 1))
      fi
      m=$((m + 1))
    done
  fi

  rm -rf "$tmpd"

  GUILD_COV_N=$n
  if [ "$n" -le 0 ]; then return 1; fi

  m=0
  while [ "$m" -lt "$n" ]; do
    # A latin-1 charter must not abort init either — same reasoning as carry_over_docs:
    # by now the v4 board has already been moved into v4-archive/. One scan per ROW, on
    # every free-text field at once. The fields are joined with NEWLINES, not
    # concatenated: 0x0A cannot appear inside a multi-byte sequence, so a truncated
    # sequence at the end of one field can never be completed by the start of the next
    # and read as valid. `slug` is _init_slug output ([a-z0-9-]) and needs no check.
    if ! utf8_valid "${GUILD_COV_AREA[$m]}
${GUILD_COV_RISK[$m]}
${GUILD_COV_NOTES[$m]}
${GUILD_COV_SPEC[$m]}"; then
      printf 'guild: skipping qa area %s — its v4 charter text is not valid UTF-8.\n' \
        "${GUILD_COV_SLUG[$m]}" >&2
      printf 'guild: nothing was deleted; re-encode the charter with\n' >&2
      printf "guild:   iconv -f latin1 -t utf8 — then re-run 'guild init'.\n" >&2
      GUILD_COV_SKIPPED=$((GUILD_COV_SKIPPED + 1))
      m=$((m + 1))
      continue
    fi
    slug="$(sql_str "${GUILD_COV_SLUG[$m]}")"
    if [ -n "${GUILD_COV_SPEC[$m]}" ]; then
      spec="$(sql_text "${GUILD_COV_SPEC[$m]}")"
    else
      spec='NULL'
    fi
    printf 'INSERT INTO coverage (id, area, risk, spec_path, last_inspected_at, notes)\n'
    printf 'SELECT %s, %s, %s, %s, NULL, %s\n' \
      "$slug" "$(sql_text "${GUILD_COV_AREA[$m]}")" "$(sql_text "${GUILD_COV_RISK[$m]}")" \
      "$spec" "$(sql_text "${GUILD_COV_NOTES[$m]}")"
    printf 'WHERE NOT EXISTS (SELECT 1 FROM coverage WHERE id = %s)\n' "$slug"
    printf "RETURNING 'COVROW|' || id;\n"
    m=$((m + 1))
  done
  return 0
}

# ---- journal pass ----------------------------------------------------------------

# _init_journal_carryover <ts> <doc-slug-set> <cov-id-set> — one journal line per row
# the database ACTUALLY INSERTED, so `guild rebuild` reproduces the knowledge base and
# the risk surface without inventing anything.
#
# The two sets are `|a|b|`-delimited lists built from the INSERTs' RETURNING output, not
# from the files that were scanned. That distinction is the whole point: a file whose
# slug already had a row emitted no INSERT, so journaling it would write a body the
# database does not hold — which is exactly how a rebuild used to change a doc.
#
# Sets the counts actually journaled in GUILD_DOC_N / GUILD_COV_N for the summary.
_init_journal_carryover() {
  local ts="$1" docset="${2-|}" covset="${3-|}" i row body dn cn

  dn=0
  cn=0

  i=0
  while [ "$i" -lt "${GUILD_DOC_N:-0}" ]; do
    if ! _init_seen "$docset" "${GUILD_DOC_SLUG[$i]}"; then
      i=$((i + 1))
      continue
    fi
    dn=$((dn + 1))
    _init_read_body body "${GUILD_DOC_PATH[$i]}"
    row="$(journal_row \
      slug "${GUILD_DOC_SLUG[$i]}" \
      title "${GUILD_DOC_TITLE[$i]}" \
      body "$body" \
      source "${GUILD_DOC_SOURCE[$i]}" \
      updated_at "$ts")"
    journal_append doc upsert "$row"
    i=$((i + 1))
  done

  i=0
  while [ "$i" -lt "${GUILD_COV_N:-0}" ]; do
    if ! _init_seen "$covset" "${GUILD_COV_SLUG[$i]}"; then
      i=$((i + 1))
      continue
    fi
    cn=$((cn + 1))
    if [ -n "${GUILD_COV_SPEC[$i]}" ]; then
      row="$(journal_row \
        id "${GUILD_COV_SLUG[$i]}" \
        area "${GUILD_COV_AREA[$i]}" \
        risk "${GUILD_COV_RISK[$i]}" \
        spec_path "${GUILD_COV_SPEC[$i]}" \
        '#last_inspected_at' null \
        notes "${GUILD_COV_NOTES[$i]}")"
    else
      row="$(journal_row \
        id "${GUILD_COV_SLUG[$i]}" \
        area "${GUILD_COV_AREA[$i]}" \
        risk "${GUILD_COV_RISK[$i]}" \
        '#spec_path' null \
        '#last_inspected_at' null \
        notes "${GUILD_COV_NOTES[$i]}")"
    fi
    journal_append coverage upsert "$row"
    i=$((i + 1))
  done

  # The summary reports what landed, not what was looked at.
  GUILD_DOC_N=$dn
  GUILD_COV_N=$cn
}

# ---- config and repo files -------------------------------------------------------

# _init_write_config <mode> <url_env> <token_env> — write config.yaml if absent.
# Returns 1 (writing nothing) when one already exists.
#
# Stores env var NAMES, never secret values (§2.1). `guild init` is not a
# configuration editor: an existing config.yaml is left exactly as it is.
_init_write_config() {
  local mode="$1" url_env="$2" token_env="$3" cfg
  cfg="$GUILD_DIR/config.yaml"
  if [ -f "$cfg" ]; then return 1; fi
  {
    printf '# guild v5 configuration. Committed to git.\n'
    printf '# Cloud credentials are read from the ENVIRONMENT VARIABLES NAMED below —\n'
    printf '# this file never holds a URL or a token itself.\n'
    printf 'version: 5\n'
    printf 'db:\n'
    printf '  mode: %s\n' "$mode"
    if [ "$mode" = "cloud" ]; then
      printf '  url_env: %s\n' "$url_env"
      printf '  token_env: %s\n' "$token_env"
    fi
  } >"$cfg" || die "guild: could not write $cfg"
  return 0
}

# _init_write_gitignore — the database is derived state; journal.ndjson and export/
# are what git carries (§2.3). Written only if absent.
#
# Everything listed here is either derived, machine-local, or a repair artifact:
#   guild.db*        derived — 'guild rebuild' replays journal.ndjson into it
#   spool/*          in-flight agent lines, drained into the database
#                    EXCEPT spool/rejected/, which is re-included: those are the entries the
#                    drain could NOT import, spool_drain tells the operator "nothing was
#                    discarded", and ignoring the file would have made that copy the only one
#                    — untracked, and dead with the worktree. `spool/*` plus a negation is the
#                    spelling that works: git cannot re-include a path under an ignored
#                    DIRECTORY, so `spool/` itself must not be the pattern.
#   journal.pending  quarantined lines awaiting 'guild journal recover' — a local repair
#                    state, not board state; committing it would replay someone else's
#                    half-finished mutation into everyone's journal
#   .export.tmp.*/   an export staging tree; a run killed mid-flight leaves one behind
#   backup-*/        pre-rebuild database copies and pre-compaction journal copies
_init_write_gitignore() {
  local f="$GUILD_DIR/.gitignore"
  if [ -f "$f" ]; then return 1; fi
  {
    printf "# Written by 'guild init'. The database is DERIVED state — journal.ndjson\n"
    printf '# and export/ are what git carries (design 2.3).\n'
    printf 'guild.db\n'
    printf 'guild.db-*\n'
    printf 'guild.db.*\n'
    printf 'spool/*\n'
    printf '!spool/rejected/\n'
    printf 'journal.pending\n'
    printf 'journal.ndjson.tmp.*\n'
    printf '.export.tmp.*/\n'
    printf 'dashboard.html\n'
    printf 'backup-*/\n'
  } >"$f" || die "guild: could not write $f"
  return 0
}

# _init_write_gitattributes — pin the line endings of everything git carries for the
# board. Written only if absent, exactly like the .gitignore above.
#
# WHY THIS IS A DATA-SAFETY FILE AND NOT A STYLE ONE. journal.ndjson is the ONE artifact
# git carries for the board (§2.3), and every reader of it parses positionally: a line
# must start `{"seq":` and its last byte must be `}`. A CR before the newline breaks that
# for every line at once. That is not exotic — it is what `core.autocrlf=true` (the
# Git-for-Windows default) and any `* text=auto` rule produce on checkout, and the guild
# writes no such file otherwise.
#
# The CLI now refuses on both paths that used to destroy data behind it — `guild rebuild`
# refuses rather than replaying an unreadable journal into an empty board, and
# `guild journal compact` refuses rather than overwriting the journal from a database it
# could not compare against. But a refusal is a worse outcome than never getting the CRLF
# in the first place, and the refusal text tells the operator to write exactly this file.
# Writing it at init is the difference between the guild diagnosing the problem and the
# guild preventing it.
#
# It lives in $GUILD_DIR, not at the repo root: a .gitattributes applies to its own
# directory and below, which is precisely the tree these patterns describe, and init has
# no business writing outside the guild directory. `-text` means "never convert, in
# either direction", whatever the user's core.autocrlf or a `* text=auto` rule says.
_init_write_gitattributes() {
  local f="$GUILD_DIR/.gitattributes"
  if [ -f "$f" ]; then return 1; fi
  {
    printf "# Written by 'guild init'. These files are PARSED POSITIONALLY — a line must\n"
    printf '# start {"seq": and end } — so a CR before the newline makes them unreadable\n'
    printf '# and the guild refuses to rebuild or compact (design 2.3).\n'
    printf '#\n'
    printf '# -text means: never convert line endings, whatever core.autocrlf says.\n'
    printf 'journal.ndjson -text\n'
    printf 'journal.pending -text\n'
    printf '*.ndjson -text\n'
  } >"$f" || die "guild: could not write $f"
  return 0
}

# ---- guild init ------------------------------------------------------------------

# _init_check_env_name <flag> <value> — die unless <value> is an environment variable
# NAME. THE VALUE IS NEVER PRINTED: the whole reason this check exists is that the value
# may be a live credential, and stderr is copied into every agent transcript.
#
# `--token-env "$TURSO_AUTH_TOKEN"` instead of `--token-env TURSO_AUTH_TOKEN` is a
# one-character mistake, and it used to write the token itself into config.yaml — a file
# whose own header promises it never holds one, and which is committed to git.
_init_check_env_name() {
  local flag="$1" v="$2"
  db_is_env_name "$v" && return 0
  die "guild: $flag takes the NAME of an environment variable, not its value.

What you passed is not a valid variable name (it must match [A-Za-z_][A-Za-z0-9_]*),
which means it is probably the URL or the token itself. config.yaml is COMMITTED TO GIT
and stores only the name (design 2.1), so the value is not repeated here.

  right:  guild init --mode cloud --url-env TURSO_DATABASE_URL --token-env TURSO_AUTH_TOKEN
  wrong:  guild init --mode cloud --url-env \"\$TURSO_DATABASE_URL\" --token-env \"\$TURSO_AUTH_TOKEN\"

Nothing was written. If a previous run did write a real token into $GUILD_DIR/config.yaml,
rotate it — it is already in your git history."
}

# cmd_init [--mode local|cloud] [--url-env NAME] [--token-env NAME] [--yes] [DATE]
#
# The sequence, and why the order matters:
#
#   1. Validate the flags (env var NAMES, never values), resolve the mode, refuse the
#      unverified cloud mode, then `db_require_binary` — fail early with the install
#      line for THIS mode rather than "command not found" three steps in (§2.2).
#   2. If a v4 board is present AND $GUILD_DIR really looks like a v4 guild root,
#      `archive_v4` FIRST, so the whole tree is safely aside before anything else
#      touches the directory (§11). Weak evidence is refused, not archived.
#   3. Create .guild/, config.yaml (env var NAMES only), spool/, export/, docs/, qa/,
#      reviews/, journal.
#   4. Apply schema.sql.
#   5. Carry over docs/ and qa/ in one composed script, guarded so a re-run inserts
#      nothing and overwrites nothing.
#   6. Print a summary: mode, what was archived, what carried over.
#
# Idempotent: re-running on an initialized guild archives nothing, overwrites no file
# and inserts no row. Also RESUMABLE: the carry-over is guarded on whether the row is
# actually in the database, not on whether some previous run said it had done the work,
# so a lost or rebuilt database re-imports what is missing from the archive.
cmd_init() {
  local mode_flag="" url_flag="" token_flag="" date_arg=""
  local cfg existing_mode mode url_env token_env
  local schema tmpd marker last_checkin carried wrote_cfg fresh_db carry_ts dbpath
  local line tag val docset covset ins_docs ins_cov d out

  guild_root >/dev/null
  cfg="$GUILD_DIR/config.yaml"

  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)        shift; mode_flag="${1-}";  [ $# -gt 0 ] && shift ;;
      --mode=*)      mode_flag="${1#--mode=}";  shift ;;
      --url-env)     shift; url_flag="${1-}";   [ $# -gt 0 ] && shift ;;
      --url-env=*)   url_flag="${1#--url-env=}"; shift ;;
      --token-env)   shift; token_flag="${1-}"; [ $# -gt 0 ] && shift ;;
      --token-env=*) token_flag="${1#--token-env=}"; shift ;;
      --date)        shift; date_arg="${1-}";   [ $# -gt 0 ] && shift ;;
      --date=*)      date_arg="${1#--date=}";   shift ;;
      --yes|-y)      GUILD_ASSUME_YES=1; shift ;;
      -*)            die "guild: unknown option '$1' for init" ;;
      *)
        if [ -n "$date_arg" ]; then die "guild: init takes at most one DATE argument"; fi
        date_arg="$1"; shift ;;
    esac
  done

  # ---- 0. the flags that must never carry a secret ----
  # Before ANY file is written, so a mistyped credential cannot reach config.yaml.
  if [ -n "$url_flag" ];   then _init_check_env_name --url-env   "$url_flag";   fi
  if [ -n "$token_flag" ]; then _init_check_env_name --token-env "$token_flag"; fi
  # The DATE argument is the one free-text flag init takes, and it reaches sql_text — so
  # it is checked HERE, before archive_v4 moves anything. Refusing it three steps later,
  # after the v4 board has moved into v4-archive/, would be the same trap the carry-over
  # skip exists to avoid, except there is nothing to skip: the user simply retypes it.
  if [ -n "$date_arg" ]; then utf8_require 'the DATE argument' "$date_arg"; fi

  # ---- 1. mode, then the binary check ----
  existing_mode=""
  if [ -f "$cfg" ]; then existing_mode="$(_db_cfg_get mode "$cfg")"; fi

  if [ -n "$mode_flag" ]; then
    case "$mode_flag" in
      local|cloud) : ;;
      *) die "guild: invalid --mode '$mode_flag' (expected local|cloud)" ;;
    esac
    if [ -n "$existing_mode" ] && [ "$existing_mode" != "$mode_flag" ]; then
      die "guild: this guild is already configured for '$existing_mode' mode.
Switching to '$mode_flag' would change where the board lives, so init will not do it
for you. Edit $cfg by hand once you have moved or re-created the database."
    fi
    mode="$mode_flag"
  else
    mode="${existing_mode:-local}"
  fi

  # Cloud mode is gated as UNVERIFIED (lib/db.sh: db_refuse_cloud_mode). This sits
  # AFTER the mode-switch check above, so a guild already configured for local mode
  # still gets the more specific "will not switch modes" message.
  if [ "$mode" = "cloud" ]; then
    db_refuse_cloud_mode
  fi

  url_env="$url_flag"
  token_env="$token_flag"
  if [ -f "$cfg" ]; then
    if [ -z "$url_env" ];   then url_env="$(_db_cfg_get url_env "$cfg")"; fi
    if [ -z "$token_env" ]; then token_env="$(_db_cfg_get token_env "$cfg")"; fi
  fi
  [ -n "$url_env" ]   || url_env="TURSO_DATABASE_URL"
  [ -n "$token_env" ] || token_env="TURSO_AUTH_TOKEN"

  # Seed the driver globals through the driver's own setter, so db_require_binary
  # checks the mode we are about to write rather than a default read back from a file
  # that does not exist yet.
  db_set_config "$mode" "$url_env" "$token_env"
  db_require_binary
  dbpath="$(db_path)"

  fresh_db=0
  if [ "$mode" = "local" ] && [ ! -f "$dbpath" ]; then fresh_db=1; fi

  # ---- 2. archive a v4 board BEFORE anything else ----
  #
  # Two guards stand in front of the only mass `mv` in the CLI: the evidence test, which
  # refuses when $GUILD_DIR is an ordinary directory that merely contains a `plans/`,
  # and the confirmation, which prints the exact list and asks when there is a human to
  # ask. Neither guard deletes anything, and neither does archive_v4.
  GUILD_V4_ARCHIVE_DIR=""
  GUILD_V4_ARCHIVED=""
  if _init_has_v4; then
    if [ "$(_init_v4_evidence)" != "strong" ]; then
      die "guild: refusing to archive — $GUILD_DIR does not look like a v4 guild board.

'guild init' moves a v4 board's top-level entries (requirements, tasks, plans, reviews,
archive, docs, qa, state.yaml, BOARD.md) into $GUILD_DIR/v4-archive/. Here it found:

  $(_init_v4_present)

but none of the markers that identify a real board: this directory is not named
'.guild', there is no state.yaml or BOARD.md beside a status tree, and there is no
requirements/<status> or tasks/<status> subdirectory. Those names are ordinary
directory names, and moving your working tree on the strength of them would be wrong.

NOTHING WAS MOVED AND NOTHING WAS DELETED.

If this really is a v4 board, point GUILD_DIR at its .guild directory:
  GUILD_DIR=path/to/.guild guild init
If it is not, unset GUILD_DIR (the default is ./.guild) or point it somewhere else."
    fi
    if ! _init_confirm_archive; then
      die "guild: init cancelled — nothing was moved, nothing was written."
    fi
    archive_v4
  fi

  # ---- 3. directories, config, gitignore, journal ----
  #
  # docs/, qa/ and reviews/ are re-created because v4 created them and the skills still
  # write there: the researcher writes .guild/docs/<slug>.md, the qa-artifacts skill
  # writes .guild/qa/*, and check-in step 3.5 writes .guild/reviews/. Archival moves the
  # v4 copies aside, so without this the directories would be silently gone after the
  # first init. They are created empty; _init_dir_has_content is what keeps an empty
  # docs/ from masking the archived one during carry-over.
  mkdir -p "$GUILD_DIR" "$GUILD_DIR/spool" "$GUILD_DIR/export" \
    "$GUILD_DIR/docs" "$GUILD_DIR/qa" "$GUILD_DIR/reviews" \
    || die "guild: could not create $GUILD_DIR"
  wrote_cfg=0
  if _init_write_config "$mode" "$url_env" "$token_env"; then wrote_cfg=1; fi
  _init_write_gitignore || true
  _init_write_gitattributes || true
  if [ ! -f "$(journal_path)" ]; then
    : >"$(journal_path)" || die "guild: could not create $(journal_path)"
  fi

  # ---- 4. schema ----
  schema="$(guild_schema_path)"
  db_apply_schema "$schema" >/dev/null

  # ---- 5. state + carry-over, composed into ONE script ----
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/guild-init.XXXXXX")" \
    || die "guild: could not create a temporary directory"
  carry_ts="$(db_now)"
  GUILD_CARRY_TS="$carry_ts"
  GUILD_DOC_N=0
  GUILD_COV_N=0
  GUILD_DOC_SKIPPED=0
  GUILD_COV_SKIPPED=0
  carried=0

  # A brace group, NOT a subshell: carry_over_* must leave its arrays behind.
  {
    printf 'BEGIN;\n'
    # v4 parity: `guild init DATE` seeds last-checkin on a FIRST init and never
    # clobbers a real value afterwards.
    if [ -n "$date_arg" ]; then
      printf 'UPDATE guild_state SET value = %s\n' "$(sql_text "$date_arg" 'the DATE argument')"
      printf "  WHERE key = 'last-checkin' AND (value = 'null' OR value = '');\n"
    fi

    if carry_over_docs; then carried=1; fi
    if carry_over_qa;   then carried=1; fi

    if [ "$carried" = 1 ]; then
      # The marker records WHEN a carry-over last ran, for the summary line. It is no
      # longer a guard: every insert above is guarded on the row's own existence, so
      # the carry-over is exactly-once per ROW, decided by the database itself. The
      # marker used to gate the inserts, which made init un-resumable — the marker
      # lives in guild.db, guild.db is gitignored, and a fresh clone would then skip
      # the carry-over forever while reporting that there was nothing to carry.
      printf 'INSERT INTO guild_state (key, value)\n'
      printf "SELECT 'v4-carryover', %s\n" "$(sql_str "$carry_ts")"
      printf "WHERE NOT EXISTS (SELECT 1 FROM guild_state WHERE key = 'v4-carryover');\n"
    fi
    printf 'COMMIT;\n'

    printf "SELECT 'CARRYOVER|' || value FROM guild_state WHERE key = 'v4-carryover';\n"
    printf "SELECT 'LASTCHECKIN|' || value FROM guild_state WHERE key = 'last-checkin';\n"
  } >"$tmpd/init.sql"

  if ! db_exec <"$tmpd/init.sql" >"$tmpd/out"; then
    # tursodb reports on STDOUT, which is redirected into the file above — so relay it,
    # or this is the failure that reads as "nothing happened" while the v4 board has
    # already moved to v4-archive/ and every re-run fails the same silent way.
    out="$(cat "$tmpd/out" 2>/dev/null || true)"
    rm -rf "$tmpd"
    db_fail "database initialization failed. Nothing was deleted${GUILD_V4_ARCHIVE_DIR:+; the v4 board is at $GUILD_V4_ARCHIVE_DIR}." "$out"
  fi

  # The result stream is tagged, single-column lines. DOCROW / COVROW come from the
  # INSERTs' RETURNING clause and name the rows the database ACTUALLY accepted; both
  # carry a slug ([a-z0-9-] only), so nothing user-supplied can impersonate a tag in
  # this pipe-separated channel.
  marker=""
  last_checkin=""
  docset="|"
  covset="|"
  ins_docs=0
  ins_cov=0
  while IFS= read -r line || [ -n "$line" ]; do
    tag="${line%%|*}"
    val="${line#*|}"
    case "$tag" in
      CARRYOVER)   marker="$val" ;;
      LASTCHECKIN) last_checkin="$val" ;;
      DOCROW)      docset="$docset$val|"; ins_docs=$((ins_docs + 1)) ;;
      COVROW)      covset="$covset$val|"; ins_cov=$((ins_cov + 1)) ;;
    esac
  done <"$tmpd/out"
  rm -rf "$tmpd"

  # "Did this run carry anything over" is now answered by the database's own RETURNING
  # output, not by whether SQL was emitted and not by the marker's timestamp. Journal
  # exactly the rows that landed — no more (which would make `guild rebuild` invent a
  # row) and no fewer (which would make it drop one).
  if [ "$ins_docs" -gt 0 ] || [ "$ins_cov" -gt 0 ]; then
    carried=1
    _init_journal_carryover "$carry_ts" "$docset" "$covset"
    if [ -n "$marker" ] && [ "$marker" = "$carry_ts" ]; then
      journal_append guild_state upsert "$(journal_row key v4-carryover value "$marker")"
    fi
  else
    carried=0
  fi

  if [ -n "$date_arg" ] && [ "$last_checkin" = "$date_arg" ]; then
    journal_append guild_state upsert "$(journal_row key last-checkin value "$last_checkin")"
  fi

  # ---- 6. summary ----
  printf 'Guild initialized at %s\n' "$GUILD_DIR"
  if [ "$mode" = "local" ]; then
    if [ "$fresh_db" = 1 ]; then
      printf '  mode:         local (database created at %s)\n' "$dbpath"
    else
      printf '  mode:         local (existing database at %s)\n' "$dbpath"
    fi
  else
    printf '  mode:         cloud (url from $%s, token from $%s)\n' "$url_env" "$token_env"
  fi
  if [ "$wrote_cfg" = 1 ]; then
    printf '  config:       %s\n' "$cfg"
  else
    printf '  config:       %s (existing, left unchanged)\n' "$cfg"
  fi
  printf '  journal:      %s\n' "$(journal_path)"
  printf '  spool:        %s/\n' "$GUILD_DIR/spool"
  printf '  export:       %s/\n' "$GUILD_DIR/export"
  printf '  last-checkin: %s\n' "${last_checkin:-null}"

  if [ -n "$GUILD_V4_ARCHIVE_DIR" ]; then
    printf '\nArchived the v4 board to %s/\n' "$GUILD_V4_ARCHIVE_DIR"
    for line in $GUILD_V4_ARCHIVED; do
      printf '  moved  %s  ->  %s/%s\n' "$GUILD_DIR/$line" "$GUILD_V4_ARCHIVE_DIR" "$line"
    done
    printf '  Everything was MOVED, not deleted — still plain markdown, still in git.\n'
    printf '  There is no history import (design 11): re-enter unfinished work with\n'
    printf '  guild:new-requirement, reading the archived plan for the details.\n'
  fi

  printf '\nCarried over:\n'
  if [ "$carried" = 1 ]; then
    printf '  docs:      %s -> doc table\n' "$GUILD_DOC_N"
    printf '  qa areas:  %s -> coverage table (last_inspected_at NULL — everything is due)\n' \
      "$GUILD_COV_N"
    case "${GUILD_COV_SOURCE:-none}" in
      risk)    printf "             areas read from the v4 charter's Risk Map\n" ;;
      cov)     printf "             areas read from the v4 charter's Coverage Matrix (no Risk Map)\n" ;;
      mission) printf '             areas read from the v4 QA missions (no charter)\n' ;;
    esac
    if [ "${GUILD_COV_SPECS_MATCHED:-0}" -gt 0 ]; then
      printf '             %s of them matched a committed spec in regression.md\n' \
        "$GUILD_COV_SPECS_MATCHED"
    fi
    printf '  QA sessions were archived, not imported — they are history (design 11).\n'
  elif [ -n "$marker" ]; then
    printf '  nothing — a previous init already carried over on %s\n' "$marker"
  else
    # Say which of the two it is. The old wording asserted "nothing was found" even
    # when the content was sitting in .guild/v4-archive/docs and the rows were already
    # in the database — a claim that sent people looking for data they still had.
    d=""
    if [ -n "$(_init_carry_src docs)" ] || [ -n "$(_init_carry_src qa)" ]; then d=1; fi
    if [ -n "$d" ]; then
      printf '  nothing new — every doc and coverage row is already in the database\n'
    else
      printf '  nothing — no .guild/docs or .guild/qa content was found\n'
    fi
  fi

  # Reported OUTSIDE the `carried` branch on purpose: if every doc in the archive is
  # latin-1, nothing carried over and the block above says so — but the reason must not
  # disappear with it. Skips are never silent and nothing is ever deleted.
  if [ "${GUILD_DOC_SKIPPED:-0}" -gt 0 ] || [ "${GUILD_COV_SKIPPED:-0}" -gt 0 ]; then
    printf '\nSkipped (not valid UTF-8, nothing deleted):\n'
    if [ "${GUILD_DOC_SKIPPED:-0}" -gt 0 ]; then
      printf '  docs:      %s file(s) left where they are; each was named above\n' \
        "$GUILD_DOC_SKIPPED"
    fi
    if [ "${GUILD_COV_SKIPPED:-0}" -gt 0 ]; then
      printf '  qa areas:  %s row(s) whose v4 charter text is not UTF-8\n' \
        "$GUILD_COV_SKIPPED"
    fi
    printf "  Re-encode with 'iconv -f latin1 -t utf8' and re-run 'guild init' — the\n"
    printf '  carry-over is guarded on each row, so only the missing ones are added.\n'
  fi
}

# ---- journal wrappers ------------------------------------------------------------

# cmd_rebuild — replay .guild/journal.ndjson into a fresh database (§2.3).
#
# Deliberately does NOT call db_require_init: a missing or corrupt database is the
# reason to run this, so demanding one would refuse exactly the case it exists for.
# Only the config (which mode, which binary) has to be there.
cmd_rebuild() {
  [ $# -eq 0 ] || die "guild: rebuild takes no arguments"
  db_load_config
  [ -f "$GUILD_DIR/config.yaml" ] ||
    die "guild: no guild found at $GUILD_DIR (run 'guild init')"
  db_require_binary
  journal_rebuild
}

# cmd_journal_compact [--force] — snapshot current database state as a new baseline
# journal (§2.3). Needs a live database, so db_require_init is right here.
#
# `--force` is forwarded rather than rejected: journal_compact refuses a snapshot that
# would SHRINK the journal, and its own refusal message ends with "'guild journal
# compact --force' overrides this check". An argument check here that swallowed the flag
# made that instruction a dead end.
cmd_journal_compact() {
  db_require_init
  journal_compact "$@"
}

# cmd_journal_recover — fold .guild/journal.pending back into the journal.
#
# This is the command _journal_quarantine tells the operator to run ("Repair the journal,
# then fold it back in with: guild journal recover"). It was named in two messages and
# routed from nowhere.
#
# No db_require_init: the pending file is a repair artifact on disk and folding it in
# never touches the database, so this must work on a guild whose database is missing —
# which is one of the situations that produces a pending file in the first place.
cmd_journal_recover() {
  [ $# -eq 0 ] || die "guild: journal recover takes no arguments"
  db_load_config
  journal_recover
}

# cmd_journal_sync [table ...] — journal the append-only record tables (work_log,
# review_finding, event) that the writers did not journal as they went. Prints the count.
#
# `guild rebuild` runs this itself before replaying; exposing it separately means an
# operator can reconcile without rebuilding, and can see the number.
cmd_journal_sync() {
  local n
  db_require_init
  n="$(journal_sync "$@")"
  printf 'Journaled %s un-journaled record row(s)\n' "${n:-0}"
}

# cmd_journal <subcommand> — compact | recover | sync.
cmd_journal() {
  local sub="${1-}"
  [ $# -ge 1 ] || die "guild: 'journal' requires a subcommand (compact|recover|sync)"
  shift
  case "$sub" in
    compact) cmd_journal_compact "$@" ;;
    recover) cmd_journal_recover "$@" ;;
    sync)    cmd_journal_sync "$@" ;;
    *) die "guild: unknown 'journal' subcommand '$sub' (compact|recover|sync)" ;;
  esac
}
