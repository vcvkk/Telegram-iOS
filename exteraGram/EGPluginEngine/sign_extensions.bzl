"""
sign_extensions: Bazel rule that renames CPython extension modules .so → .dylib
and ad-hoc signs them.

WHY .dylib:
  iOS signing tools (Feather, AltStore, …) sign framework binaries and .dylib
  files but skip arbitrary .so resources — they're treated as plain data.
  Renaming to .dylib makes the tool recognise and re-sign them with the
  developer certificate. A custom sys.meta_path finder in EGIOSBridge.m
  resolves both '.cpython-313-iphoneos.dylib' and '.abi3.dylib' suffixes.

WHY ad-hoc pre-signing:
  Some tools only replace *existing* signatures; files with no signature at
  all are ignored. Pre-signing ensures the tool detects them as signed Mach-O.

strip_prefix:
  When bundling packages with subdirectory structure (e.g. PIL/, aiohttp/),
  set strip_prefix to the workspace-relative package path (with trailing /).
  The subdirectory structure is preserved in the output, allowing
  apple_resource_group(structured_resources=...) to bundle files at the
  correct paths inside the framework.
  Without strip_prefix, only the basename is used (flat output — suitable
  for ios_framework(resources=...) which places files at the bundle root).
"""

def _sign_ios_extension_impl(ctx):
    strip_prefix = ctx.attr.strip_prefix
    signed_files = []
    for src in ctx.files.srcs:
        # Compute output relative path:
        # • with strip_prefix: preserve subdirectory structure after the prefix
        # • without:           use basename (backward-compat, flat output)
        rel = src.path
        if strip_prefix and rel.startswith(strip_prefix):
            rel = rel[len(strip_prefix):]
        else:
            rel = src.basename

        # Rename .so → .dylib so iOS signing tools recognise the file as a
        # dynamic library and include it in the developer-cert signing pass.
        if rel.endswith(".so"):
            rel = rel[:-3] + ".dylib"

        out = ctx.actions.declare_file(rel)
        ctx.actions.run_shell(
            inputs = [src],
            outputs = [out],
            command = """
set -e
cp "{src}" "{out}"
# Ad-hoc sign (xcrun first for macOS build hosts, fall back to plain codesign).
xcrun codesign --sign - --force --timestamp=none "{out}" 2>/dev/null || \
codesign  --sign - --force --timestamp=none "{out}" 2>/dev/null || \
echo "WARNING: codesign unavailable; {out} will be unsigned" >&2
""".format(src = src.path, out = out.path),
            mnemonic = "SignExtensionDylib",
            progress_message = "Signing extension %s" % rel,
        )
        signed_files.append(out)
    return [DefaultInfo(files = depset(signed_files))]

sign_ios_extensions = rule(
    implementation = _sign_ios_extension_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "CPython .so extension modules to rename to .dylib and ad-hoc sign",
        ),
        "strip_prefix": attr.string(
            default = "",
            doc = "Workspace-relative path prefix (with trailing /) to strip from src.path. " +
                  "When set, subdirectory structure relative to the prefix is preserved in outputs.",
        ),
    },
    doc = "Renames CPython .so modules to .dylib and ad-hoc signs them for Feather/AltStore compatibility.",
)
