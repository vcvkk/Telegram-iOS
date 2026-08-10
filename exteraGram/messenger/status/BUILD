load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "status",
    module_name = "status",
    srcs = glob([
        "status/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
