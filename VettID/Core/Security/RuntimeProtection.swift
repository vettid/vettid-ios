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

    /// Check for common jailbreak file paths
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
            "/usr/bin/sshd",
            "/usr/libexec/sftp-server",
            "/usr/libexec/ssh-keysign",
            "/usr/sbin/sshd",
            "/bin/bash",
            "/bin/sh",
            "/etc/apt",
            "/etc/ssh/sshd_config",
            "/var/cache/apt",
            "/var/lib/apt",
            "/var/lib/cydia",
            "/var/log/syslog",
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

    /// Check for suspicious environment variables
    private func checkSuspiciousEnvironmentVariables() -> Bool {
        let suspiciousVars = [
            "DYLD_INSERT_LIBRARIES",
            "_MSSafeMode",
            "MobileSubstrate",
            "SubstrateSafeMode"
        ]

        for varName in suspiciousVars {
            if ProcessInfo.processInfo.environment[varName] != nil {
                return true
            }
        }

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

    /// Check for suspicious dynamic libraries
    private func checkDynamicLibraries() -> Bool {
        let suspiciousLibs = [
            "FridaGadget",
            "frida",
            "cynject",
            "libcycript",
            "substrate",
            "MobileSubstrate",
            "TweakInject",
            "libblackjack",
            "SSLKillSwitch",
            "Flex"
        ]

        let count = _dyld_image_count()
        for i in 0..<count {
            if let imageName = _dyld_get_image_name(i) {
                let name = String(cString: imageName)
                for lib in suspiciousLibs {
                    if name.localizedCaseInsensitiveContains(lib) {
                        return true
                    }
                }
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

    /// Check if can connect to a local port
    private func canConnectToPort(_ port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock != -1 else { return false }
        defer { close(sock) }

        // Set non-blocking
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddr_ptr in
                connect(sock, sockaddr_ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0 || errno == EINPROGRESS
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

    /// Check for suspicious threads (Frida creates threads)
    private func checkFridaThreads() -> Bool {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS else { return false }

        defer {
            if let list = threadList {
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_act_t>.size))
            }
        }

        // Frida typically creates multiple threads with specific patterns
        // This is a heuristic check - high thread count might indicate instrumentation
        return threadCount > 50  // Normal apps rarely have this many threads
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
