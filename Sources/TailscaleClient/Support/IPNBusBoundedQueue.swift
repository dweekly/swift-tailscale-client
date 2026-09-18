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

  init(bounds: StreamBufferBounds) {
    self.bounds = bounds
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
          if byteSize <= bounds.maxByteCount {
            buffer.append(Entry(event: event, byteSize: byteSize))
            currentByteCount += byteSize
          }
        } else {
          buffer.append(Entry(event: gapEvent, byteSize: 64))
          currentByteCount += 64
          if byteSize <= bounds.maxByteCount {
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
    if let cont = consumerContinuation {
      consumerContinuation = nil
      cont.resume(returning: nil)
    }
  }

  func fail(_ error: Error) {
    terminalError = error
    if let cont = consumerContinuation {
      consumerContinuation = nil
      cont.resume(throwing: error)
    }
  }

  func cancelConsumer() {
    isFinished = true
    if let cont = consumerContinuation {
      consumerContinuation = nil
      cont.resume(throwing: CancellationError())
    }
  }
}
