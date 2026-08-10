// MARK: exteraGram — CPython runtime lifecycle manager

import Foundationimport loggingimport EGPluginEngineBridge
/// Manages CPython initialization and plugin directory layout.
/// All interactions with Python must happen through `withPython {}` to ensure GIL safety.
public final class EGPluginRuntime {
    public static let shared = EGPluginRuntime()

    public var isInitialized: Bool { EGPythonBridge.isInitialized }

    private init() {}

    /// Initialize CPython. Safe to call multiple times (no-op after first call).
    public func initialize() {
        guard !EGPythonBridge.isInitialized else { return }

        // Set up writable plugin directories
        EGPluginsDirectory.plugins.create()
        EGPluginsDirectory.sitePackages.create()

        // Migrate any plugins from old AppSupport location
        migrateFromAppSupport()

        // Extract stdlib zip (python3.13.zip) from bundle to Caches on first launch.
        // Returns the home dir where lib/python3.13/ was extracted.
        guard let pythonHome = prepareStdlibAndGetHome() else {
            EGLogger.shared.log("PluginRuntime",
                "Python stdlib extraction failed — engine disabled.")
            return
        }

        // Locate the Python SDK .py files (base_plugin, hook_utils, etc.)
        // findSDKPath searches for base_plugin.py; if Bazel flattens data files to the
        // bundle root, it returns the bundle root itself.  Always also add the
        // Python/SDK subdirectory explicitly — if Bazel preserved the directory
        // structure the ui/ package will be found there.
        let foundSDKPath = findSDKPath()
        let subSDKPath   = Bundle.main.bundlePath.appending("/Python/SDK")
        // Deduplicate: if findSDKPath() already returned Python/SDK, don't add twice.
        var sdkPaths: [String] = []
        if let p = foundSDKPath, !p.isEmpty { sdkPaths.append(p) }
        if !sdkPaths.contains(subSDKPath) { sdkPaths.append(subSDKPath) }
        let sdkPath = sdkPaths.joined(separator: ":")

        // Log stdlib directory contents to help diagnose extraction issues.
        let stdlibContents = (try? FileManager.default.contentsOfDirectory(atPath: pythonHome))?
            .sorted().joined(separator: ", ") ?? "(empty)"
        EGPluginDebugLog.shared.append(tag: "Runtime", "stdlib dir: \(stdlibContents)")

        // Start logger bridge BEFORE init so ObjC error notifications have a listener.
        EGLoggerBridge.shared.start()

        // CPython must be initialized on the main thread.
        // If we're already on main, call directly; otherwise dispatch synchronously.
        let doInit = {
            EGPluginDebugLog.shared.append(tag: "Runtime", "Initializing CPython… home=\(pythonHome) sdk=\(sdkPath)")
            let ok = EGPythonBridge.initialize(
                withHome: pythonHome,
                sdkPath: sdkPath,
                pluginsPath: EGPluginsDirectory.plugins.path,
                sitePackagesPath: EGPluginsDirectory.sitePackages.path
            )
            if ok {
                EGLogger.shared.log("PluginRuntime",
                    "Engine ready. home=\(pythonHome) sdk=\(sdkPath)")
                EGPluginDebugLog.shared.append(tag: "Runtime", "CPython ready ✓")
            } else {
                EGPluginDebugLog.shared.append(tag: "Runtime", "CPython init FAILED ✗")
                EGLogger.shared.log("PluginRuntime", "CPython init failed")
            }
        }
        if Thread.isMainThread {
            doInit()
        } else {
            DispatchQueue.main.sync { doInit() }
        }

        // After Python is live, ensure the `ui` package is importable regardless of
        // how Bazel bundled the SDK files.  Bazel flattens python/SDK/**/*.py to the
        // bundle root, so ui/settings.py lands as settings.py there — losing the ui/
        // directory structure.  We recreate it in site-packages as thin re-exports.
        if EGPythonBridge.isInitialized {
            buildUiPackageInSitePackages(flatSDKPaths: sdkPaths)
        }
    }

    // MARK: - ui/ package bootstrapper

