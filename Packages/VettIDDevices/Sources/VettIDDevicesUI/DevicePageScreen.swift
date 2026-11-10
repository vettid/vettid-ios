#if os(iOS)
import SwiftUI
import VettIDData
import VettIDDevices
import VettIDUI

/// What a device's page can ask for. Mirrors vettid-android `DevicePageActions`.
public struct DevicePageActions {
    public var onBack: @MainActor () -> Void = {}
    public var onEndAccess: @MainActor () -> Void = {}
    public var onRemove: @MainActor () -> Void = {}
    /// The device's History (the search set to its name, §10.9).
    public var onHistory: @MainActor (String) -> Void = { _ in }
    public var onConfirm: @MainActor () -> Void = {}
    public var onDismissConfirm: @MainActor () -> Void = {}
    public var onDismissFailure: @MainActor () -> Void = {}
    public var onAccessEndedShown: @MainActor () -> Void = {}
    public var onRetry: @MainActor () -> Void = {}

    public init() {}
}

/// A device's page (ANDROID-PLAN 0.1.53 AA1; agents and desktops): its name as the device gave it (never renamed here), its
/// role, when it was paired and last active, its key fingerprint, and the access card with **End access**. The pill holds
/// **History** and **Remove**; both ending access and removing are confirmed. Mirrors vettid-android `DevicePageScreen`.
public struct DevicePageScreen: View {
    let state: DeviceState
    let actions: DevicePageActions
    let now: Date
    let calendar: Calendar

    public init(state: DeviceState, actions: DevicePageActions, now: Date = Date(), calendar: Calendar = .current) {
        self.state = state
        self.actions = actions
        self.now = now
        self.calendar = calendar
    }

    /// One way out, however it came about (removed here, or no longer listed): a single step back.
    private var leave: Bool { state.gone || state.removed }

    public var body: some View {
        let d = state.device.flatMap { $0.thisPhone ? nil : $0 }
        DetailScaffold(onBack: actions.onBack) {
            if let d {
                PageContent(state: state, device: d, actions: actions, now: now, calendar: calendar)
            } else {
                Unavailable(state: state, onRetry: actions.onRetry)
            }
        } overlay: {
            if let d { pill(d) }
        }
        .onChange(of: leave, initial: true) { _, leaving in if leaving { actions.onBack() } }
        .deviceToast(state.accessEnded ? DeviceStrings.devicesAccessEnded : nil, bottom: 88, onShown: actions.onAccessEndedShown)
        .confirmDialog(
            isPresented: confirming, title: dialog.title, message: dialog.message, confirmLabel: dialog.confirm,
            destructive: state.confirm == .remove, onConfirm: actions.onConfirm
        )
        .accessibilityIdentifier("device_page")
    }

    /// One dialog for both confirmations (one alert to a view): End access names the device, Remove says what follows.
    private var dialog: Dialog {
        guard let d = state.device else { return Dialog() }
        let name = DeviceTexts.sentenceName(d)
        switch state.confirm {
        case .endAccess?:
            return Dialog(
                title: DeviceStrings.devicesEndAccessTitle(name), message: DeviceStrings.devicesEndAccessBody,
                confirm: DeviceStrings.devicesEndAccess
            )
        case .remove?:
            let text = Self.removeText(agent: d.isAgent, boundSeconds: state.removalBoundSeconds)
            return Dialog(title: DeviceStrings.devicesRemoveTitle(name), message: text, confirm: DeviceStrings.devicesRemove)
        case nil: return Dialog()
        }
    }

    struct Dialog {
        var title = ""
        var message = ""
        var confirm = ""
    }

    private var confirming: Binding<Bool> {
        Binding(get: { state.confirm != nil && state.device != nil }, set: { if !$0 { actions.onDismissConfirm() } })
    }

    /// The remove confirmation: an agent's names how long a service may still accept its permissions, only while it has one.
    static func removeText(agent: Bool, boundSeconds: Int64) -> String {
        guard agent else { return DeviceStrings.devicesRemoveDesktopBody }
        var parts = [DeviceStrings.devicesRemoveAgentBody]
        // "Services it showed a permission to may accept it for up to ...": only while it has a permission.
        if boundSeconds > 0 { parts.append(DeviceStrings.devicesRemoveAgentServices(DurationText.of(TimeInterval(boundSeconds)))) }
        parts.append(DeviceStrings.devicesRemoveAgentAgain)
        return parts.joined(separator: " ")
    }

    private func pill(_ d: DeviceInfo) -> some View { FloatingPillActionBar(Self.pillActions(d, actions)) }

    /// **History** (searched for the device's own name, as it gave it) and **Remove**.
    static func pillActions(_ d: DeviceInfo, _ actions: DevicePageActions) -> [PillAction] {
        var items: [PillAction] = []
        // An empty name would open the unfiltered log: no History for it.
        if !d.name.isEmpty { items.append(PillAction(.history, label: DeviceStrings.devicesHistory) { actions.onHistory(d.name) }) }
        if d.actionable {
            items.append(PillAction(.delete, label: DeviceStrings.devicesRemove, destructive: true, action: actions.onRemove))
        }
        return items
    }
}

