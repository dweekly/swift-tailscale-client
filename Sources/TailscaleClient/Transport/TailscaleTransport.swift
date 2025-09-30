import Foundation

/// Represents an HTTP request against the LocalAPI.
public struct TailscaleRequest: Sendable {
  public var method: String
  public var path: String
  public var queryItems: [URLQueryItem]
  public var body: Data?
  public var additionalHeaders: [String: String]

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

public struct TailscaleResponse: Sendable {
  public var statusCode: Int
  public var data: Data
  public var headers: [String: String]

  public init(statusCode: Int, data: Data, headers: [String: String] = [:]) {
    self.statusCode = statusCode
    self.data = data
    self.headers = headers
  }
}

public protocol TailscaleTransport: Sendable {
  func send(_ request: TailscaleRequest, configuration: TailscaleClientConfiguration) async throws
    -> TailscaleResponse
}

public enum TailscaleTransportError: Error, Sendable {
  case unimplemented
  case invalidURL
  case networkFailure(underlying: Error)
}

public struct URLSessionTailscaleTransport: TailscaleTransport {
  private let session: URLSession

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
    request.additionalHeaders.forEach { key, value in
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
