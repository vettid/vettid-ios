import Foundation
import VettIDData

/// A file opened with VettID ("Open in VettID" from Files, the share sheet or AirDrop): the app declares `public.json`
/// as a document type it can view, at rank `Alternate`, so that it is never the default app for JSON files and only
/// offered when the member chooses it (`project.yml`, `CFBundleDocumentTypes`). The only JSON file it takes is a canary
/// manifest (VAULT-RELEASES §10.1 step 9, VAULT-MESSAGING §11.10.1): an opened file is read, bounded, and handed to the
/// root's dialog, which verifies it and installs nothing before the member confirms. Nothing else happens on an open.
/// Mirrors vettid-android `MainActivity.receiveCanaryManifest`.
enum CanaryManifestFiles {
    /// The served document in [url], read at most one byte past the limit; nil when it is not a file or cannot be read.
    /// iOS copies a file opened from another app into `Documents/Inbox` (the app does not open documents in place): that
    /// copy is removed once read, so that nothing of it stays in the app.
    static func receive(_ url: URL, inbox: URL? = defaultInbox) -> [UInt8]? {
        guard url.isFileURL else { return nil }
        defer { removeCopy(url, inbox: inbox) }
        return try? CanaryManifestInbox.readBounded(url)
    }

    /// `Documents/Inbox`, where iOS puts the files other apps hand to this one.
    static var defaultInbox: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// How old a copy left in `Documents/Inbox` must be before the launch sweep removes it: a file being opened with the
    /// launch itself is read first (chosen; not in the spec).
    static let strayAge: TimeInterval = 600

    /// At launch: copies left in `Documents/Inbox` by an open that never reached the app (a crash, a refused read) are
    /// removed, so nothing handed to VettID stays in it.
    static func sweepInbox(_ inbox: URL? = defaultInbox, now: Date = Date()) {
        guard let inbox else { return }
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files {
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) >= strayAge { try? fm.removeItem(at: f) }
        }
    }

    private static func removeCopy(_ url: URL, inbox: URL?) {
        guard let inbox else { return }
        let dir = inbox.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(dir) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
