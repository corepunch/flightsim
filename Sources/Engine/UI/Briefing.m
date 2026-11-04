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

typedef NS_ENUM(NSInteger, Mode) { ModeList, ModeDialogue, ModeBriefing, ModeDebrief };

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
    NSArray<NSDictionary *> *_dialogue;
    NSUInteger _line;
    SKShapeNode *_confirmButton;
    SKLabelNode *_confirmLabel;
    NSValue *_queuedClick;
    NSMutableDictionary<NSString *, SKTexture *> *_art;
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
    SKNode *_mapParent;      // _root, or the room's presentation
    CGFloat _mapText;        // label scale on the map
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
    _confirmButton = nil;
    _laidOut = self.size;
    CGSize s = self.size;
    _mapParent = _root;
    _mapText = 1;
    if (self.inRoom) {
        [_presentation removeAllChildren];
        // The room shows through; only the text side of the tactical shot is dimmed.
        if (_mode == ModeBriefing) [_root addChild:[self leftShade]];
    } else {
        // Dim the 3D scene behind the UI.
        SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIBlack, 0.72) size:s];
        shade.anchorPoint = CGPointZero;
        [_root addChild:shade];
    }
    switch (_mode) {
        case ModeList: [self buildList]; break;
        case ModeBriefing: [self buildBriefing]; break;
        case ModeDialogue: [self buildDialogue]; break;
        case ModeDebrief: [self buildDebrief]; break;
    }
}

- (BOOL)inRoom { return _presentation && (_mode == ModeDialogue || _mode == ModeBriefing); }
- (RoomShot)roomShot { return _mode == ModeBriefing ? RoomShotTactical : RoomShotWide; }
- (float)roomLean {
    if (_mode != ModeDialogue || !_dialogue.count) return 0;
    NSArray *cast = _dialogueScene[@"cast"];
    NSUInteger i = [cast indexOfObject:_dialogue[_line][@"portrait"] ?: @""];
    return i == NSNotFound ? 0 : (i == 0 ? -1 : 1);
}

// Black fading out to the right, under the tactical briefing's text column.
- (SKSpriteNode *)leftShade {
    CGSize s = self.size;
    CGFloat w = MAX(1, s.width * 0.5);
    NSImage *img = [NSImage imageWithSize:NSMakeSize(256, 4) flipped:NO drawingHandler:^BOOL(NSRect r) {
        NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:
                         UIColorWithOpacity(UIBlack, 0.82), 0.0, UIColorWithOpacity(UIBlack, 0.7), 0.7,
                         UIColorWithOpacity(UIBlack, 0.0), 1.0, nil];
        [g drawInRect:r angle:0];
        return YES;
    }];
    SKSpriteNode *n = [SKSpriteNode spriteNodeWithTexture:[SKTexture textureWithImage:img] size:CGSizeMake(w, s.height)];
    n.anchorPoint = CGPointZero;
    SKSpriteNode *bottom = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIBlack, 0.55) size:CGSizeMake(s.width, 84)];
    bottom.anchorPoint = CGPointZero;
    [n addChild:bottom];
    return n;
}

