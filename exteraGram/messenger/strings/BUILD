load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "strings",
    module_name = "strings",
    srcs = glob([
        "strings/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//exteraGram/EGLogging:EGLogging",
        "//submodules/AppBundle:AppBundle",
    ],
    visibility = [
        "//visibility:public",
    ],
)

filegroup(
    name = "EGStrings/EGLocalizableStrings",
    srcs = glob(["EGStrings/Strings/*.lproj/EGLocalizable.strings"]),
    visibility = [
        "//visibility:public",
    ],
)
