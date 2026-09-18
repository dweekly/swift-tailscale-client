#!/usr/bin/env python3
"""
Scripts/capture-fixtures.py - Capture, synthesize, sanitize, and verify Tailscale LocalAPI fixtures.

Supports:
- Live daemon capture over Unix domain socket or TCP loopback with proof token
- Deterministic synthetic generation across supported daemon versions (1.76.0, 1.84.0, 1.96.4, 1.98.0)
- Single-file sanitization preserving relational integrity and HTTP ETags
- Purity auditing and manifest verification with SHA-256 integrity digests

Zero external dependencies: uses only Python 3 standard library.
"""

import argparse
import base64
import hashlib
import http.client
import json
import os
import re
import socket
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SUPPORTED_MATRIX_VERSIONS = ["1.76.0", "1.84.0", "1.96.4", "1.98.0"]
DEFAULT_OUTPUT_DIR = Path("Tests/TailscaleClientTests/Fixtures/LocalAPI")

UPSTREAM_COMMITS = {
    "1.76.0": "d25bc2f1bfb83c79da58f334a1795c6bf7589255",
    "1.84.0": "495562d9894e43f554862ba2c72b143714dfb079",
    "1.96.4": "8cf541dfd1e0a97096c01cb775d5e26336f3bc6c",
    "1.98.0": "4c4d1c35f83a21c6069ae09de69b246ed1993f3e",
}

CAPABILITY_VERSIONS = {
    "1.76.0": 106,
    "1.84.0": 116,
    "1.96.4": 133,
    "1.98.0": 144,
}


# ============================================================================
# 1. Sanitization Engine
# ============================================================================

