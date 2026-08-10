// MARK: exteraGram — renders Python widget-spec dicts into native UIKit views

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Renders Android-style widget specs (NSDictionary trees produced by
/// eg_widgets.py) into native UIKit views.  Each interactive widget that
/// carries an "on_click_id" registers a UIControl whose action posts
/// EGPluginViewCallbackNotification with the id in userInfo["handle"].
/// EGPythonBridge listens for that notification and dispatches back into
/// Python via eg_widgets._invoke(handle).
@interface EGViewRenderer : NSObject

/// Build a native UIView tree from a spec dict.  Returns nil if spec is nil.
+ (nullable UIView *)buildView:(nullable NSDictionary *)spec;

@end

NS_ASSUME_NONNULL_END
