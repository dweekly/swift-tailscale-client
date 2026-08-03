#!/usr/bin/env python3
"""Mechanized model-conformance audit (the API-conventions section of
ROADMAP.md as an executable check, not a one-time review).

For every public Codable struct in Sources/TailscaleClient (wire models):
  - must conform to Sendable and Equatable
  - must declare a public init (memberwise-style, for consumer fixtures
    and SwiftUI previews)

For every public raw-value (String/Int) Codable enum DECODED from the wire:
  - must have a tolerant fallback (`case other`/`case unknown`) or a custom
    `init(from:)`, so upstream adding values never breaks decoding.
    Request-only enums (values we send, never decode) are allowlisted.

The check is textual on purpose: it needs no toolchain, runs in the same
CI job as the other docs-as-code gates, and fails loudly with file/line
context. If it misfires on a new pattern, extend the allowlists with a
comment saying why.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "TailscaleClient"

# Request-side enums: encoded into query items/bodies, never decoded from
# daemon responses, so a tolerant fallback case is meaningless.
REQUEST_ONLY_ENUMS = {
    "PingType",  # ping ?type= parameter
    "CertKind",  # cert/<domain> ?type= parameter
    "WhoIsIPProtocol",  # whois ?proto= parameter
}

# Codable structs that are deliberately not Equatable, with the reason.
EQUATABLE_EXEMPT = {}


def declaration_blocks(text, keyword):
    """Yield (name, conformances, body, line) for each top-level or nested
    `public <keyword> Name: conformances { body }`."""
    for match in re.finditer(
            rf"public (?:indirect )?{keyword} (\w+)\s*(?::\s*([^{{]+))?\{{", text):
        name = match.group(1)
        conformances = (match.group(2) or "").strip()
        # Brace-match to find the body.
        depth = 1
        i = match.end()
        while i < len(text) and depth > 0:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        body = text[match.end():i - 1]
        line = text[:match.start()].count("\n") + 1
        yield name, conformances, body, line


def main():
    problems = []
    structs = 0
    enums = 0
    for path in sorted(SOURCES.rglob("*.swift")):
        text = path.read_text()
        rel = path.relative_to(ROOT)

        for name, conformances, body, line in declaration_blocks(text, "struct"):
            if "Codable" not in conformances:
                continue
            structs += 1
            if "Sendable" not in conformances:
                problems.append(f"{rel}:{line}: struct {name} (Codable) is not Sendable")
            if "Equatable" not in conformances and name not in EQUATABLE_EXEMPT:
                problems.append(f"{rel}:{line}: struct {name} (Codable) is not Equatable")
            if not re.search(r"public init\s*\(", body):
                problems.append(
                    f"{rel}:{line}: struct {name} (Codable) has no public init — "
                    f"consumers can't build fixtures/previews")

        for name, conformances, body, line in declaration_blocks(text, "enum"):
            parts = [c.strip() for c in conformances.split(",")]
            if "Codable" not in parts or not ({"String", "Int"} & set(parts)):
                continue
            enums += 1
            if name in REQUEST_ONLY_ENUMS:
                continue
            # A custom init(from:) alone proves nothing — a strict decoder
            # that throws on unknown raw values would pass, which is the
            # exact failure this gate exists to prevent. Tolerant means the
            # decoder demonstrably falls back: `?? .other` /
            # `self = .other` (or .unknown) inside the enum body. A bare
            # fallback case without a custom decoder is also insufficient,
            # because synthesized raw-value decoding still throws.
            has_custom_init = re.search(r"init\s*\(\s*from", body)
            has_fallback_assignment = re.search(
                r"(\?\?\s*\.(other|unknown)\b|self\s*=\s*\.(other|unknown)\b)", body)
            if not (has_custom_init and has_fallback_assignment):
                problems.append(
                    f"{rel}:{line}: enum {name} (raw-value, Codable) decodes from "
                    f"the wire but lacks a demonstrably tolerant decoder — it "
                    f"needs a custom init(from:) that falls back to .other/"
                    f".unknown (`?? .other` or `self = .other`); upstream adding "
                    f"a value must never break decoding. Allowlist it in "
                    f"REQUEST_ONLY_ENUMS only if it is never decoded.")

    if problems:
        for p in problems:
            print(f"NONCONFORMANT  {p}")
        sys.exit(1)
    print(f"ok: {structs} Codable structs and {enums} wire enums conform to the "
          f"API conventions (inits, Sendable/Equatable, tolerant decoding)")


if __name__ == "__main__":
    main()
