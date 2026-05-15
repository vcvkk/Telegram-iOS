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
            case "icon":
                // Mirror Android Plugin.setIcon() / isIconValid(): only accept "packName/N" format.
                // Bare icon names like "msg_reactions" from plugin code bodies are silently ignored.
                if let slash = value.lastIndex(of: "/"),
                   Int(value[value.index(after: slash)...]) != nil {
                    meta.icon = value
                }
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

    // Parses Python metadata assignment lines in all formats:
    //   __key__ = "value"  /  __key__ = 'value'
    //   __key = "value"    /  __key = 'value'
    //   key = "value"      /  key = 'value'
    private static func parseLine(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let eqIdx = trimmed.firstIndex(of: "=") else { return nil }
        let rawKey = String(trimmed[trimmed.startIndex..<eqIdx])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let valuePart = String(trimmed[trimmed.index(after: eqIdx)...])
            .trimmingCharacters(in: .whitespaces)
        guard !rawKey.isEmpty, !valuePart.isEmpty else { return nil }
        for quote: Character in ["\"", "'"] {
            let q = String(quote)
            guard valuePart.hasPrefix(q) else { continue }
            let afterOpen = String(valuePart.dropFirst())
            guard let closeRange = afterOpen.range(of: q) else { continue }
            return (rawKey, String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound]))
        }
        return nil
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

// MARK: - Plugin Icon Loader (matches Android setPlaceholderImageByIndex pattern)
// Fetches sticker pack by name, picks item at index, renders it — all inside the Coordinator
// so no @State mutation is needed. Identical pattern to EGPluginIconView in EGPluginsController.

@available(iOS 14.0, *)
private struct EGPluginIconLoader: UIViewRepresentable {
    let iconStr: String   // "packName/index"
    let context: AccountContext
    let size: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(iconStr: iconStr, context: context, size: size) }

    func makeUIView(context uiCtx: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        uiCtx.coordinator.load(into: v)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator {
        private let iconStr: String
        private let context: AccountContext
        private let size: CGFloat
        private var node: DefaultAnimatedStickerNodeImpl?
        private var packDisposable: Disposable?
        private var fetchDisposable: Disposable?

        init(iconStr: String, context: AccountContext, size: CGFloat) {
            self.iconStr = iconStr; self.context = context; self.size = size
        }

        deinit { packDisposable?.dispose(); fetchDisposable?.dispose() }

        func load(into container: UIView) {
            guard let slashIdx = iconStr.lastIndex(of: "/"),
                  let index = Int(iconStr[iconStr.index(after: slashIdx)...]) else { return }
            let packName = String(iconStr[iconStr.startIndex..<slashIdx])
            let iconSize = CGSize(width: size, height: size)
            let pixelSide = Int(size * UIScreen.main.scale)

            packDisposable = (context.engine.stickers.loadedStickerPack(
                    reference: .name(packName), forceActualized: false)
                |> deliverOnMainQueue
            ).startStandalone(next: { [weak container, weak self] result in
                guard let self, let container else { return }
                guard self.node == nil else { return }
                guard case .result(_, let items, _) = result, index < items.count else { return }

                let file = items[index].file._parse()
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
                // overrideVisibility bypasses didEnterHierarchy tracking; required when the
                // node is embedded in a plain UIView rather than an ASDisplayNode tree.
                node.overrideVisibility = true
                node.visibility = true
                node.frame = CGRect(origin: .zero, size: iconSize)
                node.view.frame = CGRect(origin: .zero, size: iconSize)
                container.addSubview(node.view)
                self.node = node

                self.fetchDisposable = freeMediaFileResourceInteractiveFetched(
                    account: self.context.account,
                    userLocation: .other,
                    fileReference: stickerPackFileReference(file),
                    resource: file.resource
                ).startStandalone()
            })
        }
    }
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

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color(UIColor.tertiaryLabel))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 12)

            // Header bar: [X]  version · author  [share]
            headerBar

            ScrollView {
                VStack(spacing: 12) {
                    // Main info card with gray fill
                    infoCard
                        .padding(.horizontal, 16)

                    // Requirements chips
                    if !metadata.requirements.isEmpty {
                        RequirementChipsView(requirements: metadata.requirements)
                            .padding(.top, 4)
                    }

                    // Enable after installation toggle
                    Toggle("Enable after installation", isOn: $enableAfterInstall)
                        .font(.system(size: 15))
                        .padding(.horizontal, 21)
                        .padding(.top, 4)

                    // Install button — .borderedProminent picks up Liquid Glass on iOS 26+
                    installButton
                        .padding(.bottom, 8)

                    Color.clear.frame(height: 16)
                }
                .padding(.top, 4)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ActivitySheet(items: [URL(fileURLWithPath: filePath)])
        }
    }

    // MARK: Header bar — dismiss | version · author | share

    @ViewBuilder
    private var headerBar: some View {
        HStack(alignment: .center) {
            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(UIColor.secondaryLabel))
                    .frame(width: 30, height: 30)
                    .background(Color(UIColor.tertiarySystemFill))
                    .clipShape(Circle())
            }

            Spacer()

            // Version · Author as navigation subtitle
            HStack(spacing: 0) {
                if let version = metadata.version {
                    Text(version)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(UIColor.secondaryLabel))
                }
                if metadata.version != nil && metadata.author != nil {
                    Text(" · ")
                        .font(.system(size: 13))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
                if let author = metadata.author {
                    Text(author)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(UIColor.secondaryLabel))
                }
            }

            Spacer()

            Button(action: { showShareSheet = true }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(UIColor.secondaryLabel))
                    .frame(width: 30, height: 30)
                    .background(Color(UIColor.tertiarySystemFill))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: Info card — gray fill, name+desc left, icon right, unknown source row

    @ViewBuilder
    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(metadata.name ?? "Plugin")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color(UIColor.label))

                    if let desc = metadata.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 14))
                            .foregroundColor(Color(UIColor.secondaryLabel))
                            .lineLimit(5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                iconView
            }
            .padding(16)

            // Separator
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 0.5)
                .padding(.leading, 16)

            // Trust badge row — always "Unknown source" until we have signed plugin support
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(UIColor.systemOrange))
                Text("Unknown source")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(UIColor.systemOrange))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Icon view — sticker with badge overlay, or puzzle piece placeholder

    @ViewBuilder
    private var iconView: some View {
        if let iconStr = metadata.icon, !iconStr.isEmpty {
            EGPluginIconLoader(iconStr: iconStr, context: context, size: 90)
                .frame(width: 90, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    ZStack {
                        Circle()
                            .fill(Color(UIColor.secondarySystemGroupedBackground))
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
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 90, height: 90)
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 36))
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

            if #available(iOS 16.0, *) {
                sheet.modalPresentationStyle = .pageSheet
                if let sc = sheet.sheetPresentationController {
                    let screenH = UIScreen.main.bounds.height
                    let deviceRadius = (UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 44
                    sc.detents = [
                        .custom { _ in min(screenH * 0.58, 540) },
                        .large()
                    ]
                    sc.prefersGrabberVisible = false
                    sc.preferredCornerRadius = deviceRadius
                    sc.prefersScrollingExpandsWhenScrolledToEdge = true
                }
            } else {
                sheet.modalPresentationStyle = .overFullScreen
                sheet.view.backgroundColor = .clear
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
