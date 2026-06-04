// MARK: exteraGram — EGViewRenderer implementation

#import "EGViewRenderer.h"
#import <objc/runtime.h>

// Notification posted by tappable widgets — observed by EGPythonBridge to
// dispatch back into Python's eg_widgets._invoke(handle).
NSString *const EGPluginViewCallbackNotification = @"EGPluginViewCallbackNotification";

// ----------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------

static UIColor *EG_ColorFromARGB(NSNumber *n) {
    if (!n) return UIColor.clearColor;
    uint32_t v = (uint32_t)[n unsignedIntValue];
    CGFloat a = ((v >> 24) & 0xFF) / 255.0;
    CGFloat r = ((v >> 16) & 0xFF) / 255.0;
    CGFloat g = ((v >>  8) & 0xFF) / 255.0;
    CGFloat b = ((v      ) & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

// Map Android gravity bit-flag → UIKit text alignment / stack alignment.
static NSTextAlignment EG_TextAlignmentFromGravity(NSInteger gravity) {
    NSInteger horiz = gravity & 0x07;
    if (horiz & 0x01) return NSTextAlignmentCenter;  // CENTER_HORIZONTAL
    if (horiz == 0x05) return NSTextAlignmentRight;
    return NSTextAlignmentLeft;
}

// ----------------------------------------------------------------------
// Tap action target — needed because UIControl actions require a target
// object that outlives the control. We attach it via associated objects.
// ----------------------------------------------------------------------

@interface EGTapTarget : NSObject
@property (nonatomic, copy) NSString *handle;
- (instancetype)initWithHandle:(NSString *)h;
- (void)tap:(id)sender;
@end

@implementation EGTapTarget
- (instancetype)initWithHandle:(NSString *)h {
    if ((self = [super init])) { _handle = [h copy]; }
    return self;
}
- (void)tap:(id)sender {
    if (!_handle) return;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:EGPluginViewCallbackNotification
                      object:nil
                    userInfo:@{@"handle": _handle}];
}
@end

// ----------------------------------------------------------------------
// EGViewRenderer
// ----------------------------------------------------------------------

@implementation EGViewRenderer

+ (nullable UIView *)buildView:(nullable NSDictionary *)spec {
    if (![spec isKindOfClass:[NSDictionary class]]) return nil;
    NSString *kind = spec[@"kind"];
    UIView *v = nil;

    if ([kind isEqualToString:@"linear_layout"])      v = [self buildLinearLayout:spec];
    else if ([kind isEqualToString:@"text_view"])      v = [self buildTextView:spec];
    else if ([kind isEqualToString:@"button"])         v = [self buildButton:spec];
    else if ([kind isEqualToString:@"image_view"])     v = [self buildImageView:spec];
    else if ([kind isEqualToString:@"space"])          v = [self buildSpace:spec];
    else                                               v = [self buildPlainView:spec];

    [self applyCommonStyle:v from:spec];
    [self applySizing:v from:spec[@"layout_params"]];
    [self attachOnClick:v from:spec];
    return v;
}

// -- LinearLayout → UIStackView ---------------------------------------------

+ (UIView *)buildLinearLayout:(NSDictionary *)spec {
    UIStackView *stack = [UIStackView new];
    NSString *orientation = spec[@"orientation"];
    stack.axis = [orientation isEqualToString:@"vertical"]
        ? UILayoutConstraintAxisVertical
        : UILayoutConstraintAxisHorizontal;
    stack.spacing = 0;
    stack.distribution = UIStackViewDistributionFill;

    NSInteger gravity = [spec[@"gravity"] integerValue];
    // Cross-axis alignment derived from the gravity bits.
    if (stack.axis == UILayoutConstraintAxisHorizontal) {
        // For horizontal stack, "vertical gravity" controls cross-axis (Y).
        NSInteger v = gravity & 0xF0;
        if (v == 0x10)       stack.alignment = UIStackViewAlignmentCenter;
        else if (v == 0x50)  stack.alignment = UIStackViewAlignmentBottom;
        else if (v == 0x30)  stack.alignment = UIStackViewAlignmentTop;
        else                 stack.alignment = UIStackViewAlignmentFill;
    } else {
        NSInteger h = gravity & 0x07;
        if (h & 0x01)        stack.alignment = UIStackViewAlignmentCenter;
        else if (h == 0x05)  stack.alignment = UIStackViewAlignmentTrailing;
        else if (h == 0x03)  stack.alignment = UIStackViewAlignmentLeading;
        else                 stack.alignment = UIStackViewAlignmentFill;
    }

    NSArray *children = spec[@"children"];
    if ([children isKindOfClass:[NSArray class]]) {
        for (NSDictionary *childSpec in children) {
            UIView *child = [self buildView:childSpec];
            if (!child) continue;

            // Per-child margins: if any margin > 0, wrap in a padded container.
            NSArray *margins = childSpec[@"layout_params"][@"margins"];
            if ([margins isKindOfClass:[NSArray class]] && margins.count == 4) {
                CGFloat l = [margins[0] doubleValue];
                CGFloat t = [margins[1] doubleValue];
                CGFloat r = [margins[2] doubleValue];
                CGFloat b = [margins[3] doubleValue];
                if (l != 0 || t != 0 || r != 0 || b != 0) {
                    UIView *wrap = [UIView new];
                    wrap.translatesAutoresizingMaskIntoConstraints = NO;
                    child.translatesAutoresizingMaskIntoConstraints = NO;
                    [wrap addSubview:child];
                    [NSLayoutConstraint activateConstraints:@[
                        [child.leadingAnchor  constraintEqualToAnchor:wrap.leadingAnchor  constant:l],
                        [child.topAnchor      constraintEqualToAnchor:wrap.topAnchor      constant:t],
                        [child.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-r],
                        [child.bottomAnchor   constraintEqualToAnchor:wrap.bottomAnchor   constant:-b],
                    ]];
                    [stack addArrangedSubview:wrap];
                    [self applySizing:wrap from:childSpec[@"layout_params"]];
                    continue;
                }
            }
            [stack addArrangedSubview:child];
        }
    }
    return stack;
}

// -- TextView → UILabel -----------------------------------------------------

+ (UIView *)buildTextView:(NSDictionary *)spec {
    UILabel *label = [UILabel new];
    label.text = spec[@"text"] ?: @"";
    CGFloat size = [spec[@"text_size"] doubleValue]; if (size <= 0) size = 14;
    NSString *face = spec[@"typeface"] ?: @"normal";
    UIFontWeight w = UIFontWeightRegular;
    BOOL italic = NO;
    if ([face containsString:@"bold"])    w = UIFontWeightSemibold;
    if ([face containsString:@"italic"])  italic = YES;
    UIFont *font = [UIFont systemFontOfSize:size weight:w];
    if (italic) {
        UIFontDescriptor *d = [font.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitItalic];
        if (d) font = [UIFont fontWithDescriptor:d size:size];
    }
    label.font = font;
    label.textColor = EG_ColorFromARGB(spec[@"text_color"]);
    NSInteger gravity = [spec[@"gravity"] integerValue];
    label.textAlignment = EG_TextAlignmentFromGravity(gravity);
    NSInteger maxLines = [spec[@"max_lines"] integerValue];
    label.numberOfLines = maxLines > 0 ? maxLines : 0;
    label.adjustsFontSizeToFitWidth = (maxLines == 1);
    label.minimumScaleFactor = 0.6;
    return label;
}

// -- Button → UIButton ------------------------------------------------------

+ (UIView *)buildButton:(NSDictionary *)spec {
    BOOL hasBackground = [spec[@"background_drawable"] isKindOfClass:[NSDictionary class]];
    UIButton *btn = [UIButton buttonWithType:hasBackground ? UIButtonTypeCustom : UIButtonTypeSystem];
    [btn setTitle:(spec[@"text"] ?: @"") forState:UIControlStateNormal];
    CGFloat size = [spec[@"text_size"] doubleValue]; if (size <= 0) size = 14;
    NSString *face = spec[@"typeface"] ?: @"bold";
    UIFontWeight w = [face containsString:@"bold"] ? UIFontWeightBold : UIFontWeightRegular;
    btn.titleLabel.font = [UIFont systemFontOfSize:size weight:w];
    [btn setTitleColor:EG_ColorFromARGB(spec[@"text_color"]) forState:UIControlStateNormal];
    [btn setTitleColor:[EG_ColorFromARGB(spec[@"text_color"]) colorWithAlphaComponent:0.4]
              forState:UIControlStateDisabled];
    btn.titleLabel.numberOfLines = 2;
    btn.titleLabel.textAlignment = NSTextAlignmentCenter;
    NSNumber *enabled = spec[@"enabled"];
    if (enabled) btn.enabled = [enabled boolValue];
    NSNumber *alpha = spec[@"alpha"];
    if (alpha)   btn.alpha = [alpha doubleValue];
    return btn;
}

// -- ImageView → UIImageView ------------------------------------------------

+ (UIView *)buildImageView:(NSDictionary *)spec {
    UIImageView *iv = [UIImageView new];
    NSString *path = spec[@"path"];
    if (path.length > 0) {
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        if (img) iv.image = img;
    }
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.clipsToBounds = YES;
    return iv;
}

// -- Space → flexible UIView ------------------------------------------------

+ (UIView *)buildSpace:(NSDictionary *)spec {
    UIView *v = [UIView new];
    v.backgroundColor = UIColor.clearColor;
    return v;
}

// -- plain View -------------------------------------------------------------

+ (UIView *)buildPlainView:(NSDictionary *)spec {
    return [UIView new];
}

// -- common styling: background color, background drawable, padding, alpha --

+ (void)applyCommonStyle:(UIView *)v from:(NSDictionary *)spec {
    if (!v) return;

    NSNumber *bgc = spec[@"background_color"];
    if (bgc) v.backgroundColor = EG_ColorFromARGB(bgc);

    NSDictionary *drawable = spec[@"background_drawable"];
    if ([drawable isKindOfClass:[NSDictionary class]]) {
        UIColor *fill   = EG_ColorFromARGB(drawable[@"color"]);
        CGFloat radius  = [drawable[@"corner_radius"] doubleValue];
        CGFloat strokeW = [drawable[@"stroke_width"]  doubleValue];
        UIColor *stroke = EG_ColorFromARGB(drawable[@"stroke_color"]);
        v.backgroundColor = fill;
        v.layer.cornerRadius = radius;
        if (strokeW > 0) {
            v.layer.borderWidth = strokeW;
            v.layer.borderColor = stroke.CGColor;
        }
        v.layer.masksToBounds = YES;
        if ([drawable[@"shape"] isEqualToString:@"oval"]) {
            v.layer.cornerRadius = 9999;  // pill / circle
        }
    }

    NSArray *padding = spec[@"padding"];
    if ([padding isKindOfClass:[NSArray class]] && padding.count == 4) {
        CGFloat l = [padding[0] doubleValue], t = [padding[1] doubleValue],
                r = [padding[2] doubleValue], b = [padding[3] doubleValue];
        if (l != 0 || t != 0 || r != 0 || b != 0) {
            if ([v isKindOfClass:[UIStackView class]]) {
                UIStackView *sv = (UIStackView *)v;
                sv.layoutMarginsRelativeArrangement = YES;
                sv.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(t, l, b, r);
            } else if ([v isKindOfClass:[UILabel class]]) {
                // UILabel has no padding — wrap is complex; we just ignore tiny insets here.
                // (Plugins can add a wrapping LinearLayout if needed.)
            } else if ([v isKindOfClass:[UIButton class]]) {
                ((UIButton *)v).contentEdgeInsets = UIEdgeInsetsMake(t, l, b, r);
            }
        }
    }

    NSNumber *alpha = spec[@"alpha"];
    if (alpha) v.alpha = [alpha doubleValue];

    NSNumber *visible = spec[@"visible"];
    if (visible) v.hidden = ![visible boolValue];
}

// -- sizing: width / height (MATCH_PARENT=-1, WRAP_CONTENT=-2) + weight -----

+ (void)applySizing:(UIView *)v from:(NSDictionary *)lp {
    if (!v || ![lp isKindOfClass:[NSDictionary class]]) return;
    NSInteger w = [lp[@"width"]  integerValue];
    NSInteger h = [lp[@"height"] integerValue];
    CGFloat   wt = [lp[@"weight"] doubleValue];

    if (w > 0) {  // fixed width
        [v.widthAnchor constraintEqualToConstant:w].active = YES;
    }
    if (h > 0) {  // fixed height
        [v.heightAnchor constraintEqualToConstant:h].active = YES;
    }
    if (wt > 0) {
        // Stretch along stack axis: low hugging so it expands to share space.
        [v setContentHuggingPriority:UILayoutPriorityDefaultLow - 1
                             forAxis:UILayoutConstraintAxisHorizontal];
        [v setContentHuggingPriority:UILayoutPriorityDefaultLow - 1
                             forAxis:UILayoutConstraintAxisVertical];
    }
}

// -- on_click_id → UIControl target/action ----------------------------------

+ (void)attachOnClick:(UIView *)v from:(NSDictionary *)spec {
    NSString *handle = spec[@"on_click_id"];
    if (![handle isKindOfClass:[NSString class]] || handle.length == 0) return;

    EGTapTarget *target = [[EGTapTarget alloc] initWithHandle:handle];
    if ([v isKindOfClass:[UIControl class]]) {
        UIControl *ctl = (UIControl *)v;
        [ctl addTarget:target action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    } else {
        v.userInteractionEnabled = YES;
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(tap:)];
        [v addGestureRecognizer:tap];
    }
    // Keep the target alive for the lifetime of the view.
    objc_setAssociatedObject(v, "EGTapTarget", target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
