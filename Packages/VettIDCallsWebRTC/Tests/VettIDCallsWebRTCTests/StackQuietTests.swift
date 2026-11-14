import Foundation
import Testing
@testable import VettIDCallsWebRTC

// The pinned stack prints nothing as shipped (its logging could print addresses, ICE user names and the SDP's fragments).
// This is what the logging guard stands on, since the stack's output level cannot be read and setting it switches the output
// on. iOS only: on macOS a release build of the library may write nothing to stderr under a test runner whatever it is
// asked, so there the test could not fail. (The setter's effect, measured on macOS, cannot be a test here: it is not
// reversible in the process, so it would break every later test.)
#if os(iOS)
@Suite(.serialized) @MainActor
struct StackQuietTests {
    /// The control: the capture sees what is written to stderr, so an empty capture below is a finding and not a blind spot.
    @Test func theCaptureSeesWhatIsWrittenToStderr() throws {
        let capture = try StderrCapture()
        fputs("(control.cc:1): a line of the shape the stack's own output has\n", stderr)
        let text = capture.finish()
        #expect(text.contains("a line of the shape the stack's own output has"))
    }

    @Test func aWholeCallPrintsNoOutputOfTheStack() async throws {
        let capture = try StderrCapture()
        let call = try LoopbackCall()
        try await call.connect(suiteA: .aes128Gcm, suiteB: .aes128Gcm, kCaller: randomKey(), kCallee: randomKey())
        let ok = await call.wait(seconds: 15) {
            call.heardA.states(.receive).contains(.ok) && call.heardB.states(.receive).contains(.ok)
        }
        call.close()
        try await Task.sleep(for: .milliseconds(500))
        let text = capture.finish()
        #expect(ok, "the call connected, so the stack ran")
        // No filter on the shape of a line: nothing of the stack's own files, namespaces or names at all.
        let markers = [".cc:", ".mm:", ".cpp:", ".h:", "rtc::", "RTC_OBJC", "RTCLogging", "ufrag", "Conn[", "Port["]
        let hits = markers.filter { text.contains($0) }
        #expect(hits.isEmpty, "stack output found, markers \(hits)")
    }
}
#endif
