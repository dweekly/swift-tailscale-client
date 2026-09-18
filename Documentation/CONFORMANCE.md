# LocalAPI Conformance & Differential Verification Specification

This document defines the conformance verification architecture for `swift-tailscale-client` 1.0 against the official Go implementation of the Tailscale LocalAPI.

## 1. Upstream Baseline & Provenance

The conformance harness and reference oracle are pinned to the upstream `tailscale/tailscale` repository:

| Metric | Value |
|---|---|
| **Upstream Repository** | `tailscale/tailscale` |
| **Pinned Commit SHA** | `4c4d1c35f83a21c6069ae09de69b246ed1993f3e` |
| **Protocol Capability Level** | `144` (`tailcfg.CurrentCapabilityVersion`) |
| **Supported Daemon Matrix Floor** | `1.76.0` (Capability 106) |
| **Mainline Supported Range** | `1.76.x` – `1.96.x` (tracking `1.76.0`, `1.84.0`, `1.96.4`) |
| **Latest Stable Version** | `1.98.0` (Capability 144) |

---

## 2. Three-Tier Testing Architecture

Testing is partitioned into three distinct tiers to balance complete isolation, CI reproducibility, and safe integration:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Tier 1: Hermetic Offline Playback (CI Default)                              │
│ - Zero live daemons, zero network access, 100% reproducible                 │
│ - Feeds versioned sanitized fixtures (1.76.x - 1.98.x) via MockTransport    │
│ - Compares decoded Swift models against Go Canonical Reference Oracles      │
│ - Exercises all HTTP error codes, stream framing, and injected mutations    │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
┌──────────────────────────────────────▼──────────────────────────────────────┐
│ Tier 2: Hermetic Headscale Local Matrix (Gated: TAILSCALE_INTEGRATION=1)     │
│ - Runs against containerized or local Headscale control plane + tailscaled  │
│ - Gated: TAILSCALE_INTEGRATION_WRITE=1 for mutations (prefs, serve config)  │
│ - Safe for state mutation; no external network or production dependencies    │
│ - Fast, automated, reproducible in Linux CI lanes                           │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
┌──────────────────────────────────────▼──────────────────────────────────────┐
│ Tier 3: Disposable Production Tailnet (Strictly Gated, Quota-Controlled)     │
│ - Dedicated strictly to control-plane features Headscale cannot establish:  │
│   1. ACME Let's Encrypt certificates (certPEM, certPair, certDomains)        │
│   2. Tailscale OIDC ID tokens (idToken(audience:))                          │
│   3. Control-plane feature probes (queryFeature("serve"), etc.)              │
│   4. Real multi-node identity resolution and capability maps                 │
│ - Safeguards: Ephemeral auth keys (auto-delete on disconnect),              │
│   1-hour max tailnet lifespan, resource quotas, non-fork secret isolation.   │
│ - ZERO write tests run on personal or permanent developer tailnets.         │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. The Six Conformance Surfaces

### Surface 1: Status (`/localapi/v0/status`)
- **Query Variants**: Full status with peers (`?peers=true`) and sparse status without peers (`?peers=false`).
- **Node Status**: All 28+ fields in `NodeStatus` matching Go `ipnstate.PeerStatus` (`ID`, `PublicKey`, `HostName`, `DNSName`, `OS`, `UserID`, `TailscaleIPs`, `AllowedIPs`, `Addrs`, `CurAddr`, `Relay`, `RxBytes`, `TxBytes`, `Created`, `LastWrite`, `LastSeen`, `LastHandshake`, `Online`, `ExitNode`, `ExitNodeOption`, `Active`, `PeerAPIURL`, `CapMap`, `InNetworkMap`, `InMagicSock`, `InEngine`, `KeyExpiry`).
- **CapMap**: Structured capability array decoding (`CapabilityValue`).
- **BackendState**: Tolerant decoding mapping known strings (`Running`, `Stopped`, `NeedsLogin`, `Starting`) and unknown strings to `.other`.

### Surface 2: Peers (`/localapi/v0/whois` & `/localapi/v0/peer/`)
- **Query Routing**: Lookups by IP address (`whois(address:)`), node key (`whois(nodeKey:)`), destination IP scope, and service tag.
- **Node & User Profile**: Complete node metadata, hostinfo, tags, and user identity resolution.
- **404 Disambiguation**: Peer queries answering HTTP 404 map to typed `TailscaleClientError.peerNotFound(endpoint:)` rather than generic unexpected status.

### Surface 3: Routes (Subnet Routing, Exit Nodes & Split-DNS)
- **Prefix Notation**: Exact CIDR parsing and round-tripping for IPv4 (`100.64.0.0/10`, `192.168.1.0/24`, `0.0.0.0/0`) and IPv6 (`fd7a:115c:.../128`, `::/0`).
- **Preferences**: `AdvertiseRoutes` and `RouteAll` in `Prefs`.
- **Split-DNS**: Route table in `DNSConfig.routes` mapping domain suffixes to `[DNSResolver]`.
- **Forwarding Preflights**: `checkIPForwarding()` and `checkUDPGROForwarding()` diagnostic assertions (`IPForwardingCheck`).

### Surface 4: Preferences & Masked Writes (`/localapi/v0/prefs`)
- **Masked Property Pairs**: Each mutated preference travels with an explicit `<Property>Set: true` flag.
- **Partial Mutation Safety**: Setting a single preference (e.g. `corpDNS: true`) does not clear, overwrite, or mutate unmentioned settings.

