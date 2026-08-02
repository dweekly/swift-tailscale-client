// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

@testable import TailscaleClient

final class STUNCodecTests: XCTestCase {

  private let transactionID: [UInt8] = [
    0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C,
  ]

  // MARK: - Request encoding

  func testBindingRequestLayout() {
    let request = [UInt8](STUN.bindingRequest(transactionID: transactionID))
    XCTAssertEqual(request.count, 20)
    XCTAssertEqual(Array(request[0..<4]), [0x00, 0x01, 0x00, 0x00])
    XCTAssertEqual(Array(request[4..<8]), STUN.magicCookie)
    XCTAssertEqual(Array(request[8..<20]), transactionID)
  }

  func testRandomTransactionIDsAreTwelveBytesAndDistinct() {
    let first = STUN.randomTransactionID()
    let second = STUN.randomTransactionID()
    XCTAssertEqual(first.count, 12)
    XCTAssertNotEqual(first, second, "96-bit IDs should never collide in practice")
  }

  // MARK: - Response parsing

  /// Builds a binding success response with the given attributes.
  private func response(attributes: [UInt8]) -> Data {
    var bytes: [UInt8] = [0x01, 0x01]
    bytes.append(UInt8(attributes.count >> 8))
    bytes.append(UInt8(attributes.count & 0xFF))
    bytes.append(contentsOf: STUN.magicCookie)
    bytes.append(contentsOf: transactionID)
    bytes.append(contentsOf: attributes)
    return Data(bytes)
  }

  /// XOR-MAPPED-ADDRESS value for 203.0.113.7:41641 (IPv4).
  private var xorMappedV4Value: [UInt8] {
    let port = UInt16(41641) ^ 0x2112
    let plain: [UInt8] = [203, 0, 113, 7]
    let octets = zip(plain, STUN.magicCookie).map { $0.0 ^ $0.1 }
    return [0x00, 0x01, UInt8(port >> 8), UInt8(port & 0xFF)] + octets
  }

  func testParsesXORMappedAddressV4() throws {
    let attributes: [UInt8] = [0x00, 0x20, 0x00, 0x08] + xorMappedV4Value
    let parsed = try STUN.parseBindingResponse(response(attributes: attributes))

    XCTAssertEqual(parsed.transactionID, transactionID)
    let address = try XCTUnwrap(parsed.address)
    XCTAssertEqual(address.ip, "203.0.113.7")
    XCTAssertEqual(address.port, 41641)
    XCTAssertFalse(address.isIPv6)
    XCTAssertEqual(address.description, "203.0.113.7:41641")
  }

  func testParsesLegacyXORMappedAddress() throws {
    let attributes: [UInt8] = [0x80, 0x20, 0x00, 0x08] + xorMappedV4Value
    let parsed = try STUN.parseBindingResponse(response(attributes: attributes))
    XCTAssertEqual(parsed.address?.ip, "203.0.113.7")
    XCTAssertEqual(parsed.address?.port, 41641)
  }

  func testFallsBackToPlainMappedAddress() throws {
    let attributes: [UInt8] = [0x00, 0x01, 0x00, 0x08, 0x00, 0x01, 0xA2, 0xA9, 203, 0, 113, 7]
    let parsed = try STUN.parseBindingResponse(response(attributes: attributes))
    let address = try XCTUnwrap(parsed.address)
    XCTAssertEqual(address.ip, "203.0.113.7")
    XCTAssertEqual(address.port, 41641)
  }

