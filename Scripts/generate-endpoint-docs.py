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
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Documentation" / "endpoints.json"
FIXTURES = ROOT / "Tests" / "TailscaleClientTests" / "Fixtures"
RUN_URL = "https://github.com/dweekly/swift-tailscale-client/actions/runs/{}"

MARKER_FMT = "<!-- {} GENERATED: {} (Scripts/generate-endpoint-docs.py) -->"

VALID_MATURITY = {"stable", "unstable", "unspecified"}
VALID_SUPPORT = {"supported", "preview", "experimental"}
VALID_ACCESS = {"read", "write", "destructive"}
VALID_UNIT = {"synthetic-fixture", "captured-fixture", "wire-shape"}
VALID_MODE = {"read", "read+write"}
VALID_TRIGGER = {"automatic", "manual"}
MANUAL_EVENTS = {"workflow_dispatch", "workflow_call"}
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
UNIT_LABEL = {
    "synthetic-fixture": "synthetic fixture",
    "captured-fixture": "captured fixture",
    "wire-shape": "wire shape",
}


def load():
    with open(MANIFEST) as f:
        return json.load(f)


def split_list(value):
    return [s.strip() for s in value.split(",") if s.strip()]


def workflow_trigger(text):
    """'manual' when a workflow's `on:` names only dispatch/call events."""
    events = set()
    lines = text.splitlines()
    for i, line in enumerate(lines):
        match = re.match(r"^(?:on|\"on\"|'on'):\s*(.*)$", line)
        if not match:
            continue
        inline = match.group(1).split("#")[0].strip()
        if inline:
            events.update(e.strip() for e in inline.strip("[]").split(",") if e.strip())
        for child in lines[i + 1:]:
            if child.strip() and not child.startswith((" ", "#")):
                break
            event = re.match(r"^  ([A-Za-z_]+):", child)
            if event:
                events.add(event.group(1))
        break
    if not events:
        return None
    return "manual" if events <= MANUAL_EVENTS else "automatic"


def evidence_problems(data, read_text=None, fixtures=FIXTURES):
    """Every claim that a daemon was observed must name lane, run, version, date.

    A live or historical record that cannot be traced to a run, a fixture
    claim with no matching file, or a lane whose recorded trigger disagrees
    with its workflow file is the class of defect this guards against.
    """
    if read_text is None:
        def read_text(rel):
            return (ROOT / rel).read_text()
    problems = []
    for key in ("tested_matrix",):
        if key in data:
            problems.append(f"top-level {key} is retired; use evidence_lanes")
    lanes = data.get("evidence_lanes")
    if not isinstance(lanes, dict) or not lanes:
        problems.append("manifest is missing the evidence_lanes block")
        lanes = {}
    for lane_name, lane in lanes.items():
        trigger = lane.get("trigger")
        if trigger not in VALID_TRIGGER:
            problems.append(f"lane {lane_name}: trigger={trigger!r} is not one of {sorted(VALID_TRIGGER)}")
        try:
            actual = workflow_trigger(read_text(lane.get("workflow", "")))
        except OSError:
            actual = None
            problems.append(f"lane {lane_name}: workflow {lane.get('workflow')!r} not found")
        if actual and trigger in VALID_TRIGGER and actual != trigger:
            problems.append(
                f"lane {lane_name}: manifest says trigger={trigger!r} but "
                f"{lane.get('workflow')} is {actual}")
        last = lane.get("last_success") or {}
        if not isinstance(last.get("run"), int) or not DATE_RE.match(str(last.get("date", ""))) \
                or not split_list(str(last.get("daemons", ""))):
            problems.append(f"lane {lane_name}: last_success must name run, date, and daemons")
    for e in data["endpoints"]:
        name = e.get("endpoint", "<unnamed>")
        if "tested" in e:
            problems.append(f"{name}: free-text 'tested' is retired; use evidence")
        if str(e.get("min_tailscaled", "")).startswith("old") or "tested floor" in str(e.get("min_tailscaled", "")):
            problems.append(f"{name}: min_tailscaled implies a tested floor; use a recorded release or 'not established'")
        ev = e.get("evidence")
        if not isinstance(ev, dict):
            problems.append(f"{name}: missing evidence")
            continue
        unit = ev.get("unit")
        if unit not in VALID_UNIT:
            problems.append(f"{name}: evidence.unit={unit!r} is not one of {sorted(VALID_UNIT)}")
        globs = split_list(ev.get("fixtures", ""))
        if unit in ("synthetic-fixture", "captured-fixture") and not globs:
            problems.append(f"{name}: evidence.unit={unit} needs evidence.fixtures")
        for pattern in globs:
            if not list(fixtures.glob(pattern)):
                problems.append(f"{name}: evidence.fixtures {pattern!r} matches no file")
        for kind, version_key in (("live", "daemon"), ("historical", "daemons")):
            record = ev.get(kind, "absent")
            if record == "absent":
                problems.append(f"{name}: evidence.{kind} must be present (null when none)")
                continue
            if record is None:
                continue
            lane = lanes.get(record.get("lane"))
            if lane is None:
                problems.append(f"{name}: evidence.{kind} names unknown lane {record.get('lane')!r}")
                continue
            last = lane.get("last_success") or {}
            versions = split_list(str(record.get(version_key, "")))
            if not versions:
                problems.append(f"{name}: evidence.{kind} does not name a daemon version")
            for v in versions:
                if v not in split_list(str(last.get("daemons", ""))):
                    problems.append(
                        f"{name}: evidence.{kind} daemon {v} is not among lane "
                        f"{record['lane']}'s recorded daemons")
            if record.get("run") != last.get("run"):
                problems.append(
                    f"{name}: evidence.{kind} run {record.get('run')!r} is not lane "
                    f"{record['lane']}'s recorded last success")
            if record.get("mode") not in VALID_MODE:
                problems.append(f"{name}: evidence.{kind} mode={record.get('mode')!r} is not one of {sorted(VALID_MODE)}")
            if kind == "live":
                if not DATE_RE.match(str(record.get("last_passed", ""))) \
                        or record.get("last_passed") != last.get("date"):
                    problems.append(f"{name}: evidence.live must name the date of the run it cites")
                if not split_list(record.get("tests", "")):
                    problems.append(f"{name}: evidence.live must name the passing tests")
    return problems


