#if os(iOS)
import SwiftUI
import VettIDData
import VettIDSettings
import VettIDUI

/// Attestation (stateless): what this phone's attestation is and the enclave release it last verified. An iPhone shows
/// its App Attest key (``AppAttestInfo``) where vettid-android shows its hardware key attestation (key level, StrongBox,
/// verified boot), which App Attest does not report; an Android-shaped value still shows Android's rows. [canary]: the
/// installed canary manifest (VettID's test phones only), shown only when there is one, with "Stop using the test
/// manifest"; [onLoadCanary] (the iPhone's file importer) adds the row that loads one. Mirrors vettid-android
/// `AttestationContent`.
public struct AttestationContent: View {
    @Environment(\.vettIDColors) private var colors
    let state: LoadState<AttestationInfo>
    let onBack: @MainActor () -> Void
    let canary: CanaryManifestView?
    let onRemoveCanary: @MainActor () -> Void
    let onLoadCanary: (@MainActor () -> Void)?

    public init(
        state: LoadState<AttestationInfo>,
        onBack: @escaping @MainActor () -> Void = {},
        canary: CanaryManifestView? = nil,
        onRemoveCanary: @escaping @MainActor () -> Void = {},
        onLoadCanary: (@MainActor () -> Void)? = nil
    ) {
        self.state = state
        self.onBack = onBack
        self.canary = canary
        self.onRemoveCanary = onRemoveCanary
        self.onLoadCanary = onLoadCanary
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
        }
    }

    /// An Android-shaped value's body is Android's; the iPhone's names App Attest.
    private var bodyText: String {
        state.value.map { $0.appAttest == nil } == true ? SettingsStrings.attestationBody : SettingsStrings.iosAttestationBody
    }

    @ViewBuilder private func loaded(_ a: AttestationInfo) -> some View {
        if let appAttest = a.appAttest {
            SettingsSectionHeader(SettingsStrings.iosAttestationDevice)
            SettingsGroup {
                SettingsInfoRow(
                    SettingsStrings.iosAttestationKey,
                    value: appAttest.accepted ? SettingsStrings.attestationKeyAccepted : SettingsStrings.attestationKeyNotAccepted,
                    icon: .key
                )
                .accessibilityIdentifier("app_attest_key")
            }
        } else {
            AndroidDeviceRows(a: a)
        }
        SettingsSectionHeader(SettingsStrings.attestationEnclave)
        SettingsGroup {
            SettingsInfoRow(SettingsStrings.attestationRelease, value: Self.releaseText(a), icon: .update)
            SettingsDivider()
            SettingsInfoRow(SettingsStrings.attestationEnvironment, value: a.environment, icon: .storage)
        }
        if canary != nil || onLoadCanary != nil {
            CanaryManifestSection(canary: canary, onRemove: onRemoveCanary, onLoad: onLoadCanary)
        }
        Spacer().frame(height: Spacing.xxl)
    }

    static func releaseText(_ a: AttestationInfo) -> String {
        guard a.lastRelease > 0 else { return "-" }
        return SettingsStrings.attestationReleaseValue(Int(a.lastRelease), a.lastReleaseFingerprint ?? "-")
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
            SettingsInfoRow(SettingsStrings.attestationBootKey, value: a.bootKeyFingerprint ?? "-", icon: .key)
        }
    }
}
#endif
