// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

// MARK: - Profile Management (v0.9.0, 1.0.0)

extension TailscaleClient {
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

  /// Creates a new, empty login profile and switches to it — the "sign out
  /// to a clean slate" move. Follow with ``loginInteractive()`` or
  /// ``start(options:)`` to authenticate it; the previous profile remains
  /// available via ``profiles()`` / ``switchProfile(_:)``.
  ///
  /// Mirrors upstream's stable `SwitchToEmptyProfile`
  /// (`PUT /localapi/v0/profiles/`); the daemon answers `201 Created`.
  public func switchToEmptyProfile() async throws {
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
}
