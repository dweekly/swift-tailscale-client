// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Candidate selection and the blocking UDP probe loop behind ``Netcheck``.
/// Splitting the pure planning step from the socket work keeps the former
/// unit-testable without a network.
enum NetcheckProbe {

  /// One STUN target: a region's first STUN-capable node for one address
  /// family. Planned from the DERP map before any DNS or socket work.
  struct Candidate: Equatable, Sendable {
    let regionID: Int
    let hostName: String
    /// Pinned IP from the DERP map, letting the probe skip DNS entirely.
    let ipLiteral: String?
    let port: Int
    let ipv6: Bool
    /// `false` for regions flagged `Avoid`: still measured, never preferred.
    let countsForPreferred: Bool
  }

  /// One STUN answer: how long the region took and what public address it
  /// saw us as (when the response included one).
  struct Sample: Sendable {
    let regionID: Int
    let rttSeconds: Double
    let address: STUN.MappedAddress?
    let ipv6: Bool
    let countsForPreferred: Bool
  }

  /// Picks per-region probe targets: the first STUN-capable node, once per
  /// address family. Regions marked `NoMeasureNoHome` are skipped outright.
  static func candidates(for map: DERPMap, includeIPv6: Bool) -> [Candidate] {
    var result: [Candidate] = []
    for region in map.sortedRegions where !region.noMeasureNoHome {
      var families = [false]
      if includeIPv6 { families.append(true) }
      for ipv6 in families {
        guard
          let node = region.nodes.first(where: { node in
            guard node.effectiveSTUNPort != nil, !node.hostName.isEmpty else { return false }
            // The literal "none" declares the family unsupported on this node.
            return (ipv6 ? node.ipv6 : node.ipv4) != "none"
          }),
          let stunPort = node.effectiveSTUNPort
        else { continue }
        result.append(
          Candidate(
            regionID: region.regionID,
            hostName: node.hostName,
            ipLiteral: ipv6 ? node.ipv6 : node.ipv4,
            port: stunPort,
            ipv6: ipv6,
            countsForPreferred: !region.avoid))
      }
    }
    return result
  }

  /// Resolves candidates, fires one binding request at each over a shared
  /// per-family socket, and collects responses until every target answered
  /// or the deadline passes. Blocking; run it on a detached task.
  static func run(candidates: [Candidate], timeout: Duration) -> [Sample] {
    var inFlight: [[UInt8]: (candidate: Candidate, sentAt: ContinuousClock.Instant)] = [:]
    var samples: [Sample] = []

    var socketV4: Int32 = -1
    var socketV6: Int32 = -1
    defer {
      if socketV4 >= 0 { close(socketV4) }
      if socketV6 >= 0 { close(socketV6) }
    }

    for candidate in candidates {
      guard let address = resolve(candidate) else { continue }
      let fd = candidate.ipv6 ? socketV6 : socketV4
      let sendFD: Int32
      if fd >= 0 {
        sendFD = fd
      } else {
        let created = socket(candidate.ipv6 ? AF_INET6 : AF_INET, datagramSocketType, 0)
        guard created >= 0 else { continue }
        if candidate.ipv6 { socketV6 = created } else { socketV4 = created }
        sendFD = created
      }

      let transactionID = STUN.randomTransactionID()
      let request = STUN.bindingRequest(transactionID: transactionID)
      let sent = request.withUnsafeBytes { payload in
        address.withUnsafeBytes { raw in
          sendto(
            sendFD, payload.baseAddress, payload.count, 0,
            raw.baseAddress!.assumingMemoryBound(to: sockaddr.self),
            socklen_t(address.count))
        }
      }
      // A failed send (e.g. no IPv6 route) simply leaves the region silent.
      if sent == request.count {
        inFlight[transactionID] = (candidate, ContinuousClock.now)
      }
    }

    guard !inFlight.isEmpty else { return samples }

    let deadline = ContinuousClock.now.advanced(by: timeout)
    var buffer = [UInt8](repeating: 0, count: 2048)
    while !inFlight.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
      var descriptors: [pollfd] = []
      for fd in [socketV4, socketV6] where fd >= 0 {
        descriptors.append(pollfd(fd: fd, events: Int16(POLLIN), revents: 0))
      }
      let ready = poll(&descriptors, nfds_t(descriptors.count), 100)
      if ready < 0 {
        if errno == EINTR { continue }
        break
      }
      if ready == 0 { continue }

      for descriptor in descriptors where descriptor.revents & Int16(POLLIN) != 0 {
        let received = recv(descriptor.fd, &buffer, buffer.count, 0)
        guard received > 0 else { continue }
        let now = ContinuousClock.now
        guard
          let parsed = try? STUN.parseBindingResponse(Data(bytes: buffer, count: received)),
          let entry = inFlight.removeValue(forKey: parsed.transactionID)
        else { continue }
        samples.append(
          Sample(
            regionID: entry.candidate.regionID,
            rttSeconds: entry.sentAt.duration(to: now).timeIntervalValue,
            address: parsed.address,
            ipv6: entry.candidate.ipv6,
            countsForPreferred: entry.candidate.countsForPreferred))
      }
    }
    return samples
  }

  // MARK: - Address resolution

  /// Produces raw `sockaddr` bytes for a candidate: straight from the map's
  /// pinned IP when present, otherwise via DNS for the candidate's family.
  private static func resolve(_ candidate: Candidate) -> [UInt8]? {
    if let literal = candidate.ipLiteral {
      return sockaddrBytes(ip: literal, port: candidate.port, ipv6: candidate.ipv6)
    }
    return resolveHostname(candidate.hostName, port: candidate.port, ipv6: candidate.ipv6)
  }

  private static func sockaddrBytes(ip: String, port: Int, ipv6: Bool) -> [UInt8]? {
    if ipv6 {
      var address = sockaddr_in6()
      address.sin6_family = sa_family_t(AF_INET6)
      address.sin6_port = in_port_t(UInt16(port).bigEndian)
      guard inet_pton(AF_INET6, ip, &address.sin6_addr) == 1 else { return nil }
      return withUnsafeBytes(of: &address) { [UInt8]($0) }
    }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { return nil }
    return withUnsafeBytes(of: &address) { [UInt8]($0) }
  }

  private static func resolveHostname(_ host: String, port: Int, ipv6: Bool) -> [UInt8]? {
    var hints = addrinfo()
    hints.ai_family = ipv6 ? AF_INET6 : AF_INET
    hints.ai_socktype = datagramSocketType
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return nil }
    defer { freeaddrinfo(list) }

    var current: UnsafeMutablePointer<addrinfo>? = first
    while let node = current {
      if node.pointee.ai_family == hints.ai_family, let addr = node.pointee.ai_addr {
        return [UInt8](UnsafeRawBufferPointer(start: addr, count: Int(node.pointee.ai_addrlen)))
      }
      current = node.pointee.ai_next
    }
    return nil
  }

  private static var datagramSocketType: Int32 {
    #if canImport(Glibc)
      return Int32(SOCK_DGRAM.rawValue)
    #else
      return SOCK_DGRAM
    #endif
  }
}

extension Duration {
  /// The duration in seconds as a floating-point value.
  var timeIntervalValue: Double {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
