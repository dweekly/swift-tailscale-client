#!/usr/bin/env python3
"""Validate Documentation/endpoints.json against the pinned upstream revision.

The manifest's ``upstream_provenance.revision`` must be an immutable commit
SHA in tailscale/tailscale. This script downloads the annotated sources at
exactly that revision, re-derives every "API maturity" annotation, and fails
if the manifest disagrees with upstream — so a transcription error (or an
upstream change hidden behind a mutable ref) cannot survive CI.

Checks performed:
  1. Every Go symbol named in an endpoint's ``upstream_symbol`` exists
     upstream and its derived maturity matches the manifest. Entries that
     aggregate symbols of differing maturity record the exceptions in
     ``upstream_symbol_maturity`` (symbol -> maturity).
  2. Every ``upstream_stable_unimplemented`` ledger row names symbols that
     really are upstream-stable (an unstable method is not a "stable gap").
  3. ``upstream_provenance.capability_version`` matches
     ``tailcfg.CurrentCapabilityVersion`` at the pinned revision, and the
     Swift ``defaultCapabilityVersion`` constant matches both.
  4. Each endpoint's ``gate`` matches the handler registration at the
     pinned revision: entries in localapi.go's static handler map are
     ``core``; entries registered inside an ``if buildfeatures.X { ... }``
     block carry that build-tag expression verbatim (e.g.
     ``HasDebug || HasAdvertiseRoutes``); and handlers that live in
     build-tagged sibling files (cert.go, serve.go, debug.go — the
     ``//go:build !ts_omit_x`` pattern) carry the ``Hasx`` feature their
     file's tag implies. Endpoints with no registration in any scanned file
     are skipped, never guessed.

Usage:
  Scripts/verify-upstream-maturity.py                 # download at pinned SHA
  Scripts/verify-upstream-maturity.py --source-dir D  # use cached *.go files
"""

import json
import pathlib
import re
import sys
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Documentation" / "endpoints.json"
SWIFT_CONFIG = (
    ROOT / "Sources" / "TailscaleClient" / "Configuration"
    / "TailscaleClientConfiguration.swift"
)

# The files that carry "API maturity" annotations for the LocalAPI client,
# plus tailcfg.go for the capability-version cross-check.
SOURCE_FILES = [
    "client/local/local.go",
    "client/local/cert.go",
    "client/local/serve.go",
    "tailcfg/tailcfg.go",
    "ipn/localapi/localapi.go",
]

# Handlers registered from build-tagged sibling files rather than
# localapi.go itself; their gate is the feature the file's
# ``//go:build !ts_omit_x`` tag implies.
GATED_HANDLER_FILES = [
    "ipn/localapi/cert.go",
    "ipn/localapi/serve.go",
    "ipn/localapi/debug.go",
]
SOURCE_FILES += GATED_HANDLER_FILES

# ts_omit_<x> build tag -> buildfeatures.Has<X> name (irregular casings).
OMIT_TAG_FEATURES = {
    "ts_omit_acme": "HasACME",
    "ts_omit_serve": "HasServe",
    "ts_omit_debug": "HasDebug",
}

RAW_URL = "https://raw.githubusercontent.com/tailscale/tailscale/{rev}/{path}"

FUNC_RE = re.compile(r"^func (?:\([^)]*\) )?([A-Za-z0-9_]+)\(")
# Order matters: the unstable phrase contains the stable phrase.
UNSTABLE_RE = re.compile(r"not considered a stable API", re.IGNORECASE)
STABLE_RE = re.compile(r"considered a stable API", re.IGNORECASE)


def fetch(revision, path):
    url = RAW_URL.format(rev=revision, path=path)
    last = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return response.read().decode("utf-8")
        except Exception as error:  # noqa: BLE001 - report the last failure
            last = error
            time.sleep(2 * (attempt + 1))
    raise SystemExit(f"ERROR: could not fetch {url}: {last}")


def load_sources(revision, source_dir):
    sources = {}
    for path in SOURCE_FILES:
        if source_dir:
            # Flattened path names avoid basename collisions (cert.go and
            # serve.go exist in both client/local and ipn/localapi).
            local = pathlib.Path(source_dir) / path.replace("/", "__")
            if not local.exists():
                raise SystemExit(f"ERROR: {local} not found (--source-dir)")
            sources[path] = local.read_text()
        else:
            sources[path] = fetch(revision, path)
    return sources


