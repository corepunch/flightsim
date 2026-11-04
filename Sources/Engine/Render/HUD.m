#import "HUD.h"
#import "Exhaust.h"

#define MAX_TARGETS 64

static NSColor *HUDColor(CGFloat a) { return [NSColor colorWithRed:0.55 green:0.95 blue:0.85 alpha:a]; }
static NSColor *EnemyColor(CGFloat a) { return [NSColor colorWithRed:1.0 green:0.42 blue:0.32 alpha:a]; }
static NSColor *FriendColor(CGFloat a) { return [NSColor colorWithRed:0.4 green:0.95 blue:0.5 alpha:a]; }
static NSColor *NeutralColor(CGFloat a) { return [NSColor colorWithRed:0.95 green:0.88 blue:0.45 alpha:a]; }
static NSColor *KindColor(HUDKind k, CGFloat a) {
    switch (k) {
        case HUDKindEnemy: return EnemyColor(a);
        case HUDKindFriend: return FriendColor(a);
        case HUDKindNeutral: return NeutralColor(a);
        case HUDKindNav: return HUDColor(a);
    }
}

static SKLabelNode *Label(CGFloat size, SKLabelHorizontalAlignmentMode align) {
    SKLabelNode *l = [SKLabelNode labelNodeWithFontNamed:@"Menlo"];
    l.fontSize = size;
    l.fontColor = HUDColor(0.9);
    l.horizontalAlignmentMode = align;
    l.verticalAlignmentMode = SKLabelVerticalAlignmentModeCenter;
    return l;
}

// Four corner marks of a square of side `size`, centred on the origin.
static CGPathRef BracketPath(CGFloat size) {
    CGMutablePathRef p = CGPathCreateMutable();
    const CGFloat s = size * 0.5, k = MAX(size * 0.22, 5);
    CGPoint corners[4] = { {-s, -s}, {s, -s}, {s, s}, {-s, s} };
    for (int i = 0; i < 4; i++) {
        CGFloat sx = corners[i].x > 0 ? -1 : 1, sy = corners[i].y > 0 ? -1 : 1;
        CGPathMoveToPoint(p, NULL, corners[i].x + sx * k, corners[i].y);
        CGPathAddLineToPoint(p, NULL, corners[i].x, corners[i].y);
        CGPathAddLineToPoint(p, NULL, corners[i].x, corners[i].y + sy * k);
    }
    return p;
}

static SKShapeNode *Bracket(void) {
    SKShapeNode *n = [SKShapeNode node];
    n.strokeColor = EnemyColor(0.9);
    n.lineWidth = 1.5;
    return n;
}

@implementation HUD {
    SKNode *_root;
    SKShapeNode *_boresight, *_cursor, *_cursorLine, *_ring;
    SKShapeNode *_throttleFrame, *_throttleFill, *_boostFill, *_hullFill, *_shieldFill;
    SKLabelNode *_speedLabel, *_throttleLabel, *_scoreLabel, *_inputLabel, *_deadLabel, *_hullLabel, *_shieldLabel;
    SKNode *_help;
    SKShapeNode *_damage;
    NSMutableArray<SKShapeNode *> *_brackets, *_arrows, *_leads;
    NSMutableArray<SKLabelNode *> *_distLabels;
    NSMutableArray<SKSpriteNode *> *_flares;
    NSMutableArray<SKShapeNode *> *_navMarks;
    SKShapeNode *_aimMark;
    SKLabelNode *_statusLabel, *_torpLabel, *_bannerLabel;
    SKNode *_objectivePanel, *_messagePanel;
    NSMutableArray<SKLabelNode *> *_messages;
    SKSpriteNode *_sunStreak;
    CGSize _laidOut;
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.backgroundColor = [NSColor clearColor];
        _root = [SKNode node];
        [self addChild:_root];
        [self build];
    }
    return self;
}

