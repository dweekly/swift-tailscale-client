#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 David E. Weekly
"""Regression tests for the CI-report-to-release-evidence contract."""
import hashlib
import importlib
import json
import pathlib
import tempfile
import unittest

reporter = importlib.import_module("ci-test-report")
aggregator = importlib.import_module("aggregate-release-evidence")
SHA = "a" * 40
PASS = "Executed 3 tests, with 0 failures (0 unexpected) in 0.01 seconds\n"


def skipped_log(test, reason):
    return (f"Test Case '{test}' started at now\nfile.swift:18: Test skipped - {reason}\n"
            f"Test Case '{test}' skipped (0.0 seconds)\n"
            "Executed 3 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.01 seconds\n")


class ReportTests(unittest.TestCase):
    def test_xctest_and_swift_testing_counts_are_not_double_counted(self):
        output = PASS + PASS + "Test run with 2 tests in 1 suite passed after 0.1 seconds.\n"
        summary, _, errors = reporter.parse_output(output, "test_macos", "unit")
        self.assertEqual(summary["executed"], 5)
        self.assertFalse(errors)

    def test_disabled_live_suites_are_only_expected_in_unit_jobs(self):
        output = skipped_log("-[Module.TailscaleClientIntegrationTests testStatus]",
                             "Integration tests disabled. Set TAILSCALE_INTEGRATION=1 to enable.")
        for lane, member, expected in [("test_macos", "unit", 1), ("integration_linux_headscale", "stable-api", 0)]:
            summary, _, errors = reporter.parse_output(output, lane, member)
            self.assertEqual(summary["expected_skips"], expected)
            self.assertEqual(summary["executed"], 2)
            self.assertFalse(errors)

    def test_headscale_skips_require_named_method_and_reason(self):
        reason = "Interface discovery is Darwin-only (userspace tailscaled has no TUN)"
        for name, expected in [("testInterfaceInfo", 1), ("testServeConfigStaleETagIsRejected", 0)]:
            summary, _, _ = reporter.parse_output(skipped_log(f"TailscaleClientIntegrationTests.{name}", reason),
                                                 "integration_linux_headscale", "stable-api")
            self.assertEqual(summary["expected_skips"], expected)

    def test_old_endpoint_skip_is_not_allowed_on_stable(self):
        output = skipped_log("TailscaleClientIntegrationTests.testDNSConfigAgainstLiveDaemon",
                             "Daemon predates dns-config (Tailscale 1.98+); skipping")
        for member, expected in [("supported-floor-api", 1), ("stable-api", 0), ("unstable-api", 0)]:
            summary, _, _ = reporter.parse_output(output, "integration_linux_headscale", member)
            self.assertEqual(summary["expected_skips"], expected)

    def test_critical_skips_are_always_rejected(self):
        output = skipped_log("UnixSocketFaultTests.testTimeout", "environment unsupported")
        summary, _, _ = reporter.parse_output(output, "test_linux", "unit")
        self.assertEqual(summary["unexpected_skips"], 1)
        self.assertTrue(summary["critical_skips"])

    def test_missing_summary_unaccounted_skips_and_swift_failure(self):
        for output in ("Build complete!", "Executed 3 tests, with 1 test skipped and 0 failures\n",
                       PASS + 'Test example() skipped: disabled\n'):
            self.assertTrue(reporter.parse_output(output, "test_linux", "unit")[2])
        summary, _, _ = reporter.parse_output("Test run with 1 test failed after 1 second", "test_linux", "unit")
        self.assertEqual(summary["failures"], 1)

    def make_reports(self, root):
        for lane, members in reporter.MEMBERS.items():
            for member in members:
                summary, skips, errors = reporter.parse_output(PASS, lane, member)
                path = root / f"{lane}-{member}.json"
                path.with_suffix(".log").write_text(PASS)
                path.write_text(json.dumps({"schema_version": 1, "source_sha": SHA, "run_id": "123",
                    "lane": lane, "member": member, "exit_code": 0, "test_summary": summary,
                    "skips": skips, "errors": errors, "log_sha256": hashlib.sha256(PASS.encode()).hexdigest()}))

    def lanes(self):
        return {lane: {"status": "unverified", "checks_passed": True} for lane in reporter.MEMBERS}

    def test_reports_complete_the_real_check_run_parser(self):
        checks = [{"name": name, "conclusion": "success", "status": "completed"} for name in (
            "Test on macOS", "Test on Linux", "Test with Thread Sanitizer", "Docs consistency", "DocC (strict)",
            "Build (iOS)", "Build (tvOS)", "Build (watchOS)",
            *(f"Integration (Linux) / Hermetic integration (tailscaled {track})" for track in reporter.TRACKS))]
        checks.append({"name": "Integration (Linux) / Hermetic integration (tailscaled unstable)",
                       "conclusion": "failure", "status": "completed"})
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_reports(root)
            ci_path = root / "ci.json"
            ci_path.write_text(json.dumps({"check_runs": checks}))
            collector = aggregator.EvidenceAggregator("v1.0.0", commit=SHA, ci_data_path=ci_path, test_reports_dir=root)
            lanes = collector._collect_lanes(False)
            self.assertTrue(all(lanes[name]["status"] == "passed" for name in aggregator.REQUIRED_LANES), lanes)

    def test_release_rejects_missing_stale_failed_duplicate_or_tampered_reports(self):
        for defect in ("missing", "sha", "exit", "duplicate", "log", "count", "run", "zero", "skip", "check"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                self.make_reports(root)
                path = root / "test_tsan-unit.json"
                value = json.loads(path.read_text())
                lanes = self.lanes()
                if defect == "sha": value["source_sha"] = "b" * 40
                if defect == "exit": value["exit_code"] = 1
                if defect == "run": value["run_id"] = "456"
                if defect == "count": value["test_summary"]["executed"] = 99
                if defect == "check": lanes["test_tsan"]["checks_passed"] = False
                if defect in ("zero", "skip"):
                    log = "Executed 0 tests, with 0 failures\n" if defect == "zero" else skipped_log("LoginLifecycleIntegrationTests.testLogin", "Login disabled")
                    path.with_suffix(".log").write_text(log)
                    value["test_summary"], value["skips"], value["errors"] = reporter.parse_output(log, value["lane"], value["member"])
                    value["log_sha256"] = hashlib.sha256(log.encode()).hexdigest()
                path.write_text(json.dumps(value))
                if defect == "missing": path.unlink()
                if defect == "duplicate": (root / "copy.json").write_text(json.dumps(value))
                if defect == "log": path.with_suffix(".log").write_text(PASS + "tampered")
                result = reporter.attach_reports(lanes, root, SHA)
                self.assertNotEqual(result["test_tsan"]["status"], "passed")

    def test_api_baseline_requires_a_successful_check(self):
        collector = aggregator.EvidenceAggregator("v1.0.0", commit=SHA)
        self.assertEqual(collector.api_baseline_status, "unverified")
        collector._record_api_baseline([{"name": "Check API Baseline", "status": "completed", "conclusion": "success"}])
        self.assertEqual(collector.api_baseline_status, "passed")
        collector._record_api_baseline([{"name": "Check API Baseline", "status": "completed", "conclusion": "failure"}])
        self.assertEqual(collector.api_baseline_status, "unverified")

    def test_expected_skips_do_not_bypass_unexpected_skip_gate(self):
        evidence = {"required_lanes": {"test_macos": {"test_summary": {
            "skipped": 45, "expected_skips": 45, "unexpected_skips": 0}}}}
        self.assertFalse(aggregator.GateValidator.check_gate_2_unexpected_skips(evidence))
        evidence["required_lanes"]["test_macos"]["test_summary"]["unexpected_skips"] = 1
        self.assertTrue(aggregator.GateValidator.check_gate_2_unexpected_skips(evidence))


if __name__ == "__main__":
    unittest.main()
