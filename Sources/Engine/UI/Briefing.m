#import "Briefing.h"
#import "Assets.h"
#import "Progress.h"
#import "UIStyle.h"

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

// The Bastion terminals use dark steel, copper edging and phosphor displays.
static const UIRGB BastionSteel = { 0.055, 0.047, 0.041 };
static const UIRGB BastionEdge = { 0.51, 0.31, 0.17 };
static const UIRGB BastionGlass = { 0.014, 0.055, 0.058 };

static SKShapeNode *ConsolePanel(CGRect rect, UIRGB fill, CGFloat opacity) {
    CGFloat x = CGRectGetMinX(rect), y = CGRectGetMinY(rect);
    CGFloat r = CGRectGetMaxX(rect), t = CGRectGetMaxY(rect);
    CGFloat cut = MIN(9, MIN(rect.size.width, rect.size.height) * 0.25);
    const CGPoint corners[] = {
        {x + cut, y}, {r, y}, {r, t - cut}, {r - cut, t}, {x, t}, {x, y + cut}
    };
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddLines(path, NULL, corners, sizeof(corners) / sizeof(*corners));
    CGPathCloseSubpath(path);
    SKShapeNode *panel = [SKShapeNode shapeNodeWithPath:path];
    CGPathRelease(path);
    panel.fillColor = UIColorWithOpacity(fill, opacity);
    panel.strokeColor = UIColorWithOpacity(BastionEdge, 0.95);
    panel.lineWidth = 1.5;
    return panel;
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
    NSArray<NSString *> *_results;
    NSDictionary *_dialogueScene;
    NSArray<NSDictionary *> *_pages;
    NSUInteger _page;
    CGRect _confirmRect;
    NSValue *_queuedClick;
    NSMutableDictionary<NSString *, SKTexture *> *_art;
    SKNode *_root;
    CGSize _laidOut;

    // Briefing state
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
        _art = [NSMutableDictionary dictionary];
        [self addChild:_root];
    }
    return self;
}

- (NSUInteger)selectedIndex { return _index; }

