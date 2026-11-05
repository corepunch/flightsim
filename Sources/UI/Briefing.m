#import "UI.h"
#import "Shared.h"
#import "Audio.h"
#import "Common.h"
#import "Story.h"
#import <ImageIO/ImageIO.h>

static SKLabelNode *Text(CGFloat size, SKColor *c, SKLabelHorizontalAlignmentMode h) {
    return UIInterfaceLabel(size, c, h, SKLabelVerticalAlignmentModeTop);
}

static SKLabelNode *Para(CGFloat size, SKColor *c, CGFloat width) {
    SKLabelNode *l = Text(size, c, SKLabelHorizontalAlignmentModeLeft);
    l.numberOfLines = 0;
    l.preferredMaxLayoutWidth = width;
    l.lineBreakMode = NSLineBreakByWordWrapping;
    return l;
}

static BOOL InsetsEqual(BriefingInsets a, BriefingInsets b) {
#if TARGET_OS_IOS
    return UIEdgeInsetsEqualToEdgeInsets(a, b);
#else
    return NSEdgeInsetsEqual(a, b);
#endif
}

typedef NS_ENUM(NSInteger, Mode) { ModeList, ModeBriefing, ModeDebrief };

typedef struct {
    CGPoint point;
    CGFloat delta;
} ScrollInput;

static const CGFloat ScrollGutter = 10;
static NSString *const PortraitDeparture = @"portraitDeparture";
// Reserve room for the widest portrait canvas at the shared height.
static const CGFloat MaxPortraitAspect = 1.04;
static const CGFloat CaptionDrop = 42;
static const CGFloat PortraitDepth = 1, CaptionDepth = 2, FooterDepth = 3;
static const CGFloat MonitorInset = 6;

// Offset every edge inward, including the diagonals, so the gap stays uniform.
static SKShapeNode *MonitorMask(const CGPoint *corners, NSUInteger count) {
    CGPoint inset[count];
    for (NSUInteger i = 0; i < count; i++) {
        CGPoint previous = corners[(i + count - 1) % count], point = corners[i];
        CGPoint next = corners[(i + 1) % count];
        CGPoint n = PointLeftNormal(previous, point), m = PointLeftNormal(point, next);
        inset[i] = PointAdd(point, PointScale(PointAdd(n, m), MonitorInset / (1 + PointDot(n, m))));
    }
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddLines(path, NULL, inset, count);
    CGPathCloseSubpath(path);
    SKShapeNode *mask = [SKShapeNode shapeNodeWithPath:path];
    CGPathRelease(path);
    mask.fillColor = SKColor.whiteColor;
    mask.strokeColor = SKColor.clearColor;
    mask.lineWidth = 0;
    return mask;
}

// MARK: - Speech bubble

// A speech bubble on screen: the panel (pivoting from its top edge), the
// speaker's name and the line, and where it stands.
typedef struct {
    SKNode *holder;
    SKLabelNode *name, *speech;
    CGRect rect;
    BOOL right;             // the speaker sits on the right
    NSString *speaker;
} Caption;

// Moves a caption out of *from, leaving it empty.
static Caption CaptionTake(Caption *from) {
    Caption caption = *from;
    *from = (Caption){0};
    return caption;
}

static NSArray<SKLabelNode *> *CaptionLabels(Caption c) {
    NSMutableArray *labels = [NSMutableArray array];
    if (c.name) [labels addObject:c.name];
    if (c.speech) [labels addObject:c.speech];
    return labels;
}

static NSArray<SKNode *> *CaptionNodes(Caption c) {
    NSArray<SKNode *> *labels = CaptionLabels(c);
    return c.holder ? [labels arrayByAddingObject:c.holder] : labels;
}

// Same voice, same bubble position: the next line reuses the bubble.
static BOOL CaptionContinues(Caption old, Caption next) {
    return old.holder && old.right == next.right && [old.speaker isEqualToString:next.speaker] &&
           fabs(CGRectGetMaxY(old.rect) - CGRectGetMaxY(next.rect)) < 1 &&
           fabs(CGRectGetWidth(old.rect) - CGRectGetWidth(next.rect)) < 1;
}

// MARK: - Shown state

// How a tactical cue arrives: the map powering up, the map wiped in fresh,
// the same map changing emphasis, or no motion.
typedef NS_ENUM(NSInteger, CueStyle) { CueStyleStill, CueStyleIntro, CueStyleFresh, CueStyleTween };

// Where the map looks: the x/z point at its middle and how many metres its
// shorter side spans. A zero span is "not set yet".
typedef struct {
    simd_float2 center;
    float span;
} MapCamera;

static MapCamera MapCameraLerp(MapCamera a, MapCamera b, float t) {
    // Zoom in log space so a long move feels even from start to end.
    return (MapCamera){ .center = a.center + (b.center - a.center) * t, .span = a.span * powf(b.span / a.span, t) };
}

static BOOL MapCameraNear(MapCamera a, MapCamera b) {
    return simd_distance(a.center, b.center) < 1 && fabsf(a.span - b.span) < 1;
}

// What a tactical cue emphasised, so the next one can animate from it.
typedef struct {
    NSString *focus;
    NSArray<NSString *> *route;
    NSDictionary<NSString *, NSNumber *> *alpha;
    MapCamera camera;
} MapEmphasis;

// What the previous build put on screen, so the next one can animate from
// it rather than popping. An intro forgets all but the mode.
typedef struct {
    Mode mode;
    NSString *channel, *content, *action;   // monitor channel, content kind, footer action
    MapEmphasis map;
} Shown;

// A briefing that plays by itself: timed steps advance after their caption
// has typed plus their seconds, until the player touches anything.
typedef struct {
    BOOL stopped;
    BOOL armed;             // the current page's clock is running
    NSUInteger page;        // the page it was armed for
    double due;             // scene time to move on
} Autoplay;

// Where the footer's buttons are, for clicks.
typedef struct {
    CGRect confirm, previous, back;
} FooterButtons;

// The mission list's tiles, for clicks and keyboard navigation.
typedef struct {
    CGRect rows;
    NSUInteger columns;
    NSArray<NSValue *> *tiles;
} MissionGrid;

// MARK: - Text viewport

// Clips text to a rect and, when it overflows, shows a scroll bar. Measures
// on creation, before reveal animations change the labels' frames.
@interface TextViewport : SKNode
- (instancetype)initWithRect:(CGRect)rect content:(SKNode *)content;
@property (nonatomic, readonly) CGRect rect;
@property (nonatomic, readonly) CGFloat limit;   // how far the content can scroll; 0 if it fits
@property (nonatomic, readonly) SKNode *content;
- (void)showOffset:(CGFloat)offset;
@end

@implementation TextViewport {
    SKSpriteNode *_thumb;
}

- (instancetype)initWithRect:(CGRect)rect content:(SKNode *)content {
    if (!(self = [super init]) || CGRectIsEmpty(rect)) return self;
    _rect = rect;
    SKCropNode *crop = [SKCropNode node];
    SKSpriteNode *mask = [SKSpriteNode spriteNodeWithColor:SKColor.whiteColor size:rect.size];
    mask.position = RectCenter(rect);
    crop.maskNode = mask;
    [crop addChild:content];
    [self addChild:crop];
    _content = content;

    CGFloat overflow = CGRectGetMinY(rect) - CGRectGetMinY([content calculateAccumulatedFrame]);
    if (overflow <= 0.5) return self;
    _limit = overflow;
    CGFloat height = CGRectGetHeight(rect), x = CGRectGetMaxX(rect) - 2;
    SKSpriteNode *track = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.22)
                                                      size:CGSizeMake(2, height)];
    track.position = CGPointMake(x, CGRectGetMidY(rect));
    [self addChild:track];
    CGFloat thumbHeight = MIN(height, MAX(12, height * height / (height + overflow)));
    _thumb = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.8) size:CGSizeMake(3, thumbHeight)];
    _thumb.position = CGPointMake(x, 0);
    _thumb.zPosition = 1;
    [self addChild:_thumb];
    return self;
}

- (void)showOffset:(CGFloat)offset {
    if (_limit <= 0) return;
    _content.position = CGPointMake(0, offset);
    CGFloat thumbHeight = _thumb.size.height;
    CGFloat y = CGRectGetMaxY(_rect) - thumbHeight / 2 - (CGRectGetHeight(_rect) - thumbHeight) * offset / _limit;
    _thumb.position = CGPointMake(_thumb.position.x, y);
}

@end

// MARK: - Tactical map

// One thing on the tactical map.
@interface MapItem : NSObject
@property (nonatomic, copy) NSString *identifier, *group;
@property (nonatomic) BOOL container;
@property (nonatomic) CGPoint point;                  // where the camera puts it, in the map layer
@property (nonatomic) simd_float3 world;
@property (nonatomic, strong) SKNode *node;
@property (nonatomic, strong) SKNode *extent;         // a drawing in metres (a minefield) that zooms with the camera
@end
@implementation MapItem
@end

// What the map draws for one thing in the level.
typedef NS_ENUM(NSInteger, ContactKind) { ContactPlayer, ContactCapital, ContactNav, ContactWave, ContactMines, ContactRocks };

typedef struct {
    ContactKind kind;
    NSString *identifier, *label, *team, *group, *asset;
    simd_float3 pos, size;          // size: a minefield's extent
    float radius;                   // an asteroid field's
} MapContact;

// Everything in the level with a place on the map, in drawing order.
static void EachContact(const LevelDef *level, void (^body)(MapContact contact)) {
    body((MapContact){ .kind = ContactPlayer, .identifier = @"start", .pos = level->playerPos,
                       .label = L10n(@"briefing.map_player"), .team = @"friend" });
    for (int i = 0; i < level->entityCount; i++) {
        const LevelEntity *e = &level->entities[i];
        body((MapContact){ .kind = ContactCapital, .identifier = e->identifier, .pos = e->pos, .team = e->team,
                           .label = e->name ?: e->asset, .asset = e->asset, .group = e->group });
    }
    for (int i = 0; i < level->navCount; i++) {
        const LevelNav *n = &level->navs[i];
        body((MapContact){ .kind = ContactNav, .identifier = n->identifier, .pos = n->pos, .label = n->name });
    }
    for (int i = 0; i < level->waveCount; i++) {
        const LevelWave *w = &level->waves[i];
        const ShipDef *ship = ShipDefNamed(w->ship);
        NSString *label = w->name ?: L10nFormat(@"briefing.map_wave", @(w->count), ship ? @(ship->displayName) : w->ship);
        const LevelEntity *carrier = w->mothership ? LevelEntityNamed(level, w->mothership) : NULL;   // launches from it
        body((MapContact){ .kind = ContactWave, .identifier = w->identifier, .pos = carrier ? carrier->pos : w->pos, .team = w->team, .label = label });
    }
    for (int i = 0; i < level->fieldCount; i++) {
        const LevelField *f = &level->fields[i];
        if (f->kind == LevelFieldMines)
            body((MapContact){ .kind = ContactMines, .identifier = f->group, .pos = f->center, .size = f->size, .team = @"enemy",
                               .label = L10n(@"briefing.map_minefield") });
        else if (f->kind == LevelFieldAsteroids)
            body((MapContact){ .kind = ContactRocks, .identifier = @"_rocks", .pos = f->center, .radius = f->radius });
    }
}

static SKColor *TeamColor(NSString *team) {
    if ([team isEqualToString:@"enemy"]) return UIColorWithOpacity(UIRed, 1);
    if ([team isEqualToString:@"neutral"]) return UIColorWithOpacity(UIYellow, 1);
    return UIColorWithOpacity(UIBlue, 1);
}

static SKShapeNode *ClosedShape(const CGPoint *points, size_t count) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddLines(path, NULL, points, count);
    CGPathCloseSubpath(path);
    SKShapeNode *shape = [SKShapeNode shapeNodeWithPath:path];
    CGPathRelease(path);
    return shape;
}

// The mission seen from above: contacts on the x/z plane, a dashed route and
// a lock on the focus. Each briefing step lights some of it.
@interface TacticalMap : SKCropNode
- (instancetype)initWithLevel:(const LevelDef *)level rect:(CGRect)rect;
// Applies a step's show/focus/route, animated from what was shown before;
// returns what this cue shows. A nil step dims nothing in particular.
- (MapEmphasis)applyCue:(BriefingStep *)step style:(CueStyle)style after:(MapEmphasis)shown;
- (void)pulse:(double)time;
@end

