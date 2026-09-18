// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

/// An actor managing byte-bounded buffering and cooperative backpressure for
/// transport-level streaming response bodies.
///
/// Ensures that slow consumers do not cause unbounded memory growth or silent
/// packet loss. If buffered bytes reach the high-water mark, `enqueue` suspends the
/// reader (applying backpressure to the underlying socket/connection). If the
/// hard `maxByteCount` ceiling is exceeded, it terminates the stream with an explicit
/// `TailscaleTransportError.malformedResponse` indicating buffer overflow.
actor TransportByteBoundedQueue {
  private var buffer: [Data] = []
  private var currentByteCount: Int = 0
  private let maxByteCount: Int
  private let highWaterMark: Int
  private let lowWaterMark: Int

  private var consumerContinuation: CheckedContinuation<Data?, Error>?
  private var producerContinuations: [CheckedContinuation<Void, Error>] = []
  private var isFinished: Bool = false
  private var terminalError: Error?

  init(
    maxByteCount: Int = 16 * 1024 * 1024,
    highWaterMark: Int = 256 * 1024,
    lowWaterMark: Int = 64 * 1024
  ) {
    self.maxByteCount = maxByteCount
    self.highWaterMark = highWaterMark
    self.lowWaterMark = lowWaterMark
  }

  func enqueue(_ data: Data) async throws {
    guard !isFinished, terminalError == nil else { return }

    // If consumer is already waiting for the next chunk, hand it directly.
    if let cont = consumerContinuation {
      consumerContinuation = nil
      cont.resume(returning: data)
      return
    }

    // Check hard byte ceiling
    if (currentByteCount + data.count) > maxByteCount {
      let error = TailscaleTransportError.malformedResponse(
        detail:
          "Streaming body buffer overflow: slow consumer exceeded byte limit of \(maxByteCount) bytes"
      )
      terminalError = error
      buffer.removeAll()
      currentByteCount = 0
      resumeProducers(throwing: error)
      throw error
    }

    buffer.append(data)
    currentByteCount += data.count

    // If buffered bytes exceed high-water mark, suspend producer (backpressure)
    if currentByteCount >= highWaterMark {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
          producerContinuations.append(cont)
        }
      } onCancel: {
        Task { [weak self] in
          await self?.cancelProducers()
        }
      }
    }
  }

  func next() async throws -> Data? {
    try Task.checkCancellation()

    if !buffer.isEmpty {
      let data = buffer.removeFirst()
      currentByteCount -= data.count

      // If buffer drained below low-water mark, resume suspended producers
      if currentByteCount <= lowWaterMark && !producerContinuations.isEmpty {
        let producers = producerContinuations
        producerContinuations.removeAll()
        for p in producers {
          p.resume()
        }
      }
      return data
    }

    if let error = terminalError {
      throw error
    }

    if isFinished {
      return nil
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.consumerContinuation = continuation
      }
    } onCancel: {
      Task { [weak self] in
        await self?.cancelConsumer()
      }
    }
  }

  func finish() {
    guard !isFinished, terminalError == nil else { return }
    isFinished = true
    if let cont = consumerContinuation {
      consumerContinuation = nil
      cont.resume(returning: nil)
    }
    resumeProducers(throwing: CancellationError())
  }

  func fail(_ error: Error) {
    guard !isFinished, terminalError == nil else { return }
    terminalError = error
    buffer.removeAll()
    currentByteCount = 0
    if let cont = consumerContinuation {
      consumerContinuation = nil
      cont.resume(throwing: error)
    }
    resumeProducers(throwing: error)
  }

  func cancelConsumer() {
    if let cont = consumerContinuation {
      consumerContinuation = nil
      cont.resume(throwing: CancellationError())
    }
    resumeProducers(throwing: CancellationError())
  }

  func cancelProducers() {
    resumeProducers(throwing: CancellationError())
  }

  private func resumeProducers(throwing error: Error) {
    let producers = producerContinuations
    producerContinuations.removeAll()
    for p in producers {
      p.resume(throwing: error)
    }
  }
}

/// Lifetime context ensuring that when a streaming body consumer finishes or drops
/// the stream, the underlying background reader task is cancelled deterministically.
final class TransportStreamContext: @unchecked Sendable {
  let queue: TransportByteBoundedQueue
  private let task: Task<Void, Never>

  init(queue: TransportByteBoundedQueue, task: Task<Void, Never>) {
    self.queue = queue
    self.task = task
  }

  deinit {
    task.cancel()
    Task { [queue] in
      await queue.cancelConsumer()
    }
  }
}
