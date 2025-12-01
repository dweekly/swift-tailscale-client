// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Discovers network interface information by matching IP addresses to system interfaces.
///
/// This utility uses the BSD `getifaddrs` API to enumerate network interfaces
/// and can identify which interface (e.g., `utun16`) corresponds to Tailscale
/// by matching against known Tailscale IP addresses.
public enum NetworkInterfaceDiscovery {

  /// Information about a network interface.
  public struct InterfaceInfo: Sendable, Equatable {
    /// The interface name (e.g., "utun16", "en0").
    public let name: String

    /// The IP address assigned to this interface.
    public let address: String

    /// Whether this is an IPv6 address.
    public let isIPv6: Bool

    /// Whether the interface is currently up.
    public let isUp: Bool

    /// Whether the interface is running.
    public let isRunning: Bool

    /// Whether this is a loopback interface.
    public let isLoopback: Bool

    /// Whether this is a point-to-point interface (typical for TUN/TAP).
    public let isPointToPoint: Bool
  }

  /// Returns all network interfaces with their IP addresses.
  ///
  /// - Returns: Array of interface information for all active interfaces.
  public static func allInterfaces() -> [InterfaceInfo] {
    #if canImport(Darwin)
      return enumerateInterfaces()
    #else
      return []
    #endif
  }

  /// Finds the network interface that has the specified IP address.
  ///
  /// - Parameter ipAddress: The IP address to search for (IPv4 or IPv6).
  /// - Returns: The interface info if found, or `nil` if no interface has that address.
  public static func interface(withAddress ipAddress: String) -> InterfaceInfo? {
    // Normalize the IP for comparison
    let normalizedTarget = normalizeIP(ipAddress)
    return allInterfaces().first { normalizeIP($0.address) == normalizedTarget }
  }

  /// Finds the Tailscale TUN interface by matching against known Tailscale IPs.
  ///
  /// - Parameter tailscaleIPs: Array of Tailscale IP addresses (from `StatusResponse.tailscaleIPs`).
  /// - Returns: The interface info for the Tailscale TUN, or `nil` if not found.
  ///
  /// Example:
  /// ```swift
  /// let status = try await client.status()
  /// if let tunInterface = NetworkInterfaceDiscovery.tailscaleInterface(matching: status.tailscaleIPs) {
  ///     print("Tailscale is using interface: \(tunInterface.name)")
  /// }
  /// ```
  public static func tailscaleInterface(matching tailscaleIPs: [String]) -> InterfaceInfo? {
    let normalizedTargets = Set(tailscaleIPs.map { normalizeIP($0) })
    return allInterfaces().first { normalizedTargets.contains(normalizeIP($0.address)) }
  }

  // MARK: - Private Implementation

  #if canImport(Darwin)
    private static func enumerateInterfaces() -> [InterfaceInfo] {
      var interfaces: [InterfaceInfo] = []
      var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?

      guard getifaddrs(&ifaddrsPtr) == 0 else {
        return []
      }
      defer { freeifaddrs(ifaddrsPtr) }

      var current = ifaddrsPtr
      while let ifaddr = current {
        defer { current = ifaddr.pointee.ifa_next }

        guard let addr = ifaddr.pointee.ifa_addr else { continue }
        let family = Int32(addr.pointee.sa_family)

        // Only process IPv4 and IPv6 addresses
        guard family == AF_INET || family == AF_INET6 else { continue }

        let flags = Int32(ifaddr.pointee.ifa_flags)
        let name = String(cString: ifaddr.pointee.ifa_name)

        // Extract the IP address string
        guard let addressString = extractAddress(from: addr, family: family) else { continue }

        let info = InterfaceInfo(
          name: name,
          address: addressString,
          isIPv6: family == AF_INET6,
          isUp: (flags & IFF_UP) != 0,
          isRunning: (flags & IFF_RUNNING) != 0,
          isLoopback: (flags & IFF_LOOPBACK) != 0,
          isPointToPoint: (flags & IFF_POINTOPOINT) != 0
        )
        interfaces.append(info)
      }

      return interfaces
    }

    private static func extractAddress(from addr: UnsafePointer<sockaddr>, family: Int32) -> String?
    {
      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

      let result = addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        let length =
          family == AF_INET
          ? socklen_t(MemoryLayout<sockaddr_in>.size)
          : socklen_t(MemoryLayout<sockaddr_in6>.size)

        return getnameinfo(
          sockaddrPtr,
          length,
          &hostname,
          socklen_t(hostname.count),
          nil,
          0,
          NI_NUMERICHOST
        )
      }

      guard result == 0 else { return nil }

      // Convert CChar array to String
      var addressString = hostname.withUnsafeBufferPointer { buffer in
        String(cString: buffer.baseAddress!)
      }

      // For IPv6 link-local addresses, strip the scope ID (e.g., "%en0")
      if family == AF_INET6, let percentIndex = addressString.firstIndex(of: "%") {
        addressString = String(addressString[..<percentIndex])
      }

      return addressString
    }
  #endif

  /// Normalizes an IP address for comparison.
  /// - Handles IPv4 addresses directly
  /// - For IPv6, strips scope identifiers and normalizes case
  private static func normalizeIP(_ ip: String) -> String {
    var normalized = ip.lowercased()

    // Strip IPv6 scope identifier if present
    if let percentIndex = normalized.firstIndex(of: "%") {
      normalized = String(normalized[..<percentIndex])
    }

    // Strip CIDR notation if present
    if let slashIndex = normalized.firstIndex(of: "/") {
      normalized = String(normalized[..<slashIndex])
    }

    return normalized
  }
}
