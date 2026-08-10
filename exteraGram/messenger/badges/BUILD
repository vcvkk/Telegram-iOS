load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "badges",
    module_name = "badges",
    srcs = glob([
        "badges/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [

    ],
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGAppBadgeAssets/EGAppBadgeAssets",
    srcs = glob(["EGAppBadgeAssets/Images.xcassets/**"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "EGAppBadgeOffset/EGAppBadgeOffset",
    srcs = glob([
        "EGAppBadgeOffset/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)
