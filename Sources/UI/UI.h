#pragma once

#import <SpriteKit/SpriteKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "Input.h"
#import "Net.h"
#import "Common.h"

// A screen's safe area, in scene points.
#if TARGET_OS_IOS
typedef UIEdgeInsets ScreenInsets;
#else
typedef NSEdgeInsets ScreenInsets;
#endif

// MARK: - Briefing

typedef NS_ENUM(NSInteger, BriefingCommand) {
    BriefingCommandNone,
    BriefingCommandLaunch,      // fly selectedIndex
    BriefingCommandMainMenu,
};

// Full-screen campaign UI drawn over the 3D view: the mission list, the
// briefing for one mission (story text, objectives, intel, and a tactical
// map that steps through the briefing captions) and the debriefing.
#if TARGET_OS_IOS
typedef UIEdgeInsets BriefingInsets;
#else
typedef NSEdgeInsets BriefingInsets;
#endif
@interface Briefing : SKScene <ScreenInput>
@property (nonatomic) BriefingInsets contentInsets;
// Native iOS defaults to touch navigation even on large iPad viewports.
@property (nonatomic) BOOL touchNavigationEnabled;

@property (nonatomic, readonly) NSUInteger selectedIndex;

- (void)showListSelecting:(NSUInteger)index;
- (void)showBriefing:(NSUInteger)index;
- (void)showBriefing:(NSUInteger)index page:(NSUInteger)page;   // opens on a later page
// results: one line per objective, prefixed "+" done, "x" failed, "-" not done.
- (void)showDebrief:(NSUInteger)index success:(BOOL)success results:(NSArray<NSString *> *)results;
// Pointer input arrives through <ScreenInput>: hover, click, and scroll
// (positive delta reveals text farther down; the point is the wheel or drag origin).
- (BriefingCommand)handle:(InputAction)actions;
- (void)tick:(double)time;

// Layout as last built, for Tools/GUI checks.
@property (nonatomic, readonly) SKLabelNode *speech;            // the caption's line, if one is up
@property (nonatomic, readonly) CGRect captionRect;
@property (nonatomic, readonly) NSString *backdropRoom;
- (CGRect)portraitRectForCharacter:(NSString *)name;
// Conservative head clearance in the shared portrait canvas's upper third.
- (CGRect)portraitFaceRegionForCharacter:(NSString *)name;
@property (nonatomic, readonly) BOOL captionOnRight;             // the speaker sits on the right
@property (nonatomic, readonly) CGRect confirmRect, previousRect, backRect;
@property (nonatomic, readonly) CGRect scrollRect;              // empty unless text overflows
@property (nonatomic, readonly) CGFloat scrollOffset;
@property (nonatomic, readonly) SKNode *scrollContent;
@property (nonatomic, readonly) NSArray<NSValue *> *missionTiles;   // boxed CGRects
@property (nonatomic, readonly) CGRect missionRows;                  // the scrolling area the tiles sit in
@property (nonatomic, readonly) NSUInteger missionColumns;

@end

// MARK: - FrontEnd

@class NetAddress, LANServer, Loading, UILayoutResult;

// What the front end may ask of the engine. The host implements it; the
// front end never touches the server, client, renderer or view.
@protocol UIServices <NSObject>
// Flies a level of the local campaign on our own server.
- (void)startLevel:(NSUInteger)index;
// Joins someone else's game; the host reports progress with -setBrowserStatus:.
- (void)joinServer:(NetAddress *)address;
// Backs out of a join that has not reached the game yet.
- (void)cancelJoin;
// Explicit LAN hosting: a lobby first, then a match once friends have joined.
- (BOOL)createLANGame;
- (void)startLANMatch;
- (void)closeLANGame;
@property (nonatomic, readonly) NSArray<NSString *> *hostedPilots;
@property (nonatomic, readonly) BOOL hostingFailed;
@property (nonatomic, readonly) BOOL waitingForLANMatch;
// Shows a screen once the current one has played its exit animation.
- (void)present:(SKScene *)screen;
// Plays an exit of `seconds` (e.g. the main menu powering down), then quits.
- (void)quitAfter:(NSTimeInterval)seconds;
// The slow drift through the sky behind see-through screens.
- (void)drawMenuBackdrop;
// Whether a LAN listing is our own listen server (left off the list).
- (BOOL)isOwnServer:(LANServer *)server;
// Starts LAN discovery for the server browser. It opens a broadcast socket and
// a Bonjour search, so a host without a network (a check) returns nil and the
// browser lists nothing.
- (LANBrowser *)makeLANBrowser;
@property (nonatomic, readonly) double time;
@property (nonatomic, readonly, copy) NSString *connectedServer;   // a remote host we are on, or nil
@end

// The front end: main menu, campaign (mission list, briefing, debrief),
// server browser, and the campaign record. It decides which screen shows and
// what each choice does; the host only says when the menus are up and
// reports level and connection events.
@interface FrontEnd : NSObject

- (instancetype)initWithSize:(CGSize)size services:(id<UIServices>)services;

// The screen the menus show now (for the host's reveal after loading).
@property (nonatomic, readonly) SKScene *currentScreen;
@property (nonatomic, readonly) NSUInteger levelCount;

// Menus are up: handle this frame's actions on the current screen.
- (void)frame:(InputAction)actions;

- (void)showMainMenu;
- (void)showMissionsSelecting:(NSUInteger)index;
- (void)showBriefing:(NSUInteger)index page:(NSUInteger)page;
- (void)showBrowser;
- (void)showLANResults:(NSArray<NSString *> *)results hosting:(BOOL)hosting;
- (void)showLANHost;
// Set up after boot, without presenting: the main menu, with the mission
// list ready behind it.
- (void)prepareAfterBoot;