@implementation TacticalMap {
    CGRect _rect;
    CGFloat _fitScale;              // map points per metre when everything fits
    CGFloat _scale;                 // map points per metre under the current camera
    MapCamera _fit, _camera;
    NSMutableDictionary<NSString *, MapItem *> *_items;
    NSMutableArray<MapItem *> *_scenery, *_notes;
    SKNode *_layer, *_routeLayer, *_focusLock, *_noteLayer;
    SKSpriteNode *_scaleBar;
    SKLabelNode *_scaleLabel;
    SKShapeNode *_focusRing, *_routeLine;
    NSArray<NSString *> *_routeIDs;
    CGFloat _routeFraction;         // how much of the route is drawn while it plots
    SKShapeNode *_routeDot;
    MapItem *_focusItem;
}

- (instancetype)initWithLevel:(const LevelDef *)level rect:(CGRect)rect {
    if (!(self = [super init])) return nil;
    _rect = rect;
    _items = [NSMutableDictionary dictionary];
    _scenery = [NSMutableArray array];
    _notes = [NSMutableArray array];
    _routeFraction = 1;
    SKSpriteNode *mask = [SKSpriteNode spriteNodeWithColor:[SKColor whiteColor] size:rect.size];
    mask.position = RectCenter(rect);
    self.maskNode = mask;
    _layer = [SKNode node];
    [self addChild:_layer];

    // Fit the x/z plane of everything placed (fields of rocks aside) into the map.
    __block simd_float3 lo = simd_make_float3(FLT_MAX), hi = simd_make_float3(-FLT_MAX);
    EachContact(level, ^(MapContact c) {
        if (c.kind == ContactRocks) return;
        lo = simd_min(lo, c.pos);
        hi = simd_max(hi, c.pos);
    });
    simd_float3 extent = hi - lo, centre = (lo + hi) / 2;
    _fit = (MapCamera){ .center = simd_make_float2(centre.x, centre.z),
                        .span = fmaxf(fmaxf(extent.x, extent.z), 800.0f) * 1.25f };
    _camera = _fit;
    _fitScale = _scale = MIN(rect.size.width, rect.size.height) / _fit.span;
    [self addGrid];
    CGPoint playerPoint = [self project:level->playerPos];
    EachContact(level, ^(MapContact c) { [self addContact:c at:[self project:c.pos] player:playerPoint]; });
    [self addFocusLock];
    _noteLayer = [SKNode node];
    [_layer addChild:_noteLayer];
    [self showCamera:_fit];
    return self;
}

// Forward (-Z) is up on the map.
- (CGPoint)project:(simd_float3)world {
    simd_float2 d = (simd_make_float2(world.x, world.z) - _camera.center) * (float)_scale;
    return PointAdd(RectCenter(_rect), CGPointMake(d.x, -d.y));
}

// Moves every contact, note and route to where the camera sees it. Drawn
// things sized in metres (minefields, rocks) zoom; icons and text keep their size.
- (void)showCamera:(MapCamera)camera {
    _camera = camera;
    _scale = MIN(_rect.size.width, _rect.size.height) / camera.span;
    CGFloat zoom = _scale / _fitScale;
    for (MapItem *it in _items.allValues) {
        it.point = [self project:it.world];
        if (!it.container) it.node.position = it.point;
        it.extent.xScale = it.extent.yScale = zoom;
    }
    for (MapItem *it in [_scenery arrayByAddingObjectsFromArray:_notes]) {
        it.point = [self project:it.world];
        it.node.position = it.point;
    }
    for (MapItem *it in _scenery) it.node.xScale = it.node.yScale = zoom;
    if (_focusItem) _focusLock.position = _focusItem.point;
    [self updateScaleBar];
    [self drawRoute];
}

// A bar of a round length that takes up under a third of the map.
- (void)updateScaleBar {
    static const float lengths[] = { 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000 };
    float bar = lengths[0];
    for (size_t i = 0; i < sizeof lengths / sizeof *lengths; i++)
        if (lengths[i] * _scale <= MIN(_rect.size.width, _rect.size.height) / 3) bar = lengths[i];
    _scaleBar.size = CGSizeMake(bar * _scale, 2);
    _scaleLabel.text = bar >= 1000 ? L10nFormat(@"units.km0", bar / 1000) : L10nFormat(@"units.m_short", (int)bar).uppercaseString;
}

// A fixed graticule, like a radar scope's: it does not move with the camera.
- (void)addGrid {
    CGRect rect = _rect;
    CGPoint mid = RectCenter(rect);
    for (int i = 1; i < 8; i++) {
        CGPoint grid = PointAdd(rect.origin, PointMultiply(CGPointMake(i / 8.0, i / 8.0), rect.size));
        SKSpriteNode *v = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.07) size:CGSizeMake(1, rect.size.height)];
        v.position = CGPointMake(grid.x, mid.y);
        v.name = @"grid-v";
        SKSpriteNode *h = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.07) size:CGSizeMake(rect.size.width, 1)];
        h.position = CGPointMake(mid.x, grid.y);
        h.name = @"grid-h";
        [_layer addChild:v];
        [_layer addChild:h];
    }
    _scaleBar = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.7) size:CGSizeMake(1, 2)];
    _scaleBar.anchorPoint = CGPointMake(0, 0.5);
    _scaleBar.position = PointAdd(rect.origin, CGPointMake(16, 18));
    _scaleBar.name = @"scale";
    [_layer addChild:_scaleBar];
    _scaleLabel = Text(11, UIColorWithOpacity(UIInk, 0.7), SKLabelHorizontalAlignmentModeLeft);
    _scaleLabel.position = PointAdd(rect.origin, CGPointMake(16, 36));
    _scaleLabel.name = @"scale-label";
    [_layer addChild:_scaleLabel];
}

- (SKNode *)iconFor:(MapContact)c {
    SKColor *ink = TeamColor(c.team);
    switch (c.kind) {
        case ContactPlayer: {
            const CGPoint arrow[] = { {0, 10}, {7, -7}, {-7, -7} };
            SKShapeNode *n = ClosedShape(arrow, 3);
            n.fillColor = UIColorWithOpacity(UIInk, 0.9);
            n.strokeColor = UIColorWithOpacity(UIInk, 1);
            return n;
        }
        case ContactNav: {
            const CGPoint diamond[] = { {0, 8}, {8, 0}, {0, -8}, {-8, 0} };
            SKShapeNode *n = ClosedShape(diamond, 4);
            n.strokeColor = UIColorWithOpacity(UIInk, 1);
            n.lineWidth = 2;
            return n;
        }
        case ContactWave: {
            SKNode *g = [SKNode node];
            const CGPoint dart[] = { {0, 5}, {4, -4}, {-4, -4} };
            for (int k = 0; k < 3; k++) {
                SKShapeNode *n = ClosedShape(dart, 3);
                n.fillColor = ink;
                n.strokeColor = [SKColor clearColor];
                n.position = CGPointMake((k - 1) * 9, k == 1 ? 5 : 0);
                [g addChild:n];
            }
            return g;
        }
        case ContactMines: {
            CGSize size = CGSizeMake(c.size.x * _fitScale, c.size.z * _fitScale);
            SKShapeNode *n = [SKShapeNode shapeNodeWithRect:CGRectMake(-size.width / 2, -size.height / 2, size.width, size.height)];
            n.strokeColor = UIColorWithOpacity(UIRed, 0.6);
            n.fillColor = UIColorWithOpacity(UIRed, 0.08);
            return n;
        }
        case ContactRocks: {
            SKShapeNode *n = [SKShapeNode shapeNodeWithCircleOfRadius:c.radius * _fitScale];
            n.strokeColor = UIColorWithOpacity(UIField, 0.25);
            n.fillColor = UIColorWithOpacity(UIField, 0.06);
            return n;
        }
        case ContactCapital: {
            // Scaled to the real hull, pointing along its facing.
            const CapitalDef *info = CapitalDefNamed(c.asset);
            BOOL prop = info && info->prop;
            CGFloat maxLength = MIN(60, _rect.size.height * 0.15);
            CGFloat len = prop ? 6 : MIN(maxLength, MAX(12, (info ? info->hp : 10) * 0.9 + 10));
            SKShapeNode *n = prop ? [SKShapeNode shapeNodeWithRect:CGRectMake(-3, -3, 6, 6)]
                                  : [SKShapeNode shapeNodeWithRect:CGRectMake(-len * 0.18, -len / 2, len * 0.36, len) cornerRadius:3];
            n.strokeColor = ink;
            n.fillColor = [ink colorWithAlphaComponent:0.35];
            n.lineWidth = 1.5;
            return n;
        }
    }
    return [SKNode node];
}

- (void)addContact:(MapContact)c at:(CGPoint)p player:(CGPoint)playerPoint {
    SKNode *icon = [self iconFor:c];
    if (c.kind == ContactRocks) {
        // Scenery: drawn, never lit or named.
        icon.name = @"rocks";
        [_layer addChild:icon];
        MapItem *rocks = [MapItem new];
        rocks.world = c.pos;
        rocks.node = icon;
        [_scenery addObject:rocks];
        return;
    }
    SKNode *holder = [SKNode node];
    [holder addChild:icon];
    BOOL grouped = c.group.length > 0;
    if (c.kind == ContactMines) {
        SKLabelNode *l = Text(11, UIColorWithOpacity(UIRed, 0.9), SKLabelHorizontalAlignmentModeCenter);
        l.text = c.label;
        l.position = CGPointMake(0, -6);
        [holder addChild:l];
    } else if (c.label.length && !(c.kind == ContactCapital && grouped)) {
        // Put a nearby wingman's callsign opposite the player's callsign.
        BOOL wingman = c.kind == ContactWave && [c.team isEqualToString:@"friend"] && PointDistance(p, playerPoint) < 24;
        SKLabelNode *l = Text(11, UIColorWithOpacity(UIInk, 0.85),
                              wingman ? SKLabelHorizontalAlignmentModeRight : SKLabelHorizontalAlignmentModeLeft);
        l.text = c.label.uppercaseString;
        l.position = CGPointMake(wingman ? -15 : 12, 6);
        [holder addChild:l];
    }
    [_layer addChild:holder];
    if (!c.identifier) return;
    MapItem *item = [MapItem new];
    item.identifier = c.identifier;
    item.group = grouped ? c.group : nil;
    item.point = p;
    item.world = c.pos;
    item.node = holder;
    holder.position = p;
    if (c.kind == ContactMines) item.extent = icon;
    _items[c.identifier] = item;
    if (!grouped) return;
    // Groups (e.g. containers, pods) answer to the group name too.
    MapItem *g = _items[c.group];
    if (!g) {
        g = [MapItem new];
        g.identifier = c.group;
        g.container = YES;
        g.point = p;
        g.world = c.pos;
        g.node = [SKNode node];
        [_layer addChild:g.node];
        _items[c.group] = g;
    }
    [holder removeFromParent];
    [g.node addChild:holder];
}

// The focus marker: a pulsing ring inside slowly turning lock brackets.
- (void)addFocusLock {
    _routeLayer = [SKNode node];
    [_layer addChild:_routeLayer];
    _focusLock = [SKNode node];
    [_layer addChild:_focusLock];
    _focusRing = [SKShapeNode shapeNodeWithCircleOfRadius:18];
    _focusRing.strokeColor = UIColorWithOpacity(UIAmber, 1);
    _focusRing.lineWidth = 2;
    [_focusLock addChild:_focusRing];
    CGMutablePathRef corners = CGPathCreateMutable();
    const CGFloat r = 27, arm = 7;
    for (int i = 0; i < 4; i++) {
        CGFloat sx = (i & 1) ? 1 : -1, sy = (i & 2) ? 1 : -1;
        CGPathMoveToPoint(corners, NULL, sx * r, sy * (r - arm));
        CGPathAddLineToPoint(corners, NULL, sx * r, sy * r);
        CGPathAddLineToPoint(corners, NULL, sx * (r - arm), sy * r);
    }
    SKShapeNode *brackets = [SKShapeNode shapeNodeWithPath:corners];
    CGPathRelease(corners);
    brackets.strokeColor = UIColorWithOpacity(UIAmber, 0.75);
    brackets.lineWidth = 1.5;
    [_focusLock addChild:brackets];
    if (!UIMotionReduced()) [brackets runAction:[SKAction repeatActionForever:[SKAction rotateByAngle:-M_PI_2 duration:4]]];
}

