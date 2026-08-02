// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// Prints a value as pretty, stably-ordered JSON — the shared implementation
/// behind every subcommand's `--json` flag.
func printJSON<T: Encodable>(_ value: T) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  encoder.dateEncodingStrategy = .iso8601
  let data = try encoder.encode(value)
  print(String(decoding: data, as: UTF8.self))
}
