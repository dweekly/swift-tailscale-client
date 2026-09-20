// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

actor IPNBusBoundedQueue {
  private struct Entry {
    let event: IPNBusEvent
    let byteSize: Int
  }

  private var buffer: [Entry] = []
  private var currentByteCount: Int = 0
  private let bounds: StreamBufferBounds
  private var consumerContinuation: CheckedContinuation<IPNBusEvent?, Error>?
  private var isFinished: Bool = false
  private var terminalError: Error?
  private var producerTask: Task<Void, Never>?

  init(bounds: StreamBufferBounds) {
    self.bounds = bounds
  }

  var isClosed: Bool {
    isFinished || terminalError != nil
  }

  func setProducerTask(_ task: Task<Void, Never>) {
    self.producerTask = task
    if isClosed {
      task.cancel()
    }
  }

  func enqueue(_ event: IPNBusEvent, byteSize: Int) {
    guard !isFinished, terminalError == nil else { return }

    let exceedsEvents = buffer.count >= bounds.maxEventCount
    let exceedsBytes = (currentByteCount + byteSize) > bounds.maxByteCount

    if exceedsEvents || exceedsBytes {
      switch bounds.overflowStrategy {
      case .fail:
        buffer.removeAll()
        currentByteCount = 0
        terminalError = TailscaleClientError.streamOverflow
        producerTask?.cancel()
        if let cont = consumerContinuation {
          consumerContinuation = nil
          cont.resume(throwing: TailscaleClientError.streamOverflow)
        }
      case .reportGap:
        buffer.removeAll()
        currentByteCount = 0
        let gapEvent = IPNBusEvent.lifecycle(.stateGap(reason: "buffer_overflow"))
        if let cont = consumerContinuation {
          consumerContinuation = nil
          cont.resume(returning: gapEvent)
          if (currentByteCount + byteSize) <= bounds.maxByteCount {
            buffer.append(Entry(event: event, byteSize: byteSize))
            currentByteCount += byteSize
          }
        } else {
          buffer.append(Entry(event: gapEvent, byteSize: 64))
          currentByteCount += 64
          if (currentByteCount + byteSize) <= bounds.maxByteCount {
            buffer.append(Entry(event: event, byteSize: byteSize))
            currentByteCount += byteSize
          }
        }
      }
      return
    }

    if let cont = consumerContinuation {
      consumerContinuation = nil
      cont.resume(returning: event)
      return
    }

    buffer.append(Entry(event: event, byteSize: byteSize))
    currentByteCount += byteSize
  }

  func next() async throws -> IPNBusEvent? {
    try Task.checkCancellation()

    if !buffer.isEmpty {
      let entry = buffer.removeFirst()
      currentByteCount -= entry.byteSize
      return entry.event
    }

    if let error = terminalError {
      throw error
    }

    if isFinished {
      return nil
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { cont in
        if Task.isCancelled {
          cont.resume(throwing: CancellationError())
          return
        }
        if let error = self.terminalError {
          cont.resume(throwing: error)
          return
        }
        if self.isFinished {
          cont.resume(returning: nil)
          return
        }
        if let existing = self.consumerContinuation {
          self.consumerContinuation = nil
          existing.resume(throwing: CancellationError())
        }
        self.consumerContinuation = cont
      }
    } onCancel: {
      Task {
        await self.cancelConsumer()
      }
    }
  }

  func finish() {
    isFinished = true
    producerTask?.cancel()
    if let cont = consumerContinuation {
      consumerContinuation = nil
      cont.resume(returning: nil)
    }
  }

  func fail(_ error: Error) {
    terminalError = error
    producerTask?.cancel()
    if let cont = consumerContinuation {
      consumerContinuation = nil
      cont.resume(throwing: error)
    }
  }

  func cancelConsumer() {
    isFinished = true
    producerTask?.cancel()
    if let cont = consumerContinuation {
      consumerContinuation = nil
      cont.resume(throwing: CancellationError())
    }
  }
}
