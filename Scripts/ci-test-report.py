#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 David E. Weekly
"""Run Swift tests and retain exact-SHA counts, named skips, and the original log.

Unknown output or skips fail closed. Expected skips are limited to disabled live
suites in unit jobs and explicit limitations of the disposable Headscale fixture.
"""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import subprocess
import sys

TRACKS = ("supported-floor", "intermediate-lts", "previous-stable", "stable")
MEMBERS = {
    "test_macos": ("unit",), "test_linux": ("unit",), "test_tsan": ("unit",),
    "integration_linux_headscale": tuple(f"{track}-{suite}" for track in TRACKS for suite in ("api", "login")),
}
CRITICAL = ("ReadinessRegressionTests", "UnixSocketFaultTests", "StreamingFramingTests",
            "ServeConfigLosslessTests", "IPNBusStreamingTests", "ConformanceTests")
# Exact method + reason allowlist. Missing permissions, disabled write/login tests,
# missing ETags/netmaps and failed peer pings are deliberately not allowed.
HEADSCALE_SKIPS = {
    "testPingToPeer": ("No online peers available for ping test",),
    "testSuggestExitNodeAgainstLiveDaemon": ("Daemon returned an empty suggestion (no exit nodes); skipping", "No exit node candidates on this tailnet:"),
    "testDNSOSConfigAgainstLiveDaemon": ("Daemon has no OS DNS configuration (userspace mode); skipping",),
    "testNetcheckAgainstLiveDERPMap": ("No STUN responses (UDP blocked or empty DERP map); skipping",),
    "testInterfaceDiscovery": ("Interface discovery is Darwin-only (userspace tailscaled has no TUN)",),
    "testInterfaceInfo": ("Interface discovery is Darwin-only (userspace tailscaled has no TUN)",),
    "testNetworkInterfaceDiscoveryDirectly": ("Interface enumeration is Darwin-only; Linux returns empty results",),
    "testWhoIsProtoVariantAgainstLiveDaemon": ("Daemon did not resolve the proto-scoped lookup; skipping",),
    "testCheckUpdateAgainstLiveDaemon": ("Update check unavailable in this environment; skipping",),
    "testQueryFeatureAgainstLiveDaemon": ("Control plane does not support query-feature; skipping",),
}
# Only older daemon tracks may lack these endpoints. Stable must exercise them.
OLDER_SKIPS = {
    "testDaemonFeaturesAgainstLiveDaemon": "Daemon predates debug-optional-features; skipping",
    "testUserMetricsAgainstLiveDaemon": "Daemon predates usermetrics; skipping",
    "testPeerAndUserProfileLookupAgainstLiveDaemon": "Daemon predates the peer-by-id endpoint; skipping",
    "testDNSConfigAgainstLiveDaemon": "Daemon predates dns-config (Tailscale 1.98+); skipping",
    "testCheckUDPGROForwardingAgainstLiveDaemon": "Daemon does not serve check-udp-gro-forwarding; skipping",
    "testServicesAgainstLiveDaemon": "Daemon predates the services endpoint; skipping",
}


def expected_skip(test, reason, lane, member):
    if any(suite in test for suite in CRITICAL):
        return False
    if lane != "integration_linux_headscale":
        return (any(suite in test for suite in ("TailscaleClientIntegrationTests", "LoginLifecycleIntegrationTests"))
                and reason == "Integration tests disabled. Set TAILSCALE_INTEGRATION=1 to enable.")
    if "TailscaleClientIntegrationTests" not in test or not member.endswith("-api"):
        return False
    method = test.rstrip("]").replace(" ", ".").split(".")[-1]
    if any(reason == allowed or (allowed.endswith(":") and reason.startswith(allowed))
           for allowed in HEADSCALE_SKIPS.get(method, ())):
        return True
    return any(member == f"{track}-api" for track in TRACKS[:-1]) and reason == OLDER_SKIPS.get(method)


