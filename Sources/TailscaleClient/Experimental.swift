// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

extension TailscaleClient {
  /// Wrappers over the daemon's unstable debug surfaces.
  ///
  /// Everything reachable through this namespace is **exempt from SemVer**:
  /// upstream marks these endpoints as debug interfaces that can change or
  /// vanish in any Tailscale release, and this package mirrors that stance
  /// (see the stability tiers in `ROADMAP.md`). Reach for them in
  /// diagnostics tooling; avoid them in production app logic.
  public nonisolated var experimental: ExperimentalClient {
    ExperimentalClient(client: self)
  }
}

/// Experimental (SemVer-exempt) LocalAPI surfaces. Obtain via
/// ``TailscaleClient/experimental``.
public struct ExperimentalClient: Sendable {
  let client: TailscaleClient

  /// Logs a bug-report marker in the daemon's log stream and returns it —
  /// the same marker `tailscale bugreport` prints for support tickets.
  ///
  /// - Parameters:
  ///   - note: Optional note logged alongside the marker.
  ///   - diagnose: Ask the daemon to run its self-diagnostics and log the
  ///     findings.
  ///   - record: Enable verbose component debug logging for the next 12
  ///     hours (a second marker is returned for the recording window).
  /// - Returns: The marker text (one marker per line).
  /// - Throws: ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` when the
  ///   daemon was built without debug support; other `TailscaleClientError`
  ///   cases on failure.
  public func bugreport(
    note: String? = nil, diagnose: Bool = false, record: Bool = false
  ) async throws -> String {
    let endpoint = "/localapi/v0/bugreport"
    var queryItems: [URLQueryItem] = []
    if let note, !note.isEmpty {
      queryItems.append(URLQueryItem(name: "note", value: note))
    }
    if diagnose {
      queryItems.append(URLQueryItem(name: "diagnose", value: "true"))
    }
    if record {
      queryItems.append(URLQueryItem(name: "record", value: "true"))
    }
    let request = TailscaleRequest(method: "POST", path: endpoint, queryItems: queryItems)
    let marker = try await client.performRawRequest(
      request, endpoint: endpoint, optionalEndpoint: true, feature: "debug")
    return marker.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Dumps the stacks of every goroutine in the daemon — the moral
  /// equivalent of sampling a process, for "why is tailscaled stuck".
  ///
  /// - Returns: A plain-text stack dump.
  /// - Throws: `TailscaleClientError` on failure (403 when the LocalAPI
  ///   connection lacks write permission).
  public func goroutines() async throws -> String {
    let endpoint = "/localapi/v0/goroutines"
    let request = TailscaleRequest(path: endpoint)
    return try await client.performRawRequest(
      request, endpoint: endpoint, optionalEndpoint: true, feature: "debug")
  }

  /// Streams the daemon's live log output, one entry per line.
  ///
  /// The stream ends with an error if the connection drops; there is no
  /// automatic reconnection (this is a debug tap, not a monitoring API).
  ///
  /// - Returns: An async stream of ``LogtapEntry`` values.
  /// - Throws: ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` when the
  ///   daemon was built without logtail support; `.transport` if the
  ///   connection cannot be established.
  public func logtap() async throws -> AsyncThrowingStream<LogtapEntry, Error> {
    let endpoint = "/localapi/v0/logtap"
    let request = TailscaleRequest(path: endpoint)
    let configuration = client.configuration

    let lineStream: AsyncThrowingStream<Data, Error>
    do {
      lineStream = try await TailscaleClient.withDeadline(
        configuration.requestTimeout, endpoint: endpoint
      ) {
        try await configuration.transport.sendStreaming(request, configuration: configuration)
      }
    } catch let transportError as TailscaleTransportError {
      throw TailscaleClientError.transport(transportError)
    }

    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await lineData in lineStream {
            if let entry = try? JSONDecoder.tailscale().decode(LogtapEntry.self, from: lineData) {
              continuation.yield(entry)
            } else if let text = String(data: lineData, encoding: .utf8), !text.isEmpty {
              // Tolerate non-JSON lines by wrapping them verbatim.
              continuation.yield(LogtapEntry(text: text))
            }
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: TailscaleClient.mapStreamError(error))
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
}

/// One line of daemon log output from ``ExperimentalClient/logtap()``.
public struct LogtapEntry: Codable, Sendable, Equatable {
  /// The log line text (typically newline-terminated).
  public var text: String

  /// Creates an instance for tests, previews, or fixtures.
  public init(text: String) {
    self.text = text
  }

  private enum CodingKeys: String, CodingKey {
    case text
  }
}
