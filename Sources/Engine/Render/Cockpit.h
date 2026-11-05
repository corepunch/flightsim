#import <SceneKit/SceneKit.h>
#import <simd/simd.h>
#import "ShipView.h"
#import "CockpitFrame.h"

// The player's cockpit: Resources/Models/Cockpit.scn, baked from Cockpit.obj (built by
// Art/build_cockpit.py) with live SpriteKit scenes on its displays and
// emissive annunciators. Screens and lamps are found by material name.
@interface Cockpit : NSObject

@property (nonatomic, readonly) SCNNode *node;   // origin is the pilot's eye

- (instancetype)initWithDevice:(id<MTLDevice>)device;
// Renders the displays into their textures; call before the frame renders.
- (void)renderDisplaysWithQueue:(id<MTLCommandQueue>)queue time:(NSTimeInterval)time;

- (void)updateFrame:(CockpitFrame)frame contacts:(const CockpitContact *)contacts count:(NSUInteger)count;
// The player's own ship, for the status display's hologram (OBJ space, +Z nose).
- (void)setSelfGeometry:(SCNGeometry *)geometry;

@end
