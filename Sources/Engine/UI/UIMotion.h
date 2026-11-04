#import <SpriteKit/SpriteKit.h>

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
@end

// The system "reduce motion" setting: effects jump to their final state.
BOOL UIMotionReduced(void);
// SF_UI_SLOWMO=N (debug) plays all front-end motion N times slower.
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
