// SmallClock — shrinks the Lock Screen clock into the date row.
//
// Apelin workspace build: compiled by apelin/build.sh with the bootstrap
// clang. No Logos, no Theos; hooks go through MSHookMessageEx, looked up at
// run time so the dylib carries no hard dependency on a bootstrap path.
//
// The iOS 16 Lock Screen builds its header from SBFLockScreenDateView:
//   CSProminentTimeView         -> the big time label
//   CSProminentSubtitleDateView -> the date label
// This tweak hides the big time, draws a small time label of its own and
// pins it to the right of the date, so the two read as one small row.

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
#define SC_ROW_GAP 6.0
#define SC_ROW_MARGIN 12.0
#define SC_TIME_FONT_SIZE 19.0

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
static UILabel *SCTimeLabel = nil;
static NSDateFormatter *SCFormatter = nil;
static NSTimer *SCEnforceTimer = nil;
static NSInteger SCDumps = 0;

#pragma mark - Diagnostics

static void SCDumpView(UIView *view, NSInteger depth, NSMutableString *out) {
    if (view == nil || depth > 7) {
        return;
    }
    [out appendFormat:@"%*s%@ (%.0f,%.0f %.0fx%.0f)%@\n",
                     (int)(depth * 2), "", NSStringFromClass(view.class),
                     view.frame.origin.x, view.frame.origin.y,
                     view.frame.size.width, view.frame.size.height,
                     view.hidden ? @" hidden" : @""];
    for (UIView *subview in view.subviews) {
        SCDumpView(subview, depth + 1, out);
    }
}

static void SCLogBlock(NSString *text) {
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSUInteger index = 0;
    while (index < lines.count) {
        NSMutableString *chunk = [NSMutableString string];
        while (index < lines.count && chunk.length < 600) {
            [chunk appendFormat:@"%@\n", lines[index]];
            index++;
        }
        os_log(SCLog(), "%{public}s", chunk.UTF8String);
    }
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

#pragma mark - Time text

static NSString *SCNowString(void) {
    if (SCFormatter == nil) {
        SCFormatter = [NSDateFormatter new];
        SCFormatter.dateFormat =
            [NSDateFormatter dateFormatFromTemplate:@"jm" options:0
                                             locale:[NSLocale currentLocale]];
    }
    return [SCFormatter stringFromDate:[NSDate date]];
}

static UILabel *SCTimeLabelCreate(void) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = [UIFont monospacedDigitSystemFontOfSize:SC_TIME_FONT_SIZE
                                                  weight:UIFontWeightSemibold];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.96];
    label.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    label.shadowOffset = CGSizeMake(0, 1);
    label.numberOfLines = 1;
    label.textAlignment = NSTextAlignmentCenter;
    label.userInteractionEnabled = NO;
    label.text = SCNowString();
    return label;
}

#pragma mark - Layout

static void SCApply(UIView *root, BOOL dump) {
    if (root == nil) {
        return;
    }
    UIView *timeBox = SCFind(root, @"CSProminentTimeView");
    UIView *dateBox = SCFind(root, @"CSProminentSubtitleDateView");
    UILabel *dateLabel = SCFirstLabel(dateBox);
    if (dateBox == nil || dateLabel == nil) {
        return;
    }

    if (timeBox != nil) {
        timeBox.hidden = YES;
    }
    SCHideGlassClockViews(root);

    if (SCTimeLabel == nil) {
        SCTimeLabel = SCTimeLabelCreate();
    }
    NSString *now = SCNowString();
    if (![SCTimeLabel.text isEqualToString:now]) {
        SCTimeLabel.text = now;
    }
    if (SCTimeLabel.superview != root) {
        [root addSubview:SCTimeLabel];
    }

    CGRect dateRect = [dateLabel.superview convertRect:dateLabel.frame toView:root];
    CGSize timeSize = [SCTimeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGFloat boundsWidth = root.bounds.size.width;
    CGFloat total = dateRect.size.width + SC_ROW_GAP + timeSize.width;
    if (total > boundsWidth - SC_ROW_MARGIN * 2.0) {
        SCTimeLabel.font = [UIFont monospacedDigitSystemFontOfSize:SC_TIME_FONT_SIZE - 3.0
                                                          weight:UIFontWeightSemibold];
        timeSize = [SCTimeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
        total = dateRect.size.width + SC_ROW_GAP + timeSize.width;
    }

    CGFloat rowLeft = (boundsWidth - total) / 2.0;
    if (rowLeft < SC_ROW_MARGIN) {
        rowLeft = SC_ROW_MARGIN;
    }
    CGFloat centerY = CGRectGetMidY(dateRect);

    CGRect dateTarget = CGRectMake(rowLeft, dateRect.origin.y,
                                   dateRect.size.width, dateRect.size.height);
    dateLabel.frame = [root convertRect:dateTarget toView:dateLabel.superview];

    SCTimeLabel.frame = CGRectMake(rowLeft + dateRect.size.width + SC_ROW_GAP,
                                   centerY - timeSize.height / 2.0,
                                   timeSize.width, timeSize.height);

    if (dump && SCDumps < 60) {
        SCDumps++;
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"state %ld rowLeft=%.1f total=%.1f\n",
                          (long)SCDumps, rowLeft, total];
        SCDumpView(root, 0, out);
        SCLogBlock(out);
    }
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
    SCApply(self, NO);
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
    Class cls = object_getClass(self);
    for (NSInteger i = 0; i < SCGlassCount; i++) {
        if (SCGlassClasses[i] == cls && SCGlassOriginals[i] != NULL) {
            SCGlassOriginals[i](self, _cmd, YES);
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
    SCApply(root, YES);
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
