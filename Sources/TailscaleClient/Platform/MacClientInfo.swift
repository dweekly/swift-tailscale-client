// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Darwin
import Foundation

#if os(macOS)
  struct MacClientInfo: Sendable {
    struct Result: Sendable {
      var port: UInt16
      var token: String
      var source: String
    }

    /// Locates the sameuserproof file asynchronously.
    ///
    /// Uses a two-tier discovery strategy:
    /// 1. **libproc** (PRIMARY): Uses `proc_pidinfo` to find IPNExtension's open files (~5ms)
    /// 2. **Filesystem fallback**: Enumerates Group Containers directories (~50-200ms)
    ///
    /// The libproc approach works because IPNExtension runs as the current user,
    /// allowing file descriptor inspection without special entitlements.
    func locateSameUserProofAsync() async -> Result? {
      await Task.detached(priority: .userInitiated) {
        self.locateSameUserProof()
      }.value
    }

    /// Locates the sameuserproof file synchronously.
    ///
    /// Prefer `locateSameUserProofAsync()` to avoid blocking the caller.
    func locateSameUserProof() -> Result? {
      // Check for explicit path override first
      if let pathOverride = ProcessInfo.processInfo.environment["TAILSCALE_SAMEUSER_PATH"] {
        let expanded = (pathOverride as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded),
          let parsed = parseSameUserProofPath(expanded)
        {
          log("Using TAILSCALE_SAMEUSER_PATH override: \(expanded)")
          return Result(port: parsed.port, token: parsed.token, source: expanded)
        }
      }

      // Try libproc first (fast and precise)
      if ProcessInfo.processInfo.environment["TAILSCALE_SKIP_LIBPROC"] != "1" {
        if let result = locateViaLibproc() {
          log("Found sameuserproof via libproc: \(result.source)")
          return result
        }
      }

      // Fall back to filesystem enumeration
      if let result = locateViaFilesystem() {
        log("Found sameuserproof via filesystem: \(result.source)")
        return result
      }

      log("did not find sameuserproof file")
      return nil
    }

    // MARK: - libproc discovery

    /// Finds the sameuserproof file by inspecting IPNExtension's open file descriptors.
    private func locateViaLibproc() -> Result? {
      // Find IPNExtension PID
      guard let pid = findIPNExtensionPID() else {
        log("IPNExtension process not found")
        return nil
      }
      log("Found IPNExtension at PID \(pid)")

      // Get buffer size for file descriptor list
      let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
      guard bufferSize > 0 else {
        log("proc_pidinfo failed to get buffer size: errno \(errno)")
        return nil
      }

      // Allocate and populate file descriptor list
      let fdInfoSize = MemoryLayout<proc_fdinfo>.stride
      let count = Int(bufferSize) / fdInfoSize
      var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)

      let actualSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferSize)
      guard actualSize > 0 else {
        log("proc_pidinfo failed to get fd list: errno \(errno)")
        return nil
      }

      let actualCount = Int(actualSize) / fdInfoSize

      // Inspect each vnode file descriptor for sameuserproof
      for i in 0..<actualCount {
        let fd = fds[i]
        guard fd.proc_fdtype == PROX_FDTYPE_VNODE else { continue }

        var vnodeInfo = vnode_fdinfowithpath()
        let vnodeSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)

        let result = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnodeInfo, vnodeSize)
        guard result > 0 else { continue }

        let path = withUnsafePointer(to: &vnodeInfo.pvip.vip_path) {
          $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
            String(cString: $0)
          }
        }

        if let parsed = parseSameUserProofPath(path) {
          return Result(port: parsed.port, token: parsed.token, source: path)
        }
      }

      log("No sameuserproof file found in IPNExtension's open files")
      return nil
    }

    /// Finds the PID of the IPNExtension process.
    private func findIPNExtensionPID() -> pid_t? {
      // Get list of all PIDs
      var pids = [pid_t](repeating: 0, count: 4096)
      let bytesUsed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
      guard bytesUsed > 0 else { return nil }

      let pidCount = Int(bytesUsed) / MemoryLayout<pid_t>.size

      // Search for IPNExtension by name
      for i in 0..<pidCount {
        let pid = pids[i]
        guard pid > 0 else { continue }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))

        if pathLength > 0 {
          pathBuffer[Int(pathLength)] = 0  // Ensure null termination
          let path = String(cString: &pathBuffer)
          if path.hasSuffix("/IPNExtension") || path.contains("/IPNExtension.appex/") {
            return pid
          }
        }
      }
      return nil
    }

    // MARK: - Filesystem discovery (fallback)

    private func locateViaFilesystem() -> Result? {
      let fm = FileManager.default
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

    // MARK: - Parsing

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
