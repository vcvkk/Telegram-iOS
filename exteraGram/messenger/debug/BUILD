load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "debug",
    module_name = "debug",
    srcs = glob([
        "debug/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//exteraGram/EGBadges:EGBadges",
        "//exteraGram/EGIAP:EGIAP",
        "//exteraGram/EGItemListUI:EGItemListUI",
        "//exteraGram/EGLogging:EGLogging",
        "//exteraGram/EGPayWall:EGPayWall",
        "//exteraGram/EGPluginEngine:EGPluginEngine",
        "//exteraGram/EGSimpleSettings:EGSimpleSettings",
        "//exteraGram/EGStrings:EGStrings",
        "//exteraGram/EGSwiftUI:EGSwiftUI",
        "//submodules/AccountContext:AccountContext",
        "//submodules/AnimatedStickerNode:AnimatedStickerNode",
        "//submodules/Display:Display",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/LegacyUI:LegacyUI",
        "//submodules/OverlayStatusController:OverlayStatusController",
        "//submodules/Postbox:Postbox",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramAnimatedStickerNode:TelegramAnimatedStickerNode",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/UndoUI:UndoUI",
    ],
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGShowMessageJson/EGShowMessageJson",
    srcs = glob([
        "EGShowMessageJson/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGDBReset/EGDBReset",
    srcs = glob([
        "EGDBReset/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)
