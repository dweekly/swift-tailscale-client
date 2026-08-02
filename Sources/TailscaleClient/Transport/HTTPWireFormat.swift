// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Serializes LocalAPI requests to HTTP/1.1 wire bytes and parses response
/// heads. Pure functions with no socket dependency so the corner cases are
/// unit-testable (see `Documentation/TESTING.md`).
enum HTTPWireFormat {
  /// The status line and headers of an HTTP response, with header names
  /// lowercased for case-insensitive lookup.
  struct ResponseHead: Equatable {
    let statusCode: Int
    let headers: [String: String]

    var isChunked: Bool {
      headers["transfer-encoding"]?.lowercased().contains("chunked") == true
    }
  }

  /// Builds the HTTP/1.1 request bytes for a LocalAPI call.
  ///
  /// - Parameter keepAlive: `true` for streaming endpoints (the connection
  ///   stays open for the response stream); `false` closes after one response
  ///   so the body can be read to EOF.
  static func requestData(
    for request: TailscaleRequest, capabilityVersion: Int, keepAlive: Bool
  ) -> Data {
    var components = URLComponents()
    components.queryItems = request.queryItems.isEmpty ? nil : request.queryItems
    let queryString = components.percentEncodedQuery.map { "?\($0)" } ?? ""
    let requestLine = "\(request.method) \(request.path)\(queryString) HTTP/1.1\r\n"

    var headers = request.additionalHeaders
    headers["Host"] = "local-tailscaled.sock"
    headers["Connection"] = keepAlive ? "keep-alive" : "close"
    headers["Accept"] = "application/json"
    headers["Tailscale-Cap"] = String(capabilityVersion)
    if let body = request.body, body.isEmpty == false {
      headers["Content-Length"] = String(body.count)
    }

    let headerLines = headers.map { "\($0.key): \($0.value)\r\n" }.sorted()
    var httpData = Data(requestLine.utf8)
    httpData.append(Data(headerLines.joined().utf8))
    httpData.append(Data("\r\n".utf8))
    if let body = request.body {
      httpData.append(body)
    }
    return httpData
  }

  /// Parses a response head (status line + header lines, without the
  /// terminating blank line).
  static func parseResponseHead(_ headData: Data) throws -> ResponseHead {
    guard let headerString = String(data: headData, encoding: .utf8) else {
      throw TailscaleTransportError.malformedResponse(detail: "Headers not valid UTF-8")
    }
    let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)
    guard let statusLine = lines.first, !statusLine.isEmpty else {
      throw TailscaleTransportError.malformedResponse(detail: "Empty HTTP response")
    }
    let statusComponents = statusLine.split(separator: " ")
    guard statusComponents.count >= 2, let statusCode = Int(statusComponents[1]) else {
      throw TailscaleTransportError.malformedResponse(
        detail: "Invalid status line: '\(statusLine)'")
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let separatorIndex = line.firstIndex(of: ":") else { continue }
      let name = String(line[..<separatorIndex]).lowercased()
      let valueStart = line.index(after: separatorIndex)
      headers[name] = line[valueStart...].trimmingCharacters(in: .whitespaces)
    }
    return ResponseHead(statusCode: statusCode, headers: headers)
  }
}

/// Accumulates bytes until the head/body separator (`\r\n\r\n`) arrives —
/// which may be split across any number of reads.
struct HTTPHeadBuffer {
  /// Guard against a malformed peer streaming unbounded "headers".
  static let maxHeadBytes = 64 * 1024

  private var buffer = Data()

  /// Appends `data`; once the separator is seen, returns the head bytes
  /// (separator excluded) and any body bytes that arrived after it.
  mutating func feed(_ data: Data) throws -> (head: Data, bodyRemainder: Data)? {
    buffer.append(data)
    guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
      guard buffer.count <= Self.maxHeadBytes else {
        throw TailscaleTransportError.malformedResponse(
          detail: "HTTP head exceeds \(Self.maxHeadBytes) bytes")
      }
      return nil
    }
    return (Data(buffer[..<range.lowerBound]), Data(buffer[range.upperBound...]))
  }
}

/// Splits a byte stream into newline-delimited frames, tolerating frame
/// boundaries (including multi-byte UTF-8 sequences) split across reads.
struct NewlineFramer {
  private var buffer = Data()

  /// Appends `data` and returns all complete lines (without the trailing
  /// newline; empty lines are dropped, matching the IPN bus framing).
  mutating func feed(_ data: Data) -> [Data] {
    buffer.append(data)
    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
      let line = Data(buffer[buffer.startIndex..<newline])
      buffer.removeSubrange(buffer.startIndex...newline)
      if !line.isEmpty {
        lines.append(line)
      }
    }
    return lines
  }

  /// Returns any trailing bytes that never received a newline (call at EOF).
  mutating func flushRemainder() -> Data? {
    guard !buffer.isEmpty else { return nil }
    let remainder = buffer
    buffer.removeAll()
    return remainder
  }
}
