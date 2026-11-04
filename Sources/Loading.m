#import "Loading.h"

static NSColor *Ink(CGFloat a) { return [NSColor colorWithRed:0.55 green:0.95 blue:0.85 alpha:a]; }
static NSColor *Amber(CGFloat a) { return [NSColor colorWithRed:1.0 green:0.72 blue:0.3 alpha:a]; }

static SKLabelNode *Text(CGFloat size, NSColor *c, SKLabelHorizontalAlignmentMode h) {
    SKLabelNode *l = [SKLabelNode labelNodeWithFontNamed:@"Menlo"];
    l.fontSize = size;
    l.fontColor = c;
    l.horizontalAlignmentMode = h;
    l.verticalAlignmentMode = SKLabelVerticalAlignmentModeBaseline;
    return l;
}

static NSArray<NSString *> *Tips(void) {
    return @[
        @"Hold SHIFT or TAB to boost. Boost energy recharges while you cruise.",
        @"T cycles targets. The lead marker shows where to shoot, not where the target is.",
        @"G launches a torpedo at the selected target. Aim at a subsystem to cripple a capital ship.",
        @"Knock out shield generators first: a shielded capital ship shrugs off torpedoes.",
        @"Z sets full throttle, X cuts it. Slow down to turn tighter in a dogfight.",
        @"C switches between the cockpit and the chase camera.",
        @"Click to capture the mouse for flying; right-click recentres the virtual stick.",
        @"Q and E roll. Rolling onto a target before pulling up keeps it in front of you.",
        @"R restarts the mission. H or F1 shows the controls at any time.",
        @"Mines drift toward anything that comes close. Shoot them from range.",
    ];
}

@implementation Loading {
    SKNode *_root;
    CGSize _laidOut;
    NSString *_title, *_kicker, *_detail, *_status;
    SKLabelNode *_titleLabel, *_kickerLabel, *_detailLabel, *_statusLabel, *_percentLabel, *_tipLabel;
    SKSpriteNode *_barFill;
    SKNode *_spinner;
    NSMutableArray<SKSpriteNode *> *_stars;
    CGFloat _barWidth;
    float _target, _shown;
    double _now, _lastTick, _tipChanged, _fadeStart, _fadeLength;
    NSUInteger _tip;
    BOOL _fadeRequested;
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.backgroundColor = [NSColor clearColor];
        _root = [SKNode node];
        [self addChild:_root];
        _stars = [NSMutableArray array];
        _tip = arc4random_uniform((uint32_t)Tips().count);
        _title = _kicker = _detail = @"";
        _status = @"LOADING";
    }
    return self;
}

- (void)showTitle:(NSString *)title kicker:(NSString *)kicker detail:(NSString *)detail {
    _title = [title.uppercaseString copy] ?: @"";
    _kicker = [kicker copy] ?: @"";
    _detail = [detail copy] ?: @"";
    _status = @"LOADING";
    _target = _shown = 0;
    _fadeRequested = NO;
    _fadeStart = _fadeLength = 0;
    _root.alpha = 1;
    _tip = (_tip + 1) % Tips().count;
    _tipChanged = _now;
    [self layout];
}

- (void)setProgress:(float)progress status:(NSString *)status {
    _target = fmaxf(_target, fminf(fmaxf(progress, 0), 1));
    if (status && ![status isEqualToString:_status]) {
        _status = [status copy];
        _statusLabel.text = _status;
    }
}

- (BOOL)barFull { return _shown > 0.995f; }
- (BOOL)fading { return _fadeRequested; }
- (BOOL)faded { return _fadeRequested && _fadeStart >= 0 && _now - _fadeStart >= _fadeLength; }

- (void)fadeOut:(double)seconds {
    if (_fadeRequested) return;
    _fadeRequested = YES;
    _fadeLength = fmax(seconds, 0.01);
    _fadeStart = -1;   // stamped at the next tick, on the render clock
}

#pragma mark - Layout

