#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David E. Weekly
"""
Verifies that a fresh SwiftPM symbol graph contains all public symbols
and relationships (protocol conformances, memberships, requirements)
recorded in Scripts/api-baseline-1.0.json, ensuring the 1.0 public API freeze is upheld.
"""

import json
import os
import re
import shutil
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
BASELINE_PATH = os.path.join(SCRIPT_DIR, "api-baseline-1.0.json")
SYMBOL_GRAPH_DIR = os.path.join(ROOT_DIR, ".build", "out", "symbolgraph")


def extract_symbols_and_relationships(path):
    if not os.path.exists(path):
        return None, None
    with open(path, "r", encoding="utf-8") as f:
        d = json.load(f)
    symbols = {}
    for s in d.get("symbols", []):
        if s.get("accessLevel") == "public":
            precise = s["identifier"]["precise"]
            title = s.get("names", {}).get("title", precise)
            kind = s.get("kind", {}).get("identifier", "")
            decl = "".join([frag["spelling"] for frag in s.get("declarationFragments", [])])
            symbols[precise] = {
                "title": title,
                "kind": kind,
                "declaration": decl,
            }
    relationships = {}
    for r in d.get("relationships", []):
        kind = r.get("kind")
        src = r.get("source")
        tgt = r.get("target")
        k = f"{kind}::{src}::{tgt}"
        relationships[k] = {
            "kind": kind,
            "source": src,
            "target": tgt,
            "targetFallback": r.get("targetFallback", ""),
        }
    return symbols, relationships


def normalize_declaration(declaration):
    """Normalize known Swift 6.3/6.4 graph spelling differences, not API changes."""
    declaration = declaration.replace("any Error & Sendable", "any Error")
    declaration = re.sub(r"\bany (Error|Decoder|Encoder)\b", r"\1", declaration)
    for qualified in ("LocalAPIDiscovery.Result", "StreamingResponse.AsyncIterator",
                      "NetworkInterfaceDiscovery.InterfaceInfo", "Netcheck.Options",
                      "MockTransport.Handler", "MockTransport.StreamHandler"):
        declaration = declaration.replace(qualified, qualified.rsplit(".", 1)[1])
    return declaration


def synthesized_aliases(expected, current):
    """Match inherited members by recipient and full signature across SDK USRs.

    Authored symbols and protocol conformance targets still require exact IDs.
    In particular, newer standard libraries change Equatable's != mangling.
    """
    aliases = {}
    for precise, symbol in expected.items():
        if precise in current or "::SYNTHESIZED::" not in precise:
            continue
        recipient = precise.split("::SYNTHESIZED::", 1)[1]
        candidates = [key for key, actual in current.items()
                      if key.endswith("::SYNTHESIZED::" + recipient)
                      and actual["title"] == symbol["title"]
                      and actual["kind"] == symbol["kind"]
                      and normalize_declaration(actual["declaration"]) == normalize_declaration(symbol["declaration"])]
        if len(candidates) == 1:
            aliases[precise] = candidates[0]
    return aliases


def relationship_key(relationship, aliases):
    source = aliases.get(relationship["source"], relationship["source"])
    target = aliases.get(relationship["target"], relationship["target"])
    return f"{relationship['kind']}::{source}::{target}"


