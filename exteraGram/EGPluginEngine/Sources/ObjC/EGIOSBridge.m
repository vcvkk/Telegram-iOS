// MARK: exteraGram — EGPluginEngine ObjC/Python bridge implementation

#import "EGIOSBridge.h"
#import "EGViewRenderer.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/time.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <ZipArchive/ZipArchive.h>
#import <SystemConfiguration/SystemConfiguration.h>

extern NSString *const EGPluginViewCallbackNotification;

// ---------------------------------------------------------------------------
// CPython C API — only compiled when the framework is present.
// To activate: add Python.xcframework to third-party/Python/ and update BUILD.
// ---------------------------------------------------------------------------
#if __has_include(<Python/Python.h>)
#define EGPLUGIN_HAS_PYTHON 1
#import <Python/Python.h>
#endif

// ---------------------------------------------------------------------------
// Logging helper (ObjC side, calls back into Swift EGLoggerBridge)
// ---------------------------------------------------------------------------

// Declared in Swift as:
//   @objc public static func logFromPlugin(tag: String, message: String)
// We forward-declare it so ObjC can call it without importing the Swift module.
@class EGLoggerBridgeImpl;
extern void EGLoggerBridgeImpl_logFromPlugin(NSString *tag, NSString *message);

// Swift @_cdecl bridge — synchronous write to EGPluginDebugLog (no async dispatch).
// Declared in EGPluginDebugLog.swift.
extern void EGPluginDebugLog_appendCStr(const char *tag, const char *message);

// Swift @_cdecl bridges — localisation. Declared in EGStringsBridge.swift.
// Both return strdup'd strings — caller must free().
extern const char *EGStringsBridge_currentLanguageCStr(void);
extern const char *EGStringsBridge_localizedStringCStr(const char *key);

// Swift @_cdecl bridges — client info & data dir. Declared in EGPluginClientInfo.swift.
extern int64_t EGPluginClientInfo_getAccountId(void);
extern int64_t EGPluginClientInfo_getUserId(void);
extern const char *EGPluginClientInfo_getConnectionStateCStr(void);
extern const char *EGPluginClientInfo_getPluginDataDirCStr(const char *plugin_id);

static void plugin_log(NSString *tag, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void plugin_log(NSString *tag, NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    os_log(OS_LOG_DEFAULT, "[SG.%{public}@] %{public}@", tag, msg);
    [EGPythonBridge logFromPlugin:tag message:msg];
}

// ---------------------------------------------------------------------------
// Global Python state (only used when EGPLUGIN_HAS_PYTHON)
// ---------------------------------------------------------------------------

#if EGPLUGIN_HAS_PYTHON

// Forward declarations — implementations appear after the PyMethodDef table.
static PyObject *ns_to_py(id obj);
static id py_to_ns(PyObject *obj);

// Dict: {"tl_type": [callback, ...]}
static PyObject *g_tl_hooks = NULL;
// Dict: {"plugin_id": module}
static PyObject *g_loaded_modules = NULL;
static BOOL g_initialized = NO;

// Wired by EGPluginsEngineImpl to forward suppress_entity/attribute_type() → EGPluginHooks Sets
static void (^g_suppressEntityTypeHandler)(NSString *, BOOL) = nil;
static void (^g_suppressAttributeTypeHandler)(NSString *, BOOL) = nil;
// Wired by PluginsController.wireClientInfo: lets plugins send Telegram messages
static void (^g_sendMessageHandler)(long long, NSString *) = nil;
// Wired by PluginsController.wireClientInfo: lets plugins send Telegram reactions
static void (^g_sendReactionHandler)(long long, int32_t, NSString *) = nil;
// Wired by EGPluginsEngineImpl: register a plugin menu entry in the iOS UI
static void (^g_registerMenuItemHandler)(NSString *, NSString *, NSString *, NSString *) = nil;

// ---------------------------------------------------------------------------
// Overlay system storage (BRIDGE_VERSION 4)
// ---------------------------------------------------------------------------
// overlay_id → root UIView of the overlay UIWindow (content goes here)
static NSMutableDictionary<NSNumber *, UIView *>         *g_overlays       = nil;
// overlay_id → array of EGGestureTarget (keeps them alive while overlay lives)
static NSMutableDictionary<NSNumber *, NSMutableArray *> *g_overlayTargets = nil;
// overlay_id → UIWindow (kept alive; hidden/released on dismiss)
static NSMutableDictionary<NSNumber *, UIWindow *>       *g_overlayWindows = nil;
// audio_id → AVAudioPlayer
static NSMutableDictionary<NSNumber *, AVAudioPlayer *>  *g_audioPlayers   = nil;
static int32_t g_nextOverlayId = 1;
static int32_t g_nextAudioId   = 1;
// splat image cache: file path → decoded UIImage (animated). Avoids per-tap disk I/O + decode.
static NSMutableDictionary<NSString *, UIImage *>        *g_splatCache     = nil;
// view_id → UIView — tracks individual views created via add_image_view.
static NSMutableDictionary<NSNumber *, UIView *>         *g_views          = nil;
// view_id → overlay_id — used to purge views when their overlay is dismissed.
static NSMutableDictionary<NSNumber *, NSNumber *>       *g_viewOwners     = nil;
static int32_t g_nextViewId = 1;

// UIKit values that must be read on main thread — cached at engine startup via prepareUIKitCaches.
// Once written, only ever read (no synchronisation needed for reads after the barrier).
static struct {
    int    width;
    int    height;
    double scale;
    BOOL   ready;
} g_screen = {0, 0, 1.0, NO};

// ---------------------------------------------------------------------------
// ObjC method-hook registry  (add_method_hook)
// ---------------------------------------------------------------------------

typedef struct {
    IMP original_imp;
    PyObject *before_list;
    PyObject *after_list;
} EGMethodHookEntry;

// Key: "ClassName.methodName" → NSValue wrapping EGMethodHookEntry*
static NSMutableDictionary<NSString *, NSValue *> *g_method_hooks = nil;

// Pass the ObjC instance pointer as a Python integer so callbacks can use
// add_view_label / class inspection.  ptr == 0 when called without a target.
static void eg_call_python_hooks(PyObject *list, id target) {
    if (!list) return;
    Py_ssize_t n = PyList_Size(list);
    if (n == 0) return;
    PyObject *py_ptr = PyLong_FromVoidPtr(target ? (__bridge void *)target : NULL);
    for (Py_ssize_t i = 0; i < n; i++) {
        PyObject *cb = PyList_GetItem(list, i); // borrowed
        if (cb && PyCallable_Check(cb)) {
            PyObject *r = PyObject_CallFunctionObjArgs(cb, py_ptr, NULL);
            if (!r) PyErr_Clear(); else Py_DECREF(r);
        }
    }
    Py_DECREF(py_ptr);
}

// ---------------------------------------------------------------------------
// Python C extension: _ios_bridge
// ---------------------------------------------------------------------------

static PyObject *py_log_text(PyObject *self, PyObject *args) {
    const char *tag = "Plugin";
    const char *msg = "";
    if (!PyArg_ParseTuple(args, "s|s", &msg, &tag)) {
        PyErr_Clear();
        if (!PyArg_ParseTuple(args, "s", &msg)) return NULL;
    }
    NSString *nsTag = [NSString stringWithUTF8String:tag];
    NSString *nsMsg = [NSString stringWithUTF8String:msg];
    // Dispatch async so we don't block the plugin while logging
    dispatch_async(dispatch_get_main_queue(), ^{
        [EGPythonBridge logFromPlugin:nsTag message:nsMsg];
    });
    Py_RETURN_NONE;
}

static PyObject *py_add_tl_hook(PyObject *self, PyObject *args) {
    const char *tl_type;
    PyObject *callback;
    if (!PyArg_ParseTuple(args, "sO", &tl_type, &callback)) return NULL;
    if (!PyCallable_Check(callback)) {
        PyErr_SetString(PyExc_TypeError, "callback must be callable");
        return NULL;
    }
    if (!g_tl_hooks) {
        PyErr_SetString(PyExc_RuntimeError, "_ios_bridge not initialized");
        return NULL;
    }
    PyObject *list = PyDict_GetItemString(g_tl_hooks, tl_type);
    if (!list) {
        list = PyList_New(0);
        PyDict_SetItemString(g_tl_hooks, tl_type, list);
        Py_DECREF(list);
        list = PyDict_GetItemString(g_tl_hooks, tl_type);
    }
    PyList_Append(list, callback);
    EGPluginDebugLog_appendCStr("TLHook",
        [[NSString stringWithFormat:@"add_tl_hook: registered '%s' (total %ld)",
          tl_type, (long)PyList_Size(list)] UTF8String]);
    Py_RETURN_NONE;
}

static PyObject *py_has_hook(PyObject *self, PyObject *args) {
    const char *tl_type;
    if (!PyArg_ParseTuple(args, "s", &tl_type)) return NULL;
    if (!g_tl_hooks) Py_RETURN_FALSE;
    PyObject *list = PyDict_GetItemString(g_tl_hooks, tl_type);
    if (list && PyList_Size(list) > 0) Py_RETURN_TRUE;
    Py_RETURN_FALSE;
}

static PyObject *py_run_on_main_thread(PyObject *self, PyObject *args) {
    PyObject *callable;
    if (!PyArg_ParseTuple(args, "O", &callable)) return NULL;
    if (!PyCallable_Check(callable)) {
        PyErr_SetString(PyExc_TypeError, "argument must be callable");
        return NULL;
    }
    Py_INCREF(callable);
    dispatch_async(dispatch_get_main_queue(), ^{
        PyGILState_STATE state = PyGILState_Ensure();
        PyObject *result = PyObject_CallFunctionObjArgs(callable, NULL);
        if (!result) PyErr_Clear();
        else Py_DECREF(result);
        Py_DECREF(callable);
        PyGILState_Release(state);
    });
    Py_RETURN_NONE;
}

// show_alert(title, message, button="OK")
static PyObject *py_show_alert(PyObject *self, PyObject *args) {
    const char *title   = "";
    const char *message = "";
    const char *button  = "OK";
    if (!PyArg_ParseTuple(args, "ss|s", &title, &message, &button)) return NULL;
    NSString *nsTitle   = [NSString stringWithUTF8String:title];
    NSString *nsMessage = [NSString stringWithUTF8String:message];
    NSString *nsButton  = [NSString stringWithUTF8String:button];
    // Delay 1.0s so any presenting sheet / install flow can finish dismissing first.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Find the topmost presented VC using connected scenes (iOS 13+).
        UIWindow *keyWin = nil;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow) { keyWin = w; break; }
                }
            }
            if (keyWin) break;
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (!keyWin) keyWin = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
        UIViewController *root = keyWin.rootViewController;
        // Skip VCs that are in the middle of being dismissed — presenting from them fails silently.
        while (root.presentedViewController && !root.presentedViewController.isBeingDismissed) {
            root = root.presentedViewController;
        }
        // If root itself is being dismissed, step back to its presenter.
        while (root && root.isBeingDismissed && root.presentingViewController) {
            root = root.presentingViewController;
        }
        if (!root) return;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:nsTitle
                             message:nsMessage
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:nsButton
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [root presentViewController:alert animated:YES completion:nil];
    });
    Py_RETURN_NONE;
}

// show_action_sheet(title, message, options, callback)
//   Presents a UIAlertController with one button per option.  When the user
//   taps a button, callback(index, label) is invoked under the Python GIL.
//   The new alert is presented after a 0.4s delay so any previously visible
//   alert has time to finish its dismissal animation.
static PyObject *py_show_action_sheet(PyObject *self, PyObject *args) {
    const char *title = "", *message = "";
    PyObject *options = NULL, *callback = NULL;
    if (!PyArg_ParseTuple(args, "ssOO", &title, &message, &options, &callback)) return NULL;
    if (!PyList_Check(options)) {
        PyErr_SetString(PyExc_TypeError, "options must be a list of strings");
        return NULL;
    }
    if (!PyCallable_Check(callback)) {
        PyErr_SetString(PyExc_TypeError, "callback must be callable");
        return NULL;
    }
    NSString *nsTitle   = [NSString stringWithUTF8String:title];
    NSString *nsMessage = [NSString stringWithUTF8String:message];

    NSMutableArray<NSString *> *labels = [NSMutableArray new];
    Py_ssize_t n = PyList_Size(options);
    for (Py_ssize_t i = 0; i < n; i++) {
        PyObject *item = PyList_GetItem(options, i);
        const char *s = PyUnicode_AsUTF8(item);
        if (s) [labels addObject:[NSString stringWithUTF8String:s]];
    }

    // Retain callback once; it's released by whichever action handler fires.
    Py_INCREF(callback);
    PyObject *cbBox = callback; // captured by all action handler blocks
    __block BOOL fired = NO;    // ensure exactly one DECREF

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Find the topmost VC able to present.
        UIWindow *win = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { win = w; break; }
                }
                if (win) break;
            }
        }
        UIViewController *vc = win.rootViewController;
        while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
            vc = vc.presentedViewController;
        }
        if (!vc) {
            // No host VC — release ref and abort.
            PyGILState_STATE gs = PyGILState_Ensure();
            Py_DECREF(cbBox);
            PyGILState_Release(gs);
            return;
        }

        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:nsTitle.length ? nsTitle : nil
                             message:nsMessage.length ? nsMessage : nil
                      preferredStyle:UIAlertControllerStyleAlert];

        for (NSInteger i = 0; i < (NSInteger)labels.count; i++) {
            NSString *label = labels[i];
            UIAlertActionStyle style = UIAlertActionStyleDefault;
            NSString *lc = [label lowercaseString];
            if ([lc containsString:@"cancel"] || [lc containsString:@"отмена"] ||
                [lc isEqualToString:@"exit"] || [lc isEqualToString:@"выход"]) {
                style = UIAlertActionStyleCancel;
            }
            NSInteger capturedIdx = i;
            NSString *capturedLabel = label;
            [alert addAction:[UIAlertAction
                actionWithTitle:label style:style
                        handler:^(UIAlertAction *act) {
                if (fired) return;
                fired = YES;
                PyGILState_STATE gs = PyGILState_Ensure();
                PyObject *res = PyObject_CallFunction(
                    cbBox, "is", (int)capturedIdx, capturedLabel.UTF8String);
                if (!res) { PyErr_Print(); PyErr_Clear(); } else Py_DECREF(res);
                Py_DECREF(cbBox);
                PyGILState_Release(gs);
            }]];
        }
        [vc presentViewController:alert animated:YES completion:nil];
    });
    Py_RETURN_NONE;
}

// Dialog registry — maps handle string to presented UIAlertController.
static NSMutableDictionary<NSString *, UIViewController *> *g_dialogs = nil;

@interface EGDoneTarget : NSObject <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, weak) UIViewController *vc;
@property (nonatomic, copy) NSString *dialogHandle;
@property (nonatomic, copy) NSString *dismissCallbackId;
@property (nonatomic) BOOL fired;
- (void)done:(id)sender;
- (void)_fireCallback;
@end
@implementation EGDoneTarget
- (void)done:(id)sender {
    [self.vc dismissViewControllerAnimated:YES completion:^{ [self _fireCallback]; }];
}
// Fires when user swipes down to dismiss (interactive dismissal only).
- (void)presentationControllerDidDismiss:(UIPresentationController *)pc {
    [self _fireCallback];
}
- (void)_fireCallback {
    if (self.fired) return;
    self.fired = YES;
    NSString *h = self.dialogHandle;
    if (h.length > 0) [g_dialogs removeObjectForKey:h];
    NSString *cbId = self.dismissCallbackId;
    if (cbId.length == 0) return;
    const char *cid = cbId.UTF8String;
    [EGPythonBridge withPython:^{
        PyObject *mod = PyImport_ImportModule("eg_widgets");
        if (!mod) { PyErr_Clear(); return; }
        PyObject *fn = PyObject_GetAttrString(mod, "_invoke");
        if (fn && PyCallable_Check(fn)) {
            PyObject *r = PyObject_CallFunction(fn, "s", cid);
            if (!r) PyErr_Clear(); else Py_DECREF(r);
        }
        Py_XDECREF(fn);
        Py_DECREF(mod);
    }];
}
@end

// ---------------------------------------------------------------------------
// Gesture target: bridges UIGestureRecognizer → Python callable (BRIDGE_VERSION 4)
// ---------------------------------------------------------------------------

@interface EGGestureTarget : NSObject
- (instancetype)initWithCallback:(PyObject *)cb longPress:(BOOL)lp;
- (void)handleGesture:(UIGestureRecognizer *)gr;
@end

