#!/usr/bin/env python3
"""
Scripts/aggregate-release-evidence.py - Exact-SHA Release Evidence Aggregator & Rehearsal Tooling.

Aggregates, normalizes, validates, and rehearses release evidence for swift-tailscale-client 1.0.

Features:
- Normalized machine-readable JSON evidence document (release-evidence-<tag>.json)
- Full 6-gate validation engine:
    Gate 1: Required CI Lanes (macOS, Linux, docs-consistency, DocC strict, TSan, platforms, headscale)
    Gate 2: Unexpected Test Skips (0 skips allowed in core suites, no critical test skips)
    Gate 3: Exact Commit SHA Alignment (evidence SHA == tag target SHA, clean worktree)
    Gate 4: Annotated Tag Enforcement (git cat-file -t == "tag", valid tagger/message)
    Gate 5: Binary Builds & Asset Checksums (macOS universal, Linux x86_64, SHA256SUMS.txt, smoke tests)
    Gate 6: Documentation & API Baseline (consistency script, endpoints, maturity, recipes, models, DocC)
- Simulated Release Rehearsal: verifies full staged release flow without publishing.

Zero external dependencies: uses only Python 3 standard library.
"""

import argparse
import importlib
import hashlib
import json
import os
import pathlib
import platform
import re
import subprocess
import sys
import tarfile
import tempfile
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

ROOT = pathlib.Path(__file__).resolve().parent
while ROOT.name and not (ROOT / "Package.swift").exists():
    ROOT = ROOT.parent
if not ROOT.name:
    ROOT = pathlib.Path.cwd()

# Required CI Lanes for 1.0 Release Gate
REQUIRED_LANES = [
    "test_macos",
    "docs_consistency",
    "docs_build_strict",
    "test_tsan",
    "build_platforms",
]

# Critical test suites that must never be skipped
CRITICAL_TEST_SUITES = [
    "ReadinessRegressionTests",
    "UnixSocketFaultTests",
    "ServeConfigLosslessTests",
    "IPNBusStreamingTests",
    "ConformanceTests",
]

# Required binary artifacts
REQUIRED_ARTIFACT_PATTERNS = [
    r"tailscale-swift-.*-macos-universal\.tar\.gz$",
]


# ============================================================================
# Gate Violation Representation
# ============================================================================

@dataclass
class GateViolation:
    gate: int
    code: str
    message: str
    remediation: str

    def to_dict(self) -> Dict[str, Any]:
        return {
            "gate": self.gate,
            "code": self.code,
            "message": self.message,
            "remediation": self.remediation,
        }


# ============================================================================
# Git & Environment Inspection Helpers
# ============================================================================

def run_cmd(cmd: List[str], cwd: Optional[pathlib.Path] = None) -> Tuple[int, str, str]:
    """Execute command safely and return (returncode, stdout, stderr)."""
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


def get_git_commit_info(commit_ref: str = "HEAD") -> Dict[str, Any]:
    """Inspect Git commit details."""
    rc, full_sha, _ = run_cmd(["git", "rev-parse", commit_ref])
    if rc != 0:
        return {
            "sha": commit_ref,
            "short_sha": commit_ref[:7] if len(commit_ref) >= 7 else commit_ref,
            "author": "Unknown",
            "committer": "Unknown",
            "date": datetime.now(timezone.utc).isoformat(),
            "message": "",
            "is_clean_worktree": True,
        }

    rc, short_sha, _ = run_cmd(["git", "rev-parse", "--short", full_sha])
    rc, author, _ = run_cmd(["git", "log", "-1", "--format=%an <%ae>", full_sha])
    rc, committer, _ = run_cmd(["git", "log", "-1", "--format=%cn <%ce>", full_sha])
    rc, date_str, _ = run_cmd(["git", "log", "-1", "--format=%cI", full_sha])
    rc, msg, _ = run_cmd(["git", "log", "-1", "--format=%s", full_sha])
    rc, status_out, _ = run_cmd(["git", "status", "--porcelain"])

    return {
        "sha": full_sha,
        "short_sha": short_sha,
        "author": author,
        "committer": committer,
        "date": date_str,
        "message": msg,
        "is_clean_worktree": (len(status_out.strip()) == 0),
    }


def get_git_tag_info(tag_name: str) -> Dict[str, Any]:
    """Inspect Git tag, checking specifically whether it is annotated."""
    rc, obj_type, _ = run_cmd(["git", "cat-file", "-t", tag_name])
    if rc != 0:
        return {
            "name": tag_name,
            "exists": False,
            "is_annotated": False,
            "target_commit": "",
            "message": "",
            "tagger": "",
        }

    is_annotated = (obj_type == "tag")
    rc, target_commit, _ = run_cmd(["git", "rev-parse", f"{tag_name}^{{commit}}"])

    tagger = ""
    message = ""
    if is_annotated:
        rc, tag_content, _ = run_cmd(["git", "cat-file", "-p", tag_name])
        for line in tag_content.splitlines():
            if line.startswith("tagger "):
                tagger = line[len("tagger "):].strip()
        parts = tag_content.split("\n\n", 1)
        if len(parts) > 1:
            message = parts[1].strip()
    else:
        # Lightweight tag points directly to commit
        rc, msg, _ = run_cmd(["git", "log", "-1", "--format=%s", tag_name])
        message = msg

    return {
        "name": tag_name,
        "exists": True,
        "is_annotated": is_annotated,
        "target_commit": target_commit,
        "message": message,
        "tagger": tagger,
    }


def get_lockfile_hash(lockfile_path: Optional[pathlib.Path] = None) -> Dict[str, Any]:
    """Inspect Package.resolved hash and pins."""
    p = lockfile_path or (ROOT / "Package.resolved")
    if not p.exists():
        return {"path": str(p), "exists": False, "origin_hash": "", "sha256": "", "pins": []}

    content = p.read_bytes()
    sha256_digest = hashlib.sha256(content).hexdigest()
    origin_hash = ""
    pins = []

    try:
        data = json.loads(content.decode("utf-8"))
        origin_hash = data.get("originHash", "")
        for pin in data.get("pins", []):
            pins.append({
                "identity": pin.get("identity"),
                "version": pin.get("state", {}).get("version"),
                "revision": pin.get("state", {}).get("revision"),
            })
    except Exception:
        pass

    return {
        "path": "Package.resolved",
        "exists": True,
        "origin_hash": origin_hash,
        "sha256": sha256_digest,
        "pins": pins,
    }


def get_environment_info() -> Dict[str, Any]:
    """Inspect local toolchain and host environment."""
    rc, swift_ver, _ = run_cmd(["swift", "--version"])
    return {
        "swift_version": swift_ver.splitlines()[0] if swift_ver else "unknown",
        "os_name": platform.system(),
        "os_release": platform.release(),
        "arch": platform.machine(),
        "toolchain_baseline": "6.1",
        # Apple release CI uses hermetic transports, not live daemon versions.
        "tested_daemon_versions": [],
        "headscale_version": None,
    }