// The room's screen: grid ground and a header strip, then the map in `rect`
// (presentation points). Returns the area below the header.
- (CGRect)preparePresentation:(NSString *)title {
    SKScene *p = _presentation;
    CGSize s = p.size;
    for (int i = 1; i < 28; i++) {
        SKSpriteNode *v = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.035) size:CGSizeMake(1, s.height)];
        v.anchorPoint = CGPointZero;
        v.position = CGPointMake(s.width * i / 28, 0);
        [p addChild:v];
    }
    for (int i = 1; i < 12; i++) {
        SKSpriteNode *h = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.035) size:CGSizeMake(s.width, 1)];
        h.anchorPoint = CGPointZero;
        h.position = CGPointMake(0, s.height * i / 12);
        [p addChild:h];
    }
    SKSpriteNode *bar = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIPanel, 0.95) size:CGSizeMake(s.width, 40)];
    bar.anchorPoint = CGPointZero;
    bar.position = CGPointMake(0, s.height - 40);
    [p addChild:bar];
    SKSpriteNode *rule = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.6) size:CGSizeMake(s.width, 2)];
    rule.anchorPoint = CGPointZero;
    rule.position = CGPointMake(0, s.height - 41);
    [p addChild:rule];
    SKLabelNode *l = Text(18, UIColorWithOpacity(UIInk, 0.95), SKLabelHorizontalAlignmentModeLeft);
    l.fontName = @"Menlo-Bold";
    l.text = @"CNS BASTION  /  TACTICAL";
    l.position = CGPointMake(24, s.height - 10);
    [p addChild:l];
    SKLabelNode *r = Text(18, UIColorWithOpacity(UIAmber, 0.95), SKLabelHorizontalAlignmentModeRight);
    r.fontName = @"Menlo-Bold";
    r.text = title;
    r.position = CGPointMake(s.width - 24, s.height - 10);
    [p addChild:r];
    _mapParent = p;
    _mapText = 1.45;
    return CGRectMake(0, 0, s.width, s.height - 42);
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
    SKLabelNode *hint = Para(12, UIColorWithOpacity(UIInk, 0.65),
                             MAX(1, self.size.width - 2 * inset - (action ? 200 : 0)));
    hint.text = text;
    hint.position = CGPointMake(inset, 40);
    [_root addChild:hint];
    if (!action) return;

    CGRect rect = CGRectMake(self.size.width - inset - 180, 20, 180, 40);
    _confirmButton = UISkewedShape(rect, UIColorWithOpacity(UIInk, 0.85),
                                 UIColorWithOpacity(UIPanel, 0.96));
    [_root addChild:_confirmButton];
    _confirmLabel = Text(13, UIColorWithOpacity(UIInk, 1), SKLabelHorizontalAlignmentModeCenter);
    _confirmLabel.fontName = @"Menlo-Bold";
    _confirmLabel.verticalAlignmentMode = SKLabelVerticalAlignmentModeCenter;
    _confirmLabel.position = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    _confirmLabel.text = action;
    [_root addChild:_confirmLabel];
}

#pragma mark - Briefing

- (void)showBriefing:(NSUInteger)index {
    _index = MIN(index, CampaignMissions().count - 1);
    _dialogueScene = CampaignMission(_index)[@"briefing"][@"dialogue"];
    _dialogue = _dialogueScene[@"lines"];
    _line = 0;
    _step = 0;
    if (_dialogue.count) {
        _mode = ModeDialogue;
        [self rebuild];
    } else {
        [self enterTacticalBriefing];
    }
}

