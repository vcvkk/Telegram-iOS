load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:objc_library.bzl", "objc_library")

swift_library(
    name = "plugins",
    module_name = "plugins",
    srcs = glob([
        "plugins/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//third-party/ZipArchive:ZipArchive",
        "@python_apple_support//:Python",
    ],
    visibility = [
        "//visibility:public",
    ],
)

objc_library(
    name = "EGPluginEngine/EGPluginEngineBridge",
    enable_modules = True,
    module_name = "EGPluginEngine/EGPluginEngineBridge",
    srcs = [
        "EGPluginEngine/Sources/ObjC/EGIOSBridge.m",
        "EGPluginEngine/Sources/ObjC/EGViewRenderer.m",
    ],
    hdrs = [
        "EGPluginEngine/Sources/ObjC/EGIOSBridge.h",
        "EGPluginEngine/Sources/ObjC/EGViewRenderer.h",
    ],
    sdk_frameworks = [
        "EGPluginEngine/AVFoundation",
        "EGPluginEngine/Foundation",
        "EGPluginEngine/ImageIO",
        "EGPluginEngine/SystemConfiguration",
        "EGPluginEngine/UIKit",
    ],
    deps = [
        "@python_apple_support//:Python",
        "//third-party/ZipArchive:ZipArchive",
    ],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "EGPluginEngine/PythonSDK",
    srcs = glob(["EGPluginEngine/Python/SDK/**/*.py"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "EGPluginEngine/SamplePlugins",
    srcs = glob(["EGPluginEngine/Python/Plugins/**/*.plugin"]),
    visibility = ["//visibility:public"],
)

objc_library(
    name = "EGPluginEngine/EGPythonExtensionsStub",
    srcs = ["EGPluginEngine/Sources/ObjC/EGPythonExtensionsStub.m"],
    visibility = ["//visibility:public"],
)

objc_library(
    name = "EGPluginEngine/EGBeewarePackagesStub",
    srcs = ["EGPluginEngine/Sources/ObjC/EGBeewarePackagesStub.m"],
    visibility = ["//visibility:public"],
)