@implementation EGGestureTarget {
    PyObject *_callback;
    BOOL      _isLongPress;
}
- (instancetype)initWithCallback:(PyObject *)cb longPress:(BOOL)lp {
    if (!(self = [super init])) return nil;
    Py_INCREF(cb);
    _callback   = cb;
    _isLongPress = lp;
    return self;
}
- (void)dealloc {
    if (_callback) {
        PyGILState_STATE gs = PyGILState_Ensure();
        Py_DECREF(_callback);
        PyGILState_Release(gs);
    }
}
- (void)handleGesture:(UIGestureRecognizer *)gr {
    if (!_callback) return;
    if (_isLongPress) {
        BOOL began = (gr.state == UIGestureRecognizerStateBegan);
        BOOL ended = (gr.state == UIGestureRecognizerStateEnded ||
                      gr.state == UIGestureRecognizerStateCancelled);
        if (!began && !ended) return;
        PyGILState_STATE gs = PyGILState_Ensure();
        PyObject *r = PyObject_CallFunctionObjArgs(_callback, began ? Py_True : Py_False, NULL);
        if (!r) { PyErr_Print(); PyErr_Clear(); } else Py_DECREF(r);
        PyGILState_Release(gs);
    } else {
        PyGILState_STATE gs = PyGILState_Ensure();
        PyObject *r = PyObject_CallFunctionObjArgs(_callback, NULL);
        if (!r) { PyErr_Print(); PyErr_Clear(); } else Py_DECREF(r);
        PyGILState_Release(gs);
    }
}
@end

// ---------------------------------------------------------------------------
// Raw-touch overlay view: forwards touchesBegan/Moved/Ended/Cancelled → Python
// (BRIDGE_VERSION 5 — add_touch_handler)
// ---------------------------------------------------------------------------

@interface EGOverlayContentView : UIView
- (void)setTouchCallback:(PyObject *)callback;
@end

@implementation EGOverlayContentView {
    PyObject *_touchCallback;
}
- (void)setTouchCallback:(PyObject *)callback {
    PyGILState_STATE gs = PyGILState_Ensure();
    Py_XDECREF(_touchCallback);
    _touchCallback = callback;
    Py_XINCREF(callback);
    PyGILState_Release(gs);
}
- (void)dealloc {
    if (_touchCallback) {
        PyGILState_STATE gs = PyGILState_Ensure();
        Py_DECREF(_touchCallback);
        PyGILState_Release(gs);
        _touchCallback = NULL;
    }
}
- (void)_fireTouchEvent:(int)action touch:(UITouch *)touch {
    if (!_touchCallback) return;
    CGPoint pt = [touch locationInView:self];
    PyGILState_STATE gs = PyGILState_Ensure();
    PyObject *r = PyObject_CallFunction(_touchCallback, "idd", action, (double)pt.x, (double)pt.y);
    if (!r) { PyErr_Print(); PyErr_Clear(); } else Py_DECREF(r);
    PyGILState_Release(gs);
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) [self _fireTouchEvent:0 touch:t];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) [self _fireTouchEvent:2 touch:t];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) [self _fireTouchEvent:1 touch:t];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) [self _fireTouchEvent:1 touch:t];
}
@end

@interface EGOverlayViewController : UIViewController
@end
@implementation EGOverlayViewController
- (void)loadView {
    EGOverlayContentView *v = [[EGOverlayContentView alloc] init];
    v.backgroundColor = UIColor.clearColor;
    v.userInteractionEnabled = YES;
    self.view = v;
}
@end

static UIWindow *eg_key_window_for_overlay(void) {
    UIWindow *w = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *win in ((UIWindowScene *)scene).windows) {
                if (win.isKeyWindow) { w = win; break; }
            }
        }
        if (w) break;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!w) w = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    return w;
}

// show_dialog(spec) -> handle: present a Python widget tree as a modal sheet.
static PyObject *py_show_dialog(PyObject *self, PyObject *args) {
    PyObject *specObj = NULL;
    if (!PyArg_ParseTuple(args, "O", &specObj)) return NULL;

    id ns = py_to_ns(specObj);
    if (![ns isKindOfClass:[NSDictionary class]]) {
        PyErr_SetString(PyExc_TypeError, "show_dialog: spec must be a dict");
        return NULL;
    }
    NSDictionary *spec = (NSDictionary *)ns;
    NSString *title = spec[@"title"] ?: @"";
    NSDictionary *viewSpec = spec[@"view"];

    // Allocate a handle and ask the renderer (on main) to build + present.
    NSString *handle = [[NSUUID UUID] UUIDString];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_dialogs) g_dialogs = [NSMutableDictionary new];
        UIView *content = [EGViewRenderer buildView:viewSpec];
        if (!content) {
            EGPluginDebugLog_appendCStr("Dialog", "show_dialog: empty content view");
            return;
        }

        // Wrap content in a UIViewController for presentation.
        UIViewController *vc = [UIViewController new];
        vc.modalPresentationStyle = UIModalPresentationFormSheet;
        vc.view.backgroundColor = UIColor.systemBackgroundColor;

        content.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:content];
        UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [content.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor],
            [content.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
            [content.topAnchor      constraintEqualToAnchor:safe.topAnchor],
            [content.bottomAnchor   constraintEqualToAnchor:safe.bottomAnchor],
        ]];
        if (title.length > 0) {
            vc.title = title;
        }

        // Find a host VC to present from.
        UIWindow *win = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { win = w; break; }
                }
                if (win) break;
            }
        }
        UIViewController *host = win.rootViewController;
        while (host.presentedViewController && !host.presentedViewController.isBeingDismissed) {
            host = host.presentedViewController;
        }
        if (!host) {
            EGPluginDebugLog_appendCStr("Dialog", "show_dialog: no host VC found");
            return;
        }

        // Wrap in a navigation controller so a Done button can be added cleanly.
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        NSString *dismissId = spec[@"on_dismiss_id"] ?: @"";
        EGDoneTarget *doneTarget = [EGDoneTarget new];
        doneTarget.vc = nav;
        doneTarget.dialogHandle = handle;
        doneTarget.dismissCallbackId = dismissId;
        vc.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                          target:doneTarget
                                                          action:@selector(done:)];
        // Retain doneTarget for the nav controller's lifetime.
        objc_setAssociatedObject(nav, "EGDoneTarget", doneTarget, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        g_dialogs[handle] = nav;
        // Set the presentation delegate in the completion block — presentationController
        // is guaranteed non-nil once the presentation animation has begun.
        [host presentViewController:nav animated:YES completion:^{
            nav.presentationController.delegate = doneTarget;
        }];
        EGPluginDebugLog_appendCStr("Dialog",
            [[NSString stringWithFormat:@"show_dialog: presented (handle=%@)", handle] UTF8String]);
    });

    return PyUnicode_FromString(handle.UTF8String);
}

// update_dialog(handle, view_spec) — replace the dialog's content view in place.
// Used by plugins to refresh game/state UI without dismissing & re-presenting.
static PyObject *py_update_dialog(PyObject *self, PyObject *args) {
    const char *handle = "";
    PyObject *specObj = NULL;
    if (!PyArg_ParseTuple(args, "sO", &handle, &specObj)) return NULL;
    id ns = py_to_ns(specObj);
    if (![ns isKindOfClass:[NSDictionary class]]) {
        PyErr_SetString(PyExc_TypeError, "update_dialog: spec must be a dict");
        return NULL;
    }
    NSDictionary *viewSpec = (NSDictionary *)ns;
    NSString *h = [NSString stringWithUTF8String:handle];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *navVC = g_dialogs[h];
        UIViewController *vc = nil;
        if ([navVC isKindOfClass:[UINavigationController class]]) {
            vc = ((UINavigationController *)navVC).viewControllers.firstObject;
        } else {
            vc = navVC;
        }
        if (!vc) return;
        for (UIView *sv in [vc.view.subviews copy]) [sv removeFromSuperview];
        UIView *content = [EGViewRenderer buildView:viewSpec];
        if (!content) return;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:content];
        UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [content.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor],
            [content.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
            [content.topAnchor      constraintEqualToAnchor:safe.topAnchor],
            [content.bottomAnchor   constraintEqualToAnchor:safe.bottomAnchor],
        ]];
    });
    Py_RETURN_NONE;
}

// dismiss_dialog(handle)
static PyObject *py_dismiss_dialog(PyObject *self, PyObject *args) {
    const char *handle = "";
    if (!PyArg_ParseTuple(args, "s", &handle)) return NULL;
    NSString *h = [NSString stringWithUTF8String:handle];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = g_dialogs[h];
        if (vc) {
            [vc dismissViewControllerAnimated:YES completion:nil];
            [g_dialogs removeObjectForKey:h];
        }
    });
    Py_RETURN_NONE;
}

// invoke_view_callback(handle, *args) — called by ObjC notification observer,
// forwards back into Python's eg_widgets._invoke().  Exposed as a Python-callable
// in case tests want to trigger it manually too.
static PyObject *py_invoke_view_callback(PyObject *self, PyObject *args) {
    const char *handle = "";
    if (!PyArg_ParseTuple(args, "s", &handle)) return NULL;
    PyObject *mod = PyImport_ImportModule("eg_widgets");
    if (mod) {
        PyObject *fn = PyObject_GetAttrString(mod, "_invoke");
        if (fn && PyCallable_Check(fn)) {
            PyObject *r = PyObject_CallFunction(fn, "s", handle);
            if (!r) PyErr_Clear(); else Py_DECREF(r);
        }
        Py_XDECREF(fn);
        Py_DECREF(mod);
    } else { PyErr_Clear(); }
    Py_RETURN_NONE;
}

// show_toast(message, duration=2.0)
static PyObject *py_show_toast(PyObject *self, PyObject *args) {
    const char *message = "";
    double duration = 2.0;
    if (!PyArg_ParseTuple(args, "s|d", &message, &duration)) return NULL;
    NSString *nsMsg = [NSString stringWithUTF8String:message];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"EGPluginShowToastNotification"
                          object:nil
                        userInfo:@{@"message": nsMsg, @"duration": @(duration)}];
    });
    Py_RETURN_NONE;
}

// copy_to_clipboard(text)
static PyObject *py_copy_to_clipboard(PyObject *self, PyObject *args) {
    const char *text = "";
    if (!PyArg_ParseTuple(args, "s", &text)) return NULL;
    NSString *nsText = [NSString stringWithUTF8String:text];
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIPasteboard generalPasteboard].string = nsText;
    });
    Py_RETURN_NONE;
}

// read_clipboard() -> str
static PyObject *py_read_clipboard(PyObject *self, PyObject *args) {
    __block NSString *value = nil;
    if ([NSThread isMainThread]) {
        value = [UIPasteboard generalPasteboard].string;
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            value = [UIPasteboard generalPasteboard].string;
        });
    }
    const char *cstr = value ? [value UTF8String] : "";
    return PyUnicode_FromString(cstr ?: "");
}

// get_screen_info() -> dict {"width": float, "height": float, "scale": float}
static PyObject *py_get_screen_info(PyObject *self, PyObject *args) {
    __block CGFloat w = 0, h = 0, scale = 1;
    void (^block)(void) = ^{
        UIScreen *s = [UIScreen mainScreen];
        w = s.bounds.size.width;
        h = s.bounds.size.height;
        scale = s.scale;
    };
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
    PyObject *d = PyDict_New();
    PyDict_SetItemString(d, "width",  PyFloat_FromDouble((double)w));
    PyDict_SetItemString(d, "height", PyFloat_FromDouble((double)h));
    PyDict_SetItemString(d, "scale",  PyFloat_FromDouble((double)scale));
    return d;
}

// open_url(url)
static PyObject *py_open_url(PyObject *self, PyObject *args) {
    const char *url = "";
    if (!PyArg_ParseTuple(args, "s", &url)) return NULL;
    NSString *nsUrl = [NSString stringWithUTF8String:url];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *u = [NSURL URLWithString:nsUrl];
        if (u && [[UIApplication sharedApplication] canOpenURL:u]) {
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
        }
    });
    Py_RETURN_NONE;
}

// haptic_feedback(style="medium")
//   "light"|"medium"|"heavy" → UIImpactFeedbackGenerator
//   "success"|"warning"|"error" → UINotificationFeedbackGenerator
static PyObject *py_haptic_feedback(PyObject *self, PyObject *args) {
    const char *style = "medium";
    if (!PyArg_ParseTuple(args, "|s", &style)) return NULL;
    NSString *nsStyle = [NSString stringWithUTF8String:style];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([nsStyle isEqualToString:@"success"] ||
            [nsStyle isEqualToString:@"warning"] ||
            [nsStyle isEqualToString:@"error"]) {
            UINotificationFeedbackGenerator *gen = [UINotificationFeedbackGenerator new];
            UINotificationFeedbackType type = UINotificationFeedbackTypeSuccess;
            if      ([nsStyle isEqualToString:@"warning"]) type = UINotificationFeedbackTypeWarning;
            else if ([nsStyle isEqualToString:@"error"])   type = UINotificationFeedbackTypeError;
            [gen notificationOccurred:type];
        } else {
            UIImpactFeedbackStyle s = UIImpactFeedbackStyleMedium;
            if      ([nsStyle isEqualToString:@"light"]) s = UIImpactFeedbackStyleLight;
            else if ([nsStyle isEqualToString:@"heavy"]) s = UIImpactFeedbackStyleHeavy;
            UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:s];
            [gen impactOccurred];
        }
    });
    Py_RETURN_NONE;
}

// suppress_entity_type(type_name, suppress=True)
// Adds/removes a MessageTextEntity type name from EGPluginHooks.suppressedEntityTypes.
static PyObject *py_suppress_entity_type(PyObject *self, PyObject *args) {
    const char *typeName = "";
    int suppress = 1;
    if (!PyArg_ParseTuple(args, "s|p", &typeName, &suppress)) return NULL;
    void (^h)(NSString *, BOOL) = g_suppressEntityTypeHandler;
    if (h) {
        // Call synchronously — Set must be populated before asyncLayout reads it.
        // No UI work here, no main-thread requirement.
        h([NSString stringWithUTF8String:typeName], (BOOL)suppress);
        EGPluginDebugLog_appendCStr("Bridge",
            [[NSString stringWithFormat:@"suppress_entity_type: %s=%d", typeName, suppress] UTF8String]);
    } else {
        EGPluginDebugLog_appendCStr("Bridge", "suppress_entity_type: handler NIL — called before engine wired?");
    }
    Py_RETURN_NONE;
}

// suppress_attribute_type(type_name, suppress=True)
// Adds/removes a MessageAttribute class name from EGPluginHooks.suppressedAttributeTypes.
static PyObject *py_suppress_attribute_type(PyObject *self, PyObject *args) {
    const char *typeName = "";
    int suppress = 1;
    if (!PyArg_ParseTuple(args, "s|p", &typeName, &suppress)) return NULL;
    void (^h)(NSString *, BOOL) = g_suppressAttributeTypeHandler;
    if (h) {
        h([NSString stringWithUTF8String:typeName], (BOOL)suppress);
        EGPluginDebugLog_appendCStr("Bridge",
            [[NSString stringWithFormat:@"suppress_attribute_type: %s=%d", typeName, suppress] UTF8String]);
    } else {
        EGPluginDebugLog_appendCStr("Bridge", "suppress_attribute_type: handler NIL — called before engine wired?");
    }
    Py_RETURN_NONE;
}

// get_locale_language() -> str
static PyObject *py_get_locale_language(PyObject *self, PyObject *args) {
    const char *lang = EGStringsBridge_currentLanguageCStr();
    PyObject *result = PyUnicode_FromString(lang ?: "en");
    if (lang) free((void *)lang);
    return result;
}

// get_string(key, default="") -> str
static PyObject *py_get_string(PyObject *self, PyObject *args) {
    const char *key = "";
    const char *def = "";
    if (!PyArg_ParseTuple(args, "s|s", &key, &def)) return NULL;
    const char *value = EGStringsBridge_localizedStringCStr(key);
    PyObject *result;
    // EGLocalizationManager returns the key itself if not found — fall back to default.
    if (value && strcmp(value, key) != 0 && strlen(value) > 0) {
        result = PyUnicode_FromString(value);
    } else {
        result = PyUnicode_FromString(def);
    }
    if (value) free((void *)value);
    return result;
}

// ---------------------------------------------------------------------------
// Plugin settings (UserDefaults, namespaced eg.plugin.<id>.<key>)
// ---------------------------------------------------------------------------

static NSString *settingKey(const char *plugin_id, const char *key) {
    return [NSString stringWithFormat:@"eg.plugin.%s.%s", plugin_id ?: "", key ?: ""];
}

