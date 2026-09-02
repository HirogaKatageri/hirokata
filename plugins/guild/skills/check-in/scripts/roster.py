#!/usr/bin/env python3
"""Build the guild roster by reading subagent frontmatter.

The roster is NOT in the database. Who the guild's members are, what each can do,
which model it runs on and whether it runs serially are facts about the agent FILES,
and this script is how the orchestrator reads them.

It scans every place a subagent can live, in Claude Code's own precedence order, and
DEDUPES BY NAME so the nearest definition wins — a project-local `developer` overrides
the plugin's, exactly as it does when the agent is spawned.

    python3 "${CLAUDE_PLUGIN_ROOT}/skills/check-in/scripts/roster.py"
    python3 .../roster.py --json          machine-readable, same data
    python3 .../roster.py --covers a,b    only members whose capabilities cover ALL of a,b

Output is one line per member:

    name | model | serial | scope | capabilities

WHAT THIS SCRIPT CANNOT KNOW: whether a subagent is ENABLED for this session. It reads
files off disk; the authoritative list of spawnable agent types is the one in the session
prompt. When the two disagree, the session prompt wins — check a member is really there
before you dispatch it, and treat a file-only member as absent.
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

# Nearest scope first. A name found earlier is not overridden by a later one.
def scan_roots():
    roots = []
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    cwd = Path.cwd()
    home = Path.home()

    roots.append(("project", cwd / ".claude" / "agents"))
    roots.append(("user", home / ".claude" / "agents"))
    if plugin_root:
        roots.append(("guild", Path(plugin_root) / "agents"))

    # Other installed plugins. Both the installed cache and the marketplace checkouts,
    # because which of the two is live depends on how the plugin was installed.
    for base in (home / ".claude" / "plugins" / "cache",
                 home / ".claude" / "plugins" / "marketplaces"):
        if base.is_dir():
            for d in sorted(base.rglob("agents")):
                if d.is_dir():
                    roots.append(("plugin", d))
    return roots


FRONTMATTER = re.compile(r"\A---\s*?\n(.*?)\n---\s*?(?:\n|\Z)", re.S)


def parse_frontmatter(text):
    """Enough YAML for an agent header: scalars, inline lists, and block lists.

    Deliberately not a YAML parser. Agent frontmatter is a flat header, and a real
    parser would be a dependency this script does not get to assume.
    """
    m = FRONTMATTER.match(text)
    if not m:
        return None
    out, key = {}, None
    for raw in m.group(1).splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw.startswith((" ", "\t")) and key:
            item = raw.strip()
            if item.startswith("- "):
                out.setdefault(key, [])
                if isinstance(out[key], list):
                    out[key].append(item[2:].strip().strip("'\""))
            continue
        if ":" not in raw:
            continue
        key, _, value = raw.partition(":")
        key, value = key.strip(), value.strip()
        if value.startswith("[") and value.endswith("]"):
            inner = value[1:-1].strip()
            out[key] = [v.strip().strip("'\"") for v in inner.split(",") if v.strip()]
        elif value in ("|", ">", "|-", ">-", ""):
            out[key] = []           # block scalar or an about-to-be block list
        else:
            out[key] = value.strip("'\"")
    return out


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v) for v in value]
    return [v.strip() for v in str(value).split(",") if v.strip()]


def collect():
    members, warnings, seen_paths = {}, [], set()
    for scope, directory in scan_roots():
        if not directory.is_dir():
            continue
        for path in sorted(directory.glob("*.md")):
            real = path.resolve()
            if real in seen_paths:
                continue
            seen_paths.add(real)
            try:
                fm = parse_frontmatter(path.read_text(encoding="utf-8", errors="replace"))
            except OSError as exc:
                warnings.append(f"unreadable: {path} ({exc})")
                continue
            if fm is None:
                warnings.append(f"no frontmatter: {path}")
                continue
            name = fm.get("name") or path.stem
            if not isinstance(name, str) or not name:
                warnings.append(f"no name: {path}")
                continue
            if name in members:          # nearer scope already claimed it
                continue
            serial = str(fm.get("serial", "false")).lower() in ("true", "1", "yes")
            members[name] = {
                "name": name,
                "model": fm.get("model") or "",
                "serial": serial,
                "scope": scope,
                "capabilities": sorted(set(as_list(fm.get("capabilities")))),
                "path": str(path),
            }
    return members, warnings


def main():
    ap = argparse.ArgumentParser(add_help=True, description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", action="store_true", help="emit JSON instead of the table")
    ap.add_argument("--covers", metavar="a,b",
                    help="only members whose capabilities cover ALL of these")
    args = ap.parse_args()

    members, warnings = collect()
    rows = sorted(members.values(), key=lambda m: m["name"])

    if args.covers:
        required = {c.strip() for c in args.covers.split(",") if c.strip()}
        rows = [m for m in rows if required <= set(m["capabilities"])]
        # The dispatch ranking, in the one place it is implemented:
        #   preferred coverage is the caller's business (it needs the ticket's rows),
        #   but the last two keys are universal — specialist first, then name.
        rows.sort(key=lambda m: (len(m["capabilities"]), m["name"]))

    if args.json:
        json.dump({"members": rows, "warnings": warnings}, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0

    for m in rows:
        caps = ", ".join(m["capabilities"]) or "-"
        print(f"{m['name']} | {m['model'] or '-'} | "
              f"{'serial' if m['serial'] else 'parallel'} | {m['scope']} | {caps}")

    uncapped = [m["name"] for m in rows if not m["capabilities"]]
    if uncapped:
        print(f"\nNOTE  no capabilities declared (pin-only): {', '.join(uncapped)}",
              file=sys.stderr)
    for w in warnings:
        print(f"WARN  {w}", file=sys.stderr)
    if not rows:
        print("WARN  no agent files found — check CLAUDE_PLUGIN_ROOT is set",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
