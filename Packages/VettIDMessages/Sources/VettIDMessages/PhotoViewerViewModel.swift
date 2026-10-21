import Foundation
import Observation
import VettIDData
import VettIDMedia

/// Why the viewer shows no photo, in the plan's words; nil for a failure the shared failure text says.
public enum PhotoViewerProblem: Equatable, Sendable, CaseIterable {
    /// Not JPEG, PNG or WebP by its bytes.
    case type
    /// The blob did not pass its checks.
    case bad
    /// The attachment is not stored yet (`unavailable`), or the photo was dropped from memory (a lock, the hold).
    case unavailable
    case busy
}

/// The photo viewer's state. The photo is the members' own: never printed, dumped or mirrored. Mirrors vettid-android
/// `PhotoViewerUiState`.
public struct PhotoViewerState: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public var loading = true
    /// The fetched, checked photo (encoded; decoded by the screen to its size).
    public var photo: FetchedPhoto?
    /// The sender's name for it, sanitized; never a file name.
    public var name: String?
    public var error: FailureKind?
    public var problem: PhotoViewerProblem?

    public init(loading: Bool = true) { self.loading = loading }

    public static func == (a: PhotoViewerState, b: PhotoViewerState) -> Bool {
        a.loading == b.loading && a.photo === b.photo && a.name == b.name && a.error == b.error && a.problem == b.problem
    }

    public var description: String {
        "PhotoViewerState(loading: \(loading), photo: \(photo != nil), error: \(error.map { "\($0)" } ?? "nil"))"
    }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Fetches a message's photo (`message.attachment.get`, the blob from this phone's mailbox, its checks), from memory when
/// it was fetched before (ANDROID-PLAN "Photo attachments", "Viewing"). Only the ids travel; the photo stays in memory,
/// zeroed at a clear and when the viewer goes, which also withdraws its share offers. Mirrors vettid-android
/// `PhotoViewerViewModel`.
@MainActor
@Observable
public final class PhotoViewerViewModel {
    public let connectionID: String
    public let messageID: String
    @ObservationIgnored private let attachments: any AttachmentsRepository
    @ObservationIgnored private let messages: any MessagesRepository
    @ObservationIgnored private let shared: SharedPhotos
    @ObservationIgnored private let work = Work()
    @ObservationIgnored private let follows = TaskBag()
    /// The photo shown, where `deinit` reaches it.
    @ObservationIgnored private let held = HeldPhoto()
    public private(set) var state = PhotoViewerState()

    public init(
        connectionID: String, messageID: String, attachments: any AttachmentsRepository, messages: any MessagesRepository,
        shared: SharedPhotos = .shared
    ) {
        self.connectionID = connectionID
        self.messageID = messageID
        self.attachments = attachments
        self.messages = messages
        self.shared = shared
        load()
        // A lock, the hold or due state, a wipe or an unlink: the photo this viewer holds goes too.
        follows.add(follow(self, read: { $0.attachments.cleared }, apply: { $0.onCleared($1) }))
    }

    deinit {
        work.cancelAll()
        follows.cancelAll()
        held.wipe()
        // The viewer is gone: its share offers are withdrawn.
        shared.clear()
    }

    public func load() {
        state.loading = true
        state.error = nil
        state.problem = nil
        let name = messages.messages(connectionID).first { $0.messageID == messageID }?.attachment?.name
        let (attachments, c, m) = (attachments, connectionID, messageID)
        let mark = attachments.cleared
        work.launch { [weak self] in
            do {
                let p = try await attachments.photo(c, messageID: m)
                // Gone, or a clear came while it was on its way (``onCleared(_:)`` said so): it is not shown.
                guard let self, attachments.cleared == mark else { return p.wipe() }
                held.set(p)
                var s = PhotoViewerState(loading: false)
                s.photo = p
                s.name = name
                state = s
            } catch {
                guard attachments.cleared == mark else { return }
                var s = PhotoViewerState(loading: false)
                s.name = name
                s.error = failureKind(error)
                s.problem = Self.problem((error as? VaultFailure)?.code)
                self?.state = s
            }
        }
    }

    static func problem(_ code: String?) -> PhotoViewerProblem? {
        switch code {
        case AttachmentManager.codeType: .type
        case AttachmentManager.codeBad: .bad
        case "unavailable": .unavailable
        case "busy": .busy
        default: nil
        }
    }

    private func onCleared(_ generation: Int) {
        defer { held.lastCleared = generation }
        guard let last = held.lastCleared, last != generation else { return }
        held.wipe()
        var s = PhotoViewerState(loading: false)
        s.error = .other
        s.problem = .unavailable
        state = s
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}

/// The photo a viewer shows, where its `deinit` reaches it.
final class HeldPhoto: @unchecked Sendable {
    private let lock = NSLock()
    private var photo: FetchedPhoto?
    private var lastClearedValue: Int?

    var lastCleared: Int? {
        get { lock.withLock { lastClearedValue } }
        set { lock.withLock { lastClearedValue = newValue } }
    }

    func set(_ p: FetchedPhoto) {
        let old = lock.withLock {
            defer { photo = p }
            return photo
        }
        if old !== p { old?.wipe() }
    }

    func wipe() {
        let p = lock.withLock {
            defer { photo = nil }
            return photo
        }
        p?.wipe()
    }
}
