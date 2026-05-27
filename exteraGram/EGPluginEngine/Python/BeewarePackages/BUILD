load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_group")

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
