#!/usr/bin/env python3
"""
Scripts/check-governance.py - Programmatic Governance, Maintenance & Security Policy Checker.

Automated verification of:
1. Contribution, Provenance & DCO:
   - DCO v1.1 'Signed-off-by:' trailer requirement on git commits in specified range.
   - Clean MIT license verification & zero-dependency third-party inventory.
2. Maintenance, Security & Release Ownership:
   - Primary release owner and designated backup maintainer definitions.
   - Security triage SLAs, reporting contact, and CVE/GHSA coordination procedures.
   - Tag immutability (published tags are never moved) and post-release patch protocol.
3. Release Checklist & Rehearsal Readiness:
   - Verification that Documentation/RELEASING.md references all 1.0 automated tooling.
   - Verification that Documentation/EXTERNAL-REVIEW.md exists and covers all four core subsystems.
   - Detection of stale future-tense text in release documentation.

Zero external dependencies: uses only Python 3 standard library.
"""

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from typing import Any, Dict, List, Optional, Tuple

ROOT = pathlib.Path(__file__).resolve().parent
while ROOT.name and not (ROOT / "Package.swift").exists():
    ROOT = ROOT.parent
if not ROOT.name:
    ROOT = pathlib.Path.cwd()


@dataclass
class CheckResult:
    check: str
    passed: bool
    details: str
    remediation: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def run_cmd(cmd: List[str], cwd: Optional[pathlib.Path] = None) -> Tuple[int, str, str]:
    """Runs a shell command returning (returncode, stdout, stderr)."""
    try:
        res = subprocess.run(
            cmd,
            cwd=str(cwd or ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        return res.returncode, res.stdout.strip(), res.stderr.strip()
    except FileNotFoundError:
        return 127, "", f"Command not found: {cmd[0]}"


class GovernanceChecker:
    def __init__(self, root: pathlib.Path = ROOT, verbose: bool = False):
        self.root = root
        self.verbose = verbose
        self.results: List[CheckResult] = []

    def check_license_and_inventory(self) -> CheckResult:
        """Verifies clean MIT license and zero-dependency library products."""
        license_path = self.root / "LICENSE"
        if not license_path.exists():
            return CheckResult(
                check="license_and_inventory",
                passed=False,
                details="LICENSE file missing from repository root.",
                remediation="Ensure standard MIT LICENSE is present at repository root.",
            )

        content = license_path.read_text(encoding="utf-8")
        if "MIT License" not in content or "Permission is hereby granted" not in content:
            return CheckResult(
                check="license_and_inventory",
                passed=False,
                details="LICENSE file does not contain standard MIT License text.",
                remediation="Restore standard MIT License header and clauses.",
            )

        if "David E. Weekly" not in content:
            return CheckResult(
                check="license_and_inventory",
                passed=False,
                details="LICENSE file missing copyright holder David E. Weekly.",
                remediation="Include 'Copyright (c) <years> David E. Weekly' in LICENSE.",
            )

        # Inspect Package.swift to verify library targets have zero external dependencies
        pkg_path = self.root / "Package.swift"
        if not pkg_path.exists():
            return CheckResult(
                check="license_and_inventory",
                passed=False,
                details="Package.swift missing.",
                remediation="Restore Package.swift.",
            )

        pkg_content = pkg_path.read_text(encoding="utf-8")
        
        # Verify TailscaleClient target has no external package dependencies
        # Target definition should be .target(name: "TailscaleClient") without dependencies
        ts_target_match = re.search(r'\.target\(\s*name:\s*"TailscaleClient"\s*(?:,\s*dependencies:\s*\[([^\]]*)\])?\s*\)', pkg_content)
        if not ts_target_match:
            return CheckResult(
                check="license_and_inventory",
                passed=False,
                details="Cannot parse TailscaleClient target definition in Package.swift.",
                remediation="Verify Target definition for TailscaleClient in Package.swift.",
            )

        deps = ts_target_match.group(1)
        if deps and deps.strip():
            return CheckResult(
                check="license_and_inventory",
                passed=False,
                details=f"TailscaleClient library target must have 0 external dependencies, found: {deps}",
                remediation="Ensure TailscaleClient target has zero external dependencies.",
            )

        return CheckResult(
            check="license_and_inventory",
            passed=True,
            details="Clean MIT license verified. TailscaleClient has zero external third-party dependencies.",
        )

    def check_dco(self, commit_range: Optional[str] = None) -> CheckResult:
        """Verifies DCO v1.1 'Signed-off-by:' trailer on commits in range."""
        if not commit_range:
            # By default, check HEAD commit
            commit_range = "HEAD~1..HEAD"

        rc, log_output, err = run_cmd(["git", "log", commit_range, "--format=%H%x01%an%x01%ae%x01%B%x02"], cwd=self.root)
        if rc != 0:
            # If commit range is invalid (e.g., shallow clone or single commit repo), fallback to HEAD only
            rc, log_output, err = run_cmd(["git", "log", "-1", "--format=%H%x01%an%x01%ae%x01%B%x02"], cwd=self.root)
            if rc != 0:
                return CheckResult(
                    check="dco_compliance",
                    passed=False,
                    details=f"Failed to inspect git commits via git log: {err}",
                    remediation="Ensure repository git history is accessible.",
                )

        commits = [c for c in log_output.split("\x02") if c.strip()]
        dco_pattern = re.compile(r"^Signed-off-by:\s+([^<]+)\s+<([^@>]+@[^>]+)>", re.MULTILINE)
        placeholder_names = {"jane doe", "john doe", "your name", "author name"}

        missing_dco = []
        for c in commits:
            parts = c.strip().split("\x01")
            if len(parts) < 4:
                continue
            sha, author_name, author_email, body = parts[0], parts[1], parts[2], parts[3]
            
            # Skip automated merge or bot commits if configured
            if "[bot]" in author_name.lower():
                continue

            # Historical commits prior to DCO enforcement in PR 14 Part 2 (up to and including 2b671797) are exempt
            if sha.startswith("2b671797"):
                continue

            matches = dco_pattern.findall(body)
            if not matches:
                missing_dco.append(f"{sha[:8]} ({author_name}: {body.strip().splitlines()[0]})")
            else:
                for sign_name, sign_email in matches:
                    if sign_name.strip().lower() in placeholder_names:
                        missing_dco.append(f"{sha[:8]} (Placeholder name '{sign_name}' in Signed-off-by)")

        if missing_dco:
            return CheckResult(
                check="dco_compliance",
                passed=False,
                details=f"{len(missing_dco)} commit(s) missing valid DCO sign-off in range '{commit_range}': " + "; ".join(missing_dco[:5]),
                remediation="Ensure commits include 'Signed-off-by: Full Name <email>' using `git commit -s`.",
            )

        return CheckResult(
            check="dco_compliance",
            passed=True,
            details=f"DCO v1.1 compliance verified for checked commit range ({commit_range}).",
        )

    def check_security_policy(self) -> CheckResult:
        """Verifies SECURITY.md exists with contact, SLAs, and CVE/GHSA coordination."""
        sec_path = self.root / "SECURITY.md"
        if not sec_path.exists():
            return CheckResult(
                check="security_policy",
                passed=False,
                details="SECURITY.md missing from repository root.",
                remediation="Create SECURITY.md specifying security policy and reporting channel.",
            )

        content = sec_path.read_text(encoding="utf-8")

        # Contact check
        if "david@weekly.org" not in content:
            return CheckResult(
                check="security_policy",
                passed=False,
                details="SECURITY.md missing primary reporting contact 'david@weekly.org'.",
                remediation="Add security contact email to SECURITY.md.",
            )

        # SLA checks
        sla_requirements = [
            ("Critical", ["48 hours", "14"]),
            ("High", ["3 business days", "30"]),
            ("Medium", ["5 business days"]),
        ]
        for level, keywords in sla_requirements:
            if level not in content:
                return CheckResult(
                    check="security_policy",
                    passed=False,
                    details=f"SECURITY.md missing SLA definition for {level} severity.",
                    remediation=f"Document explicit response and patch SLAs for {level} vulnerabilities.",
                )
            for kw in keywords:
                if kw not in content:
                    return CheckResult(
                        check="security_policy",
                        passed=False,
                        details=f"SECURITY.md missing SLA keyword '{kw}' for {level} severity.",
                        remediation=f"Ensure SLA targets specify '{kw}' for {level} severity.",
                    )

        # CVE / GHSA coordination check
        if "GHSA" not in content and "GitHub Security Advisory" not in content and "CVE" not in content:
            return CheckResult(
                check="security_policy",
                passed=False,
                details="SECURITY.md missing CVE/GHSA coordinated disclosure procedure.",
                remediation="Document CVE and GitHub Security Advisory (GHSA) coordination workflow.",
            )

        return CheckResult(
            check="security_policy",
            passed=True,
            details="SECURITY.md verified: valid contact, CVSS SLA commitments, and CVE/GHSA coordination defined.",
        )

    def check_release_ownership_and_immutability(self) -> CheckResult:
        """Verifies primary owner, designated backup maintainer, and tag immutability."""
        doc_paths = [
            self.root / "SECURITY.md",
            self.root / "Documentation" / "SUPPORT.md",
            self.root / "Documentation" / "RELEASING.md",
        ]
        combined_text = "\n".join(
            p.read_text(encoding="utf-8") for p in doc_paths if p.exists()
        )

        # Primary owner check
        if "David E. Weekly" not in combined_text:
            return CheckResult(
                check="release_ownership",
                passed=False,
                details="Primary release owner (David E. Weekly) not recorded in governance documentation.",
                remediation="Designate David E. Weekly as primary release owner in documentation.",
            )

        # Designated backup maintainer check
        if "backup maintainer" not in combined_text.lower() and "backup release owner" not in combined_text.lower():
            return CheckResult(
                check="release_ownership",
                passed=False,
                details="Designated backup maintainer role is not documented in SUPPORT.md or SECURITY.md.",
                remediation="Document designated backup maintainer role and escalation triggers.",
            )

        # Tag immutability check
        if "never move" not in combined_text.lower() and "immutable" not in combined_text.lower():
            return CheckResult(
                check="release_ownership",
                passed=False,
                details="Documentation missing explicit statement that published git tags are immutable and never moved.",
                remediation="Record tag immutability principle and fast-track patch protocol in RELEASING.md.",
            )

        return CheckResult(
            check="release_ownership",
            passed=True,
            details="Release ownership (primary + designated backup) and tag immutability verified.",
        )

    def check_release_checklist_readiness(self) -> CheckResult:
        """Verifies Documentation/RELEASING.md references 1.0 automated tooling and removes stale text."""
        releasing_path = self.root / "Documentation" / "RELEASING.md"
        if not releasing_path.exists():
            return CheckResult(
                check="release_checklist_readiness",
                passed=False,
                details="Documentation/RELEASING.md missing.",
                remediation="Ensure Documentation/RELEASING.md is present.",
            )

        content = releasing_path.read_text(encoding="utf-8")

        # Check required 1.0 tooling references
        required_tools = [
            "aggregate-release-evidence.py",
            "check-release-consistency.sh",
            "check-api-baseline.sh",
            "generate-endpoint-docs.py",
            "verify-upstream-maturity.py",
            "check-recipe-snippets.py",
            "check-governance.py",
        ]
        missing_tools = [tool for tool in required_tools if tool not in content]
        if missing_tools:
            return CheckResult(
                check="release_checklist_readiness",
                passed=False,
                details=f"Documentation/RELEASING.md release checklist missing automated tooling: {', '.join(missing_tools)}",
                remediation="Update Documentation/RELEASING.md to incorporate all 1.0 release verification tools.",
            )

        # Check for stale text in RELEASING.md
        stale_indicators = [
            "One-time backfill",
            "Retro-create the missing `v0.3.0` tag",
            "from v0.4.0 forward",
        ]
        found_stale = [s for s in stale_indicators if s in content]
        if found_stale:
            return CheckResult(
                check="release_checklist_readiness",
                passed=False,
                details=f"Documentation/RELEASING.md contains stale historical text: {', '.join(found_stale)}",
                remediation="Remove stale historical backfill tasks from active release process in Documentation/RELEASING.md.",
            )

        # Check EXTERNAL-REVIEW.md exists
        ext_review_path = self.root / "Documentation" / "EXTERNAL-REVIEW.md"
        if not ext_review_path.exists():
            return CheckResult(
                check="release_checklist_readiness",
                passed=False,
                details="Documentation/EXTERNAL-REVIEW.md missing.",
                remediation="Ensure external technical review record is documented in Documentation/EXTERNAL-REVIEW.md.",
            )

        ext_content = ext_review_path.read_text(encoding="utf-8")
        subsystems = ["Transport", "Serve", "Discovery", "Streaming"]
        missing_subsystems = [s for s in subsystems if s.lower() not in ext_content.lower()]
        if missing_subsystems:
            return CheckResult(
                check="release_checklist_readiness",
                passed=False,
                details=f"Documentation/EXTERNAL-REVIEW.md missing coverage of subsystems: {', '.join(missing_subsystems)}",
                remediation="Document technical review across transport framing, safe writes, discovery, and streaming.",
            )

        return CheckResult(
            check="release_checklist_readiness",
            passed=True,
            details="Release checklist in RELEASING.md and EXTERNAL-REVIEW.md verified with 1.0 automated tooling.",
        )

    def validate_all(self, dco_range: Optional[str] = None, skip_dco: bool = False) -> bool:
        """Runs all governance checks."""
        self.results = [
            self.check_license_and_inventory(),
            self.check_security_policy(),
            self.check_release_ownership_and_immutability(),
            self.check_release_checklist_readiness(),
        ]
        if not skip_dco:
            self.results.insert(1, self.check_dco(dco_range))

        return all(r.passed for r in self.results)

    def print_report(self) -> None:
        """Prints a structured console report."""
        print("=" * 80)
        print(" swift-tailscale-client 1.0 Governance & Maintenance Policy Rehearsal")
        print("=" * 80)
        all_passed = True
        for r in self.results:
            status_tag = "PASS" if r.passed else "FAIL"
            color_mark = "✓" if r.passed else "✗"
            print(f"[{status_tag}] {color_mark} {r.check}: {r.details}")
            if not r.passed and r.remediation:
                print(f"       Remediation: {r.remediation}")
                all_passed = False
        print("-" * 80)
        if all_passed:
            print("STATUS: All governance, maintenance, and security checks PASSED.")
        else:
            print("STATUS: Governance checks FAILED. Resolve violations above before release.")
        print("=" * 80)


def main() -> None:
    parser = argparse.ArgumentParser(description="Programmatic Governance Policy Checker")
    parser.add_argument("--dco-range", help="Git revision range for DCO check (e.g. origin/main..HEAD)")
    parser.add_argument("--skip-dco", action="store_true", help="Skip DCO trailer verification (for historical runs)")
    parser.add_argument("--json", action="store_true", help="Output results in machine-readable JSON format")
    args = parser.parse_args()

    checker = GovernanceChecker()
    success = checker.validate_all(dco_range=args.dco_range, skip_dco=args.skip_dco)

    if args.json:
        data = {
            "passed": success,
            "checks": [r.to_dict() for r in checker.results],
        }
        print(json.dumps(data, indent=2))
    else:
        checker.print_report()

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