// Level events from the host.
- (void)fillLoadingCard:(Loading *)card level:(NSUInteger)index;
- (NSString *)bannerForLevel:(NSUInteger)index;
- (void)levelStarted:(NSUInteger)index remote:(BOOL)remote;
- (void)levelEnded:(NSUInteger)index success:(BOOL)success results:(NSArray<NSString *> *)results remote:(BOOL)remote;
// The level was left (aborted, restarted elsewhere, disconnected): back to the list.
- (void)levelLeft:(NSUInteger)index;

// Server browser lines.
- (void)setBrowserStatus:(NSString *)status;

@end

// MARK: - Loading

// Opaque full-screen overlay shown while a mission (or the game itself) is
// built on a background queue: title card, progress bar, status line and a
// rotating tip. Game drives it from the render loop with -tick:.
@interface Loading : SKScene <ScreenInput>

// kicker: small line above the title ("MISSION 03"), detail: line under it.
- (void)showTitle:(NSString *)title kicker:(NSString *)kicker detail:(NSString *)detail;
// progress 0..1; the bar eases toward it so coarse steps still look smooth.
- (void)setProgress:(float)progress status:(NSString *)status;
// YES once the displayed bar has caught up with a progress of 1.
@property (nonatomic, readonly) BOOL barFull;
// Opaque artwork under the outgoing menu while it animates into this card.
- (SKNode *)motionBackdropWithSize:(CGSize)size;
// Host enables this only when the mission and the displayed bar are ready.
@property (nonatomic) BOOL readyToStart;
- (BOOL)consumeStartRequest;
// Fades the whole card out over `seconds`, starting at the next tick.
- (void)fadeOut:(double)seconds;
// YES while fading or after the fade finished.
@property (nonatomic, readonly) BOOL fading;
@property (nonatomic, readonly) BOOL faded;
- (void)tick:(double)time;

@end

// MARK: - MainMenu

// Declarative settings content. The form owns row heights, padding, alignment,
// responsive stacking and slider interaction; screens supply only content.
@interface UISettingItem : NSObject
@property (nonatomic) BOOL enabled;
+ (instancetype)choice:(NSString *)title value:(NSString *)value detail:(NSString *)detail action:(void (^)(void))action;
+ (instancetype)slider:(NSString *)title value:(float)value minimum:(float)minimum maximum:(float)maximum
                step:(float)step text:(NSString *(^)(float))text change:(void (^)(float))change;
+ (instancetype)action:(NSString *)title value:(NSString *)value action:(void (^)(void))action;
@end

@interface UISettingsForm : SKNode
- (instancetype)initWithItems:(NSArray<UISettingItem *> *)items width:(CGFloat)width;
- (instancetype)initWithItems:(NSArray<UISettingItem *> *)items width:(CGFloat)width compact:(BOOL)compact;
@property (nonatomic) NSUInteger selectedIndex;
@property (nonatomic, readonly) CGFloat height;
@property (nonatomic, readonly) NSArray<NSValue *> *rowRects, *controlRects, *titleRects;
@property (nonatomic, readonly) BOOL dragging;
- (BOOL)clickAt:(CGPoint)point; // YES after an action that refreshes content
- (void)beginAt:(CGPoint)point;
- (void)dragTo:(CGPoint)point;
- (void)endDrag;
- (void)hoverAt:(CGPoint)point;
- (BOOL)adjust:(NSInteger)direction;
@end

// Content starts in the center; overflow keeps its top reachable by scrolling.
CGPoint UIScrollContentPosition(CGRect region, CGSize contentSize, CGFloat offset);

@class UIHover;

// Framed entries shared by game browsers, rosters and match results. Geometry
// and typography belong to the row; the caller supplies content and selection.
@interface UIListRow : SKNode
- (instancetype)initWithRect:(CGRect)rect title:(NSString *)title detail:(NSString *)detail
                     compact:(BOOL)compact selected:(BOOL)selected;
@property (nonatomic, readonly) CGRect rect;
@property (nonatomic, readonly) SKShapeNode *plate;
@property (nonatomic, readonly) SKLabelNode *titleLabel, *detailLabel;
- (void)registerHover:(UIHover *)hover;
@end

// A centered, wrapping status message constrained to a screen's content area.
@interface UIEmptyState : SKNode
- (instancetype)initWithRegion:(CGRect)region text:(NSString *)text compact:(BOOL)compact;
@property (nonatomic, readonly) SKLabelNode *label;
@end

// The engine's flight options and fixed bindings, reused in the menu and pause.
// The title stays visible while the body scrolls on small screens.
@interface ControlsPanel : SKNode <ScreenInput>
@property (nonatomic) BOOL touchNavigationEnabled;
- (void)layoutIn:(CGRect)bounds sceneSize:(CGSize)size;
- (BOOL)handle:(InputAction)actions; // YES when Back is chosen
@property (nonatomic, readonly) CGRect backRect, scrollRect;
@property (nonatomic, readonly) NSArray<NSValue *> *settingRects; // in scrollContent's coordinates
@property (nonatomic, readonly) CGFloat scrollOffset;
@property (nonatomic, readonly) SKNode *scrollContent;
@property (nonatomic, readonly) UISettingsForm *form;
@property (nonatomic, readonly) CGRect bindingsRect;
- (void)showBindings;
@end

#if TARGET_OS_IOS
typedef UIEdgeInsets MainMenuInsets;
#else
typedef NSEdgeInsets MainMenuInsets;
#endif

