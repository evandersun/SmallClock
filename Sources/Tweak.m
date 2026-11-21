// SmallClock — shrinks the Lock Screen clock into the date row.
//
// Apelin workspace build: compiled by apelin/build.sh with the bootstrap
// clang. No Logos, no Theos; hooks go through MSHookMessageEx, looked up at
// run time so the dylib carries no hard dependency on a bootstrap path.
//
// The iOS 16 Lock Screen builds its header from SBFLockScreenDateView:
//   CSProminentTimeView         -> the big time label
//   CSProminentSubtitleDateView -> the date label
// SpringBoard re-centres those system labels on every layout pass and renders
// them through a vibrancy portal, so a frame we set on them does not stick.
// This tweak therefore hides both, reads the date string the system produced
// and draws one small row of its own: date, then the time beside it.

#import <UIKit/UIKit.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#ifndef APELIN_PACKAGE_ID
#define APELIN_PACKAGE_ID "local.apelin.smallclock"
#endif
#ifndef APELIN_BUILD_ID
#define APELIN_BUILD_ID "dev"
#endif

#define SC_MAX_TARGETS 8
#define SC_ROW_GAP 8.0
#define SC_ROW_MARGIN 16.0
#define SC_DATE_FONT_SIZE 22.0
#define SC_TIME_FONT_SIZE 20.0
#define SC_MIN_FONT_SIZE 13.0

typedef void (*MSHookMessageExFn)(Class cls, SEL sel, IMP imp, IMP *result);

static os_log_t SCLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "tweak");
    });
    return log;
}

static MSHookMessageExFn SCHookMessageExFunction(void) {
    static MSHookMessageExFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (MSHookMessageExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    });
    return fn;
}

static Class SCTargets[SC_MAX_TARGETS];
static IMP SCOriginalLayouts[SC_MAX_TARGETS];
static NSInteger SCTargetCount = 0;

static UIView *SCDateRoot = nil;
static UILabel *SCDateLabel = nil;
static UILabel *SCTimeLabel = nil;
static NSDateFormatter *SCFormatter = nil;
static NSTimer *SCEnforceTimer = nil;
static NSInteger SCLoggedState = -1;
static BOOL SCEnabledCache = YES;
static NSTimeInterval SCEnabledChecked = 0;

// The switch in the settings pane writes "enabled" into the package's own
// preferences domain; anything but an explicit false means on. The pane also
// writes the plist file directly (the Settings app's cfprefsd write can be
// dropped on iOS 16), so the file is read first.
static BOOL SCIsEnabled(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (SCEnabledChecked > 0 && now - SCEnabledChecked < 0.5) {
        return SCEnabledCache;
    }
    SCEnabledChecked = now;

    BOOL enabled = YES;
    NSDictionary *stored =
        [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.evander.smallclock.plist"];
    id value = stored[@"enabled"];
    if (value == nil) {
        value = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("enabled"),
                                                            CFSTR(APELIN_PACKAGE_ID)));
    }
    if (value != nil) {
        if ([value respondsToSelector:@selector(boolValue)]) {
            enabled = [value boolValue];
        }
    }
    SCEnabledCache = enabled;
    return enabled;
}

#pragma mark - View lookup

static NSUInteger SCViewCount = 0;

static UIView *SCFindView(UIView *root, NSString *fragment, NSInteger depth) {
    if (root == nil || depth > 8 || SCViewCount++ > 200) {
        return nil;
    }
    if ([NSStringFromClass(root.class) containsString:fragment]) {
        return root;
    }
    for (UIView *subview in root.subviews) {
        UIView *found = SCFindView(subview, fragment, depth + 1);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

static UIView *SCFind(UIView *root, NSString *fragment) {
    SCViewCount = 0;
    return SCFindView(root, fragment, 0);
}

static UILabel *SCFirstLabel(UIView *root) {
    if (root == nil) {
        return nil;
    }
    if ([root isKindOfClass:[UILabel class]]) {
        return (UILabel *)root;
    }
    for (UIView *subview in root.subviews) {
        UILabel *label = SCFirstLabel(subview);
        if (label != nil) {
            return label;
        }
    }
    return nil;
}

// The glass clock of SystemBoxClockGlass draws over the system clock and
// hides its label; with the time moved into the date row that panel is in
// the way, so its views (and any view of that family) stay hidden.
static void SCHideGlassClockViews(UIView *root) {
    for (UIView *subview in root.subviews) {
        NSString *name = NSStringFromClass(subview.class);
        if ([name hasPrefix:@"LGClock"]) {
            subview.hidden = YES;
            continue;
        }
        SCHideGlassClockViews(subview);
    }
}

#pragma mark - Row

static NSString *SCNowString(void) {
    if (SCFormatter == nil) {
        SCFormatter = [NSDateFormatter new];
        SCFormatter.dateFormat =
            [NSDateFormatter dateFormatFromTemplate:@"jm" options:0
                                             locale:[NSLocale currentLocale]];
    }
    return [SCFormatter stringFromDate:[NSDate date]];
}

static UILabel *SCCreateLabel(void) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.96];
    label.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    label.shadowOffset = CGSizeMake(0, 1);
    label.numberOfLines = 1;
    label.textAlignment = NSTextAlignmentCenter;
    label.userInteractionEnabled = NO;
    label.backgroundColor = [UIColor clearColor];
    return label;
}

