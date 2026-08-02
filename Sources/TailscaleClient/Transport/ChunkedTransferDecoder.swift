// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Incremental decoder for HTTP/1.1 chunked transfer encoding.
///
/// A push-style state machine: feed it raw body bytes as they arrive off the
/// socket — in fragments split at *any* boundary (mid size-line, mid chunk,
/// mid CRLF) — and it returns the decoded payload bytes. Used by both the
/// unary path (whole body in one feed) and the streaming path (per read).
struct ChunkedTransferDecoder {
  /// Guard against a malformed peer streaming an unbounded size line.
  static let maxSizeLineBytes = 1024

  private enum State {
    /// Accumulating the hex chunk-size line (until CRLF).
    case size
    /// Consuming chunk payload bytes.
    case data(remaining: Int)
    /// Consuming the CRLF that follows each chunk's payload.
    case dataCRLF
    /// After the terminal 0-chunk: consuming trailer lines until a blank line.
    case trailers
    /// Terminal 0-chunk and trailers fully consumed.
    case complete
  }

  private var state: State = .size
  private var lineBuffer = Data()

  /// Whether the terminal chunk (and its trailers) have been consumed.
  var isComplete: Bool {
    if case .complete = state { return true }
    return false
  }

  /// Decodes the next fragment of wire bytes, returning any payload bytes it
  /// completes. Throws `TailscaleTransportError.malformedResponse` on an
  /// invalid chunk-size line.
  mutating func feed(_ input: Data) throws -> Data {
    var output = Data()
    let bytes = [UInt8](input)
    var index = 0

    while index < bytes.count {
      switch state {
      case .size:
        let byte = bytes[index]
        index += 1
        lineBuffer.append(byte)
        guard lineBuffer.count <= Self.maxSizeLineBytes else {
          throw TailscaleTransportError.malformedResponse(detail: "Chunk size line too long")
        }
        if byte == UInt8(ascii: "\n") {
          let size = try Self.parseChunkSize(lineBuffer)
          lineBuffer.removeAll(keepingCapacity: true)
          state = size == 0 ? .trailers : .data(remaining: size)
        }

      case .data(let remaining):
        let available = bytes.count - index
        let take = min(remaining, available)
        output.append(contentsOf: bytes[index..<(index + take)])
        index += take
        if take == remaining {
          state = .dataCRLF
        } else {
          state = .data(remaining: remaining - take)
        }

      case .dataCRLF:
        // Consume through the newline that terminates the chunk's CRLF;
        // tolerate a bare LF from non-conforming encoders.
        let byte = bytes[index]
        index += 1
        if byte == UInt8(ascii: "\n") {
          state = .size
        }

      case .trailers:
        let byte = bytes[index]
        index += 1
        lineBuffer.append(byte)
        guard lineBuffer.count <= Self.maxSizeLineBytes else {
          throw TailscaleTransportError.malformedResponse(detail: "Chunk trailer line too long")
        }
        if byte == UInt8(ascii: "\n") {
          // A blank line (bare CRLF) ends the trailer section.
          let isBlank = lineBuffer == Data("\r\n".utf8) || lineBuffer == Data("\n".utf8)
          lineBuffer.removeAll(keepingCapacity: true)
          if isBlank {
            state = .complete
          }
        }

      case .complete:
        // Ignore anything after the terminal chunk.
        return output
      }
    }
    return output
  }

  private static func parseChunkSize(_ line: Data) throws -> Int {
    guard let string = String(data: line, encoding: .utf8) else {
      throw TailscaleTransportError.malformedResponse(detail: "Chunk size line not UTF-8")
    }
    // Strip CRLF and any chunk extensions (";name=value").
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    let sizeField = trimmed.split(separator: ";", maxSplits: 1).first.map(String.init) ?? trimmed
    guard let size = Int(sizeField.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0
    else {
      throw TailscaleTransportError.malformedResponse(
        detail: "Invalid chunk size line: '\(trimmed)'")
    }
    return size
  }
}
