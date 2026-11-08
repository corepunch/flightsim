#import "Refresh.h"
#import "Render.h"
#import "UI.h"
#import "Common.h"

#define MAX_TARGETS 64

static SKColor *HUDColor(CGFloat a) { return UIColorWithOpacity(UIInk, a); }

// The sensor scopes' scale: smaller on short screens, larger on touch phones
// where the scopes are read at arm's length.
static CGFloat ScannerScale(CGSize size, BOOL touchLayout) {
    CGFloat scale = size.height < 550 ? 0.56 : 0.86;
    BOOL phone = touchLayout && MIN(size.width, size.height) < 550 && MAX(size.width, size.height) < 1100;
    return scale * (phone ? 1.5 : 1);
}
static SKColor *EnemyColor(CGFloat a) { return UIColorWithOpacity(UIRed, a); }
static SKColor *FriendColor(CGFloat a) { return UIColorWithOpacity(UIFriendly, a); }
static SKColor *NeutralColor(CGFloat a) { return UIColorWithOpacity(UIHUDNeutral, a); }
static SKColor *PickupColor(CGFloat a) { return UIColorWithOpacity(UIPickup, a); }
static SKColor *ReticleColor(CGFloat a) { return UIColorWithOpacity(UIReticle, a); }
static SKColor *TargetColor(CGFloat a) { return [SKColor colorWithRed:1 green:0.92 blue:0.18 alpha:a]; }
static SKColor *KindColor(HUDKind k, CGFloat a) {
    switch (k) {
        case HUDKindEnemy: return EnemyColor(a);
        case HUDKindFriend: return FriendColor(a);
        case HUDKindNeutral: return NeutralColor(a);
        case HUDKindNav: return HUDColor(a);
        case HUDKindPickup: return PickupColor(a);
    }
}

static SKLabelNode *Label(CGFloat size, SKLabelHorizontalAlignmentMode align) {
    return UIMonoLabel(size, HUDColor(0.9), align, SKLabelVerticalAlignmentModeCenter);
}

// These small moving rings need no per-frame cubic subdivision in SpriteKit.
// A 64-edge circle differs by less than a pixel at the reticle's drawn size.
static void ReticleArc(CGMutablePathRef path, CGFloat radius, CGFloat start, CGFloat end, int steps) {
    for (int i = 0; i <= steps; i++) {
        CGFloat angle = start + (end - start) * i / steps;
        CGPoint point = PointScale(CGPointMake(cos(angle), sin(angle)), radius);
        if (i == 0) CGPathMoveToPoint(path, NULL, point.x, point.y);
        else CGPathAddLineToPoint(path, NULL, point.x, point.y);
    }
}

static CGPathRef ReticleShape(BOOL nearest, BOOL pip) {
    static CGPathRef shapes[4];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (int i = 0; i < 4; i++) {
            CGMutablePathRef path = CGPathCreateMutable();
            ReticleArc(path, 2.5, 0, M_PI * 2, 64);
            CGPathCloseSubpath(path);
            if (i & 1) for (int side = 0; side < 2; side++)
                ReticleArc(path, 3.6, side * M_PI - 0.6, side * M_PI + 0.6, 16);
            if (i & 2) {
                ReticleArc(path, 0.4, 0, M_PI * 2, 16);
                CGPathCloseSubpath(path);
            }
            shapes[i] = path;
        }
    });
    return shapes[(nearest ? 1 : 0) | (pip ? 2 : 0)];
}

typedef struct {
    NSArray<NSNumber *> *states;
    NSArray<SKLabelNode *> *labels;
    NSArray<UIHorizontalStack *> *rows;
} HUDObjectives;

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

#pragma mark - Condition bars

// One row of the ship's condition on the right: a label, then a skewed bar
// filling a dark track that shows the bar's full length even when empty.
// What the next second of recharge adds is drawn just ahead of the fill in a
// fainter shade of the same colour, so a fast-filling bar shows a long chunk.
@interface ConditionBar : UIHorizontalStack
- (instancetype)initWithTitle:(NSString *)title;
@property (nonatomic) CGFloat width;                // of a full bar, points
- (void)setLevel:(float)level recharge:(float)perSecond color:(SKColor *)color;
@property (nonatomic, readonly) CGFloat inkBottom;  // lowest visible point, from the position
@property (nonatomic, readonly) CGFloat inkHeight;
@end

