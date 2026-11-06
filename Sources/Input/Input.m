#import <TargetConditionals.h>
#if TARGET_OS_OSX
// Carbon (key codes) names a type EventType, as Protocol does.
#define EventType CarbonEventType
#import <Carbon/Carbon.h>
#undef EventType
#import "Input.h"
#import "Common.h"
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <os/lock.h>

#define MAX_AXES 16
#define AXIS_KEY(page, usage) (((uint32_t)(page) << 16) | (uint32_t)(usage))

typedef struct {
    uint32_t key;
    float value;     // normalised -1..1
    float initial;   // centre used when the axis acts as a rudder
    float ref;       // last position that counted as "moved" (throttle pickup)
} HIDAxis;


static float deadzone(float v, float dz) {
    float a = fabsf(v);
    if (a < dz) return 0;
    return copysignf((a - dz) / (1.0f - dz), v);
}

@interface Input ()
@property (atomic, readwrite) CGPoint mouseStick;
@property (atomic, readwrite, copy) NSString *joystickName;
@property (atomic, readwrite, copy) NSString *axisDescription;
@property (atomic, readwrite) BOOL throttleFromJoystick;
- (void)hidValue:(IOHIDValueRef)value;
- (void)hidAttached:(IOHIDDeviceRef)device;
- (void)hidRemoved:(IOHIDDeviceRef)device;
@end

static void HIDValueCallback(void *ctx, IOReturn result, void *sender, IOHIDValueRef value) {
    [(__bridge Input *)ctx hidValue:value];
}
static void HIDAttachCallback(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef device) {
    [(__bridge Input *)ctx hidAttached:device];
}
static void HIDRemoveCallback(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef device) {
    [(__bridge Input *)ctx hidRemoved:device];
}

@implementation Input {
    os_unfair_lock _lock;
    NSMutableIndexSet *_keys;
    BOOL _shift, _mouseFire;
    CGPoint _stick;
    float _kbThrottle, _throttle;
    InputAction _actions;

    IOHIDManagerRef _hid;
    IOHIDDeviceRef _joystick;
    HIDAxis _axes[MAX_AXES];
    int _axisCount;
    uint32_t _throttleAxis, _rudderAxis;
    uint32_t _levers[MAX_AXES];   // non-stick axes that can drive the throttle
    int _leverCount;
    BOOL _invertThrottle;
    BOOL _joyThrottleSeen;
    uint32_t _buttons;
    int _hat;
    Cvar *_testFire;
}

- (instancetype)init {
    if ((self = [super init])) {
        _pointer = [PointerQueue new];
        [FlightControls shared];
        _lock = OS_UNFAIR_LOCK_INIT;
        _keys = [NSMutableIndexSet indexSet];
        _hat = -1;
        _kbThrottle = _throttle = clampf([Cvar get:@"in_throttle" defaultValue:@"0" flags:0 help:@"Throttle at launch (0..1)"].value, 0, 1);
        _testFire = [Cvar get:@"cl_testFire" defaultValue:@"0" flags:CVAR_CHEAT help:@"Hold the trigger (test drives)"];
        [self startHID];
    }
    return self;
}

