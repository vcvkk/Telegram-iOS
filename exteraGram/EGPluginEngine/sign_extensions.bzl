"""
sign_extensions: Bazel rule that renames CPython extension modules .so → .dylib
and ad-hoc signs them.

WHY .dylib:
  iOS signing tools (Feather, AltStore, …) sign framework binaries and .dylib
  files but skip arbitrary .so resources — they're treated as plain data.
  Renaming to .dylib makes the tool recognise and re-sign them with the
  developer certificate. Python's EXTENSION_SUFFIXES is patched at runtime
  (see EGIOSBridge.m) to include '.cpython-313-iphoneos.dylib' so the
  renamed files are found by the import machinery.

WHY ad-hoc pre-signing:
  Some tools only replace *existing* signatures; files with no signature at
  all are ignored. Pre-signing ensures the tool detects them as signed Mach-O.
"""

def _sign_ios_extension_impl(ctx):
    signed_files = []
    for src in ctx.files.srcs:
        # Rename .so → .dylib so iOS signing tools recognise the file as a
        # dynamic library and include it in the developer-cert signing pass.
        out_name = src.basename
        if out_name.endswith(".so"):
            out_name = out_name[:-3] + ".dylib"
        out = ctx.actions.declare_file("signed_exts/" + out_name)
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
            progress_message = "Signing extension %s" % out_name,
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
    },
    doc = "Renames CPython .so modules to .dylib and ad-hoc signs them for Feather/AltStore compatibility.",
)
