#import <SpriteKit/SpriteKit.h>

// Camera optics in view points, separate from the sky's HDR sun and bloom.
// The caller supplies visibility after testing the light against scene geometry.
@interface LensFlare : SKNode
- (void)updateSource:(CGPoint)source visibility:(CGFloat)visibility
           viewport:(CGSize)viewport deltaTime:(NSTimeInterval)dt;
@end
