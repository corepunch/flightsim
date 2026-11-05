// Console commands and the command buffer, after Quake 2's Cmd_* and Cbuf_*.
// Modules register named commands; text comes from the command line (+name
// args ...), from .cfg files (exec) and from code. A line that names no
// command but a cvar prints or sets it ("cl_predict 0"). The buffer runs once
// per frame so commands act on a consistent frame, and `wait` / `sleep` let a
// script pace itself (screenshots, test drives).
#import <Foundation/Foundation.h>

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
