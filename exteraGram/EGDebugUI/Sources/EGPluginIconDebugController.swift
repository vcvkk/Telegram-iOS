import Foundation
import UIKit
import SwiftUI
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import AnimatedStickerNode
import TelegramAnimatedStickerNode
import LegacyUI
import EGSwiftUI
import Display

// MARK: - Log Store

@available(iOS 14.0, *)
private final class DebugLogStore: ObservableObject {
    @Published var entries: [String] = []

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func append(_ msg: String) {
        let ts = DebugLogStore.fmt.string(from: Date())
        let line = "[\(ts)] \(msg)"
        if Thread.isMainThread {
            entries.insert(line, at: 0)
        } else {
            DispatchQueue.main.async { self.entries.insert(line, at: 0) }
        }
    }

    func clear() {
        if Thread.isMainThread { entries = [] }
        else { DispatchQueue.main.async { self.entries = [] } }
    }

    var allText: String { entries.reversed().joined(separator: "\n") }
}

// MARK: - Icon Renderer with Logging

@available(iOS 14.0, *)
private struct DebugIconView: UIViewRepresentable {
    let iconStr: String
    let context: AccountContext
    let size: CGFloat
    let log: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(iconStr: iconStr, context: context, size: size, log: log)
    }

    func makeUIView(context uiCtx: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor.secondarySystemBackground
        v.layer.cornerRadius = size * 0.2
        v.clipsToBounds = true
        uiCtx.coordinator.start(in: v)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator {
        private let iconStr: String
        private let context: AccountContext
        private let size: CGFloat
        private let log: (String) -> Void
        private var packDisposable: Disposable?
        private var fetchDisposable: Disposable?
        private var pathDisposable: Disposable?
        private var node: DefaultAnimatedStickerNodeImpl?

        init(iconStr: String, context: AccountContext, size: CGFloat, log: @escaping (String) -> Void) {
            self.iconStr = iconStr; self.context = context
            self.size = size; self.log = log
        }

        deinit { packDisposable?.dispose(); fetchDisposable?.dispose(); pathDisposable?.dispose() }

        func start(in container: UIView) {
            log("\u{1F50D} Parsing '\(iconStr)'")
            guard let slash = iconStr.lastIndex(of: "/"),
                  let index = Int(iconStr[iconStr.index(after: slash)...]) else {
                log("\u{274C} Parse error: expected 'packName/index'")
                showError(in: container, text: "Bad format")
                return
            }
            let packName = String(iconStr[iconStr.startIndex..<slash])
            log("\u{2705} packName='\(packName)' index=\(index)")

            let iconSize = CGSize(width: size, height: size)
            let pixelSide = Int(size * UIScreen.main.scale)

            log("\u{1F4E6} Loading pack '\(packName)'...")
            packDisposable = (context.engine.stickers.loadedStickerPack(
                    reference: .name(packName), forceActualized: false)
                |> deliverOnMainQueue
            ).startStandalone(next: { [weak container, weak self] result in
                guard let self else { return }
                switch result {
                case .fetching:
                    self.log("\u{23F3} Pack: fetching from server...")
                case .none:
                    self.log("\u{274C} Pack '\(packName)' not found")
                    if let container { self.showError(in: container, text: "Pack not found") }
                case .result(_, let items, let installed):
                    if self.node != nil { return }
                    self.log("\u{2705} Pack: \(items.count) items, installed=\(installed)")
                    guard index < items.count else {
                        self.log("\u{274C} Index \(index) out of range (max \(items.count - 1))")
                        if let container { self.showError(in: container, text: "Index \(index) \u{2265} \(items.count)") }
                        return
                    }
                    self.log("\u{2705} Item[\(index)] found")
                    let file = items[index].file._parse()
                    self.log("\u{1F4C4} resource.id=\(file.resource.id.stringRepresentation) isVideo=\(file.isVideoSticker)")

                    self.pathDisposable = (AnimatedStickerResourceSource(
                        account: self.context.account,
                        resource: file.resource,
                        isVideo: file.isVideoSticker
                    ).directDataPath(attemptSynchronously: false)
                    |> deliverOnMainQueue
                    ).startStandalone(next: { [weak self] path in
                        guard let self, let path else { return }
                        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                        self.log("\u{2705} TGS ready: \(bytes) bytes at ...\(path.suffix(40))")
                    })

                    self.log("\u{2B07}\u{FE0F} Starting download...")
                    self.fetchDisposable = freeMediaFileResourceInteractiveFetched(
                        account: self.context.account,
                        userLocation: .other,
                        fileReference: stickerPackFileReference(file),
                        resource: file.resource
                    ).startStandalone(error: { [weak self] err in
                        self?.log("\u{274C} Download error: \(err)")
                    }, completed: { [weak self] in
                        self?.log("\u{2705} Download completed")
                    })

                    guard let container else { return }
                    self.log("\u{1F3A8} Creating render node (\(pixelSide)\u{00D7}\(pixelSide) px)...")
                    let node = DefaultAnimatedStickerNodeImpl()
                    node.setup(
                        source: AnimatedStickerResourceSource(
                            account: self.context.account,
                            resource: file.resource,
                            isVideo: file.isVideoSticker
                        ),
                        width: pixelSide, height: pixelSide,
                        playbackMode: .loop, mode: .direct(cachePathPrefix: nil)
                    )
                    node.updateLayout(size: iconSize)
                    node.overrideVisibility = true
                    node.visibility = true
                    node.frame = CGRect(origin: .zero, size: iconSize)
                    node.view.frame = CGRect(origin: .zero, size: iconSize)
                    node.started = { [weak self] in
                        self?.log("\u{2705} \u{1F389} FIRST FRAME RENDERED \u{2014} animation is working!")
                    }
                    container.addSubview(node.view)
                    self.node = node
                    self.log("\u{1F3A8} Node added to view, waiting for TGS data...")
                }
            })
        }

        private func showError(in view: UIView, text: String) {
            let label = UILabel()
            label.text = text
            label.font = .systemFont(ofSize: 10)
            label.textColor = .systemRed
            label.textAlignment = .center
            label.numberOfLines = 0
            label.frame = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            view.addSubview(label)
        }
    }
}

