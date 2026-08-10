load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "pro",
    module_name = "pro",
    srcs = glob([
        "pro/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//exteraGram/EGAPI:EGAPI",
        "//exteraGram/EGAPIToken:EGAPIToken",
        "//exteraGram/EGItemListUI:EGItemListUI",
        "//exteraGram/EGKeychainBackupManager:EGKeychainBackupManager",
        "//exteraGram/EGLogging:EGLogging",
        "//exteraGram/EGSimpleSettings:EGSimpleSettings",
        "//exteraGram/EGStrings:EGStrings",
        "//exteraGram/EGSwiftUI:EGSwiftUI",
        "//submodules/AccountContext:AccountContext",
        "//submodules/AppBundle:AppBundle",
        "//submodules/Display:Display",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/OverlayStatusController:OverlayStatusController",
        "//submodules/Postbox:Postbox",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/SettingsUI:SettingsUI",
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
