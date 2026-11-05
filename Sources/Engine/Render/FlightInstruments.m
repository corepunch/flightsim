#import "FlightInstruments.h"
#import "UIStyle.h"
#import "MonitorSignal.h"
#import "UIMotion.h"
#import "PlatformImage.h"
#import <Metal/Metal.h>

static SKColor *ContactInk(TeamRelation relation) {
    return UIColorWithOpacity(relation == RelationHostile ? UIRed : relation == RelationFriendly ? UIFriendly : UIHUDNeutral, 1);
}
static SKLabelNode *Readout(SKNode *parent, NSString *text, CGFloat x, CGFloat y, CGFloat size, SKLabelHorizontalAlignmentMode align) {
    SKLabelNode *label = UIMonoLabel(size, UIColorWithOpacity(UIInk, 1), align, SKLabelVerticalAlignmentModeCenter);
    label.fontName = UIMonoBoldFont;
    label.text = text; label.position = CGPointMake(x, y);
    [parent addChild:label];
    return label;
}
static NSString *Short(NSString *text, NSUInteger length) {
    NSString *upper = [text uppercaseString] ?: @"";
    return upper.length > length ? [[upper substringToIndex:length - 1] stringByAppendingString:@"…"] : upper;
}

@implementation TargetReadout {
    SKNode *_info;
    SKLabelNode *_empty, *_name, *_kind, *_shield, *_hull, *_systems, *_range, *_closing, *_cargo, *_component, *_mode;
    SKSpriteNode *_preview;
    SCNRenderer *_previewRenderer;
    double _previewAt;
    SCNNode *_holder, *_mesh;
    SCNGeometry *_source;
    SCNMaterial *_material;
}
- (instancetype)initWithPreview:(BOOL)preview {
    if ((self = [super init])) {
        self.name = @"Target readout";
        _empty = Readout(self, @"NO TARGET SELECTED", 304, 215, 24, SKLabelHorizontalAlignmentModeCenter);
        _info = [SKNode node]; [self addChild:_info];
        _name = Readout(_info, @"", 304, 370, 26, SKLabelHorizontalAlignmentModeCenter);
        _kind = Readout(_info, @"", 304, 337, 18, SKLabelHorizontalAlignmentModeCenter);
        _shield = Readout(_info, @"", 22, 275, 22, SKLabelHorizontalAlignmentModeLeft);
        _hull = Readout(_info, @"", 22, 233, 22, SKLabelHorizontalAlignmentModeLeft);
        _systems = Readout(_info, @"", 22, 191, 22, SKLabelHorizontalAlignmentModeLeft);
        _range = Readout(_info, @"", 586, 275, 22, SKLabelHorizontalAlignmentModeRight);
        _closing = Readout(_info, @"", 586, 233, 20, SKLabelHorizontalAlignmentModeRight);
        _mode = Readout(_info, @"", 304, 109, 22, SKLabelHorizontalAlignmentModeCenter);
        _cargo = Readout(_info, @"", 22, 65, 20, SKLabelHorizontalAlignmentModeLeft);
        _component = Readout(_info, @"", 22, 30, 20, SKLabelHorizontalAlignmentModeLeft);
        if (preview) {
            _preview = [SKSpriteNode spriteNodeWithColor:SKColor.clearColor size:CGSizeMake(220, 205)];
            _preview.position = CGPointMake(304, 220);
            SCNScene *scene = [SCNScene scene];
            scene.background.contents = SKColor.clearColor;
            _holder = [SCNNode node]; _mesh = [SCNNode node];
            [_holder addChildNode:_mesh]; [scene.rootNode addChildNode:_holder];
            SCNNode *camera = [SCNNode node]; camera.camera = [SCNCamera camera];
            camera.camera.usesOrthographicProjection = YES; camera.camera.orthographicScale = 1.05;
            camera.position = SCNVector3Make(0, 0, 4);
            [scene.rootNode addChildNode:camera];
            _previewRenderer = [SCNRenderer rendererWithDevice:MTLCreateSystemDefaultDevice() options:nil];
            _previewRenderer.scene = scene; _previewRenderer.pointOfView = camera;
            _preview.shader = UIMotionReduced() ? nil : UIMonitorSignalShader(YES);
            [_preview setValue:[SKAttributeValue valueWithVectorFloat2:(vector_float2){220, 205}] forAttributeNamed:@"a_screen_size"];
            [_info addChild:_preview];
            _previewAt = -1;
            _material = [SCNMaterial material];
            _material.lightingModelName = SCNLightingModelConstant;
            _material.fillMode = SCNFillModeLines; _material.doubleSided = YES;
        }
    }
    return self;
}
- (void)setCompact:(BOOL)compact {
    // The phone panel keeps full-size text while reducing vertical spacing.
    CGFloat height = compact ? 310 : 400;
    _empty.position = CGPointMake(304, 20);
    _name.position = CGPointMake(304, height - 30);
    _kind.position = CGPointMake(304, height - 63);
    _shield.position = CGPointMake(22, compact ? 169 : 275);
    _hull.position = CGPointMake(22, compact ? 139 : 233);
    _systems.position = CGPointMake(22, compact ? 109 : 191);
    _range.position = CGPointMake(586, compact ? 169 : 275);
    _closing.position = CGPointMake(586, compact ? 139 : 233);
    _mode.horizontalAlignmentMode = compact ? SKLabelHorizontalAlignmentModeRight : SKLabelHorizontalAlignmentModeCenter;
    _mode.position = CGPointMake(compact ? 586 : 304, compact ? 21 : 109);
    _cargo.position = CGPointMake(22, compact ? 48 : 65);
    _component.position = CGPointMake(22, compact ? 21 : 30);
    _preview.size = CGSizeMake(compact ? 240 : 220, compact ? 150 : 205);
    _preview.position = CGPointMake(304, compact ? 155 : 220);
    [_preview setValue:[SKAttributeValue valueWithVectorFloat2:(vector_float2){compact ? 240 : 220, compact ? 150 : 205}] forAttributeNamed:@"a_screen_size"];
}
- (void)updateFrame:(CockpitFrame)f contacts:(const CockpitContact *)contacts count:(NSUInteger)count {
    BOOL has = f.alive && f.target >= 0 && f.target < (int)count;
    _info.hidden = !has; _empty.hidden = has;
    if (!has) return;
    CockpitContact c = contacts[f.target];
    _name.text = Short(c.name, 31); _name.fontColor = ContactInk(c.relation);
    _kind.text = [NSString stringWithFormat:@"%@ / %@", c.relation == RelationHostile ? @"HOSTILE" : c.relation == RelationFriendly ? @"FRIENDLY" : @"NEUTRAL", Short(c.className, 25)];
    _shield.text = [NSString stringWithFormat:@"SHD %3d%%", (int)lroundf(c.shield * 100)];
    _hull.text = [NSString stringWithFormat:@"HUL %3d%%", (int)lroundf(c.hull * 100)];
    _hull.fontColor = UIColorWithOpacity(c.hull < 0.3 ? UIRed : UIInk, 1);
    _systems.text = c.systems < 0 ? @"SYS  N/A" : [NSString stringWithFormat:@"SYS %3d%%", (int)lroundf(c.systems * 100)];
    _range.text = [NSString stringWithFormat:@"%.2f KM", simd_length(c.local) / 1000];
    _closing.text = [NSString stringWithFormat:@"%+d M/S", (int)lroundf(f.closingSpeed)];
    _cargo.text = [@"CARGO: " stringByAppendingString:Short(c.cargo ?: @"UNKNOWN", 36)];
    _component.text = [@"PART: " stringByAppendingString:Short(c.component ?: @"FUSELAGE", 36)];
    _mode.text = f.lock ? @"FIRING SOLUTION" : c.attacking ? @"INCOMING ATTACK" : c.capital ? (c.shielded ? @"SHIELDED" : @"VULNERABLE") : @"TRACKING";
    _mode.fontColor = UIColorWithOpacity(c.attacking ? UIRed : f.lock ? UIFriendly : UIAmber, 1);
    if (_preview) {
        if (_source != c.hologram) {
            _source = c.hologram;
            _mesh.geometry = [(SCNGeometry *)c.hologram copy]; _mesh.geometry.materials = @[_material];
            SCNVector3 lo, hi;
            if ([_mesh getBoundingBoxMin:&lo max:&hi]) {
                float radius = fmaxf(0.001, simd_length(SCNVector3ToFloat3(hi) - SCNVector3ToFloat3(lo)) / 2);
                _mesh.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2);
                _mesh.scale = SCNVector3Make(1 / radius, 1 / radius, 1 / radius);
            }
            _mesh.eulerAngles = SCNVector3Make(0, fabsf(c.holoScale - 0.0075f) < 1e-5 ? M_PI : 0, 0);
        }
        _material.diffuse.contents = ContactInk(c.relation);
        // Look along the player-to-target line, using the player's up as the
        // horizon. Transform the target into that view, not merely into the
        // player's forward-facing coordinate system.
        float distance = simd_length(c.local);
        simd_float3 direction = distance > 0.001f ? c.local / distance : simd_make_float3(0, 0, -1);
        simd_float3 up = simd_make_float3(0, 1, 0);
        simd_float3 right = simd_cross(direction, up);
        if (simd_length_squared(right) < 1e-6f) right = simd_cross(direction, simd_make_float3(0, 0, 1));
        right = simd_normalize(right);
        up = simd_normalize(simd_cross(right, direction));
        simd_quatf view = simd_quaternion(simd_matrix(right, up, -direction));
        _holder.simdOrientation = simd_mul(simd_inverse(view), c.orientation);
        if (_previewAt < 0 || f.time < _previewAt || f.time - _previewAt >= 0.12) {
            _previewAt = f.time;
            PlatformImage *picture = [_previewRenderer snapshotAtTime:f.time withSize:CGSizeMake(240, 240 * _preview.size.height / _preview.size.width) antialiasingMode:SCNAntialiasingModeMultisampling2X];
            if (picture) _preview.texture = [SKTexture textureWithImage:picture];
        }
    }
}
@end