static CGSize SCMeasure(NSString *text, UIFont *font) {
    if (text.length == 0) {
        return CGSizeZero;
    }
    return [text sizeWithAttributes:@{NSFontAttributeName: font}];
}

static void SCApply(UIView *root) {
    if (root == nil) {
        return;
    }
    UIView *timeBox = SCFind(root, @"CSProminentTimeView");
    UIView *dateBox = SCFind(root, @"CSProminentSubtitleDateView");
    UILabel *systemDate = SCFirstLabel(dateBox);
    if (dateBox == nil || systemDate == nil) {
        return;
    }

    NSString *dateText = systemDate.attributedText.length
                             ? systemDate.attributedText.string
                             : systemDate.text;
    if (dateText.length == 0) {
        return;
    }
    CGRect dateRect = [systemDate.superview convertRect:systemDate.frame toView:root];

    if (!SCIsEnabled()) {
        // Off: hand the header back to SpringBoard, untouched.
        if (timeBox != nil) {
            timeBox.hidden = NO;
        }
        systemDate.hidden = NO;
        SCDateLabel.hidden = YES;
        SCTimeLabel.hidden = YES;
        if (SCLoggedState != 0) {
            SCLoggedState = 0;
            os_log(SCLog(), "disabled: system clock restored");
        }
        return;
    }
    if (SCLoggedState != 1) {
        SCLoggedState = 1;
        os_log(SCLog(), "enabled: small row applied");
    }

    if (timeBox != nil) {
        timeBox.hidden = YES;
    }
    systemDate.hidden = YES;
    SCHideGlassClockViews(root);

    if (SCDateLabel == nil) {
        SCDateLabel = SCCreateLabel();
    }
    if (SCTimeLabel == nil) {
        SCTimeLabel = SCCreateLabel();
    }
    if (SCDateLabel.superview != root) {
        [root addSubview:SCDateLabel];
    }
    if (SCTimeLabel.superview != root) {
        [root addSubview:SCTimeLabel];
    }
    SCDateLabel.hidden = NO;
    SCTimeLabel.hidden = NO;
    if (![SCDateLabel.text isEqualToString:dateText]) {
        SCDateLabel.text = dateText;
    }
    NSString *now = SCNowString();
    if (![SCTimeLabel.text isEqualToString:now]) {
        SCTimeLabel.text = now;
    }

    CGFloat available = root.bounds.size.width - SC_ROW_MARGIN * 2.0;
    CGFloat dateSize = SC_DATE_FONT_SIZE;
    CGFloat timeSize = SC_TIME_FONT_SIZE;
    UIFont *dateFont = nil;
    UIFont *timeFont = nil;
    CGSize dateMeasure = CGSizeZero;
    CGSize timeMeasure = CGSizeZero;

    for (NSInteger attempt = 0; attempt < 8; attempt++) {
        dateFont = [UIFont systemFontOfSize:dateSize weight:UIFontWeightSemibold];
        timeFont = [UIFont monospacedDigitSystemFontOfSize:timeSize
                                                    weight:UIFontWeightSemibold];
        dateMeasure = SCMeasure(dateText, dateFont);
        timeMeasure = SCMeasure(now, timeFont);
        CGFloat total = dateMeasure.width + SC_ROW_GAP + timeMeasure.width;
        if (total <= available || dateSize <= SC_MIN_FONT_SIZE) {
            break;
        }
        CGFloat factor = available / total;
        dateSize = MAX(SC_MIN_FONT_SIZE, dateSize * factor);
        timeSize = MAX(SC_MIN_FONT_SIZE, timeSize * factor);
    }

    if (![SCDateLabel.font.fontName isEqualToString:dateFont.fontName] ||
        fabs(SCDateLabel.font.pointSize - dateFont.pointSize) > 0.05) {
        SCDateLabel.font = dateFont;
    }
    if (![SCTimeLabel.font.fontName isEqualToString:timeFont.fontName] ||
        fabs(SCTimeLabel.font.pointSize - timeFont.pointSize) > 0.05) {
        SCTimeLabel.font = timeFont;
    }

    CGFloat total = dateMeasure.width + SC_ROW_GAP + timeMeasure.width;
    CGFloat rowLeft = (root.bounds.size.width - total) / 2.0;
    CGFloat centerY = CGRectGetMidY(dateRect);

    SCTimeLabel.frame = CGRectMake(rowLeft, centerY - timeMeasure.height / 2.0,
                                   timeMeasure.width, timeMeasure.height);
    SCDateLabel.frame = CGRectMake(rowLeft + timeMeasure.width + SC_ROW_GAP,
                                   centerY - dateMeasure.height / 2.0,
                                   dateMeasure.width, dateMeasure.height);
}

