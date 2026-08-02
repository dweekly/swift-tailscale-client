import Foundation

/// An arbitrary JSON value.
///
/// Some LocalAPI fields — notably node capability maps (`CapMap`) — are typed
/// upstream as raw JSON (`[]json.RawMessage` in `tailcfg`), so any valid JSON
/// value can appear. `JSONValue` preserves such values losslessly instead of
/// failing to decode shapes this package has not seen before.
public enum JSONValue: Sendable, Equatable, Decodable {
  case null
  case bool(Bool)
  case integer(Int)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .integer(value)
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
}