// get_plugin_setting(plugin_id, key, default=None) -> Any
static PyObject *py_get_plugin_setting(PyObject *self, PyObject *args) {
    const char *plugin_id = "", *key = "";
    PyObject *def = Py_None;
    if (!PyArg_ParseTuple(args, "ss|O", &plugin_id, &key, &def)) return NULL;
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:settingKey(plugin_id, key)];
    if (value == nil) {
        Py_INCREF(def);
        return def;
    }
    PyObject *py = ns_to_py(value);
    if (py) return py;
    Py_INCREF(def);
    return def;
}

// set_plugin_setting(plugin_id, key, value)
static PyObject *py_set_plugin_setting(PyObject *self, PyObject *args) {
    const char *plugin_id = "", *key = "";
    PyObject *value;
    if (!PyArg_ParseTuple(args, "ssO", &plugin_id, &key, &value)) return NULL;
    NSString *k = settingKey(plugin_id, key);
    if (value == Py_None) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:k];
    } else {
        id ns = py_to_ns(value);
        if (ns && ns != [NSNull null]) {
            [[NSUserDefaults standardUserDefaults] setObject:ns forKey:k];
        } else {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:k];
        }
    }
    Py_RETURN_NONE;
}

// ---------------------------------------------------------------------------
// Plugin data directory
// ---------------------------------------------------------------------------

// get_plugin_data_dir(plugin_id) -> str
static PyObject *py_get_plugin_data_dir(PyObject *self, PyObject *args) {
    const char *plugin_id = "";
    if (!PyArg_ParseTuple(args, "s", &plugin_id)) return NULL;
    const char *path = EGPluginClientInfo_getPluginDataDirCStr(plugin_id);
    PyObject *result = PyUnicode_FromString(path ?: "");
    if (path) free((void *)path);
    return result;
}

// ---------------------------------------------------------------------------
// Telegram client info
// ---------------------------------------------------------------------------

// get_account_id() -> int
static PyObject *py_get_account_id(PyObject *self, PyObject *args) {
    return PyLong_FromLongLong(EGPluginClientInfo_getAccountId());
}

// get_user_id() -> int
static PyObject *py_get_user_id(PyObject *self, PyObject *args) {
    return PyLong_FromLongLong(EGPluginClientInfo_getUserId());
}

// get_connection_state() -> str ("connected" | "connecting" | "updating" | "waiting_for_network")
static PyObject *py_get_connection_state(PyObject *self, PyObject *args) {
    const char *state = EGPluginClientInfo_getConnectionStateCStr();
    PyObject *result = PyUnicode_FromString(state ?: "connected");
    if (state) free((void *)state);
    return result;
}

// ---------------------------------------------------------------------------
// log(tag, message) — write directly to EGPluginDebugLog so Python plugins
// can emit visible diagnostics without relying on stdout/print().
static PyObject *py_log(PyObject *self, PyObject *args) {
    const char *tag = "Plugin", *message = "";
    if (!PyArg_ParseTuple(args, "ss", &tag, &message)) return NULL;
    EGPluginDebugLog_appendCStr(tag, message);
    Py_RETURN_NONE;
}

// Bulletin / toast
// ---------------------------------------------------------------------------

// show_bulletin(title, text="", icon="")
static PyObject *py_show_bulletin(PyObject *self, PyObject *args) {
    const char *title = "", *text = "", *icon = "";
    if (!PyArg_ParseTuple(args, "s|ss", &title, &text, &icon)) return NULL;
    NSString *nsTitle = [NSString stringWithUTF8String:title];
    NSString *nsText  = [NSString stringWithUTF8String:text];
    NSString *nsIcon  = [NSString stringWithUTF8String:icon];
    EGPluginDebugLog_appendCStr("Bulletin",
        [[NSString stringWithFormat:@"show_bulletin called: title='%@'", nsTitle] UTF8String]);
    // 0.5s delay so any toggle animation or install sheet finishes before we present.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        EGPluginDebugLog_appendCStr("Bulletin", "posting EGPluginShowBulletinNotification");
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"EGPluginShowBulletinNotification"
                          object:nil
                        userInfo:@{@"title": nsTitle, @"text": nsText, @"icon": nsIcon}];
    });
    Py_RETURN_NONE;
}

// ---------------------------------------------------------------------------
// View label overlay
// ---------------------------------------------------------------------------

// add_view_label(view_ptr, tag, text, font_size, r, g, b, a) → None
// Adds or updates a UILabel on the given UIView or ASDisplayNode (by ObjC pointer).
// tag: integer viewWithTag: key to find/replace existing label.
// Runs on main thread asynchronously; view_ptr must remain valid until then.
static PyObject *py_add_view_label(PyObject *self_py, PyObject *args) {
    unsigned long long ptr = 0;
    int tag = 0;
    const char *text_c = "";
    double font_size = 11.0, r = 0.5, g = 0.5, b = 0.5, a = 1.0;
    if (!PyArg_ParseTuple(args, "Kisddddd", &ptr, &tag, &text_c, &font_size, &r, &g, &b, &a))
        return NULL;
    if (!ptr) Py_RETURN_NONE;
    NSString *nsText   = [NSString stringWithUTF8String:text_c];
    CGFloat   fontSize = (CGFloat)font_size;
    UIColor  *color    = [UIColor colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a];
    NSInteger nsTag    = (NSInteger)tag;
    void *raw = (void *)(uintptr_t)ptr;
    dispatch_async(dispatch_get_main_queue(), ^{
        id obj = (__bridge id)raw;
        if (!obj) return;
        UIView *view = nil;
        if ([obj isKindOfClass:[UIView class]]) {
            view = (UIView *)obj;
        } else if ([obj respondsToSelector:@selector(view)]) {
            // ASDisplayNode — triggers node loading if not yet loaded
            view = [obj performSelector:@selector(view)];
        }
        if (!view) return;
        UILabel *lbl = (UILabel *)[view viewWithTag:nsTag];
        if (!lbl) {
            lbl = [[UILabel alloc] init];
            lbl.tag = nsTag;
            lbl.numberOfLines = 1;
            [view addSubview:lbl];
        }
        lbl.text      = nsText;
        lbl.font      = [UIFont systemFontOfSize:fontSize];
        lbl.textColor = color;
        [lbl sizeToFit];
        // Pin to top-left with 4pt padding
        CGRect f  = lbl.frame;
        f.origin  = CGPointMake(4.0, 2.0);
        lbl.frame = f;
    });
    Py_RETURN_NONE;
}

// get_theme_color(key) → (r, g, b, a)
// key: "primaryText" | "secondaryText" | "accent" | "background" | "separator"
// Uses system adaptive colors (iOS 13+) — resolves correctly for light/dark mode.
static PyObject *py_get_theme_color(PyObject *self_py, PyObject *args) {
    const char *key_c = "";
    if (!PyArg_ParseTuple(args, "s", &key_c)) return NULL;
    NSString *key = [NSString stringWithUTF8String:key_c];
    UIColor *color;
    if      ([key isEqualToString:@"primaryText"])    color = UIColor.labelColor;
    else if ([key isEqualToString:@"secondaryText"])  color = UIColor.secondaryLabelColor;
    else if ([key isEqualToString:@"accent"])         color = UIColor.systemBlueColor;
    else if ([key isEqualToString:@"background"])     color = UIColor.systemBackgroundColor;
    else if ([key isEqualToString:@"separator"])      color = UIColor.separatorColor;
    else                                              color = UIColor.secondaryLabelColor;
    // resolvedColorWithTraitCollection: is thread-safe from iOS 13+
    UITraitCollection *tc = [UITraitCollection currentTraitCollection];
    UIColor *resolved = [color resolvedColorWithTraitCollection:tc];
    CGFloat cr = 0, cg = 0, cb = 0, ca = 1;
    [resolved getRed:&cr green:&cg blue:&cb alpha:&ca];
    return Py_BuildValue("(dddd)", (double)cr, (double)cg, (double)cb, (double)ca);
}

// measure_text_width(text, font_size) → float
// Returns the typographic width of text rendered with system font at the given size.
static PyObject *py_measure_text_width(PyObject *self_py, PyObject *args) {
    const char *text_c = "";
    double font_size = 12.0;
    if (!PyArg_ParseTuple(args, "sd", &text_c, &font_size)) return NULL;
    NSString *text = [NSString stringWithUTF8String:text_c];
    UIFont   *font = [UIFont systemFontOfSize:(CGFloat)font_size];
    CGFloat   width = [text sizeWithAttributes:@{NSFontAttributeName: font}].width;
    return PyFloat_FromDouble((double)width);
}

// ---------------------------------------------------------------------------
// ObjC method hooks
// ---------------------------------------------------------------------------

// add_method_hook(class_name, method_name, before=None, after=None)
// Installs a Python before/after hook on the given ObjC instance method.
// The callbacks receive no arguments (notification-style hooks).
// Uses the ARM64 register-preservation trick so the original IMP sees all its args.
static PyObject *py_add_method_hook(PyObject *self_py, PyObject *args) {
    const char *class_name_c = "", *method_name_c = "";
    PyObject *before = Py_None, *after = Py_None;
    if (!PyArg_ParseTuple(args, "ss|OO", &class_name_c, &method_name_c, &before, &after))
        return NULL;
    if (before != Py_None && !PyCallable_Check(before)) {
        PyErr_SetString(PyExc_TypeError, "before must be callable or None"); return NULL;
    }
    if (after != Py_None && !PyCallable_Check(after)) {
        PyErr_SetString(PyExc_TypeError, "after must be callable or None"); return NULL;
    }
    if (!g_method_hooks) g_method_hooks = [NSMutableDictionary new];

    NSString *className  = [NSString stringWithUTF8String:class_name_c];
    NSString *methodName = [NSString stringWithUTF8String:method_name_c];
    NSString *key = [NSString stringWithFormat:@"%@.%@", className, methodName];

    Class cls = NSClassFromString(className);
    if (!cls) {
        PyErr_Format(PyExc_ValueError, "ObjC class not found: %s", class_name_c); return NULL;
    }
    SEL sel = NSSelectorFromString(methodName);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) method = class_getClassMethod(cls, sel);
    if (!method) {
        PyErr_Format(PyExc_ValueError, "Method not found: %s on %s", method_name_c, class_name_c);
        return NULL;
    }

    NSValue *existing = g_method_hooks[key];
    if (!existing) {
        // First hook on this method — install replacement IMP.
        EGMethodHookEntry *entry = (EGMethodHookEntry *)calloc(1, sizeof(EGMethodHookEntry));
        entry->original_imp = method_getImplementation(method);
        entry->before_list  = PyList_New(0);
        entry->after_list   = PyList_New(0);
        g_method_hooks[key] = [NSValue valueWithPointer:entry];

        const char *enc = method_getTypeEncoding(method) ?: "v@:";
        char ret = enc[0];

        // On ARM64 the calling convention puts self in x0, _cmd in x1, args in x2+.
        // Our block only declares (id, SEL) but extra args remain untouched in x2+,
        // so the original IMP receives them correctly when called via the cast.
        // Callbacks receive the target object pointer as a PyLong argument.
        IMP new_imp;
        if (ret == '@') {
            id (^block)(id, SEL) = ^id(id target, SEL cmd) {
                PyGILState_STATE gs = PyGILState_Ensure();
                eg_call_python_hooks(entry->before_list, target);
                PyGILState_Release(gs);
                typedef id (*F)(id, SEL);
                id res = ((F)entry->original_imp)(target, cmd);
                gs = PyGILState_Ensure();
                eg_call_python_hooks(entry->after_list, target);
                PyGILState_Release(gs);
                return res;
            };
            new_imp = imp_implementationWithBlock(block);
        } else if (ret == 'B' || ret == 'c') {
            BOOL (^block)(id, SEL) = ^BOOL(id target, SEL cmd) {
                PyGILState_STATE gs = PyGILState_Ensure();
                eg_call_python_hooks(entry->before_list, target);
                PyGILState_Release(gs);
                typedef BOOL (*F)(id, SEL);
                BOOL res = ((F)entry->original_imp)(target, cmd);
                gs = PyGILState_Ensure();
                eg_call_python_hooks(entry->after_list, target);
                PyGILState_Release(gs);
                return res;
            };
            new_imp = imp_implementationWithBlock(block);
        } else if (ret == 'i' || ret == 'l' || ret == 'q' || ret == 'I' || ret == 'L') {
            long long (^block)(id, SEL) = ^long long(id target, SEL cmd) {
                PyGILState_STATE gs = PyGILState_Ensure();
                eg_call_python_hooks(entry->before_list, target);
                PyGILState_Release(gs);
                typedef long long (*F)(id, SEL);
                long long res = ((F)entry->original_imp)(target, cmd);
                gs = PyGILState_Ensure();
                eg_call_python_hooks(entry->after_list, target);
                PyGILState_Release(gs);
                return res;
            };
            new_imp = imp_implementationWithBlock(block);
        } else {
            // void or float/struct — treat as void.
            void (^block)(id, SEL) = ^void(id target, SEL cmd) {
                PyGILState_STATE gs = PyGILState_Ensure();
                eg_call_python_hooks(entry->before_list, target);
                PyGILState_Release(gs);
                typedef void (*F)(id, SEL);
                ((F)entry->original_imp)(target, cmd);
                gs = PyGILState_Ensure();
                eg_call_python_hooks(entry->after_list, target);
                PyGILState_Release(gs);
            };
            new_imp = imp_implementationWithBlock(block);
        }

        // Safe swizzle: if cls doesn't define this method itself (inherits it from a superclass),
        // class_addMethod adds a class-specific override so only instances of cls are affected.
        // If cls already defines the method, method_setImplementation replaces it in-place.
        if (!class_addMethod(cls, sel, new_imp, enc)) {
            method_setImplementation(method, new_imp);
        }

        EGPluginDebugLog_appendCStr("Swizzler",
            [[NSString stringWithFormat:@"Hooked %@.%@", className, methodName] UTF8String]);
    }

    // Append callbacks (both first-time and subsequent hooks on the same method)
    EGMethodHookEntry *entry = (EGMethodHookEntry *)[(existing ?: g_method_hooks[key]) pointerValue];
    if (before != Py_None && PyCallable_Check(before)) {
        Py_INCREF(before); PyList_Append(entry->before_list, before); Py_DECREF(before);
    }
    if (after != Py_None && PyCallable_Check(after)) {
        Py_INCREF(after); PyList_Append(entry->after_list, after); Py_DECREF(after);
    }
    Py_RETURN_NONE;
}

// ---------------------------------------------------------------------------
// Plugin settings introspection & UI
// ---------------------------------------------------------------------------

// plugin_has_settings(plugin_id) -> bool
static PyObject *py_plugin_has_settings(PyObject *self, PyObject *args) {
    const char *plugin_id = "";
    if (!PyArg_ParseTuple(args, "s", &plugin_id)) return NULL;
    if (!g_loaded_modules) Py_RETURN_FALSE;
    PyObject *mod = PyDict_GetItemString(g_loaded_modules, plugin_id);
    if (!mod) Py_RETURN_FALSE;
    int has = PyObject_HasAttrString(mod, "__settings__");
    return PyBool_FromLong(has);
}

// get_plugin_settings(plugin_id) -> dict | None
// Returns the plugin's __settings__.to_dict() if present.
static PyObject *py_get_plugin_settings(PyObject *self, PyObject *args) {
    const char *plugin_id = "";
    if (!PyArg_ParseTuple(args, "s", &plugin_id)) return NULL;
    if (!g_loaded_modules) Py_RETURN_NONE;
    PyObject *mod = PyDict_GetItemString(g_loaded_modules, plugin_id);
    if (!mod) Py_RETURN_NONE;
    PyObject *settings = PyObject_GetAttrString(mod, "__settings__");
    if (!settings) { PyErr_Clear(); Py_RETURN_NONE; }
    PyObject *to_dict = PyObject_GetAttrString(settings, "to_dict");
    if (to_dict && PyCallable_Check(to_dict)) {
        PyObject *result = PyObject_CallFunctionObjArgs(to_dict, NULL);
        Py_DECREF(to_dict); Py_DECREF(settings);
        if (!result) { PyErr_Clear(); Py_RETURN_NONE; }
        return result;
    }
    Py_XDECREF(to_dict);
    return settings; // return as-is if no to_dict
}

// show_plugin_settings(plugin_id)
static PyObject *py_show_plugin_settings(PyObject *self, PyObject *args) {
    const char *plugin_id = "";
    if (!PyArg_ParseTuple(args, "s", &plugin_id)) return NULL;
    NSString *nsId = [NSString stringWithUTF8String:plugin_id];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"EGPluginShowSettingsNotification"
                          object:nil
                        userInfo:@{@"pluginId": nsId}];
    });
    Py_RETURN_NONE;
}