static IMP SCSavedOriginal(id self) {
    Class cls = object_getClass(self);
    for (NSInteger i = 0; i < SCTargetCount; i++) {
        if (SCTargets[i] == cls) {
            return SCOriginalLayouts[i];
        }
    }
    return NULL;
}

static void SCHookedLayoutSubviews(UIView *self, SEL _cmd) {
    IMP original = SCSavedOriginal(self);
    if (original != NULL) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }
    SCDateRoot = self;
    SCApply(self);
}

static void SCInstallLayoutHook(Class cls) {
    if (cls == Nil || SCTargetCount >= SC_MAX_TARGETS) {
        return;
    }
    MSHookMessageExFn hook = SCHookMessageExFunction();
    if (hook == NULL) {
        os_log(SCLog(), "MSHookMessageEx unavailable");
        return;
    }
    IMP original = NULL;
    hook(cls, @selector(layoutSubviews), (IMP) SCHookedLayoutSubviews, &original);
    SCTargets[SCTargetCount] = cls;
    SCOriginalLayouts[SCTargetCount] = original;
    SCTargetCount++;
    os_log(SCLog(), "hooked %{public}s", class_getName(cls));
}

// SystemBoxClockGlass puts its glass clock back after any plain hide, so its
// own setHidden: is answered with YES.
#define SC_MAX_GLASS 4
static Class SCGlassClasses[SC_MAX_GLASS];
static void (*SCGlassOriginals[SC_MAX_GLASS])(id self, SEL _cmd, BOOL hidden);
static NSInteger SCGlassCount = 0;

static void SCHookedGlassSetHidden(id self, SEL _cmd, BOOL hidden) {
    BOOL force = SCIsEnabled();
    Class cls = object_getClass(self);
    for (NSInteger i = 0; i < SCGlassCount; i++) {
        if (SCGlassClasses[i] == cls && SCGlassOriginals[i] != NULL) {
            SCGlassOriginals[i](self, _cmd, force ? YES : hidden);
            return;
        }
    }
}

static void SCInstallGlassHideHook(void) {
    MSHookMessageExFn hook = SCHookMessageExFunction();
    if (hook == NULL) {
        return;
    }
    NSArray<NSString *> *names = @[@"LGClockGlassView", @"LGClockReplacementTimeView"];
    for (NSString *name in names) {
        Class cls = objc_getClass(name.UTF8String);
        if (cls == Nil || SCGlassCount >= SC_MAX_GLASS) {
            continue;
        }
        IMP original = NULL;
        hook(cls, @selector(setHidden:), (IMP) SCHookedGlassSetHidden, &original);
        SCGlassClasses[SCGlassCount] = cls;
        SCGlassOriginals[SCGlassCount] = (void (*)(id, SEL, BOOL))original;
        SCGlassCount++;
        os_log(SCLog(), "hid %{public}s", name.UTF8String);
    }
}

#pragma mark - Entry point

static void SCEnforce(void) {
    UIView *root = SCDateRoot;
    if (root == nil || root.window == nil) {
        return;
    }
    SCApply(root);
}

__attribute__((constructor)) static void SCTweakInitialize(void) {
    os_log(SCLog(), "ApelinLoaded %{public}s in %{public}s", APELIN_BUILD_ID, getprogname());

    if (objc_getClass("SpringBoard") == Nil) {
        return;
    }
    Class dateView = objc_getClass("SBFLockScreenDateView");
    if (dateView == Nil) {
        os_log(SCLog(), "SBFLockScreenDateView missing");
        return;
    }
    SCInstallLayoutHook(dateView);
    Class dateViewAX = objc_getClass("SBFLockScreenDateViewAccessibility");
    if (dateViewAX != Nil) {
        SCInstallLayoutHook(dateViewAX);
    }
    SCInstallGlassHideHook();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SCEnforceTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         repeats:YES
                                                           block:^(NSTimer *timer) {
            SCEnforce();
        }];
    });
}