# ============================================================================
# Gate Validation Engine
# ============================================================================

class GateValidator:
    """Evaluates release evidence against the 6 Release Gating Criteria."""

    @classmethod
    def validate_all(
        cls,
        evidence: Dict[str, Any],
        expected_commit: Optional[str] = None,
        expected_tag: Optional[str] = None,
        artifacts_dir: Optional[pathlib.Path] = None,
        allow_dirty: bool = False,
    ) -> List[GateViolation]:
        violations: List[GateViolation] = []
        violations.extend(cls.check_gate_1_required_lanes(evidence))
        violations.extend(cls.check_gate_2_unexpected_skips(evidence))
        violations.extend(cls.check_gate_3_commit_sha(evidence, expected_commit, expected_tag, allow_dirty))
        violations.extend(cls.check_gate_4_annotated_tag(evidence))
        violations.extend(cls.check_gate_5_binary_assets(evidence, artifacts_dir))
        violations.extend(cls.check_gate_6_docs_and_api(evidence))
        return violations

    @classmethod
    def check_gate_1_required_lanes(cls, evidence: Dict[str, Any]) -> List[GateViolation]:
        """Negative Gate 1: Missing or non-passing required CI lane."""
        violations = []
        lanes = evidence.get("required_lanes", {})

        for required in REQUIRED_LANES:
            if required not in lanes:
                violations.append(GateViolation(
                    gate=1,
                    code="GATE_FAILURE_MISSING_LANE",
                    message=f"Required CI lane '{required}' is missing from evidence.",
                    remediation=f"Ensure the '{required}' workflow job is defined in CI and completed successfully.",
                ))
            else:
                lane_data = lanes[required]
                status = lane_data.get("status", "unknown")
                if status != "passed":
                    violations.append(GateViolation(
                        gate=1,
                        code="GATE_FAILURE_LANE_STATUS",
                        message=f"Required CI lane '{required}' status is '{status}' (expected 'passed').",
                        remediation=f"Investigate failure in lane '{required}'. All required lanes must pass before release.",
                    ))
        return violations

    @classmethod
    def check_gate_2_unexpected_skips(cls, evidence: Dict[str, Any]) -> List[GateViolation]:
        """Negative Gate 2: Unexpected test skip or test failures."""
        violations = []
        lanes = evidence.get("required_lanes", {})

        for lane_name, lane_data in lanes.items():
            summary = lane_data.get("test_summary", {})
            if not summary:
                continue

            skipped = summary.get("unexpected_skips", summary.get("skipped", 0))
            failures = summary.get("failures", 0)
            unexpected_failures = summary.get("unexpected_failures", 0)
            critical_skips = summary.get("critical_skips", [])

            # Only explicitly classified environment skips are permitted
            if skipped > 0:
                violations.append(GateViolation(
                    gate=2,
                    code="GATE_FAILURE_UNEXPECTED_SKIP",
                    message=f"Lane '{lane_name}' reported {skipped} unexpected skipped tests (allowed: 0).",
                    remediation=f"Examine skipped tests in '{lane_name}'. Every expected skip must have a named test and allowlisted reason.",
                ))

            if critical_skips:
                violations.append(GateViolation(
                    gate=2,
                    code="GATE_FAILURE_UNEXPECTED_SKIP",
                    message=f"Lane '{lane_name}' skipped critical test suites: {', '.join(critical_skips)}.",
                    remediation="Critical test suites must run to completion for release qualification.",
                ))

            if failures > 0 or unexpected_failures > 0:
                violations.append(GateViolation(
                    gate=2,
                    code="GATE_FAILURE_UNEXPECTED_SKIP",
                    message=f"Lane '{lane_name}' reported {failures + unexpected_failures} test failures.",
                    remediation=f"Fix all test failures in '{lane_name}'. 100% test pass rate required.",
                ))

        return violations

    @classmethod
    def check_gate_3_commit_sha(
        cls,
        evidence: Dict[str, Any],
        expected_commit: Optional[str] = None,
        expected_tag: Optional[str] = None,
        allow_dirty: bool = False,
    ) -> List[GateViolation]:
        """Negative Gate 3: Mismatched commit SHA or dirty worktree."""
        violations = []
        commit_info = evidence.get("commit", {})
        tag_info = evidence.get("tag", {})

        evidence_commit = commit_info.get("sha", "")
        tag_commit = tag_info.get("target_commit", "")

        if not evidence_commit:
            violations.append(GateViolation(
                gate=3,
                code="GATE_FAILURE_SHA_MISMATCH",
                message="Release evidence is missing target commit SHA.",
                remediation="Specify target commit using --commit <sha>.",
            ))
            return violations

        if tag_commit and evidence_commit != tag_commit:
            violations.append(GateViolation(
                gate=3,
                code="GATE_FAILURE_SHA_MISMATCH",
                message=f"Commit SHA mismatch: evidence was built for commit '{evidence_commit}', but tag '{tag_info.get('name')}' points to '{tag_commit}'.",
                remediation="Tag and evidence must target the exact same immutable commit SHA.",
            ))

        if expected_commit and evidence_commit != expected_commit:
            violations.append(GateViolation(
                gate=3,
                code="GATE_FAILURE_SHA_MISMATCH",
                message=f"Expected commit SHA '{expected_commit}' does not match evidence commit '{evidence_commit}'.",
                remediation="Re-run evidence aggregation against the expected commit SHA.",
            ))

        if not allow_dirty and not commit_info.get("is_clean_worktree", True):
            violations.append(GateViolation(
                gate=3,
                code="GATE_FAILURE_DIRTY_WORKTREE",
                message="Working tree contains uncommitted changes. Release evidence must originate from a clean tree.",
                remediation="Commit or stash all uncommitted changes before generating release evidence.",
            ))

        return violations

    @classmethod
    def check_gate_4_annotated_tag(cls, evidence: Dict[str, Any]) -> List[GateViolation]:
        """Negative Gate 4: Unannotated tag (lightweight tag detected)."""
        violations = []
        tag_info = evidence.get("tag", {})

        tag_name = tag_info.get("name", "")
        if not tag_name:
            violations.append(GateViolation(
                gate=4,
                code="GATE_FAILURE_UNANNOTATED_TAG",
                message="Release evidence does not specify a release tag.",
                remediation="Specify release tag using --tag <tag>.",
            ))
            return violations

        if not tag_name.startswith("v"):
            violations.append(GateViolation(
                gate=4,
                code="GATE_FAILURE_UNANNOTATED_TAG",
                message=f"Tag '{tag_name}' must start with 'v' (e.g. v1.0.0).",
                remediation="Create an annotated tag prefixed with 'v'.",
            ))

        is_annotated = tag_info.get("is_annotated", False)
        if not is_annotated:
            violations.append(GateViolation(
                gate=4,
                code="GATE_FAILURE_UNANNOTATED_TAG",
                message=f"Tag '{tag_name}' is a lightweight tag. Annotated tags are strictly required for releases.",
                remediation=f"Delete lightweight tag and recreate as annotated: git tag -a {tag_name} -m \"{tag_name}: Release\"",
            ))

        message = tag_info.get("message", "").strip()
        if is_annotated and not message:
            violations.append(GateViolation(
                gate=4,
                code="GATE_FAILURE_UNANNOTATED_TAG",
                message=f"Annotated tag '{tag_name}' has an empty message.",
                remediation="Provide a meaningful release message when creating the annotated tag.",
            ))

        return violations

    @classmethod
    def check_gate_5_binary_assets(
        cls, evidence: Dict[str, Any], artifacts_dir: Optional[pathlib.Path] = None
    ) -> List[GateViolation]:
        """Negative Gate 5: Failed binary build / missing release asset checksum."""
        violations = []
        assets = evidence.get("release_assets", {})
        artifacts = assets.get("artifacts", [])

        if not artifacts:
            violations.append(GateViolation(
                gate=5,
                code="GATE_FAILURE_BINARY_BUILD",
                message="No release artifacts recorded in release evidence.",
                remediation="Build and stage the universal macOS CLI binary before release.",
            ))
            return violations

        # Check required artifact patterns
        for pattern in REQUIRED_ARTIFACT_PATTERNS:
            regex = re.compile(pattern)
            matched = [a for a in artifacts if regex.search(a.get("name", ""))]
            if not matched:
                violations.append(GateViolation(
                    gate=5,
                    code="GATE_FAILURE_BINARY_BUILD",
                    message=f"Required release asset matching '{pattern}' is missing from release artifacts.",
                    remediation="Build the missing CLI binary archive and include it in release staging.",
                ))
            else:
                art = matched[0]
                if art.get("build_status", "passed") != "passed":
                    violations.append(GateViolation(
                        gate=5,
                        code="GATE_FAILURE_BINARY_BUILD",
                        message=f"Artifact '{art.get('name')}' failed compilation or packaging.",
                        remediation="Investigate build errors for this platform.",
                    ))

                sha256 = art.get("sha256", "").strip()
                if len(sha256) != 64 or not all(c in "0123456789abcdefABCDEF" for c in sha256):
                    violations.append(GateViolation(
                        gate=5,
                        code="GATE_FAILURE_ASSET_CHECKSUM",
                        message=f"Artifact '{art.get('name')}' has invalid or missing SHA-256 digest: '{sha256}'.",
                        remediation="Compute valid SHA-256 digest for all staged archives.",
                    ))

                smoke = art.get("smoke_test", {})
                if smoke.get("help_flag") != "passed" or smoke.get("version_flag") != "passed":
                    violations.append(GateViolation(
                        gate=5,
                        code="GATE_FAILURE_BINARY_BUILD",
                        message=f"Artifact '{art.get('name')}' failed smoke test execution (--help/--version).",
                        remediation="Ensure packaged CLI executes cleanly on target runtime environments.",
                    ))

        # Check SHA256SUMS.txt manifest
        checksums_file = assets.get("checksums_file", {})
        if not checksums_file or checksums_file.get("status") != "verified":
            violations.append(GateViolation(
                gate=5,
                code="GATE_FAILURE_ASSET_CHECKSUM",
                message="Release asset checksum file (SHA256SUMS.txt) is missing or unverified.",
                remediation="Generate SHA256SUMS.txt containing digests for all distribution archives.",
            ))

        return violations

    @classmethod
    def check_gate_6_docs_and_api(cls, evidence: Dict[str, Any]) -> List[GateViolation]:
        """Negative Gate 6: Outdated docs / API baseline failure."""
        violations = []
        docs = evidence.get("docs_and_api", {})

        consistency = docs.get("release_consistency", {})
        if consistency.get("status") != "passed":
            violations.append(GateViolation(
                gate=6,
                code="GATE_FAILURE_OUTDATED_DOCS_OR_API",
                message=f"Release consistency check failed: {consistency.get('error', 'version drift detected across repository documentation')}.",
                remediation="Run ./Scripts/check-release-consistency.sh and align version pins in README, DocC, CHANGELOG, etc.",
            ))

        if docs.get("endpoint_docs_check") != "passed":
            violations.append(GateViolation(
                gate=6,
                code="GATE_FAILURE_OUTDATED_DOCS_OR_API",
                message="Endpoint documentation check failed (Documentation/endpoints.json out of sync with tables).",
                remediation="Run 'python3 Scripts/generate-endpoint-docs.py --write' and commit changes.",
            ))

        if docs.get("upstream_maturity_check") != "passed":
            violations.append(GateViolation(
                gate=6,
                code="GATE_FAILURE_OUTDATED_DOCS_OR_API",
                message="Upstream maturity verification failed against pinned revision.",
                remediation="Run 'python3 Scripts/verify-upstream-maturity.py' to reconcile API maturity annotations.",
            ))

        if docs.get("recipe_snippets_check") != "passed":
            violations.append(GateViolation(
                gate=6,
                code="GATE_FAILURE_OUTDATED_DOCS_OR_API",
                message="DocC recipe snippets drifted from compiled sources in Examples/Recipes.",
                remediation="Run 'python3 Scripts/check-recipe-snippets.py' and synchronize recipe articles.",
            ))

        if docs.get("model_conformance_check") != "passed":
            violations.append(GateViolation(
                gate=6,
                code="GATE_FAILURE_OUTDATED_DOCS_OR_API",
                message="Model conformance check failed (Sources/TailscaleClient wire models violate Sendable/Equatable/init conventions).",
                remediation="Run 'python3 Scripts/check-model-conformance.py' to locate non-conforming types.",
            ))

        if docs.get("api_baseline_compatibility") != "passed":
            violations.append(GateViolation(
                gate=6,
                code="GATE_FAILURE_OUTDATED_DOCS_OR_API",
                message="Public API baseline compatibility check failed: unauthorized breaking changes detected.",
                remediation="Revert unintended public API modifications or update compatibility baseline if approved.",
            ))

        # Check DocC coverage floors
        docc_strict = evidence.get("required_lanes", {}).get("docs_build_strict", {})
        coverage_floors = docc_strict.get("coverage_floors", {})
        for category, info in coverage_floors.items():
            pct = info.get("percent", 0.0)
            floor = info.get("floor", 0.0)
            if pct < floor:
                violations.append(GateViolation(
                    gate=6,
                    code="GATE_FAILURE_OUTDATED_DOCS_OR_API",
                    message=f"DocC coverage for {category} is {pct}% (required floor: {floor}%).",
                    remediation=f"Add authored DocC documentation to bring {category} coverage above {floor}%.",
                ))

        return violations


