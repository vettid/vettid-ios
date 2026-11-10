import Foundation
@testable import VettIDData
import VettIDDataTesting
@testable import VettIDDevices

/// Devices as the vault shows them, for the tests. Mirrors the fixtures of vettid-android `DevicesViewModelsTest`.
enum Samples {
    /// The middle of a day in every zone: "today" is the 21st wherever the tests run.
    static let now = Date(timeIntervalSince1970: 1_792_584_000) // 2026-10-21T12:00:00Z
    static let ik = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    static let phone = DeviceInfo(id: "me", kind: "app", name: "iPhone", thisPhone: true)
    static let agent = DeviceInfo(
        id: "a1", kind: "agent", name: "Claude", ik: ik, createdAt: now.addingTimeInterval(-86_400),
        lastActiveAt: now.addingTimeInterval(-600), sessionExpiresAt: now.addingTimeInterval(1_800)
    )
    static let desktop = DeviceInfo(id: "d1", kind: "desktop", name: "Laptop", ik: ik, createdAt: now.addingTimeInterval(-172_800))

    /// A calendar in UTC with the US English formats, so that the times read the same wherever the tests run.
    static func calendar(offsetHours: Int = 0) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: offsetHours * 3_600)!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    /// `n` seconds before [now].
    static func before(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    @MainActor
    static func fake(_ devices: [DeviceInfo]? = nil) -> FakeDevices {
        let f = FakeDevices()
        f.devices = devices ?? [phone, agent, desktop]
        return f
    }
}