// MARK: - Installer Preview Sheet

@available(iOS 14.0, *)
private struct InstallerPreviewSheet: View {
    let iconStr: String
    let context: AccountContext

    @StateObject private var sheetLog = DebugLogStore()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color(UIColor.tertiaryLabel))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8).padding(.bottom, 16)

                Text("Installer Preview")
                    .font(.caption).foregroundColor(.secondary).padding(.bottom, 12)

                DebugIconView(iconStr: iconStr, context: context, size: 78) { msg in
                    sheetLog.append("[SHEET] \(msg)")
                }
                .frame(width: 78, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    ZStack {
                        Circle().fill(Color(UIColor.systemBackground)).frame(width: 26, height: 26)
                        Circle().fill(Color.accentColor).frame(width: 22, height: 22)
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                    }.offset(x: 3, y: 3),
                    alignment: .bottomTrailing
                )
                .padding(.bottom, 12)

                Text("Debug Test Plugin")
                    .font(.system(size: 18, weight: .bold)).padding(.bottom, 4)
                Text("v1.0 \u{00B7} Debug").font(.system(size: 14)).foregroundColor(.secondary).padding(.bottom, 16)

                Text("Install Plugin")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.accentColor).cornerRadius(12)
                    .padding(.horizontal, 16).padding(.bottom, 20)

                if !sheetLog.entries.isEmpty {
                    Divider().padding(.horizontal, 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Sheet Logs").font(.caption.bold()).foregroundColor(.secondary)
                            Spacer()
                            Button("Copy") {
                                UIPasteboard.general.string = sheetLog.allText
                            }.font(.caption)
                        }.padding(.bottom, 4)
                        ForEach(Array(sheetLog.entries.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(entry.contains("\u{274C}") ? .red : entry.contains("\u{2705}") ? .green : .primary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                Color.clear.frame(height: 32)
            }
        }
    }
}

// MARK: - Main Debug View

@available(iOS 14.0, *)
private struct EGPluginIconDebugView: View {
    let context: AccountContext

    @StateObject private var log = DebugLogStore()
    @State private var iconStr: String = "HappyHappyPepe/0"
    @State private var renderKey: UUID = UUID()
    @State private var isRendering: Bool = false
    @State private var showInstaller: Bool = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Icon string (packName/index)")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("HappyHappyPepe/0", text: $iconStr)
                        .font(.system(size: 14, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            } header: { Text("Configuration") }

            Section {
                Button {
                    log.clear()
                    isRendering = false
                    renderKey = UUID()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isRendering = true
                    }
                } label: {
                    Label("Run Download + Render Test", systemImage: "play.fill")
                }

                Button {
                    showInstaller = true
                } label: {
                    Label("Open Installer Preview", systemImage: "square.and.arrow.down")
                }
            } header: { Text("Tests") }

            if isRendering {
                Section {
                    HStack {
                        Spacer()
                        DebugIconView(iconStr: iconStr, context: context, size: 120) { msg in
                            log.append(msg)
                        }
                        .id(renderKey)
                        .frame(width: 120, height: 120)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } header: { Text("Render Preview") }
            }

            Section {
                HStack {
                    Button {
                        UIPasteboard.general.string = log.allText
                    } label: {
                        Label("Copy All Logs", systemImage: "doc.on.doc")
                    }
                    Spacer()
                    Button("Clear") { log.clear() }
                        .foregroundColor(.red)
                }

                if log.entries.isEmpty {
                    Text("No logs yet \u{2014} press \u{25B6} to run tests.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(log.entries.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(
                                entry.contains("\u{274C}") ? .red :
                                entry.contains("\u{2705}") ? Color(UIColor.systemGreen) :
                                entry.contains("\u{23F3}") ? Color(UIColor.systemOrange) :
                                .primary
                            )
                            .lineLimit(nil)
                    }
                }
            } header: { Text("Logs") }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showInstaller) {
            InstallerPreviewSheet(iconStr: iconStr, context: context)
        }
    }
}

// MARK: - Entry Point

func egPluginIconDebugController(context: AccountContext) -> ViewController {
    guard #available(iOS 14.0, *) else { return egDebugController(context: context) }

    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let theme = presentationData.theme
    let strings = presentationData.strings

    let legacyController = LegacySwiftUIController(
        presentation: .navigation,
        theme: theme,
        strings: strings
    )
    legacyController.title = "Plugin Icon Debug"
    legacyController.statusBar.statusBarStyle = theme.rootController.statusBarStyle.style

    let swiftUIView = EGSwiftUIView<EGPluginIconDebugView>(legacyController: legacyController, manageSafeArea: true) {
        EGPluginIconDebugView(context: context)
    }
    let hostingController = UIHostingController(rootView: swiftUIView, ignoreSafeArea: true)
    legacyController.bind(controller: hostingController)

    return legacyController
}
