#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import "Input.h"
#import "Common.h"
#import <GameController/GameController.h>
#import <os/lock.h>

static float Deadzone(float value) {
    return copysignf(fmaxf(fabsf(value) - 0.06f, 0) / 0.94f, value);
}

// Icons for the on-screen face buttons, drawn centred on the origin. The
// system fills each path in place of the button's letter, scaling the path's
// bounds to the button with y pointing up. IconFrame turns the UIKit drawing
// (y down) the right way up and pads its bounds so the icon keeps a margin
// inside the disc.
static UIBezierPath *IconFrame(UIBezierPath *icon) {
    [icon applyTransform:CGAffineTransformMakeScale(1, -1)];
    const CGFloat half = 20;
    for (CGFloat corner = -half; corner <= half; corner += 2 * half) {
        [icon moveToPoint:CGPointMake(corner, corner)];
        [icon addLineToPoint:CGPointMake(corner, corner)];
    }
    return icon;
}
static UIBezierPath *Rotated(UIBezierPath *path, CGFloat angle) {
    [path applyTransform:CGAffineTransformMakeRotation(angle)];
    return path;
}

// The virtual controller fills geometry; lineWidth and line caps on a
// UIBezierPath are not part of its CGPath. Expand strokes before handing
// them to the system so the reticle keeps its rounded ends.
static UIBezierPath *IconStroke(UIBezierPath *line, CGFloat width) {
    CGPathRef outline = CGPathCreateCopyByStrokingPath(line.CGPath, NULL, width,
        kCGLineCapRound, kCGLineJoinRound, 0);
    UIBezierPath *icon = [UIBezierPath bezierPathWithCGPath:outline];
    CGPathRelease(outline);
    return icon;
}

// An elliptical muzzle and the gap around the breech give the barrel depth
// in a single colour. Both weapon icons aim diagonally toward the screen.
static UIBezierPath *LaserIcon(void) {
    UIBezierPath *icon = [UIBezierPath bezierPath];
    [icon moveToPoint:CGPointMake(-4.5, -6.5)];
    [icon addCurveToPoint:CGPointMake(-8, 0) controlPoint1:CGPointMake(-6.5, -6.5) controlPoint2:CGPointMake(-8, -4)];
    [icon addCurveToPoint:CGPointMake(-4.5, 6.5) controlPoint1:CGPointMake(-8, 4) controlPoint2:CGPointMake(-6.5, 6.5)];
    [icon addQuadCurveToPoint:CGPointMake(-1.5, 4.5) controlPoint:CGPointMake(-2, 6.5)];
    [icon addLineToPoint:CGPointMake(5, 4.5)];
    [icon addQuadCurveToPoint:CGPointMake(7, 2.5) controlPoint:CGPointMake(7, 4.5)];
    [icon addLineToPoint:CGPointMake(7, -2.5)];
    [icon addQuadCurveToPoint:CGPointMake(5, -4.5) controlPoint:CGPointMake(7, -4.5)];
    [icon addLineToPoint:CGPointMake(-1.5, -4.5)];
    [icon addQuadCurveToPoint:CGPointMake(-4.5, -6.5) controlPoint:CGPointMake(-2, -6.5)];
    [icon closePath];
    // The bore winds opposite to the outer contour to preserve its opening.
    UIBezierPath *bore = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-6.7, -3.8, 3, 7.6)];
    [icon appendPath:bore];
    UIBezierPath *breech = [UIBezierPath bezierPath];
    [breech moveToPoint:CGPointMake(2, -7.5)];
    [breech addLineToPoint:CGPointMake(8, -7.5)];
    [breech addCurveToPoint:CGPointMake(8, 7.5) controlPoint1:CGPointMake(18, -7.5) controlPoint2:CGPointMake(18, 7.5)];
    [breech addLineToPoint:CGPointMake(2, 7.5)];
    [breech addLineToPoint:CGPointMake(2, 6)];
    [breech addLineToPoint:CGPointMake(6, 6)];
    [breech addQuadCurveToPoint:CGPointMake(8.5, 3.5) controlPoint:CGPointMake(8.5, 6)];
    [breech addLineToPoint:CGPointMake(8.5, -3.5)];
    [breech addQuadCurveToPoint:CGPointMake(6, -6) controlPoint:CGPointMake(8.5, -6)];
    [breech addLineToPoint:CGPointMake(2, -6)];
    [breech closePath];
    [icon appendPath:breech];
    [icon appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(-18, -1.4, 8, 2.8) cornerRadius:1.4]];
    return Rotated(icon, M_PI / 4);
}