typedef NS_ENUM(NSInteger, MainMenuCommand) {
    MainMenuCommandNone,
    MainMenuCommandCampaign,
    MainMenuCommandMissions,
    MainMenuCommandMultiplayer,
    MainMenuCommandQuit,
};

// Takes pointer input through <ScreenInput>.
@interface MainMenu : SKScene <ScreenInput>
@property (nonatomic) BOOL touchNavigationEnabled;

// Insets are in scene points. When used as a SceneKit overlay, the host
// supplies its view's safe area. In a standalone SKView the scene reads it.
@property (atomic) MainMenuInsets contentInsets;
@property (nonatomic, readonly) ControlsPanel *controlsPanel;

- (void)showMission:(NSUInteger)index title:(NSString *)title started:(BOOL)started completed:(BOOL)completed;
- (MainMenuCommand)handle:(InputAction)actions;
// Exit by switching off like a tube (for quitting). Returns its length.
- (NSTimeInterval)motionPowerDown;

@end

// MARK: - MonitorSignal

// Briefing monitor interference, optionally keeping transparent surroundings.
SKShader *UIMonitorSignalShader(BOOL preserveAlpha);

// MARK: - PauseMenu

typedef NS_ENUM(NSInteger, PauseCommand) {
    PauseCommandNone, PauseCommandResume, PauseCommandCamera, PauseCommandSound,
    PauseCommandRestart, PauseCommandMissions
};

// The in-flight pause menu, laid out by Resources/UI/menus/pause.json. Its
// buttons' ids map to commands: resume, camera, sound, restart, missions;
// controls opens the engine's flight preferences within this screen.
// other ids do nothing. Flags for "when": "online" (a remote game, where the
// mission keeps running) and "cockpit" (the cockpit camera is on).
@interface PauseMenu : SKScene <ScreenInput>
@property (atomic) ScreenInsets contentInsets;
@property (nonatomic, readonly) UILayoutResult *layout;
@property (nonatomic, readonly) ControlsPanel *controlsPanel;
- (void)showRemote:(BOOL)remote cockpit:(BOOL)cockpit;
- (PauseCommand)handle:(InputAction)actions;
@end

// MARK: - Progress

// Campaign progress on this machine (NSUserDefaults): how many missions are
// open. A client-side record; the server never sees it.
NSUInteger ProgressUnlockedCount(void);     // at least 1
BOOL ProgressHasStarted(void);
BOOL ProgressCampaignCompleted(void);
void ProgressMarkStarted(void);
void ProgressMarkCompleted(NSUInteger missionIndex);

NSUInteger ProgressBestStars(NSUInteger missionIndex); // 0 unplayed, 1..3 best objective rating
void ProgressRecordResult(NSUInteger missionIndex, NSArray<NSString *> *results);

// MARK: - ScreenHost

// Which screen is up, and the change from one to the next: the outgoing
// screen plays its exit (UIMotionScene) before the next one is installed; if
// another change arrives meanwhile, the newest wins. Frame thread only.
@interface ScreenHost : NSObject

// `install` puts a screen on the view (the host hops to the main thread) and
// then removes `cover` (the backdrop that hid the gap) from the old one.
- (instancetype)initWithScreen:(SKScene *)first install:(void (^)(SKScene *screen, SKNode *cover))install;

@property (nonatomic, readonly) SKScene *shown;
// Called with the incoming screen just before its entrance, to give it what it
// needs to lay out as it will be shown (the view's safe area). A screen that
// has to lay out again once it is on the view rebuilds without its entrance.
@property (nonatomic, copy) void (^prepare)(SKScene *screen);
// YES while a screen is playing its exit; input should be held back.
@property (nonatomic, readonly) BOOL changing;

// The incoming screen's backdrop (-motionBackdropWithSize:), if it has one,
// is added under the outgoing screen's content while that content animates away.
- (void)present:(SKScene *)next time:(double)now;
// Runs `then` after `seconds` of exit animation, on a later -pump:.
- (void)after:(NSTimeInterval)seconds then:(void (^)(void))then time:(double)now;
// Call once per frame.
- (void)pump:(double)now;

@end

// MARK: - ServerBrowser

typedef NS_ENUM(NSInteger, BrowserCommand) { BrowserCommandNone, BrowserCommandJoin, BrowserCommandBack, BrowserCommandCreate };

// The multiplayer screen: create a game or select a discovered host.
// Up/Down pick, Return confirms, Esc goes back.
// Takes pointer input through <ScreenInput>.
@interface ServerBrowser : SKScene <ScreenInput>

@property (nonatomic, readonly) LANServer *selected;
@property (nonatomic, readonly, copy) NSString *status;
@property (nonatomic, readonly) CGRect createRect, joinRect, serverRows;
// The safe area in scene points, from the host; a standalone SKView's own wins.
@property (atomic) ScreenInsets contentInsets;

- (void)showServers:(NSArray<LANServer *> *)servers;
- (BrowserCommand)handle:(InputAction)actions;
- (void)setStatus:(NSString *)status;

@end

// MARK: - LANGame

typedef NS_ENUM(NSInteger, LANGameStage) { LANGameSetup, LANGameLobby, LANGameResults };
typedef NS_ENUM(NSInteger, LANGameCommand) { LANGameCommandNone, LANGameCommandConfirm, LANGameCommandBack, LANGameCommandSettings };

