#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David E. Weekly
"""Capture one sanitized /localapi/v0/ping reply from a running tailscaled as a test fixture.

Read-only: sends a single POST /localapi/v0/ping?ip=<ip>&type=<type> and nothing else.

Usage:
  python3 Scripts/capture-ping-fixture.py --peer HOSTNAME --type disco --name disco-direct
  python3 Scripts/capture-ping-fixture.py --self --type disco --name error-self-ip
  python3 Scripts/capture-ping-fixture.py --self-test

The LocalAPI credential comes from `tailscale debug local-creds` (macOS standalone and
App Store daemons) and stays in process memory: it is never placed on argv, printed, or
written. With --socket PATH the request goes over a Unix socket with no credential.

Every Tailscale IP, host name, MagicDNS name, and tailnet suffix that `tailscale status
--json` reports is replaced with a documentation value; any other IPv4 or IPv6 literal is
mapped into a documentation range; `NodeName` is always replaced, even when the daemon
returns a name status does not list. The result is leak-checked before it is written to
Tests/TailscaleClientTests/Fixtures/ping-captured-<name>.json, and its SHA-256 digest and
provenance are recorded in Tests/TailscaleClientTests/Fixtures/ping-captured.provenance.json.
"""

import argparse
import base64
import hashlib
import http.client
import json
import platform
import re
import socket
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Tests" / "TailscaleClientTests" / "Fixtures"
PROVENANCE = FIXTURES / "ping-captured.provenance.json"
PING_TYPES = ("disco", "TSMP", "ICMP", "peerapi")
DOC_PREFIXES = ("100.64.0.", "192.0.2.", "203.0.113.")

IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
IPV6 = re.compile(r"(?<![\w:.])[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{0,4}){2,7}(?![\w:])")


class Sanitizer:
    """Maps real addresses and names to documentation values, consistently within one reply."""

    def __init__(self, status):
        self.replacements = []  # (real, sanitized), applied longest first
        self.secrets = []
        self.generated = {}
        suffix = status.get("MagicDNSSuffix") or ""
        nodes = [("self", status.get("Self") or {})]
        nodes += [("peer", p) for p in (status.get("Peer") or {}).values()]
        for index, (role, node) in enumerate(nodes):
            name = "example-self" if role == "self" else f"example-peer-{index}"
            for ip in node.get("TailscaleIPs") or []:
                fake = f"fd7a:115c:a1e0::{index + 1:x}" if ":" in ip else f"100.64.0.{index + 1}"
                self._add(ip, fake)
            dns = (node.get("DNSName") or "").rstrip(".")
            if dns:
                self._add(dns, f"{name}.example.ts.net")
            if node.get("HostName"):
                self._add(node["HostName"], name)
        if suffix:
            self._add(suffix.rstrip("."), "example.ts.net")
        self.replacements.sort(key=lambda pair: -len(pair[0]))

    def _add(self, real, fake):
        self.replacements.append((real, fake))
        self.secrets.append(real)

    def _literal(self, value, fmt):
        if value not in self.generated:
            self.generated[value] = fmt.format(10 + len(self.generated))
        return self.generated[value]

    def scrub_text(self, text):
        for real, fake in self.replacements:
            text = text.replace(real, fake)

        def v4(match):
            ip = match.group(0)
            if ip.startswith(DOC_PREFIXES):
                return ip
            first, second = (int(part) for part in ip.split(".")[:2])
            private = first == 10 or (first == 172 and 16 <= second <= 31) or (
                first == 192 and second == 168)
            if 64 <= second <= 127 and first == 100:
                return self._literal(ip, "100.64.0.{}")
            return self._literal(ip, "192.0.2.{}" if private else "203.0.113.{}")

        def v6(match):
            ip = match.group(0)
            if ip.lower().startswith(("fd7a:115c:a1e0::", "2001:db8:")) or ip.count(":") < 2:
                return ip
            return self._literal(ip, "2001:db8::{:x}")

        return IPV6.sub(v6, IPV4.sub(v4, text))

    def scrub_reply(self, reply):
        text = self.scrub_text(json.dumps(reply, indent=2))
        sanitized = json.loads(text)
        name = sanitized.get("NodeName")
        if isinstance(name, str) and name and not name.startswith("example-"):
            fqdn = name.endswith(".")
            sanitized["NodeName"] = "example-peer.example.ts.net." if fqdn else "example-peer"
            if reply.get("NodeName"):
                self.secrets.append(reply["NodeName"].rstrip("."))
        return json.dumps(sanitized, indent=2) + "\n"

    def leaks(self, text):
        found = [s for s in self.secrets if s and s in text]
        found += [ip for ip in IPV4.findall(text) if not ip.startswith(DOC_PREFIXES)]
        return found


