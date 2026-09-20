// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import XCTest

extension XCTestCase {
  func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verification: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await expression()
      XCTFail("Expected error", file: file, line: line)
    } catch {
      verification(error)
    }
  }

  func fixture(named name: String, type: String) throws -> Data {
    if let url = Bundle.module.url(forResource: name, withExtension: type, subdirectory: "Fixtures")
    {
      return try Data(contentsOf: url)
    }
    if let url = Bundle.module.url(forResource: name, withExtension: type) {
      return try Data(contentsOf: url)
    }
    if let resourceURL = Bundle.module.resourceURL {
      let directURL = resourceURL.appendingPathComponent("Fixtures/\(name).\(type)")
      if FileManager.default.fileExists(atPath: directURL.path) {
        return try Data(contentsOf: directURL)
      }
    }
    XCTFail("Missing fixture \(name).\(type)")
    return Data()
  }

  /// Loads a versioned LocalAPI fixture from `Fixtures/LocalAPI/<version>/<endpoint>.<type>`.
  func localAPIFixture(version: String, endpoint: String, type: String = "json") throws -> Data {
    let subpath = "Fixtures/LocalAPI/\(version)"
    if let url = Bundle.module.url(
      forResource: endpoint, withExtension: type, subdirectory: subpath)
    {
      return try Data(contentsOf: url)
    }
    if let url = Bundle.module.url(
      forResource: endpoint, withExtension: type, subdirectory: "LocalAPI/\(version)")
    {
      return try Data(contentsOf: url)
    }
    if let url = Bundle.module.url(forResource: endpoint, withExtension: type) {
      return try Data(contentsOf: url)
    }
    if let resourceURL = Bundle.module.resourceURL {
      let directURL = resourceURL.appendingPathComponent(
        "Fixtures/LocalAPI/\(version)/\(endpoint).\(type)")
      if FileManager.default.fileExists(atPath: directURL.path) {
        return try Data(contentsOf: directURL)
      }
      let directURL2 = resourceURL.appendingPathComponent("LocalAPI/\(version)/\(endpoint).\(type)")
      if FileManager.default.fileExists(atPath: directURL2.path) {
        return try Data(contentsOf: directURL2)
      }
    }
    XCTFail("Missing versioned LocalAPI fixture for \(version)/\(endpoint).\(type)")
    return Data()
  }

  /// Loads the LocalAPI master manifest or a version-specific manifest.
  func localAPIManifest(version: String? = nil) throws -> Data {
    let subpath = version.map { "Fixtures/LocalAPI/\($0)" } ?? "Fixtures/LocalAPI"
    if let url = Bundle.module.url(
      forResource: "manifest", withExtension: "json", subdirectory: subpath)
    {
      return try Data(contentsOf: url)
    }
    let altSubpath = version.map { "LocalAPI/\($0)" } ?? "LocalAPI"
    if let url = Bundle.module.url(
      forResource: "manifest", withExtension: "json", subdirectory: altSubpath)
    {
      return try Data(contentsOf: url)
    }
    if let resourceURL = Bundle.module.resourceURL {
      let directURL = resourceURL.appendingPathComponent("\(subpath)/manifest.json")
      if FileManager.default.fileExists(atPath: directURL.path) {
        return try Data(contentsOf: directURL)
      }
      let directURL2 = resourceURL.appendingPathComponent("\(altSubpath)/manifest.json")
      if FileManager.default.fileExists(atPath: directURL2.path) {
        return try Data(contentsOf: directURL2)
      }
    }
    XCTFail("Missing LocalAPI manifest at \(subpath)/manifest.json")
    return Data()
  }
}
