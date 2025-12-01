// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Represents an HTTP request against the LocalAPI.
public struct TailscaleRequest: Sendable {
  /// HTTP method (e.g., "GET", "POST").
  public var method: String
  /// Request path (e.g., "/localapi/v0/status").
  public var path: String
  /// URL query parameters to append to the request.
  public var queryItems: [URLQueryItem]
  /// Optional request body data.
  public var body: Data?
  /// Additional HTTP headers to include in the request.
  public var additionalHeaders: [String: String]

  /// Creates a new LocalAPI request.
  ///
  /// - Parameters:
  ///   - method: HTTP method (defaults to "GET").
  ///   - path: Request path relative to the LocalAPI base URL.
  ///   - queryItems: URL query parameters (defaults to empty array).
  ///   - body: Optional request body data (defaults to nil).
  ///   - additionalHeaders: Additional HTTP headers (defaults to empty dictionary).
  public init(
    method: String = "GET",
    path: String,
    queryItems: [URLQueryItem] = [],
    body: Data? = nil,
    additionalHeaders: [String: String] = [:]
  ) {
    self.method = method
    self.path = path
    self.queryItems = queryItems
    self.body = body
    self.additionalHeaders = additionalHeaders
  }
}

/// Represents an HTTP response from the LocalAPI.
public struct TailscaleResponse: Sendable {
  /// HTTP status code (e.g., 200, 404, 500).
  public var statusCode: Int
  /// Response body data.
  public var data: Data
  /// HTTP response headers.
  public var headers: [String: String]

  /// Creates a new LocalAPI response.
  ///
  /// - Parameters:
  ///   - statusCode: HTTP status code.
  ///   - data: Response body data.
  ///   - headers: HTTP response headers (defaults to empty dictionary).
  public init(statusCode: Int, data: Data, headers: [String: String] = [:]) {
    self.statusCode = statusCode
    self.data = data
    self.headers = headers
  }
}

/// Protocol for executing HTTP requests against the Tailscale LocalAPI.
///
/// Implementers handle the low-level communication with the LocalAPI,
/// including Unix domain sockets, TCP connections, and HTTP request/response handling.
public protocol TailscaleTransport: Sendable {
  /// Sends a request to the LocalAPI and returns the response.
  ///
  /// - Parameters:
  ///   - request: The request to send.
  ///   - configuration: Configuration containing endpoint and authentication details.
  /// - Returns: The response from the LocalAPI.
  /// - Throws: `TailscaleTransportError` if the request fails.
  func send(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration) async throws
    -> TailscaleResponse
}

/// Errors that can occur during LocalAPI transport operations.
public enum TailscaleTransportError: Error, Sendable {
  /// The requested transport method is not implemented.
  case unimplemented
  /// The URL could not be constructed from the provided components.
  case invalidURL
  /// A network error occurred. The underlying error provides additional details.
  case networkFailure(underlying: any Error & Sendable)
  /// The Unix socket could not be found or accessed.
  case socketNotFound(path: String)
  /// Connection to the LocalAPI was refused (daemon may not be running).
  case connectionRefused(endpoint: String)
  /// The response from the LocalAPI was malformed or could not be parsed.
  case malformedResponse(detail: String)
}

extension TailscaleTransportError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .unimplemented:
      return "Transport method not implemented on this platform"
    case .invalidURL:
      return "Could not construct valid URL from endpoint configuration"
    case .networkFailure(let underlying):
      return "Network failure: \(underlying.localizedDescription)"
    case .socketNotFound(let path):
      return
        "Unix socket not found at '\(path)'. Ensure tailscaled is running or set TAILSCALE_LOCALAPI_SOCKET to the correct path."
    case .connectionRefused(let endpoint):
      return
        "Connection refused to '\(endpoint)'. Ensure the Tailscale daemon is running and accessible."
    case .malformedResponse(let detail):
      return "Malformed response from LocalAPI: \(detail)"
    }
  }
}

extension TailscaleTransportError: LocalizedError {
  public var errorDescription: String? { description }

