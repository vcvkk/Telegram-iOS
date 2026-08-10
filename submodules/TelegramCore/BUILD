load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

egdeps = [
    "//exteraGram/SwiftSoup:SwiftSoup",
    "//exteraGram/EGSimpleSettings:EGSimpleSettings",
    "//exteraGram/EGTranslationLangFix:EGTranslationLangFix",
    "//exteraGram/EGGTranslate:EGGTranslate",
    "//exteraGram/EGWebSettingsScheme:EGWebSettingsScheme",
    "//exteraGram/EGGHSettingsScheme:EGGHSettingsScheme",
    "//exteraGram/EGConfig:EGConfig",
    "//exteraGram/EGLogging:EGLogging",
]

egsrc = [
    "//exteraGram/EGIQTP:EGIQTP",
]

swift_library(
    name = "TelegramCore",
    module_name = "TelegramCore",
    srcs = egsrc + glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = egdeps + [
        "//submodules/TelegramApi:TelegramApi",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Postbox:Postbox",
        "//submodules/CloudData:CloudData",
        "//submodules/EncryptionProvider:EncryptionProvider",
        "//submodules/CryptoUtils:CryptoUtils",
        "//submodules/NetworkLogging:NetworkLogging",
        "//submodules/Reachability:Reachability",
        "//submodules/ManagedFile:ManagedFile",
        "//submodules/Utils/RangeSet:RangeSet",
        "//submodules/Utils/DarwinDirStat",
        "//submodules/Emoji",
        "//submodules/TelegramCore/FlatBuffers",
        "//submodules/TelegramCore/FlatSerialization",
        "//submodules/MurMurHash32"
    ],
    visibility = [
        "//visibility:public",
    ],
)
