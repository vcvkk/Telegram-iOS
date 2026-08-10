load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "config",
    module_name = "config",
    srcs = glob([
        "config/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//exteraGram/EGGHSettingsScheme:EGGHSettingsScheme",
        "//exteraGram/EGLogging:EGLogging",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramCore:TelegramCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "configcore",
    module_name = "configcore",
    srcs = glob([
        "configcore/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//exteraGram/EGLogging:EGLogging",
        "//submodules/BuildConfig:BuildConfig",
    ],
    visibility = [
        "//visibility:public",
    ],
)
