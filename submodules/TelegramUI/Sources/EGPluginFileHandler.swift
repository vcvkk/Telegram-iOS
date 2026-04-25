// MARK: exteraGram — .plugin file metadata display

import Foundation
import UIKit
import SwiftUI
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import AnimatedStickerNode
import TelegramAnimatedStickerNode
import StickerResources
import EGSettingsUI

// MARK: - Metadata Model

struct EGPluginFileMetadata {
    var id: String?
    var name: String?
    var description: String?
    var author: String?
    var version: String?
    var icon: String?
    var requirements: [String] = []
    var appVersion: String?
    var sdkVersion: String?

    var isEmpty: Bool {
        return id == nil && name == nil && description == nil && author == nil && version == nil
    }

    static func parse(from text: String) -> EGPluginFileMetadata {
        var meta = EGPluginFileMetadata()
        for line in text.components(separatedBy: .newlines) {
            guard let (key, value) = parseLine(line) else { continue }
            switch key {
            case "id":          meta.id = value
            case "name":        meta.name = value
            case "description": meta.description = value
            case "author":      meta.author = value
            case "version":     meta.version = value
            case "icon":        meta.icon = value
            case "requirements":
                meta.requirements = value.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "app_version": meta.appVersion = value
            case "sdk_version": meta.sdkVersion = value
            default:            break
            }
        }
        return meta
    }

    // Parses lines of the form:  __key__ = "value"
    private static func parseLine(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("__") else { return nil }
        let separator = "__ = \""
        guard let sepRange = trimmed.range(of: separator) else { return nil }
        let key = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<sepRange.lowerBound])
        guard !key.isEmpty else { return nil }
        let remaining = String(trimmed[sepRange.upperBound...])
        guard remaining.hasSuffix("\"") else { return nil }
        return (key, String(remaining.dropLast()))
    }
}

// MARK: - Activity Sheet

@available(iOS 14.0, *)
private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Requirements Chips (matches Android PluginRequirementsView)