- (void)rebuild {
    [_root removeAllChildren];
    _confirmRect = CGRectZero;
    _laidOut = self.size;
    BOOL illustrated = _mode == ModeBriefing;
    self.backgroundColor = illustrated ? UIColorWithOpacity(UIBackground, 1) : [NSColor clearColor];
    if (!illustrated) {
        SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIBlack, 0.72) size:self.size];
        shade.anchorPoint = CGPointZero;
        [_root addChild:shade];
    }
    switch (_mode) {
        case ModeList: [self buildList]; break;
        case ModeBriefing: [self buildBriefing]; break;
        case ModeDebrief: [self buildDebrief]; break;
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
    SKLabelNode *t = Text(30, UIColorWithOpacity(UIInk, 1), SKLabelHorizontalAlignmentModeLeft);
    t.fontName = @"Menlo-Bold";
    t.text = @"KESTREL FRONTIER";
    t.position = CGPointMake(60, top);
    [_root addChild:t];
    SKLabelNode *sub = Text(15, UIColorWithOpacity(UIInk, 0.6), SKLabelHorizontalAlignmentModeLeft);
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
            SKShapeNode *bar = UISkewedShape(CGRectMake(50, y - rowH + 4, listW, rowH - 2), UIColorWithOpacity(UIInk, 0.8), UIColorWithOpacity(UIInk, 0.12));
            [_root addChild:bar];
        }
        SKLabelNode *l = Text(MIN(17, rowH * 0.6), open ? (sel ? UIColorWithOpacity(UIInk, 1) : UIColorWithOpacity(UIInk, 0.75)) : UIColorWithOpacity(UIInk, 0.25), SKLabelHorizontalAlignmentModeLeft);
        l.text = [NSString stringWithFormat:@"%02lu   %@", (unsigned long)i + 1, open ? [all[i][@"title"] uppercaseString] : @"-- CLASSIFIED --"];
        l.position = CGPointMake(64, y - 4);
        [_root addChild:l];
    }

    // Preview of the selected mission.
    NSDictionary *m = all[_index];
    BOOL open = _index < unlocked;
    CGFloat px = listW + 100, pw = s.width - px - 60;
    [_root addChild:Frame(CGRectMake(px - 20, 90, pw + 20, top - 160), UIColorWithOpacity(UIInk, 0.4), UIColorWithOpacity(UIBlack, 0.35))];
    SKLabelNode *title = Text(24, UIColorWithOpacity(UIInk, 1), SKLabelHorizontalAlignmentModeLeft);
    title.fontName = @"Menlo-Bold";
    title.text = open ? [m[@"title"] uppercaseString] : @"CLASSIFIED";
    title.position = CGPointMake(px, top - 90);
    [_root addChild:title];
    if (open) {
        NSDictionary *b = m[@"briefing"];
        SKLabelNode *loc = Text(15, UIColorWithOpacity(UIAmber, 0.9), SKLabelHorizontalAlignmentModeLeft);
        loc.text = [NSString stringWithFormat:@"%@   /   SD %@", b[@"location"], b[@"stardate"]];
        loc.position = CGPointMake(px, top - 128);
        [_root addChild:loc];
        SKLabelNode *p = Para(16, UIColorWithOpacity(UIInk, 0.8), pw - 20);
        p.text = [b[@"text"] firstObject];
        p.position = CGPointMake(px, top - 165);
        [_root addChild:p];
        SKLabelNode *objs = Para(15, UIColorWithOpacity(UIInk, 0.65), pw - 20);
        NSMutableString *o = [NSMutableString stringWithString:@"OBJECTIVES\n"];
        for (NSDictionary *d in m[@"objectives"]) [o appendFormat:@"  %@ %@\n", [d[@"optional"] boolValue] ? @"o" : @">", d[@"text"]];
        objs.text = o;
        objs.position = CGPointMake(px, p.position.y - p.frame.size.height - 30);
        [_root addChild:objs];
    } else {
        SKLabelNode *p = Para(16, UIColorWithOpacity(UIInk, 0.5), pw - 20);
        p.text = @"Complete the previous missions to unlock this briefing.";
        p.position = CGPointMake(px, top - 130);
        [_root addChild:p];
    }
    [self footer:@"↑ / ↓  Select mission" action:open ? @"BRIEFING" : nil];
}

- (void)footer:(NSString *)text action:(NSString *)action {
    CGFloat inset = MIN(50, self.size.width * 0.05);
    BOOL console = _mode == ModeBriefing;
    if (console) [_root addChild:ConsolePanel(CGRectMake(inset - 10, 14, MAX(1, self.size.width - 2 * inset + 20), 52), BastionSteel, 0.91)];
    SKLabelNode *hint = Para(12, UIColorWithOpacity(UIInk, console ? 0.9 : 0.65),
                             MAX(1, self.size.width - 2 * inset - (action ? 200 : 0)));
    hint.text = text;
    hint.position = CGPointMake(inset, 40);
    [_root addChild:hint];
    if (!action) return;

    _confirmRect = CGRectMake(self.size.width - inset - 180, 20, 180, 40);
    [_root addChild:UISkewedShape(_confirmRect, UIColorWithOpacity(console ? UIAmber : UIInk, 0.85),
                                 UIColorWithOpacity(UIPanel, 0.96))];
    SKLabelNode *label = Text(13, UIColorWithOpacity(UIInk, 1), SKLabelHorizontalAlignmentModeCenter);
    label.fontName = @"Menlo-Bold";
    label.verticalAlignmentMode = SKLabelVerticalAlignmentModeCenter;
    label.position = CGPointMake(CGRectGetMidX(_confirmRect), CGRectGetMidY(_confirmRect));
    label.text = action;
    [_root addChild:label];
}

#pragma mark - Briefing

