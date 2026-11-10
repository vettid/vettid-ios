import Foundation
import Observation
import VettIDData

/// TEST ONLY. An in-memory devices list (ANDROID-PLAN 0.1.53 AA1) for view-model tests and the screen catalog: [devices] is
/// what `device.list` answers; calls are recorded in [calls] (`refresh`, `endAccess:<id>`, `remove:<id>`, `removalBound:<id>`);
/// [fail] makes the next call of a name throw; [bound] is the answer of ``removalBoundSeconds(_:)``. Mirrors vettid-android
/// `FakeDevices`.
@MainActor
@Observable
public final class FakeDevices: DevicesRepository {
    public var devices: [DeviceInfo] = []
    public var load: ListLoad = .loaded
    public var removed: DeviceInfo?

    @ObservationIgnored public var calls: [String] = []
    @ObservationIgnored public var fail: [String: VaultFailure] = [:]
    @ObservationIgnored public var bound: Int64 = 0
    /// Any other error the next call of that name throws (once): a ``CancellationError`` (a lock or the app leaving).
    @ObservationIgnored public var failError: [String: any Error] = [:]

    /// Calls whose failure also forgets the list, as the hold does (the failure is the refused owner check): `devices` empty
    /// and not loaded.
    @ObservationIgnored public var clearsOnFailure: Set<String> = []

    public init() {}

    private func call(_ name: String) throws {
        calls.append(name)
        if clearsOnFailure.contains(name), fail[name] != nil || failError[name] != nil {
            devices = []
            load = .notLoaded
        }
        if let f = fail.removeValue(forKey: name) { throw f }
        if let e = failError.removeValue(forKey: name) { throw e }
    }

    public func refresh() async throws { try call("refresh") }

    public func refreshQuietly() { calls.append("refreshQuietly") }

    public func endAccess(_ deviceID: String) async throws {
        try call("endAccess:\(deviceID)")
        devices = devices.map { d in
            var d = d
            if d.id == deviceID { d.sessionExpiresAt = nil }
            return d
        }
    }

    public func remove(_ deviceID: String) async throws {
        try call("remove:\(deviceID)")
        removed = devices.first { $0.id == deviceID }
        devices = devices.filter { $0.id != deviceID }
    }

    public func removalBoundSeconds(_ agentID: String) async -> Int64 {
        calls.append("removalBound:\(agentID)")
        return bound
    }

    public func dismissRemoved() {
        calls.append("dismissRemoved")
        removed = nil
    }
}