// Creation, waiting for friends and results use the same responsive screen.
@interface LANGame : SKScene <ScreenInput>
@property (atomic) ScreenInsets contentInsets;
@property (nonatomic, readonly) LANGameStage stage;
@property (nonatomic, readonly) CGRect confirmRect, backRect, bodyRect;
@property (nonatomic, readonly) LANMatchSettings settings;
@property (nonatomic, readonly) BOOL hosting, editingLobby;
@property (nonatomic, readonly) NSArray<NSValue *> *pilotRects;
@property (nonatomic, readonly) UISettingsForm *settingsForm;
@property (nonatomic, readonly) SKLabelNode *statusLabel;
- (void)showSetup;
- (void)showPilots:(NSArray<NSString *> *)pilots;
- (void)showGuestLobby:(LANServer *)server;
- (void)showResults:(NSArray<NSString *> *)results hosting:(BOOL)hosting;
- (LANGameCommand)handle:(InputAction)actions;
@end

// MARK: - UILayout

// Screen layouts as data: Resources/UI/menus/<name>.json, read every time a
// screen lays itself out, so editing the file changes the next rebuild.
//
// A layout is a tree of nodes. Every node may have:
//   "id"        name for the screen's code to find its frame or items
//   "anchor"    [x, y] in the parent frame, 0..1 (default [0.5, 0.5])
//   "pivot"     [x, y] of the node's own frame placed at the anchor (default = anchor)
//   "offset"    [dx, dy] points
//   "size"      [w, h] points; a value <= 0 means the parent's size minus it
//   "margin"    [x, y]: the size never exceeds the parent's minus twice this
//   "inset"     [left, top, right, bottom]: the frame children are laid out in
//   "when"      { "<flag>": { …overrides… } } merged when the flag is set;
//               "compact" is set when the screen is shorter than the root's
//               "compactBelow" (or in portrait)
//   "children"  nodes, laid out in this node's (inset) frame
// and a "type":
//   "shade"     full-screen colour: "color" (theme name), "opacity"
//   "panel"     chamfered readout panel: "stroke"/"fill" as [color, opacity]
//   "label"     "text" (catalog key, or "$variable"), "font" (theme font
//               name), "fontSize", "color", "opacity", "align" left|center|right;
//               centred vertically in its frame
//   "buttons"   a vertical list of action buttons from "items" (each with
//               "id", "text", optional "disabled" and "when"), "rowHeight",
//               "gap", optional "columns" and "textLines"; rows shrink to fit the frame
//   "group"     nothing drawn; for positioning children
// Numbers anywhere can be replaced by { "compact": n, "regular": n }.

@interface UILayoutResult : NSObject
@property (nonatomic, readonly) SKNode *node;
// Frames (scene points) by id; buttons also register "<id>.<item id>".
@property (nonatomic, readonly) NSDictionary<NSString *, NSValue *> *frames;
// Buttons by "<list id>.<item id>", and the item ids of each list in order.
@property (nonatomic, readonly) NSDictionary<NSString *, SKNode *> *buttons;
@property (nonatomic, readonly) NSDictionary<NSString *, NSArray<NSString *> *> *lists;
@property (nonatomic, readonly) NSSet<NSString *> *disabled;   // "<list id>.<item id>"
- (CGRect)frame:(NSString *)name;   // CGRectNull when missing
@end

@interface UILayout : NSObject

// nil (and a log line) when the file is missing or unreadable.
+ (instancetype)named:(NSString *)name;

@property (nonatomic, readonly) NSDictionary *root;

// Whether a scene of this size uses the compact variant.
- (BOOL)compactForSize:(CGSize)size;

// Builds the tree into `bounds` (usually the scene minus its safe area).
// `flags` switch "when" variants; `variables` fill "$name" texts; `selected`
// is "<list id>.<item id>" of the highlighted button, drawn in amber.
- (UILayoutResult *)buildIn:(CGRect)bounds sceneSize:(CGSize)size flags:(NSSet<NSString *> *)flags
                  variables:(NSDictionary<NSString *, NSString *> *)variables selected:(NSString *)selected;

// A value from the root's "metrics" object, with "when" variants applied.
- (CGFloat)metric:(NSString *)name flags:(NSSet<NSString *> *)flags fallback:(CGFloat)fallback;
// The root's "items" array (for screens that draw their own rows), filtered
// by an optional per-item "platforms": ["mac", "ios"].
- (NSArray<NSDictionary *> *)items;
- (NSArray<NSDictionary *> *)itemsForTouch:(BOOL)touch;

@end

// MARK: - UITheme

typedef struct { CGFloat r, g, b; } UIRGB;

// The interface theme, from Resources/UI/theme.json:
//
//   { "colors":  { "ink": [0.55, 0.95, 0.85], … },     linear 0..1 RGB
//     "fonts":   { "interface": "Oxanium-Regular", … },  PostScript names
//     "metrics": { "slant": 0.36, … },
//     "motion":  "full" }                               UIMotionStyle; optional
//
// The roles: ink (phosphor text and outlines), amber (emphasis), red
// (danger); panel, background and map fills; the console variant's steel,
// copper edge and glass; menu night/title for the main menu. Fonts: mono and
// monoBold for cockpit telemetry, interface/interfaceBold/body/bodyMedium for
// the front end. UIStyle below names each one (UIInk, UIInterfaceFont, …).
//
// A missing key logs once and draws magenta / Menlo / 0, so it is easy to
// spot; Tools/validate_strings.py checks that the file has every key UIStyle uses.
// Thread-safe; loads once on first use.

// How much the front end moves. A game picks its style with "motion" in its
// UI/theme.json; the system "reduce motion" setting turns it down to none.
typedef NS_ENUM(NSInteger, UIMotionStyle) {
    UIMotionStyleFull,   // the default: decode, glitch, scan sweeps, beam-drawn panels
    UIMotionStyleFade,   // entrances fade in with the same timing; nothing scrambles or sweeps
    UIMotionStyleNone,   // everything appears in place
};

