import Foundation
import Observation
import VettIDData

/// Tag colours while the vault is open (owner decision 2026-10-09): the registry's stored colours for every screen
/// (``colors``), and a colour stored for every tag that has none. Lives with the open app (the shell hosts it), so nothing
/// runs while the vault is locked. The registry is read when it is not held (the vault opened, a `tag.changed`, a tag first
/// used on an item), a burst of drops read once after [rereadDelay]; each time it is listed, tags without a colour get the
/// next palette colour ([next], `TagColors.next`) — never while the daily owner check is due or the vault held (§3.6,
/// [gated]), when they keep their hash colours. Mirrors vettid-android `TagColorsViewModel`.
@MainActor
@Observable
public final class TagColorsKeeper {
    @ObservationIgnored private let sharing: any SharingRepository
    @ObservationIgnored private let gated: @MainActor () -> Bool
    @ObservationIgnored private let next: ([TagView]) -> (tag: String, color: String)?
    @ObservationIgnored private let rereadDelay: Duration
    @ObservationIgnored private let followers = TaskBag()
    @ObservationIgnored private var assigning: Task<Void, Never>?
    @ObservationIgnored private var rereading: Task<Void, Never>?
    @ObservationIgnored private var again = false

    /// vettid-android's: a burst of `tag.changed` is one read.
    public static let defaultRereadDelay: Duration = .milliseconds(400)

    public init(
        sharing: any SharingRepository, gated: @escaping @MainActor () -> Bool,
        next: @escaping ([TagView]) -> (tag: String, color: String)?, rereadDelay: Duration = TagColorsKeeper.defaultRereadDelay
    ) {
        self.sharing = sharing
        self.gated = gated
        self.next = next
        self.rereadDelay = rereadDelay
        followers.add(follow(self, read: { $0.sharing.tags }, apply: { k, r in k.registryChanged(r) }))
    }

    deinit {
        followers.cancelAll()
        assigning?.cancel()
        rereading?.cancel()
    }

    /// The colours the registry stores, by tag (the screens' environment).
    public var colors: [String: String] { sharing.colors }

    private func registryChanged(_ r: TagRegistry?) {
        guard r == nil else { return assign() }
        // Dropped: read again shortly, quietly (offline, held or refused: the tags keep their hash colours).
        rereading?.cancel()
        rereading = Task { [weak self, rereadDelay] in
            try? await Task.sleep(for: rereadDelay)
            guard !Task.isCancelled, let self else { return }
            _ = try? await sharing.refreshTagsQuietly()
        }
    }

    /// One assignment at a time; a registry listed meanwhile is looked at once it ends.
    private func assign() {
        guard !gated() else { return }
        if assigning != nil {
            again = true
            return
        }
        assigning = Task { [weak self] in
            guard let self else { return }
            repeat {
                again = false
                _ = try? await sharing.assignColors(next)
            } while again && !gated() && !Task.isCancelled
            assigning = nil
        }
    }
}