@implementation ConditionBar {
    SKShapeNode *_track, *_fill, *_chunk;
    SKNode *_bar;
}

- (instancetype)initWithTitle:(NSString *)title {
    if ((self = [super init])) {
        SKLabelNode *label = Label(12, SKLabelHorizontalAlignmentModeRight);
        label.text = title;
        self.spacing = 10;
        self.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
        [self addArrangedNode:label];
        _bar = [SKNode node];
        [self addArrangedNode:_bar layoutBounds:CGRectMake(0, 0, 200, 6)];
        _track = [SKShapeNode node];
        _track.fillColor = HUDColor(0.2);
        _fill = [SKShapeNode node];
        _chunk = [SKShapeNode node];
        for (SKShapeNode *n in @[_track, _fill, _chunk]) { n.strokeColor = SKColor.clearColor; [_bar addChild:n]; }
        self.width = 200;
    }
    return self;
}

- (void)setWidth:(CGFloat)width {
    _width = width;
    [self setLayoutBounds:CGRectMake(0, 0, width, 6) forArrangedNode:_bar];
    UISetSkewedBar(_track, width, 6);
    [self layout];
}

- (void)setLevel:(float)level recharge:(float)perSecond color:(SKColor *)color {
    level = clampf(level, 0, 1);
    float ahead = fminf(1 - level, fmaxf(perSecond, 0));
    UISetSkewedBar(_fill, _width * level, 6);
    _fill.fillColor = color;
    _chunk.hidden = ahead < 0.001f;
    _chunk.position = CGPointMake(_width * level, 0);
    UISetSkewedBar(_chunk, _width * ahead, 6);
    _chunk.fillColor = [color colorWithAlphaComponent:CGColorGetAlpha(color.CGColor) * 0.35];
}

// Fallback scripts can extend beyond the Latin font's capital height.
- (CGFloat)inkBottom { return -self.contentSize.height / 2; }
- (CGFloat)inkHeight { return self.contentSize.height; }

@end

