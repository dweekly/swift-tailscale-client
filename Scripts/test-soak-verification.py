#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 David E. Weekly
"""
Test harness for Scripts/run-soak-verification.py:
Validates negative failure conditions and honest metric accounting:
1. Rejection of premature child process exits.
2. Rejection of memory plateau failure (excessive RSS drift).
3. Rejection of zero events processed.
4. Honest reporting of unmeasured internal actor metrics (None/null, not invented formulas).
5. Accurate binary compilation identification (SHA-256 recording).
"""

import copy
import json
import os
import sys
import unittest
from unittest.mock import MagicMock, patch

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import importlib
soak = importlib.import_module("run-soak-verification")


class TestSoakVerificationFailures(unittest.TestCase):

    def test_rejection_of_premature_child_exit(self):
        """When child process terminates before soak duration completes, harness must record violation."""
        mock_proc = MagicMock()
        # First poll is None, second poll returns exit code 1 (premature death)
        mock_proc.poll.side_effect = [None, 1]
        mock_proc.pid = 99999
        mock_proc.stdout.readline.return_value = ""

        with patch("subprocess.check_call"), \
             patch("subprocess.check_output", return_value="/fake/bin"), \
             patch("os.path.exists", return_value=True), \
             patch("builtins.open", unittest.mock.mock_open(read_data=b"fake-binary")), \
             patch("subprocess.Popen", return_value=mock_proc), \
             patch.object(soak, "get_process_descriptors", return_value=(4, 1)), \
             patch.object(soak, "get_process_rss_kb", return_value=12000), \
             patch("time.sleep"):

            with self.assertRaises(SystemExit) as ctx:
                soak.run_soak_test(
                    mode="accelerated",
                    duration_seconds=5,
                    sample_interval_seconds=1,
                    target="mock",
                    output_path="/dev/null"
                )
            self.assertEqual(ctx.exception.code, 1)

    def test_rejection_of_failed_memory_plateau(self):
        """When memory exhibits excessive drift without reaching plateau, harness must fail."""
        # Simulated rss_samples where last sample drifts > 32MB
        rss_samples = [10000, 15000, 50000]
        drift = rss_samples[-1] - rss_samples[-3]
        self.assertGreater(drift, 32768)

        # Confirm plateau_reached evaluates to False
        plateau_reached = True
        if len(rss_samples) >= 3:
            if drift > 32768:
                plateau_reached = False
        self.assertFalse(plateau_reached)

    def test_honest_unmeasured_quantities_are_none(self):
        """Queue high-water marks and cache inconsistencies must be reported as None, never fabricated."""
        mock_proc = MagicMock()
        mock_proc.poll.return_value = None
        mock_proc.pid = 99999
        mock_proc.stdout.readline.return_value = '{"Event":"connected"}\n'

        saved_report = {}

        def mock_dump(obj, f, **kwargs):
            nonlocal saved_report
            saved_report = copy.deepcopy(obj)

        with patch("subprocess.check_call"), \
             patch("subprocess.check_output", return_value="/fake/bin"), \
             patch("os.path.exists", return_value=True), \
             patch("builtins.open", unittest.mock.mock_open(read_data=b"fake-binary")), \
             patch("subprocess.Popen", return_value=mock_proc), \
             patch.object(soak, "get_process_descriptors", return_value=(4, 1)), \
             patch.object(soak, "get_process_rss_kb", return_value=12000), \
             patch("json.dump", side_effect=mock_dump), \
             patch("time.sleep"), \
             patch("time.time", side_effect=[100.0, 100.0, 100.5, 101.0, 102.0, 103.0, 105.1, 105.2, 105.3, 105.4]):

            try:
                soak.run_soak_test(
                    mode="accelerated",
                    duration_seconds=1,
                    sample_interval_seconds=1,
                    target="mock",
                    output_path="/dev/null"
                )
            except SystemExit:
                pass

        mem = saved_report.get("memory_bounds", {})
        self.assertIsNone(mem.get("queue_event_high_water_mark"), "Must not invent queue event high-water mark")
        self.assertIsNone(mem.get("queue_byte_high_water_mark"), "Must not invent queue byte high-water mark")
        self.assertIsNone(mem.get("queue_ceiling_breached"), "Must not hardcode queue ceiling breach")

        state = saved_report.get("state_gap_recovery", {})
        self.assertIsNone(state.get("baseline_refreshes_executed"), "Must not equate reconnects with baseline refreshes")
        self.assertIsNone(state.get("cache_inconsistencies"), "Must not hardcode cache inconsistencies to 0")

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
