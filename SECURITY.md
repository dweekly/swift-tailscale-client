# Security Policy

`swift-tailscale-client` is an unofficial personal project by David E. Weekly and is not affiliated with Tailscale Inc. Security-sensitive reports are treated with high priority to protect users and systems integrating the library.

## Release & Security Ownership

- **Primary Release Owner**: David E. Weekly ([david@weekly.org](mailto:david@weekly.org), GitHub: `@dweekly`). Responsible for architectural direction, release tagging, package publishing, and security incident response.
- **Designated Backup Maintainer**: In the event that the primary maintainer is unreachable for more than 48 hours during an active Critical security incident, or more than 7 business days during normal maintenance, security triage and emergency release management escalate to the designated backup maintainer ([security-backup@weekly.org](mailto:security-backup@weekly.org) / repository co-admin).

### Tag Immutability & Emergency Patch Protocol
- **Published Git Tags are Strictly Immutable**: Once a release tag (e.g., `v1.0.0`) is published and pushed, it is **never moved or deleted**. Moving a tag breaks Swift Package Manager fingerprint verification (`Package.resolved` checksum mismatch) and damages package ecosystem integrity.
- **Emergency Tag Withdrawal & Remediation**: If a critical vulnerability or catastrophic regression is identified in a published release, the release is marked as **Yanked / Deprecated** on GitHub Releases. A fast-track emergency patch release (`v1.0.(x+1)`) is branched directly from the tag, verified through full release gates, and published immediately.

## Supported Versions and Release Branch Policy

Following the 1.0.0 release, security patches are maintained on active major/minor release branches:

| Version Line | Status | Security Patch Window | Policy |
| :--- | :--- | :--- | :--- |
| **1.0.x** | Supported | 12 months from 1.0.0 release | Critical and high severity security fixes backported as patch releases. |
| **< 1.0.0** | End of Life | None | All pre-1.0 versions are unsupported; users must upgrade to 1.0.0+. |

Patch releases on the `1.0.x` branch preserve strict binary and source compatibility.

## Severity Classification & SLAs

We categorize vulnerabilities according to standard CVSS criteria and commit to the following response targets:

- **Critical Severity (CVSS 9.0–10.0)**: Initial response within 48 hours; targeted fix and patch release within 14 calendar days; coordinated disclosure within 90 days.
- **High Severity (CVSS 7.0–8.9)**: Initial response within 3 business days; patch release within 30 calendar days.
- **Medium / Low Severity (CVSS < 7.0)**: Initial response within 5 business days; addressed in the next scheduled minor or patch release.

## Reporting a Vulnerability

Please report security vulnerabilities through either:
1. **GitHub Private Vulnerability Reporting (Preferred)**: Submit an advisory report via [GitHub Security Advisories](https://github.com/dweekly/swift-tailscale-client/security/advisories/new).
2. **Direct Email**: Send encrypted or plain reports to [david@weekly.org](mailto:david@weekly.org), copying [security-backup@weekly.org](mailto:security-backup@weekly.org).

### Coordinated Disclosure & CVE Assignment
- All vulnerability triage occurs within a temporary private GitHub Security Advisory (GHSA) fork.
- For confirmed vulnerabilities with CVSS score >= 4.0, the maintainers will request a **CVE identifier** via GitHub's CNA service prior to public disclosure.
- Coordinated disclosure follows a standard **90-day timeline** from initial report, or sooner upon mutual agreement once patched binaries and packages are published.
- Registered downstream production consumers (such as Network Weather / NWX) are provided an embargoed notification 48–72 hours prior to public disclosure.

To ensure efficient handling, please include:
- A clear description of the vulnerability and affected versions or platforms.
- Complete, minimal steps to reproduce (including proof-of-concept Swift code or HTTP payloads).
- Potential impact on client applications or local system security (e.g. credential leakage, privilege escalation, memory corruption).
- Any proposed mitigations or patch suggestions.

You will receive an initial confirmation within 48 hours. Once a fix is verified, we coordinate public disclosure and release notes with the finder unless an extended embargo is mutually agreed upon.

> Important: Because this is an unofficial project, do **not** contact Tailscale Inc. regarding vulnerabilities in this codebase.

