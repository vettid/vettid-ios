#if os(iOS)
import SwiftUI
import VettIDAttestation
import VettIDData
import VettIDSettings
import VettIDUI

/// Settings → Security → Advanced security → **Attestation** (ANDROID-PLAN 0.1.124 §4 "Attestation in detail", IOS-PLAN
/// §4.17), stateless: this phone's last verification of the enclave its vault runs on ([record]; nil: none yet), each check
/// the app makes with its result ("Passed" only with a recorded pass), the values each rests on, the release's source,
/// This iPhone, and "Copy all" of the public material. An iPhone shows its App Attest key's state only (``AppAttestInfo``)
/// where vettid-android shows its hardware key attestation; an Android-shaped value still shows Android's rows. [canary]:
/// the installed canary manifest (VettID's test phones only), shown only when there is one, with "Stop using the test
/// manifest"; [onLoadCanary] (the iPhone's file importer) adds the row that loads one. [copy]: puts a text on the app's
/// local, expiring pasteboard (``SecurePasteboard``, IOS-PLAN §6.5). Mirrors vettid-android `AttestationContent`.
public struct AttestationContent: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.openURL) private var openURL
    let state: LoadState<AttestationInfo>
    let onBack: @MainActor () -> Void
    let canary: CanaryManifestView?
    let onRemoveCanary: @MainActor () -> Void
    let onLoadCanary: (@MainActor () -> Void)?
    let record: EnclaveRecord?
    let copy: @MainActor (String) -> Void
    /// What was copied last ("PCR0", "all"), for its "Copied".
    @State private var copied: String?

    public init(
        state: LoadState<AttestationInfo>,
        onBack: @escaping @MainActor () -> Void = {},
        canary: CanaryManifestView? = nil,
        onRemoveCanary: @escaping @MainActor () -> Void = {},
        onLoadCanary: (@MainActor () -> Void)? = nil,
        record: EnclaveRecord? = nil,
        copy: (@MainActor (String) -> Void)? = nil
    ) {
        self.state = state
        self.onBack = onBack
        self.canary = canary
        self.onRemoveCanary = onRemoveCanary
        self.onLoadCanary = onLoadCanary
        self.record = record
        self.copy = copy ?? { SecurePasteboard.copy($0) }
    }

    public var body: some View {
        DetailScaffold(background: colors.groupedBackground, onBack: onBack) {
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle(SettingsStrings.attestationTitle)
                    Text(bodyText)
                        .vettIDFont(.bodyMedium)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.gutter + Spacing.xs)
                    if state.loading {
                        FullScreenProgress(SettingsStrings.loading)
                    } else if let a = state.value {
                        loaded(a)
                    } else {
                        LoadFailure(error: state.error ?? .other)
                    }
                }
            }
            .accessibilityIdentifier("attestation_screen")
        }
    }

    /// An Android-shaped value's body is Android's; the iPhone's names App Attest.
    private var bodyText: String {
        state.value.map { $0.appAttest == nil } == true ? SettingsStrings.attestationBody : SettingsStrings.iosAttestationBody
    }

    @ViewBuilder private func loaded(_ a: AttestationInfo) -> some View {
        if let r = record {
            RecordNotice(record: r)
            EnclaveSection(record: r, environment: a.environment, copied: $copied, copy: copy)
            ChecksSection(record: r, root: a.rootFingerprint)
            if let tag = AttestationDetail.tag(r, prefix: a.releaseTagPrefix) {
                ReleaseSection(tag: tag) { url in if let u = URL(string: url) { openURL(u) } }
            }
            PhoneSection(a: a)
            let allLabel = copied == Self.allKey ? AttestationStrings.copied : AttestationStrings.copyAll
            NoticeAction(label: allLabel, identifier: "attestation_copy_all") {
                copy(AttestationDetail.copyAll(r, environment: a.environment, tagPrefix: a.releaseTagPrefix, root: a.rootFingerprint))
                copied = Self.allKey
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.gutter + Spacing.xs)
            .padding(.vertical, Spacing.s)
        } else {
            Text(AttestationStrings.none)
                .vettIDFont(.bodyMedium)
                .foregroundStyle(colors.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.gutter + Spacing.xs)
                .padding(.vertical, Spacing.s)
                .accessibilityIdentifier("attestation_none")
            PhoneSection(a: a)
        }
        if canary != nil || onLoadCanary != nil {
            CanaryManifestSection(canary: canary, onRemove: onRemoveCanary, onLoad: onLoadCanary)
        }
        Spacer().frame(height: Spacing.xxl)
    }

    static let allKey = "all"
}