- (MapEmphasis)applyCue:(BriefingStep *)st style:(CueStyle)style after:(MapEmphasis)shown {
    NSSet *show = [NSSet setWithArray:st.show ?: @[]];
    // Lit: named in the step, or a member of a group named in the step.
    for (MapItem *it in _items.allValues) {
        if (it.container) continue;
        BOOL lit = [show containsObject:it.identifier] || (it.group && [show containsObject:it.group]);
        it.node.alpha = lit ? 1.0 : (st ? 0.22 : 0.45);
    }
    // The step's focus is the one thing at full contrast: bright bold label,
    // slightly larger icon. Everything else lit stays at its normal weight.
    NSString *focusID = st.focus ?: @"";
    for (MapItem *it in _items.allValues) {
        if (it.container) continue;
        BOOL focused = [it.identifier isEqualToString:focusID] || (it.group && [it.group isEqualToString:focusID]);
        for (SKNode *c in it.node.children) {
            if ([c isKindOfClass:[SKLabelNode class]]) {
                SKLabelNode *l = (SKLabelNode *)c;
                if (![l.userData[@"ink"] isKindOfClass:[SKColor class]]) l.userData = [@{ @"ink": l.fontColor } mutableCopy];
                l.fontColor = focused ? UIColorWithOpacity(UIWhite, 1) : l.userData[@"ink"];
                l.fontName = focused ? UIInterfaceBoldFont : UIInterfaceFont;
            } else if (c != it.extent) {
                c.xScale = c.yScale = focused ? 1.3 : 1.0;
            }
        }
    }
    [_routeLayer removeAllChildren];
    _routeLine = _routeDot = nil;
    _routeFraction = 1;
    NSArray *route = st.route;
    NSMutableArray<NSString *> *routeIDs = [NSMutableArray array];
    for (NSString *rid in route) if (_items[rid]) [routeIDs addObject:rid];
    _routeIDs = routeIDs;
    if (routeIDs.count > 1) {
        _routeLine = [SKShapeNode node];
        _routeLine.strokeColor = UIColorWithOpacity(UIAmber, 0.9);
        _routeLine.lineWidth = 2;
        [_routeLayer addChild:_routeLine];
    }
    _focusItem = _items[focusID];
    _focusLock.hidden = !_focusItem;
    [self placeNotes:st.labels style:style];

    MapCamera target = [self cameraFor:st.camera];
    BOOL glide = style == CueStyleTween && shown.camera.span > 0 && !MapCameraNear(shown.camera, target) && !UIMotionReduced();
    [self showCamera:glide ? shown.camera : target];

    NSMutableDictionary<NSString *, NSNumber *> *alphas = [NSMutableDictionary dictionary];
    for (MapItem *it in _items.allValues) if (!it.container) alphas[it.identifier] = @(it.node.alpha);
    MapEmphasis now = { .focus = focusID, .route = route ?: @[], .alpha = alphas, .camera = target };
    [self animateFrom:shown to:now style:style];
    if (glide) [self glideFrom:shown.camera to:target];
    return now;
}

// The step's camera over the default fit; a part it leaves out stays fitted.
- (MapCamera)cameraFor:(BriefingCamera *)camera {
    MapCamera result = _fit;
    simd_float2 at;
    if (camera.span > 0) result.span = camera.span;
    if (camera.center && [self resolve:camera.center into:&at]) result.center = at;
    return result;
}

// A place as an x/z point; NO for a contact the level does not have.
- (BOOL)resolve:(BriefingPlace *)place into:(simd_float2 *)point {
    if (!place.identifier) {
        *point = place.position;
        return YES;
    }
    MapItem *item = _items[place.identifier];
    if (item) *point = item.world.xz;
    return item != nil;
}

- (void)glideFrom:(MapCamera)from to:(MapCamera)to {
    const NSTimeInterval duration = 1.0;
    [self runAction:[SKAction customActionWithDuration:duration actionBlock:^(SKNode *node, CGFloat elapsed) {
        float t = MIN(1, elapsed / duration);
        [(TacticalMap *)node showCamera:MapCameraLerp(from, to, t * t * (3 - 2 * t))];
    }] withKey:@"camera"];
}

// The step's free text: amber, pinned to a place, flickering in with the cue.
- (void)placeNotes:(NSArray<BriefingLabel *> *)labels style:(CueStyle)style {
    [_noteLayer removeAllChildren];
    [_notes removeAllObjects];
    for (BriefingLabel *label in labels) {
        simd_float2 at;
        if (![self resolve:label.at into:&at]) continue;
        SKNode *node = [SKNode node];
        SKShapeNode *dot = [SKShapeNode shapeNodeWithCircleOfRadius:2.5];
        dot.fillColor = UIColorWithOpacity(UIAmber, 1);
        dot.strokeColor = [SKColor clearColor];
        [node addChild:dot];
        SKLabelNode *text = Text(11, UIColorWithOpacity(UIAmber, 1), SKLabelHorizontalAlignmentModeLeft);
        text.fontName = UIInterfaceBoldFont;
        text.text = L10nExpand(label.text).uppercaseString;
        text.position = CGPointMake(8, 5);
        [node addChild:text];
        [_noteLayer addChild:node];
        MapItem *note = [MapItem new];
        note.world = simd_make_float3(at.x, 0, at.y);
        note.node = node;
        [_notes addObject:note];
        if (style != CueStyleStill) UIMotionFlickerIn(node, style == CueStyleIntro ? 1.1 : 0.35);
    }
}

- (void)animateFrom:(MapEmphasis)shown to:(MapEmphasis)now style:(CueStyle)style {
    if (style == CueStyleIntro && !UIMotionReduced()) {
        // The plot powers up: grid lines draw out from the centre, then
        // contacts strike in a ring spreading from the middle of the map.
        NSUInteger n = 0;
        for (SKNode *child in _layer.children) {
            BOOL vertical = [child.name isEqualToString:@"grid-v"];
            if (!vertical && ![child.name isEqualToString:@"grid-h"]) continue;
            if (vertical) child.yScale = 0.001; else child.xScale = 0.001;
            SKAction *grow = vertical ? [SKAction scaleYTo:1 duration:0.45] : [SKAction scaleXTo:1 duration:0.45];
            [child runAction:UIAfter(0.3 + 0.025 * n++, UIEased(grow, UICurveOut))];
        }
        SKNode *scale = [_layer childNodeWithName:@"scale"];
        scale.xScale = 0.001;
        [scale runAction:UIAfter(0.6, UIEased([SKAction scaleXTo:1 duration:0.3], UICurveOutExpo))];
        UIMotionFlickerIn([_layer childNodeWithName:@"scale-label"], 0.7);
        CGPoint mid = RectCenter(_rect);
        CGFloat reach = MAX(1, PointLength(PointFromSize(_rect.size)) / 2);
        for (MapItem *it in _items.allValues) {
            if (it.container) continue;
            CGFloat d = MIN(1, PointDistance(it.point, mid) / reach);
            UIMotionFlickerIn(it.node, 0.45 + d * 0.45);
        }
        for (SKNode *child in _layer.children)
            if ([child.name isEqualToString:@"rocks"]) UIMotionFlickerIn(child, 0.5);
        [self lockFocus:0.95];
        [self plotRoute:0.85];
    } else if (style == CueStyleTween) {
        // Same plot, new emphasis: contacts brighten or recede, the lock
        // jumps to the new focus and a changed route is redrawn.
        for (MapItem *it in _items.allValues) {
            NSNumber *was = shown.alpha[it.identifier];
            if (it.container || !was || fabs(was.doubleValue - it.node.alpha) < 0.01) continue;
            CGFloat target = it.node.alpha;
            it.node.alpha = was.doubleValue;
            [it.node runAction:UIEased([SKAction fadeAlphaTo:target duration:0.3], UICurveOut)];
        }
        if (![now.focus isEqualToString:shown.focus ?: @""]) [self lockFocus:0.05];
        if (![now.route isEqualToArray:shown.route ?: @[]]) [self plotRoute:0.1];
    } else if (style == CueStyleFresh) {
        [self lockFocus:0.3];
        [self plotRoute:0.25];
    }
}

- (void)pulse:(double)time {
    CGFloat wave = sin(time * 5.0);
    [_focusRing setScale:1.0 + 0.25 * wave];
    _focusRing.alpha = 0.6 + 0.4 * wave;
}

- (void)lockFocus:(NSTimeInterval)delay {
    if (!_focusLock || _focusLock.hidden || UIMotionReduced()) return;
    _focusLock.alpha = 0;
    [_focusLock setScale:2.6];
    _focusLock.zRotation = M_PI_2;
    [_focusLock runAction:UIAfter(delay, [SKAction group:@[
        [SKAction fadeInWithDuration:0.12],
        UIEased([SKAction scaleTo:1 duration:0.45], UICurveOutExpo),
        UIEased([SKAction rotateToAngle:0 duration:0.45], UICurveOutExpo),
    ]])];
}

// Dashed route up to fraction of its length; head is where it ends.
static CGPathRef CreatePartialRoute(NSArray<NSValue *> *points, CGFloat fraction, CGPoint *head) CF_RETURNS_RETAINED {
    CGFloat total = 0;
    for (NSUInteger i = 1; i < points.count; i++) total += PointDistance(UnboxPoint(points[i - 1]), UnboxPoint(points[i]));
    CGFloat want = MAX(0.5, total * fraction);
    CGMutablePathRef path = CGPathCreateMutable();
    CGPoint start = UnboxPoint(points.firstObject);
    CGPathMoveToPoint(path, NULL, start.x, start.y);
    *head = start;
    for (NSUInteger i = 1; i < points.count && want > 0; i++) {
        CGPoint a = UnboxPoint(points[i - 1]), b = UnboxPoint(points[i]);
        CGFloat len = PointDistance(a, b);
        *head = PointLerp(a, b, len > 0 ? MIN(1, want / len) : 1);
        CGPathAddLineToPoint(path, NULL, head->x, head->y);
        want -= len;
    }
    CGFloat dash[] = { 8, 6 };
    CGPathRef dashed = CGPathCreateCopyByDashingPath(path, NULL, 0, dash, 2);
    CGPathRelease(path);
    return dashed;
}

// The route as far as it is plotted, under the current camera.
- (void)drawRoute {
    if (!_routeLine) return;
    NSMutableArray<NSValue *> *points = [NSMutableArray array];
    for (NSString *rid in _routeIDs) [points addObject:BoxPoint(_items[rid].point)];
    CGPoint head;
    CGPathRef path = CreatePartialRoute(points, _routeFraction, &head);
    _routeLine.path = path;
    CGPathRelease(path);
    _routeDot.position = head;
}

- (void)plotRoute:(NSTimeInterval)delay {
    if (!_routeLine || UIMotionReduced()) return;
    SKShapeNode *line = _routeLine;
    SKShapeNode *dot = _routeDot = [SKShapeNode shapeNodeWithCircleOfRadius:3.5];
    dot.fillColor = UIColorWithOpacity(UIAmber, 1);
    dot.strokeColor = UIColorWithOpacity(UIAmber, 0.4);
    dot.lineWidth = 4;
    dot.alpha = 0;
    [_routeLayer addChild:dot];
    line.hidden = YES;
    const NSTimeInterval duration = 0.7;
    __weak TacticalMap *weakSelf = self;
    SKAction *plot = [SKAction customActionWithDuration:duration actionBlock:^(SKNode *node, CGFloat elapsed) {
        CGFloat t = MIN(1, elapsed / duration);
        TacticalMap *map = weakSelf;
        map->_routeFraction = 1 - pow(1 - t, 3);
        [map drawRoute];
        line.hidden = NO;
        dot.alpha = 1;
    }];
    [line runAction:UIAfter(delay, plot)];
    [dot runAction:UIAfter(delay + duration, [SKAction sequence:@[
        [SKAction group:@[[SKAction scaleTo:2.2 duration:0.3], [SKAction fadeOutWithDuration:0.3]]],
        [SKAction removeFromParent],
    ]])];
}

@end

@interface Briefing () <UIMotionScene>
@end

