#import "Briefing.h"
#import "Assets.h"
#import "Progress.h"

static NSColor *Ink(CGFloat a) { return [NSColor colorWithRed:0.55 green:0.95 blue:0.85 alpha:a]; }
static NSColor *Amber(CGFloat a) { return [NSColor colorWithRed:1.0 green:0.72 blue:0.3 alpha:a]; }
static NSColor *Red(CGFloat a) { return [NSColor colorWithRed:1.0 green:0.42 blue:0.32 alpha:a]; }
static NSColor *Blue(CGFloat a) { return [NSColor colorWithRed:0.45 green:0.75 blue:1.0 alpha:a]; }
static NSColor *Yellow(CGFloat a) { return [NSColor colorWithRed:0.95 green:0.9 blue:0.45 alpha:a]; }

static SKLabelNode *Text(CGFloat size, NSColor *c, SKLabelHorizontalAlignmentMode h) {
    SKLabelNode *l = [SKLabelNode labelNodeWithFontNamed:@"Menlo"];
    l.fontSize = size;
    l.fontColor = c;
    l.horizontalAlignmentMode = h;
    l.verticalAlignmentMode = SKLabelVerticalAlignmentModeTop;
    return l;
}

static SKLabelNode *Para(CGFloat size, NSColor *c, CGFloat width) {
    SKLabelNode *l = Text(size, c, SKLabelHorizontalAlignmentModeLeft);
    l.numberOfLines = 0;
    l.preferredMaxLayoutWidth = width;
    l.lineBreakMode = NSLineBreakByWordWrapping;
    return l;
}

static SKShapeNode *Frame(CGRect r, NSColor *stroke, NSColor *fill) {
    SKShapeNode *n = [SKShapeNode shapeNodeWithRect:r cornerRadius:4];
    n.strokeColor = stroke;
    n.fillColor = fill;
    n.lineWidth = 1.5;
    return n;
}

typedef NS_ENUM(NSInteger, Mode) { ModeList, ModeBriefing, ModeDebrief };

// One thing on the tactical map.
@interface MapItem : NSObject
@property (nonatomic, copy) NSString *identifier, *group;
@property (nonatomic) BOOL container;
@property (nonatomic) CGPoint point;
@property (nonatomic, strong) SKNode *node;
@end
@implementation MapItem
@end

@implementation Briefing {
    Mode _mode;
    NSUInteger _index;
    BOOL _success;
    SKNode *_root;
    CGSize _laidOut;

    // Briefing state
    SKLabelNode *_story, *_caption, *_stepLabel;
    NSString *_storyText;
    double _typeStart, _now;
    NSUInteger _step;
    NSArray *_steps;
    NSMutableDictionary<NSString *, MapItem *> *_items;
    SKNode *_mapLayer, *_routeLayer;
    SKShapeNode *_focusRing;
    CGRect _mapRect;
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.backgroundColor = [NSColor clearColor];
        _root = [SKNode node];
        [self addChild:_root];
    }
    return self;
}

- (NSUInteger)selectedIndex { return _index; }

- (void)rebuild {
    [_root removeAllChildren];
    _laidOut = self.size;
    CGSize s = self.size;
    // Dim the 3D scene behind the UI.
    SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:[NSColor colorWithWhite:0 alpha:0.72] size:s];
    shade.anchorPoint = CGPointZero;
    [_root addChild:shade];
    switch (_mode) {
        case ModeList: [self buildList]; break;
        case ModeBriefing: [self buildBriefing]; break;
        case ModeDebrief: break;
    }
}

#pragma mark - Mission list

- (void)showListSelecting:(NSUInteger)index {
    _mode = ModeList;
    _index = MIN(index, CampaignMissions().count - 1);
    [self rebuild];
}

