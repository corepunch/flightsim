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
} HUDFrame;

typedef struct {
    CGPoint point;          // projected position (clamped to edge if off-screen)
    BOOL onScreen;
    float angle;            // arrow direction when off-screen
    float distance;
    float size;             // bracket size, points
    BOOL hasLead;
    CGPoint lead;
    float health;
} HUDTarget;

@interface HUD : SKScene

- (void)updateFrame:(HUDFrame)frame targets:(const HUDTarget *)targets count:(NSUInteger)count;
- (void)setInputText:(NSString *)text;
- (void)toggleHelp;

@end
