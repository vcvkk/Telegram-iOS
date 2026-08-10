load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_bundle_import")

swift_library(
    name = "preferences",
    module_name = "preferences",
    srcs = glob([
        "preferences/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//exteraGram/EGAPI:EGAPI",
        "//exteraGram/EGAPIToken:EGAPIToken",
        "//exteraGram/EGLogging:EGLogging",
        "//exteraGram/EGPluginEngine:EGPluginEngine",
        "//exteraGram/EGSimpleSettings:EGSimpleSettings",
        "//exteraGram/EGStrings:EGStrings",
        "//exteraGram/EGSwiftUI:EGSwiftUI",
        "//submodules/AccountContext:AccountContext",
        "//submodules/AnimatedStickerNode:AnimatedStickerNode",
        "//submodules/AppBundle:AppBundle",
        "//submodules/Display:Display",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/OverlayStatusController:OverlayStatusController",
        "//submodules/Postbox:Postbox",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/ShimmerEffect:ShimmerEffect",
        "//submodules/StickerResources:StickerResources",
        "//submodules/TelegramAnimatedStickerNode:TelegramAnimatedStickerNode",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TelegramUI/Components/Settings/PeerNameColorScreen",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/UndoUI:UndoUI",
    ],
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGSettingsUI/EGUIAssets",
    srcs = glob(["EGSettingsUI/Images.xcassets/**"]),
    visibility = ["//visibility:public"],
)

apple_bundle_import(
    name = "EGSettingsBundle/EGSettingsBundle",
    bundle_imports = glob([
        "EGSettingsBundle/Settings.bundle/*",
        "EGSettingsBundle/Settings.bundle/**/*",
    ]),
    visibility = ["//visibility:public"]
)