@available(iOS 14.0, *)
private struct RequirementChipsView: View {
    let requirements: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(requirements, id: \.self) { req in
                    Button(action: { openPyPI(req) }) {
                        Text(req)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(UIColor.systemBlue))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(UIColor.systemBlue).opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 21)
        }
    }

    private func openPyPI(_ spec: String) {
        let pkg = spec.components(separatedBy: CharacterSet(charactersIn: "><=!~")).first?
            .trimmingCharacters(in: .whitespaces) ?? spec
        guard let url = URL(string: "https://pypi.org/project/\(pkg)/") else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Animated Sticker Icon (matches Android BackupImageView with setPlaceholderImageByIndex)

@available(iOS 14.0, *)
private struct EGStickerIconView: UIViewRepresentable {
    let file: TelegramMediaFile
    let context: AccountContext

    func makeUIView(context uiContext: Context) -> UIView {
        let containerView = UIView()
        containerView.backgroundColor = .clear

        let node = DefaultAnimatedStickerNodeImpl()
        node.setup(
            source: AnimatedStickerResourceSource(
                account: self.context.account,
                resource: file.resource,
                fitzModifier: nil
            ),
            width: Int(78 * UIScreen.main.scale),
            height: Int(78 * UIScreen.main.scale),
            playbackMode: .loop,
            mode: .direct(cachePathPrefix: nil)
        )
        node.updateLayout(size: CGSize(width: 78, height: 78))
        node.visibility = true
        node.view.frame = CGRect(x: 0, y: 0, width: 78, height: 78)
        containerView.addSubview(node.view)

        // Retain the ASDisplayNode — UIView does not hold a strong reference to its node
        objc_setAssociatedObject(containerView, &EGStickerIconView.nodeKey, node, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Trigger download if not cached yet
        let _ = freeMediaFileInteractiveFetched(
            account: self.context.account,
            userLocation: .other,
            fileReference: .standalone(media: file)
        ).startStandalone()

        return containerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private static var nodeKey: UInt8 = 0
}

// MARK: - Disposable lifetime wrapper for use with @State

private final class DisposableWrapper {
    private let inner: Disposable
    init(_ d: Disposable) { inner = d }
    deinit { inner.dispose() }
}

// MARK: - SwiftUI Bottom Sheet

@available(iOS 14.0, *)
private struct EGPluginInstallSheet: View {
    let metadata: EGPluginFileMetadata
    let filePath: String
    let context: AccountContext
    @Environment(\.presentationMode) private var presentationMode
    @State private var isInstalling = false
    @State private var enableAfterInstall = true
    @State private var showShareSheet = false
    @State private var iconFile: TelegramMediaFile? = nil
    @State private var iconLoader: DisposableWrapper? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 0) {
                    // Drag handle
                    Capsule()
                        .fill(Color(UIColor.tertiaryLabel))
                        .frame(width: 36, height: 4)
                        .padding(.top, 8)
                        .padding(.bottom, 20)

                    // Plugin icon — sticker from pack if available, puzzle piece placeholder otherwise
                    iconView
                        .padding(.bottom, 16)
                        .onAppear(perform: loadIcon)

                    // Plugin name
                    Text(metadata.name ?? "Plugin")
                        .font(.system(size: 18, weight: .bold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 4)

                    // Version · Author
                    if metadata.version != nil || metadata.author != nil {
                        HStack(spacing: 0) {
                            if let version = metadata.version {
                                Text("v\(version)")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(UIColor.secondaryLabel))
                            }
                            if metadata.version != nil && metadata.author != nil {
                                Text(" · ")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(UIColor.tertiaryLabel))
                            }
                            if let author = metadata.author {
                                Text(author)
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(UIColor.secondaryLabel))
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    // Trust badge — always "Unknown source" until we have verification
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 12))
                        Text("Unknown source")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(Color(UIColor.systemOrange))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color(UIColor.systemOrange).opacity(0.12))
                    .clipShape(Capsule())
                    .padding(.bottom, 16)

                    // Requirements chips
                    if !metadata.requirements.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Requires:")
                                .font(.system(size: 12))
                                .foregroundColor(Color(UIColor.secondaryLabel))
                                .padding(.horizontal, 21)
                            RequirementChipsView(requirements: metadata.requirements)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 20)
                    }

                    // Description
                    if let description = metadata.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 15))
                            .foregroundColor(Color(UIColor.label))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 21)
                            .padding(.bottom, 20)
                    }

                    // Install button — .borderedProminent picks up Liquid Glass on iOS 26+
                    installButton

                    // Enable after installation toggle
                    Toggle("Enable after installation", isOn: $enableAfterInstall)
                        .font(.system(size: 15))
                        .padding(.horizontal, 21)
                        .padding(.bottom, 16)

                    // Safe area bottom padding
                    Color.clear.frame(height: 16)
                }
            }

            // Top-right: share / open-in button
            Button(action: { showShareSheet = true }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(UIColor.secondaryLabel))
                    .frame(width: 30, height: 30)
                    .background(Color(UIColor.tertiarySystemFill))
                    .clipShape(Circle())
            }
            .padding(.top, 16)
            .padding(.trailing, 16)
            .sheet(isPresented: $showShareSheet) {
                ActivitySheet(items: [URL(fileURLWithPath: filePath)])
            }
        }
    }

    // MARK: Icon view — sticker with badge overlay, or puzzle piece placeholder

    @ViewBuilder
    private var iconView: some View {
        if let file = iconFile {
            // Sticker icon (matches Android BackupImageView with rounded rect + badge)
            EGStickerIconView(file: file, context: context)
                .frame(width: 78, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    // Puzzle piece badge at bottom-right (matches Android canvas overlay)
                    ZStack {
                        Circle()
                            .fill(Color(UIColor.systemBackground))
                            .frame(width: 26, height: 26)
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 22, height: 22)
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .offset(x: 3, y: 3),
                    alignment: .bottomTrailing
                )
        } else {
            // Placeholder — plain circle with puzzle piece
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 78, height: 78)
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.white)
            }
        }
    }

    // MARK: Install button — Liquid Glass on iOS 15+, manual style below

    @ViewBuilder
    private var installButton: some View {
        if #available(iOS 15.0, *) {
            Button(action: performInstall) {
                ZStack {
                    if isInstalling {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Install Plugin")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isInstalling)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        } else {
            Button(action: performInstall) {
                ZStack {
                    if isInstalling {
                        ProgressView()
                    } else {
                        Text("Install Plugin")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor)
                .cornerRadius(12)
            }
            .disabled(isInstalling)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: Install — copies file to persistent storage and registers with PluginsController

    private func performInstall() {
        isInstalling = true
        let capturedMetadata = metadata
        let capturedFilePath = filePath
        let capturedEnable = enableAfterInstall

        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let pluginId = capturedMetadata.id ?? UUID().uuidString

            // Copy plugin file to persistent location
            if let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let pluginsDir = supportDir.appendingPathComponent("EGPlugins", isDirectory: true)
                try? fileManager.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
                let destURL = pluginsDir.appendingPathComponent("\(pluginId).plugin")
                try? fileManager.removeItem(at: destURL)
                try? fileManager.copyItem(atPath: capturedFilePath, toPath: destURL.path)
            }

            let plugin = EGPlugin(
                id: pluginId,
                name: capturedMetadata.name ?? "Unknown Plugin",
                subtitle: capturedMetadata.author ?? "",
                pluginDescription: capturedMetadata.description ?? "",
                version: capturedMetadata.version ?? "1.0",
                iconUrl: capturedMetadata.icon,
                isEnabled: capturedEnable,
                requiresPermissions: capturedMetadata.requirements
            )

            DispatchQueue.main.async {
                var plugins = PluginsController.shared.plugins
                if let idx = plugins.firstIndex(where: { $0.id == pluginId }) {
                    plugins[idx] = plugin
                } else {
                    plugins.append(plugin)
                }
                PluginsController.shared.plugins = plugins
                isInstalling = false
                presentationMode.wrappedValue.dismiss()
            }
        }
    }

    // MARK: Load sticker icon by "packName/index" from metadata

    private func loadIcon() {
        guard let iconStr = metadata.icon else { return }
        let parts = iconStr.components(separatedBy: "/")
        guard parts.count == 2, let index = Int(parts[1]) else { return }
        let packName = parts[0]

        let d = (context.engine.stickers.loadedStickerPack(reference: .name(packName), forceActualized: false)
            |> filter { if case .result = $0 { return true }; return false }
            |> take(1)
            |> deliverOnMainQueue
        ).startStandalone(next: { pack in
            if case .result(_, let items, _) = pack, index < items.count {
                iconFile = items[index].file._parse()
            }
        })
        iconLoader = DisposableWrapper(d)
    }
}

// MARK: - Presentation Helper

func presentEGPluginMetadataIfAvailable(
    file: TelegramMediaFile,
    context: AccountContext,
    navigationController: UINavigationController?
) {
    let _ = (context.account.postbox.mediaBox.resourceData(file.resource, option: .complete(waitUntilFetchStatus: true))
    |> take(1)
    |> deliverOnMainQueue).startStandalone(next: { data in
        guard data.complete,
              let text = try? String(contentsOfFile: data.path, encoding: .utf8) else {
            return
        }
        let metadata = EGPluginFileMetadata.parse(from: text)
        guard !metadata.isEmpty else { return }

        guard let rootController = navigationController?.view.window?.rootViewController else { return }

        if #available(iOS 14.0, *) {
            let sheet = UIHostingController(rootView: EGPluginInstallSheet(metadata: metadata, filePath: data.path, context: context))
            sheet.modalPresentationStyle = .overFullScreen
            sheet.view.backgroundColor = .clear

            if #available(iOS 16.0, *) {
                sheet.modalPresentationStyle = .pageSheet
                if let sheetController = sheet.sheetPresentationController {
                    sheetController.detents = [.medium(), .large()]
                    sheetController.prefersGrabberVisible = false  // we draw our own
                    sheetController.preferredCornerRadius = 16
                }
            }
            rootController.present(sheet, animated: true)
        } else {
            // iOS 13 fallback: alert with key metadata
            let lines = [
                metadata.name.map { "Plugin: \($0)" },
                metadata.author.map { "Author: \($0)" },
                metadata.version.map { "Version: \($0)" },
                metadata.description.map { "\($0)" },
                metadata.requirements.isEmpty ? nil : "Requires: \(metadata.requirements.joined(separator: ", "))"
            ].compactMap { $0 }
            let alert = UIAlertController(
                title: metadata.name ?? "Plugin Info",
                message: lines.dropFirst().joined(separator: "\n"),
                preferredStyle: .actionSheet
            )
            alert.addAction(UIAlertAction(title: "Install", style: .default))
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            rootController.present(alert, animated: true)
        }
    })
}
