// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// A client-side network-condition probe modeled on Tailscale's `netcheck`:
/// it STUN-pings every region in a ``DERPMap`` over UDP to measure latency,
/// learn this machine's public address, and detect NAT behavior.
///
/// This runs entirely in-process (pure Swift, no daemon involvement beyond
/// fetching the map), so it also answers "is UDP usable at all on this
/// network?" — the question that decides whether Tailscale traffic can go
/// direct or must fall back to DERP relays.
///
/// ```swift
/// let client = TailscaleClient()
/// let report = try await client.netcheck()
/// if let region = report.preferredDERPRegionID {
///     print("nearest DERP region: \(region)")
/// }
/// ```
public struct Netcheck: Sendable {
  /// Tuning knobs for a netcheck run.
  public struct Options: Sendable {
    /// How long to wait for STUN responses after the requests go out.
    public var timeout: Duration

    /// Whether to also probe over IPv6. Costs nothing on IPv4-only
    /// networks (the sends fail locally and the regions stay silent).
    public var probeIPv6: Bool

    /// Creates options, defaulting to a 3-second window with IPv6 enabled.
    public init(timeout: Duration = .seconds(3), probeIPv6: Bool = true) {
      self.timeout = timeout
      self.probeIPv6 = probeIPv6
    }
  }

  public var options: Options

  /// Creates a netcheck runner.
  public init(options: Options = Options()) {
    self.options = options
  }

  /// Probes every eligible region in `derpMap` and summarizes the results.
  ///
  /// Regions flagged `NoMeasureNoHome` are not probed; regions flagged
  /// `Avoid` are measured but never become the preferred region. A map with
  /// no STUN-capable nodes yields an empty report (``NetcheckReport/udpWorking``
  /// `false`, no latencies) rather than an error.
  public func run(derpMap: DERPMap) async throws -> NetcheckReport {
    let candidates = NetcheckProbe.candidates(for: derpMap, includeIPv6: options.probeIPv6)
    let timeout = options.timeout
    let samples = await Task.detached(priority: .userInitiated) {
      NetcheckProbe.run(candidates: candidates, timeout: timeout)
    }.value
    try Task.checkCancellation()
    return NetcheckReport(samples: samples)
  }
}

/// The outcome of a ``Netcheck`` run.
///
/// Field semantics follow Tailscale's `netcheck.Report` where they overlap.
public struct NetcheckReport: Codable, Sendable, Equatable {
  /// Whether any STUN response arrived over UDP. `false` means UDP is
  /// blocked (or the map had nothing to probe) and traffic will relay.
  public var udpWorking: Bool

  /// Whether STUN worked over IPv4.
  public var ipv4Working: Bool

  /// Whether STUN worked over IPv6.
  public var ipv6Working: Bool

  /// This machine's public IPv4 endpoint ("ip:port") as seen by the
  /// fastest-responding region, when known.
  public var globalV4: String?

  /// This machine's public IPv6 endpoint ("[ip]:port"), when known.
  public var globalV6: String?

  /// Whether different destinations saw different public addresses — the
  /// signature of "hard" (endpoint-dependent) NAT, which defeats direct
  /// connections. `nil` when fewer than two regions reported an address.
  public var mappingVariesByDestination: Bool?

  /// The lowest-latency region eligible for homing, i.e. the region a
  /// daemon on this network would likely pick as home.
  public var preferredDERPRegionID: Int?

  /// Best measured round-trip time per region ID, in seconds (either
  /// address family).
  public var regionLatencySeconds: [Int: Double]

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    udpWorking: Bool = false,
    ipv4Working: Bool = false,
    ipv6Working: Bool = false,
    globalV4: String? = nil,
    globalV6: String? = nil,
    mappingVariesByDestination: Bool? = nil,
    preferredDERPRegionID: Int? = nil,
    regionLatencySeconds: [Int: Double] = [:]
  ) {
    self.udpWorking = udpWorking
    self.ipv4Working = ipv4Working
    self.ipv6Working = ipv6Working
    self.globalV4 = globalV4
    self.globalV6 = globalV6
    self.mappingVariesByDestination = mappingVariesByDestination
    self.preferredDERPRegionID = preferredDERPRegionID
    self.regionLatencySeconds = regionLatencySeconds
  }

  /// Summarizes raw probe samples into a report.
  init(samples: [NetcheckProbe.Sample]) {
    self.init()
    guard !samples.isEmpty else { return }
    udpWorking = true

    var bestV4: NetcheckProbe.Sample?
    var bestV6: NetcheckProbe.Sample?
    var v4Addresses = Set<STUN.MappedAddress>()
    var v4AddressReports = 0
    var bestPreferred: NetcheckProbe.Sample?

    for sample in samples {
      if let existing = regionLatencySeconds[sample.regionID] {
        regionLatencySeconds[sample.regionID] = min(existing, sample.rttSeconds)
      } else {
        regionLatencySeconds[sample.regionID] = sample.rttSeconds
      }

      if sample.ipv6 {
        ipv6Working = true
        if sample.address != nil, sample.rttSeconds < (bestV6?.rttSeconds ?? .infinity) {
          bestV6 = sample
        }
      } else {
        ipv4Working = true
        if let address = sample.address {
          v4Addresses.insert(address)
          v4AddressReports += 1
          if sample.rttSeconds < (bestV4?.rttSeconds ?? .infinity) {
            bestV4 = sample
          }
        }
      }

      if sample.countsForPreferred,
        sample.rttSeconds < (bestPreferred?.rttSeconds ?? .infinity)
      {
        bestPreferred = sample
      }
    }

    globalV4 = bestV4?.address?.description
    globalV6 = bestV6?.address?.description
    preferredDERPRegionID = bestPreferred?.regionID
    if v4AddressReports >= 2 {
      mappingVariesByDestination = v4Addresses.count > 1
    }
  }
}

extension TailscaleClient {
  /// Fetches the daemon's DERP map and runs a client-side ``Netcheck``
  /// against it.
  ///
  /// - Parameter options: Probe tuning; defaults to a 3-second window.
  /// - Returns: The measured ``NetcheckReport``.
  /// - Throws: `TailscaleClientError` if fetching the DERP map fails, or
  ///   `CancellationError` if the surrounding task is cancelled.
  public func netcheck(options: Netcheck.Options = Netcheck.Options()) async throws
    -> NetcheckReport
  {
    let map = try await derpMap()
    return try await Netcheck(options: options).run(derpMap: map)
  }
}
