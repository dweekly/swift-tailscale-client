// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Primary entry point for interacting with the Tailscale LocalAPI.
///
/// This library is an unofficial, MIT-licensed project by David E. Weekly and is not
/// endorsed by Tailscale Inc. The initial v0.1.0 release focuses on providing access
/// to the `/localapi/v0/status` endpoint via an async/await friendly API.
public actor TailscaleClient {
  /// Configuration applied to each request the client makes.
  public nonisolated let configuration: TailscaleClientConfiguration

  /// Creates a client that uses the default configuration for the current platform.
  public init(configuration: TailscaleClientConfiguration = .default) {
    self.configuration = configuration
  }

  /// Fetches the current node status from the Tailscale daemon.
  ///
  /// - Parameter query: Optional parameters that influence the response (e.g. toggling peers).
  /// - Returns: The parsed response payload from `/localapi/v0/status`.
  public func status(query: StatusQuery = .default) async throws -> StatusResponse {
    let endpoint = "/localapi/v0/status"
    let request = TailscaleRequest(path: endpoint, queryItems: query.queryItems)
    let response: TailscaleResponse
    do {
      response = try await configuration.transport.send(request, configuration: configuration)
    } catch let transportError as TailscaleTransportError {
      throw TailscaleClientError.transport(transportError)
    }

    guard response.statusCode == 200 else {
      throw TailscaleClientError.unexpectedStatus(
        code: response.statusCode, body: response.data, endpoint: endpoint)
    }

    do {
      return try JSONDecoder.tailscale().decode(StatusResponse.self, from: response.data)
    } catch let decodingError as DecodingError {
      throw TailscaleClientError.decoding(decodingError, body: response.data, endpoint: endpoint)
    }
  }
}

/// Error namespace for the Swift Tailscale client.
public enum TailscaleClientError: Error, Sendable {
  /// Underlying transport failed to execute the request.
  case transport(TailscaleTransportError)
  /// LocalAPI returned a non-success status with the given payload.
  case unexpectedStatus(code: Int, body: Data, endpoint: String)
  /// LocalAPI responded successfully but the payload could not be decoded.
  case decoding(DecodingError, body: Data, endpoint: String)

  /// Returns a preview of the response body (up to 500 characters), useful for debugging.
  public var bodyPreview: String? {
    let data: Data
    switch self {
    case .transport:
      return nil
    case .unexpectedStatus(_, let body, _):
      data = body
    case .decoding(_, let body, _):
      data = body
    }
    guard let string = String(data: data, encoding: .utf8) else {
      return "<binary data: \(data.count) bytes>"
    }
    if string.count <= 500 {
      return string
    }
    return String(string.prefix(500)) + "... (\(string.count) chars total)"
  }
}

extension TailscaleClientError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .transport(let error):
      return "Transport error: \(error.description)"
    case .unexpectedStatus(let code, _, let endpoint):
      let statusMessage = Self.httpStatusMessage(for: code)
      return "LocalAPI returned HTTP \(code) (\(statusMessage)) for \(endpoint)"
    case .decoding(let error, _, let endpoint):
      return "Failed to decode response from \(endpoint): \(Self.decodingErrorSummary(error))"
    }
  }

  private static func httpStatusMessage(for code: Int) -> String {
    switch code {
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    case 502: return "Bad Gateway"
    case 503: return "Service Unavailable"
    default: return HTTPURLResponse.localizedString(forStatusCode: code)
    }
  }

  private static func decodingErrorSummary(_ error: DecodingError) -> String {
    switch error {
    case .keyNotFound(let key, let context):
      let path = context.codingPath.map(\.stringValue).joined(separator: ".")
      return "missing key '\(key.stringValue)' at path '\(path)'"
    case .typeMismatch(let type, let context):
      let path = context.codingPath.map(\.stringValue).joined(separator: ".")
      return "type mismatch (expected \(type)) at path '\(path)'"
    case .valueNotFound(let type, let context):
      let path = context.codingPath.map(\.stringValue).joined(separator: ".")
      return "null value (expected \(type)) at path '\(path)'"
    case .dataCorrupted(let context):
      let path = context.codingPath.map(\.stringValue).joined(separator: ".")
      return "corrupted data at path '\(path)': \(context.debugDescription)"
    @unknown default:
      return error.localizedDescription
    }
  }
}

extension TailscaleClientError: LocalizedError {
  public var errorDescription: String? { description }

  public var recoverySuggestion: String? {
    switch self {
    case .transport(let error):
      return error.recoverySuggestion
    case .unexpectedStatus(let code, _, _):
      switch code {
      case 401, 403:
        return
          "Check that your auth token is valid. For loopback connections, ensure TAILSCALE_LOCALAPI_AUTHKEY is set correctly."
      case 404:
        return
          "The requested endpoint may not be available in your Tailscale version. Check that tailscaled is up to date."
      case 500, 502, 503:
        return
          "The Tailscale daemon encountered an error. Check 'tailscale status' and daemon logs for details."
      default:
        return nil
      }
    case .decoding:
      return
        "This may indicate a Tailscale API change. Please report this issue at https://github.com/dweekly/swift-tailscale-client/issues with the response body."
    }
  }
}
