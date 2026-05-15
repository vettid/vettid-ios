import Foundation
import UIKit
import MachO

/// Runtime Application Self-Protection (RASP)
/// Detects jailbreak, debugger, simulator, tampering, and instrumentation
final class RuntimeProtection {

    // MARK: - Singleton

    static let shared = RuntimeProtection()

    private init() {}

    // MARK: - Detection Results

    struct SecurityStatus {
        let isJailbroken: Bool
        let isDebuggerAttached: Bool
        let isSimulator: Bool
        let isTampered: Bool
        let isFridaDetected: Bool
        let isReverseEngineeringDetected: Bool
        let isScreenCaptured: Bool

        var isSecure: Bool {
            return !isJailbroken &&
                   !isDebuggerAttached &&
                   !isSimulator &&
                   !isTampered &&
                   !isFridaDetected &&
                   !isReverseEngineeringDetected
        }

        var threats: [String] {
            var detected: [String] = []
            if isJailbroken { detected.append("Jailbreak detected") }
            if isDebuggerAttached { detected.append("Debugger attached") }
            if isSimulator { detected.append("Running in simulator") }
            if isTampered { detected.append("Binary tampering detected") }
            if isFridaDetected { detected.append("Frida/instrumentation detected") }
            if isReverseEngineeringDetected { detected.append("Reverse engineering tools detected") }
            if isScreenCaptured { detected.append("Screen is being captured") }
            return detected
        }
    }

    /// Perform comprehensive security check
    func checkSecurityStatus() -> SecurityStatus {
        return SecurityStatus(
            isJailbroken: isJailbroken(),
            isDebuggerAttached: isDebuggerAttached(),
            isSimulator: isRunningOnSimulator(),
            isTampered: isBinaryTampered(),
            isFridaDetected: isFridaRunning(),
            isReverseEngineeringDetected: isReverseEngineeringToolDetected(),
            isScreenCaptured: isScreenBeingCaptured()
        )
    }

    // MARK: - Jailbreak Detection

