# Experimental APIs & Stability Tiers

Which parts of this package you can build on, and which parts can shift
under you.

## Why tiers exist

The LocalAPI is explicitly namespaced `/localapi/v0/` because upstream does
not promise stability: endpoints appear, change shape, and get gated behind
build features between releases. A Swift wrapper that pretended otherwise
would break its own SemVer promises. So every surface in this package
belongs to one of three tiers, documented per-endpoint in the repository's
`Documentation/LOCALAPI-COVERAGE.md`.

## Stable

Methods directly on ``TailscaleClient`` — `status()`, `whois(address:)`,
`derpMap()`, `netcheck()`, `dnsQuery(name:type:)`, and the rest. These wrap
endpoints that have been in tailscaled for years and power its own CLI.
Pre-1.0 they may still evolve with the package's minor versions; from 1.0
they follow SemVer strictly.

Stability here also means *tolerant decoding*: models default missing
fields, ignore unknown ones, and (as of v0.4.0) decode arbitrary capability
values losslessly — a daemon upgrade should never make `status()` start
throwing.

## Experimental

Everything under ``TailscaleClient/experimental`` (``ExperimentalClient``):
`bugreport()`, `goroutines()`, `logtap()`, and whatever debug surfaces land
later. Two rules:

1. **Exempt from SemVer, permanently.** These wrap upstream *debug*
   endpoints that Tailscale reserves the right to change in any release; the
   Swift signatures track upstream rather than protecting you from it.
2. **Available in your build, maybe not in the daemon's.** Expect
   ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` and treat
   it as "this diagnostic isn't available here", not as a bug.

Use them freely in developer tooling and diagnostics screens; keep them out
of production control flow.

## Unsupported

A small set of endpoints (`dial`, `debug-capture`, low-level state hijacks)
are deliberately not wrapped — each with its reason recorded in the coverage
matrix. If a real use case appears, they get promoted rather than silently
half-supported.

## How endpoints move between tiers

New endpoints usually debut as Experimental unless they are clearly part of
the daemon's supported CLI surface. Promotion to Stable happens in a minor
release after the endpoint has proven shape-stable across upstream releases;
the coverage matrix and CHANGELOG record every move. Nothing is ever moved
*out* of Stable post-1.0 without a major version.
