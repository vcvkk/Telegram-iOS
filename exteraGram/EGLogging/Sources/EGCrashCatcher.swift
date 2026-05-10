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

// Pre-computed at install() — available in signal handler without malloc-backed calls.
private var precomputedHeader = ""

private func signalName(_ signal: Int32) -> String {
    switch signal {
    case SIGSEGV:  return "SIGSEGV"
    case SIGABRT:  return "SIGABRT"
    case SIGBUS:   return "SIGBUS"
    case SIGILL:   return "SIGILL"
    case SIGFPE:   return "SIGFPE"
    case SIGTRAP:  return "SIGTRAP"
    default:       return "SIG\(signal)"
    }
}

private func signalDescription(_ signal: Int32) -> String {
    switch signal {
    case SIGSEGV:  return "Segmentation fault"
    case SIGABRT:  return "Abort"
    case SIGBUS:   return "Bus error"
    case SIGILL:   return "Illegal instruction"
    case SIGFPE:   return "Floating point exception"
    case SIGTRAP:  return "Trap"
    default:       return "Unknown"
    }
}

private func currentMemoryUsage() -> (used: UInt64, total: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    let used  = kr == KERN_SUCCESS ? info.phys_footprint / 1024 / 1024 : 0
    let total = ProcessInfo.processInfo.physicalMemory / 1024 / 1024
    return (used, total)
}

// dladdr-based frame formatter — matches Android NDK tombstone style:
//   #00  0x000000010521f000  TelegramCoreFramework (SomeSymbol + 44)
private func formatFrame(_ index: Int, _ address: UnsafeMutableRawPointer?) -> String {
    guard let addr = address else {
        return String(format: "  #%02d  (null)", index)
    }
    let addrInt = UInt(bitPattern: addr)
    var info = Dl_info()
    if dladdr(addr, &info) != 0 {
        let module = info.dli_fname.map {
            String(cString: $0).components(separatedBy: "/").last ?? "?"
        } ?? "?"
        if let symPtr = info.dli_sname, let symBase = info.dli_saddr {
            let sym    = String(cString: symPtr)
            let offset = addrInt - UInt(bitPattern: symBase)
            return String(format: "  #%02d  0x%016lx  %@ (%@ + %lu)", index, addrInt, module, sym, offset)
        } else if let imgBase = info.dli_fbase {
            let offset = addrInt - UInt(bitPattern: imgBase)
            return String(format: "  #%02d  0x%016lx  %@ + %lu", index, addrInt, module, offset)
        }
    }
    return String(format: "  #%02d  0x%016lx", index, addrInt)
}

private func buildPrecomputedHeader() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    let date = formatter.string(from: Date())

    let bundle    = Bundle.main
    let version   = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build     = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    let bundleId  = bundle.bundleIdentifier ?? "com.exteragram.messenger"

    var sysInfo = utsname()
    uname(&sysInfo)
    let machine = withUnsafePointer(to: &sysInfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }

    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "x86_64"
    #endif

    return """
    *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
    App:     exteraGram \(version) (\(build))
    Package: \(bundleId)
    iOS:     \(UIDevice.current.systemVersion)
    Device:  \(machine) (\(arch))
    Date:    \(date)

    """
}

private func signalHandler(_ sig: Int32) {
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
    let count  = backtrace(&frames, 128)

    let (memUsed, memTotal) = currentMemoryUsage()
    let pid    = getpid()
    let tid    = pthread_mach_thread_np(pthread_self())
    let thread = Thread.isMainThread ? "main" : (Thread.current.name.flatMap { $0.isEmpty ? nil : $0 } ?? "background")

    var report  = precomputedHeader
    report += "pid: \(pid), tid: \(tid), name: \(thread)\n"
    report += "RAM: \(memUsed) MB used / \(memTotal) MB total\n"
    report += "\n"
    report += "signal \(sig) (\(signalName(sig))) — \(signalDescription(sig))\n"
    report += "\n"
    report += "backtrace:\n"

    for i in 0..<Int(count) {
        report += formatFrame(i, frames[i]) + "\n"
    }

    let path = crashFilePath()
    report.withCString { ptr in
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            _ = write(fd, ptr, strlen(ptr))
            close(fd)
        }
    }

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
    let (memUsed, memTotal) = currentMemoryUsage()
    let pid    = getpid()
    let tid    = pthread_mach_thread_np(pthread_self())
    let thread = Thread.isMainThread ? "main" : (Thread.current.name.flatMap { $0.isEmpty ? nil : $0 } ?? "background")

    var report  = precomputedHeader
    report += "pid: \(pid), tid: \(tid), name: \(thread)\n"
    report += "RAM: \(memUsed) MB used / \(memTotal) MB total\n"
    report += "\n"
    report += "FATAL EXCEPTION: \(thread)\n"
    report += "\(exception.name.rawValue): \(exception.reason ?? "(none)")\n"
    if let userInfo = exception.userInfo, !userInfo.isEmpty {
        report += "userInfo: \(userInfo)\n"
    }
    report += "\n"
    report += "backtrace:\n"
    report += exception.callStackSymbols
        .enumerated()
        .map { i, sym in String(format: "  #%02d  %@", i, sym) }
        .joined(separator: "\n")

    try? report.write(toFile: crashFilePath(), atomically: true, encoding: .utf8)
}

// MARK: - Public API

public class EGCrashCatcher {

    public static func install() {
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
