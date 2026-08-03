// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

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

  /// Fetches the DERP relay map the daemon is currently using.
  ///
  /// DERP servers relay traffic between peers that cannot connect directly.
  /// The map lists every region and relay node the daemon knows about; combine
  /// it with `StatusResponse.selfNode?.relay` to identify the home region.
  ///
  /// - Returns: The parsed response from `/localapi/v0/derpmap`.
  /// - Throws: `TailscaleClientError` if the request fails.
  public func derpMap() async throws -> DERPMap {
    let endpoint = "/localapi/v0/derpmap"
    let request = TailscaleRequest(path: endpoint)
    return try await performRequest(request, endpoint: endpoint)
  }

  /// Asks the daemon which exit node it would recommend right now.
  ///
  /// The suggestion weighs measured DERP latency and location metadata — the
  /// same logic behind `tailscale exit-node suggest`. The daemon reports an
  /// error (surfaced as ``TailscaleClientError/unexpectedStatus(code:body:endpoint:)``)
  /// when the tailnet has no exit nodes to suggest.
  ///
  /// - Parameter forceProbe: When `true`, asks the daemon to re-probe the
  ///   network before answering (slower, fresher; requires Tailscale 1.86+).
  ///   The default reuses the daemon's most recent measurements and works on
  ///   older daemons too.
  /// - Returns: The suggested exit node.
  /// - Throws: ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` when the
  ///   daemon was built without exit-node support; other `TailscaleClientError`
  ///   cases on failure.
  public func suggestExitNode(forceProbe: Bool = false) async throws -> ExitNodeSuggestion {
    let endpoint = "/localapi/v0/suggest-exit-node"
    let request: TailscaleRequest
    if forceProbe {
      request = TailscaleRequest(
        method: "POST",
        path: endpoint,
        queryItems: [URLQueryItem(name: "probe", value: "true")]
      )
    } else {
      request = TailscaleRequest(path: endpoint)
    }
    return try await performRequest(
      request, endpoint: endpoint, optionalEndpoint: true, feature: "use-exit-node")
  }

  /// Fetches user-facing metrics in Prometheus exposition format.
  ///
  /// Unlike ``metrics()`` (internal implementation counters), these are the
  /// stable, documented metrics behind `tailscale metrics print` — bytes
  /// routed, health status, advertised routes, and so on.
  ///
  /// - Returns: Raw metrics text in Prometheus format.
  /// - Throws: ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` when the
  ///   daemon predates user metrics (Tailscale < 1.78); other
  ///   `TailscaleClientError` cases on failure.
  public func userMetrics() async throws -> String {
    let endpoint = "/localapi/v0/usermetrics"
    let request = TailscaleRequest(path: endpoint)
    return try await performRawRequest(request, endpoint: endpoint, optionalEndpoint: true)
  }

  /// Applies a partial preferences update and returns the resulting prefs.
  ///
  /// This is the first **write** API: it changes daemon state (the same
  /// mechanism behind `tailscale set`). Only the fields set on `masked` are
  /// touched; everything else is preserved. Validate risky changes first
  /// with ``checkPrefs(_:)``.
  ///
  /// - Parameter masked: The fields to change; see ``MaskedPrefs``.
  /// - Returns: The daemon's full updated ``Prefs``.
  /// - Throws: `TailscaleClientError` if the request fails —
  ///   `.unexpectedStatus(400, …)` carries the daemon's validation message.
  public func editPrefs(_ masked: MaskedPrefs) async throws -> Prefs {
    let endpoint = "/localapi/v0/prefs"
    let body = try JSONEncoder().encode(masked)
    let request = TailscaleRequest(method: "PATCH", path: endpoint, body: body)
    return try await performRequest(request, endpoint: endpoint)
  }

  /// Asks the daemon whether a full preferences object would be valid,
  /// without applying it.
  ///
  /// - Parameter prefs: The complete preferences to validate.
  /// - Throws: ``TailscaleClientError/unexpectedStatus(code:body:endpoint:)`` with the
  ///   daemon's explanation when the prefs are invalid (the daemon reports
  ///   validation failures as HTTP 200 with an `Error` field, surfaced here
  ///   as `unexpectedStatus(200, <reason>, …)`); nothing on success.
  public func checkPrefs(_ prefs: Prefs) async throws {
    let endpoint = "/localapi/v0/check-prefs"
    let body = try JSONEncoder().encode(prefs)
    let request = TailscaleRequest(method: "POST", path: endpoint, body: body)
    let raw = try await performRawRequest(request, endpoint: endpoint)
    // The daemon answers 200 even for invalid prefs, with the reason in
    // {"Error": "..."} — an empty or absent Error means valid.
    struct CheckResult: Decodable {
      let error: String?
      enum CodingKeys: String, CodingKey { case error = "Error" }
    }
    if let data = raw.data(using: .utf8),
      let result = try? JSONDecoder().decode(CheckResult.self, from: data),
      let reason = result.error, !reason.isEmpty
    {
      throw TailscaleClientError.unexpectedStatus(
        code: 200, body: Data(reason.utf8), endpoint: endpoint)
    }
  }

  /// Toggles use of the currently-selected exit node without forgetting
  /// which node was selected — the daemon remembers the prior choice when
  /// re-enabling.
  ///
  /// - Parameter enabled: Whether traffic should flow through the exit node.
  /// - Returns: The daemon's full updated ``Prefs``.
  /// - Throws: ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` when the
  ///   daemon was built without exit-node support; other
  ///   `TailscaleClientError` cases on failure (including 400 when no exit
  ///   node was ever selected).
  public func setUseExitNode(enabled: Bool) async throws -> Prefs {
    let endpoint = "/localapi/v0/set-use-exit-node-enabled"
    let request = TailscaleRequest(
      method: "POST",
      path: endpoint,
      queryItems: [URLQueryItem(name: "enabled", value: enabled ? "true" : "false")])
    return try await performRequest(
      request, endpoint: endpoint, optionalEndpoint: true, feature: "use-exit-node")
  }

  /// Asks the control plane to expire this node's key sooner than scheduled
  /// — the mechanism behind `tailscale logout`-adjacent key hygiene.
  ///
  /// - Parameter expiry: The new expiry time; must be earlier than the
  ///   current one (the daemon rejects extensions).
  /// - Throws: `TailscaleClientError` if the request fails.
  public func setExpirySooner(_ expiry: Date) async throws {
    let endpoint = "/localapi/v0/set-expiry-sooner"
    let request = TailscaleRequest(
      method: "POST",
      path: endpoint,
      queryItems: [
        URLQueryItem(name: "expiry", value: String(Int(expiry.timeIntervalSince1970)))
      ])
    _ = try await performRawRequest(request, endpoint: endpoint)
  }

  /// Asks a config-file-driven daemon to reload its configuration file.
  ///
  /// - Returns: The reload outcome; ``ReloadConfigResult/reloaded`` is
  ///   `false` when the daemon is not in config-file mode.
  /// - Throws: `TailscaleClientError` if the request fails; a failed reload
  ///   is reported in ``ReloadConfigResult/error`` rather than thrown.
  public func reloadConfig() async throws -> ReloadConfigResult {
    let endpoint = "/localapi/v0/reload-config"
    let request = TailscaleRequest(method: "POST", path: endpoint)
    return try await performRequest(request, endpoint: endpoint)
  }

  /// Starts (or restarts) the backend with the given options — required
  /// once after connecting to a daemon that has never been configured, and
  /// the vehicle for headless auth-key bring-up.
  ///
  /// - Parameter options: Start options; the default starts with stored
  ///   preferences.
  /// - Throws: `TailscaleClientError` if the request fails (500 when the
  ///   daemon's state store is unhealthy).
  public func start(options: StartOptions = StartOptions()) async throws {
    let endpoint = "/localapi/v0/start"
    let body = try JSONEncoder().encode(options)
    let request = TailscaleRequest(method: "POST", path: endpoint, body: body)
    _ = try await performRawRequest(request, endpoint: endpoint)
  }

  /// Begins an interactive login: the control plane responds with a URL the
  /// user must open, delivered as `browseToURL` on the IPN bus.
  ///
  /// Watch ``watchIPNBus(options:reconnect:onUndecodableLine:)`` for
  /// ``IPNNotify/browseToURL`` before calling this, then open the URL for
  /// the user. Returns immediately (204); completion arrives as a state
  /// change on the bus.
  ///
  /// - Throws: `TailscaleClientError` if the request fails.
  public func loginInteractive() async throws {
    let endpoint = "/localapi/v0/login-interactive"
    _ = try await performRawRequest(
      TailscaleRequest(method: "POST", path: endpoint), endpoint: endpoint)
  }

  /// Logs this node out of the tailnet, expiring its keys. **Destructive**:
  /// re-authentication is required afterward.
  ///
  /// - Throws: `TailscaleClientError` if the request fails.
  public func logout() async throws {
    let endpoint = "/localapi/v0/logout"
    _ = try await performRawRequest(
      TailscaleRequest(method: "POST", path: endpoint), endpoint: endpoint)
  }

  /// Resets the daemon's authentication state without contacting the
  /// control plane — the recovery hammer for a wedged login.
  ///
  /// - Throws: `TailscaleClientError` if the request fails.
  public func resetAuth() async throws {
    let endpoint = "/localapi/v0/reset-auth"
    _ = try await performRawRequest(
      TailscaleRequest(method: "POST", path: endpoint), endpoint: endpoint)
  }

  /// Lists all saved login profiles.
  public func profiles() async throws -> [LoginProfile] {
    let endpoint = "/localapi/v0/profiles/"
    return try await performRequest(TailscaleRequest(path: endpoint), endpoint: endpoint)
  }

  /// Fetches the currently active login profile.
  public func currentProfile() async throws -> LoginProfile {
    let endpoint = "/localapi/v0/profiles/current"
    return try await performRequest(TailscaleRequest(path: endpoint), endpoint: endpoint)
  }

  /// Creates a new (empty) login profile and switches to it; follow with
  /// ``loginInteractive()`` or ``start(options:)`` to authenticate it.
  public func addProfile() async throws {
    let endpoint = "/localapi/v0/profiles/"
    _ = try await performRawRequest(
      TailscaleRequest(method: "PUT", path: endpoint), endpoint: endpoint)
  }

  /// Switches to the profile with the given ID (see ``LoginProfile/id``).
  public func switchProfile(_ id: String) async throws {
    let endpoint = "/localapi/v0/profiles/\(id)"
    _ = try await performRawRequest(
      TailscaleRequest(method: "POST", path: endpoint), endpoint: endpoint)
  }

  /// Deletes the profile with the given ID. **Destructive.**
  public func deleteProfile(_ id: String) async throws {
    let endpoint = "/localapi/v0/profiles/\(id)"
    _ = try await performRawRequest(
      TailscaleRequest(method: "DELETE", path: endpoint), endpoint: endpoint)
  }

  /// Fetches an OIDC ID token for this node from the control plane.
  ///
  /// - Parameter audience: The token audience (`aud` claim).
  /// - Returns: The control plane's raw JSON response (shape is
  ///   control-plane defined; typically `{"id_token": "..."}`).
  /// - Throws: ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` when the
  ///   daemon was built without debug support; other `TailscaleClientError`
  ///   cases on failure.
  public func idToken(audience: String) async throws -> String {
    let endpoint = "/localapi/v0/id-token"
    let request = TailscaleRequest(
      method: "POST", path: endpoint,
      queryItems: [URLQueryItem(name: "aud", value: audience)])
    return try await performRawRequest(
      request, endpoint: endpoint, optionalEndpoint: true, feature: "debug")
  }

  /// Fetches the full netmap record for a peer by its numeric node ID.
  ///
  /// The numeric ID is `WhoIsNode.id` (or the `User`/`ID` fields seen on the
  /// IPN bus) — not the stable string ID shown in `status`. A 404 surfaces as
  /// ``TailscaleClientError/unexpectedStatus(code:body:endpoint:)`` and means the
  /// peer is not in the current netmap, not that the endpoint is missing.
  ///
  /// - Parameter id: The peer's numeric node ID.
  /// - Returns: The peer's `tailcfg.Node` record decoded as ``WhoIsNode``.
  /// - Throws: `TailscaleClientError` if the request fails.
  public func peer(byID id: UInt64) async throws -> WhoIsNode {
    let endpoint = "/localapi/v0/peer-by-id"
    let request = TailscaleRequest(
      path: endpoint, queryItems: [URLQueryItem(name: "id", value: String(id))])
    return try await performRequest(request, endpoint: endpoint)
  }

  /// Looks up a user profile by its numeric user ID.
  ///
  /// Useful for resolving the `UserID` references that appear on peer nodes
  /// (e.g., from the IPN bus or ``peer(byID:)``) into names. A 404 means the
  /// user is not known to the current netmap — or, on daemons that predate
  /// this 2026 endpoint, that the path itself is unknown (LocalAPI routing
  /// 404s unrecognized paths, so the two cases are indistinguishable).
  ///
  /// - Parameter id: The numeric user ID.
  /// - Returns: The ``UserProfile`` for that ID.
  /// - Throws: `TailscaleClientError` if the request fails.
  public func userProfile(byID id: UInt64) async throws -> UserProfile {
    let endpoint = "/localapi/v0/user-profile"
    let request = TailscaleRequest(
      path: endpoint, queryItems: [URLQueryItem(name: "id", value: String(id))])
    return try await performRequest(request, endpoint: endpoint)
  }

  /// Fetches the OS-level DNS configuration tailscaled has installed.
  ///
  /// - Returns: The parsed response from `/localapi/v0/dns-osconfig`.
  /// - Throws: ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` when the
  ///   daemon was built without DNS support; other `TailscaleClientError`
  ///   cases on failure.
  public func dnsOSConfig() async throws -> DNSOSConfig {
    let endpoint = "/localapi/v0/dns-osconfig"
    let request = TailscaleRequest(path: endpoint)
    return try await performRequest(
      request, endpoint: endpoint, optionalEndpoint: true, feature: "dns")
  }

  /// Resolves a name through tailscaled's internal DNS forwarder — the same
  /// path MagicDNS queries take, including split-DNS routing.
  ///
  /// The response carries the raw DNS answer (RFC 1035 wire format) plus the
  /// resolvers the forwarder chose for the name.
  ///
  /// - Parameters:
  ///   - name: The DNS name to resolve (e.g., `"peer.tailnet.ts.net"`).
  ///   - type: Record type (`"A"`, `"AAAA"`, `"TXT"`, `"CNAME"`, `"SRV"`, …).
  /// - Returns: The parsed response from `/localapi/v0/dns-query`.
  /// - Throws: ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` when the
  ///   daemon was built without DNS support; `.unexpectedStatus(400, …)` for
  ///   an unknown record type; other `TailscaleClientError` cases on failure.
  public func dnsQuery(name: String, type: String = "A") async throws -> DNSQueryResponse {
    let endpoint = "/localapi/v0/dns-query"
    let request = TailscaleRequest(
      path: endpoint,
      queryItems: [
        URLQueryItem(name: "name", value: name),
        URLQueryItem(name: "type", value: type),
      ])
    return try await performRequest(
      request, endpoint: endpoint, optionalEndpoint: true, feature: "dns")
  }

  /// Fetches the tailnet's DNS configuration from the current netmap —
  /// what the control plane wants DNS to be, versus ``dnsOSConfig()``
  /// which reports what is installed on the OS.
  ///
  /// - Returns: The parsed response from `/localapi/v0/dns-config`.
  /// - Throws: `TailscaleClientError` if the request fails
  ///   (`.unexpectedStatus(503, …)` when the daemon has no netmap yet).
  public func dnsConfig() async throws -> DNSConfig {
    let endpoint = "/localapi/v0/dns-config"
    return try await performRequest(TailscaleRequest(path: endpoint), endpoint: endpoint)
  }

  /// Checks whether the host is configured to forward IP traffic — the
  /// preflight for advertising subnet routes or acting as an exit node.
  ///
  /// - Returns: The parsed response from `/localapi/v0/check-ip-forwarding`;
  ///   ``IPForwardingCheck/isReady`` is `true` when nothing needs fixing.
  /// - Throws: ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` when the
  ///   daemon was built without route advertising; other
  ///   `TailscaleClientError` cases on failure.
  public func checkIPForwarding() async throws -> IPForwardingCheck {
    let endpoint = "/localapi/v0/check-ip-forwarding"
    let request = TailscaleRequest(path: endpoint)
    return try await performRequest(
      request, endpoint: endpoint, optionalEndpoint: true, feature: "advertise-routes")
  }

  /// Reports which optional features the connected daemon was compiled with.
  ///
  /// Modern tailscaled builds are modular: endpoint availability depends on the
  /// build, not just the version. Probe this before relying on optional
  /// surfaces (metrics, serve, Taildrop, ...) instead of treating a 404 as an
  /// error.
  ///
  /// ```swift
  /// let features = try await client.daemonFeatures()
  /// if features.isEnabled("serve") { /* safe to query serve-config */ }
  /// ```
  ///
  /// - Returns: The daemon's optional-feature map.
  /// - Throws: ``TailscaleClientError/endpointUnavailable(endpoint:feature:)`` when the
  ///   daemon predates this endpoint; other `TailscaleClientError` cases on failure.
  public func daemonFeatures() async throws -> OptionalFeatures {
    let endpoint = "/localapi/v0/debug-optional-features"
    let request = TailscaleRequest(method: "POST", path: endpoint)
    return try await performRequest(request, endpoint: endpoint, optionalEndpoint: true)
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
  /// An undecodable line never terminates the stream: it is skipped and, when
  /// provided, reported through `onUndecodableLine` — daemons routinely add
  /// notification fields this package hasn't modeled yet. A dropped connection
  /// terminates the stream with an error unless a `reconnect` policy is given,
  /// in which case the client re-dials with exponential backoff and the stream
  /// continues transparently (the daemon re-sends initial state per the watch
  /// options on each connection).
  ///
  /// - Parameters:
  ///   - options: Watch options controlling what notifications to receive.
  ///     Defaults to `.default` which includes initial state, health, and engine updates.
  ///   - reconnect: Opt-in automatic reconnection policy. `nil` (the default)
  ///     ends the stream on the first connection failure.
  ///   - onUndecodableLine: Called with the raw line and the decoding error for
  ///     each line that could not be decoded as an ``IPNNotify``.
  /// - Returns: An async stream of IPN notifications.
  /// - Throws: `TailscaleClientError` if the initial connection fails.
  public func watchIPNBus(
    options: NotifyWatchOpt = .default,
    reconnect: IPNBusReconnectPolicy? = nil,
    onUndecodableLine: (@Sendable (Data, TailscaleClientError) -> Void)? = nil
  ) async throws -> AsyncThrowingStream<IPNNotify, Error> {
    let endpoint = "/localapi/v0/watch-ipn-bus"
    let request = TailscaleRequest(
      path: endpoint,
      queryItems: [URLQueryItem(name: "mask", value: String(options.rawValue))]
    )

    let configuration = self.configuration
    let open: @Sendable () async throws -> AsyncThrowingStream<Data, Error> = {
      try await Self.withDeadline(configuration.requestTimeout, endpoint: endpoint) {
        try await configuration.transport.sendStreaming(request, configuration: configuration)
      }
    }

    // Establish the first connection before returning so callers get a thrown
    // error (not a poisoned stream) when the daemon is unreachable.
    let initialStream: AsyncThrowingStream<Data, Error>
    do {
      initialStream = try await open()
    } catch let transportError as TailscaleTransportError {
      throw TailscaleClientError.transport(transportError)
    }

    return AsyncThrowingStream { continuation in
      let task = Task {
        var stream: AsyncThrowingStream<Data, Error>? = initialStream
        var attempt = 0
        var lastError: (any Error)? = nil

        while true {
          if stream == nil {
            guard let policy = reconnect else {
              // Unreachable: stream is only cleared when a policy exists.
              continuation.finish()
              return
            }
            if let maxAttempts = policy.maxAttempts, attempt >= maxAttempts {
              continuation.finish(throwing: lastError.map(Self.mapStreamError))
              return
            }
            attempt += 1
            do {
              try await Task.sleep(for: policy.delay(forAttempt: attempt))
              stream = try await open()
            } catch is CancellationError {
              continuation.finish()
              return
            } catch {
              lastError = error
              stream = nil
              continue
            }
          }

          do {
            for try await lineData in stream! {
              do {
                let notify = try JSONDecoder.tailscale().decode(IPNNotify.self, from: lineData)
                attempt = 0
                continuation.yield(notify)
              } catch let decodingError as DecodingError {
                onUndecodableLine?(
                  lineData,
                  .decoding(decodingError, body: lineData, endpoint: endpoint))
              }
            }
            // Server closed the stream (e.g. daemon restart).
            if reconnect == nil {
              continuation.finish()
              return
            }
            stream = nil
            lastError = nil
          } catch is CancellationError {
            continuation.finish()
            return
          } catch {
            if reconnect == nil {
              continuation.finish(throwing: Self.mapStreamError(error))
              return
            }
            stream = nil
            lastError = error
          }
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  // MARK: - Private Helpers

  func performRawRequest(
    _ request: TailscaleRequest,
    endpoint: String,
    optionalEndpoint: Bool = false,
    feature: String? = nil
  ) async throws
    -> String
  {
    let response = try await executeWithDeadline(request, endpoint: endpoint)

    if optionalEndpoint, response.statusCode == 404 || response.statusCode == 501 {
      throw TailscaleClientError.endpointUnavailable(endpoint: endpoint, feature: feature)
    }
    // Write endpoints answer with other 2xx codes too (start returns 204).
    guard (200..<300).contains(response.statusCode) else {
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

  func performRequest<T: Decodable>(
    _ request: TailscaleRequest,
    endpoint: String,
    optionalEndpoint: Bool = false,
    feature: String? = nil
  ) async throws -> T {
    let response = try await executeWithDeadline(request, endpoint: endpoint)

    // Optional surfaces signal absence as 404 (endpoint not registered) or
    // 501 (registered, but the feature was compiled out of this build).
    if optionalEndpoint, response.statusCode == 404 || response.statusCode == 501 {
      throw TailscaleClientError.endpointUnavailable(endpoint: endpoint, feature: feature)
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

  private func executeWithDeadline(_ request: TailscaleRequest, endpoint: String) async throws
    -> TailscaleResponse
  {
    let configuration = self.configuration
    do {
      return try await Self.withDeadline(configuration.requestTimeout, endpoint: endpoint) {
        try await configuration.transport.send(request, configuration: configuration)
      }
    } catch let transportError as TailscaleTransportError {
      throw TailscaleClientError.transport(transportError)
    }
  }

  /// Races `operation` against the configured deadline, throwing
  /// `TailscaleClientError.timeout` if the deadline elapses first.
  static func withDeadline<T: Sendable>(
    _ timeout: Duration?,
    endpoint: String,
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    guard let timeout else { return try await operation() }
    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw TailscaleClientError.timeout(endpoint: endpoint)
      }
      guard let result = try await group.next() else {
        throw TailscaleClientError.timeout(endpoint: endpoint)
      }
      group.cancelAll()
      return result
    }
  }

  static func mapStreamError(_ error: any Error) -> any Error {
    if let clientError = error as? TailscaleClientError {
      return clientError
    }
    if let transportError = error as? TailscaleTransportError {
      return TailscaleClientError.transport(transportError)
    }
    return error
  }
}

/// Controls automatic re-dialing of the IPN bus after a dropped connection.
///
/// Delays grow exponentially from ``initialDelay`` (doubling per consecutive
/// failed attempt) and are capped at ``maxDelay``. The attempt counter resets
/// each time a notification is successfully received.
public struct IPNBusReconnectPolicy: Sendable, Equatable {
  /// Consecutive failed attempts before the stream gives up and throws the
  /// last error. `nil` retries indefinitely.
  public var maxAttempts: Int?
  /// Delay before the first reconnection attempt.
  public var initialDelay: Duration
  /// Upper bound on the backoff delay.
  public var maxDelay: Duration

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    maxAttempts: Int? = nil,
    initialDelay: Duration = .milliseconds(500),
    maxDelay: Duration = .seconds(30)
  ) {
    self.maxAttempts = maxAttempts
    self.initialDelay = initialDelay
    self.maxDelay = maxDelay
  }

  /// Indefinite retries, starting at 500 ms and capped at 30 s.
  public static let `default` = IPNBusReconnectPolicy()

  func delay(forAttempt attempt: Int) -> Duration {
    var delay = initialDelay
    var step = 1
    while step < attempt, delay < maxDelay {
      delay = delay * 2
      step += 1
    }
    return min(delay, maxDelay)
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
  /// The endpoint is not available on this daemon — it was compiled without the
  /// optional feature, or predates the endpoint entirely. `feature` names the
  /// upstream build feature when known.
  case endpointUnavailable(endpoint: String, feature: String?)
  /// The configured `requestTimeout` elapsed before the daemon responded.
  case timeout(endpoint: String)

  /// Returns a preview of the response body (up to 500 characters), useful for debugging.
  public var bodyPreview: String? {
    let data: Data
    switch self {
    case .transport, .endpointUnavailable, .timeout:
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
    case .endpointUnavailable(let endpoint, let feature):
      if let feature, !feature.isEmpty {
        return "Endpoint \(endpoint) is unavailable: daemon built without feature '\(feature)'"
      }
      return "Endpoint \(endpoint) is unavailable on this daemon"
    case .timeout(let endpoint):
      return "Request to \(endpoint) timed out"
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
    case .endpointUnavailable:
      return
        "Probe daemonFeatures() before calling optional endpoints, or update Tailscale to a build that includes this feature."
    case .timeout:
      return
        "The daemon did not respond in time. Check that tailscaled is responsive, or raise/disable TailscaleClientConfiguration.requestTimeout."
    }
  }
}
