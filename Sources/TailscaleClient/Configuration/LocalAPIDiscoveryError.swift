// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Actionable error classification for LocalAPI discovery failures.
public enum LocalAPIDiscoveryError: Error, Sendable, Equatable, LocalizedError {
  /// No Tailscale installation was detected on the system.
  case notInstalled

  /// A Tailscale daemon is installed but appears to be stopped or not listening on its socket/port.
  case stopped(candidate: TailscaleEndpoint)

  /// A Tailscale endpoint exists but cannot be accessed due to filesystem permissions or sandbox restrictions.
  case inaccessible(path: String, reason: String)

  /// The endpoint responded, but the authentication credentials were missing, corrupted, or rejected (HTTP 401/403).
  case invalidCredentials(endpoint: TailscaleEndpoint)

  public var errorDescription: String? {
    switch self {
    case .notInstalled:
      return "No Tailscale installation detected on this system"
    case .stopped(let candidate):
      return "Tailscale daemon is stopped or not answering on \(candidate)"
    case .inaccessible(let path, let reason):
      return
        "Tailscale endpoint at '\(DiscoveryLog.redactedProofPath(path))' is inaccessible: \(reason)"
    case .invalidCredentials(let endpoint):
      return "Tailscale LocalAPI rejected credentials for \(endpoint)"
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .notInstalled:
      return
        "Install Tailscale from https://tailscale.com/download or via Homebrew ('brew install tailscale')."
    case .stopped:
      return
        "Ensure the Tailscale service is running (e.g., launch Tailscale.app or run 'sudo tailscaled')."
    case .inaccessible(let path, _):
      if path.contains("/Library/Tailscale") {
        return
          "Ensure the current user is a member of the 'admin' group, or run with appropriate privileges."
      } else if path.contains("Group Containers") {
        return
          "Grant Full Disk Access or enable App Store discovery in your application configuration."
      }
      return "Check file and socket permissions for '\(DiscoveryLog.redactedProofPath(path))'."
    case .invalidCredentials:
      return
        "Verify authentication token or restart the Tailscale daemon to generate a fresh token."
    }
  }
}

extension LocalAPIDiscoveryError: CustomStringConvertible {
  public var description: String {
    errorDescription ?? "LocalAPIDiscoveryError"
  }
}
