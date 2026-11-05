#import "Common.h"
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>

typedef struct { NSString *help; CmdHandler handler; } CmdEntry;

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSArray *> *gCommands;      // name -> @[help, handler]
static NSMutableArray<NSString *> *gBuffer;                        // queued lines
static double gResumeAt;                                           // sleep: run the buffer again after this time
static NSArray<NSArray<NSString *> *> *gCommandLine;               // +commands from the process arguments

@implementation Cmd

+ (void)initialize {
    if (self != [Cmd class]) return;
    gCommands = [NSMutableDictionary dictionary];
    gBuffer = [NSMutableArray array];
    gCommandLine = @[];

    [self add:@"set" help:@"set <cvar> <value>: creates the cvar if needed" handler:^(NSArray<NSString *> *a) {
        if (a.count < 3) { NSLog(@"usage: set <cvar> <value>"); return; }
        [Cvar set:a[1] value:[[a subarrayWithRange:NSMakeRange(2, a.count - 2)] componentsJoinedByString:@" "]];
    }];
    [self add:@"exec" help:@"exec <file.cfg>: runs the commands in a file" handler:^(NSArray<NSString *> *a) {
        if (a.count < 2) { NSLog(@"usage: exec <file>"); return; }
        if (![Cmd executeFile:a[1]]) NSLog(@"exec: cannot read %@", a[1]);
    }];
    [self add:@"echo" help:@"Prints its arguments" handler:^(NSArray<NSString *> *a) {
        NSLog(@"%@", [[a subarrayWithRange:NSMakeRange(1, a.count - 1)] componentsJoinedByString:@" "]);
    }];
    [self add:@"cvarlist" help:@"Lists every cvar with its value and help" handler:^(NSArray<NSString *> *a) {
        for (Cvar *c in [Cvar all]) NSLog(@"  %@%@", c, c.help.length ? [@"  // " stringByAppendingString:c.help] : @"");
    }];
    [self add:@"cmdlist" help:@"Lists every command" handler:^(NSArray<NSString *> *a) {
        os_unfair_lock_lock(&gLock);
        NSArray *names = [gCommands.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSDictionary *commands = [gCommands copy];
        os_unfair_lock_unlock(&gLock);
        for (NSString *n in names) NSLog(@"  %@  %@", n, commands[n][0]);
    }];
    [self add:@"reset" help:@"reset <cvar>: back to its default" handler:^(NSArray<NSString *> *a) {
        if (a.count < 2) { NSLog(@"usage: reset <cvar>"); return; }
        [[Cvar find:a[1]] reset];
    }];
    // wait and sleep are handled by -executeBuffer, registered here so they list.
    [self add:@"wait" help:@"Defers the rest of the buffer to the next frame" handler:^(NSArray<NSString *> *a) {}];
    [self add:@"sleep" help:@"sleep <seconds>: defers the rest of the buffer" handler:^(NSArray<NSString *> *a) {}];
}

#pragma mark - Registry

+ (void)add:(NSString *)name help:(NSString *)help handler:(CmdHandler)handler {
    os_unfair_lock_lock(&gLock);
    gCommands[name] = @[help ?: @"", [handler copy]];
    os_unfair_lock_unlock(&gLock);
}

+ (void)remove:(NSString *)name {
    os_unfair_lock_lock(&gLock);
    [gCommands removeObjectForKey:name];
    os_unfair_lock_unlock(&gLock);
}

+ (BOOL)exists:(NSString *)name {
    os_unfair_lock_lock(&gLock);
    BOOL exists = gCommands[name] != nil;
    os_unfair_lock_unlock(&gLock);
    return exists;
}

#pragma mark - Execution

+ (NSArray<NSString *> *)tokenize:(NSString *)line {
    NSMutableArray *tokens = [NSMutableArray array];
    NSMutableString *token = nil;
    BOOL quoted = NO;
    NSUInteger n = line.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [line characterAtIndex:i];
        if (!quoted && c == '/' && i + 1 < n && [line characterAtIndex:i + 1] == '/') break;
        if (c == '"') {
            quoted = !quoted;
            if (!token) token = [NSMutableString string];
            continue;
        }
        if (!quoted && (c == ' ' || c == '\t' || c == '\r')) {
            if (token) { [tokens addObject:token]; token = nil; }
            continue;
        }
        if (!token) token = [NSMutableString string];
        [token appendFormat:@"%C", c];
    }
    if (token) [tokens addObject:token];
    return tokens;
}

