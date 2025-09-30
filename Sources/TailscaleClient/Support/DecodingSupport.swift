import Foundation

extension JSONDecoder {
  /// Decoder configured for Tailscale LocalAPI payloads.
  static func tailscale() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .tailscaleISO8601
    return decoder
  }
}

extension JSONDecoder.DateDecodingStrategy {
  static let tailscaleISO8601: JSONDecoder.DateDecodingStrategy = .custom { decoder in
    let container = try decoder.singleValueContainer()
    let string = try container.decode(String.self)
    if let date = TailscaleDateParser.parse(string) {
      return date
    }
    throw DecodingError.dataCorruptedError(
      in: container, debugDescription: "Invalid ISO8601 date: \(string)")
  }
}

enum TailscaleDateParser {
  static func parse(_ string: String) -> Date? {
    guard !string.isEmpty else { return nil }
    if let date = parse(string, fractional: true) {
      return date
    }
    return parse(string, fractional: false)
  }

  private static func parse(_ string: String, fractional: Bool) -> Date? {
    let formatter = ISO8601DateFormatter()
    var options: ISO8601DateFormatter.Options = [.withInternetDateTime]
    if fractional {
      options.insert(.withFractionalSeconds)
    }
    formatter.formatOptions = options
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: string)
  }
}
