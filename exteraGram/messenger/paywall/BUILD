load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "paywall",
    module_name = "paywall",
    srcs = glob([
        "paywall/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//exteraGram/EGIAP:EGIAP",
        "//exteraGram/EGLogging:EGLogging",
        "//exteraGram/EGSimpleSettings:EGSimpleSettings",
        "//exteraGram/EGStrings:EGStrings",
        "//exteraGram/EGSwiftUI:EGSwiftUI",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGPayWall/EGPayWallAssets",
    srcs = glob(["EGPayWall/Images.xcassets/**"]),
    visibility = ["//visibility:public"],
)
