// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// The result of asking a config-file-driven daemon to reload, from
/// `POST /localapi/v0/reload-config`.
///
/// Upstream: `apitype.ReloadConfigResponse`.
public struct ReloadConfigResult: Codable, Sendable, Equatable {
  /// Whether the configuration was reloaded. `false` (with no error) means
  /// the daemon is not running in config-file mode.
  public var reloaded: Bool

  /// The daemon's error message when the reload failed.
  public var error: String?

  /// Creates an instance for tests, previews, or fixtures.
  public init(reloaded: Bool = false, error: String? = nil) {
    self.reloaded = reloaded
    self.error = error
  }

  private enum CodingKeys: String, CodingKey {
    case reloaded = "Reloaded"
    case error = "Err"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    reloaded = try container.decodeIfPresent(Bool.self, forKey: .reloaded) ?? false
    error = try container.decodeIfPresent(String.self, forKey: .error)
  }
}

/// Options for ``TailscaleClient/start(options:)``.
///
/// Mirrors the useful subset of `ipn.Options`; most callers need nothing
/// (the daemon starts with its stored preferences) or just an auth key for
/// headless bring-up.
public struct StartOptions: Sendable, Equatable, Encodable {
  /// Auth key used to authenticate the node non-interactively.
  public var authKey: String?

  /// Creates start options.
  public init(authKey: String? = nil) {
    self.authKey = authKey
  }

  private enum CodingKeys: String, CodingKey {
    case authKey = "AuthKey"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(authKey, forKey: .authKey)
  }
}
