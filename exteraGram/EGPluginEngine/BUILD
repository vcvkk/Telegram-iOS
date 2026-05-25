load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# ---------------------------------------------------------------------------
# ObjC/C bridge — Python C extension (_ios_bridge) + view renderer
#
# Python.xcframework is provided by @python_apple_support (see MODULE.bazel).
# Bazel downloads Python-3.14-iOS-support.b9.tar.gz automatically at build time.
#
# EGIOSBridge.m uses #if __has_include(<Python/Python.h>) so it compiles
# cleanly even if the xcframework is not yet fetched.
# ---------------------------------------------------------------------------

objc_library(
    name = "EGPluginEngineBridge",
    enable_modules = True,
    module_name = "EGPluginEngineBridge",
    srcs = [
        "Sources/ObjC/EGIOSBridge.m",
        "Sources/ObjC/EGViewRenderer.m",
    ],
    hdrs = [
        "Sources/ObjC/EGIOSBridge.h",
        "Sources/ObjC/EGViewRenderer.h",
    ],
    sdk_frameworks = [
        "AVFoundation",
        "Foundation",
        "SystemConfiguration",
        "UIKit",
    ],
    deps = [
        "@python_apple_support//:Python",
        "//third-party/ZipArchive:ZipArchive",
    ],
    visibility = ["//visibility:public"],
)

# ---------------------------------------------------------------------------
# Python SDK files — shipped as app bundle data so the runtime can find them
# ---------------------------------------------------------------------------

filegroup(
    name = "PythonSDK",
    srcs = glob(["Python/SDK/**/*.py"]),
    visibility = ["//visibility:public"],
)

# Sample plugins shipped with the app (available in Settings → Plugins → Browse)
filegroup(
    name = "SamplePlugins",
    srcs = glob(["Python/Plugins/**/*.plugin"]),
    visibility = ["//visibility:public"],
)

# ---------------------------------------------------------------------------
# Main Swift module
# ---------------------------------------------------------------------------

swift_library(
    name = "EGPluginEngine",
    module_name = "EGPluginEngine",
    srcs = glob(["Sources/Swift/**/*.swift"]),
    copts = ["-warnings-as-errors"],
    deps = [
        ":EGPluginEngineBridge",
        "//exteraGram/EGLogging:EGLogging",
        "//exteraGram/EGStrings:EGStrings",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/MtProtoKit:MtProtoKit",
    ],
    data = [":PythonSDK"],
    visibility = ["//visibility:public"],
)