def run(args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def local_creds():
    out = run(["tailscale", "debug", "local-creds"])
    match = re.search(r"-u:(\S+)\s+http://[^:/\s]+:(\d+)/", out)
    if not match:
        sys.exit("could not parse `tailscale debug local-creds` output (not shown)")
    return match.group(1), int(match.group(2))


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("local-tailscaled.sock", timeout=timeout)
        self.socket_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


def ping(ip, ping_type, socket_path, timeout):
    path = "/localapi/v0/ping?" + urllib.parse.urlencode({"ip": ip, "type": ping_type})
    headers = {"Host": "local-tailscaled.sock", "Sec-Tailscale": "localapi"}
    if socket_path:
        conn = UnixHTTPConnection(socket_path, timeout)
    else:
        token, port = local_creds()
        headers["Authorization"] = "Basic " + base64.b64encode(f":{token}".encode()).decode()
        del token
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    conn.request("POST", path, headers=headers)
    response = conn.getresponse()
    body = response.read()
    if response.status != 200:
        sys.exit(f"HTTP {response.status} from /localapi/v0/ping; nothing written")
    return json.loads(body)


def daemon_version():
    try:
        version = json.loads(run(["tailscale", "version", "--json"]))
        return {"short": version.get("short"), "long": version.get("long"),
                "commit": version.get("gitCommit")}
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return {"short": "unknown"}


def record(name, ping_type, text, version, request):
    data = json.loads(PROVENANCE.read_text()) if PROVENANCE.exists() else {"captured": {}}
    data.setdefault("captured", {})[f"ping-captured-{name}.json"] = {
        "sha256": hashlib.sha256(text.encode()).hexdigest(),
        "type": ping_type,
        "request": request,
        "daemon": version,
        "os": f"{platform.system()} {platform.mac_ver()[0] or platform.release()}",
        "captured_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "capture_command": f"python3 Scripts/capture-ping-fixture.py ... --type {ping_type} "
                           f"--name {name}",
    }
    PROVENANCE.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def verify_digests():
    """Fails if a captured fixture no longer matches its recorded digest."""
    data = json.loads(PROVENANCE.read_text())
    bad = []
    for file, meta in data.get("captured", {}).items():
        actual = hashlib.sha256((FIXTURES / file).read_bytes()).hexdigest()
        if actual != meta["sha256"]:
            bad.append(file)
    return bad


def self_test():
    status = {
        "MagicDNSSuffix": "tail1234.ts.net",
        "Self": {"HostName": "realself", "DNSName": "realself.tail1234.ts.net.",
                 "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0:ab12::1"]},
        "Peer": {"k": {"HostName": "realpeer", "DNSName": "realpeer.tail1234.ts.net.",
                       "TailscaleIPs": ["100.99.98.97"]}},
    }
    reply = {"IP": "100.99.98.97", "NodeIP": "100.99.98.97", "NodeName": "unlisted-box",
             "Err": "", "LatencySeconds": 0.004, "Endpoint": "[2600:1700:abcd::5]:41641",
             "PeerRelay": "", "DERPRegionID": 0, "DERPRegionCode": "",
             "PeerAPIURL": "http://100.99.98.97:42272"}
    fqdn = dict(reply, NodeName="realpeer.tail1234.ts.net.", Endpoint="192.168.1.20:41641")
    failures = []
    for case in (reply, fqdn):
        sanitizer = Sanitizer(status)
        text = sanitizer.scrub_reply(case)
        out = json.loads(text)
        for real in ("100.99.98.97", "unlisted-box", "realpeer", "tail1234", "2600:1700",
                     "192.168.1.20"):
            if real in text:
                failures.append(f"leaked {real!r}")
        if sanitizer.leaks(text):
            failures.append(f"leak check flagged {sanitizer.leaks(text)}")
        if list(out) != list(case):
            failures.append("key order or key set changed")
        if out["LatencySeconds"] != case["LatencySeconds"] or out["Err"] != case["Err"]:
            failures.append("non-identifying value changed")
        if case["NodeName"].endswith(".") != out["NodeName"].endswith("."):
            failures.append("trailing dot of an FQDN NodeName not preserved")
        if hashlib.sha256(text.encode()).hexdigest() != hashlib.sha256(
                Sanitizer(status).scrub_reply(case).encode()).hexdigest():
            failures.append("sanitization is not deterministic")
    leaky = Sanitizer(status)
    if not leaky.leaks('{"NodeName": "realpeer", "IP": "8.8.8.8"}'):
        failures.append("leak check missed a real host name and a public IPv4")
    failures += [f"digest mismatch: {f}" for f in verify_digests()]
    if failures:
        print("capture-ping-fixture self-test FAILED:\n  " + "\n  ".join(failures))
        sys.exit(1)
    print("capture-ping-fixture self-test passed (sanitization, leak check, fixture digests).")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--peer", help="HostName of the peer to ping, as in `tailscale status`")
    target.add_argument("--self", action="store_true", help="ping this node's own IP")
    target.add_argument("--self-test", action="store_true", help="run offline checks and exit")
    parser.add_argument("--type", choices=PING_TYPES, default="disco")
    parser.add_argument("--name", help="fixture name: ping-captured-<name>.json")
    parser.add_argument("--socket", help="LocalAPI Unix socket (no credential sent)")
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not (args.peer or args.self) or not args.name:
        parser.error("--peer or --self, and --name, are required for a capture")

    status = json.loads(run(["tailscale", "status", "--json"]))
    if args.self:
        node = status["Self"]
    else:
        node = next((p for p in (status.get("Peer") or {}).values()
                     if p.get("HostName") == args.peer), None)
        if node is None:
            sys.exit("no peer with that HostName in `tailscale status --json`")
    sanitizer = Sanitizer(status)
    reply = ping(node["TailscaleIPs"][0], args.type, args.socket, args.timeout)
    text = sanitizer.scrub_reply(reply)
    if sanitizer.leaks(text):
        sys.exit("leak check failed; nothing written")
    out = FIXTURES / f"ping-captured-{args.name}.json"
    out.write_text(text)
    request = f"POST /localapi/v0/ping?ip=<{'self' if args.self else 'peer'}-ip>&type={args.type}"
    record(args.name, args.type, text, daemon_version(), request)
    print(f"wrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