- (void)buildList {
    CGSize s = self.size;
    CGFloat top = s.height - 50;
    SKLabelNode *t = Text(30, Ink(1), SKLabelHorizontalAlignmentModeLeft);
    t.fontName = @"Menlo-Bold";
    t.text = @"KESTREL FRONTIER";
    t.position = CGPointMake(60, top);
    [_root addChild:t];
    SKLabelNode *sub = Text(15, Ink(0.6), SKLabelHorizontalAlignmentModeLeft);
    sub.text = @"CNS BASTION  /  LANCER FLIGHT  /  MISSION SELECT";
    sub.position = CGPointMake(60, top - 40);
    [_root addChild:sub];

    NSArray *all = CampaignMissions();
    NSUInteger unlocked = ProgressUnlockedCount();
    CGFloat rowH = MIN(30, (s.height - 220) / MAX(all.count, 1));
    CGFloat listW = MIN(520, s.width * 0.42);
    for (NSUInteger i = 0; i < all.count; i++) {
        BOOL open = i < unlocked, sel = i == _index;
        CGFloat y = top - 90 - i * rowH;
        if (sel) {
            SKShapeNode *bar = Frame(CGRectMake(50, y - rowH + 4, listW, rowH - 2), Ink(0.8), Ink(0.12));
            [_root addChild:bar];
        }
        SKLabelNode *l = Text(MIN(17, rowH * 0.6), open ? (sel ? Ink(1) : Ink(0.75)) : Ink(0.25), SKLabelHorizontalAlignmentModeLeft);
        l.text = [NSString stringWithFormat:@"%02lu   %@", (unsigned long)i + 1, open ? [all[i][@"title"] uppercaseString] : @"-- CLASSIFIED --"];
        l.position = CGPointMake(64, y - 4);
        [_root addChild:l];
    }

    // Preview of the selected mission.
    NSDictionary *m = all[_index];
    BOOL open = _index < unlocked;
    CGFloat px = listW + 100, pw = s.width - px - 60;
    [_root addChild:Frame(CGRectMake(px - 20, 90, pw + 20, top - 160), Ink(0.4), [NSColor colorWithWhite:0 alpha:0.35])];
    SKLabelNode *title = Text(24, Ink(1), SKLabelHorizontalAlignmentModeLeft);
    title.fontName = @"Menlo-Bold";
    title.text = open ? [m[@"title"] uppercaseString] : @"CLASSIFIED";
    title.position = CGPointMake(px, top - 90);
    [_root addChild:title];
    if (open) {
        NSDictionary *b = m[@"briefing"];
        SKLabelNode *loc = Text(15, Amber(0.9), SKLabelHorizontalAlignmentModeLeft);
        loc.text = [NSString stringWithFormat:@"%@   /   SD %@", b[@"location"], b[@"stardate"]];
        loc.position = CGPointMake(px, top - 128);
        [_root addChild:loc];
        SKLabelNode *p = Para(16, Ink(0.8), pw - 20);
        p.text = [b[@"text"] firstObject];
        p.position = CGPointMake(px, top - 165);
        [_root addChild:p];
        SKLabelNode *objs = Para(15, Ink(0.65), pw - 20);
        NSMutableString *o = [NSMutableString stringWithString:@"OBJECTIVES\n"];
        for (NSDictionary *d in m[@"objectives"]) [o appendFormat:@"  %@ %@\n", [d[@"optional"] boolValue] ? @"o" : @">", d[@"text"]];
        objs.text = o;
        objs.position = CGPointMake(px, p.position.y - p.frame.size.height - 30);
        [_root addChild:objs];
    } else {
        SKLabelNode *p = Para(16, Ink(0.5), pw - 20);
        p.text = @"Complete the previous missions to unlock this briefing.";
        p.position = CGPointMake(px, top - 130);
        [_root addChild:p];
    }
    [self footer:@"UP / DOWN  select      ENTER  briefing"];
}

- (void)footer:(NSString *)text {
    SKLabelNode *f = Text(14, Ink(0.55), SKLabelHorizontalAlignmentModeCenter);
    f.text = text;
    f.position = CGPointMake(self.size.width / 2, 44);
    [_root addChild:f];
}

#pragma mark - Briefing

- (void)showBriefing:(NSUInteger)index {
    _mode = ModeBriefing;
    _index = index;
    _step = 0;
    _typeStart = _now;
    [self rebuild];
}

