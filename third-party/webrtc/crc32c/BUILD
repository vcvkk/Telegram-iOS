
arch_specific_crc32c_sources = select({
    "@build_bazel_rules_apple//apple:ios_arm64": [
        "third_party/crc32c/src/crc32c_arm64.cc",
    ],
    "//build-system:ios_sim_arm64": [
        "third_party/crc32c/src/crc32c_arm64.cc",
    ],
    # MARK: exteraGram - Intel host simulator. crc32c.cc calls ExtendSse42
    # whenever the compiler says SSE4.2 is available, so leaving this on the
    # empty default gets all the way to the link and fails there.
    "@build_bazel_rules_apple//apple:ios_x86_64": [
        "third_party/crc32c/src/crc32c_sse42.cc",
    ],
    "//conditions:default": [],
})

crc32c_sources = ["third_party/crc32c/src/" + x for x in [
    "crc32c_portable.cc",
    "crc32c.cc",
    "crc32c_arm64.h",
    "crc32c_internal.h",
    "crc32c_prefetch.h",
    "crc32c_read_le.h",
    "crc32c_round_up.h",
    "crc32c_sse42.h",
    "crc32c_sse42_check.h",
    "crc32c_arm64_check.h",
]] + arch_specific_crc32c_sources

cc_library(
    name = "crc32c",
    hdrs = [
        "third_party/crc32c/src/include/crc32c/crc32c.h",
        "third_party/crc32c/src/include/crc32c/crc32c_config.h",
    ],
    srcs = crc32c_sources,
    copts = [
        "-Ithird-party/webrtc/crc32c/third_party/crc32c/src/include"
    ] + select({
        # MARK: exteraGram - Intel host simulator. The intrinsics in
        # crc32c_sse42.cc are always_inline and refuse to compile without the
        # target feature; every x86_64 Mac that can run the simulator has
        # SSE4.2, and crc32c still gates the call on CanUseSse42() at runtime.
        "@build_bazel_rules_apple//apple:ios_x86_64": ["-msse4.2"],
        "//conditions:default": [],
    }),
    cxxopts = [
        "-std=c++17",
    ],
    deps = [
    ],
    includes = [
        ".",
    ],
    visibility = ["//visibility:public"],
)