@implementation Briefing {
    Mode _mode;
    NSUInteger _index;
    BOOL _success;
    NSArray<NSString *> *_results;
    NSUInteger _debriefBeat;
    CampaignMission *_mission;
    NSArray<BriefingPage *> *_pages;
    NSUInteger _page;
    FooterButtons _buttons;
    MissionGrid _grid;
    NSValue *_queuedClick;
    NSMutableArray<NSValue *> *_queuedScrolls;
    TextViewport *_viewport;     // the screen's scrolling text, if any
    CGFloat _scrollOffset;
    NSMutableDictionary<NSString *, SKTexture *> *_art;
    SKNode *_root;
    SKShapeNode *_monitorMask;
    TacticalMap *_map;
    CGSize _laidOut;

    // Motion. _stage sits at the scene centre so the screen can scale about
    // it; _root and _ghost (outgoing content) undo the offset.
    SKNode *_stage, *_ghost;
    UITransition _transition;
    BOOL _presented;
    NSMutableArray<SKNode *> *_footerNodes;
    TitleBar *_bar;                         // in _footerNodes when touch navigation is up
    Shown _shown;
    Autoplay _autoplay;
    SKNode *_portraitLayer;
    NSMutableSet<SKSpriteNode *> *_portraitsToDismiss;
    // The speech bubble on screen, and the one being replaced.
    Caption _caption, _oldCaption;
    UIHover *_hover;
    // Insets as set, possibly from outside the frame update; taken up at the
    // next tick or rebuild so the node tree only changes during the update.
    BriefingInsets _contentInsets, _pendingInsets;
    BOOL _hasPendingInsets;
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        _touchNavigationEnabled = TARGET_OS_IOS;
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.backgroundColor = [SKColor clearColor];
        self.speed = 1 / UIMotionTimeScale();
        _hover = [UIHover new];
        _stage = [SKNode node];
        _root = [SKNode node];
        _ghost = [SKNode node];
        _art = [NSMutableDictionary dictionary];
        [_stage addChild:_root];
        [_stage addChild:_ghost];
        [self addChild:_stage];
    }
    return self;
}

- (NSUInteger)selectedIndex { return _index; }
- (SKLabelNode *)speech { return _caption.speech; }
- (CGRect)captionRect { return _caption.rect; }
- (BOOL)captionOnRight { return _caption.right; }
- (CGRect)confirmRect { return _buttons.confirm; }
- (CGRect)previousRect { return _buttons.previous; }
- (CGRect)backRect { return _buttons.back; }
- (CGRect)scrollRect { return _viewport.limit > 0 ? _viewport.rect : CGRectZero; }
- (CGFloat)scrollOffset { return _scrollOffset; }
- (SKNode *)scrollContent { return _viewport.content; }
- (NSArray<NSValue *> *)missionTiles { return _grid.tiles; }
- (CGRect)missionRows { return _grid.rows; }
- (NSUInteger)missionColumns { return _grid.columns; }

- (BOOL)hasNextBriefingPage { return _page + 1 < _pages.count; }

// Story screens draw a room behind portraits and a speech bubble.
- (BOOL)illustrated { return _mode == ModeBriefing || (_mode == ModeDebrief && _debriefBeat > 0); }

- (BOOL)compactStoryLayout { return MIN(self.size.width, self.size.height) <= 500 && [self illustrated]; }

// Phone-sized story screens are seen from farther away relative to their size:
// larger portraits, captions and controls.
static const CGFloat PhoneSpeakerFont = 16;
static const CGFloat PhonePortraitInset = 0.3;   // of the side safe-area inset

- (CGFloat)footerInset {
    BriefingInsets safe = self.contentInsets;
    return MAX(MIN(50, self.size.width * 0.05), MAX(safe.left, safe.right) + 12);
}

- (NSString *)footerActionLabel:(NSString *)action {
    return [action stringByReplacingOccurrencesOfString:@"↵  " withString:@""];
}

// The mission list keeps a hint line in its footer where there is room for it.
- (BOOL)listHasHint { return !ScreenRegionsMake(self.size, self.contentInsets, 0).compact && self.size.width > 750; }

- (ScreenRegions)listRegions { return ScreenRegionsMake(self.size, self.contentInsets, [self listHasHint] ? 20 : 0); }

// The story screens' title bar for touch: back to the missions, then the
// previous page and the action in the top-right corner. The monitor carries
// the mission's title, so the bar has none of its own.
- (TitleBar *)storyBar:(NSString *)action rects:(FooterButtons *)rects {
    ScreenRegions regions = ScreenRegionsMake(self.size, self.contentInsets, 0);
    BOOL compact = regions.compact;
    TitleBar *bar = [[TitleBar alloc] initWithHeader:regions.header compact:compact];
    FooterButtons b = { .back = [bar addBack:L10n(@"story.missions") accent:UIAmber] };
    if (action) b.confirm = [bar addAction:[self footerActionLabel:action] accent:UIAmber minWidth:compact ? 132 : 144];
    BOOL hasPrevious = _mode == ModeBriefing ? _page > 0 : _debriefBeat > 0;
    if (hasPrevious) b.previous = [bar addAction:L10n(@"story.previous") accent:UIAmber minWidth:0];
    if (rects) *rects = b;
    return bar;
}

- (BOOL)intro { return _transition == UITransitionIntro; }
- (BOOL)paging { return _transition == UITransitionPage; }

- (void)dismissPortrait:(SKSpriteNode *)portrait {
    if ([portrait actionForKey:PortraitDeparture]) return;
    [portrait removeAllActions];
    BOOL reduced = UIMotionReduced();
    NSTimeInterval duration = reduced ? 0.1 : ([self paging] ? 0.25 : 0.35);
    CGFloat offset = portrait.position.x <= self.size.width / 2 ? -70 : 70;
    SKAction *fade = [SKAction fadeOutWithDuration:duration];
    SKAction *exit = reduced || [self paging] ? fade : [SKAction group:@[
        fade, UIEased([SKAction moveByX:offset y:0 duration:duration], UICurveIn),
    ]];
    [portrait runAction:[SKAction sequence:@[exit, [SKAction removeFromParent]]] withKey:PortraitDeparture];
}

- (void)rebuild {
    [self takePendingInsets];
    BOOL keepScroll = _transition == UITransitionNone || (_mode == ModeList && _transition == UITransitionSelect);
    if (!keepScroll) {
        _scrollOffset = 0;
        _queuedScrolls = nil;
    }
    _viewport = nil;
    if (!_presented && _transition != UITransitionIntro) _transition = UITransitionNone;
    CGPoint centre = PointScale(PointFromSize(self.size), 0.5);
    _stage.position = centre;
    _root.position = _ghost.position = PointScale(centre, -1);
    if (_transition == UITransitionIntro) {
        [_stage removeAllActions];
        _stage.alpha = 1;
        [_stage setScale:1];
        if (_presented) {
            // Mode change on screen: the old layout dissolves under the new one.
            for (SKNode *node in [_root.children copy]) {
                [node removeFromParent];
                if (node == _portraitLayer) {
                    for (SKSpriteNode *portrait in node.children) {
                        [portrait removeFromParent];
                        [_ghost addChild:portrait];
                        [self dismissPortrait:portrait];
                    }
                } else {
                    [_ghost addChild:node];
                    UIMotionDismiss(node, CGVectorMake(0, 0), 0.24);
                }
            }
        }
        _shown = (Shown){ .mode = _shown.mode };
    }
    // A page turn keeps the outgoing speech bubble until the new one decides
    // how to replace it; anything else took it away with the old layout.
    Caption outgoing = CaptionTake(&_caption);
    if ([self paging]) {
        _oldCaption = outgoing;
        for (SKNode *node in CaptionNodes(_oldCaption)) {
            [node removeFromParent];
            node.zPosition = CaptionDepth;
            [_ghost addChild:node];
        }
    }

    // Keep the portrait layer attached through page turns. Only the room,
    // monitor and captions need to be rebuilt.
    if (![self paging]) {
        [_portraitLayer removeFromParent];
        _portraitLayer = [SKNode node];
        _portraitLayer.zPosition = PortraitDepth;
    }
    _portraitsToDismiss = [NSMutableSet setWithArray:_portraitLayer.children];
    for (SKNode *node in _root.children)
        if (node != _portraitLayer) [node removeFromParent];
    [_hover reset];
    _footerNodes = [NSMutableArray array];
    _bar = nil;
    _buttons = (FooterButtons){0};
    _grid = (MissionGrid){0};
    _map = nil;
    _laidOut = self.size;
    BOOL illustrated = [self illustrated];
    // Backgrounds are sprites, not the scene colour, so the screen can fade as a whole.
    SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:illustrated ? UIColorWithOpacity(UIBackground, 1)
                                                           : UIColorWithOpacity(UIBlack, 0.72) size:self.size];
    shade.anchorPoint = CGPointZero;
    [_root addChild:shade];
    if ([self intro] && (_shown.mode != _mode || !illustrated || !_presented) && !UIMotionReduced()) {
        shade.alpha = 0;
        [shade runAction:[SKAction fadeInWithDuration:0.25]];
    }
    switch (_mode) {
        case ModeList: [self buildList]; break;
        case ModeBriefing: [self buildBriefing]; break;
        case ModeDebrief: [self buildDebrief]; break;
    }
    for (SKSpriteNode *portrait in _portraitsToDismiss) [self dismissPortrait:portrait];
    _portraitsToDismiss = nil;
    // A bubble that has no successor closes where it stood.
    [self closeOldCaption];
    _shown.mode = _mode;
    _transition = UITransitionNone;
    [self scrollBy:0];
}

- (NSTimeInterval)closeOldCaption {
    Caption old = CaptionTake(&_oldCaption);
    if (!old.holder && !old.name) return 0;
    for (SKLabelNode *label in CaptionLabels(old)) UIMotionDismiss(label, CGVectorMake(0, 0), 0.1);
    return old.holder ? UIMotionClosePanel(old.holder, old.rect, UIColorWithOpacity(UIAmber, 0.9), old.right) : 0.1;
}

#pragma mark - Scrollable text

// The screen's one scrolling text area.
- (TextViewport *)textViewport:(CGRect)rect content:(SKNode *)content {
    _viewport = [[TextViewport alloc] initWithRect:rect content:content];
    return _viewport;
}

- (void)scrollBy:(CGFloat)delta {
    _scrollOffset = MIN(_viewport.limit, MAX(0, _scrollOffset + delta));
    [_viewport showOffset:_scrollOffset];
}

#pragma mark - Mission list

- (void)showListSelecting:(NSUInteger)index {
    _transition = _mode == ModeList && _presented ? UITransitionSelect : UITransitionIntro;
    _mode = ModeList;
    _index = MIN(index, CampaignMissions().count - 1);
    [self rebuild];
}

- (BriefingInsets)contentInsets { return _contentInsets; }

- (void)setContentInsets:(BriefingInsets)insets {
    @synchronized (self) {
        _pendingInsets = insets;
        _hasPendingInsets = YES;
    }
}

// Takes up insets set since the last call; YES when they changed.
- (BOOL)takePendingInsets {
    BriefingInsets insets = {0};
    BOOL pending = NO;
    @synchronized (self) {
        pending = _hasPendingInsets;
        insets = _pendingInsets;
        _hasPendingInsets = NO;
    }
    if (!pending || InsetsEqual(insets, _contentInsets)) return NO;
    _contentInsets = insets;
    return YES;
}

