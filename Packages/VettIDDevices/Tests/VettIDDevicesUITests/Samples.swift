#if os(iOS)
import Foundation
@testable import VettIDData
@testable import VettIDDevices

/// Devices as the vault shows them, for the screen tests (the same as the view-model tests').
enum Samples {
    static let now = Date(timeIntervalSince1970: 1_792_584_000) // 2026-10-21T12:00:00Z
    static let ik = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    static let phone = DeviceInfo(id: "me", kind: "app", name: "iPhone", thisPhone: true)
    static let agent = DeviceInfo(
        id: "a1", kind: "agent", name: "Claude", ik: ik, createdAt: now.addingTimeInterval(-86_400),
        lastActiveAt: now.addingTimeInterval(-600), sessionExpiresAt: now.addingTimeInterval(1_800), paused: true
    )
    static let desktop = DeviceInfo(id: "d1", kind: "desktop", name: "Laptop", ik: ik, createdAt: now.addingTimeInterval(-172_800))

    /// A calendar in UTC with the US English formats, so that the times read the same wherever the tests run.
    static func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    static func list(_ devices: DeviceInfo..., change: (inout DevicesState) -> Void = { _ in }) -> DevicesState {
        var s = DevicesState()
        s.devices = devices
        s.load = .loaded
        change(&s)
        return s
    }

    static func page(_ device: DeviceInfo?, change: (inout DeviceState) -> Void = { _ in }) -> DeviceState {
        var s = DeviceState()
        s.device = device
        s.loaded = true
        change(&s)
        return s
    }
}
#endif
