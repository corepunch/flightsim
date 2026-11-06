#import "App.h"
#if TARGET_OS_IOS
#import "UI.h"
#import "Common.h"

static const CGFloat ThrottleTravel = 112, StickRadius = 66, StickTravel = 132;
static const CGFloat StickKnobTravel = 39, StickStretch = 36, StickDeadzone = 3;

@implementation TouchFlightControls {
    Input *_input;
    UITouchControls *_art;
    UITouch *_touches[TouchControlCount];
}

- (instancetype)initWithInput:(Input *)input {
    if ((self = [super initWithFrame:CGRectZero])) {
        _input = input;
        self.multipleTouchEnabled = YES;
        self.hidden = YES;
        _art = [UITouchControls new];
        [self updateController];
    }
    return self;
}

- (void)setSecondaryLabel:(NSString *)label {
    dispatch_async(dispatch_get_main_queue(), ^{ [self->_art setSecondaryLabel:label]; });
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
    [_art layoutWithSize:self.bounds.size insets:self.safeAreaInsets];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return [super pointInside:point withEvent:event] && [_art controlAt:point] != TouchControlNone;
}

- (void)updateControl:(TouchControl)control at:(CGPoint)point {
    // The finger's pull from the control's centre; UIKit's y grows downwards, the stick's upwards.
    CGPoint pull = PointMultiply(PointSub(point, [_art centerForControl:control]), CGSizeMake(1, -1));
    if (control == TouchControlStick) {
        CGFloat distance = PointLength(pull);
        CGPoint direction = PointNormalize(pull);

        // The knob resists stretching past the ring, while steering gain keeps rising.
        CGFloat knobGain = StickKnobTravel / StickRadius;
        CGFloat excess = MAX(0, distance - StickRadius) * knobGain;
        CGFloat knobDistance = MIN(distance, StickRadius) * knobGain + StickStretch * excess / (StickStretch + excess);
        [_art displayStick:PointScale(direction, knobDistance) stretched:excess > 0];

        CGFloat travel = MAX(0, MIN(distance, StickTravel) - StickDeadzone) / (StickTravel - StickDeadzone);
        CGFloat strength = pow(travel, 2.5);
        [_input setTouchStick:PointScale(direction, strength)];
    } else if (control == TouchControlThrottle) {
        float value = fminf(1, fmaxf(0, 0.5 + pull.y / ThrottleTravel));
        [_art displayThrottle:value];
        [_input setTouchThrottle:value];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:self];
        TouchControl control = [_art controlAt:point];
        if (control == TouchControlNone || _touches[control]) continue;
        _touches[control] = touch;
        if (control == TouchControlStick || control == TouchControlThrottle) {
            [self updateControl:control at:point];
        } else {
            [_art setPressed:YES control:control];
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
            [_art displayStick:CGPointZero stretched:NO];
            [_input setTouchStick:CGPointZero];
        } else if (control != TouchControlThrottle) {
            [_art setPressed:NO control:control];
            if (control == TouchControlFire) [_input setTouchFire:NO];
            else if (activate && [_art controlAt:[touch locationInView:self]] == control) {
                InputAction action = control == TouchControlSecondary ? InputActionSecondary :
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
        if (control >= TouchControlFire) [_art setPressed:NO control:control];
    }
    [_art displayStick:CGPointZero stretched:NO];
    [_input cancelTouchInput];
}

- (void)updateController {
    [self cancelInput];
    _art.controllerConnected = _input.joystickName != nil;
    [_art displayThrottle:_input.currentThrottle];
}

@end
#endif
