#import "TouchFlightControls.h"
#if TARGET_OS_IOS
#import "UIStyle.h"

typedef NS_ENUM(NSInteger, TouchControl) {
    TouchControlNone = -1,
    TouchControlStick, TouchControlThrottle, TouchControlFire,
    TouchControlTorpedo, TouchControlTarget, TouchControlMissions, TouchControlCount
};

static const CGFloat ThrottleHeight = 136, ThrottleTravel = 112;

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
    SKShapeNode *_stickKnob, *_throttleFill, *_throttleThumb;
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
    _radii[TouchControlStick] = 66;
    _faces[TouchControlStick] = Circle(_radii[TouchControlStick], UIInk, 0.62, 0.6);
    [_faces[TouchControlStick] addChild:Circle(49, UIInk, 0.24, 0)];
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
    _faces[TouchControlMissions] = UIActionButton(CGRectMake(-46, -22, 92, 44), @"MISSIONS", UIInk);
    [_art addChild:_faces[TouchControlMissions]];
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
    CGFloat anchor = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 2.0 / 3.0 : 0.5;
    CGFloat centerY = CGRectGetMinY(safe) + CGRectGetHeight(safe) * anchor;
    _centers[TouchControlStick] = CGPointMake(left + _radii[TouchControlStick], centerY);
    _centers[TouchControlThrottle] = CGPointMake(right - 147, centerY);
    _centers[TouchControlFire] = CGPointMake(right - 35, centerY);
    _centers[TouchControlTorpedo] = CGPointMake(right - 85, centerY - 53);
    _centers[TouchControlTarget] = CGPointMake(right - 85, centerY + 53);
    _centers[TouchControlMissions] = CGPointMake(right - 46, CGRectGetMinY(safe) + 30);
    for (TouchControl control = 0; control < TouchControlCount; control++) {
        CGPoint center = _centers[control];
        _faces[control].position = CGPointMake(center.x, CGRectGetHeight(self.bounds) - center.y);
    }
}

- (TouchControl)controlAt:(CGPoint)point {
    for (TouchControl control = 0; control < TouchControlCount; control++) {
        if (_controllerConnected && control != TouchControlMissions) continue;
        CGPoint center = _centers[control];
        CGFloat dx = point.x - center.x, dy = point.y - center.y;
        if (control == TouchControlThrottle) {
            if (fabs(dx) <= 22 && fabs(dy) <= ThrottleHeight / 2) return control;
        } else if (control == TouchControlMissions) {
            if (fabs(dx) <= 46 && fabs(dy) <= 22) return control;
        } else if (hypot(dx, dy) <= _radii[control]) return control;
    }
    return TouchControlNone;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return [super pointInside:point withEvent:event] && [self controlAt:point] != TouchControlNone;
}

- (void)displayStick:(CGPoint)vector {
    CGFloat travel = _radii[TouchControlStick] - 27;
    _stickKnob.position = CGPointMake(vector.x * travel, vector.y * travel);
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
        CGFloat scale = MAX(_radii[control] - 27, hypot(dx, dy));
        CGPoint vector = CGPointMake(dx / scale, dy / scale);
        [self displayStick:vector];
        [_input setTouchStick:vector];
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
            [self displayStick:CGPointZero];
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
    [self displayStick:CGPointZero];
    [_input cancelTouchInput];
}

- (void)updateController {
    [self cancelInput];
    _controllerConnected = _input.joystickName != nil;
    for (TouchControl control = 0; control < TouchControlMissions; control++)
        _faces[control].hidden = _controllerConnected;
    [self displayThrottle:_input.currentThrottle];
}

@end
#endif
