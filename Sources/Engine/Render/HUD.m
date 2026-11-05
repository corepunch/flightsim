#import "HUD.h"
#import "FlightInstruments.h"
#import "LensFlare.h"
#import "UIStyle.h"
#import "PlatformImage.h"

#define MAX_TARGETS 64

static SKColor *HUDColor(CGFloat a) { return UIColorWithOpacity(UIInk, a); }
static SKColor *EnemyColor(CGFloat a) { return UIColorWithOpacity(UIRed, a); }
static SKColor *FriendColor(CGFloat a) { return UIColorWithOpacity(UIFriendly, a); }
static SKColor *NeutralColor(CGFloat a) { return UIColorWithOpacity(UIHUDNeutral, a); }
static SKColor *TargetColor(CGFloat a) { return [SKColor colorWithRed:1 green:0.92 blue:0.18 alpha:a]; }
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
    TargetReadout *_targetReadout;
    SensorScope *_forwardScope, *_rearScope;
    SKLabelNode *_laserLabel, *_rechargeLabel;
    SKShapeNode *_boresight, *_cursor, *_cursorLine, *_ring;
    SKShapeNode *_throttleFrame, *_throttleFill, *_boostFill, *_hullFill, *_shieldFill;
    SKLabelNode *_speedLabel, *_throttleLabel, *_scoreLabel, *_inputLabel, *_deadLabel, *_hullLabel, *_shieldLabel;
    SKNode *_help;
    SKShapeNode *_damage;
    NSMutableArray<SKShapeNode *> *_brackets, *_arrows, *_leads;
    NSMutableArray<SKLabelNode *> *_distLabels;
    NSMutableArray<SKShapeNode *> *_navMarks;
    SKShapeNode *_aimMark;
    SKShapeNode *_selectedOutline, *_selectedLeadOutline, *_selectedLabelBacking;
    SKLabelNode *_statusLabel, *_secondaryLabel, *_bannerLabel;
    SKNode *_objectivePanel, *_messagePanel;
    SKNode *_secondaryRack;
    NSMutableArray<SKShapeNode *> *_secondarySegments;
    NSMutableArray<SKLabelNode *> *_messages;
    LensFlare *_lensFlare;
    CGSize _laidOut;
    HUDInsets _laidOutInsets;
    BOOL _laidOutTouch;
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        _touchLayout = TARGET_OS_IOS;
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.backgroundColor = [SKColor clearColor];
        _root = [SKNode node];
        [self addChild:_root];
        [self build];
    }
    return self;
}

