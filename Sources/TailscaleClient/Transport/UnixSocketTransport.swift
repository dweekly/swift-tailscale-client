// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// An RAII wrapper managing a single POSIX file descriptor with single-ownership semantics.
///
/// Ensures:
/// - Thread-safe, idempotent closure of the underlying descriptor.
/// - Atomic transition of raw descriptor to `-1` before calling POSIX `close()`,
///   preventing descriptor reuse races.
/// - Automatic closure on deallocation if cancellation or error occurs before
///   explicit cleanup.
final class ManagedSocketFD: @unchecked Sendable {
  private let lock = NSLock()
  private var rawFD: Int32

  init(_ fd: Int32) {
    self.rawFD = fd
  }

  var fd: Int32 {
    lock.lock()
    defer { lock.unlock() }
    return rawFD
  }

  func close() {
    lock.lock()
    let fdToClose = rawFD
    rawFD = -1
    lock.unlock()

    if fdToClose >= 0 {
      #if canImport(Glibc)
        _ = Glibc.close(fdToClose)
      #else
        _ = Darwin.close(fdToClose)
      #endif
    }
  }

  deinit {
    close()
  }
}

/// Speaks HTTP/1.1 to the LocalAPI over a Unix domain socket using plain
/// POSIX calls, so the same code runs on Darwin and Linux. Wire-format
/// concerns live in `HTTPWireFormat`/`ChunkedTransferDecoder`, which are pure
/// and unit-tested; this type owns only the socket lifecycle.
struct UnixSocketTransport {
  /// Maximum response body size for unary requests over Unix socket (16 MiB).
  static let maxUnaryResponseBytes = 16 * 1024 * 1024

  let path: String