- (void)layout {
    [_root removeAllChildren];
    [_stars removeAllObjects];
    CGSize s = self.size;
    _laidOut = s;

    SKSpriteNode *bg = [SKSpriteNode spriteNodeWithColor:[NSColor colorWithRed:0.012 green:0.018 blue:0.028 alpha:1] size:s];
    bg.anchorPoint = CGPointZero;
    [_root addChild:bg];

    // A slow parallax star drift: bigger stars are "nearer" and move faster.
    srand48(4242);
    for (int i = 0; i < 220; i++) {
        CGFloat z = drand48();
        CGFloat r = 0.6 + z * z * 1.8;
        SKSpriteNode *st = [SKSpriteNode spriteNodeWithColor:[NSColor colorWithWhite:1 alpha:1] size:CGSizeMake(r, r)];
        st.alpha = 0.15 + z * 0.6;
        st.position = CGPointMake(drand48() * s.width, drand48() * s.height);
        st.userData = [NSMutableDictionary dictionaryWithDictionary:@{ @"z": @(z), @"phase": @(drand48() * 6.28) }];
        [_root addChild:st];
        [_stars addObject:st];
    }

    // Faint horizon band and scan rules, the same language as the briefing map.
    SKSpriteNode *band = [SKSpriteNode spriteNodeWithColor:Ink(0.035) size:CGSizeMake(s.width, s.height * 0.34)];
    band.anchorPoint = CGPointZero;
    band.position = CGPointMake(0, s.height * 0.36);
    [_root addChild:band];
    for (int i = 0; i < 2; i++) {
        SKSpriteNode *rule = [SKSpriteNode spriteNodeWithColor:Ink(0.25) size:CGSizeMake(s.width - 120, 1)];
        rule.anchorPoint = CGPointZero;
        rule.position = CGPointMake(60, s.height * (i ? 0.70 : 0.36));
        [_root addChild:rule];
    }

    CGFloat x = 60, mid = s.height * 0.53;
    _kickerLabel = Text(15, Ink(0.6), SKLabelHorizontalAlignmentModeLeft);
    _kickerLabel.text = _kicker;
    _kickerLabel.position = CGPointMake(x, mid + 52);
    [_root addChild:_kickerLabel];

    _titleLabel = Text(MIN(48, s.width / 22), Ink(1), SKLabelHorizontalAlignmentModeLeft);
    _titleLabel.fontName = @"Menlo-Bold";
    _titleLabel.text = _title;
    _titleLabel.position = CGPointMake(x, mid);
    [_root addChild:_titleLabel];

    _detailLabel = Text(15, Amber(0.85), SKLabelHorizontalAlignmentModeLeft);
    _detailLabel.text = _detail;
    _detailLabel.position = CGPointMake(x, mid - 36);
    [_root addChild:_detailLabel];

    // Progress bar along the bottom.
    _barWidth = MIN(720, s.width - 220);
    CGFloat barY = 104;
    SKShapeNode *frame = [SKShapeNode shapeNodeWithRect:CGRectMake(x - 3, barY - 3, _barWidth + 6, 12) cornerRadius:2];
    frame.strokeColor = Ink(0.45);
    frame.fillColor = Ink(0.05);
    frame.lineWidth = 1;
    [_root addChild:frame];
    _barFill = [SKSpriteNode spriteNodeWithColor:Ink(0.9) size:CGSizeMake(1, 6)];
    _barFill.anchorPoint = CGPointZero;
    _barFill.position = CGPointMake(x, barY);
    [_root addChild:_barFill];
    for (int i = 1; i < 10; i++) {   // tick marks every 10%
        SKSpriteNode *t = [SKSpriteNode spriteNodeWithColor:Ink(0.3) size:CGSizeMake(1, 4)];
        t.position = CGPointMake(x + _barWidth * i / 10.0, barY - 7);
        [_root addChild:t];
    }

    _statusLabel = Text(13, Ink(0.75), SKLabelHorizontalAlignmentModeLeft);
    _statusLabel.text = _status;
    _statusLabel.position = CGPointMake(x, barY + 20);
    [_root addChild:_statusLabel];
    _percentLabel = Text(13, Ink(0.75), SKLabelHorizontalAlignmentModeRight);
    _percentLabel.position = CGPointMake(x + _barWidth, barY + 20);
    [_root addChild:_percentLabel];

    _tipLabel = Text(13, Ink(0.45), SKLabelHorizontalAlignmentModeLeft);
    _tipLabel.numberOfLines = 0;
    _tipLabel.preferredMaxLayoutWidth = _barWidth;
    _tipLabel.verticalAlignmentMode = SKLabelVerticalAlignmentModeTop;
    _tipLabel.position = CGPointMake(x, barY - 22);
    _tipLabel.text = [@"TIP  /  " stringByAppendingString:Tips()[_tip]];
    [_root addChild:_tipLabel];

    // Three-segment ring that spins while work is in flight.
    _spinner = [SKNode node];
    _spinner.position = CGPointMake(s.width - 90, barY + 4);
    for (int i = 0; i < 3; i++) {
        CGMutablePathRef p = CGPathCreateMutable();
        CGFloat a0 = i * 2 * M_PI / 3;
        CGPathAddArc(p, NULL, 0, 0, 22, a0, a0 + 1.4, false);
        SKShapeNode *arc = [SKShapeNode shapeNodeWithPath:p];
        CGPathRelease(p);
        arc.strokeColor = i == 0 ? Amber(0.9) : Ink(0.7);
        arc.lineWidth = 2.5;
        arc.lineCap = kCGLineCapRound;
        [_spinner addChild:arc];
    }
    SKShapeNode *inner = [SKShapeNode shapeNodeWithCircleOfRadius:12];
    inner.strokeColor = Ink(0.25);
    inner.lineWidth = 1;
    [_spinner addChild:inner];
    [_root addChild:_spinner];

    [self applyProgress];
}

