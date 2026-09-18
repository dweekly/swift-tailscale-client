// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// An arbitrary JSON value preserving 64-bit integer precision.
///
/// Some LocalAPI fields — notably node capability maps (`CapMap`) and unmodeled
/// daemon configuration settings — are typed upstream as raw JSON (`[]json.RawMessage`
/// in `tailcfg`), so any valid JSON value can appear. `JSONValue` preserves such
/// values losslessly instead of failing to decode shapes this package has not seen before,
/// avoiding truncation of 64-bit signed and unsigned integers.
public enum JSONValue: Sendable, Equatable, Codable {
  /// A JSON `null` literal.
  case null
  /// A boolean JSON value (`true` or `false`).
  case bool(Bool)
  /// A signed 64-bit integer JSON value.
  case integer(Int64)
  /// An unsigned 64-bit integer JSON value.
  case unsignedInteger(UInt64)
  /// A floating-point number JSON value.
  case double(Double)
  /// A UTF-8 string JSON value.
  case string(String)
  /// An ordered array of JSON values.
  case array([JSONValue])
  /// An unordered key-value dictionary of JSON values.
  case object([String: JSONValue])

  /// Convenience factory for backward compatibility with standard `Int`.
  public static func integer(_ value: Int) -> JSONValue {
    .integer(Int64(value))
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(UInt64.self) {
      self = .unsignedInteger(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Value is not valid JSON")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .integer(let value):
      try container.encode(value)
    case .unsignedInteger(let value):
      try container.encode(value)
    case .double(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  // MARK: - Accessors

  /// Returns the value as an `Int` if this is an integer that fits in the platform's `Int`.
  public var intValue: Int? {
    switch self {
    case .integer(let v): return Int(exactly: v)
    case .unsignedInteger(let v): return Int(exactly: v)
    default: return nil
    }
  }

  /// Returns the value as an `Int64` if this is an integer that fits in `Int64`.
  public var int64Value: Int64? {
    switch self {
    case .integer(let v): return v
    case .unsignedInteger(let v): return Int64(exactly: v)
    default: return nil
    }
  }

  /// Returns the value as a `UInt64` if this is an integer that fits in `UInt64`.
  public var uint64Value: UInt64? {
    switch self {
    case .integer(let v): return UInt64(exactly: v)
    case .unsignedInteger(let v): return v
    default: return nil
    }
  }

  /// Returns the value as a `Double` if this is a double or integer.
  public var doubleValue: Double? {
    switch self {
    case .double(let v): return v
    case .integer(let v): return Double(v)
    case .unsignedInteger(let v): return Double(v)
    default: return nil
    }
  }

  /// Returns the value as a `String` if this is a `.string`.
  public var stringValue: String? {
    if case .string(let v) = self { return v }
    return nil
  }

  /// Returns the value as a `Bool` if this is a `.bool`.
  public var boolValue: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }

  /// Returns whether this value is `.null`.
  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }
}
