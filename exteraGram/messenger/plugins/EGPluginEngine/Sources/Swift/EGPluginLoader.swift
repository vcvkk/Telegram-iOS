// MARK: exteraGram — Plugin metadata parsing and validation

import Foundation
import EGLogging
import EGPluginEngineBridge

// MARK: - Validation errors

public enum EGPluginValidationError: Error, LocalizedError {
    case missingOS
    case unsupportedOS(String)
    case missingID
    case missingName
    case invalidIDFormat(String)
    case incompatibleVersion(required: String, current: String)
    case fileNotReadable

    public var errorDescription: String? {
        switch self {
        case .missingOS:
            return "Plugin doesn't declare __os__. Add __os__ = \"ios\" to the plugin file."
        case .unsupportedOS(let os):
            return "This plugin is for '\(os)' only and doesn't support iOS."
        case .missingID:
            return "Plugin is missing __id__."
        case .missingName:
            return "Plugin is missing __name__."
        case .invalidIDFormat(let id):
            return "Invalid plugin ID '\(id)'. Use letters, numbers, and underscores only."
        case .incompatibleVersion(let required, let current):
            return "Plugin requires app v\(required), you have v\(current)."
        case .fileNotReadable:
            return "Plugin file could not be read."
        }
    }
}

// MARK: - Full metadata model (superset of EGPluginFileMetadata)

public struct EGFullPluginMetadata {
    public let id: String
    public let name: String
    public let os: [String]
    public let version: String
    public let author: String
    public let description: String
    public let iconUrl: String?
    public let minVersion: String?
    public let requirements: [String]
    public let permissions: [String]
}

// MARK: - Loader

public final class EGPluginLoader {
    public static let shared = EGPluginLoader()
    private init() {}