    /// Multi-method jailbreak detection
    func isJailbroken() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return checkJailbreakPaths() ||
               checkJailbreakURLSchemes() ||
               checkSandboxViolation() ||
               checkSymlinks() ||
               checkSuspiciousEnvironmentVariables()
        #endif
    }

    /// Check for common jailbreak file paths.
    ///
    /// Path list curated to strong indicators only — paths like `/bin/sh`,
    /// `/bin/bash`, `/var/log/syslog`, `/etc/ssh/sshd_config`, `/usr/bin/sshd`
    /// can be visible to a sandboxed app via `FileManager.fileExists` on
    /// modern iOS (sandbox semantics shifted ~iOS 15/16); they false-positive
    /// on stock devices. Keep the jailbreak-only artifacts: Cydia/Sileo/Zebra
    /// app bundles, MobileSubstrate / CydiaSubstrate frameworks, jailbreakd
    /// payloads, and apt/lib directories that exist only on jailbroken roots.
    private func checkJailbreakPaths() -> Bool {
        let paths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/Applications/Installer.app",
            "/Applications/blackra1n.app",
            "/Applications/FakeCarrier.app",
            "/Applications/Icy.app",
            "/Applications/IntelliScreen.app",
            "/Applications/MxTube.app",
            "/Applications/RockApp.app",
            "/Applications/SBSettings.app",
            "/Applications/WinterBoard.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/Library/MobileSubstrate/DynamicLibraries/LiveClock.plist",
            "/Library/MobileSubstrate/DynamicLibraries/Veency.plist",
            "/private/var/lib/apt",
            "/private/var/lib/apt/",
            "/private/var/lib/cydia",
            "/private/var/mobile/Library/SBSettings/Themes",
            "/private/var/stash",
            "/private/var/tmp/cydia.log",
            "/System/Library/LaunchDaemons/com.ikey.bbot.plist",
            "/System/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist",
            "/var/cache/apt",
            "/var/lib/apt",
            "/var/lib/cydia",
            "/var/tmp/cydia.log",
            "/.bootstrapped_electra",
            "/usr/lib/libjailbreak.dylib",
            "/jb/lzma",
            "/.cydia_no_stash",
            "/.installed_unc0ver",
            "/jb/jailbreakd.plist",
            "/jb/amfid_payload.dylib",
            "/jb/libjailbreak.dylib",
            "/usr/share/jailbreak/injectme.plist",
            "/Library/Frameworks/CydiaSubstrate.framework",
            "/usr/lib/substrate"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                #if DEBUG
                print("[Security] Jailbreak path hit: \(path)")
                #endif
                return true
            }
        }

        return false
    }

    /// Check for jailbreak-related URL schemes
    private func checkJailbreakURLSchemes() -> Bool {
        let schemes = [
            "cydia://",
            "sileo://",
            "zbra://",
            "filza://",
            "activator://",
            "undecimus://",
            "frida://"
        ]

        for scheme in schemes {
            if let url = URL(string: scheme),
               UIApplication.shared.canOpenURL(url) {
                return true
            }
        }

        return false
    }

    /// Check if app can write outside sandbox (sandbox violation)
    private func checkSandboxViolation() -> Bool {
        let testPath = "/private/jailbreak_test_\(UUID().uuidString)"
        do {
            try "test".write(toFile: testPath, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(atPath: testPath)
            return true
        } catch {
            return false
        }
    }

    /// Check for suspicious symlinks
    private func checkSymlinks() -> Bool {
        let paths = ["/Applications", "/var/stash/Library/Ringtones", "/Library/Ringtones"]
        for path in paths {
            var isSymlink: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isSymlink) {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let type = attrs[.type] as? FileAttributeType,
                   type == .typeSymbolicLink {
                    return true
                }
            }
        }
        return false
    }

    /// Check for suspicious environment variables.
    ///
    /// `DYLD_INSERT_LIBRARIES` is the canonical jailbreak signal but
    /// Xcode sets it in DEBUG builds for sanitizers (ASAN/TSAN/UBSAN)
    /// and other instrumentation. To avoid false-positives we only
    /// inspect this var in Release. The Substrate-specific vars are
    /// safe to check in both configurations — Xcode doesn't set them.
    private func checkSuspiciousEnvironmentVariables() -> Bool {
        let substrateVars = ["_MSSafeMode", "MobileSubstrate", "SubstrateSafeMode"]
        for varName in substrateVars where ProcessInfo.processInfo.environment[varName] != nil {
            #if DEBUG
            print("[Security] Jailbreak env hit: \(varName)")
            #endif
            return true
        }
        #if !DEBUG
        if ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] != nil {
            return true
        }
        #endif
        return false
    }

    // MARK: - Debugger Detection

    /// Check if a debugger is attached
    func isDebuggerAttached() -> Bool {
        #if DEBUG
        return false  // Allow debugging in debug builds
        #else
        return checkPtrace() || checkSysctl() || checkDebuggerEnv()
        #endif
    }

    /// Check using sysctl for debugger
    private func checkSysctl() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }

        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Check using ptrace for anti-debugging
    private func checkPtrace() -> Bool {
        // Note: Calling ptrace with PT_DENY_ATTACH prevents debugger attachment
        // We use it here just for detection, not prevention
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        return result == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Check for debugger environment variables
    private func checkDebuggerEnv() -> Bool {
        let debugVars = ["_MSSafeMode", "LLDB_NAMED_PIPE"]
        for varName in debugVars {
            if ProcessInfo.processInfo.environment[varName] != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Simulator Detection

    /// Check if running in iOS Simulator
    func isRunningOnSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return checkSimulatorArchitecture() || checkSimulatorEnvironment()
        #endif
    }

    private func checkSimulatorArchitecture() -> Bool {
        #if arch(i386) || arch(x86_64)
        // x86 architecture on iOS means simulator
        return true
        #else
        return false
        #endif
    }

    private func checkSimulatorEnvironment() -> Bool {
        if let simulatorHost = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] {
            return !simulatorHost.isEmpty
        }
        if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil {
            return true
        }
        return false
    }

    // MARK: - Binary Integrity / Tamper Detection

    /// Check for binary tampering
    func isBinaryTampered() -> Bool {
        return checkCodeSignature() || checkDynamicLibraries()
    }

    /// Check for invalid code signature
    /// Note: Full code signing verification (SecStaticCode) is only available on macOS
    /// On iOS, we use alternative integrity checks
    private func checkCodeSignature() -> Bool {
        // Check bundle identifier hasn't been modified
        guard let bundleId = Bundle.main.bundleIdentifier else {
            return true  // No bundle identifier - suspicious
        }

        // Verify expected bundle identifier
        let expectedBundleIds = ["com.vettid.app", "dev.vettid.app"]
        if !expectedBundleIds.contains(bundleId) {
            return true  // Bundle ID doesn't match expected values
        }

        // Check executable hasn't been modified by comparing embedded hash
        // This is a simplified check - production apps might embed a hash at build time
        guard let executablePath = Bundle.main.executablePath else {
            return true
        }

        // Verify the executable exists and is readable
        guard FileManager.default.isReadableFile(atPath: executablePath) else {
            return true
        }

        return false
    }

    /// Check for suspicious dynamic libraries by basename only.
    ///
    /// The previous version used `localizedCaseInsensitiveContains` on the
    /// full dylib path, so legitimate frameworks whose path contained any
    /// substring like `"Flex"` (e.g. `Flexibility` framework variants),
    /// `"substrate"`, or `"frida"` produced false positives. Switched to
    /// last-path-component matching against exact dylib names — the same
    /// shape the hooking-frameworks check uses below.
    private func checkDynamicLibraries() -> Bool {
        // Use the dylib *file name*, not the full path. Each entry must
        // match a real attacker-loaded image; broad terms like "substrate"
        // alone are gone because they hit framework paths in normal apps.
        let suspiciousLibs: Set<String> = [
            "FridaGadget.dylib",
            "frida-agent.dylib",
            "libfrida-gadget.dylib",
            "cynject",
            "libcycript.dylib",
            "MobileSubstrate.dylib",
            "CydiaSubstrate",
            "TweakInject.dylib",
            "libblackjack.dylib",
            "SSLKillSwitch.dylib",
            "SSLKillSwitch2.dylib"
        ]

        let count = _dyld_image_count()
        for i in 0..<count {
            guard let imageName = _dyld_get_image_name(i) else { continue }
            let path = String(cString: imageName)
            let basename = (path as NSString).lastPathComponent
            if suspiciousLibs.contains(basename) {
                #if DEBUG
                print("[Security] Tamper dylib hit: \(basename)")
                #endif
                return true
            }
        }

        return false
    }

    // MARK: - Frida/Instrumentation Detection

    /// Check for Frida instrumentation framework
    func isFridaRunning() -> Bool {
        return checkFridaPorts() ||
               checkFridaLibraries() ||
               checkFridaThreads()
    }

    /// Check for Frida default ports
    private func checkFridaPorts() -> Bool {
        let fridaPorts: [UInt16] = [27042, 27043, 27044]

        for port in fridaPorts {
            if canConnectToPort(port) {
                return true
            }
        }

        return false
    }

    /// Check if can connect to a local port.
    ///
    /// Uses a *blocking* connect so we get a definitive yes/no answer.
    /// The previous version returned `true` on `errno == EINPROGRESS`,
    /// which only means the connect is pending — it then almost always
    /// fails with ECONNREFUSED a microsecond later. That false-positive
    /// was firing the "Frida detected" warning on every launch.
    ///
    /// We're connecting to localhost, so a synchronous connect resolves
    /// in microseconds (no DNS, no network round-trip). The fail-closed
    /// behavior is to return `false` — i.e. "port is closed, no Frida"
    /// — on any error other than a successful connect.
    private func canConnectToPort(_ port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock != -1 else { return false }
        defer { close(sock) }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr_ptr in
                connect(sock, sockaddr_ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        // Only `result == 0` indicates a real listener. Anything else
        // (ECONNREFUSED, ETIMEDOUT, etc.) means nothing on the wire.
        return result == 0
    }

    /// Check for Frida-related libraries in memory
    private func checkFridaLibraries() -> Bool {
        let fridaIndicators = [
            "frida",
            "FridaGadget",
            "frida-agent",
            "lz4_decompress_safe_usingDict",
            "gum_invocation_context"
        ]

        let count = _dyld_image_count()
        for i in 0..<count {
            if let imageName = _dyld_get_image_name(i) {
                let name = String(cString: imageName)
                for indicator in fridaIndicators {
                    if name.localizedCaseInsensitiveContains(indicator) {
                        return true
                    }
                }
            }
        }

        return false
    }

    /// Thread-count heuristic was retired. A modest iOS app today (NATS
    /// subscriptions + URLSession + AVAudioSession + Combine + WebRTC's
    /// audio/video/ICE/DTLS workers) routinely runs 60-100+ threads on
    /// a real device. The 50-thread ceiling fired on every cold start
    /// after we wired WebRTC, with zero correlation to actual Frida
    /// presence. Real Frida detection lives in `checkFridaPorts` (now
    /// that `canConnectToPort` is correct) and `checkFridaLibraries`.
    private func checkFridaThreads() -> Bool {
        return false
    }

    // MARK: - Reverse Engineering Tools Detection

    /// Check for reverse engineering tools
    func isReverseEngineeringToolDetected() -> Bool {
        return checkHookingFrameworks() || checkDebuggerProcess()
    }

    /// Check for hooking frameworks
    private func checkHookingFrameworks() -> Bool {
        let hookingLibs = [
            "libsubstrate.dylib",
            "SubstrateLoader.dylib",
            "SubstrateInserter.dylib",
            "libsubstitute.dylib",
            "substitute-loader.dylib",
            "libblackjack.dylib",
            "TweakInject.dylib"
        ]

        let count = _dyld_image_count()
        for i in 0..<count {
            if let imageName = _dyld_get_image_name(i) {
                let name = String(cString: imageName)
                for lib in hookingLibs {
                    if name.hasSuffix(lib) {
                        return true
                    }
                }
            }
        }

        return false
    }

    /// Check for debugger processes
    private func checkDebuggerProcess() -> Bool {
        let debugProcesses = ["debugserver", "lldb", "gdb", "radare2", "r2"]

        // Note: We can't directly check running processes on iOS
        // Instead, check for debugging environment
        for process in debugProcesses {
            if ProcessInfo.processInfo.environment[process.uppercased()] != nil {
                return true
            }
        }

        return false
    }

    // MARK: - Screen Capture Detection

    /// Check if screen is being captured or recorded
    func isScreenBeingCaptured() -> Bool {
        return UIScreen.main.isCaptured
    }

    /// Start monitoring for screen capture
    func startScreenCaptureMonitoring(handler: @escaping (Bool) -> Void) {
        NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            handler(UIScreen.main.isCaptured)
        }
    }

    /// Stop monitoring for screen capture
    func stopScreenCaptureMonitoring() {
        NotificationCenter.default.removeObserver(
            self,
            name: UIScreen.capturedDidChangeNotification,
            object: nil
        )
    }

    // MARK: - Combined Security Check

    /// Perform security check and optionally take action
    func performSecurityCheck(
        allowSimulator: Bool = false,
        allowDebugger: Bool = false,
        onThreatDetected: ((SecurityStatus) -> Void)? = nil
    ) -> Bool {
        var status = checkSecurityStatus()

        // In debug builds, we might allow simulator and debugger
        #if DEBUG
        let isSecure = !status.isJailbroken &&
                       !status.isTampered &&
                       !status.isFridaDetected &&
                       !status.isReverseEngineeringDetected
        #else
        var isSecure = status.isSecure
        if allowSimulator && status.isSimulator {
            isSecure = !status.isJailbroken &&
                       !status.isDebuggerAttached &&
                       !status.isTampered &&
                       !status.isFridaDetected
        }
        if allowDebugger && status.isDebuggerAttached {
            isSecure = !status.isJailbroken &&
                       !status.isSimulator &&
                       !status.isTampered &&
                       !status.isFridaDetected
        }
        #endif

        if !isSecure {
            onThreatDetected?(status)
        }

        return isSecure
    }
}
