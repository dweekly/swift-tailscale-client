// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Which part of a domain's TLS credential to fetch from
/// `GET /localapi/v0/cert/<domain>`.
public enum CertKind: String, Sendable, Equatable {
  /// Private key PEM followed by the certificate chain PEM.
  case pair
  /// Certificate chain PEM only.
  case certificate = "cert"
  /// Private key PEM only.
  case privateKey = "key"
}

/// A TLS certificate and private key for a tailnet HTTPS domain, split from
/// the daemon's `type=pair` response.
public struct CertPair: Sendable, Equatable {
  /// The certificate chain, PEM-encoded.
  public var certificatePEM: String

  /// The private key, PEM-encoded. Handle with care — never log it.
  public var privateKeyPEM: String

  /// Creates an instance for tests, previews, or fixtures.
  public init(certificatePEM: String, privateKeyPEM: String) {
    self.certificatePEM = certificatePEM
    self.privateKeyPEM = privateKeyPEM
  }
}

/// The control plane's answer to a feature availability probe, from
/// `POST /localapi/v0/query-feature` (e.g. `feature=funnel` or `serve`).
///
/// Upstream: `tailcfg.QueryFeatureResponse`.
public struct QueryFeatureResponse: Codable, Sendable, Equatable {
  /// `true` when the feature is already enabled for this tailnet/node.
  public var complete: Bool

  /// Human-readable lines (newline-separated) explaining the feature and
  /// how to enable it.
  public var text: String?

  /// Admin-console URL the user should visit to enable the feature;
  /// `nil`/empty when there is nothing to do.
  public var url: String?

  /// Whether a CLI should block awaiting enablement (the control plane
  /// expects it to be quick).
  public var shouldWait: Bool

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    complete: Bool = false,
    text: String? = nil,
    url: String? = nil,
    shouldWait: Bool = false
  ) {
    self.complete = complete
    self.text = text
    self.url = url
    self.shouldWait = shouldWait
  }

  private enum CodingKeys: String, CodingKey {
    case complete = "Complete"
    case text = "Text"
    case url = "URL"
    case shouldWait = "ShouldWait"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    complete = try container.decodeIfPresent(Bool.self, forKey: .complete) ?? false
    text = try container.decodeIfPresent(String.self, forKey: .text)
    url = try container.decodeIfPresent(String.self, forKey: .url)
    shouldWait = try container.decodeIfPresent(Bool.self, forKey: .shouldWait) ?? false
  }
}
