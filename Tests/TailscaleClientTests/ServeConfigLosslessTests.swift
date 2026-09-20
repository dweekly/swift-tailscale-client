// SPDX-License-Identifier: MIT
// Copyright (c) 2026 David E. Weekly

import Foundation
import XCTest

@testable import TailscaleClient

final class ServeConfigLosslessTests: XCTestCase {

  // MARK: - JSONValue 64-Bit Integer & Precision Tests

  func testJSONValueDecodesSigned64BitIntegers() throws {
    let raw = """
      {
        "min": -9223372036854775808,
        "zero": 0,
        "max": 9223372036854775807
      }
      """
    let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(raw.utf8))

    XCTAssertEqual(decoded["min"], .integer(Int64.min))
    XCTAssertEqual(decoded["min"]?.int64Value, Int64.min)

    XCTAssertEqual(decoded["zero"], .integer(0))
    XCTAssertEqual(decoded["zero"]?.intValue, 0)
    XCTAssertEqual(decoded["zero"]?.int64Value, 0)
    XCTAssertEqual(decoded["zero"]?.uint64Value, 0)

    XCTAssertEqual(decoded["max"], .integer(Int64.max))
    XCTAssertEqual(decoded["max"]?.int64Value, Int64.max)
    XCTAssertEqual(decoded["max"]?.uint64Value, UInt64(Int64.max))

