import Foundation

/// Tiny in-process change broadcaster: repositories `notify()` after every write and observers
/// re-query. Stands in for Room's query invalidation / DataStore's flow.
actor ChangeBus {
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// A stream that yields once per change (coalesced — observers re-read the latest state).
    func subscribe() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return stream
    }

    func notify() {
        for c in subscribers.values { c.yield(()) }
    }

    private func remove(_ id: UUID) { subscribers[id] = nil }
}

extension ChangeBus {
    /// Builds an `AsyncStream` that yields `read()` now and again after every change.
    nonisolated func observing<T: Sendable>(_ read: @escaping @Sendable () async -> T) -> AsyncStream<T> {
        AsyncStream { continuation in
            let task = Task {
                let changes = await self.subscribe()
                continuation.yield(await read())
                for await _ in changes {
                    if Task.isCancelled { break }
                    continuation.yield(await read())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
