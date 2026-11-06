#import "UI.h"

static const CGFloat ThrottleHeight = 136, ThrottleTravel = 112;
static const CGFloat StickRadius = 66, StickTravel = 132;

static CGPoint PauseCenter(CGSize size, ScreenInsets insets) {
    CGFloat scannerScale = size.height < 550 ? 0.56 : 0.86;
    return CGPointMake(size.width - insets.right - 12 - 128 * scannerScale - 54, insets.top + 30);
}

static SKShapeNode *Circle(CGFloat radius, UIRGB accent, CGFloat stroke, CGFloat fill) {
    SKShapeNode *node = [SKShapeNode shapeNodeWithCircleOfRadius:radius];
    node.strokeColor = UIColorWithOpacity(accent, stroke);
    node.fillColor = UIColorWithOpacity(UIPanel, fill);
    node.lineWidth = 1.5;
    return node;
}

static SKShapeNode *RoundedRect(CGFloat width, CGFloat height, CGFloat radius) {
    return [SKShapeNode shapeNodeWithRectOfSize:CGSizeMake(width, height) cornerRadius:radius];
}

static SKLabelNode *ControlLabel(NSString *text, CGFloat size, UIRGB accent) {
    SKLabelNode *label = UIMonoLabel(size, UIColorWithOpacity(accent, 1),
                                   SKLabelHorizontalAlignmentModeCenter, SKLabelVerticalAlignmentModeCenter);
    label.fontName = UIMonoBoldFont;
    label.text = text;
    return label;
}

static void ButtonTitle(SKLabelNode *label, NSString *text, CGFloat radius) {
    label.numberOfLines=0;
    label.preferredMaxLayoutWidth=radius*2-12;
    label.lineBreakMode=NSLineBreakByWordWrapping;
    UIFitMultilineButtonLabel(label,text,2,radius*1.5);
    UICenterLabelVertically(label,0);
}

@implementation UITouchControls {
    SKShapeNode *_stickKnob, *_stickTether, *_throttleFill, *_throttleThumb;
    SKShapeNode *_faces[TouchControlCount];
    CGPoint _centers[TouchControlCount];
    CGFloat _radii[TouchControlCount];
    SKLabelNode *_secondaryLabel;
}

+ (CGRect)pauseRectForSize:(CGSize)size insets:(ScreenInsets)insets {
    CGPoint center = PauseCenter(size,insets);
    center = CGPointMake(center.x,size.height-center.y);
    return CGRectInset((CGRect){center,CGSizeZero},-46,-22);
}

- (NSDictionary<NSNumber *,SKLabelNode *> *)buttonLabels {
    NSMutableDictionary *labels=[NSMutableDictionary dictionary];
    for (TouchControl control=TouchControlFire;control<TouchControlCount;control++)
        for (SKNode *child in _faces[control].children) if ([child isKindOfClass:SKLabelNode.class])
            labels[@(control)]=(SKLabelNode *)child;
    return labels;
}
- (instancetype)init {
    if ((self = [super init])) {
        self.name = @"Touch flight controls";
        self.zPosition = 100;
        [self buildArt];
    }
    return self;
}
- (void)addButton:(TouchControl)control title:(NSString *)title radius:(CGFloat)radius accent:(UIRGB)accent {
    _radii[control] = radius;
    SKShapeNode *face = Circle(radius, accent, 0.83, 0.8);
    [face addChild:Circle(radius - 5, accent, 0.23, 0)];
    SKLabelNode *label = ControlLabel(title, control == TouchControlFire ? 14 : 11, accent);
    ButtonTitle(label,title,radius);
    [face addChild:label];
    if (control == TouchControlSecondary) _secondaryLabel = label;
    _faces[control] = face;
    [self addChild:face];
}

- (void)setSecondaryLabel:(NSString *)label {
    ButtonTitle(_secondaryLabel,label.length ? label : L10n(@"touch.fire2"),_radii[TouchControlSecondary]);
}