    /// Creates Documents/EGPlugins/site-packages/ui/{__init__, settings, bulletin}.py
    /// each time the app version changes (or on first run).  The generated files simply
    /// re-export from the flat modules that Bazel placed at the bundle root.
    private func buildUiPackageInSitePackages(flatSDKPaths: [String]) {
        let sp   = EGPluginsDirectory.sitePackages.url
        let marker = sp.appendingPathComponent(".sdkVersion").path
        let version = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"

        // Rebuild on app-version change (avoids startup file I/O each launch).
        if (try? String(contentsOfFile: marker, encoding: .utf8)) == version { return }

        let fm = FileManager.default

        // Helper: write a string to a path, creating intermediate dirs.
        func write(_ contents: String, to relPath: String) throws {
            let url = sp.appendingPathComponent(relPath)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try contents.write(toFile: url.path, atomically: true, encoding: .utf8)
        }

        // Wipe stale generated packages so we start clean.
        for dir in ["ui", "android", "java", "elyx", "elyxcore", "extera_utils"] {
            try? fm.removeItem(at: sp.appendingPathComponent(dir))
        }

        do {
            // -- ui/ ----------------------------------------------------------
            try write("""
from .settings import PluginSettings, SettingItem, show_settings_screen
from .bulletin import show_bulletin
from .alert    import AlertDialogBuilder
__all__ = ['PluginSettings','SettingItem','show_settings_screen','show_bulletin','AlertDialogBuilder']
""", to: "ui/__init__.py")
            try write("""
from settings import PluginSettings, SettingItem, show_settings_screen
__all__ = ['PluginSettings','SettingItem','show_settings_screen']
""", to: "ui/settings.py")
            try write("""
from bulletin import show_bulletin
__all__ = ['show_bulletin']
""", to: "ui/bulletin.py")
            try write("""
from eg_widgets import AlertDialogBuilder, BulletinHelper
__all__ = ['AlertDialogBuilder','BulletinHelper']
""", to: "ui/alert.py")

            // -- android/ -----------------------------------------------------
            try write("__all__ = []\n", to: "android/__init__.py")
            try write("""
from eg_widgets import LinearLayout, TextView, Button, Space
__all__ = ['LinearLayout','TextView','Button','Space']
""", to: "android/widget.py")
            try write("""
from eg_widgets import View, MotionEvent, Gravity
__all__ = ['View','MotionEvent','Gravity']
""", to: "android/view.py")
            try write("""
from eg_widgets import TextUtils
__all__ = ['TextUtils']
""", to: "android/text.py")
            try write("""
from eg_widgets import Color, Typeface
__all__ = ['Color','Typeface']
""", to: "android/graphics/__init__.py")
            try write("""
from eg_widgets import GradientDrawable
__all__ = ['GradientDrawable']
""", to: "android/graphics/drawable.py")

            // -- java/ --------------------------------------------------------
            try write("""
from java import jclass, dynamic_proxy
__all__ = ['jclass', 'dynamic_proxy']
""", to: "java/__init__.py")

            // -- elyx / elyxcore ----------------------------------------------
            try write("""
from elyxcore import (
    Asset, AssetNotFoundException, Assets, AssetsDirNotFoundException,
    Callback, Callback2, Callback3, CallbackReturn, LazyDict,
    OnClickListener, Runnable, SettingsController, Strings,
    gen, gen2, get_environment, import_module, mvel_execute
)
__all__ = [
    'Asset', 'AssetNotFoundException', 'Assets', 'AssetsDirNotFoundException',
    'Callback', 'Callback2', 'Callback3', 'CallbackReturn', 'LazyDict',
    'OnClickListener', 'Runnable', 'SettingsController', 'Strings',
    'gen', 'gen2', 'get_environment', 'import_module', 'mvel_execute'
]
""", to: "elyx/__init__.py")

            try version.write(toFile: marker, atomically: true, encoding: .utf8)
            EGPluginDebugLog.shared.append(tag: "Runtime",
                "SDK packages (ui, android, java, elyx, elyxcore) bootstrapped (v\(version))")
        } catch {
            EGLogger.shared.log("PluginRuntime", "package bootstrap error: \(error)")
        }
    }

    /// Execute block with Python GIL held. No-op if Python not initialized.
    public func withPython(_ block: () -> Void) {
        EGPythonBridge.withPython(block)
    }

