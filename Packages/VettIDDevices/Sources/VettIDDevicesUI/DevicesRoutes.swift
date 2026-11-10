#if os(iOS)
import SwiftUI
import VettIDData
import VettIDDevices
import VettIDUI

/// Where the Devices & agents screens go: a device's page, back, and History searched for a device's name. Mirrors vettid-android
/// `DevicesHost`.
public struct DevicesHost {
    public var onOpen: @MainActor (String) -> Void = { _ in }
    public var onBack: @MainActor () -> Void = {}
    /// Opens History with its search set to the device's name (§10.9: the vault's search matches device names).
    public var onOpenHistory: @MainActor (String) -> Void = { _ in }

    public init() {}
}

/// How often the rows' "Access until" and "Last active" are worked out again while the screen is shown.
private let clockSeconds = 30.0

/// The Devices & agents list with its view model (the drawer's Devices & agents). Read when the screen opens and on every
/// return to it; a list refused because the daily check was due reads again once a check passes.
public struct DevicesRoute: View {
    private let devices: any DevicesRepository
    private let ownerChecks: (any OwnerCheckRepository)?
    private let chrome: ShellChrome
    private let host: DevicesHost
    @State private var model: DevicesViewModel?

    public init(devices: any DevicesRepository, ownerChecks: (any OwnerCheckRepository)? = nil, chrome: ShellChrome, host: DevicesHost) {
        self.devices = devices
        self.ownerChecks = ownerChecks
        self.chrome = chrome
        self.host = host
    }

    public var body: some View {
        // The minute clock the rows follow while the screen is shown.
        TimelineView(.periodic(from: .now, by: clockSeconds)) { timeline in
            DevicesScreen(state: model?.state ?? DevicesState(), chrome: chrome, now: timeline.date, actions: actions)
        }
        .onAppear {
            if model == nil { model = DevicesViewModel(repo: devices, ownerChecks: ownerChecks) }
            model?.refresh()
        }
    }

    private var actions: DevicesActions {
        var a = DevicesActions()
        a.onOpen = host.onOpen
        guard let m = model else { return a }
        a.onRetry = { m.refresh() }
        a.onRemovedShown = { m.removedShown() }
        return a
    }
}

/// One device's page with its view model, made when the screen first appears and released when it goes. The model holds the
/// device's id and the devices repository alone: it can never sign or ask for a password.
public struct DeviceRoute: View {
    private let id: String
    private let devices: any DevicesRepository
    private let ownerChecks: (any OwnerCheckRepository)?
    private let host: DevicesHost
    @State private var model: DeviceViewModel?

    public init(_ id: String, devices: any DevicesRepository, ownerChecks: (any OwnerCheckRepository)? = nil, host: DevicesHost) {
        self.id = id
        self.devices = devices
        self.ownerChecks = ownerChecks
        self.host = host
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: clockSeconds)) { timeline in
            DevicePageScreen(state: model?.state ?? DeviceState(), actions: actions, now: timeline.date)
        }
        .onAppear { if model == nil { model = DeviceViewModel(id: id, repo: devices) } }
        // The daily check passed or the hold ended: a page the hold left without its device reads again (opened from the feed
        // it has no list screen to do it). The route tells the model, which holds only the id and the repository.
        .onChange(of: ownerChecks?.ownerCheck?.state == .ok) { _, passed in if passed { model?.ownerCheckPassed() } }
    }

    private var actions: DevicePageActions {
        var a = DevicePageActions()
        a.onBack = host.onBack
        a.onHistory = host.onOpenHistory
        guard let m = model else { return a }
        a.onEndAccess = { m.askEndAccess() }
        a.onRemove = { m.askRemove() }
        a.onConfirm = { m.confirm() }
        a.onDismissConfirm = { m.dismissConfirm() }
        a.onDismissFailure = { m.dismissFailure() }
        a.onAccessEndedShown = { m.accessEndedShown() }
        a.onRetry = { m.refresh() }
        a.onRemovedShown = {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(removedNoticeSeconds))
                m.removedShown()
            }
        }
        return a
    }
}

/// How long the page shows "<name> was removed" before it leaves.
private let removedNoticeSeconds = 3.0
#endif
