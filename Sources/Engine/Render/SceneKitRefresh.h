#import <SceneKit/SceneKit.h>
#import "Refresh.h"

// The Refresh backend on SceneKit: one SCNScene holding the sky, sun, camera,
// the player's ship rig and cockpit, the world's entity nodes and the effect
// pools. Only the platform glue (Host, FXRecorder) knows this class; the
// client talks to it through <Refresh>.
@interface SceneKitRefresh : NSObject <Refresh>

// `renderer` is the view (or offscreen renderer) the scene is drawn with; it
// projects points and uploads to the GPU. `size` is used when it is not a
// view.
- (instancetype)initWithRenderer:(id<SCNSceneRenderer>)renderer size:(CGSize)size;

// Load queue, instead of -buildWorld: a black studio with a neutral key and
// fill light and no sky, for effect previews (--record-fx).
- (void)buildStudio;

@property (nonatomic, readonly) SCNScene *scene;
@property (nonatomic, readonly) SCNNode *cameraNode;

@end
