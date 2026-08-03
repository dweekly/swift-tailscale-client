// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

#if os(macOS)
  import Darwin
  import os
#endif

#if os(macOS)
  struct MacClientInfo: Sendable {
    struct Result: Sendable {
      var port: UInt16
      var token: String
      var source: String
    }

    /// Liveness probe for a loopback candidate; injectable for tests.
    /// Defaults to an authenticated status request against the port.
    var probeOverride: (@Sendable (UInt16, String) -> Bool)?

    /// Candidate directories to scan; injectable for tests. Defaults to
    /// Tailscale's Group Containers (plus `TAILSCALE_SAMEUSER_DIR`).
    var directoriesOverride: [URL]?

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

    func locateViaFilesystem() -> Result? {
      let fm = FileManager.default
      var candidates: [(url: URL, port: UInt16, token: String, modified: Date)] = []
      for dir in candidateDirectories() {
        guard fm.fileExists(atPath: dir.path) else { continue }
        log("Scanning directory \(dir.path) for sameuserproof files")
        // Shallow scan only: proof files sit directly in the Tailscale
        // container; recursing through all of Group Containers wastes time
        // and risks touching unrelated apps' data.
        guard
          let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { continue }
        for fileURL in contents {
          guard let parsed = parseSameUserProofPath(fileURL.path) else { continue }
          let modified =
            (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
              .contentModificationDate) ?? .distantPast
          candidates.append((fileURL, parsed.port, parsed.token, modified))
        }
      }
      // Proof files from previously installed flavors linger, so candidates
      // are liveness-probed — concurrently, under one overall deadline, so a
      // pile of stale files cannot stack sequential waits and freeze a
      // synchronous caller. Newest live candidate wins.
      let probe = probeOverride ?? Self.liveProbe
      let ordered = candidates.sorted { $0.modified > $1.modified }
      guard !ordered.isEmpty else { return nil }

      let results = OSAllocatedUnfairLock(initialState: [Int: Bool]())
      let group = DispatchGroup()
      for (index, candidate) in ordered.enumerated() {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
          let alive = probe(candidate.port, candidate.token)
          results.withLock { $0[index] = alive }
          group.leave()
        }
      }
      _ = group.wait(timeout: .now() + 1.5)

      let snapshot = results.withLock { $0 }
      for (index, candidate) in ordered.enumerated() {
        if snapshot[index] == true {
          return Result(
            port: candidate.port, token: candidate.token, source: candidate.url.path)
        }
        let reason = snapshot[index] == nil ? "probe timed out" : "port not answering"
        log("Ignoring sameuserproof at \(candidate.url.path) (\(reason))")
      }
      return nil
    }

    /// Confirms a loopback LocalAPI candidate actually answers an
    /// authenticated status request before it is selected.
    private static let liveProbe: @Sendable (UInt16, String) -> Bool = { port, token in
      guard let url = URL(string: "http://127.0.0.1:\(port)/localapi/v0/status?peers=false")
      else { return false }
      var request = URLRequest(url: url, timeoutInterval: 0.8)
      let credentials = Data(":\(token)".utf8).base64EncodedString()
      request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
      let semaphore = DispatchSemaphore(value: 0)
      let alive = OSAllocatedUnfairLock(initialState: false)
      URLSession.shared.dataTask(with: request) { _, response, _ in
        if (response as? HTTPURLResponse)?.statusCode == 200 {
          alive.withLock { $0 = true }
        }
        semaphore.signal()
      }.resume()
      _ = semaphore.wait(timeout: .now() + 1.0)
      return alive.withLock { $0 }
    }

    private func candidateDirectories() -> [URL] {
      if let directoriesOverride { return directoriesOverride }
      var urls: [URL] = []
      let fm = FileManager.default
      if let dirOverride = ProcessInfo.processInfo.environment["TAILSCALE_SAMEUSER_DIR"] {
        let expanded = (dirOverride as NSString).expandingTildeInPath
        urls.append(URL(fileURLWithPath: expanded, isDirectory: true))
      }
      let homeGroup = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Group Containers", isDirectory: true)
      let systemGroup = URL(fileURLWithPath: "/Library/Group Containers", isDirectory: true)
      // Only Tailscale's own containers are scanned — never the whole
      // Group Containers tree.
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
