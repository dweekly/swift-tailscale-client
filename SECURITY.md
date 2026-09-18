# Security Policy

`swift-tailscale-client` is an unofficial personal project by David E. Weekly and is not affiliated with Tailscale Inc. Security-sensitive reports are treated with high priority to protect users and systems integrating the library.

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

Please email security reports directly to [david@weekly.org](mailto:david@weekly.org).

To ensure efficient handling, please include:
- A clear description of the vulnerability and affected versions or platforms.
- Complete, minimal steps to reproduce (including proof-of-concept Swift code or HTTP payloads).
- Potential impact on client applications or local system security (e.g. credential leakage, privilege escalation, memory corruption).
- Any proposed mitigations or patch suggestions.

You will receive an initial confirmation within 48 hours. Once a fix is verified, we coordinate public disclosure and release notes with the finder unless an extended embargo is mutually agreed upon.

> Important: Because this is an unofficial project, do **not** contact Tailscale Inc. regarding vulnerabilities in this codebase.

