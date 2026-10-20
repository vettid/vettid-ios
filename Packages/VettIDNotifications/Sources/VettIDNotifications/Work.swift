import Foundation

/// The work a view model started (vettid-android's `viewModelScope`): run on the main actor, each piece holding its model
/// weakly, cancelled when the model goes (the screen went away: ``cancelAll()`` from its `deinit`), and awaited by the
/// tests (``settle()``).
final class Work: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var next = 0

    init() {}

    @MainActor
    func launch(_ body: @escaping @MainActor () async -> Void) {
        let id = reserve()
        let task = Task { @MainActor [weak self] in
            await body()
            self?.remove(id)
        }
        store(id, task)
    }

    /// Cancels everything still running.
    func cancelAll() {
        lock.lock()
        let all = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        for t in all { t.cancel() }
    }

    /// TEST ONLY: returns once the work started so far, and any it started in turn, has run.
    @MainActor
    func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            while let task = first() {
                await task.value
            }
        }
    }

    private func reserve() -> Int {
        lock.lock()
        defer { lock.unlock() }
        next += 1
        return next
    }

    private func store(_ id: Int, _ task: Task<Void, Never>) {
        lock.lock()
        tasks[id] = task
        lock.unlock()
    }

    private func remove(_ id: Int) {
        lock.lock()
        tasks[id] = nil
        lock.unlock()
    }

    private func first() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        guard let (id, task) = tasks.first else { return nil }
        tasks[id] = nil
        return task
    }
}