- (void)build {
    _targetReadout = [[TargetReadout alloc] initWithPreview:YES];
    _forwardScope = [[SensorScope alloc] initRear:NO];
    _rearScope = [[SensorScope alloc] initRear:YES];
    for (SKNode *instrument in @[_targetReadout, _forwardScope, _rearScope]) {
        instrument.zPosition = 25; [_root addChild:instrument];
    }
    _laserLabel = Label(12, SKLabelHorizontalAlignmentModeLeft);
    _rechargeLabel = Label(10, SKLabelHorizontalAlignmentModeRight);
    [_root addChild:_laserLabel]; [_root addChild:_rechargeLabel];
    _lensFlare = [LensFlare new];
    [_root addChild:_lensFlare];

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
    NSArray *lines = @[@"CLICK  capture mouse (virtual stick)   ESC release   wheel-click recentre",
                       @"MOUSE  pitch / yaw   hold RMB + move sideways to roll   Q/E roll   A/D yaw",
                       @"WHEEL or W/S throttle   Z full   X cut   SHIFT/TAB boost   SPACE/LMB fire",
                       @"C camera   J cycle stick throttle axis   K invert throttle   I invert mouse",
                       @"Joystick: X roll  Y pitch  throttle lever  B1 fire  B2/B4 boost  B3 camera  B5 torpedo  B6 target  hat look",
                       @"T  next target   G  torpedo   ESC (mouse free) / M  pause / flight options",
                       @"R restart   H toggle this help"];
    for (NSUInteger i = 0; i < lines.count; i++) {
        SKLabelNode *l = Label(12, SKLabelHorizontalAlignmentModeLeft);
        l.text = lines[i];
        l.fontColor = HUDColor(0.7);
        l.position = CGPointMake(0, -(CGFloat)i * 17);
        [_help addChild:l];
    }
    _help.hidden = YES;
    [_root addChild:_help];

    _navMarks = [NSMutableArray array];
    _aimMark = [SKShapeNode node];
    CGMutablePathRef am = CGPathCreateMutable();
    CGPathMoveToPoint(am, NULL, 0, 12); CGPathAddLineToPoint(am, NULL, 12, 0); CGPathAddLineToPoint(am, NULL, 0, -12); CGPathAddLineToPoint(am, NULL, -12, 0);
    CGPathCloseSubpath(am);
    _aimMark.path = am;
    CGPathRelease(am);
    _aimMark.strokeColor = TargetColor(1);
    _aimMark.lineWidth = 2.5;
    SKShapeNode *aimOutline = [SKShapeNode shapeNodeWithPath:_aimMark.path];
    aimOutline.strokeColor = [SKColor colorWithWhite:0 alpha:0.9];
    aimOutline.lineWidth = 5.5;
    aimOutline.zPosition = -1;
    [_aimMark addChild:aimOutline];
    _aimMark.zPosition = 20;
    [_root addChild:_aimMark];
    _statusLabel = Label(13, SKLabelHorizontalAlignmentModeCenter);
    [_root addChild:_statusLabel];
    _secondaryLabel = Label(12, SKLabelHorizontalAlignmentModeRight);
    _secondaryLabel.fontColor = UIColorWithOpacity(UIAmber, 0.9);
    [_root addChild:_secondaryLabel];
    _secondaryRack = [SKNode node];
    _secondarySegments = [NSMutableArray array];
    [_root addChild:_secondaryRack];
    _bannerLabel = Label(30, SKLabelHorizontalAlignmentModeCenter);
    _bannerLabel.fontName = UIMonoBoldFont;
    _bannerLabel.alpha = 0;
    [_root addChild:_bannerLabel];
    _objectivePanel = [SKNode node];
    [_root addChild:_objectivePanel];
    _messagePanel = [SKNode node];
    [_root addChild:_messagePanel];
    _messages = [NSMutableArray array];

    // One selected contact: dark outlines retain contrast against both the
    // starfield and bright hulls/bloom, without making every contact louder.
    _selectedOutline = [SKShapeNode node];
    _selectedLeadOutline = [SKShapeNode node];
    for (SKShapeNode *outline in @[_selectedOutline, _selectedLeadOutline]) {
        outline.strokeColor = [SKColor colorWithWhite:0 alpha:0.9];
        outline.lineWidth = 6;
        outline.zPosition = 19;
        outline.hidden = YES;
        [_root addChild:outline];
    }
    CGMutablePathRef leadOutline = CGPathCreateMutable();
    CGPathAddEllipseInRect(leadOutline, NULL, CGRectMake(-5, -5, 10, 10));
    for (int i = 0; i < 4; i++) {
        CGFloat a = i * M_PI_2;
        CGPathMoveToPoint(leadOutline, NULL, cos(a) * 5, sin(a) * 5);
        CGPathAddLineToPoint(leadOutline, NULL, cos(a) * 9, sin(a) * 9);
    }
    _selectedLeadOutline.path = leadOutline;
    CGPathRelease(leadOutline);
    _selectedLabelBacking = [SKShapeNode node];
    _selectedLabelBacking.fillColor = [SKColor colorWithWhite:0.015 alpha:0.85];
    _selectedLabelBacking.strokeColor = TargetColor(0.35);
    _selectedLabelBacking.lineWidth = 0.75;
    _selectedLabelBacking.zPosition = 21;
    _selectedLabelBacking.hidden = YES;
    [_root addChild:_selectedLabelBacking];

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
    HUDInsets insets = self.contentInsets;
    if (CGSizeEqualToSize(s, _laidOut) && _touchLayout == _laidOutTouch &&
        insets.left == _laidOutInsets.left && insets.right == _laidOutInsets.right &&
        insets.top == _laidOutInsets.top && insets.bottom == _laidOutInsets.bottom) return;
    _laidOutInsets = insets; _laidOutTouch = _touchLayout;
    _laidOut = s;
    _throttleFrame.position = CGPointMake(20, 22);
    _throttleLabel.position = CGPointMake(46, 32);
    _speedLabel.position = CGPointMake(46, 62);
    _hullLabel.position = CGPointMake(s.width - 222, 32);
    _shieldLabel.position = CGPointMake(s.width - 222, 50);
    _hullFill.position = CGPointMake(s.width - 210, 29);
    _shieldFill.position = CGPointMake(s.width - 210, 47);
    _scoreLabel.position = CGPointMake(s.width - 40, s.height - 40);
    _inputLabel.position = CGPointMake(40, 30);
    _deadLabel.position = CGPointMake(s.width / 2, s.height / 2 + 80);
    _help.position = CGPointMake(40, s.height - 40);
    _objectivePanel.position = CGPointMake(40, s.height - 40);
    _messagePanel.position = CGPointMake(s.width / 2, s.height - 110);
    _bannerLabel.position = CGPointMake(s.width / 2, s.height * 0.68);
    if (_touchLayout) {
    // Telemetry follows the safe edges, below the touch control clusters.
    CGFloat left = insets.left + 8, right = s.width - insets.right - 8;
    CGFloat top = s.height - insets.top - 18;
    CGFloat stats = insets.bottom + (s.width > s.height ? 9 : 177);
    CGFloat leftStats = left;
    CGFloat rightStats = right;
    _throttleLabel.position = CGPointMake(leftStats, stats + 36);
    _speedLabel.position = CGPointMake(leftStats, stats + 17);
    _speedLabel.fontSize = 16;
    _hullLabel.position = CGPointMake(rightStats - 88, stats + 24);
    _shieldLabel.position = CGPointMake(rightStats - 88, stats + 40);
    _hullFill.position = CGPointMake(rightStats - 80, stats + 21);
    _shieldFill.position = CGPointMake(rightStats - 80, stats + 37);
    _objectivePanel.position = CGPointMake(left + 100, top);
    _inputLabel.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
    _inputLabel.position = CGPointMake(right - 100, top - 44);
    }
    BOOL phoneLayout = _touchLayout && MIN(s.width, s.height) < 550 && MAX(s.width, s.height) < 1100;
    CGFloat edgeLeft = 12, edgeRight = s.width - 12, edgeTop = s.height;
    CGFloat edgeBottom = phoneLayout ? 2 : (_touchLayout ? insets.bottom + 24 : 40);
    if (_touchLayout) {
    edgeLeft = insets.left + 4; edgeRight = s.width - insets.right - 4;
    edgeTop -= insets.top;
    }
    BOOL compact = s.height < 550;
    CGFloat scopeScale = compact ? 0.56 : 0.86;
    [_forwardScope setScale:scopeScale]; [_rearScope setScale:scopeScale];
    // The top label extends 82 points from the centre at the authored scale.
    CGFloat scopeY = edgeTop - 82 * scopeScale - (_touchLayout ? 4 : 12);
    _forwardScope.position = CGPointMake(edgeLeft + 64 * scopeScale, scopeY);
    _rearScope.position = CGPointMake(edgeRight - 64 * scopeScale, scopeY);
    [_targetReadout setCompact:compact];
    CGFloat panelWidth = MIN(compact ? 270 : 380, MAX(160, s.width - 380));
    CGFloat panelScale = panelWidth / 608;
    [_targetReadout setScale:panelScale];
    _targetReadout.position = CGPointMake((s.width - panelWidth) / 2, edgeBottom);
    _laserLabel.position = CGPointMake(_throttleLabel.position.x, _throttleLabel.position.y + (_touchLayout ? 20 : 60));
    _rechargeLabel.position = CGPointMake(edgeRight, _shieldLabel.position.y - 33);
    // Match the actual text edge to the bottom of the target details.
    SKNode *heading = _objectivePanel.children.firstObject;
    CGFloat bottomMargin = edgeBottom + (compact ? 11 : 20) * panelScale;
    CGFloat topMargin = phoneLayout ? MAX(insets.top, bottomMargin) : (_touchLayout ? insets.top + 30 : 36);
    CGFloat headingTop = heading ? CGRectGetMaxY(heading.frame) : 7;
    _objectivePanel.position = CGPointMake(edgeLeft + 128 * scopeScale + 16,
                                           s.height - topMargin - headingTop);
    _secondaryLabel.position = CGPointMake(_shieldLabel.position.x, _shieldLabel.position.y + 18);
    _secondaryRack.position = CGPointMake(_shieldFill.position.x, _shieldFill.position.y + 18);
    [self layoutSecondary];
    CGPathRef dp = CGPathCreateWithRect(CGRectMake(0, 0, s.width, s.height), NULL);
    _damage.path = dp;
    CGPathRelease(dp);
    _ring.position = _cursor.position = CGPointMake(s.width / 2, s.height / 2);
}

