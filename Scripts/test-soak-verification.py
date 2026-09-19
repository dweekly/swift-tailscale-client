#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 David E. Weekly
"""Exercise verdicts through the real soak runner, with deterministic measurements."""
import importlib
import io
import json
import pathlib
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import MagicMock, mock_open, patch

soak = importlib.import_module("run-soak-verification")


class TestSoakVerificationFailures(unittest.TestCase):
    def run_harness(self, *, rss=12000, descriptors=(4, 1), exit_code=None, events=True, duration=4):
        clock = [0.0]
        proc = MagicMock(pid=99999)
        proc.poll.side_effect = lambda: exit_code if clock[0] >= 1.0 else None
        proc.stdout = io.StringIO('{"type":"notification"}\n' if events else '')
        thread = MagicMock()

        def create_thread(target, **kwargs):
            thread.start.side_effect = target
            return thread

        with tempfile.TemporaryDirectory() as directory:
            report_path = pathlib.Path(directory) / "report.json"
            with patch.object(soak, "build_and_identify_swift_binary", return_value=("/fake/bin", "a" * 64)), \
                 patch.object(soak.subprocess, "Popen", return_value=proc), \
                 patch.object(soak.subprocess, "check_output", return_value="Swift test toolchain"), \
                 patch.object(soak, "get_process_descriptors", return_value=descriptors), \
                 patch.object(soak, "get_process_rss_kb", side_effect=rss if callable(rss) else lambda _: rss), \
                 patch.object(soak.threading, "Thread", side_effect=create_thread), \
                 patch.object(soak.time, "time", side_effect=lambda: clock[0]), \
                 patch.object(soak.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                 redirect_stdout(io.StringIO()):
                status = 0
                try:
                    soak.run_soak_test("accelerated", duration, 1, "mock", str(report_path))
                except SystemExit as error:
                    status = error.code
            report = json.loads(report_path.read_text())
        proc.terminate.assert_called_once()
        proc.wait.assert_called_once()
        return status, report

    def test_rejection_of_premature_child_exit(self):
        for code in (0, 1):
            with self.subTest(code=code):
                status, report = self.run_harness(exit_code=code)
                self.assertEqual(status, 1)
                self.assertTrue(any("prematurely" in v for v in report["verdict"]["violations"]))

    def test_rejection_of_failed_memory_plateau(self):
        samples = iter([10000, 15000, 20000, 60000, 100000])
        status, report = self.run_harness(rss=lambda _: next(samples))
        self.assertEqual(status, 1)
        self.assertFalse(report["memory_bounds"]["plateau_reached"])
        self.assertTrue(any("RSS drift" in v for v in report["verdict"]["violations"]))

    def test_unavailable_measurements_fail_closed(self):
        for measurements in ({"rss": None}, {"descriptors": (None, None)}):
            with self.subTest(measurements=measurements):
                status, report = self.run_harness(**measurements)
                self.assertEqual(status, 1)
                self.assertIn("Required RSS or descriptor measurement unavailable", report["verdict"]["violations"])
                if "descriptors" in measurements:
                    self.assertIsNone(report["resource_leak_audit"]["net_fd_leak"])
                else:
                    self.assertIsNone(report["memory_bounds"]["final_rss_kb"])

    def test_zero_events_fail(self):
        status, report = self.run_harness(events=False)
        self.assertEqual(status, 1)
        self.assertIn("Zero events processed during soak run", report["verdict"]["violations"])

    def test_insufficient_samples_fail(self):
        status, report = self.run_harness(duration=0)
        self.assertEqual(status, 1)
        self.assertIsNone(report["memory_bounds"]["plateau_reached"])

    def test_measured_plateau_passes_with_unmeasured_quantities_null(self):
        status, report = self.run_harness()
        self.assertEqual(status, 0)
        self.assertTrue(report["verdict"]["passed"])
        self.assertTrue(report["memory_bounds"]["plateau_reached"])
        for key in ("queue_event_high_water_mark", "queue_byte_high_water_mark", "queue_ceiling_breached"):
            self.assertIsNone(report["memory_bounds"][key])
        for key in ("baseline_refreshes_executed", "cache_inconsistencies"):
            self.assertIsNone(report["state_gap_recovery"][key])
        self.assertIsNone(report["reconnect_and_backoff"]["tight_loop_detected"])

    def test_failed_descriptor_probes_return_unavailable(self):
        with patch.object(soak.ctypes, "CDLL", side_effect=OSError), \
             patch.object(soak.pathlib.Path, "iterdir", side_effect=PermissionError):
            self.assertEqual(soak.get_darwin_fd_counts(99999), (None, None))
            self.assertEqual(soak.get_linux_fd_counts(99999), (None, None))

    def test_fresh_binary_compilation_and_sha256(self):
        """Harness must always invoke swift build and compute sha256 checksum."""
        calls = []
        def mock_check_call(cmd):
            calls.append(cmd)

        with patch("subprocess.check_call", side_effect=mock_check_call), \
             patch("subprocess.check_output", return_value="/fake/path"), \
             patch("os.path.exists", return_value=True), \
             patch("builtins.open", unittest.mock.mock_open(read_data=b"mock-binary-content")):

            candidate, sha = soak.build_and_identify_swift_binary()
            self.assertTrue(any("swift" in c and "build" in c for c in calls))
            self.assertEqual(len(sha), 64)  # Valid hex sha256


if __name__ == "__main__":
    unittest.main()