UIRGB UIThemeColor(NSString *name);
NSString *UIThemeFont(NSString *name);
CGFloat UIThemeMetric(NSString *name);
// "motion": "full" (default), "fade" or "none"; see UIMotionStyle.
UIMotionStyle UIThemeMotion(void);

// MARK: - UIStyle

// The palette, fonts and metrics, from Resources/UI/theme.json (see UITheme above).
#define UIInk UIThemeColor(@"ink")
#define UIAmber UIThemeColor(@"amber")
#define UIRed UIThemeColor(@"red")
#define UIBlue UIThemeColor(@"blue")
#define UIFriendly UIThemeColor(@"friendly")
#define UIHUDNeutral UIThemeColor(@"hudNeutral")
#define UIShield UIThemeColor(@"shield")
#define UIReticle UIThemeColor(@"reticle")
#define UIBoost UIThemeColor(@"boost")
#define UIYellow UIThemeColor(@"yellow")
#define UIBackground UIThemeColor(@"background")
#define UIPanel UIThemeColor(@"panel")
#define UIMap UIThemeColor(@"map")
#define UIBlack UIThemeColor(@"black")
#define UIWhite UIThemeColor(@"white")
#define UIField UIThemeColor(@"field")
#define UIConsoleSteel UIThemeColor(@"consoleSteel")
#define UIConsoleEdge UIThemeColor(@"consoleEdge")
#define UIConsoleGlass UIThemeColor(@"consoleGlass")
#define UIMenuNight UIThemeColor(@"menuNight")
#define UIMenuTitle UIThemeColor(@"menuTitle")
#define UIMonoFont UIThemeFont(@"mono")
#define UIMonoBoldFont UIThemeFont(@"monoBold")
#define UIInterfaceFont UIThemeFont(@"interface")
#define UIInterfaceBoldFont UIThemeFont(@"interfaceBold")
#define UIBodyFont UIThemeFont(@"body")
#define UIBodyMediumFont UIThemeFont(@"bodyMedium")
#define UISlant UIThemeMetric(@"slant")
#define UIReadoutChamfer UIThemeMetric(@"readoutChamfer")

static inline SKColor *UIColorWithOpacity(UIRGB color, CGFloat opacity) {
    return [SKColor colorWithRed:color.r green:color.g blue:color.b alpha:opacity];
}

static inline SKLabelNode *UIMonoLabel(CGFloat size, SKColor *color, SKLabelHorizontalAlignmentMode horizontal,
                                      SKLabelVerticalAlignmentMode vertical) {
    SKLabelNode *label = [SKLabelNode labelNodeWithFontNamed:UIMonoFont];
    label.fontSize = size;
    label.fontColor = color;
    label.horizontalAlignmentMode = horizontal;
    label.verticalAlignmentMode = vertical;
    return label;
}

static inline SKLabelNode *UIInterfaceLabel(CGFloat size, SKColor *color, SKLabelHorizontalAlignmentMode horizontal,
                                           SKLabelVerticalAlignmentMode vertical) {
    SKLabelNode *label = UIMonoLabel(size, color, horizontal, vertical);
    label.fontName = UIInterfaceFont;
    return label;
}

// Font and wrapping changes can offset SpriteKit's nominal centre. Align the
// measured glyph bounds, including multi-line setting titles and hints.
static inline void UICenterLabelVertically(SKLabelNode *label, CGFloat y) {
    label.position = PointAdd(label.position, CGPointMake(0, y - CGRectGetMidY(label.frame)));
}

// Skew action controls, selection highlights, and horizontal progress indicators.
static inline CGPathRef UICreateSkewedPath(CGRect rect) CF_RETURNS_RETAINED {
    CGFloat left = CGRectGetMinX(rect), right = CGRectGetMaxX(rect);
    CGFloat bottom = CGRectGetMinY(rect), top = CGRectGetMaxY(rect);
    CGFloat slant = MIN(rect.size.height * UISlant, rect.size.width * 0.25);
    const CGPoint corners[] = {
        { left, bottom }, { right - slant, bottom }, { right, top }, { left + slant, top }
    };
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddLines(path, NULL, corners, 4);
    CGPathCloseSubpath(path);
    return path;
}

static inline SKShapeNode *UISkewedShape(CGRect rect, SKColor *stroke, SKColor *fill) {
    CGPathRef path = UICreateSkewedPath(rect);
    SKShapeNode *shape = [SKShapeNode shapeNodeWithPath:path];
    CGPathRelease(path);
    shape.strokeColor = stroke;
    shape.fillColor = fill;
    shape.lineWidth = 1;
    return shape;
}



static inline SKLabelNode *UIButtonLabel(NSString *text, CGFloat fontSize, CGPoint at) {
    SKLabelNode *label = UIInterfaceLabel(fontSize, UIColorWithOpacity(UIInk, 1), SKLabelHorizontalAlignmentModeCenter,
                                   SKLabelVerticalAlignmentModeCenter);
    label.fontName = UIInterfaceBoldFont;
    label.position = at;
    label.text = text;
    UICenterLabelVertically(label, at.y);
    return label;
}

// SpriteKit does not consistently truncate single-line labels using
// preferredMaxLayoutWidth. Fit the actual glyph bounds, without shrinking type.
static inline void UIFitControlLabel(SKLabelNode *label, CGFloat width) {
    NSString *text = label.text ?: @"";
    while (CGRectGetWidth(label.frame) > MAX(1, width) && text.length) {
        NSRange last = [text rangeOfComposedCharacterSequenceAtIndex:text.length - 1];
        text = [text substringToIndex:last.location];
        label.text = text.length ? [text stringByAppendingString:@"…"] : @"";
    }
}

