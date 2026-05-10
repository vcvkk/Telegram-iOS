import Foundation
import UIKit

private let crashReportFile = "eg_last_crash.txt"

private func crashFilePath() -> String {
    return NSTemporaryDirectory() + crashReportFile
}

// MARK: - Signal handler

private var crashSignals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
// Store previous handlers as raw pointers to avoid Swift sig_t comparison issues
private var previousHandlerPtrs: [Int32: UInt] = [:]

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

private func signalHandler(_ sig: Int32) {
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
    let count = backtrace(&frames, 64)

    var report = "=== exteraGram Crash Report ===\n"
    report += "Signal: \(signalName(sig))\n\n"
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

    // Re-raise with default handler
    let sdfPtr = unsafeBitCast(SIG_DFL, to: UInt.self)
    let sigIgnPtr = unsafeBitCast(SIG_IGN, to: UInt.self)
    let prevPtr = previousHandlerPtrs[sig] ?? sdfPtr

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
    var report = "=== exteraGram Crash Report ===\n"
    report += "Exception: \(exception.name.rawValue)\n"
    report += "Reason: \(exception.reason ?? "nil")\n\n"
    report += "Call Stack:\n"
    report += exception.callStackSymbols.joined(separator: "\n")

    try? report.write(toFile: crashFilePath(), atomically: true, encoding: .utf8)
}

// MARK: - Public API

public class EGCrashCatcher {

    public static func install() {
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
                message: "Crash report copied to clipboard.\n\n" + String(report.prefix(400)),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            window?.rootViewController?.present(alert, animated: true)
        }
    }
}
