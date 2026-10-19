#if os(iOS)
import SwiftUI
import VettIDData
import VettIDUI

/// **What's new in release N** (ANDROID-PLAN "What's new", RELEASE-UPDATES §2): the release log entry of the offered
/// release, labelled with the log's host, as plain text (never made into links); while [notes] is nil, a progress line.
/// Information only: nothing here gates the update. "Full release notes" opens the manifest's [notesURL] (https only).
/// Mirrors vettid-android `WhatsNew`.
public struct WhatsNew: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.openURL) private var openURL
    let release: UInt64
    let notes: ReleaseNotes?
    let notesURL: String

    public init(release: UInt64, notes: ReleaseNotes?, notesURL: String) {
        self.release = release
        self.notes = notes
        self.notesURL = notesURL
    }

    public var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(OnboardingStrings.releaseNotesTitle(Int(release)))
                    .vettIDFont(.titleMedium)
                    .accessibilityAddTraits(.isHeader)
                switch notes {
                case nil:
                    HStack(spacing: Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text(OnboardingStrings.releaseNotesLoading).vettIDFont(.bodyMedium)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("whats_new_loading")
                case .unavailable:
                    Text(OnboardingStrings.releaseNotesUnavailable)
                        .vettIDFont(.bodyMedium)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .accessibilityIdentifier("whats_new_unavailable")
                case .available(let host, let entry, let earlier):
                    WhatsNewEntry(host: host, entry: entry, earlier: earlier)
                }
                if ReleaseLog.openable(notesURL), let url = URL(string: notesURL) {
                    Button { openURL(url) } label: {
                        Text(OnboardingStrings.releaseNotesFull).vettIDFont(.labelLarge).foregroundStyle(colors.primary)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: Spacing.touchTarget)
                    .accessibilityIdentifier("whats_new_full")
                }
            }
        }
        .accessibilityIdentifier("whats_new")
    }
}

/// One release log entry: the summary, the changes, the security line, the earlier releases' summaries and the source.
private struct WhatsNewEntry: View {
    @Environment(\.vettIDColors) private var colors
    let host: String
    let entry: ReleaseLogEntry
    let earlier: [EarlierRelease]

    var body: some View {
        Text(verbatim: entry.summary).vettIDFont(.bodyLarge).accessibilityIdentifier("whats_new_summary")
        if !entry.changes.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Array(entry.changes.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        Text(verbatim: "•").vettIDFont(.bodyMedium)
                        Text(verbatim: c).vettIDFont(.bodyMedium)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(security)
                .vettIDFont(.bodyMedium)
                .fontWeight(.semibold)
                .foregroundStyle(entry.security == .urgent ? colors.error : colors.onSurface)
            if let t = entry.securityText { Text(verbatim: t).vettIDFont(.bodyMedium) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("whats_new_security")
        if !earlier.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(OnboardingStrings.releaseNotesEarlier).vettIDFont(.titleSmall)
                ForEach(earlier, id: \.release) { r in
                    Text(verbatim: OnboardingStrings.releaseNotesEarlierItem(Int(r.release), r.summary))
                        .vettIDFont(.bodyMedium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .accessibilityIdentifier("whats_new_earlier")
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: OnboardingStrings.releaseNotesFrom(host)).vettIDFont(.labelLarge).foregroundStyle(colors.onSurfaceVariant)
            Text(OnboardingStrings.releaseNotesInformation).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("whats_new_from")
    }

    private var security: String {
        switch entry.security {
        case .none: OnboardingStrings.releaseNotesSecurityNone
        case .recommended: OnboardingStrings.releaseNotesSecurityRecommended
        case .urgent: OnboardingStrings.releaseNotesSecurityUrgent
        }
    }
}
#endif