def validate(data):
    problems = evidence_problems(data)
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


def provenance_block(data):
    """Header lines derived from the manifest so the pinned commit and
    verification date can never drift from what the validator enforces."""
    prov = data["upstream_provenance"]
    return (
        f"**Last updated:** {prov['verified']}\n"
        f"**Upstream reference:** `{prov['repository']}` pinned commit "
        f"`{prov['revision'][:12]}` (verified {prov['verified']}; full SHA and "
        f"validation in [`endpoints.json`](endpoints.json)), "
        f"`ipn/localapi/` + `client/local/`")


def summary_table(data):
    """Implemented counts computed from the manifest, never hand-maintained."""
    counts = {}
    for e in data["endpoints"]:
        counts[e["swift_support"]] = counts.get(e["swift_support"], 0) + 1
    parts = [f"{counts.get('supported', 0)} supported"]
    if counts.get("preview"):
        parts.append(f"{counts['preview']} preview")
    parts.append(f"{counts.get('experimental', 0)} experimental")
    lines = [
        "| Category | Count |",
        "|----------|-------|",
        f"| Implemented (from `endpoints.json`) | {' + '.join(parts)} |",
        "| Planned Stable | ~40 |",
        "| Planned Experimental | ~15 |",
        "| Unsupported (documented, with reasons) | 6 |",
        "| No LocalAPI equivalent (client-side features) | netcheck (implemented "
        "client-side in v0.6.0 as `Netcheck`), captive portal detection |",
    ]
    return "\n".join(lines)


def source_cell(e):
    return "gate, maturity" if e.get("upstream_symbol", "").strip() else "gate"


def live_cell(ev):
    live = ev.get("live")
    if not live:
        return "—"
    return f"{live['daemon']} ({live['mode']}, {live['last_passed']})"


def historical_cell(ev):
    hist = ev.get("historical")
    if not hist:
        return "—"
    return f"{hist['daemons']} ({hist['mode']})"


def lane_sentence(lane):
    last = lane["last_success"]
    return (f"[run {last['run']}]({RUN_URL.format(last['run'])}), {last['date']}, "
            f"commit `{last['commit']}`, tailscaled {last['daemons']}; "
            f"tests executed: {last['executed']}; skipped: {last['skipped']}; failed: {last['failed']}")


