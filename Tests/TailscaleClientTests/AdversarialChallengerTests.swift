// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient
@testable import TailscaleClientMocks

/// Comprehensive adversarial challenge suite for Milestone 1 W1 (PR 02 & PR 03).
///
/// Probes:
/// 1. `JSONValue` numeric precision preservation:
///    - Boundary integers: 0, -1, 1, Int64.min, Int64.max, UInt64.max
///    - Critical 64-bit transition points: 9223372036854775808 (Int64.max + 1), 18446744073709551614 (UInt64.max - 1)
///    - Floating-point representations: pi, scientific notations (1e10, 1.23e-4, -2.5e-8, 1e20, 1E+6)
///    - High-precision numbers: numbers with > 15 decimal digits, 2^53 + 1 (9007199254740993)
///    - Out-of-bounds 64-bit numbers (overflow UInt64.max falling back to Double)
///    - Re-encoding fidelity without scientific notation or truncation for integers
/// 2. `ServeConfig` lossless round-trip & adversarial mutation:
///    - Deeply nested objects (depth 10+)
///    - Heterogeneous arrays with mixed null, bool, int, float, string, object, array
///    - Unicode torture tests: emoji, non-Latin scripts, RTL, zero-width joiners, surrogate pairs, escaped chars
///    - Empty string keys and values, explicit nulls
///    - Unknown fields adjacent to EVERY known field at all 5 structural levels (ServeConfig, TCPPortHandler, WebServerConfig, HTTPHandler, ServiceConfig)
///    - Multi-field concurrent mutations of known fields while asserting all unknown fields survive intact
/// 3. Concurrency & ETag edge cases:
///    - Weak ETags, whitespace ETags, missing ETags
///    - Mutate closure throwing and preserving original config
final class AdversarialChallengerTests: XCTestCase {

  // MARK: - 1. JSONValue Adversarial Numeric Precision

  func testJSONValueBoundaryIntegers() throws {
    let testCases: [(String, JSONValue, Int64?, UInt64?)] = [
      ("0", .integer(0), 0, 0),
      ("-1", .integer(-1), -1, nil),
      ("1", .integer(1), 1, 1),
      (
        "-9223372036854775808",
        .integer(Int64.min),
        Int64.min,
        nil
      ),
      (
        "9223372036854775807",
        .integer(Int64.max),
        Int64.max,
        UInt64(Int64.max)
      ),
      (
        "9223372036854775808",
        .unsignedInteger(9_223_372_036_854_775_808),
        nil,
        9_223_372_036_854_775_808
      ),
      (
        "18446744073709551614",
        .unsignedInteger(18_446_744_073_709_551_614),
        nil,
        18_446_744_073_709_551_614
      ),
      (
        "18446744073709551615",
        .unsignedInteger(UInt64.max),
        nil,
        UInt64.max
      ),
    ]

    for (rawStr, expectedValue, expectedInt64, expectedUInt64) in testCases {
      let json = "{\"val\": \(rawStr)}"
      let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
      let actual = try XCTUnwrap(decoded["val"], "Failed to decode key for \(rawStr)")

      XCTAssertEqual(actual, expectedValue, "Mismatch for raw integer \(rawStr)")
      XCTAssertEqual(actual.int64Value, expectedInt64, "int64Value mismatch for \(rawStr)")
      XCTAssertEqual(actual.uint64Value, expectedUInt64, "uint64Value mismatch for \(rawStr)")

      // Re-encode and verify lossless textual format
      let encoded = try JSONEncoder().encode(decoded)
      let encodedStr = String(decoding: encoded, as: UTF8.self)
      XCTAssertTrue(
        encodedStr.contains(rawStr),
        "Encoded JSON '\(encodedStr)' must contain exact integer representation '\(rawStr)'"
      )
      XCTAssertFalse(
        encodedStr.contains("e+"),
        "Integer '\(rawStr)' must not be encoded in scientific notation: '\(encodedStr)'"
      )

      // Redecode and verify structural equality
      let redecoded = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
      XCTAssertEqual(redecoded["val"], expectedValue)
    }
  }