- (void)buildBriefing {
    CGSize s = self.size;
    NSDictionary *m = CampaignMission(_index);
    NSDictionary *b = m[@"briefing"];
    CGFloat top = s.height - 40;

    SKLabelNode *t = Text(26, Ink(1), SKLabelHorizontalAlignmentModeLeft);
    t.fontName = @"Menlo-Bold";
    t.text = [NSString stringWithFormat:@"MISSION %02lu  -  %@", (unsigned long)_index + 1, [m[@"title"] uppercaseString]];
    t.position = CGPointMake(50, top);
    [_root addChild:t];
    SKLabelNode *loc = Text(14, Amber(0.9), SKLabelHorizontalAlignmentModeLeft);
    loc.text = [NSString stringWithFormat:@"%@   /   SD %@", b[@"location"], b[@"stardate"]];
    loc.position = CGPointMake(50, top - 38);
    [_root addChild:loc];

    // Left: who is talking, the story, then objectives / intel / loadout.
    CGFloat lw = s.width * 0.42 - 60;
    SKLabelNode *who = Text(15, Ink(0.95), SKLabelHorizontalAlignmentModeLeft);
    who.fontName = @"Menlo-Bold";
    who.text = [b[@"speaker"] uppercaseString];
    who.position = CGPointMake(50, top - 78);
    [_root addChild:who];
    _storyText = [b[@"text"] componentsJoinedByString:@"\n\n"];
    _story = Para(15, Ink(0.85), lw);
    _story.position = CGPointMake(50, top - 106);
    _story.text = @"";
    [_root addChild:_story];

    // Measure the full text so the sections below have a fixed place.
    SKLabelNode *probe = Para(15, Ink(0), lw);
    probe.text = _storyText;
    CGFloat y = _story.position.y - probe.frame.size.height - 26;
    NSMutableString *o = [NSMutableString stringWithString:@"OBJECTIVES\n"];
    for (NSDictionary *d in m[@"objectives"])
        [o appendFormat:@"  %@ %@%@\n", [d[@"optional"] boolValue] ? @"o" : @">", d[@"text"], [d[@"optional"] boolValue] ? @" (optional)" : @""];
    [o appendString:@"\nINTEL\n"];
    for (NSString *line in b[@"intel"]) [o appendFormat:@"  - %@\n", line];
    [o appendFormat:@"\nLOADOUT   twin lasers, %d torpedo%@", [m[@"loadout"][@"torpedoes"] intValue], [m[@"loadout"][@"torpedoes"] intValue] == 1 ? @"" : @"es"];
    SKLabelNode *details = Para(14, Ink(0.7), lw);
    details.text = o;
    details.position = CGPointMake(50, y);
    [_root addChild:details];

    // Right: the tactical map with the step caption under it.
    CGFloat mx = s.width * 0.42 + 10, mw = s.width - mx - 50;
    CGFloat mh = MIN(mw, s.height - 260);
    _mapRect = CGRectMake(mx, s.height - 90 - mh, mw, mh);
    [_root addChild:Frame(_mapRect, Ink(0.5), [NSColor colorWithRed:0 green:0.06 blue:0.06 alpha:0.6])];
    [self buildMap:m];
    _stepLabel = Text(13, Amber(0.9), SKLabelHorizontalAlignmentModeLeft);
    _stepLabel.position = CGPointMake(mx, _mapRect.origin.y - 14);
    [_root addChild:_stepLabel];
    _caption = Para(17, Ink(1), mw);
    _caption.position = CGPointMake(mx, _mapRect.origin.y - 36);
    [_root addChild:_caption];
    _steps = b[@"steps"];
    [self applyStep];
    [self footer:@"LEFT / RIGHT  step      ENTER  next / launch      ESC  missions"];
}

