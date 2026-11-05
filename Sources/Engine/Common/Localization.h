#import <Foundation/Foundation.h>

// Every user-visible string, by key, from Resources/Strings/<locale>.json:
//
//   { "name": "English", "direction": "ltr",
//     "strings": { "menu.quit": "QUIT GAME", "hud.speed": "%4d m/s", "loading.tips": ["…", "…"] } }
//
// The locale is the best match for the user's language order among the
// catalogs present (BCP 47, so "pt-BR" and "zh-Hant" match). A key missing
// from that catalog falls back to English, then to the key itself, which
// shows up on screen and in the unit checks. Values are plain strings or
// arrays of strings; strings may be format strings, whose specifiers must
// match English in every locale (checked by Tools/UnitChecks.m).
//
// Thread-safe; the catalogs load once on first use.

// The localized string for `key`.
NSString *L10n(NSString *key);
// The localized list for `key`: an array value, or the string as one item.
// Empty when no catalog has it.
NSArray<NSString *> *L10nList(NSString *key);
// `key` as a format string. Specifiers are checked against English, not at
// compile time, so keep the arguments in the order the English string uses.
NSString *L10nFormat(NSString *key, ...);

// Whether the current locale's own catalog defines `key` (no fallback).
BOOL L10nHasOwn(NSString *key);
NSString *L10nLocale(void);
BOOL L10nIsRightToLeft(void);

// For checks: every catalog, locale -> { name, direction, strings }.
NSDictionary<NSString *, NSDictionary *> *L10nCatalogs(void);
