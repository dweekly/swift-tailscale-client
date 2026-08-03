// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

extension TailscaleClient {
  /// Wrappers over the daemon's debug surfaces.
  ///
  /// Everything reachable through this namespace is **exempt from SemVer**
  /// in *this package*: these are debug interfaces that can change or vanish
  /// between Tailscale releases, and this package mirrors that stance (see
  /// the stability tiers in `ROADMAP.md`). Upstream maturity varies per
  /// method — `BugReport`/`BugReportWithOpts` are upstream-stable, while
  /// `TailDaemonLogs` (logtap) is explicitly unstable and the rest carry no
  /// annotation; `Documentation/endpoints.json` records each one. Reach for
  /// this namespace in diagnostics tooling; avoid it in production app
  /// logic.
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
  ///   - record: Asks the daemon to start a bugreport recording. **Caveat:**
  ///     upstream's contract keeps the POST body open until the caller ends
  ///     the recording; this client sends a complete (empty) body, so the
  ///     daemon sees EOF and closes the recording window almost immediately.
  ///     A real recording handle is tracked in the stable-parity ledger
  ///     (`BugReportWithOpts`).
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

  /// Tells the daemon whether the client UI is currently visible — part of
  /// the contract Tailscale's own GUI clients use to tune notification and
  /// polling behavior.
  ///
  /// - Parameters:
  ///   - visible: Whether the UI is presented to the user.
  ///   - sessionID: The last `SessionID` received on the IPN bus, when known.
  /// - Throws: ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` on daemon
  ///   builds without this surface; other `TailscaleClientError` cases on failure.
  public func setGUIVisible(_ visible: Bool, sessionID: String? = nil) async throws {
    let endpoint = "/localapi/v0/set-gui-visible"
    var payload: [String: JSONValue] = ["IsVisible": .bool(visible)]
    if let sessionID { payload["SessionID"] = .string(sessionID) }
    let request = TailscaleRequest(
      method: "POST", path: endpoint, body: try JSONEncoder().encode(payload))
    _ = try await client.performRawRequest(
      request, endpoint: endpoint, optionalEndpoint: true, feature: "debug")
  }

  /// Registers an APNs/FCM push device token with the daemon so the control
  /// plane can wake this device.
  ///
  /// - Parameter token: The platform push token string.
  /// - Throws: ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` on daemon
  ///   builds without this surface; other `TailscaleClientError` cases on failure.
  public func setPushDeviceToken(_ token: String) async throws {
    let endpoint = "/localapi/v0/set-push-device-token"
    let payload: [String: JSONValue] = ["PushDeviceToken": .string(token)]
    let request = TailscaleRequest(
      method: "POST", path: endpoint, body: try JSONEncoder().encode(payload))
    _ = try await client.performRawRequest(
      request, endpoint: endpoint, optionalEndpoint: true, feature: "debug")
  }

  /// Forwards a received push-notification payload to the daemon.
  ///
  /// - Parameter payload: The push message body as arbitrary JSON.
  /// - Throws: ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` on daemon
  ///   builds without this surface; other `TailscaleClientError` cases on failure.
  public func handlePushMessage(_ payload: [String: JSONValue]) async throws {
    let endpoint = "/localapi/v0/handle-push-message"
    let request = TailscaleRequest(
      method: "POST", path: endpoint, body: try JSONEncoder().encode(payload))
    _ = try await client.performRawRequest(
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