    /// Parse and validate plugin metadata. Throws EGPluginValidationError on any issue.
    ///
    /// Prefers AST-based parsing via Python (robust against multiline strings, nested
    /// quotes, and list values) when the runtime is live. Falls back to the line-based
    /// parser when Python isn't initialized (e.g. the install flow may run before the
    /// interpreter starts) or when the AST result can't be decoded.
    public func parseAndValidate(path: String) throws -> EGFullPluginMetadata {
        if EGPythonBridge.isInitialized,
           let json = EGPythonBridge.parsePluginMetadata(path),
           let data = json.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return try buildMetadata(from: obj)
        }
        return try parseAndValidateLineBased(path: path)
    }

    /// Build & validate metadata from already-typed AST values (strings, lists, …).
    private func buildMetadata(from raw: [String: Any]) throws -> EGFullPluginMetadata {
        // Required fields
        guard let id = Self.string(raw["__id__"]) else { throw EGPluginValidationError.missingID }
        guard let name = Self.string(raw["__name__"]) else { throw EGPluginValidationError.missingName }

        // ID format: alphanumeric + underscore only
        let idPattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_]+$")
        let idRange = NSRange(id.startIndex..., in: id)
        guard idPattern.firstMatch(in: id, range: idRange) != nil else {
            throw EGPluginValidationError.invalidIDFormat(id)
        }

        // __os__ — may be a string or list of strings
        guard raw["__os__"] != nil else { throw EGPluginValidationError.missingOS }
        let osList = Self.stringList(raw["__os__"])
        guard osList.contains("ios") else {
            throw EGPluginValidationError.unsupportedOS(osList.joined(separator: ", "))
        }

        // App version check
        let minVer = Self.string(raw["__min_version__"])
        if let minVer {
            let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if compareVersions(appVer, minVer) == .orderedAscending {
                throw EGPluginValidationError.incompatibleVersion(required: minVer, current: appVer)
            }
        }

        // Optional icon — validate format "packName/index"
        var iconUrl: String? = nil
        if let rawIcon = Self.string(raw["__icon__"]),
           let slashIdx = rawIcon.lastIndex(of: "/"),
           Int(rawIcon[rawIcon.index(after: slashIdx)...]) != nil {
            iconUrl = rawIcon
        }

        return EGFullPluginMetadata(
            id: id,
            name: name,
            os: osList,
            version: Self.string(raw["__version__"]) ?? "0.0",
            author: Self.string(raw["__author__"]) ?? "",
            description: Self.string(raw["__description__"]) ?? "",
            iconUrl: iconUrl,
            minVersion: minVer,
            requirements: Self.stringList(raw["__requirements__"]),
            permissions: Self.stringList(raw["__permissions__"])
        )
    }

    /// Legacy line-based parser. Used as a fallback when AST parsing is unavailable.
    private func parseAndValidateLineBased(path: String) throws -> EGFullPluginMetadata {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw EGPluginValidationError.fileNotReadable
        }

        var raw: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            if let (key, value) = Self.parseLine(line) {
                raw[key] = value
            }
        }

        // Required fields
        guard let id = raw["__id__"] else { throw EGPluginValidationError.missingID }
        guard let name = raw["__name__"] else { throw EGPluginValidationError.missingName }

        // ID format: alphanumeric + underscore only
        let idPattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_]+$")
        let idRange = NSRange(id.startIndex..., in: id)
        guard idPattern.firstMatch(in: id, range: idRange) != nil else {
            throw EGPluginValidationError.invalidIDFormat(id)
        }

        // __os__ validation
        let osList = try parseOS(raw["__os__"])

        // App version check
        if let minVer = raw["__min_version__"] {
            let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if compareVersions(appVer, minVer) == .orderedAscending {
                throw EGPluginValidationError.incompatibleVersion(required: minVer, current: appVer)
            }
        }

        // Optional icon — validate format "packName/index"
        var iconUrl: String? = nil
        if let rawIcon = raw["__icon__"] {
            if let slashIdx = rawIcon.lastIndex(of: "/"),
               Int(rawIcon[rawIcon.index(after: slashIdx)...]) != nil {
                iconUrl = rawIcon
            }
        }

        return EGFullPluginMetadata(
            id: id,
            name: name,
            os: osList,
            version: raw["__version__"] ?? "0.0",
            author: raw["__author__"] ?? "",
            description: raw["__description__"] ?? "",
            iconUrl: iconUrl,
            minVersion: raw["__min_version__"],
            requirements: parseList(raw["__requirements__"]),
            permissions: parseList(raw["__permissions__"])
        )
    }

    // MARK: - Private

    /// Coerce an AST/JSON value to a trimmed non-empty String, or nil.
    private static func string(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    /// Coerce an AST/JSON value to a list of strings (accepts a single string or an array).
    private static func stringList(_ any: Any?) -> [String] {
        if let arr = any as? [Any] {
            return arr.compactMap { string($0) }
        }
        if let s = string(any) { return [s] }
        return []
    }

    private func parseOS(_ raw: String?) throws -> [String] {
        guard let raw = raw else { throw EGPluginValidationError.missingOS }
        let osList: [String]
        if raw.hasPrefix("[") {
            osList = raw
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
                .filter { !$0.isEmpty }
        } else {
            let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            osList = clean.isEmpty ? [] : [clean]
        }
        guard osList.contains("ios") else {
            throw EGPluginValidationError.unsupportedOS(osList.joined(separator: ", "))
        }
        return osList
    }

    private func parseList(_ raw: String?) -> [String] {
        guard let raw = raw, raw.hasPrefix("[") else {
            return raw.map { [$0] } ?? []
        }
        return raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
            .filter { !$0.isEmpty }
    }

    private func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        return a.compare(b, options: .numeric)
    }

    // Parse key = "value" or key = 'value' lines from plugin header
    private static func parseLine(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let eqIdx = trimmed.firstIndex(of: "=") else { return nil }
        let rawKey = String(trimmed[trimmed.startIndex..<eqIdx])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: " "))
        guard !rawKey.isEmpty else { return nil }
        let valuePart = String(trimmed[trimmed.index(after: eqIdx)...])
            .trimmingCharacters(in: .whitespaces)
        for quote: Character in ["\"", "'"] {
            let q = String(quote)
            guard valuePart.hasPrefix(q) else { continue }
            let afterOpen = String(valuePart.dropFirst())
            guard let closeRange = afterOpen.range(of: q) else { continue }
            return (rawKey, String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound]))
        }
        // List values: key = [...]
        if valuePart.hasPrefix("[") {
            return (rawKey, valuePart)
        }
        return nil
    }
}
