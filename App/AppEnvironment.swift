import Foundation

/// The environment a build talks to, fixed by its build configuration
/// (IOS-PLAN §5 "Build configurations"). The values come from
/// `Config/<configuration>.xcconfig` through the app's Info.plist.
struct AppEnvironment: Equatable, Sendable {
    enum Kind: String, Sendable {
        case production
        case staging
        case debug
        case devstack
    }

    let kind: Kind
    let accountHost: String

    /// Reads the environment from an Info.plist dictionary; `nil` when a
    /// key is missing or unknown.
    init?(infoDictionary: [String: Any]) {
        guard
            let raw = infoDictionary["VettIDEnvironment"] as? String,
            let kind = Kind(rawValue: raw),
            let host = infoDictionary["VettIDAccountHost"] as? String,
            !host.isEmpty
        else { return nil }
        self.kind = kind
        self.accountHost = host
    }

    /// This build's environment. A build without one is misconfigured.
    static let current: AppEnvironment = {
        guard let env = AppEnvironment(infoDictionary: Bundle.main.infoDictionary ?? [:]) else {
            preconditionFailure("Info.plist lacks VettIDEnvironment or VettIDAccountHost")
        }
        return env
    }()
}