+ (void)executeTokens:(NSArray<NSString *> *)args {
    if (!args.count) return;
    NSString *name = args[0];
    os_unfair_lock_lock(&gLock);
    NSArray *entry = gCommands[name];
    os_unfair_lock_unlock(&gLock);
    if (entry) {
        ((CmdHandler)entry[1])(args);
        return;
    }
    Cvar *c = [Cvar find:name];
    if (c) {
        if (args.count > 1) [c setString:[[args subarrayWithRange:NSMakeRange(1, args.count - 1)] componentsJoinedByString:@" "]];
        else NSLog(@"%@", c);
        return;
    }
    NSLog(@"Unknown command \"%@\"", name);
}

+ (NSArray<NSString *> *)linesOf:(NSString *)text {
    NSMutableArray *lines = [NSMutableArray array];
    NSMutableString *line = [NSMutableString string];
    BOOL quoted = NO;
    for (NSUInteger i = 0, n = text.length; i < n; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '"') quoted = !quoted;
        if ((c == '\n' || (c == ';' && !quoted))) {
            [lines addObject:[line copy]];
            [line setString:@""];
            continue;
        }
        [line appendFormat:@"%C", c];
    }
    if (line.length) [lines addObject:line];
    return lines;
}

+ (void)execute:(NSString *)text {
    for (NSString *line in [self linesOf:text]) [self executeTokens:[self tokenize:line]];
}

+ (void)addText:(NSString *)text {
    NSArray *lines = [self linesOf:text];
    os_unfair_lock_lock(&gLock);
    [gBuffer addObjectsFromArray:lines];
    os_unfair_lock_unlock(&gLock);
}

+ (void)executeBuffer {
    for (;;) {
        if (gResumeAt > 0) {
            if (CACurrentMediaTime() < gResumeAt) return;
            gResumeAt = 0;
        }
        os_unfair_lock_lock(&gLock);
        NSString *line = gBuffer.firstObject;
        if (line) [gBuffer removeObjectAtIndex:0];
        os_unfair_lock_unlock(&gLock);
        if (!line) return;
        NSArray *args = [self tokenize:line];
        if ([args.firstObject isEqualToString:@"wait"]) return;
        if ([args.firstObject isEqualToString:@"sleep"]) {
            gResumeAt = CACurrentMediaTime() + (args.count > 1 ? [args[1] doubleValue] : 0);
            return;
        }
        [self executeTokens:args];
    }
}

+ (BOOL)executeFile:(NSString *)path {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *resolved = nil;
    if (path.isAbsolutePath && [fm fileExistsAtPath:path]) resolved = path;
    else if ([fm fileExistsAtPath:path]) resolved = path;
    else resolved = [NSBundle.mainBundle pathForResource:path.lastPathComponent.stringByDeletingPathExtension
                                                  ofType:path.pathExtension.length ? path.pathExtension : @"cfg"
                                             inDirectory:path.stringByDeletingLastPathComponent];
    NSString *text = resolved ? [NSString stringWithContentsOfFile:resolved encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (!text) return NO;
    NSLog(@"exec %@", resolved);
    // A file's commands go to the front of the buffer so wait/sleep pace them.
    NSArray *lines = [self linesOf:text];
    os_unfair_lock_lock(&gLock);
    [gBuffer insertObjects:lines atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, lines.count)]];
    os_unfair_lock_unlock(&gLock);
    return YES;
}

#pragma mark - Command line

+ (void)setArguments:(NSArray<NSString *> *)arguments {
    NSMutableArray *commands = [NSMutableArray array];
    NSMutableArray *current = nil;
    for (NSString *arg in arguments) {
        if ([arg hasPrefix:@"+"] && arg.length > 1) {
            current = [NSMutableArray arrayWithObject:[arg substringFromIndex:1]];
            [commands addObject:current];
        } else if (current) {
            [current addObject:arg];
        }
    }
    gCommandLine = commands;
}

+ (void)executeEarlyCommands {
    [Cvar setInitializing:YES];
    for (NSArray *c in gCommandLine) if ([c.firstObject isEqualToString:@"set"]) [self executeTokens:c];
    [Cvar setInitializing:NO];
}

// Queued rather than run, so +sleep and +wait pace what follows them.
+ (void)executeLateCommands {
    NSMutableString *text = [NSMutableString string];
    for (NSArray<NSString *> *c in gCommandLine) {
        if ([c.firstObject isEqualToString:@"set"]) continue;
        NSMutableArray *quoted = [NSMutableArray array];
        for (NSString *token in c)
            [quoted addObject:[token rangeOfString:@" "].location == NSNotFound ? token : [NSString stringWithFormat:@"\"%@\"", token]];
        [text appendFormat:@"%@\n", [quoted componentsJoinedByString:@" "]];
    }
    [self addText:text];
}

@end
