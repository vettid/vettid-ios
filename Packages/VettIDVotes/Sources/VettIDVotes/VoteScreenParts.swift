import Foundation

/// Where the check of the published results again, when the screen opens, is (owner decision 2026-11-02): the numbers
/// are shown only once it passed.
public enum Recheck: Equatable, Sendable { case none, running, done, notChecked }

/// The vault's evidence of a vote, in memory only, handed to the system's file exporter (IOS-PLAN §4.16 "Save the proof"):
/// the bytes are the vault's evidence unchanged; the name is the proposal's id, never the title or the choice. Its
/// description shows nothing of it.
public struct ProofFile: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let bytes: Data
    public let name: String

    public var description: String { "ProofFile(\(bytes.count) bytes)" }
    public var debugDescription: String { description }
}
