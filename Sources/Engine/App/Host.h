#import <SceneKit/SceneKit.h>
#import "Input.h"

// The application loop: boots the renderer, runs the menus and loading
// screens, and in a mission drives the local server and the client once per
// rendered frame (input -> server ticks -> interpolated draw).
@interface Host : NSObject <SCNSceneRendererDelegate>

- (instancetype)initWithView:(SCNView *)view input:(Input *)input;

@end
