load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "EGGTranslate",
    module_name = "EGGTranslate",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//exteraGram/SwiftSoup:SwiftSoup",
    ],
    visibility = [
        "//visibility:public",
    ],
)