// send_message(peer_id: int, text: str) — plugin-initiated Telegram message send.
// Calls g_sendMessageHandler which is wired to real enqueueMessages by PluginsController.
static PyObject *py_send_message(PyObject *self, PyObject *args) {
    long long peerId = 0;
    const char *text = "";
    if (!PyArg_ParseTuple(args, "Ls", &peerId, &text)) return NULL;
    void (^h)(long long, NSString *) = g_sendMessageHandler;
    if (h) {
        NSString *nsText = [NSString stringWithUTF8String:text];
        h(peerId, nsText);
        EGPluginDebugLog_appendCStr("Bridge", [[NSString stringWithFormat:@"send_message: peer=%lld len=%lu", peerId, (unsigned long)nsText.length] UTF8String]);
    } else {
        EGPluginDebugLog_appendCStr("Bridge", "send_message: handler NIL — wireClientInfo not called yet?");
    }
    Py_RETURN_NONE;
}

// send_reaction(peer_id: int, msg_id: int, emoticon: str) — plugin-initiated reaction send.
// Calls g_sendReactionHandler wired to updateMessageReactionsInteractively by PluginsController.
static PyObject *py_send_reaction(PyObject *self, PyObject *args) {
    long long peerId = 0;
    int       msgId  = 0;
    const char *emoticon = "";
    if (!PyArg_ParseTuple(args, "Lis", &peerId, &msgId, &emoticon)) return NULL;
    void (^h)(long long, int32_t, NSString *) = g_sendReactionHandler;
    if (h) {
        NSString *nsEmoticon = [NSString stringWithUTF8String:emoticon];
        h(peerId, (int32_t)msgId, nsEmoticon);
        EGPluginDebugLog_appendCStr("Bridge", [[NSString stringWithFormat:
            @"send_reaction: peer=%lld msg=%d emoticon=%s", peerId, msgId, emoticon] UTF8String]);
    } else {
        EGPluginDebugLog_appendCStr("Bridge", "send_reaction: handler NIL — wireClientInfo not called?");
    }
    Py_RETURN_NONE;
}

// get_device_info() -> dict
// Returns: battery_level (float, -1 if unknown), battery_state (str), app_version (str).
// Safe to call from any thread — battery monitoring must have been enabled on main thread
// via prepareUIKitCaches before this is called; batteryLevel/batteryState are then atomic reads.
// NSBundle info is immutable after app launch and thread-safe.
static PyObject *py_get_device_info(PyObject *self, PyObject *args) {
    UIDevice *device = [UIDevice currentDevice];
    float level = device.batteryLevel;
    NSString *state;
    switch (device.batteryState) {
        case UIDeviceBatteryStateCharging:  state = @"charging";    break;
        case UIDeviceBatteryStateFull:      state = @"full";        break;
        case UIDeviceBatteryStateUnplugged: state = @"discharging"; break;
        default:                            state = @"unknown";     break;
    }
    NSString *shortVer = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString *buildNum = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";
    NSString *appVer   = buildNum.length
        ? [NSString stringWithFormat:@"%@ (%@)", shortVer, buildNum]
        : shortVer;
    NSDictionary *result = @{
        @"battery_level": @(level),
        @"battery_state": state,
        @"app_version":   appVer,
    };
    return ns_to_py(result);
}

// get_system_info() -> dict
// Collects all hardware/OS/network info in ObjC so plugins need no C extensions.
// Safe to call from any thread — all APIs used here are thread-safe:
//   sysctl*, uname, gettimeofday, getifaddrs: POSIX, thread-safe by spec.
//   NSFileManager -attributesOfFileSystemForPath: thread-safe.
//   NSBundle info: immutable after launch, thread-safe.
//   UIDevice systemVersion: immutable string, thread-safe.
//   UIDevice batteryLevel/batteryState: atomic reads once monitoring is enabled (see prepareUIKitCaches).
//   UIScreen nativeBounds/nativeScale: cached in g_screen by prepareUIKitCaches (main thread).
// Fields: device_model, architecture, ios_version, kernel_version, uptime_seconds,
//         battery_level, battery_state, jailbroken, cpu_brand, cpu_count, ram_bytes,
//         storage_total, storage_free, screen_width, screen_height, screen_scale,
//         network_ip, network_type, app_version.
static PyObject *py_get_system_info(PyObject *self, PyObject *args) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:24];

    // --- Device model ---
    char hw[256] = {0}; size_t hwsz = sizeof(hw);
    sysctlbyname("hw.machine", hw, &hwsz, NULL, 0);
    d[@"device_model"] = hw[0] ? @(hw) : @"Unknown";

    // --- Architecture ---
    struct utsname un; uname(&un);
    d[@"architecture"] = @(un.machine);

    // --- iOS version ---
    d[@"ios_version"] = [UIDevice currentDevice].systemVersion ?: @"Unknown";

    // --- Kernel version ---
    char osrel[128] = {0}; size_t orelsz = sizeof(osrel);
    sysctlbyname("kern.osrelease", osrel, &orelsz, NULL, 0);
    d[@"kernel_version"] = osrel[0] ? @(osrel) : @"Unknown";

    // --- Uptime (seconds since boot) ---
    struct timeval boottime; size_t btsz = sizeof(boottime);
    if (sysctlbyname("kern.boottime", &boottime, &btsz, NULL, 0) == 0) {
        struct timeval now; gettimeofday(&now, NULL);
        d[@"uptime_seconds"] = @(now.tv_sec - boottime.tv_sec);
    } else {
        d[@"uptime_seconds"] = @(0);
    }

    // --- Battery (monitoring enabled on main thread via prepareUIKitCaches) ---
    UIDevice *dev = [UIDevice currentDevice];
    d[@"battery_level"] = @(dev.batteryLevel);
    switch (dev.batteryState) {
        case UIDeviceBatteryStateCharging:  d[@"battery_state"] = @"charging";    break;
        case UIDeviceBatteryStateFull:      d[@"battery_state"] = @"full";        break;
        case UIDeviceBatteryStateUnplugged: d[@"battery_state"] = @"discharging"; break;
        default:                            d[@"battery_state"] = @"unknown";     break;
    }

    // --- Jailbreak markers ---
    static NSArray *jbPaths = nil;
    if (!jbPaths) jbPaths = @[
        @"/bin/bash", @"/etc/apt", @"/var/lib/cydia",
        @"/Applications/Cydia.app", @"/Applications/Sileo.app",
        @"/private/var/stash", @"/usr/lib/libhooker.dylib",
        @"/usr/bin/ssh", @"/usr/sbin/sshd", @"/var/checkra1n.dmg",
    ];
    BOOL jb = NO;
    for (NSString *p in jbPaths) if ([[NSFileManager defaultManager] fileExistsAtPath:p]) { jb = YES; break; }
    d[@"jailbroken"] = @(jb);

    // --- CPU ---
    char cpuBrand[256] = {0}; size_t cpusz = sizeof(cpuBrand);
    sysctlbyname("machdep.cpu.brand_string", cpuBrand, &cpusz, NULL, 0);
    d[@"cpu_brand"] = cpuBrand[0] ? @(cpuBrand) : @"Apple Silicon";
    int ncpu = 0; size_t ncpusz = sizeof(ncpu);
    sysctlbyname("hw.ncpu", &ncpu, &ncpusz, NULL, 0);
    d[@"cpu_count"] = @(ncpu ?: 1);

    // --- RAM ---
    int64_t memsize = 0; size_t msz = sizeof(memsize);
    sysctlbyname("hw.memsize", &memsize, &msz, NULL, 0);
    d[@"ram_bytes"] = @(memsize);

    // --- Storage ---
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
    d[@"storage_total"] = attrs[NSFileSystemSize] ?: @(0LL);
    d[@"storage_free"]  = attrs[NSFileSystemFreeSize] ?: @(0LL);

    // --- Screen (cached from main thread in prepareUIKitCaches) ---
    d[@"screen_width"]  = @(g_screen.width);
    d[@"screen_height"] = @(g_screen.height);
    d[@"screen_scale"]  = @(g_screen.ready ? g_screen.scale : 1.0);

    // --- Network (getifaddrs: en0=WiFi, pdp_ip*=Cellular) ---
    struct ifaddrs *ifalist = NULL;
    NSString *netIP = @"Unknown", *netType = @"none";
    if (getifaddrs(&ifalist) == 0) {
        for (struct ifaddrs *ifa = ifalist; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            char buf[INET_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr, buf, sizeof(buf));
            NSString *ip = @(buf), *name = ifa->ifa_name ? @(ifa->ifa_name) : @"";
            if ([ip isEqualToString:@"127.0.0.1"]) continue;
            if ([name isEqualToString:@"en0"])     { netIP = ip; netType = @"wifi";     break; }
            if ([name hasPrefix:@"pdp_ip"] && [netType isEqualToString:@"none"]) { netIP = ip; netType = @"cellular"; }
        }
        freeifaddrs(ifalist);
    }
    d[@"network_ip"]   = netIP;
    d[@"network_type"] = netType;

    // --- App version ---
    NSString *ver   = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";
    d[@"app_version"] = build.length ? [NSString stringWithFormat:@"%@ (%@)", ver, build] : ver;

    return ns_to_py(d);
}

// get_network_info() -> dict: {"ip": str, "type": "wifi"|"cellular"|"none"}
// Uses getifaddrs — works entirely in ObjC, no Python socket module needed.
// en0 = Wi-Fi, pdp_ip* = cellular. Wi-Fi takes priority.
static PyObject *py_get_network_info(PyObject *self, PyObject *args) {
    struct ifaddrs *ifalist = NULL;
    NSString *ip   = @"Unknown";
    NSString *type = @"none";

    if (getifaddrs(&ifalist) == 0) {
        // Two-pass: collect cellular first, then override with WiFi if found.
        for (struct ifaddrs *ifa = ifalist; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            struct sockaddr_in *sa = (struct sockaddr_in *)ifa->ifa_addr;
            char buf[INET_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET, &sa->sin_addr, buf, sizeof(buf));
            NSString *ifIP   = [NSString stringWithUTF8String:buf];
            NSString *ifName = ifa->ifa_name ? [NSString stringWithUTF8String:ifa->ifa_name] : @"";
            if ([ifIP isEqualToString:@"127.0.0.1"]) continue;
            if ([ifName isEqualToString:@"en0"]) {
                ip = ifIP; type = @"wifi"; break;          // WiFi found — stop
            }
            if ([ifName hasPrefix:@"pdp_ip"] && [type isEqualToString:@"none"]) {
                ip = ifIP; type = @"cellular";             // remember cellular, keep scanning
            }
        }
        freeifaddrs(ifalist);
    }

    NSDictionary *result = @{@"ip": ip, @"type": type};
    return ns_to_py(result);
}

// get_network_type() -> str: "wifi" | "cellular" | "none"
// Uses SCNetworkReachability + kSCNetworkReachabilityFlagsIsWWAN to distinguish WiFi vs Cellular.
static PyObject *py_get_network_type(PyObject *self, PyObject *args) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len    = sizeof(addr);
    addr.sin_family = AF_INET;

    SCNetworkReachabilityRef reach = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&addr);
    if (!reach) Py_RETURN_NONE;

    SCNetworkReachabilityFlags flags = 0;
    Boolean ok = SCNetworkReachabilityGetFlags(reach, &flags);
    CFRelease(reach);

    if (!ok) return PyUnicode_FromString("none");

    BOOL reachable   = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
    BOOL needsConn   = (flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0;
    BOOL isWWAN      = (flags & kSCNetworkReachabilityFlagsIsWWAN) != 0;

    if (!reachable || needsConn) return PyUnicode_FromString("none");
    return PyUnicode_FromString(isWWAN ? "cellular" : "wifi");
}

// ---------------------------------------------------------------------------
// Overlay / gesture / projectile / audio / plugin-entry (BRIDGE_VERSION 4)
// ---------------------------------------------------------------------------

// create_overlay(alpha=0.0) → int overlay_id
// Creates a UIWindow at UIWindowLevelAlert+100 — above ALL Telegram windows.
// Telegram uses a multi-window architecture; adding a UIView to the key window
// puts it below the actual app-UI window, so touches bypass it.
static PyObject *py_create_overlay(PyObject *self, PyObject *args) {
    double alpha = 0.0;
    if (!PyArg_ParseTuple(args, "|d", &alpha)) return NULL;

    __block int32_t oid = -1;
    void (^blk)(void) = ^{
        if (!g_overlays) {
            g_overlays       = [NSMutableDictionary new];
            g_overlayTargets = [NSMutableDictionary new];
            g_overlayWindows = [NSMutableDictionary new];
        }

        // Find the foreground UIWindowScene so the overlay appears in the correct screen.
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s;
                break;
            }
        }

        UIWindow *overlayWin;
        if (scene) {
            overlayWin = [[UIWindow alloc] initWithWindowScene:scene];
        } else {
            overlayWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
        overlayWin.frame            = [UIScreen mainScreen].bounds;
        overlayWin.windowLevel      = UIWindowLevelAlert + 100.0f;
        overlayWin.backgroundColor  = [UIColor colorWithWhite:0 alpha:(CGFloat)alpha];
        overlayWin.userInteractionEnabled = YES;

        EGOverlayViewController *rootVC = [[EGOverlayViewController alloc] init];
        overlayWin.rootViewController = rootVC;
        overlayWin.hidden = NO;   // make visible WITHOUT stealing key-window status

        oid = g_nextOverlayId++;
        g_overlays[@(oid)]       = rootVC.view;  // gesture recognizers & projectile labels go here
        g_overlayTargets[@(oid)] = [NSMutableArray new];
        g_overlayWindows[@(oid)] = overlayWin;   // retained here; released on dismiss
        EGPluginDebugLog_appendCStr("Overlay",
            [[NSString stringWithFormat:@"create_overlay id=%d level=%.0f",
              oid, (double)overlayWin.windowLevel] UTF8String]);
    };
    if ([NSThread isMainThread]) blk();
    else dispatch_sync(dispatch_get_main_queue(), blk);
    return PyLong_FromLong(oid);
}

// dismiss_overlay(overlay_id) → None
static PyObject *py_dismiss_overlay(PyObject *self, PyObject *args) {
    int oid = 0;
    if (!PyArg_ParseTuple(args, "i", &oid)) return NULL;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win   = g_overlayWindows[@(oid)];
        UIView *overlay = g_overlays[@(oid)];
        UIView *target  = win ?: overlay;
        if (target) {
            [UIView animateWithDuration:0.2 animations:^{ target.alpha = 0; }
                            completion:^(BOOL _) {
                win.hidden = YES;
                [overlay removeFromSuperview];
                [g_overlays removeObjectForKey:@(oid)];
                [g_overlayWindows removeObjectForKey:@(oid)];
            }];
        }
        [g_overlayTargets removeObjectForKey:@(oid)];
        // Purge views owned by this overlay.
        if (g_viewOwners) {
            NSMutableArray<NSNumber *> *dead = [NSMutableArray new];
            for (NSNumber *vid in g_viewOwners) {
                if ([g_viewOwners[vid] isEqual:@(oid)]) [dead addObject:vid];
            }
            for (NSNumber *vid in dead) {
                [g_views removeObjectForKey:vid];
                [g_viewOwners removeObjectForKey:vid];
            }
        }
        if (g_splatCache && g_overlays.count == 0) {
            [g_splatCache removeAllObjects];
        }
        EGPluginDebugLog_appendCStr("Overlay",
            [[NSString stringWithFormat:@"dismiss_overlay id=%d", oid] UTF8String]);
    });
    Py_RETURN_NONE;
}

// add_tap_gesture(overlay_id, tap_count, callback) → None
static PyObject *py_add_tap_gesture(PyObject *self, PyObject *args) {
    int oid = 0, tapCount = 1;
    PyObject *cb = Py_None;
    if (!PyArg_ParseTuple(args, "iiO", &oid, &tapCount, &cb)) return NULL;
    if (!PyCallable_Check(cb)) {
        PyErr_SetString(PyExc_TypeError, "callback must be callable"); return NULL;
    }
    EGGestureTarget *target = [[EGGestureTarget alloc] initWithCallback:cb longPress:NO];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *overlay = g_overlays[@(oid)];
        if (!overlay) {
            EGPluginDebugLog_appendCStr("Overlay", "add_tap_gesture: overlay not found");
            return;
        }
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:target action:@selector(handleGesture:)];
        tap.numberOfTapsRequired = (NSUInteger)MAX(1, tapCount);
        [overlay addGestureRecognizer:tap];
        [g_overlayTargets[@(oid)] addObject:target];
        EGPluginDebugLog_appendCStr("Overlay",
            [[NSString stringWithFormat:@"add_tap_gesture id=%d taps=%d", oid, tapCount] UTF8String]);
        // Make lower-count taps require higher-count taps to fail (so double-tap takes priority)
        for (UIGestureRecognizer *gr in overlay.gestureRecognizers) {
            if (gr == tap || ![gr isKindOfClass:[UITapGestureRecognizer class]]) continue;
            UITapGestureRecognizer *other = (UITapGestureRecognizer *)gr;
            if (other.numberOfTapsRequired > tap.numberOfTapsRequired)
                [tap requireGestureRecognizerToFail:other];
            else if (tap.numberOfTapsRequired > other.numberOfTapsRequired)
                [other requireGestureRecognizerToFail:tap];
        }
    });
    Py_RETURN_NONE;
}

