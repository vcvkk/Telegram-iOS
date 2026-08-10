load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

egsrc = [
    "//exteraGram/EGSwiftSignalKit:EGSwiftSignalKit"
]

swift_library(
    name = "SwiftSignalKit",
    module_name = "SwiftSignalKit",
    srcs = egsrc + glob([
        "Source/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    visibility = [
        "//visibility:public",
    ],
)