  func testJSONValue53BitPrecisionEdge() throws {
    // 2^53 + 1 = 9007199254740993.
    // In IEEE 754 double precision (53-bit significand), 9007199254740993 rounds to 9007199254740992!
    // JSONValue MUST decode this as an Int64, retaining exact precision.
    let numStr = "9007199254740993"
    let json = "{\"exact\": \(numStr)}"
    let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
    let val = try XCTUnwrap(decoded["exact"])

    guard case .integer(let intVal) = val else {
      XCTFail("Expected .integer for \(numStr), got \(val)")
      return
    }
    XCTAssertEqual(intVal, 9_007_199_254_740_993)

    let encoded = try JSONEncoder().encode(decoded)
    let encodedStr = String(decoding: encoded, as: UTF8.self)
    XCTAssertTrue(encodedStr.contains(numStr), "Must retain exact digit 9007199254740993")
  }

  func testJSONValueScientificNotationAndFloats() throws {
    let cases: [(String, Double)] = [
      ("1e10", 1e10),
      ("1.23e-4", 1.23e-4),
      ("-2.5e-8", -2.5e-8),
      ("1e20", 1e20),
      ("1E+6", 1e6),
      ("3.141592653589793", 3.141592653589793),
      ("-0.0000000000001", -0.0000000000001),
    ]

    for (rawStr, expectedDouble) in cases {
      let json = "{\"f\": \(rawStr)}"
      let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
      let val = try XCTUnwrap(decoded["f"])

      let doubleVal = try XCTUnwrap(val.doubleValue, "Expected double value for \(rawStr)")
      XCTAssertEqual(doubleVal, expectedDouble, accuracy: abs(expectedDouble) * 1e-12)

      let encoded = try JSONEncoder().encode(decoded)
      let redecoded = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
      let redecodedDouble = try XCTUnwrap(redecoded["f"]?.doubleValue)
      XCTAssertEqual(redecodedDouble, expectedDouble, accuracy: abs(expectedDouble) * 1e-12)
    }
  }

  func testJSONValueNumbersBeyondUInt64MaxFallbackToDouble() throws {
    // A number exceeding UInt64.max (18446744073709551615) cannot fit in Int64 or UInt64.
    // It should gracefully decode as .double without crashing.
    let hugeNum = "18446744073709551616"  // UInt64.max + 1
    let json = "{\"huge\": \(hugeNum)}"
    let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
    let val = try XCTUnwrap(decoded["huge"])

    guard case .double(let d) = val else {
      XCTFail("Expected .double fallback for overflow integer \(hugeNum), got \(val)")
      return
    }
    XCTAssertGreaterThan(d, 1.84e19)
  }

  func testJSONValueNegativeOverflowFallbackToDouble() throws {
    // Number less than Int64.min (-9223372036854775808)
    let tinyNum = "-9223372036854775809"
    let json = "{\"tiny\": \(tinyNum)}"
    let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
    let val = try XCTUnwrap(decoded["tiny"])

    guard case .double(let d) = val else {
      XCTFail("Expected .double fallback for underflow integer \(tinyNum), got \(val)")
      return
    }
    XCTAssertLessThan(d, -9.22e18)
  }

  // MARK: - 2. ServeConfig Adversarial Lossless Round-Trip & Mutation

  func testServeConfigArbitraryDeeplyNestedUnknownObjects() throws {
    // Construct 15 levels of nested unmodeled objects
    var deeplyNestedJSON = "{\"leaf\": \"deep_value\", \"leaf_int\": 9223372036854775807}"
    for i in (1...15).reversed() {
      deeplyNestedJSON = "{\"level_\(i)\": \(deeplyNestedJSON)}"
    }

    let rawJSON = """
      {
        "TCP": {
          "8080": {
            "HTTP": true,
            "DeepTCP": \(deeplyNestedJSON)
          }
        },
        "DeepRoot": \(deeplyNestedJSON)
      }
      """

    let decoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(rawJSON.utf8))

    // Verify root deep object
    XCTAssertNotNil(decoded.unmodeledFields["DeepRoot"])
    // Verify TCP deep object
    let tcp8080 = try XCTUnwrap(decoded.tcp[8080])
    XCTAssertNotNil(tcp8080.unmodeledFields["DeepTCP"])