/// The page with no device to show: the list could not be read (and no device is known), or it is still being read.
private struct Unavailable: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: DeviceState
    let onRetry: @MainActor () -> Void

    var body: some View {
        VStack {
            if let e = state.loadError {
                NoticeCard(.warning, title: DeviceStrings.devicesErrorTitle, message: e.message(timeScale: timeScale), announce: .polite) {
                    DeviceTextAction(label: DeviceStrings.devicesRetry, identifier: "devices_retry", action: onRetry)
                }
                .accessibilityIdentifier("device_load_failed")
            } else if !state.loaded {
                ProgressView()
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PageContent: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: DeviceState
    let device: DeviceInfo
    let actions: DevicePageActions
    let now: Date
    let calendar: Calendar

    var body: some View {
        let d = device
        let name = DeviceTexts.name(d)
        ScrollView {
            VStack(spacing: Spacing.m) {
                VStack(spacing: Spacing.m) {
                    InitialTile(name, size: 72, colors: deviceTileColors(d, dark: colors.isDark))
                    Text(name)
                        .vettIDFont(.headlineSmall)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.gutter)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("device_name")
                    // The name is what the device says about itself: never verified, never edited here (decision 11).
                    Text(nameNote(d))
                        .vettIDFont(.bodyMedium)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.gutter)
                        .accessibilityIdentifier("device_name_note")
                }
                .padding(.top, Spacing.s)
                if let f = state.failure { failure(f, d) }
                accessCard(d)
                aboutCard(d)
            }
            .padding(.bottom, 96)
        }
    }

    /// Whose word the name is: the agent's, the desktop's, or a device's of a kind this app does not know.
    private func nameNote(_ d: DeviceInfo) -> String {
        if d.isAgent { return DeviceStrings.devicesNameByAgent }
        return d.kind == DeviceInfo.kindDesktop ? DeviceStrings.devicesNameByDesktop : DeviceStrings.devicesNameByDevice
    }

    private func failure(_ f: DeviceFailure, _ d: DeviceInfo) -> some View {
        // A refused daily check says why in the vault's words; anything else says what did not happen.
        let body = if state.error == .ownerCheckRequired, let e = state.error {
            e.message(timeScale: timeScale)
        } else if f == .endAccess {
            DeviceStrings.devicesEndFailed(DeviceTexts.sentenceName(d))
        } else {
            DeviceStrings.devicesRemoveFailed(DeviceTexts.sentenceName(d))
        }
        let title = f == .endAccess ? DeviceStrings.devicesEndFailedTitle : DeviceStrings.devicesRemoveFailedTitle
        return NoticeCard(.warning, title: title, message: body, announce: .assertive) {
            DeviceTextAction(label: DeviceStrings.devicesOk, identifier: "device_failure_ok", action: actions.onDismissFailure)
        }
        .padding(.horizontal, Spacing.s)
        .accessibilityIdentifier("device_failure")
    }

    /// Access: its end and **End access**, or "No access" and how the device asks (§6.8); agents also read the rule.
    private func accessCard(_ d: DeviceInfo) -> some View {
        DetailCard {
            CardTitle(DeviceStrings.devicesAccess)
            Text(DeviceTexts.access(d, now: now, calendar: calendar))
                .vettIDFont(.bodyLarge)
                .accessibilityIdentifier("access_status")
            if d.actionable, d.hasAccess(now) {
                SecondaryButton(DeviceStrings.devicesEndAccess, action: actions.onEndAccess)
                    .disabled(state.busy)
                    .padding(.top, Spacing.m)
                    .accessibilityIdentifier("end_access")
            } else if d.actionable {
                Text(d.isAgent ? DeviceStrings.devicesNoAccessAgent : DeviceStrings.devicesNoAccessDesktop)
                    .vettIDFont(.bodyMedium)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .padding(.top, Spacing.xs)
            }
            if d.isAgent {
                Text(DeviceStrings.devicesAgentsRule)
                    .vettIDFont(.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .padding(.top, Spacing.s)
            }
        }
        .accessibilityIdentifier("access_card")
    }

    private func aboutCard(_ d: DeviceInfo) -> some View {
        DetailCard {
            CardTitle(DeviceStrings.devicesAbout)
            InfoLine(label: DeviceStrings.devicesRole, value: DeviceTexts.role(d))
            if let created = d.createdAt {
                InfoLine(label: DeviceStrings.devicesPairedOn, value: DeviceTexts.full(created, calendar))
            }
            InfoLine(
                label: DeviceStrings.devicesLastActiveLabel,
                value: d.lastActiveAt.map { DeviceTexts.ago($0, now: now, calendar: calendar) } ?? DeviceStrings.devicesNotActiveYet
            )
            if let fingerprint = d.fingerprint {
                Text(DeviceStrings.devicesKey).foregroundStyle(colors.onSurfaceVariant).padding(.top, Spacing.s)
                Text(fingerprint)
                    .vettIDFont(.bodyLarge)
                    .monospaced()
                    .accessibilityIdentifier("device_fingerprint")
            }
        }
        .accessibilityIdentifier("about_card")
    }
}

private struct CardTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .vettIDFont(.titleSmall, weight: .semibold)
            .padding(.bottom, Spacing.s)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct InfoLine: View {
    @Environment(\.vettIDColors) private var colors
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .center) {
            Text(label).foregroundStyle(colors.onSurfaceVariant).frame(maxWidth: .infinity, alignment: .leading)
            Text(value).multilineTextAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }
}
#endif
