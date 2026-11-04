#import <SpriteKit/SpriteKit.h>

typedef struct {
    CGPoint boresight;      // where the guns converge, view points
    BOOL boresightVisible;
    CGPoint mouseStick;     // -1..1
    BOOL mouseCaptured;
    float throttle, boostEnergy, speed, hull, shield;
    BOOL boosting;
    int kills, deaths;
    BOOL playerDead;
    CGPoint sun;            // lens flare source, view points
    float sunVisibility;    // 0..1
    float damageFlash;      // 0..1
    BOOL cockpit;           // gauges are on the cockpit displays instead
    int torpedoes;
    BOOL aimVisible;        // subsystem aim marker on the selected capital
    CGPoint aim;
    __unsafe_unretained NSString *status;   // under the boresight, e.g. "SCANNING 40%"
} HUDFrame;

typedef NS_ENUM(int, HUDKind) { HUDKindEnemy, HUDKindFriend, HUDKindNeutral, HUDKindNav };

typedef struct {
    CGPoint point;          // projected position (clamped to edge if off-screen)
    BOOL onScreen;
    float angle;            // arrow direction when off-screen
    float distance;
    float size;             // bracket size, points
    BOOL hasLead;
    CGPoint lead;
    float health;
    HUDKind kind;
    BOOL capital, selected;
    __unsafe_unretained NSString *label;
} HUDTarget;

@interface HUD : SKScene

- (void)updateFrame:(HUDFrame)frame targets:(const HUDTarget *)targets count:(NSUInteger)count;
- (void)setInputText:(NSString *)text;
- (void)toggleHelp;
- (void)setHelpVisible:(BOOL)visible;
// Objective lines; state per line: 0 active, 1 complete, 2 failed, 3 optional.
- (void)setObjectives:(NSArray<NSString *> *)lines states:(NSArray<NSNumber *> *)states;
- (void)showMessage:(NSString *)text from:(NSString *)from;
- (void)showBanner:(NSString *)text color:(NSColor *)color;
- (void)clearMessages;

@end