// SpriteKit centres a multiline label's block; paragraph alignment centres
// each individual line inside that block.
void UISetCenteredButtonText(SKLabelNode *label, NSString *text);
void UIFitMultilineButtonLabel(SKLabelNode *label, NSString *text, NSUInteger lines, CGFloat height);

static inline SKShapeNode *UIActionButtonWithLines(CGRect rect, NSString *text, UIRGB accent, CGFloat fontSize, NSUInteger lines) {
    SKShapeNode *button = UISkewedShape(rect, UIColorWithOpacity(accent, 0.85), UIColorWithOpacity(UIPanel, 0.96));
    SKLabelNode *label = UIButtonLabel(text, fontSize, RectCenter(rect));
    label.numberOfLines = lines > 1 ? 0 : 1;
    label.preferredMaxLayoutWidth = MAX(1, CGRectGetWidth(rect) - MIN(CGRectGetHeight(rect) * UISlant, CGRectGetWidth(rect) * 0.25) - 20);
    label.lineBreakMode = lines > 1 ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
    if (lines > 1) {
        UIFitMultilineButtonLabel(label, text, lines, CGRectGetHeight(rect) - 4);
    } else UIFitControlLabel(label, label.preferredMaxLayoutWidth);
    UICenterLabelVertically(label, CGRectGetMidY(rect));
    [button addChild:label];
    return button;
}

static inline SKShapeNode *UIActionButtonSized(CGRect rect, NSString *text, UIRGB accent, CGFloat fontSize) {
    return UIActionButtonWithLines(rect, text, accent, fontSize, 1);
}

static inline SKShapeNode *UIActionButton(CGRect rect, NSString *text, UIRGB accent) {
    return UIActionButtonSized(rect, text, accent, 17);
}

// Navigation back: a plate whose left end is an arrowhead, so leaving a screen
// reads differently from acting on it. First on the left of a control bar.
static inline CGFloat UIBackControlTip(CGRect rect) { return rect.size.height * 0.45; }

static inline CGFloat UIBackControlWidth(NSString *text, CGFloat height, CGFloat fontSize) {
    return UIButtonLabel(text, fontSize, CGPointZero).frame.size.width + UIBackControlTip(CGRectMake(0, 0, 0, height))
        + height * UISlant + 24;
}

static inline CGPathRef UICreateBackControlPath(CGRect rect) CF_RETURNS_RETAINED {
    CGFloat left = CGRectGetMinX(rect), right = CGRectGetMaxX(rect);
    CGFloat bottom = CGRectGetMinY(rect), top = CGRectGetMaxY(rect), tip = UIBackControlTip(rect);
    const CGPoint corners[] = {
        { left, CGRectGetMidY(rect) }, { left + tip, top }, { right, top },
        { right - MIN(rect.size.height * UISlant, rect.size.width * 0.25), bottom }, { left + tip, bottom },
    };
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddLines(path, NULL, corners, sizeof(corners) / sizeof(*corners));
    CGPathCloseSubpath(path);
    return path;
}

static inline SKShapeNode *UIBackControl(CGRect rect, NSString *text, UIRGB accent, CGFloat fontSize) {
    CGPathRef path = UICreateBackControlPath(rect);
    SKShapeNode *button = [SKShapeNode shapeNodeWithPath:path];
    CGPathRelease(path);
    button.strokeColor = UIColorWithOpacity(accent, 0.85);
    button.fillColor = UIColorWithOpacity(UIPanel, 0.96);
    button.lineWidth = 1;
    CGPoint at = RectCenter(RectInsetEdges(rect, UIBackControlTip(rect), 0, rect.size.height * UISlant, 0));
    SKLabelNode *label = UIButtonLabel(text, fontSize, at);
    UIFitControlLabel(label, CGRectGetWidth(rect) - UIBackControlTip(rect) - rect.size.height * UISlant - 12);
    UICenterLabelVertically(label, at.y);
    [button addChild:label];
    return button;
}

// Chamfer informational panels so their silhouette reads differently from an action.
static inline SKShapeNode *UIReadoutPanel(CGRect rect, SKColor *stroke, SKColor *fill) {
    CGFloat left = CGRectGetMinX(rect), right = CGRectGetMaxX(rect);
    CGFloat bottom = CGRectGetMinY(rect), top = CGRectGetMaxY(rect);
    CGFloat cut = MIN(UIReadoutChamfer, MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)) * 0.25);
    const CGPoint corners[] = {
        {left + cut, bottom}, {right, bottom}, {right, top - cut},
        {right - cut, top}, {left, top}, {left, bottom + cut}
    };
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddLines(path, NULL, corners, sizeof(corners) / sizeof(*corners));
    CGPathCloseSubpath(path);
    SKShapeNode *panel = [SKShapeNode shapeNodeWithPath:path];
    CGPathRelease(path);
    panel.strokeColor = stroke;
    panel.fillColor = fill;
    panel.lineWidth = 1.5;
    return panel;
}

static inline void UISetSkewedBar(SKShapeNode *bar, CGFloat width, CGFloat height) {
    CGPathRef path = UICreateSkewedPath(CGRectMake(0, 0, MAX(0, width), height));
    bar.path = path;
    CGPathRelease(path);
}

// MARK: - UIMotion

// Motion for the front end: one vocabulary of timings, curves and effects so
// every screen powers up, changes and powers down the same way. Screens are
// rebuilt from scratch on each change, so effects are fire-and-forget actions
// attached to the freshly built nodes, and everything starts from its final
// layout (an effect only ever offsets, scales, hides or rewrites a node).

