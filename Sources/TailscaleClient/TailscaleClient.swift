// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Primary entry point for interacting with the Tailscale LocalAPI.
///
/// `TailscaleClient` provides async/await access to the Tailscale daemon's LocalAPI,
/// enabling Swift applications to query status, look up identities, test connectivity,
/// and fetch metrics without shelling out to the CLI.
///
/// ```swift
/// let client = TailscaleClient()
/// let status = try await client.status()
/// let ping = try await client.ping(ip: "100.64.0.5")
/// ```
///
/// > Important: This library is an unofficial, MIT-licensed project by David E. Weekly
/// > and is not endorsed by Tailscale Inc.
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
    return try await performRequest(request, endpoint: endpoint)
  }

  /// Looks up identity information for a Tailscale IP address or node key.
  ///
  /// - Parameter address: The Tailscale IP address (e.g., "100.64.0.1") or node key to look up.
  /// - Returns: The node and user profile information for the queried address.
  /// - Throws: `TailscaleClientError` if the lookup fails or the address is not found.
  public func whois(address: String) async throws -> WhoIsResponse {
    let endpoint = "/localapi/v0/whois"
    let request = TailscaleRequest(
      path: endpoint,
      queryItems: [URLQueryItem(name: "addr", value: address)]
    )
    return try await performRequest(request, endpoint: endpoint)
  }

  /// Fetches the current Tailscale preferences for this node.
  ///
  /// - Returns: The current preferences/configuration for the Tailscale node.
  /// - Throws: `TailscaleClientError` if the request fails.
  public func prefs() async throws -> Prefs {
    let endpoint = "/localapi/v0/prefs"
    let request = TailscaleRequest(path: endpoint)
    return try await performRequest(request, endpoint: endpoint)
  }

  /// Fetches Tailscale internal metrics in Prometheus exposition format.
  ///
  /// - Returns: Raw metrics text in Prometheus format.
  /// - Throws: `TailscaleClientError` if the request fails.
  public func metrics() async throws -> String {
    let endpoint = "/localapi/v0/metrics"
    let request = TailscaleRequest(path: endpoint)
    return try await performRawRequest(request, endpoint: endpoint)
  }

  /// Pings a Tailscale IP address to test connectivity.
  ///
  /// - Parameters:
  ///   - ip: The Tailscale IP address to ping.
  ///   - type: The type of ping to perform (default: disco).
  ///   - size: Optional packet size for disco pings.
  /// - Returns: The ping result including latency and connection details.
  /// - Throws: `TailscaleClientError` if the request fails.
  public func ping(ip: String, type: PingType = .disco, size: Int? = nil) async throws
    -> PingResult
  {
    let endpoint = "/localapi/v0/ping"
    var queryItems = [
      URLQueryItem(name: "ip", value: ip),
      URLQueryItem(name: "type", value: type.rawValue),
    ]
    if let size = size {
      queryItems.append(URLQueryItem(name: "size", value: String(size)))
    }
    let request = TailscaleRequest(method: "POST", path: endpoint, queryItems: queryItems)
    return try await performRequest(request, endpoint: endpoint)
  }

  /// Watches the IPN notification bus for real-time state changes.
  ///
  /// This streaming API provides instant notifications when Tailscale state changes,
  /// eliminating the need to poll the status endpoint.
  ///
  /// ```swift
  /// let client = TailscaleClient()
  /// for try await notify in client.watchIPNBus() {
  ///     if let state = notify.state {
  ///         print("Backend state: \(state)")
  ///     }
  ///     if let engine = notify.engine {
  ///         print("Traffic: ↓\(engine.rBytes) ↑\(engine.wBytes)")
  ///     }
  /// }
  /// ```
  ///
  /// - Parameter options: Watch options controlling what notifications to receive.
  ///   Defaults to `.default` which includes initial state, health, and engine updates.
  /// - Returns: An async stream of IPN notifications.
  /// - Throws: `TailscaleClientError` if the connection fails.
  public func watchIPNBus(options: NotifyWatchOpt = .default) async throws
    -> AsyncThrowingStream<IPNNotify, Error>
  {
    let endpoint = "/localapi/v0/watch-ipn-bus"
    let request = TailscaleRequest(
      path: endpoint,
      queryItems: [URLQueryItem(name: "mask", value: String(options.rawValue))]
    )

    let dataStream: AsyncThrowingStream<Data, Error>
    do {
      dataStream = try await configuration.transport.sendStreaming(
        request, configuration: configuration)
    } catch let transportError as TailscaleTransportError {
      throw TailscaleClientError.transport(transportError)
    }

    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await lineData in dataStream {
            do {
              let notify = try JSONDecoder.tailscale().decode(IPNNotify.self, from: lineData)
              continuation.yield(notify)
            } catch let decodingError as DecodingError {
              // Log decoding errors but continue - some messages may have unknown fields
              // In production, you might want to handle this differently
              #if DEBUG
                print("IPN bus decode error: \(decodingError)")
              #endif
              continuation.finish(
                throwing: TailscaleClientError.decoding(
                  decodingError, body: lineData, endpoint: endpoint))
              return
            }
          }
          continuation.finish()
        } catch {
          if let clientError = error as? TailscaleClientError {
            continuation.finish(throwing: clientError)
          } else if let transportError = error as? TailscaleTransportError {
            continuation.finish(throwing: TailscaleClientError.transport(transportError))
          } else {
            continuation.finish(throwing: error)
          }
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  // MARK: - Private Helpers

  private func performRawRequest(_ request: TailscaleRequest, endpoint: String) async throws
    -> String
  {
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

    guard let text = String(data: response.data, encoding: .utf8) else {
      throw TailscaleClientError.unexpectedStatus(
        code: response.statusCode,
        body: response.data,
        endpoint: endpoint
      )
    }
    return text
  }

  private func performRequest<T: Decodable>(_ request: TailscaleRequest, endpoint: String)
    async throws -> T
  {
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
      return try JSONDecoder.tailscale().decode(T.self, from: response.data)
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
