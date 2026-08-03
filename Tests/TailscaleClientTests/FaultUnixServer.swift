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

    /// One lock guards all lifecycle state below. Every file descriptor is
    /// closed exactly once: ownership is transferred out under the lock
    /// (`listenFD = -1`, removal from `openFDs`) before the close happens,
    /// so a stop() racing the accept thread — or a second stop() from
    /// deinit after `defer { server.stop() }` — can never double-close a
    /// descriptor number the OS may have already reused.
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var openFDs: [Int32] = []
    private var stopped = false

    private var thread: Thread?

    /// - Parameter behaviors: one entry per accepted connection; the last
    ///   entry repeats for any further connections.
    init(behaviors: [Behavior]) throws {
      self.behaviors = behaviors
      self.path = NSTemporaryDirectory() + "fault-\(UUID().uuidString.prefix(8)).sock"

      let fd = socket(AF_UNIX, Self.streamType, 0)
      guard fd >= 0 else { throw POSIXError(.EIO) }

      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let maxLength = MemoryLayout.size(ofValue: addr.sun_path) / MemoryLayout<CChar>.stride
      guard path.utf8.count < maxLength else {
        close(fd)
        throw POSIXError(.ENAMETOOLONG)
      }
      withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        let base = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
        _ = strncpy(base, path, maxLength - 1)
      }
      let size = socklen_t(MemoryLayout<sockaddr_un>.size)
      let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
      }
      guard bindResult == 0, listen(fd, 4) == 0 else {
        close(fd)
        throw POSIXError(.EIO)
      }
      listenFD = fd

      let thread = Thread { [weak self] in self?.acceptLoop(listenerFD: fd) }
      thread.name = "FaultUnixServer"
      thread.start()
      self.thread = thread
    }

    private func acceptLoop(listenerFD: Int32) {
      var connectionIndex = 0
      while !isStopped {
        let fd = accept(listenerFD, nil, nil)
        guard fd >= 0 else { return }

        lock.lock()
        if stopped {
          // stop() already ran and will never see this fd; close it here.
          lock.unlock()
          close(fd)
          return
        }
        openFDs.append(fd)
        lock.unlock()

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
            // Take ownership under the lock so a concurrent stop() cannot
            // also close this descriptor.
            lock.lock()
            let owned = openFDs.contains(fd)
            openFDs.removeAll { $0 == fd }
            lock.unlock()
            if owned { close(fd) }
          }
        }
      }
    }

    private var isStopped: Bool {
      lock.lock()
      defer { lock.unlock() }
      return stopped
    }

    /// Stops the server. Thread-safe and idempotent: only the first call
    /// closes descriptors; later calls (including deinit after a
    /// `defer { server.stop() }`) are no-ops apart from the unlink.
    /// Pass `keepSocketFile: true` to leave the (now unserved) socket file
    /// behind, which makes connects fail with ECONNREFUSED instead of ENOENT.
    func stop(keepSocketFile: Bool = false) {
      lock.lock()
      let alreadyStopped = stopped
      stopped = true
      let listener = listenFD
      listenFD = -1
      let connections = openFDs
      openFDs.removeAll()
      lock.unlock()

      if !alreadyStopped {
        if listener >= 0 { close(listener) }
        for fd in connections { close(fd) }
      }
      if !keepSocketFile {
        unlink(path)
      }
    }

    deinit {
      stop()
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
