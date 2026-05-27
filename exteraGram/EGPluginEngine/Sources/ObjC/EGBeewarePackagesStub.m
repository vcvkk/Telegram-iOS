// Stub binary for BeewarePackages.framework.
// This framework bundles pre-built beeware iOS arm64 .so C-extension modules
// (Pillow, aiohttp, numpy, cffi, cryptography, etc.) plus their Python files.
// All .so files are code-signed as part of the app bundle, making them
// dlopen-able under AMFI on signed builds (Feather, SideStore, LiveContainer).
void EGBeewarePackagesInit(void) {}