- (void)buildMap:(NSDictionary *)m {
    _items = [NSMutableDictionary dictionary];
    _mapLayer = [SKNode node];
    [_root addChild:_mapLayer];

    // Gather everything with a position, then fit the x/z plane into the map.
    NSMutableArray<NSDictionary *> *things = [NSMutableArray array];
    [things addObject:@{ @"id": @"start", @"pos": m[@"player"][@"pos"], @"kind": @"player", @"label": @"LANCER 1" }];
    for (NSDictionary *e in m[@"entities"]) {
        NSString *team = e[@"team"];
        [things addObject:@{ @"id": e[@"id"], @"pos": e[@"pos"], @"kind": @"capital", @"team": team, @"label": e[@"name"] ?: e[@"asset"],
                             @"asset": e[@"asset"], @"group": e[@"group"] ?: @"" }];
    }
    for (NSDictionary *n in m[@"navs"]) [things addObject:@{ @"id": n[@"id"], @"pos": n[@"pos"], @"kind": @"nav", @"label": n[@"name"] }];
    for (NSDictionary *w in m[@"waves"]) {
        NSString *label = w[@"name"] ?: [NSString stringWithFormat:@"%@x %@", w[@"count"], w[@"ship"]];
        [things addObject:@{ @"id": w[@"id"], @"pos": w[@"pos"], @"kind": @"wave", @"team": w[@"team"], @"label": label }];
    }
    for (NSDictionary *f in m[@"fields"]) {
        if ([f[@"type"] isEqualToString:@"mines"])
            [things addObject:@{ @"id": f[@"group"], @"pos": f[@"center"], @"kind": @"field", @"team": @"enemy", @"label": @"MINEFIELD", @"size": f[@"size"] }];
        if ([f[@"type"] isEqualToString:@"asteroids"])
            [things addObject:@{ @"id": @"_rocks", @"pos": f[@"center"], @"kind": @"rocks", @"radius": f[@"radius"], @"label": @"" }];
    }
    float minX = FLT_MAX, maxX = -FLT_MAX, minZ = FLT_MAX, maxZ = -FLT_MAX;
    for (NSDictionary *t in things) {
        if ([t[@"kind"] isEqualToString:@"rocks"]) continue;
        simd_float3 p = Vec3(t[@"pos"]);
        minX = fminf(minX, p.x); maxX = fmaxf(maxX, p.x);
        minZ = fminf(minZ, p.z); maxZ = fmaxf(maxZ, p.z);
    }
    float span = fmaxf(fmaxf(maxX - minX, maxZ - minZ), 800.0f) * 1.25f;
    float cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2;
    CGFloat scale = MIN(_mapRect.size.width, _mapRect.size.height) / span;
    CGPoint mid = CGPointMake(CGRectGetMidX(_mapRect), CGRectGetMidY(_mapRect));
    CGPoint (^project)(simd_float3) = ^CGPoint(simd_float3 p) {
        // Forward (-Z) is up on the map.
        return CGPointMake(mid.x + (p.x - cx) * scale, mid.y - (p.z - cz) * scale);
    };

    // Grid and scale bar.
    for (int i = 1; i < 8; i++) {
        CGFloat gx = _mapRect.origin.x + _mapRect.size.width * i / 8, gy = _mapRect.origin.y + _mapRect.size.height * i / 8;
        SKSpriteNode *v = [SKSpriteNode spriteNodeWithColor:Ink(0.07) size:CGSizeMake(1, _mapRect.size.height)];
        v.position = CGPointMake(gx, CGRectGetMidY(_mapRect));
        SKSpriteNode *h = [SKSpriteNode spriteNodeWithColor:Ink(0.07) size:CGSizeMake(_mapRect.size.width, 1)];
        h.position = CGPointMake(CGRectGetMidX(_mapRect), gy);
        [_mapLayer addChild:v];
        [_mapLayer addChild:h];
    }
    float bar = span > 6000 ? 2000 : 1000;
    SKSpriteNode *sb = [SKSpriteNode spriteNodeWithColor:Ink(0.7) size:CGSizeMake(bar * scale, 2)];
    sb.anchorPoint = CGPointMake(0, 0.5);
    sb.position = CGPointMake(_mapRect.origin.x + 16, _mapRect.origin.y + 18);
    [_mapLayer addChild:sb];
    SKLabelNode *sl = Text(11, Ink(0.7), SKLabelHorizontalAlignmentModeLeft);
    sl.text = [NSString stringWithFormat:@"%.0f KM", bar / 1000];
    sl.position = CGPointMake(_mapRect.origin.x + 16, _mapRect.origin.y + 36);
    [_mapLayer addChild:sl];

    for (NSDictionary *t in things) {
        NSString *kind = t[@"kind"];
        CGPoint p = project(Vec3(t[@"pos"]));
        SKNode *icon;
        NSColor *c = [t[@"team"] isEqualToString:@"enemy"] ? Red(1) : ([t[@"team"] isEqualToString:@"neutral"] ? Yellow(1) : Blue(1));
        if ([kind isEqualToString:@"rocks"]) {
            CGFloat r = [t[@"radius"] floatValue] * scale;
            SKShapeNode *field = [SKShapeNode shapeNodeWithCircleOfRadius:r];
            field.strokeColor = [NSColor colorWithWhite:0.6 alpha:0.25];
            field.fillColor = [NSColor colorWithWhite:0.5 alpha:0.06];
            field.position = p;
            [_mapLayer addChild:field];
            continue;
        } else if ([kind isEqualToString:@"player"]) {
            CGMutablePathRef a = CGPathCreateMutable();
            CGPathMoveToPoint(a, NULL, 0, 10); CGPathAddLineToPoint(a, NULL, 7, -7); CGPathAddLineToPoint(a, NULL, -7, -7);
            CGPathCloseSubpath(a);
            SKShapeNode *n = [SKShapeNode shapeNodeWithPath:a];
            CGPathRelease(a);
            n.fillColor = Ink(0.9);
            n.strokeColor = Ink(1);
            icon = n;
        } else if ([kind isEqualToString:@"nav"]) {
            CGMutablePathRef a = CGPathCreateMutable();
            CGPathMoveToPoint(a, NULL, 0, 8); CGPathAddLineToPoint(a, NULL, 8, 0); CGPathAddLineToPoint(a, NULL, 0, -8); CGPathAddLineToPoint(a, NULL, -8, 0);
            CGPathCloseSubpath(a);
            SKShapeNode *n = [SKShapeNode shapeNodeWithPath:a];
            CGPathRelease(a);
            n.strokeColor = Ink(1);
            n.lineWidth = 2;
            icon = n;
        } else if ([kind isEqualToString:@"wave"]) {
            SKNode *g = [SKNode node];
            for (int k = 0; k < 3; k++) {
                CGMutablePathRef a = CGPathCreateMutable();
                CGPathMoveToPoint(a, NULL, 0, 5); CGPathAddLineToPoint(a, NULL, 4, -4); CGPathAddLineToPoint(a, NULL, -4, -4);
                CGPathCloseSubpath(a);
                SKShapeNode *n = [SKShapeNode shapeNodeWithPath:a];
                CGPathRelease(a);
                n.fillColor = c;
                n.strokeColor = [NSColor clearColor];
                n.position = CGPointMake((k - 1) * 9, k == 1 ? 5 : 0);
                [g addChild:n];
            }
            icon = g;
        } else if ([kind isEqualToString:@"field"]) {
            NSArray *sz = t[@"size"];
            SKShapeNode *n = [SKShapeNode shapeNodeWithRect:CGRectMake(-[sz[0] floatValue] * scale / 2, -[sz[2] floatValue] * scale / 2,
                                                                       [sz[0] floatValue] * scale, [sz[2] floatValue] * scale)];
            n.strokeColor = Red(0.6);
            n.fillColor = Red(0.08);
            icon = n;
        } else {
            // Capital icon scaled to the real hull, pointing along its facing.
            NSDictionary *info = AssetInfo(t[@"asset"]);
            BOOL prop = [info[@"prop"] boolValue];
            CGFloat len = prop ? 6 : MAX(12, MIN(60, [info[@"hp"] floatValue] * 0.9 + 10));
            SKShapeNode *n = prop ? [SKShapeNode shapeNodeWithRect:CGRectMake(-3, -3, 6, 6)]
                                  : [SKShapeNode shapeNodeWithRect:CGRectMake(-len * 0.18, -len / 2, len * 0.36, len) cornerRadius:3];
            n.strokeColor = c;
            n.fillColor = [c colorWithAlphaComponent:0.35];
            n.lineWidth = 1.5;
            icon = n;
        }
        icon.position = p;
        SKNode *holder = [SKNode node];
        [holder addChild:icon];
        if ([t[@"label"] length] && ![kind isEqualToString:@"field"] && !([kind isEqualToString:@"capital"] && [t[@"group"] length])) {
            SKLabelNode *l = Text(11, Ink(0.85), SKLabelHorizontalAlignmentModeLeft);
            l.text = [t[@"label"] uppercaseString];
            l.position = CGPointMake(p.x + 12, p.y + 6);
            [holder addChild:l];
        } else if ([kind isEqualToString:@"field"]) {
            SKLabelNode *l = Text(11, Red(0.9), SKLabelHorizontalAlignmentModeCenter);
            l.text = t[@"label"];
            l.position = CGPointMake(p.x, p.y - 6);
            [holder addChild:l];
        }
        [_mapLayer addChild:holder];
        MapItem *item = [MapItem new];
        item.identifier = t[@"id"];
        item.group = [t[@"group"] length] ? t[@"group"] : nil;
        item.point = p;
        item.node = holder;
        _items[t[@"id"]] = item;
        // Groups (e.g. containers, pods) answer to the group name too.
        if ([t[@"group"] length]) {
            MapItem *g = _items[t[@"group"]];
            if (!g) {
                g = [MapItem new];
                g.identifier = t[@"group"];
                g.container = YES;
                g.point = p;
                g.node = [SKNode node];
                [_mapLayer addChild:g.node];
                _items[t[@"group"]] = g;
            }
            [holder removeFromParent];
            [g.node addChild:holder];
        }
    }
    _routeLayer = [SKNode node];
    [_mapLayer addChild:_routeLayer];
    _focusRing = [SKShapeNode shapeNodeWithCircleOfRadius:18];
    _focusRing.strokeColor = Amber(1);
    _focusRing.lineWidth = 2;
    [_mapLayer addChild:_focusRing];
}

