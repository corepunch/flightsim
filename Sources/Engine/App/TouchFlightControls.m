#import "TouchFlightControls.h"
#if TARGET_OS_IOS
#import "UIStyle.h"

typedef NS_ENUM(NSInteger, TouchControl) {
    TouchControlNone = -1,
    TouchControlStick, TouchControlThrottle, TouchControlFire,
    TouchControlTorpedo, TouchControlTarget, TouchControlPause, TouchControlCount
};

static const CGFloat ThrottleHeight = 136, ThrottleTravel = 112;
static const CGFloat StickRadius = 66, StickTravel = 132;
static const CGFloat StickKnobTravel = 39, StickStretch = 36, StickDeadzone = 3;

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

@implementation TouchFlightControls {
    Input *_input;
    SKNode *_art;
    SKShapeNode *_stickKnob, *_stickTether, *_throttleFill, *_throttleThumb;
    SKShapeNode *_faces[TouchControlCount];
    CGPoint _centers[TouchControlCount]; // UIKit points, from the top left
    CGFloat _radii[TouchControlCount];
    UITouch *_touches[TouchControlCount];
    BOOL _controllerConnected;
}

- (instancetype)initWithInput:(Input *)input {
    if ((self = [super initWithFrame:CGRectZero])) {
        _input = input;
        self.multipleTouchEnabled = YES;
        self.hidden = YES;
        _art = [SKNode node];
        _art.name = @"Touch flight controls";
        _art.zPosition = 100;
        [self buildArt];
        [self updateController];
    }
    return self;
}

- (void)addButton:(TouchControl)control title:(NSString *)title radius:(CGFloat)radius accent:(UIRGB)accent {
    _radii[control] = radius;
    SKShapeNode *face = Circle(radius, accent, 0.83, 0.8);
    [face addChild:Circle(radius - 5, accent, 0.23, 0)];
    [face addChild:ControlLabel(title, control == TouchControlFire ? 14 : 11, accent)];
    _faces[control] = face;
    [_art addChild:face];
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
    [_art addChild:_faces[TouchControlStick]];

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
    SKLabelNode *label = ControlLabel(@"THR", 11, UIInk);
    label.position = CGPointMake(0, ThrottleHeight / 2 + 13);
    [throttle addChild:label];
    _faces[TouchControlThrottle] = throttle;
    [_art addChild:throttle];

    [self addButton:TouchControlFire title:@"FIRE" radius:35 accent:UIInk];
    [self addButton:TouchControlTorpedo title:@"TORP" radius:28 accent:UIAmber];
    [self addButton:TouchControlTarget title:@"TARGET" radius:28 accent:UIInk];
    _faces[TouchControlPause] = UIActionButton(CGRectMake(-46, -22, 92, 44), @"PAUSE", UIInk);
    [_art addChild:_faces[TouchControlPause]];
}

- (void)showInHUD:(SKScene *)hud {
    [self cancelInput];
    [_art removeFromParent];
    [hud addChild:_art];
    self.hidden = hud == nil;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect safe = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGFloat left = CGRectGetMinX(safe) + 12, right = CGRectGetMaxX(safe) - 12;
    // Use the full viewport midpoint; the home indicator only insets one edge.
    CGFloat centerY = CGRectGetMidY(self.bounds);
    // Keep full leftward travel reachable on screens without a side inset.
    CGFloat stickX = MAX(left + StickRadius, CGRectGetMinX(self.bounds) + StickTravel);
    _centers[TouchControlStick] = CGPointMake(stickX, centerY);
    _centers[TouchControlThrottle] = CGPointMake(right - 147, centerY);
    _centers[TouchControlFire] = CGPointMake(right - 35, centerY);
    _centers[TouchControlTorpedo] = CGPointMake(right - 85, centerY - 53);
    _centers[TouchControlTarget] = CGPointMake(right - 85, centerY + 53);
    // Keep the pause button beside the rear scanner, which occupies the
    // upper-right corner at the same height as the forward scanner.
    CGFloat scannerScale = CGRectGetHeight(self.bounds) < 550 ? 0.56 : 0.86;
    _centers[TouchControlPause] = CGPointMake(right - 128 * scannerScale - 54, CGRectGetMinY(safe) + 30);
    for (TouchControl control = 0; control < TouchControlCount; control++) {
        CGPoint center = _centers[control];
        _faces[control].position = CGPointMake(center.x, CGRectGetHeight(self.bounds) - center.y);
    }
}