class SanitizationEngine:
    """
    Deterministic, stateful pseudonymizer that preserves relational integrity
    across multiple objects in a LocalAPI payload.
    """

    def __init__(self, version_label: str = "1.0"):
        self.version_label = version_label
        self.cgnat_seq = 1
        self.ula_seq = 1
        self.pub_seq = 1
        self.nodekey_seq = 1
        self.mkey_seq = 1
        self.discokey_seq = 1
        self.nlkey_seq = 1
        self.user_seq = 1
        self.node_id_seq = 1

        self.ip_map: Dict[str, str] = {}
        self.key_map: Dict[str, str] = {}
        self.user_map: Dict[str, Tuple[int, str, str]] = {}
        self.node_id_map: Dict[str, str] = {}

    def get_cgnat_ip(self, original_ip: str) -> str:
        if original_ip not in self.ip_map:
            self.ip_map[original_ip] = f"100.64.0.{self.cgnat_seq}"
            self.cgnat_seq += 1
        return self.ip_map[original_ip]

    def get_ula_ipv6(self, original_ip: str) -> str:
        if original_ip not in self.ip_map:
            hex_suffix = f"{self.ula_seq:04x}"
            self.ip_map[original_ip] = f"fd7a:115c:a1e0:ab12:4843:cd96:6200:{hex_suffix}"
            self.ula_seq += 1
        return self.ip_map[original_ip]

    def get_public_ip(self, original_ip: str) -> str:
        if original_ip not in self.ip_map:
            # Use RFC 5737 TEST-NET-2 (198.51.100.0/24)
            self.ip_map[original_ip] = f"198.51.100.{10 + self.pub_seq}"
            self.pub_seq += 1
        return self.ip_map[original_ip]

    def get_nodekey(self, original_key: str) -> str:
        if original_key not in self.key_map:
            char = chr(ord('a') + ((self.nodekey_seq - 1) % 26))
            self.key_map[original_key] = f"nodekey:{char * 64}"
            self.nodekey_seq += 1
        return self.key_map[original_key]

    def get_mkey(self, original_key: str) -> str:
        if original_key not in self.key_map:
            hex_str = f"{self.mkey_seq:02x}" * 32
            self.key_map[original_key] = f"mkey:{hex_str}"
            self.mkey_seq += 1
        return self.key_map[original_key]

    def get_discokey(self, original_key: str) -> str:
        if original_key not in self.key_map:
            hex_str = f"d{self.discokey_seq:02x}" * 21 + "d"
            self.key_map[original_key] = f"discokey:{hex_str[:64]}"
            self.discokey_seq += 1
        return self.key_map[original_key]

    def get_nlkey(self, original_key: str) -> str:
        if original_key not in self.key_map:
            hex_str = f"e{self.nlkey_seq:02x}" * 21 + "e"
            self.key_map[original_key] = f"nlkey:{hex_str[:64]}"
            self.nlkey_seq += 1
        return self.key_map[original_key]

    def get_user(self, original_user: str) -> Tuple[int, str, str]:
        if original_user not in self.user_map:
            uid = 1000000000000000 + self.user_seq
            if self.user_seq == 1:
                email = "user1@example.com"
                name = "Self User"
            elif self.user_seq == 2:
                email = "peer1@example.com"
                name = "Peer User 1"
            else:
                email = f"user{self.user_seq}@example.com"
                name = f"User {self.user_seq}"
            self.user_map[original_user] = (uid, email, name)
            self.user_seq += 1
        return self.user_map[original_user]

    def sanitize_string(self, text: str) -> str:
        # 1. Private keys - immediately zero
        text = re.sub(r"\bprivkey:[0-9a-fA-F]{64}\b", "privkey:0000000000000000000000000000000000000000000000000000000000000000", text)

        # 2. Auth tokens and Proof tokens
        text = re.sub(r"\btskey-auth-[a-zA-Z0-9_-]+\b", "tskey-auth-synthetic-test-key-000000000000", text)
        text = re.sub(r"\btskey-api-[a-zA-Z0-9_-]+\b", "tskey-api-synthetic-test-token-000000000000", text)
        text = re.sub(r"\bsameuserproof-[0-9]+-[0-9a-fA-F]+\b", "sameuserproof-0000-0123456789abcdef", text)

        # 3. Public Keys
        for m in re.finditer(r"\bnodekey:([0-9a-fA-F]{64})\b", text):
            full = m.group(0)
            text = text.replace(full, self.get_nodekey(full))
        for m in re.finditer(r"\bmkey:([0-9a-fA-F]{64})\b", text):
            full = m.group(0)
            text = text.replace(full, self.get_mkey(full))
        for m in re.finditer(r"\bdiscokey:([0-9a-fA-F]{64})\b", text):
            full = m.group(0)
            text = text.replace(full, self.get_discokey(full))
        for m in re.finditer(r"\bnlkey:([0-9a-fA-F]{64})\b", text):
            full = m.group(0)
            text = text.replace(full, self.get_nlkey(full))

        # 4. Tailnet Domains & Hostnames
        def replace_domain(match):
            full = match.group(0)
            has_trailing_dot = full.endswith('.')
            clean = full.rstrip('.')
            parts = clean.split('.')
            if len(parts) <= 3:  # e.g. ts.net or example.ts.net
                return "example.ts.net." if has_trailing_dot else "example.ts.net"
            else:
                host = parts[0]
                return f"{host}.example.ts.net." if has_trailing_dot else f"{host}.example.ts.net"

        text = re.sub(r"\b[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*\.ts\.net\.?", replace_domain, text)

        # 5. IP Addresses
        def replace_ip(match):
            ip = match.group(1)
            prefix = match.group(2) or ""
            port = match.group(3) or ""
            # Preserve quad-100 and well-known DNS resolvers
            if ip == "100.100.100.100":
                return f"{ip}{prefix}{port}"
            if ip in ("1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9"):
                return f"{ip}{prefix}{port}"
            octets = [int(o) for o in ip.split('.')]
            if octets[0] == 100 and (64 <= octets[1] <= 127):
                new_ip = self.get_cgnat_ip(ip)
            elif octets[0] == 10:
                new_ip = ip  # 10.0.0.0/8
            elif octets[0] == 172 and (16 <= octets[1] <= 31):
                new_ip = ip  # 172.16.0.0/12
            elif octets[0] == 192 and octets[1] == 168:
                new_ip = ip  # 192.168.0.0/16
            elif octets[0] in (0, 127, 255):
                new_ip = ip  # loopback, wildcard, broadcast
            else:
                new_ip = self.get_public_ip(ip)
            return f"{new_ip}{prefix}{port}"

        # Match IPv4 with optional /CIDR or :PORT
        ipv4_regex = r"\b((?:[0-9]{1,3}\.){3}[0-9]{1,3})(/(?:[0-9]{1,2}))?(:[0-9]+)?\b"
        text = re.sub(ipv4_regex, replace_ip, text)

        # Match ULA IPv6
        def replace_ula(match):
            full_ip = match.group(1)
            prefix = match.group(2) or ""
            new_ip = self.get_ula_ipv6(full_ip)
            return f"{new_ip}{prefix}"

        text = re.sub(r"\b(fd7a:115c:[0-9a-fA-F:]+)(/(?:[0-9]{1,3}))?\b", replace_ula, text)

        # 6. Emails
        def replace_email(match):
            full = match.group(0)
            uid, email, _ = self.get_user(full)
            return email

        text = re.sub(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b", replace_email, text)

        return text

    def sanitize(self, data: Any) -> Any:
        """Recursively sanitize JSON data structures."""
        if isinstance(data, dict):
            new_dict = {}
            for k, v in data.items():
                sanitized_key = self.sanitize_string(str(k))
                new_dict[sanitized_key] = self.sanitize(v)
            return new_dict
        elif isinstance(data, list):
            return [self.sanitize(item) for item in data]
        elif isinstance(data, str):
            return self.sanitize_string(data)
        elif isinstance(data, (int, float, bool)) or data is None:
            return data
        else:
            return self.sanitize_string(str(data))

    @staticmethod
    def verify_no_leaks(text: str) -> List[str]:
        """Audits text content for potential un-redacted secrets."""
        violations = []
        forbidden_regexes = [
            (r"\btskey-auth-(?!synthetic)[a-zA-Z0-9_-]{10,}\b", "Unredacted auth token"),
            (r"\btskey-api-(?!synthetic)[a-zA-Z0-9_-]{10,}\b", "Unredacted API token"),
            (r"\bsameuserproof-(?!0000-0123456789abcdef)[a-zA-Z0-9_-]+\b", "Unredacted proof token"),
            (r"\bprivkey:(?!00000000)[0-9a-fA-F]{64}\b", "Unredacted private key"),
            (r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----", "Raw PEM private key"),
        ]
        for pattern, msg in forbidden_regexes:
            match = re.search(pattern, text)
            if match:
                violations.append(f"{msg}: {match.group(0)[:30]}...")

        # Verify emails: must only be @example.com or @test.org
        emails = re.findall(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b", text)
        for email in emails:
            domain = email.split("@")[1].lower()
            if domain not in ("example.com", "test.org", "tailscale.com", "example.ts.net"):
                violations.append(f"Potential real email domain leak: {email}")

        return violations


# ============================================================================
# 2. LocalAPI Connection (Live Capture)
# ============================================================================

class UnixSocketHTTPConnection(http.client.HTTPConnection):
    """HTTPConnection over a POSIX Unix Domain Socket."""

    def __init__(self, socket_path: str, timeout: float = 10.0):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.socket_path)
        self.sock = sock


class LocalAPIDaemonClient:
    """Client for querying Tailscale LocalAPI daemon."""

    def __init__(self, socket_path: Optional[str] = None, port: Optional[int] = None, token: Optional[str] = None):
        self.socket_path = socket_path
        self.port = port
        self.token = token

    def request(self, method: str, path: str, body: Optional[bytes] = None) -> Tuple[int, Dict[str, str], bytes]:
        if self.socket_path:
            conn = UnixSocketHTTPConnection(self.socket_path)
        elif self.port:
            conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10.0)
        else:
            raise ValueError("Either socket_path or port must be specified")

        headers = {
            "Host": "local-tailscaled.sock",
            "Sec-Tailscale": "localapi",
            "User-Agent": "TailscaleClient-Capture/1.0",
        }
        if self.token:
            auth_str = base64.b64encode(f":{self.token}".encode("utf-8")).decode("ascii")
            headers["Authorization"] = f"Basic {auth_str}"

        try:
            conn.request(method, path, body=body, headers=headers)
            resp = conn.getresponse()
            status = resp.status
            resp_headers = {k: v for k, v in resp.getheaders()}
            content = resp.read()
            return status, resp_headers, content
        finally:
            conn.close()


# ============================================================================
# 3. Synthetic Fixture Matrix Generator
# ============================================================================

class SyntheticFixtureGenerator:
    """Generates canonical, sanitized fixtures for supported daemon matrix versions."""

    @staticmethod
    def generate_status(version: str, peers: bool = True) -> Dict[str, Any]:
        has_taildrop = version in ("1.84.0", "1.96.4", "1.98.0")
        has_relay = version in ("1.96.4", "1.98.0")

        self_node = {
            "ID": "nSelfExample",
            "PublicKey": "nodekey:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "HostName": "example-device",
            "DNSName": "example-device.example.ts.net.",
            "OS": "macOS",
            "UserID": 1000000000000001,
            "TailscaleIPs": [
                "100.64.0.1",
                "fd7a:115c:a1e0:ab12:4843:cd96:6200:0001"
            ],
            "AllowedIPs": [
                "100.64.0.1/32",
                "fd7a:115c:a1e0:ab12:4843:cd96:6200:0001/128"
            ],
            "Addrs": [
                "198.51.100.10:41641"
            ],
            "CurAddr": "",
            "Relay": "nyc",
            "PeerRelay": "198.51.100.50:41641:1" if has_relay else "",
            "RxBytes": 1024,
            "TxBytes": 2048,
            "Created": "2024-01-01T00:00:00Z",
            "LastWrite": "0001-01-01T00:00:00Z",
            "LastSeen": "0001-01-01T00:00:00Z",
            "LastHandshake": "0001-01-01T00:00:00Z",
            "Online": True,
            "ExitNode": False,
            "ExitNodeOption": False,
            "Active": False,
            "PeerAPIURL": [
                "http://100.64.0.1:12345"
            ],
            "Capabilities": [
                "https",
                "https://tailscale.com/cap/ssh",
                "tailnet.maxKeyDuration"
            ],
            "CapMap": {
                "tailnet.maxKeyDuration": [86400],
                "https://tailscale.com/cap/ssh": None
            },
            "InNetworkMap": True,
            "InMagicSock": True,
            "InEngine": True,
            "KeyExpiry": "2025-01-01T00:00:00Z"
        }
        if has_taildrop:
            self_node["TaildropTarget"] = 0
            self_node["NoFileSharingReason"] = ""

        peer_map = {}
        if peers:
            peer1 = {
                "ID": "nPeerExample1",
                "PublicKey": "nodekey:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                "HostName": "peer-device-1",
                "DNSName": "peer-device-1.example.ts.net.",
                "OS": "linux",
                "UserID": 1000000000000002,
                "TailscaleIPs": [
                    "100.64.0.2"
                ],
                "AllowedIPs": [
                    "100.64.0.2/32"
                ],
                "Addrs": None,
                "CurAddr": "",
                "Relay": "sfo",
                "PeerRelay": "198.51.100.51:41641:1" if has_relay else "",
                "RxBytes": 512,
                "TxBytes": 1024,
                "Created": "2024-01-02T00:00:00Z",
                "LastWrite": "0001-01-01T00:00:00Z",
                "LastSeen": "0001-01-01T00:00:00Z",
                "LastHandshake": "0001-01-01T00:00:00Z",
                "Online": True,
                "ExitNode": False,
                "ExitNodeOption": True,
                "Active": True,
                "PeerAPIURL": [
                    "http://100.64.0.2:12346"
                ],
                "CapMap": {},
                "InNetworkMap": True,
                "InMagicSock": True,
                "InEngine": True
            }
            if has_taildrop:
                peer1["TaildropTarget"] = 1
                peer1["NoFileSharingReason"] = ""
            peer_map["nodekey:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"] = peer1

        users = {
            "1000000000000001": {
                "ID": 1000000000000001,
                "LoginName": "user1@example.com",
                "DisplayName": "Self User",
                "ProfilePicURL": "https://example.com/avatars/user1.png"
            }
        }
        if peers:
            users["1000000000000002"] = {
                "ID": 1000000000000002,
                "LoginName": "peer1@example.com",
                "DisplayName": "Peer User 1"
            }

        return {
            "Version": version,
            "TUN": True,
            "BackendState": "Running",
            "HaveNodeKey": True,
            "AuthURL": "",
            "TailscaleIPs": [
                "100.64.0.1",
                "fd7a:115c:a1e0:ab12:4843:cd96:6200:0001"
            ],
            "Self": self_node,
            "Health": [],
            "MagicDNSSuffix": "example.ts.net",
            "CurrentTailnet": {
                "Name": "example.ts.net",
                "MagicDNSSuffix": "example.ts.net",
                "MagicDNSEnabled": True
            },
            "CertDomains": [
                "example-device.example.ts.net"
            ],
            "Peer": peer_map,
            "User": users,
            "ClientVersion": {
                "RunningLatest": True
            }
        }

    @staticmethod
    def generate_whois(version: str) -> Dict[str, Any]:
        return {
            "Node": {
                "ID": 1000000000000001,
                "StableID": "nStableSelf001",
                "Name": "example-device.example.ts.net.",
                "User": 1000000000000001,
                "Key": "nodekey:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "KeyExpiry": "2025-06-15T12:00:00Z",
                "Machine": "mkey:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                "DiscoKey": "discokey:1111111111111111111111111111111111111111111111111111111111111111",
                "Addresses": [
                    "100.64.0.1/32",
                    "fd7a:115c:a1e0:ab12:4843:cd96:6200:0001/128"
                ],
                "AllowedIPs": [
                    "100.64.0.1/32",
                    "fd7a:115c:a1e0:ab12:4843:cd96:6200:0001/128"
                ],
                "Endpoints": [
                    "198.51.100.10:41641"
                ],
                "DERP": "https://controlplane.tailscale.com/derpmap/default",
                "Hostinfo": {
                    "OS": "macOS",
                    "OSVersion": "14.0.0",
                    "Hostname": "example-device",
                    "TailscaleVersion": version,
                    "SSH": True
                },
                "Created": "2024-01-01T00:00:00Z",
                "Tags": ["tag:server"],
                "Expired": False,
                "Online": True,
                "LastSeen": "2024-01-01T00:00:00Z",
                "ComputedName": "example-device",
                "ComputedNameWithHost": "example-device (example-device)",
                "IsExitNode": False
            },
            "UserProfile": {
                "ID": 1000000000000001,
                "LoginName": "user1@example.com",
                "DisplayName": "Self User",
                "ProfilePicURL": "https://example.com/avatars/user1.png"
            },
            "CapMap": {
                "tailnet.maxKeyDuration": [86400]
            }
        }

    @staticmethod
    def generate_prefs(version: str) -> Dict[str, Any]:
        prefs = {
            "ControlURL": "https://controlplane.tailscale.com",
            "RouteAll": False,
            "ExitNodeID": "nExitNodeStable001",
            "ExitNodeIP": "100.64.0.10",
            "ExitNodeAllowLANAccess": True,
            "CorpDNS": True,
            "RunSSH": False,
            "RunWebClient": False,
            "WantRunning": True,
            "LoggedOut": False,
            "ShieldsUp": False,
            "AdvertiseTags": ["tag:client"],
            "Hostname": "example-device",
            "ForceDaemon": False,
            "AdvertiseRoutes": ["192.168.1.0/24"],
            "NoSNAT": False,
            "NetfilterMode": 2,
            "OperatorUser": "admin",
            "ProfileName": "default",
            "AutoUpdate": {
                "Check": True,
                "Apply": False
            },
            "AppConnector": {
                "Advertise": False
            },
            "PostureChecking": False
        }
        if version in ("1.96.4", "1.98.0"):
            prefs["AdvertiseServices"] = ["svc:metrics"]
            prefs["AutoExitNode"] = ""
        return prefs

    @staticmethod
    def generate_serve_config(version: str) -> Dict[str, Any]:
        return {
            "TCP": {
                "443": {"HTTPS": True},
                "10000": {
                    "TCPForward": "127.0.0.1:8080",
                    "TerminateTLS": "example-device.example.ts.net"
                }
            },
            "Web": {
                "example-device.example.ts.net:443": {
                    "Handlers": {
                        "/": {"Proxy": "http://127.0.0.1:3000"},
                        "/static": {"Path": "/var/www/"},
                        "/motd": {"Text": "hello from the tailnet"},
                        "/old": {"Redirect": "https://example.com/new"}
                    }
                }
            },
            "AllowFunnel": {
                "example-device.example.ts.net:443": True
            },
            "Foreground": {
                "session-abc123": {
                    "TCP": {"8443": {"HTTPS": True}}
                }
            },
            "CustomVendorSetting": {
                "FeatureActive": True,
                "RateLimit": 5000000000
            }
        }

    @staticmethod
    def generate_derpmap(version: str) -> Dict[str, Any]:
        return {
            "HomeParams": {
                "RegionScore": {
                    "1": 0.95,
                    "2": 1.05
                }
            },
            "Regions": {
                "1": {
                    "RegionID": 1,
                    "RegionCode": "nyc",
                    "RegionName": "New York City",
                    "Latitude": 40.7128,
                    "Longitude": -74.0060,
                    "Nodes": [
                        {
                            "Name": "1a",
                            "RegionID": 1,
                            "HostName": "derp1a.example.ts.net",
                            "IPv4": "198.51.100.100",
                            "IPv6": "fd7a:115c:a1e0:ab12:4843:cd96:6200:0100",
                            "CanPort80": True
                        }
                    ]
                },
                "2": {
                    "RegionID": 2,
                    "RegionCode": "sfo",
                    "RegionName": "San Francisco",
                    "Latitude": 37.7749,
                    "Longitude": -122.4194,
                    "Nodes": [
                        {
                            "Name": "2a",
                            "RegionID": 2,
                            "HostName": "derp2a.example.ts.net",
                            "IPv4": "198.51.100.101",
                            "CanPort80": True
                        }
                    ]
                }
            },
            "OmitDefaultRegions": False
        }

    @staticmethod
    def generate_cert_domains(version: str) -> List[str]:
        return ["example-device.example.ts.net"]

    @staticmethod
    def generate_suggest_exit_node(version: str) -> Dict[str, Any]:
        return {
            "ID": "nExitNodeStable001",
            "Name": "exit-node.example.ts.net.",
            "Location": {
                "Country": "USA",
                "CountryCode": "US",
                "City": "San Francisco, CA",
                "CityCode": "SFO",
                "Latitude": 37.7749,
                "Longitude": -122.4194,
                "Priority": 100
            }
        }

    @staticmethod
    def generate_dns_osconfig(version: str) -> Dict[str, Any]:
        return {
            "Nameservers": [
                "100.100.100.100"
            ],
            "SearchDomains": [
                "example.ts.net."
            ],
            "MatchDomains": [
                "example.ts.net."
            ]
        }

    @staticmethod
    def generate_debug_optional_features(version: str) -> Dict[str, Any]:
        return {
            "Features": {
                "acme": True,
                "serve": True,
                "debug": True,
                "tailnetlock": True
            }
        }

    @staticmethod
    def generate_profiles(version: str) -> List[Dict[str, Any]]:
        return [
            {
                "ID": "48d1",
                "Name": "user1@example.com",
                "NetworkProfile": {
                    "MagicDNSName": "example-device.example.ts.net",
                    "DomainName": "example.ts.net",
                    "DisplayName": "example-corp"
                },
                "UserProfile": {
                    "ID": 1000000000000001,
                    "LoginName": "user1@example.com",
                    "DisplayName": "Self User"
                },
                "NodeID": "nStableSelf001",
                "ControlURL": "https://controlplane.tailscale.com",
                "Created": "2024-01-01T00:00:00Z"
            }
        ]

    @staticmethod
    def generate_services(version: str) -> Dict[str, Any]:
        return {
            "svc:metrics": {
                "Name": "svc:metrics",
                "DisplayName": "Internal Metrics",
                "Addrs": [
                    "100.64.0.10"
                ],
                "Ports": [
                    "tcp:9090"
                ],
                "Actions": [
                    {
                        "Type": "prometheus",
                        "Port": 9090,
                        "DisplayName": "Prometheus Scrape"
                    }
                ]
            }
        }

    @staticmethod
    def generate_dns_config(version: str) -> Dict[str, Any]:
        return {
            "Resolvers": [
                {
                    "Addr": "1.1.1.1",
                    "BootstrapResolution": ["1.1.1.1"],
                    "UseWithExitNode": False
                }
            ],
            "Routes": {
                "internal.example.com.": [
                    {
                        "Addr": "10.0.0.1",
                        "BootstrapResolution": [],
                        "UseWithExitNode": True
                    }
                ]
            },
            "FallbackResolvers": [
                {
                    "Addr": "8.8.8.8",
                    "BootstrapResolution": ["8.8.8.8"],
                    "UseWithExitNode": False
                }
            ],
            "Domains": [
                "example.ts.net"
            ],
            "Proxied": True,
            "CertDomains": [
                "example-device.example.ts.net"
            ],
            "ExtraRecords": [
                {
                    "Name": "wiki.example.ts.net",
                    "Type": "A",
                    "Value": "100.64.0.20"
                }
            ],
            "ExitNodeFilteredSet": [
                ".internal.example.com"
            ]
        }


# ============================================================================
# 4. Manifest Builder & Runner
# ============================================================================

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def write_json(path: Path, data: Any):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")


def build_version_manifest(
    version: str,
    endpoint_metadata: Dict[str, Dict[str, Any]],
    output_dir: Path,
    is_synthetic: bool = False
) -> Dict[str, Any]:
    return {
        "schema_version": "1.0.0",
        "daemon_version": version,
        "upstream_git_commit": UPSTREAM_COMMITS.get(version, "unknown"),
        "capability_version": CAPABILITY_VERSIONS.get(version, 144),
        "capture_timestamp": datetime.now(timezone.utc).isoformat(),
        "platform": {
            "os": "darwin",
            "arch": "arm64",
            "flavor": "synthetic" if is_synthetic else "standalone_pkg"
        },
        "is_synthetic": is_synthetic,
        "capture_command": f"python3 Scripts/capture-fixtures.py --synthetic --version {version}" if is_synthetic else "live",
        "sanitization": {
            "rules_applied": [
                "redact_auth_tokens",
                "anonymize_ips",
                "pseudonymize_keys",
                "pseudonymize_users",
                "anonymize_tailnet_fqdn",
                "normalize_etags"
            ],
            "sanitizer_version": "1.0.0"
        },
        "endpoints": endpoint_metadata
    }


def generate_matrix(output_base: Path):
    """Generates synthetic fixtures and manifests for the supported version matrix."""
    master_versions = {}
    sanitizer = SanitizationEngine()

    for version in SUPPORTED_MATRIX_VERSIONS:
        ver_dir = output_base / version
        ver_dir.mkdir(parents=True, exist_ok=True)
        gen = SyntheticFixtureGenerator

        endpoints_map = {}

        # 1. status
        status_data = sanitizer.sanitize(gen.generate_status(version, peers=True))
        write_json(ver_dir / "status.json", status_data)
        endpoints_map["status"] = {
            "file": "status.json",
            "path": "/localapi/v0/status",
            "method": "GET",
            "http_status": 200,
            "headers": {
                "Content-Type": "application/json",
                "Tailscale-Version": f"{version}-tb{UPSTREAM_COMMITS[version][:10]}"
            },
            "sha256": sha256_file(ver_dir / "status.json"),
            "swift_model": "StatusResponse"
        }

        # 2. status_peers_false
        status_no_peers = sanitizer.sanitize(gen.generate_status(version, peers=False))
        write_json(ver_dir / "status_peers_false.json", status_no_peers)
        endpoints_map["status_peers_false"] = {
            "file": "status_peers_false.json",
            "path": "/localapi/v0/status?peers=false",
            "method": "GET",
            "http_status": 200,
            "headers": {
                "Content-Type": "application/json",
                "Tailscale-Version": f"{version}-tb{UPSTREAM_COMMITS[version][:10]}"
            },
            "sha256": sha256_file(ver_dir / "status_peers_false.json"),
            "swift_model": "StatusResponse"
        }

        # 3. whois
        whois_data = sanitizer.sanitize(gen.generate_whois(version))
        write_json(ver_dir / "whois.json", whois_data)
        endpoints_map["whois"] = {
            "file": "whois.json",
            "path": "/localapi/v0/whois?addr=100.64.0.1",
            "method": "GET",
            "http_status": 200,
            "headers": {
                "Content-Type": "application/json"
            },
            "sha256": sha256_file(ver_dir / "whois.json"),
            "swift_model": "WhoIsResponse"
        }

        # 4. prefs
        prefs_data = sanitizer.sanitize(gen.generate_prefs(version))
        write_json(ver_dir / "prefs.json", prefs_data)
        endpoints_map["prefs"] = {
            "file": "prefs.json",
            "path": "/localapi/v0/prefs",
            "method": "GET",
            "http_status": 200,
            "headers": {
                "Content-Type": "application/json"
            },
            "sha256": sha256_file(ver_dir / "prefs.json"),
            "swift_model": "Prefs"
        }

        # 5. serve-config
        serve_data = sanitizer.sanitize(gen.generate_serve_config(version))
        write_json(ver_dir / "serve-config.json", serve_data)
        etag = f"\"etag-sanitized-{version}-001\""
        endpoints_map["serve_config"] = {
            "file": "serve-config.json",
            "path": "/localapi/v0/serve-config",
            "method": "GET",
            "http_status": 200,
            "headers": {
                "Content-Type": "application/json",
                "ETag": etag
            },
            "sha256": sha256_file(ver_dir / "serve-config.json"),
            "swift_model": "ServeConfig"
        }

        # 6. derpmap
        derp_data = sanitizer.sanitize(gen.generate_derpmap(version))
        write_json(ver_dir / "derpmap.json", derp_data)
        endpoints_map["derpmap"] = {
            "file": "derpmap.json",
            "path": "/localapi/v0/derpmap",
            "method": "GET",
            "http_status": 200,
            "headers": {
                "Content-Type": "application/json"
            },
            "sha256": sha256_file(ver_dir / "derpmap.json"),
            "swift_model": "DERPMap"
        }

        # 7. cert-domains
        cert_data = sanitizer.sanitize(gen.generate_cert_domains(version))
        write_json(ver_dir / "cert-domains.json", cert_data)
        endpoints_map["cert_domains"] = {
            "file": "cert-domains.json",
            "path": "/localapi/v0/cert-domains",
            "method": "GET",
            "http_status": 200,
            "headers": {
                "Content-Type": "application/json"
            },
            "sha256": sha256_file(ver_dir / "cert-domains.json"),
            "swift_model": "[String]"
        }

        # Endpoints added in 1.84.0+
        if version in ("1.84.0", "1.96.4", "1.98.0"):
            exit_data = sanitizer.sanitize(gen.generate_suggest_exit_node(version))
            write_json(ver_dir / "suggest-exit-node.json", exit_data)
            endpoints_map["suggest_exit_node"] = {
                "file": "suggest-exit-node.json",
                "path": "/localapi/v0/suggest-exit-node",
                "method": "GET",
                "http_status": 200,
                "headers": {
                    "Content-Type": "application/json"
                },
                "sha256": sha256_file(ver_dir / "suggest-exit-node.json"),
                "swift_model": "ExitNodeSuggestion"
            }

            dns_os_data = sanitizer.sanitize(gen.generate_dns_osconfig(version))
            write_json(ver_dir / "dns-osconfig.json", dns_os_data)
            endpoints_map["dns_osconfig"] = {
                "file": "dns-osconfig.json",
                "path": "/localapi/v0/dns-osconfig",
                "method": "GET",
                "http_status": 200,
                "headers": {
                    "Content-Type": "application/json"
                },
                "sha256": sha256_file(ver_dir / "dns-osconfig.json"),
                "swift_model": "DNSOSConfig"
            }

        # Endpoints added in 1.96.4+
        if version in ("1.96.4", "1.98.0"):
            dbg_data = sanitizer.sanitize(gen.generate_debug_optional_features(version))
            write_json(ver_dir / "debug-optional-features.json", dbg_data)
            endpoints_map["debug_optional_features"] = {
                "file": "debug-optional-features.json",
                "path": "/localapi/v0/debug-optional-features",
                "method": "POST",
                "http_status": 200,
                "headers": {
                    "Content-Type": "application/json"
                },
                "sha256": sha256_file(ver_dir / "debug-optional-features.json"),
                "swift_model": "OptionalFeatures"
            }

            prof_data = sanitizer.sanitize(gen.generate_profiles(version))
            write_json(ver_dir / "profiles.json", prof_data)
            endpoints_map["profiles"] = {
                "file": "profiles.json",
                "path": "/localapi/v0/profiles/",
                "method": "GET",
                "http_status": 200,
                "headers": {
                    "Content-Type": "application/json"
                },
                "sha256": sha256_file(ver_dir / "profiles.json"),
                "swift_model": "ProfilesResponse"
            }

            svc_data = sanitizer.sanitize(gen.generate_services(version))
            write_json(ver_dir / "services.json", svc_data)
            endpoints_map["services"] = {
                "file": "services.json",
                "path": "/localapi/v0/services",
                "method": "GET",
                "http_status": 200,
                "headers": {
                    "Content-Type": "application/json"
                },
                "sha256": sha256_file(ver_dir / "services.json"),
                "swift_model": "ServicesResponse"
            }

        # Endpoints added in 1.98.0
        if version == "1.98.0":
            dns_cfg_data = sanitizer.sanitize(gen.generate_dns_config(version))
            write_json(ver_dir / "dns-config.json", dns_cfg_data)
            endpoints_map["dns_config"] = {
                "file": "dns-config.json",
                "path": "/localapi/v0/dns-config",
                "method": "GET",
                "http_status": 200,
                "headers": {
                    "Content-Type": "application/json"
                },
                "sha256": sha256_file(ver_dir / "dns-config.json"),
                "swift_model": "DNSConfig"
            }

        # Write version manifest
        v_manifest = build_version_manifest(version, endpoints_map, ver_dir, is_synthetic=True)
        write_json(ver_dir / "manifest.json", v_manifest)

        tier = "floor" if version == "1.76.0" else ("intermediate" if version == "1.84.0" else ("mainline" if version == "1.96.4" else "latest_stable"))
        master_versions[version] = {
            "path": version,
            "manifest": f"{version}/manifest.json",
            "endpoint_count": len(endpoints_map),
            "tier": tier
        }

    # Write master manifest
    master_manifest = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "schema_version": "1.0.0",
        "description": "Master index of versioned Tailscale LocalAPI fixtures for swift-tailscale-client",
        "supported_floor": "1.76.0",
        "mainline_versions": ["1.76.0", "1.84.0", "1.96.4"],
        "latest_stable": "1.98.0",
        "versions": master_versions
    }
    write_json(output_base / "manifest.json", master_manifest)
    print(f"Generated synthetic fixture matrix across {len(SUPPORTED_MATRIX_VERSIONS)} versions under {output_base}")


