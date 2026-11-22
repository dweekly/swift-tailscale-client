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
  /// cancellation paths in `UnixSocketTransport`. `init(loopbackBehaviors:)`
  /// serves the same behaviors over loopback TCP instead.
  final class FaultUnixServer: @unchecked Sendable {
    enum Behavior {
      /// Accept the connection, read the request, and never send a byte.
      case acceptThenSilence
      /// Write the given raw bytes, then close (or hold the connection open).
      case respond(String, closeAfterWrite: Bool)
      /// Write `first`, hold the connection open in silence for `delay`
      /// seconds, write `second`, then keep holding the connection open.
      /// Records in ``peerClosedConnections`` when the client closes its
      /// side during the silence.
      case respondThenLater(String, after: TimeInterval, String)
    }

    /// Connections accepted so far.
    var acceptedConnections: Int {
      lock.lock()
      defer { lock.unlock() }
      return acceptedCount
    }

    /// The first read of each accepted connection's request, in accept order.
    var receivedRequests: [String] {
      lock.lock()
      defer { lock.unlock() }
      return requests
    }

    /// Connections the client closed while a `respondThenLater` behavior was
    /// waiting to send its second write.
    var peerClosedConnections: Int {
      lock.lock()
      defer { lock.unlock() }
      return peerClosedCount
    }

    /// The Unix socket path (empty for a loopback TCP server).
    let path: String
    /// The bound 127.0.0.1 port for a loopback TCP server (nil for a Unix socket).
    let port: UInt16?
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
    private var acceptedCount = 0
    private var peerClosedCount = 0
    private var requests: [String] = []

    private var thread: Thread?

    /// - Parameter behaviors: one entry per accepted connection; the last
    ///   entry repeats for any further connections.
    convenience init(behaviors: [Behavior]) throws {
      let path = NSTemporaryDirectory() + "fault-\(UUID().uuidString.prefix(8)).sock"

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
      self.init(listeningFD: fd, path: path, port: nil, behaviors: behaviors)
    }

    /// Serves the same behaviors over TCP on 127.0.0.1 with a kernel-chosen
    /// port, for exercising the loopback (URLSession) transport against a
    /// real connection.
    convenience init(loopbackBehaviors behaviors: [Behavior]) throws {
      let fd = socket(AF_INET, Self.streamType, 0)
      guard fd >= 0 else { throw POSIXError(.EIO) }

      var addr = sockaddr_in()
      addr.sin_family = sa_family_t(AF_INET)
      addr.sin_port = 0
      addr.sin_addr.s_addr = inet_addr("127.0.0.1")
      var size = socklen_t(MemoryLayout<sockaddr_in>.size)
      let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
      }
      guard bindResult == 0, listen(fd, 4) == 0 else {
        close(fd)
        throw POSIXError(.EIO)
      }
      let nameResult = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
      }
      guard nameResult == 0 else {
        close(fd)
        throw POSIXError(.EIO)
      }
      self.init(
        listeningFD: fd, path: "", port: UInt16(bigEndian: addr.sin_port), behaviors: behaviors)
    }

    private init(listeningFD fd: Int32, path: String, port: UInt16?, behaviors: [Behavior]) {
      self.behaviors = behaviors
      self.path = path
      self.port = port
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
        acceptedCount += 1
        lock.unlock()

        // Drain whatever request bytes arrive first.
        var buffer = [UInt8](repeating: 0, count: 4096)
        let requestCount = read(fd, &buffer, buffer.count)
        let request = String(decoding: buffer.prefix(max(0, requestCount)), as: UTF8.self)
        lock.lock()
        requests.append(request)
        lock.unlock()

        let behavior =
          connectionIndex < behaviors.count ? behaviors[connectionIndex] : behaviors.last!
        connectionIndex += 1

        switch behavior {
        case .acceptThenSilence:
          break  // Hold the fd open; the client must time out on its own.
        case .respond(let text, let closeAfterWrite):
          writeAll(fd, text)
          if closeAfterWrite {
            // Take ownership under the lock so a concurrent stop() cannot
            // also close this descriptor.
            lock.lock()
            let owned = openFDs.contains(fd)
            openFDs.removeAll { $0 == fd }
            lock.unlock()
            if owned { close(fd) }
          }
        case .respondThenLater(let first, let delay, let second):
          writeAll(fd, first)
          if waitForPeerClose(fd, seconds: delay) {
            lock.lock()
            peerClosedCount += 1
            lock.unlock()
          } else {
            writeAll(fd, second)
          }
        }
      }
    }

    private func writeAll(_ fd: Int32, _ text: String) {
      #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        _ = setsockopt(
          fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
      #endif
      text.utf8CString.withUnsafeBufferPointer { pointer in
        var offset = 0
        while offset < pointer.count - 1, !isStopped {
          #if canImport(Glibc)
            let count = send(
              fd, pointer.baseAddress!.advanced(by: offset), pointer.count - 1 - offset,
              Int32(MSG_NOSIGNAL))
          #else
            let count = write(
              fd, pointer.baseAddress!.advanced(by: offset), pointer.count - 1 - offset)
          #endif
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { break }
          offset += count
        }
      }
    }

    /// Waits up to `seconds`, polling every 50 ms. Returns true as soon as
    /// the client closes its side (a read returns EOF or an error), false
    /// when the time elapses or the server stops first.
    private func waitForPeerClose(_ fd: Int32, seconds: TimeInterval) -> Bool {
      let deadline = Date().addingTimeInterval(seconds)
      var buffer = [UInt8](repeating: 0, count: 4096)
      while Date() < deadline, !isStopped {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 50) > 0 else { continue }
        let count = read(fd, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        if count <= 0 { return !isStopped }
      }
      return false
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
      if !keepSocketFile, !path.isEmpty {
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