  func testParsesXORMappedAddressV6() throws {
    let octets: [UInt8] = [
      0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01,
    ]
    let mask = STUN.magicCookie + transactionID
    let xored = zip(octets, mask).map { $0.0 ^ $0.1 }
    let port = UInt16(3478) ^ 0x2112
    let value: [UInt8] = [0x00, 0x02, UInt8(port >> 8), UInt8(port & 0xFF)] + xored
    let attributes: [UInt8] = [0x00, 0x20, 0x00, 0x14] + value

    let parsed = try STUN.parseBindingResponse(response(attributes: attributes))
    let address = try XCTUnwrap(parsed.address)
    XCTAssertTrue(address.isIPv6)
    XCTAssertEqual(address.ip, "2001:db8:0:0:0:0:0:1")
    XCTAssertEqual(address.port, 3478)
    XCTAssertEqual(address.description, "[2001:db8:0:0:0:0:0:1]:3478")
  }

  func testSkipsUnknownAttributesWithPadding() throws {
    // SOFTWARE (0x8022) with a 5-byte value pads to 8; the mapped address
    // that follows must still be found.
    let software: [UInt8] = [0x80, 0x22, 0x00, 0x05, 0x73, 0x77, 0x69, 0x66, 0x74, 0, 0, 0]
    let mapped: [UInt8] = [0x00, 0x20, 0x00, 0x08] + xorMappedV4Value
    let parsed = try STUN.parseBindingResponse(response(attributes: software + mapped))
    XCTAssertEqual(parsed.address?.ip, "203.0.113.7")
  }

  func testResponseWithoutAddressAttributeParses() throws {
    let parsed = try STUN.parseBindingResponse(response(attributes: []))
    XCTAssertEqual(parsed.transactionID, transactionID)
    XCTAssertNil(parsed.address)
  }

  func testRejectsTruncatedMessage() {
    XCTAssertThrowsError(try STUN.parseBindingResponse(Data([0x01, 0x01, 0x00]))) { error in
      XCTAssertEqual(error as? STUN.ParseError, .truncated)
    }
  }

  func testRejectsWrongMagicCookie() {
    var bytes = [UInt8](response(attributes: []))
    bytes[4] = 0xFF
    XCTAssertThrowsError(try STUN.parseBindingResponse(Data(bytes))) { error in
      XCTAssertEqual(error as? STUN.ParseError, .notASTUNResponse)
    }
  }

  func testRejectsNonSuccessMessageType() {
    var bytes = [UInt8](response(attributes: []))
    bytes[0] = 0x00
    bytes[1] = 0x01  // binding request, not a success response
    XCTAssertThrowsError(try STUN.parseBindingResponse(Data(bytes))) { error in
      XCTAssertEqual(error as? STUN.ParseError, .notABindingSuccess)
    }
  }
}

final class NetcheckPlanningTests: XCTestCase {

  private func makeMap() -> DERPMap {
    DERPMap(regions: [
      1: DERPRegion(
        regionID: 1, regionCode: "one",
        nodes: [
          DERPNode(name: "1-stunless", regionID: 1, hostName: "a.example.com", stunPort: -1),
          DERPNode(
            name: "1a", regionID: 1, hostName: "b.example.com", ipv4: "192.0.2.1",
            ipv6: "none"),
        ]),
      2: DERPRegion(
        regionID: 2, regionCode: "two", avoid: true,
        nodes: [
          DERPNode(name: "2a", regionID: 2, hostName: "c.example.com", ipv4: "192.0.2.2")
        ]),
      3: DERPRegion(
        regionID: 3, regionCode: "silent", noMeasureNoHome: true,
        nodes: [
          DERPNode(name: "3a", regionID: 3, hostName: "d.example.com", ipv4: "192.0.2.3")
        ]),
    ])
  }

  func testCandidateSelection() {
    let candidates = NetcheckProbe.candidates(for: makeMap(), includeIPv6: true)

    // Region 3 is NoMeasureNoHome; region 1 offers no IPv6 ("none" +
    // stunless first node); region 2 has no IPv6 literal but may resolve.
    let v4 = candidates.filter { !$0.ipv6 }
    XCTAssertEqual(v4.map(\.regionID), [1, 2])
    XCTAssertEqual(v4.first?.hostName, "b.example.com", "STUN-disabled node must be skipped")
    XCTAssertEqual(v4.first?.ipLiteral, "192.0.2.1")
    XCTAssertEqual(v4.first?.port, 3478)
    XCTAssertEqual(v4.first?.countsForPreferred, true)
    XCTAssertEqual(v4.last?.countsForPreferred, false, "Avoid regions never become preferred")

    let v6 = candidates.filter(\.ipv6)
    XCTAssertEqual(v6.map(\.regionID), [2], "Region 1 declares IPv6 unsupported")
  }

