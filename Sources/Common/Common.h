#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include "Shared.h"

// MARK: - Geometry

// CGPoint doubles as the 2D vector, so screens do arithmetic on points and
// rects as values instead of on their components.
static inline CGPoint PointAdd(CGPoint a, CGPoint b) { return CGPointMake(a.x + b.x, a.y + b.y); }
static inline CGPoint PointSub(CGPoint a, CGPoint b) { return CGPointMake(a.x - b.x, a.y - b.y); }
static inline CGPoint PointScale(CGPoint p, CGFloat s) { return CGPointMake(p.x * s, p.y * s); }
static inline CGFloat PointDot(CGPoint a, CGPoint b) { return a.x * b.x + a.y * b.y; }
static inline CGFloat PointLength(CGPoint p) { return hypot(p.x, p.y); }
static inline CGFloat PointDistance(CGPoint a, CGPoint b) { return PointLength(PointSub(b, a)); }
static inline CGPoint PointLerp(CGPoint a, CGPoint b, CGFloat t) { return PointAdd(a, PointScale(PointSub(b, a), t)); }
static inline CGPoint PointOffset(CGPoint p, CGVector v) { return CGPointMake(p.x + v.dx, p.y + v.dy); }
// Shortened to `limit` when longer.
static inline CGPoint PointClampLength(CGPoint p, CGFloat limit) {
    CGFloat length = PointLength(p);
    return length > limit ? PointScale(p, limit / length) : p;
}
static inline CGPoint PointNormalize(CGPoint p) {
    CGFloat length = PointLength(p);
    return length > 0 ? PointScale(p, 1 / length) : CGPointZero;
}
// Unit normal to the left of the direction a → b.
static inline CGPoint PointLeftNormal(CGPoint a, CGPoint b) {
    CGPoint d = PointSub(b, a);
    return PointScale(CGPointMake(-d.y, d.x), 1 / PointLength(d));
}
// Component-wise product: a fraction of a size, or a point in a scaled frame.
static inline CGPoint PointFromSize(CGSize s) { return CGPointMake(s.width, s.height); }
static inline CGPoint PointMultiply(CGPoint p, CGSize s) { return CGPointMake(p.x * s.width, p.y * s.height); }

static inline CGPoint RectCenter(CGRect r) { return CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)); }
static inline CGPoint RectTopCenter(CGRect r) { return CGPointMake(CGRectGetMidX(r), CGRectGetMaxY(r)); }
// A point expressed as fractions of a rectangle, without clamping at its edges.
static inline CGPoint PointFractionInRect(CGPoint p, CGRect r) {
    CGPoint local = PointSub(p, r.origin);
    return PointMultiply(local, CGSizeMake(r.size.width > 0 ? 1 / r.size.width : 0,
                                           r.size.height > 0 ? 1 / r.size.height : 0));
}
static inline CGRect RectFromEdges(CGFloat left, CGFloat bottom, CGFloat right, CGFloat top) {
    return CGRectMake(left, bottom, right - left, top - bottom);
}
static inline CGRect RectWithSize(CGSize s) { return (CGRect){ .size = s }; }
// Inset by each edge separately; never negative in size.
static inline CGRect RectInsetEdges(CGRect r, CGFloat left, CGFloat top, CGFloat right, CGFloat bottom) {
    return CGRectMake(r.origin.x + left, r.origin.y + bottom, MAX(0, r.size.width - left - right), MAX(0, r.size.height - top - bottom));
}

static inline NSValue *BoxPoint(CGPoint p) { return [NSValue valueWithBytes:&p objCType:@encode(CGPoint)]; }
static inline CGPoint UnboxPoint(NSValue *v) { CGPoint p = CGPointZero; [v getValue:&p size:sizeof p]; return p; }
static inline NSValue *BoxRect(CGRect r) { return [NSValue valueWithBytes:&r objCType:@encode(CGRect)]; }
static inline CGRect UnboxRect(NSValue *v) { CGRect r = CGRectZero; [v getValue:&r size:sizeof r]; return r; }

// MARK: - LAN matches

// LAN choices persist as console variables; UI and hosting share this contract.
LANMatchSettings LANMatchSettingsCurrent(void);
void LANMatchSettingsSave(LANMatchSettings settings);
NSString *LANMatchSummary(LANMatchSettings settings);

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
// string takes the arguments as %@ in order; arguments may contain nested
// tokens, such as a localized ship class. Text without tokens comes back
// unchanged, so level text written in one language passes through.
NSString *L10nExpand(NSString *text);

// Whether the current locale's own catalog defines `key` (no fallback).
BOOL L10nHasOwn(NSString *key);
NSString *L10nLocale(void);
BOOL L10nIsRightToLeft(void);

// For checks: every catalog, locale -> { name, direction, strings }.
NSDictionary<NSString *, NSDictionary *> *L10nCatalogs(void);

// MARK: - Objectives

// Localized objective data for the flight checklist and mission debrief.
typedef NS_ENUM(NSInteger, ObjectiveStatus) { ObjectiveOpen, ObjectiveComplete, ObjectiveFailed };

@interface ObjectiveReadout : NSObject
- (instancetype)initWithText:(NSString *)text status:(ObjectiveStatus)status;
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly) ObjectiveStatus status;
@end

// Decode the two server messages into the same presentation data.
NSArray<ObjectiveReadout *> *FlightObjectiveReadouts(NSString *lines, NSString *states);
NSArray<ObjectiveReadout *> *MissionResultReadouts(NSArray<NSString *> *lines);

