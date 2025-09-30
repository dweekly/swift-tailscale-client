// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

#if os(macOS)
  struct MacClientInfo {
    struct Result {
      var port: UInt16
      var token: String
      var source: String
    }

    func locateSameUserProof() -> Result? {
      if ProcessInfo.processInfo.environment["TAILSCALE_SKIP_LSOF"] != "1",
        let result = locateViaLsof()
      {
        return result
      }
      if let result = locateViaFilesystem() {
        log("Falling back to filesystem discovery, path: \(result.source)")
        return result
      }
      log("did not find sameuserproof file")
      return nil
    }

    // MARK: - lsof discovery

    private func locateViaLsof() -> Result? {
      let lsofPath = "/usr/sbin/lsof"
      guard FileManager.default.isExecutableFile(atPath: lsofPath) else {
        log("lsof not available at \(lsofPath)")
        return nil
      }
      for processName in ["IPNExtension", "Tailscale"] {
        if let result = runLsof(processName: processName, lsofPath: lsofPath) {
          return result
        }
      }
      return nil
    }

    private func runLsof(processName: String, lsofPath: String) -> Result? {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: lsofPath)
      process.arguments = ["-n", "-a", "-c", processName, "-F", "n"]
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.standardOutput = outputPipe
      process.standardError = errorPipe
      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        log("Failed to run lsof for \(processName): \(error)")
        return nil
      }
      let status = process.terminationStatus
      if status != 0 {
        let errorOutput =
          String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        log(
          "lsof exited with status \(status) for \(processName): \(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
        return nil
      }
      let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
      guard let output = String(data: data, encoding: .utf8) else {
        return nil
      }
      for line in output.split(separator: "\n") {
        guard line.hasPrefix("n") else { continue }
        let path = String(line.dropFirst())
        if let parsed = parseSameUserProofPath(path) {
          log("Found sameuserproof via lsof (process=\(processName)) at \(path)")
          return Result(port: parsed.port, token: parsed.token, source: path)
        }
      }
      return nil
    }

    // MARK: - Filesystem fallback

    private func locateViaFilesystem() -> Result? {
      let fm = FileManager.default
      if let pathOverride = ProcessInfo.processInfo.environment["TAILSCALE_SAMEUSER_PATH"] {
        let expanded = (pathOverride as NSString).expandingTildeInPath
        if fm.fileExists(atPath: expanded), let parsed = parseSameUserProofPath(expanded) {
          log("Using TAILSCALE_SAMEUSER_PATH override: \(expanded)")
          return Result(port: parsed.port, token: parsed.token, source: expanded)
        }
      }
      for url in candidateDirectories() {
        guard fm.fileExists(atPath: url.path) else { continue }
        log("Scanning directory \(url.path) for sameuserproof files")
        if let enumerator = fm.enumerator(
          at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        {
          for case let fileURL as URL in enumerator {
            if let parsed = parseSameUserProofPath(fileURL.path) {
              return Result(port: parsed.port, token: parsed.token, source: fileURL.path)
            }
          }
        }
      }
      return nil
    }

    private func candidateDirectories() -> [URL] {
      var urls: [URL] = []
      let fm = FileManager.default
      if let dirOverride = ProcessInfo.processInfo.environment["TAILSCALE_SAMEUSER_DIR"] {
        let expanded = (dirOverride as NSString).expandingTildeInPath
        urls.append(URL(fileURLWithPath: expanded, isDirectory: true))
      }
      let homeGroup = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Group Containers", isDirectory: true)
      let systemGroup = URL(fileURLWithPath: "/Library/Group Containers", isDirectory: true)
      urls.append(homeGroup)
      urls.append(systemGroup)
      if let homeContents = try? fm.contentsOfDirectory(
        at: homeGroup, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      {
        urls.append(contentsOf: homeContents.filter { $0.lastPathComponent.contains("tailscale") })
      }
      if let systemContents = try? fm.contentsOfDirectory(
        at: systemGroup, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      {
        urls.append(
          contentsOf: systemContents.filter { $0.lastPathComponent.contains("tailscale") })
      }
      return urls
    }

    private func parseSameUserProofPath(_ path: String) -> (port: UInt16, token: String)? {
      guard let filename = path.split(separator: "/").last,
        filename.hasPrefix("sameuserproof-")
      else { return nil }
      let components = filename.split(separator: "-")
      guard components.count >= 3, let port = UInt16(components[1]) else { return nil }
      let token = components.dropFirst(2).joined(separator: "-")
      return (port, String(token))
    }

    private func log(_ message: String) {
      if ProcessInfo.processInfo.environment["TAILSCALE_DISCOVERY_DEBUG"] == "1" {
        fputs("[MacClientInfo] \(message)\n", stderr)
      }
    }
  }
#endif