// add_longpress_gesture(overlay_id, callback, min_duration=0.4) → None
// callback(started: bool) — True on began, False on ended/cancelled
static PyObject *py_add_longpress_gesture(PyObject *self, PyObject *args) {
    int oid = 0;
    PyObject *cb = Py_None;
    double minDur = 0.4;
    if (!PyArg_ParseTuple(args, "iO|d", &oid, &cb, &minDur)) return NULL;
    if (!PyCallable_Check(cb)) {
        PyErr_SetString(PyExc_TypeError, "callback must be callable"); return NULL;
    }
    EGGestureTarget *target = [[EGGestureTarget alloc] initWithCallback:cb longPress:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *overlay = g_overlays[@(oid)];
        if (!overlay) return;
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:target action:@selector(handleGesture:)];
        lp.minimumPressDuration = (NSTimeInterval)minDur;
        [overlay addGestureRecognizer:lp];
        [g_overlayTargets[@(oid)] addObject:target];
    });
    Py_RETURN_NONE;
}

// show_projectile(overlay_id, emoji, x, y, size, vx, vy, duration=1.4) → None
// Launches an emoji label from (x,y) with velocity (vx,vy) along a parabolic arc.
static PyObject *py_show_projectile(PyObject *self, PyObject *args) {
    int oid = 0;
    const char *emoji_c = "●";
    double x0=0, y0=0, size=50, vx=0, vy=-500, dur=1.4;
    if (!PyArg_ParseTuple(args, "isddddd|d", &oid, &emoji_c, &x0, &y0, &size, &vx, &vy, &dur))
        return NULL;

    NSString *emoji    = [NSString stringWithUTF8String:emoji_c];
    CGFloat   cx       = (CGFloat)x0, cy = (CGFloat)y0, sz = (CGFloat)size;
    CGFloat   cvx      = (CGFloat)vx, cvy = (CGFloat)vy;
    CFTimeInterval dur2 = (CFTimeInterval)dur;
    CGFloat   gravity  = 520.0f; // pt/s²

    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *overlay = g_overlays[@(oid)];
        if (!overlay) {
            EGPluginDebugLog_appendCStr("Overlay", "show_projectile: overlay not found");
            return;
        }

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(cx - sz/2, cy - sz/2, sz, sz)];
        lbl.text              = emoji;
        lbl.font              = [UIFont systemFontOfSize:sz * 0.85f];
        lbl.textAlignment     = NSTextAlignmentCenter;
        lbl.userInteractionEnabled = NO;
        [overlay addSubview:lbl];

        // Build parabolic position key-values (layer position = view center)
        NSInteger steps = 32;
        NSMutableArray<NSValue *> *positions = [NSMutableArray arrayWithCapacity:(NSUInteger)(steps+1)];
        NSMutableArray<NSNumber *> *angles   = [NSMutableArray arrayWithCapacity:(NSUInteger)(steps+1)];
        for (NSInteger i = 0; i <= steps; i++) {
            double t = dur2 * i / steps;
            CGFloat px = cx + cvx * (CGFloat)t;
            CGFloat py = cy + cvy * (CGFloat)t + 0.5f * gravity * (CGFloat)(t * t);
            [positions addObject:[NSValue valueWithCGPoint:CGPointMake(px, py)]];
            [angles    addObject:@(M_PI * 3.0 * (cvx >= 0 ? 1.0 : -1.0) * i / steps)];
        }

        CAKeyframeAnimation *posAnim = [CAKeyframeAnimation animationWithKeyPath:@"position"];
        posAnim.values          = positions;
        posAnim.calculationMode = kCAAnimationLinear;
        posAnim.duration        = dur2;

        CAKeyframeAnimation *rotAnim = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
        rotAnim.values   = angles;
        rotAnim.duration = dur2;

        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.animations          = @[posAnim, rotAnim];
        group.duration            = dur2;
        group.fillMode            = kCAFillModeForwards;
        group.removedOnCompletion = NO;

        [lbl.layer addAnimation:group forKey:@"eg_proj"];

        // Fade out before animation ends, then remove
        CGFloat fadeDelay = (CGFloat)MAX(0.0, dur - 0.2);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fadeDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.2 animations:^{ lbl.alpha = 0; }
                            completion:^(BOOL _) {
                [lbl.layer removeAnimationForKey:@"eg_proj"];
                [lbl removeFromSuperview];
            }];
        });
    });
    Py_RETURN_NONE;
}

// load_audio(path) → int audio_id  (−1 on error)
static PyObject *py_load_audio(PyObject *self, PyObject *args) {
    const char *path_c = "";
    if (!PyArg_ParseTuple(args, "s", &path_c)) return NULL;
    NSString *path = [NSString stringWithUTF8String:path_c];

    __block int32_t aid = -1;
    void (^blk)(void) = ^{
        if (!g_audioPlayers) g_audioPlayers = [NSMutableDictionary new];
        NSURL *url = [NSURL fileURLWithPath:path];
        NSError *err = nil;
        AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
        if (!player || err) return;
        [player prepareToPlay];
        aid = g_nextAudioId++;
        g_audioPlayers[@(aid)] = player;
    };
    if ([NSThread isMainThread]) blk();
    else dispatch_sync(dispatch_get_main_queue(), blk);
    return PyLong_FromLong(aid);
}

// play_audio(audio_id, volume=1.0, rate=1.0) → None
static PyObject *py_play_audio(PyObject *self, PyObject *args) {
    int aid = 0;
    double volume = 1.0, rate = 1.0;
    if (!PyArg_ParseTuple(args, "i|dd", &aid, &volume, &rate)) return NULL;
    dispatch_async(dispatch_get_main_queue(), ^{
        AVAudioPlayer *p = g_audioPlayers[@(aid)];
        if (!p) return;
        p.volume      = (float)volume;
        p.enableRate  = YES;
        p.rate        = (float)rate;
        [p stop];
        p.currentTime = 0;
        [p play];
    });
    Py_RETURN_NONE;
}

// register_plugin_entry(plugin_id, entry_type, item_id, title) → None
// entry_type: "chatlist" | "context_menu" | "profile"
static PyObject *py_register_plugin_entry(PyObject *self, PyObject *args) {
    const char *pid_c=NULL, *etype_c=NULL, *iid_c=NULL, *title_c=NULL;
    if (!PyArg_ParseTuple(args, "ssss", &pid_c, &etype_c, &iid_c, &title_c)) return NULL;
    NSString *pluginId  = [NSString stringWithUTF8String:pid_c];
    NSString *entryType = [NSString stringWithUTF8String:etype_c];
    NSString *itemId    = [NSString stringWithUTF8String:iid_c];
    NSString *title     = [NSString stringWithUTF8String:title_c];
    if (g_registerMenuItemHandler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            g_registerMenuItemHandler(pluginId, entryType, itemId, title);
        });
    }
    Py_RETURN_NONE;
}

// ---------------------------------------------------------------------------
// BRIDGE_VERSION 5 — show_splat, add_touch_handler
// (download_file removed in v6 — plugins use urllib.request directly)
// BRIDGE_VERSION 7 — preload_splat; show_splat now uses background decode + cache
// ---------------------------------------------------------------------------

// GIF/PNG/JPG decoder: returns animated UIImage (multi-frame) or static UIImage.
// May be called on any thread.
static UIImage *eg_animated_image_from_data(NSData *data) {
    if (!data || data.length == 0) return nil;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, nil);
    if (!src) {
        EGPluginDebugLog_appendCStr("Splat", "decode: CGImageSourceCreateWithData failed");
        return nil;
    }
    size_t count = CGImageSourceGetCount(src);
    if (count == 0) {
        CFStringRef uti = CGImageSourceGetType(src);
        EGPluginDebugLog_appendCStr("Splat",
            [[NSString stringWithFormat:@"decode: CGImageSourceGetCount==0 uti=%@ len=%lu",
              uti ? (__bridge NSString *)uti : @"?", (unsigned long)data.length] UTF8String]);
        CFRelease(src);
        return nil;
    }
    if (count == 1) {
        CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, nil);
        CFRelease(src);
        if (!cg) return nil;
        UIImage *img = [UIImage imageWithCGImage:cg];
        CGImageRelease(cg);
        return img;
    }
    NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:count];
    double totalDuration = 0.0;
    for (size_t i = 0; i < count; i++) {
        CGImageRef cg = CGImageSourceCreateImageAtIndex(src, i, nil);
        if (!cg) continue;
        [frames addObject:[UIImage imageWithCGImage:cg]];
        CGImageRelease(cg);
        double delay = 0.1;
        CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, i, nil);
        if (props) {
            CFDictionaryRef gd = CFDictionaryGetValue(props, kCGImagePropertyGIFDictionary);
            if (gd) {
                CFNumberRef n = CFDictionaryGetValue(gd, kCGImagePropertyGIFUnclampedDelayTime);
                if (!n) n = CFDictionaryGetValue(gd, kCGImagePropertyGIFDelayTime);
                if (n) CFNumberGetValue(n, kCFNumberDoubleType, &delay);
                if (delay < 0.011) delay = 0.1;
            }
            CFRelease(props);
        }
        totalDuration += delay;
    }
    CFRelease(src);
    if (frames.count == 0) return nil;
    return [UIImage animatedImageWithImages:frames duration:totalDuration];
}

// Attach one splat image-view to an overlay and animate it. Must be called on main thread.
// repeat_count: passed to UIImageView.animationRepeatCount (0 = loop forever, N = play N times).
// remove_after:  0.0 = auto (img.duration+0.15s or 1.5s for static), -1.0 = never auto-remove.
static void eg_spawn_splat_view(UIImage *img, UIView *overlay,
                                CGFloat cx, CGFloat cy, CGFloat size,
                                NSInteger repeatCount, double removeAfter) {
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.frame = CGRectMake(cx - size/2.0f, cy - size/2.0f, size, size);
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = NO;
    iv.alpha = 0.0f;
    // initWithImage: does NOT auto-start animation when the UIWindow is not keyWindow.
    if (img.images.count > 1) {
        iv.animationImages      = img.images;
        iv.animationDuration    = img.duration;
        iv.animationRepeatCount = repeatCount;
        [iv startAnimating];
    }
    [overlay addSubview:iv];
    [UIView animateWithDuration:0.25 animations:^{ iv.alpha = 1.0f; }];
    if (removeAfter < 0) return; // plugin requested no auto-removal
    double dur = (removeAfter > 0) ? removeAfter
               : ((img.images.count > 1 && img.duration > 0) ? img.duration + 0.15 : 1.5);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dur * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.2 animations:^{ iv.alpha = 0.0f; }
                        completion:^(BOOL _) { [iv removeFromSuperview]; }];
    });
}

// show_splat(overlay_id, image_path, x, y, size[, repeat_count[, remove_after]]) → None
// repeat_count (int, default 0): 0=loop forever, N=play N times.
// remove_after (float, default 0.0): 0=auto (animation duration+0.15s), -1=never remove.
// Cache-hit path: instant (main thread only). Cache-miss: decodes on background, stores in cache, then spawns.
static PyObject *py_show_splat(PyObject *self, PyObject *args) {
    int oid = 0;
    const char *path_c = "";
    double x = 0, y = 0, sz = 200.0;
    int repeat_count = 0;
    double remove_after = 0.0;
    if (!PyArg_ParseTuple(args, "isddd|id", &oid, &path_c, &x, &y, &sz, &repeat_count, &remove_after)) return NULL;
    NSString *path = [NSString stringWithUTF8String:path_c];
    CGFloat cx = (CGFloat)x, cy = (CGFloat)y, size = (CGFloat)sz;
    NSInteger rc = (NSInteger)repeat_count;
    double ra = remove_after;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *overlay = g_overlays[@(oid)];
        if (!overlay) {
            EGPluginDebugLog_appendCStr("Splat", "show_splat: overlay not found");
            return;
        }
        if (!g_splatCache) g_splatCache = [NSMutableDictionary new];
        UIImage *cached = g_splatCache[path];
        if (cached) {
            eg_spawn_splat_view(cached, overlay, cx, cy, size, rc, ra);
            return;
        }
        // Cache miss: decode on background queue to avoid blocking the main thread.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (!data || data.length == 0) {
                EGPluginDebugLog_appendCStr("Splat", "show_splat: file not found or empty");
                return;
            }
            UIImage *img = eg_animated_image_from_data(data);
            if (!img) {
                EGPluginDebugLog_appendCStr("Splat", "show_splat: could not decode image");
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                UIView *ov = g_overlays[@(oid)];
                if (!ov) return;
                if (!g_splatCache) g_splatCache = [NSMutableDictionary new];
                g_splatCache[path] = img;
                eg_spawn_splat_view(img, ov, cx, cy, size, rc, ra);
            });
        });
    });
    Py_RETURN_NONE;
}

// preload_splat(image_path) → None
// Decode and cache the splat image in the background without displaying it.
// Call after create_overlay so the very first tap finds the cache already warm.
static PyObject *py_preload_splat(PyObject *self, PyObject *args) {
    const char *path_c = "";
    if (!PyArg_ParseTuple(args, "s", &path_c)) return NULL;
    NSString *path = [NSString stringWithUTF8String:path_c];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Re-check on main thread to avoid racing with another preload.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!g_splatCache) g_splatCache = [NSMutableDictionary new];
            if (g_splatCache[path]) return; // already cached
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSData *data = [NSData dataWithContentsOfFile:path];
                if (!data || data.length == 0) return;
                UIImage *img = eg_animated_image_from_data(data);
                if (!img) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!g_splatCache) g_splatCache = [NSMutableDictionary new];
                    g_splatCache[path] = img;
                    EGPluginDebugLog_appendCStr("Splat", "preload_splat: cached");
                });
            });
        });
    });
    Py_RETURN_NONE;
}

// BRIDGE_VERSION 9 — add_image_view, remove_view
// ---------------------------------------------------------------------------

// add_image_view(overlay_id, image_path, x, y, size[, repeat_count]) → view_id
// Creates a UIImageView centred at (x,y), starts animation, fades in 0.25s, returns a stable id.
// Plugin is responsible for calling remove_view when done (no auto-removal).
// repeat_count: 0 = loop forever (default), N = play N times.
// Image must be preloaded via preload_splat; on cache miss a background decode is attempted.
static PyObject *py_add_image_view(PyObject *self, PyObject *args) {
    int oid = 0; const char *path_c = ""; double x = 0, y = 0, sz = 200.0;
    int repeat_count = 0;
    if (!PyArg_ParseTuple(args, "isddd|i", &oid, &path_c, &x, &y, &sz, &repeat_count)) return NULL;
    // Pre-allocate view_id so we can return it immediately (view will appear shortly).
    int32_t vid = OSAtomicIncrement32(&g_nextViewId);
    NSString *path = [NSString stringWithUTF8String:path_c];
    CGFloat cx = (CGFloat)x, cy = (CGFloat)y, size = (CGFloat)sz;
    NSInteger rc = (NSInteger)repeat_count;

    void (^spawnBlock)(UIImage *, UIView *) = ^(UIImage *img, UIView *overlay) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        iv.frame = CGRectMake(cx - size/2.0f, cy - size/2.0f, size, size);
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.userInteractionEnabled = NO;
        iv.alpha = 0.0f;
        if (img.images.count > 1) {
            iv.animationImages      = img.images;
            iv.animationDuration    = img.duration;
            iv.animationRepeatCount = rc;
            [iv startAnimating];
        }
        [overlay addSubview:iv];
        [UIView animateWithDuration:0.25 animations:^{ iv.alpha = 1.0f; }];
        if (!g_views) g_views = [NSMutableDictionary new];
        if (!g_viewOwners) g_viewOwners = [NSMutableDictionary new];
        g_views[@(vid)]      = iv;
        g_viewOwners[@(vid)] = @(oid);
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *overlay = g_overlays[@(oid)];
        if (!overlay) return;
        if (!g_splatCache) g_splatCache = [NSMutableDictionary new];
        UIImage *cached = g_splatCache[path];
        if (cached) {
            spawnBlock(cached, overlay);
        } else {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                NSData *data = [NSData dataWithContentsOfFile:path];
                if (!data || data.length == 0) return;
                UIImage *img = eg_animated_image_from_data(data);
                if (!img) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIView *ov = g_overlays[@(oid)];
                    if (!ov) return;
                    if (!g_splatCache) g_splatCache = [NSMutableDictionary new];
                    g_splatCache[path] = img;
                    spawnBlock(img, ov);
                });
            });
        }
    });
    return PyLong_FromLong((long)vid);
}

