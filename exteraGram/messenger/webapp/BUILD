load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "webapp",
    module_name = "webapp",
    srcs = glob([
        "webapp/**/*.swift",
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