typedef NS_ENUM(NSInteger, UICurve) {
    UICurveLinear,
    UICurveOut,        // cubic ease-out: things arriving
    UICurveIn,         // cubic ease-in: things leaving
    UICurveInOut,
    UICurveOutExpo,    // fast snap that settles: beams, lock-ons
    UICurveOutBack,    // slight overshoot: selection nudges
};

// How a screen came to be rebuilt; screens pick their effects from this.
typedef NS_ENUM(NSInteger, UITransition) {
    UITransitionNone,     // relayout (resize): no motion
    UITransitionIntro,    // the screen powers up
    UITransitionPage,     // same screen, next page of content
    UITransitionSelect,   // the highlighted item moved
};

static const NSTimeInterval UIMotionQuick = 0.14;
static const NSTimeInterval UIMotionBase = 0.28;
static const NSTimeInterval UIMotionSlow = 0.55;

// Front-end scenes that play an entrance when the host shows them and an
// exit before it takes them down.
@protocol UIMotionScene <NSObject>
// Called just before the scene goes on screen: rebuild and play the entrance.
- (void)motionEnter;
// Start the exit and return how long it runs, in scene time.
- (NSTimeInterval)motionExit;
@optional
// What the scene shows behind its content as it enters, at full opacity.
// ScreenHost lays it under the outgoing screen while that one exits, so the
// view behind the overlays never shows through between two screens. A scene
// that has one shows its own backdrop at full opacity from its first frame.
- (SKNode *)motionBackdropWithSize:(CGSize)size;
@end

// The style in force: the ui_motion cvar, else none when motion is reduced
// (ui_reduceMotion, then the system setting), else the theme's.
UIMotionStyle UIMotionCurrentStyle(void);
// Anything short of full motion: screens skip their own flourishes (drifting
// art, selection kicks) and the effects below fade or jump to their end state.
BOOL UIMotionReduced(void);
// The ui_timescale cvar plays all front-end motion that many times slower.
double UIMotionTimeScale(void);

SKAction *UIEased(SKAction *action, UICurve curve);
SKAction *UIAfter(NSTimeInterval delay, SKAction *action);

// Reparent node under a holder positioned at pivot (in the parent's space),
// keeping its place in the draw order, so it can scale around pivot.
SKNode *UIMotionPivot(SKNode *node, CGPoint pivot);

// Slide in from offset while fading up.
void UIMotionSlideIn(SKNode *node, CGVector offset, NSTimeInterval delay, NSTimeInterval duration);
// Strobe up to full opacity like a tube striking.
void UIMotionFlickerIn(SKNode *node, NSTimeInterval delay);
// Monospaced text resolves left to right out of scrambled glyphs.
void UIMotionDecode(SKLabelNode *label, NSTimeInterval delay, NSTimeInterval duration);
// Wrapped text types on at charsPerSecond without reflowing (unrevealed
// characters are laid out but clear). Returns when the last one lands.
NSTimeInterval UIMotionTypeOn(SKLabelNode *label, NSTimeInterval delay, CGFloat charsPerSecond);
// Dialogue adds a phosphor block caret and a brief carriage-return trail at
// wrapped and explicit line breaks. Uses the same finish/skip controls.
NSTimeInterval UIMotionDialogueTypeOn(SKLabelNode *label, NSTimeInterval delay, CGFloat charsPerSecond);
// Adjust the block and return trail within a scene's paragraph baseline.
void UIMotionOffsetDialogueCaret(SKLabelNode *label, CGFloat y);
// Draws ranges (NSValue of NSRange) of the label's text in color, and keeps
// them while the text types on. Call after setting text, before typing.
void UIMotionHighlight(SKLabelNode *label, NSArray<NSValue *> *ranges, SKColor *color);
BOOL UIMotionIsTyping(SKLabelNode *label);
void UIMotionFinishTyping(SKLabelNode *label);
// Chromatic split and flicker. Intro resolves the label; a burst is a short
// disturbance on a label that stays visible.
void UIMotionGlitchIn(SKLabelNode *label, NSTimeInterval delay, NSTimeInterval duration, SKColor *split);
void UIMotionGlitchBurst(SKLabelNode *label, NSTimeInterval duration, CGFloat strength, SKColor *split);

// A bright line with a fading trail crosses rect (upward or downward).
void UIMotionSweep(SKNode *parent, CGRect rect, SKColor *color, BOOL downward,
                   NSTimeInterval delay, NSTimeInterval duration);
// A glowing horizontal beam drawn across [x0, x1] at y; grows from x0.
SKSpriteNode *UIMotionBeam(SKNode *parent, CGFloat x0, CGFloat x1, CGFloat y, SKColor *color);

// Panels are drawn by a beam: it runs along the top edge from the anchored
// side, then the panel drops open beneath it. Returns the panel's holder
// (pivoted on its top edge) and, through ready, when content can appear.
SKNode *UIMotionDrawPanel(SKNode *panel, CGRect rect, SKColor *beam, BOOL fromRight,
                          NSTimeInterval delay, NSTimeInterval *ready);
// The reverse, on a holder from UIMotionDrawPanel. Removes it when done.
NSTimeInterval UIMotionClosePanel(SKNode *holder, CGRect rect, SKColor *beam, BOOL toRight);

// Reveal node top-down behind a scan line, clipped to rect.
void UIMotionWipe(SKNode *node, CGRect rect, SKColor *line, NSTimeInterval delay, NSTimeInterval duration);
// Fade out with a stutter and drift, then remove (for content being replaced).
NSTimeInterval UIMotionDismiss(SKNode *node, CGVector drift, NSTimeInterval duration);
// A tube switching off: the stage collapses to a line, then a point.
NSTimeInterval UIMotionPowerDown(SKNode *stage, CGSize size);