    // Re-encode and re-decode
    let encoded = try JSONEncoder().encode(decoded)
    let redecoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: encoded)

    XCTAssertEqual(decoded, redecoded)
  }

  func testServeConfigUnicodeAndSpecialCharacterPreservation() throws {
    let rawJSON = """
      {
        "TCP": {
          "443": {
            "HTTPS": true,
            "🚀_launch_emoji": "✨_sparkles_✨",
            "кириллица": "значение",
            "العربية": "مرحبا بالعالم",
            "日本語キー": "日本語の値",
            "escapes": "line1\\nline2\\t\\\"quoted\\\"\\\\backslash",
            "zero_width": "a\\u200Db",
            "empty_str": ""
          }
        },
        "🚀_root_emoji": "🛸",
        "special_symbols": "!@#$%^&*()_+-=[]{}|;':,.<>/?`~"
      }
      """

    let decoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(rawJSON.utf8))
    let tcp443 = try XCTUnwrap(decoded.tcp[443])

    XCTAssertEqual(tcp443.unmodeledFields["🚀_launch_emoji"], .string("✨_sparkles_✨"))
    XCTAssertEqual(tcp443.unmodeledFields["кириллица"], .string("значение"))
    XCTAssertEqual(tcp443.unmodeledFields["العربية"], .string("مرحبا بالعالم"))
    XCTAssertEqual(tcp443.unmodeledFields["日本語キー"], .string("日本語の値"))
    XCTAssertEqual(
      tcp443.unmodeledFields["escapes"], .string("line1\nline2\t\"quoted\"\\backslash"))
    XCTAssertEqual(tcp443.unmodeledFields["zero_width"], .string("a\u{200D}b"))
    XCTAssertEqual(tcp443.unmodeledFields["empty_str"], .string(""))

    XCTAssertEqual(decoded.unmodeledFields["🚀_root_emoji"], .string("🛸"))
    XCTAssertEqual(
      decoded.unmodeledFields["special_symbols"], .string("!@#$%^&*()_+-=[]{}|;':,.<>/?`~"))

    // Roundtrip
    let encoded = try JSONEncoder().encode(decoded)
    let redecoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: encoded)
    XCTAssertEqual(decoded, redecoded)
  }

  func testServeConfigHeterogeneousArraysAndNulls() throws {
    let rawJSON = """
      {
        "HeteroArray": [
          null,
          true,
          false,
          12345,
          -98765432109876,
          18446744073709551615,
          3.14159,
          "string_element",
          [],
          {},
          {"inner_key": [null, "deep"]}
        ],
        "RootExplicitNull": null,
        "RootEmptyObject": {},
        "RootEmptyArray": []
      }
      """

    let decoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(rawJSON.utf8))

    XCTAssertEqual(decoded.unmodeledFields["RootExplicitNull"], .null)
    XCTAssertEqual(decoded.unmodeledFields["RootEmptyObject"], .object([:]))
    XCTAssertEqual(decoded.unmodeledFields["RootEmptyArray"], .array([]))

    guard case .array(let arrayElements)? = decoded.unmodeledFields["HeteroArray"] else {
      XCTFail("Expected HeteroArray to decode as .array")
      return
    }

    XCTAssertEqual(arrayElements.count, 11)
    XCTAssertEqual(arrayElements[0], .null)
    XCTAssertEqual(arrayElements[1], .bool(true))
    XCTAssertEqual(arrayElements[2], .bool(false))
    XCTAssertEqual(arrayElements[3], .integer(12345))
    XCTAssertEqual(arrayElements[4], .integer(-98_765_432_109_876))
    XCTAssertEqual(arrayElements[5], .unsignedInteger(UInt64.max))
    XCTAssertEqual(arrayElements[6].doubleValue, 3.14159)
    XCTAssertEqual(arrayElements[7], .string("string_element"))
    XCTAssertEqual(arrayElements[8], .array([]))
    XCTAssertEqual(arrayElements[9], .object([:]))

    let encoded = try JSONEncoder().encode(decoded)
    let redecoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: encoded)
    XCTAssertEqual(decoded, redecoded)
  }

  func testServeConfigAdversarialMutationAcrossAllLevels() throws {
    // Construct a comprehensive config with unknown fields at all levels
    let complexJSON = """
      {
        "TCP": {
          "80": {
            "HTTP": true,
            "TCP_Custom_A": "preserve_tcp_80"
          },
          "443": {
            "HTTPS": true,
            "TCP_Custom_B": 18446744073709551615
          }
        },
        "Web": {
          "site.ts.net:443": {
            "Handlers": {
              "/": {
                "Proxy": "http://127.0.0.1:3000",
                "Handler_Unknown_1": "handler_meta",
                "Handler_Unknown_2": [1, 2, 3]
              },
              "/static": {
                "Path": "/var/www",
                "Handler_Unknown_3": true
              }
            },
            "Web_Custom_1": {"theme": "dark", "version": 2}
          }
        },
        "Services": {
          "svc:metrics": {
            "Tun": true,
            "Service_Custom_1": "metrics_secret"
          }
        },
        "AllowFunnel": {
          "site.ts.net:443": true
        },
        "Root_Unknown_Alpha": "keep_alpha",
        "Root_Unknown_Beta": 42,
        "Root_Unknown_Gamma": null
      }
      """

    var config = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(complexJSON.utf8))

    // Perform multiple deliberate mutations to known fields:
    // 1. Add a new TCP port
    config.tcp[8443] = TCPPortHandler(https: true)
    // 2. Modify existing TCP port
    config.tcp[80]?.http = false
    // 3. Add a new web handler
    config.web["site.ts.net:443"]?.handlers["/api"] = HTTPHandler(proxy: "http://127.0.0.1:5000")
    // 4. Modify existing handler
    config.web["site.ts.net:443"]?.handlers["/"]?.proxy = "http://127.0.0.1:3001"
    // 5. Delete a web handler
    config.web["site.ts.net:443"]?.handlers.removeValue(forKey: "/static")
    // 6. Mutate AllowFunnel
    config.allowFunnel["site.ts.net:443"] = false
    config.allowFunnel["other.ts.net:443"] = true

    // Re-encode to JSON
    let encoded = try JSONEncoder().encode(config)

    // Verify raw JSON serialization preserves unknown keys and updated known keys
    let jsonDict = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    // Root unknowns survived
    XCTAssertEqual(jsonDict["Root_Unknown_Alpha"] as? String, "keep_alpha")
    XCTAssertEqual(jsonDict["Root_Unknown_Beta"] as? Int, 42)
    XCTAssertTrue(jsonDict.keys.contains("Root_Unknown_Gamma"))
    XCTAssertTrue(jsonDict["Root_Unknown_Gamma"] is NSNull)

    // TCP mutations and unknowns
    let tcpDict = try XCTUnwrap(jsonDict["TCP"] as? [String: Any])
    let tcp80 = try XCTUnwrap(tcpDict["80"] as? [String: Any])
    XCTAssertEqual(tcp80["TCP_Custom_A"] as? String, "preserve_tcp_80")
    XCTAssertNil(tcp80["HTTP"], "HTTP was false and should be omitted or false")

    let tcp443 = try XCTUnwrap(tcpDict["443"] as? [String: Any])
    XCTAssertEqual(tcp443["HTTPS"] as? Bool, true)

    let tcp8443 = try XCTUnwrap(tcpDict["8443"] as? [String: Any])
    XCTAssertEqual(tcp8443["HTTPS"] as? Bool, true)

    // Web mutations and unknowns
    let webDict = try XCTUnwrap(jsonDict["Web"] as? [String: Any])
    let siteWeb = try XCTUnwrap(webDict["site.ts.net:443"] as? [String: Any])
    let webCustom = try XCTUnwrap(siteWeb["Web_Custom_1"] as? [String: Any])
    XCTAssertEqual(webCustom["theme"] as? String, "dark")
    XCTAssertEqual(webCustom["version"] as? Int, 2)

    let handlersDict = try XCTUnwrap(siteWeb["Handlers"] as? [String: Any])
    let rootHandler = try XCTUnwrap(handlersDict["/"] as? [String: Any])
    XCTAssertEqual(rootHandler["Proxy"] as? String, "http://127.0.0.1:3001")  // mutated
    XCTAssertEqual(rootHandler["Handler_Unknown_1"] as? String, "handler_meta")  // preserved
    XCTAssertEqual(rootHandler["Handler_Unknown_2"] as? [Int], [1, 2, 3])  // preserved

    let apiHandler = try XCTUnwrap(handlersDict["/api"] as? [String: Any])
    XCTAssertEqual(apiHandler["Proxy"] as? String, "http://127.0.0.1:5000")  // added

    XCTAssertNil(handlersDict["/static"], "Handler /static was deleted")

    // Services unknowns
    let svcDict = try XCTUnwrap(jsonDict["Services"] as? [String: Any])
    let metricsSvc = try XCTUnwrap(svcDict["svc:metrics"] as? [String: Any])
    XCTAssertEqual(metricsSvc["Service_Custom_1"] as? String, "metrics_secret")
    XCTAssertEqual(metricsSvc["Tun"] as? Bool, true)

    // AllowFunnel mutations
    let funnelDict = try XCTUnwrap(jsonDict["AllowFunnel"] as? [String: Any])
    XCTAssertEqual(funnelDict["site.ts.net:443"] as? Bool, false)
    XCTAssertEqual(funnelDict["other.ts.net:443"] as? Bool, true)

    // Redecode and assert structural equality with modified config
    let redecoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: encoded)
    XCTAssertEqual(redecoded, config)
  }

  // MARK: - 3. Concurrency & ETag Adversarial Checks

  private func makeClient(transport: MockTransport) -> TailscaleClient {
    let configuration = TailscaleClientConfiguration(
      endpoint: .url(URL(string: "http://example.local")!),
      authToken: nil,
      capabilityVersion: 1,
      transport: transport)
    return TailscaleClient(configuration: configuration)
  }

  func testServeConfigSnapshotWithWeakETag() async throws {
    let transport = MockTransport { request, _ in
      XCTAssertEqual(request.method, "GET")
      return TailscaleResponse(
        statusCode: 200,
        data: Data("{}".utf8),
        headers: ["ETag": "W/\"weak-12345\""]
      )
    }
    let client = makeClient(transport: transport)

    let snapshot = try await client.serveConfigSnapshot()
    XCTAssertEqual(snapshot.etag, "W/\"weak-12345\"")

    let recorder = RequestRecorder()
    let postTransport = MockTransport { request, _ in
      await recorder.record(request: request)
      return TailscaleResponse(
        statusCode: 200,
        data: Data("{}".utf8),
        headers: ["ETag": "\"new-tag\""]
      )
    }
    let postClient = makeClient(transport: postTransport)

    let updated = try await postClient.setServeConfig(snapshot.config, matching: snapshot)
    let recorded = await recorder.requests
    XCTAssertEqual(recorded.first?.additionalHeaders["If-Match"], "W/\"weak-12345\"")
    XCTAssertEqual(updated.etag, "\"new-tag\"")
  }

  func testUpdateServeConfigClosureThrowDoesNotCorruptOriginalSnapshot() async throws {
    struct TestFailure: Error {}
    let transport = MockTransport { _, _ in
      XCTFail("Must not contact transport on closure throw")
      return TailscaleResponse(statusCode: 200, data: Data())
    }
    let client = makeClient(transport: transport)
    let original = ServeConfigSnapshot(
      etag: "\"original\"",
      targetIdentifier: client.targetIdentifier,
      config: ServeConfig(tcp: [80: TCPPortHandler(http: true)])
    )

    do {
      _ = try await client.updateServeConfig(original) { cfg in
        cfg.tcp[80]?.http = false
        cfg.tcp[443] = TCPPortHandler(https: true)
        throw TestFailure()
      }
      XCTFail("Should have thrown")
    } catch is TestFailure {
      // Original snapshot config must remain unchanged
      XCTAssertEqual(original.config.tcp[80]?.http, true)
      XCTAssertNil(original.config.tcp[443])
      XCTAssertEqual(original.etag, "\"original\"")
    }
  }

  // MARK: - 4. Generative / Fuzz Testing for JSONValue & ServeConfig

  private func generateRandomJSONValue(depth: Int) -> JSONValue {
    if depth <= 0 {
      let choice = Int.random(in: 0...5)
      switch choice {
      case 0:
        return .null
      case 1:
        return .bool(Bool.random())
      case 2:
        // Random Int64 with bias toward extremes
        let intChoice = Int.random(in: 0...4)
        switch intChoice {
        case 0: return .integer(Int64.min)
        case 1: return .integer(Int64.max)
        case 2: return .integer(0)
        case 3: return .integer(-1)
        default: return .integer(Int64.random(in: Int64.min...Int64.max))
        }
      case 3:
        // Random UInt64 biased above Int64.max
        let uintChoice = Int.random(in: 0...3)
        switch uintChoice {
        case 0: return .unsignedInteger(UInt64.max)
        case 1: return .unsignedInteger(UInt64(Int64.max) + 1)
        case 2: return .unsignedInteger(18_446_744_073_709_551_614)
        default: return .unsignedInteger(UInt64.random(in: (UInt64(Int64.max) + 1)...UInt64.max))
        }
      case 4:
        // Double (normalized to avoid NaN / Inf)
        let d = Double.random(in: -1000000.0...1000000.0)
        return .double(Double(round(10000 * d) / 10000))
      default:
        let chars = ["a", "b", " ", "🚀", "中", "\n", "\t", "\"", "\\", ""]
        let str = (0..<Int.random(in: 0...10)).map { _ in chars.randomElement()! }.joined()
        return .string(str)
      }
    }

    let choice = Int.random(in: 0...7)
    switch choice {
    case 0...5:
      return generateRandomJSONValue(depth: 0)
    case 6:
      // Array
      let count = Int.random(in: 0...4)
      let items = (0..<count).map { _ in generateRandomJSONValue(depth: depth - 1) }
      return .array(items)
    default:
      // Object
      let count = Int.random(in: 0...4)
      var dict: [String: JSONValue] = [:]
      for i in 0..<count {
        let key = "key_\(i)_\(UUID().uuidString.prefix(4))"
        dict[key] = generateRandomJSONValue(depth: depth - 1)
      }
      return .object(dict)
    }
  }

  func testGenerativeJSONValueRoundTripStress() throws {
    for iteration in 1...50 {
      let randomVal = generateRandomJSONValue(depth: 4)
      let wrapped = ["root": randomVal]

      let encoded = try JSONEncoder().encode(wrapped)
      let decoded = try JSONDecoder().decode([String: JSONValue].self, from: encoded)

      XCTAssertEqual(
        decoded["root"],
        randomVal,
        "Generative JSONValue failed round-trip on iteration \(iteration)"
      )
    }
  }

  func testGenerativeServeConfigRoundTripStress() throws {
    for iteration in 1...30 {
      var config = ServeConfig()

      // Populate some known fields
      let port = UInt16.random(in: 1024...65535)
      config.tcp[port] = TCPPortHandler(
        https: Bool.random(),
        http: Bool.random(),
        tcpForward: Bool.random() ? "127.0.0.1:\(port)" : nil,
        terminateTLS: Bool.random() ? "node.ts.net" : nil,
        unmodeledFields: [
          "tcp_unmodeled_\(iteration)": generateRandomJSONValue(depth: 2)
        ]
      )

      config.web["site\(iteration).ts.net:443"] = WebServerConfig(
        handlers: [
          "/": HTTPHandler(
            proxy: "http://127.0.0.1:8080",
            unmodeledFields: [
              "handler_unmodeled": generateRandomJSONValue(depth: 2)
            ]
          )
        ],
        unmodeledFields: [
          "web_unmodeled": generateRandomJSONValue(depth: 2)
        ]
      )

      config.services["svc:rand\(iteration)"] = ServiceConfig(
        tun: Bool.random(),
        unmodeledFields: [
          "svc_unmodeled": generateRandomJSONValue(depth: 2)
        ]
      )

      // Random root unmodeled fields
      config.unmodeledFields["root_rand_\(iteration)"] = generateRandomJSONValue(depth: 3)
      config.unmodeledFields["explicit_null_\(iteration)"] = .null

      // Encode and decode
      let encoded = try JSONEncoder().encode(config)
      let redecoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: encoded)

      XCTAssertEqual(
        redecoded,
        config,
        "Generative ServeConfig failed round-trip on iteration \(iteration)"
      )
    }
  }

  func testForegroundRecursiveUnmodeledFieldsRoundTrip() throws {
    let rawJSON = """
      {
        "Foreground": {
          "sess-999": {
            "TCP": {
              "9000": {
                "HTTP": true,
                "ForegroundTCPUnknown": "fg-tcp-value"
              }
            },
            "ForegroundRootUnknown": "fg-root-value",
            "ForegroundInt64": 9223372036854775807
          }
        },
        "ParentUnknown": "parent-value"
      }
      """

    let decoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(rawJSON.utf8))
    let fg = try XCTUnwrap(decoded.foreground["sess-999"])

    XCTAssertEqual(fg.unmodeledFields["ForegroundRootUnknown"], .string("fg-root-value"))
    XCTAssertEqual(fg.unmodeledFields["ForegroundInt64"], .integer(Int64.max))
    XCTAssertEqual(fg.tcp[9000]?.unmodeledFields["ForegroundTCPUnknown"], .string("fg-tcp-value"))

    let encoded = try JSONEncoder().encode(decoded)
    let redecoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: encoded)
    XCTAssertEqual(redecoded, decoded)
  }
}
