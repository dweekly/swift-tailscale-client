// SPDX-License-Identifier: MIT
// Copyright (c) 2025 David E. Weekly

import Foundation

final class IPNBusStreamContext: @unchecked Sendable {
  let queue: IPNBusBoundedQueue
  private let task: Task<Void, Never>

  init(queue: IPNBusBoundedQueue, task: Task<Void, Never>) {
    self.queue = queue
    self.task = task
  }

  deinit {
    task.cancel()
    Task { [queue] in
      await queue.finish()
    }
  }
}