@implementation HUD {
    SKNode *_root;
    TargetReadout *_targetReadout;
    SensorScope *_forwardScope, *_rearScope;
    ConditionBar *_hullBar, *_shieldBar, *_laserBar;     // bottom up, under the secondary rack
    // Touch screens show the throttle as a bar under the hull instead of the
    // gauge and the throttle and speed readouts in the left corner, which
    // the on-screen controller's stick covers.
    ConditionBar *_thrustBar;
    SKShapeNode *_boresight, *_cursor, *_cursorLine, *_ring;
    // The chase view's reticle, drawn in perspective each frame: one node per
    // ring so farther rings can be fainter.
    NSArray<SKShapeNode *> *_reticleRings;
    SKShapeNode *_throttleFrame, *_throttleFill, *_boostFill;
    SKLabelNode *_speedLabel, *_throttleLabel, *_scoreLabel, *_inputLabel, *_deadLabel;
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
    UIHorizontalStack *_secondaryRow;
    NSMutableArray<SKShapeNode *> *_secondarySegments;
    NSMutableArray<SKLabelNode *> *_messages;
    LensFlare *_lensFlare;
    CGSize _laidOut;
    HUDInsets _laidOutInsets;
    BOOL _laidOutTouch;
    HUDObjectives _objectives;
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
    _targetReadout = [[TargetReadout alloc] initWithPreview:NO];
    _forwardScope = [[SensorScope alloc] initRear:NO];
    _rearScope = [[SensorScope alloc] initRear:YES];
    for (SKNode *instrument in @[_targetReadout, _forwardScope, _rearScope]) {
        instrument.zPosition = 25; [_root addChild:instrument];
    }
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
    NSMutableArray<SKShapeNode *> *rings = [NSMutableArray array];
    for (int i = 0; i < HUD_RETICLE_RINGS; i++) {
        SKShapeNode *n = [SKShapeNode node];
        n.strokeColor = ReticleColor(0.95 - 0.22 * i);
        n.lineWidth = i ? 1 : 1.5;
        n.lineCap = kCGLineCapRound;
        n.hidden = YES;
        [_root addChild:n];
        [rings addObject:n];
    }
    _reticleRings = rings;

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
    _speedLabel.text = L10nFormat(@"hud.speed", 0);
    [_root addChild:_speedLabel];

    _hullBar = [[ConditionBar alloc] initWithTitle:L10n(@"hud.hull")];
    _shieldBar = [[ConditionBar alloc] initWithTitle:L10n(@"hud.shield")];
    _laserBar = [[ConditionBar alloc] initWithTitle:L10n(@"hud.laser")];
    _thrustBar = [[ConditionBar alloc] initWithTitle:L10n(@"hud.thrust")];
    for (ConditionBar *bar in @[_thrustBar, _hullBar, _shieldBar, _laserBar]) [_root addChild:bar];

    _scoreLabel = Label(16, SKLabelHorizontalAlignmentModeRight);
    [_root addChild:_scoreLabel];
    _inputLabel = Label(12, SKLabelHorizontalAlignmentModeLeft);
    _inputLabel.fontColor = HUDColor(0.55);
    [_root addChild:_inputLabel];
    _deadLabel = Label(30, SKLabelHorizontalAlignmentModeCenter);
    _deadLabel.text = L10n(@"hud.destroyed");
    _deadLabel.fontColor = EnemyColor(0.95);
    _deadLabel.hidden = YES;
    [_root addChild:_deadLabel];

    _help = [SKNode node];
    NSArray *lines = L10nList(@"hud.help");
    for (NSUInteger i = 0; i < lines.count; i++) {
        SKLabelNode *l = Label(12, SKLabelHorizontalAlignmentModeLeft);
        l.text = lines[i];
        l.fontColor = HUDColor(0.7);
        l.position = CGPointMake(0, -(CGFloat)i * 17);
        [_help addChild:l];
    }
    _help.hidden = YES;
    _help.zPosition = 200;
    [_root addChild:_help];

    _navMarks = [NSMutableArray array];
    _aimMark = [SKShapeNode node];
    CGMutablePathRef am = CGPathCreateMutable();
    CGPathMoveToPoint(am, NULL, 0, 12); CGPathAddLineToPoint(am, NULL, 12, 0); CGPathAddLineToPoint(am, NULL, 0, -12); CGPathAddLineToPoint(am, NULL, -12, 0);
    CGPathCloseSubpath(am);
    _aimMark.path = am;
    CGPathRelease(am);
    _aimMark.strokeColor = TargetColor(1);
    _aimMark.lineWidth = 1;
    SKShapeNode *aimOutline = [SKShapeNode shapeNodeWithPath:_aimMark.path];
    aimOutline.strokeColor = [SKColor colorWithWhite:0 alpha:0.9];
    aimOutline.lineWidth = 3;
    aimOutline.zPosition = -1;
    [_aimMark addChild:aimOutline];
    _aimMark.zPosition = 20;
    [_root addChild:_aimMark];
    _statusLabel = Label(13, SKLabelHorizontalAlignmentModeCenter);
    [_root addChild:_statusLabel];
    _secondaryLabel = Label(12, SKLabelHorizontalAlignmentModeRight);
    _secondaryLabel.fontColor = UIColorWithOpacity(UIAmber, 0.9);
    _secondaryRow = [UIHorizontalStack node];
    _secondaryRow.spacing = 10;
    _secondaryRow.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
    [_secondaryRow addArrangedNode:_secondaryLabel];
    _secondaryRack = [SKNode node];
    [_secondaryRow addArrangedNode:_secondaryRack layoutBounds:CGRectMake(0, 0, 200, 6)];
    _secondarySegments = [NSMutableArray array];
    [_root addChild:_secondaryRow];
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
    // starfield and bright hulls, without making every contact louder.
    _selectedOutline = [SKShapeNode node];
    _selectedLeadOutline = [SKShapeNode node];
    for (SKShapeNode *outline in @[_selectedOutline, _selectedLeadOutline]) {
        outline.strokeColor = [SKColor colorWithWhite:0 alpha:0.9];
        outline.lineWidth = 3;
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
    _hullBar.position = CGPointMake(s.width - 10, 29);
    _shieldBar.position = CGPointMake(s.width - 10, 47);
    _laserBar.position = CGPointMake(s.width - 10, 65);
    _scoreLabel.position = CGPointMake(s.width - 40, s.height - 40);
    _inputLabel.position = CGPointMake(40, 30);
    _deadLabel.position = CGPointMake(s.width / 2, s.height / 2 + 80);
    _help.position = CGPointMake(40, s.height - 40);
    _objectivePanel.position = CGPointMake(40, s.height - 40);
    _messagePanel.position = CGPointMake(s.width / 2, s.height - 110);
    _bannerLabel.position = CGPointMake(s.width / 2, s.height * 0.68);
    if (_touchLayout) {
    // Corner readouts can sit below the central home-indicator inset. Keep
    // their side insets so the rounded bottom corners remain clear.
    CGFloat left = insets.left + 8, right = s.width - insets.right - 8;
    CGFloat top = s.height - insets.top - 18;
    CGFloat stats = s.width > s.height ? 10 : insets.bottom + 194;
    CGFloat leftStats = left;
    CGFloat rightStats = right;
    _throttleLabel.position = CGPointMake(leftStats, stats + 19);
    _speedLabel.position = CGPointMake(leftStats, stats);
    _speedLabel.fontSize = 16;
    _hullBar.position = CGPointMake(rightStats, stats + 4);
    _shieldBar.position = CGPointMake(rightStats, stats + 20);
    _laserBar.position = CGPointMake(rightStats, stats + 36);
    _objectivePanel.position = CGPointMake(left + 100, top);
    _inputLabel.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
    _inputLabel.position = CGPointMake(right - 100, top - 44);
    }
    BOOL phoneLayout = _touchLayout && MIN(s.width, s.height) < 550 && MAX(s.width, s.height) < 1100;
    CGFloat edgeBottom = phoneLayout ? 2 : (_touchLayout ? insets.bottom + 24 : 40);
    BOOL compact = s.height < 550;
    CGFloat scopeScale = ScannerScale(s, _touchLayout);
    [_forwardScope setScale:scopeScale]; [_rearScope setScale:scopeScale];
    // Landscape sensor housings sit mid-edge. The upper corners can use a
    // uniform inset, with room above each disc for its label.
    CGFloat scopeInset = 82 * scopeScale + (_touchLayout ? insets.top + 4 : 12);
    _forwardScope.position = CGPointMake(scopeInset, s.height - scopeInset);
    _rearScope.position = CGPointMake(s.width - scopeInset, s.height - scopeInset);
    [_targetReadout setCompact:compact];
    CGFloat panelWidth = MIN(compact ? 270 : 380, MAX(160, s.width - 380));
    CGFloat panelScale = panelWidth / 608;
    [_targetReadout setScale:panelScale];
    _targetReadout.position = CGPointMake((s.width - panelWidth) / 2, edgeBottom);
    // Match the actual text edge to the bottom of the target details.
    CGFloat bottomMargin = edgeBottom + (compact ? 11 : 20) * panelScale;
    CGFloat rowStep = _touchLayout ? 16 : 18;
    for (ConditionBar *bar in @[_thrustBar, _hullBar, _shieldBar, _laserBar]) rowStep = MAX(rowStep, bar.inkHeight + 4);
    if (phoneLayout && s.width > s.height) {
        // The corner readouts end on the same line as the target details, so
        // every bottom indicator keeps one distance from the screen edge.
        CGFloat lift = bottomMargin - CGRectGetMinY(_speedLabel.frame);
        _speedLabel.position = PointAdd(_speedLabel.position, CGPointMake(0, lift));
        _throttleLabel.position = PointAdd(_throttleLabel.position, CGPointMake(0, lift));
        lift = bottomMargin - _hullBar.inkBottom - _hullBar.position.y;
        for (ConditionBar *bar in @[_hullBar, _shieldBar, _laserBar])
            bar.position = PointAdd(bar.position, CGPointMake(0, lift));
    }
    _shieldBar.position = PointAdd(_hullBar.position, CGPointMake(0, rowStep));
    _laserBar.position = PointAdd(_shieldBar.position, CGPointMake(0, rowStep));
    CGFloat topMargin = phoneLayout ? MAX(insets.top, bottomMargin) : (_touchLayout ? insets.top + 30 : 36);
    // The objective rows hang from the top margin, clear of the forward
    // scope's drawn edge, whatever its scale.
    CGFloat scopeRight = CGRectGetMaxX(_forwardScope.discFrame);
    _objectivePanel.position = CGPointMake(scopeRight + (compact ? 20 : 28), s.height - topMargin);
    CGFloat objectivesRight = CGRectGetMinX(_rearScope.discFrame) - 12;
    CGFloat objectivesWidth = MAX(80, objectivesRight - _objectivePanel.position.x);
    CGFloat rowTop = 0;
    for (UIHorizontalStack *row in _objectives.rows) {
        row.maximumWidth = objectivesWidth;
        [row layout];
        row.position = CGPointMake(0, rowTop - row.contentSize.height / 2);
        rowTop -= row.contentSize.height + 8;
    }
    CGFloat helpWidth = MAX(1, MIN(760, s.width - insets.left - insets.right - 48));
    CGFloat helpY = 0;
    for (SKNode *node in _help.children) if ([node isKindOfClass:SKLabelNode.class]) {
        SKLabelNode *label = (SKLabelNode *)node;
        label.numberOfLines = 0;
        label.preferredMaxLayoutWidth = MAX(1, helpWidth - 32);
        label.verticalAlignmentMode = SKLabelVerticalAlignmentModeTop;
        label.position = CGPointMake(16, -16 + helpY);
        helpY -= CGRectGetHeight(label.frame) + 8;
    }
    [[_help childNodeWithName:@"help-backdrop"] removeFromParent];
    CGFloat helpHeight = -helpY + 24;
    SKSpriteNode *helpBackdrop = [SKSpriteNode spriteNodeWithColor:[SKColor colorWithWhite:0 alpha:0.92]
        size:CGSizeMake(helpWidth, helpHeight)];
    helpBackdrop.name = @"help-backdrop"; helpBackdrop.anchorPoint = CGPointMake(0, 1); helpBackdrop.zPosition = -1;
    [_help addChild:helpBackdrop];
    _help.position = CGPointMake(insets.left + (s.width - insets.left - insets.right - helpWidth) / 2,
        insets.bottom + (s.height - insets.top - insets.bottom + helpHeight) / 2);
    _secondaryRow.position = PointAdd(_laserBar.position, CGPointMake(0, rowStep));
    for (ConditionBar *bar in @[_thrustBar, _hullBar, _shieldBar, _laserBar]) bar.width = _touchLayout ? 80 : 200;
    [self layoutSecondary];
    if (_touchLayout) {
        // The on-screen controller fills the bottom corners, so the thrust and
        // condition bars stack at the bottom centre, as far from the bottom
        // edge as the objectives list is from the top.
        NSArray<SKNode *> *rows = @[_thrustBar, _hullBar, _shieldBar, _laserBar, _secondaryRow];
        // The block's rows sit closer than the desktop's corner stack.
        CGFloat blockStep = rowStep * 0.8;
        CGPoint row = CGPointMake(0, topMargin - _thrustBar.inkBottom);
        for (SKNode *node in rows) {
            node.position = row;
            row = PointAdd(row, CGPointMake(0, blockStep));
        }
        CGRect block = CGRectNull;
        for (SKNode *node in rows) block = CGRectUnion(block, [node calculateAccumulatedFrame]);
        CGPoint shift = CGPointMake(s.width / 2 - CGRectGetMidX(block), 0);
        for (SKNode *node in rows) node.position = PointAdd(node.position, shift);
    }
    CGPathRef dp = CGPathCreateWithRect(CGRectMake(0, 0, s.width, s.height), NULL);
    _damage.path = dp;
    CGPathRelease(dp);
    _ring.position = _cursor.position = CGPointMake(s.width / 2, s.height / 2);
    [self layoutMessages];
}

- (void)layoutMessages {
    CGSize size = self.size;
    BOOL compact = _touchLayout && size.height < 550;
    CGFloat width = compact ? MAX(160, size.width - _contentInsets.left - _contentInsets.right - 400)
                            : MIN(760, size.width - _contentInsets.left - _contentInsets.right - 48);
    CGRect objectives = [_objectivePanel calculateAccumulatedFrame];
    CGFloat top = size.height - _contentInsets.top - 100;
    if (!_objectivePanel.hidden && _objectivePanel.children.count) top = MIN(top, CGRectGetMinY(objectives) - 12);
    _messagePanel.position = CGPointMake(size.width / 2, top);
    CGFloat y = 0;
    for (NSUInteger i = 0; i < _messages.count; i++) {
        SKLabelNode *label = _messages[i];
        // Short phone screens reserve the central lane for the latest radio
        // line; older lines have already had their time on screen.
        label.hidden = compact && i > 0;
        label.numberOfLines = 0;
        label.preferredMaxLayoutWidth = MAX(1, width);
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.verticalAlignmentMode = SKLabelVerticalAlignmentModeTop;
        label.position = CGPointMake(0, y);
        y -= CGRectGetHeight(label.frame) + 8;
    }
}

- (void)layoutSecondary {
    NSUInteger count = _secondarySegments.count;
    CGFloat width = _touchLayout ? 80 : 200;
    [_secondaryRow setLayoutBounds:CGRectMake(0, 0, width, 6) forArrangedNode:_secondaryRack];
    [_secondaryRow layout];
    if (!count) return;
    CGFloat gap = MIN(2, width / (count * 8));
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
    if (UISetLabelText(_secondaryLabel, name.length ? name : @"")) [_secondaryRow layout];
}

- (void)updateInstruments:(CockpitFrame)frame contacts:(const CockpitContact *)contacts count:(NSUInteger)count cockpit:(BOOL)cockpit {
    [self layoutIfNeeded];
    [_forwardScope updateFrame:frame contacts:contacts count:count];
    [_rearScope updateFrame:frame contacts:contacts count:count];
    // The chase view leaves the target to its bracket and the scopes; the
    // readout's preview would sit under the ship.
    _targetReadout.hidden = YES;
    _hullBar.hidden = _laserBar.hidden = cockpit;
    _shieldBar.hidden = cockpit || frame.shieldRecharge <= 0;     // a ship with no shield shows none
    [_hullBar setLevel:frame.hull recharge:0 color:frame.hull < 0.3 ? EnemyColor(0.9) : HUDColor(0.8)];
    [_shieldBar setLevel:frame.shield recharge:frame.shieldRecharge color:UIColorWithOpacity(UIShield, 0.85)];
    [_laserBar setLevel:frame.weaponEnergy recharge:frame.weaponRecharge
                  color:frame.weaponEnergy < frame.weaponShotEnergy ? EnemyColor(0.9) : UIColorWithOpacity(UIYellow, 0.85)];
}

- (NSArray<SKNode *> *)conditionRows { return @[_hullBar, _shieldBar, _laserBar, _secondaryRow]; }
- (SKLabelNode *)scoreLabel { return _scoreLabel; }
- (SKNode *)forwardScope { return _forwardScope; }
- (SKNode *)rearScope { return _rearScope; }
- (BOOL)helpVisible { return !_help.hidden; }
- (CGRect)helpRect { return _help.frame; }
- (CGRect)objectivesRect { return _objectivePanel.hidden ? CGRectZero : [_objectivePanel calculateAccumulatedFrame]; }
- (CGRect)messagesRect { return _messagePanel.hidden ? CGRectZero : [_messagePanel calculateAccumulatedFrame]; }

- (void)setInputText:(NSString *)text { _inputLabel.text = @""; }
- (void)toggleHelp {
    [self setHelpVisible:_help.hidden];
}
- (void)setHelpVisible:(BOOL)visible {
    _help.hidden = !visible;
    _objectivePanel.hidden = visible || !_objectivePanel.children.count;
    [self layoutMessages];
}

- (void)setObjectives:(NSArray<NSString *> *)lines states:(NSArray<NSNumber *> *)states {
    if ([_objectives.states isEqualToArray:states] && _objectives.labels.count == lines.count) {
        // A ticking countdown keeps its rows and checkbox paths.
        for (NSUInteger i = 0; i < lines.count; i++) {
            SKLabelNode *label = _objectives.labels[i];
            if ([label.text isEqualToString:lines[i]]) continue;
            UIHorizontalStack *row = _objectives.rows[i];
            CGFloat height = row.contentSize.height;
            UISetLabelText(label, lines[i]);
            [row layout];
            if (fabs(row.contentSize.height - height) > 0.5) _laidOut = CGSizeZero;
        }
        [self layoutIfNeeded];
        return;
    }
    NSMutableArray<SKLabelNode *> *labels = [NSMutableArray array];
    NSMutableArray<UIHorizontalStack *> *rows = [NSMutableArray array];
    [_objectivePanel removeAllChildren];
    _laidOut = CGSizeZero;
    // The border's outside edge matches the capital D, rather than the font's
    // point size. All states share exactly the same square control geometry.
    PlatformFont *font = [PlatformFont fontWithName:UIMonoFont size:14];
    CGFloat side = font.capHeight;
    for (NSUInteger i = 0; i < lines.count; i++) {
        int st = states[i].intValue;
        UIHorizontalStack *row = [UIHorizontalStack node];
        row.spacing = 8;
        [rows addObject:row];
        SKNode *checkbox = [SKNode node];
        SKColor *ink = st == 2 ? EnemyColor(0.95) : HUDColor(0.95);
        const CGFloat border = 1.0;
        SKShapeNode *box = [SKShapeNode shapeNodeWithRect:CGRectMake(border / 2, -side / 2 + border / 2,
                                                                   side - border, side - border)];
        box.strokeColor = ink;
        box.fillColor = SKColor.clearColor;
        box.lineWidth = border;
        [checkbox addChild:box];
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
            [checkbox addChild:mark];
        }
        SKLabelNode *l = Label(14, SKLabelHorizontalAlignmentModeLeft);
        l.numberOfLines = 0;
        l.lineBreakMode = NSLineBreakByWordWrapping;
        l.text = lines[i];
        [labels addObject:l];
        l.fontColor = ink;
        [row addArrangedNode:checkbox layoutBounds:CGRectMake(0, -side / 2, side, side)];
        [row addArrangedNode:l];
        [_objectivePanel addChild:row];
    }
    _objectives = (HUDObjectives){ [states copy], [labels copy], [rows copy] };
    [self layoutIfNeeded];
}