- (void)buildList {
    CGSize s = self.size;
    BOOL compact = s.height < 550;
    // The grid fills the body; on a phone it runs to the screen's bottom edge.
    CGRect body = [self listRegions].bodyToEdge;
    CGFloat left = CGRectGetMinX(body), right = CGRectGetMaxX(body);

    NSArray<CampaignMission *> *missions = CampaignMissions();
    NSUInteger unlocked = ProgressUnlockedCount();
    CGFloat gap = 12, width = MAX(1, right - left - ScrollGutter);
    _grid.columns = MAX(1, MIN(6, (NSUInteger)((width + gap) / 160)));
    CGFloat tileW = (width - gap * (_grid.columns - 1)) / _grid.columns;
    CGFloat tileH = compact ? 144 : 172;
    _grid.rows = body;
    SKNode *content = [SKNode node];
    NSMutableArray *tiles = [NSMutableArray array];
    for (NSUInteger i = 0; i < missions.count; i++) {
        BOOL open = i < unlocked, selected = i == _index;
        NSUInteger stars = ProgressBestStars(i);
        CGFloat x = left + (i % _grid.columns) * (tileW + gap);
        CGFloat y = CGRectGetMaxY(_grid.rows) - (i / _grid.columns + 1) * (tileH + gap) + gap;
        CGRect rect = CGRectMake(x, y, tileW, tileH);
        [tiles addObject:BoxRect(rect)];
        SKColor *ink = UIColorWithOpacity(selected ? UIAmber : UIInk, open ? 1 : 0.35);
        SKShapeNode *tile = UIReadoutPanel(rect, ink, UIColorWithOpacity(selected ? UIInk : UIPanel, selected ? 0.14 : 0.88));
        tile.name = [NSString stringWithFormat:@"mission-%lu", (unsigned long)i + 1];
        [content addChild:tile];
        // Top to bottom: number, title, then the stars and the status line
        // from the bottom up. Each label sits under the measured frame of the
        // one above, so no two can touch whatever the font metrics are.
        const CGFloat inset = 16, spacing = 4;
        SKLabelNode *number = Text(compact ? 42 : 52, ink, SKLabelHorizontalAlignmentModeLeft);
        number.fontName = UIInterfaceBoldFont;
        number.text = [NSString stringWithFormat:@"%02lu", (unsigned long)i + 1];
        number.position = CGPointMake(x + inset, y + tileH - 12);
        [content addChild:number];
        SKLabelNode *status = Text(10, ink, SKLabelHorizontalAlignmentModeLeft);
        status.text = L10n(!open ? @"missions.locked" : stars ? @"missions.completed" : @"missions.ready");
        status.position = CGPointMake(x + inset, y + 10 + status.frame.size.height);
        [content addChild:status];
        SKLabelNode *rating = Text(18, UIColorWithOpacity(stars ? UIAmber : UIInk, stars ? 1 : 0.25), SKLabelHorizontalAlignmentModeLeft);
        rating.text = [@[@"☆ ☆ ☆", @"★ ☆ ☆", @"★ ★ ☆", @"★ ★ ★"] objectAtIndex:stars];
        rating.position = CGPointMake(x + inset, CGRectGetMaxY(status.frame) + spacing + rating.frame.size.height);
        [content addChild:rating];
        SKLabelNode *name = Para(12, ink, tileW - 2 * inset);
        name.fontName = UIInterfaceBoldFont;
        name.text = open ? missions[i].title.uppercaseString : L10n(@"missions.classified");
        name.numberOfLines = 2;
        CGFloat nameTop = CGRectGetMinY(number.frame) - spacing;
        if (nameTop - name.frame.size.height < CGRectGetMaxY(rating.frame) + spacing) name.numberOfLines = 1;   // compact tiles
        name.position = CGPointMake(x + inset, nameTop);
        [content addChild:name];
    }
    _grid.tiles = tiles;
    [_root addChild:[self textViewport:_grid.rows content:content]];
    // Keyboard/controller navigation always brings its selected tile into view.
    if (_transition != UITransitionNone && _index < tiles.count) {
        CGRect selected = UnboxRect(tiles[_index]);
        if (CGRectGetMinY(selected) + _scrollOffset < CGRectGetMinY(_grid.rows))
            [self scrollBy:CGRectGetMinY(_grid.rows) - CGRectGetMinY(selected) - _scrollOffset];
        if (CGRectGetMaxY(selected) + _scrollOffset > CGRectGetMaxY(_grid.rows))
            [self scrollBy:CGRectGetMaxY(_grid.rows) - CGRectGetMaxY(selected) - _scrollOffset];
    }
    NSString *hint = L10n(TARGET_OS_IOS ? @"missions.hint_touch" : @"missions.hint");
    [self footer:hint action:_index < unlocked ? L10n(@"missions.briefing") : nil];
}

- (void)revealPreviewTitle:(SKLabelNode *)title location:(SKLabelNode *)location text:(SKLabelNode *)text
                objectives:(SKLabelNode *)objectives at:(NSTimeInterval)t {
    UIMotionDecode(title, t, 0.32);
    if (location) UIMotionDecode(location, t + 0.06, 0.32);
    NSTimeInterval typed = UIMotionTypeOn(text, t + 0.1, 260);
    if (objectives) UIMotionSlideIn(objectives, CGVectorMake(0, 8), MIN(typed, t + 0.45), 0.25);
}

- (void)footer:(NSString *)text action:(NSString *)action {
    [self buildFooter:text action:action];
    SKNode *confirm = !action ? nil : _bar ? _bar.action
                    : [_footerNodes.lastObject isKindOfClass:SKShapeNode.class] ? _footerNodes.lastObject : nil;
    if ([self intro]) {
        NSUInteger i = 0;
        for (SKNode *node in _footerNodes) {
            if ([node isKindOfClass:SKLabelNode.class]) UIMotionFlickerIn(node, 0.45);
            else if (node == _bar) {
                [_bar revealAfter:0.18 + 0.05 * i];
                i += _bar.controls.count;
            } else UIMotionSlideIn(node, CGVectorMake(0, -44), 0.18 + 0.05 * i++, 0.32);
        }
    } else if ([self paging] && action && _shown.action && ![action isEqualToString:_shown.action] && confirm) {
        // The footer action changed: the button re-strikes.
        for (SKNode *child in confirm.children)
            if ([child isKindOfClass:SKLabelNode.class]) UIMotionDecode((SKLabelNode *)child, 0, 0.3);
        UIMotionFlickerIn(confirm, 0);
    }
    _shown.action = action;
}

- (SKNode *)footerAdd:(SKNode *)node {
    node.zPosition = FooterDepth;
    [_root addChild:node];
    [_footerNodes addObject:node];
    return node;
}

- (SKNode *)footerButton:(CGRect)rect title:(NSString *)title accent:(UIRGB)accent {
    SKNode *button = [self footerAdd:UIActionButton(rect, title, accent)];
    [_hover addButton:button rect:rect accent:accent];
    return button;
}

- (void)footerBar:(TitleBar *)bar {
    _bar = bar;
    [self footerAdd:bar];
    [bar registerHover:_hover];
}

- (void)buildFooter:(NSString *)text action:(NSString *)action {
    BriefingInsets safe = self.contentInsets;
    CGFloat inset = [self footerInset];
    BOOL console = [self illustrated];
    if (_mode == ModeList) {
        ScreenRegions regions = [self listRegions];
        TitleBar *bar = [[TitleBar alloc] initWithHeader:regions.header compact:regions.compact];
        _buttons.back = [bar addBack:L10n(@"missions.main_menu") accent:UIInk];
        if (action) _buttons.confirm = [bar addAction:action accent:UIAmber minWidth:regions.compact ? 132 : 150];
        [bar setTitle:L10n(@"missions.title") kicker:L10n(@"missions.kicker")];
        [self footerBar:bar];
        if (!CGRectIsEmpty(regions.footer)) {
            SKLabelNode *hint = Text(11, UIColorWithOpacity(UIInk, 0.65), SKLabelHorizontalAlignmentModeCenter);
            hint.verticalAlignmentMode = SKLabelVerticalAlignmentModeCenter;
            hint.text = text;
            hint.position = RectCenter(regions.footer);
            [self footerAdd:hint];
        }
        return;
    }
    if (self.touchNavigationEnabled || [self compactStoryLayout]) {
        [self footerBar:[self storyBar:action rects:&_buttons]];
        return;
    }
    CGRect rail = CGRectMake(inset - 10, safe.bottom + 14, self.size.width - 2 * inset + 20, 52);
    [self footerAdd:UIControlRail(rail, console)];
    CGFloat hintLeft = inset + 8;
    SKLabelNode *hint = Para(12, UIColorWithOpacity(UIInk, console ? 0.9 : 0.65),
                             MAX(1, self.size.width - inset - hintLeft - (action ? 200 : 0)));
    hint.text = text;
    hint.verticalAlignmentMode = SKLabelVerticalAlignmentModeCenter;
    hint.position = CGPointMake(hintLeft, safe.bottom + 42);
    [self footerAdd:hint];
    if (!action) return;

    _buttons.confirm = CGRectMake(self.size.width - inset - 180, safe.bottom + 20, 180, 44);
    [self footerButton:_buttons.confirm title:action accent:console ? UIAmber : UIInk];
}

#pragma mark - Briefing

- (void)showBriefing:(NSUInteger)index { [self showBriefing:index page:0]; }

- (void)showBriefing:(NSUInteger)index page:(NSUInteger)startPage {
    _index = MIN(index, CampaignMissions().count - 1);
    _mission = CampaignMissionAt(_index);
    NSArray<BriefingPage *> *pages = StoryBriefingPages(_mission);
    _pages = pages;
    _page = MIN(startPage, pages.count - 1);
    _mode = ModeBriefing;
    _autoplay = (Autoplay){0};
    _transition = UITransitionIntro;
    [self rebuild];
}

- (SKTexture *)artTextureNamed:(NSString *)name {
    SKTexture *texture = _art[name];
    if (!texture) {
        NSString *subdirectory = [@"Briefing" stringByAppendingPathComponent:name.stringByDeletingLastPathComponent];
        NSURL *url = FSURL(subdirectory, name.lastPathComponent, @"png");
        CGImageSourceRef source = url ? CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL) : NULL;
        if (!source) return nil;
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!image) return nil;
        texture = [SKTexture textureWithCGImage:image];
        CGImageRelease(image);
        _art[name] = texture;
    }
    return texture;
}

- (SKSpriteNode *)artNamed:(NSString *)name {
    SKTexture *texture = [self artTextureNamed:name];
    return texture ? [SKSpriteNode spriteNodeWithTexture:texture] : nil;
}

// A room from Story/rooms.json: the art, cropped to fill the screen, and its
// wall monitor traced by the room's bezel polygon (source pixels, y down).
// clear: rects the monitor should stay below, such as a navigation bar's
// controls; the art moves down as far as it can while still filling the screen.
- (CGRect)addBackdrop:(NSString *)roomName raiseBoard:(BOOL)raiseBoard clear:(NSArray<NSValue *> *)clear {
    CGSize size = self.size;
    StoryRoom *room = StoryRoomNamed(roomName);
    SKSpriteNode *art = room ? [self artNamed:room.image] : nil;
    if (!art) return CGRectZero;
    // Room coordinates are source pixels, y down.
    CGSize source = room.size.x > 0 ? CGSizeMake(room.size.x, room.size.y) : art.size;
    const CGFloat boardBottom = room.boardBottom / source.height, boardHeight = room.boardHeight / source.height;
    CGFloat scale = MAX(size.width / art.size.width, size.height / art.size.height * (raiseBoard ? 1.15 : 1));
    CGSize artSize = CGSizeMake(art.size.width * scale, art.size.height * scale);
    CGFloat centerY = size.height / 2;
    if (raiseBoard && room.hasBoard) {
        // Give the caption more room while keeping the top of the monitor visible.
        CGFloat boardTop = artSize.height * (boardBottom + boardHeight);
        CGFloat originY = MIN(0, size.height * 0.96 - boardTop);
        centerY = MAX(centerY, originY + artSize.height / 2);
    }
    NSUInteger count = room.bezelCount;
    CGRect board = CGRectNull;
    for (NSUInteger i = 0; i < count; i++) {
        simd_float2 bezel = [room bezelPoint:i];
        CGPoint fraction = CGPointMake(bezel.x / source.width, 1 - bezel.y / source.height);
        board = CGRectUnion(board, (CGRect){ PointMultiply(fraction, artSize), CGSizeZero });
    }
    CGPoint origin = CGPointMake(size.width / 2 - artSize.width / 2, centerY - artSize.height / 2);
    CGFloat drop = 0;
    for (NSValue *value in clear) {
        CGRect rect = UnboxRect(value), placed = CGRectOffset(board, origin.x, origin.y);
        if (CGRectGetMaxX(rect) > CGRectGetMinX(placed) && CGRectGetMinX(rect) < CGRectGetMaxX(placed))
            drop = MAX(drop, CGRectGetMaxY(placed) - CGRectGetMinY(rect) + 4);
    }
    // Never so far that the art's top edge comes into view.
    centerY -= MIN(drop, MAX(0, origin.y + artSize.height - size.height));
    [art setScale:scale];
    art.position = CGPointMake(size.width / 2, centerY);
    CGRect frame = art.frame;
    [_root addChild:art];
    if ([self intro] && !UIMotionReduced()) {
        art.alpha = 0;
        [art setScale:scale * 1.04];
        [art runAction:[SKAction group:@[
            UIEased([SKAction fadeInWithDuration:0.5], UICurveOut),
            UIEased([SKAction scaleTo:scale duration:0.9], UICurveOut),
        ]]];
    }
    SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIBlack, 0.12) size:size];
    shade.anchorPoint = CGPointZero;
    [_root addChild:shade];

    // Counterclockwise once converted to scene coordinates.
    if (count < 3) return CGRectZero;
    CGPoint corners[count];
    for (NSUInteger i = 0; i < count; i++) {
        simd_float2 bezel = [room bezelPoint:i];
        CGPoint fraction = CGPointMake(bezel.x / source.width, 1 - bezel.y / source.height);
        corners[i] = PointAdd(frame.origin, PointMultiply(fraction, frame.size));
    }
    _monitorMask = MonitorMask(corners, count);
    return CGPathGetBoundingBox(_monitorMask.path);
}

