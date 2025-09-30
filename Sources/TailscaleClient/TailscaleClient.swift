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
    let request = TailscaleRequest(path: "/localapi/v0/status", queryItems: query.queryItems)
    let response: TailscaleResponse
    do {
      response = try await configuration.transport.send(request, configuration: configuration)
    } catch let transportError as TailscaleTransportError {
      throw TailscaleClientError.transport(transportError)
    }

    guard response.statusCode == 200 else {
      throw TailscaleClientError.unexpectedStatus(code: response.statusCode, body: response.data)
    }

    do {
      return try JSONDecoder.tailscale().decode(StatusResponse.self, from: response.data)
    } catch let decodingError as DecodingError {
      throw TailscaleClientError.decoding(decodingError, body: response.data)
    }
  }
}

/// Error namespace for the Swift Tailscale client.
public enum TailscaleClientError: Error {
  /// Underlying transport failed to execute the request.
  case transport(TailscaleTransportError)
  /// LocalAPI returned a non-success status with the given payload.
  case unexpectedStatus(code: Int, body: Data)
  /// LocalAPI responded successfully but the payload could not be decoded.
  case decoding(DecodingError, body: Data)
}
