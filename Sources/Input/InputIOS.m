#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import "Input.h"
#import "Common.h"
#import <GameController/GameController.h>
#import <os/lock.h>

static float Deadzone(float value) {
    return copysignf(fmaxf(fabsf(value) - 0.06f, 0) / 0.94f, value);
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
    return [GCVirtualController virtualControllerWithConfiguration:config];
}

// How far forward the on-screen throttle stick must be held to boost.
static const float BoostPush = 0.9f;

typedef NS_ENUM(NSInteger, VirtualPadState) { VirtualPadOff, VirtualPadConnecting, VirtualPadOn };

@interface Input ()
@property (atomic, readwrite, strong) InputGuide *controlGuide;
@end

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
    GCExtendedGamepad *pad = _controller.extendedGamepad;
    self.controlGuide = InputGuideMake(pad ? InputSchemeGamepad : InputSchemeTouch, _controller.vendorName, (InputPadSymbols){
        .leftStick = pad.leftThumbstick.sfSymbolsName, .rightStick = pad.rightThumbstick.sfSymbolsName,
        .a = pad.buttonA.sfSymbolsName, .b = pad.buttonB.sfSymbolsName, .x = pad.buttonX.sfSymbolsName, .y = pad.buttonY.sfSymbolsName,
        .leftTrigger = pad.leftTrigger.sfSymbolsName, .rightTrigger = pad.rightTrigger.sfSymbolsName,
        .leftShoulder = pad.leftShoulder.sfSymbolsName, .rightShoulder = pad.rightShoulder.sfSymbolsName,
        .menu = pad.buttonMenu.sfSymbolsName,
    });
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
