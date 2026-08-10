// MARK: exteraGram — bridges Python i18n → EGLocalizationManager

import Foundation
import EGStrings

/// Called from EGIOSBridge.m for Python get_locale_language() calls.
/// ObjC calls this via a notification or direct @objc method.
@objc public final class EGStringsBridgeImpl: NSObject {
    @objc public static func currentLanguage() -> String {
        return Locale.current.languageCode ?? "en"
    }

    @objc public static func localizedString(_ key: String) -> String {
        return EGLocalizationManager.shared.localizedString(key)
    }
}

// MARK: - C bridges for ObjC (no module import needed)

/// Returns the current UI language code (e.g. "en", "ru").
/// Caller is responsible for using the returned string before any Python GC pass.
@_cdecl("EGStringsBridge_currentLanguageCStr")
public func EGStringsBridge_currentLanguageCStr() -> UnsafePointer<CChar>? {
    let lang = Locale.current.languageCode ?? "en"
    return UnsafePointer(strdup(lang))
}

/// Returns a localized string for the given key, or the key itself if not found.
/// Result is heap-allocated; caller must `free()` it.
@_cdecl("EGStringsBridge_localizedStringCStr")
public func EGStringsBridge_localizedStringCStr(_ key: UnsafePointer<CChar>?) -> UnsafePointer<CChar>? {
    guard let key else { return UnsafePointer(strdup("")) }
    let keyStr = String(cString: key)
    let value = EGLocalizationManager.shared.localizedString(keyStr)
    return UnsafePointer(strdup(value))
}
