#import "HUD.h"
#import "Exhaust.h"
#import "UIStyle.h"

#define MAX_TARGETS 64

static SKColor *HUDColor(CGFloat a) { return UIColorWithOpacity(UIInk, a); }
static SKColor *EnemyColor(CGFloat a) { return UIColorWithOpacity(UIRed, a); }
static SKColor *FriendColor(CGFloat a) { return UIColorWithOpacity(UIFriendly, a); }
static SKColor *NeutralColor(CGFloat a) { return UIColorWithOpacity(UIHUDNeutral, a); }
static SKColor *KindColor(HUDKind k, CGFloat a) {
    switch (k) {
        case HUDKindEnemy: return EnemyColor(a);
        case HUDKindFriend: return FriendColor(a);
        case HUDKindNeutral: return NeutralColor(a);
        case HUDKindNav: return HUDColor(a);
    }
}

static SKLabelNode *Label(CGFloat size, SKLabelHorizontalAlignmentMode align) {
    return UIMonoLabel(size, HUDColor(0.9), align, SKLabelVerticalAlignmentModeCenter);
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
    NSMutableArray<SKShapeNode *> *_navMarks;
    SKShapeNode *_aimMark;
    SKLabelNode *_statusLabel, *_torpLabel, *_bannerLabel;
    SKNode *_objectivePanel, *_messagePanel;
    NSMutableArray<SKLabelNode *> *_messages;
    SKSpriteNode *_sunStreak;
    CGSize _laidOut;
#if TARGET_OS_IOS
    UIEdgeInsets _laidOutInsets;
#endif
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.backgroundColor = [SKColor clearColor];
        _root = [SKNode node];
        [self addChild:_root];
        [self build];
    }
    return self;
}

