#import <SceneKit/SceneKit.h>
#import <simd/simd.h>
#import "Ship.h"

#define COCKPIT_MAX_CONTACTS 12

typedef struct {
    simd_float3 local;          // position in player ship space (-Z forward), metres
    simd_quatf orientation;     // relative to the player ship
    float hull, shield;
    ShipClass shipClass;
    BOOL attacking;             // in an attack run on the player
} CockpitContact;

typedef struct {
    float throttle, speed, maxSpeed, boostEnergy, hull, shield;
    float damageFlash;          // 0..1, decays after a hit
    BOOL boosting, firing, alive;
    float pitch, yaw, roll;     // stick deflection, -1..1
    int kills, deaths;
    double time;
    int target;                 // index into the contacts, -1 for none
    float closingSpeed;         // towards the target, m/s
    BOOL lock;                  // lead marker under the boresight
    BOOL six;                   // someone attacking from behind
    float nearest;              // distance to the closest contact, metres
} CockpitFrame;

// The player's cockpit: Resources/Models/Cockpit.obj (built by
// Art/build_cockpit.py) with live SpriteKit scenes on its displays and
// emissive annunciators. Screens and lamps are found by material name.
@interface Cockpit : NSObject

@property (nonatomic, readonly) SCNNode *node;   // origin is the pilot's eye

- (instancetype)initWithDevice:(id<MTLDevice>)device;
// Renders the displays into their textures; call before the frame renders.
- (void)renderDisplaysWithQueue:(id<MTLCommandQueue>)queue time:(NSTimeInterval)time;

- (void)updateFrame:(CockpitFrame)frame contacts:(const CockpitContact *)contacts count:(NSUInteger)count;

@end
