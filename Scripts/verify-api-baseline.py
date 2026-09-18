#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David E. Weekly
"""
Verifies that the current SwiftPM symbol graph contains all public symbols
recorded in Scripts/api-baseline-1.0.json, ensuring the 1.0 public API freeze is upheld.
"""

import json
import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
BASELINE_PATH = os.path.join(SCRIPT_DIR, "api-baseline-1.0.json")
SYMBOL_GRAPH_DIR = os.path.join(ROOT_DIR, ".build", "out", "symbolgraph")


def extract_symbols(path):
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        d = json.load(f)
    result = {}
    for s in d.get("symbols", []):
        if s.get("accessLevel") == "public":
            precise = s["identifier"]["precise"]
            title = s.get("names", {}).get("title", precise)
            kind = s.get("kind", {}).get("identifier", "")
            decl = "".join([frag["spelling"] for frag in s.get("declarationFragments", [])])
            result[precise] = {
                "title": title,
                "kind": kind,
                "declaration": decl,
            }
    return result


def ensure_symbol_graphs():
    tc_path = os.path.join(SYMBOL_GRAPH_DIR, "TailscaleClient.symbols.json")
    tcm_path = os.path.join(SYMBOL_GRAPH_DIR, "TailscaleClientMocks.symbols.json")
    if not (os.path.exists(tc_path) and os.path.exists(tcm_path)):
        print("Symbol graph missing. Running swift package dump-symbol-graph...")
        cmd = ["swift", "package", "dump-symbol-graph"]
        res = subprocess.run(cmd, cwd=ROOT_DIR, capture_output=True, text=True)
        if res.returncode != 0:
            print(f"Error dumping symbol graph:\n{res.stderr}", file=sys.stderr)
            sys.exit(1)
    return tc_path, tcm_path


def main():
    if not os.path.exists(BASELINE_PATH):
        print(f"ERROR: Baseline file {BASELINE_PATH} not found.", file=sys.stderr)
        sys.exit(1)

    with open(BASELINE_PATH, "r", encoding="utf-8") as f:
        baseline = json.load(f)

    tc_path, tcm_path = ensure_symbol_graphs()
    current_modules = {
        "TailscaleClient": extract_symbols(tc_path),
        "TailscaleClientMocks": extract_symbols(tcm_path),
    }

    errors = []
    total_verified = 0

    for mod_name, base_symbols in baseline.get("modules", {}).items():
        curr_symbols = current_modules.get(mod_name)
        if curr_symbols is None:
            errors.append(f"Module {mod_name} symbol graph could not be extracted.")
            continue

        for precise, expected in base_symbols.items():
            total_verified += 1
            if precise not in curr_symbols:
                errors.append(
                    f"MISSING 1.0 API symbol in {mod_name}: '{expected.get('title')}' "
                    f"[{expected.get('kind')}] ({precise})"
                )
            else:
                actual = curr_symbols[precise]
                if expected.get("declaration") and actual.get("declaration"):
                    if expected["declaration"] != actual["declaration"]:
                        errors.append(
                            f"CHANGED 1.0 API declaration in {mod_name} for '{expected.get('title')}':\n"
                            f"  Expected: {expected['declaration']}\n"
                            f"  Actual:   {actual['declaration']}"
                        )

    if errors:
        print(f"ERROR: 1.0 API baseline check failed with {len(errors)} issue(s):", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        sys.exit(1)

    print(f"API freeze verification passed: {total_verified} baseline symbols verified intact across 1.0 public modules.")
    sys.exit(0)


if __name__ == "__main__":
    main()