- (void)build {
    // Lens flare ghosts (drawn first, underneath everything).
    _flares = [NSMutableArray array];
    SKTexture *starburst = [SKTexture textureWithImage:[Exhaust particleTexture:@"flare_01"]];
    SKTexture *ring = [SKTexture textureWithImage:[Exhaust particleTexture:@"circle_05"]];
    SKTexture *glow = [SKTexture textureWithImage:[Exhaust softDotImage]];
    // 0-1: the flare at the sun itself, a hot white core plus the starburst,
    // both at full strength so the flare is as bright as the disc it sits on.
    // 2+: ghosts along the sun-to-centre line (clean soft discs and rings).
    NSArray *sizes = @[@60, @260, @40, @90, @22, @130, @34];
    NSArray *colors = @[[NSColor whiteColor],
                        [NSColor colorWithRed:1 green:0.97 blue:0.9 alpha:1],
                        [NSColor colorWithRed:0.5 green:0.7 blue:1 alpha:1],
                        [NSColor colorWithRed:0.9 green:0.5 blue:1 alpha:1],
                        [NSColor colorWithRed:0.6 green:1 blue:0.8 alpha:1],
                        [NSColor colorWithRed:1 green:0.6 blue:0.4 alpha:1],
                        [NSColor colorWithRed:0.6 green:0.8 blue:1 alpha:1]];
    for (NSUInteger i = 0; i < sizes.count; i++) {
        CGFloat r = [sizes[i] doubleValue];
        SKTexture *tex = i == 0 ? glow : i == 1 ? starburst : (i % 2 ? ring : glow);
        SKSpriteNode *f = [SKSpriteNode spriteNodeWithTexture:tex size:CGSizeMake(r * 2, r * 2)];
        f.color = colors[i];
        f.colorBlendFactor = 1;
        f.blendMode = SKBlendModeAdd;
        f.alpha = 0;
        [_root addChild:f];
        [_flares addObject:f];
    }

    // Anamorphic streak through the sun, the way a widescreen lens smears it.
    _sunStreak = [SKSpriteNode spriteNodeWithTexture:[SKTexture textureWithImage:[Exhaust streakImage]]
                                                size:CGSizeMake(1400, 24)];
    _sunStreak.color = [NSColor colorWithRed:0.6 green:0.75 blue:1 alpha:1];
    _sunStreak.colorBlendFactor = 1;
    _sunStreak.blendMode = SKBlendModeAdd;
    _sunStreak.alpha = 0;
    [_root addChild:_sunStreak];

    _damage = [SKShapeNode shapeNodeWithRect:CGRectMake(0, 0, 10, 10)];
    _damage.fillColor = [NSColor colorWithRed:1 green:0.15 blue:0.1 alpha:1];
    _damage.strokeColor = [NSColor clearColor];
    _damage.alpha = 0;
    _damage.blendMode = SKBlendModeAdd;
    [_root addChild:_damage];

    _boresight = [SKShapeNode shapeNodeWithCircleOfRadius:9];
    _boresight.strokeColor = HUDColor(0.9);
    _boresight.lineWidth = 1.5;
    SKShapeNode *dot = [SKShapeNode shapeNodeWithCircleOfRadius:1.5];
    dot.fillColor = HUDColor(1);
    dot.strokeColor = [NSColor clearColor];
    [_boresight addChild:dot];
    for (int i = 0; i < 4; i++) {
        CGMutablePathRef p = CGPathCreateMutable();
        CGFloat a = i * M_PI_2;
        CGPathMoveToPoint(p, NULL, cos(a) * 13, sin(a) * 13);
        CGPathAddLineToPoint(p, NULL, cos(a) * 21, sin(a) * 21);
        SKShapeNode *tick = [SKShapeNode shapeNodeWithPath:p];
        CGPathRelease(p);
        tick.strokeColor = HUDColor(0.9);
        tick.lineWidth = 1.5;
        [_boresight addChild:tick];
    }
    [_root addChild:_boresight];

    _ring = [SKShapeNode shapeNodeWithCircleOfRadius:100];
    _ring.strokeColor = HUDColor(0.12);
    _ring.lineWidth = 1;
    [_root addChild:_ring];
    _cursorLine = [SKShapeNode node];
    _cursorLine.strokeColor = HUDColor(0.25);
    _cursorLine.lineWidth = 1;
    [_root addChild:_cursorLine];
    CGMutablePathRef cp = CGPathCreateMutable();
    CGPathMoveToPoint(cp, NULL, 0, 7); CGPathAddLineToPoint(cp, NULL, 7, 0);
    CGPathAddLineToPoint(cp, NULL, 0, -7); CGPathAddLineToPoint(cp, NULL, -7, 0);
    CGPathCloseSubpath(cp);
    _cursor = [SKShapeNode shapeNodeWithPath:cp];
    CGPathRelease(cp);
    _cursor.strokeColor = HUDColor(0.85);
    _cursor.lineWidth = 1.5;
    [_root addChild:_cursor];

    // Throttle gauge: tall bar on the left with boost segment above it.
    _throttleFrame = [SKShapeNode shapeNodeWithRect:CGRectMake(0, 0, 18, 220) cornerRadius:3];
    _throttleFrame.strokeColor = HUDColor(0.6);
    _throttleFrame.lineWidth = 1;
    [_root addChild:_throttleFrame];
    _throttleFill = [SKShapeNode shapeNodeWithRect:CGRectMake(0, 0, 12, 1)];
    _throttleFill.fillColor = HUDColor(0.75);
    _throttleFill.strokeColor = [NSColor clearColor];
    [_throttleFrame addChild:_throttleFill];
    _boostFill = [SKShapeNode shapeNodeWithRect:CGRectMake(0, 0, 4, 1)];
    _boostFill.fillColor = [NSColor colorWithRed:1 green:0.75 blue:0.3 alpha:0.9];
    _boostFill.strokeColor = [NSColor clearColor];
    [_throttleFrame addChild:_boostFill];
    _throttleLabel = Label(13, SKLabelHorizontalAlignmentModeLeft);
    [_root addChild:_throttleLabel];
    _speedLabel = Label(22, SKLabelHorizontalAlignmentModeLeft);
    [_root addChild:_speedLabel];

    _hullFill = [SKShapeNode shapeNodeWithRect:CGRectMake(0, 0, 1, 6)];
    _hullFill.fillColor = HUDColor(0.8);
    _hullFill.strokeColor = [NSColor clearColor];
    [_root addChild:_hullFill];
    _shieldFill = [SKShapeNode shapeNodeWithRect:CGRectMake(0, 0, 1, 6)];
    _shieldFill.fillColor = [NSColor colorWithRed:0.4 green:0.7 blue:1 alpha:0.85];
    _shieldFill.strokeColor = [NSColor clearColor];
    [_root addChild:_shieldFill];
    _hullLabel = Label(12, SKLabelHorizontalAlignmentModeRight);
    _hullLabel.text = @"HULL";
    [_root addChild:_hullLabel];
    _shieldLabel = Label(12, SKLabelHorizontalAlignmentModeRight);
    _shieldLabel.text = @"SHIELD";
    [_root addChild:_shieldLabel];

    _scoreLabel = Label(16, SKLabelHorizontalAlignmentModeRight);
    [_root addChild:_scoreLabel];
    _inputLabel = Label(12, SKLabelHorizontalAlignmentModeLeft);
    _inputLabel.fontColor = HUDColor(0.55);
    [_root addChild:_inputLabel];
    _deadLabel = Label(30, SKLabelHorizontalAlignmentModeCenter);
    _deadLabel.text = @"SHIP DESTROYED - respawning";
    _deadLabel.fontColor = EnemyColor(0.95);
    _deadLabel.hidden = YES;
    [_root addChild:_deadLabel];

    _help = [SKNode node];
    NSArray *lines = @[@"CLICK  capture mouse (virtual stick)   ESC release   right-click recentre",
                       @"MOUSE  pitch / yaw     Q/E roll     A/D yaw     arrows pitch/yaw",
                       @"W/S throttle   Z full   X cut   SHIFT/TAB boost   SPACE/LMB fire",
                       @"C camera   J cycle stick throttle axis   K invert throttle   I invert mouse",
                       @"Joystick: X roll  Y pitch  throttle lever  B1 fire  B2/B4 boost  B3 camera  B5 torpedo  B6 target  hat look",
                       @"T  next target   G  torpedo   ESC (mouse free) / M  abort to missions",
                       @"R restart   H toggle this help"];
    for (NSUInteger i = 0; i < lines.count; i++) {
        SKLabelNode *l = Label(12, SKLabelHorizontalAlignmentModeLeft);
        l.text = lines[i];
        l.fontColor = HUDColor(0.7);
        l.position = CGPointMake(0, -(CGFloat)i * 17);
        [_help addChild:l];
    }
    [_root addChild:_help];

    _navMarks = [NSMutableArray array];
    _aimMark = [SKShapeNode node];
    CGMutablePathRef am = CGPathCreateMutable();
    CGPathMoveToPoint(am, NULL, 0, 9); CGPathAddLineToPoint(am, NULL, 9, 0); CGPathAddLineToPoint(am, NULL, 0, -9); CGPathAddLineToPoint(am, NULL, -9, 0);
    CGPathCloseSubpath(am);
    _aimMark.path = am;
    CGPathRelease(am);
    _aimMark.strokeColor = [NSColor colorWithRed:1 green:0.75 blue:0.3 alpha:1];
    _aimMark.lineWidth = 2;
    [_root addChild:_aimMark];
    _statusLabel = Label(13, SKLabelHorizontalAlignmentModeCenter);
    [_root addChild:_statusLabel];
    _torpLabel = Label(13, SKLabelHorizontalAlignmentModeLeft);
    [_root addChild:_torpLabel];
    _bannerLabel = Label(30, SKLabelHorizontalAlignmentModeCenter);
    _bannerLabel.fontName = @"Menlo-Bold";
    _bannerLabel.alpha = 0;
    [_root addChild:_bannerLabel];
    _objectivePanel = [SKNode node];
    [_root addChild:_objectivePanel];
    _messagePanel = [SKNode node];
    [_root addChild:_messagePanel];
    _messages = [NSMutableArray array];

    _brackets = [NSMutableArray array];
    _arrows = [NSMutableArray array];
    _leads = [NSMutableArray array];
    _distLabels = [NSMutableArray array];
    for (int i = 0; i < MAX_TARGETS; i++) {
        SKShapeNode *b = Bracket();
        b.hidden = YES;
        [_root addChild:b];
        [_brackets addObject:b];

        CGMutablePathRef ap = CGPathCreateMutable();
        CGPathMoveToPoint(ap, NULL, 14, 0);
        CGPathAddLineToPoint(ap, NULL, -6, 8);
        CGPathAddLineToPoint(ap, NULL, -2, 0);
        CGPathAddLineToPoint(ap, NULL, -6, -8);
        CGPathCloseSubpath(ap);
        SKShapeNode *a = [SKShapeNode shapeNodeWithPath:ap];
        CGPathRelease(ap);
        a.fillColor = EnemyColor(0.8);
        a.strokeColor = [NSColor clearColor];
        a.hidden = YES;
        [_root addChild:a];
        [_arrows addObject:a];

        SKShapeNode *lead = [SKShapeNode shapeNodeWithCircleOfRadius:5];
        lead.strokeColor = EnemyColor(0.95);
        lead.lineWidth = 1.5;
        SKShapeNode *cross = [SKShapeNode node];
        CGMutablePathRef xp = CGPathCreateMutable();
        CGPathMoveToPoint(xp, NULL, -9, 0); CGPathAddLineToPoint(xp, NULL, -5, 0);
        CGPathMoveToPoint(xp, NULL, 9, 0); CGPathAddLineToPoint(xp, NULL, 5, 0);
        CGPathMoveToPoint(xp, NULL, 0, -9); CGPathAddLineToPoint(xp, NULL, 0, -5);
        CGPathMoveToPoint(xp, NULL, 0, 9); CGPathAddLineToPoint(xp, NULL, 0, 5);
        cross.path = xp;
        CGPathRelease(xp);
        cross.strokeColor = EnemyColor(0.95);
        cross.lineWidth = 1.5;
        [lead addChild:cross];
        lead.hidden = YES;
        [_root addChild:lead];
        [_leads addObject:lead];

        SKLabelNode *d = Label(11, SKLabelHorizontalAlignmentModeLeft);
        d.fontColor = EnemyColor(0.85);
        d.hidden = YES;
        [_root addChild:d];
        [_distLabels addObject:d];
    }
}