- (void)addPortrait:(NSString *)name expression:(NSString *)expression facingRight:(BOOL)facingRight
              active:(BOOL)active inRect:(CGRect)area {
    // Keep faces inside the usable landscape width, while the illustration
    // can still extend behind the bottom caption and footer.
    BriefingInsets safe = self.contentInsets;
    // On a phone the outer shoulder may pass under the notch so the figure can
    // grow without its face crowding the monitor.
    CGFloat side = MAX(safe.left, safe.right) * ([self compactStoryLayout] ? PhonePortraitInset : 1);
    CGRect portraitBounds = CGRectMake(side, 0, MAX(1, self.size.width - 2 * side),
                                       MAX(1, self.size.height - safe.top));
    area = CGRectIntersection(area, portraitBounds);
    if (CGRectIsNull(area) || CGRectIsEmpty(area)) return;
    SKTexture *texture = expression ? [self artTextureNamed:[NSString stringWithFormat:@"Expressions/%@-%@", name, expression]] : nil;
    if (!texture) texture = [self artTextureNamed:name];
    if (!texture) return;
    if (!_portraitLayer.parent) [_root addChild:_portraitLayer];
    CGFloat dim = active ? 0 : 0.38;
    CGPoint home = CGPointMake(CGRectGetMidX(area), CGRectGetMinY(area));
    SKSpriteNode *existing = (SKSpriteNode *)[_portraitLayer childNodeWithName:name];
    if (existing) {
        existing.texture = texture;
        [_portraitsToDismiss removeObject:existing];
        if ([existing actionForKey:PortraitDeparture]) {
            [existing removeActionForKey:PortraitDeparture];
            BOOL reduced = UIMotionReduced();
            SKAction *fade = [SKAction fadeInWithDuration:reduced ? 0.1 : 0.25];
            [existing runAction:reduced ? fade : [SKAction group:@[
                fade, UIEased([SKAction moveTo:home duration:0.25], UICurveOut),
            ]]];
        }
        [existing runAction:[SKAction colorizeWithColorBlendFactor:dim duration:0.25] withKey:@"speakerFade"];
        return;
    }

    SKSpriteNode *portrait = [SKSpriteNode spriteNodeWithTexture:texture];
    portrait.name = name;
    // Both sides use the same height budget, regardless of the current cast.
    CGFloat height = MIN(area.size.height, area.size.width / MaxPortraitAspect);
    CGFloat scale = height / portrait.size.height;
    [portrait setScale:scale];
    BOOL sourceFacesRight = StoryPortraitFacesRight(name);
    if (sourceFacesRight != facingRight) portrait.xScale = -scale;
    portrait.anchorPoint = CGPointMake(0.5, 0);
    portrait.position = home;
    portrait.color = UIColorWithOpacity(UIBackground, 1);
    portrait.colorBlendFactor = dim;
    [_portraitLayer addChild:portrait];
    if ([self intro]) {
        UIMotionSlideIn(portrait, CGVectorMake(facingRight ? -70 : 70, 0), 0.15, 0.5);
    } else if ([self paging]) {
        portrait.alpha = 0;
        [portrait runAction:[SKAction fadeInWithDuration:UIMotionReduced() ? 0.1 : 0.25]];
    }
}

- (BOOL)addPortraitsForLine:(StoryLine *)line speakerArea:(CGRect)speakerArea playerArea:(CGRect)playerArea {
    NSString *player = StoryPlayer();
    BOOL playerSpeaking = [line.portrait isEqualToString:player];
    NSString *other = playerSpeaking ? line.listener : line.portrait;
    NSString *expression = line.expression;
    NSString *listenerExpression = line.listenerExpression;
    if (other) {
        [self addPortrait:other expression:playerSpeaking ? listenerExpression : expression
              facingRight:YES active:!playerSpeaking inRect:speakerArea];
    }
    [self addPortrait:player expression:playerSpeaking ? expression : listenerExpression
          facingRight:NO active:playerSpeaking inRect:playerArea];
    return playerSpeaking;
}

// From the bubble's top edge to its first line of text, below the speaker's name.
- (CGFloat)captionHeader { return [self compactStoryLayout] ? 36 : 32; }

- (CGFloat)captionTextHeightForLines:(NSArray<StoryLine *> *)lines width:(CGFloat)width fontSize:(CGFloat)fontSize {
    SKLabelNode *speech = Para(fontSize, UIColorWithOpacity(UIWhite, 1), MAX(1, width - 32));
    speech.fontName = UIBodyFont;
    CGFloat height = 0;
    for (StoryLine *line in lines) {
        speech.text = StoryPlainText(line.text, NULL);
        height = MAX(height, speech.frame.size.height);
    }
    return height;
}

- (void)addCaption:(StoryLine *)line inRect:(CGRect)rect fontSize:(CGFloat)fontSize
      speakerOnRight:(BOOL)speakerOnRight {
    SKNode *layer = [SKNode node];
    layer.zPosition = CaptionDepth;
    [_root addChild:layer];
    SKShapeNode *panel = UIReadoutPanel(rect, UIColorWithOpacity(UIConsoleEdge, 0.95),
                                        UIColorWithOpacity(UIConsoleSteel, 0.95));
    [layer addChild:panel];
    CGFloat left = CGRectGetMinX(rect) + 16, top = CGRectGetMaxY(rect);
    CGFloat width = MAX(1, rect.size.width - 32);
    BOOL phone = [self compactStoryLayout];
    SKLabelNode *speaker = Text(phone ? PhoneSpeakerFont : 13, UIColorWithOpacity(UIAmber, 1),
                               speakerOnRight ? SKLabelHorizontalAlignmentModeRight : SKLabelHorizontalAlignmentModeLeft);
    speaker.fontName = UIInterfaceBoldFont;
    speaker.text = line.speaker.uppercaseString;
    if (speaker.frame.size.width > width) {
        // Keep the name when the full rank and posting won't fit.
        speaker.text = [speaker.text componentsSeparatedByString:@","].firstObject;
        if (speaker.frame.size.width > width) speaker.fontSize *= width / speaker.frame.size.width;
    }
    speaker.position = CGPointMake(speakerOnRight ? CGRectGetMaxX(rect) - 16 : left, top - 10);
    [layer addChild:speaker];

    SKLabelNode *speech = Para(fontSize, UIColorWithOpacity(UIWhite, 1), width);
    speech.fontName = UIBodyFont;
    NSArray<NSValue *> *highlights;
    speech.text = StoryPlainText(line.text, &highlights);
    UIMotionHighlight(speech, highlights, UIColorWithOpacity(UIYellow, 1));
    speech.position = CGPointMake(left, top - [self captionHeader]);
    [layer addChild:speech];

    // The bubble hangs from its top edge, which stays put between lines.
    Caption caption = { .name = speaker, .speech = speech, .rect = rect, .right = speakerOnRight,
                        .speaker = line.speaker };
    const CGFloat charsPerSecond = 80;
    if ([self paging] && CaptionContinues(_oldCaption, caption)) {
        // Same voice, next line: the bubble resizes in place and the new line types in.
        Caption old = CaptionTake(&_oldCaption);
        caption.holder = UIMotionPivot(panel, RectTopCenter(rect));
        if (!UIMotionReduced()) {
            caption.holder.yScale = CGRectGetHeight(old.rect) / MAX(1, CGRectGetHeight(rect));
            [caption.holder runAction:UIEased([SKAction scaleYTo:1 duration:0.2], UICurveOut)];
        }
        [old.holder removeFromParent];
        [old.name removeFromParent];
        if (old.speech) UIMotionDismiss(old.speech, CGVectorMake(0, 0), 0.1);
        UIMotionDialogueTypeOn(speech, 0.06, charsPerSecond);
    } else if ([self intro] || [self paging]) {
        // A new voice: the old bubble folds away, then a beam draws the new
        // one out from the speaker's side.
        NSTimeInterval closing = [self closeOldCaption];
        NSTimeInterval ready = 0;
        caption.holder = UIMotionDrawPanel(panel, rect, UIColorWithOpacity(UIAmber, 0.9), speakerOnRight,
                                   [self intro] ? 0.45 : closing * 0.8, &ready);
        UIMotionDecode(speaker, ready, 0.3);
        UIMotionDialogueTypeOn(speech, ready + 0.05, charsPerSecond);
    } else {
        caption.holder = UIMotionPivot(panel, RectTopCenter(rect));
    }
    // Centre the scanning cell on the visible caption letters. These compact
    // top-aligned paragraphs need a small lift relative to a standalone label.
    UIMotionOffsetDialogueCaret(speech, fontSize * 0.12);
    _caption = caption;
}

- (void)buildBriefing {
    CGSize size = self.size;
    CampaignMission *mission = _mission;
    BriefingPage *page = _pages[_page];
    BOOL narrow = size.width < size.height * 1.24;
    BOOL compact = [self compactStoryLayout];
    BOOL phone = compact && !narrow;
    CGFloat textSize = phone ? 19 : MIN(24, MAX(14, size.width / 60));
    CGFloat minTextSize = phone ? 15 : 12;
    NSString *action = L10n([self hasNextBriefingPage] ? @"briefing.skip" : @"briefing.launch");
    // Touch screens navigate from a bar along the top, which leaves the bottom
    // to the caption; desktop keeps its hint rail along the bottom.
    BOOL topBar = self.touchNavigationEnabled || compact;
    TitleBar *bar = topBar ? [self storyBar:action rects:NULL] : nil;
    CGFloat floor = self.contentInsets.bottom + (topBar ? (compact ? 10 : 16) : 70);

    NSMutableArray<NSValue *> *clear = [NSMutableArray array];
    for (SKShapeNode *control in bar.controls) [clear addObject:BoxRect(control.frame)];
    CGRect screen = [self addBackdrop:mission.briefingRoom raiseBoard:compact && !narrow clear:clear];
    BOOL paintedBoard = !narrow && !CGRectIsEmpty(screen);
    if (!paintedBoard) {
        CGFloat margin = size.width * 0.06, panelTop = size.height * 0.93;
        if (bar) panelTop = MIN(panelTop, CGRectGetMinY(bar.row) - 8);
        screen = RectFromEdges(margin, panelTop - size.height * 0.34, size.width - margin, panelTop);
        SKShapeNode *panel = UIReadoutPanel(screen, UIColorWithOpacity(UIConsoleEdge, 0.95),
                                          UIColorWithOpacity(UIConsoleGlass, 1));
        [_root addChild:panel];
        CGFloat left = CGRectGetMinX(screen), right = CGRectGetMaxX(screen);
        CGFloat bottom = CGRectGetMinY(screen), top = CGRectGetMaxY(screen);
        CGFloat cut = MIN(UIReadoutChamfer, MIN(screen.size.width, screen.size.height) * 0.25);
        const CGPoint corners[] = {
            {left + cut, bottom}, {right, bottom}, {right, top - cut},
            {right - cut, top}, {left, top}, {left, bottom + cut},
        };
        _monitorMask = MonitorMask(corners, 6);
        screen = CGPathGetBoundingBox(_monitorMask.path);
    }

    // The bubble hangs below the monitor on its speaker's side; on a phone it
    // takes most of the monitor's width.
    CGFloat captionWidth = screen.size.width * (phone ? 0.9 : 0.70);
    CGFloat laneLeft = CGRectGetMinX(screen), laneRight = CGRectGetMaxX(screen);
    const CGFloat captionPadding = [self captionHeader] + 12; // Speaker header and bottom inset.
    CGFloat tallestCaption = [self captionTextHeightForLines:_pages width:captionWidth fontSize:textSize] + captionPadding;
    // Leave a gap below the monitor while keeping the caption above the footer.
    CGFloat captionTop = CGRectGetMinY(screen) + (paintedBoard ? 0 : 3) - CaptionDrop;
    while (tallestCaption > captionTop - floor && textSize > minTextSize) {
        textSize = MAX(minTextSize, textSize - 1);
        tallestCaption = [self captionTextHeightForLines:_pages width:captionWidth fontSize:textSize] + captionPadding;
    }
    CGFloat captionHeight = [self captionTextHeightForLines:@[page] width:captionWidth fontSize:textSize] + captionPadding;
    CGFloat captionBottom = MAX(floor, captionTop - captionHeight);

    [self buildMonitor:screen mission:mission page:page];

    CGFloat wing = CGRectGetMinX(screen);
    CGRect speakerArea, playerArea;
    if (phone) {
        // As large as the height allows, from the screen edge inward, below the bar.
        CGFloat side = MAX(self.contentInsets.left, self.contentInsets.right) * PhonePortraitInset;
        CGFloat width = size.width * 0.36, height = MAX(1, CGRectGetMinY(bar.row) - 4);
        speakerArea = CGRectMake(side, 0, width, height);
        playerArea = CGRectMake(size.width - side - width, 0, width, height);
    } else if (narrow) {
        CGFloat height = MAX(floor, captionTop - tallestCaption) + 6;
        speakerArea = CGRectMake(0, 0, size.width / 2, height);
        playerArea = CGRectOffset(speakerArea, size.width / 2, 0);
    } else {
        CGFloat width = MIN(size.width * 0.31, wing * 1.45);
        CGFloat bottom = compact ? 0 : floor - 10;
        CGFloat height = MAX(1, size.height - bottom - 48);
        CGFloat center = wing * 0.65;
        speakerArea = CGRectMake(center - width / 2, bottom, width, height);
        playerArea = CGRectMake(size.width - center - width / 2, bottom, width, height);
    }
    BOOL playerSpeaking = [self addPortraitsForLine:page speakerArea:speakerArea playerArea:playerArea];

    CGFloat captionLeft = playerSpeaking ? laneRight - captionWidth : laneLeft;
    [self addCaption:page inRect:CGRectMake(captionLeft, captionBottom, captionWidth, captionHeight)
             fontSize:textSize speakerOnRight:playerSpeaking];
    [self footer:L10n(@"briefing.hint") action:action];
}

