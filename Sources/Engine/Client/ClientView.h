#import <SceneKit/SceneKit.h>
#import "Input.h"
#import "HUD.h"
#include "Protocol.h"

// Everything the client draws: the SceneKit scene, one view per entity in
// the current (interpolated) frame, bolts and effects from events, the
// camera, HUD and cockpit. It knows nothing about gameplay; it draws models
// at coordinates and dresses them by the flags the server sends.
@interface ClientView : NSObject

- (instancetype)initWithView:(SCNView *)view input:(Input *)input;

@property (nonatomic, readonly) SCNScene *scene;
@property (nonatomic, readonly) SCNNode *cameraNode;
@property (nonatomic, readonly) HUD *hud;
@property (nonatomic) BOOL cockpit;
@property (nonatomic, copy) NSArray<NSString *> *configStrings;

// Load queue, once: scene, boot sky, camera, own ship, cockpit, effects.
- (void)buildScene;
- (NSArray *)warmupObjects;
// Load queue: the mission's sky and model prototypes, from configstrings.
// Returns nodes to upload with -prepareObject:.
- (NSArray *)loadMissionAssets:(float *)progress;
// Render thread: swap in what -loadMissionAssets: built.
- (void)attachMission;
// Render thread: drop every entity view, bolt and torpedo.
- (void)clearMission;

- (void)menuFrame:(double)time;
- (void)drawEntities:(const EntityState *)entities count:(NSUInteger)count player:(const PlayerState *)ps
            controls:(ControlState)controls time:(double)time dt:(float)dt;
- (void)handleEvent:(const GameEvent *)event player:(const PlayerState *)ps;
- (void)serverCommand:(int)type a:(NSString *)a b:(NSString *)b c:(NSString *)c;
- (void)renderDisplaysWithQueue:(id<MTLCommandQueue>)queue time:(NSTimeInterval)time;

@end