### Surface 5: Serve Config Concurrency & Lossless Fields (`/localapi/v0/serve-config`)
- **Concurrency Token**: ETag header encapsulation in `ServeConfigSnapshot`.
- **Conditional Writes**: `setServeConfig(_:matching:)` transmits `If-Match: <etag>`.
- **Precondition Conflict**: HTTP 412 Precondition Failed throws `TailscaleClientError.preconditionFailed(body:endpoint:)`.
- **Missing Token Defense**: Writes attempted without a valid ETag throw `TailscaleClientError.missingConcurrencyToken`.
- **Unconditional Replacement**: `replaceServeConfigUnconditionally(_:)` explicitly bypasses `If-Match`.
- **Recursive Unmodeled Fields**: Losslessly preserves unknown JSON fields throughout `ServeConfig` (root, TCP, Web, Handlers, Services) without 64-bit integer precision loss.

### Surface 6: IPN Bus Streaming (`/localapi/v0/watch-ipn-bus`)
- **Head Observation**: Response status code (200) and `Tailscale-Version` header validated before body lines are yielded.
- **Framing**: NDJSON stream parsed line-by-line into `IPNNotify`.
- **Event Classification**: Differentiates between notification events and connection lifecycle events (`IPNBusEvent`).
- **Queue Bounds**: Bounded memory and event capacity; overflow emits `.stateGap(reason: "buffer_overflow")` or throws `streamOverflow`.
- **Classified Reconnect**: Permanent authorization failures (401, 403) terminate immediately; transient network interruptions retry with capped exponential backoff and jitter.

---

## 4. Canonical Normalization Rules

To ensure exact byte-for-byte differential comparison between Go and Swift decoders:
1. **Sorted Map Keys**: All JSON dictionaries are serialized with alphabetically sorted keys (`JSONEncoder.OutputFormatting.sortedKeys`).
2. **Timestamps**: Normalized to UTC RFC 3339 strings (`YYYY-MM-DDTHH:MM:SSZ`) without fractional seconds. Zero-time `"0001-01-01T00:00:00Z"` is preserved.
3. **Empty vs Nil Slices**: Null and empty arrays are normalized to `[]` for all array fields.
4. **Volatile Counters**: `RxBytes` and `TxBytes` are zeroed during live differential comparison to prevent spurious diffs caused by background traffic.
5. **Deterministic Pseudonymization**: All cryptographic keys, auth tokens, IPs, and user emails are pseudonymized consistently across related objects.

---

## 5. Complete Wire Error Mapping Matrix

| HTTP Status | LocalAPI Wire Condition | Typed Swift Error | Modifiers / Endpoints |
|---|---|---|---|
| **400** | Malformed JSON or invalid query parameter | `.unexpectedStatus(code: 400, body: body, endpoint: endpoint)` | All endpoints |
| **401** | Missing or invalid loopback authentication token | `.unexpectedStatus(code: 401, body: body, endpoint: endpoint)` | Automatically re-probed on auto endpoints |
| **403** | Unauthorized access, missing operator privileges | `.permissionDenied(body: body, endpoint: endpoint)` | Unprivileged token |
| **404 (Peer)** | Node key or peer IP not found in netmap | `.peerNotFound(endpoint: endpoint)` | `whois`, `peer(byID:)` |
| **404 (Feature)**| Optional endpoint omitted from modular build | `.endpointUnavailable(endpoint: endpoint, feature: feature)` | Optional endpoints |
| **404 (Standard)**| Standard endpoint path not found | `.unexpectedStatus(code: 404, body: body, endpoint: endpoint)` | Standard endpoints |
| **412** | Stale ETag on conditional configuration write | `.preconditionFailed(body: body, endpoint: endpoint)` | `setServeConfig(_:matching:)` |
| **429** | Daemon rate limiting (e.g. ACME certificates) | `.rateLimited(retryAfterSeconds: Double?, body: body, endpoint: endpoint)` | `cert/`, `setDNS` (RFC 9110 Retry-After) |
| **500** | Internal daemon failure or unsupported OS stack | `.unexpectedStatus(code: 500, body: body, endpoint: endpoint)` | Diagnostic endpoints |
| **501** | Feature registered but disabled at runtime | `.endpointUnavailable(endpoint: endpoint, feature: feature)` | Optional endpoints |
| **503** | Daemon starting or netmap not yet synchronized | `.unexpectedStatus(code: 503, body: body, endpoint: endpoint)` | `services` |

---

## 6. Negative / Fault Injection Testing

To guarantee that differential conformance tests are sensitive to real regressions, the test suite injects deliberate defects:
1. **Corrupt ETag**: Modifying the concurrency token causes conditional write mismatch detection.
2. **Dropped IP Address**: Omitting an AllowedIP from NodeStatus causes differential comparator failure.
3. **Mutated Unmodeled Field**: Mutating an unknown JSON configuration value causes round-trip inequality detection.
4. **Toggled Boolean**: Inverting preference flags causes differential mismatch detection.
5. **64-bit Integer Corruption**: Altering a 64-bit integer magnitude detects precision truncation.

Each test verifies that the differential verification engine detects the defect and reports a descriptive failure.
