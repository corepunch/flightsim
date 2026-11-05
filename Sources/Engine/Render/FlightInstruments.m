#import "FlightInstruments.h"
#import "UIStyle.h"
#import "Localization.h"
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
    SCNNode *_camera, *_holder, *_model, *_key;
    id _source;
    simd_float3 _boundsMin, _boundsMax;   // the model's box, in holder space
    float _fit;                           // eased orthographic half-height
}
- (instancetype)initWithPreview:(BOOL)preview {
    if ((self = [super init])) {
        self.name = @"Target readout";
        _empty = Readout(self, L10n(@"cockpit.no_target"), 304, 215, 24, SKLabelHorizontalAlignmentModeCenter);
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
            // The free space between the stat columns and the name and mode lines.
            _preview = [SKSpriteNode spriteNodeWithColor:SKColor.clearColor size:CGSizeMake(300, 205)];
            _preview.position = CGPointMake(304, 220);
            // The target as the world draws it, lit by the sun from where we
            // look at it, framed to fill the display.
            SCNScene *scene = [SCNScene scene];
            scene.background.contents = SKColor.clearColor;
            scene.lightingEnvironment.contents = [SKColor colorWithWhite:0.32 alpha:1];
            scene.lightingEnvironment.intensity = 1;
            _holder = [SCNNode node];
            [scene.rootNode addChildNode:_holder];
            _camera = [SCNNode node]; _camera.camera = [SCNCamera camera];
            _camera.camera.usesOrthographicProjection = YES; _camera.camera.orthographicScale = 1.05;
            _camera.camera.zNear = 0.1; _camera.camera.zFar = 20;
            _camera.position = SCNVector3Make(0, 0, 6);
            [scene.rootNode addChildNode:_camera];
            _key = [SCNNode node]; _key.light = [SCNLight light];
            _key.light.type = SCNLightTypeDirectional; _key.light.intensity = 1400;
            [scene.rootNode addChildNode:_key];
            SCNNode *fill = [SCNNode node]; fill.light = [SCNLight light];
            fill.light.type = SCNLightTypeDirectional; fill.light.intensity = 350;
            fill.light.color = [SKColor colorWithRed:0.7 green:0.8 blue:1 alpha:1];
            fill.simdOrientation = simd_quaternion(simd_make_float3(0, 0, -1), simd_normalize(simd_make_float3(0.4f, 0.25f, -1)));
            [scene.rootNode addChildNode:fill];
            SCNNode *ambient = [SCNNode node]; ambient.light = [SCNLight light];
            ambient.light.type = SCNLightTypeAmbient; ambient.light.intensity = 220;
            [scene.rootNode addChildNode:ambient];
            _previewRenderer = [SCNRenderer rendererWithDevice:MTLCreateSystemDefaultDevice() options:nil];
            _previewRenderer.scene = scene; _previewRenderer.pointOfView = _camera;
            [_info addChild:_preview];
            _previewAt = -1;
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
    _preview.size = CGSizeMake(compact ? 280 : 300, compact ? 150 : 205);
    _preview.position = CGPointMake(304, compact ? 155 : 220);
}
- (void)updateFrame:(CockpitFrame)f contacts:(const CockpitContact *)contacts count:(NSUInteger)count {
    BOOL has = f.alive && f.target >= 0 && f.target < (int)count;
    _info.hidden = !has; _empty.hidden = has;
    if (!has) return;
    CockpitContact c = contacts[f.target];
    _name.text = Short(c.name, 31); _name.fontColor = ContactInk(c.relation);
    _kind.text = L10nFormat(@"cockpit.kind", L10n(c.relation == RelationHostile ? @"cockpit.hostile" : c.relation == RelationFriendly ? @"cockpit.friendly" : @"cockpit.neutral"), Short(c.className, 25));
    _shield.text = L10nFormat(@"cockpit.target_shield", (int)lroundf(c.shield * 100));
    _hull.text = L10nFormat(@"cockpit.target_hull", (int)lroundf(c.hull * 100));
    _hull.fontColor = UIColorWithOpacity(c.hull < 0.3 ? UIRed : UIInk, 1);
    _systems.text = c.systems < 0 ? L10n(@"cockpit.target_systems_na") : L10nFormat(@"cockpit.target_systems", (int)lroundf(c.systems * 100));
    _range.text = L10nFormat(@"units.km2", simd_length(c.local) / 1000);
    _closing.text = L10nFormat(@"units.closing", (int)lroundf(f.closingSpeed));
    _cargo.text = L10nFormat(@"cockpit.cargo", Short(c.cargo ?: L10n(@"cockpit.unknown"), 36));
    _component.text = L10nFormat(@"cockpit.part", Short(c.component ?: L10n(@"part.hull"), 36));
    _mode.text = L10n(f.lock ? @"cockpit.mode_lock" : c.attacking ? @"cockpit.mode_attack" : c.capital ? (c.shielded ? @"cockpit.mode_shielded" : @"cockpit.mode_vulnerable") : @"cockpit.mode_tracking");
    _mode.fontColor = UIColorWithOpacity(c.attacking ? UIRed : f.lock ? UIFriendly : UIAmber, 1);
    if (_preview) {
        if (_source != c.preview) {
            _source = c.preview;
            [_model removeFromParentNode];
            // A clone shares geometry and materials (hull styles, running
            // lights) with the world's copies.
            _model = [(SCNNode *)c.preview clone];
            if (_model) {
                [_holder addChildNode:_model];
                SCNVector3 lo, hi;
                if ([_model getBoundingBoxMin:&lo max:&hi]) {
                    // Normalise to a unit radius about the box centre.
                    simd_float3 min = SCNVector3ToFloat3(lo), max = SCNVector3ToFloat3(hi);
                    float radius = fmaxf(0.001f, simd_length(max - min) / 2);
                    _model.simdPivot = matrix_identity_float4x4;
                    _model.simdPosition = -(min + max) / 2 / radius;
                    _model.simdScale = simd_make_float3(1, 1, 1) / radius;
                    _boundsMin = (min - (min + max) / 2) / radius;
                    _boundsMax = (max - (min + max) / 2) / radius;
                }
            }
            _fit = 0;
        }
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
        simd_quatf toView = simd_inverse(view);
        _holder.simdOrientation = simd_mul(toView, c.orientation);
        // The sun lights it from the side it lights the real ship.
        simd_float3 sun = simd_length_squared(f.sun) > 1e-6f ? simd_normalize(simd_act(toView, f.sun)) : simd_make_float3(-0.5f, 0.6f, 0.6f);
        _key.simdOrientation = simd_quaternion(simd_make_float3(0, 0, -1), -sun);
        // Frame the box as it faces us now: fit its projected extent to the
        // display, so a fighter seen nose-on fills it as well as side-on.
        if (_model) {
            simd_float2 lo = simd_make_float2(FLT_MAX, FLT_MAX), hi = -lo;
            for (int i = 0; i < 8; i++) {
                simd_float3 corner = simd_make_float3(i & 1 ? _boundsMax.x : _boundsMin.x, i & 2 ? _boundsMax.y : _boundsMin.y,
                                                      i & 4 ? _boundsMax.z : _boundsMin.z);
                simd_float3 p = simd_act(_holder.simdOrientation, corner);
                lo = simd_min(lo, p.xy); hi = simd_max(hi, p.xy);
            }
            float aspect = (float)(_preview.size.width / fmax(1, _preview.size.height));
            float fit = fmaxf(0.05f, fmaxf((hi.y - lo.y) / 2, (hi.x - lo.x) / 2 / aspect)) * 1.12f;
            _fit = _fit > 0 ? _fit + (fit - _fit) * 0.35f : fit;
            simd_float2 centre = (lo + hi) / 2;
            _camera.camera.orthographicScale = _fit;
            _camera.simdPosition = simd_make_float3(centre.x, centre.y, 6);
        }
        if (_previewAt < 0 || f.time < _previewAt || f.time - _previewAt >= 0.12) {
            _previewAt = f.time;
            PlatformImage *picture = [_previewRenderer snapshotAtTime:f.time withSize:CGSizeMake(_preview.size.width * 2, _preview.size.height * 2) antialiasingMode:SCNAntialiasingModeMultisampling4X];
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
        Readout(self, L10n(rear ? @"cockpit.scanner_rear" : @"cockpit.scanner_forward"), 0, 76, 11, SKLabelHorizontalAlignmentModeCenter);
        _range = Readout(self, L10nFormat(@"units.km0", 5.0), 0, -76, 10, SKLabelHorizontalAlignmentModeCenter);
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
    _range.text = L10nFormat(@"units.km0", range / 1000);
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
