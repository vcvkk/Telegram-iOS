import Foundation
import UIKit
import Darwin

private let crashReportFile = "eg_last_crash.txt"

private func crashFilePath() -> String {
    return NSTemporaryDirectory() + crashReportFile
}

// MARK: - Signal handler

private var crashSignals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
private var previousHandlerPtrs: [Int32: UInt] = [:]

// Pre-computed at install() time so it is available inside the signal handler
// without calling malloc-backed APIs on a potentially corrupted heap.
private var precomputedHeader = ""

private func signalName(_ signal: Int32) -> String {
    switch signal {
    case SIGSEGV:  return "SIGSEGV (Segmentation fault)"
    case SIGABRT:  return "SIGABRT (Abort)"
    case SIGBUS:   return "SIGBUS (Bus error)"
    case SIGILL:   return "SIGILL (Illegal instruction)"
    case SIGFPE:   return "SIGFPE (Floating point exception)"
    case SIGTRAP:  return "SIGTRAP (Trap)"
    default:       return "Signal \(signal)"
    }
}

private func currentThreadDescription() -> String {
    if Thread.isMainThread { return "main" }
    let name = Thread.current.name ?? ""
    return name.isEmpty ? "background" : name
}

// Resident memory footprint via Mach task_info — works in signal handler context.
private func currentMemoryUsageMB() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint / 1024 / 1024 : 0
}

private func buildPrecomputedHeader() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    let date = formatter.string(from: Date())

    let bundle = Bundle.main
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build   = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    var sysInfo = utsname()
    uname(&sysInfo)
    let machine = withUnsafePointer(to: &sysInfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }

    let totalRAM = ProcessInfo.processInfo.physicalMemory / 1024 / 1024

    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "x86_64"
    #endif

    return [
        "Date:         \(date)",
        "App Version:  \(version) (\(build))",
        "iOS:          \(UIDevice.current.systemVersion)",
        "Device:       \(machine)",
        "Architecture: \(arch)",
        "Total RAM:    \(totalRAM) MB",
        ""
    ].joined(separator: "\n")
}

private func signalHandler(_ sig: Int32) {
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
    let count = backtrace(&frames, 128)

    let memMB  = currentMemoryUsageMB()
    let thread = currentThreadDescription()

    var report = "=== exteraGram Crash Report ===\n"
    report += precomputedHeader
    report += "Memory Used:  \(memMB) MB\n"
    report += "Thread:       \(thread)\n"
    report += "\n"
    report += "Signal: \(signalName(sig))\n"
    report += "\n"
    report += "Backtrace:\n"

    if let symbols = backtrace_symbols(&frames, count) {
        for i in 0..<Int(count) {
            if let sym = symbols[i] {
                report += String(cString: sym) + "\n"
            }
        }
        free(symbols)
    }

    let path = crashFilePath()
    report.withCString { ptr in
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            _ = write(fd, ptr, strlen(ptr))
            close(fd)
        }
    }

    // Re-raise with the previous handler
    let sdfPtr    = unsafeBitCast(SIG_DFL, to: UInt.self)
    let sigIgnPtr = unsafeBitCast(SIG_IGN, to: UInt.self)
    let prevPtr   = previousHandlerPtrs[sig] ?? sdfPtr

    if prevPtr != sdfPtr && prevPtr != sigIgnPtr {
        let prevHandler = unsafeBitCast(prevPtr, to: sig_t.self)
        prevHandler(sig)
    } else {
        var sa = sigaction()
        sa.__sigaction_u = unsafeBitCast(SIG_DFL, to: __sigaction_u.self)
        sigaction(sig, &sa, nil)
        raise(sig)
    }
}

// MARK: - ObjC exception handler

private func uncaughtExceptionHandler(_ exception: NSException) {
    let memMB  = currentMemoryUsageMB()
    let thread = currentThreadDescription()

    var report = "=== exteraGram Crash Report ===\n"
    report += precomputedHeader
    report += "Memory Used:  \(memMB) MB\n"
    report += "Thread:       \(thread)\n"
    report += "\n"
    report += "Exception: \(exception.name.rawValue)\n"
    report += "Reason:    \(exception.reason ?? "(none)")\n"
    if let userInfo = exception.userInfo, !userInfo.isEmpty {
        report += "User Info: \(userInfo)\n"
    }
    report += "\n"
    report += "Call Stack:\n"
    report += exception.callStackSymbols.joined(separator: "\n")

    try? report.write(toFile: crashFilePath(), atomically: true, encoding: .utf8)
}

// MARK: - Public API

public class EGCrashCatcher {

    public static func install() {
        // Pre-compute on the main thread before any crash can happen
        precomputedHeader = buildPrecomputedHeader()

        NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)

        for sig in crashSignals {
            var sa = sigaction()
            let handler: @convention(c) (Int32) -> Void = signalHandler
            sa.__sigaction_u = unsafeBitCast(handler, to: __sigaction_u.self)
            sa.sa_flags = Int32(SA_NODEFER)
            var old = sigaction()
            sigaction(sig, &sa, &old)
            previousHandlerPtrs[sig] = unsafeBitCast(old.__sigaction_u.__sa_handler, to: UInt.self)
        }
    }

    public static func checkAndReport(in window: UIWindow?) {
        let path = crashFilePath()
        guard FileManager.default.fileExists(atPath: path),
              let report = try? String(contentsOfFile: path, encoding: .utf8),
              !report.isEmpty else { return }

        try? FileManager.default.removeItem(atPath: path)
        UIPasteboard.general.string = report

        DispatchQueue.main.async {
            let alert = UIAlertController(
                title: "exteraGram Crash Detected",
                message: "Crash report copied to clipboard.\n\n" + String(report.prefix(600)),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Share", style: .default) { _ in
                let activityVC = UIActivityViewController(activityItems: [report], applicationActivities: nil)
                window?.rootViewController?.present(activityVC, animated: true)
            })
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            window?.rootViewController?.present(alert, animated: true)
        }
    }
}