/// The notice of a verification that failed, or was refused after every check passed.
private struct RecordNotice: View {
    let record: EnclaveRecord

    var body: some View {
        if let body = AttestationDetail.noticeBody(record) {
            NoticeCard(.urgent, title: AttestationStrings.failedTitle, message: body)
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, Spacing.s)
                .accessibilityIdentifier("attestation_failed")
        }
    }
}

/// A value, with "Not verified" after it unless every check it rests on passed.
private func shown(_ value: String, verified: Bool) -> String {
    verified ? value : "\(value) · \(AttestationStrings.notVerified)"
}

/// The enclave: its environment, the release (once the measurements matched), the PCRs with "Copy", when it was attested
/// and how long its key is valid.
private struct EnclaveSection: View {
    let record: EnclaveRecord
    let environment: String
    @Binding var copied: String?
    let copy: @MainActor (String) -> Void

    var body: some View {
        let r = record
        let doc = AttestationDetail.documentVerified(r)
        SettingsSectionHeader(SettingsStrings.attestationEnclave)
        SettingsGroup {
            SettingsInfoRow(SettingsStrings.attestationEnvironment, value: environment, icon: .storage)
            if AttestationDetail.releaseShown(r) {
                SettingsDivider()
                SettingsInfoRow(
                    SettingsStrings.attestationRelease, value: AttestationDetail.releaseValue(r, date: SettingsTimes.full), icon: .tag
                )
                .accessibilityIdentifier("attestation_release")
            }
            ForEach([("PCR0", r.pcr0), ("PCR1", r.pcr1), ("PCR2", r.pcr2)], id: \.0) { label, value in
                if let value {
                    SettingsDivider()
                    PcrRow(label: label, hex: value, verified: doc, copied: copied == label) {
                        copy(value)
                        copied = label
                    }
                }
            }
            if let t = r.attestedAt {
                SettingsDivider()
                SettingsInfoRow(AttestationStrings.attestedAt, value: shown(SettingsTimes.full(t), verified: doc), icon: .verifiedUser)
                    .accessibilityIdentifier("attestation_attested_at")
            }
            if let t = r.notAfter {
                SettingsDivider()
                SettingsInfoRow(
                    AttestationStrings.validUntil,
                    value: shown(SettingsTimes.full(t), verified: AttestationDetail.notAfterVerified(r)), icon: .lock
                )
                .accessibilityIdentifier("attestation_valid_until")
            }
        }
    }
}

/// A PCR: its full hex, monospaced and wrapped, and "Copy" ("Copied" once copied).
private struct PcrRow: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let hex: String
    let verified: Bool
    let copied: Bool
    let onCopy: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(label).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurface)
                Text(hex)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(colors.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                // Not selectable: the system's Copy would put it on the general pasteboard, without expiry and synced to the
                // member's other devices (IOS-PLAN §4.17). "Copy" is the only way.
                if !verified {
                    Text(AttestationStrings.notVerified).vettIDFont(.bodySmall).foregroundStyle(colors.error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            NoticeAction(
                label: copied ? AttestationStrings.copied : AttestationStrings.copy, identifier: "attestation_copy_\(label)", action: onCopy
            )
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.s)
        .accessibilityIdentifier("attestation_\(label)")
    }
}

/// The checks, in the order the app makes them, each "Passed", "Failed" or "Not checked" in text and glyph.
private struct ChecksSection: View {
    let record: EnclaveRecord
    let root: String

