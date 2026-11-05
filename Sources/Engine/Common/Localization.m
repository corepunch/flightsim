#import "Localization.h"

static NSString *const kFallbackLocale = @"en";

NSDictionary<NSString *, NSDictionary *> *L10nCatalogs(void) {
    static NSDictionary *catalogs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *all = [NSMutableDictionary dictionary];
        for (NSURL *url in [NSBundle.mainBundle URLsForResourcesWithExtension:@"json" subdirectory:@"Strings"]) {
            NSData *data = [NSData dataWithContentsOfURL:url];
            NSError *error = nil;
            NSDictionary *catalog = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
            if (![catalog isKindOfClass:NSDictionary.class] || ![catalog[@"strings"] isKindOfClass:NSDictionary.class]) {
                NSLog(@"Localization: %@ unreadable: %@", url.lastPathComponent, error.localizedDescription ?: @"no \"strings\"");
                continue;
            }
            all[url.lastPathComponent.stringByDeletingPathExtension] = catalog;
        }
        if (!all[kFallbackLocale]) NSLog(@"Localization: no Strings/%@.json; showing keys", kFallbackLocale);
        catalogs = all;
    });
    return catalogs;
}

NSString *L10nLocale(void) {
    static NSString *locale;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *available = [L10nCatalogs().allKeys sortedArrayUsingSelector:@selector(compare:)];
        // Apple's BCP 47 matching, including Chinese scripts and Portuguese
        // regions, in the system/app language order.
        locale = [NSBundle preferredLocalizationsFromArray:available
                                          forPreferences:[NSLocale.preferredLanguages arrayByAddingObject:kFallbackLocale]].firstObject
                 ?: kFallbackLocale;
    });
    return locale;
}

BOOL L10nIsRightToLeft(void) {
    return [L10nCatalogs()[L10nLocale()][@"direction"] isEqualToString:@"rtl"];
}

static id Lookup(NSString *key) {
    NSDictionary *catalogs = L10nCatalogs();
    return catalogs[L10nLocale()][@"strings"][key] ?: catalogs[kFallbackLocale][@"strings"][key];
}

BOOL L10nHasOwn(NSString *key) {
    return L10nCatalogs()[L10nLocale()][@"strings"][key] != nil;
}

NSString *L10n(NSString *key) {
    id value = Lookup(key);
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSArray.class] && [[value firstObject] isKindOfClass:NSString.class]) return [value firstObject];
    return key;
}

NSArray<NSString *> *L10nList(NSString *key) {
    id value = Lookup(key);
    if ([value isKindOfClass:NSArray.class]) return value;
    if ([value isKindOfClass:NSString.class]) return @[value];
    return @[];
}

NSString *L10nFormat(NSString *key, ...) {
    va_list args;
    va_start(args, key);
    NSString *s = [[NSString alloc] initWithFormat:L10n(key) arguments:args];
    va_end(args);
    return s;
}
