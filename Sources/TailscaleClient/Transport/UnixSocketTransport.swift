// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Speaks HTTP/1.1 to the LocalAPI over a Unix domain socket using plain
/// POSIX calls, so the same code runs on Darwin and Linux. Wire-format
/// concerns live in `HTTPWireFormat`/`ChunkedTransferDecoder`, which are pure
/// and unit-tested; this type owns only the socket lifecycle.
struct UnixSocketTransport {
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
    -> AsyncThrowingStream<Data, Error>
  {
    let transport = self
    // Connect, send the request, and validate the response head BEFORE
    // returning, so callers get a thrown error (not a poisoned stream) when
    // the daemon is unreachable or rejects the request.
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
    } catch {
      throw TailscaleTransportError.networkFailure(underlying: error)
    }

    return AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .userInitiated) {
        defer { transport.closeSocket(connection.fd) }
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
  }

  /// A validated streaming connection: the request has been written and the
  /// 200 response head consumed; `initialBody` holds bytes read past it.
  struct StreamConnection: Sendable {
    let fd: Int32
    let isChunked: Bool
    let initialBody: Data
  }

  private func openStreamConnection(_ request: TailscaleRequest, capabilityVersion: Int) throws
    -> StreamConnection
  {
    let fd = try connectSocket()
    do {
      let requestData = HTTPWireFormat.requestData(
        for: request, capabilityVersion: capabilityVersion, keepAlive: true)
      try writeAll(fd, requestData)

      var headBuffer = HTTPHeadBuffer()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        try Task.checkCancellation()
        guard try waitReadable(fd, timeoutMilliseconds: 500) else { continue }
        let readCount = try readSome(fd, into: &buffer)
        guard readCount > 0 else {
          throw TailscaleTransportError.malformedResponse(
            detail: "Connection closed before the response head arrived")
        }
        let incoming = Data(bytes: buffer, count: readCount)
        guard let (headData, bodyRemainder) = try headBuffer.feed(incoming) else { continue }
        let head = try HTTPWireFormat.parseResponseHead(headData)
        guard head.statusCode == 200 else {
          throw TailscaleTransportError.malformedResponse(
            detail: "Streaming endpoint returned status \(head.statusCode)")
        }
        return StreamConnection(fd: fd, isChunked: head.isChunked, initialBody: bodyRemainder)
      }
    } catch {
      closeSocket(fd)
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
            for line in framer.feed(payload) { continuation.yield(line) }
            if let remainder = framer.flushRemainder() { continuation.yield(remainder) }
            continuation.finish()
            return
          }
        } else {
          payload = pending
        }
        for line in framer.feed(payload) { continuation.yield(line) }
        pending = Data()
      }

      guard try waitReadable(connection.fd, timeoutMilliseconds: 500) else { continue }
      let readCount = try readSome(connection.fd, into: &buffer)
      if readCount == 0 { break }  // Server closed the connection.
      pending = Data(bytes: buffer, count: readCount)
    }

    if let remainder = framer.flushRemainder() {
      continuation.yield(remainder)
    }
    continuation.finish()
  }

  // MARK: - Unary

  private func performSend(_ request: TailscaleRequest, capabilityVersion: Int) throws
    -> TailscaleResponse
  {
    let fd = try connectSocket()
    defer { closeSocket(fd) }

    let requestData = HTTPWireFormat.requestData(
      for: request, capabilityVersion: capabilityVersion, keepAlive: false)
    try writeAll(fd, requestData)

    // Connection: close — read the entire response to EOF, polling so a
    // cancelled deadline interrupts a daemon that accepts the connection
    // but never answers or never closes it.
    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      try Task.checkCancellation()
      guard try waitReadable(fd, timeoutMilliseconds: 500) else { continue }
      let readCount = try readSome(fd, into: &buffer)
      guard readCount > 0 else { break }
      responseData.append(buffer, count: readCount)
    }

    var headBuffer = HTTPHeadBuffer()
    guard let (headData, body) = try headBuffer.feed(responseData) else {
      throw TailscaleTransportError.malformedResponse(
        detail: "Missing header/body separator (\\r\\n\\r\\n)")
    }
    let head = try HTTPWireFormat.parseResponseHead(headData)

    var bodyData = body
    if head.isChunked {
      var decoder = ChunkedTransferDecoder()
      bodyData = try decoder.feed(body)
    }
    return TailscaleResponse(statusCode: head.statusCode, data: bodyData, headers: head.headers)
  }

  // MARK: - POSIX plumbing

  private func connectSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, socketStreamType, 0)
    guard fd >= 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }

    #if canImport(Darwin)
      // Linux suppresses SIGPIPE per send() via MSG_NOSIGNAL; Darwin does it
      // per socket.
      var one: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #endif

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path) / MemoryLayout<CChar>.stride
    guard path.utf8.count < maxPathLength else {
      closeSocket(fd)
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
        connect(fd, ptr, addrSize)
      }
    }
    guard connectResult == 0 else {
      let code = POSIXErrorCode(rawValue: errno) ?? .EIO
      closeSocket(fd)
      switch code {
      case .ENOENT:
        throw TailscaleTransportError.socketNotFound(path: path)
      case .ECONNREFUSED:
        throw TailscaleTransportError.connectionRefused(endpoint: "unix:\(path)")
      default:
        throw POSIXError(code)
      }
    }
    return fd
  }

  private var socketStreamType: Int32 {
    #if canImport(Glibc)
      return Int32(SOCK_STREAM.rawValue)
    #else
      return SOCK_STREAM
    #endif
  }

  private func closeSocket(_ fd: Int32) {
    _ = close(fd)
  }

  private func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { pointer in
      var bytesRemaining = pointer.count
      var currentPointer = pointer.baseAddress!
      while bytesRemaining > 0 {
        #if canImport(Glibc)
          let written = Glibc.send(fd, currentPointer, bytesRemaining, Int32(MSG_NOSIGNAL))
        #else
          let written = write(fd, currentPointer, bytesRemaining)
        #endif
        if written <= 0 {
          if errno == EINTR { continue }
          throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        bytesRemaining -= written
        currentPointer = currentPointer.advanced(by: written)
      }
    }
  }

  /// Reads available bytes; returns 0 at EOF. Retries EINTR.
  private func readSome(_ fd: Int32, into buffer: inout [UInt8]) throws -> Int {
    while true {
      let readCount = read(fd, &buffer, buffer.count)
      if readCount >= 0 { return readCount }
      if errno == EINTR { continue }
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
  }

  /// Waits up to `timeoutMilliseconds` for the socket to become readable.
  /// Returns `false` on timeout or EINTR so the caller can re-check
  /// cancellation.
  private func waitReadable(_ fd: Int32, timeoutMilliseconds: Int32) throws -> Bool {
    var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let result = poll(&pollDescriptor, 1, timeoutMilliseconds)
    if result < 0 {
      if errno == EINTR { return false }
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return result > 0
  }
}
