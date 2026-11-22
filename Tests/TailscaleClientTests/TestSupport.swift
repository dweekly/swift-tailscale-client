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

#if canImport(Darwin) || canImport(Glibc)
  /// The highest descriptor number, exclusive, that descriptor-counting tests inspect.
  private let inspectedDescriptorLimit: Int32 = 4096

  /// Counts this process's open socket descriptors.
  ///
  /// Descriptor-leak tests compare a count against a baseline taken earlier in
  /// the test. Counting every descriptor makes that baseline unstable, because
  /// the Swift runtime opens descriptors of its own on first use: on Linux a
  /// `timerfd` appears the first time a task sleeps. The transports and the
  /// fault server only ever open sockets, so a leaked connection is a leaked
  /// socket, and sockets are what these tests count.
  func openSocketDescriptorCount() -> Int {
    let limit = min(getdtablesize(), inspectedDescriptorLimit)
    var count = 0
    for descriptor in 0..<limit {
      var info = stat()
      if fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) {
        count += 1
      }
    }
    return count
  }
#endif