- (void)layoutIfNeeded {
    CGSize s = self.size;
    if (CGSizeEqualToSize(s, _laidOut)) return;
    _laidOut = s;
    _throttleFrame.position = CGPointMake(40, 60);
    _throttleLabel.position = CGPointMake(66, 70);
    _speedLabel.position = CGPointMake(66, 100);
    _hullLabel.position = CGPointMake(s.width - 252, 70);
    _shieldLabel.position = CGPointMake(s.width - 252, 88);
    _hullFill.position = CGPointMake(s.width - 240, 67);
    _shieldFill.position = CGPointMake(s.width - 240, 85);
    _scoreLabel.position = CGPointMake(s.width - 40, s.height - 40);
    _inputLabel.position = CGPointMake(40, 30);
    _deadLabel.position = CGPointMake(s.width / 2, s.height / 2 + 80);
    _help.position = CGPointMake(40, s.height - 40);
    _objectivePanel.position = CGPointMake(40, s.height - 40);
    _messagePanel.position = CGPointMake(s.width / 2, s.height - 110);
    _bannerLabel.position = CGPointMake(s.width / 2, s.height * 0.68);
    _torpLabel.position = CGPointMake(66, 130);
    CGPathRef dp = CGPathCreateWithRect(CGRectMake(0, 0, s.width, s.height), NULL);
    _damage.path = dp;
    CGPathRelease(dp);
    _ring.position = _cursor.position = CGPointMake(s.width / 2, s.height / 2);
}

