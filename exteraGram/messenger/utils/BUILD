load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "utils",
    module_name = "utils",
    srcs = glob([
        "utils/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGSwiftSignalKit/EGSwiftSignalKit",
    srcs = glob([
        "EGSwiftSignalKit/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGTabBarHeightModifier/EGTabBarHeightModifier",
    srcs = glob([
        "EGTabBarHeightModifier/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGEmojiKeyboardDefaultFirst/EGEmojiKeyboardDefaultFirst",
    srcs = glob([
        "EGEmojiKeyboardDefaultFirst/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGIQTP/EGIQTP",
    srcs = glob([
        "EGIQTP/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGExternalVideoPlayer/EGExternalVideoPlayer",
    srcs = glob([
        "EGExternalVideoPlayer/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGDoubleTapMessageAction/EGDoubleTapMessageAction",
    srcs = glob([
        "EGDoubleTapMessageAction/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGChatListSimpleSettingsSignal/EGChatListSimpleSettingsSignal",
    srcs = glob([
        "EGChatListSimpleSettingsSignal/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGSharedAccountContextMigration/EGSharedAccountContextMigration",
    srcs = glob([
        "EGSharedAccountContextMigration/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "ChatControllerImplExtension/ChatControllerImplExtension",
    srcs = glob([
        "ChatControllerImplExtension/Sources/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)
