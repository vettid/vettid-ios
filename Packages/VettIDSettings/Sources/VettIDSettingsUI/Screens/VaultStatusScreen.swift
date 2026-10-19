#if os(iOS)
import SwiftUI
import VettIDData
import VettIDSettings
import VettIDUI

/// Vault status (stateless): a release notice, then the vault's state with "Installed from" under it (IOS-PLAN ID15:
/// where vettid-android shows its signer line, from the build here, with "Apple App Attest confirms this is the VettID
/// app"), its ID, the releases, recovery, confirmation, devices and connections, and that the status is advisory.
/// Under the release notice, the urgent notice of a recovery counter unavailable for a day (§11.14.5; STAGING-TIME-SCALE
/// 0.1.1 S8). vettid-android's notice of attempts used comes with the recovery screens and the PIN and password changes
/// it leads to (I1.8b, I3). Mirrors vettid-android `VaultStatusContent`.
public struct VaultStatusContent: View {
    @Environment(\.vettIDColors) private var colors
    let state: LoadState<VaultOverview>
    let installedFrom: InstalledFrom
    let retry: @MainActor () -> Void
    let onBack: @MainActor () -> Void

    public init(
        state: LoadState<VaultOverview>,
        installedFrom: InstalledFrom,
        retry: @escaping @MainActor () -> Void = {},
        onBack: @escaping @MainActor () -> Void = {}
    ) {
        self.state = state
        self.installedFrom = installedFrom
        self.retry = retry
        self.onBack = onBack
    }

