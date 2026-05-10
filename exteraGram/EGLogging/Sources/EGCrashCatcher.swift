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

// Pre-computed at install() — safe to read from signal handler.
private var precomputedDeviceLine = ""

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

private func currentMemoryUsageMB() -> UInt64 {
    var info  = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint / 1024 / 1024 : 0
}

// dladdr-based frame — mirrors Android "\tat ClassName.method(File.java:line)"
private func frameString(_ address: UnsafeMutableRawPointer?) -> String {
    guard let addr = address else { return "\tat (null)" }
    let addrInt = UInt(bitPattern: addr)
    var info = Dl_info()
    if dladdr(addr, &info) != 0 {
        let module = info.dli_fname.map {
            String(cString: $0).components(separatedBy: "/").last ?? "?"
        } ?? "?"
        if let symPtr = info.dli_sname, let symBase = info.dli_saddr {
            let sym    = String(cString: symPtr)
            let offset = addrInt - UInt(bitPattern: symBase)
            return "\tat \(module) (\(sym) + \(offset))"
        } else if let imgBase = info.dli_fbase {
            let offset = addrInt - UInt(bitPattern: imgBase)
            return String(format: "\tat %@ + 0x%lx", module, offset)
        }
    }
    return String(format: "\tat 0x%016lx", addrInt)
}

private func buildPrecomputedDeviceLine() -> String {
    let bundle  = Bundle.main
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build   = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    let iosVer  = UIDevice.current.systemVersion
    let memMB   = ProcessInfo.processInfo.physicalMemory / 1024 / 1024

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

    return "exteraGram \(version) (\(build)) | \(machine) | iOS \(iosVer) | \(arch) | \(memMB) MB RAM"
}

private func signalHandler(_ sig: Int32) {
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
    let count  = backtrace(&frames, 128)

    let memUsed = currentMemoryUsageMB()
    let pid     = getpid()
    let tid     = pthread_mach_thread_np(pthread_self())
    let thread  = Thread.isMainThread ? "main" : (Thread.current.name.flatMap { $0.isEmpty ? nil : $0 } ?? "background")

    // Header line with device context (iOS has no Crashlytics to capture this separately)
    var report  = "\(precomputedDeviceLine) | used \(memUsed) MB | pid=\(pid) tid=\(tid) thread=\(thread)\n"
    report     += "\n"
    // Exception line — mirrors "ExceptionType: message" from Android Log.getStackTraceString()
    report     += "\(signalName(sig)): \(signalDescription(sig))\n"
    for i in 0..<Int(count) {
        report += frameString(frames[i]) + "\n"
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
    let memUsed = currentMemoryUsageMB()
    let pid     = getpid()
    let tid     = pthread_mach_thread_np(pthread_self())
    let thread  = Thread.isMainThread ? "main" : (Thread.current.name.flatMap { $0.isEmpty ? nil : $0 } ?? "background")

    var report  = "\(precomputedDeviceLine) | used \(memUsed) MB | pid=\(pid) tid=\(tid) thread=\(thread)\n"
    report     += "\n"
    // Exception line — same structure as Android: "ExceptionType: message"
    report     += "\(exception.name.rawValue): \(exception.reason ?? "(none)")\n"
    if let userInfo = exception.userInfo, !userInfo.isEmpty {
        report += "\tuserInfo: \(userInfo)\n"
    }
    for sym in exception.callStackSymbols {
        report += "\tat \(sym)\n"
    }

    try? report.write(toFile: crashFilePath(), atomically: true, encoding: .utf8)
}

// MARK: - Public API

public class EGCrashCatcher {

    public static func install() {
        precomputedDeviceLine = buildPrecomputedDeviceLine()

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