- (void)applyStep {
    if (!_steps.count) return;
    NSDictionary *st = _steps[_step];
    _stepLabel.text = [NSString stringWithFormat:@"BRIEFING  %lu / %lu", (unsigned long)_step + 1, (unsigned long)_steps.count];
    _caption.text = st[@"caption"];
    NSSet *show = [NSSet setWithArray:st[@"show"] ?: @[]];
    // Lit: named in the step, or a member of a group named in the step.
    for (MapItem *it in _items.allValues) {
        if (it.container) continue;
        BOOL lit = [show containsObject:it.identifier] || (it.group && [show containsObject:it.group]);
        it.node.alpha = lit ? 1.0 : 0.28;
    }
    [_routeLayer removeAllChildren];
    NSArray *route = st[@"route"];
    if (route.count > 1) {
        CGMutablePathRef path = CGPathCreateMutable();
        BOOL first = YES;
        for (NSString *rid in route) {
            MapItem *it = _items[rid];
            if (!it) continue;
            if (first) CGPathMoveToPoint(path, NULL, it.point.x, it.point.y);
            else CGPathAddLineToPoint(path, NULL, it.point.x, it.point.y);
            first = NO;
        }
        CGFloat dash[] = { 8, 6 };
        CGPathRef dashed = CGPathCreateCopyByDashingPath(path, NULL, 0, dash, 2);
        SKShapeNode *line = [SKShapeNode shapeNodeWithPath:dashed];
        line.strokeColor = Amber(0.9);
        line.lineWidth = 2;
        [_routeLayer addChild:line];
        CGPathRelease(dashed);
        CGPathRelease(path);
    }
    MapItem *focus = _items[st[@"focus"] ?: @""];
    _focusRing.hidden = !focus;
    if (focus) _focusRing.position = focus.point;
}