// One continuous outline avoids holes where the body and swept fins meet
// when the system rasterizes the compound path.
static UIBezierPath *TorpedoIcon(void) {
    UIBezierPath *icon = [UIBezierPath bezierPath];
    [icon moveToPoint:CGPointMake(0, -15)];
    [icon addCurveToPoint:CGPointMake(3.5, -6) controlPoint1:CGPointMake(2, -13) controlPoint2:CGPointMake(3.5, -10)];
    [icon addLineToPoint:CGPointMake(6, -3.5)];
    [icon addQuadCurveToPoint:CGPointMake(6.3, -2.8) controlPoint:CGPointMake(6.3, -3.2)];
    [icon addLineToPoint:CGPointMake(6.3, -1.8)];
    [icon addQuadCurveToPoint:CGPointMake(5.6, -1.3) controlPoint:CGPointMake(6.3, -1)];
    [icon addLineToPoint:CGPointMake(3.5, -2.2)];
    [icon addLineToPoint:CGPointMake(3.5, 2.5)];
    [icon addLineToPoint:CGPointMake(7.2, 7.5)];
    [icon addQuadCurveToPoint:CGPointMake(7.5, 8.5) controlPoint:CGPointMake(7.5, 8)];
    [icon addLineToPoint:CGPointMake(7.5, 10)];
    [icon addQuadCurveToPoint:CGPointMake(6.5, 10.7) controlPoint:CGPointMake(7.5, 11.3)];
    [icon addLineToPoint:CGPointMake(3, 9)];
    [icon addLineToPoint:CGPointMake(3, 10.5)];
    [icon addQuadCurveToPoint:CGPointMake(2.3, 11.2) controlPoint:CGPointMake(3, 11.2)];
    [icon addLineToPoint:CGPointMake(-2.3, 11.2)];
    [icon addQuadCurveToPoint:CGPointMake(-3, 10.5) controlPoint:CGPointMake(-3, 11.2)];
    [icon addLineToPoint:CGPointMake(-3, 9)];
    [icon addLineToPoint:CGPointMake(-6.5, 10.7)];
    [icon addQuadCurveToPoint:CGPointMake(-7.5, 10) controlPoint:CGPointMake(-7.5, 11.3)];
    [icon addLineToPoint:CGPointMake(-7.5, 8.5)];
    [icon addQuadCurveToPoint:CGPointMake(-7.2, 7.5) controlPoint:CGPointMake(-7.5, 8)];
    [icon addLineToPoint:CGPointMake(-3.5, 2.5)];
    [icon addLineToPoint:CGPointMake(-3.5, -2.2)];
    [icon addLineToPoint:CGPointMake(-5.6, -1.3)];
    [icon addQuadCurveToPoint:CGPointMake(-6.3, -1.8) controlPoint:CGPointMake(-6.3, -1)];
    [icon addLineToPoint:CGPointMake(-6.3, -2.8)];
    [icon addQuadCurveToPoint:CGPointMake(-6, -3.5) controlPoint:CGPointMake(-6.3, -3.2)];
    [icon addLineToPoint:CGPointMake(-3.5, -6)];
    [icon addCurveToPoint:CGPointMake(0, -15) controlPoint1:CGPointMake(-3.5, -10) controlPoint2:CGPointMake(-2, -13)];
    [icon closePath];
    [icon appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(-1.3, 13.5, 2.6, 4) cornerRadius:1.3]];
    return Rotated(icon, -M_PI / 4);
}