// MARK: - Screen models

// What a screen shows, as plain values. A scene gathers facts, a function here
// turns them into a model, and a view in UI/ draws the model; nothing in a
// scene chooses texts, order or sizes. Models need no window, so the unit
// checks cover them.

// One button of a menu. The scene maps `identifier` to what choosing it does.
@interface MenuChoice : NSObject
+ (instancetype)choice:(NSString *)identifier title:(NSString *)title;
+ (instancetype)choice:(NSString *)identifier title:(NSString *)title enabled:(BOOL)enabled;
@property (nonatomic, readonly, copy) NSString *identifier, *title;
@property (nonatomic, readonly) BOOL enabled;
@end

@interface MenuModel : NSObject
- (instancetype)initWithTitle:(NSString *)title hint:(NSString *)hint choices:(NSArray<MenuChoice *> *)choices;
@property (nonatomic, readonly, copy) NSString *title, *hint;
@property (nonatomic, readonly, copy) NSArray<MenuChoice *> *choices;
// NSNotFound when no choice has the identifier.
- (NSUInteger)indexOfChoice:(NSString *)identifier;
// The highlight after Up (-1) or Down (+1); it wraps around the ends.
- (NSUInteger)indexByMoving:(NSInteger)step from:(NSUInteger)index;
// The choice Confirm activates at `index`: nil when out of range or disabled.
- (MenuChoice *)choiceToActivateAt:(NSUInteger)index;
@end

// The pause menu's content for a local or remote flight.
MenuModel *PauseMenuModel(BOOL remote, BOOL cockpit, NSString *soundTitle);

// How a number of equal buttons fills a space: one column while the rows fit,
// more columns when they do not, and shorter rows only when the columns ran out.
typedef struct {
    CGFloat rowHeight, minimumRowHeight, gap;
    CGFloat columnWidth;            // the width of one column when there are several
    NSUInteger maximumColumns;
} MenuGridMetrics;
typedef struct {
    NSUInteger columns, rows;
    CGFloat rowHeight, columnWidth, gap;
    CGSize size;
} MenuGrid;
// `width` is one column's; several columns take `columnWidth` each and never
// more than `available.width` together.
MenuGrid MenuGridFit(NSUInteger count, CGFloat width, CGSize available, MenuGridMetrics metrics);
// Cells fill a column from the top before starting the next; `frame` has the grid's size.
CGRect MenuGridCell(MenuGrid grid, CGRect frame, NSUInteger index);

// A results page is a column of blocks, drawn in order by UIReportView.
typedef NS_ENUM(NSInteger, ReportBlockKind) {
    ReportHeadline,     // the outcome, large and centred
    ReportRating,       // 0-3 stars
    ReportScore,        // the career total and what this result added to it
    ReportNote,         // a centred line
    ReportText,         // a wrapped paragraph
    ReportChecklist,    // a heading over objectives
    ReportTable,        // a header over rows of cells, one row highlighted
};
typedef NS_ENUM(NSInteger, ReportTone) { ReportTonePlain, ReportToneEmphasis, ReportToneDanger };

@interface ReportBlock : NSObject
+ (instancetype)headline:(NSString *)text tone:(ReportTone)tone;
+ (instancetype)rating:(NSUInteger)stars;
+ (instancetype)scoreTotal:(NSUInteger)total earned:(NSUInteger)earned;
+ (instancetype)note:(NSString *)text;
+ (instancetype)text:(NSString *)text;
+ (instancetype)checklist:(NSString *)title items:(NSArray<ObjectiveReadout *> *)items;
// The second column is the wide, leading-aligned one (a name); the others are narrow figures.
+ (instancetype)table:(NSArray<NSString *> *)header rows:(NSArray<NSArray<NSString *> *> *)rows
          highlighted:(NSUInteger)row;
@property (nonatomic, readonly) ReportBlockKind kind;
@property (nonatomic, readonly) ReportTone tone;
@property (nonatomic, readonly, copy) NSString *text;                       // headline, note, text, checklist heading
@property (nonatomic, readonly) NSUInteger stars, total, earned;
@property (nonatomic, readonly, copy) NSArray<ObjectiveReadout *> *items;
@property (nonatomic, readonly, copy) NSArray<NSString *> *header;
@property (nonatomic, readonly, copy) NSArray<NSArray<NSString *> *> *rows;
@property (nonatomic, readonly) NSUInteger highlightedRow;                  // NSNotFound for none
@end

@interface ReportModel : NSObject
- (instancetype)initWithBlocks:(NSArray<ReportBlock *> *)blocks;
@property (nonatomic, readonly, copy) NSArray<ReportBlock *> *blocks;
- (ReportBlock *)firstBlockOfKind:(ReportBlockKind)kind;
@end

typedef struct {
    BOOL success;
    NSUInteger stars, total, earned;            // the rating, the career score and this mission's share
    NSString *summary;
    NSArray<ObjectiveReadout *> *results;
} DebriefFacts;
ReportModel *DebriefReport(DebriefFacts facts);
ReportModel *CampaignEndReport(NSUInteger stars, NSUInteger possible, NSUInteger total);
// The local pilot's outcome and the scoreboard in the server's order.
ReportModel *MatchReport(LANMatchResult result, NSUInteger total, NSUInteger earned);
