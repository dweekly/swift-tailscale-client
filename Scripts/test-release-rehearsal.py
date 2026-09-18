#!/usr/bin/env python3
"""
Scripts/test-release-rehearsal.py - Negative Gate Simulation Test Suite for Release Evidence & Rehearsal.

Simulates and verifies:
1. Missing required lane (test_linux, docs_build_strict, etc.)
2. Unexpected test skip (skipped > 0 or critical test skipped)
3. Mismatched commit SHA (evidence commit != tag target commit)
4. Unannotated tag (lightweight tag detected)
5. Failed binary build / missing release asset checksum (missing archive, bad digest, missing SHA256SUMS.txt)
6. Outdated docs / API baseline failure (drift across README/DocC/constants, breaking API changes)
7. Full successful rehearsal flow (all 6 gates pass, dry-run guaranteed, no release published)

Zero external dependencies: uses only Python 3 standard library.
"""

import copy
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
from typing import Any, Dict, List, Tuple

# Locate and import aggregate-release-evidence module
SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR
while ROOT_DIR.name and not (ROOT_DIR / "Package.swift").exists():
    ROOT_DIR = ROOT_DIR.parent
if not ROOT_DIR.name:
    ROOT_DIR = pathlib.Path.cwd()

script_path = SCRIPT_DIR / "aggregate-release-evidence.py"
if not script_path.exists():
    script_path = ROOT_DIR / "Scripts" / "aggregate-release-evidence.py"

if not script_path.exists():
    raise RuntimeError(f"Cannot find aggregate-release-evidence script at {script_path}")

import importlib.util
spec = importlib.util.spec_from_file_location("aggregate_release_evidence", script_path)
agg_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agg_module)
GateValidator = agg_module.GateValidator
GateViolation = agg_module.GateViolation
EvidenceAggregator = agg_module.EvidenceAggregator


# ============================================================================
# Test Fixture Factory: Deterministic 1.0 Release Candidate Evidence
# ============================================================================

