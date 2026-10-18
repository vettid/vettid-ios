import Foundation
import VettIDKeys

/// What a wipe erases: directories, keychain items and Secure Enclave keys, and notifications. The app's on the iPhone;
/// temporary directories and software keys in the tests. Mirrors vettid-android `WipeTargets`.
public protocol WipeTargets: Sendable {
    /// "Wipe pending": written (and synced) before anything is deleted, removed last; it survives the process.
    var marker: URL { get }

    /// Every directory whose contents are erased (the [marker] and the [kept] files excepted), and found empty after.
    var dirs: [URL] { get }

    /// Directories whose contents are erased too, best effort, without being checked: iOS writes into some of them by
    /// itself (the app switcher's snapshots in the caches), so a wipe never waits on them (chosen; not in the spec).
    var scratch: [URL] { get }

    /// Files the wipe leaves: the first-run cleanup's marker (IOS-PLAN §6.1), which holds nothing of the vault and keeps
    /// the next launch from taking keys made after the wipe for an earlier installation's (chosen; not in the spec).
    var kept: [URL] { get }

    /// Every keychain item and key of the app, through their protocols (``KeychainEraser`` first, as the first-run
    /// cleanup's).
    var erasers: [any KeyEraser] { get }

    /// Whether any keychain item or key of the app is left. Throws when it cannot tell.
    func keysLeft() throws -> Bool

    func cancelNotifications()

    /// The app's own preferences, best effort.
    func clearSettings()
}

public extension WipeTargets {
    var scratch: [URL] { [] }
    func clearSettings() {}

    /// Written when a wipe whose marker named ``LocalWipe/reasonMovedAway`` finished, removed when the member has read
    /// it; a later wipe erases it like any file.
    var movedAwayNotice: URL { marker.deletingLastPathComponent().appendingPathComponent(LocalWipe.movedAwayNotice) }
}

/// Erases everything this app keeps on the phone, as if it had just been installed (owner decision, 2026-10-05: once the
/// vault has moved to another phone and works there, the old phone shows no sign it was there). Used only after an
/// authenticated signal that this phone was replaced (``HolderWatch``), or when the member confirms "Erase VettID from
/// this phone" (``AccountRepository/eraseThisPhone()``).
///
/// Crash-safe: ``begin(reason:)`` writes the marker first; ``erase()`` deletes (idempotent, it goes on past a failure);
/// ``finish()`` removes the marker only once everything is gone. A process that ends in between finds the marker at the
/// next start, and ``resumeIfPending()`` finishes the wipe before anything else reads local state. [hooks] reset what
/// lives in memory in this process (the app lock, a setup link waiting); they run in a live wipe only. Mirrors
/// vettid-android `LocalWipe`.
public final class LocalWipe: @unchecked Sendable {
    /// The marker's file name, in the app's data directory.
    public static let marker = "wipe-pending"
    /// The marker's reason for an old phone that removes its keys at the end of a kept transfer (release R).
    public static let reasonMovedAway = "moved_away"
    /// The notice file of ``WipeTargets/movedAwayNotice``.
    public static let movedAwayNotice = "moved-away-notice"
    static let markerContent = Array("1".utf8)

    private let targets: any WipeTargets
    private let hooks: [@MainActor () async -> Void]

    public init(targets: any WipeTargets, hooks: [@MainActor () async -> Void] = []) {
        self.targets = targets
        self.hooks = hooks
    }

    /// Whether a wipe was started and not finished.
    public var pending: Bool { FileManager.default.fileExists(atPath: targets.marker.path) }

    /// Step 1: the marker, synced, before anything is deleted. [reason] is written in it, so that a wipe a crash
    /// interrupted still knows why it ran when ``resumeIfPending()`` finishes it.
    public func begin(reason: String? = nil) throws {
        let url = targets.marker
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = Data(reason.map { Array($0.utf8) } ?? Self.markerContent)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.write(contentsOf: content)
        try h.synchronize()
    }

    /// Whether the last finished wipe was that of an old phone at the end of a kept transfer, not yet read.
    public var movedAway: Bool { FileManager.default.fileExists(atPath: targets.movedAwayNotice.path) }

    public func acknowledgeMovedAway() { try? FileManager.default.removeItem(at: targets.movedAwayNotice) }

    /// Runs the in-memory resets of this process. A failing hook does not stop the others or the wipe.
    @MainActor
    public func resetMemory() async {
        for h in hooks { await h() }
    }

    /// Erases notifications, every keychain item and key of the app, and the contents of every directory (the marker and
    /// the kept files excepted). Idempotent; goes on past a failure. True when nothing is left.
    @discardableResult
    public func erase() -> Bool {
        targets.cancelNotifications()
        targets.clearSettings()
        for e in targets.erasers {
            // Checked below.
            try? e.deleteAll()
        }
        let keep = Set(([targets.marker] + targets.kept).map(Self.path))
        for d in targets.dirs + targets.scratch { clear(d, keeping: keep) }
        return isErased()
    }

    /// Whether nothing is left: no keychain item or key, every directory empty (but for the marker and the kept files).
    public func isErased() -> Bool {
        guard let left = try? targets.keysLeft(), !left else { return false }
        let keep = Set(([targets.marker] + targets.kept).map(Self.path))
        return targets.dirs.allSatisfy { d in Self.children(d).allSatisfy { keep.contains(Self.path($0)) } }
    }

    /// The last step: the marker goes (after the notice its reason asks for, if any).
    public func finish() {
        if let reason = try? Data(contentsOf: targets.marker), Array(reason) == Array(Self.reasonMovedAway.utf8) {
            FileManager.default.createFile(atPath: targets.movedAwayNotice.path, contents: Data(Self.markerContent))
        }
        try? FileManager.default.removeItem(at: targets.marker)
    }

    /// At the start: finishes a wipe that a crash interrupted. True when one was pending. The marker stays if something
    /// could not be erased, so that the next start tries again.
    @discardableResult
    public func resumeIfPending() -> Bool {
        guard pending else { return false }
        if erase() { finish() }
        return true
    }

    /// A whole live wipe: marker, memory, disk, marker removed.
    @MainActor
    public func run() async throws -> Bool {
        try begin()
        await resetMemory()
        let done = erase()
        if done { finish() }
        return done
    }

    /// "Erase VettID's data on this phone", the way out of a wipe that did not finish (vettid-android `AppDataClear`):
    /// local only, best effort, without the marker's bookkeeping (a marker that cannot be written stops a wipe, not this):
    /// every keychain item and key, then every file, the marker included. True when nothing is left. iOS has no system
    /// clear of an app's data (Android's `clearApplicationUserData`): when this cannot finish, the member removes the app.
    public func clearAll() -> Bool {
        targets.cancelNotifications()
        targets.clearSettings()
        for e in targets.erasers { try? e.deleteAll() }
        let keep = Set(targets.kept.map(Self.path))
        for d in targets.dirs + targets.scratch { clear(d, keeping: keep) }
        try? FileManager.default.removeItem(at: targets.marker)
        return isErased() && !pending
    }

    private func clear(_ dir: URL, keeping keep: Set<String>) {
        for c in Self.children(dir) where !keep.contains(Self.path(c)) {
            // What is left is found by isErased().
            try? FileManager.default.removeItem(at: c)
        }
    }

    /// A file's path with its symbolic links resolved (`/var` and `/private/var` are the same directory).
    private static func path(_ u: URL) -> String { u.resolvingSymlinksInPath().path }

    private static func children(_ dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }
}
