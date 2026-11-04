#import "TouchFlightControls.h"
#if TARGET_OS_IOS
#import "UIStyle.h"

static UIColor *PanelColor(void) { return UIColorWithOpacity(UIPanel, 0.86); }
static UIColor *ControlInk(void) { return UIColorWithOpacity(UIInk, 1); }

@interface FlightStick : UIControl
@property (nonatomic, readonly) CGPoint vector;
- (void)centerStick;
@end

@implementation FlightStick {
    UIView *_knob;
}

- (instancetype)init {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = PanelColor();
        self.layer.borderColor = UIColorWithOpacity(UIInk, 0.46).CGColor;
        self.layer.borderWidth = 1;
        self.accessibilityLabel = @"Flight stick";
        _knob = [UIView new];
        _knob.userInteractionEnabled = NO;
        _knob.backgroundColor = UIColorWithOpacity(UIInk, 0.32);
        _knob.layer.borderColor = UIColorWithOpacity(UIInk, 0.74).CGColor;
        _knob.layer.borderWidth = 1;
        [self addSubview:_knob];
    }
    return self;
}

- (CGFloat)travel { return CGRectGetWidth(self.bounds) * 0.32; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat diameter = CGRectGetWidth(self.bounds);
    CGFloat knobSize = diameter * 0.32;
    self.layer.cornerRadius = diameter / 2;
    _knob.bounds = CGRectMake(0, 0, knobSize, knobSize);
    _knob.layer.cornerRadius = knobSize / 2;
    _knob.center = CGPointMake(CGRectGetMidX(self.bounds) + _vector.x * self.travel,
                              CGRectGetMidY(self.bounds) - _vector.y * self.travel);
}

- (void)updateWithTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:self];
    CGFloat x = p.x - CGRectGetMidX(self.bounds), y = CGRectGetMidY(self.bounds) - p.y;
    CGFloat scale = MAX(self.travel, hypot(x, y));
    if (scale <= 0) return;
    _vector = CGPointMake(x / scale, y / scale);
    [self setNeedsLayout];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)centerStick {
    _vector = CGPointZero;
    [self setNeedsLayout];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (BOOL)beginTracking:(UITouch *)touch withEvent:(UIEvent *)event { [self updateWithTouch:touch]; return YES; }
- (BOOL)continueTracking:(UITouch *)touch withEvent:(UIEvent *)event { [self updateWithTouch:touch]; return YES; }
- (void)endTracking:(UITouch *)touch withEvent:(UIEvent *)event { [self centerStick]; }
- (void)cancelTrackingWithEvent:(UIEvent *)event {
    [super cancelTrackingWithEvent:event];
    [self centerStick];
}

@end

@implementation TouchFlightControls {
    Input *_input;
    FlightStick *_stick;
    UISlider *_throttle;
    UILabel *_throttleLabel;
    UIButton *_fire, *_torpedo, *_target, *_missions;
}

- (UIButton *)button:(NSString *)title accent:(UIColor *)color action:(SEL)action events:(UIControlEvents)events {
    UIButtonConfiguration *config = UIButtonConfiguration.tintedButtonConfiguration;
    config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    config.baseForegroundColor = color;
    config.baseBackgroundColor = PanelColor();
    config.contentInsets = NSDirectionalEdgeInsetsMake(0, 5, 0, 5);
    config.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightSemibold]
    }];
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    [button addTarget:self action:action forControlEvents:events];
    [self addSubview:button];
    return button;
}

