// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation
import XCTest

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

#if canImport(Darwin) || os(Linux)
  /// A minimal Unix-socket test server for exercising transport failure
  /// modes against a *real* socket — mocks cannot prove the poll and
  /// cancellation paths in `UnixSocketTransport`.
  final class FaultUnixServer: @unchecked Sendable {
    enum Behavior {
      /// Accept the connection, read the request, and never send a byte.
      case acceptThenSilence
      /// Write the given raw bytes, then close (or hold the connection open).
      case respond(String, closeAfterWrite: Bool)
    }

    let path: String
    private let behaviors: [Behavior]
    private var listenFD: Int32 = -1
    private let heldFDs = NSLock()
    private var openFDs: [Int32] = []
    private var thread: Thread?
    private var stopped = false

    /// - Parameter behaviors: one entry per accepted connection; the last
    ///   entry repeats for any further connections.
    init(behaviors: [Behavior]) throws {
      self.behaviors = behaviors
      self.path = NSTemporaryDirectory() + "fault-\(UUID().uuidString.prefix(8)).sock"

      listenFD = socket(AF_UNIX, Self.streamType, 0)
      guard listenFD >= 0 else { throw POSIXError(.EIO) }

      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let maxLength = MemoryLayout.size(ofValue: addr.sun_path) / MemoryLayout<CChar>.stride
      guard path.utf8.count < maxLength else { throw POSIXError(.ENAMETOOLONG) }
      withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        let base = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
        _ = strncpy(base, path, maxLength - 1)
      }
      let size = socklen_t(MemoryLayout<sockaddr_un>.size)
      let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
      }
      guard bindResult == 0, listen(listenFD, 4) == 0 else {
        close(listenFD)
        throw POSIXError(.EIO)
      }

      let thread = Thread { [weak self] in self?.acceptLoop() }
      thread.name = "FaultUnixServer"
      thread.start()
      self.thread = thread
    }

    private func acceptLoop() {
      var connectionIndex = 0
      while !stopped {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        heldFDs.lock()
        openFDs.append(fd)
        heldFDs.unlock()

        // Drain whatever request bytes arrive first.
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = read(fd, &buffer, buffer.count)

        let behavior =
          connectionIndex < behaviors.count ? behaviors[connectionIndex] : behaviors.last!
        connectionIndex += 1

        switch behavior {
        case .acceptThenSilence:
          break  // Hold the fd open; the client must time out on its own.
        case .respond(let text, let closeAfterWrite):
          text.utf8CString.withUnsafeBufferPointer { pointer in
            _ = write(fd, pointer.baseAddress, pointer.count - 1)  // omit NUL
          }
          if closeAfterWrite {
            close(fd)
            heldFDs.lock()
            openFDs.removeAll { $0 == fd }
            heldFDs.unlock()
          }
        }
      }
    }

    /// Stops the server. Pass `keepSocketFile: true` to leave the (now
    /// unserved) socket file behind, which makes connects fail with
    /// ECONNREFUSED instead of ENOENT.
    func stop(keepSocketFile: Bool = false) {
      stopped = true
      if listenFD >= 0 { close(listenFD) }
      heldFDs.lock()
      for fd in openFDs { close(fd) }
      openFDs.removeAll()
      heldFDs.unlock()
      if !keepSocketFile {
        unlink(path)
      }
    }

    deinit {
      stop()
      unlink(path)
    }

    private static var streamType: Int32 {
      #if canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue)
      #else
        return SOCK_STREAM
      #endif
    }
  }
#endif