// Two upright bars.
static UIBezierPath *PauseIcon(void) {
    UIBezierPath *icon = [UIBezierPath bezierPath];
    for (CGFloat x = -5; x <= 5; x += 10)
        [icon appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x - 2.3, -10, 4.6, 20) cornerRadius:1.5]];
    return icon;
}

// Four circular arcs and a centre dot stay readable inside a small disc.
static UIBezierPath *TargetIcon(void) {
    UIBezierPath *icon = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-2, -2, 4, 4)];
    for (int quadrant = 0; quadrant < 4; quadrant++) {
        CGFloat angle = quadrant * M_PI / 2;
        UIBezierPath *arc = [UIBezierPath bezierPath];
        [arc addArcWithCenter:CGPointZero radius:10.5 startAngle:angle + M_PI / 10
                    endAngle:angle + 2 * M_PI / 5 clockwise:YES];
        [icon appendPath:IconStroke(arc, 3)];
    }
    return icon;
}

// The on-screen pad shown while flying without a physical controller. The
// left stick steers. The right stick works the throttle up and down and
// rolls left and right; held fully forward at full throttle it boosts. X
// fires the guns, A launches the secondary weapon and Y picks the next
// target. B, the corner the thumb reaches least, pauses: the system has no
// menu button, and a pause should not be hit by accident.
static GCVirtualController *MakeVirtualController(void) {
    GCVirtualControllerConfiguration *config = [GCVirtualControllerConfiguration new];
    config.elements = [NSSet setWithArray:@[
        GCInputLeftThumbstick, GCInputRightThumbstick,
        GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY,
    ]];
    GCVirtualController *pad = [GCVirtualController virtualControllerWithConfiguration:config];
    NSDictionary<NSString *, UIBezierPath *> *icons = @{
        GCInputButtonX: IconFrame(LaserIcon()), GCInputButtonA: IconFrame(TorpedoIcon()),
        GCInputButtonY: IconFrame(TargetIcon()), GCInputButtonB: IconFrame(PauseIcon()),
    };
    [icons enumerateKeysAndObjectsUsingBlock:^(NSString *button, UIBezierPath *icon, BOOL *stop) {
        [pad updateConfigurationForElement:button configuration:^(GCVirtualControllerElementConfiguration *element) {
            element.path = icon;
            return element;
        }];
    }];
    return pad;
}

// How far forward the on-screen throttle stick must be held to boost.
static const float BoostPush = 0.9f;

typedef NS_ENUM(NSInteger, VirtualPadState) { VirtualPadOff, VirtualPadConnecting, VirtualPadOn };

@implementation Input {
    os_unfair_lock _lock;
    // Controller changes, callbacks and the virtual pad live on the main
    // queue. Only the sampled values and pending actions cross over to the
    // render thread.
    GCController *_controller;          // a physical controller, if one is connected
    GCVirtualController *_virtual;
    VirtualPadState _virtualState;
    GCController *_padSource;           // whichever of the two drives _pad
    NSString *_controllerName;
    ControlState _pad;
    float _throttle, _throttleRate;
    BOOL _boostPush;                    // the on-screen throttle stick is held fully forward
    BOOL _fireTapped, _flying, _active;
    InputAction _controllerActions, _menuActions;
    Cvar *_touchOnly;
}

