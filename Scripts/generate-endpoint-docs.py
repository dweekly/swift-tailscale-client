#!/usr/bin/env python3
"""Render the human-readable endpoint tables from Documentation/endpoints.json.

The manifest is the single source of truth for what this package implements.
This script injects generated tables between BEGIN/END markers in:

  - Documentation/LOCALAPI-COVERAGE.md  (implemented-endpoints)
  - Documentation/INTEGRATING.md        (endpoint-quick-reference)

Usage:
  Scripts/generate-endpoint-docs.py            # rewrite the marked sections
  Scripts/generate-endpoint-docs.py --check    # exit 1 if anything would change
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Documentation" / "endpoints.json"

MARKER_FMT = "<!-- {} GENERATED: {} (Scripts/generate-endpoint-docs.py) -->"


def load():
    with open(MANIFEST) as f:
        return json.load(f)


def coverage_table(data):
    lines = [
        "| Endpoint | Method(s) | Swift API | Access | Gate | Since | Min tailscaled | Tested | Notes |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for e in data["endpoints"]:
        lines.append(
            "| `{endpoint}` | {methods} | `{symbol}` | {access} | {gate} | v{since} "
            "| {min} | {tested} | {notes} |".format(
                endpoint=e["endpoint"],
                methods=", ".join(e["methods"]),
                symbol=e["symbol"],
                access=e["access"],
                gate=e["gate"],
                since=e["since"],
                min=e["min_tailscaled"],
                tested=e["tested"],
                notes=e["notes"],
            )
        )
    lines.append("")
    lines.append(f"Tested against: {data['tested_matrix']}.")
    return "\n".join(lines)


def quick_reference(data):
    lines = [
        "| Swift API | Endpoint | Access | Availability caveat |",
        "|---|---|---|---|",
    ]
    for e in data["endpoints"]:
        caveat = "—"
        if not e["min_tailscaled"].startswith("old"):
            caveat = f"needs tailscaled {e['min_tailscaled']}"
        if e["gate"].startswith("Has"):
            gate_note = f"absent on builds without `{e['gate']}`"
            caveat = gate_note if caveat == "—" else f"{caveat}; {gate_note}"
        if e["access"] == "destructive":
            caveat = ("**destructive** — " + caveat) if caveat != "—" else "**destructive**"
        if e["stability"] == "experimental":
            caveat = (caveat + "; " if caveat != "—" else "") + "SemVer-exempt"
        lines.append(
            "| `{symbol}` | `{endpoint}` | {access} | {caveat} |".format(
                symbol=e["symbol"],
                endpoint=e["endpoint"],
                access=e["access"],
                caveat=caveat,
            )
        )
    return "\n".join(lines)


def inject(path, section, body, check):
    begin = MARKER_FMT.format("BEGIN", section)
    end = MARKER_FMT.format("END", section)
    text = path.read_text()
    if begin not in text or end not in text:
        print(f"ERROR: markers for '{section}' not found in {path}")
        return False
    head, rest = text.split(begin, 1)
    _, tail = rest.split(end, 1)
    new = f"{head}{begin}\n{body}\n{end}{tail}"
    if new != text:
        if check:
            print(f"DRIFT: {path} section '{section}' is out of date; "
                  "run Scripts/generate-endpoint-docs.py")
            return False
        path.write_text(new)
        print(f"updated {path} ({section})")
    else:
        print(f"ok      {path} ({section})")
    return True


def main():
    check = "--check" in sys.argv
    data = load()
    ok = True
    ok &= inject(
        ROOT / "Documentation" / "LOCALAPI-COVERAGE.md",
        "implemented-endpoints", coverage_table(data), check)
    ok &= inject(
        ROOT / "Documentation" / "INTEGRATING.md",
        "endpoint-quick-reference", quick_reference(data), check)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