  func testIPv6CandidatesCanBeDisabled() {
    let candidates = NetcheckProbe.candidates(for: makeMap(), includeIPv6: false)
    XCTAssertTrue(candidates.allSatisfy { !$0.ipv6 })
  }

  func testEmptyMapYieldsNoCandidatesAndEmptyReport() async throws {
    XCTAssertTrue(NetcheckProbe.candidates(for: DERPMap(), includeIPv6: true).isEmpty)
    let report = try await Netcheck().run(derpMap: DERPMap())
    XCTAssertEqual(report, NetcheckReport())
  }
}

final class NetcheckReportTests: XCTestCase {

  private func sample(
    region: Int, rtt: Double, ip: String? = nil, port: Int = 41641,
    ipv6: Bool = false, preferred: Bool = true
  ) -> NetcheckProbe.Sample {
    NetcheckProbe.Sample(
      regionID: region,
      rttSeconds: rtt,
      address: ip.map { STUN.MappedAddress(ip: $0, port: port, isIPv6: ipv6) },
      ipv6: ipv6,
      countsForPreferred: preferred)
  }

  func testSummarizesSamples() {
    let report = NetcheckReport(samples: [
      sample(region: 1, rtt: 0.020, ip: "203.0.113.7"),
      sample(region: 2, rtt: 0.050, ip: "203.0.113.7"),
      sample(region: 2, rtt: 0.045, ipv6: true),
    ])

    XCTAssertTrue(report.udpWorking)
    XCTAssertTrue(report.ipv4Working)
    XCTAssertTrue(report.ipv6Working)
    XCTAssertEqual(report.preferredDERPRegionID, 1)
    XCTAssertEqual(report.globalV4, "203.0.113.7:41641")
    XCTAssertNil(report.globalV6, "IPv6 sample carried no mapped address")
    XCTAssertEqual(report.regionLatencySeconds[1] ?? 0, 0.020, accuracy: 0.0001)
    XCTAssertEqual(
      report.regionLatencySeconds[2] ?? 0, 0.045, accuracy: 0.0001,
      "Region latency should keep the best sample across families")
    XCTAssertEqual(report.mappingVariesByDestination, false)
  }

  func testDetectsVaryingMappings() {
    let report = NetcheckReport(samples: [
      sample(region: 1, rtt: 0.020, ip: "203.0.113.7", port: 1001),
      sample(region: 2, rtt: 0.030, ip: "203.0.113.7", port: 2002),
    ])
    XCTAssertEqual(report.mappingVariesByDestination, true)
  }

  func testSingleAddressReportLeavesVarianceUnknown() {
    let report = NetcheckReport(samples: [sample(region: 1, rtt: 0.020, ip: "203.0.113.7")])
    XCTAssertNil(report.mappingVariesByDestination)
  }

  func testAvoidRegionsAreMeasuredButNeverPreferred() {
    let report = NetcheckReport(samples: [
      sample(region: 1, rtt: 0.010, preferred: false),
      sample(region: 2, rtt: 0.080),
    ])
    XCTAssertEqual(report.preferredDERPRegionID, 2)
    XCTAssertEqual(report.regionLatencySeconds.count, 2)
  }

  func testNoSamplesMeansUDPNotWorking() {
    let report = NetcheckReport(samples: [])
    XCTAssertFalse(report.udpWorking)
    XCTAssertNil(report.preferredDERPRegionID)
    XCTAssertTrue(report.regionLatencySeconds.isEmpty)
  }
}