- (void)showBriefing:(NSUInteger)index {
    _index = MIN(index, CampaignMissions().count - 1);
    NSDictionary *mission = CampaignMission(_index);
    NSDictionary *brief = mission[@"briefing"];
    _dialogueScene = brief[@"dialogue"];
    NSString *speaker = brief[@"speaker"] ?: @"Bastion Control";
    NSString *portrait = [speaker containsString:@"Okafor"] ? @"Okafor" : @"Varn";
    NSMutableArray<NSDictionary *> *pages = [NSMutableArray array];
    for (NSDictionary *line in _dialogueScene[@"lines"]) {
        [pages addObject:@{ @"speaker": line[@"speaker"], @"portrait": line[@"portrait"],
                            @"text": line[@"text"], @"channel": @"MISSION BRIEFING",
                            @"cast": _dialogueScene[@"cast"] ?: @[line[@"portrait"]] }];
    }

    // The mission's original briefing is the officer's speech. Each tactical
    // cue and each readout gets its own beat on the same wall monitor.
    for (NSString *text in brief[@"text"]) {
        [pages addObject:@{ @"speaker": speaker, @"portrait": portrait,
                            @"text": text, @"channel": @"SITUATION" }];
    }
    for (NSDictionary *step in brief[@"steps"]) {
        [pages addObject:@{ @"speaker": speaker, @"portrait": portrait, @"tactical": step,
                            @"text": step[@"caption"] ?: @"", @"channel": @"FLIGHT PLAN" }];
    }

    NSMutableArray<NSString *> *orders = [NSMutableArray array];
    for (NSDictionary *objective in mission[@"objectives"]) {
        [orders addObject:[NSString stringWithFormat:@"%@%@", objective[@"text"],
                           [objective[@"optional"] boolValue] ? @" (optional)" : @""]];
    }
    if (orders.count) {
        [pages addObject:@{ @"speaker": speaker, @"portrait": portrait, @"readout": orders,
                            @"text": @"Your orders are on the board, Lancer.", @"channel": @"OBJECTIVES" }];
    }
    int torpedoes = [mission[@"loadout"][@"torpedoes"] intValue];
    NSString *loadout = [NSString stringWithFormat:@"Loadout: twin lasers, %d torpedo%@", torpedoes, torpedoes == 1 ? @"" : @"es"];
    NSArray *intel = [(brief[@"intel"] ?: @[]) arrayByAddingObject:loadout];
    [pages addObject:@{ @"speaker": speaker, @"portrait": portrait, @"readout": intel,
                        @"text": @"Check the intel and your loadout. Launch when ready.", @"channel": @"INTEL / LOADOUT" }];
    _pages = pages;
    _page = 0;
    _mode = ModeBriefing;
    [self rebuild];
}

- (SKSpriteNode *)artNamed:(NSString *)name {
    SKTexture *texture = _art[name];
    if (!texture) {
        NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"png" subdirectory:@"Briefing"];
        NSImage *image = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
        if (!image) return nil;
        texture = [SKTexture textureWithImage:image];
        _art[name] = texture;
    }
    return [SKSpriteNode spriteNodeWithTexture:texture];
}

// Return the painted monitor's position after an aspect-fill crop. The
// coordinates describe the inside of the cyan bezel in Bastion.png.
- (CGRect)addBackdrop:(NSString *)name {
    CGSize size = self.size;
    SKSpriteNode *art = [self artNamed:name];
    if (!art) return CGRectZero;
    CGFloat scale = MAX(size.width / art.size.width, size.height / art.size.height);
    [art setScale:scale];
    art.position = CGPointMake(size.width / 2, size.height / 2);
    [_root addChild:art];
    SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIBlack, 0.12) size:size];
    shade.anchorPoint = CGPointZero;
    [_root addChild:shade];

    CGRect frame = art.frame;
    return CGRectMake(frame.origin.x + frame.size.width * 0.25,
                      frame.origin.y + frame.size.height * 0.465,
                      frame.size.width * 0.50, frame.size.height * 0.375);
}

