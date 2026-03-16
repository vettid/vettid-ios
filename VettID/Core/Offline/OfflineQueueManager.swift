import Foundation

// MARK: - Queued Operation Type

enum QueuedOperationType: String, Codable {
    case sendMessage = "send_message"
    case respondConnection = "respond_connection"
    case acceptConnection = "accept_connection"
    case syncSecrets = "sync_secrets"
    case syncPersonalData = "sync_personal_data"
}

// MARK: - Queued Operation

struct QueuedOperation: Identifiable, Codable {
    let id: String
    let type: QueuedOperationType
    let payload: Data
    let createdAt: Date
    var retryCount: Int

    init(
        id: String = UUID().uuidString,
        type: QueuedOperationType,
        payload: Data,
        createdAt: Date = Date(),
        retryCount: Int = 0
    ) {
        self.id = id
        self.type = type
        self.payload = payload
        self.createdAt = createdAt
        self.retryCount = retryCount
    }
}

// MARK: - Offline Queue Manager

/// Manages a queue of operations to execute when NATS connection is restored.
/// Operations are persisted to UserDefaults so they survive app restarts.
actor OfflineQueueManager {
    static let shared = OfflineQueueManager()

    private static let storageKey = "com.vettid.offlineQueue"
    private static let maxRetries = 3

    private var queue: [QueuedOperation] = []

    private init() {
        queue = Self.loadQueue()
    }

    // MARK: - Public API

    /// Add an operation to the offline queue and persist it
    func enqueue(operation: QueuedOperation) {
        queue.append(operation)
        persistQueue()
        #if DEBUG
        print("[OfflineQueue] Enqueued operation: \(operation.type.rawValue) (id: \(operation.id))")
        #endif
    }

    /// Process all queued operations. Called when NATS connection is restored.
    /// Returns the number of successfully processed operations.
    @discardableResult
    func processQueue() async -> Int {
        guard !queue.isEmpty else { return 0 }

        #if DEBUG
        print("[OfflineQueue] Processing \(queue.count) queued operations...")
        #endif

        var processedCount = 0
        var failedOperations: [QueuedOperation] = []

        for var operation in queue {
            let success = await processOperation(operation)
            if success {
                processedCount += 1
            } else {
                operation.retryCount += 1
                if operation.retryCount < Self.maxRetries {
                    failedOperations.append(operation)
                } else {
                    #if DEBUG
                    print("[OfflineQueue] Dropping operation \(operation.id) after \(Self.maxRetries) retries")
                    #endif
                }
            }
        }

        queue = failedOperations
        persistQueue()

        #if DEBUG
        print("[OfflineQueue] Processed \(processedCount) operations, \(failedOperations.count) remaining")
        #endif

        return processedCount
    }

    /// Remove an operation after successful processing
    func removeOperation(id: String) {
        queue.removeAll { $0.id == id }
        persistQueue()
    }

    /// Number of queued operations pending
    var pendingCount: Int {
        queue.count
    }

    /// All pending operations (read-only)
    var pendingOperations: [QueuedOperation] {
        queue
    }

    // MARK: - Private Helpers

    private func processOperation(_ operation: QueuedOperation) async -> Bool {
        // Processing is delegated to the appropriate handler based on operation type.
        // In a full implementation, each type would call the corresponding NATS handler.
        // For now, return false to retain in queue until handlers are wired up.
        #if DEBUG
        print("[OfflineQueue] Processing operation: \(operation.type.rawValue) (attempt \(operation.retryCount + 1))")
        #endif

        switch operation.type {
        case .sendMessage:
            // TODO: Wire to messaging NATS handler
            return false
        case .respondConnection:
            // TODO: Wire to connection response handler
            return false
        case .acceptConnection:
            // TODO: Wire to connection acceptance handler
            return false
        case .syncSecrets:
            // TODO: Wire to secrets sync handler
            return false
        case .syncPersonalData:
            // TODO: Wire to personal data sync handler
            return false
        }
    }

    private func persistQueue() {
        do {
            let data = try JSONEncoder().encode(queue)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            #if DEBUG
            print("[OfflineQueue] Failed to persist queue: \(error)")
            #endif
        }
    }

    private static func loadQueue() -> [QueuedOperation] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([QueuedOperation].self, from: data)
        } catch {
            #if DEBUG
            print("[OfflineQueue] Failed to load queue: \(error)")
            #endif
            return []
        }
    }
}