// remove_view(view_id[, fade_duration]) → None
// Fades out the view and removes it. fade_duration defaults to 0.2s; pass 0 for instant removal.
static PyObject *py_remove_view(PyObject *self, PyObject *args) {
    int vid = 0;
    double fade = 0.2;
    if (!PyArg_ParseTuple(args, "i|d", &vid, &fade)) return NULL;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *v = g_views[@(vid)];
        if (!v) return;
        [g_views removeObjectForKey:@(vid)];
        [g_viewOwners removeObjectForKey:@(vid)];
        NSTimeInterval dur = MAX(0.0, fade);
        [UIView animateWithDuration:dur animations:^{ v.alpha = 0.0f; }
                        completion:^(BOOL _) { [v removeFromSuperview]; }];
    });
    Py_RETURN_NONE;
}

// add_touch_handler(overlay_id, callback) → None
// callback(action: int, x: float, y: float) — action: 0=down, 1=up/cancel, 2=move
static PyObject *py_add_touch_handler(PyObject *self, PyObject *args) {
    int oid = 0;
    PyObject *cb = Py_None;
    if (!PyArg_ParseTuple(args, "iO", &oid, &cb)) return NULL;
    if (!PyCallable_Check(cb)) {
        PyErr_SetString(PyExc_TypeError, "callback must be callable"); return NULL;
    }
    Py_INCREF(cb);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *overlay = g_overlays[@(oid)];
        if (!overlay || ![overlay isKindOfClass:[EGOverlayContentView class]]) {
            PyGILState_STATE gs = PyGILState_Ensure();
            Py_DECREF(cb);
            PyGILState_Release(gs);
            EGPluginDebugLog_appendCStr("Overlay", "add_touch_handler: overlay not found or wrong type");
            return;
        }
        [(EGOverlayContentView *)overlay setTouchCallback:cb];
        PyGILState_STATE gs = PyGILState_Ensure();
        Py_DECREF(cb);  // EGOverlayContentView now owns its own reference
        PyGILState_Release(gs);
        EGPluginDebugLog_appendCStr("Overlay",
            [[NSString stringWithFormat:@"add_touch_handler id=%d", oid] UTF8String]);
    });
    Py_RETURN_NONE;
}

static PyMethodDef ios_bridge_methods[] = {
    {"log_text",           py_log_text,           METH_VARARGS, "log_text(msg, tag='Plugin')"},
    {"add_tl_hook",        py_add_tl_hook,        METH_VARARGS, "add_tl_hook(tl_type, callback)"},
    {"has_hook",           py_has_hook,           METH_VARARGS, "has_hook(tl_type) -> bool"},
    {"run_on_main_thread", py_run_on_main_thread, METH_VARARGS, "run_on_main_thread(fn)"},
    {"show_alert",         py_show_alert,         METH_VARARGS, "show_alert(title, message, button='OK')"},
    {"show_action_sheet",  py_show_action_sheet,  METH_VARARGS, "show_action_sheet(title, message, options, callback)"},
    {"show_dialog",        py_show_dialog,        METH_VARARGS, "show_dialog(spec) -> handle"},
    {"update_dialog",      py_update_dialog,      METH_VARARGS, "update_dialog(handle, view_spec)"},
    {"dismiss_dialog",     py_dismiss_dialog,     METH_VARARGS, "dismiss_dialog(handle)"},
    {"invoke_view_callback", py_invoke_view_callback, METH_VARARGS, "invoke_view_callback(handle)"},
    {"show_toast",         py_show_toast,         METH_VARARGS, "show_toast(message, duration=2.0)"},
    {"copy_to_clipboard",  py_copy_to_clipboard,  METH_VARARGS, "copy_to_clipboard(text)"},
    {"read_clipboard",     py_read_clipboard,     METH_NOARGS,  "read_clipboard() -> str"},
    {"get_screen_info",    py_get_screen_info,    METH_NOARGS,  "get_screen_info() -> dict"},
    {"open_url",           py_open_url,           METH_VARARGS, "open_url(url)"},
    {"haptic_feedback",    py_haptic_feedback,    METH_VARARGS, "haptic_feedback(style='medium')"},
    {"get_locale_language",py_get_locale_language,METH_NOARGS,  "get_locale_language() -> str"},
    {"get_string",         py_get_string,         METH_VARARGS, "get_string(key, default='') -> str"},
    {"get_plugin_setting", py_get_plugin_setting, METH_VARARGS, "get_plugin_setting(plugin_id, key, default=None) -> Any"},
    {"set_plugin_setting", py_set_plugin_setting, METH_VARARGS, "set_plugin_setting(plugin_id, key, value)"},
    {"get_plugin_data_dir",py_get_plugin_data_dir,METH_VARARGS, "get_plugin_data_dir(plugin_id) -> str"},
    {"get_account_id",       py_get_account_id,       METH_NOARGS,  "get_account_id() -> int"},
    {"get_user_id",          py_get_user_id,          METH_NOARGS,  "get_user_id() -> int"},
    {"get_connection_state", py_get_connection_state, METH_NOARGS,  "get_connection_state() -> str"},
    {"show_bulletin",        py_show_bulletin,        METH_VARARGS, "show_bulletin(title, text='', icon='')"},
    {"add_view_label",       py_add_view_label,       METH_VARARGS, "add_view_label(view_ptr, tag, text, font_size, r, g, b, a) — add/update UILabel on UIView or ASDisplayNode"},
    {"get_theme_color",      py_get_theme_color,      METH_VARARGS, "get_theme_color(key) -> (r,g,b,a) — key: primaryText|secondaryText|accent|background|separator"},
    {"measure_text_width",   py_measure_text_width,   METH_VARARGS, "measure_text_width(text, font_size) -> float"},
    {"add_method_hook",      py_add_method_hook,      METH_VARARGS, "add_method_hook(class_name, method_name, before=None, after=None) — callbacks receive (view_ptr: int)"},
    {"plugin_has_settings",  py_plugin_has_settings,  METH_VARARGS, "plugin_has_settings(plugin_id) -> bool"},
    {"get_plugin_settings",  py_get_plugin_settings,  METH_VARARGS, "get_plugin_settings(plugin_id) -> dict|None"},
    {"show_plugin_settings", py_show_plugin_settings, METH_VARARGS, "show_plugin_settings(plugin_id)"},
    {"suppress_entity_type",    py_suppress_entity_type,    METH_VARARGS, "suppress_entity_type(type_name, suppress=True)"},
    {"suppress_attribute_type", py_suppress_attribute_type, METH_VARARGS, "suppress_attribute_type(type_name, suppress=True)"},
    {"send_message",            py_send_message,            METH_VARARGS, "send_message(peer_id, text) — send a Telegram message as the current user"},
    {"send_reaction",           py_send_reaction,           METH_VARARGS, "send_reaction(peer_id, msg_id, emoticon) — add a reaction to a message"},
    {"get_device_info",         py_get_device_info,         METH_NOARGS,  "get_device_info() -> dict with battery_level, battery_state, app_version"},
    {"get_system_info",         py_get_system_info,         METH_NOARGS,  "get_system_info() -> dict with all hw/os/network info"},
    {"get_network_type",        py_get_network_type,        METH_NOARGS,  "get_network_type() -> 'wifi' | 'cellular' | 'none'"},
    {"get_network_info",        py_get_network_info,        METH_NOARGS,  "get_network_info() -> {'ip': str, 'type': str}"},
    // BRIDGE_VERSION 4 — overlay / gesture / projectile / audio / plugin entry
    {"create_overlay",          py_create_overlay,          METH_VARARGS, "create_overlay(alpha=0.0) -> overlay_id — transparent interactive UIView over key window"},
    {"dismiss_overlay",         py_dismiss_overlay,         METH_VARARGS, "dismiss_overlay(overlay_id) — remove overlay with fade"},
    {"add_tap_gesture",         py_add_tap_gesture,         METH_VARARGS, "add_tap_gesture(overlay_id, tap_count, callback) — tap_count=1 or 2"},
    {"add_longpress_gesture",   py_add_longpress_gesture,   METH_VARARGS, "add_longpress_gesture(overlay_id, callback, min_duration=0.4) — callback(started: bool)"},
    {"show_projectile",         py_show_projectile,         METH_VARARGS, "show_projectile(overlay_id, emoji, x, y, size, vx, vy, duration=1.4)"},
    {"load_audio",              py_load_audio,              METH_VARARGS, "load_audio(path) -> audio_id or -1"},
    {"play_audio",              py_play_audio,              METH_VARARGS, "play_audio(audio_id, volume=1.0, rate=1.0)"},
    {"register_plugin_entry",   py_register_plugin_entry,   METH_VARARGS, "register_plugin_entry(plugin_id, entry_type, item_id, title)"},
    // BRIDGE_VERSION 5 — show_splat, add_touch_handler
    {"show_splat",              py_show_splat,              METH_VARARGS, "show_splat(overlay_id, image_path, x, y, size) — show GIF/PNG at position, fade-in, auto-remove"},
    {"add_touch_handler",       py_add_touch_handler,       METH_VARARGS, "add_touch_handler(overlay_id, callback) — callback(action:int, x:float, y:float): 0=down, 1=up/cancel, 2=move"},
    // BRIDGE_VERSION 6 — log
    {"log",                     py_log,                     METH_VARARGS, "log(tag, message) — write to EGPluginDebugLog"},
    // BRIDGE_VERSION 7 — preload_splat; show_splat now uses background decode + image cache
    {"preload_splat",           py_preload_splat,           METH_VARARGS, "preload_splat(image_path) — decode and cache splat image without displaying it"},
    // BRIDGE_VERSION 8 — show_splat gains optional repeat_count and remove_after params
    // BRIDGE_VERSION 9 — add_image_view, remove_view (low-level; plugin owns removal timing)
    {"add_image_view",          py_add_image_view,          METH_VARARGS, "add_image_view(overlay_id, path, x, y, size[, repeat_count=0]) -> view_id — create animated image view, no auto-removal"},
    {"remove_view",             py_remove_view,             METH_VARARGS, "remove_view(view_id[, fade=0.2]) — fade out and remove a view created by add_image_view"},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef ios_bridge_module = {
    PyModuleDef_HEAD_INIT, "_ios_bridge", NULL, -1, ios_bridge_methods
};

PyMODINIT_FUNC PyInit__ios_bridge(void) {
    PyObject *m = PyModule_Create(&ios_bridge_module);
    if (!m) return NULL;
    // Expose the global hook dict so Python code can inspect it if needed
    if (g_tl_hooks) PyModule_AddObject(m, "_hooks", g_tl_hooks);
    // Integer version so plugins can guard against missing functions.
    // Bump when new bridge functions are added.
    //   1 — initial release
    //   2 — added get_system_info, get_network_info, send_message
    //   3 — add_method_hook callbacks now receive view_ptr; add_view_label, get_theme_color, measure_text_width
    //   4 — create_overlay, dismiss_overlay, add_tap_gesture, add_longpress_gesture,
    //         show_projectile, load_audio, play_audio, register_plugin_entry
    //   5 — show_splat, add_touch_handler; EGOverlayContentView raw touch
    //   6 — download_file removed; plugins use urllib.request directly
    //   7 — preload_splat; show_splat background decode + cache; dismiss_overlay evicts cache
    //   8 — show_splat gains optional repeat_count and remove_after params
    //   9 — add_image_view, remove_view: plugin-controlled view lifecycle
    PyModule_AddIntConstant(m, "BRIDGE_VERSION", 9);
    return m;
}

// ---------------------------------------------------------------------------
// Helpers: NSObject ↔ PyObject conversion
// ---------------------------------------------------------------------------

static PyObject *ns_to_py(id obj) {
    if (!obj || obj == [NSNull null]) Py_RETURN_NONE;
    if ([obj isKindOfClass:[NSString class]]) {
        return PyUnicode_FromString([(NSString *)obj UTF8String]);
    }
    if ([obj isKindOfClass:[NSNumber class]]) {
        NSNumber *n = obj;
        if (strcmp(n.objCType, @encode(BOOL)) == 0 ||
            strcmp(n.objCType, @encode(bool)) == 0) {
            return PyBool_FromLong(n.boolValue ? 1 : 0);
        }
        // Check if it's a float
        CFNumberType type = CFNumberGetType((CFNumberRef)n);
        if (type == kCFNumberFloat32Type || type == kCFNumberFloat64Type ||
            type == kCFNumberDoubleType  || type == kCFNumberFloatType) {
            return PyFloat_FromDouble(n.doubleValue);
        }
        return PyLong_FromLongLong(n.longLongValue);
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *arr = obj;
        PyObject *list = PyList_New((Py_ssize_t)arr.count);
        for (NSUInteger i = 0; i < arr.count; i++) {
            PyObject *item = ns_to_py(arr[i]);
            PyList_SET_ITEM(list, (Py_ssize_t)i, item);
        }
        return list;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;
        PyObject *py_dict = PyDict_New();
        for (id key in dict) {
            PyObject *py_key = ns_to_py(key);
            PyObject *py_val = ns_to_py(dict[key]);
            PyDict_SetItem(py_dict, py_key, py_val);
            Py_DECREF(py_key);
            Py_DECREF(py_val);
        }
        return py_dict;
    }
    // Fallback: repr string
    return PyUnicode_FromString([[obj description] UTF8String]);
}

static id py_to_ns(PyObject *obj) {
    if (!obj || obj == Py_None) return [NSNull null];
    if (PyBool_Check(obj)) return @((BOOL)(obj == Py_True));
    if (PyLong_Check(obj)) return @(PyLong_AsLongLong(obj));
    if (PyFloat_Check(obj)) return @(PyFloat_AsDouble(obj));
    if (PyUnicode_Check(obj)) {
        const char *s = PyUnicode_AsUTF8(obj);
        return s ? [NSString stringWithUTF8String:s] : @"";
    }
    if (PyList_Check(obj) || PyTuple_Check(obj)) {
        Py_ssize_t n = PySequence_Size(obj);
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
        for (Py_ssize_t i = 0; i < n; i++) {
            PyObject *item = PySequence_GetItem(obj, i);
            [arr addObject:py_to_ns(item)];
            Py_DECREF(item);
        }
        return arr;
    }
    if (PyDict_Check(obj)) {
        PyObject *keys = PyDict_Keys(obj);
        Py_ssize_t n = PyList_Size(keys);
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)n];
        for (Py_ssize_t i = 0; i < n; i++) {
            PyObject *key = PyList_GetItem(keys, i);
            PyObject *val = PyDict_GetItem(obj, key);
            id nsKey = py_to_ns(key);
            id nsVal = py_to_ns(val);
            if (nsKey && nsVal) dict[nsKey] = nsVal;
        }
        Py_DECREF(keys);
        return dict;
    }
    return [[NSString alloc] initWithFormat:@"<PyObj:%s>",
            Py_TYPE(obj)->tp_name];
}

#endif // EGPLUGIN_HAS_PYTHON

// ---------------------------------------------------------------------------
// EGPythonBridge implementation
// ---------------------------------------------------------------------------

@implementation EGPythonBridge

+ (void (^)(NSString *, BOOL))suppressEntityTypeHandler { return g_suppressEntityTypeHandler; }
+ (void)setSuppressEntityTypeHandler:(void (^)(NSString *, BOOL))b { g_suppressEntityTypeHandler = [b copy]; }

+ (void (^)(NSString *, BOOL))suppressAttributeTypeHandler { return g_suppressAttributeTypeHandler; }
+ (void)setSuppressAttributeTypeHandler:(void (^)(NSString *, BOOL))b { g_suppressAttributeTypeHandler = [b copy]; }

+ (void (^)(long long, NSString *))sendMessageHandler { return g_sendMessageHandler; }
+ (void)setSendMessageHandler:(void (^)(long long, NSString *))b { g_sendMessageHandler = [b copy]; }

+ (void (^)(long long, int32_t, NSString *))sendReactionHandler { return g_sendReactionHandler; }
+ (void)setSendReactionHandler:(void (^)(long long, int32_t, NSString *))b { g_sendReactionHandler = [b copy]; }

+ (void (^)(NSString *, NSString *, NSString *, NSString *))registerMenuItemHandler { return g_registerMenuItemHandler; }
+ (void)setRegisterMenuItemHandler:(void (^)(NSString *, NSString *, NSString *, NSString *))b { g_registerMenuItemHandler = [b copy]; }