- (void)dealloc {
    if (_hid) {
        IOHIDManagerUnscheduleFromRunLoop(_hid, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDManagerClose(_hid, kIOHIDOptionsTypeNone);
        CFRelease(_hid);
    }
}

#pragma mark - HID

- (void)startHID {
    _hid = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *matching = @[
        @{ @kIOHIDDeviceUsagePageKey : @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey : @(kHIDUsage_GD_Joystick) },
        @{ @kIOHIDDeviceUsagePageKey : @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey : @(kHIDUsage_GD_GamePad) },
        @{ @kIOHIDDeviceUsagePageKey : @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey : @(kHIDUsage_GD_MultiAxisController) },
    ];
    IOHIDManagerSetDeviceMatchingMultiple(_hid, (__bridge CFArrayRef)matching);
    IOHIDManagerRegisterDeviceMatchingCallback(_hid, HIDAttachCallback, (__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(_hid, HIDRemoveCallback, (__bridge void *)self);
    IOHIDManagerRegisterInputValueCallback(_hid, HIDValueCallback, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(_hid, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(_hid, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) NSLog(@"Input: IOHIDManagerOpen failed 0x%x", r);
}

static BOOL IsAxisUsage(uint32_t page, uint32_t usage) {
    if (page == kHIDPage_GenericDesktop)
        return (usage >= kHIDUsage_GD_X && usage <= kHIDUsage_GD_Wheel) || usage == 0xBB;
    if (page == kHIDPage_Simulation)
        return usage == kHIDUsage_Sim_Throttle || usage == kHIDUsage_Sim_Rudder;
    return NO;
}

static float Normalise(IOHIDElementRef el, CFIndex raw) {
    CFIndex mn = IOHIDElementGetLogicalMin(el), mx = IOHIDElementGetLogicalMax(el);
    if (mx <= mn) return 0;
    return clampf(((float)(raw - mn) / (float)(mx - mn)) * 2.0f - 1.0f, -1, 1);
}

- (HIDAxis *)axisForKey:(uint32_t)key create:(BOOL)create {
    for (int i = 0; i < _axisCount; i++) if (_axes[i].key == key) return &_axes[i];
    if (!create || _axisCount >= MAX_AXES) return NULL;
    HIDAxis *a = &_axes[_axisCount++];
    a->key = key;
    return a;
}

- (BOOL)hasAxis:(uint32_t)key { return [self axisForKey:key create:NO] != NULL; }

- (void)hidAttached:(IOHIDDeviceRef)device {
    os_unfair_lock_lock(&_lock);
    if (_joystick) { os_unfair_lock_unlock(&_lock); return; }
    _joystick = device;
    _axisCount = 0;
    _buttons = 0;
    _joyThrottleSeen = NO;

    NSArray *elements = (__bridge_transfer NSArray *)IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
    for (id obj in elements) {
        IOHIDElementRef el = (__bridge IOHIDElementRef)obj;
        uint32_t page = IOHIDElementGetUsagePage(el), usage = IOHIDElementGetUsage(el);
        if (!IsAxisUsage(page, usage)) continue;
        HIDAxis *a = [self axisForKey:AXIS_KEY(page, usage) create:YES];
        if (!a) continue;
        IOHIDValueRef v = NULL;
        if (IOHIDDeviceGetValue(device, el, &v) == kIOReturnSuccess && v)
            a->value = a->initial = a->ref = Normalise(el, IOHIDValueGetIntegerValue(v));
    }

    // Throttle: a Simulation throttle, else Z (Thrustmaster's USB Joystick
    // documents its thumb throttle as Z), else a slider, else 0xBB. Rudder only
    // from twist (Rz) or a Simulation rudder: a throttle lever is not a centred
    // rudder, and using Z for yaw steered the ship by itself. Generic firmware
    // also reports extra axes with nothing behind them (0xBB on that stick);
    // all non-stick axes go in _levers, which J cycles through.
    _throttleAxis = _rudderAxis = 0;
    _leverCount = 0;
    uint32_t rudders[] = { AXIS_KEY(kHIDPage_GenericDesktop, kHIDUsage_GD_Rz), AXIS_KEY(kHIDPage_Simulation, kHIDUsage_Sim_Rudder) };
    for (int i = 0; i < 2 && !_rudderAxis; i++) if ([self hasAxis:rudders[i]]) _rudderAxis = rudders[i];
    uint32_t throttles[] = { AXIS_KEY(kHIDPage_Simulation, kHIDUsage_Sim_Throttle), AXIS_KEY(kHIDPage_GenericDesktop, kHIDUsage_GD_Z),
                             AXIS_KEY(kHIDPage_GenericDesktop, kHIDUsage_GD_Slider), AXIS_KEY(kHIDPage_GenericDesktop, 0xBB) };
    for (int i = 0; i < 4 && !_throttleAxis; i++) if ([self hasAxis:throttles[i]]) _throttleAxis = throttles[i];
    for (int i = 0; i < _axisCount; i++) {
        uint32_t k = _axes[i].key;
        if (k == AXIS_KEY(kHIDPage_GenericDesktop, kHIDUsage_GD_X) || k == AXIS_KEY(kHIDPage_GenericDesktop, kHIDUsage_GD_Y) ||
            k == _rudderAxis) continue;
        _levers[_leverCount++] = k;   // includes the default throttle, so J can come back to it
    }
    os_unfair_lock_unlock(&_lock);

    NSString *name = (__bridge NSString *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    self.joystickName = name ?: L10n(@"input.joystick");
    [self updateAxisDescription];
    NSLog(@"Input: joystick attached: %@ (%d axes) %@", self.joystickName, _axisCount, self.axisDescription);
}

- (void)hidRemoved:(IOHIDDeviceRef)device {
    os_unfair_lock_lock(&_lock);
    if (device == _joystick) {
        _joystick = NULL;
        _axisCount = 0;
        _buttons = 0;
        _hat = -1;
        self.throttleFromJoystick = NO;
    }
    os_unfair_lock_unlock(&_lock);
    if (!_joystick) self.joystickName = nil;
}

static NSString *AxisName(uint32_t key) {
    uint32_t page = key >> 16, usage = key & 0xffff;
    if (!key) return @"none";
    if (page == kHIDPage_Simulation) return usage == kHIDUsage_Sim_Throttle ? @"SimThrottle" : @"SimRudder";
    switch (usage) {
        case kHIDUsage_GD_X: return @"X"; case kHIDUsage_GD_Y: return @"Y"; case kHIDUsage_GD_Z: return @"Z";
        case kHIDUsage_GD_Rx: return @"Rx"; case kHIDUsage_GD_Ry: return @"Ry"; case kHIDUsage_GD_Rz: return @"Rz";
        case kHIDUsage_GD_Slider: return @"Slider"; case kHIDUsage_GD_Dial: return @"Dial";
        default: return [NSString stringWithFormat:@"0x%X", usage];
    }
}

- (void)updateAxisDescription {
    self.axisDescription = [NSString stringWithFormat:@"throttle=%@%@ rudder=%@",
                            AxisName(_throttleAxis), _invertThrottle ? @"(inv)" : @"", AxisName(_rudderAxis)];
}

- (void)hidValue:(IOHIDValueRef)value {
    IOHIDElementRef el = IOHIDValueGetElement(value);
    if (IOHIDElementGetDevice(el) != _joystick) return;
    uint32_t page = IOHIDElementGetUsagePage(el), usage = IOHIDElementGetUsage(el);
    CFIndex raw = IOHIDValueGetIntegerValue(value);

    os_unfair_lock_lock(&_lock);
    if (page == kHIDPage_Button && usage >= 1 && usage <= 32) {
        uint32_t bit = 1u << (usage - 1);
        BOOL down = raw != 0;
        if (down && !(_buttons & bit) && usage == 3) _actions |= InputActionToggleCamera;
        if (down && !(_buttons & bit) && usage == 1) _actions |= InputActionConfirm;
        if (down && !(_buttons & bit) && usage == 5) _actions |= InputActionSecondary;
        if (down && !(_buttons & bit) && usage == 6) _actions |= InputActionTarget;
        _buttons = down ? (_buttons | bit) : (_buttons & ~bit);
    } else if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Hatswitch) {
        CFIndex mn = IOHIDElementGetLogicalMin(el), mx = IOHIDElementGetLogicalMax(el);
        _hat = (raw >= mn && raw <= mx) ? (int)(raw - mn) : -1;
    } else if (IsAxisUsage(page, usage)) {
        HIDAxis *a = [self axisForKey:AXIS_KEY(page, usage) create:NO];
        if (a) a->value = Normalise(el, raw);
    }
    os_unfair_lock_unlock(&_lock);
}

// Value of an axis that springs back to the position it had at startup.
- (float)centredAxis:(uint32_t)key {
    HIDAxis *a = [self axisForKey:key create:NO];
    if (!a) return 0;
    float c = a->initial, v = a->value;
    return v >= c ? (v - c) / MAX(1.0f - c, 1e-3f) : (v - c) / MAX(1.0f + c, 1e-3f);
}

#pragma mark - Keyboard & mouse

- (void)keyDown:(NSEvent *)event {
    os_unfair_lock_lock(&_lock);
    [_keys addIndex:event.keyCode];
    if (!event.isARepeat) {
        switch (event.keyCode) {
            case kVK_ANSI_C: _actions |= InputActionToggleCamera; break;
            case kVK_ANSI_J: _actions |= InputActionSwapAxes; break;
            case kVK_ANSI_K: _actions |= InputActionInvertThrottle; break;
            case kVK_ANSI_I: _actions |= InputActionInvertMouse; break;
            case kVK_ANSI_R: _actions |= InputActionRestart; break;
            case kVK_ANSI_H: case kVK_F1: _actions |= InputActionToggleHelp; break;
            case kVK_ANSI_X: _kbThrottle = 0; _throttle = 0; self.throttleFromJoystick = NO; break;
            case kVK_ANSI_Z: _kbThrottle = 1; _throttle = 1; self.throttleFromJoystick = NO; break;
            case kVK_UpArrow: _actions |= InputActionUp; break;
            case kVK_DownArrow: _actions |= InputActionDown; break;
            case kVK_LeftArrow: _actions |= InputActionLeft; break;
            case kVK_RightArrow: _actions |= InputActionRight; break;
            case kVK_Return: case kVK_ANSI_KeypadEnter: _actions |= InputActionConfirm; break;
            case kVK_Escape: case kVK_ANSI_M: case kVK_Delete: _actions |= InputActionBack; break;
            case kVK_ANSI_T: _actions |= InputActionTarget; break;
            case kVK_ANSI_G: _actions |= InputActionSecondary; break;
            case kVK_ANSI_N: _actions |= InputActionMultiplayer; break;
        }
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)keyUp:(NSEvent *)event {
    os_unfair_lock_lock(&_lock);
    [_keys removeIndex:event.keyCode];
    os_unfair_lock_unlock(&_lock);
}

- (void)flagsChanged:(NSEvent *)event {
    os_unfair_lock_lock(&_lock);
    _shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    os_unfair_lock_unlock(&_lock);
}

- (void)releaseAllKeys {
    os_unfair_lock_lock(&_lock);
    [_keys removeAllIndexes];
    _shift = NO;
    _mouseFire = NO;
    _actions = 0;
    _stick = CGPointZero;
    self.mouseStick = _stick;
    os_unfair_lock_unlock(&_lock);
}

- (void)mouseMovedByX:(CGFloat)dx y:(CGFloat)dy {
    if (!self.mouseCaptured) return;
    os_unfair_lock_lock(&_lock);
    const CGFloat sens = 1.0 / 320.0;
    CGPoint move = CGPointMake(dx, -dy);
    _stick = PointClampLength(PointAdd(_stick, PointScale(move, sens)), 1);
    self.mouseStick = _stick;
    os_unfair_lock_unlock(&_lock);
}

- (void)setMouseFire:(BOOL)down {
    os_unfair_lock_lock(&_lock);
    _mouseFire = down;
    os_unfair_lock_unlock(&_lock);
}

- (void)queueMouseAction:(InputAction)action {
    if (!self.mouseCaptured) return;
    os_unfair_lock_lock(&_lock);
    _actions |= action & (InputActionTarget | InputActionSecondary);
    os_unfair_lock_unlock(&_lock);
}

- (void)adjustMouseThrottleBy:(float)delta {
    if (!self.mouseCaptured || !isfinite(delta) || delta == 0) return;
    os_unfair_lock_lock(&_lock);
    if (self.throttleFromJoystick) _kbThrottle = _throttle;
    self.throttleFromJoystick = NO;
    _kbThrottle = _throttle = clampf(_kbThrottle + delta, 0, 1);
    os_unfair_lock_unlock(&_lock);
}

- (void)recenterMouse {
    os_unfair_lock_lock(&_lock);
    _stick = CGPointZero;
    self.mouseStick = _stick;
    os_unfair_lock_unlock(&_lock);
}

- (InputAction)consumeActions {
    os_unfair_lock_lock(&_lock);
    // Target first, then launch on the next frame, as on touch/controller.
    InputAction weapons = _actions & (InputActionTarget | InputActionSecondary);
    InputAction next = (weapons & InputActionTarget) ? InputActionTarget : (weapons & InputActionSecondary);
    InputAction a = (_actions & ~(InputActionTarget | InputActionSecondary)) | next;
    _actions = weapons & ~next;
    os_unfair_lock_unlock(&_lock);

    // Actions that only concern input itself are handled here.
    if (a & (InputActionSwapAxes | InputActionInvertThrottle | InputActionInvertMouse)) {
        os_unfair_lock_lock(&_lock);
        if (a & InputActionSwapAxes) {
            // Cycle the throttle axis through the non-stick axes, then none.
            int next = 0;
            for (int i = 0; i < _leverCount; i++) if (_levers[i] == _throttleAxis) next = i + 1;
            _throttleAxis = next < _leverCount ? _levers[next] : 0;
            HIDAxis *t = [self axisForKey:_throttleAxis create:NO];
            if (t) t->ref = t->value;
            self.throttleFromJoystick = NO;
        }
        if (a & InputActionInvertThrottle) _invertThrottle = !_invertThrottle;
        if (a & InputActionInvertMouse) [FlightControls shared].invertPitch = ![FlightControls shared].invertPitch;
        os_unfair_lock_unlock(&_lock);
        [self updateAxisDescription];
    }
    return a;
}

- (BOOL)key:(unsigned short)code { return [_keys containsIndex:code]; }

- (ControlState)poll:(float)dt {
    ControlState c = {0};
    os_unfair_lock_lock(&_lock);

    // Throttle: keyboard ramps it, a moved joystick throttle takes over.
    BOOL up = [self key:kVK_ANSI_W], down = [self key:kVK_ANSI_S];
    if (up || down) {
        if (self.throttleFromJoystick) _kbThrottle = _throttle;
        self.throttleFromJoystick = NO;
        _kbThrottle = clampf(_kbThrottle + (up ? 1.0f : -1.0f) * 0.75f * dt, 0, 1);
    }
    // The stick's throttle takes over from the keys once it is moved.
    HIDAxis *tm = _joystick ? [self axisForKey:_throttleAxis create:NO] : NULL;
    if (tm && fabsf(tm->value - tm->ref) > 0.06f) {
        tm->ref = tm->value;
        self.throttleFromJoystick = YES;
    }
    HIDAxis *ta = _joystick ? [self axisForKey:_throttleAxis create:NO] : NULL;
    float joyThrottle = 0;
    if (ta) {
        float v = _invertThrottle ? -ta->value : ta->value;
        joyThrottle = clampf((1.0f - v) * 0.5f, 0, 1);  // lever forward (min) = full
    }
    _throttle = self.throttleFromJoystick ? joyThrottle : _kbThrottle;
    c.throttle = _throttle;

    // Keyboard: arrows behave like a stick (up = push forward = nose down).
    float kp = ([self key:kVK_DownArrow] ? 1.0f : 0) - ([self key:kVK_UpArrow] ? 1.0f : 0);
    float kx = (float)[self key:kVK_RightArrow] - (float)[self key:kVK_LeftArrow];
    float ky = (float)[self key:kVK_ANSI_D] - (float)[self key:kVK_ANSI_A];
    float kr = ([self key:kVK_ANSI_E] ? 1.0f : 0) - ([self key:kVK_ANSI_Q] ? 1.0f : 0);

    float mx = 0, my = 0;
    if (self.mouseCaptured) {
        mx = deadzone((float)_stick.x, 0.04f);
        my = deadzone((float)_stick.y, 0.04f);
    }

    float jx = 0, jy = 0, jr = 0;
    if (_joystick) {
        HIDAxis *ax = [self axisForKey:AXIS_KEY(kHIDPage_GenericDesktop, kHIDUsage_GD_X) create:NO];
        HIDAxis *ay = [self axisForKey:AXIS_KEY(kHIDPage_GenericDesktop, kHIDUsage_GD_Y) create:NO];
        if (ax) jx = deadzone(ax->value, 0.06f);
        if (ay) jy = deadzone(ay->value, 0.06f);   // pull back (+) = nose up
        if (_rudderAxis) jr = deadzone([self centredAxis:_rudderAxis], 0.12f);
    }

    c.pitch = my + jy;
    c.yaw = mx + jx;
    c = [[FlightControls shared] applyTo:c];
    BOOL expert = [FlightControls shared].expert;
    c.pitch = clampf(c.pitch + kp, -1, 1);
    c.yaw = clampf(c.yaw + ky + jr + (expert ? 0 : kx), -1, 1);
    c.roll = clampf(c.roll + kr + (expert ? kx : 0), -1, 1);
    c.boost = _shift || [self key:kVK_Tab] || (_buttons & (1u << 1)) || (_buttons & (1u << 3));
    c.fire = [self key:kVK_Space] || _mouseFire || (_buttons & 1u);
    c.hat = _hat;
    if (_testFire.boolValue) c.fire = YES;
    os_unfair_lock_unlock(&_lock);
    return c;
}

@end

#endif