    public var body: some View {
        DetailScaffold(background: colors.groupedBackground, onBack: onBack) {
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle(SettingsStrings.statusTitle)
                    if state.loading {
                        FullScreenProgress(SettingsStrings.loading)
                    } else if let v = state.value {
                        loaded(v)
                    } else {
                        LoadFailure(error: state.error ?? .other, retry: retry)
                    }
                }
            }
        }
    }

    @ViewBuilder private func loaded(_ v: VaultOverview) -> some View {
        if let r = v.release, let text = Self.releaseNotice(r) {
            NoticeCard(r.notice == "update_available" ? .info : .urgent, title: SettingsStrings.noticeTitle, message: text)
                .padding(.horizontal, Spacing.gutter)
                .accessibilityIdentifier("release_notice")
        }
        if v.recoveryOffered, let r = v.recovery, r.unknownForADay {
            NoticeCard(.urgent, title: SettingsStrings.statusRecovery, message: Self.recoveryUnknownDayText(r))
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, Spacing.xs)
                .accessibilityIdentifier("recovery_unknown_day")
        }
        SettingsGroup {
            SettingsInfoRow(SettingsStrings.statusState, value: Self.stateText(v.state), icon: .lock)
            SettingsDivider()
            SettingsInfoRow(Self.installedText(installedFrom), value: SettingsStrings.installedAppAttest, icon: .verifiedUser)
                .accessibilityIdentifier("installed_from")
            SettingsDivider()
            SettingsInfoRow(SettingsStrings.statusVaultId, value: v.vaultID.map { Self.grouped($0, 8) } ?? "-", icon: .tag)
            SettingsDivider()
            SettingsInfoRow(SettingsStrings.statusRelease, value: Self.releaseText(v.release), icon: .update)
            SettingsDivider()
            SettingsInfoRow(
                SettingsStrings.statusReleaseLast,
                value: v.lastRelease > 0 ? SettingsStrings.statusReleaseLastValue(Int(v.lastRelease)) : "-",
                icon: .verifiedUser
            )
            SettingsDivider()
            SettingsInfoRow(SettingsStrings.statusRecovery, value: Self.recoveryText(v), icon: .restore)
            SettingsDivider()
            SettingsInfoRow(SettingsStrings.statusProvisional, value: Self.yesNo(v.provisional.map { !$0 }), icon: .storage)
            SettingsDivider()
            SettingsInfoRow(SettingsStrings.statusDevices, value: v.devices.map(String.init) ?? "-", icon: .devices)
            SettingsDivider()
            SettingsInfoRow(SettingsStrings.statusConnections, value: v.connections.map(String.init) ?? "-", icon: .connections)
        }
        Text(SettingsStrings.statusAdvisory)
            .vettIDFont(.bodySmall)
            .foregroundStyle(colors.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.gutter + Spacing.xs)
            .padding(.vertical, Spacing.l)
    }

    /// The counter unavailable for a day (STAGING-TIME-SCALE 0.1.1 S8, S7): the clock's period as it started and the quiet
    /// period at the vault's time scale, with "Staging: 1 day = 1 hour" under it on a staging vault.
    static func recoveryUnknownDayText(_ r: RecoveryStatusView) -> String {
        r.stagingNote.map { r.unknownDayText + "\n\n" + $0 } ?? r.unknownDayText
    }

    /// IOS-PLAN ID15: Apple for the Release and Staging builds; the development builds' own text otherwise.
    static func installedText(_ i: InstalledFrom) -> String {
        switch i {
        case .apple: SettingsStrings.installedApple
        case .development(let label): label
        }
    }

    static func stateText(_ s: String?) -> String {
        switch s {
        case "unlocked": SettingsStrings.statusStateUnlocked
        case "locked": SettingsStrings.statusStateLocked
        case "enrolling": SettingsStrings.statusStateEnrolling
        default: SettingsStrings.unknown
        }
    }

    static func releaseText(_ r: ReleaseInfoView?) -> String {
        guard let r, let n = r.number else { return SettingsStrings.unknown }
        return SettingsStrings.statusReleaseValue(Int(n), r.status)
    }

    static func recoveryText(_ v: VaultOverview) -> String {
        if !v.recoveryOffered { return SettingsStrings.recoveryNotOffered }
        if let r = v.recovery { return recoveryLine(RecoveryLine.of(r)) }
        return v.recoveryState ?? SettingsStrings.statusRecoveryNone
    }

    static func recoveryLine(_ l: RecoveryLine) -> String {
        switch l {
        case .armed(let used): SettingsStrings.recoveryStatusArmed(used)
        case .used(let used): SettingsStrings.recoveryStatusUsed(used)
        case .exhausted: SettingsStrings.recoveryStatusExhausted
        case .changeRequired: SettingsStrings.recoveryStatusChangeRequired
        case .needsCheck: SettingsStrings.recoveryStatusNeedsCheck
        case .off: SettingsStrings.recoveryStatusOff
        case .unknown: SettingsStrings.recoveryStatusUnknown
        }
    }

    static func releaseNotice(_ r: ReleaseInfoView) -> String? {
        switch r.notice {
        case "update_available": SettingsStrings.noticeUpdateAvailable(Int(r.newestActive ?? 0))
        case "final_warning": SettingsStrings.noticeFinalWarning(formatDate(r.endsAt) ?? "-")
        case "ended": SettingsStrings.noticeEnded
        case "rescue": SettingsStrings.noticeRescue
        case "unavailable": SettingsStrings.noticeUnavailable
        default: nil
        }
    }

    static func yesNo(_ b: Bool?) -> String {
        switch b {
        case true?: SettingsStrings.yes
        case false?: SettingsStrings.no
        case nil: SettingsStrings.unknown
        }
    }

    /// [s] in groups of [n] characters.
    static func grouped(_ s: String, _ n: Int) -> String {
        let chars = Array(s)
        return stride(from: 0, to: chars.count, by: n).map { String(chars[$0..<min($0 + n, chars.count)]) }.joined(separator: " ")
    }

    /// An RFC 3339 time as a date and time in the iPhone's zone and locale; the text as is when it does not parse.
    static func formatDate(_ s: String?) -> String? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let d = f.date(from: s) ?? plain.date(from: s) else { return s }
        return SettingsTimes.full(d)
    }
}

/// A screen's value that could not be loaded: the failure, and "Try again" when it can be.
struct LoadFailure: View {
    let error: FailureKind
    var retry: (@MainActor () -> Void)?

    var body: some View {
        VStack(spacing: Spacing.l) {
            NoticeCard(.warning, title: SettingsStrings.title, message: error.message)
            if let retry { SecondaryButton(SettingsStrings.retry, action: retry) }
        }
        .padding(Spacing.gutter)
        .accessibilityIdentifier("load_failure")
    }
}
#endif
