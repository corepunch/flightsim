#import <Foundation/Foundation.h>

// Header-only so both native builds and the checked-in Xcode project use the
// same catalog without requiring a project regeneration.
static inline NSDictionary *LoadingCatalog(void) {
    static NSDictionary *catalog;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle URLForResource:@"Loading" withExtension:@"json" subdirectory:@"Menu"];
        NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
        NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        catalog = root[@"locales"] ?: @{};
    });
    return catalog;
}

static inline NSString *LoadingLocale(void) {
    static NSString *locale;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *available = [LoadingCatalog().allKeys sortedArrayUsingSelector:@selector(compare:)];
        // Uses Apple's BCP 47 matching, including Chinese scripts and
        // Portuguese regions, and respects the system/app language order.
        locale = [NSBundle preferredLocalizationsFromArray:available
                                          forPreferences:[NSLocale.preferredLanguages arrayByAddingObject:@"en"]].firstObject ?: @"en";
    });
    return locale;
}

static inline BOOL LoadingIsRTL(void) {
    return [LoadingCatalog()[LoadingLocale()][@"direction"] isEqualToString:@"rtl"];
}

static inline NSString *LoadingText(NSString *key, NSString *fallback) {
    NSDictionary *catalog = LoadingCatalog();
    return catalog[LoadingLocale()][@"messages"][key] ?: catalog[@"en"][@"messages"][key] ?: fallback;
}