  func send(_ request: TailscaleRequest, capabilityVersion: Int) async throws -> TailscaleResponse {
    let transport = self
    // Bridge cancellation into the detached task so a request deadline
    // (Task cancellation) interrupts the blocking socket work.
    let task = Task.detached(priority: .userInitiated) {
      try transport.performSend(request, capabilityVersion: capabilityVersion)
    }
    do {
      return try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    } catch let error as TailscaleTransportError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw TailscaleTransportError.networkFailure(underlying: error)
    }
  }

  func sendStreaming(_ request: TailscaleRequest, capabilityVersion: Int) async throws
    -> StreamingResponse
  {
    let transport = self
    // Connect, send the request, and validate the response head BEFORE
    // returning, so callers get a thrown error (not a poisoned stream) when
    // the daemon is unreachable.
    let setup = Task.detached(priority: .userInitiated) {
      try transport.openStreamConnection(request, capabilityVersion: capabilityVersion)
    }
    let connection: StreamConnection
    do {
      connection = try await withTaskCancellationHandler {
        try await setup.value
      } onCancel: {
        setup.cancel()
      }
    } catch let error as TailscaleTransportError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw TailscaleTransportError.networkFailure(underlying: error)
    }

    let bodyStream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingNewest(256)) { continuation in
      let task = Task.detached(priority: .userInitiated) {
        defer { connection.socket.close() }
        do {
          try transport.streamBody(connection, continuation: continuation)
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }

    return StreamingResponse(
      statusCode: connection.statusCode,
      headers: connection.headers,
      body: bodyStream
    )
  }

  /// A validated streaming connection: the request has been written and the
  /// response head consumed; `initialBody` holds bytes read past it.
  struct StreamConnection: Sendable {
    let socket: ManagedSocketFD
    let statusCode: Int
    let headers: [String: String]
    let isChunked: Bool
    let initialBody: Data

    var fd: Int32 { socket.fd }
  }

  private func openStreamConnection(_ request: TailscaleRequest, capabilityVersion: Int) throws
    -> StreamConnection
  {
    let socket = try connectSocket()
    do {
      let requestData = HTTPWireFormat.requestData(
        for: request, capabilityVersion: capabilityVersion, keepAlive: true)
      try writeAll(socket, requestData)

      var headBuffer = HTTPHeadBuffer()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        try Task.checkCancellation()
        guard try waitReadable(socket.fd, timeoutMilliseconds: 500) else { continue }
        guard let readCount = try readSome(socket.fd, into: &buffer) else { continue }
        guard readCount > 0 else {
          throw TailscaleTransportError.malformedResponse(
            detail: "Connection closed before the response head arrived")
        }
        let incoming = Data(bytes: buffer, count: readCount)
        guard let (headData, bodyRemainder) = try headBuffer.feed(incoming) else { continue }
        let head = try HTTPWireFormat.parseResponseHead(headData)
        return StreamConnection(
          socket: socket,
          statusCode: head.statusCode,
          headers: head.headers,
          isChunked: head.isChunked,
          initialBody: bodyRemainder)
      }
    } catch {
      socket.close()
      throw error
    }
  }

  private func streamBody(
    _ connection: StreamConnection,
    continuation: AsyncThrowingStream<Data, Error>.Continuation
  ) throws {
    var framer = NewlineFramer()
    var chunkDecoder = connection.isChunked ? ChunkedTransferDecoder() : nil
    var buffer = [UInt8](repeating: 0, count: 4096)
    var pending = connection.initialBody

    while !Task.isCancelled {
      if !pending.isEmpty {
        let payload: Data
        if chunkDecoder != nil {
          payload = try chunkDecoder!.feed(pending)
          if chunkDecoder!.isComplete {
            for line in try framer.feed(payload) { continuation.yield(line) }
            if let remainder = try framer.flushRemainder() { continuation.yield(remainder) }
            continuation.finish()
            return
          }
        } else {
          payload = pending
        }
        for line in try framer.feed(payload) { continuation.yield(line) }
        pending = Data()
      }

      guard try waitReadable(connection.fd, timeoutMilliseconds: 500) else { continue }
      guard let readCount = try readSome(connection.fd, into: &buffer) else { continue }
      if readCount == 0 { break }  // Server closed the connection.
      pending = Data(bytes: buffer, count: readCount)
    }

    if let remainder = try framer.flushRemainder() {
      continuation.yield(remainder)
    }
    continuation.finish()
  }

  // MARK: - Unary

  private func performSend(_ request: TailscaleRequest, capabilityVersion: Int) throws
    -> TailscaleResponse
  {
    let socket = try connectSocket()
    defer { socket.close() }

    let requestData = HTTPWireFormat.requestData(
      for: request, capabilityVersion: capabilityVersion, keepAlive: false)
    try writeAll(socket, requestData)

    // Connection: close — read the entire response to EOF, polling so a
    // cancelled deadline interrupts a daemon that accepts the connection
    // but never answers or never closes it.
    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      try Task.checkCancellation()
      guard try waitReadable(socket.fd, timeoutMilliseconds: 500) else { continue }
      guard let readCount = try readSome(socket.fd, into: &buffer) else { continue }
      guard readCount > 0 else { break }
      guard responseData.count + readCount <= Self.maxUnaryResponseBytes else {
        throw TailscaleTransportError.malformedResponse(
          detail: "Unary response exceeded maximum allowed limit of \(Self.maxUnaryResponseBytes) bytes")
      }
      responseData.append(buffer, count: readCount)
    }

    var headBuffer = HTTPHeadBuffer()
    guard let (headData, body) = try headBuffer.feed(responseData) else {
      throw TailscaleTransportError.malformedResponse(
        detail: "Missing header/body separator (\\r\\n\\r\\n)")
    }
    let head = try HTTPWireFormat.parseResponseHead(headData)

    let bodyData = try HTTPWireFormat.decodeResponseBody(body, head: head)
    return TailscaleResponse(statusCode: head.statusCode, data: bodyData, headers: head.headers)
  }

  // MARK: - POSIX plumbing

  private func connectSocket() throws -> ManagedSocketFD {
    try Task.checkCancellation()

    let rawFD = socket(AF_UNIX, socketStreamType, 0)
    guard rawFD >= 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    let managed = ManagedSocketFD(rawFD)

    #if canImport(Darwin)
      // Linux suppresses SIGPIPE per send() via MSG_NOSIGNAL; Darwin does it per socket.
      var one: Int32 = 1
      setsockopt(rawFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #endif

    // Configure non-blocking and close-on-exec flags.
    let flags = fcntl(rawFD, F_GETFL, 0)
    guard flags >= 0, fcntl(rawFD, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      managed.close()
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    let fdFlags = fcntl(rawFD, F_GETFD, 0)
    if fdFlags >= 0 {
      _ = fcntl(rawFD, F_SETFD, fdFlags | FD_CLOEXEC)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path) / MemoryLayout<CChar>.stride
    guard path.utf8.count < maxPathLength else {
      managed.close()
      throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
      let base = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
      _ = strncpy(base, path, maxPathLength - 1)
    }
    let addrSize = socklen_t(
      MemoryLayout.size(ofValue: addr) - MemoryLayout.size(ofValue: addr.sun_path)
        + path.utf8.count + 1)

    let connectResult = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
        connect(rawFD, ptr, addrSize)
      }
    }

    if connectResult == 0 {
      return managed
    }

    let initialErrno = errno
    if initialErrno != EINPROGRESS && initialErrno != EINTR {
      managed.close()
      let code = POSIXErrorCode(rawValue: initialErrno) ?? .EIO
      switch code {
      case .ENOENT:
        throw TailscaleTransportError.socketNotFound(path: path)
      case .ECONNREFUSED:
        throw TailscaleTransportError.connectionRefused(endpoint: "unix:\(path)")
      default:
        throw POSIXError(code)
      }
    }

    // Cooperative connect poll loop: waits for POLLOUT checking Task.isCancelled.
    while true {
      do {
        try Task.checkCancellation()
      } catch {
        managed.close()
        throw error
      }

      var pollDescriptor = pollfd(fd: rawFD, events: Int16(POLLOUT), revents: 0)
      let pollResult = poll(&pollDescriptor, 1, 500)
      if pollResult < 0 {
        if errno == EINTR { continue }
        managed.close()
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
      if pollResult == 0 {
        // 500ms timeout: loop around to check Task.isCancelled
        continue
      }

      var errorValue: Int32 = 0
      var errorLength = socklen_t(MemoryLayout<Int32>.size)
      let status = getsockopt(rawFD, SOL_SOCKET, SO_ERROR, &errorValue, &errorLength)
      guard status == 0 else {
        managed.close()
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
      if errorValue != 0 {
        managed.close()
        let code = POSIXErrorCode(rawValue: errorValue) ?? .EIO
        switch code {
        case .ENOENT:
          throw TailscaleTransportError.socketNotFound(path: path)
        case .ECONNREFUSED:
          throw TailscaleTransportError.connectionRefused(endpoint: "unix:\(path)")
        default:
          throw POSIXError(code)
        }
      }
      break
    }
    return managed
  }

  private var socketStreamType: Int32 {
    #if canImport(Glibc)
      return Int32(SOCK_STREAM.rawValue)
    #else
      return SOCK_STREAM
    #endif
  }

  private func writeAll(_ socket: ManagedSocketFD, _ data: Data) throws {
    let rawFD = socket.fd
    guard rawFD >= 0 else { throw POSIXError(.EBADF) }

    try data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
      var bytesRemaining = pointer.count
      guard var currentPointer = pointer.baseAddress else { return }

      while bytesRemaining > 0 {
        try Task.checkCancellation()

        guard try waitWritable(rawFD, timeoutMilliseconds: 500) else {
          continue
        }

        #if canImport(Glibc)
          let written = Glibc.send(rawFD, currentPointer, bytesRemaining, Int32(MSG_NOSIGNAL))
        #else
          let written = Darwin.write(rawFD, currentPointer, bytesRemaining)
        #endif

        if written > 0 {
          bytesRemaining -= written
          currentPointer = currentPointer.advanced(by: written)
        } else if written < 0 {
          if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
            continue
          }
          let code = POSIXErrorCode(rawValue: errno) ?? .EIO
          if code == .EPIPE || code == .ECONNRESET {
            throw TailscaleTransportError.networkFailure(underlying: POSIXError(code))
          }
          throw POSIXError(code)
        } else {
          throw TailscaleTransportError.networkFailure(underlying: POSIXError(.EPIPE))
        }
      }
    }
  }

  private func waitWritable(_ fd: Int32, timeoutMilliseconds: Int32) throws -> Bool {
    guard fd >= 0 else { throw POSIXError(.EBADF) }
    var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let result = poll(&pollDescriptor, 1, timeoutMilliseconds)
    if result < 0 {
      if errno == EINTR { return false }
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return result > 0
  }

  /// Reads available bytes; returns nil on transient EAGAIN/EWOULDBLOCK, 0 on EOF. Retries EINTR.
  private func readSome(_ fd: Int32, into buffer: inout [UInt8]) throws -> Int? {
    guard fd >= 0 else { throw POSIXError(.EBADF) }
    while true {
      let readCount = read(fd, &buffer, buffer.count)
      if readCount >= 0 { return readCount }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        return nil
      }
      let code = POSIXErrorCode(rawValue: errno) ?? .EIO
      if code == .ECONNRESET {
        throw TailscaleTransportError.networkFailure(underlying: POSIXError(code))
      }
      throw POSIXError(code)
    }
  }

  /// Waits up to `timeoutMilliseconds` for the socket to become readable.
  /// Returns `false` on timeout or EINTR so the caller can re-check
  /// cancellation.
  private func waitReadable(_ fd: Int32, timeoutMilliseconds: Int32) throws -> Bool {
    guard fd >= 0 else { throw POSIXError(.EBADF) }
    var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let result = poll(&pollDescriptor, 1, timeoutMilliseconds)
    if result < 0 {
      if errno == EINTR { return false }
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return result > 0
  }
}
