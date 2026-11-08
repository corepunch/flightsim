#import "UI.h"
#import "Shared.h"
#import "Audio.h"
#import "Common.h"
#import "Render.h"

static SKLabelNode *Text(CGFloat size, SKColor *c, SKLabelHorizontalAlignmentMode h) {
    return UIInterfaceLabel(size, c, h, SKLabelVerticalAlignmentModeBaseline);
}

// Gameplay tips where the locale has them; otherwise one generic line.
static NSArray<NSString *> *Tips(InputGuide *guide) {
    // The generic tip is input-neutral; device-specific bindings live in the
    // guide instead of rotating keyboard advice onto a phone or a gamepad.
    if (guide && guide.scheme != InputSchemeKeyboard) return L10nList(@"loading.mission_tip");
    return L10nHasOwn(@"loading.tips") ? L10nList(@"loading.tips") : L10nList(@"loading.mission_tip");
}

@implementation Loading {
    SKNode *_root;
    SKNode *_progressContent, *_readyContent;
    InputGuide *_guideSnapshot;
    ScreenInsets _usedInsets;
    CGSize _laidOut;
    NSString *_title, *_kicker, *_detail, *_status;
    SKLabelNode *_titleLabel, *_kickerLabel, *_detailLabel, *_statusLabel, *_percentLabel, *_tipLabel;
    SKShapeNode *_barFill;
    SKNode *_spinner;
    SKLabelNode *_startLabel;
    SKTexture *_hangarTexture;
    BOOL _readyToStart, _startRequested;
    BOOL _armed;    // a press began while the card was ready to start
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
        self.backgroundColor = [SKColor clearColor];
        _root = [SKNode node];
        [self addChild:_root];
        _stars = [NSMutableArray array];
        _tip = arc4random_uniform((uint32_t)Tips(self.input.controlGuide).count);
        _title = _kicker = _detail = @"";
        _status = L10n(@"loading.loading_mission");
    }
    return self;
}

// The hangar art is a full-screen image; the card keeps it only while it is
// on screen and decodes it again the next time it is shown.
- (SKTexture *)hangarTexture {
    if (!_hangarTexture) {
        NSURL *hangar = FSURL(@"Menu", @"loading", @"png");
        PlatformImage *image = hangar ? [[PlatformImage alloc] initWithContentsOfFile:hangar.path] : nil;
        if (image) _hangarTexture = [SKTexture textureWithImage:image];
    }
    return _hangarTexture;
}

- (void)unload {
    [_root removeAllChildren];
    [_stars removeAllObjects];
    _laidOut = CGSizeZero;
    _hangarTexture = nil;
}