def derive_maturity(go_text):
    """Map exported function name -> stable | unstable | unspecified."""
    derived = {}
    comment = []
    for line in go_text.splitlines():
        if line.startswith("//"):
            comment.append(line)
            continue
        match = FUNC_RE.match(line)
        if match:
            name = match.group(1)
            block = "\n".join(comment)
            if UNSTABLE_RE.search(block):
                derived[name] = "unstable"
            elif STABLE_RE.search(block):
                derived[name] = "stable"
            else:
                derived[name] = "unspecified"
        # Any non-comment line (code or blank) ends the doc-comment block:
        # Go doc comments must be contiguous and adjacent to the declaration.
        comment = []
    return derived


def symbols(field):
    return [s.strip() for s in field.split("/") if s.strip()]


CONDITION_TOKEN_RE = re.compile(
    r'buildfeatures\.(Has[A-Za-z0-9]+)|runtime\.GOOS == "([a-z]+)"')
STATIC_ENTRY_RE = re.compile(r'^\t"([^"]+)":\s+\(\*Handler\)\.')
REGISTER_RE = re.compile(r'Register\("([^"]+)"')


def derive_gates(localapi_text):
    """Map registration name -> gate expression from ipn/localapi/localapi.go.

    Static handler-map entries are "core"; Register() calls inside an
    ``if <build conditions> {`` block carry the condition, with
    ``buildfeatures.HasX`` rendered as ``HasX`` and GOOS comparisons as the
    bare OS name, joined by ``||`` in source order.
    """
    gates = {}
    in_static_map = False
    condition = None
    for line in localapi_text.splitlines():
        if line.startswith("var handler = map[string]LocalAPIHandler{"):
            in_static_map = True
            continue
        if in_static_map:
            if line.startswith("}"):
                in_static_map = False
                continue
            match = STATIC_ENTRY_RE.match(line)
            if match:
                gates[match.group(1)] = "core"
            continue
        stripped = line.strip()
        if stripped.startswith("if ") and stripped.endswith("{"):
            tokens = [a or b for a, b in CONDITION_TOKEN_RE.findall(stripped)]
            condition = " || ".join(tokens) if tokens else None
            continue
        if stripped == "}":
            condition = None
            continue
        match = REGISTER_RE.search(stripped)
        if match and condition:
            gates[match.group(1)] = condition
    return gates


def derive_file_gates(go_text, path):
    """Map registration name -> gate for a build-tagged handler file.

    These files register unconditionally in init(); the gate is the
    ``Has<X>`` feature implied by the file's ``//go:build !ts_omit_x`` tag
    (platform-only terms like !ios are ignored — they describe OSes with no
    reachable LocalAPI daemon, not build features).
    """
    tag_line = next(
        (l for l in go_text.splitlines() if l.startswith("//go:build")), "")
    features = [
        OMIT_TAG_FEATURES[t] for t in re.findall(r"!(ts_omit_[a-z0-9_]+)", tag_line)
        if t in OMIT_TAG_FEATURES]
    unknown = [
        t for t in re.findall(r"!(ts_omit_[a-z0-9_]+)", tag_line)
        if t not in OMIT_TAG_FEATURES]
    if unknown:
        raise SystemExit(
            f"ERROR: {path} has unmapped build tags {unknown}; extend "
            f"OMIT_TAG_FEATURES")
    gate = " && ".join(features) if features else "core"
    return {m.group(1): gate for m in REGISTER_RE.finditer(go_text)}