#pragma mark - Debrief

- (void)showDebrief:(NSUInteger)index success:(BOOL)success results:(NSArray<NSString *> *)results {
    _mode = ModeDebrief;
    _index = index;
    _success = success;
    [self rebuild];
    CGSize s = self.size;
    NSDictionary *m = CampaignMission(index);
    SKLabelNode *t = Text(40, success ? Ink(1) : Red(1), SKLabelHorizontalAlignmentModeCenter);
    t.fontName = @"Menlo-Bold";
    t.text = success ? @"MISSION COMPLETE" : @"MISSION FAILED";
    t.position = CGPointMake(s.width / 2, s.height - 120);
    [_root addChild:t];
    SKLabelNode *name = Text(18, Amber(0.9), SKLabelHorizontalAlignmentModeCenter);
    name.text = [NSString stringWithFormat:@"MISSION %02lu  -  %@", (unsigned long)index + 1, [m[@"title"] uppercaseString]];
    name.position = CGPointMake(s.width / 2, s.height - 180);
    [_root addChild:name];
    CGFloat w = MIN(900, s.width - 120);
    SKLabelNode *p = Para(18, Ink(0.9), w);
    p.text = success ? m[@"debrief"][@"win"] : m[@"debrief"][@"lose"];
    p.position = CGPointMake((s.width - w) / 2, s.height - 240);
    [_root addChild:p];
    SKLabelNode *r = Para(16, Ink(0.75), w);
    NSMutableString *lines = [NSMutableString stringWithString:@"OBJECTIVES\n"];
    for (NSString *line in results) [lines appendFormat:@"  %@\n", line];
    r.text = lines;
    r.position = CGPointMake((s.width - w) / 2, p.position.y - p.frame.size.height - 40);
    [_root addChild:r];
    BOOL more = success && index + 1 < CampaignMissions().count;
    [self footer:success ? (more ? @"ENTER  next mission      R  fly again      ESC  missions" : @"ENTER  missions      R  fly again")
                         : @"ENTER / R  retry      ESC  missions"];
}