- (void)setInputText:(NSString *)text { _inputLabel.text = text; }
- (void)toggleHelp {
    _help.hidden = !_help.hidden;
    _objectivePanel.hidden = !_help.hidden;
}
- (void)setHelpVisible:(BOOL)visible {
    _help.hidden = !visible;
    _objectivePanel.hidden = visible;
}

- (void)setObjectives:(NSArray<NSString *> *)lines states:(NSArray<NSNumber *> *)states {
    [_objectivePanel removeAllChildren];
    SKLabelNode *head = Label(13, SKLabelHorizontalAlignmentModeLeft);
    head.text = @"OBJECTIVES";
    head.fontColor = HUDColor(0.6);
    [_objectivePanel addChild:head];
    for (NSUInteger i = 0; i < lines.count; i++) {
        int st = states[i].intValue;
        SKLabelNode *l = Label(14, SKLabelHorizontalAlignmentModeLeft);
        NSString *mark = st == 1 ? @"[+]" : (st == 2 ? @"[x]" : (st == 3 ? @"[o]" : @"[ ]"));
        l.text = [NSString stringWithFormat:@"%@ %@", mark, lines[i]];
        l.fontColor = st == 1 ? FriendColor(0.85) : (st == 2 ? EnemyColor(0.9) : (st == 3 ? HUDColor(0.55) : HUDColor(0.95)));
        l.position = CGPointMake(0, -20.0 * (i + 1));
        [_objectivePanel addChild:l];
    }
}