    var body: some View {
        SettingsSectionHeader("\(AttestationStrings.sectionChecks) · \(AttestationStrings.asOf(SettingsTimes.full(record.at)))")
        SettingsGroup {
            ForEach(Array(AttestationCheck.allCases.enumerated()), id: \.element) { i, c in
                if i > 0 { SettingsDivider() }
                CheckLine(check: c, result: record.result(c))
                if c == .manifest, AttestationDetail.manifestShown(record), let k = record.manifestKeyID, let s = record.manifestSerial {
                    SubLine(text: AttestationStrings.manifestKey(k, Int(clamping: s)), identifier: "attestation_manifest_key")
                }
                if c == .chain {
                    SubLine(text: "\(AttestationStrings.rootFingerprint)\n\(root)", identifier: "attestation_root_fingerprint", mono: true)
                }
            }
        }
    }
}

/// One check: its line and its state, in text and glyph (never by color alone), read as "<line>: <state>".
struct CheckLine: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.dynamicTypeSize) private var typeSize
    let check: AttestationCheck
    let result: CheckResult

    static func spoken(_ c: AttestationCheck, _ r: CheckResult) -> String {
        AttestationStrings.checkSpoken(AttestationDetail.checkLabel(c), AttestationDetail.resultLabel(r))
    }

    var body: some View {
        let (glyph, tint): (VettIDSymbol, ThemeColor) = switch result {
        case .passed: (.checkCircle, colors.success)
        case .failed: (.cancel, colors.error)
        case .notRun: (.radioUnchecked, colors.onSurfaceVariant)
        }
        let label = Text(AttestationDetail.checkLabel(check))
            .vettIDFont(.bodyLarge)
            .foregroundStyle(colors.onSurface)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        let state = Text(AttestationDetail.resultLabel(result)).vettIDFont(.bodyMedium).foregroundStyle(tint)
        Group {
            // At the accessibility sizes the state goes under the line, so that the line keeps the width.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        glyph.image.foregroundStyle(tint).accessibilityHidden(true)
                        label
                    }
                    state
                }
            } else {
                HStack(spacing: Spacing.s) {
                    glyph.image.foregroundStyle(tint).accessibilityHidden(true)
                    label
                    state
                }
            }
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(check, result))
        .accessibilityIdentifier("check_\(check.rawValue)")
    }
}

/// A line under a check: the manifest's key and serial, the root's fingerprint.
private struct SubLine: View {
    @Environment(\.vettIDColors) private var colors
    /// Under the line's text, past its glyph, at any text size.
    @ScaledMetric(relativeTo: .body) private var indent: CGFloat = 32
    let text: String
    let identifier: String
    var mono = false

    var body: some View {
        Group {
            if mono {
                Text(text).font(.system(.footnote, design: .monospaced))
            } else {
                Text(text).vettIDFont(.bodySmall)
            }
        }
        .foregroundStyle(colors.onSurfaceVariant)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Spacing.gutter + indent)
        .padding(.trailing, Spacing.gutter)
        .padding(.bottom, Spacing.s)
        .accessibilityIdentifier(identifier)
    }
}

/// The release's signed tag (a link to its page) and how to rebuild it.
private struct ReleaseSection: View {
    @Environment(\.vettIDColors) private var colors
    let tag: String
    let open: @MainActor (String) -> Void

    var body: some View {
        SettingsSectionHeader(AttestationStrings.sectionRelease)
        SettingsGroup {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(AttestationStrings.source).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurface)
                NoticeAction(label: tag, identifier: "attestation_source_link") { open(AttestationDetail.tagURL(tag)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.s)
            .accessibilityIdentifier("attestation_source")
            SettingsDivider()
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(AttestationStrings.reproducible).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurface)
                Text(AttestationStrings.rebuildBody).vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                NoticeAction(label: AttestationStrings.rebuild, identifier: "attestation_rebuild") {
                    open(AttestationDetail.rebuildURL(tag))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.gutter)
            .padding(.vertical, Spacing.s)
            .accessibilityIdentifier("attestation_reproducible")
        }
    }
}

/// This iPhone: the App Attest key's state only (IOS-PLAN §4.17), the iOS version and the app's; an Android-shaped value,
/// Android's rows and the app's version. Never copied.
private struct PhoneSection: View {
    let a: AttestationInfo