  public var recoverySuggestion: String? {
    switch self {
    case .unimplemented:
      return "This transport method is only available on macOS/iOS."
    case .invalidURL:
      return
        "Check your endpoint configuration. If using environment variables, verify TAILSCALE_LOCALAPI_URL or TAILSCALE_LOCALAPI_HOST/PORT are valid."
    case .networkFailure:
      return "Check your network connection and ensure the Tailscale daemon is running."
    case .socketNotFound:
      return
        "Run 'tailscale status' to verify tailscaled is running. For macOS App Store version, the client auto-discovers the loopback API."
    case .connectionRefused:
      return
        "Start the Tailscale daemon or app. On macOS, open Tailscale from Applications. On Linux, run 'sudo systemctl start tailscaled'."
    case .malformedResponse:
      return
        "This may indicate a version mismatch. Try updating swift-tailscale-client or check if your Tailscale version is supported."
    }
  }
}

/// Default transport implementation using `URLSession` for HTTP and a custom Unix socket transport.
///
/// This transport automatically selects the appropriate communication method based on the endpoint:
/// - Unix domain sockets use a custom `UnixSocketTransport`
/// - TCP loopback and custom URLs use `URLSession`
///
/// The transport automatically injects required headers including `Tailscale-Cap` and optional authentication.
public struct URLSessionTailscaleTransport: TailscaleTransport {
  private let session: URLSession

  /// Creates a new transport with the specified URLSession.
  ///
  /// - Parameter session: The URLSession to use for HTTP requests (defaults to `.shared`).
  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func send(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration)
    async throws -> TailscaleResponse
  {
    switch configuration.endpoint {
    case .unixSocket(let path):
      let unixRequest = enrich(request: request, configuration: configuration)
      let transport = UnixSocketTransport(path: path)
      return try await transport.send(
        unixRequest, capabilityVersion: configuration.capabilityVersion)
    case .loopback, .url:
      return try await sendViaURLSession(request: request, configuration: configuration)
    }
  }

  private func sendViaURLSession(
    request: TailscaleRequest, configuration: TailscaleClientConfiguration
  ) async throws -> TailscaleResponse {
    let urlRequest = try buildURLRequest(
      for: enrich(request: request, configuration: configuration), configuration: configuration)
    do {
      let (data, response) = try await session.data(for: urlRequest)
      guard let http = response as? HTTPURLResponse else {
        throw TailscaleTransportError.networkFailure(underlying: URLError(.badServerResponse))
      }
      let headers = http.allHeaderFields.reduce(into: [String: String]()) {
        partialResult, element in
        if let key = element.key as? String, let value = element.value as? String {
          partialResult[key] = value
        }
      }
      return TailscaleResponse(statusCode: http.statusCode, data: data, headers: headers)
    } catch {
      throw TailscaleTransportError.networkFailure(underlying: error)
    }
  }

  private func buildURLRequest(
    for request: TailscaleRequest, configuration: TailscaleClientConfiguration
  ) throws -> URLRequest {
    let url: URL
    switch configuration.endpoint {
    case .unixSocket:
      throw TailscaleTransportError.unimplemented
    case .loopback(let host, let port):
      var components = URLComponents()
      components.scheme = "http"
      components.host = host
      components.port = Int(port)
      components.path = request.path
      components.queryItems = request.queryItems.isEmpty ? nil : request.queryItems
      guard let resolved = components.url else {
        throw TailscaleTransportError.invalidURL
      }
      url = resolved
    case .url(let base):
      var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
      components?.path = request.path
      components?.queryItems = request.queryItems.isEmpty ? nil : request.queryItems
      guard let resolved = components?.url else {
        throw TailscaleTransportError.invalidURL
      }
      url = resolved
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    for (key, value) in request.additionalHeaders {
      urlRequest.setValue(value, forHTTPHeaderField: key)
    }
    return urlRequest
  }

  private func enrich(request: TailscaleRequest, configuration: TailscaleClientConfiguration)
    -> TailscaleRequest
  {
    var request = request
    var headers = request.additionalHeaders
    headers["Tailscale-Cap"] = String(configuration.capabilityVersion)
    if let token = configuration.authToken, !token.isEmpty,
      let data = ":\(token)".data(using: .utf8)
    {
      headers["Authorization"] = "Basic \(data.base64EncodedString())"
    }
    request.additionalHeaders = headers
    return request
  }
}