def make_valid_1_0_evidence() -> Dict[str, Any]:
    """Generates a complete, valid release evidence document for v1.0.0."""
    target_sha = "1f8c798e3b5e4a8996b797b5e4a8996b797b5e4a"
    mac_name = "tailscale-swift-v1.0.0-macos-universal.tar.gz"
    linux_name = "tailscale-swift-v1.0.0-linux-x86_64.tar.gz"

    mac_sha = hashlib.sha256(b"macos-universal-binary-v1.0.0").hexdigest()
    linux_sha = hashlib.sha256(b"linux-x86_64-binary-v1.0.0").hexdigest()
    sums_sha = hashlib.sha256(f"{mac_sha}  {mac_name}\n{linux_sha}  {linux_name}\n".encode("utf-8")).hexdigest()

    return {
        "schema_version": "1.0.0",
        "generated_at": "2026-09-18T10:00:00Z",
        "tag": {
            "name": "v1.0.0",
            "exists": True,
            "is_annotated": True,
            "target_commit": target_sha,
            "message": "v1.0.0: Production-grade Swift Tailscale LocalAPI client",
            "tagger": "David E. Weekly <david@weekly.org> 1785942923 -1000",
        },
        "commit": {
            "sha": target_sha,
            "short_sha": "1f8c798",
            "author": "David E. Weekly <david@weekly.org>",
            "committer": "David E. Weekly <david@weekly.org>",
            "date": "2026-09-18T09:50:00Z",
            "message": "chore: prepare 1.0.0 release",
            "is_clean_worktree": True,
        },
        "lockfile": {
            "path": "Package.resolved",
            "origin_hash": "c556cd282e134474532707467660e545c6ee700afc88d89dd2e971fff463fd40",
            "sha256": "4b6807d9bb82be59a6c721bbf6e5a611c0f0bb3b37803d2745326442657e28f1",
            "pins": [
                {"identity": "swift-argument-parser", "version": "1.8.2"},
                {"identity": "swift-docc-plugin", "version": "1.5.0"},
            ],
        },
        "environment": {
            "swift_version": "Swift version 6.1 (swiftlang-6.1.0.12)",
            "os_name": "Darwin",
            "os_release": "24.0.0",
            "arch": "arm64",
            "toolchain_baseline": "6.0",
            "tested_daemon_versions": ["1.76.0", "1.84.0", "1.96.4", "1.98.0"],
            "headscale_version": "0.26.1",
        },
        "required_lanes": {
            "test_macos": {
                "name": "Test on macOS",
                "status": "passed",
                "test_summary": {
                    "executed": 142,
                    "failures": 0,
                    "unexpected_failures": 0,
                    "skipped": 0,
                    "critical_skips": [],
                },
                "coverage": {"percent": 86.4, "floor": 85.0, "status": "passed"},
            },
            "test_linux": {
                "name": "Test on Linux",
                "status": "passed",
                "test_summary": {
                    "executed": 142,
                    "failures": 0,
                    "unexpected_failures": 0,
                    "skipped": 0,
                    "critical_skips": [],
                },
            },
            "docs_consistency": {
                "name": "Docs consistency",
                "status": "passed",
                "checks": {
                    "release_consistency": "passed",
                    "endpoint_docs": "passed",
                    "recipe_snippets": "passed",
                    "upstream_maturity": "passed",
                    "model_conformance": "passed",
                },
            },
            "docs_build_strict": {
                "name": "DocC (strict)",
                "status": "passed",
                "warnings_as_errors": True,
                "coverage_floors": {
                    "Types": {"percent": 100.0, "floor": 90.0, "status": "passed"},
                    "Members": {"percent": 98.5, "floor": 68.0, "status": "passed"},
                    "Globals": {"percent": 100.0, "floor": 1.0, "status": "passed"},
                },
            },
            "test_tsan": {
                "name": "Test with Thread Sanitizer",
                "status": "passed",
                "sanitizer": "thread",
                "test_summary": {
                    "executed": 142,
                    "failures": 0,
                    "unexpected_failures": 0,
                    "skipped": 0,
                    "critical_skips": [],
                },
            },
            "build_platforms": {
                "name": "Build platforms",
                "status": "passed",
                "platforms": {"iOS": "passed", "tvOS": "passed", "watchOS": "passed"},
            },
            "integration_linux_headscale": {
                "name": "Hermetic integration (Linux / headscale)",
                "status": "passed",
                "test_summary": {"executed": 18, "failures": 0, "skipped": 0},
                "daemon_tracks": {
                    "stable": {"version": "1.98.0", "status": "passed"},
                    "previous_stable": {"version": "1.96.4", "status": "passed"},
                },
                "unstable_drift_signal": {"status": "passed", "blocking": False},
            },
        },
        "docs_and_api": {
            "release_consistency": {"status": "passed", "target_tag": "v1.0.0"},
            "endpoint_docs_check": "passed",
            "upstream_maturity_check": "passed",
            "recipe_snippets_check": "passed",
            "model_conformance_check": "passed",
            "api_baseline_compatibility": "passed",
        },
        "fixtures_and_conformance": {
            "fixture_manifest_integrity": "passed",
            "fixture_purity_audit": "passed",
            "conformance_harness_status": "passed",
        },
        "release_assets": {
            "staging_status": "complete",
            "artifacts": [
                {
                    "name": mac_name,
                    "platform": "darwin-universal",
                    "architectures": ["arm64", "x86_64"],
                    "size_bytes": 1245928,
                    "sha256": mac_sha,
                    "build_status": "passed",
                    "smoke_test": {"help_flag": "passed", "version_flag": "passed"},
                },
                {
                    "name": linux_name,
                    "platform": "linux-x86_64",
                    "architectures": ["x86_64"],
                    "size_bytes": 1582910,
                    "sha256": linux_sha,
                    "build_status": "passed",
                    "smoke_test": {"help_flag": "passed", "version_flag": "passed"},
                },
            ],
            "checksums_file": {
                "name": "SHA256SUMS.txt",
                "sha256": sums_sha,
                "status": "verified",
            },
        },
    }


