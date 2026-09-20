// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Classification of errors encountered while connecting or streaming.
public enum StreamErrorClassification: Sendable, Equatable {
  /// Transient error that can be retried after backoff.
  case retryable
  /// Fatal error that indicates unrecoverable failure (e.g. auth failure or cancellation).
  case fatal
}

/// Controls automatic reconnection and exponential backoff with jitter for streaming connections.
public struct StreamRetryPolicy: Sendable, Equatable {
  /// Maximum number of consecutive retry attempts before giving up. `nil` retries indefinitely.
  public var maxAttempts: Int?
  /// Base delay before the first reconnection attempt.
  public var initialDelay: Duration
  /// Maximum upper bound on the backoff delay.
  public var maxDelay: Duration
  /// Jitter factor between 0.0 (no jitter) and 1.0 (full proportional jitter).
  public var jitter: Double
  /// Custom random generator for jitter, enabling deterministic unit testing.
  public var randomProvider: (@Sendable () -> Double)?

  /// Creates a retry policy configuration.
  ///
  /// - Parameters:
  ///   - maxAttempts: Maximum number of consecutive retry attempts, or `nil` for indefinite retries.
  ///   - initialDelay: Initial delay before the first reconnection attempt.
  ///   - maxDelay: Maximum upper bound on the backoff delay.
  ///   - jitter: Jitter factor between 0.0 and 1.0 applied to backoff delays.
  ///   - randomProvider: Optional random number generator producing values in `0.0...1.0`.
  public init(
    maxAttempts: Int? = nil,
    initialDelay: Duration = .milliseconds(100),
    maxDelay: Duration = .seconds(10),
    jitter: Double = 0.2,
    randomProvider: (@Sendable () -> Double)? = nil
  ) {
    self.maxAttempts = maxAttempts
    self.initialDelay = initialDelay
    self.maxDelay = maxDelay
    self.jitter = max(0.0, min(1.0, jitter))
    self.randomProvider = randomProvider
  }

  /// Default production retry policy: indefinite retries starting at 100 ms up to 10 s with 20% jitter.
  public static let `default` = StreamRetryPolicy()

  /// Never retries; terminates immediately on the first connection failure or drop.
  public static let none = StreamRetryPolicy(
    maxAttempts: 0, initialDelay: .zero, maxDelay: .zero, jitter: 0.0)

  public static func == (lhs: StreamRetryPolicy, rhs: StreamRetryPolicy) -> Bool {
    lhs.maxAttempts == rhs.maxAttempts
      && lhs.initialDelay == rhs.initialDelay
      && lhs.maxDelay == rhs.maxDelay
      && lhs.jitter == rhs.jitter
  }

  /// Calculates the deterministic base exponential backoff delay for the given 0-indexed attempt, without jitter.
  public func baseDelay(forAttempt attempt: Int) -> Duration {
    guard attempt >= 0 else { return initialDelay }
    let multiplier = pow(2.0, Double(attempt))
    let initialSeconds =
      Double(initialDelay.components.seconds) + Double(initialDelay.components.attoseconds) / 1e18
    let calculatedSeconds = initialSeconds * multiplier
    let maxSeconds =
      Double(maxDelay.components.seconds) + Double(maxDelay.components.attoseconds) / 1e18
    return .seconds(min(calculatedSeconds, maxSeconds))
  }

  /// Calculates the backoff delay for the given attempt, applying jitter.
  public func delay(forAttempt attempt: Int) -> Duration {
    let base = baseDelay(forAttempt: attempt)
    guard jitter > 0.0 else { return base }

    let baseSeconds =
      Double(base.components.seconds) + Double(base.components.attoseconds) / 1e18
    let rand = randomProvider?() ?? Double.random(in: 0.0...1.0)
    let jitterOffset = (rand * 2.0 - 1.0) * (jitter * baseSeconds)
    let jitteredSeconds = max(0.0, baseSeconds + jitterOffset)
    return .seconds(jitteredSeconds)
  }

  /// Classifies an error as retryable or fatal.
  public static func classify(_ error: Error) -> StreamErrorClassification {
    if error is CancellationError {
      return .fatal
    }
    if let clientError = error as? TailscaleClientError {
      switch clientError {
      case .permissionDenied, .missingConcurrencyToken, .targetMismatch, .preconditionFailed,
        .endpointUnavailable,
        .peerNotFound, .streamOverflow, .decoding:
        return .fatal
      case .discovery(let discoveryError):
        switch discoveryError {
        case .notInstalled, .inaccessible, .invalidCredentials:
          return .fatal
        case .stopped:
          return .retryable
        }
      case .unexpectedStatus(let code, _, _):
        if code == 401 || code == 403 || code == 404 {
          return .fatal
        }
        return .retryable
      case .timeout, .rateLimited:
        return .retryable
      case .transport(let transportError):
        return classifyTransport(transportError)
      }
    }
    if let transportError = error as? TailscaleTransportError {
      return classifyTransport(transportError)
    }
    return .retryable
  }

  private static func classifyTransport(_ error: TailscaleTransportError)
    -> StreamErrorClassification
  {
    switch error {
    case .unimplemented, .socketNotFound:
      return .fatal
    default:
      return .retryable
    }
  }
}