- (void)layoutSecondary {
    NSUInteger count = _secondarySegments.count;
    if (!count) return;
    CGFloat width = _touchLayout ? 80 : 200;
    CGFloat gap = MIN(4, width / (count * 4));
    CGFloat segmentWidth = (width - gap * (count - 1)) / count;
    for (NSUInteger i = 0; i < count; i++) {
        SKShapeNode *segment = _secondarySegments[i];
        segment.position = CGPointMake(i * (segmentWidth + gap), 0);
        UISetSkewedBar(segment, segmentWidth, 6);
    }
}

- (void)updateSecondary:(int)remaining capacity:(int)capacity name:(NSString *)name {
    capacity = MAX(0, MAX(capacity, remaining));
    remaining = MAX(0, remaining);
    if (_secondarySegments.count != (NSUInteger)capacity) {
        [_secondaryRack removeAllChildren];
        [_secondarySegments removeAllObjects];
        for (int i = 0; i < capacity; i++) {
            SKShapeNode *segment = [SKShapeNode node];
            segment.lineWidth = 0.75;
            [_secondaryRack addChild:segment];
            [_secondarySegments addObject:segment];
        }
        [self layoutSecondary];
    }
    for (NSUInteger i = 0; i < _secondarySegments.count; i++) {
        BOOL loaded = i < (NSUInteger)remaining;
        _secondarySegments[i].fillColor = UIColorWithOpacity(UIAmber, loaded ? 0.9 : 0.04);
        _secondarySegments[i].strokeColor = UIColorWithOpacity(UIAmber, loaded ? 0.95 : 0.4);
    }
    _secondaryLabel.text = name.length ? name : @"";
}