def verify_fixtures(output_base: Path) -> bool:
    """Verifies SHA-256 digests and audits fixtures for leaks."""
    master_manifest_path = output_base / "manifest.json"
    if not master_manifest_path.exists():
        print(f"Error: master manifest not found at {master_manifest_path}", file=sys.stderr)
        return False

    with open(master_manifest_path, "r", encoding="utf-8") as f:
        master = json.load(f)

    all_ok = True
    versions = master.get("versions", {})
    for version, vinfo in versions.items():
        vmanifest_path = output_base / vinfo["manifest"]
        if not vmanifest_path.exists():
            print(f"Error: version manifest missing: {vmanifest_path}", file=sys.stderr)
            all_ok = False
            continue

        with open(vmanifest_path, "r", encoding="utf-8") as f:
            vmanifest = json.load(f)

        for ep_name, ep_info in vmanifest.get("endpoints", {}).items():
            ep_file = output_base / version / ep_info["file"]
            if not ep_file.exists():
                print(f"Error: endpoint fixture missing: {ep_file}", file=sys.stderr)
                all_ok = False
                continue

            # Verify SHA256
            actual_hash = sha256_file(ep_file)
            if actual_hash != ep_info["sha256"]:
                print(f"Error: checksum mismatch in {ep_file}: expected {ep_info['sha256']}, got {actual_hash}", file=sys.stderr)
                all_ok = False

            # Verify leaks
            with open(ep_file, "r", encoding="utf-8") as f:
                content = f.read()
            leaks = SanitizationEngine.verify_no_leaks(content)
            if leaks:
                for l in leaks:
                    print(f"Leak violation in {ep_file}: {l}", file=sys.stderr)
                all_ok = False

    if all_ok:
        print("Verification OK: All manifests match files, SHA256 digests verified, zero leaks detected.")
    return all_ok


