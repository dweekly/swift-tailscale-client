// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class NetworkInterfaceDiscoveryTests: XCTestCase {
  /// The platform's loopback interface name ("lo0" on Darwin, "lo" on Linux).
  private var loopbackName: String {
    #if canImport(Darwin)
      return "lo0"
    #else
      return "lo"
    #endif
  }

  override func setUpWithError() throws {
    // Interface enumeration runs on Darwin and Glibc platforms; the whole
    // suite (loopback presence, address lookup, flag semantics) is the
    // Linux CI assertion that the getifaddrs port actually works.
    #if !canImport(Darwin) && !canImport(Glibc)
      throw XCTSkip("Interface enumeration is unsupported on this platform")
    #endif
  }

  // MARK: - allInterfaces Tests

  func testAllInterfacesReturnsNonEmpty() {
    // On any real system, we should have at least a loopback interface
    let interfaces = NetworkInterfaceDiscovery.allInterfaces()
    XCTAssertFalse(interfaces.isEmpty, "Expected at least one network interface")
  }

  func testAllInterfacesIncludesLoopback() {
    let interfaces = NetworkInterfaceDiscovery.allInterfaces()
    let hasLoopback = interfaces.contains { $0.isLoopback }
    XCTAssertTrue(hasLoopback, "Expected loopback interface (lo0)")
  }

  func testLoopbackInterfaceProperties() {
    let interfaces = NetworkInterfaceDiscovery.allInterfaces()
    guard let loopback = interfaces.first(where: { $0.isLoopback && !$0.isIPv6 }) else {
      XCTFail("Expected to find IPv4 loopback interface")
      return
    }

    XCTAssertEqual(loopback.name, loopbackName)
    XCTAssertEqual(loopback.address, "127.0.0.1")
    XCTAssertTrue(loopback.isUp)
    XCTAssertTrue(loopback.isRunning)
    XCTAssertFalse(loopback.isPointToPoint)
  }

  // MARK: - interface(withAddress:) Tests

  func testInterfaceWithLoopbackAddress() {
    let result = NetworkInterfaceDiscovery.interface(withAddress: "127.0.0.1")
    XCTAssertNotNil(result, "Expected to find loopback by IP")
    XCTAssertEqual(result?.name, loopbackName)
    XCTAssertTrue(result?.isLoopback ?? false)
  }

  func testInterfaceWithIPv6LoopbackAddress() {
    let result = NetworkInterfaceDiscovery.interface(withAddress: "::1")
    XCTAssertNotNil(result, "Expected to find IPv6 loopback")
    XCTAssertEqual(result?.name, loopbackName)
    XCTAssertTrue(result?.isIPv6 ?? false)
  }

  func testInterfaceWithNonexistentAddress() {
    let result = NetworkInterfaceDiscovery.interface(withAddress: "192.0.2.1")  // TEST-NET-1
    XCTAssertNil(result, "Should not find non-existent IP")
  }

  func testInterfaceWithInvalidAddress() {
    let result = NetworkInterfaceDiscovery.interface(withAddress: "not-an-ip")
    XCTAssertNil(result, "Should not find invalid IP")
  }

  // MARK: - tailscaleInterface(matching:) Tests

  func testTailscaleInterfaceWithEmptyArray() {
    let result = NetworkInterfaceDiscovery.tailscaleInterface(matching: [])
    XCTAssertNil(result, "Should return nil for empty IP array")
  }

  func testTailscaleInterfaceWithLoopbackIPs() {
    // Using loopback as a stand-in for Tailscale IP matching logic
    let result = NetworkInterfaceDiscovery.tailscaleInterface(matching: ["127.0.0.1"])
    XCTAssertNotNil(result, "Should find interface matching loopback")
    XCTAssertEqual(result?.name, loopbackName)
  }

  func testTailscaleInterfaceWithMultipleIPs() {
    // First IP that matches wins
    let result = NetworkInterfaceDiscovery.tailscaleInterface(
      matching: ["192.0.2.1", "127.0.0.1", "::1"])
    XCTAssertNotNil(result, "Should find first matching interface")
    XCTAssertEqual(result?.name, loopbackName)
  }

  func testTailscaleInterfaceWithNonexistentIPs() {
    let result = NetworkInterfaceDiscovery.tailscaleInterface(
      matching: ["192.0.2.1", "198.51.100.1"])  // TEST-NET addresses
    XCTAssertNil(result, "Should return nil for non-existent IPs")
  }

  // MARK: - IP Normalization Tests

  func testIPNormalizationCaseInsensitive() throws {
    // IPv6 addresses should match regardless of case
    let interfaces = NetworkInterfaceDiscovery.allInterfaces()
    guard interfaces.contains(where: { $0.isIPv6 }) else {
      throw XCTSkip("No IPv6 interfaces available")
    }

    // Find any IPv6 interface
    if let ipv6Interface = interfaces.first(where: { $0.isIPv6 }) {
      // Try to find it with uppercase
      let uppercase = NetworkInterfaceDiscovery.interface(
        withAddress: ipv6Interface.address.uppercased())
      XCTAssertNotNil(uppercase, "Should find IPv6 interface regardless of case")
    }
  }

  // MARK: - InterfaceInfo Equality Tests

  func testInterfaceInfoEquality() {
    let info1 = NetworkInterfaceDiscovery.InterfaceInfo(
      name: "en0",
      address: "192.168.1.1",
      isIPv6: false,
      isUp: true,
      isRunning: true,
      isLoopback: false,
      isPointToPoint: false
    )

    let info2 = NetworkInterfaceDiscovery.InterfaceInfo(
      name: "en0",
      address: "192.168.1.1",
      isIPv6: false,
      isUp: true,
      isRunning: true,
      isLoopback: false,
      isPointToPoint: false
    )

    let info3 = NetworkInterfaceDiscovery.InterfaceInfo(
      name: "en1",
      address: "192.168.1.1",
      isIPv6: false,
      isUp: true,
      isRunning: true,
      isLoopback: false,
      isPointToPoint: false
    )

    XCTAssertEqual(info1, info2)
    XCTAssertNotEqual(info1, info3)
  }

  // MARK: - StatusResponse Integration Tests

  func testStatusResponseInterfaceNameWithMockedIPs() {
    // Create a status response with loopback IP to test the computed property
    let status = StatusResponse(
      tailscaleIPs: ["127.0.0.1"]
    )

    XCTAssertEqual(status.interfaceName, loopbackName)
  }

  func testStatusResponseInterfaceNameWithNoMatchingIPs() {
    let status = StatusResponse(
      tailscaleIPs: ["192.0.2.1"]  // TEST-NET address that won't exist
    )

    XCTAssertNil(status.interfaceName)
  }

  func testStatusResponseInterfaceNameWithEmptyIPs() {
    let status = StatusResponse(
      tailscaleIPs: []
    )

    XCTAssertNil(status.interfaceName)
  }

  func testStatusResponseInterfaceInfo() {
    let status = StatusResponse(
      tailscaleIPs: ["127.0.0.1"]
    )

    let info = status.interfaceInfo
    XCTAssertNotNil(info)
    XCTAssertEqual(info?.name, loopbackName)
    XCTAssertTrue(info?.isLoopback ?? false)
  }
}
