load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_group")
load("//exteraGram/EGPluginEngine:sign_extensions.bzl", "sign_ios_extensions")

apple_resource_group(
    name = "BeewarePackagesResources",
    structured_resources = glob(
        ["**/*"],
        exclude = [
            "BUILD",
            "**/*.pyc",
            "**/__pycache__/**",
        ],
    ),
    visibility = ["//visibility:public"],
)

# Rename and ad-hoc sign all .so extension modules so that iOS signing tools
# (Feather, AltStore) detect them as Mach-O .dylib files and re-sign them with
# the developer certificate. Without this AMFI blocks dlopen at runtime.
# strip_prefix preserves the subdirectory structure (PIL/, aiohttp/, numpy/, …)
# so structured_resources places each file at its correct package-relative path.
sign_ios_extensions(
    name = "BeewarePackagesSosSigned",
    strip_prefix = "exteraGram/EGPluginEngine/Python/BeewarePackages/",
    srcs = glob(["**/*.so"]),
)

apple_resource_group(
    name = "BeewarePackagesSignedExts",
    structured_resources = [":BeewarePackagesSosSigned"],
    visibility = ["//visibility:public"],
)