- (void)buildMonitor:(CGRect)screen mission:(CampaignMission *)mission page:(BriefingPage *)page {
    SKNode *display = _root;
    if (!CGRectIsEmpty(screen)) {
        CGPoint center = RectCenter(screen);
        SKCropNode *crop = [SKCropNode node];
        crop.maskNode = _monitorMask;
        [_root addChild:crop];

        display = crop;
        if (!UIMotionReduced()) {
            SKEffectNode *effect = [SKEffectNode node];
            effect.name = @"monitor.signal";
            effect.shader = UIMonitorSignalShader(NO);
            vector_float2 pixels = { screen.size.width, screen.size.height };
            [effect setValue:[SKAttributeValue valueWithVectorFloat2:pixels] forAttributeNamed:@"a_screen_size"];
            effect.shouldEnableEffects = YES;
            [crop addChild:effect];
            display = effect;
        }
        // A stable screen-sized buffer, with the honeycomb behind all readouts.
        SKSpriteNode *glass = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIConsoleGlass, 0.01)
                                                          size:screen.size];
        glass.position = center;
        [display addChild:glass];
        CGFloat radius = MAX(10, MIN(18, screen.size.height / 17));
        CGFloat dy = sqrt(3) * radius;
        CGMutablePathRef honeycomb = CGPathCreateMutable();
        NSInteger column = 0;
        for (CGFloat x = CGRectGetMinX(screen); x < CGRectGetMaxX(screen) + radius; x += radius * 1.5, column++) {
            for (CGFloat y = CGRectGetMinY(screen) + (column % 2) * dy / 2; y < CGRectGetMaxY(screen) + dy; y += dy) {
                // Three shared edges per cell; adjacent cells supply the others.
                CGPathMoveToPoint(honeycomb, NULL, x - radius / 2, y - dy / 2);
                CGPathAddLineToPoint(honeycomb, NULL, x + radius / 2, y - dy / 2);
                CGPathAddLineToPoint(honeycomb, NULL, x + radius, y);
                CGPathAddLineToPoint(honeycomb, NULL, x + radius / 2, y + dy / 2);
            }
        }
        SKShapeNode *hex = [SKShapeNode shapeNodeWithPath:honeycomb];
        CGPathRelease(honeycomb);
        hex.name = @"monitor.honeycomb";
        hex.strokeColor = UIColorWithOpacity(UIInk, 0.085);
        hex.lineWidth = 0.8;
        [display addChild:hex];
    }

    MissionBriefing *brief = mission.briefing;
    CGFloat pad = MIN(22, screen.size.width * 0.04);
    CGFloat left = CGRectGetMinX(screen) + pad, right = CGRectGetMaxX(screen) - pad;
    CGFloat top = CGRectGetMaxY(screen) - 5;
    CGFloat width = MAX(1, right - left);
    CGFloat titleSize = MIN(21, MAX(12, width / 29));
    SKLabelNode *title = Para(titleSize, UIColorWithOpacity(UIInk, 1), width);
    title.fontName = UIInterfaceBoldFont;
    title.text = L10nFormat(@"briefing.title", (unsigned long)_index + 1, mission.title.uppercaseString);
    title.position = CGPointMake(left, top);
    [display addChild:title];

    SKLabelNode *location = Para(MIN(13, MAX(9, width / 45)), UIColorWithOpacity(UIInk, 0.75), width);
    location.text = L10nFormat(@"briefing.location", brief.location, brief.stardate);
    location.position = CGPointMake(left, CGRectGetMinY(title.frame) - 4);
    [display addChild:location];

    CGFloat channelY = CGRectGetMinY(location.frame) - 10;
    SKLabelNode *channel = Text(12, UIColorWithOpacity(UIAmber, 1), SKLabelHorizontalAlignmentModeLeft);
    channel.fontName = UIInterfaceBoldFont;
    channel.text = page.channel;
    channel.position = CGPointMake(left, channelY);
    [display addChild:channel];
    SKLabelNode *counter = Text(12, UIColorWithOpacity(UIInk, 0.7), SKLabelHorizontalAlignmentModeRight);
    counter.text = [NSString stringWithFormat:@"%02lu / %02lu", (unsigned long)_page + 1, (unsigned long)_pages.count];
    counter.position = CGPointMake(right, channelY);
    [display addChild:counter];

    CGFloat contentTop = CGRectGetMinY(channel.frame) - 8;
    CGFloat bottom = CGRectGetMinY(screen) + 4;
    CGRect contentRect = CGRectMake(CGRectGetMinX(screen), bottom, screen.size.width, MAX(1, contentTop - bottom));
    NSString *kind = nil;
    SKNode *content = [self buildMonitorContent:mission page:page left:left right:right top:contentTop
                                         bottom:bottom kind:&kind];
    [display addChild:content];
    BOOL map = [kind hasPrefix:@"map"];
    BOOL fresh = ![kind isEqualToString:_shown.content];

    if ([self intro]) {
        UIMotionSweep(_root, screen, UIColorWithOpacity(UIInk, 0.5), YES, 0.1, 0.6);
        UIMotionDecode(title, 0.25, 0.5);
        UIMotionDecode(location, 0.32, 0.45);
        UIMotionDecode(channel, 0.4, 0.35);
        UIMotionDecode(counter, 0.4, 0.35);
        if (!map && content) UIMotionWipe(content, contentRect, UIColorWithOpacity(UIInk, 0.7), 0.45, 0.45);
    } else if ([self paging]) {
        if (![page.channel isEqual:_shown.channel]) UIMotionDecode(channel, 0, 0.3);
        UIMotionDecode(counter, 0, 0.2);
        if (fresh && content) UIMotionWipe(content, contentRect, UIColorWithOpacity(UIInk, 0.7), 0.04, 0.38);
    }
    if (map) {
        // Dialogue lines keep the map on what the scene is about.
        NSString *sceneFocus = brief.dialogue.focus;
        BriefingStep *step = page.step ?: (page.dialogue && sceneFocus ? [BriefingStep stepFocusing:sceneFocus] : nil);
        CueStyle style = [self intro] ? CueStyleIntro : (![self paging] ? CueStyleStill : (fresh ? CueStyleFresh : CueStyleTween));
        _shown.map = [_map applyCue:step style:style after:_shown.map];
    }
    _shown.content = kind;
    _shown.channel = page.channel;
}

// The tactical map, a ship schematic or a readout list. kind names what was
// drawn so the next page can tell whether the content changed.
- (SKNode *)buildMonitorContent:(CampaignMission *)mission page:(BriefingPage *)page left:(CGFloat)left
                          right:(CGFloat)right top:(CGFloat)contentTop bottom:(CGFloat)bottom
                           kind:(NSString **)kind {
    CGFloat width = MAX(1, right - left);
    const LevelEntity *target = LevelEntityNamed(mission.level, page.step.focus);
    NSString *subsystemKind = page.step.schematic;
    NSString *key = target && subsystemKind ? [NSString stringWithFormat:@"Schematics/%@-%@", target->asset, subsystemKind] : nil;
    SKSpriteNode *schematic = key && contentTop > bottom + 20 ? [self artNamed:key] : nil;
    if (schematic) {
        SKNode *group = [SKNode node];
        CGFloat height = contentTop - bottom - 14;
        [schematic setScale:MIN(width / schematic.size.width, height / schematic.size.height)];
        schematic.position = CGPointMake((left + right) / 2, bottom + 14 + height / 2);
        [group addChild:schematic];
        SKLabelNode *legend = Text(10, UIColorWithOpacity(UIRed, 1), SKLabelHorizontalAlignmentModeLeft);
        NSString *subsystemKey = [@"briefing.subsystem." stringByAppendingString:subsystemKind.lowercaseString];
        NSString *subsystem = L10n(subsystemKey);
        legend.text = L10nFormat(@"briefing.target", [subsystem isEqualToString:subsystemKey] ? subsystemKind.uppercaseString : subsystem);
        legend.position = CGPointMake(left, bottom + 12);
        [group addChild:legend];
        *kind = key;
        return group;
    }
    NSArray<NSString *> *readout = page.readout;
    if (readout.count) {
        NSString *lines = [@"›  " stringByAppendingString:[readout componentsJoinedByString:@"\n›  "]];
        CGFloat fontSize = MIN(20, MAX(12, width / 32));
        SKLabelNode *list = Para(fontSize, UIColorWithOpacity(UIInk, 0.96), MAX(1, width - ScrollGutter));
        list.fontName = UIBodyMediumFont;
        list.text = lines;
        CGFloat top = contentTop - 4;
        list.position = CGPointMake(left, top);
        SKNode *content = [SKNode node];
        [content addChild:list];
        *kind = [@"readout:" stringByAppendingString:lines];
        return [self textViewport:CGRectMake(left, bottom, width, MAX(0, top - bottom)) content:content];
    }

    *kind = [NSString stringWithFormat:@"map:%lu", (unsigned long)_index];
    _map = [[TacticalMap alloc] initWithLevel:mission.level rect:RectFromEdges(left, bottom, right, MAX(bottom + 1, contentTop))];
    return _map;
}


#pragma mark - Debrief

- (void)showDebrief:(NSUInteger)index success:(BOOL)success results:(NSArray<NSString *> *)results {
    _mode = ModeDebrief;
    _index = index;
    _success = success;
    _results = [results copy];
    _debriefBeat = 0;
    _transition = UITransitionIntro;
    [self rebuild];
}