- (void)updateInstruments:(CockpitFrame)frame contacts:(const CockpitContact *)contacts count:(NSUInteger)count cockpit:(BOOL)cockpit {
    [self layoutIfNeeded];
    [_forwardScope updateFrame:frame contacts:contacts count:count];
    [_rearScope updateFrame:frame contacts:contacts count:count];
    _targetReadout.hidden = cockpit;
    if (!cockpit) [_targetReadout updateFrame:frame contacts:contacts count:count];
    _laserLabel.hidden = _rechargeLabel.hidden = cockpit;
    _laserLabel.text = [NSString stringWithFormat:@"LASER %3d%%", (int)lroundf(frame.weaponEnergy * 100)];
    _laserLabel.fontColor = frame.weaponEnergy < frame.weaponShotEnergy ? EnemyColor(1) : HUDColor(0.9);
    _rechargeLabel.text = frame.shield < 0.999 ? @"SHIELD +6%/S" : @"SHIELD FULL";
}

- (void)setInputText:(NSString *)text { _inputLabel.text = @""; }
- (void)toggleHelp {
    _help.hidden = YES;
}
- (void)setHelpVisible:(BOOL)visible {
    _help.hidden = YES;
    _objectivePanel.hidden = NO;
}

- (void)setObjectives:(NSArray<NSString *> *)lines states:(NSArray<NSNumber *> *)states {
    [_objectivePanel removeAllChildren];
    SKLabelNode *head = Label(13, SKLabelHorizontalAlignmentModeLeft);
    head.text = @"OBJECTIVES";
    head.fontColor = HUDColor(0.6);
    [_objectivePanel addChild:head];
    _laidOut = CGSizeZero; // Heading metrics determine the matching top margin.
    // The border's outside edge matches the capital D, rather than the font's
    // point size. All states share exactly the same square control geometry.
    PlatformFont *font = [PlatformFont fontWithName:UIMonoFont size:14];
    CGFloat side = font.capHeight;
    for (NSUInteger i = 0; i < lines.count; i++) {
        int st = states[i].intValue;
        SKNode *row = [SKNode node];
        row.position = CGPointMake(0, -22.0 * (i + 1));
        SKColor *ink = st == 2 ? EnemyColor(0.95) : HUDColor(0.95);
        const CGFloat border = 1.0;
        SKShapeNode *box = [SKShapeNode shapeNodeWithRect:CGRectMake(border / 2, -side / 2 + border / 2,
                                                                   side - border, side - border)];
        box.strokeColor = ink;
        box.fillColor = SKColor.clearColor;
        box.lineWidth = border;
        [row addChild:box];
        if (st == 1 || st == 2) {
            CGMutablePathRef path = CGPathCreateMutable();
            if (st == 1) {
                CGPathMoveToPoint(path, NULL, side * 0.23, side * -0.02);
                CGPathAddLineToPoint(path, NULL, side * 0.43, side * -0.27);
                CGPathAddLineToPoint(path, NULL, side * 0.77, side * 0.27);
            } else {
                CGPathMoveToPoint(path, NULL, side * 0.27, side * -0.23);
                CGPathAddLineToPoint(path, NULL, side * 0.73, side * 0.23);
                CGPathMoveToPoint(path, NULL, side * 0.27, side * 0.23);
                CGPathAddLineToPoint(path, NULL, side * 0.73, side * -0.23);
            }
            SKShapeNode *mark = [SKShapeNode shapeNodeWithPath:path];
            CGPathRelease(path);
            mark.strokeColor = ink;
            mark.lineWidth = 1.35;
            mark.lineCap = kCGLineCapRound;
            mark.lineJoin = kCGLineJoinRound;
            [row addChild:mark];
        }
        SKLabelNode *l = Label(14, SKLabelHorizontalAlignmentModeLeft);
        l.verticalAlignmentMode = SKLabelVerticalAlignmentModeBaseline;
        l.text = lines[i];
        l.fontColor = ink;
        l.position = CGPointMake(side + 8, -side / 2);
        [row addChild:l];
        [_objectivePanel addChild:row];
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
    CGFloat conditionWidth = _touchLayout ? 80 : 200;
    UISetSkewedBar(_hullFill, conditionWidth * f.hull, 6);
    UISetSkewedBar(_shieldFill, conditionWidth * f.shield, 6);
    _hullFill.fillColor = f.hull < 0.3 ? EnemyColor(0.9) : HUDColor(0.8);
    _scoreLabel.text = [NSString stringWithFormat:@"KILLS %d   DEATHS %d", f.kills, f.deaths];
    for (SKNode *n in @[_throttleFrame, _throttleLabel, _speedLabel, _hullFill, _shieldFill, _hullLabel, _shieldLabel, _scoreLabel, _secondaryLabel, _secondaryRack])
        n.hidden = f.cockpit;
    _scoreLabel.hidden = YES;
    if (_touchLayout) _throttleFrame.hidden = YES;
    [self updateSecondary:f.secondary capacity:f.secondaryCapacity name:f.secondaryName];
    _aimMark.hidden = !f.aimVisible || f.playerDead;
    _aimMark.position = f.aim;
    _aimMark.zRotation = 0.0;
    _statusLabel.text = f.status ?: @"";
    _statusLabel.position = CGPointMake(f.boresight.x, f.boresight.y - 40);
    _deadLabel.hidden = !f.playerDead;
    _damage.alpha = f.damageFlash * 0.35;

    [_lensFlare updateSource:f.sun visibility:f.sunVisibility viewport:s deltaTime:f.deltaTime];

    _selectedOutline.hidden = _selectedLeadOutline.hidden = _selectedLabelBacking.hidden = YES;
    for (NSUInteger i = 0; i < MAX_TARGETS; i++) {
        SKShapeNode *b = _brackets[i], *a = _arrows[i], *l = _leads[i];
        SKLabelNode *d = _distLabels[i];
        if (i >= count || f.playerDead) { b.hidden = a.hidden = l.hidden = d.hidden = YES; continue; }
        HUDTarget t = targets[i];
        SKColor *c = t.selected ? TargetColor(1) : KindColor(t.kind, 0.9);
        BOOL nav = t.kind == HUDKindNav;
        b.hidden = !t.onScreen;
        d.hidden = !t.onScreen;
        // Off-screen arrows only for what matters: hostile fighters, navs, the selection.
        a.hidden = t.onScreen || !(t.selected || nav || (t.kind == HUDKindEnemy && !t.capital));
        l.hidden = !(t.onScreen && t.hasLead && (t.selected || (t.kind == HUDKindEnemy && !t.capital)));
        b.strokeColor = c;
        b.lineWidth = t.selected ? 3 : 1.5;
        b.zPosition = a.zPosition = l.zPosition = t.selected ? 20 : 0;
        a.fillColor = t.selected ? c : KindColor(t.kind, 0.7);
        a.strokeColor = t.selected ? [SKColor colorWithWhite:0 alpha:0.9] : SKColor.clearColor;
        a.lineWidth = t.selected ? 2 : 0;
        [a setScale:t.selected ? 1.4 : 1];
        l.strokeColor = t.selected ? c : EnemyColor(0.8);
        l.lineWidth = t.selected ? 2.25 : 1.5;
        [l setScale:t.selected ? 1.35 : 1];
        for (SKShapeNode *tick in l.children) {
            tick.strokeColor = l.strokeColor;
            tick.lineWidth = l.lineWidth;
        }
        d.fontColor = c;
        d.fontName = t.selected ? UIMonoBoldFont : UIMonoFont;
        d.fontSize = t.selected ? 14 : 11;
        d.zPosition = t.selected ? 22 : 0;
        d.numberOfLines = t.selected ? 2 : 1;
        d.preferredMaxLayoutWidth = t.selected ? MIN(320, s.width - 24) : 0;
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
                bp = BracketPath(roundf(t.selected ? MAX(44, t.size) : t.size));
            }
            b.path = bp;
            CGPathRelease(bp);
            NSString *dist = t.distance >= 1000 ? [NSString stringWithFormat:@"%.1fkm", t.distance / 1000.0]
                                                : [NSString stringWithFormat:@"%dm", (int)t.distance];
            BOOL named = t.label && (t.selected || t.capital || nav);
            d.text = named ? [NSString stringWithFormat:@"%@ %@", t.label, dist] : dist;
            if (t.selected) d.text = [@"TARGET / " stringByAppendingString:d.text];
            CGFloat half = nav ? 12 : (t.selected ? MAX(44, t.size) : t.size) * 0.5;
            d.position = CGPointMake(t.point.x + half + 6, t.point.y + half + (t.selected ? 10 : -4));
            if (t.selected) {
                CGRect text = d.frame;
                // Keep the larger label below the contact, away from the
                // forward lead marker. Flip above near the bottom edge.
                CGFloat labelY = t.point.y - half - 12 - text.size.height / 2;
                if (labelY - text.size.height / 2 < 12)
                    labelY = t.point.y + half + 12 + text.size.height / 2;
                d.position = CGPointMake(MAX(12, MIN(t.point.x - text.size.width / 2, s.width - text.size.width - 12)),
                                         MAX(text.size.height / 2 + 12, MIN(labelY, s.height - text.size.height / 2 - 12)));
                CGPathRef plate = CGPathCreateWithRoundedRect(CGRectInset(d.frame, -6, -4), 3, 3, NULL);
                _selectedLabelBacking.path = plate;
                CGPathRelease(plate);
                _selectedLabelBacking.hidden = NO;
                _selectedOutline.path = b.path;
                _selectedOutline.position = b.position;
                _selectedOutline.hidden = NO;
                _selectedLeadOutline.position = t.lead;
                [_selectedLeadOutline setScale:l.xScale];
                _selectedLeadOutline.hidden = l.hidden;
            }
            l.position = t.lead;
        } else {
            a.position = t.point;
            a.zRotation = t.angle;
        }
    }
}

@end