#pragma mark - Input & animation

- (BriefingCommand)handle:(InputAction)a {
    NSUInteger count = CampaignMissions().count;
    switch (_mode) {
        case ModeList:
            if (a & InputActionUp) [self showListSelecting:(_index + count - 1) % count];
            if (a & InputActionDown) [self showListSelecting:(_index + 1) % count];
            if ((a & InputActionConfirm) && _index < ProgressUnlockedCount()) [self showBriefing:_index];
            break;
        case ModeBriefing:
            if (a & InputActionBack) { [self showListSelecting:_index]; break; }
            if (a & InputActionLeft) { _step = _step > 0 ? _step - 1 : 0; [self applyStep]; }
            if (a & InputActionRight) { _step = MIN(_step + 1, _steps.count - 1); [self applyStep]; }
            if (a & InputActionConfirm) {
                // First press finishes the typing, then steps, then launch.
                if (_story.text.length < _storyText.length) _typeStart = -1e9;
                else if (_step + 1 < _steps.count) { _step++; [self applyStep]; }
                else return BriefingCommandLaunch;
            }
            break;
        case ModeDebrief:
            if (a & InputActionBack) [self showListSelecting:_index];
            else if (a & InputActionRestart) return BriefingCommandLaunch;
            else if (a & InputActionConfirm) {
                if (!_success) return BriefingCommandLaunch;
                if (_index + 1 < count) [self showBriefing:_index + 1];
                else [self showListSelecting:_index];
            }
            break;
    }
    return BriefingCommandNone;
}

- (void)tick:(double)time {
    _now = time;
    if (!CGSizeEqualToSize(self.size, _laidOut) && _mode != ModeDebrief) [self rebuild];
    if (_mode != ModeBriefing) return;
    // Typewriter: 90 characters a second.
    NSUInteger n = MIN(_storyText.length, (NSUInteger)MAX(0.0, (time - _typeStart) * 90.0));
    if (n != _story.text.length) _story.text = [_storyText substringToIndex:n];
    CGFloat pulse = 1.0 + 0.25 * sin(time * 5.0);
    _focusRing.xScale = _focusRing.yScale = pulse;
    _focusRing.alpha = 0.6 + 0.4 * sin(time * 5.0);
}

@end
