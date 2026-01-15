// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

#if canImport(Darwin)
  import Darwin
#endif

struct UnixSocketTransport {
  let path: String

  func send(_ request: TailscaleRequest, capabilityVersion: Int) async throws -> TailscaleResponse {
    #if canImport(Darwin)
      do {
        return try await Task.detached(priority: .userInitiated) {
          try performSend(request, capabilityVersion: capabilityVersion)
        }.value
      } catch let error as TailscaleTransportError {
        // Let our specific transport errors pass through unwrapped
        throw error
      } catch {
        throw TailscaleTransportError.networkFailure(underlying: error)
      }
    #else
      throw TailscaleTransportError.unimplemented
    #endif
  }

  #if canImport(Darwin)
    func sendStreaming(_ request: TailscaleRequest, capabilityVersion: Int) async throws
      -> AsyncThrowingStream<Data, Error>
    {
      // Capture self for the closure
      let transport = self
      // For Unix socket streaming, we create a persistent connection and read lines
      return AsyncThrowingStream { continuation in
        let task = Task.detached(priority: .userInitiated) {
          do {
            try transport.performStreamingRead(
              request, capabilityVersion: capabilityVersion, continuation: continuation)
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in
          task.cancel()
        }
      }
    }
  #else
    func sendStreaming(_ request: TailscaleRequest, capabilityVersion: Int) async throws
      -> AsyncThrowingStream<Data, Error>
    {
      throw TailscaleTransportError.unimplemented
    }
  #endif

  #if canImport(Darwin)
    private func performSend(_ request: TailscaleRequest, capabilityVersion: Int) throws
      -> TailscaleResponse
    {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
      defer { close(fd) }

      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path) / MemoryLayout<CChar>.stride
      guard path.utf8.count < maxPathLength else {
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
        switch code {
        case .ENOENT:
          throw TailscaleTransportError.socketNotFound(path: path)
        case .ECONNREFUSED:
          throw TailscaleTransportError.connectionRefused(endpoint: "unix:\(path)")
        default:
          throw POSIXError(code)
        }
      }

      let requestData = try buildHTTPRequestData(for: request, capabilityVersion: capabilityVersion)
      try requestData.withUnsafeBytes { pointer in
        var bytesRemaining = pointer.count
        var currentPointer = pointer.baseAddress!
        while bytesRemaining > 0 {
          let written = write(fd, currentPointer, bytesRemaining)
          if written <= 0 {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
          }
          bytesRemaining -= written
          currentPointer = currentPointer.advanced(by: written)
        }
      }

      var buffer = [UInt8](repeating: 0, count: 4096)
      var responseData = Data()
      while true {
        let readCount = read(fd, &buffer, buffer.count)
        if readCount > 0 {
          responseData.append(buffer, count: readCount)
        } else if readCount == 0 {
          break
        } else {
          throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
      }

      return try parseHTTPResponse(from: responseData)
    }

    private func buildHTTPRequestData(for request: TailscaleRequest, capabilityVersion: Int) throws
      -> Data
    {
      var components = URLComponents()
      components.queryItems = request.queryItems.isEmpty ? nil : request.queryItems
      let queryString = components.percentEncodedQuery.map { "?\($0)" } ?? ""
      let requestLine = "\(request.method) \(request.path)\(queryString) HTTP/1.1\r\n"

      var headers = request.additionalHeaders
      headers["Host"] = "local-tailscaled.sock"
      headers["Connection"] = "close"
      headers["Accept"] = "application/json"
      headers["Tailscale-Cap"] = String(capabilityVersion)
      if let body = request.body, body.isEmpty == false {
        headers["Content-Length"] = String(body.count)
      }

      let headerLines = headers.map { "\($0.key): \($0.value)\r\n" }.sorted()
      let headerString = headerLines.joined()
      var httpData = Data(requestLine.utf8)
      httpData.append(Data(headerString.utf8))
      httpData.append(Data("\r\n".utf8))
      if let body = request.body {
        httpData.append(body)
      }
      return httpData
    }

    private func parseHTTPResponse(from data: Data) throws -> TailscaleResponse {
      guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
        throw TailscaleTransportError.malformedResponse(
          detail: "Missing header/body separator (\\r\\n\\r\\n)")
      }
      let headerData = data[..<separatorRange.lowerBound]
      var bodyData = Data(data[separatorRange.upperBound...])
      guard let headerString = String(data: headerData, encoding: .utf8) else {
        throw TailscaleTransportError.malformedResponse(
          detail: "Headers not valid UTF-8")
      }
      let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)
      guard let statusLine = lines.first else {
        throw TailscaleTransportError.malformedResponse(
          detail: "Empty HTTP response")
      }
      let statusComponents = statusLine.split(separator: " ")
      guard statusComponents.count >= 2, let statusCode = Int(statusComponents[1]) else {
        throw TailscaleTransportError.malformedResponse(
          detail: "Invalid status line: '\(statusLine)'")
      }

