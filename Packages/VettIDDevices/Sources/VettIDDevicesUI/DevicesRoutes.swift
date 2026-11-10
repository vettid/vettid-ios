#if os(iOS)
import SwiftUI
import VettIDData
import VettIDDevices
import VettIDUI

/// Where the Devices & agents screens go: a device's page, the two pairings, back, History searched for a device's name, and the daily
/// check. Mirrors vettid-android `DevicesHost`.
public struct DevicesHost {
    public var onOpen: @MainActor (String) -> Void = { _ in }
    public var onBack: @MainActor () -> Void = {}
    /// Opens History with its search set to the device's name (§10.9: the vault's search matches device names).
    public var onOpenHistory: @MainActor (String) -> Void = { _ in }
    /// The pairing screens (AA2): **Pair an agent**, and **Pair a desktop** (vettid-android #291).
    public var onPair: @MainActor () -> Void = {}
    public var onPairDesktop: @MainActor () -> Void = {}
    /// The daily owner check (a refused pairing request says it is due).
    public var onOwnerCheck: @MainActor () -> Void = {}

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
        a.onPair = host.onPair
        a.onPairDesktop = host.onPairDesktop
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
        .onChange(of: ownerChecks?.ownerCheck) { _, check in if check?.state == .ok { model?.ownerCheckPassed() } }
        // "<name> was removed" shows for a moment, then the page leaves; the wait ends with the page.
        .task(id: model?.state.removedDevice?.id) {
            guard model?.state.removedDevice != nil else { return }
            try? await Task.sleep(for: .seconds(removedNoticeSeconds))
            if !Task.isCancelled { model?.removedShown() }
        }
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
        return a
    }
}

/// How long the page shows "<name> was removed" before it leaves.
private let removedNoticeSeconds = 3.0

/// Pairing an agent (AA2) or, with [desktop], a desktop (vettid-android #291), with its view model, made when the screen first
/// appears and released when it goes: leaving it with a pairing not approved rejects it. [held]: opened from the feed item "A device
/// asks to pair", so it shows what is held, never a new code (what is held says its own role).
public struct PairRoute: View {
    private let pairing: any PairingRepository
    private let ownerChecks: (any OwnerCheckRepository)?
    private let held: Bool
    private let desktop: Bool
    private let host: DevicesHost
    @State private var model: PairViewModel?

    public init(
        held: Bool = false, desktop: Bool = false, pairing: any PairingRepository, ownerChecks: (any OwnerCheckRepository)? = nil,
        host: DevicesHost
    ) {
        self.held = held
        self.desktop = desktop
        self.pairing = pairing
        self.ownerChecks = ownerChecks
        self.host = host
    }

    public var body: some View {
        PairScreen(state: model?.state ?? PairState(), actions: actions)
            .onAppear {
                if model == nil { model = PairViewModel(held: held, desktop: desktop, repo: pairing, ownerChecks: ownerChecks) }
            }
    }

    private var actions: PairActions {
        var a = PairActions()
        a.onOwnerCheck = host.onOwnerCheck
        guard let m = model else {
            a.onBack = host.onBack
            return a
        }
        let host = host
        // Leaving a pairing not approved rejects it (the view model's end); a final stage is read.
        a.onBack = {
            m.done()
            host.onBack()
        }
        a.onNewCode = { m.newCode() }
        a.onCopied = { m.copied() }
        a.onCancel = {
            m.cancel()
            host.onBack()
        }
        a.onCodesMatch = { m.codesMatch(pairingID: $0) }
        a.onCloseSheet = { m.closeSheet() }
        a.onChoose = { m.choose($0) }
        a.onPair = { m.pair() }
        a.onReject = { m.reject(pairingID: $0) }
        a.onDone = {
            m.done()
            host.onBack()
        }
        // **Open its page**: the new agent's page over the list.
        a.onOpenPage = { id in
            m.done()
            host.onBack()
            host.onOpen(id)
        }
        return a
    }
}
#endif