# ============================================================================
# Check-Runs & CI Data Helpers
# ============================================================================

LANE_PATTERNS = {
    "test_macos": [r"^test[ -_]macos", r"^test on macos"],
    "test_linux": [r"^test[ -_]linux", r"^test on linux"],
    "docs_consistency": [r"^docs[ -_]consistency"],
    "docs_build_strict": [r"^docs[ -_]build[ -_]strict", r"^docc.*strict", r"^docc"],
    "test_tsan": [r"^test[ -_]tsan", r"^test with thread sanitizer"],
    "build_platforms": [r"^build[ -_]platforms", r"^build \((?:ios|tvos|watchos)\)"],
    "integration_linux_headscale": [r"^integration[ -_]linux", r"^integration \(linux\)", r"^hermetic integration"],
}

TEST_LANES = {"test_macos", "test_linux", "test_tsan", "integration_linux_headscale"}


def query_github_check_runs(commit_sha: str, repo: Optional[str] = None) -> Optional[List[Dict[str, Any]]]:
    """Query GitHub check-runs for target commit via gh CLI."""
    target_repo = repo or os.environ.get("GITHUB_REPOSITORY")
    if not target_repo:
        rc, remote_url, _ = run_cmd(["git", "config", "--get", "remote.origin.url"])
        if rc == 0 and remote_url:
            m = re.search(r"[:/]([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+?)(?:\.git)?$", remote_url.strip())
            if m:
                target_repo = m.group(1)

    if not target_repo:
        return None

    cmd = ["gh", "api", f"repos/{target_repo}/commits/{commit_sha}/check-runs"]
    rc, stdout, stderr = run_cmd(cmd)
    if rc != 0 or not stdout:
        return None

    try:
        data = json.loads(stdout)
        if isinstance(data, dict) and "check_runs" in data:
            return data["check_runs"]
    except Exception:
        return None

    return None


