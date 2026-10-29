import Foundation
import VettIDData

/// The names an entry's title may show (IOS-PLAN §4.1), as History resolves them for the row. Mirrors vettid-android
/// `EntryNames`.
public struct EntryNames: Equatable, Sendable {
    public var connection: String?
    public var device: String?
    public var item: String?

    public init(connection: String? = nil, device: String? = nil, item: String? = nil) {
        self.connection = connection
        self.device = device
        self.item = item
    }
}

/// The member-facing title and detail lines of an audit entry (``AuditKinds``), for the screens, the search on the phone
/// and the export's labels. Mirrors vettid-android `HistoryText`.
public enum HistoryText {
    /// [isolate] false for a file (an export): the names are cleaned but carry no bidi controls at all. Otherwise a name is
    /// cleaned and bidi-isolated where it sits in the sentence (VAULT-MESSAGING §10.8; mirrors vettid-android #220).
    public static func title(_ kind: String, _ ref: String? = nil, names: EntryNames = EntryNames(), isolate: Bool = true) -> String {
        switch AuditKinds.title(kind, ref) {
        case .known(let key): HistoryKindTexts.text(key)
        case .summary(let key): HistoryStrings.kindSummary(HistoryKindTexts.text(key))
        case .dropped(let reason): HistoryStrings.kindDropped(reason)
        case .unknown(let kind): HistoryStrings.kindUnknown(kind)
        case .counted(let key, let n, let of): HistoryKindTexts.text(key, Int64(n), Int64(of))
        case .named(let key, let any, let who):
            // Without the name (gone or not known), the title drops it.
            if let name = name(who, names).flatMap({ isolate ? AccountNames.isolateOrNull($0) : AccountNames.cleaned($0) }) {
                HistoryKindTexts.text(key, name)
            } else {
                HistoryKindTexts.text(any)
            }
        }
    }

    private static func name(_ who: AuditKinds.Who, _ names: EntryNames) -> String? {
        switch who {
        case .connection: names.connection
        case .device: names.device
        case .item: names.item
        }
    }

    /// An entry's detail lines (IOS-PLAN §4.1). A duration the vault's time scale divides is said in real time at
    /// scale 1, else as the vault runs it.
    public static func details(_ kind: String, _ ref: String?, outcome: AuditKinds.Outcome, timeScale: UInt64 = 1) -> [String] {
        AuditKinds.details(kind, ref, outcome: outcome).compactMap { d in
            switch d {
            case .line(let key): HistoryKindTexts.text(key)
            case .scaled(let key, let scaled, let seconds):
                TimeScales.scaledText(seconds, by: timeScale).map { HistoryKindTexts.text(scaled, $0) } ?? HistoryKindTexts.text(key)
            case .named(let key, let name): AccountNames.isolateOrNull(name).map { HistoryKindTexts.text(key, $0) }
            }
        }
    }

    /// The signer entries' second line (0.27.0 §11.7.1), in the words of ANDROID-PLAN §7. Mirrors vettid-android
    /// `HistorySigner`.
    public static func signer(_ d: AuditKinds.SignerDetail) -> String {
        switch d {
        case .bound(let c):
            let label = FeedKinds.signerLabel(c)
            return label.prefix(1).uppercased() + label.dropFirst()
        case .changed(let from, let to):
            return FeedKinds.signerChangeText("\(from):\(to)") ?? HistoryKindTexts.text("history_kind_device_signer_changed")
        case .refused(let unbound):
            return HistoryKindTexts.text(unbound ? "history_signer_refused_unbound" : "history_signer_refused_unpinned")
        }
    }

    /// An `audit.exported` entry's second line: "CSV · 40 entries".
    public static func exportSummary(_ kind: String, _ ref: String?) -> String? {
        AuditKinds.exportSummary(kind, ref).map { s in
            HistoryStrings.exportSummary(s.format.uppercased(), HistoryStrings.exportCount(s.count))
        }
    }

    /// The name of an entry's device as a row's second line and the export show it (ANDROID-PLAN §4 History): the listed
    /// name, "Removed device" for one no longer listed; nil without a device, while the list is not known, or for a
    /// listed device without a name (this phone's own app among them). Mirrors vettid-android `HistoryDevice.name`.
    public static func deviceName(_ deviceID: String?, _ devices: HistoryDevices?) -> String? {
        guard let devices else { return nil }
        switch devices.device(deviceID) {
        case .named(let n): return n
        case .removed: return HistoryStrings.deviceRemoved
        case .thisPhone, .unnamed, nil: return nil
        }
    }

    /// A row's second line: the item, connection and device names where the entry has them, else [fallback]. Mirrors
    /// vettid-android `HistoryDevice.supporting`.
    public static func supporting(_ parts: [String?], fallback: String) -> String {
        let s = parts.compactMap { $0 }.joined(separator: " · ")
        return s.isEmpty ? fallback : s
    }
}
