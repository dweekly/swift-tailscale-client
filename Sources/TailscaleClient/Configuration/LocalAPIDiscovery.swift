// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Captures how the client should connect to the Tailscale daemon.
public enum TailscaleEndpoint: Sendable, Equatable, CustomStringConvertible {
  /// Connect via a Unix domain socket at the supplied path.
  case unixSocket(path: String)
  /// Connect via an HTTP server reachable on the local loopback interface.
  case loopback(host: String = "127.0.0.1", port: UInt16)
  /// Use a fully qualified base URL (primarily for testing and custom setups).
  case url(URL)

  public var description: String {
    switch self {
    case .unixSocket(let path):
      return "unixSocket(\(path))"
    case .loopback(let host, let port):
      return "loopback(\(host):\(port))"
    case .url(let url):
      return "url(\(url.absoluteString))"
    }
  }
}

/// Locates the LocalAPI endpoint for the current machine.
///
/// `TailscaleClientConfiguration.default` runs this automatically; use it
/// directly when an app needs to report *how* the daemon was found (which
/// socket path, loopback port, or environment override) or to drive discovery
/// with a custom environment.
///
/// ```swift
/// let result = LocalAPIDiscovery().discover()
/// print("Connecting via \(result.endpoint)")
/// ```
///
/// Set `TAILSCALE_DISCOVERY_DEBUG=1` to log each decision to stderr.
public struct LocalAPIDiscovery {
  /// The outcome of a discovery pass.
  public struct Result: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
  {
    /// Where to connect.
    public var endpoint: TailscaleEndpoint
    /// Auth token for loopback connections, when discovery found one.
    /// Treat this as a secret: it authenticates every LocalAPI request.
    public var authToken: String?
    /// Capability version to advertise (from `TAILSCALE_LOCALAPI_CAPABILITY`
    /// or the default).
    public var capabilityVersion: Int

    /// Never includes the auth token, so printing a discovery result cannot
    /// leak credential material.
    public var description: String {
      let token = authToken == nil ? "nil" : "<redacted>"
      return
        "LocalAPIDiscovery.Result(endpoint: \(endpoint), authToken: \(token), "
        + "capabilityVersion: \(capabilityVersion))"
    }

    public var debugDescription: String { description }

    /// `dump(_:)` and `Mirror` follow this instead of the stored properties,
    /// so the auth token cannot surface through reflection either.
    public var customMirror: Mirror {
      Mirror(
        self,
        children: [
          "endpoint": endpoint,
          "authToken": authToken == nil ? "nil" : "<redacted>",
          "capabilityVersion": capabilityVersion,
        ],
        displayStyle: .struct)
    }
  }

  private let environment: [String: String]
  private let fileExists: @Sendable (String) -> Bool
  private let allowMacOSAppStoreDiscovery: Bool
  internal let socketProber: (@Sendable (String) -> (isAlive: Bool, error: LocalAPIDiscoveryError?))?
  internal let standaloneDirectoryOverride: URL?
  internal let probeOverride: (@Sendable (UInt16, String) -> Bool)?

