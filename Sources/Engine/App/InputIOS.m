#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import "Input.h"
#import "Cvar.h"
#import <GameController/GameController.h>
#import <os/lock.h>

NSNotificationName const InputControllerDidChangeNotification = @"InputControllerDidChange";

static float Deadzone(float value) {
    return copysignf(fmaxf(fabsf(value) - 0.06f, 0) / 0.94f, value);
}

@implementation Input {
    os_unfair_lock _lock;
    // Controller changes and callbacks arrive on the main queue. Only the
    // sampled values and pending actions cross over to the render thread.
    GCController *_controller;
    NSString *_controllerName;
    ControlState _pad;
    CGPoint _touchStick;
    float _throttle, _throttleRate;
    BOOL _touchFire, _fireTapped, _flying, _active;
    InputAction _touchActions, _controllerActions, _menuActions;
    Cvar *_touchOnly;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _throttle = fminf(fmaxf([Cvar get:@"in_throttle" defaultValue:@"0" flags:0 help:@"Throttle at launch (0..1)"].value, 0), 1);
        _touchOnly = [Cvar get:@"in_touchOnly" defaultValue:@"0" flags:0 help:@"Ignore game controllers (touch layout checks)"];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(controllersChanged:) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(controllersChanged:) name:GCControllerDidDisconnectNotification object:nil];
        [self controllersChanged:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    _controller.extendedGamepad.valueChangedHandler = nil;
}

- (void)controllersChanged:(NSNotification *)note {
    // Simulator may present a host controller even during a touch-only check.
    if (_touchOnly.boolValue) return;
    GCController *removed = [note.name isEqualToString:GCControllerDidDisconnectNotification] ? note.object : nil;
    NSArray<GCController *> *controllers = GCController.controllers;
    if (_controller && _controller != removed && [controllers containsObject:_controller]) return;
    GCController *next = nil;
    for (GCController *controller in controllers) {
        if (controller != removed && controller.extendedGamepad) { next = controller; break; }
    }
    if (_controller == next) return;

    _controller.extendedGamepad.valueChangedHandler = nil;
    _controller = next;
    os_unfair_lock_lock(&_lock);
    _controllerName = next ? (next.vendorName ?: @"Controller") : nil;
    _pad = (ControlState){ .hat = -1 };
    _throttleRate = 0;
    _controllerActions = 0;
    [self clearTouchLocked];
    os_unfair_lock_unlock(&_lock);

    __weak Input *weak = self;
    next.handlerQueue = dispatch_get_main_queue();
    next.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *pad, GCControllerElement *element) {
        [weak updatePad:pad changed:element];
    };
    [self updatePad:next.extendedGamepad changed:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:InputControllerDidChangeNotification object:self];
}

- (void)updatePad:(GCExtendedGamepad *)pad changed:(GCControllerElement *)element {
    if (!pad || pad != _controller.extendedGamepad) return;
    os_unfair_lock_lock(&_lock);
    _pad.yaw = Deadzone(pad.leftThumbstick.xAxis.value);
    _pad.pitch = Deadzone(-pad.leftThumbstick.yAxis.value); // push forward = nose down
    _pad.roll = Deadzone(pad.rightThumbstick.xAxis.value);
    _pad.fire = pad.rightTrigger.isPressed;
    _pad.boost = pad.leftTrigger.isPressed;
    _throttleRate = (float)pad.rightShoulder.isPressed - (float)pad.leftShoulder.isPressed;
    if (_active && [element isKindOfClass:GCControllerButtonInput.class] && ((GCControllerButtonInput *)element).isPressed) {
        if (element == pad.buttonA) _controllerActions |= InputActionConfirm;
        else if (element == pad.buttonB) _controllerActions |= _flying ? InputActionTorpedo : InputActionBack;
        else if (element == pad.buttonX && _flying) _controllerActions |= InputActionToggleCamera;
        else if (element == pad.buttonY && _flying) _controllerActions |= InputActionTarget;
        else if (element == pad.buttonMenu) _controllerActions |= InputActionBack;
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

- (float)currentThrottle {
    os_unfair_lock_lock(&_lock);
    float value = _throttle;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (void)clearTouchLocked {
    _touchStick = CGPointZero;
    _touchFire = _fireTapped = NO;
    _touchActions = 0;
}

- (void)cancelTouchInput {
    os_unfair_lock_lock(&_lock);
    [self clearTouchLocked];
    os_unfair_lock_unlock(&_lock);
}

- (void)setFlightInputActive:(BOOL)active {
    os_unfair_lock_lock(&_lock);
    if (_flying != active) {
        _flying = active;
        [self clearTouchLocked];
        _controllerActions = _menuActions = 0;
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)setApplicationActive:(BOOL)active {
    os_unfair_lock_lock(&_lock);
    _active = active;
    if (!active) {
        [self clearTouchLocked];
        _controllerActions = _menuActions = 0;
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)setTouchStick:(CGPoint)stick {
    os_unfair_lock_lock(&_lock);
    if (_active && _flying && !_controllerName) _touchStick = stick;
    os_unfair_lock_unlock(&_lock);
}

- (void)setTouchThrottle:(float)value {
    os_unfair_lock_lock(&_lock);
    if (_active && _flying && !_controllerName) _throttle = fminf(fmaxf(value, 0), 1);
    os_unfair_lock_unlock(&_lock);
}

- (void)setTouchFire:(BOOL)down {
    os_unfair_lock_lock(&_lock);
    if (_active && _flying && !_controllerName) {
        if (down && !_touchFire) _fireTapped = YES;
        _touchFire = down;
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)queueTouchAction:(InputAction)action {
    os_unfair_lock_lock(&_lock);
    if (_active && _flying) {
        if (action == InputActionBack) _menuActions |= action;
        else if (!_controllerName) _touchActions |= action;
    }
    os_unfair_lock_unlock(&_lock);
}

- (InputAction)consumeActions {
    os_unfair_lock_lock(&_lock);
    InputAction actions = _menuActions | (_controllerActions & ~(InputActionTarget | InputActionTorpedo));
    _menuActions = 0;
    _controllerActions &= InputActionTarget | InputActionTorpedo;
    // A target and a launch pressed in the same frame need separate commands.
    InputAction weapons = _controllerActions | _touchActions;
    InputAction next = (weapons & InputActionTarget) ? InputActionTarget : (weapons & InputActionTorpedo);
    actions |= next;
    _controllerActions &= ~next;
    _touchActions &= ~next;
    os_unfair_lock_unlock(&_lock);
    return actions;
}

- (ControlState)poll:(float)dt {
    ControlState state = { .hat = -1 };
    os_unfair_lock_lock(&_lock);
    if (_active && _flying) {
        if (_controllerName) {
            state = _pad;
            _throttle = fminf(fmaxf(_throttle + _throttleRate * 0.75f * dt, 0), 1);
        } else {
            // The touch stick applies its deadzone and response curve radially.
            state.yaw = _touchStick.x;
            state.pitch = _touchStick.y;
            state.fire = _touchFire || _fireTapped;
            _fireTapped = NO;
        }
    }
    state.throttle = _throttle;
    os_unfair_lock_unlock(&_lock);
    return state;
}

- (BOOL)mouseCaptured { return NO; }
- (CGPoint)mouseStick { return CGPointZero; }
@end
#endif
