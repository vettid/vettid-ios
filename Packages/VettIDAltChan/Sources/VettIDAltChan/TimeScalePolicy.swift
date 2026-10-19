import Foundation
import VettIDCrypto

/// Which time scales (VAULT-MESSAGING 0.43.0 §11.10.9, ``TimeScale``) a build accepts from a vault's instance or a
/// transfer bundle (STAGING-TIME-SCALE §4 item 4, §5.2): a production build (the one that pins the production manifest)
/// only 1; a staging build 1 and 24; a development build that talks to the dev stack 1 to 86,400.
public enum TimeScalePolicy: Equatable, Sendable {
    case production
    case staging
    case development

    public func accepts(_ scale: UInt64) -> Bool {
        switch self {
        case .production: scale == TimeScale.real
        case .staging: scale == TimeScale.real || scale == TimeScale.staging
        case .development: (TimeScale.real...TimeScale.maxDevelopment).contains(scale)
        }
    }

    /// Refuses [scale] unless this build accepts it: nothing is then sealed or sent to that instance (§11.10.9).
    public func check(_ scale: UInt64) throws {
        guard accepts(scale) else { throw TimeScaleRefused(scale: scale) }
    }
}

/// A verified instance (or a transfer bundle) whose time scale this build does not accept: it is treated as malformed and
/// nothing is sent to it. The app says "This vault's software is not for this app. Contact VettID." (§11.10.9).
public struct TimeScaleRefused: Error, Equatable, Sendable, CustomStringConvertible {
    public let scale: UInt64

    public init(scale: UInt64) { self.scale = scale }

    public var description: String { "time scale \(scale) not accepted by this build" }
}