- (void)buildDebrief {
    CampaignMission *mission = CampaignMissionAt(_index);
    NSArray<StoryLine *> *conversation = _success ? mission.debrief.dialogue : nil;
    CGSize s = self.size;
    BriefingInsets safe = self.contentInsets;
    CGFloat inset = MAX(MIN(50, s.width * 0.05), MAX(safe.left, safe.right) + 12);
    CGFloat width = MAX(1, s.width - 2 * inset);
    CGFloat fontSize = MIN(23, MAX(15, s.width / 58));
    if (_debriefBeat > 0 && MIN(s.width, s.height) <= 500) fontSize = 18;
    BOOL more = _success && _index + 1 < CampaignMissions().count;
    NSString *next = L10n(more ? @"debrief.next_mission" : @"debrief.missions");

    if (_debriefBeat > 0 && _debriefBeat <= conversation.count) {
        StoryLine *line = conversation[_debriefBeat - 1];
        [self addBackdrop:mission.debriefRoom raiseBoard:NO clear:nil];
        CGFloat captionHeight = MAX(72, [self captionTextHeightForLines:conversation width:width fontSize:fontSize] + [self captionHeader] + 8);
        BOOL compact = [self compactStoryLayout];
        CGFloat floor = compact ? (s.height - captionHeight) / 2 : safe.bottom + 72;
        CGFloat bottom = compact ? 0 : floor + captionHeight - 8;
        CGFloat height = compact ? floor + 6 : s.height - bottom - 26;
        CGRect leftArea = CGRectMake(inset, bottom, width / 2, MAX(1, height));
        BOOL playerSpeaking = [self addPortraitsForLine:line speakerArea:leftArea playerArea:CGRectOffset(leftArea, width / 2, 0)];
        CGFloat captionBottom = MAX(safe.bottom + (compact ? 10 : self.touchNavigationEnabled ? 16 : 70),
                                    floor - CaptionDrop);
        [self addCaption:line inRect:CGRectMake(inset, captionBottom, width, captionHeight)
                 fontSize:fontSize speakerOnRight:playerSpeaking];
        [self footer:L10n(@"debrief.conversation_hint")
               action:_debriefBeat == conversation.count ? next : L10n(@"debrief.continue")];
        return;
    }

    CGFloat top = s.height - safe.top - MIN(95, s.height * 0.15);
    SKLabelNode *title = Text(MIN(36, MAX(20, s.width / 30)),
                              _success ? UIColorWithOpacity(UIInk, 1) : UIColorWithOpacity(UIRed, 1),
                              SKLabelHorizontalAlignmentModeCenter);
    title.fontName = UIInterfaceBoldFont;
    title.text = L10n(_success ? @"debrief.complete" : @"debrief.failed");
    title.position = CGPointMake(s.width / 2, top);
    [_root addChild:title];
    SKLabelNode *name = Para(16, UIColorWithOpacity(UIAmber, 0.9), width);
    name.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeCenter;
    name.text = L10nFormat(@"menu.mission_line", (unsigned long)_index + 1, mission.title.uppercaseString);
    name.position = CGPointMake(s.width / 2, CGRectGetMinY(title.frame) - 10);
    [_root addChild:name];
    SKNode *report = [SKNode node];
    CGFloat reportTop = CGRectGetMinY(name.frame) - 24;
    CGFloat reportBottom = safe.bottom + 84; // Leave the footer clear.
    SKLabelNode *summary = Para(fontSize, UIColorWithOpacity(UIInk, 0.9), MAX(1, width - ScrollGutter));
    summary.text = _success ? mission.debrief.win : mission.debrief.lose;
    summary.position = CGPointMake(inset, reportTop);
    [report addChild:summary];
    SKLabelNode *results = Para(16, UIColorWithOpacity(UIInk, 0.75), MAX(1, width - ScrollGutter));
    results.text = [[L10n(@"debrief.objectives") stringByAppendingString:@"\n"] stringByAppendingString:[_results componentsJoinedByString:@"\n"] ?: @""];
    results.position = CGPointMake(inset, CGRectGetMinY(summary.frame) - 20);
    [report addChild:results];
    [_root addChild:[self textViewport:CGRectMake(inset, reportBottom, width, MAX(0, reportTop - reportBottom))
                               content:report]];
    if ([self intro]) {
        // Success decodes cleanly; failure arrives as a corrupted signal.
        if (_success) UIMotionDecode(title, 0.1, 0.6);
        else UIMotionGlitchIn(title, 0.1, 0.7, UIColorWithOpacity(UIRed, 1));
        if (!UIMotionReduced()) {
            SKColor *glow = _success ? UIColorWithOpacity(UIInk, 0.9) : UIColorWithOpacity(UIRed, 0.9);
            CGFloat y = CGRectGetMinY(title.frame) - 4, reach = MIN(s.width * 0.32, 420);
            for (int side = -1; side <= 1; side += 2) {
                SKSpriteNode *beam = UIMotionBeam(_root, s.width / 2, s.width / 2 + side * reach, y, glow);
                beam.xScale = 0;
                [beam runAction:UIAfter(0.15, [SKAction sequence:@[
                    UIEased([SKAction scaleXTo:1 duration:0.45], UICurveOutExpo),
                    [SKAction fadeOutWithDuration:0.6], [SKAction removeFromParent],
                ]])];
            }
        }
        UIMotionDecode(name, 0.3, 0.45);
        NSTimeInterval typed = UIMotionTypeOn(summary, 0.5, 160);
        UIMotionTypeOn(results, MAX(0.7, typed - 0.2), 200);
    }
    [self footer:L10n(@"debrief.hint")
           action:conversation.count ? L10n(@"debrief.continue_story") : (_success ? next : L10n(@"debrief.retry"))];
}

#pragma mark - Input & animation

- (void)pointerHover:(CGPoint)point { [_hover queuePointAtFraction:point]; }

- (void)pointerClick:(CGPoint)point { _queuedClick = BoxPoint(point); }

// Kept until -handle:, which knows the current scroll areas.
- (void)pointerScroll:(CGFloat)delta at:(CGPoint)point {
    if (delta == 0) return;
    ScrollInput input = {point, delta};
    if (!_queuedScrolls) _queuedScrolls = [NSMutableArray array];
    [_queuedScrolls addObject:[NSValue value:&input withObjCType:@encode(ScrollInput)]];
}

- (void)turnPage {
    [[GameAudio shared] play:@"ui-panel" gain:0.65f pan:0];
    _transition = UITransitionPage;
    [self rebuild];
}

// The summary and the conversation are different layouts; beats within the
// conversation are pages.
- (void)turnBeat {
    [[GameAudio shared] play:@"ui-panel" gain:0.65f pan:0];
    BOOL conversation = _debriefBeat > 0 && _shown.mode == ModeDebrief && _caption.holder;
    _transition = conversation ? UITransitionPage : UITransitionIntro;
    [self rebuild];
}

- (BriefingCommand)handle:(InputAction)a {
    [_hover updateInScene:self];
    NSValue *click;
    NSArray<NSValue *> *scrolls;
    click = _queuedClick;
    _queuedClick = nil;
    scrolls = _queuedScrolls;
    _queuedScrolls = nil;
    for (NSValue *value in scrolls) {
        ScrollInput input;
        [value getValue:&input size:sizeof(input)];
        if (CGRectContainsPoint(_viewport.rect, PointMultiply(input.point, self.size))) [self scrollBy:input.delta];
    }
    if (a || click || scrolls.count) _autoplay.stopped = YES;
    // Leave up/down for mission selection and left/right for story pages.
    InputAction scrollUp = _mode == ModeList ? 0 : InputActionUp;
    InputAction scrollDown = _mode == ModeList ? 0 : InputActionDown;
    if (a & scrollUp) [self scrollBy:-54];
    if (a & scrollDown) [self scrollBy:54];
    if (click) {
        CGPoint point = PointMultiply(UnboxPoint(click), self.size);
        if (CGRectContainsPoint(_buttons.confirm, point)) {
            if (_mode == ModeBriefing && [self hasNextBriefingPage]) {
                _page = _pages.count - 1;
                [self turnPage];
                UIMotionFinishTyping(_caption.speech);
                return BriefingCommandNone;
            }
            a |= InputActionConfirm;
        } else if (CGRectContainsPoint(_buttons.previous, point)) a |= InputActionLeft;
        else if (CGRectContainsPoint(_buttons.back, point)) a |= InputActionBack;
        else if (_mode == ModeList && CGRectContainsPoint(_grid.rows, point)) {
            CGPoint inContent = PointSub(point, CGPointMake(0, _scrollOffset));
            for (NSUInteger i = 0; i < _grid.tiles.count; i++) {
                if (!CGRectContainsPoint(UnboxRect(_grid.tiles[i]), inContent)) continue;
                if (i == _index) a |= InputActionConfirm;
                else { [[GameAudio shared] play:@"ui-hover"]; [self showListSelecting:i]; }
                break;
            }
        } else if (_mode != ModeList &&
                   CGRectContainsPoint(RectWithSize(self.size), point)) {
            // Scene taps turn pages. Final actions still require confirmation.
            a |= InputActionRight;
        }
    }
    NSUInteger count = CampaignMissions().count;
    if (a & InputActionBack) [[GameAudio shared] play:@"ui-back"];
    else if (a & InputActionConfirm) {
        BOOL locked = _mode == ModeList && _index >= ProgressUnlockedCount();
        [[GameAudio shared] play:locked ? @"ui-alert" : @"ui-confirm"];
    } else if (_mode == ModeList && (a & (InputActionUp | InputActionDown))) [[GameAudio shared] play:@"ui-hover"];
    switch (_mode) {
        case ModeList:
            if (a & InputActionBack) return BriefingCommandMainMenu;
            if (a & InputActionLeft) [self showListSelecting:_index > 0 ? _index - 1 : count - 1];
            if (a & InputActionRight) [self showListSelecting:(_index + 1) % count];
            if (a & InputActionUp) [self showListSelecting:_index >= _grid.columns ? _index - _grid.columns : _index];
            if (a & InputActionDown) [self showListSelecting:MIN(count - 1, _index + _grid.columns)];
            if ((a & InputActionConfirm) && _index < ProgressUnlockedCount()) [self showBriefing:_index];
            break;
        case ModeBriefing:
            if (a & InputActionBack) { [self showListSelecting:_index]; break; }
            if (a & InputActionLeft) {
                if (_page > 0) { _page--; [self turnPage]; }
            } else if (a & (InputActionRight | InputActionConfirm)) {
                // The first press lands a line that is still typing.
                if (UIMotionIsTyping(_caption.speech)) UIMotionFinishTyping(_caption.speech);
                else if ([self hasNextBriefingPage]) { _page++; [self turnPage]; }
                else if (a & InputActionConfirm) return BriefingCommandLaunch;
            }
            break;
        case ModeDebrief:
            if (a & InputActionBack) [self showListSelecting:_index];
            else if (a & InputActionRestart) return BriefingCommandLaunch;
            else if (a & InputActionLeft) {
                if (_debriefBeat > 0) { _debriefBeat--; [self turnBeat]; }
            } else if (a & (InputActionRight | InputActionConfirm)) {
                if (!_success) {
                    if (a & InputActionConfirm) return BriefingCommandLaunch;
                    break;
                }
                NSArray *conversation = CampaignMissionAt(_index).debrief.dialogue;
                if (UIMotionIsTyping(_caption.speech)) UIMotionFinishTyping(_caption.speech);
                else if (_debriefBeat < conversation.count) {
                    _debriefBeat++;
                    [self turnBeat];
                } else if (a & InputActionConfirm) {
                    if (_index + 1 < count) [self showBriefing:_index + 1];
                    else [self showListSelecting:_index];
                }
            }
            break;
    }
    return BriefingCommandNone;
}

#pragma mark - Scene motion

- (void)motionEnter {
    _queuedClick = nil;
    _transition = UITransitionIntro;
    _presented = NO;
    [self rebuild];
    _presented = YES;
}

- (NSTimeInterval)motionExit {
    _presented = NO;
    if (UIMotionReduced()) {
        [_stage runAction:[SKAction fadeOutWithDuration:0.15]];
        return 0.15;
    }
    UIMotionFinishTyping(_caption.speech);
    _oldCaption = CaptionTake(&_caption);
    NSTimeInterval caption = [self closeOldCaption];
    NSUInteger i = 0;
    for (SKNode *node in _footerNodes) {
        // The navigation bar leaves upward, the footer downward.
        CGFloat away = node == _bar ? 40 : -40;
        [node runAction:UIAfter(i++ * 0.03, [SKAction group:@[
            UIEased([SKAction moveByX:0 y:away duration:0.2], UICurveIn), [SKAction fadeOutWithDuration:0.2],
        ]])];
    }
    NSTimeInterval hold = MAX(caption, 0.16);
    [_stage runAction:UIAfter(hold * 0.6, [SKAction group:@[
        UIEased([SKAction scaleTo:1.025 duration:0.22], UICurveIn),
        [SKAction sequence:@[
            [SKAction fadeAlphaTo:0.45 duration:0.04], [SKAction fadeAlphaTo:0.85 duration:0.03],
            [SKAction fadeOutWithDuration:0.15],
        ]],
    ]])];
    return hold * 0.6 + 0.22;
}

- (void)tick:(double)time {
    if ([self takePendingInsets] || !CGSizeEqualToSize(self.size, _laidOut)) [self rebuild];
    if (_mode == ModeBriefing) {
        [_map pulse:time];
        [self autoplayAt:time];
    }
}

// Moves a timed page on once its caption is typed and its seconds are up.
- (void)autoplayAt:(double)time {
    BriefingStep *step = _pages[_page].step;
    if (_autoplay.stopped || !step.timed || ![self hasNextBriefingPage] || !_presented) return;
    if (UIMotionIsTyping(_caption.speech)) {
        _autoplay.armed = NO;
        return;
    }
    if (!_autoplay.armed || _autoplay.page != _page) {
        _autoplay = (Autoplay){ .armed = YES, .page = _page, .due = time + step.seconds };
        return;
    }
    if (time < _autoplay.due) return;
    _autoplay.armed = NO;
    _page++;
    [self turnPage];
}

@end

