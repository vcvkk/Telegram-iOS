// Stub binary for PythonExtensions.framework.
// This framework bundles CPython .so extension modules so they are
// code-signed as part of the app bundle and dlopen-able from Frameworks/.
// The stub symbol gives the linker a valid entry point; it is never called.
void EGPythonExtensionsInit(void) {}
