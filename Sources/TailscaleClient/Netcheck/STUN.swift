// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Minimal STUN (RFC 8489) binding-request codec — just enough to ask a DERP
/// node's STUN server "what is my public address?" and read the answer.
/// Pure functions over bytes; the UDP socket work lives in `NetcheckProbe`.
enum STUN {
  /// The fixed magic cookie every RFC 5389+ STUN message carries at bytes 4–7.
  static let magicCookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]

  private static let bindingRequestType: UInt16 = 0x0001
  private static let bindingSuccessType: UInt16 = 0x0101
  private static let headerLength = 20

  /// Attribute numbers for the address the server saw us from.
  /// 0x8020 is the pre-RFC 5389 XOR-MAPPED-ADDRESS some servers still send.
  private static let attrMappedAddress: UInt16 = 0x0001
  private static let attrXORMappedAddress: UInt16 = 0x0020
  private static let attrXORMappedAddressLegacy: UInt16 = 0x8020

  /// A public IP and port reported by a STUN server.
  struct MappedAddress: Equatable, Hashable, Sendable {
    let ip: String
    let port: Int
    let isIPv6: Bool

    /// Standard "ip:port" / "[ip]:port" rendering.
    var description: String {
      isIPv6 ? "[\(ip)]:\(port)" : "\(ip):\(port)"
    }
  }

  enum ParseError: Error, Equatable {
    case truncated
    case notASTUNResponse
    case notABindingSuccess
  }

  /// 96-bit transaction ID used to match responses to requests.
  static func randomTransactionID() -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<12).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  }

  /// Serializes a binding request (header only; no attributes needed).
  static func bindingRequest(transactionID: [UInt8]) -> Data {
    precondition(transactionID.count == 12, "STUN transaction IDs are 12 bytes")
    var bytes: [UInt8] = []
    bytes.reserveCapacity(headerLength)
    bytes.append(contentsOf: [
      UInt8(bindingRequestType >> 8), UInt8(bindingRequestType & 0xFF),
      0x00, 0x00,  // message length: no attributes
    ])
    bytes.append(contentsOf: magicCookie)
    bytes.append(contentsOf: transactionID)
    return Data(bytes)
  }

  /// Parses a binding success response, returning its transaction ID and the
  /// mapped address (when the server included one).
  static func parseBindingResponse(_ data: Data) throws -> (
    transactionID: [UInt8], address: MappedAddress?
  ) {
    let bytes = [UInt8](data)
    guard bytes.count >= headerLength else { throw ParseError.truncated }
    guard Array(bytes[4..<8]) == magicCookie else { throw ParseError.notASTUNResponse }
    let messageType = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    guard messageType == bindingSuccessType else { throw ParseError.notABindingSuccess }

    let declaredLength = Int(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
    guard bytes.count >= headerLength + declaredLength else { throw ParseError.truncated }
    let transactionID = Array(bytes[8..<headerLength])

    var plainMapped: MappedAddress?
    var offset = headerLength
    let end = headerLength + declaredLength
    while offset + 4 <= end {
      let attrType = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
      let attrLength = Int(UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3]))
      let valueStart = offset + 4
      guard valueStart + attrLength <= end else { throw ParseError.truncated }
      let value = Array(bytes[valueStart..<valueStart + attrLength])

      switch attrType {
      case attrXORMappedAddress, attrXORMappedAddressLegacy:
        if let address = decodeAddress(value, xor: true, transactionID: transactionID) {
          return (transactionID, address)  // XOR form wins outright.
        }
      case attrMappedAddress:
        if plainMapped == nil {
          plainMapped = decodeAddress(value, xor: false, transactionID: transactionID)
        }
      default:
        break
      }
      // Attribute values are padded to a 4-byte boundary.
      offset = valueStart + ((attrLength + 3) & ~3)
    }
    return (transactionID, plainMapped)
  }

  /// Decodes a (XOR-)MAPPED-ADDRESS value: reserved byte, family byte,
  /// 2-byte port, then the 4- or 16-byte address.
  private static func decodeAddress(
    _ value: [UInt8], xor: Bool, transactionID: [UInt8]
  ) -> MappedAddress? {
    guard value.count >= 8 else { return nil }
    let family = value[1]
    var port = Int(UInt16(value[2]) << 8 | UInt16(value[3]))
    if xor {
      port ^= Int(UInt16(magicCookie[0]) << 8 | UInt16(magicCookie[1]))
    }

    switch family {
    case 0x01:
      var octets = Array(value[4..<8])
      if xor {
        for index in 0..<4 { octets[index] ^= magicCookie[index] }
      }
      let ip = octets.map(String.init).joined(separator: ".")
      return MappedAddress(ip: ip, port: port, isIPv6: false)
    case 0x02:
      guard value.count >= 20 else { return nil }
      var octets = Array(value[4..<20])
      if xor {
        // IPv6 XORs against cookie ‖ transaction ID (16 bytes total).
        let mask = magicCookie + transactionID
        for index in 0..<16 { octets[index] ^= mask[index] }
      }
      let groups = stride(from: 0, to: 16, by: 2).map { index in
        String(UInt16(octets[index]) << 8 | UInt16(octets[index + 1]), radix: 16)
      }
      return MappedAddress(ip: groups.joined(separator: ":"), port: port, isIPv6: true)
    default:
      return nil
    }
  }
}
