// Console variables, after Quake 2's cvar_t: named, typed-as-you-read values
// that every module registers at init and reads at use. They replace
// environment variables and compile-time switches as the one way to configure
// or debug the engine and the game. Set from the command line (+set name
// value), from a .cfg (exec), or from code; CVAR_ARCHIVE ones persist in the
// user's defaults. Thread-safe: values are read on the render thread and set
// from anywhere.
#import <Foundation/Foundation.h>
#include "CvarFlags.h"

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
