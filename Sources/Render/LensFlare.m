#import "Render.h"
#import "Common.h"

// Shape references: Cooke's photographed anamorphic flares and ShareGrid's
// Kowa tests. The streak is blue at its shoulders, warm near the source;
// the much fainter reflections follow the source / optical-centre axis.
// https://cookeoptics.com/news-and-events/an-introduction-to-anamorphic-lenses/
// https://www.sharegrid.com/learn/lens-sets/kowa-cine-prominar-anamorphic
static SKShader *FlareShader(int profile) {
    static NSArray<SKShader *> *shaders;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle URLForResource:@"LensFlare" withExtension:@"fsh" subdirectory:@"Shaders"];
        NSString *source = url ? [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL] : nil;
        if (!source) NSLog(@"LensFlare: missing Shaders/LensFlare.fsh");
        NSMutableArray *profiles = [NSMutableArray array];
        for (int i = 0; i < 3; i++) {
            SKShader *shader = [SKShader shaderWithSource:source ?: @"void main() { gl_FragColor = vec4(0.0); }"];
            shader.uniforms = @[
                [SKUniform uniformWithName:@"u_profile" float:i],
                [SKUniform uniformWithName:@"u_layerCoverage" float:TARGET_OS_IOS ? 1 : 0],
            ];
            [profiles addObject:shader];
        }
        shaders = profiles;
    });
    return shaders[profile];
}

@implementation LensFlare {
    SKSpriteNode *_streak, *_glare, *_ghosts[3];
    CGFloat _visibility;
}

- (SKSpriteNode *)spriteWithProfile:(int)profile {
    // If a device ever rejects the shader, SpriteKit's ordinary texture path
    // must draw nothing instead of substituting an opaque rectangular sprite.
    static SKTexture *transparent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        transparent = [SKTexture textureWithData:[NSData dataWithBytes:(uint8_t[4]){0} length:4] size:CGSizeMake(1, 1)];
    });
    SKSpriteNode *sprite = [SKSpriteNode spriteNodeWithTexture:transparent];
    sprite.shader = FlareShader(profile);
    sprite.blendMode = SKBlendModeAdd;
    [self addChild:sprite];
    return sprite;
}

- (instancetype)init {
    if ((self = [super init])) {
        self.name = @"lensFlare";
        self.hidden = YES;
        _glare = [self spriteWithProfile:1];
        _streak = [self spriteWithProfile:0];
        for (int i = 0; i < 3; i++) _ghosts[i] = [self spriteWithProfile:2];
    }
    return self;
}

- (void)updateSource:(CGPoint)source visibility:(CGFloat)visibility
           viewport:(CGSize)viewport deltaTime:(NSTimeInterval)dt {
    if (viewport.width <= 0 || viewport.height <= 0 ||
        !isfinite(source.x) || !isfinite(source.y) || !isfinite(visibility) || visibility <= 0) {
        _visibility = 0;
        self.hidden = YES;
        return;
    }
    CGFloat shortSide = MIN(viewport.width, viewport.height);
    CGFloat edge = MIN(MIN(source.x, viewport.width - source.x), MIN(source.y, viewport.height - source.y));
    CGFloat fade = MAX(0, MIN(1, edge / (shortSide * 0.09)));
    fade = fade * fade * (3 - 2 * fade);
    CGFloat target = MIN(visibility, 1) * fade;
    // Occlusion removes the flare immediately; emergence is a short, stable
    // exposure response, independent of the rendering frame rate.
    if (target < _visibility) _visibility = target;
    else _visibility += (target - _visibility) * (1 - exp(-14 * MAX(0, MIN(dt, 0.1))));
    self.hidden = _visibility < 0.001;
    if (self.hidden) return;
    self.alpha = _visibility;

    _streak.position = _glare.position = source;
    _streak.size = CGSizeMake(MIN(viewport.width * 1.15, shortSide * 1.8), shortSide * 0.065);
    _glare.size = CGSizeMake(shortSide * 0.24, shortSide * 0.24);
    _glare.alpha = 0.92;
    _streak.alpha = 0.8;

    CGPoint centre = PointScale(PointFromSize(viewport), 0.5);
    CGPoint axis = PointSub(source, centre);   // ghosts sit along the line through the optical centre
    CGFloat separation = PointLength(axis) / shortSide;
    CGFloat ghosts = MIN(1, separation / 0.25);
    ghosts *= ghosts; // Reflections merge into the source at the optical centre.
    const CGFloat offset[] = { -0.45, -1.15, 0.30 };
    const CGFloat diameter[] = { 0.105, 0.065, 0.045 };
    const CGFloat intensity[] = { 0.045, 0.028, 0.04 };
    for (int i = 0; i < 3; i++) {
        _ghosts[i].position = PointAdd(centre, PointScale(axis, offset[i]));
        _ghosts[i].size = CGSizeMake(shortSide * diameter[i], shortSide * diameter[i] * 1.45);
        _ghosts[i].alpha = intensity[i] * ghosts;
    }
}
@end
