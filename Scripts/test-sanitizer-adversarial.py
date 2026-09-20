#!/usr/bin/env python3
"""
Scripts/test-sanitizer-adversarial.py - Empirical Adversarial Stress Test Suite for capture-fixtures.py
"""

import copy
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

# Import SanitizationEngine and verify_fixtures from capture-fixtures.py
sys.path.insert(0, str(Path(__file__).parent))
import importlib
capture_fixtures = importlib.import_module("capture-fixtures")
SanitizationEngine = capture_fixtures.SanitizationEngine
verify_fixtures = capture_fixtures.verify_fixtures

def log_test(name, passed, details=""):
    status = "PASS" if passed else "FAIL"
    print(f"[{status}] {name}")
    if details:
        print(f"       {details}")
    if not passed:
        return False
    return True

def run_all_stress_tests():
    all_passed = True

    print("=== Test Suite 1: Token & Secret Sanitization & Leak Detection ===")
    
    # 1.1 Deeply nested keys and JSON arrays
    engine = SanitizationEngine()
    deep_payload = {"level0": "val0"}
    curr = deep_payload
    for i in range(1, 30):
        curr["nested"] = [{"level": i, "token": f"tskey-auth-secretkey{i}1234567890"}]
        curr = curr["nested"][0]
    curr["final_proof"] = "sameuserproof-999-abcdef0123456789abcdef"
    curr["privkey"] = "privkey:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    curr["nodekey"] = "nodekey:1111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff"

    sanitized = engine.sanitize(deep_payload)
    sanitized_str = json.dumps(sanitized)
    leaks = SanitizationEngine.verify_no_leaks(sanitized_str)
    
    test1_pass = (len(leaks) == 0) and ("secretkey" not in sanitized_str) and ("privkey:00000000" in sanitized_str)
    all_passed &= log_test("1.1 Deeply nested tokens (30 levels deep)", test1_pass, f"Leaks found: {leaks}")

    # 1.2 Tokens in dictionary keys
    key_payload = {
        "tskey-auth-secretkeyinkey1234567890": "normal_val",
        "nested": {
            "nodekey:aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899": 123
        }
    }
    sanitized_keys = engine.sanitize(key_payload)
    sanitized_keys_str = json.dumps(sanitized_keys)
    leaks_keys = SanitizationEngine.verify_no_leaks(sanitized_keys_str)
    test1_2_pass = (len(leaks_keys) == 0) and ("secretkeyinkey" not in sanitized_keys_str)
    all_passed &= log_test("1.2 Tokens embedded in dictionary keys", test1_2_pass, f"Leaks: {leaks_keys}")

    # 1.3 Tokens embedded in query parameters & URLs
    url_payload = {
        "webhook_url": "https://api.internal.corp/callback?auth=tskey-auth-secreturltoken1234567890&state=ok",
        "api_endpoint": "http://127.0.0.1:41112/debug?api_key=tskey-api-supersecretkey1234567890"
    }
    sanitized_urls = engine.sanitize(url_payload)
    sanitized_urls_str = json.dumps(sanitized_urls)
    leaks_urls = SanitizationEngine.verify_no_leaks(sanitized_urls_str)
    test1_3_pass = (len(leaks_urls) == 0) and ("secreturltoken" not in sanitized_urls_str) and ("supersecretkey" not in sanitized_urls_str)
    all_passed &= log_test("1.3 Tokens in query parameters & URLs", test1_3_pass, f"Leaks: {leaks_urls}")

    # 1.4 Raw PEM private key detection in verify_no_leaks
    pem_payload = "-----BEGIN EC PRIVATE KEY-----\nMHQCAQEEIB...\n-----END EC PRIVATE KEY-----"
    leaks_pem = SanitizationEngine.verify_no_leaks(pem_payload)
    test1_4_pass = any("Raw PEM private key" in l for l in leaks_pem)
    all_passed &= log_test("1.4 Raw PEM key detection", test1_4_pass, f"Expected PEM leak detected: {leaks_pem}")

    # 1.5 Real email domains leak detection
    email_payload = {
        "allowed": ["user@example.com", "bot@test.org", "support@tailscale.com", "device@example.ts.net"],
        "leaked": ["ceo@megacorp.com", "admin@gmail.com", "dev@randomcompany.io"]
    }
    sanitized_emails = engine.sanitize(email_payload)
    sanitized_emails_str = json.dumps(sanitized_emails)
    leaks_emails = SanitizationEngine.verify_no_leaks(sanitized_emails_str)
    # SanitizationEngine converts all emails via regex to userN@example.com
    test1_5_pass = (len(leaks_emails) == 0) and ("megacorp.com" not in sanitized_emails_str) and ("gmail.com" not in sanitized_emails_str)
    all_passed &= log_test("1.5 Email domain sanitization and leak verification", test1_5_pass, f"Leaks: {leaks_emails}")

    print("\n=== Test Suite 2: IP Address & Network Notation Variations ===")
    
    # 2.1 CGNAT mapping and preservation
    ip_payload = {
        "magic_dns": "100.100.100.100",
        "cgnat_ips": ["100.64.0.1", "100.120.45.67", "100.64.0.1:41641", "100.64.0.1/32"],
        "rfc1918": ["192.168.1.50", "10.0.0.1", "172.16.0.1", "172.31.255.255"],
        "public_ips": ["93.184.216.34", "198.51.100.25", "142.250.190.46:443", "172.56.21.99", "192.30.252.1"],
        "dns_well_known": ["1.1.1.1", "8.8.8.8", "9.9.9.9", "1.0.0.1", "8.8.4.4"]
    }
    sanitized_ips = engine.sanitize(ip_payload)
    
    # Check MagicDNS preserved
    p1 = (sanitized_ips["magic_dns"] == "100.100.100.100")
    # Check DNS well known preserved
    p2 = all(ip in sanitized_ips["dns_well_known"] for ip in ["1.1.1.1", "8.8.8.8", "9.9.9.9"])
    # Check public IPs mapped to TEST-NET-2 (198.51.100.x)
    p3 = (
        "93.184.216.34" not in json.dumps(sanitized_ips)
        and "142.250.190.46" not in json.dumps(sanitized_ips)
        and "172.56.21.99" not in json.dumps(sanitized_ips)
        and "192.30.252.1" not in json.dumps(sanitized_ips)
    )
    p4 = all("198.51.100." in s for s in sanitized_ips["public_ips"])
    # Check CGNAT mapped into 100.64.0.x
    p5 = all("100.64.0." in s for s in sanitized_ips["cgnat_ips"])
    test2_1_pass = p1 and p2 and p3 and p4 and p5
    all_passed &= log_test("2.1 IPv4 CGNAT, RFC 1918, and Public IP Sanitization", test2_1_pass, f"p1={p1}, p2={p2}, p3={p3}, p4={p4}, p5={p5}")

    # 2.2 IPv6 ULA Mapping
    ipv6_payload = {
        "tailscale_ula": ["fd7a:115c:a1e0:ab12:4843:cd96:6200:0001", "fd7a:115c:a1e0:ab12:4843:cd96:6200:0001/128"],
        "another_ula": "fd7a:115c:a1e0:ffff:ffff:ffff:ffff:ffff"
    }
    sanitized_ipv6 = engine.sanitize(ipv6_payload)
    test2_2_pass = all("fd7a:115c:a1e0:ab12:4843:cd96:6200:" in s for s in sanitized_ipv6["tailscale_ula"])
    all_passed &= log_test("2.2 IPv6 Tailscale ULA Sanitization", test2_2_pass)

    print("\n=== Test Suite 3: Boundary Integer Fidelity ===")
    
    # Boundary integers: 0, 32-bit bounds, 53-bit JS bounds, 64-bit Int64 and UInt64 bounds
    boundary_ints = {
        "zero": 0,
        "neg_one": -1,
        "pos_one": 1,
        "int32_max": 2147483647,
        "int32_max_plus_one": 2147483648,
        "int32_min": -2147483648,
        "int53_max": 9007199254740991,       # Number.MAX_SAFE_INTEGER
        "int53_max_plus_one": 9007199254740992,
        "int64_max": 9223372036854775807,      # Int64.max
        "uint64_max": 18446744073709551615,    # UInt64.max
        "uint64_overflow": 18446744073709551616, # Exceeds 64-bit unsigned integer
        "very_large_bigint": 10**40
    }
    sanitized_ints = engine.sanitize(boundary_ints)
    
    # Check that Python preserves exact values without truncation
    int_preserved = (
        sanitized_ints["int32_max"] == 2147483647 and
        sanitized_ints["int53_max"] == 9007199254740991 and
        sanitized_ints["int64_max"] == 9223372036854775807 and
        sanitized_ints["uint64_max"] == 18446744073709551615 and
        sanitized_ints["uint64_overflow"] == 18446744073709551616 and
        sanitized_ints["very_large_bigint"] == 10**40
    )
    all_passed &= log_test("3.1 Arbitrary precision integer preservation in sanitizer", int_preserved)

    print("\n=== Test Suite 4: Fixture Integrity & Secret Injection Tamper Detection ===")
    
    # Test --verify behavior with temporary modified fixtures
    fixtures_dir = Path("Tests/TailscaleClientTests/Fixtures/LocalAPI")
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp_fixtures = Path(tmpdir) / "LocalAPI"
        shutil.copytree(fixtures_dir, tmp_fixtures)
        
        # 4.1 Verify unmodified copy passes
        pass_unmodified = verify_fixtures(tmp_fixtures)
        all_passed &= log_test("4.1 Verify fixtures on clean copy passes", pass_unmodified)

        # 4.2 Tamper with content (checksum mismatch)
        target_file = tmp_fixtures / "1.76.0" / "status.json"
        with open(target_file, "r", encoding="utf-8") as f:
            status_data = json.load(f)
        status_data["TamperedField"] = "AdversarialData"
        with open(target_file, "w", encoding="utf-8") as f:
            json.dump(status_data, f)
        
        tamper_detected = not verify_fixtures(tmp_fixtures)
        all_passed &= log_test("4.2 Checksum mismatch detected upon file tampering", tamper_detected)

        # Revert file
        shutil.copyfile(fixtures_dir / "1.76.0" / "status.json", target_file)

        # 4.3 Inject unredacted auth token (leak detection)
        with open(target_file, "r", encoding="utf-8") as f:
            status_data = json.load(f)
        status_data["InjectedSecret"] = "tskey-auth-liveleakedtoken1234567890abcdef"
        with open(target_file, "w", encoding="utf-8") as f:
            json.dump(status_data, f)
        # Also update hash in manifest to test that leak detection triggers even if hash is updated
        vmanifest_path = tmp_fixtures / "1.76.0" / "manifest.json"
        with open(vmanifest_path, "r", encoding="utf-8") as f:
            vmanifest = json.load(f)
        vmanifest["endpoints"]["status"]["sha256"] = capture_fixtures.sha256_file(target_file)
        with open(vmanifest_path, "w", encoding="utf-8") as f:
            json.dump(vmanifest, f)

        leak_detected = not verify_fixtures(tmp_fixtures)
        all_passed &= log_test("4.3 Secret leak detected despite updated sha256 digest", leak_detected)

        # 4.4 Inject unredacted private key
        with open(target_file, "r", encoding="utf-8") as f:
            status_data = json.load(f)
        status_data["InjectedSecret"] = "privkey:11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff"
        with open(target_file, "w", encoding="utf-8") as f:
            json.dump(status_data, f)
        vmanifest["endpoints"]["status"]["sha256"] = capture_fixtures.sha256_file(target_file)
        with open(vmanifest_path, "w", encoding="utf-8") as f:
            json.dump(vmanifest, f)

        privkey_leak_detected = not verify_fixtures(tmp_fixtures)
        all_passed &= log_test("4.4 Raw private key leak detected", privkey_leak_detected)

        # 4.5 Missing endpoint fixture file
        os.remove(target_file)
        missing_file_detected = not verify_fixtures(tmp_fixtures)
        all_passed &= log_test("4.5 Missing fixture file detected", missing_file_detected)

    return all_passed

if __name__ == "__main__":
    success = run_all_stress_tests()
    sys.exit(0 if success else 1)