- (instancetype)init {
    if ((self = [super init])) {
        _pointer = [PointerQueue new];
        [FlightControls shared];
        _lock = OS_UNFAIR_LOCK_INIT;
        _throttle = fminf(fmaxf([Cvar get:@"in_throttle" defaultValue:@"0" flags:0 help:@"Throttle at launch (0..1)"].value, 0), 1);
        _touchOnly = [Cvar get:@"in_touchOnly" defaultValue:@"0" flags:0 help:@"Ignore game controllers (touch layout checks)"];
        _virtual = MakeVirtualController();
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(controllersChanged:) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(controllersChanged:) name:GCControllerDidDisconnectNotification object:nil];
        [self controllersChanged:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    _padSource.extendedGamepad.valueChangedHandler = nil;
    [_virtual disconnect];
}

// MARK: - Controllers

- (void)controllersChanged:(NSNotification *)note {
    // The virtual pad announces itself like any controller; its connection
    // finishes by calling back here, once it can be told apart.
    if (_virtualState == VirtualPadConnecting) return;
    GCController *next = nil;
    // Simulator may present a host controller even during a touch-only check.
    if (!_touchOnly.boolValue) {
        GCController *removed = [note.name isEqualToString:GCControllerDidDisconnectNotification] ? note.object : nil;
        for (GCController *controller in GCController.controllers) {
            if (controller == removed || controller == _virtual.controller || !controller.extendedGamepad) continue;
            if (controller == _controller) { next = controller; break; }
            if (!next) next = controller;
        }
    }
    if (_controller != next) {
        _controller = next;
        os_unfair_lock_lock(&_lock);
        _controllerName = next ? (next.vendorName ?: L10n(@"input.controller")) : nil;
        os_unfair_lock_unlock(&_lock);
    }
    [self updateVirtualController];
}

// Shows the virtual pad while flying without a physical controller, and
// listens to whichever pad is in use.
- (void)updateVirtualController {
    os_unfair_lock_lock(&_lock);
    BOOL wanted = _active && _flying && !_controller;
    os_unfair_lock_unlock(&_lock);

    if (wanted && _virtualState == VirtualPadOff) {
        _virtualState = VirtualPadConnecting;
        __weak Input *weak = self;
        [_virtual connectWithReplyHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weak virtualControllerConnected:error]; });
        }];
    } else if (!wanted && _virtualState == VirtualPadOn) {
        _virtualState = VirtualPadOff;
        [_virtual disconnect];
    }
    [self listenTo:_controller ?: (_virtualState == VirtualPadOn ? _virtual.controller : nil)];
}

- (void)virtualControllerConnected:(NSError *)error {
    if (_virtualState != VirtualPadConnecting) return;
    if (error) NSLog(@"Input: virtual controller failed to connect: %@", error);
    _virtualState = error ? VirtualPadOff : VirtualPadOn;
    // Pick up a physical controller that arrived meanwhile, or let go of the
    // pad if flight ended while it was connecting.
    [self controllersChanged:nil];
}

- (void)listenTo:(GCController *)source {
    if (_padSource == source) return;
    _padSource.extendedGamepad.valueChangedHandler = nil;
    _padSource = source;
    os_unfair_lock_lock(&_lock);
    _pad = (ControlState){ .hat = -1 };
    _throttleRate = 0;
    _boostPush = _fireTapped = NO;
    _controllerActions = 0;
    os_unfair_lock_unlock(&_lock);

    __weak Input *weak = self;
    source.handlerQueue = dispatch_get_main_queue();
    source.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *pad, GCControllerElement *element) {
        [weak updatePad:pad changed:element];
    };
    [self updatePad:source.extendedGamepad changed:nil];
}