- (TouchControl)controlAt:(CGPoint)point {
    for (TouchControl control = 0; control < TouchControlCount; control++) {
        if (_controllerConnected && control != TouchControlPause) continue;
        CGPoint center = _centers[control];
        CGFloat dx = point.x - center.x, dy = point.y - center.y;
        if (control == TouchControlThrottle) {
            if (fabs(dx) <= 22 && fabs(dy) <= ThrottleHeight / 2) return control;
        } else if (control == TouchControlPause) {
            if (fabs(dx) <= 46 && fabs(dy) <= 22) return control;
        } else if (hypot(dx, dy) <= _radii[control]) return control;
    }
    return TouchControlNone;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return [super pointInside:point withEvent:event] && [self controlAt:point] != TouchControlNone;
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

- (void)updateControl:(TouchControl)control at:(CGPoint)point {
    CGFloat dy = _centers[control].y - point.y;
    if (control == TouchControlStick) {
        CGFloat dx = point.x - _centers[control].x;
        CGFloat distance = hypot(dx, dy);
        CGPoint direction = distance > 0 ? CGPointMake(dx / distance, dy / distance) : CGPointZero;

        // The knob resists stretching past the ring, while steering gain keeps rising.
        CGFloat knobGain = StickKnobTravel / StickRadius;
        CGFloat excess = MAX(0, distance - StickRadius) * knobGain;
        CGFloat knobDistance = MIN(distance, StickRadius) * knobGain + StickStretch * excess / (StickStretch + excess);
        [self displayStick:CGPointMake(direction.x * knobDistance, direction.y * knobDistance) stretched:excess > 0];

        CGFloat travel = MAX(0, MIN(distance, StickTravel) - StickDeadzone) / (StickTravel - StickDeadzone);
        CGFloat strength = pow(travel, 2.5);
        [_input setTouchStick:CGPointMake(direction.x * strength, direction.y * strength)];
    } else if (control == TouchControlThrottle) {
        float value = fminf(1, fmaxf(0, 0.5 + dy / ThrottleTravel));
        [self displayThrottle:value];
        [_input setTouchThrottle:value];
    }
}

- (void)setPressed:(BOOL)pressed control:(TouchControl)control {
    UIRGB accent = control == TouchControlTorpedo ? UIAmber : UIInk;
    SKShapeNode *face = _faces[control];
    face.fillColor = pressed ? UIColorWithOpacity(accent, 0.34) : UIColorWithOpacity(UIPanel, 0.8);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:self];
        TouchControl control = [self controlAt:point];
        if (control == TouchControlNone || _touches[control]) continue;
        _touches[control] = touch;
        if (control == TouchControlStick || control == TouchControlThrottle) {
            [self updateControl:control at:point];
        } else {
            [self setPressed:YES control:control];
            if (control == TouchControlFire) [_input setTouchFire:YES];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (TouchControl control = TouchControlStick; control <= TouchControlThrottle; control++) {
        UITouch *touch = _touches[control];
        if (touch && [touches containsObject:touch]) [self updateControl:control at:[touch locationInView:self]];
    }
}

- (void)finishTouches:(NSSet<UITouch *> *)touches activate:(BOOL)activate {
    for (TouchControl control = 0; control < TouchControlCount; control++) {
        UITouch *touch = _touches[control];
        if (!touch || ![touches containsObject:touch]) continue;
        _touches[control] = nil;
        if (control == TouchControlStick) {
            [self displayStick:CGPointZero stretched:NO];
            [_input setTouchStick:CGPointZero];
        } else if (control != TouchControlThrottle) {
            [self setPressed:NO control:control];
            if (control == TouchControlFire) [_input setTouchFire:NO];
            else if (activate && [self controlAt:[touch locationInView:self]] == control) {
                InputAction action = control == TouchControlTorpedo ? InputActionTorpedo :
                                     control == TouchControlTarget ? InputActionTarget : InputActionBack;
                [_input queueTouchAction:action];
            }
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self finishTouches:touches activate:YES];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self finishTouches:touches activate:NO];
}

- (void)cancelInput {
    for (TouchControl control = 0; control < TouchControlCount; control++) {
        _touches[control] = nil;
        if (control >= TouchControlFire) [self setPressed:NO control:control];
    }
    [self displayStick:CGPointZero stretched:NO];
    [_input cancelTouchInput];
}

- (void)updateController {
    [self cancelInput];
    _controllerConnected = _input.joystickName != nil;
    for (TouchControl control = 0; control < TouchControlPause; control++)
        _faces[control].hidden = _controllerConnected;
    [self displayThrottle:_input.currentThrottle];
}

@end
#endif
