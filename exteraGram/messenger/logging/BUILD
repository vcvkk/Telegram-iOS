load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "logging",
    module_name = "logging",
    srcs = glob([
        "logging/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/ManagedFile:ManagedFile",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
