"""
sign_extensions: Bazel rule that ad-hoc signs Mach-O extension modules (.so).

iOS signing tools (Feather, AltStore, etc.) replace existing code signatures but
skip files that carry NO signature at all (treating them as plain data resources).
Pre-signing with --sign - (ad-hoc) marks each .so as "signed Mach-O" so the
sideloading tool detects it and replaces the signature with the developer identity.
"""

def _sign_ios_extension_impl(ctx):
    signed_files = []
    for src in ctx.files.srcs:
        out = ctx.actions.declare_file("signed_exts/" + src.basename)
        ctx.actions.run_shell(
            inputs = [src],
            outputs = [out],
            command = """
set -e
cp "{src}" "{out}"
# Try xcrun codesign first (macOS build host), fall back to plain codesign.
xcrun codesign --sign - --force --timestamp=none "{out}" 2>/dev/null || \
codesign  --sign - --force --timestamp=none "{out}" 2>/dev/null || \
echo "WARNING: codesign not found; {out} will be unsigned" >&2
""".format(src = src.path, out = out.path),
            mnemonic = "AdHocSignExtension",
            progress_message = "Ad-hoc signing %s" % src.basename,
        )
        signed_files.append(out)
    return [DefaultInfo(files = depset(signed_files))]

sign_ios_extensions = rule(
    implementation = _sign_ios_extension_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Mach-O .so extension modules to ad-hoc sign",
        ),
    },
    doc = "Ad-hoc signs CPython .so extension modules for inclusion in a signed iOS framework.",
)
