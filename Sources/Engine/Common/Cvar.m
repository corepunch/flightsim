#import "Cvar.h"
#import <os/lock.h>

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, Cvar *> *gCvars;
static BOOL gInitializing;

static NSString *DefaultsKey(NSString *name) { return [@"cvar." stringByAppendingString:name]; }

@interface Cvar ()
- (void)store:(NSString *)string;
- (void)apply:(NSString *)string;
@end

@implementation Cvar

+ (void)initialize {
    if (self != [Cvar class]) return;
    gCvars = [NSMutableDictionary dictionary];
    [self get:@"sv_cheats" defaultValue:@"0" flags:0 help:@"Allow CVAR_CHEAT cvars to change"];
}

static BOOL CheatsEnabled(void) {
    Cvar *c = gCvars[@"sv_cheats"];
    return c ? c.boolValue : NO;
}

- (instancetype)initWithName:(NSString *)name value:(NSString *)value flags:(unsigned)flags help:(NSString *)help {
    if ((self = [super init])) {
        _name = [name copy];
        _defaultString = [value copy];
        _flags = flags;
        _help = [help copy];
        [self store:value];
    }
    return self;
}

// Parses once so reads on the render thread are plain loads.
- (void)store:(NSString *)s {
    _string = [s copy];
    _value = s.floatValue;
    _integer = s.intValue;
    _boolValue = _value != 0 || [s.lowercaseString isEqualToString:@"yes"] || [s.lowercaseString isEqualToString:@"true"];
}

#pragma mark - Registry

+ (Cvar *)get:(NSString *)name defaultValue:(NSString *)value flags:(unsigned)flags help:(NSString *)help {
    Cvar *c;
    BOOL resetCheat = NO;
    os_unfair_lock_lock(&gLock);
    c = gCvars[name];
    if (c) {
        if (!c->_defaultString.length && value.length) c->_defaultString = [value copy];
        if (help.length) c->_help = [help copy];
        c->_flags |= flags;
        // A cheat cvar set before anything registered it (so before the cheat
        // flag existed) goes back to its default unless cheats are on.
        if ((flags & CVAR_CHEAT) && !CheatsEnabled() && ![c->_string isEqualToString:c->_defaultString]) resetCheat = YES;
    } else {
        c = [[Cvar alloc] initWithName:name value:value flags:flags help:help];
        gCvars[name] = c;
        if (flags & CVAR_ARCHIVE) {
            NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:DefaultsKey(name)];
            if (saved) [c store:saved];
        }
    }
    os_unfair_lock_unlock(&gLock);
    if (resetCheat) {
        NSLog(@"Cvar: %@ is cheat protected; reset to \"%@\"", name, c.defaultString);
        [c setString:c.defaultString force:YES];
    }
    return c;
}

+ (Cvar *)find:(NSString *)name {
    os_unfair_lock_lock(&gLock);
    Cvar *c = gCvars[name];
    os_unfair_lock_unlock(&gLock);
    return c;
}

+ (NSArray<Cvar *> *)all {
    os_unfair_lock_lock(&gLock);
    NSArray *all = [gCvars.allValues sortedArrayUsingComparator:^NSComparisonResult(Cvar *a, Cvar *b) {
        return [a.name compare:b.name];
    }];
    os_unfair_lock_unlock(&gLock);
    return all;
}

+ (BOOL)set:(NSString *)name value:(NSString *)value {
    Cvar *c = [self find:name] ?: [self get:name defaultValue:@"" flags:0 help:nil];
    return [c setString:value];
}

+ (float)valueOf:(NSString *)name { return [self find:name].value; }
+ (NSString *)stringOf:(NSString *)name { return [self find:name].string ?: @""; }

+ (void)applyLatched {
    for (Cvar *c in [self all]) {
        NSString *latched = c.latchedString;
        if (!latched) continue;
        c->_latchedString = nil;
        [c apply:latched];
    }
}

+ (void)setInitializing:(BOOL)initializing { gInitializing = initializing; }

#pragma mark - Values

- (BOOL)setString:(NSString *)string { return [self setString:string force:NO]; }

- (BOOL)setString:(NSString *)string force:(BOOL)force {
    string = string ?: @"";
    if (!force) {
        if ((_flags & CVAR_NOSET) && !gInitializing) {
            NSLog(@"Cvar: %@ can only be set from the command line", _name);
            return NO;
        }
        if ((_flags & CVAR_CHEAT) && !CheatsEnabled() && ![string isEqualToString:_defaultString]) {
            NSLog(@"Cvar: %@ is cheat protected (set sv_cheats 1)", _name);
            return NO;
        }
    }
    if ([string isEqualToString:_string] && !_latchedString) return YES;
    if ((_flags & CVAR_LATCH) && !force) {
        _latchedString = [string copy];
        NSLog(@"Cvar: %@ will be \"%@\" at the next level", _name, string);
        return YES;
    }
    [self apply:string];
    return YES;
}

- (void)apply:(NSString *)string {
    os_unfair_lock_lock(&gLock);
    [self store:string];
    os_unfair_lock_unlock(&gLock);
    if (_flags & CVAR_ARCHIVE) [NSUserDefaults.standardUserDefaults setObject:string forKey:DefaultsKey(_name)];
    CvarChangeHandler handler = self.onChange;
    if (handler) handler(self);
}

- (BOOL)setValue:(float)value {
    return [self setString:value == (int)value ? [NSString stringWithFormat:@"%d", (int)value] : [NSString stringWithFormat:@"%g", value]];
}

- (BOOL)setInteger:(int)value { return [self setString:[NSString stringWithFormat:@"%d", value]]; }

- (void)reset { [self setString:_defaultString force:YES]; }

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ \"%@\"%@%@%@%@%@", _name, _string,
            [_string isEqualToString:_defaultString] ? @"" : [NSString stringWithFormat:@" (default \"%@\")", _defaultString],
            (_flags & CVAR_ARCHIVE) ? @" archive" : @"", (_flags & CVAR_CHEAT) ? @" cheat" : @"",
            (_flags & CVAR_LATCH) ? @" latch" : @"", (_flags & CVAR_NOSET) ? @" noset" : @""];
}

@end