- (void)buildBriefing {
    CGSize size = self.size;
    NSDictionary *mission = CampaignMission(_index);
    NSDictionary *page = _pages[_page];
    CGFloat inset = MIN(44, size.width * 0.045);
    CGFloat panelWidth = MAX(1, size.width - 2 * inset);
    CGFloat textSize = MAX(16, MIN(24, size.width / 60));
    SKLabelNode *speech = Para(textSize, UIColorWithOpacity(UIWhite, 1), MAX(1, panelWidth - 40));
    speech.fontName = @"HelveticaNeue";
    // Reserve room for the tallest caption at this width so the portrait
    // and nameplate stay anchored as the dialogue advances.
    CGFloat captionHeight = 0;
    for (NSDictionary *beat in _pages) {
        speech.text = beat[@"text"];
        captionHeight = MAX(captionHeight, speech.frame.size.height);
    }
    speech.text = page[@"text"];
    CGFloat panelBottom = 72;
    CGFloat panelHeight = MAX(82, captionHeight + 54);
    CGFloat panelTop = panelBottom + panelHeight;

    CGRect screen = [self addBackdrop:_dialogueScene[@"room"] ?: @"Bastion"];
    if (CGRectIsEmpty(screen)) {
        screen = CGRectMake(size.width * 0.25, size.height * 0.465,
                            size.width * 0.50, size.height * 0.375);
        [_root addChild:ConsolePanel(screen, BastionGlass, 1)];
    }
    _focusRing = nil;
    [self buildMonitor:screen mission:mission page:page];

    NSArray<NSString *> *cast = page[@"cast"] ?: @[page[@"portrait"]];
    CGFloat wingWidth = MAX(1, CGRectGetMinX(screen));
    for (NSUInteger i = 0; i < MIN(cast.count, 2); i++) {
        NSString *name = cast[i];
        SKSpriteNode *portrait = [self artNamed:name];
        if (!portrait) continue;
        CGFloat maxWidth = MIN(size.width * 0.31, wingWidth * 1.45);
        CGFloat maxHeight = MAX(1, size.height - panelTop - 56);
        [portrait setScale:MIN(maxWidth / portrait.size.width, maxHeight / portrait.size.height)];
        portrait.anchorPoint = CGPointMake(0.5, 0);
        CGFloat center = wingWidth * 0.65;
        portrait.position = CGPointMake(i == 0 ? center : size.width - center, panelTop - 10);
        portrait.color = UIColorWithOpacity(UIBackground, 1);
        portrait.colorBlendFactor = [page[@"portrait"] isEqualToString:name] ? 0 : 0.30;
        [_root addChild:portrait];
    }

    [_root addChild:ConsolePanel(CGRectMake(inset, panelBottom, panelWidth, panelHeight), BastionSteel, 0.95)];
    SKLabelNode *speaker = Text(14, UIColorWithOpacity(UIAmber, 1), SKLabelHorizontalAlignmentModeLeft);
    speaker.fontName = @"Menlo-Bold";
    speaker.text = [page[@"speaker"] uppercaseString];
    speaker.position = CGPointMake(inset + 20, panelTop - 12);
    [_root addChild:speaker];
    speech.position = CGPointMake(inset + 20, panelTop - 36);
    [_root addChild:speech];
    [self footer:@"← / →  Briefing     Esc  Missions"
           action:_page + 1 == _pages.count ? @"↵  LAUNCH" : @"↵  CONTINUE"];
}

