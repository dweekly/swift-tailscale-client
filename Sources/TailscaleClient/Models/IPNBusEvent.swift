// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// An event emitted by the IPN bus stream.
///
/// Encapsulates either a daemon notification or a connection lifecycle event.
public enum IPNBusEvent: Sendable, Equatable {
  /// A sparse delta or initial state update from the Tailscale daemon.
  case notification(IPNNotify)
  /// A connection lifecycle transition or data freshness warning.
  case lifecycle(IPNBusLifecycle)

  /// Returns the notification payload if this is a `.notification` event, or nil otherwise.
  public var notification: IPNNotify? {
    guard case .notification(let notify) = self else { return nil }
    return notify
  }

  /// Returns the lifecycle event if this is a `.lifecycle` event, or nil otherwise.
  public var lifecycle: IPNBusLifecycle? {
    guard case .lifecycle(let lifecycle) = self else { return nil }
    return lifecycle
  }
}

extension IPNBusEvent: CustomStringConvertible {
  public var description: String {
    switch self {
    case .notification(let notify):
      return "IPNBusEvent.notification(\(notify))"
    case .lifecycle(let lifecycle):
      return "IPNBusEvent.lifecycle(\(lifecycle))"
    }
  }
}

/// Represents connection lifecycle transitions and freshness boundaries for the IPN bus.
public enum IPNBusLifecycle: Sendable, Equatable {
  /// The stream has connected to the LocalAPI and validated response head metadata.
  case connected
  /// The active connection dropped or closed. `underlying` provides diagnostic detail.
  case disconnected(underlying: String)
  /// The client is waiting before re-dialing the LocalAPI.
  case retrying(attempt: Int, delay: Duration)
  /// An event gap occurred (e.g. queue overflow, undecodable line, or reconnect),
  /// meaning intermediate notifications may have been lost and current state may be stale.
  case stateGap(reason: String)
}

extension IPNBusLifecycle: CustomStringConvertible {
  public var description: String {
    switch self {
    case .connected:
      return "connected"
    case .disconnected(let underlying):
      return "disconnected: \(underlying)"
    case .retrying(let attempt, let delay):
      return "retrying (attempt: \(attempt), delay: \(delay))"
    case .stateGap(let reason):
      return "stateGap: \(reason)"
    }
  }
}