- (void)showTitle:(NSString *)title kicker:(NSString *)kicker detail:(NSString *)detail {
    _title = [title.uppercaseString copy] ?: @"";
    _kicker = [kicker copy] ?: @"";
    _detail = [detail copy] ?: @"";
    _status = L10n(@"loading.loading_mission");
    self.readyToStart = NO;
    _target = _shown = 0;
    _fadeRequested = NO;
    _fadeStart = _fadeLength = 0;
    _root.alpha = 1;
    _tip = (_tip + 1) % Tips(self.input.controlGuide).count;
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
- (BOOL)readyToStart { return _readyToStart; }

- (void)setReadyToStart:(BOOL)ready {
    if (ready && !_readyToStart) [[GameAudio shared] play:@"ui-confirm" gain:0.65f pan:0];
    _startRequested = NO;
    _armed = NO;
    _readyToStart = ready;
    [self layout];
}

static BOOL Inside(CGPoint fraction) {
    return fraction.x >= 0 && fraction.x <= 1 && fraction.y >= 0 && fraction.y <= 1;
}

// Only a press that begins once the card is ready starts the mission: a touch
// held through loading must not.
- (void)pointerDown:(CGPoint)at { _armed = _readyToStart && Inside(at); }

- (void)pointerClick:(CGPoint)at {
    if (_armed && _readyToStart && Inside(at)) _startRequested = YES;
    _armed = NO;
}

- (BOOL)consumeStartRequest {
    BOOL requested = _startRequested;
    _startRequested = NO;
    return requested;
}
- (BOOL)fading { return _fadeRequested; }
- (BOOL)faded { return _fadeRequested && _fadeStart >= 0 && _now - _fadeStart >= _fadeLength; }

- (void)fadeOut:(double)seconds {
    if (_fadeRequested) return;
    self.readyToStart = NO;
    _fadeRequested = YES;
    _fadeLength = fmax(seconds, 0.01);
    _fadeStart = -1;   // stamped at the next tick, on the render clock
}

#pragma mark - Layout

- (SKNode *)motionBackdropWithSize:(CGSize)s {
    SKNode *backdrop = [SKNode node];
    SKSpriteNode *bg = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIBackground, 1) size:s];
    bg.anchorPoint = CGPointZero;
    [backdrop addChild:bg];

    SKTexture *hangar = self.hangarTexture;
    if (hangar) {
        SKSpriteNode *art = [SKSpriteNode spriteNodeWithTexture:hangar];
        CGSize image = hangar.size;
        CGFloat scale = MAX(s.width / MAX(image.width, 1), s.height / MAX(image.height, 1));
        art.size = CGSizeMake(image.width * scale, image.height * scale);
        art.position = CGPointMake(s.width * 0.5, s.height * 0.5);
        [backdrop addChild:art];
        SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:[SKColor colorWithWhite:0 alpha:0.55] size:s];
        shade.anchorPoint = CGPointZero;
        [backdrop addChild:shade];
    }
    return backdrop;
}

