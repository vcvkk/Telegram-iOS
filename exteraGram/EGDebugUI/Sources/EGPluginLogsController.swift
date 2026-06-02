import Foundation
import UIKit
import SwiftUI
import AccountContext
import Display
import LegacyUI
import EGSwiftUI
import EGPluginEngine

// MARK: - Live log view

@available(iOS 14.0, *)
private final class PluginLogModel: ObservableObject {
    @Published var entries: [EGPluginDebugLog.Entry] = []
    private var observer: NSObjectProtocol?

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: EGPluginDebugLog.changed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func reload() {
        entries = EGPluginDebugLog.shared.entries.reversed()
    }

    func clear() { EGPluginDebugLog.shared.clear() }

    var allText: String {
        EGPluginDebugLog.shared.entries
            .map { "[\($0.formattedTimestamp)] [\($0.tag)] \($0.message)" }
            .joined(separator: "\n")
    }
}

@available(iOS 14.0, *)
private struct PluginLogsView: View {
    @StateObject private var model = PluginLogModel()
    @State private var showCopied = false

    var body: some View {
        List {
            // ── Status ──────────────────────────────────────────────
            Section(header: Text("STATUS")) {
                let initialized = EGPluginRuntime.shared.isInitialized
                statusRow("Python initialized",
                          initialized ? "YES ✓" : "NO ✗",
                          initialized ? .green : .red)
                statusRow("Log entries", "\(model.entries.count)", .secondary)
            }

            // ── Log stream ──────────────────────────────────────────
            Section(header:
                HStack {
                    Text("LOG")
                    Spacer()
                    Button("Copy") {
                        UIPasteboard.general.string = model.allText
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopied = false }
                    }
                    .font(.system(size: 13))
                    Text("·").foregroundColor(.secondary)
                    Button("Clear") { model.clear() }
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }
            ) {
                if model.entries.isEmpty {
                    Text("No log entries yet.\nInstall or enable a plugin to see output here.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(entry.formattedTimestamp)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text("[\(entry.tag)]")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(colorFor(tag: entry.tag))
                            }
                            Text(entry.message)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .overlay(
            showCopied
                ? AnyView(
                    Text("Copied!")
                        .padding(8)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding()
                )
                : AnyView(EmptyView()),
            alignment: .top
        )
    }

    @ViewBuilder
    private func statusRow(_ label: String, _ value: String, _ valueColor: Color) -> some View {
        HStack {
            Text(label).font(.system(size: 14))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(valueColor)
        }
    }

    private func colorFor(tag: String) -> Color {
        switch tag {
        case "Runtime": return .blue
        case "Engine":  return .orange
        default:        return .purple
        }
    }
}

// MARK: - Entry point

public func egPluginLogsController(context: AccountContext) -> ViewController {
    guard #available(iOS 14.0, *) else {
        return LegacyController(presentation: .navigation, theme: nil)
    }

    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let theme   = presentationData.theme
    let strings = presentationData.strings

    let legacyController = LegacySwiftUIController(
        presentation: .navigation,
        theme: theme,
        strings: strings
    )
    legacyController.title = "Plugin Logs"
    legacyController.statusBar.statusBarStyle = theme.rootController.statusBarStyle.style

    let swiftUIView = EGSwiftUIView<PluginLogsView>(legacyController: legacyController, manageSafeArea: true) {
        PluginLogsView()
    }
    let hostingController = UIHostingController(rootView: swiftUIView, ignoreSafeArea: true)
    legacyController.bind(controller: hostingController)

    return legacyController
}