- (void)showMessage:(NSString *)text from:(NSString *)from {
    SKLabelNode *l = Label(15, SKLabelHorizontalAlignmentModeCenter);
    l.text = from.length ? [NSString stringWithFormat:@"%@: %@", [from uppercaseString], text] : text;
    l.fontColor = [SKColor colorWithRed:0.85 green:0.95 blue:1 alpha:1];
    [_messagePanel addChild:l];
    [_messages insertObject:l atIndex:0];
    while (_messages.count > 3) { [_messages.lastObject removeFromParent]; [_messages removeLastObject]; }
    [self layoutIfNeeded];
    [self layoutMessages];
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

// The ship's frame at one ring, mapping metres there to view points.
static CGAffineTransform RingTransform(HUDRing r) {
    return (CGAffineTransform){ r.right.x, r.right.y, r.up.x, r.up.y, r.centre.x, r.centre.y };
}

// The reticle: separate rings of one radius at growing distances along the
// line of fire, so perspective shrinks them toward the aim point and the row
// shows which way the guns point. The nearest ring carries side arcs, the
// farthest the pip.
- (void)drawReticle:(HUDFrame)f hidden:(BOOL)hidden {
    int count = hidden ? 0 : f.reticleRings;
    for (int i = 0; i < HUD_RETICLE_RINGS; i++) {
        SKShapeNode *node = _reticleRings[i];
        node.hidden = i >= count;
        if (node.hidden) continue;
        CGAffineTransform t = RingTransform(f.reticle[i]);
        CGPathRef p = CGPathCreateCopyByTransformingPath(ReticleShape(i == 0, i == count - 1), &t);
        node.path = p;
        CGPathRelease(p);
    }
}

- (void)updateFrame:(HUDFrame)f targets:(const HUDTarget *)targets count:(NSUInteger)count {
    [self layoutIfNeeded];
    CGSize s = self.size;
    CGPoint center = CGPointMake(s.width / 2, s.height / 2);

    BOOL perspective = !f.cockpit && f.reticleRings > 0;
    _boresight.hidden = !f.boresightVisible || f.playerDead || perspective;
    _boresight.position = f.boresight;
    [self drawReticle:f hidden:!perspective || f.playerDead];

    CGFloat ringR = MIN(s.width, s.height) * 0.22;
    _ring.hidden = _cursor.hidden = _cursorLine.hidden = !f.mouseCaptured || f.playerDead;
    _ring.xScale = _ring.yScale = ringR / 100.0;
    CGPoint cur = PointAdd(center, PointScale(f.mouseStick, ringR));
    _cursor.position = cur;
    if (!_cursorLine.hidden) {
        CGMutablePathRef lp = CGPathCreateMutable();
        CGPathMoveToPoint(lp, NULL, center.x, center.y);
        CGPathAddLineToPoint(lp, NULL, cur.x, cur.y);
        _cursorLine.path = lp;
        CGPathRelease(lp);
    }

    SetBar(_throttleFill, 12, 214 * MIN(f.throttle, 1.0f));
    _throttleFill.position = CGPointMake(3, 3);
    _throttleFill.fillColor = f.boosting ? UIColorWithOpacity(UIBoost, 0.9) : HUDColor(0.75);
    SetBar(_boostFill, 3, 214 * f.boostEnergy);
    _boostFill.position = CGPointMake(-7, 3);
    UISetLabelText(_throttleLabel, L10nFormat(f.boosting ? @"hud.throttle_boost" : @"hud.throttle", (int)lroundf(f.throttle * 100)));
    UISetLabelText(_speedLabel, L10nFormat(@"hud.speed", (int)lroundf(f.speed)));
    UISetLabelText(_scoreLabel, L10nFormat(@"hud.score", f.kills, f.deaths));
    UISetLabelText(_deadLabel, L10n(f.respawning ? @"hud.destroyed" : @"hud.destroyed_campaign"));
    for (SKNode *n in @[_throttleFrame, _throttleLabel, _speedLabel, _scoreLabel, _secondaryRow])
        n.hidden = f.cockpit;
    _scoreLabel.hidden = !f.respawning || !_help.hidden;
    _scoreLabel.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeLeft;
    _scoreLabel.fontSize = MIN(s.width, s.height) < 550 ? 12 : 16;
    _scoreLabel.position = PointAdd(_objectivePanel.position, CGPointMake(0, -20));
    BOOL objectivesWereHidden = _objectivePanel.hidden;
    _objectivePanel.hidden = f.respawning || !_help.hidden || !_objectivePanel.children.count;
    if (objectivesWereHidden != _objectivePanel.hidden) [self layoutMessages];
    if (_touchLayout) _throttleFrame.hidden = _throttleLabel.hidden = _speedLabel.hidden = YES;
    _thrustBar.hidden = f.cockpit || !_touchLayout;
    [_thrustBar setLevel:f.throttle recharge:0
                   color:f.boosting ? UIColorWithOpacity(UIBoost, 0.9) : HUDColor(0.75)];
    [self updateSecondary:f.secondary capacity:f.secondaryCapacity name:f.secondaryName];
    _aimMark.hidden = !f.aimVisible || f.playerDead;
    _aimMark.position = f.aim;
    _aimMark.zRotation = 0.0;
    UISetLabelText(_statusLabel, f.status ?: @"");
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
        b.lineWidth = t.selected ? 1 : 1.5;
        b.zPosition = a.zPosition = l.zPosition = t.selected ? 20 : 0;
        a.fillColor = t.selected ? c : KindColor(t.kind, 0.7);
        a.strokeColor = t.selected ? [SKColor colorWithWhite:0 alpha:0.9] : SKColor.clearColor;
        a.lineWidth = t.selected ? 2 : 0;
        [a setScale:t.selected ? 1.4 : 1];
        l.strokeColor = t.selected ? c : EnemyColor(0.8);
        [l setScale:t.selected ? 1.35 : 1];
        // The stroke scales with the node: the selection's stays 1 pt.
        l.lineWidth = t.selected ? 1 / l.xScale : 1.5;
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
            NSString *dist = t.distance >= 1000 ? L10nFormat(@"units.km1_short", t.distance / 1000.0)
                                                : L10nFormat(@"units.m_short", (int)t.distance);
            BOOL named = t.label && (t.selected || t.capital || nav);
            NSString *text = named ? [NSString stringWithFormat:@"%@ %@", t.label, dist] : dist;
            UISetLabelText(d, t.selected ? L10nFormat(@"hud.target_prefix", text) : text);
            CGFloat half = nav ? 12 : (t.selected ? MAX(44, t.size) : t.size) * 0.5;
            d.position = PointAdd(t.point, CGPointMake(half + 6, half + (t.selected ? 10 : -4)));
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
                _selectedLeadOutline.lineWidth = 3 / l.xScale;
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
