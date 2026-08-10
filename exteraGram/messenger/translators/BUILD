load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "translators",
    module_name = "translators",
    srcs = glob([
        "translators/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//exteraGram/SwiftSoup:SwiftSoup",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
