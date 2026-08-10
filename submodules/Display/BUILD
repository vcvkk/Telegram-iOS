load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

egsrc = [
    "//exteraGram/EGAppBadgeOffset:EGAppBadgeOffset"
]

egdeps = [
    "//submodules/Utils/DeviceModel",
    "//exteraGram/EGSimpleSettings:EGSimpleSettings",
]

swift_library(
    name = "Display",
    module_name = "Display",
    srcs = egsrc + glob([
        "Source/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = egdeps + [
    	"//submodules/ObjCRuntimeUtils:ObjCRuntimeUtils",
    	"//submodules/UIKitRuntimeUtils:UIKitRuntimeUtils",
        "//submodules/AppBundle:AppBundle",
    	"//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Markdown:Markdown",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