- (void)updatePad:(GCExtendedGamepad *)pad changed:(GCControllerElement *)element {
    if (!pad || pad != _padSource.extendedGamepad) return;
    // A physical stick pushed forward dives; the on-screen stick follows the
    // finger, so dragging up climbs.
    BOOL onScreen = _padSource != _controller;
    float pitchSign = onScreen ? 1 : -1;
    os_unfair_lock_lock(&_lock);
    _pad.yaw = Deadzone(pad.leftThumbstick.xAxis.value);
    _pad.pitch = Deadzone(pitchSign * pad.leftThumbstick.yAxis.value);
    _pad.roll = Deadzone(pad.rightThumbstick.xAxis.value);
    BOOL fire = onScreen ? pad.buttonX.isPressed : pad.rightTrigger.isPressed;
    // A tap shorter than a frame still fires once.
    if (fire && !_pad.fire) _fireTapped = YES;
    _pad.fire = fire;
    if (onScreen) {
        float push = pad.rightThumbstick.yAxis.value;
        _throttleRate = Deadzone(push);
        _boostPush = push >= BoostPush;
        _pad.boost = NO;
    } else {
        _throttleRate = (float)pad.rightShoulder.isPressed - (float)pad.leftShoulder.isPressed;
        _boostPush = NO;
        _pad.boost = pad.leftTrigger.isPressed;
    }
    if (onScreen && _active && _flying && [element isKindOfClass:GCControllerButtonInput.class] &&
        ((GCControllerButtonInput *)element).isPressed) {
        if (element == pad.buttonA) _controllerActions |= InputActionSecondary;
        else if (element == pad.buttonY) _controllerActions |= InputActionTarget;
        else if (element == pad.buttonB) _controllerActions |= InputActionBack;
    } else if (!onScreen && _active && [element isKindOfClass:GCControllerButtonInput.class] &&
               ((GCControllerButtonInput *)element).isPressed) {
        if (element == pad.buttonA) _controllerActions |= InputActionConfirm;
        else if (element == pad.buttonB) _controllerActions |= _flying ? InputActionSecondary : InputActionBack;
        else if (element == pad.buttonX && _flying) _controllerActions |= InputActionToggleCamera;
        else if (element == pad.buttonY && _flying) _controllerActions |= InputActionTarget;
        // Menu (Start) and Options (Select, View, Share) both pause, as each is
        // the pause button on some pad.
        else if (element == pad.buttonMenu || element == pad.buttonOptions) _controllerActions |= InputActionBack;
    }
    if (_active && !_flying && element == pad.dpad) {
        if (pad.dpad.up.isPressed) _controllerActions |= InputActionUp;
        if (pad.dpad.down.isPressed) _controllerActions |= InputActionDown;
        if (pad.dpad.left.isPressed) _controllerActions |= InputActionLeft;
        if (pad.dpad.right.isPressed) _controllerActions |= InputActionRight;
    }
    os_unfair_lock_unlock(&_lock);
}

- (NSString *)joystickName {
    os_unfair_lock_lock(&_lock);
    NSString *name = _controllerName;
    os_unfair_lock_unlock(&_lock);
    return name;
}

// MARK: - State

- (void)setFlightInputActive:(BOOL)active {
    os_unfair_lock_lock(&_lock);
    BOOL changed = _flying != active;
    if (changed) {
        _flying = active;
        _controllerActions = _menuActions = 0;
    }
    os_unfair_lock_unlock(&_lock);
    if (changed) dispatch_async(dispatch_get_main_queue(), ^{ [self updateVirtualController]; });
}

- (void)setApplicationActive:(BOOL)active {
    os_unfair_lock_lock(&_lock);
    _active = active;
    if (!active) _controllerActions = _menuActions = 0;
    os_unfair_lock_unlock(&_lock);
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateVirtualController]; });
}

- (InputAction)consumeActions {
    os_unfair_lock_lock(&_lock);
    InputAction actions = _menuActions | (_controllerActions & ~(InputActionTarget | InputActionSecondary));
    _menuActions = 0;
    // A target and a launch pressed in the same frame need separate commands.
    InputAction next = (_controllerActions & InputActionTarget) ? InputActionTarget : (_controllerActions & InputActionSecondary);
    actions |= next;
    _controllerActions &= (InputActionTarget | InputActionSecondary) & ~next;
    os_unfair_lock_unlock(&_lock);
    return actions;
}

- (ControlState)poll:(float)dt {
    ControlState state = { .hat = -1 };
    os_unfair_lock_lock(&_lock);
    if (_active && _flying) {
        state = _pad;
        state.fire = _pad.fire || _fireTapped;
        _fireTapped = NO;
        _throttle = fminf(fmaxf(_throttle + _throttleRate * 0.75f * dt, 0), 1);
        // Pushing on past full throttle boosts.
        if (_boostPush && _throttle >= 1) state.boost = YES;
    }
    state = [[FlightControls shared] applyTo:state];
    state.throttle = _throttle;
    os_unfair_lock_unlock(&_lock);
    return state;
}

- (BOOL)mouseCaptured { return NO; }
- (CGPoint)mouseStick { return CGPointZero; }
@end
#endif
