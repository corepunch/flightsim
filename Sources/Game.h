#import <SceneKit/SceneKit.h>
#import "Input.h"

@interface Game : NSObject <SCNSceneRendererDelegate>

- (instancetype)initWithView:(SCNView *)view input:(Input *)input;

@end