- (void)buildMonitor:(CGRect)screen mission:(NSDictionary *)mission page:(NSDictionary *)page {
    NSDictionary *brief = mission[@"briefing"];
    CGFloat pad = MIN(22, screen.size.width * 0.04);
    CGFloat left = CGRectGetMinX(screen) + pad, right = CGRectGetMaxX(screen) - pad;
    CGFloat top = CGRectGetMaxY(screen) - 5;
    CGFloat width = MAX(1, right - left);
    CGFloat titleSize = MIN(21, MAX(12, width / 29));
    SKLabelNode *title = Para(titleSize, UIColorWithOpacity(UIInk, 1), width);
    title.fontName = @"Menlo-Bold";
    title.text = [NSString stringWithFormat:@"%02lu  /  %@", (unsigned long)_index + 1, [mission[@"title"] uppercaseString]];
    title.position = CGPointMake(left, top);
    [_root addChild:title];

    SKLabelNode *location = Para(MIN(13, MAX(9, width / 45)), UIColorWithOpacity(UIInk, 0.75), width);
    location.text = [NSString stringWithFormat:@"%@  /  SD %@", brief[@"location"], brief[@"stardate"]];
    location.position = CGPointMake(left, CGRectGetMinY(title.frame) - 4);
    [_root addChild:location];

    CGFloat channelY = CGRectGetMinY(location.frame) - 10;
    SKLabelNode *channel = Text(12, UIColorWithOpacity(UIAmber, 1), SKLabelHorizontalAlignmentModeLeft);
    channel.fontName = @"Menlo-Bold";
    channel.text = page[@"channel"];
    channel.position = CGPointMake(left, channelY);
    [_root addChild:channel];
    SKLabelNode *counter = Text(12, UIColorWithOpacity(UIInk, 0.7), SKLabelHorizontalAlignmentModeRight);
    counter.text = [NSString stringWithFormat:@"%02lu / %02lu", (unsigned long)_page + 1, (unsigned long)_pages.count];
    counter.position = CGPointMake(right, channelY);
    [_root addChild:counter];

    CGFloat contentTop = CGRectGetMinY(channel.frame) - 8;
    CGFloat bottom = CGRectGetMinY(screen) + 4;
    NSArray<NSString *> *readout = page[@"readout"];
    if (readout.count) {
        NSString *lines = [@"›  " stringByAppendingString:[readout componentsJoinedByString:@"\n›  "]];
        CGFloat fontSize = MIN(20, MAX(12, width / 32));
        SKLabelNode *list = Para(fontSize, UIColorWithOpacity(UIInk, 0.96), width);
        list.fontName = @"HelveticaNeue-Medium";
        list.text = lines;
        list.position = CGPointMake(left, contentTop - 8);
        while (list.fontSize > 10 && CGRectGetMinY(list.frame) < bottom) list.fontSize -= 1;
        [_root addChild:list];
        return;
    }

    _mapRect = CGRectMake(left, bottom, width, MAX(1, contentTop - bottom));
    [self buildMap:mission];
    NSDictionary *step = page[@"tactical"];
    NSString *dialogueFocus = _dialogueScene[@"focus"];
    if (!step && page[@"cast"] && dialogueFocus) {
        step = @{ @"show": @[dialogueFocus], @"focus": dialogueFocus };
    }
    [self applyTacticalCue:step];
}

