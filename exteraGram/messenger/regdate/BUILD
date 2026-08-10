load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "regdate",
    module_name = "regdate",
    srcs = glob([
        "regdate/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//exteraGram/EGAPI:EGAPI",
        "//exteraGram/EGAPIToken:EGAPIToken",
        "//exteraGram/EGDeviceToken:EGDeviceToken",
        "//exteraGram/EGRegDateScheme:EGRegDateScheme",
        "//exteraGram/EGSimpleSettings:EGSimpleSettings",
        "//exteraGram/EGStrings:EGStrings",
        "//submodules/AccountContext:AccountContext",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
    ],
    visibility = [
        "//visibility:public",
    ],
)
