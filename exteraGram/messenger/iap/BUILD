load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "iap",
    module_name = "iap",
    srcs = glob([
        "iap/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//exteraGram/EGConfig:EGConfig",
        "//exteraGram/EGLogging:EGLogging",
        "//submodules/AppBundle:AppBundle",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