    let encoded = try JSONEncoder().encode(decoded)
    let redecoded = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
    XCTAssertEqual(redecoded, decoded)
  }

  func testJSONValueDecodesLargeUnsigned64BitIntegersWithoutDoubleRounding() throws {
    let largeUnsignedStr = "18446744073709551615"
    let justOverSignedMaxStr = "9223372036854775808"
    let raw = """
      {
        "unsignedMax": \(largeUnsignedStr),
        "aboveSignedMax": \(justOverSignedMaxStr)
      }
      """
    let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(raw.utf8))

    XCTAssertEqual(decoded["unsignedMax"], .unsignedInteger(UInt64.max))
    XCTAssertEqual(decoded["unsignedMax"]?.uint64Value, UInt64.max)
    XCTAssertNil(decoded["unsignedMax"]?.int64Value)

    XCTAssertEqual(decoded["aboveSignedMax"], .unsignedInteger(9_223_372_036_854_775_808))
    XCTAssertEqual(decoded["aboveSignedMax"]?.uint64Value, 9_223_372_036_854_775_808)

    // Re-encode to verify exact string preservation without scientific notation
    let encoded = try JSONEncoder().encode(decoded)
    let encodedString = String(decoding: encoded, as: UTF8.self)
    XCTAssertTrue(encodedString.contains(largeUnsignedStr), "Expected exact integer string")
    XCTAssertTrue(encodedString.contains(justOverSignedMaxStr), "Expected exact integer string")
    XCTAssertFalse(encodedString.contains("e+"), "Must not encode as scientific notation Double")

    let redecoded = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
    XCTAssertEqual(redecoded, decoded)
  }

  func testJSONValueDecodesFloatsAndDoubles() throws {
    let raw = """
      {
        "pi": 3.141592653589793,
        "scientific": 1.23e-4
      }
      """
    let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(raw.utf8))

    guard case .double(let piVal)? = decoded["pi"],
      case .double(let sciVal)? = decoded["scientific"]
    else {
      XCTFail("Expected double values")
      return
    }

    XCTAssertEqual(piVal, 3.141592653589793, accuracy: 1e-15)
    XCTAssertEqual(sciVal, 0.000123, accuracy: 1e-10)
    XCTAssertEqual(decoded["pi"]?.doubleValue, piVal)
    XCTAssertNil(decoded["pi"]?.intValue)
  }

  func testJSONValueAccessorsAndConveniences() {
    let intVal = JSONValue.integer(42)
    XCTAssertEqual(intVal.intValue, 42)
    XCTAssertEqual(intVal.int64Value, 42)
    XCTAssertEqual(intVal.uint64Value, 42)
    XCTAssertEqual(intVal.doubleValue, 42.0)
    XCTAssertNil(intVal.stringValue)
    XCTAssertNil(intVal.boolValue)
    XCTAssertFalse(intVal.isNull)

    let strVal = JSONValue.string("hello")
    XCTAssertEqual(strVal.stringValue, "hello")
    XCTAssertNil(strVal.intValue)

    let boolVal = JSONValue.bool(true)
    XCTAssertEqual(boolVal.boolValue, true)
    XCTAssertNil(boolVal.stringValue)

    let nullVal = JSONValue.null
    XCTAssertTrue(nullVal.isNull)
    XCTAssertNil(nullVal.intValue)
  }

  // MARK: - Lossless ServeConfig Round-Trip Tests

  func testServeConfigPreservesUnmodeledFieldsAtAllLevels() throws {
    let json = """
      {
        "TCP": {
          "8443": {
            "HTTPS": true,
            "TCPForward": "127.0.0.1:8000",
            "CustomTCPSetting": "custom-tcp-val",
            "ProxyProtocol": 2
          }
        },
        "Web": {
          "my-node.ts.net:443": {
            "Handlers": {
              "/api": {
                "Proxy": "http://127.0.0.1:5000",
                "CustomHandlerInt": 1234567890123456,
                "CustomHandlerNull": null,
                "CustomHandlerArray": ["a", "b", "c"]
              }
            },
            "CustomWebObject": {
              "nestedKey": "nestedVal"
            }
          }
        },
        "Services": {
          "svc:custom": {
            "Tun": true,
            "CustomServiceSetting": true
          }
        },
        "AllowFunnel": {
          "my-node.ts.net:443": true
        },
        "CustomRootString": "root-val",
        "CustomRootInt64": 9223372036854775807,
        "CustomRootUInt64": 18446744073709551615,
        "CustomRootNull": null
      }
      """

    let decoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(json.utf8))

    // Verify root unmodeled fields
    XCTAssertEqual(decoded.unmodeledFields["CustomRootString"], .string("root-val"))
    XCTAssertEqual(decoded.unmodeledFields["CustomRootInt64"], .integer(Int64.max))
    XCTAssertEqual(decoded.unmodeledFields["CustomRootUInt64"], .unsignedInteger(UInt64.max))
    XCTAssertEqual(decoded.unmodeledFields["CustomRootNull"], .null)

    // Verify TCP unmodeled fields
    let tcp8443 = try XCTUnwrap(decoded.tcp[8443])
    XCTAssertEqual(tcp8443.https, true)
    XCTAssertEqual(tcp8443.tcpForward, "127.0.0.1:8000")
    XCTAssertEqual(tcp8443.unmodeledFields["CustomTCPSetting"], .string("custom-tcp-val"))
    XCTAssertEqual(tcp8443.unmodeledFields["ProxyProtocol"], .integer(2))

    // Verify Web unmodeled fields
    let webConfig = try XCTUnwrap(decoded.web["my-node.ts.net:443"])
    XCTAssertEqual(
      webConfig.unmodeledFields["CustomWebObject"],
      .object(["nestedKey": .string("nestedVal")])
    )

    // Verify Handler unmodeled fields
    let handler = try XCTUnwrap(webConfig.handlers["/api"])
    XCTAssertEqual(handler.proxy, "http://127.0.0.1:5000")
    XCTAssertEqual(handler.unmodeledFields["CustomHandlerInt"], .integer(1_234_567_890_123_456))
    XCTAssertEqual(handler.unmodeledFields["CustomHandlerNull"], .null)
    XCTAssertEqual(
      handler.unmodeledFields["CustomHandlerArray"],
      .array([.string("a"), .string("b"), .string("c")])
    )

    // Verify Service unmodeled fields
    let service = try XCTUnwrap(decoded.services["svc:custom"])
    XCTAssertEqual(service.tun, true)
    XCTAssertEqual(service.unmodeledFields["CustomServiceSetting"], .bool(true))

    // Encode back and verify equality and preservation
    let encoded = try JSONEncoder().encode(decoded)
    let redecoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: encoded)
    XCTAssertEqual(redecoded, decoded)

    let jsonObject =
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
      )
    XCTAssertEqual(jsonObject["CustomRootString"] as? String, "root-val")
    XCTAssertTrue(jsonObject.keys.contains("CustomRootNull"))
    XCTAssertTrue(jsonObject["CustomRootNull"] is NSNull)
  }

  func testServeConfigEqualityIncludesUnmodeledFields() {
    var configA = ServeConfig()
    var configB = ServeConfig()
    XCTAssertEqual(configA, configB)

    configA.unmodeledFields["Setting"] = .string("alpha")
    XCTAssertNotEqual(configA, configB)

    configB.unmodeledFields["Setting"] = .string("alpha")
    XCTAssertEqual(configA, configB)

    configB.unmodeledFields["Setting"] = .string("beta")
    XCTAssertNotEqual(configA, configB)
  }

  func testServeConfigIsEmptyIncludesUnmodeledFields() {
    var config = ServeConfig()
    XCTAssertTrue(config.isEmpty)

    config.unmodeledFields["FeatureFlag"] = .bool(true)
    XCTAssertFalse(config.isEmpty)

    config.unmodeledFields.removeAll()
    XCTAssertTrue(config.isEmpty)
  }

  // MARK: - Strict Port Key Validation Tests

  func testServeConfigRejectsMalformedTCPPortKeys() {
    let malformedKeys = ["bogus", "-1", "65536", "443abc", " 80", ""]
    for key in malformedKeys {
      let json = """
        {
          "TCP": {
            "\(key)": {
              "HTTPS": true
            }
          }
        }
        """
      XCTAssertThrowsError(
        try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(json.utf8)),
        "Expected decoding to fail for malformed TCP port key '\(key)'"
      ) { error in
        guard case DecodingError.dataCorrupted(let context) = error else {
          XCTFail("Expected DecodingError.dataCorrupted for '\(key)', got \(error)")
          return
        }
        XCTAssertTrue(
          context.debugDescription.contains(key)
            || context.debugDescription.contains("TCP port key")
        )
      }
    }
  }

  func testServiceConfigRejectsMalformedTCPPortKeys() {
    let json = """
      {
        "Services": {
          "svc:custom": {
            "TCP": {
              "invalid_port": {
                "HTTP": true
              }
            }
          }
        }
      }
      """
    XCTAssertThrowsError(
      try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(json.utf8))
    ) { error in
      guard case DecodingError.dataCorrupted = error else {
        XCTFail("Expected DecodingError.dataCorrupted, got \(error)")
        return
      }
    }
  }

  func testServeConfigAcceptsValidBoundaryTCPPortKeys() throws {
    let json = """
      {
        "TCP": {
          "0": {
            "HTTP": true
          },
          "65535": {
            "HTTPS": true
          }
        }
      }
      """
    let decoded = try JSONDecoder.tailscale().decode(ServeConfig.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.tcp[0]?.http, true)
    XCTAssertEqual(decoded.tcp[65535]?.https, true)
  }

  func testKnownKeyCollisionsAreNotDuplicatedOnEncode() throws {
    var config = ServeConfig()
    config.tcp[443] = TCPPortHandler(https: true)
    // Manually inject a collision key into unmodeledFields
    config.unmodeledFields["TCP"] = .string("should-be-ignored-on-encode")

    let encoded = try JSONEncoder().encode(config)
    let jsonObject =
      try XCTUnwrap(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
      )

    // The strongly typed TCP dictionary must prevail
    let tcpDict = try XCTUnwrap(jsonObject["TCP"] as? [String: Any])
    XCTAssertNotNil(tcpDict["443"])
  }
}