def dump_fresh_symbol_graphs():
    """Always wipes existing symbol graph output and dumps fresh graphs from reviewed source."""
    # Some SwiftPM versions enumerate the generated test runner when dumping
    # graphs; a fresh checkout must build it before the extractor can load it.
    subprocess.run(["swift", "build", "--build-tests"], cwd=ROOT_DIR, check=True)
    bin_dir = subprocess.check_output(
        ["swift", "build", "--show-bin-path"], cwd=ROOT_DIR, text=True).strip()
    graph_dirs = [SYMBOL_GRAPH_DIR, os.path.join(os.path.dirname(bin_dir), "symbolgraph")]
    for directory in graph_dirs:
        if os.path.exists(directory):
            shutil.rmtree(directory)

    print("Dumping fresh symbol graph from current source...")
    res = subprocess.run(["swift", "package", "dump-symbol-graph"],
                         cwd=ROOT_DIR, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"Error dumping symbol graph:\n{res.stderr}", file=sys.stderr)
        sys.exit(1)

    for directory in graph_dirs:
        tc_path = os.path.join(directory, "TailscaleClient.symbols.json")
        tcm_path = os.path.join(directory, "TailscaleClientMocks.symbols.json")
        if os.path.exists(tc_path) and os.path.exists(tcm_path):
            return tc_path, tcm_path
    print(f"Fresh symbol graph outputs not found in {graph_dirs}", file=sys.stderr)
    sys.exit(1)


def main():
    if not os.path.exists(BASELINE_PATH):
        print(f"ERROR: Baseline file {BASELINE_PATH} not found.", file=sys.stderr)
        sys.exit(1)

    with open(BASELINE_PATH, "r", encoding="utf-8") as f:
        baseline = json.load(f)

    tc_path, tcm_path = dump_fresh_symbol_graphs()

    tc_syms, tc_rels = extract_symbols_and_relationships(tc_path)
    tcm_syms, tcm_rels = extract_symbols_and_relationships(tcm_path)

    current_modules = {
        "TailscaleClient": tc_syms,
        "TailscaleClientMocks": tcm_syms,
    }
    current_relationships = {
        "TailscaleClient": tc_rels,
        "TailscaleClientMocks": tcm_rels,
    }

    aliases = {module: synthesized_aliases(symbols, current_modules.get(module) or {})
               for module, symbols in baseline.get("modules", {}).items()}
    errors = []
    total_symbols_verified = 0
    total_relationships_verified = 0

    # 1. Verify Symbols
    for mod_name, base_symbols in baseline.get("modules", {}).items():
        curr_symbols = current_modules.get(mod_name)
        if curr_symbols is None:
            errors.append(f"Module {mod_name} symbol graph could not be extracted.")
            continue

        for precise, expected in base_symbols.items():
            total_symbols_verified += 1
            resolved = aliases[mod_name].get(precise, precise)
            if resolved not in curr_symbols:
                errors.append(
                    f"MISSING 1.0 API symbol in {mod_name}: '{expected.get('title')}' "
                    f"[{expected.get('kind')}] ({precise})"
                )
            else:
                actual = curr_symbols[resolved]
                if expected.get("declaration") and actual.get("declaration"):
                    if normalize_declaration(expected["declaration"]) != normalize_declaration(actual["declaration"]):
                        errors.append(
                            f"CHANGED 1.0 API declaration in {mod_name} for '{expected.get('title')}':\n"
                            f"  Expected: {expected['declaration']}\n"
                            f"  Actual:   {actual['declaration']}"
                        )

    # 2. Verify Relationships (protocol conformances, memberOf, requirementOf)
    for mod_name, base_rels in baseline.get("relationships", {}).items():
        curr_rels = current_relationships.get(mod_name)
        if curr_rels is None:
            errors.append(f"Module {mod_name} relationships could not be extracted.")
            continue

        for rel_key, expected in base_rels.items():
            total_relationships_verified += 1
            if relationship_key(expected, aliases.get(mod_name, {})) not in curr_rels:
                kind = expected.get("kind", "relationship")
                target = expected.get("targetFallback") or expected.get("target")
                errors.append(
                    f"MISSING 1.0 API {kind} in {mod_name}: '{expected.get('source')}' -> '{target}'"
                )

    if errors:
        print(f"ERROR: 1.0 API baseline check failed with {len(errors)} issue(s):", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        sys.exit(1)

    print(
        f"API freeze verification passed: {total_symbols_verified} baseline symbols and "
        f"{total_relationships_verified} relationships verified intact across 1.0 public modules."
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
