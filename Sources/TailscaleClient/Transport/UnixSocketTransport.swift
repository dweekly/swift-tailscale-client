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
      let bodyData = data[separatorRange.upperBound...]
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
        let name = line[..<separatorIndex]
        let valueStart = line.index(after: separatorIndex)
        let value = line[valueStart...].trimmingCharacters(in: .whitespaces)
        headers[String(name)] = value
      }
      return TailscaleResponse(statusCode: statusCode, data: Data(bodyData), headers: headers)
    }
  #endif
}