- (void)build {
    // A single horizontal streak centered on the visible sky sun.
    _sunStreak = [SKSpriteNode spriteNodeWithTexture:[SKTexture textureWithImage:[Exhaust streakImage]]
                                                size:CGSizeMake(1400, 24)];
    _sunStreak.color = [SKColor colorWithRed:0.6 green:0.75 blue:1 alpha:1];
    _sunStreak.colorBlendFactor = 1;
    _sunStreak.blendMode = SKBlendModeAdd;
    _sunStreak.alpha = 0;
    [_root addChild:_sunStreak];

    _damage = [SKShapeNode shapeNodeWithRect:CGRectMake(0, 0, 10, 10)];
    _damage.fillColor = [SKColor colorWithRed:1 green:0.15 blue:0.1 alpha:1];
    _damage.strokeColor = [SKColor clearColor];
    _damage.alpha = 0;
    _damage.blendMode = SKBlendModeAdd;
    [_root addChild:_damage];

    _boresight = [SKShapeNode shapeNodeWithCircleOfRadius:9];
    _boresight.strokeColor = HUDColor(0.9);
    _boresight.lineWidth = 1.5;
    SKShapeNode *dot = [SKShapeNode shapeNodeWithCircleOfRadius:1.5];
    dot.fillColor = HUDColor(1);
    dot.strokeColor = [SKColor clearColor];
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
    _throttleFill.strokeColor = [SKColor clearColor];
    [_throttleFrame addChild:_throttleFill];
    _boostFill = [SKShapeNode shapeNodeWithRect:CGRectMake(0, 0, 4, 1)];
    _boostFill.fillColor = UIColorWithOpacity(UIBoost, 0.9);
    _boostFill.strokeColor = [SKColor clearColor];
    [_throttleFrame addChild:_boostFill];
    _throttleLabel = Label(13, SKLabelHorizontalAlignmentModeLeft);
    [_root addChild:_throttleLabel];
    _speedLabel = Label(22, SKLabelHorizontalAlignmentModeLeft);
    [_root addChild:_speedLabel];

    _hullFill = [SKShapeNode shapeNodeWithRect:CGRectMake(0, 0, 1, 6)];
    _hullFill.fillColor = HUDColor(0.8);
    _hullFill.strokeColor = [SKColor clearColor];
    [_root addChild:_hullFill];
    _shieldFill = [SKShapeNode shapeNodeWithRect:CGRectMake(0, 0, 1, 6)];
    _shieldFill.fillColor = UIColorWithOpacity(UIShield, 0.85);
    _shieldFill.strokeColor = [SKColor clearColor];
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
    _aimMark.strokeColor = [SKColor colorWithRed:1 green:0.75 blue:0.3 alpha:1];
    _aimMark.lineWidth = 2;
    [_root addChild:_aimMark];
    _statusLabel = Label(13, SKLabelHorizontalAlignmentModeCenter);
    [_root addChild:_statusLabel];
    _torpLabel = Label(13, SKLabelHorizontalAlignmentModeLeft);
    [_root addChild:_torpLabel];
    _bannerLabel = Label(30, SKLabelHorizontalAlignmentModeCenter);
    _bannerLabel.fontName = UIMonoBoldFont;
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
        a.strokeColor = [SKColor clearColor];
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
#if TARGET_OS_IOS
    UIEdgeInsets insets = self.contentInsets;
    if (CGSizeEqualToSize(s, _laidOut) && UIEdgeInsetsEqualToEdgeInsets(insets, _laidOutInsets)) return;
    _laidOutInsets = insets;
#else
    if (CGSizeEqualToSize(s, _laidOut)) return;
#endif
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
#if TARGET_OS_IOS
    // The bottom corners belong to the stick and weapon controls. Keep
    // telemetry in the open space above them and inside the safe area.
    CGFloat left = insets.left + 14, right = s.width - insets.right - 14;
    CGFloat top = s.height - insets.top - 18;
    CGFloat stats = insets.bottom + (s.width > s.height ? 18 : 177);
    CGFloat leftStats = s.width > s.height ? left + 160 : left;
    CGFloat rightStats = s.width > s.height ? right - 158 : right;
    _throttleLabel.position = CGPointMake(leftStats, stats + 36);
    _speedLabel.position = CGPointMake(leftStats, stats + 17);
    _speedLabel.fontSize = 16;
    _torpLabel.position = CGPointMake(leftStats, stats);
    _hullLabel.position = CGPointMake(rightStats - 88, stats + 24);
    _shieldLabel.position = CGPointMake(rightStats - 88, stats + 40);
    _hullFill.position = CGPointMake(rightStats - 80, stats + 21);
    _shieldFill.position = CGPointMake(rightStats - 80, stats + 37);
    _objectivePanel.position = CGPointMake(left, top);
    _inputLabel.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
    _inputLabel.position = CGPointMake(right, top - 44);
#endif
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
    l.fontColor = [SKColor colorWithRed:0.85 green:0.95 blue:1 alpha:1];
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

- (void)showBanner:(NSString *)text color:(SKColor *)color {
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
    _throttleFill.fillColor = f.boosting ? UIColorWithOpacity(UIBoost, 0.9) : HUDColor(0.75);
    SetBar(_boostFill, 3, 214 * f.boostEnergy);
    _boostFill.position = CGPointMake(-7, 3);
    _throttleLabel.text = [NSString stringWithFormat:@"THR %3d%%%@", (int)lroundf(f.throttle * 100), f.boosting ? @" BOOST" : @""];
    _speedLabel.text = [NSString stringWithFormat:@"%4d m/s", (int)lroundf(f.speed)];
    CGFloat conditionWidth = TARGET_OS_IOS ? 80 : 200;
    UISetSkewedBar(_hullFill, conditionWidth * f.hull, 6);
    UISetSkewedBar(_shieldFill, conditionWidth * f.shield, 6);
    _hullFill.fillColor = f.hull < 0.3 ? EnemyColor(0.9) : HUDColor(0.8);
    _scoreLabel.text = [NSString stringWithFormat:@"KILLS %d   DEATHS %d", f.kills, f.deaths];
    for (SKNode *n in @[_throttleFrame, _throttleLabel, _speedLabel, _hullFill, _shieldFill, _hullLabel, _shieldLabel, _scoreLabel, _torpLabel])
        n.hidden = f.cockpit;
    _scoreLabel.hidden = YES;
#if TARGET_OS_IOS
    _throttleFrame.hidden = YES;
#endif
    _torpLabel.text = [NSString stringWithFormat:@"TORP %d", f.torpedoes];
    _aimMark.hidden = !f.aimVisible || f.playerDead;
    _aimMark.position = f.aim;
    _aimMark.zRotation = 0.0;
    _statusLabel.text = f.status ?: @"";
    _statusLabel.position = CGPointMake(f.boresight.x, f.boresight.y - 40);
    _deadLabel.hidden = !f.playerDead;
    _damage.alpha = f.damageFlash * 0.35;

    _sunStreak.position = f.sun;
    _sunStreak.alpha = 0.45 * f.sunVisibility;

    for (NSUInteger i = 0; i < MAX_TARGETS; i++) {
        SKShapeNode *b = _brackets[i], *a = _arrows[i], *l = _leads[i];
        SKLabelNode *d = _distLabels[i];
        if (i >= count || f.playerDead) { b.hidden = a.hidden = l.hidden = d.hidden = YES; continue; }
        HUDTarget t = targets[i];
        SKColor *c = KindColor(t.kind, 0.9);
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