- (instancetype)initWithInput:(Input *)input {
    if ((self = [super initWithFrame:CGRectZero])) {
        _input = input;
        _stick = [FlightStick new];
        [_stick addTarget:self action:@selector(stickChanged) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_stick];

        _throttle = [UISlider new];
        _throttle.accessibilityLabel = @"Throttle";
        _throttle.tintColor = ControlInk();
        _throttle.minimumTrackTintColor = ControlInk();
        _throttle.maximumTrackTintColor = UIColorWithOpacity(UIInk, 0.32);
        _throttle.backgroundColor = PanelColor();
        _throttle.layer.cornerRadius = 12;
        _throttle.transform = CGAffineTransformMakeRotation(-M_PI_2);
        [_throttle addTarget:self action:@selector(throttleChanged) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_throttle];
        _throttleLabel = [UILabel new];
        _throttleLabel.text = @"THR";
        _throttleLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
        _throttleLabel.textColor = ControlInk();
        _throttleLabel.textAlignment = NSTextAlignmentCenter;
        _throttleLabel.userInteractionEnabled = NO;
        [self addSubview:_throttleLabel];

        UIColor *amber = UIColorWithOpacity(UIAmber, 1);
        _fire = [self button:@"FIRE" accent:ControlInk() action:@selector(fireDown) events:UIControlEventTouchDown];
        [_fire addTarget:self action:@selector(fireUp)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        _torpedo = [self button:@"TORPEDO" accent:amber action:@selector(launchTorpedo) events:UIControlEventPrimaryActionTriggered];
        _target = [self button:@"TARGET" accent:ControlInk() action:@selector(nextTarget) events:UIControlEventPrimaryActionTriggered];
        _missions = [self button:@"MISSIONS" accent:ControlInk() action:@selector(missions) events:UIControlEventPrimaryActionTriggered];
        _fire.accessibilityLabel = @"Fire guns";
        _torpedo.accessibilityLabel = @"Launch torpedo";
        _target.accessibilityLabel = @"Next target";
        _missions.accessibilityLabel = @"Return to missions";
        [self updateController];
    }
    return self;
}

- (void)stickChanged { [_input setTouchStick:_stick.vector]; }
- (void)throttleChanged { [_input setTouchThrottle:_throttle.value]; }
- (void)fireDown { [_input setTouchFire:YES]; }
- (void)fireUp { [_input setTouchFire:NO]; }
- (void)launchTorpedo { [_input queueTouchAction:InputActionTorpedo]; }
- (void)nextTarget { [_input queueTouchAction:InputActionTarget]; }
- (void)missions { [_input queueTouchAction:InputActionBack]; }

- (void)cancelInput {
    [_stick cancelTrackingWithEvent:nil];
    [_throttle cancelTrackingWithEvent:nil];
    for (UIButton *button in @[_fire, _torpedo, _target, _missions]) {
        [button cancelTrackingWithEvent:nil];
        button.highlighted = NO;
    }
    [_input cancelTouchInput];
}

- (void)updateController {
    BOOL connected = _input.joystickName != nil;
    [self cancelInput];
    _stick.hidden = _throttle.hidden = _throttleLabel.hidden = _fire.hidden = _torpedo.hidden = _target.hidden = connected;
    [_throttle setValue:_input.currentThrottle animated:NO];
}

// Only controls intercept hits. The space between them belongs to the game.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect safe = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGFloat left = CGRectGetMinX(safe) + 12, right = CGRectGetMaxX(safe) - 12;
    CGFloat verticalPosition = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 2.0 / 3.0 : 0.5;
    CGFloat centerY = CGRectGetMinY(safe) + CGRectGetHeight(safe) * verticalPosition;
    CGFloat diameter = MIN(144, MAX(88, CGRectGetWidth(safe) * 0.24));
    CGFloat buttonWidth = MIN(104, MAX(78, CGRectGetWidth(safe) * 0.20));
    CGFloat buttonHeight = 44, gap = 5, throttleWidth = 44;
    CGFloat weaponStackHeight = buttonHeight * 3 + gap * 2;
    CGFloat throttleLength = MAX(diameter, weaponStackHeight);
    CGFloat throttleX = right - buttonWidth - 10 - throttleWidth / 2;
    _stick.frame = CGRectMake(left, centerY - diameter / 2, diameter, diameter);
    _throttle.bounds = CGRectMake(0, 0, throttleLength, throttleWidth);
    _throttle.center = CGPointMake(throttleX, centerY);
    _throttleLabel.frame = CGRectMake(throttleX - throttleWidth / 2, centerY - throttleLength / 2 - 18, throttleWidth, 16);
    _target.frame = CGRectMake(right - buttonWidth, centerY - weaponStackHeight / 2, buttonWidth, buttonHeight);
    _torpedo.frame = CGRectOffset(_target.frame, 0, buttonHeight + gap);
    _fire.frame = CGRectOffset(_torpedo.frame, 0, buttonHeight + gap);
    _missions.frame = CGRectMake(right - 92, CGRectGetMinY(safe) + 8, 92, buttonHeight);
}

@end
#endif
