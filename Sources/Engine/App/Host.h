#import <SceneKit/SceneKit.h>
#import "Input.h"

// The application loop: boots the renderer, runs the menus and loading
// screens, and in a mission drives the local server and client each frame
// (input -> server ticks -> interpolated draw).
@interface Host : NSObject <SCNSceneRendererDelegate>

- (instancetype)initWithView:(SCNView *)view input:(Input *)input;

#if TARGET_OS_IOS
- (void)displayLinkTick:(CADisplayLink *)link;
#endif

@end