- (void)buildMap:(NSDictionary *)m {
    _items = [NSMutableDictionary dictionary];
    SKCropNode *display = [SKCropNode node];
    SKSpriteNode *mask = [SKSpriteNode spriteNodeWithColor:[NSColor whiteColor] size:_mapRect.size];
    mask.position = CGPointMake(CGRectGetMidX(_mapRect), CGRectGetMidY(_mapRect));
    display.maskNode = mask;
    _mapLayer = [SKNode node];
    [display addChild:_mapLayer];
    [_root addChild:display];

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
        SKSpriteNode *v = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.07) size:CGSizeMake(1, _mapRect.size.height)];
        v.position = CGPointMake(gx, CGRectGetMidY(_mapRect));
        SKSpriteNode *h = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.07) size:CGSizeMake(_mapRect.size.width, 1)];
        h.position = CGPointMake(CGRectGetMidX(_mapRect), gy);
        [_mapLayer addChild:v];
        [_mapLayer addChild:h];
    }
    float bar = span > 6000 ? 2000 : 1000;
    SKSpriteNode *sb = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.7) size:CGSizeMake(bar * scale, 2)];
    sb.anchorPoint = CGPointMake(0, 0.5);
    sb.position = CGPointMake(_mapRect.origin.x + 16, _mapRect.origin.y + 18);
    [_mapLayer addChild:sb];
    SKLabelNode *sl = Text(11, UIColorWithOpacity(UIInk, 0.7), SKLabelHorizontalAlignmentModeLeft);
    sl.text = [NSString stringWithFormat:@"%.0f KM", bar / 1000];
    sl.position = CGPointMake(_mapRect.origin.x + 16, _mapRect.origin.y + 36);
    [_mapLayer addChild:sl];

    for (NSDictionary *t in things) {
        NSString *kind = t[@"kind"];
        CGPoint p = project(Vec3(t[@"pos"]));
        SKNode *icon;
        NSColor *c = [t[@"team"] isEqualToString:@"enemy"] ? UIColorWithOpacity(UIRed, 1) : ([t[@"team"] isEqualToString:@"neutral"] ? UIColorWithOpacity(UIYellow, 1) : UIColorWithOpacity(UIBlue, 1));
        if ([kind isEqualToString:@"rocks"]) {
            CGFloat r = [t[@"radius"] floatValue] * scale;
            SKShapeNode *field = [SKShapeNode shapeNodeWithCircleOfRadius:r];
            field.strokeColor = UIColorWithOpacity(UIField, 0.25);
            field.fillColor = UIColorWithOpacity(UIField, 0.06);
            field.position = p;
            [_mapLayer addChild:field];
            continue;
        } else if ([kind isEqualToString:@"player"]) {
            CGMutablePathRef a = CGPathCreateMutable();
            CGPathMoveToPoint(a, NULL, 0, 10); CGPathAddLineToPoint(a, NULL, 7, -7); CGPathAddLineToPoint(a, NULL, -7, -7);
            CGPathCloseSubpath(a);
            SKShapeNode *n = [SKShapeNode shapeNodeWithPath:a];
            CGPathRelease(a);
            n.fillColor = UIColorWithOpacity(UIInk, 0.9);
            n.strokeColor = UIColorWithOpacity(UIInk, 1);
            icon = n;
        } else if ([kind isEqualToString:@"nav"]) {
            CGMutablePathRef a = CGPathCreateMutable();
            CGPathMoveToPoint(a, NULL, 0, 8); CGPathAddLineToPoint(a, NULL, 8, 0); CGPathAddLineToPoint(a, NULL, 0, -8); CGPathAddLineToPoint(a, NULL, -8, 0);
            CGPathCloseSubpath(a);
            SKShapeNode *n = [SKShapeNode shapeNodeWithPath:a];
            CGPathRelease(a);
            n.strokeColor = UIColorWithOpacity(UIInk, 1);
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
            n.strokeColor = UIColorWithOpacity(UIRed, 0.6);
            n.fillColor = UIColorWithOpacity(UIRed, 0.08);
            icon = n;
        } else {
            // Capital icon scaled to the real hull, pointing along its facing.
            NSDictionary *info = AssetInfo(t[@"asset"]);
            BOOL prop = [info[@"prop"] boolValue];
            CGFloat maxLength = MIN(60, _mapRect.size.height * 0.15);
            CGFloat len = prop ? 6 : MIN(maxLength, MAX(12, [info[@"hp"] floatValue] * 0.9 + 10));
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
            SKLabelNode *l = Text(11, UIColorWithOpacity(UIInk, 0.85), SKLabelHorizontalAlignmentModeLeft);
            l.text = [t[@"label"] uppercaseString];
            l.position = CGPointMake(p.x + 12, p.y + 6);
            [holder addChild:l];
        } else if ([kind isEqualToString:@"field"]) {
            SKLabelNode *l = Text(11, UIColorWithOpacity(UIRed, 0.9), SKLabelHorizontalAlignmentModeCenter);
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
    _focusRing.strokeColor = UIColorWithOpacity(UIAmber, 1);
    _focusRing.lineWidth = 2;
    [_mapLayer addChild:_focusRing];
}

- (void)applyTacticalCue:(NSDictionary *)st {
    NSSet *show = [NSSet setWithArray:st[@"show"] ?: @[]];
    // Lit: named in the step, or a member of a group named in the step.
    for (MapItem *it in _items.allValues) {
        if (it.container) continue;
        BOOL lit = [show containsObject:it.identifier] || (it.group && [show containsObject:it.group]);
        it.node.alpha = lit ? 1.0 : (st ? 0.22 : 0.45);
    }
    // The step's focus is the one thing at full contrast: bright bold label,
    // slightly larger icon. Everything else lit stays at its normal weight.
    NSString *focusID = st[@"focus"] ?: @"";
    for (MapItem *it in _items.allValues) {
        if (it.container) continue;
        BOOL focused = [it.identifier isEqualToString:focusID] || (it.group && [it.group isEqualToString:focusID]);
        for (SKNode *c in it.node.children) {
            if ([c isKindOfClass:[SKLabelNode class]]) {
                SKLabelNode *l = (SKLabelNode *)c;
                if (![l.userData[@"ink"] isKindOfClass:[NSColor class]]) l.userData = [@{ @"ink": l.fontColor } mutableCopy];
                l.fontColor = focused ? UIColorWithOpacity(UIWhite, 1) : l.userData[@"ink"];
                l.fontName = focused ? @"Menlo-Bold" : @"Menlo";
            } else {
                c.xScale = c.yScale = focused ? 1.3 : 1.0;
            }
        }
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
        line.strokeColor = UIColorWithOpacity(UIAmber, 0.9);
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
    _results = [results copy];
    [self rebuild];
}

- (void)buildDebrief {
    BOOL success = _success;
    NSUInteger index = _index;
    CGSize s = self.size;
    NSDictionary *m = CampaignMission(index);
    SKLabelNode *t = Text(40, success ? UIColorWithOpacity(UIInk, 1) : UIColorWithOpacity(UIRed, 1), SKLabelHorizontalAlignmentModeCenter);
    t.fontName = @"Menlo-Bold";
    t.text = success ? @"MISSION COMPLETE" : @"MISSION FAILED";
    t.position = CGPointMake(s.width / 2, s.height - 120);
    [_root addChild:t];
    SKLabelNode *name = Text(18, UIColorWithOpacity(UIAmber, 0.9), SKLabelHorizontalAlignmentModeCenter);
    name.text = [NSString stringWithFormat:@"MISSION %02lu  -  %@", (unsigned long)index + 1, [m[@"title"] uppercaseString]];
    name.position = CGPointMake(s.width / 2, s.height - 180);
    [_root addChild:name];
    CGFloat w = MIN(900, s.width - 120);
    SKLabelNode *p = Para(18, UIColorWithOpacity(UIInk, 0.9), w);
    p.text = success ? m[@"debrief"][@"win"] : m[@"debrief"][@"lose"];
    p.position = CGPointMake((s.width - w) / 2, s.height - 240);
    [_root addChild:p];
    SKLabelNode *r = Para(16, UIColorWithOpacity(UIInk, 0.75), w);
    NSMutableString *lines = [NSMutableString stringWithString:@"OBJECTIVES\n"];
    for (NSString *line in _results) [lines appendFormat:@"  %@\n", line];
    r.text = lines;
    r.position = CGPointMake((s.width - w) / 2, p.position.y - p.frame.size.height - 40);
    [_root addChild:r];
    BOOL more = success && index + 1 < CampaignMissions().count;
    [self footer:@"R  Fly again     Esc  Missions"
           action:success ? (more ? @"↵  NEXT MISSION" : @"↵  MISSIONS") : @"↵  RETRY"];
}

#pragma mark - Input & animation

- (void)queueClickAtFraction:(CGPoint)point {
    @synchronized (self) {
        _queuedClick = [NSValue valueWithPoint:point];
    }
}

- (BriefingCommand)handle:(InputAction)a {
    NSValue *click;
    @synchronized (self) {
        click = _queuedClick;
        _queuedClick = nil;
    }
    if (click && !CGRectIsEmpty(_confirmRect)) {
        CGPoint point = click.pointValue;
        point.x *= self.size.width;
        point.y *= self.size.height;
        if (CGRectContainsPoint(_confirmRect, point)) a |= InputActionConfirm;
    }
    NSUInteger count = CampaignMissions().count;
    switch (_mode) {
        case ModeList:
            if (a & InputActionUp) [self showListSelecting:(_index + count - 1) % count];
            if (a & InputActionDown) [self showListSelecting:(_index + 1) % count];
            if ((a & InputActionConfirm) && _index < ProgressUnlockedCount()) [self showBriefing:_index];
            break;
        case ModeBriefing:
            if (a & InputActionBack) { [self showListSelecting:_index]; break; }
            if (a & InputActionLeft) {
                if (_page > 0) { _page--; [self rebuild]; }
            } else if (a & (InputActionRight | InputActionConfirm)) {
                if (_page + 1 < _pages.count) { _page++; [self rebuild]; }
                else if (a & InputActionConfirm) return BriefingCommandLaunch;
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
    if (!CGSizeEqualToSize(self.size, _laidOut)) [self rebuild];
    if (_mode != ModeBriefing) return;
    CGFloat pulse = 1.0 + 0.25 * sin(time * 5.0);
    _focusRing.xScale = _focusRing.yScale = pulse;
    _focusRing.alpha = 0.6 + 0.4 * sin(time * 5.0);
}

@end