def coverage_table(data):
    prov = data["upstream_provenance"]
    lanes = data["evidence_lanes"]
    lines = [
        "| Endpoint | Method(s) | Swift API | Access | Upstream maturity | Swift support "
        "| Gate | Since | Min tailscaled | Unit | Source | Live on 1.x | Pre-1.0 matrix | Notes |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for e in data["endpoints"]:
        ev = e["evidence"]
        notes = e["notes"]
        if e.get("upstream_notes"):
            notes = f"{notes}. Upstream: {e['upstream_notes']}"
        if ev.get("note"):
            notes = f"{notes}. Testing: {ev['note']}"
        lines.append(
            "| `{endpoint}` | {methods} | `{symbol}` | {access} | {maturity} | {support} "
            "| {gate} | v{since} | {min} | {unit} | {source} | {live} | {hist} | {notes} |".format(
                endpoint=e["endpoint"],
                methods=", ".join(e["methods"]),
                symbol=e["symbol"],
                access=e["access"],
                maturity=maturity_cell(e),
                support=e["swift_support"],
                gate=e["gate"],
                since=e["since"],
                min=e["min_tailscaled"],
                unit=UNIT_LABEL[ev["unit"]],
                source=source_cell(e),
                live=live_cell(ev),
                hist=historical_cell(ev),
                notes=notes,
            )
        )
    live_count = sum(1 for e in data["endpoints"] if e["evidence"].get("live"))
    lines.append("")
    lines.append(
        f"Upstream maturity per Tailscale's own \"API maturity\" annotations in "
        f"`{prov['repository']}` {prov['revision']} (verified {prov['verified']}); "
        f"methods without an annotation must be assumed unstable, and \"supported\" "
        f"over an upstream-unstable endpoint means this package normalizes drift — "
        f"not that Tailscale guarantees the wire contract.")
    lines.append("")
    lines.append("How to read the evidence columns:")
    lines.append("")
    lines.append(
        "- **Unit**: what the unit tests (`swift test`, mocked transport) decode. "
        "*Synthetic fixture*: generated or hand-written JSON under "
        "`Tests/TailscaleClientTests/Fixtures/`, never read from a daemon. "
        "*Captured fixture*: replies recorded from a real daemon, with provenance in "
        "`ping-captured.provenance.json`. *Wire shape*: request path, method, body, "
        "and inline response JSON asserted in the test.")
    lines.append(
        f"- **Source**: compared with `{prov['repository']}` at the pinned commit by "
        f"`Scripts/verify-upstream-maturity.py` in CI: the handler gate for every "
        f"endpoint, plus the API maturity where a Go client method exists. This is a "
        f"source comparison, not daemon behavior.")
    lines.append(
        f"- **Live on 1.x** ({live_count} of {len(data['endpoints'])} endpoints): a test "
        f"in `TailscaleClientIntegrationTests` called the endpoint and passed against "
        f"the named tailscaled version in the last successful run of the self-hosted "
        f"macOS lane ({lanes['macos-self-hosted']['description']}): "
        f"{lane_sentence(lanes['macos-self-hosted'])}. \"—\" means no 1.x run has "
        f"observed the endpoint. *read+write* in either column means a write test that "
        f"calls the endpoint also passed.")
    current = lanes.get("headscale-matrix-1x")
    later = (f"Its runs on 1.x code are recorded for the lane, not per endpoint: "
             f"{lane_sentence(current)}." if current else "It has not passed on 1.x code.")
    lines.append(
        f"- **Pre-1.0 matrix**: tailscaled versions on which the headscale matrix "
        f"observed the endpoint in its last successful run on pre-1.0 code "
        f"({lanes['headscale-matrix']['last_success']['code_line']}): "
        f"{lane_sentence(lanes['headscale-matrix'])}. That workflow is "
        f"{lanes['headscale-matrix']['trigger']}-only; these are historical observations, "
        f"not current results. {later}")
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
        if not e["min_tailscaled"].startswith("not established"):
            caveats.append(f"needs tailscaled {e['min_tailscaled']}")
        live = e["evidence"].get("live")
        if live:
            caveats.append(f"observed live on tailscaled {live['daemon']} ({live['mode']})")
        else:
            caveats.append("not yet observed on a live daemon by 1.x tests")
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
    ok &= inject(coverage, "coverage-provenance", provenance_block(data), check)
    ok &= inject(coverage, "coverage-summary", summary_table(data), check)
    ok &= inject(coverage, "implemented-endpoints", coverage_table(data), check)
    ok &= inject(coverage, "upstream-stable-unimplemented", stable_gaps_table(data), check)
    ok &= inject(
        ROOT / "Documentation" / "INTEGRATING.md",
        "endpoint-quick-reference", quick_reference(data), check)
    check_hand_sections(data)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