      var headers: [String: String] = [:]
      for line in lines.dropFirst() {
        guard let separatorIndex = line.firstIndex(of: ":") else { continue }
        let name = String(line[..<separatorIndex]).lowercased()
        let valueStart = line.index(after: separatorIndex)
        let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
        headers[name] = value
      }

      // Handle chunked transfer encoding
      if headers["transfer-encoding"]?.lowercased() == "chunked" {
        bodyData = decodeChunked(bodyData)
      }

      return TailscaleResponse(statusCode: statusCode, data: bodyData, headers: headers)
    }

    /// Decodes HTTP chunked transfer encoding.
    private func decodeChunked(_ data: Data) -> Data {
      var result = Data()
      var index = data.startIndex
      let crlf = Data("\r\n".utf8)

      while index < data.endIndex {
        // Find the end of the chunk size line
        guard let crlfRange = data[index...].range(of: crlf) else { break }

        // Parse chunk size (hex)
        let sizeData = data[index..<crlfRange.lowerBound]
        guard let sizeString = String(data: sizeData, encoding: .utf8),
          let chunkSize = Int(sizeString.trimmingCharacters(in: .whitespaces), radix: 16)
        else { break }

        // End of chunks
        if chunkSize == 0 { break }

        // Move past the size line
        let chunkStart = crlfRange.upperBound

        // Extract chunk data
        let chunkEnd =
          data.index(chunkStart, offsetBy: chunkSize, limitedBy: data.endIndex)
          ?? data.endIndex
        result.append(data[chunkStart..<chunkEnd])

        // Move past chunk data and trailing CRLF
        index = chunkEnd
        if let nextCRLF = data[index...].range(of: crlf) {
          index = nextCRLF.upperBound
        } else {
          break
        }
      }

      return result
    }

    private func performStreamingRead(
      _ request: TailscaleRequest,
      capabilityVersion: Int,
      continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) throws {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }

      // Clean up socket when done
      defer {
        close(fd)
      }

      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path) / MemoryLayout<CChar>.stride
      guard path.utf8.count < maxPathLength else {
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
        switch code {
        case .ENOENT:
          throw TailscaleTransportError.socketNotFound(path: path)
        case .ECONNREFUSED:
          throw TailscaleTransportError.connectionRefused(endpoint: "unix:\(path)")
        default:
          throw POSIXError(code)
        }
      }

      // Build and send request - use keep-alive for streaming
      let requestData = try buildStreamingHTTPRequestData(
        for: request, capabilityVersion: capabilityVersion)
      try requestData.withUnsafeBytes { pointer in
        var bytesRemaining = pointer.count
        var currentPointer = pointer.baseAddress!
        while bytesRemaining > 0 {
          let written = write(fd, currentPointer, bytesRemaining)
          if written <= 0 {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
          }
          bytesRemaining -= written
          currentPointer = currentPointer.advanced(by: written)
        }
      }

      // Read HTTP headers first
      var headerBuffer = Data()
      var singleByte: UInt8 = 0
      let headerEnd = Data("\r\n\r\n".utf8)
      while true {
        let readCount = read(fd, &singleByte, 1)
        if readCount <= 0 {
          throw TailscaleTransportError.malformedResponse(
            detail: "Connection closed while reading headers")
        }
        headerBuffer.append(singleByte)
        // Check if buffer ends with \r\n\r\n
        if headerBuffer.count >= 4 {
          let suffix = headerBuffer.suffix(4)
          if suffix.elementsEqual(headerEnd) {
            break
          }
        }
      }

      // Parse headers to check for chunked encoding
      guard let headerString = String(data: headerBuffer, encoding: .utf8),
        let statusLine = headerString.split(separator: "\r\n").first
      else {
        throw TailscaleTransportError.malformedResponse(detail: "Invalid HTTP headers")
      }
      let statusComponents = statusLine.split(separator: " ")
      guard statusComponents.count >= 2, let statusCode = Int(statusComponents[1]),
        statusCode == 200
      else {
        throw TailscaleTransportError.malformedResponse(
          detail: "Streaming endpoint returned non-200 status")
      }

      // Check if response is chunked
      let isChunked = headerString.lowercased().contains("transfer-encoding: chunked")

      // Now read the body - handle chunked encoding if needed
      var lineBuffer = Data()
      var readBuffer = [UInt8](repeating: 0, count: 4096)

      // State for chunked decoding
      var chunkRemaining = 0
      var readingChunkSize = isChunked
      var chunkSizeBuffer = Data()

      while !Task.isCancelled {
        let readCount = read(fd, &readBuffer, readBuffer.count)
        if readCount > 0 {
          var i = 0
          while i < readCount {
            let byte = readBuffer[i]
            i += 1

            if isChunked {
              if readingChunkSize {
                // Reading chunk size line
                chunkSizeBuffer.append(byte)
                if chunkSizeBuffer.count >= 2,
                  chunkSizeBuffer[chunkSizeBuffer.count - 2] == UInt8(ascii: "\r"),
                  byte == UInt8(ascii: "\n")
                {
                  // Parse chunk size (remove trailing \r\n)
                  let sizeData = chunkSizeBuffer.dropLast(2)
                  if let sizeStr = String(data: sizeData, encoding: .utf8),
                    let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16)
                  {
                    chunkRemaining = size
                    if chunkRemaining == 0 {
                      // Final chunk - we're done
                      continuation.finish()
                      return
                    }
                  }
                  chunkSizeBuffer.removeAll(keepingCapacity: true)
                  readingChunkSize = false
                }
              } else {
                // Reading chunk data
                if chunkRemaining > 0 {
                  lineBuffer.append(byte)
                  chunkRemaining -= 1

                  // Check for complete JSON line
                  if byte == UInt8(ascii: "\n") {
                    let line = lineBuffer.dropLast()  // Remove newline
                    if !line.isEmpty {
                      continuation.yield(Data(line))
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                  }
                } else {
                  // Reading trailing \r\n after chunk data
                  if byte == UInt8(ascii: "\n") {
                    readingChunkSize = true
                  }
                }
              }
            } else {
              // Non-chunked: simple line-by-line reading
              lineBuffer.append(byte)
              if byte == UInt8(ascii: "\n") {
                let line = lineBuffer.dropLast()
                if !line.isEmpty {
                  continuation.yield(Data(line))
                }
                lineBuffer.removeAll(keepingCapacity: true)
              }
            }
          }
        } else if readCount == 0 {
          // Connection closed
          break
        } else {
          let errorCode = errno
          if errorCode == EINTR {
            continue  // Interrupted, retry
          }
          throw POSIXError(.init(rawValue: errorCode) ?? .EIO)
        }
      }

      // Send any remaining data
      if !lineBuffer.isEmpty {
        continuation.yield(lineBuffer)
      }
      continuation.finish()
    }

    private func buildStreamingHTTPRequestData(
      for request: TailscaleRequest, capabilityVersion: Int
    )
      throws -> Data
    {
      var components = URLComponents()
      components.queryItems = request.queryItems.isEmpty ? nil : request.queryItems
      let queryString = components.percentEncodedQuery.map { "?\($0)" } ?? ""
      let requestLine = "\(request.method) \(request.path)\(queryString) HTTP/1.1\r\n"

      var headers = request.additionalHeaders
      headers["Host"] = "local-tailscaled.sock"
      headers["Connection"] = "keep-alive"  // Keep connection open for streaming
      headers["Accept"] = "application/json"
      headers["Tailscale-Cap"] = String(capabilityVersion)
      if let body = request.body, body.isEmpty == false {
        headers["Content-Length"] = String(body.count)
      }

      let headerLines = headers.map { "\($0.key): \($0.value)\r\n" }.sorted()
      let headerString = headerLines.joined()
      var httpData = Data(requestLine.utf8)
      httpData.append(Data(headerString.utf8))
      httpData.append(Data("\r\n".utf8))
      if let body = request.body {
        httpData.append(body)
      }
      return httpData
    }
  #endif
}