def parse_output(output, lane, member):
    # The final XCTest aggregate includes all suites; summing every summary double-counts.
    summaries = re.findall(r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", output)
    executed, skipped, failures = (int(summaries[-1][0]), int(summaries[-1][1] or 0), int(summaries[-1][2])) if summaries else (0, 0, 0)
    swift = re.findall(r"Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed)[^\n]*", output)
    if swift:
        executed += int(swift[-1][0])
        if swift[-1][1] == "failed":
            failures += 1
    active, reason, skips = "", "", []
    for line in output.splitlines():
        started = re.search(r"Test Case '(.+)' started", line)
        if started:
            active, reason = started.group(1), ""
        if "Test skipped - " in line:
            reason = line.split("Test skipped - ", 1)[1].strip()
        ended = re.search(r"Test Case '(.+)' skipped", line)
        if ended:
            test = ended.group(1)
            skips.append({"test": test, "reason": reason if test == active else "",
                          "expected": expected_skip(test, reason if test == active else "", lane, member)})
    errors = []
    if not summaries and not swift:
        errors.append("No recognized test summary")
    if skipped != len(skips):
        errors.append("Skipped test count does not match named skip records")
    # Swift Testing skips are not currently expected by this repository.
    if re.search(r"(?:Test|Suite) (?!Case )[^\n]+ skipped", output):
        errors.append("Unclassified Swift Testing skip")
    expected = sum(item["expected"] for item in skips)
    return {"executed": executed - skipped, "failures": failures, "skipped": skipped,
            "expected_skips": expected, "unexpected_skips": skipped - expected,
            "critical_skips": [item["test"] for item in skips if any(s in item["test"] for s in CRITICAL)]}, skips, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lane", choices=MEMBERS, required=True)
    parser.add_argument("--member", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("A test command is required after --")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    log_path = args.output.with_suffix(".log")
    with log_path.open("w") as log:
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
            sys.stdout.write(line)
            log.write(line)
        exit_code = proc.wait()
    summary, skips, errors = parse_output(log_path.read_text(), args.lane, args.member)
    environment = {"os": platform.platform(), "swift": subprocess.check_output(["swift", "--version"], text=True).strip()}
    if args.lane == "integration_linux_headscale":
        environment["tailscaled"] = subprocess.check_output(["tailscale", "version"], text=True).strip()
    report = {
        "schema_version": 1,
        "source_sha": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "run_id": os.environ.get("GITHUB_RUN_ID"),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "lane": args.lane, "member": args.member, "command": command, "exit_code": exit_code,
        "environment": environment,
        "test_summary": summary, "skips": skips, "errors": errors,
        "log_sha256": hashlib.sha256(log_path.read_bytes()).hexdigest(),
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    return 1 if exit_code or errors or summary["failures"] or summary["unexpected_skips"] or summary["executed"] <= 0 else 0


def attach_reports(lanes, directory, commit):
    """Attach validated reports; missing, stale, duplicate or altered logs fail closed."""
    reports = []
    load_errors = []
    for path in sorted(pathlib.Path(directory).rglob("*.json")):
        try:
            report = json.loads(path.read_text())
            if "lane" in report:
                reports.append((path, report))
        except (OSError, ValueError, TypeError) as error:
            load_errors.append(f"Unreadable report {path.name}: {error}")
    run_ids = {report.get("run_id") for _, report in reports}
    for lane, members in MEMBERS.items():
        result = lanes.setdefault(lane, {"name": lane})
        errors = list(load_errors)
        if not result.get("checks_passed", False):
            errors.append("Required CI checks did not all succeed")
        if len(run_ids) != 1 or None in run_ids:
            errors.append("Reports must come from one identified CI run")
        summaries, evidence = [], []
        for member in members:
            matching = [(path, report) for path, report in reports if report.get("lane") == lane and report.get("member") == member]
            if len(matching) != 1:
                errors.append(f"Expected exactly one report for {member}, found {len(matching)}")
                continue
            path, report = matching[0]
            if report.get("schema_version") != 1 or report.get("source_sha") != commit:
                errors.append(f"Wrong schema or source SHA for {member}")
            log_path = path.with_suffix(".log")
            try:
                log = log_path.read_bytes()
                if hashlib.sha256(log).hexdigest() != report.get("log_sha256"):
                    errors.append(f"Log digest mismatch for {member}")
                summary, skips, parse_errors = parse_output(log.decode(), lane, member)
                if summary != report.get("test_summary") or skips != report.get("skips"):
                    errors.append(f"Report does not match log for {member}")
                if parse_errors or report.get("errors") or report.get("exit_code") != 0:
                    errors.append(f"Failed or unparseable test run for {member}")
                if summary["executed"] <= 0 or summary["failures"] or summary["unexpected_skips"]:
                    errors.append(f"Missing tests, failures or unexpected skips for {member}")
                summaries.append(summary)
                evidence.append(report)
            except (OSError, UnicodeError) as error:
                errors.append(f"Missing or unreadable log for {member}: {error}")
        result["status"] = "unverified" if errors else "passed"
        result["test_reports"] = evidence
        result["test_summary"] = {key: sum(summary[key] for summary in summaries)
                                  for key in ("executed", "failures", "skipped", "expected_skips", "unexpected_skips")}
        result["test_summary"]["critical_skips"] = [test for summary in summaries for test in summary["critical_skips"]]
        result.pop("error", None)
        if errors:
            result["error"] = "; ".join(errors)
    return lanes


if __name__ == "__main__":
    sys.exit(main())
