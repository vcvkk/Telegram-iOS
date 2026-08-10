// MARK: exteraGram — Plugin settings screen

import Foundation
import UIKit
import SwiftUI
import LegacyUI
import EGSwiftUI
import EGStrings
import Display
import TelegramPresentationData
import AccountContext

// MARK: - View model

struct PluginSettingRow: Identifiable {
    let id: String
    var title: String
    var subtitle: String
    var type: String        // "toggle" | "text" | "select" | "slider"
    var currentValue: Any?
    var options: [String]
}

// MARK: - SwiftUI view

@available(iOS 14.0, *)
private struct PluginSettingsView: View {
    let pluginId: String
    let pluginName: String
    @Environment(\.lang) var lang: String
    @State private var rows: [PluginSettingRow] = []

    var body: some View {
        List {
            ForEach(rows.indices, id: \.self) { idx in
                rowView(at: idx)
            }
        }
        .listStyle(InsetGroupedListStyle())
        .onAppear { loadRows() }
    }

    @ViewBuilder
    private func rowView(at idx: Int) -> some View {
        let row = rows[idx]
        if row.type == "toggle" {
            HStack {
                labelStack(row)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { rows[idx].currentValue as? Bool ?? false },
                    set: { v in persist(idx, value: v) }
                ))
                .labelsHidden()
            }
        } else if row.type == "text" {
            HStack {
                labelStack(row)
                Spacer()
                TextField("", text: Binding(
                    get: { stringValue(rows[idx]) },
                    set: { v in persist(idx, value: v) }
                ))
                .multilineTextAlignment(.trailing)
                .foregroundColor(.secondary)
            }
        } else if row.type == "select" {
            Picker(row.title, selection: Binding(
                get: { stringValue(rows[idx]) },
                set: { v in persist(idx, value: v) }
            )) {
                ForEach(row.options, id: \.self) { opt in
                    Text(opt).tag(opt)
                }
            }
        } else if row.type == "button" {
            Button(action: {
                PluginsController.shared.invokeAction(pluginId, key: row.id)
            }) {
                HStack {
                    labelStack(row)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            labelStack(row)
        }
    }

    @ViewBuilder
    private func labelStack(_ row: PluginSettingRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
            if !row.subtitle.isEmpty {
                Text(row.subtitle).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func stringValue(_ row: PluginSettingRow) -> String {
        if let s = row.currentValue as? String { return s }
        if let n = row.currentValue as? NSNumber { return n.stringValue }
        return ""
    }

    private func persist(_ idx: Int, value: Any) {
        rows[idx].currentValue = value
        PluginsController.shared.setSetting(pluginId, key: rows[idx].id, value: value)
    }

    private func loadRows() {
        let items = PluginsController.shared.getSettingsSchema(pluginId)
        rows = items.compactMap { item in
            guard let key = item["key"] as? String,
                  let title = item["title"] as? String else { return nil }
            let subtitle = item["subtitle"] as? String ?? ""
            let type = item["type"] as? String ?? "toggle"
            let def = item["default"]
            let stored = PluginsController.shared.getSetting(pluginId, key: key, default: def)
            let opts: [String] = (item["options"] as? [Any])?.compactMap { "\($0)" } ?? []
            return PluginSettingRow(
                id: key, title: title, subtitle: subtitle,
                type: type, currentValue: stored, options: opts
            )
        }
    }
}

// MARK: - Factory

public func makePluginSettingsController(
    pluginId: String,
    pluginName: String,
    context: AccountContext
) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let legacyController = LegacySwiftUIController(
        presentation: .navigation,
        theme: presentationData.theme,
        strings: presentationData.strings
    )
    legacyController.title = pluginName
    legacyController.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style

    if #available(iOS 14.0, *) {
        let swiftUIView = EGSwiftUIView<PluginSettingsView>(
            legacyController: legacyController,
            manageSafeArea: true
        ) {
            PluginSettingsView(pluginId: pluginId, pluginName: pluginName)
        }
        let hostingController = UIHostingController(rootView: swiftUIView, ignoreSafeArea: true)
        legacyController.bind(controller: hostingController)
    }
    return legacyController
}