- (void)showMessage:(NSString *)text from:(NSString *)from {
    SKLabelNode *l = Label(15, SKLabelHorizontalAlignmentModeCenter);
    l.text = from.length ? [NSString stringWithFormat:@"%@: %@", [from uppercaseString], text] : text;
    l.fontColor = [NSColor colorWithRed:0.85 green:0.95 blue:1 alpha:1];
    [_messagePanel addChild:l];
    [_messages insertObject:l atIndex:0];
    while (_messages.count > 3) { [_messages.lastObject removeFromParent]; [_messages removeLastObject]; }
    for (NSUInteger i = 0; i < _messages.count; i++) _messages[i].position = CGPointMake(0, -22.0 * i);
    [l runAction:[SKAction sequence:@[[SKAction waitForDuration:7], [SKAction fadeOutWithDuration:1.5]]]];
}

- (void)clearMessages {
    [_messagePanel removeAllChildren];
    [_messages removeAllObjects];
}

- (void)showBanner:(NSString *)text color:(NSColor *)color {
    _bannerLabel.text = text;
    _bannerLabel.fontColor = color ?: HUDColor(1);
    [_bannerLabel removeAllActions];
    _bannerLabel.alpha = 1;
    [_bannerLabel runAction:[SKAction sequence:@[[SKAction waitForDuration:2.5], [SKAction fadeOutWithDuration:1.0]]]];
}

