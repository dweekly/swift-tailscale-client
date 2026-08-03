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
/// Mirrors upstream `ipn.Options`; most callers need nothing (the daemon
/// starts with its stored preferences) or an auth key for headless
/// bring-up. To point a fresh or logged-out profile at a control server,
/// use ``TailscaleClient/startFreshProfile(controlURL:authKey:)``.
public struct StartOptions: Sendable, Equatable, Encodable {
  /// Auth key used to authenticate the node non-interactively.
  public var authKey: String?

  /// Preferences that **replace** the stored ones when the backend starts
  /// (upstream `ipn.Options.UpdatePrefs`; the daemon keeps only the saved
  /// login identity).
  ///
  /// Deliberately internal: this package's ``Prefs`` models a *subset* of
  /// upstream `ipn.Prefs`, so re-encoding a fetched snapshot here would
  /// silently zero every field Swift doesn't model (services advertisement,
  /// stateful filtering, remote config, drive shares, …). It is only safe
  /// on a profile with no preferences worth keeping — which is exactly the
  /// scope ``TailscaleClient/startFreshProfile(controlURL:authKey:)``
  /// exposes. Going public requires a lossless `Prefs` first (tracked in
  /// ROADMAP's pre-freeze audit).
  var updatePrefs: Prefs?

  /// Creates start options.
  public init(authKey: String? = nil) {
    self.authKey = authKey
  }

  /// Internal variant carrying `UpdatePrefs`; see `updatePrefs` for why
  /// this is not public.
  init(authKey: String? = nil, updatePrefs: Prefs?) {
    self.authKey = authKey
    self.updatePrefs = updatePrefs
  }

  private enum CodingKeys: String, CodingKey {
    case authKey = "AuthKey"
    case updatePrefs = "UpdatePrefs"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(authKey, forKey: .authKey)
    try container.encodeIfPresent(updatePrefs, forKey: .updatePrefs)
  }
}

/// Wire shape of `POST /localapi/v0/check-prefs`: HTTP 200 with an `Error`
/// field carrying the rejection reason (empty/absent when valid).
struct CheckPrefsResult: Decodable {
  let error: String?

  private enum CodingKeys: String, CodingKey {
    case error = "Error"
  }
}
