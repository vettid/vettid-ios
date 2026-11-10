#if os(iOS)
import SwiftUI
import VettIDData
import VettIDDevices
import VettIDUI

/// What the Devices & agents list can ask for. Mirrors vettid-android `DevicesScreen`'s callbacks.
public struct DevicesActions {
    public var onOpen: @MainActor (String) -> Void = { _ in }
    public var onRetry: @MainActor () -> Void = {}
    /// The "<name> was removed" message was shown (it is told once).
    public var onRemovedShown: @MainActor () -> Void = {}

    public init() {}
}

/// Devices & agents (ANDROID-PLAN 0.1.53 AA1): this phone first, then the member's agents, then desktops, each newest first. A
/// row is the name, the role, the access ("Access until 15:40" / "No access") and the last activity; an agent the vault paused
/// carries a "Paused" chip. With this phone alone: "Nothing paired yet". A list that could not be read says so, above what was
/// read before. Mirrors vettid-android `DevicesScreen`.
public struct DevicesScreen: View {
    @Environment(\.vettIDTimeScale) private var timeScale
    let state: DevicesState
    let chrome: ShellChrome
    let now: Date
    let calendar: Calendar
    let actions: DevicesActions

    public init(state: DevicesState, chrome: ShellChrome, now: Date = Date(), calendar: Calendar = .current, actions: DevicesActions) {
        self.state = state
        self.chrome = chrome
        self.now = now
        self.calendar = calendar
        self.actions = actions
    }

    /// The name as the list shows it (a name that could pass for the phone or VettID comes with its role), in a sentence.
    private var removedText: String? { state.removedDevice.map { DeviceStrings.devicesRemoved(DeviceTexts.sentenceName($0)) } }

    public var body: some View {
        TopLevelScaffold(title: DeviceStrings.devicesTitle, chrome: chrome) { content }
            .deviceToast(removedText, onShown: actions.onRemovedShown)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("devices_screen")
    }

    @ViewBuilder private var content: some View {
        if state.loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("devices_loading")
        } else if state.devices.isEmpty, let error = state.shownError {
            ErrorCard(error: error, timeScale: timeScale, onRetry: actions.onRetry)
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.onlyThisPhone {
            // This phone only: "Nothing paired yet".
            VStack(spacing: 0) {
                ForEach(state.devices.filter(\.thisPhone)) { ThisPhoneRow(device: $0) }
                EmptyState(icon: .devices, title: DeviceStrings.devicesEmptyTitleAny, message: DeviceStrings.devicesEmptyBodyAny)
                    .accessibilityIdentifier("devices_empty")
            }
            .accessibilityIdentifier("devices")
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error = state.shownError {
                    // The list on screen is what was read before; a refresh that failed says so above it.
                    ErrorCard(error: error, timeScale: timeScale, onRetry: actions.onRetry)
                        .padding(.horizontal, Spacing.gutter).padding(.vertical, Spacing.s)
                }
                ForEach(state.devices.filter(\.thisPhone)) { ThisPhoneRow(device: $0) }
                ForEach(state.devices.filter { !$0.thisPhone }) { d in
                    DeviceRow(device: d, now: now, calendar: calendar) { actions.onOpen(d.id) }
                }
            }
            .padding(.bottom, Spacing.xxl)
        }
        .accessibilityIdentifier("devices")
    }
}

/// "Could not load your devices" with **Try again**.
private struct ErrorCard: View {
    let error: FailureKind
    let timeScale: UInt64
    let onRetry: @MainActor () -> Void

    var body: some View {
        NoticeCard(.warning, title: DeviceStrings.devicesErrorTitle, message: error.message(timeScale: timeScale), announce: .polite) {
            DeviceTextAction(label: DeviceStrings.devicesRetry, identifier: "devices_retry", action: onRetry)
        }
        .accessibilityIdentifier("devices_error")
    }
}

/// This phone's own entry: "This phone", no actions (it leaves only by a transfer or a recovery, §6.7), not tappable.
private struct ThisPhoneRow: View {
    let device: DeviceInfo

    var body: some View {
        VettIDListRow(title: DeviceStrings.devicesThisPhone, tileStyle: .ownAccount, tileIcon: .phone)
            .accessibilityIdentifier("device_\(device.id)")
    }
}

/// One agent or desktop: the initial tile (agents orange, desktops purple), name, role, access and last activity.
struct DeviceRow: View {
    @Environment(\.vettIDColors) private var colors
    let device: DeviceInfo
    let now: Date
    let calendar: Calendar
    let onTap: @MainActor () -> Void

    var body: some View {
        let name = DeviceTexts.name(device)
        VettIDListRow(
            title: name, supporting: DeviceTexts.access(device, now: now, calendar: calendar), meta: DeviceTexts.role(device),
            tileName: name, tileColors: deviceTileColors(device, dark: colors.isDark), onTap: onTap,
            below: {
                HStack(spacing: Spacing.s) {
                    Text(DeviceTexts.lastActive(device, now: now, calendar: calendar))
                        .vettIDFont(.bodySmall)
                        .foregroundStyle(colors.onSurfaceVariant)
                    if device.paused { PausedChip() }
                }
            }
        )
        .accessibilityIdentifier("device_\(device.id)")
    }
}

/// "Paused": the vault paused this agent (§10.11); in the error colour, in words.
private struct PausedChip: View {
    @Environment(\.vettIDColors) private var colors

    var body: some View {
        Text(DeviceStrings.devicesPaused)
            .vettIDFont(.labelSmall)
            .foregroundStyle(colors.error)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(colors.error.opacity(0.14), in: VettIDShape.pill)
            .accessibilityIdentifier("paused_chip")
    }
}
#endif
