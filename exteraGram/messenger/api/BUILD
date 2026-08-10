load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "api",
    module_name = "api",
    srcs = glob([
        "api/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//exteraGram/EGBadges:EGBadges",
        "//exteraGram/EGConfig:EGConfig",
        "//exteraGram/EGLogging:EGLogging",
        "//exteraGram/EGRegDateScheme:EGRegDateScheme",
        "//exteraGram/EGRequests:EGRequests",
        "//exteraGram/EGSimpleSettings:EGSimpleSettings",
        "//exteraGram/EGWebAppExtensions:EGWebAppExtensions",
        "//exteraGram/EGWebSettingsScheme:EGWebSettingsScheme",
        "//submodules/AccountContext:AccountContext",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "apicore",
    module_name = "apicore",
    srcs = glob([
        "apicore/**/*.swift",
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
    name = "EGRecentSessionApiId/EGRecentSessionApiId",
    srcs = glob([
        "EGRecentSessionApiId/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)
