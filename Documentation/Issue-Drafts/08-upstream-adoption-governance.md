Prepare the upstream adoption proposal, contribution posture, and governance

Goal

Prepare a credible proposal for Tailscale to adopt, incorporate, or share ownership of the Swift LocalAPI implementation.

This issue prepares the conversation. It does not claim affiliation and does not authorize opening an upstream issue or making a Community Projects submission without maintainer approval.

Tailscale contribution guidance:

https://github.com/tailscale/tailscale/blob/main/.github/CONTRIBUTING.md

Tailscale Community Projects criteria:

https://tailscale.com/docs/reference/tailscale-community-projects

Tailscale release stages and support implications:

https://tailscale.com/docs/reference/tailscale-release-stages

Questions for Tailscale

The proposal should ask directly:

1. Is installed-daemon LocalAPI intended to become a supported third-party Swift surface?
2. Would shared code belong in libtailscale/swift, a new official repository, or remain a community project?
3. Can one transport-neutral implementation serve both TailscaleKit embedded nodes and installed-daemon clients?
4. Which macOS discovery and authentication mechanism is Tailscale willing to support?
5. Which LocalAPI methods would Tailscale consider part of the supported Swift surface?
6. Which Apple/Linux platforms and installation variants are intended?
7. What release stage would be appropriate initially?
8. What naming, licensing, ownership, and support model would make code donation straightforward?
9. Does Tailscale want a narrow LocalAPI library, or any of the CLI and diagnostic functionality?
10. Who inside Tailscale would own review, releases, security response, and long-term maintenance?

Upstream design proposal

Prepare a concise repository document that includes:

* The user problem: native Swift software needs structured access to an existing local Tailscale installation without shelling out to the CLI.
* The distinction between installed-daemon LocalAPI and an embedded TailscaleKit node.
* Evidence of current functionality and compatibility testing.
* The upstream-maturity and stable-parity ledger.
* The proposed transport-neutral architecture.
* macOS authentication and sandbox questions.
* Wire-model provenance and drift strategy.
* Security posture.
* Platform matrix.
* Migration path for existing package users.
* Explicit policy questions requiring Tailscale's decision.
* A staged contribution plan made of small, independently reviewable changes.

Contribution posture

Tailscale asks contributors to discuss substantial functionality before investing heavily and requires Developer Certificate of Origin sign-offs.

Repository work:

* Adopt DCO Signed-off-by commits prospectively.
* Update CONTRIBUTING.md with the chosen DCO policy.
* Keep commits logically separate and independently tested.
* Prepare contribution slices rather than proposing a wholesale repository drop.
* Preserve the unofficial-project disclaimer until status actually changes.

Licensing

The current project is MIT licensed, while Tailscale and libtailscale use BSD-3-Clause.

MIT is not inherently incompatible, but importing or relicensing code requires a clean copyright record.

Tasks:

* Inventory contributors and copyright ownership.
* Determine whether MIT should remain, BSD-3-Clause should be offered for contributed portions, or a dual-license is appropriate.
* Obtain explicit contributor consent before any relicensing.
* Document the result so Tailscale does not have to reconstruct it during legal review.

Security and maintenance governance

Add or strengthen:

* SECURITY.md
* Supported-version policy
* Vulnerability-reporting channel
* Expected response and disclosure process
* Release ownership
* Maintainer succession
* Dependency-update policy
* Secret-handling rules
* Compatibility and deprecation policy

Official status creates support obligations. Tests reduce that burden, but they do not answer who gets paged when a macOS update breaks discovery.

Adoption evidence

Gather:

* Concrete downstream applications.
* Production use cases.
* Compatibility history across daemon releases.
* Testimonials or maintainers willing to act as design partners.
* At least one maintainer beyond the original author, if possible.
* Examples showing why parsing CLI output or embedding a second node is inadequate.

Community Projects intermediate milestone

Prepare a Tailscale Community Projects submission after the relevant quality and governance work lands.

Treat this as useful recognition and evidence of maintenance—not as official endorsement or support. Tailscale's documentation explicitly distinguishes community projects from supported products.

Acceptance criteria

* A concise upstream proposal exists and links to the architecture ADR.
* The proposal distinguishes verified facts from product and support decisions requested from Tailscale.
* CONTRIBUTING documents the chosen DCO posture.
* Licensing and contributor-consent status are documented.
* Security response and maintenance ownership are credible beyond one release.
* Concrete downstream users or design partners are identified.
* A staged contribution sequence is proposed.
* A Community Projects submission draft exists.
* Maintainer approval is obtained before any upstream issue or submission is opened.
* The repository continues to describe itself as unofficial unless and until Tailscale changes that status.
