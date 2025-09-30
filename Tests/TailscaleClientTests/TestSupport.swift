import XCTest

extension XCTestCase {
  func XCTAssertThrowsErrorAsync<T>(
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
    XCTFail("Missing fixture \(name).\(type)")
    return Data()
  }
}
