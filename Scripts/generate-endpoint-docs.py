#!/usr/bin/env python3
"""Render the human-readable endpoint tables from Documentation/endpoints.json.

The manifest is the single source of truth for what this package implements,
including TWO INDEPENDENT stability axes per endpoint:

  - upstream_maturity: Tailscale's own per-method "API maturity" annotation
    (stable | unstable | unspecified; upstream documents that unannotated
    methods must be assumed unstable), verified against the revision recorded
    in the manifest's upstream_provenance block.
  - swift_support: this package's promise for its Swift facade
    (supported | preview | experimental).

This script validates those classifications and injects generated tables
between BEGIN/END markers in:

  - Documentation/LOCALAPI-COVERAGE.md  (implemented-endpoints,
                                         upstream-stable-unimplemented)
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

VALID_MATURITY = {"stable", "unstable", "unspecified"}
VALID_SUPPORT = {"supported", "preview", "experimental"}
VALID_ACCESS = {"read", "write", "destructive"}


def load():
    with open(MANIFEST) as f:
        return json.load(f)


def validate(data):
    problems = []
    if "upstream_provenance" not in data:
        problems.append("manifest is missing the upstream_provenance block")
    for e in data["endpoints"]:
        name = e.get("endpoint", "<unnamed>")
        for field, valid in (
            ("upstream_maturity", VALID_MATURITY),
            ("swift_support", VALID_SUPPORT),
            ("access", VALID_ACCESS),
        ):
            value = e.get(field)
            if value not in valid:
                problems.append(
                    f"{name}: {field}={value!r} is not one of {sorted(valid)}")
        if "upstream_symbol" not in e:
            problems.append(f"{name}: missing upstream_symbol (use \"\" when none exists)")
        listed = [s.strip() for s in e.get("upstream_symbol", "").split("/") if s.strip()]
        for symbol, maturity in e.get("upstream_symbol_maturity", {}).items():
            if maturity not in VALID_MATURITY:
                problems.append(
                    f"{name}: upstream_symbol_maturity[{symbol}]={maturity!r} "
                    f"is not one of {sorted(VALID_MATURITY)}")
            if symbol not in listed:
                problems.append(
                    f"{name}: upstream_symbol_maturity names {symbol}, "
                    f"which is not in upstream_symbol")
    if problems:
        for p in problems:
            print(f"INVALID  {p}")
        sys.exit(1)


def maturity_cell(e):
    """Coverage-table cell: entry maturity plus any per-symbol exceptions."""
    overrides = e.get("upstream_symbol_maturity", {})
    if not overrides:
        return e["upstream_maturity"]
    detail = ", ".join(f"{s}: {m}" for s, m in sorted(overrides.items()))
    return f"{e['upstream_maturity']} ({detail})"


def maturity_phrase(e):
    mat = e["upstream_maturity"]
    support = e["swift_support"]
    if mat == "stable":
        upstream = "upstream stable"
    elif mat == "unstable":
        upstream = "upstream unstable"
    else:
        upstream = "no upstream maturity note (assume unstable)"
    if support == "supported":
        swift = "supported Swift API"
        if mat != "stable":
            swift = "supported Swift normalization layer"
    elif support == "preview":
        swift = "preview Swift API"
    else:
        swift = "experimental Swift API (SemVer-exempt)"
    if e.get("upstream_symbol_maturity"):
        upstream += " (per-symbol exceptions in the coverage matrix)"
    return f"{upstream}; {swift}"


def coverage_table(data):
    prov = data["upstream_provenance"]
    lines = [
        "| Endpoint | Method(s) | Swift API | Access | Upstream maturity | Swift support "
        "| Gate | Since | Min tailscaled | Tested | Notes |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for e in data["endpoints"]:
        notes = e["notes"]
        if e.get("upstream_notes"):
            notes = f"{notes}. Upstream: {e['upstream_notes']}"
        lines.append(
            "| `{endpoint}` | {methods} | `{symbol}` | {access} | {maturity} | {support} "
            "| {gate} | v{since} | {min} | {tested} | {notes} |".format(
                endpoint=e["endpoint"],
                methods=", ".join(e["methods"]),
                symbol=e["symbol"],
                access=e["access"],
                maturity=maturity_cell(e),
                support=e["swift_support"],
                gate=e["gate"],
                since=e["since"],
                min=e["min_tailscaled"],
                tested=e["tested"],
                notes=notes,
            )
        )
    lines.append("")
    lines.append(
        f"Upstream maturity per Tailscale's own \"API maturity\" annotations in "
        f"`{prov['repository']}` {prov['revision']} (verified {prov['verified']}); "
        f"methods without an annotation must be assumed unstable, and \"supported\" "
        f"over an upstream-unstable endpoint means this package normalizes drift — "
        f"not that Tailscale guarantees the wire contract.")
    lines.append("")
    lines.append(f"Tested against: {data['tested_matrix']}.")
    return "\n".join(lines)


def stable_gaps_table(data):
    lines = [
        "| Go method | Endpoint | Note |",
        "|---|---|---|",
    ]
    for gap in data["upstream_stable_unimplemented"]:
        lines.append(
            f"| `{gap['go_symbol']}` | `{gap['endpoint']}` | {gap['note']} |")
    return "\n".join(lines)


def quick_reference(data):
    lines = [
        "| Swift API | Endpoint | Access | Stability & availability |",
        "|---|---|---|---|",
    ]
    for e in data["endpoints"]:
        caveats = [maturity_phrase(e)]
        if not e["min_tailscaled"].startswith("old"):
            caveats.append(f"needs tailscaled {e['min_tailscaled']}")
        if e["gate"].startswith("Has"):
            caveats.append(f"absent on builds without `{e['gate']}`")
        if e["access"] == "destructive":
            caveats.insert(0, "**destructive**")
        lines.append(
            "| `{symbol}` | `{endpoint}` | {access} | {caveat} |".format(
                symbol=e["symbol"],
                endpoint=e["endpoint"],
                access=e["access"],
                caveat="; ".join(caveats),
            )
        )
    return "\n".join(lines)


def check_hand_sections(data):
    """Fail when hand-maintained coverage text contradicts the manifest.

    Every endpoint in the manifest is implemented; a hand-maintained table
    row that still calls it Planned/Unsupported/on-demand is the drift class
    that has slipped through review before. Generated sections are excluded.
    """
    coverage = (ROOT / "Documentation" / "LOCALAPI-COVERAGE.md").read_text()
    hand = []
    inside_generated = False
    for line in coverage.splitlines():
        if "BEGIN GENERATED:" in line:
            inside_generated = True
        elif "END GENERATED:" in line:
            inside_generated = False
        elif not inside_generated:
            hand.append(line)
    problems = []
    stale_markers = ("Planned", "Unsupported", "on demand")
    for e in data["endpoints"]:
        needle = f"| `{e['endpoint']}` |"
        for line in hand:
            if needle in line and any(m in line for m in stale_markers):
                problems.append(
                    f"{e['endpoint']}: implemented per the manifest, but a "
                    f"hand-maintained row still says otherwise: {line.strip()}")
    if problems:
        for p in problems:
            print(f"CONTRADICTION  {p}")
        sys.exit(1)


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
    validate(data)
    coverage = ROOT / "Documentation" / "LOCALAPI-COVERAGE.md"
    ok = True
    ok &= inject(coverage, "implemented-endpoints", coverage_table(data), check)
    ok &= inject(coverage, "upstream-stable-unimplemented", stable_gaps_table(data), check)
    ok &= inject(
        ROOT / "Documentation" / "INTEGRATING.md",
        "endpoint-quick-reference", quick_reference(data), check)
    check_hand_sections(data)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