def main():
    source_dir = None
    if "--source-dir" in sys.argv:
        source_dir = sys.argv[sys.argv.index("--source-dir") + 1]

    data = json.loads(MANIFEST.read_text())
    provenance = data["upstream_provenance"]
    revision = provenance["revision"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise SystemExit(
            f"ERROR: upstream_provenance.revision must be a full commit SHA, "
            f"got {revision!r}")

    # Drift mode: validate the manifest's expectations against a DIFFERENT
    # upstream revision (typically current main). Mismatches then mean
    # "upstream moved", not "the manifest is wrong" — the scheduled
    # upstream-drift workflow uses this to open a re-pin issue.
    if "--against-revision" in sys.argv:
        revision = sys.argv[sys.argv.index("--against-revision") + 1]
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise SystemExit(
                f"ERROR: --against-revision must be a full commit SHA, "
                f"got {revision!r}")
        print(f"drift mode: checking manifest (pinned "
              f"{provenance['revision'][:12]}) against {revision[:12]}")

    sources = load_sources(revision, source_dir)
    derived = {}
    for path in SOURCE_FILES:
        if path.startswith("client/local/"):
            derived.update(derive_maturity(sources[path]))

    problems = []

    # 1. Per-endpoint maturity, with per-symbol exceptions.
    for entry in data["endpoints"]:
        name = entry["endpoint"]
        overrides = entry.get("upstream_symbol_maturity", {})
        for symbol in symbols(entry.get("upstream_symbol", "")):
            expected = overrides.get(symbol, entry["upstream_maturity"])
            actual = derived.get(symbol)
            if actual is None:
                problems.append(
                    f"{name}: upstream symbol {symbol} not found at {revision[:12]}")
            elif actual != expected:
                problems.append(
                    f"{name}: {symbol} is upstream-{actual}, manifest says {expected}")
        for symbol in overrides:
            if symbol not in symbols(entry.get("upstream_symbol", "")):
                problems.append(
                    f"{name}: upstream_symbol_maturity names {symbol}, which is "
                    f"not in upstream_symbol")

    # 2. The stable-gap ledger may only contain upstream-stable symbols.
    for gap in data["upstream_stable_unimplemented"]:
        for symbol in symbols(gap["go_symbol"]):
            actual = derived.get(symbol)
            if actual is None:
                problems.append(
                    f"stable-gap ledger: {symbol} not found at {revision[:12]}")
            elif actual != "stable":
                problems.append(
                    f"stable-gap ledger: {symbol} is upstream-{actual}, "
                    f"so it does not belong in the stable-parity ledger")

    # 4. Gates: manifest gate == registration condition in localapi.go.
    #    Endpoints registered from feature packages (serve-config, cert/,
    #    debug-optional-features, ...) don't appear there and are skipped.
    derived_gates = derive_gates(sources["ipn/localapi/localapi.go"])
    for path in GATED_HANDLER_FILES:
        derived_gates.update(derive_file_gates(sources[path], path))
    skipped_gates = []
    for entry in data["endpoints"]:
        name = entry["endpoint"]
        expected_gate = derived_gates.get(name)
        if expected_gate is None:
            skipped_gates.append(name)
            continue
        if entry.get("gate") != expected_gate:
            problems.append(
                f"{name}: gate is {entry.get('gate')!r}, but localapi.go at "
                f"{revision[:12]} registers it under {expected_gate!r}")

    # 3. Capability version: upstream constant == provenance == Swift default.
    capability_match = re.search(
        r"CurrentCapabilityVersion CapabilityVersion = (\d+)",
        sources["tailcfg/tailcfg.go"])
    if not capability_match:
        problems.append("could not locate CurrentCapabilityVersion in tailcfg.go")
    else:
        upstream_capability = int(capability_match.group(1))
        if upstream_capability != provenance["capability_version"]:
            problems.append(
                f"capability_version: upstream has {upstream_capability} at the "
                f"pinned revision, manifest says {provenance['capability_version']}")
        swift_match = re.search(
            r"defaultCapabilityVersion = (\d+)", SWIFT_CONFIG.read_text())
        if not swift_match:
            problems.append("could not locate defaultCapabilityVersion in Swift source")
        elif int(swift_match.group(1)) != upstream_capability:
            problems.append(
                f"defaultCapabilityVersion is {swift_match.group(1)}, upstream "
                f"has {upstream_capability} at the pinned revision")

    if problems:
        for problem in problems:
            print(f"MISMATCH  {problem}")
        sys.exit(1)
    checked = sum(
        len(symbols(e.get("upstream_symbol", ""))) for e in data["endpoints"])
    gates_checked = len(data["endpoints"]) - len(skipped_gates)
    print(f"ok: {checked} endpoint symbols + {gates_checked} gates + "
          f"stable-gap ledger + capability version verified against "
          f"{revision[:12]} (gates skipped, registered outside localapi.go: "
          f"{', '.join(skipped_gates) or 'none'})")


if __name__ == "__main__":
    main()