+ (void)prepareUIKitCaches {
    // Must be called on the main thread once before plugins query system info.
    // Enables battery monitoring (UIKit requirement) and caches immutable screen
    // dimensions so bridge functions can run safely from background threads.
    NSAssert([NSThread isMainThread], @"prepareUIKitCaches must be called on main thread");
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    if (!g_screen.ready) {
        CGRect nb    = [UIScreen mainScreen].nativeBounds;
        g_screen.width  = (int)nb.size.width;
        g_screen.height = (int)nb.size.height;
        g_screen.scale  = (double)[UIScreen mainScreen].nativeScale;
        g_screen.ready  = YES;
    }
}

+ (BOOL)initializeWithHome:(NSString *)pythonHome
                   sdkPath:(NSString *)sdkPath
               pluginsPath:(NSString *)pluginsPath
          sitePackagesPath:(NSString *)sitePkgs {
#if EGPLUGIN_HAS_PYTHON
    if (g_initialized) return YES;

    NSAssert([NSThread isMainThread], @"EGPythonBridge: initializeWithHome must be called on the main thread");

    // dispatch_once guarantees exactly-once execution and blocks concurrent callers
    // until the block finishes.  This prevents the PyImport_AppendInittab-after-
    // Py_Initialize fatal error that Python 3.13 raises on double-init attempts.
    static dispatch_once_t s_pythonOnce = 0;
    dispatch_once(&s_pythonOnce, ^{
        // Safety net: detect if Python was somehow started by another path.
        if (Py_IsInitialized()) {
            plugin_log(@"PluginEngine", @"Python already running — adopting existing state");
            PyGILState_STATE s = PyGILState_Ensure();
            if (!g_tl_hooks)       g_tl_hooks       = PyDict_New();
            if (!g_loaded_modules) g_loaded_modules  = PyDict_New();
            PyGILState_Release(s);
            g_initialized = YES;
            return;
        }

        // Register C extension BEFORE any initialization (required by CPython).
        PyImport_AppendInittab("_ios_bridge", &PyInit__ios_bridge);

        // ---------------------------------------------------------------------------
        // Python 3.13: use modern PyConfig API (replaces Py_Initialize() for embeds)
        // ---------------------------------------------------------------------------
        PyPreConfig preconfig;
        PyPreConfig_InitIsolatedConfig(&preconfig);
        preconfig.utf8_mode = 1;

        PyStatus status = Py_PreInitialize(&preconfig);
        if (PyStatus_Exception(status)) {
            plugin_log(@"PluginEngine", @"Py_PreInitialize failed: %s", status.err_msg);
            char buf[512]; snprintf(buf, sizeof(buf), "Py_PreInitialize failed: %s", status.err_msg ?: "(null)");
            EGPluginDebugLog_appendCStr("Runtime", buf);
            return;
        }

        PyConfig config;
        PyConfig_InitIsolatedConfig(&config);
        config.write_bytecode = 0;        // can't modify signed bundle
        config.install_signal_handlers = 1;

        // Set PYTHONHOME (tells CPython where lib/python3.13 lives)
        wchar_t *wHome = Py_DecodeLocale([pythonHome UTF8String], NULL);
        if (wHome) {
            status = PyConfig_SetString(&config, &config.home, wHome);
            PyMem_RawFree(wHome);
            if (PyStatus_Exception(status)) {
                plugin_log(@"PluginEngine", @"PyConfig_SetString(home) failed: %s", status.err_msg);
                char buf[512]; snprintf(buf, sizeof(buf), "PyConfig_SetString(home) failed: %s", status.err_msg ?: "(null)");
                EGPluginDebugLog_appendCStr("Runtime", buf);
                PyConfig_Clear(&config);
                return;
            }
        }

        // Read stdlib paths from config.home before adding extras
        status = PyConfig_Read(&config);
        if (PyStatus_Exception(status)) {
            plugin_log(@"PluginEngine", @"PyConfig_Read failed: %s", status.err_msg);
            char buf[512]; snprintf(buf, sizeof(buf), "PyConfig_Read failed: %s", status.err_msg ?: "(null)");
            EGPluginDebugLog_appendCStr("Runtime", buf);
            PyConfig_Clear(&config);
            return;
        }

        // Do NOT set module_search_paths_set=1 — that would replace the computed stdlib
        // paths with only our extras, causing "Failed to import encodings module".
        // Instead, let CPython compute sys.path from home automatically and append
        // our extra paths to sys.path after initialization via the C API.

        @try {
            status = Py_InitializeFromConfig(&config);
        } @catch (NSException *ex) {
            PyConfig_Clear(&config);
            plugin_log(@"PluginEngine", @"Py_InitializeFromConfig exception: %@", ex.reason);
            EGPluginDebugLog_appendCStr("Runtime", [[NSString stringWithFormat:@"Py_InitializeFromConfig exception: %@", ex.reason] UTF8String]);
            return;
        }
        PyConfig_Clear(&config);

        if (PyStatus_Exception(status)) {
            plugin_log(@"PluginEngine", @"Py_InitializeFromConfig failed: %s", status.err_msg);
            char buf[512]; snprintf(buf, sizeof(buf), "Py_InitializeFromConfig failed: %s", status.err_msg ?: "(null)");
            EGPluginDebugLog_appendCStr("Runtime", buf);
            return;
        }

        // Release GIL (allows GILState acquire/release pattern on all threads)
        PyEval_SaveThread();

        // One-time global state setup + extend sys.path with extra dirs
        PyGILState_STATE state = PyGILState_Ensure();
        g_tl_hooks = PyDict_New();
        g_loaded_modules = PyDict_New();

        // Append SDK, plugins, and site-packages to sys.path now that Python is alive.
        // sdkPath may be a colon-separated list of paths (Swift side joins them).
        PyObject *sysPath = PySys_GetObject("path"); // borrowed ref — never NULL post-init
        if (sysPath) {
            // Prepend PythonExtensions.framework path so its signed .so modules are
            // found before the unsigned Caches/lib-dynload copies. On unsigned builds
            // dlopen from Caches fails; on signed builds (Feather/SideStore/LiveContainer)
            // the framework copies are signed and dlopen succeeds.
            NSString *fwDir = [[NSBundle mainBundle].privateFrameworksPath
                stringByAppendingPathComponent:@"PythonExtensions.framework"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:fwDir]) {
                PyObject *pyFwPath = PyUnicode_FromString([fwDir UTF8String]);
                if (pyFwPath) { PyList_Insert(sysPath, 0, pyFwPath); Py_DECREF(pyFwPath); }
                EGPluginDebugLog_appendCStr("Runtime",
                    [[NSString stringWithFormat:@"dynload: %@", fwDir] UTF8String]);
            } else {
                EGPluginDebugLog_appendCStr("Runtime", "dynload: PythonExtensions.framework not found");
            }

            // Add BeewarePackages.framework to sys.path so plugins can import
            // Pillow, aiohttp, numpy, cffi, cryptography, etc. directly.
            // All .so files inside the framework are code-signed and dlopen-able.
            NSString *bwDir = [[NSBundle mainBundle].privateFrameworksPath
                stringByAppendingPathComponent:@"BeewarePackages.framework"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:bwDir]) {
                PyObject *pyBwPath = PyUnicode_FromString([bwDir UTF8String]);
                if (pyBwPath) { PyList_Insert(sysPath, 1, pyBwPath); Py_DECREF(pyBwPath); }
                EGPluginDebugLog_appendCStr("Runtime",
                    [[NSString stringWithFormat:@"beeware pkgs: %@", bwDir] UTF8String]);
            }

            NSMutableArray<NSString *> *extraPaths = [NSMutableArray new];
            // Split colon-separated SDK paths
            for (NSString *p in [sdkPath componentsSeparatedByString:@":"]) {
                if (p.length > 0) [extraPaths addObject:p];
            }
            [extraPaths addObjectsFromArray:@[pluginsPath, sitePkgs]];
            for (NSString *p in extraPaths) {
                PyObject *pyPath = PyUnicode_FromString([p UTF8String]);
                if (pyPath) { PyList_Append(sysPath, pyPath); Py_DECREF(pyPath); }
            }

            // Log the final sys.path so runtime issues are diagnosable.
            PyObject *pathRepr = PyObject_Repr(sysPath);
            if (pathRepr) {
                EGPluginDebugLog_appendCStr("Runtime",
                    [[NSString stringWithFormat:@"sys.path = %s", PyUnicode_AsUTF8(pathRepr)] UTF8String]);
                Py_DECREF(pathRepr);
            }
        }

        // Install a sys.meta_path finder that looks for .cpython-313-iphoneos.dylib
        // files before the default FileFinder tries .cpython-313-iphoneos.so.
        //
        // Why meta_path instead of patching EXTENSION_SUFFIXES:
        //   FileFinder instances are built during _setup() (before we run), so
        //   modifying EXTENSION_SUFFIXES after the fact has no effect on already-
        //   created finders.  A meta_path hook is evaluated on every import and
        //   bypasses the cached FileFinder entirely.
        //
        // The .dylib extension is used because iOS signing tools (Feather, AltStore)
        // sign .dylib files but skip .so files in framework bundles — resulting in
        // unsigned .so files that AMFI blocks at dlopen time.
        // Module references stored as class attributes so find_spec can access
        // them after the global aliases are removed. 'import X' inside a class
        // body assigns to the class namespace, not the module globals.
        //
        // Two fixes vs. the simple version:
        // 1. Use name.rsplit('.',1)[-1] so 'PIL._imaging' maps to filename
        //    '_imaging', not 'PIL._imaging' (find_spec receives the full dotted name).
        // 2. Try both .cpython-313-iphoneos.dylib and .abi3.dylib suffixes so
        //    bcrypt/_bcrypt.abi3.so (renamed .abi3.dylib) is found too.
        PyRun_SimpleString(
            "class _DylibExtFinder:\n"
            "    import sys as _sys, os as _os\n"
            "    import importlib.machinery as _im, importlib.util as _iu\n"
            "    _SUFFIXES = ('.cpython-313-iphoneos.dylib', '.abi3.dylib')\n"
            "    def find_spec(self, name, path, target=None):\n"
            "        short = name.rsplit('.', 1)[-1]\n"
            "        for d in (path if path is not None else self._sys.path):\n"
            "            for s in self._SUFFIXES:\n"
            "                p = d + '/' + short + s\n"
            "                if self._os.path.isfile(p):\n"
            "                    ld = self._im.ExtensionFileLoader(name, p)\n"
            "                    return self._iu.spec_from_loader(name, ld, origin=p)\n"
            "        return None\n"
            "_DylibExtFinder._sys.meta_path.insert(0, _DylibExtFinder())\n"
            "del _DylibExtFinder\n"
        );

        PyGILState_Release(state);

        g_initialized = YES;
        plugin_log(@"PluginEngine", @"CPython %s ready. home=%@", PY_VERSION, pythonHome);

        // Observe view-tree tap notifications and dispatch them into Python.
        [[NSNotificationCenter defaultCenter]
            addObserverForName:EGPluginViewCallbackNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            NSString *handle = note.userInfo[@"handle"];
            if (![handle isKindOfClass:[NSString class]] || handle.length == 0) return;
            [EGPythonBridge withPython:^{
                PyObject *mod = PyImport_ImportModule("eg_widgets");
                if (!mod) { PyErr_Clear(); return; }
                PyObject *fn = PyObject_GetAttrString(mod, "_invoke");
                if (fn && PyCallable_Check(fn)) {
                    PyObject *r = PyObject_CallFunction(fn, "s", handle.UTF8String);
                    if (!r) PyErr_Clear(); else Py_DECREF(r);
                }
                Py_XDECREF(fn);
                Py_DECREF(mod);
            }];
        }];
    });

    return g_initialized;
#else
    (void)pythonHome; (void)sdkPath; (void)pluginsPath; (void)sitePkgs;
    plugin_log(@"PluginEngine", @"Python.xcframework not present — engine disabled");
    return NO;
#endif
}

+ (BOOL)isInitialized {
#if EGPLUGIN_HAS_PYTHON
    return g_initialized;
#else
    return NO;
#endif
}

+ (void)withPython:(NS_NOESCAPE void (^)(void))block {
#if EGPLUGIN_HAS_PYTHON
    if (!g_initialized) return;
    PyGILState_STATE state = PyGILState_Ensure();
    block();
    PyGILState_Release(state);
#endif
}

+ (nullable NSString *)loadPlugin:(NSString *)pluginId fromPath:(NSString *)path {
#if EGPLUGIN_HAS_PYTHON
    if (!g_initialized) return @"Python runtime not initialized";
    __block NSString *errorMsg = nil;
    [self withPython:^{
        PyObject *importlib_util     = PyImport_ImportModule("importlib.util");
        PyObject *importlib_machinery = PyImport_ImportModule("importlib.machinery");
        if (!importlib_util || !importlib_machinery) {
            PyErr_Clear();
            Py_XDECREF(importlib_util); Py_XDECREF(importlib_machinery);
            errorMsg = @"importlib not available";
            return;
        }

        // .plugin is not a recognised extension — build an explicit SourceFileLoader
        // so spec_from_file_location knows how to handle the file.
        PyObject *SFL = PyObject_GetAttrString(importlib_machinery, "SourceFileLoader");
        if (!SFL) {
            PyErr_Clear(); Py_DECREF(importlib_util); Py_DECREF(importlib_machinery);
            errorMsg = @"SourceFileLoader not found";
            return;
        }
        PyObject *loader = PyObject_CallFunction(SFL, "ss", pluginId.UTF8String, path.UTF8String);
        Py_DECREF(SFL);
        if (!loader) {
            PyErr_Clear(); Py_DECREF(importlib_util); Py_DECREF(importlib_machinery);
            errorMsg = @"SourceFileLoader() failed";
            return;
        }

        // spec_from_file_location(name, path, loader=loader)
        PyObject *kwArgs = PyDict_New();
        PyDict_SetItemString(kwArgs, "loader", loader);
        Py_DECREF(loader); loader = NULL;

        PyObject *posArgs = PyTuple_Pack(2,
            PyUnicode_FromString(pluginId.UTF8String),
            PyUnicode_FromString(path.UTF8String));
        PyObject *sflFn = PyObject_GetAttrString(importlib_util, "spec_from_file_location");
        PyObject *spec = sflFn ? PyObject_Call(sflFn, posArgs, kwArgs) : NULL;
        Py_XDECREF(sflFn);
        Py_DECREF(posArgs); Py_DECREF(kwArgs);

        if (!spec || spec == Py_None) {
            PyErr_Clear();
            Py_XDECREF(spec);
            Py_DECREF(importlib_util); Py_DECREF(importlib_machinery);
            errorMsg = [NSString stringWithFormat:@"spec_from_file_location failed for %@", path];
            return;
        }
        Py_DECREF(importlib_machinery);

        PyObject *module = PyObject_CallMethod(importlib_util, "module_from_spec", "O", spec);
        if (!module) {
            PyErr_Clear(); Py_DECREF(spec); Py_DECREF(importlib_util);
            errorMsg = @"module_from_spec failed";
            return;
        }

        // Register in sys.modules so imports within the plugin work
        PyObject *sys_modules = PySys_GetObject("modules"); // borrowed
        PyDict_SetItemString(sys_modules, pluginId.UTF8String, module);

        // Execute the module body
        PyObject *specLoader = PyObject_GetAttrString(spec, "loader");
        PyObject *exec_result = specLoader ? PyObject_CallMethod(specLoader, "exec_module", "O", module) : NULL;
        Py_XDECREF(specLoader);

        if (!exec_result) {
            // Capture traceback as error string
            PyObject *exc = PyErr_GetRaisedException();
            if (exc) {
                PyObject *str = PyObject_Str(exc);
                const char *cstr = str ? PyUnicode_AsUTF8(str) : "unknown error";
                errorMsg = [NSString stringWithUTF8String:cstr ?: "unknown error"];
                Py_XDECREF(str);
                Py_DECREF(exc);
            } else {
                errorMsg = @"exec_module failed";
            }
            PyDict_DelItemString(sys_modules, pluginId.UTF8String);
            Py_DECREF(module); Py_DECREF(spec); Py_DECREF(importlib_util);
            return;
        }
        Py_DECREF(exec_result);

        // Call on_load(module) if it exists — log any exception instead of
        // swallowing it silently so plugin authors can diagnose failures.
        PyObject *on_load = PyObject_GetAttrString(module, "on_load");
        if (on_load && PyCallable_Check(on_load)) {
            PyObject *r = PyObject_CallFunctionObjArgs(on_load, module, NULL);
            if (!r) {
                // Capture traceback as a string and write to debug log.
                PyObject *exc = PyErr_GetRaisedException();
                if (exc) {
                    // Try to get a full formatted traceback via traceback module.
                    PyObject *tb_mod = PyImport_ImportModule("traceback");
                    NSMutableString *tbStr = [NSMutableString string];
                    if (tb_mod) {
                        PyObject *fmt = PyObject_GetAttrString(tb_mod, "format_exception");
                        if (fmt) {
                            PyObject *lines = PyObject_CallFunctionObjArgs(fmt, exc, NULL);
                            if (lines && PyList_Check(lines)) {
                                Py_ssize_t ln = PyList_Size(lines);
                                for (Py_ssize_t i = 0; i < ln; i++) {
                                    PyObject *s = PyList_GetItem(lines, i);
                                    const char *cs = PyUnicode_AsUTF8(s);
                                    if (cs) [tbStr appendFormat:@"%s", cs];
                                }
                            }
                            Py_XDECREF(lines);
                            Py_DECREF(fmt);
                        }
                        Py_DECREF(tb_mod);
                    }
                    if (tbStr.length == 0) {
                        PyObject *str = PyObject_Str(exc);
                        const char *cs = str ? PyUnicode_AsUTF8(str) : "?";
                        [tbStr appendFormat:@"%s", cs ?: "?"];
                        Py_XDECREF(str);
                    }
                    EGPluginDebugLog_appendCStr("Engine",
                        [[NSString stringWithFormat:@"on_load EXCEPTION in '%@':\n%@",
                          pluginId, tbStr] UTF8String]);
                    plugin_log(@"PluginEngine",
                        @"on_load exception in %@: %@", pluginId, tbStr);
                    Py_DECREF(exc);
                }
                PyErr_Clear();
            } else { Py_DECREF(r); }
        }
        PyErr_Clear();
        Py_XDECREF(on_load);

        // Store loaded module
        PyDict_SetItemString(g_loaded_modules, pluginId.UTF8String, module);

        Py_DECREF(module);
        Py_DECREF(spec);
        Py_DECREF(importlib_util);

        plugin_log(@"PluginEngine", @"Loaded plugin: %@", pluginId);
    }];
    return errorMsg;
#else
    return @"Python not available";
#endif
}

