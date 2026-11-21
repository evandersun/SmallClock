// SPDX-License-Identifier: MIT
// SmallClock settings pane: rows come from Root.plist. The switch writes the
// value into the tweak's preferences domain, and the file is written directly
// as well: on iOS 16 the Settings app's write through cfprefsd can be dropped,
// and the tweak reads the same file.

#import <Preferences/PSListController.h>
#import <os/log.h>

static os_log_t PrefsLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.evander.smallclock.prefs", "prefs");
    });
    return log;
}

@interface SmallClockRootListController : PSListController
@end

@implementation SmallClockRootListController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *domain = [specifier propertyForKey:@"defaults"];
    NSString *key = [specifier propertyForKey:@"key"];
    os_log(PrefsLog(), "set key=%{public}s domain=%{public}s value=%{public}s",
           key.UTF8String ?: "(nil)", domain.UTF8String ?: "(nil)",
           [[value description] UTF8String]);

    if (domain.length > 0 && key.length > 0) {
        CFStringRef domainRef = (__bridge CFStringRef)domain;
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)value,
                                 domainRef);
        Boolean synced = CFPreferencesAppSynchronize(domainRef);
        os_log(PrefsLog(), "cfprefs sync=%d", synced);

        NSString *path = [@"/var/mobile/Library/Preferences"
                          stringByAppendingPathComponent:
                          [domain stringByAppendingPathExtension:@"plist"]];
        NSMutableDictionary *stored = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
        if (stored == nil) {
            stored = [NSMutableDictionary dictionary];
        }
        stored[key] = value ?: @NO;
        BOOL written = [stored writeToFile:path atomically:YES];
        os_log(PrefsLog(), "file write=%d path=%{public}s",
               written, path.UTF8String);
    }

    [super setPreferenceValue:value specifier:specifier];
}

@end
