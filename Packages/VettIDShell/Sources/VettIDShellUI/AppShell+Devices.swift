#if os(iOS)
import SwiftUI
import VettIDData
import VettIDDevices
import VettIDDevicesUI
import VettIDHistory
import VettIDHistoryUI
import VettIDShell

/// The Devices & agents screens over the shell (vettid-android's `devicesDestination`): a device's page, and History searched
/// for its name.
extension AppShell {
    /// Devices & agents, the drawer's destination (a placeholder without the vault's devices).
    @ViewBuilder var devicesRoot: some View {
        if let devices {
            DevicesRoute(devices: devices, ownerChecks: ownerChecks, chrome: chrome, host: devicesHost)
        } else {
            ComingLaterScreen(destination: model.destination, chrome: chrome)
        }
    }

    @ViewBuilder func devicesDetail(_ route: ShellRoute) -> some View {
        switch route {
        case .device(let id):
            if let devices { DeviceRoute(id, devices: devices, host: devicesHost) }
        case .deviceHistory(let query):
            if let history, let historyExport {
                HistoryRoute(
                    history: history, export: historyExport, connections: connections, ownerChecks: ownerChecks, items: items,
                    votes: votes, query: query, chrome: nil, host: historyHost
                )
            }
        default:
            EmptyView()
        }
    }

    /// Where the Devices & agents screens go (vettid-android `DevicesHost`): a device's page over the list, back, and the
    /// device's History (once).
    var devicesHost: DevicesHost {
        let model = model
        var h = DevicesHost()
        h.onOpen = { model.openDevice($0) }
        h.onBack = { model.pop() }
        h.onOpenHistory = { model.openDeviceHistory($0) }
        return h
    }
}
#endif
