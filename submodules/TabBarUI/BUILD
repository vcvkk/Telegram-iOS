load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

egdeps = [
    "//exteraGram/EGSimpleSettings:EGSimpleSettings",
]

egsrc = [
    "//exteraGram/EGTabBarHeightModifier:EGTabBarHeightModifier"
]

swift_library(
    name = "TabBarUI",
    module_name = "TabBarUI",
    srcs = egsrc + glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = egdeps + [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
    	"//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/AnimatedStickerNode",
        "//submodules/TelegramAnimatedStickerNode",
        "//submodules/TelegramPresentationData",
        "//submodules/ComponentFlow",
        "//submodules/Components/ComponentDisplayAdapters",
        "//submodules/TelegramUI/Components/TabBarComponent",
        "//submodules/TelegramUI/Components/GlassControls",
    ],
    visibility = [
        "//visibility:public",
    ],
)
