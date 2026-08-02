// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// The daemon's recommended exit node, from `/localapi/v0/suggest-exit-node`.
///
/// The suggestion is based on measured DERP latency and, for location-aware
/// (e.g., Mullvad) exit nodes, on geographic priority. The same information
/// powers `tailscale exit-node suggest`.
///
/// Upstream: `apitype.ExitNodeSuggestionResponse`.
public struct ExitNodeSuggestion: Codable, Sendable, Equatable {
  /// Stable node ID of the suggested exit node (matches
  /// `Prefs.exitNodeID` when this node is selected).
  public var id: String?

  /// DNS name of the suggested exit node.
  public var name: String?

  /// Geographic location of the suggested node, when published.
  public var location: NodeLocation?

  /// Creates an instance for tests, previews, or fixtures.
  public init(id: String? = nil, name: String? = nil, location: NodeLocation? = nil) {
    self.id = id
    self.name = name
    self.location = location
  }

  private enum CodingKeys: String, CodingKey {
    case id = "ID"
    case name = "Name"
    case location = "Location"
  }
}

/// Geographic location metadata a node publishes, used by location-aware
/// exit nodes.
///
/// Upstream: `tailcfg.Location`.
public struct NodeLocation: Codable, Sendable, Equatable {
  /// User-friendly country name with proper capitalization (e.g., "Canada").
  public var country: String?

  /// ISO 3166-1 alpha-2 country code in upper case (e.g., "CA").
  public var countryCode: String?

  /// User-friendly city name with proper capitalization (e.g., "Squamish").
  public var city: String?

  /// Short upper-case city code (IATA, ICAO, or ISO 3166-2) used to
  /// disambiguate cities with identical names.
  public var cityCode: String?

  /// Approximate latitude in degrees; may be the center of the city or country.
  public var latitude: Double?

  /// Approximate longitude in degrees; may be the center of the city or country.
  public var longitude: Double?

  /// Tie-breaker when a location preference matches several exit nodes:
  /// highest priority wins. Zero means no preference.
  public var priority: Int?

  /// Creates an instance for tests, previews, or fixtures.
  public init(
    country: String? = nil,
    countryCode: String? = nil,
    city: String? = nil,
    cityCode: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    priority: Int? = nil
  ) {
    self.country = country
    self.countryCode = countryCode
    self.city = city
    self.cityCode = cityCode
    self.latitude = latitude
    self.longitude = longitude
    self.priority = priority
  }

  private enum CodingKeys: String, CodingKey {
    case country = "Country"
    case countryCode = "CountryCode"
    case city = "City"
    case cityCode = "CityCode"
    case latitude = "Latitude"
    case longitude = "Longitude"
    case priority = "Priority"
  }
}
