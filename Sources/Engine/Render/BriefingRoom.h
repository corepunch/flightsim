#import <SceneKit/SceneKit.h>
#import <SpriteKit/SpriteKit.h>
#import <Metal/Metal.h>

// The CNS Bastion briefing room behind the mission dialogue and tactical
// briefing: its own SceneKit scene, built from Resources/Models/BriefingRoom
// (Art/build_briefing_room.py) and Resources/Briefing/BriefingRoom.json.
//
// The big screen shows `presentation`, a SpriteKit scene the briefing UI
// draws into, rendered offscreen each frame like the cockpit displays. The
// audience are sprite planes: Resources/Briefing/Crowd/<Kind>_<n>.png on
// each Sprite_<Kind>_<n> material; a plane whose image is missing is hidden.
typedef NS_ENUM(NSInteger, RoomShot) {
    RoomShotEnter,     // from the doors at the back
    RoomShotWide,      // over the audience's heads: the dialogue
    RoomShotTactical,  // the screen on the right of the frame, room on the left
};

@interface BriefingRoom : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device;

@property (nonatomic, readonly) SCNScene *scene;
@property (nonatomic, readonly) SCNNode *cameraNode;
@property (nonatomic, readonly) SKScene *presentation;    // 1120 x 490 points, 16:7 like the screen
@property (nonatomic, readonly) RoomShot shot;

// Jump to a shot, or move there over `seconds` (eased).
- (void)cutTo:(RoomShot)shot;
- (void)moveTo:(RoomShot)shot seconds:(double)seconds;
// Sideways lean of the camera, -1..1 (toward the left or right speaker).
@property (nonatomic) float lean;

// Render thread.
- (void)updateAtTime:(double)time aspect:(CGFloat)aspect;
- (void)renderDisplaysWithQueue:(id<MTLCommandQueue>)queue time:(NSTimeInterval)time;
- (NSArray *)warmupObjects;

@end