# ============================================================================
# Test Runner & Assertions
# ============================================================================

class TestRunner:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.errors = []

    def log_result(self, name: str, success: bool, details: str = "") -> None:
        if success:
            self.passed += 1
            print(f"  [PASS] {name}")
        else:
            self.failed += 1
            print(f"  [FAIL] {name}")
            if details:
                print(f"         Reason: {details}")
            self.errors.append((name, details))

    def run(self) -> bool:
        print("=" * 80)
        print("RUNNING 1.0 RELEASE REHEARSAL & NEGATIVE GATES TEST SUITE")
        print("=" * 80)

        self.test_positive_baseline()
        self.test_negative_gate_1_missing_lanes()
        self.test_negative_gate_2_unexpected_skips()
        self.test_negative_gate_3_sha_mismatch()
        self.test_negative_gate_4_unannotated_tag()
        self.test_negative_gate_5_binary_assets_and_checksums()
        self.test_negative_gate_6_outdated_docs_and_api()
        self.test_cli_rehearsal_flow_dry_run()
        self.test_genuine_evidence_collection()

        print("\n" + "=" * 80)
        print(f"TEST SUITE SUMMARY: {self.passed} PASSED, {self.failed} FAILED")
        print("=" * 80)
        return self.failed == 0

    # ------------------------------------------------------------------------
    # Positive Baseline
    # ------------------------------------------------------------------------
    def test_positive_baseline(self):
        print("\n--- Positive Baseline: Valid Evidence Qualification ---")
        evidence = make_valid_1_0_evidence()
        violations = GateValidator.validate_all(evidence)
        self.log_result(
            "Valid 1.0 evidence passes all 6 release gates with 0 violations",
            len(violations) == 0,
            f"Got {len(violations)} violations: {[v.code for v in violations]}"
        )

    # ------------------------------------------------------------------------
    # Negative Gate 1: Missing Required CI Lanes
    # ------------------------------------------------------------------------
    def test_negative_gate_1_missing_lanes(self):
        print("\n--- Gate 1: Missing / Non-Passing Required CI Lanes ---")

        # 1a. Missing test_linux lane
        ev = make_valid_1_0_evidence()
        del ev["required_lanes"]["test_linux"]
        v = GateValidator.check_gate_1_required_lanes(ev)
        self.log_result(
            "Rejects evidence when 'test_linux' lane is missing",
            any(x.code == "GATE_FAILURE_MISSING_LANE" and "test_linux" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 1b. Missing docs_build_strict lane
        ev = make_valid_1_0_evidence()
        del ev["required_lanes"]["docs_build_strict"]
        v = GateValidator.check_gate_1_required_lanes(ev)
        self.log_result(
            "Rejects evidence when 'docs_build_strict' lane is missing",
            any(x.code == "GATE_FAILURE_MISSING_LANE" and "docs_build_strict" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 1c. Lane marked failed
        ev = make_valid_1_0_evidence()
        ev["required_lanes"]["test_macos"]["status"] = "failed"
        v = GateValidator.check_gate_1_required_lanes(ev)
        self.log_result(
            "Rejects evidence when required lane status is 'failed'",
            any(x.code == "GATE_FAILURE_LANE_STATUS" and "test_macos" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 1d. Lane marked cancelled
        ev = make_valid_1_0_evidence()
        ev["required_lanes"]["test_tsan"]["status"] = "cancelled"
        v = GateValidator.check_gate_1_required_lanes(ev)
        self.log_result(
            "Rejects evidence when required lane status is 'cancelled'",
            any(x.code == "GATE_FAILURE_LANE_STATUS" and "test_tsan" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

    # ------------------------------------------------------------------------
    # Negative Gate 2: Unexpected Test Skips
    # ------------------------------------------------------------------------
    def test_negative_gate_2_unexpected_skips(self):
        print("\n--- Gate 2: Unexpected Test Skips & Failures ---")

        # 2a. Skips in test_macos
        ev = make_valid_1_0_evidence()
        ev["required_lanes"]["test_macos"]["test_summary"]["skipped"] = 2
        v = GateValidator.check_gate_2_unexpected_skips(ev)
        self.log_result(
            "Rejects evidence when lane reports skipped tests (threshold 0)",
            any(x.code == "GATE_FAILURE_UNEXPECTED_SKIP" and "test_macos" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 2b. Critical test suite skipped
        ev = make_valid_1_0_evidence()
        ev["required_lanes"]["test_macos"]["test_summary"]["critical_skips"] = ["ReadinessRegressionTests"]
        v = GateValidator.check_gate_2_unexpected_skips(ev)
        self.log_result(
            "Rejects evidence when a critical test suite is skipped",
            any(x.code == "GATE_FAILURE_UNEXPECTED_SKIP" and "ReadinessRegressionTests" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 2c. Failures in test_linux
        ev = make_valid_1_0_evidence()
        ev["required_lanes"]["test_linux"]["test_summary"]["failures"] = 1
        v = GateValidator.check_gate_2_unexpected_skips(ev)
        self.log_result(
            "Rejects evidence when test failures are present",
            any(x.code == "GATE_FAILURE_UNEXPECTED_SKIP" and "test_linux" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

    # ------------------------------------------------------------------------
    # Negative Gate 3: Mismatched Commit SHA
    # ------------------------------------------------------------------------
    def test_negative_gate_3_sha_mismatch(self):
        print("\n--- Gate 3: Exact Commit SHA Alignment ---")

        # 3a. Evidence SHA != Tag Target SHA
        ev = make_valid_1_0_evidence()
        ev["commit"]["sha"] = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        v = GateValidator.check_gate_3_commit_sha(ev)
        self.log_result(
            "Rejects release when evidence commit SHA != tag target commit SHA",
            any(x.code == "GATE_FAILURE_SHA_MISMATCH" for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 3b. CLI expected commit SHA mismatch
        ev = make_valid_1_0_evidence()
        v = GateValidator.check_gate_3_commit_sha(ev, expected_commit="0000000000000000000000000000000000000000")
        self.log_result(
            "Rejects release when CLI specified commit differs from evidence commit",
            any(x.code == "GATE_FAILURE_SHA_MISMATCH" for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 3c. Dirty worktree rejected
        ev = make_valid_1_0_evidence()
        ev["commit"]["is_clean_worktree"] = False
        v = GateValidator.check_gate_3_commit_sha(ev, allow_dirty=False)
        self.log_result(
            "Rejects release when worktree contains uncommitted modifications",
            any(x.code == "GATE_FAILURE_DIRTY_WORKTREE" for x in v),
            f"Violations: {[x.code for x in v]}"
        )

    # ------------------------------------------------------------------------
    # Negative Gate 4: Unannotated Tag
    # ------------------------------------------------------------------------
    def test_negative_gate_4_unannotated_tag(self):
        print("\n--- Gate 4: Annotated Tag Enforcement ---")

        # 4a. Tag is lightweight (is_annotated: False)
        ev = make_valid_1_0_evidence()
        ev["tag"]["is_annotated"] = False
        v = GateValidator.check_gate_4_annotated_tag(ev)
        self.log_result(
            "Rejects lightweight tag with actionable error to recreate as annotated",
            any(x.code == "GATE_FAILURE_UNANNOTATED_TAG" and "lightweight" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 4b. Missing 'v' prefix
        ev = make_valid_1_0_evidence()
        ev["tag"]["name"] = "1.0.0"
        v = GateValidator.check_gate_4_annotated_tag(ev)
        self.log_result(
            "Rejects tag lacking 'v' prefix",
            any(x.code == "GATE_FAILURE_UNANNOTATED_TAG" and "must start with 'v'" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 4c. Empty tag message
        ev = make_valid_1_0_evidence()
        ev["tag"]["message"] = ""
        v = GateValidator.check_gate_4_annotated_tag(ev)
        self.log_result(
            "Rejects annotated tag with empty message",
            any(x.code == "GATE_FAILURE_UNANNOTATED_TAG" and "empty message" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

    # ------------------------------------------------------------------------
    # Negative Gate 5: Binary Assets and Checksums
    # ------------------------------------------------------------------------
    def test_negative_gate_5_binary_assets_and_checksums(self):
        print("\n--- Gate 5: Binary Builds & Asset Checksums ---")

        # 5a. Missing Linux binary asset
        ev = make_valid_1_0_evidence()
        ev["release_assets"]["artifacts"] = [
            a for a in ev["release_assets"]["artifacts"] if "macos" in a["name"]
        ]
        v = GateValidator.check_gate_5_binary_assets(ev)
        self.log_result(
            "Rejects release when Linux CLI binary archive is missing",
            any(x.code == "GATE_FAILURE_BINARY_BUILD" and "linux" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 5b. Invalid SHA-256 digest
        ev = make_valid_1_0_evidence()
        ev["release_assets"]["artifacts"][0]["sha256"] = "invalid-truncated-hash"
        v = GateValidator.check_gate_5_binary_assets(ev)
        self.log_result(
            "Rejects release when asset has invalid or non-hex SHA-256 checksum",
            any(x.code == "GATE_FAILURE_ASSET_CHECKSUM" for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 5c. Missing SHA256SUMS.txt manifest
        ev = make_valid_1_0_evidence()
        ev["release_assets"]["checksums_file"]["status"] = "missing"
        v = GateValidator.check_gate_5_binary_assets(ev)
        self.log_result(
            "Rejects release when SHA256SUMS.txt manifest is unverified/missing",
            any(x.code == "GATE_FAILURE_ASSET_CHECKSUM" and "SHA256SUMS.txt" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 5d. Failed smoke test (--help / --version)
        ev = make_valid_1_0_evidence()
        ev["release_assets"]["artifacts"][0]["smoke_test"]["version_flag"] = "failed"
        v = GateValidator.check_gate_5_binary_assets(ev)
        self.log_result(
            "Rejects release when packaged binary fails smoke test",
            any(x.code == "GATE_FAILURE_BINARY_BUILD" and "smoke test" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

    # ------------------------------------------------------------------------
    # Negative Gate 6: Outdated Docs & API Baseline
    # ------------------------------------------------------------------------
    def test_negative_gate_6_outdated_docs_and_api(self):
        print("\n--- Gate 6: Documentation & API Baseline Compatibility ---")

        # 6a. check-release-consistency version drift
        ev = make_valid_1_0_evidence()
        ev["docs_and_api"]["release_consistency"]["status"] = "drift_detected"
        ev["docs_and_api"]["release_consistency"]["error"] = "DRIFT: README pin (0.12.0) != CHANGELOG (1.0.0)"
        v = GateValidator.check_gate_6_docs_and_api(ev)
        self.log_result(
            "Rejects release when check-release-consistency detects version drift",
            any(x.code == "GATE_FAILURE_OUTDATED_DOCS_OR_API" and "consistency" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 6b. Endpoints table drift
        ev = make_valid_1_0_evidence()
        ev["docs_and_api"]["endpoint_docs_check"] = "drift_detected"
        v = GateValidator.check_gate_6_docs_and_api(ev)
        self.log_result(
            "Rejects release when endpoints.json and docs tables are out of sync",
            any(x.code == "GATE_FAILURE_OUTDATED_DOCS_OR_API" and "endpoints.json" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 6c. Upstream maturity derivation failure
        ev = make_valid_1_0_evidence()
        ev["docs_and_api"]["upstream_maturity_check"] = "failed"
        v = GateValidator.check_gate_6_docs_and_api(ev)
        self.log_result(
            "Rejects release when upstream maturity verification fails",
            any(x.code == "GATE_FAILURE_OUTDATED_DOCS_OR_API" and "Upstream maturity" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 6d. DocC coverage floor regression
        ev = make_valid_1_0_evidence()
        ev["required_lanes"]["docs_build_strict"]["coverage_floors"]["Members"]["percent"] = 55.0
        v = GateValidator.check_gate_6_docs_and_api(ev)
        self.log_result(
            "Rejects release when DocC abstract coverage regresses below floor",
            any(x.code == "GATE_FAILURE_OUTDATED_DOCS_OR_API" and "coverage for Members" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 6e. API breaking change against baseline
        ev = make_valid_1_0_evidence()
        ev["docs_and_api"]["api_baseline_compatibility"] = "breaking_change_detected"
        v = GateValidator.check_gate_6_docs_and_api(ev)
        self.log_result(
            "Rejects release when intentional or unintended breaking API change detected",
            any(x.code == "GATE_FAILURE_OUTDATED_DOCS_OR_API" and "breaking changes" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

        # 6f. Wire model conformance failure
        ev = make_valid_1_0_evidence()
        ev["docs_and_api"]["model_conformance_check"] = "failed"
        v = GateValidator.check_gate_6_docs_and_api(ev)
        self.log_result(
            "Rejects release when wire model conformance check fails",
            any(x.code == "GATE_FAILURE_OUTDATED_DOCS_OR_API" and "Model conformance" in x.message for x in v),
            f"Violations: {[x.code for x in v]}"
        )

    # ------------------------------------------------------------------------
    # Full Rehearsal Flow (Dry-Run & CLI Integration)
    # ------------------------------------------------------------------------
    def test_cli_rehearsal_flow_dry_run(self):
        print("\n--- CLI Integration & Simulated Rehearsal Flow ---")

        # Uses resolved script_path from module header
        with tempfile.TemporaryDirectory() as tmpdir:
            ev_file = pathlib.Path(tmpdir) / "evidence.json"
            valid_evidence = make_valid_1_0_evidence()
            ev_file.write_text(json.dumps(valid_evidence, indent=2))

            # Test --validate on file
            proc = subprocess.run(
                [sys.executable, str(script_path), "--validate", str(ev_file)],
                capture_output=True,
                text=True,
            )
            self.log_result(
                "CLI --validate succeeds with exit code 0 on valid evidence file",
                proc.returncode == 0,
                f"stderr: {proc.stderr}, stdout: {proc.stdout}"
            )

            # Test --validate failure on injected negative gate
            invalid_evidence = make_valid_1_0_evidence()
            del invalid_evidence["required_lanes"]["test_linux"]
            ev_file.write_text(json.dumps(invalid_evidence, indent=2))
            proc_fail = subprocess.run(
                [sys.executable, str(script_path), "--validate", str(ev_file)],
                capture_output=True,
                text=True,
            )
            self.log_result(
                "CLI --validate fails with exit code 1 and actionable error on invalid evidence",
                proc_fail.returncode == 1 and "GATE_FAILURE_MISSING_LANE" in proc_fail.stderr,
                f"Exit code: {proc_fail.returncode}, stderr: {proc_fail.stderr}"
            )

            # Test --rehearse execution with dry-run guarantee using pre-collected evidence
            ev_file.write_text(json.dumps(valid_evidence, indent=2))
            proc_rehearse = subprocess.run(
                [
                    sys.executable,
                    str(script_path),
                    "--evidence", str(ev_file),
                    "--rehearse",
                ],
                capture_output=True,
                text=True,
            )

            self.log_result(
                "CLI --rehearse completes successfully with exit code 0",
                proc_rehearse.returncode == 0,
                f"returncode: {proc_rehearse.returncode}, stderr: {proc_rehearse.stderr}, stdout: {proc_rehearse.stdout}"
            )
            self.log_result(
                "CLI --rehearse report confirms all 6 gates passed and no publication occurred",
                "REHEARSAL ONLY" in proc_rehearse.stdout and "SUCCESS (ALL 6 GATES PASSED)" in proc_rehearse.stdout,
                f"stdout preview: {proc_rehearse.stdout[:300]}"
            )

    # ------------------------------------------------------------------------
    # Genuine Evidence Collection & Remediation Tests
    # ------------------------------------------------------------------------
    def test_genuine_evidence_collection(self):
        print("\n--- Genuine Evidence Collection & Remediation Tests ---")

        # 1. _collect_docs_and_api executes real verification scripts
        agg = EvidenceAggregator(tag="v0.12.0")
        docs_api = agg._collect_docs_and_api(skip_local_checks=False)
        self.log_result(
            "_collect_docs_and_api runs real docs scripts and reports release_consistency passed",
            docs_api.get("release_consistency", {}).get("status") == "passed",
            f"Result: {docs_api.get('release_consistency')}"
        )
        self.log_result(
            "_collect_docs_and_api runs real endpoint docs check",
            docs_api.get("endpoint_docs_check") == "passed",
            f"Result: {docs_api.get('endpoint_docs_check')}"
        )
        self.log_result(
            "_collect_docs_and_api runs real model conformance check",
            docs_api.get("model_conformance_check") == "passed",
            f"Result: {docs_api.get('model_conformance_check')}"
        )

        # 2. _collect_assets rejects missing artifacts without synthesizing fake values
        with tempfile.TemporaryDirectory() as empty_artifacts:
            agg_empty = EvidenceAggregator(tag="v0.12.0", artifacts_dir=pathlib.Path(empty_artifacts))
            assets = agg_empty._collect_assets()
            self.log_result(
                "_collect_assets marks missing files as build_status missing rather than fabricating",
                all(a.get("build_status") == "missing" and a.get("sha256") == "" for a in assets.get("artifacts", [])),
                f"Artifacts: {assets.get('artifacts')}"
            )
            self.log_result(
                "_collect_assets marks SHA256SUMS.txt missing when absent",
                assets.get("checksums_file", {}).get("status") == "missing",
                f"Checksums file: {assets.get('checksums_file')}"
            )

        # 3. _collect_lanes with --ci-data loads check runs and detects missing lanes
        with tempfile.TemporaryDirectory() as tmpdir:
            ci_data_file = pathlib.Path(tmpdir) / "ci_data.json"
            ci_payload = {
                "check_runs": [
                    {"name": "Test on macOS", "status": "completed", "conclusion": "success", "output": {"text": "142 executed"}},
                    {"name": "Test on Linux", "status": "completed", "conclusion": "success", "output": {"text": "142 executed"}},
                    {"name": "Docs consistency", "status": "completed", "conclusion": "success", "output": {"text": "passed"}},
                    {"name": "DocC (strict)", "status": "completed", "conclusion": "success", "output": {"text": "passed"}},
                    {"name": "Build platforms", "status": "completed", "conclusion": "success", "output": {"text": "passed"}},
                    {"name": "Integration (Linux)", "status": "completed", "conclusion": "success", "output": {"text": "18 executed"}},
                ]
            }
            ci_data_file.write_text(json.dumps(ci_payload))
            agg_ci = EvidenceAggregator(tag="v0.12.0", ci_data_path=ci_data_file)
            lanes = agg_ci._collect_lanes(skip_local_checks=False)
            self.log_result(
                "_collect_lanes parses check-runs into lane statuses",
                lanes.get("test_macos", {}).get("status") == "passed",
                f"test_macos lane: {lanes.get('test_macos')}"
            )
            self.log_result(
                "_collect_lanes reports missing lane as missing when absent from CI check-runs",
                lanes.get("test_tsan", {}).get("status") == "missing",
                f"test_tsan lane: {lanes.get('test_tsan')}"
            )


if __name__ == "__main__":
    runner = TestRunner()
    success = runner.run()
    sys.exit(0 if success else 1)