static void SetBar(SKShapeNode *n, CGFloat w, CGFloat h) {
    CGPathRef p = CGPathCreateWithRect(CGRectMake(0, 0, MAX(w, 0.01), MAX(h, 0.01)), NULL);
    n.path = p;
    CGPathRelease(p);
}

- (void)updateFrame:(HUDFrame)f targets:(const HUDTarget *)targets count:(NSUInteger)count {
    [self layoutIfNeeded];
    CGSize s = self.size;
    CGPoint center = CGPointMake(s.width / 2, s.height / 2);

    _boresight.hidden = !f.boresightVisible || f.playerDead;
    _boresight.position = f.boresight;

    CGFloat ringR = MIN(s.width, s.height) * 0.22;
    _ring.hidden = _cursor.hidden = _cursorLine.hidden = !f.mouseCaptured || f.playerDead;
    _ring.xScale = _ring.yScale = ringR / 100.0;
    CGPoint cur = CGPointMake(center.x + f.mouseStick.x * ringR, center.y + f.mouseStick.y * ringR);
    _cursor.position = cur;
    CGMutablePathRef lp = CGPathCreateMutable();
    CGPathMoveToPoint(lp, NULL, center.x, center.y);
    CGPathAddLineToPoint(lp, NULL, cur.x, cur.y);
    _cursorLine.path = lp;
    CGPathRelease(lp);

    SetBar(_throttleFill, 12, 214 * MIN(f.throttle, 1.0f));
    _throttleFill.position = CGPointMake(3, 3);
    _throttleFill.fillColor = f.boosting ? [NSColor colorWithRed:1 green:0.75 blue:0.3 alpha:0.9] : HUDColor(0.75);
    SetBar(_boostFill, 3, 214 * f.boostEnergy);
    _boostFill.position = CGPointMake(-7, 3);
    _throttleLabel.text = [NSString stringWithFormat:@"THR %3d%%%@", (int)lroundf(f.throttle * 100), f.boosting ? @" BOOST" : @""];
    _speedLabel.text = [NSString stringWithFormat:@"%4d m/s", (int)lroundf(f.speed)];
    SetBar(_hullFill, 200 * f.hull, 6);
    SetBar(_shieldFill, 200 * f.shield, 6);
    _hullFill.fillColor = f.hull < 0.3 ? EnemyColor(0.9) : HUDColor(0.8);
    _scoreLabel.text = [NSString stringWithFormat:@"KILLS %d   DEATHS %d", f.kills, f.deaths];
    for (SKNode *n in @[_throttleFrame, _throttleLabel, _speedLabel, _hullFill, _shieldFill, _hullLabel, _shieldLabel, _scoreLabel, _torpLabel])
        n.hidden = f.cockpit;
    _scoreLabel.hidden = YES;
    _torpLabel.text = [NSString stringWithFormat:@"TORP %d", f.torpedoes];
    _aimMark.hidden = !f.aimVisible || f.playerDead;
    _aimMark.position = f.aim;
    _aimMark.zRotation = 0.0;
    _statusLabel.text = f.status ?: @"";
    _statusLabel.position = CGPointMake(f.boresight.x, f.boresight.y - 40);
    _deadLabel.hidden = !f.playerDead;
    _damage.alpha = f.damageFlash * 0.35;

    // Lens flare: ghosts along the line from the sun through screen centre.
    CGFloat vis = f.sunVisibility;
    CGFloat ts[] = { 0.0, 0.0, 0.45, 0.8, 1.15, 1.5, 1.9 };
    CGFloat alphas[] = { 1.0, 1.0, 0.12, 0.10, 0.16, 0.08, 0.10 };
    _sunStreak.position = f.sun;
    _sunStreak.alpha = 0.45 * vis;
    for (NSUInteger i = 0; i < _flares.count; i++) {
        CGPoint p = CGPointMake(f.sun.x + (center.x - f.sun.x) * ts[i], f.sun.y + (center.y - f.sun.y) * ts[i]);
        _flares[i].position = p;
        _flares[i].alpha = alphas[i] * vis;
    }

    for (NSUInteger i = 0; i < MAX_TARGETS; i++) {
        SKShapeNode *b = _brackets[i], *a = _arrows[i], *l = _leads[i];
        SKLabelNode *d = _distLabels[i];
        if (i >= count || f.playerDead) { b.hidden = a.hidden = l.hidden = d.hidden = YES; continue; }
        HUDTarget t = targets[i];
        NSColor *c = KindColor(t.kind, 0.9);
        BOOL nav = t.kind == HUDKindNav;
        b.hidden = !t.onScreen;
        d.hidden = !t.onScreen;
        // Off-screen arrows only for what matters: hostile fighters, navs, the selection.
        a.hidden = t.onScreen || !(t.selected || nav || (t.kind == HUDKindEnemy && !t.capital));
        l.hidden = !(t.onScreen && t.hasLead && (t.selected || (t.kind == HUDKindEnemy && !t.capital)));
        b.strokeColor = c;
        b.lineWidth = t.selected ? 2.5 : 1.5;
        a.fillColor = KindColor(t.kind, t.selected ? 1.0 : 0.7);
        d.fontColor = c;
        if (t.onScreen) {
            b.position = t.point;
            CGPathRef bp;
            if (nav) {
                CGMutablePathRef np = CGPathCreateMutable();
                CGPathMoveToPoint(np, NULL, 0, 12); CGPathAddLineToPoint(np, NULL, 12, 0);
                CGPathAddLineToPoint(np, NULL, 0, -12); CGPathAddLineToPoint(np, NULL, -12, 0);
                CGPathCloseSubpath(np);
                bp = np;
            } else {
                bp = BracketPath(roundf(t.size));
            }
            b.path = bp;
            CGPathRelease(bp);
            NSString *dist = t.distance >= 1000 ? [NSString stringWithFormat:@"%.1fkm", t.distance / 1000.0]
                                                : [NSString stringWithFormat:@"%dm", (int)t.distance];
            BOOL named = t.label && (t.selected || t.capital || nav);
            d.text = named ? [NSString stringWithFormat:@"%@ %@", t.label, dist] : dist;
            CGFloat half = nav ? 12 : t.size * 0.5;
            d.position = CGPointMake(t.point.x + half + 4, t.point.y + half - 4);
            l.position = t.lead;
        } else {
            a.position = t.point;
            a.zRotation = t.angle;
        }
    }
}

@end