- (void)layout {
    [_root removeAllChildren];
    [_stars removeAllObjects];
    CGSize s = self.size;
    _laidOut = s;
    _usedInsets = self.contentInsets;
    _guideSnapshot = self.input.controlGuide;
    _tip %= Tips(_guideSnapshot).count;
    [_root addChild:[self motionBackdropWithSize:s]];

    SKTexture *hangar = self.hangarTexture;
    if (hangar) {
        SKSpriteNode *art = [SKSpriteNode spriteNodeWithTexture:hangar];
        CGSize image = hangar.size;
        CGFloat scale = MAX(s.width / MAX(image.width, 1), s.height / MAX(image.height, 1));
        art.size = CGSizeMake(image.width * scale, image.height * scale);
        art.position = CGPointMake(s.width * 0.5, s.height * 0.5);
        [_root addChild:art];
        SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:[SKColor colorWithWhite:0 alpha:0.55] size:s];
        shade.anchorPoint = CGPointZero;
        [_root addChild:shade];
    }

    // A slow parallax star drift: bigger stars are "nearer" and move faster.
    srand48(4242);
    for (int i = 0; i < (hangar ? 0 : 220); i++) {
        CGFloat z = drand48();
        CGFloat r = 0.6 + z * z * 1.8;
        SKSpriteNode *st = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIWhite, 1) size:CGSizeMake(r, r)];
        st.alpha = 0.15 + z * 0.6;
        st.position = CGPointMake(drand48() * s.width, drand48() * s.height);
        st.userData = [NSMutableDictionary dictionaryWithDictionary:@{ @"z": @(z), @"phase": @(drand48() * 6.28) }];
        [_root addChild:st];
        [_stars addObject:st];
    }

    // Faint horizon band and scan rules, the same language as the briefing map.
    SKSpriteNode *band = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.035) size:CGSizeMake(s.width, s.height * 0.34)];
    band.anchorPoint = CGPointZero;
    band.position = CGPointMake(0, s.height * 0.36);
    [_root addChild:band];
    for (int i = 0; i < 2; i++) {
        SKSpriteNode *rule = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.25) size:CGSizeMake(s.width - 120, 1)];
        rule.anchorPoint = CGPointZero;
        rule.position = CGPointMake(60, s.height * (i ? 0.70 : 0.36));
        [_root addChild:rule];
    }

    ScreenInsets safe = self.contentInsets;
    CGFloat x = MAX(MIN(60, s.width * 0.08), safe.left + 18), mid = MAX(250, s.height * 0.57);
    _kickerLabel = Text(15, UIColorWithOpacity(UIInk, 0.6), SKLabelHorizontalAlignmentModeLeft);
    _kickerLabel.text = _kicker;
    _kickerLabel.position = CGPointMake(x, mid + 52);
    [_root addChild:_kickerLabel];

    _titleLabel = Text(MIN(48, s.width / 22), UIColorWithOpacity(UIInk, 1), SKLabelHorizontalAlignmentModeLeft);
    _titleLabel.fontName = UIInterfaceBoldFont;
    _titleLabel.text = _title;
    _titleLabel.position = CGPointMake(x, mid);
    [_root addChild:_titleLabel];

    _detailLabel = Text(15, UIColorWithOpacity(UIAmber, 0.85), SKLabelHorizontalAlignmentModeLeft);
    _detailLabel.text = _detail;
    _detailLabel.position = CGPointMake(x, mid - 36);
    [_root addChild:_detailLabel];

    // Progress bar along the bottom.
    _progressContent = [SKNode node];
    _progressContent.hidden = self.readyToStart;
    [_root addChild:_progressContent];
    _barWidth = MAX(1, MIN(720, s.width - 2 * x - 80));
    CGFloat barY = 104;
    [_progressContent addChild:UISkewedShape(CGRectMake(x - 3, barY - 3, _barWidth + 6, 12),
                                    UIColorWithOpacity(UIInk, 0.45), UIColorWithOpacity(UIInk, 0.05))];
    _barFill = [SKShapeNode node];
    _barFill.lineWidth = 0;
    _barFill.fillColor = UIColorWithOpacity(UIInk, 0.9);
    _barFill.position = CGPointMake(x, barY);
    [_progressContent addChild:_barFill];
    for (int i = 1; i < 10; i++) {   // tick marks every 10%
        SKSpriteNode *t = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.3) size:CGSizeMake(1, 4)];
        t.position = CGPointMake(x + _barWidth * i / 10.0, barY - 7);
        [_progressContent addChild:t];
    }

    _statusLabel = Text(13, UIColorWithOpacity(UIInk, 0.75), SKLabelHorizontalAlignmentModeLeft);
    _statusLabel.text = _status;
    _statusLabel.position = CGPointMake(x, barY + 20);
    _statusLabel.fontName = UIBodyFont;
    _statusLabel.numberOfLines = 2;
    _statusLabel.preferredMaxLayoutWidth = MAX(1, _barWidth - 64);
    if (L10nIsRightToLeft()) {
        _statusLabel.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
        _statusLabel.position = CGPointMake(x + _barWidth - 64, barY + 20);
    }
    [_progressContent addChild:_statusLabel];
    _percentLabel = Text(13, UIColorWithOpacity(UIInk, 0.75), SKLabelHorizontalAlignmentModeRight);
    _percentLabel.position = CGPointMake(x + _barWidth, barY + 20);
    [_progressContent addChild:_percentLabel];

    _tipLabel = Text(13, UIColorWithOpacity(UIInk, 0.45), SKLabelHorizontalAlignmentModeLeft);
    _tipLabel.numberOfLines = 0;
    _tipLabel.preferredMaxLayoutWidth = _barWidth;
    _tipLabel.verticalAlignmentMode = SKLabelVerticalAlignmentModeTop;
    _tipLabel.position = CGPointMake(x, barY - 22);
    _tipLabel.fontName = UIBodyFont;
    _tipLabel.text = Tips(self.input.controlGuide)[_tip];
    if (L10nIsRightToLeft()) {
        _tipLabel.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
        _tipLabel.position = CGPointMake(x + _barWidth, barY - 22);
    }
    [_progressContent addChild:_tipLabel];

    // Three-segment ring that spins while work is in flight.
    _spinner = [SKNode node];
    _spinner.position = CGPointMake(s.width - 90, barY + 4);
    for (int i = 0; i < 3; i++) {
        CGMutablePathRef p = CGPathCreateMutable();
        CGFloat a0 = i * 2 * M_PI / 3;
        CGPathAddArc(p, NULL, 0, 0, 22, a0, a0 + 1.4, false);
        SKShapeNode *arc = [SKShapeNode shapeNodeWithPath:p];
        CGPathRelease(p);
        arc.strokeColor = i == 0 ? UIColorWithOpacity(UIAmber, 0.9) : UIColorWithOpacity(UIInk, 0.7);
        arc.lineWidth = 2.5;
        arc.lineCap = kCGLineCapRound;
        [_spinner addChild:arc];
    }
    SKShapeNode *inner = [SKShapeNode shapeNodeWithCircleOfRadius:12];
    inner.strokeColor = UIColorWithOpacity(UIInk, 0.25);
    inner.lineWidth = 1;
    [_spinner addChild:inner];
    [_progressContent addChild:_spinner];

    _readyContent = [SKNode node];
    _readyContent.hidden = !self.readyToStart;
    [_root addChild:_readyContent];
    if (self.readyToStart && _guideSnapshot) {
        CGFloat width = MAX(1, MIN(980, s.width - x - MAX(x, safe.right + 18)));
        UIControlGuide *guide = [[UIControlGuide alloc] initWithGuide:_guideSnapshot width:width compact:YES];
        UIHorizontalStack *prompt = [UIHorizontalStack new];
        prompt.spacing = 12;
        prompt.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeCenter;
        prompt.maximumWidth = width;
        [prompt addArrangedNode:UIInputGlyph(_guideSnapshot.confirmSymbol, _guideSnapshot.confirmText, 25)];
        _startLabel = Text(16, UIColorWithOpacity(UIAmber, 1), SKLabelHorizontalAlignmentModeLeft);
        _startLabel.fontName = UIBodyFont;
        _startLabel.numberOfLines = 0;
        _startLabel.text = L10n(@"loading.continue_prompt");
        [prompt addArrangedNode:_startLabel];
        [prompt layout];
        CGFloat bottom = safe.bottom + 18;
        prompt.position = CGPointMake(x + width / 2, bottom + prompt.contentSize.height / 2);
        CGFloat guideBottom = bottom + prompt.contentSize.height + 20;
        guide.position = CGPointMake(x, guideBottom + guide.height);
        [_readyContent addChild:guide];
        [_readyContent addChild:prompt];
    }

    [self applyProgress];
}

- (void)applyProgress {
    _barFill.hidden = _shown <= 0;
    UISetSkewedBar(_barFill, _barWidth * _shown, 6);
    _percentLabel.text = [NSString stringWithFormat:@"%3d%%", (int)roundf(_shown * 100)];
}

#pragma mark - Animation

- (void)tick:(double)time {
    double dt = _lastTick > 0 ? fmin(time - _lastTick, 0.1) : 1.0 / 60.0;
    _lastTick = time;
    _now = time;
    if (!CGSizeEqualToSize(self.size, _laidOut) || memcmp(&_usedInsets, &_contentInsets, sizeof _usedInsets) ||
        _guideSnapshot != self.input.controlGuide) [self layout];

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
        _tip = (_tip + 1) % Tips(self.input.controlGuide).count;
        _tipLabel.text = Tips(self.input.controlGuide)[_tip];
    }

    if (_fadeRequested) {
        if (_fadeStart < 0) _fadeStart = time;
        double k = fmin(1, (time - _fadeStart) / _fadeLength);
        _root.alpha = 1 - k * k * (3 - 2 * k);
        if (k >= 1 && _root.children.count) [self unload];
    }
}

@end