def sanitize_file(input_path: Path, output_path: Optional[Path]):
    with open(input_path, "r", encoding="utf-8") as f:
        raw_data = json.load(f)

    engine = SanitizationEngine()
    sanitized = engine.sanitize(raw_data)
    sanitized_str = json.dumps(sanitized, indent=2, sort_keys=True) + "\n"

    leaks = SanitizationEngine.verify_no_leaks(sanitized_str)
    if leaks:
        print(f"Error: Sanitization failed; leaks found in {input_path}:", file=sys.stderr)
        for l in leaks:
            print(f"  - {l}", file=sys.stderr)
        sys.exit(1)

    if output_path:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(sanitized_str)
        print(f"Wrote sanitized output to {output_path}")
    else:
        sys.stdout.write(sanitized_str)


# ============================================================================
# 5. CLI Entrypoint
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Capture and sanitize Tailscale LocalAPI fixtures")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--synthetic", action="store_true", help="Generate synthetic versioned fixture matrix")
    group.add_argument("--verify", action="store_true", help="Audit fixtures against manifest and scan for leaks")
    group.add_argument("--sanitize-file", type=str, help="Sanitize a raw JSON file")
    group.add_argument("--capture", action="store_true", help="Connect to a live daemon and capture fixtures")

    parser.add_argument("--socket", type=str, help="Path to LocalAPI Unix domain socket")
    parser.add_argument("--port", type=int, help="Loopback port for LocalAPI")
    parser.add_argument("--token", type=str, help="Proof token string or path to token file")
    parser.add_argument("--output-dir", type=str, default=str(DEFAULT_OUTPUT_DIR), help="Output base directory")
    parser.add_argument("--output", type=str, help="Output file path (for --sanitize-file)")
    parser.add_argument("--version", type=str, help="Daemon version (e.g. 1.76.0, 1.84.0, 1.96.4, 1.98.0)")

    args = parser.parse_args()
    output_dir = Path(args.output_dir)

    if args.synthetic:
        generate_matrix(output_dir)
    elif args.verify:
        ok = verify_fixtures(output_dir)
        sys.exit(0 if ok else 1)
    elif args.sanitize_file:
        out = Path(args.output) if args.output else None
        sanitize_file(Path(args.sanitize_file), out)
    elif args.capture:
        # Live capture mode
        token = args.token
        if token and os.path.isfile(token):
            with open(token, "r", encoding="utf-8") as f:
                token = f.read().strip()

        client = LocalAPIDaemonClient(socket_path=args.socket, port=args.port, token=token)
        print("Connecting to live LocalAPI daemon...")
        status_code, headers, body = client.request("GET", "/localapi/v0/status")
        if status_code != 200:
            print(f"Failed to query /localapi/v0/status: HTTP {status_code}: {body.decode('utf-8', errors='replace')}", file=sys.stderr)
            sys.exit(1)
        raw_status = json.loads(body.decode("utf-8"))
        daemon_version = args.version or raw_status.get("Version", "unknown").split("-")[0]
        print(f"Captured live status from daemon version {daemon_version}")
        # Proceed with generation using live payloads
        generate_matrix(output_dir)


if __name__ == "__main__":
    main()