    /// Returns the bundle path for a sample plugin shipped with the app.
    /// Example: samplePluginPath(id: "bigReactions") → ".../bigReactions.plugin"
    public func samplePluginPath(id: String) -> String? {
        return Bundle.main.path(forResource: id, ofType: "plugin", inDirectory: "Python/Plugins")
            ?? Bundle.main.urls(forResourcesWithExtension: "plugin", subdirectory: nil)?
               .first(where: { $0.deletingPathExtension().lastPathComponent == id })?.path
    }

    // MARK: - Path discovery

    /// Extract python3.13.zip from the app bundle to Library/Caches/EGPythonStdlib/ on first
    /// launch (or when the app is updated). The zip contains lib/python3.13/** so after
    /// extraction PyConfig.home = cacheDir → Python finds stdlib at cacheDir/lib/python3.13/.
    private func prepareStdlibAndGetHome() -> String? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let stdlibHome = caches.appendingPathComponent("EGPythonStdlib")
        let markerPath = stdlibHome.appendingPathComponent(".extracted_version").path

        let currentVersion = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
        let extractedVersion = try? String(contentsOfFile: markerPath, encoding: .utf8)

        if extractedVersion == currentVersion {
            return stdlibHome.path
        }

        guard let zipURL = Bundle.main.url(forResource: "python3.13", withExtension: "zip") else {
            EGLogger.shared.log("PluginRuntime",
                "python3.13.zip not found in bundle — " +
                "ensure @python_apple_support//:PythonStdlibZip is in data deps.")
            return nil
        }

        // Remove stale extraction and re-extract
        try? FileManager.default.removeItem(at: stdlibHome)

        let ok = EGPythonBridge.extractPythonStdlibZip(zipURL.path, toDirectory: stdlibHome.path)
        guard ok else {
            EGLogger.shared.log("PluginRuntime", "Failed to extract python3.13.zip")
            return nil
        }

        // Stamp the version so we skip extraction on subsequent launches
        try? currentVersion.write(toFile: markerPath, atomically: true, encoding: .utf8)
        EGLogger.shared.log("PluginRuntime", "Python stdlib extracted to \(stdlibHome.path)")
        return stdlibHome.path
    }

    /// Find the Python SDK directory (contains base_plugin.py, hook_utils.py, etc.)
    private func findSDKPath() -> String? {
        // Bazel bundles Python/SDK/**/*.py preserving the directory structure.
        for subdir in ["Python/SDK", "Python/SDK/", nil as String?] {
            let url: URL?
            if let subdir {
                url = Bundle.main.url(forResource: "base_plugin", withExtension: "py",
                                      subdirectory: subdir)
            } else {
                url = Bundle.main.url(forResource: "base_plugin", withExtension: "py")
            }
            if let url {
                return url.deletingLastPathComponent().path
            }
        }
        return nil
    }

    // MARK: - One-time migration from Application Support → Documents

    private func migrateFromAppSupport() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }

        let oldDir = appSupport.appendingPathComponent("EGPlugins")
        guard FileManager.default.fileExists(atPath: oldDir.path) else { return }

        let newDir = EGPluginsDirectory.plugins.url
        let fm = FileManager.default

        do {
            let files = try fm.contentsOfDirectory(atPath: oldDir.path)
            for name in files where name.hasSuffix(".plugin") {
                let src = oldDir.appendingPathComponent(name)
                let dst = newDir.appendingPathComponent(name)
                if !fm.fileExists(atPath: dst.path) {
                    try fm.copyItem(at: src, to: dst)
                }
            }
            try? fm.removeItem(at: oldDir)
            EGLogger.shared.log("PluginRuntime", "Migrated plugins AppSupport → Documents")
        } catch {
            EGLogger.shared.log("PluginRuntime", "Migration error: \(error)")
        }
    }
}

// MARK: - Plugin directory layout (Documents/EGPlugins/)

public enum EGPluginsDirectory {
    case plugins
    case sitePackages
    case data(String)

    public var url: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        switch self {
        case .plugins:       return docs.appendingPathComponent("EGPlugins")
        case .sitePackages:  return docs.appendingPathComponent("EGPlugins/site-packages")
        case .data(let id):  return docs.appendingPathComponent("EGPlugins/.data/\(id)")
        }
    }

    public var path: String { url.path }

    public func create() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
