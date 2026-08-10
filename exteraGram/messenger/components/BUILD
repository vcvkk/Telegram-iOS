load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "components",
    module_name = "components",
    srcs = glob([
        "components/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display:Display",
        "//submodules/LegacyUI:LegacyUI",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
    ],
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGNY/EGNY",
    srcs = glob([
        "EGNY/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGNY/EGNYAssets",
    srcs = glob(["EGNY/Images.xcassets/**"]),
    visibility = ["//visibility:public"],
)
