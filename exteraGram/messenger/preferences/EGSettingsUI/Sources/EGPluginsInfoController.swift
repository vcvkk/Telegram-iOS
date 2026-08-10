// MARK: exteraGram

import Foundation
import SwiftUI
import LegacyUI
import EGSwiftUI
import EGStrings
import AccountContext
import Display
import TelegramPresentationData

// MARK: - Safe Mode Confirmation Sheet

@available(iOS 14.0, *)
private struct SafeModeSheet: View {
    let lang: String
    let onDisable: () -> Void
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "shield.slash.fill")
                .font(.system(size: 56))
                .foregroundColor(.orange)

            Text(i18n("Plugins.SafeMode.Title", lang))
                .font(.title2.bold())

            Text(i18n("Plugins.SafeMode.Description", lang))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                Button(action: {
                    PluginsController.shared.isSafeModeEnabled = false
                    onDisable()
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Text(i18n("Plugins.SafeMode.Disable", lang))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)

                Button(i18n("Plugins.Cancel", lang)) {
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(.secondary)
            }
            .padding(.bottom, 32)
        }
        .padding()
    }
}

// MARK: - Plugin Engine Info View

@available(iOS 14.0, *)
private struct EGPluginsInfoView: View {
    @Environment(\.lang) var lang: String
    weak var wrapperController: LegacyController?

    @State private var isDevMode: Bool = PluginsController.shared.isDevMode
    @State private var isCompactView: Bool = PluginsController.shared.isCompactView
    @State private var isSafeMode: Bool = PluginsController.shared.isSafeModeEnabled
    @State private var showingSafeModeSheet: Bool = false

    var body: some View {
        List {
            Section(header: sectionHeader(i18n("Plugins.Engine.Header", lang))) {
                Toggle(i18n("Plugins.DevMode", lang), isOn: Binding(
                    get: { isDevMode },
                    set: { v in isDevMode = v; PluginsController.shared.isDevMode = v }
                ))
                Toggle(i18n("Plugins.CompactView", lang), isOn: Binding(
                    get: { isCompactView },
                    set: { v in isCompactView = v; PluginsController.shared.isCompactView = v }
                ))
            }

            Section(header: sectionHeader(i18n("Plugins.SafeMode.Header", lang))) {
                Toggle(i18n("Plugins.SafeMode.Toggle", lang), isOn: Binding(
                    get: { isSafeMode },
                    set: { v in
                        if v {
                            isSafeMode = true
                            PluginsController.shared.isSafeModeEnabled = true
                        } else {
                            showingSafeModeSheet = true
                        }
                    }
                ))
                if isSafeMode {
                    Text(i18n("Plugins.SafeMode.Notice", lang))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(action: { showingSafeModeSheet = true }) {
                        Text(i18n("Plugins.SafeMode.Disable", lang))
                            .foregroundColor(.orange)
                    }
                }
            }

            Section(header: sectionHeader(i18n("Plugins.Links.Header", lang))) {
                linkRow(
                    text: i18n("Plugins.Links.SDK", lang),
                    label: "exteraGram SDK",
                    url: "https://exteraGram.app/sdk"
                )
                linkRow(
                    text: i18n("Plugins.Links.GitHub", lang),
                    label: "GitHub",
                    url: "https://github.com/exteraGram"
                )
            }
        }
        .listStyle(InsetGroupedListStyle())
        .sheet(isPresented: $showingSafeModeSheet) {
            SafeModeSheet(lang: lang) {
                isSafeMode = false
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(Color(UIColor.secondaryLabel))
    }

    @ViewBuilder
    private func linkRow(text: String, label: String, url: String) -> some View {
        Button(action: { openURL(url) }) {
            HStack {
                Text(text)
                    .foregroundColor(.primary)
                Spacer()
                Text(label)
                    .foregroundColor(.accentColor)
            }
            .contentShape(Rectangle())
        }
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Public Entry Point

public func egPluginsInfoController(context: AccountContext) -> ViewController {
    guard #available(iOS 14.0, *) else {
        return egSettingsController(context: context)
    }

    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let theme   = presentationData.theme
    let strings = presentationData.strings

    let legacyController = LegacySwiftUIController(
        presentation: .navigation,
        theme: theme,
        strings: strings
    )
    legacyController.title = i18n("Plugins.Info.Title", strings.baseLanguageCode)
    legacyController.statusBar.statusBarStyle = theme.rootController.statusBarStyle.style

    let swiftUIView = EGSwiftUIView<EGPluginsInfoView>(legacyController: legacyController, manageSafeArea: true) {
        EGPluginsInfoView(wrapperController: legacyController)
    }
    let hostingController = UIHostingController(rootView: swiftUIView, ignoreSafeArea: true)
    legacyController.bind(controller: hostingController)

    return legacyController
}