- (void)buildArt {
    _radii[TouchControlStick] = StickRadius;
    _faces[TouchControlStick] = Circle(StickRadius, UIInk, 0.62, 0.6);
    [_faces[TouchControlStick] addChild:Circle(49, UIInk, 0.24, 0)];
    _stickTether = [SKShapeNode node];
    _stickTether.strokeColor = UIColorWithOpacity(UIInk, 0.58);
    _stickTether.lineWidth = 1.5;
    _stickTether.hidden = YES;
    [_faces[TouchControlStick] addChild:_stickTether];
    _stickKnob = Circle(24, UIInk, 0.9, 0.96);
    [_stickKnob addChild:Circle(17, UIInk, 0.32, 0)];
    [_faces[TouchControlStick] addChild:_stickKnob];
    [self addChild:_faces[TouchControlStick]];

    SKShapeNode *throttle = RoundedRect(40, ThrottleHeight, 13);
    throttle.strokeColor = UIColorWithOpacity(UIInk, 0.48);
    throttle.fillColor = UIColorWithOpacity(UIPanel, 0.8);
    for (NSInteger i = 0; i <= 4; i++) {
        SKShapeNode *tick = RoundedRect(i % 2 == 0 ? 24 : 17, 1, 0);
        tick.fillColor = UIColorWithOpacity(UIInk, 0.36);
        tick.strokeColor = SKColor.clearColor;
        tick.position = CGPointMake(0, (i / 4.0 - 0.5) * ThrottleTravel);
        [throttle addChild:tick];
    }
    _throttleFill = [SKShapeNode node];
    _throttleFill.fillColor = UIColorWithOpacity(UIInk, 0.75);
    _throttleFill.strokeColor = SKColor.clearColor;
    [throttle addChild:_throttleFill];
    _throttleThumb = RoundedRect(29, 12, 4);
    _throttleThumb.strokeColor = UIColorWithOpacity(UIInk, 0.9);
    _throttleThumb.fillColor = UIColorWithOpacity(UIInk, 0.28);
    [throttle addChild:_throttleThumb];
    SKLabelNode *label = ControlLabel(L10n(@"touch.throttle"), 11, UIInk);
    label.position = CGPointMake(0, ThrottleHeight / 2 + 13);
    [throttle addChild:label];
    _faces[TouchControlThrottle] = throttle;
    [self addChild:throttle];

    [self addButton:TouchControlFire title:L10n(@"touch.fire") radius:35 accent:UIInk];
    [self addButton:TouchControlSecondary title:L10n(@"touch.fire2") radius:28 accent:UIAmber];
    [self addButton:TouchControlTarget title:L10n(@"touch.target") radius:28 accent:UIInk];
    _faces[TouchControlPause] = UIActionButton(CGRectMake(-46, -22, 92, 44), L10n(@"touch.pause"), UIInk);
    [self addChild:_faces[TouchControlPause]];
}

- (void)layoutWithSize:(CGSize)size insets:(ScreenInsets)insets {
    CGRect bounds = RectWithSize(size);
    CGRect safe = RectInsetEdges(bounds, insets.left, insets.bottom, insets.right, insets.top);
    CGFloat left = CGRectGetMinX(safe) + 12, right = CGRectGetMaxX(safe) - 12;
    // Use the full viewport midpoint; the home indicator only insets one edge.
    CGFloat centerY = CGRectGetMidY(bounds);
    // Keep full leftward travel reachable on screens without a side inset.
    CGFloat stickX = MAX(left + StickRadius, CGRectGetMinX(bounds) + StickTravel);
    _centers[TouchControlStick] = CGPointMake(stickX, centerY);
    _centers[TouchControlThrottle] = CGPointMake(right - 147, centerY);
    _centers[TouchControlFire] = CGPointMake(right - 35, centerY);
    _centers[TouchControlSecondary] = CGPointMake(right - 85, centerY - 53);
    _centers[TouchControlTarget] = CGPointMake(right - 85, centerY + 53);
    // Keep the pause button beside the rear scanner, which occupies the
    // upper-right corner at the same height as the forward scanner.
    _centers[TouchControlPause] = PauseCenter(size,insets);
    for (TouchControl control = 0; control < TouchControlCount; control++) {
        CGPoint center = _centers[control];
        _faces[control].position = CGPointMake(center.x, CGRectGetHeight(bounds) - center.y);
    }
}

- (TouchControl)controlAt:(CGPoint)point {
    for (TouchControl control = 0; control < TouchControlCount; control++) {
        if (_controllerConnected && control != TouchControlPause) continue;
        CGPoint center = _centers[control];
        if (control == TouchControlThrottle) {
            if (CGRectContainsPoint(CGRectInset((CGRect){ center, CGSizeZero }, -22, -ThrottleHeight / 2), point)) return control;
        } else if (control == TouchControlPause) {
            if (CGRectContainsPoint(CGRectInset((CGRect){ center, CGSizeZero }, -46, -22), point)) return control;
        } else if (PointDistance(point, center) <= _radii[control]) return control;
    }
    return TouchControlNone;
}

- (CGPoint)centerForControl:(TouchControl)control { return _centers[control]; }
- (CGRect)rectForControl:(TouchControl)control { return _faces[control].frame; }
- (void)setControllerConnected:(BOOL)connected {
    _controllerConnected = connected;
    for (TouchControl control = 0; control < TouchControlPause; control++) _faces[control].hidden = connected;
}
- (void)displayStick:(CGPoint)position stretched:(BOOL)stretched {
    _stickKnob.position = position;
    _stickTether.hidden = !stretched;
    if (stretched) {
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathMoveToPoint(path, NULL, 0, 0);
        CGPathAddLineToPoint(path, NULL, position.x, position.y);
        _stickTether.path = path;
        CGPathRelease(path);
    }
}

- (void)displayThrottle:(float)value {
    CGFloat height = ThrottleTravel * value;
    CGPathRef path = CGPathCreateWithRect(CGRectMake(-1.5, -ThrottleTravel / 2, 3, height), NULL);
    _throttleFill.path = path;
    CGPathRelease(path);
    _throttleThumb.position = CGPointMake(0, height - ThrottleTravel / 2);
}

- (void)setPressed:(BOOL)pressed control:(TouchControl)control {
    UIRGB accent = control == TouchControlSecondary ? UIAmber : UIInk;
    SKShapeNode *face = _faces[control];
    face.fillColor = pressed ? UIColorWithOpacity(accent, 0.34) : UIColorWithOpacity(UIPanel, 0.8);
}


@end