+ (void)unloadPlugin:(NSString *)pluginId {
#if EGPLUGIN_HAS_PYTHON
    if (!g_initialized) return;
    [self withPython:^{
        PyObject *module = PyDict_GetItemString(g_loaded_modules, pluginId.UTF8String);
        if (module) {
            PyObject *on_unload = PyObject_GetAttrString(module, "on_unload");
            if (on_unload && PyCallable_Check(on_unload)) {
                PyObject *r = PyObject_CallFunctionObjArgs(on_unload, NULL);
                if (!r) PyErr_Clear(); else Py_DECREF(r);
            }
            PyErr_Clear();
            Py_XDECREF(on_unload);
            PyDict_DelItemString(g_loaded_modules, pluginId.UTF8String);
            PyObject *sys_modules = PySys_GetObject("modules");
            PyDict_DelItemString(sys_modules, pluginId.UTF8String);
        }

        // --- Purge TL-hook callbacks that belong to this module -----------
        // A callback belongs to the plugin when either its __module__ attribute
        // OR its __globals__["__name__"] equals the plugin id.  We check both
        // because some closures don't have __module__ set correctly while their
        // __globals__["__name__"] always reflects the defining module.
        if (g_tl_hooks) {
            PyObject *keys = PyDict_Keys(g_tl_hooks);
            Py_ssize_t kn  = PyList_Size(keys);
            Py_ssize_t totalRemoved = 0;
            const char *pidC = pluginId.UTF8String;
            for (Py_ssize_t ki = 0; ki < kn; ki++) {
                PyObject *key  = PyList_GetItem(keys, ki);
                PyObject *list = PyDict_GetItem(g_tl_hooks, key);
                if (!list) continue;
                Py_ssize_t before = PyList_Size(list);
                PyObject *filtered = PyList_New(0);
                for (Py_ssize_t li = 0; li < before; li++) {
                    PyObject *cb = PyList_GetItem(list, li);

                    // 1. __module__
                    PyObject *mod = PyObject_GetAttrString(cb, "__module__");
                    const char *modName = mod ? PyUnicode_AsUTF8(mod) : NULL;
                    BOOL byModule = (modName && strcmp(modName, pidC) == 0);
                    Py_XDECREF(mod);
                    PyErr_Clear();

                    // 2. __globals__["__name__"] (fallback for closures)
                    BOOL byGlobals = NO;
                    PyObject *globals = PyObject_GetAttrString(cb, "__globals__");
                    if (globals && PyDict_Check(globals)) {
                        PyObject *gname = PyDict_GetItemString(globals, "__name__");
                        const char *gnameC = gname ? PyUnicode_AsUTF8(gname) : NULL;
                        byGlobals = (gnameC && strcmp(gnameC, pidC) == 0);
                    }
                    Py_XDECREF(globals);
                    PyErr_Clear();

                    BOOL belongs = byModule || byGlobals;
                    const char *keyStr = PyUnicode_AsUTF8(key);
                    EGPluginDebugLog_appendCStr("Engine",
                        [[NSString stringWithFormat:@"  purge %s[%ld] __module__='%s' globals='%s' match=%s",
                          keyStr ?: "?", (long)li, modName ?: "(null)",
                          byGlobals ? pidC : "?", belongs ? "YES" : "no"] UTF8String]);
                    if (!belongs) PyList_Append(filtered, cb);
                }
                Py_ssize_t after = PyList_Size(filtered);
                totalRemoved += (before - after);
                const char *keyStr = PyUnicode_AsUTF8(key);
                EGPluginDebugLog_appendCStr("Engine",
                    [[NSString stringWithFormat:@"  purge %s: %ld → %ld",
                      keyStr ?: "?", (long)before, (long)after] UTF8String]);
                PyDict_SetItem(g_tl_hooks, key, filtered);
                Py_DECREF(filtered);
            }
            EGPluginDebugLog_appendCStr("Engine",
                [[NSString stringWithFormat:@"unloadPlugin '%@': %ld TL callback(s) removed",
                  pluginId, (long)totalRemoved] UTF8String]);
            Py_DECREF(keys);
        }

        // --- Purge ObjC method-hook callbacks for this plugin ---------------
        // Clear before_list / after_list for each installed hook so that
        // the IMP replacement becomes a no-op rather than calling freed objects.
        if (g_method_hooks) {
            for (NSValue *val in g_method_hooks.allValues) {
                EGMethodHookEntry *entry = (EGMethodHookEntry *)val.pointerValue;
                if (!entry) continue;
                PyObject *lists[2] = { entry->before_list, entry->after_list };
                for (int li = 0; li < 2; li++) {
                    PyObject *lst = lists[li];
                    if (!lst) continue;
                    PyObject *filtered = PyList_New(0);
                    Py_ssize_t ln = PyList_Size(lst);
                    for (Py_ssize_t i = 0; i < ln; i++) {
                        PyObject *cb  = PyList_GetItem(lst, i);
                        PyObject *mod = PyObject_GetAttrString(cb, "__module__");
                        const char *mn = mod ? PyUnicode_AsUTF8(mod) : NULL;
                        BOOL belongs = (mn && strcmp(mn, pluginId.UTF8String) == 0);
                        Py_XDECREF(mod);
                        PyErr_Clear();
                        if (!belongs) PyList_Append(filtered, cb);
                    }
                    // Replace the list in-place
                    PyList_SetSlice(lists[li], 0, PyList_Size(lists[li]), NULL);
                    ln = PyList_Size(filtered);
                    for (Py_ssize_t i = 0; i < ln; i++)
                        PyList_Append(lists[li], PyList_GetItem(filtered, i));
                    Py_DECREF(filtered);
                }
            }
        }

        EGPluginDebugLog_appendCStr("Engine",
            [[NSString stringWithFormat:@"unloadPlugin: hooks purged for '%@'", pluginId] UTF8String]);
    }];
#endif
}

+ (void)dispatchTLHook:(NSString *)tlType params:(NSMutableDictionary<NSString *, id> *)params {
#if EGPLUGIN_HAS_PYTHON
    if (!g_initialized || !g_tl_hooks) {
        EGPluginDebugLog_appendCStr("TLHook",
            [[NSString stringWithFormat:@"dispatchTLHook(%@): skipped — not initialized", tlType] UTF8String]);
        return;
    }
    [self withPython:^{
        PyObject *list = PyDict_GetItemString(g_tl_hooks, tlType.UTF8String);
        if (!list || PyList_Size(list) == 0) {
            EGPluginDebugLog_appendCStr("TLHook",
                [[NSString stringWithFormat:@"dispatchTLHook(%@): no hooks registered", tlType] UTF8String]);
            return;
        }

        Py_ssize_t n = PyList_Size(list);
        EGPluginDebugLog_appendCStr("TLHook",
            [[NSString stringWithFormat:@"dispatchTLHook(%@): calling %ld callback(s)", tlType, (long)n] UTF8String]);

        // Convert params to a Python dict
        PyObject *py_params = ns_to_py(params);

        for (Py_ssize_t i = 0; i < n; i++) {
            PyObject *cb = PyList_GetItem(list, i); // borrowed
            PyObject *result = PyObject_CallFunctionObjArgs(cb, py_params, NULL);
            if (!result) {
                PyObject *exc = PyErr_Occurred();
                if (exc) {
                    PyObject *str = PyObject_Str(exc);
                    const char *cstr = str ? PyUnicode_AsUTF8(str) : "unknown";
                    EGPluginDebugLog_appendCStr("TLHook",
                        [[NSString stringWithFormat:@"callback[%ld] error: %s", (long)i, cstr] UTF8String]);
                    Py_XDECREF(str);
                }
                PyErr_Clear();
            } else { Py_DECREF(result); }
        }

        // Write modified values back to params
        PyObject *keys = PyDict_Keys(py_params);
        Py_ssize_t kn = PyList_Size(keys);
        for (Py_ssize_t i = 0; i < kn; i++) {
            PyObject *key = PyList_GetItem(keys, i);
            PyObject *val = PyDict_GetItem(py_params, key);
            id nsKey = py_to_ns(key);
            id nsVal = py_to_ns(val);
            if (nsKey && ![nsKey isKindOfClass:[NSNull class]]) {
                params[nsKey] = nsVal;
            }
        }
        Py_DECREF(keys);
        Py_DECREF(py_params);
    }];
#endif
}

+ (void)invokePluginAction:(NSString *)pluginId key:(NSString *)key {
#if EGPLUGIN_HAS_PYTHON
    if (!g_initialized || !g_loaded_modules) return;
    [self withPython:^{
        PyObject *mod = PyDict_GetItemString(g_loaded_modules, pluginId.UTF8String);
        if (!mod) {
            EGPluginDebugLog_appendCStr("Action",
                [[NSString stringWithFormat:@"invokePluginAction: module '%@' not loaded", pluginId] UTF8String]);
            return;
        }
        PyObject *fn = PyObject_GetAttrString(mod, "on_setting_action");
        if (fn && PyCallable_Check(fn)) {
            PyObject *r = PyObject_CallFunction(fn, "s", key.UTF8String);
            if (!r) {
                PyObject *exc = PyErr_GetRaisedException();
                PyObject *str = exc ? PyObject_Str(exc) : NULL;
                const char *cs = str ? PyUnicode_AsUTF8(str) : "?";
                EGPluginDebugLog_appendCStr("Action",
                    [[NSString stringWithFormat:@"on_setting_action('%@', '%@') failed: %s",
                      pluginId, key, cs ?: "?"] UTF8String]);
                Py_XDECREF(str); Py_XDECREF(exc);
                PyErr_Clear();
            } else Py_DECREF(r);
        }
        Py_XDECREF(fn);
        PyErr_Clear();
    }];
#endif
}

+ (BOOL)hasHook:(NSString *)tlType {
#if EGPLUGIN_HAS_PYTHON
    if (!g_initialized || !g_tl_hooks) return NO;
    __block BOOL result = NO;
    [self withPython:^{
        PyObject *list = PyDict_GetItemString(g_tl_hooks, tlType.UTF8String);
        result = (list && PyList_Size(list) > 0);
    }];
    return result;
#else
    return NO;
#endif
}

+ (BOOL)pluginHasSettings:(NSString *)pluginId {
#if EGPLUGIN_HAS_PYTHON
    if (!g_initialized || !g_loaded_modules) return NO;
    __block BOOL result = NO;
    [self withPython:^{
        PyObject *mod = PyDict_GetItemString(g_loaded_modules, pluginId.UTF8String);
        if (mod) result = (BOOL)PyObject_HasAttrString(mod, "__settings__");
    }];
    return result;
#else
    return NO;
#endif
}

+ (nullable NSDictionary *)getPluginSettingsSchema:(NSString *)pluginId {
#if EGPLUGIN_HAS_PYTHON
    if (!g_initialized || !g_loaded_modules) return nil;
    __block NSDictionary *result = nil;
    [self withPython:^{
        PyObject *mod = PyDict_GetItemString(g_loaded_modules, pluginId.UTF8String);
        if (!mod) return;
        PyObject *settings = PyObject_GetAttrString(mod, "__settings__");
        if (!settings) { PyErr_Clear(); return; }
        PyObject *to_dict = PyObject_GetAttrString(settings, "to_dict");
        PyObject *schema = NULL;
        if (to_dict && PyCallable_Check(to_dict)) {
            schema = PyObject_CallFunctionObjArgs(to_dict, NULL);
            if (!schema) PyErr_Clear();
        }
        Py_XDECREF(to_dict);
        Py_DECREF(settings);
        if (schema) {
            id ns = py_to_ns(schema);
            if ([ns isKindOfClass:[NSDictionary class]]) result = ns;
            Py_DECREF(schema);
        }
    }];
    return result;
#else
    return nil;
#endif
}

+ (void)logFromPlugin:(NSString *)tag message:(NSString *)message {
    // Forward to Swift EGLoggerBridge via notification or direct call.
    // Using NSNotification avoids a direct Swift import from ObjC.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"EGPluginLogNotification"
                          object:nil
                        userInfo:@{@"tag": tag, @"msg": message}];
    });
}

+ (BOOL)installRequirements:(NSArray<NSString *> *)requirements forPlugin:(NSString *)pluginId {
    if (requirements.count == 0) return YES;
    PyGILState_STATE gstate = PyGILState_Ensure();
    PyObject *mgr = PyImport_ImportModule("pkg_manager");
    BOOL ok = NO;
    if (mgr) {
        PyObject *reqList = PyList_New((Py_ssize_t)requirements.count);
        for (NSUInteger i = 0; i < requirements.count; i++) {
            PyList_SET_ITEM(reqList, (Py_ssize_t)i,
                PyUnicode_FromString([requirements[i] UTF8String]));
        }
        PyObject *result = PyObject_CallMethod(mgr, "ensure_requirements", "O", reqList);
        if (result) {
            ok = PyObject_IsTrue(result) != 0;
            Py_DECREF(result);
        } else {
            PyErr_Clear();
        }
        Py_DECREF(reqList);
        Py_DECREF(mgr);
    } else {
        // Capture and log the Python exception so import errors in pkg_manager.py are visible.
        if (PyErr_Occurred()) {
            PyObject *type = NULL, *value = NULL, *tb = NULL;
            PyErr_Fetch(&type, &value, &tb);
            PyErr_NormalizeException(&type, &value, &tb);
            PyObject *str = value ? PyObject_Str(value) : NULL;
            const char *msg = str ? PyUnicode_AsUTF8(str) : "(unknown)";
            plugin_log(@"PluginEngine", @"pkg_manager import error: %s (plugin: %@)", msg, pluginId);
            Py_XDECREF(str); Py_XDECREF(type); Py_XDECREF(value); Py_XDECREF(tb);
        } else {
            plugin_log(@"PluginEngine", @"pkg_manager not found — requirements skipped for %@", pluginId);
        }
        ok = YES; // non-fatal: allow plugin to load anyway
    }
    PyGILState_Release(gstate);
    return ok;
}

+ (BOOL)extractPythonStdlibZip:(NSString *)zipPath toDirectory:(NSString *)destDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    if (![fm createDirectoryAtPath:destDir
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&err]) {
        plugin_log(@"PluginEngine", @"Could not create stdlib dir %@: %@", destDir, err);
        return NO;
    }
    BOOL ok = [SSZipArchive unzipFileAtPath:zipPath toDestination:destDir];
    if (!ok) {
        plugin_log(@"PluginEngine", @"Failed to unzip %@ → %@", zipPath, destDir);
    }
    return ok;
}

@end
