load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

egdeps = [
    "//exteraGram/EGLogging:EGLogging"
]

swift_library(
    name = "LocalAudioTranscription",
    module_name = "LocalAudioTranscription",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = egdeps +[
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