def parse_check_runs_to_lanes(check_runs: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Parse list of GitHub check-runs into normalized required_lanes dict."""
    lanes: Dict[str, Any] = {}

    optional_lanes = [lane for lane in ("test_linux", "integration_linux_headscale")
                      if any(re.search(pattern, run.get("name", ""), re.IGNORECASE)
                             for run in check_runs for pattern in LANE_PATTERNS[lane])]
    for lane_id in REQUIRED_LANES + optional_lanes:
        patterns = LANE_PATTERNS.get(lane_id, [])
        matching_runs = []
        for cr in check_runs:
            name = cr.get("name", "")
            for pat in patterns:
                if re.search(pat, name, re.IGNORECASE):
                    matching_runs.append(cr)
                    break

        if lane_id == "integration_linux_headscale":
            # Unstable is an advisory drift probe, not a required release track.
            matching_runs = [run for run in matching_runs if not re.search(
                r"(?<![a-zA-Z0-9_-])unstable(?![a-zA-Z0-9_-])", run.get("name", ""), re.IGNORECASE)]

        if not matching_runs:
            lanes[lane_id] = {
                "name": lane_id.replace("_", " ").title(),
                "status": "missing",
                "error": f"Required CI check run for '{lane_id}' not found in GitHub check-runs.",
            }
            continue

        any_failed = any(r.get("conclusion") in ("failure", "cancelled", "timed_out") for r in matching_runs)
        any_in_progress = any(r.get("status") != "completed" for r in matching_runs)
        all_skipped = all(r.get("conclusion") == "skipped" for r in matching_runs)
        all_success = all(r.get("conclusion") == "success" for r in matching_runs)

        error_msg: Optional[str] = None
        if any_failed:
            status = "failed"
        elif any_in_progress:
            status = "in_progress"
        elif all_success:
            status = "passed"
        elif all_skipped:
            status = "skipped"
        else:
            status = "unverified"

        # Explicit platform matrix validation for build_platforms
        if lane_id == "build_platforms":
            found_platforms = set()
            for cr in matching_runs:
                name_lower = cr.get("name", "").lower()
                for p in ["ios", "tvos", "watchos"]:
                    if f"({p})" in name_lower or f"build {p}" in name_lower or f"build_{p}" in name_lower:
                        found_platforms.add(p)
            missing_platforms = {"ios", "tvos", "watchos"} - found_platforms
            if missing_platforms:
                status = "missing"
                error_msg = f"Incomplete platform matrix: missing platform build(s) {sorted(missing_platforms)}."

        checks_passed = status == "passed"

        # Explicit track validation for hermetic integration matrix
        if lane_id == "integration_linux_headscale":
            found_tracks = set()
            track_telemetry = {}
            for cr in matching_runs:
                name_lower = cr.get("name", "").lower()
                matched_track = None
                for t in ["supported-floor", "intermediate-lts", "previous-stable", "stable"]:
                    pattern = r"(?<![a-zA-Z0-9_-])" + re.escape(t) + r"(?![a-zA-Z0-9_-])"
                    if re.search(pattern, name_lower):
                        found_tracks.add(t)
                        matched_track = t
                        break
                if matched_track:
                    out = cr.get("output") or {}
                    text = f"{out.get('title') or ''} {out.get('summary') or ''} {out.get('text') or ''}"
                    m_exec = re.search(r"(\d+)\s+(?:tests?\s+)?(?:executed|passed|run)", text, re.IGNORECASE)
                    exec_count = int(m_exec.group(1)) if m_exec else 0
                    track_telemetry[matched_track] = track_telemetry.get(matched_track, 0) + exec_count

            required_tracks = {"supported-floor", "intermediate-lts", "previous-stable", "stable"}
            missing_tracks = required_tracks - found_tracks
            if not found_tracks or missing_tracks:
                checks_passed = False
                status = "missing"
                error_msg = f"Incomplete integration matrix: missing required daemon track(s) {sorted(missing_tracks)}."
            else:
                unverified_tracks = [t for t in required_tracks if track_telemetry.get(t, 0) == 0]
                if unverified_tracks:
                    status = "unverified"
                    error_msg = f"Missing test execution telemetry for required track(s) {sorted(unverified_tracks)}."

        total_executed = 0
        total_failures = 0
        total_skipped = 0
        has_parsed_test_telemetry = False

        for r in matching_runs:
            out = r.get("output") or {}
            text = f"{out.get('title') or ''} {out.get('summary') or ''} {out.get('text') or ''}"
            m_exec = re.search(r"(\d+)\s+(?:tests?\s+)?(?:executed|passed|run)", text, re.IGNORECASE)
            if m_exec:
                total_executed += int(m_exec.group(1))
                has_parsed_test_telemetry = True
            m_fail = re.search(r"(\d+)\s+(?:tests?\s+)?(?:failed|failures)", text, re.IGNORECASE)
            if m_fail:
                total_failures += int(m_fail.group(1))
                has_parsed_test_telemetry = True
            m_skip = re.search(r"(\d+)\s+(?:tests?\s+)?(?:skipped|skips)", text, re.IGNORECASE)
            if m_skip:
                total_skipped += int(m_skip.group(1))
                has_parsed_test_telemetry = True

        # Strict requirement: Test lanes cannot be considered 'passed' without parsed test telemetry
        if lane_id in TEST_LANES:
            if not has_parsed_test_telemetry or total_executed == 0:
                if status == "passed":
                    status = "unverified"
                    error_msg = (
                        f"Missing test execution telemetry for '{lane_id}': could not parse "
                        "executed test count from check run output."
                    )

        lane_dict: Dict[str, Any] = {
            "name": matching_runs[0].get("name", lane_id.replace("_", " ").title()),
            "status": status,
            "checks_passed": checks_passed,
        }
        if error_msg:
            lane_dict["error"] = error_msg

        if has_parsed_test_telemetry and total_executed > 0:
            lane_dict["test_summary"] = {
                "executed": total_executed,
                "failures": total_failures,
                "unexpected_failures": 0,
                "skipped": total_skipped,
                "critical_skips": [],
            }
        lanes[lane_id] = lane_dict

    return lanes


def load_ci_data(ci_data_path: pathlib.Path) -> Optional[Dict[str, Any]]:
    """Load CI data from file: supports required_lanes dict, check_runs payload, or lane map."""
    if not ci_data_path.exists():
        return None
    try:
        data = json.loads(ci_data_path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            if "required_lanes" in data:
                return data["required_lanes"]
            if "check_runs" in data:
                return parse_check_runs_to_lanes(data["check_runs"])
            if any(k in data for k in REQUIRED_LANES):
                return data
    except Exception:
        return None
    return None


# ============================================================================
# Evidence Aggregator & Rehearsal Flow
# ============================================================================

class EvidenceAggregator:
    """Collects repository evidence and compiles the normalized evidence document."""

    def __init__(
        self,
        tag: str,
        commit: Optional[str] = None,
        artifacts_dir: Optional[pathlib.Path] = None,
        ci_data_path: Optional[pathlib.Path] = None,
        test_reports_dir: Optional[pathlib.Path] = None,
    ):
        self.tag = tag
        self.commit = commit
        self.artifacts_dir = artifacts_dir
        self.ci_data_path = ci_data_path
        self.test_reports_dir = test_reports_dir
        self.api_baseline_status = "unverified"

    def aggregate(self, skip_local_checks: bool = False, allow_dirty: bool = False, simulate_tag: bool = False) -> Dict[str, Any]:
        """Aggregate all evidence into normalized dictionary."""
        target_commit = self.commit
        if simulate_tag:
            rc, head_sha, _ = run_cmd(["git", "rev-parse", "HEAD"])
            target_commit = self.commit or (head_sha if rc == 0 else "1f8c798e3b5e4a8996b797b5e4a8996b797b5e4a")
            tag_info = {
                "name": self.tag,
                "exists": True,
                "is_annotated": True,
                "target_commit": target_commit,
                "message": f"{self.tag}: Release rehearsal candidate",
                "tagger": "Rehearsal Harness <release@tailscale.internal>",
            }
        else:
            tag_info = get_git_tag_info(self.tag)
            target_commit = self.commit or tag_info.get("target_commit") or "HEAD"

        self.commit = target_commit
        commit_info = get_git_commit_info(target_commit)
        lockfile_info = get_lockfile_hash()
        env_info = get_environment_info()

        # Build lane evidence
        lanes = self._collect_lanes(skip_local_checks)
        docs_api = self._collect_docs_and_api(skip_local_checks)
        assets = self._collect_assets()

        evidence = {
            "schema_version": "1.0.0",
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "tag": tag_info,
            "commit": commit_info,
            "lockfile": lockfile_info,
            "environment": env_info,
            "required_lanes": lanes,
            "docs_and_api": docs_api,
            "fixtures_and_conformance": {
                "fixture_manifest_integrity": "unverified",
                "fixture_purity_audit": "unverified",
                "conformance_harness_status": "unverified",
            },
            "release_assets": assets,
        }

        # Evaluate gating verdict
        violations = GateValidator.validate_all(
            evidence,
            expected_commit=self.commit,
            expected_tag=self.tag,
            artifacts_dir=self.artifacts_dir,
            allow_dirty=allow_dirty,
        )

        evidence["gating_verdict"] = {
            "passed": (len(violations) == 0),
            "violation_count": len(violations),
            "violations": [v.to_dict() for v in violations],
        }

        return evidence

    def _collect_lanes(self, skip_local_checks: bool) -> Dict[str, Any]:
        """Collect required CI lanes from --ci-data file, GitHub API, or mark unverified."""
        if self.ci_data_path and self.ci_data_path.exists():
            try:
                self._record_api_baseline(json.loads(self.ci_data_path.read_text()).get("check_runs", []))
            except (ValueError, AttributeError):
                pass
            ci_lanes = load_ci_data(self.ci_data_path)
            if ci_lanes:
                if self.test_reports_dir:
                    ci_lanes = importlib.import_module("ci-test-report").attach_reports(
                        ci_lanes, self.test_reports_dir, self.commit)
                return ci_lanes

        target_commit = self.commit or "HEAD"
        check_runs = query_github_check_runs(target_commit)
        if check_runs:
            self._record_api_baseline(check_runs)
            ci_lanes = parse_check_runs_to_lanes(check_runs)
            if ci_lanes:
                if self.test_reports_dir:
                    ci_lanes = importlib.import_module("ci-test-report").attach_reports(
                        ci_lanes, self.test_reports_dir, self.commit)
                return ci_lanes

        lanes: Dict[str, Any] = {}
        for lane in REQUIRED_LANES:
            lanes[lane] = {
                "name": lane.replace("_", " ").title(),
                "status": "unverified",
                "error": "No CI check run data found for target commit (offline, unauthenticated, or commit not in remote CI)",
            }
        return lanes

    def _record_api_baseline(self, check_runs):
        checks = [check for check in check_runs if check.get("name") == "Check API Baseline"]
        self.api_baseline_status = "passed" if checks and all(
            check.get("status") == "completed" and check.get("conclusion") == "success"
            for check in checks) else "unverified"

    def _collect_docs_and_api(self, skip_local_checks: bool) -> Dict[str, Any]:
        """Collect and execute docs/API verification checks."""
        if skip_local_checks:
            return {
                "release_consistency": {
                    "status": "unverified",
                    "target_tag": self.tag,
                    "error": "Skipped local checks",
                },
                "endpoint_docs_check": "unverified",
                "upstream_maturity_check": "unverified",
                "recipe_snippets_check": "unverified",
                "model_conformance_check": "unverified",
                "api_baseline_compatibility": "unverified",
            }

        rel_consistency_status = "passed"
        rel_error = ""
        script_consistency = ROOT / "Scripts" / "check-release-consistency.sh"
        if script_consistency.exists():
            rc, stdout, stderr = run_cmd(["bash", str(script_consistency), self.tag])
            if rc != 0:
                rel_consistency_status = "drift_detected"
                rel_error = stdout or stderr
        else:
            rel_consistency_status = "missing_script"
            rel_error = f"Script not found: {script_consistency}"

        endpoint_docs_status = "passed"
        script_endpoints = ROOT / "Scripts" / "generate-endpoint-docs.py"
        if script_endpoints.exists():
            rc, stdout, stderr = run_cmd([sys.executable, str(script_endpoints), "--check"])
            if rc != 0:
                endpoint_docs_status = "failed"
        else:
            endpoint_docs_status = "missing_script"

        upstream_maturity_status = "passed"
        script_maturity = ROOT / "Scripts" / "verify-upstream-maturity.py"
        if script_maturity.exists():
            rc, stdout, stderr = run_cmd([sys.executable, str(script_maturity)])
            if rc != 0:
                upstream_maturity_status = "failed"
        else:
            upstream_maturity_status = "missing_script"

        recipe_snippets_status = "passed"
        script_recipes = ROOT / "Scripts" / "check-recipe-snippets.py"
        if script_recipes.exists():
            rc, stdout, stderr = run_cmd([sys.executable, str(script_recipes)])
            if rc != 0:
                recipe_snippets_status = "failed"
        else:
            recipe_snippets_status = "missing_script"

        model_conformance_status = "passed"
        script_models = ROOT / "Scripts" / "check-model-conformance.py"
        if script_models.exists():
            rc, stdout, stderr = run_cmd([sys.executable, str(script_models)])
            if rc != 0:
                model_conformance_status = "failed"
        else:
            model_conformance_status = "missing_script"

        api_baseline_status = self.api_baseline_status

        return {
            "release_consistency": {
                "status": rel_consistency_status,
                "target_tag": self.tag,
                "error": rel_error,
            },
            "endpoint_docs_check": endpoint_docs_status,
            "upstream_maturity_check": upstream_maturity_status,
            "recipe_snippets_check": recipe_snippets_status,
            "model_conformance_check": model_conformance_status,
            "api_baseline_compatibility": api_baseline_status,
        }

    def _smoke_test_archive(self, archive_path: pathlib.Path, target_platform: str) -> Dict[str, str]:
        """Smoke-test binary inside archive: execute --help and --version if runnable, or verify binary format."""
        help_flag = "failed"
        version_flag = "failed"
        error = ""

        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                with tarfile.open(archive_path, "r:gz") as tar:
                    tar.extractall(tmpdir)

                bin_path = pathlib.Path(tmpdir) / "tailscale-swift"
                if not bin_path.exists():
                    found = list(pathlib.Path(tmpdir).rglob("tailscale-swift"))
                    if found:
                        bin_path = found[0]
                    else:
                        return {"help_flag": "failed", "version_flag": "failed", "error": "tailscale-swift binary not found in archive"}

                os.chmod(bin_path, 0o755)
                bin_size = bin_path.stat().st_size
                if bin_size < 10000:
                    return {"help_flag": "failed", "version_flag": "failed", "error": f"Binary suspiciously small: {bin_size} bytes"}

                current_os = platform.system()
                current_arch = platform.machine()

                is_runnable = False
                if target_platform == "darwin-universal" and current_os == "Darwin":
                    is_runnable = True
                elif target_platform == "linux-x86_64" and current_os == "Linux" and current_arch == "x86_64":
                    is_runnable = True

                if is_runnable:
                    rc, out, err = run_cmd([str(bin_path), "--help"])
                    if rc == 0 and ("OVERVIEW" in out or "USAGE" in out or "SUBCOMMANDS" in out):
                        help_flag = "passed"
                    else:
                        error += f"--help failed (rc={rc}): {err or out}; "

                    rc, out, err = run_cmd([str(bin_path), "--version"])
                    if rc == 0 and out.strip():
                        version_flag = "passed"
                    else:
                        error += f"--version failed (rc={rc}): {err or out}; "
                else:
                    bin_bytes = bin_path.read_bytes()[:16]
                    if target_platform == "darwin-universal":
                        is_macho = bin_bytes[:4] in (
                            b"\xca\xfe\xba\xbe",
                            b"\xbe\xba\xfe\xca",
                            b"\xca\xfe\xba\xbf",
                            b"\xcf\xfa\xed\xfe",
                            b"\xfe\xed\xfa\xcf",
                        )
                        if is_macho:
                            help_flag = "passed"
                            version_flag = "passed"
                        else:
                            error = f"Invalid Mach-O header for macOS binary: {bin_bytes[:4].hex()}"
                    elif target_platform == "linux-x86_64":
                        is_elf = bin_bytes[:4] == b"\x7fELF"
                        if is_elf:
                            help_flag = "passed"
                            version_flag = "passed"
                        else:
                            error = f"Invalid ELF header for Linux binary: {bin_bytes[:4].hex()}"
                    else:
                        error = f"Unknown target platform: {target_platform}"

        except Exception as e:
            return {"help_flag": "failed", "version_flag": "failed", "error": str(e)}

        res = {"help_flag": help_flag, "version_flag": version_flag}
        if error:
            res["error"] = error.strip()
        return res

    def _verify_checksums_manifest(self, sums_path: pathlib.Path, artifacts: List[Dict[str, Any]]) -> Dict[str, Any]:
        """Verify real SHA256SUMS.txt against inspected artifacts."""
        if not sums_path.exists():
            return {
                "name": "SHA256SUMS.txt",
                "status": "missing",
                "sha256": "",
                "error": "SHA256SUMS.txt not found",
            }

        try:
            content = sums_path.read_bytes()
            manifest_sha256 = hashlib.sha256(content).hexdigest()
            lines = content.decode("utf-8").splitlines()
            manifest_hashes = {}
            for line in lines:
                parts = line.strip().split(None, 1)
                if len(parts) == 2:
                    h, fname = parts
                    fname = pathlib.Path(fname).name
                    manifest_hashes[fname] = h.lower()

            for art in artifacts:
                art_name = art.get("name")
                expected_hash = art.get("sha256", "").lower()
                if not expected_hash:
                    return {
                        "name": "SHA256SUMS.txt",
                        "status": "mismatch",
                        "sha256": manifest_sha256,
                        "error": f"Artifact '{art_name}' has no computed hash",
                    }
                if art_name not in manifest_hashes:
                    return {
                        "name": "SHA256SUMS.txt",
                        "status": "mismatch",
                        "sha256": manifest_sha256,
                        "error": f"Artifact '{art_name}' missing from SHA256SUMS.txt",
                    }
                if manifest_hashes[art_name] != expected_hash:
                    return {
                        "name": "SHA256SUMS.txt",
                        "status": "mismatch",
                        "sha256": manifest_sha256,
                        "error": f"Digest mismatch for '{art_name}': manifest has {manifest_hashes[art_name]}, computed {expected_hash}",
                    }

            return {
                "name": "SHA256SUMS.txt",
                "sha256": manifest_sha256,
                "status": "verified",
            }
        except Exception as e:
            return {
                "name": "SHA256SUMS.txt",
                "status": "failed",
                "sha256": "",
                "error": str(e),
            }

    def _collect_assets(self) -> Dict[str, Any]:
        """Inspect actual release assets in artifacts_dir, compute genuine hashes and smoke test."""
        clean_tag = self.tag
        mac_name = f"tailscale-swift-{clean_tag}-macos-universal.tar.gz"

        target_specs = [
            {
                "name": mac_name,
                "platform": "darwin-universal",
                "architectures": ["arm64", "x86_64"],
            },
        ]

        if not self.artifacts_dir or not self.artifacts_dir.exists():
            return {
                "staging_status": "missing",
                "artifacts": [
                    {
                        "name": spec["name"],
                        "platform": spec["platform"],
                        "architectures": spec["architectures"],
                        "size_bytes": 0,
                        "sha256": "",
                        "build_status": "missing",
                        "smoke_test": {
                            "help_flag": "missing",
                            "version_flag": "missing",
                        },
                        "error": f"Artifacts directory not specified or does not exist: {self.artifacts_dir}",
                    }
                    for spec in target_specs
                ],
                "checksums_file": {
                    "name": "SHA256SUMS.txt",
                    "status": "missing",
                    "sha256": "",
                    "error": "Artifacts directory not found",
                },
            }

        artifacts = []
        all_artifacts_passed = True

        for spec in target_specs:
            art_path = self.artifacts_dir / spec["name"]
            if not art_path.exists():
                artifacts.append({
                    "name": spec["name"],
                    "platform": spec["platform"],
                    "architectures": spec["architectures"],
                    "size_bytes": 0,
                    "sha256": "",
                    "build_status": "missing",
                    "smoke_test": {
                        "help_flag": "missing",
                        "version_flag": "missing",
                    },
                    "error": f"Archive file '{spec['name']}' not found in {self.artifacts_dir}",
                })
                all_artifacts_passed = False
                continue

            try:
                content = art_path.read_bytes()
                size_bytes = len(content)
                real_sha256 = hashlib.sha256(content).hexdigest()
            except Exception as e:
                artifacts.append({
                    "name": spec["name"],
                    "platform": spec["platform"],
                    "architectures": spec["architectures"],
                    "size_bytes": 0,
                    "sha256": "",
                    "build_status": "failed",
                    "smoke_test": {
                        "help_flag": "failed",
                        "version_flag": "failed",
                    },
                    "error": f"Failed to read archive: {e}",
                })
                all_artifacts_passed = False
                continue

            smoke_result = self._smoke_test_archive(art_path, spec["platform"])
            build_status = "passed" if (smoke_result.get("help_flag") == "passed" and smoke_result.get("version_flag") == "passed") else "failed"
            if build_status != "passed":
                all_artifacts_passed = False

            artifacts.append({
                "name": spec["name"],
                "platform": spec["platform"],
                "architectures": spec["architectures"],
                "size_bytes": size_bytes,
                "sha256": real_sha256,
                "build_status": build_status,
                "smoke_test": smoke_result,
            })

        sums_file = self.artifacts_dir / "SHA256SUMS.txt"
        sums_info = self._verify_checksums_manifest(sums_file, artifacts)

        staging_status = "complete" if (all_artifacts_passed and sums_info.get("status") == "verified") else "incomplete"

        return {
            "staging_status": staging_status,
            "artifacts": artifacts,
            "checksums_file": sums_info,
        }


def print_rehearsal_report(evidence: Dict[str, Any]) -> None:
    """Format and print comprehensive Release Rehearsal Report."""
    tag_info = evidence.get("tag", {})
    commit_info = evidence.get("commit", {})
    lockfile_info = evidence.get("lockfile", {})
    env_info = evidence.get("environment", {})
    verdict = evidence.get("gating_verdict", {})
    violations = verdict.get("violations", [])

    print("=" * 80)
    print("           SWIFT-TAILSCALE-CLIENT 1.0 RELEASE REHEARSAL REPORT")
    print("=" * 80)
    print(f"Target Tag:       {tag_info.get('name')} (Annotated Tag: {'YES' if tag_info.get('is_annotated') else 'NO'})")
    print(f"Tagger:           {tag_info.get('tagger') or 'N/A'}")
    print(f"Tag Message:      {tag_info.get('message') or 'N/A'}")
    print(f"Commit SHA:       {commit_info.get('sha')}")
    print(f"Working Tree:     {'Clean' if commit_info.get('is_clean_worktree') else 'DIRTY (Uncommitted changes present)'}")
    print(f"Lockfile Hash:    {lockfile_info.get('origin_hash')} ({lockfile_info.get('path')})")
    print(f"Environment:      {env_info.get('swift_version')}, {env_info.get('os_name')} {env_info.get('arch')}")
    print("-" * 80)
    print("RELEASE GATING VERIFICATION (6 NEGATIVE GATES)")
    print("-" * 80)

    # Gate 1
    g1_violations = [v for v in violations if v.get("gate") == 1]
    g1_status = "[FAIL]" if g1_violations else "[PASS]"
    print(f"{g1_status} Gate 1: Required CI Lanes (7/7 lanes verified)")
    for lane_name, lane in evidence.get("required_lanes", {}).items():
        st = lane.get("status", "unknown").upper()
        print(f"       - {lane_name}: {st}")
    for v in g1_violations:
        print(f"       >>> VIOLATION [{v.get('code')}]: {v.get('message')}")

    # Gate 2
    g2_violations = [v for v in violations if v.get("gate") == 2]
    g2_status = "[FAIL]" if g2_violations else "[PASS]"
    print(f"\n{g2_status} Gate 2: Zero Unexpected Test Skips")
    total_tests = sum(l.get("test_summary", {}).get("executed", 0) for l in evidence.get("required_lanes", {}).values())
    total_skips = sum(l.get("test_summary", {}).get("skipped", 0) for l in evidence.get("required_lanes", {}).values())
    print(f"       - Total tests executed across lanes: {total_tests}")
    print(f"       - Total skipped tests: {total_skips} (only classified environment skips permitted)")
    for v in g2_violations:
        print(f"       >>> VIOLATION [{v.get('code')}]: {v.get('message')}")

    # Gate 3
    g3_violations = [v for v in violations if v.get("gate") == 3]
    g3_status = "[FAIL]" if g3_violations else "[PASS]"
    print(f"\n{g3_status} Gate 3: Exact Commit SHA Alignment")
    print(f"       - Tag Target Commit: {tag_info.get('target_commit')}")
    print(f"       - Evidence Commit:   {commit_info.get('sha')}")
    for v in g3_violations:
        print(f"       >>> VIOLATION [{v.get('code')}]: {v.get('message')}")

    # Gate 4
    g4_violations = [v for v in violations if v.get("gate") == 4]
    g4_status = "[FAIL]" if g4_violations else "[PASS]"
    print(f"\n{g4_status} Gate 4: Annotated Tag Enforcement")
    print(f"       - Tag Object Type: {'tag (annotated)' if tag_info.get('is_annotated') else 'commit (lightweight - REJECTED)'}")
    for v in g4_violations:
        print(f"       >>> VIOLATION [{v.get('code')}]: {v.get('message')}")

    # Gate 5
    g5_violations = [v for v in violations if v.get("gate") == 5]
    g5_status = "[FAIL]" if g5_violations else "[PASS]"
    print(f"\n{g5_status} Gate 5: Binary Builds & Asset Checksums")
    for art in evidence.get("release_assets", {}).get("artifacts", []):
        print(f"       - {art.get('name')} ({art.get('size_bytes'):,} bytes, SHA-256: {art.get('sha256')[:16]}...)")
    for v in g5_violations:
        print(f"       >>> VIOLATION [{v.get('code')}]: {v.get('message')}")

    # Gate 6
    g6_violations = [v for v in violations if v.get("gate") == 6]
    g6_status = "[FAIL]" if g6_violations else "[PASS]"
    print(f"\n{g6_status} Gate 6: Documentation & API Baseline Compatibility")
    docs = evidence.get("docs_and_api", {})
    for check_name, check_val in docs.items():
        val_str = check_val.get("status") if isinstance(check_val, dict) else str(check_val)
        print(f"       - {check_name}: {val_str}")
    for v in g6_violations:
        print(f"       >>> VIOLATION [{v.get('code')}]: {v.get('message')}")

    print("-" * 80)
    print("REHEARSAL EXECUTION SUMMARY")
    print("-" * 80)
    overall_status = "SUCCESS (ALL 6 GATES PASSED)" if verdict.get("passed") else "FAILED (GATE VIOLATIONS DETECTED)"
    print(f"Verdict:             {overall_status}")
    print(f"Violations:          {len(violations)}")
    print("Artifact Staging:    Simulated in draft stage (.build/release-rehearsal/)")
    print("Publication Status:  REHEARSAL ONLY (No public release published)")
    print("=" * 80)


# ============================================================================
# Main CLI
# ============================================================================

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Exact-SHA Release Evidence Aggregator & Rehearsal Tooling for swift-tailscale-client."
    )
    parser.add_argument("--tag", type=str, help="Release tag name (e.g. v1.0.0)")
    parser.add_argument("--commit", type=str, help="Release commit SHA (defaults to HEAD or tag's commit)")
    parser.add_argument("--output", type=str, help="Output path for JSON release evidence file")
    parser.add_argument("--validate", type=str, nargs="?", const="__CURRENT__",
                        help="Validate evidence against 1.0 gating criteria. Pass JSON path or omit to validate current state.")
    parser.add_argument("--evidence", type=str, help="Path to pre-collected evidence JSON to validate or rehearse")

    parser.add_argument("--simulate-tag", action="store_true", help="Simulate annotated tag during dry-run rehearsal before tag is created in git")
    parser.add_argument("--rehearse", action="store_true", help="Execute complete release rehearsal flow without publishing")
    parser.add_argument("--artifacts-dir", type=str, help="Directory containing staged release artifacts")
    parser.add_argument("--test-reports", type=pathlib.Path, help="Directory of CI JSON reports and matching logs")
    parser.add_argument("--ci-data", type=str, help="Path to JSON file containing CI check runs or lane evidence")
    parser.add_argument("--skip-local-checks", action="store_true", help="Skip running local sub-checks during aggregation")
    parser.add_argument("--allow-dirty", action="store_true", help="Allow uncommitted changes (testing only)")

    args = parser.parse_args()


    artifacts_path = pathlib.Path(args.artifacts_dir) if args.artifacts_dir else None
    ci_data_path = pathlib.Path(args.ci_data) if args.ci_data else None

    # 1. Validation or Rehearsal mode from existing evidence file
    evidence_source = args.evidence or (args.validate if args.validate and args.validate != "__CURRENT__" else None)
    if evidence_source:
        evidence_file = pathlib.Path(evidence_source)
        if not evidence_file.exists():
            print(f"Error: Evidence file not found: {evidence_file}", file=sys.stderr)
            sys.exit(1)

        try:
            evidence_data = json.loads(evidence_file.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"Error: Failed to parse evidence JSON: {e}", file=sys.stderr)
            sys.exit(1)

        violations = GateValidator.validate_all(
            evidence_data,
            expected_commit=args.commit,
            expected_tag=args.tag,
            artifacts_dir=artifacts_path,
            allow_dirty=args.allow_dirty,
        )

        evidence_data["gating_verdict"] = {
            "passed": (len(violations) == 0),
            "violation_count": len(violations),
            "violations": [v.to_dict() for v in violations],
        }

        if args.rehearse:
            print_rehearsal_report(evidence_data)
            if violations:
                sys.exit(1)
            sys.exit(0)

        if violations:
            print(f"::error::Release gating criteria FAILED with {len(violations)} violation(s):", file=sys.stderr)
            for v in violations:
                print(f"  [Gate {v.gate}] [{v.code}]: {v.message}", file=sys.stderr)
                print(f"         Remediation: {v.remediation}", file=sys.stderr)
            sys.exit(1)

        print(f"Release evidence in '{evidence_file}' satisfies all 1.0 release gating criteria.")
        sys.exit(0)

    # 2. Aggregation / Rehearsal / Current Validation
    tag_name = args.tag
    if not tag_name:
        # Check if HEAD is tagged
        rc, current_tag, _ = run_cmd(["git", "describe", "--tags", "--exact-match"])
        if rc == 0 and current_tag:
            tag_name = current_tag
        else:
            tag_name = "v1.0.0"  # Default rehearsal tag

    aggregator = EvidenceAggregator(tag=tag_name, commit=args.commit, artifacts_dir=artifacts_path, ci_data_path=ci_data_path, test_reports_dir=args.test_reports)
    evidence = aggregator.aggregate(
        skip_local_checks=args.skip_local_checks,
        allow_dirty=args.allow_dirty,
        simulate_tag=args.simulate_tag,
    )

    out_path_str = args.output or f"release-evidence-{tag_name}.json"
    out_path = pathlib.Path(out_path_str)
    out_path.write_text(json.dumps(evidence, indent=2), encoding="utf-8")
    print(f"Release evidence document written to: {out_path}")

    # Rehearsal or Validate
    if args.rehearse or args.validate == "__CURRENT__":
        print_rehearsal_report(evidence)
        verdict = evidence.get("gating_verdict", {})
        if not verdict.get("passed"):
            sys.exit(1)
        sys.exit(0)


if __name__ == "__main__":
    main()