    var body: some View {
        if let appAttest = a.appAttest {
            SettingsSectionHeader(SettingsStrings.iosAttestationDevice)
            SettingsGroup {
                SettingsInfoRow(
                    SettingsStrings.iosAttestationKey,
                    value: appAttest.accepted ? SettingsStrings.attestationKeyAccepted : SettingsStrings.attestationKeyNotAccepted,
                    icon: .key
                )
                .accessibilityIdentifier("app_attest_key")
                SettingsDivider()
                SettingsInfoRow(AttestationStrings.iosVersion, value: a.osVersion.isEmpty ? "-" : a.osVersion, icon: .phone)
                SettingsDivider()
                SettingsInfoRow(AttestationStrings.appVersion, value: a.appVersion.isEmpty ? "-" : a.appVersion, icon: .tag)
                    .accessibilityIdentifier("attestation_app_version")
            }
            .accessibilityIdentifier("attestation_phone")
        } else {
            AndroidDeviceRows(a: a)
        }
    }
}

/// The canary manifest installed on this phone (VAULT-RELEASES §10.1 step 9): its serial and key, the releases it lists,
/// and "Stop using the test manifest" (after a confirmation; the published manifest is used again); on the iPhone also
/// the row that loads one with the file importer, shown to every member (chosen; not in the spec). Mirrors vettid-android
/// `CanaryManifestSection`.
private struct CanaryManifestSection: View {
    let canary: CanaryManifestView?
    let onRemove: @MainActor () -> Void
    let onLoad: (@MainActor () -> Void)?
    @State private var confirm = false

    var body: some View {
        SettingsSectionHeader(CanaryStrings.sectionTitle)
        SettingsGroup {
            if let canary {
                SettingsInfoRow(CanaryStrings.serial, value: CanaryStrings.serialValue(Int(canary.serial), canary.keyID), icon: .tag)
                SettingsDivider()
                SettingsInfoRow(CanaryStrings.releasesLabel, value: CanaryStrings.settingsReleases(canary), icon: .update)
                SettingsDivider()
                SettingsRow(CanaryStrings.remove, icon: .storage, showChevron: false) { confirm = true }
                    .accessibilityIdentifier("canary_remove")
                if onLoad != nil { SettingsDivider() }
            }
            if let onLoad {
                SettingsRow(CanaryStrings.load, icon: .update, supporting: CanaryStrings.loadBody, showChevron: false, action: onLoad)
                    .accessibilityIdentifier("canary_load")
            }
        }
        .confirmDialog(
            isPresented: $confirm, title: CanaryStrings.removeTitle, message: CanaryStrings.removeBody,
            confirmLabel: CanaryStrings.remove, destructive: true, dismissLabel: SettingsStrings.cancel
        ) {
            confirm = false
            onRemove()
        }
    }
}

/// An Android phone's rows: its key and level, StrongBox, the attestation version, verified boot and the boot key.
private struct AndroidDeviceRows: View {
    let a: AttestationInfo

    var body: some View {
        SettingsSectionHeader(SettingsStrings.attestationDevice)
        SettingsGroup {
            SettingsInfoRow(
                SettingsStrings.attestationKey,
                value: a.keyPresent ? a.keyLevel ?? SettingsStrings.unknown : SettingsStrings.attestationKeyNone,
                icon: .key
            )
            SettingsDivider()
            SettingsInfoRow(SettingsStrings.attestationStrongbox, value: VaultStatusContent.yesNo(a.strongBoxAvailable), icon: .faceID)
            SettingsDivider()
            SettingsInfoRow(SettingsStrings.attestationVersion, value: a.attestationVersion.map(String.init) ?? "-", icon: .tag)
            SettingsDivider()
            SettingsInfoRow(SettingsStrings.attestationBoot, value: a.verifiedBoot ?? "-", icon: .verifiedUser)
            SettingsDivider()
            SettingsInfoRow(SettingsStrings.attestationLocked, value: VaultStatusContent.yesNo(a.deviceLocked), icon: .lock)
            SettingsDivider()
            SettingsInfoRow(SettingsStrings.attestationBootKey, value: a.bootKeyFingerprint ?? "-", icon: .key, code: true)
            SettingsDivider()
            SettingsInfoRow(AttestationStrings.appVersion, value: a.appVersion.isEmpty ? "-" : a.appVersion, icon: .tag)
        }
    }
}
#endif