@implementation SensorScope {
    BOOL _rear;
    NSMutableArray<SKShapeNode *> *_blips;
    SKShapeNode *_selected;
    SKLabelNode *_range;
}
- (instancetype)initRear:(BOOL)rear {
    if ((self = [super init])) {
        _rear = rear; self.name = rear ? @"Rear scanner" : @"Forward scanner";
        SKShapeNode *disc = [SKShapeNode shapeNodeWithCircleOfRadius:64];
        disc.fillColor = UIColorWithOpacity(UIPanel, 0.9); disc.strokeColor = UIColorWithOpacity(UIInk, 0.65);
        [self addChild:disc];
        for (int i = 1; i < 3; i++) {
            SKShapeNode *ring = [SKShapeNode shapeNodeWithCircleOfRadius:64 * i / 3.0];
            ring.strokeColor = UIColorWithOpacity(UIInk, 0.18); [self addChild:ring];
        }
        SKShapeNode *cross = [SKShapeNode node];
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathMoveToPoint(path, NULL, -62, 0); CGPathAddLineToPoint(path, NULL, 62, 0);
        CGPathMoveToPoint(path, NULL, 0, -62); CGPathAddLineToPoint(path, NULL, 0, 62);
        cross.path = path; CGPathRelease(path); cross.strokeColor = UIColorWithOpacity(UIInk, 0.18); [self addChild:cross];
        Readout(self, rear ? @"REAR" : @"FORWARD", 0, 76, 11, SKLabelHorizontalAlignmentModeCenter);
        _range = Readout(self, @"5 KM", 0, -76, 10, SKLabelHorizontalAlignmentModeCenter);
        _blips = [NSMutableArray array];
        for (NSUInteger i = 0; i < COCKPIT_MAX_CONTACTS; i++) {
            SKShapeNode *blip = [SKShapeNode shapeNodeWithRectOfSize:CGSizeMake(4, 4)];
            blip.lineWidth = 1; blip.hidden = YES;
            [self addChild:blip]; [_blips addObject:blip];
        }
        _selected = [SKShapeNode shapeNodeWithRectOfSize:CGSizeMake(12, 12)];
        _selected.strokeColor = UIColorWithOpacity(UIAmber, 1); _selected.lineWidth = 2; _selected.hidden = YES;
        [self addChild:_selected];
    }
    return self;
}
- (void)updateFrame:(CockpitFrame)f contacts:(const CockpitContact *)contacts count:(NSUInteger)count {
    _selected.hidden = YES;
    float range = 5000;
    // Keep a selected distant craft on sensors, with an explicit range change.
    if (f.target >= 0 && f.target < (int)count) range = fmaxf(range, ceilf(simd_length(contacts[f.target].local) / 1000) * 1000);
    _range.text = [NSString stringWithFormat:@"%.0f KM", range / 1000];
    for (NSUInteger i = 0; i < _blips.count; i++) {
        SKShapeNode *blip = _blips[i]; blip.hidden = YES;
        if (!f.alive || i >= count) continue;
        CockpitContact c = contacts[i];
        float d = simd_length(c.local);
        if (d < 0.001 || d > range || (_rear ? c.local.z <= 0 : c.local.z > 0)) continue;
        float planar = hypotf(c.local.x, c.local.y);
        float forward = _rear ? c.local.z : -c.local.z;
        float radial = atan2f(planar, fmaxf(0, forward)) / M_PI_2 * 59;
        // Rear scope is the view looking aft: port/starboard is mirrored.
        CGPoint p = planar < 0.001 ? CGPointZero : CGPointMake((_rear ? -1 : 1) * c.local.x / planar * radial, c.local.y / planar * radial);
        blip.position = p; blip.hidden = NO;
        blip.strokeColor = blip.fillColor = ContactInk(c.relation);
        [blip setScale:c.capital ? 1.5 : 1];
        blip.alpha = c.attacking && fmod(f.time * 3, 1) > 0.5 ? 0.4 : 1;
        if ((int)i == f.target) { _selected.hidden = NO; _selected.position = p; }
    }
}
@end