// Pointer hover for a screen's buttons: each lights up as the pointer
// arrives and dims as it leaves. Register buttons on every rebuild.
@interface UIHover : NSObject
// The latest pointer position, applied at the next -updateInScene:; (-1, -1)
// when it leaves the view. Same thread as the screen (see ScreenInput in Input.h).
- (void)queuePointAtFraction:(CGPoint)point;
- (void)reset;
// button's children must be laid out in the same space as rect.
- (void)addButton:(SKNode *)button rect:(CGRect)rect accent:(UIRGB)accent;
// Lights the given outline instead of the skewed action shape. Pass a path of
// the caller's own, never one read back from a node on screen: reading a live
// shape node's path races the renderer.
- (void)addButton:(SKNode *)button rect:(CGRect)rect accent:(UIRGB)accent outline:(CGPathRef)outline;
- (void)addButton:(SKNode *)button rect:(CGRect)rect accent:(UIRGB)accent outline:(CGPathRef)outline
    hoverChanged:(void (^)(BOOL hovered))changed;
// Render thread, once per frame.
- (void)updateInScene:(SKScene *)scene;
@end

// MARK: - ScreenRegions

// Every screen is laid out in the same regions, and content goes into a region,
// never at an ad hoc position: the title bar along the top (TitleBar: back,
// title, actions) and the body (lists, grids, the story). Compact screens are phones.
typedef struct {
    CGRect header, body;
    CGRect bodyToEdge;             // body run to the bottom screen edge, for scrolling grids on phones
    BOOL compact;
} ScreenRegions;

ScreenRegions ScreenRegionsMake(CGSize size, ScreenInsets safe);

// MARK: - TitleBar

// Semantic commands map directly to columns of the single authored icon atlas.
typedef NS_ENUM(NSInteger, UICommandIcon) {
    UICommandBack, UICommandHome, UICommandMissions, UICommandPrevious,
    UICommandNext, UICommandSkip, UICommandLaunch, UICommandReplay,
    UICommandCreate, UICommandJoin, UICommandStart, UICommandSettings,
    UICommandSave, UICommandBindings, UICommandIconCount
};
typedef NS_ENUM(NSInteger, UICommandState) {
    UICommandNormal, UICommandSelected, UICommandHover, UICommandPressed, UICommandDisabled, UICommandStateCount
};
SKTexture *UICommandTexture(UICommandIcon icon, UICommandState state);

// A screen supplies the meaning of an action; the bar owns its presentation
// and hit testing. Capture screen owners weakly in handlers.
@interface UIBarAction : NSObject
+ (instancetype)title:(NSString *)title accent:(UIRGB)accent handler:(void (^)(void))handler;
+ (instancetype)title:(NSString *)title icon:(UICommandIcon)icon accent:(UIRGB)accent handler:(void (^)(void))handler;
@property (nonatomic) BOOL enabled;
@property (nonatomic) UICommandState iconState;
@end

// The bar along the top of a screen or panel: the back control on the left (an
// arrow plate), the screen's kicker and title beside it, and the screen's
// actions on the right, filling in from the right end so the primary action
// sits in the corner. Neighbouring controls tuck their slanted edges together.
//
// Supply actions in primary-first order. The bar's rects are in its parent's
// coordinates, so put it at the origin.
@interface TitleBar : SKNode
+ (CGFloat)heightCompact:(BOOL)compact;
// The controls are centred vertically in the supplied region.
- (instancetype)initWithHeader:(CGRect)header compact:(BOOL)compact back:(UIBarAction *)back
                         title:(NSString *)title kicker:(NSString *)kicker actions:(NSArray<UIBarAction *> *)actions;
- (CGRect)rectForAction:(UIBarAction *)action;
- (BOOL)activateAt:(CGPoint)point;
- (void)beginAt:(CGPoint)point;
- (void)endPress;
@property (nonatomic, readonly) CGFloat height, fontSize;
@property (nonatomic, readonly) CGRect row, lane;   // the whole bar, and the space for the title
@property (nonatomic, readonly) NSArray<SKShapeNode *> *controls;   // in the order added
@property (nonatomic, readonly) SKShapeNode *action;                // the primary action
@property (nonatomic, readonly) SKLabelNode *titleLabel, *kickerLabel;
- (void)registerHover:(UIHover *)hover;
// The controls drop in from above in turn and the title decodes.
- (void)revealAfter:(NSTimeInterval)delay;
@end

// MARK: - UITouchControls

// Shared flight control artwork and hit geometry. The UIKit adapter supplies
// touches; the reference renderer uses the same layout and visual states.
typedef NS_ENUM(NSInteger, TouchControl) {
    TouchControlNone = -1,
    TouchControlStick, TouchControlThrottle, TouchControlFire,
    TouchControlSecondary, TouchControlTarget, TouchControlPause, TouchControlCount
};

@interface UITouchControls : SKNode
@property (nonatomic) BOOL controllerConnected;
@property (nonatomic, readonly) NSDictionary<NSNumber *, SKLabelNode *> *buttonLabels;
+ (CGRect)pauseRectForSize:(CGSize)size insets:(ScreenInsets)insets;
- (void)layoutWithSize:(CGSize)size insets:(ScreenInsets)insets;
- (TouchControl)controlAt:(CGPoint)point; // top-origin view points
- (CGPoint)centerForControl:(TouchControl)control;
- (CGRect)rectForControl:(TouchControl)control; // scene points
- (void)setSecondaryLabel:(NSString *)label;
- (void)displayStick:(CGPoint)position stretched:(BOOL)stretched;
- (void)displayThrottle:(float)value;
- (void)setPressed:(BOOL)pressed control:(TouchControl)control;
@end
