import Foundation
import SwiftUI

// MARK: - Guide Read Tracker

/// Tracks which guides the user has marked as read.
///
/// Backed by `UserDefaults` so reads/writes are synchronous and survive
/// launches. Published via `@Published` so SwiftUI views can re-render
/// when the read-set changes (e.g. after the user opens a guide).
///
/// Parity with Android `GuideReadTracker` — the system card uses
/// `unreadGuides()` to synthesize one `PendingRow.guideUnread` per
/// not-yet-read guide.
@MainActor
final class GuideReadTracker: ObservableObject {

    static let shared = GuideReadTracker()

    private static let defaultsKey = "guides_read_ids_v1"

    @Published private(set) var readIds: Set<String> = []

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        readIds = Set(stored)
    }

    func isRead(_ id: GuideId) -> Bool {
        readIds.contains(id.rawValue)
    }

    /// Mark a guide as read. Idempotent.
    func markRead(_ id: GuideId) {
        guard !readIds.contains(id.rawValue) else { return }
        readIds.insert(id.rawValue)
        persist()
    }

    /// Mark a guide as unread (e.g. for testing). Idempotent.
    func markUnread(_ id: GuideId) {
        guard readIds.contains(id.rawValue) else { return }
        readIds.remove(id.rawValue)
        persist()
    }

    /// Guides the user has *not* read yet, sorted by priority (so the
    /// system card shows Welcome first, Navigation next, etc.).
    func unreadGuides() -> [GuideId] {
        GuideCatalog.allGuides.filter { !readIds.contains($0.rawValue) }
    }

    var unreadCount: Int { GuideCatalog.allGuides.count - readIds.count }

    /// Reset — wipe everything (e.g. on logout).
    func reset() {
        readIds = []
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    private func persist() {
        UserDefaults.standard.set(Array(readIds), forKey: Self.defaultsKey)
    }
}
