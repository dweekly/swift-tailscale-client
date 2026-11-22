// SPDX-License-Identifier: MIT
// Unofficial sample for swift-tailscale-client; not affiliated with Tailscale Inc.

import Foundation
import TailscaleClient

/// The three things Peer Diagnostics asks of a Tailscale daemon.
///
/// The view model talks only to this protocol, so it can run against the real daemon
/// (``LiveDaemon``), a built-in demo tailnet (``FixtureDaemon``), or a test double.
public protocol DaemonConnection: Sendable {
  /// A one-line, credential-free description of where this connection points,
  /// for example "unix socket /var/run/tailscaled.socket".
  var connectionSummary: String { get }

  /// Reads the daemon's current view of this node and its peers.
  func status() async throws -> StatusResponse

  /// Sends one disco ping to `ip` and returns the daemon's reply.
  func ping(ip: String) async throws -> PingResult

  /// Opens one watch on the daemon's event bus, including connection lifecycle events.
  func watchEvents() async throws -> AsyncThrowingStream<IPNBusEvent, Error>
}

/// What the sample subscribes to on the daemon's event bus.
///
/// The sample never reads notification payloads; any notification is only a cue to
/// re-read `status()`. So it asks for exactly the notifications that mean "something
/// about the peers or the node changed":
///
/// - `.initialState`: one notification as soon as the watch opens.
/// - `.peerChanges` (upstream `ipn.NotifyPeerChanges`): peer additions, removals, and
///   changes. Tailscale 1.104 and later send peer changes only to watchers that ask
///   for this option.
/// - `.noNetMap` (upstream `ipn.NotifyNoNetMap`): suppresses the large network-map
///   notifications older daemons send; ignored by 1.104 and later.
public let peerDiagnosticsWatchOptions: NotifyWatchOpt = [
  .initialState,
  .peerChanges,
  .noNetMap,
]

/// A ``DaemonConnection`` backed by the real Tailscale daemon through `TailscaleClient`.
public struct LiveDaemon: DaemonConnection {
  /// How long any single request to the daemon may take, including one ping.
  /// It bounds each unary request (status, ping) and the opening of the watch, not how long
  /// an established watch may stay quiet.
  ///
  /// Slightly longer than ``PingBurstPolicy/perPingTimeout`` on purpose: the view model's
  /// own timeout decides when a ping counts as unanswered, and this deadline guarantees the
  /// underlying request is torn down shortly after even if cancellation is not honored.
  public static let requestTimeout: Duration = .seconds(6)

  /// Reconnect policy for the watch: retry forever with the library's capped backoff.
  public static let watchRetryPolicy: StreamRetryPolicy = .default

  private let client: TailscaleClient
  private let retryPolicy: StreamRetryPolicy
  public let connectionSummary: String

  /// Wraps an existing client. Tests pass a client built on `MockTransport`.
  public init(client: TailscaleClient, retryPolicy: StreamRetryPolicy = LiveDaemon.watchRetryPolicy)
  {
    self.client = client
    self.retryPolicy = retryPolicy
    self.connectionSummary = LiveDaemon.describe(client.configuration.endpoint)
  }

  /// Finds the local daemon with the library's default asynchronous discovery.
  ///
  /// - Parameter allowMacOSAppStoreDiscovery: Also look for the Mac App Store edition of
  ///   Tailscale. Off by default because it can make macOS ask the user for permission to
  ///   read another app's data.
  public static func discover(allowMacOSAppStoreDiscovery: Bool) async throws -> LiveDaemon {
    let client = try await TailscaleClient.discover(
      allowMacOSAppStoreDiscovery: allowMacOSAppStoreDiscovery,
      requestTimeout: requestTimeout
    )
    return LiveDaemon(client: client)
  }

  public func status() async throws -> StatusResponse {
    try await client.status()
  }

  public func ping(ip: String) async throws -> PingResult {
    try await client.ping(ip: ip, type: .disco)
  }

  public func watchEvents() async throws -> AsyncThrowingStream<IPNBusEvent, Error> {
    try await client.watchIPNBusEvents(
      options: peerDiagnosticsWatchOptions, retryPolicy: retryPolicy)
  }

  /// Names the endpoint kind without credentials. A loopback endpoint's token is never
  /// part of the endpoint value; a socket path is printed as is.
  static func describe(_ endpoint: TailscaleEndpoint) -> String {
    switch endpoint {
    case .unixSocket(let path): return "unix socket \(path)"
    case .loopback(let host, let port): return "loopback \(host):\(port) (token not shown)"
    case .url(let url): return "URL host \(url.host ?? "unknown")"
    }
  }
}