  /// Creates a new LocalAPI discovery instance.
  ///
  /// - Parameters:
  ///   - environment: Process environment dictionary (defaults to current process environment).
  ///   - fileExists: Function to check file existence (defaults to FileManager).
  ///   - allowMacOSAppStoreDiscovery: If `true`, enables scanning Group Containers for the
  ///     macOS App Store GUI's loopback API. This triggers a TCC permission popup. Defaults to `false`.
  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    allowMacOSAppStoreDiscovery: Bool = false
  ) {
    self.environment = environment
    self.fileExists = fileExists
    self.allowMacOSAppStoreDiscovery = allowMacOSAppStoreDiscovery
    self.socketProber = nil
    self.standaloneDirectoryOverride = nil
    self.probeOverride = nil
  }

  init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    allowMacOSAppStoreDiscovery: Bool = false,
    socketProber: (@Sendable (String) -> (isAlive: Bool, error: LocalAPIDiscoveryError?))? = nil,
    standaloneDirectoryOverride: URL? = nil,
    probeOverride: (@Sendable (UInt16, String) -> Bool)? = nil
  ) {
    self.environment = environment
    self.fileExists = fileExists
    self.allowMacOSAppStoreDiscovery = allowMacOSAppStoreDiscovery
    self.socketProber = socketProber
    self.standaloneDirectoryOverride = standaloneDirectoryOverride
    self.probeOverride = probeOverride
  }

  private func env(_ key: String) -> String? {
    if let value = environment[key], !value.isEmpty {
      return value
    }
    if key.hasPrefix("TAILSCALE_") {
      let tsKey = "TS_" + key.dropFirst("TAILSCALE_".count)
      if let value = environment[tsKey], !value.isEmpty {
        return value
      }
    }
    return nil
  }

  /// Runs discovery: environment overrides first, then known socket paths,
  /// then native macOS standalone .pkg discovery, then (opt-in) macOS App Store
  /// GUI discovery, then the default socket path.
  public func discover() -> Result {
    let capability =
      env("TAILSCALE_LOCALAPI_CAPABILITY").flatMap(Int.init) ?? Self.defaultCapability
    let debug = env("TAILSCALE_DISCOVERY_DEBUG") == "1"

    // 1. Explicit URL override
    if let urlString = env("TAILSCALE_LOCALAPI_URL"),
      let url = URL(string: urlString)
    {
      if debug { Self.debugLog("[LocalAPIDiscovery] using TAILSCALE_LOCALAPI_URL: \(urlString)") }
      return .init(
        endpoint: .url(url), authToken: env("TAILSCALE_LOCALAPI_AUTHKEY"),
        capabilityVersion: capability)
    }

    // 2. Explicit socket path override
    if let socketPath = env("TAILSCALE_LOCALAPI_SOCKET"), !socketPath.isEmpty {
      let expanded = Self.expandPath(socketPath)
      if debug {
        Self.debugLog("[LocalAPIDiscovery] using TAILSCALE_LOCALAPI_SOCKET: \(expanded)")
      }
      return .init(
        endpoint: .unixSocket(path: expanded),
        authToken: env("TAILSCALE_LOCALAPI_AUTHKEY"),
        capabilityVersion: capability)
    }

    // 3. Explicit port/host override
    if let portString = env("TAILSCALE_LOCALAPI_PORT"),
      let portValue = UInt16(portString)
    {
      let host = env("TAILSCALE_LOCALAPI_HOST") ?? "127.0.0.1"
      if debug {
        Self.debugLog("[LocalAPIDiscovery] using TAILSCALE_LOCALAPI_PORT: \(host):\(portValue)")
      }
      return .init(
        endpoint: .loopback(host: host, port: portValue),
        authToken: env("TAILSCALE_LOCALAPI_AUTHKEY"),
        capabilityVersion: capability)
    }

    // 4. Check for Unix sockets FIRST (no Group Container access, no scary popup)
    for candidate in Self.candidateSockets {
      let expanded = Self.expandPath(candidate.path)
      if fileExists(expanded) {
        if debug { Self.debugLog("[LocalAPIDiscovery] using Unix socket: \(expanded)") }
        return .init(
          endpoint: .unixSocket(path: expanded),
          authToken: candidate.authToken,
          capabilityVersion: capability)
      }
    }

    // 5. Native macOS standalone (.pkg) app discovery (PR 08, default, no TCC)
    #if os(macOS)
      let standalonePath =
        standaloneDirectoryOverride?.path ?? env("TAILSCALE_STANDALONE_DIR")
        ?? "/Library/Tailscale"
      if standaloneDirectoryOverride != nil || fileExists(standalonePath) {
        var standaloneInfo = MacClientInfo()
        if let standaloneDirectoryOverride {
          standaloneInfo.standaloneDirectoryOverride = standaloneDirectoryOverride
        }
        if let probeOverride {
          standaloneInfo.probeOverride = probeOverride
        }
        if let standalone = standaloneInfo.locateStandalone() {
          if debug {
            Self.debugLog(
              "[LocalAPIDiscovery] using macOS standalone pkg loopback port=\(standalone.port)")
          }
          return .init(
            endpoint: .loopback(host: "127.0.0.1", port: standalone.port),
            authToken: standalone.token,
            capabilityVersion: capability)
        }
      }
    #endif

    // 6. macOS App Store GUI loopback (requires Group Container access - triggers TCC popup)
    #if os(macOS)
      if allowMacOSAppStoreDiscovery {
        if debug {
          Self.debugLog(
            "[LocalAPIDiscovery] attempting macOS App Store discovery (TCC popup may appear)")
        }
        if let mac = MacClientInfo().locateSameUserProof() {
          if debug {
            // The token authenticates LocalAPI requests: never log any part
            // of it. Port + redacted source are enough to diagnose discovery.
            Self.debugLog(
              "[LocalAPIDiscovery] using macOS loopback port=\(mac.port) "
                + "source=\(DiscoveryLog.redactedProofPath(mac.source))")
          }
          return .init(
            endpoint: .loopback(host: "127.0.0.1", port: mac.port),
            authToken: mac.token,
            capabilityVersion: capability)
        }
      } else if debug {
        Self.debugLog(
          "[LocalAPIDiscovery] skipping macOS App Store discovery (opt-in flag disabled)")
      }
    #endif

    // 7. Final fallback to default socket path
    if debug {
      Self.debugLog(
        "[LocalAPIDiscovery] falling back to default socket: \(Self.defaultSocketPath)")
    }
    return .init(
      endpoint: .unixSocket(path: Self.expandPath(Self.defaultSocketPath)),
      authToken: nil,
      capabilityVersion: capability)
  }

  /// Asynchronously locates the LocalAPI endpoint for the current machine,
  /// executing filesystem and socket probes off the calling actor.
  ///
  /// - Returns: The discovery result containing the endpoint, auth token, and capability version.
  /// - Throws: `LocalAPIDiscoveryError` if candidate discovery fails or is stopped/inaccessible.
  public func discoverAsync() async throws -> Result {
    let capability =
      env("TAILSCALE_LOCALAPI_CAPABILITY").flatMap(Int.init) ?? Self.defaultCapability
    let debug = env("TAILSCALE_DISCOVERY_DEBUG") == "1"

    // 1. Explicit URL override (fast in-memory check)
    if let urlString = env("TAILSCALE_LOCALAPI_URL"),
      let url = URL(string: urlString)
    {
      if debug { Self.debugLog("[LocalAPIDiscovery] using TAILSCALE_LOCALAPI_URL: \(urlString)") }
      return .init(
        endpoint: .url(url), authToken: env("TAILSCALE_LOCALAPI_AUTHKEY"),
        capabilityVersion: capability)
    }

    // 2. Explicit socket path override
    if let socketPath = env("TAILSCALE_LOCALAPI_SOCKET"), !socketPath.isEmpty {
      let expanded = Self.expandPath(socketPath)
      if debug {
        Self.debugLog("[LocalAPIDiscovery] using TAILSCALE_LOCALAPI_SOCKET: \(expanded)")
      }
      return .init(
        endpoint: .unixSocket(path: expanded),
        authToken: env("TAILSCALE_LOCALAPI_AUTHKEY"),
        capabilityVersion: capability)
    }

    // 3. Explicit port/host override
    if let portString = env("TAILSCALE_LOCALAPI_PORT"),
      let portValue = UInt16(portString)
    {
      let host = env("TAILSCALE_LOCALAPI_HOST") ?? "127.0.0.1"
      if debug {
        Self.debugLog("[LocalAPIDiscovery] using TAILSCALE_LOCALAPI_PORT: \(host):\(portValue)")
      }
      return .init(
        endpoint: .loopback(host: host, port: portValue),
        authToken: env("TAILSCALE_LOCALAPI_AUTHKEY"),
        capabilityVersion: capability)
    }

    // 4. Offload filesystem and socket probing to a detached task
    return try await Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      var candidateError: LocalAPIDiscoveryError?

      // 4a. Unix sockets scan
      for candidate in Self.candidateSockets {
        try Task.checkCancellation()
        let expanded = Self.expandPath(candidate.path)
        if self.fileExists(expanded) {
          if let prober = self.socketProber {
            let (isAlive, err) = prober(expanded)
            if isAlive {
              if debug { Self.debugLog("[LocalAPIDiscovery] using probed Unix socket: \(expanded)") }
              return Result(
                endpoint: .unixSocket(path: expanded),
                authToken: candidate.authToken,
                capabilityVersion: capability)
            } else if let err {
              candidateError = err
            }
          } else {
            let (isAlive, err) = Self.probeUnixSocket(path: expanded, fileExistsCheck: self.fileExists)
            if isAlive {
              if debug { Self.debugLog("[LocalAPIDiscovery] using live Unix socket: \(expanded)") }
              return Result(
                endpoint: .unixSocket(path: expanded),
                authToken: candidate.authToken,
                capabilityVersion: capability)
            } else if let err {
              candidateError = err
            }
          }
        }
      }

      #if os(macOS)
        try Task.checkCancellation()
        // 4b. Native macOS standalone (.pkg) app discovery (PR 08, default)
        let standalonePath =
          self.standaloneDirectoryOverride?.path ?? self.env("TAILSCALE_STANDALONE_DIR")
          ?? "/Library/Tailscale"
        if self.standaloneDirectoryOverride != nil || self.fileExists(standalonePath) {
          var standaloneInfo = MacClientInfo()
          if let dir = self.standaloneDirectoryOverride {
            standaloneInfo.standaloneDirectoryOverride = dir
          }
          if let probe = self.probeOverride {
            standaloneInfo.probeOverride = probe
          }
          let standaloneResult = await standaloneInfo.inspectStandaloneAsync()
          switch standaloneResult {
          case .ok(let res):
            if debug {
              Self.debugLog("[LocalAPIDiscovery] using standalone pkg loopback port=\(res.port)")
            }
            return Result(
              endpoint: .loopback(host: "127.0.0.1", port: res.port),
              authToken: res.token,
              capabilityVersion: capability)
          case .stopped(let endpoint):
            if candidateError == nil { candidateError = .stopped(candidate: endpoint) }
          case .inaccessible(let path, let reason):
            if candidateError == nil { candidateError = .inaccessible(path: path, reason: reason) }
          case .invalidCredentials(let endpoint):
            if candidateError == nil { candidateError = .invalidCredentials(endpoint: endpoint) }
          case .notInstalled:
            break
          }
        }

        try Task.checkCancellation()
        // 4c. macOS App Store GUI loopback (requires opt-in)
        if self.allowMacOSAppStoreDiscovery {
          if debug {
            Self.debugLog("[LocalAPIDiscovery] attempting macOS App Store discovery")
          }
          if let mac = await MacClientInfo().locateSameUserProofAsync() {
            if debug {
              Self.debugLog(
                "[LocalAPIDiscovery] using macOS loopback port=\(mac.port) "
                  + "source=\(DiscoveryLog.redactedProofPath(mac.source))")
            }
            return Result(
              endpoint: .loopback(host: "127.0.0.1", port: mac.port),
              authToken: mac.token,
              capabilityVersion: capability)
          }
        }
      #endif

      // 4d. If no live candidate answered, throw actionable error
      if let candidateError {
        throw candidateError
      }
      throw LocalAPIDiscoveryError.notInstalled
    }.value
  }

  #if canImport(Darwin) || canImport(Glibc)
    private static func probeUnixSocket(
      path: String,
      fileExistsCheck: (String) -> Bool
    ) -> (isAlive: Bool, error: LocalAPIDiscoveryError?) {
      // If the file does not exist on disk according to FileManager,
      // but fileExistsCheck returned true, it's an injected test mock.
      if !FileManager.default.fileExists(atPath: path) && fileExistsCheck(path) {
        return (true, nil)
      }

      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else {
        return (false, nil)
      }
      defer { close(fd) }

      let flags = fcntl(fd, F_GETFL, 0)
      _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
      guard path.utf8.count < maxPath else {
        return (false, .inaccessible(path: path, reason: "Socket path too long"))
      }
      _ = path.withCString { cstr in
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
          strncpy(ptr, cstr, maxPath - 1)
        }
      }

      let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }

      if connectResult == 0 {
        return (true, nil)
      }

      let err = errno
      if err == EISCONN {
        return (true, nil)
      } else if err == EINPROGRESS || err == EWOULDBLOCK || err == EAGAIN {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pfd, 1, 100)
        if pollResult > 0 {
          var socketError: Int32 = 0
          var len = socklen_t(MemoryLayout<Int32>.size)
          getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &len)
          if socketError == 0 {
            return (true, nil)
          } else if socketError == ECONNREFUSED {
            return (false, .stopped(candidate: .unixSocket(path: path)))
          } else if socketError == EACCES || socketError == EPERM {
            return (false, .inaccessible(path: path, reason: "Permission denied"))
          }
        }
        return (false, .stopped(candidate: .unixSocket(path: path)))
      } else if err == ECONNREFUSED {
        return (false, .stopped(candidate: .unixSocket(path: path)))
      } else if err == EACCES || err == EPERM {
        return (false, .inaccessible(path: path, reason: "Permission denied"))
      }
      return (false, .stopped(candidate: .unixSocket(path: path)))
    }
  #else
    private static func probeUnixSocket(
      path: String,
      fileExistsCheck: (String) -> Bool
    ) -> (isAlive: Bool, error: LocalAPIDiscoveryError?) {
      return (true, nil)
    }
  #endif

  private func defaultSocketFallback() -> (path: String, authToken: String?) {
    for candidate in Self.candidateSockets {
      let expanded = Self.expandPath(candidate.path)
      if fileExists(expanded) {
        return (expanded, candidate.authToken)
      }
    }
    return (Self.expandPath(Self.defaultSocketPath), nil)
  }

  private static func debugLog(_ message: String) {
    DiscoveryLog.emit(message)
  }

  private static func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
  }

  private static let defaultCapability =
    TailscaleClientConfiguration.defaultCapabilityVersion
  private static let defaultSocketPath = "/var/run/tailscale/tailscaled.sock"

  private static let candidateSockets: [(path: String, authToken: String?)] = [
    // Homebrew tailscaled (no Group Container access needed!)
    ("/var/run/tailscaled.socket", nil),
    // System Extension (MDM-managed)
    ("/Library/Tailscale/Data/tailscaled.sock", nil),
    // User-level tailscaled
    ("~/Library/Application Support/Tailscale/tailscaled.sock", nil),
    // Linux systemd runtime directory
    ("/run/tailscale/tailscaled.sock", nil),
    // Linux/older macOS convention
    ("/var/run/tailscale/tailscaled.sock", nil),
  ]
}

extension LocalAPIDiscovery: Sendable, Equatable {
  public static func == (lhs: LocalAPIDiscovery, rhs: LocalAPIDiscovery) -> Bool {
    lhs.environment == rhs.environment
      && lhs.allowMacOSAppStoreDiscovery == rhs.allowMacOSAppStoreDiscovery
  }
}
