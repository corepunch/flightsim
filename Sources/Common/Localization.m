#import "Common.h"
#import "Shared.h"

static NSString *const kFallbackLocale = @"en";

NSDictionary<NSString *, NSDictionary *> *L10nCatalogs(void) {
    static NSDictionary *catalogs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *all = [NSMutableDictionary dictionary];
        // The engine's catalogs, then the game's: a game adds keys and overrides
        // the engine's wording (its title, its unit names) locale by locale.
        for (NSURL *url in FSURLsLayered(@"Strings", @"json")) {
            NSData *data = [NSData dataWithContentsOfURL:url];
            NSError *error = nil;
            NSDictionary *catalog = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
            if (![catalog isKindOfClass:NSDictionary.class] || ![catalog[@"strings"] isKindOfClass:NSDictionary.class]) {
                NSLog(@"Localization: %@ unreadable: %@", url.lastPathComponent, error.localizedDescription ?: @"no \"strings\"");
                continue;
            }
            NSString *locale = url.lastPathComponent.stringByDeletingPathExtension;
            NSDictionary *base = all[locale];
            if (base) {
                NSMutableDictionary *merged = [base mutableCopy], *strings = [base[@"strings"] mutableCopy];
                [strings addEntriesFromDictionary:catalog[@"strings"]];
                [merged addEntriesFromDictionary:catalog];
                merged[@"strings"] = strings;
                catalog = merged;
            }
            all[locale] = catalog;
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

static NSString *ExpandTokens(NSString *text, NSUInteger nesting) {
    if (nesting >= 16 || ![text containsString:@"{#"]) return text;
    NSMutableString *out = [NSMutableString string];
    NSUInteger i = 0, n = text.length;
    while (i < n) {
        NSRange open = [text rangeOfString:@"{#" options:0 range:NSMakeRange(i, n - i)];
        if (open.location == NSNotFound) { [out appendString:[text substringFromIndex:i]]; break; }
        // A translated entity label can itself be a token inside a message argument.
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        NSUInteger start = open.location + 2, depth = 1, close = NSNotFound;
        for (NSUInteger at = start; at < n; at++) {
            unichar character = [text characterAtIndex:at];
            if (character == '{' && at + 1 < n && [text characterAtIndex:at + 1] == '#') { depth++; at++; }
            else if (character == '}' && --depth == 0) {
                [parts addObject:[text substringWithRange:NSMakeRange(start, at - start)]];
                close = at; break;
            } else if (character == '\x1f' && depth == 1) {
                [parts addObject:[text substringWithRange:NSMakeRange(start, at - start)]];
                start = at + 1;
            }
        }
        if (close == NSNotFound) { [out appendString:[text substringFromIndex:i]]; break; }
        [out appendString:[text substringWithRange:NSMakeRange(i, open.location - i)]];
        NSString *format = L10n(parts.firstObject);
        // Arguments are strings: substitute %@ one by one (no varargs from data).
        NSMutableString *s = [format mutableCopy];
        for (NSUInteger a = 1; a < parts.count; a++) {
            NSRange at = [s rangeOfString:@"%@"];
            if (at.location == NSNotFound) break;
            [s replaceCharactersInRange:at withString:ExpandTokens(parts[a], nesting + 1)];
        }
        [s replaceOccurrencesOfString:@"%%" withString:@"%" options:0 range:NSMakeRange(0, s.length)];
        [out appendString:s];
        i = close + 1;
    }
    return out;
}

NSString *L10nExpand(NSString *text) { return ExpandTokens(text, 0); }

NSString *L10nFormat(NSString *key, ...) {
    va_list args;
    va_start(args, key);
    NSString *s = [[NSString alloc] initWithFormat:L10n(key) arguments:args];
    va_end(args);
    return s;
}
