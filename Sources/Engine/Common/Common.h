#pragma once

#import <Foundation/Foundation.h>
#include "Shared.h"

// MARK: - Cmd

// Console commands and the command buffer, after Quake 2's Cmd_* and Cbuf_*.
// Modules register named commands; text comes from the command line (+name
// args ...), from .cfg files (exec) and from code. A line that names no
// command but a cvar prints or sets it ("cl_predict 0"). The buffer runs once
// per frame so commands act on a consistent frame, and `wait` / `sleep` let a
// script pace itself (screenshots, test drives).

// args[0] is the command's name.
typedef void (^CmdHandler)(NSArray<NSString *> *args);

@interface Cmd : NSObject

+ (void)add:(NSString *)name help:(NSString *)help handler:(CmdHandler)handler;
+ (void)remove:(NSString *)name;
+ (BOOL)exists:(NSString *)name;

// Runs every command in `text` now (lines split on newlines and ';').
+ (void)execute:(NSString *)text;
// Queues text for the next -executeBuffer.
+ (void)addText:(NSString *)text;
// Runs what is queued; the frame loop calls it once per frame.
+ (void)executeBuffer;
// exec: an absolute path, a path under the working directory, or a file in
// the app bundle's resources. Returns NO if not found.
+ (BOOL)executeFile:(NSString *)path;

// The process arguments: everything from the first "+" on is split into
// commands at each "+". Earlier arguments are the platform's own.
+ (void)setArguments:(NSArray<NSString *> *)arguments;
// The command line's "set" commands, before any module registers cvars.
+ (void)executeEarlyCommands;
// Queues everything else for the command buffer, once the engine can act
// on it (map, connect, exec, sleep, screenshot, quit).
+ (void)executeLateCommands;

// Splits a line into tokens: whitespace separated, double quotes group, //
// starts a comment.
+ (NSArray<NSString *> *)tokenize:(NSString *)line;

@end

// MARK: - Cvar

// Console variables, after Quake 2's cvar_t: named, typed-as-you-read values
// that every module registers at init and reads at use. They replace
// environment variables and compile-time switches as the one way to configure
// or debug the engine and the game. Set from the command line (+set name
// value), from a .cfg (exec), or from code; CVAR_ARCHIVE ones persist in the
// user's defaults. Thread-safe: values are read on the render thread and set
// from anywhere.

@class Cvar;
typedef void (^CvarChangeHandler)(Cvar *cvar);

@interface Cvar : NSObject

// Registers (or returns) a cvar. Registering an existing one keeps its value
// and adds the flags; a value set earlier from the command line wins over
// the default and the archived one.
+ (Cvar *)get:(NSString *)name defaultValue:(NSString *)value flags:(unsigned)flags help:(NSString *)help;
+ (Cvar *)find:(NSString *)name;
+ (NSArray<Cvar *> *)all;                                   // sorted by name

// Console semantics: unknown names are created with no flags, as Quake 2's
// Cvar_Set does. Returns NO if the change was refused (cheat, noset).
+ (BOOL)set:(NSString *)name value:(NSString *)value;
+ (float)valueOf:(NSString *)name;                          // 0 if unknown
+ (NSString *)stringOf:(NSString *)name;                    // "" if unknown

// Applies pending CVAR_LATCH values; the server calls it before a level spawn.
+ (void)applyLatched;
// Set while the command line's +set commands run: CVAR_NOSET allows changes
// only then.
+ (void)setInitializing:(BOOL)initializing;

@property (atomic, readonly, copy) NSString *name;
@property (atomic, readonly, copy) NSString *help;
@property (atomic, readonly, copy) NSString *defaultString;
@property (atomic, readonly) unsigned flags;
@property (atomic, readonly, copy) NSString *string;
@property (atomic, readonly) float value;
@property (atomic, readonly) int integer;
@property (atomic, readonly) BOOL boolValue;
@property (atomic, readonly, copy) NSString *latchedString;  // waiting for +applyLatched, else nil
// Called after every accepted change, on the thread that made it.
@property (atomic, copy) CvarChangeHandler onChange;

// Returns NO if refused. `force` bypasses the cheat and noset rules (for code
// that owns the cvar, e.g. a camera toggle updating cl_cockpit).
- (BOOL)setString:(NSString *)string force:(BOOL)force;
- (BOOL)setString:(NSString *)string;
- (BOOL)setValue:(float)value;
- (BOOL)setInteger:(int)value;
- (void)reset;

@end

// MARK: - Localization

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

// Expands catalog tokens in text that came from the server: "{#key}" or
// "{#key<US>arg<US>arg}" (US = U+001F), anywhere in the string. The key's
// string takes the arguments as %@ in order. Text without tokens comes back
// unchanged, so level text written in one language passes through.
NSString *L10nExpand(NSString *text);

// Whether the current locale's own catalog defines `key` (no fallback).
BOOL L10nHasOwn(NSString *key);
NSString *L10nLocale(void);
BOOL L10nIsRightToLeft(void);

// For checks: every catalog, locale -> { name, direction, strings }.
NSDictionary<NSString *, NSDictionary *> *L10nCatalogs(void);