- (void)applyProgress {
    _barFill.size = CGSizeMake(fmax(1, _barWidth * _shown), 6);
    _percentLabel.text = [NSString stringWithFormat:@"%3d%%", (int)roundf(_shown * 100)];
}

#pragma mark - Animation

- (void)tick:(double)time {
    double dt = _lastTick > 0 ? fmin(time - _lastTick, 0.1) : 1.0 / 60.0;
    _lastTick = time;
    _now = time;
    if (!CGSizeEqualToSize(self.size, _laidOut)) [self layout];

    // Ease toward the reported progress; never stall completely so the bar
    // always reads as alive, but never run past the real value.
    float gap = _target - _shown;
    _shown = gap < 0.002f ? _target : _shown + gap * (float)fmin(1, dt * 7) + (float)dt * 0.02f;
    _shown = fminf(_shown, _target);
    [self applyProgress];

    _spinner.zRotation = -time * 3.2;
    _spinner.alpha = _target >= 1 ? 0.35 : 1;

    CGSize s = self.size;
    for (SKSpriteNode *st in _stars) {
        double z = [st.userData[@"z"] doubleValue], ph = [st.userData[@"phase"] doubleValue];
        CGPoint p = st.position;
        p.x -= dt * (4 + z * z * 26);
        if (p.x < -2) p.x += s.width + 4;
        st.position = p;
        st.alpha = (0.15 + z * 0.6) * (0.75 + 0.25 * sin(time * (0.8 + z * 2) + ph));
    }

    if (time - _tipChanged > 6.5) {
        _tipChanged = time;
        _tip = (_tip + 1) % Tips().count;
        _tipLabel.text = [@"TIP  /  " stringByAppendingString:Tips()[_tip]];
    }

    if (_fadeRequested) {
        if (_fadeStart < 0) _fadeStart = time;
        double k = fmin(1, (time - _fadeStart) / _fadeLength);
        _root.alpha = 1 - k * k * (3 - 2 * k);
    }
}

@end