- (void)enterTacticalBriefing {
    _mode = ModeBriefing;
    _typeStart = _now;
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

- (void)buildDialogue {
    CGSize size = self.size;
    NSDictionary *mission = CampaignMission(_index);
    NSDictionary *line = _dialogue[_line];
    CGFloat inset = MIN(44, size.width * 0.045);
    CGFloat panelWidth = MAX(1, size.width - 2 * inset);
    CGFloat textSize = MAX(16, MIN(24, size.width / 60));
    SKLabelNode *speech = Para(textSize, UIColorWithOpacity(UIWhite, 1), MAX(1, panelWidth - 40));
    speech.fontName = @"HelveticaNeue";
    speech.text = line[@"text"];
    CGFloat panelBottom = 72;
    CGFloat panelHeight = MAX(90, speech.frame.size.height + 58);
    CGFloat panelTop = panelBottom + panelHeight;

    NSString *missionTag = [NSString stringWithFormat:@"MISSION %02lu  /  %@", (unsigned long)_index + 1, [mission[@"title"] uppercaseString]];
    SKSpriteNode *room = self.inRoom ? nil : [self artNamed:_dialogueScene[@"room"] ?: @"Bastion"];
    if (self.inRoom) {
        CGRect area = [self preparePresentation:missionTag];
        _mapRect = CGRectInset(area, 24, 18);
    } else if (room) {
        [room setScale:MAX(size.width / room.size.width, size.height / room.size.height)];
        room.position = CGPointMake(size.width / 2, size.height / 2);
        [_root addChild:room];
    }

    CGFloat mapWidth = size.width * 0.40;
    if (!self.inRoom) _mapRect = CGRectMake((size.width - mapWidth) / 2, size.height * 0.42,
                                            mapWidth, size.height * 0.40);
    if (!room && !self.inRoom) [_root addChild:Frame(_mapRect, UIColorWithOpacity(UIInk, 0.55), UIColorWithOpacity(UIMap, 0.94))];
    [self buildMap:mission];
    for (MapItem *item in _items.allValues) item.node.alpha = [item.identifier isEqualToString:_dialogueScene[@"focus"]] ? 1 : 0.15;
    _focusRing.hidden = YES;

    NSArray<NSString *> *portraits = _dialogueScene[@"cast"];
    for (NSUInteger i = 0; i < MIN(portraits.count, 2); i++) {
        NSString *name = portraits[i];
        SKSpriteNode *portrait = [self artNamed:name];
        if (!portrait) continue;
        CGFloat maxWidth = size.width * 0.50;
        CGFloat maxHeight = MAX(1, size.height - panelTop - 68);
        [portrait setScale:MIN(maxWidth / portrait.size.width, maxHeight / portrait.size.height)];
        portrait.anchorPoint = CGPointMake(0.5, 0);
        portrait.position = CGPointMake(size.width * (i == 0 ? 0.175 : 0.825), panelTop - 10);
        portrait.color = UIColorWithOpacity(UIBackground, 1);
        portrait.colorBlendFactor = [line[@"portrait"] isEqualToString:name] ? 0 : 0.20;
        [_root addChild:portrait];
    }

    CGFloat top = size.height - 22;
    NSString *number = [NSString stringWithFormat:@"MISSION %02lu", (unsigned long)_index + 1];
    [_root addChild:UISkewedShape(CGRectMake(inset, top - 31, 128, 30),
                                  UIColorWithOpacity(UIAmber, 0.85), UIColorWithOpacity(UIPanel, 0.94))];
    SKLabelNode *badge = Text(14, UIColorWithOpacity(UIAmber, 1), SKLabelHorizontalAlignmentModeCenter);
    badge.text = number;
    badge.position = CGPointMake(inset + 64, top - 8);
    [_root addChild:badge];
    SKLabelNode *title = Text(MIN(30, size.width / 24), UIColorWithOpacity(UIWhite, 1), SKLabelHorizontalAlignmentModeLeft);
    title.fontName = @"HelveticaNeue-Bold";
    title.text = [mission[@"title"] uppercaseString];
    title.position = CGPointMake(inset + 148, top);
    [_root addChild:title];

    [_root addChild:Frame(CGRectMake(inset, panelBottom, panelWidth, panelHeight),
                           UIColorWithOpacity(UIInk, 0.5), UIColorWithOpacity(UIPanel, 0.96))];
    SKLabelNode *speaker = Text(14, UIColorWithOpacity(UIAmber, 1), SKLabelHorizontalAlignmentModeLeft);
    speaker.text = [line[@"speaker"] uppercaseString];
    speaker.position = CGPointMake(inset + 20, panelTop - 14);
    [_root addChild:speaker];
    speech.position = CGPointMake(inset + 20, panelTop - 40);
    [_root addChild:speech];
    [self footer:@"← / →  Dialogue     Esc  Missions"
           action:_line + 1 == _dialogue.count ? @"↵  FLIGHT PLAN" : @"↵  CONTINUE"];
}

- (void)buildBriefing {
    CGSize s = self.size;
    NSDictionary *m = CampaignMission(_index);
    NSDictionary *b = m[@"briefing"];
    CGFloat top = s.height - 40;

    SKLabelNode *t = Text(26, UIColorWithOpacity(UIInk, 1), SKLabelHorizontalAlignmentModeLeft);
    t.fontName = @"Menlo-Bold";
    t.text = [NSString stringWithFormat:@"MISSION %02lu  -  %@", (unsigned long)_index + 1, [m[@"title"] uppercaseString]];
    t.position = CGPointMake(50, top);
    [_root addChild:t];
    SKLabelNode *loc = Text(14, UIColorWithOpacity(UIAmber, 0.9), SKLabelHorizontalAlignmentModeLeft);
    loc.text = [NSString stringWithFormat:@"%@   /   SD %@", b[@"location"], b[@"stardate"]];
    loc.position = CGPointMake(50, top - 38);
    [_root addChild:loc];

    // Left: who is talking, the story, then objectives / intel / loadout.
    CGFloat lw = MAX(1, s.width * 0.42 - 60);
    SKLabelNode *who = Para(15, UIColorWithOpacity(UIInk, 0.95), lw);
    who.fontName = @"Menlo-Bold";
    who.text = [b[@"speaker"] uppercaseString];
    who.position = CGPointMake(50, top - 78);
    [_root addChild:who];
    _storyText = [b[@"text"] componentsJoinedByString:@"\n\n"];
    _story = Para(15, UIColorWithOpacity(UIInk, 0.85), lw);
    _story.position = CGPointMake(50, who.position.y - who.frame.size.height - 12);
    _story.text = @"";
    [_root addChild:_story];

    // Measure the full text so the sections below have a fixed place.
    SKLabelNode *probe = Para(15, UIColorWithOpacity(UIInk, 0), lw);
    probe.text = _storyText;
    CGFloat y = _story.position.y - probe.frame.size.height - 26;
    NSMutableString *o = [NSMutableString stringWithString:@"OBJECTIVES\n"];
    for (NSDictionary *d in m[@"objectives"])
        [o appendFormat:@"  %@ %@%@\n", [d[@"optional"] boolValue] ? @"o" : @">", d[@"text"], [d[@"optional"] boolValue] ? @" (optional)" : @""];
    [o appendString:@"\nINTEL\n"];
    for (NSString *line in b[@"intel"]) [o appendFormat:@"  - %@\n", line];
    [o appendFormat:@"\nLOADOUT   twin lasers, %d torpedo%@", [m[@"loadout"][@"torpedoes"] intValue], [m[@"loadout"][@"torpedoes"] intValue] == 1 ? @"" : @"es"];
    SKLabelNode *details = Para(14, UIColorWithOpacity(UIInk, 0.7), lw);
    details.text = o;
    details.position = CGPointMake(50, y);
    [_root addChild:details];

    if (self.inRoom) {
        // On the room's screen: the map, the step and its caption beside it.
        CGRect area = [self preparePresentation:[NSString stringWithFormat:@"MISSION %02lu", (unsigned long)_index + 1]];
        CGFloat cw = 360;
        _mapRect = CGRectMake(20, 18, area.size.width - cw - 60, area.size.height - 36);
        [_presentation addChild:Frame(_mapRect, UIColorWithOpacity(UIInk, 0.35), UIColorWithOpacity(UIMap, 0.5))];
        [self buildMap:m];
        CGFloat cx = CGRectGetMaxX(_mapRect) + 28;
        _stepLabel = Text(17, UIColorWithOpacity(UIAmber, 0.95), SKLabelHorizontalAlignmentModeLeft);
        _stepLabel.fontName = @"Menlo-Bold";
        _stepLabel.position = CGPointMake(cx, area.size.height - 22);
        [_presentation addChild:_stepLabel];
        _caption = Para(23, UIColorWithOpacity(UIInk, 1), cw);
        _caption.fontName = @"HelveticaNeue";
        _caption.position = CGPointMake(cx, area.size.height - 62);
        [_presentation addChild:_caption];
    } else {
        // Right: the tactical map with the step caption under it.
        CGFloat mx = s.width * 0.42 + 10, mw = s.width - mx - 50;
        CGFloat mh = MAX(1, MIN(mw, s.height - 260));
        _mapRect = CGRectMake(mx, s.height - 90 - mh, mw, mh);
        [_root addChild:Frame(_mapRect, UIColorWithOpacity(UIInk, 0.5), UIColorWithOpacity(UIMap, 0.6))];
        [self buildMap:m];
        _stepLabel = Text(13, UIColorWithOpacity(UIAmber, 0.9), SKLabelHorizontalAlignmentModeLeft);
        _stepLabel.position = CGPointMake(mx, _mapRect.origin.y - 14);
        [_root addChild:_stepLabel];
        _caption = Para(17, UIColorWithOpacity(UIInk, 1), mw);
        _caption.position = CGPointMake(mx, _mapRect.origin.y - 36);
        [_root addChild:_caption];
    }
    _steps = b[@"steps"];
    [self footer:@"← / →  Tactical steps     Esc  Missions" action:@"↵  NEXT"];
    [self applyStep];
}

- (void)buildMap:(NSDictionary *)m {
    _items = [NSMutableDictionary dictionary];
    _mapLayer = [SKNode node];
    [_mapParent ?: _root addChild:_mapLayer];

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
    SKLabelNode *sl = Text(11 * _mapText, UIColorWithOpacity(UIInk, 0.7), SKLabelHorizontalAlignmentModeLeft);
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
            SKLabelNode *l = Text(11 * _mapText, UIColorWithOpacity(UIInk, 0.85), SKLabelHorizontalAlignmentModeLeft);
            l.text = [t[@"label"] uppercaseString];
            l.position = CGPointMake(p.x + 12, p.y + 6);
            [holder addChild:l];
        } else if ([kind isEqualToString:@"field"]) {
            SKLabelNode *l = Text(11 * _mapText, UIColorWithOpacity(UIRed, 0.9), SKLabelHorizontalAlignmentModeCenter);
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

- (void)applyStep {
    _confirmLabel.text = _step + 1 < _steps.count ? @"↵  NEXT" : @"↵  LAUNCH";
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
    if (click && _confirmButton.path) {
        CGPoint p = click.pointValue;
        p.x *= self.size.width;
        p.y *= self.size.height;
        if (CGPathContainsPoint(_confirmButton.path, NULL, p, false)) a |= InputActionConfirm;
    }
    NSUInteger count = CampaignMissions().count;
    switch (_mode) {
        case ModeList:
            if (a & InputActionUp) [self showListSelecting:(_index + count - 1) % count];
            if (a & InputActionDown) [self showListSelecting:(_index + 1) % count];
            if ((a & InputActionConfirm) && _index < ProgressUnlockedCount()) [self showBriefing:_index];
            break;
        case ModeDialogue:
            if (a & InputActionBack) { [self showListSelecting:_index]; break; }
            if ((a & InputActionLeft) && _line > 0) { _line--; [self rebuild]; }
            else if (a & (InputActionRight | InputActionConfirm)) {
                if (_line + 1 == _dialogue.count) [self enterTacticalBriefing];
                else { _line++; [self rebuild]; }
            }
            break;
        case ModeBriefing:
            if (a & InputActionBack) { [self showListSelecting:_index]; break; }
            if (a & InputActionLeft) { _step = _step > 0 ? _step - 1 : 0; [self applyStep]; }
            if ((a & InputActionRight) && _steps.count) { _step = MIN(_step + 1, _steps.count - 1); [self applyStep]; }
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
    if (!CGSizeEqualToSize(self.size, _laidOut)) [self rebuild];
    if (_mode != ModeBriefing) return;
    // Typewriter: 90 characters a second.
    NSUInteger n = MIN(_storyText.length, (NSUInteger)MAX(0.0, (time - _typeStart) * 90.0));
    if (n != _story.text.length) _story.text = [_storyText substringToIndex:n];
    CGFloat pulse = 1.0 + 0.25 * sin(time * 5.0);
    _focusRing.xScale = _focusRing.yScale = pulse;
    _focusRing.alpha = 0.6 + 0.4 * sin(time * 5.0);
}

@end
