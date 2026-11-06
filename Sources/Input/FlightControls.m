#import "Input.h"
#import "Common.h"

static float Sensitivity(Cvar *cvar) {
    return isfinite(cvar.value) ? clampf(cvar.value, 0.25f, 2) : 1;
}

@implementation FlightControls {
    Cvar *_expert, *_horizontal, *_vertical, *_invert, *_dynamicCamera;
}

+ (instancetype)shared {
    static FlightControls *controls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controls = [FlightControls new]; });
    return controls;
}

- (instancetype)init {
    if ((self = [super init])) {
        _expert = [Cvar get:@"in_expert" defaultValue:@"0" flags:CVAR_ARCHIVE help:@"Horizontal stick rolls instead of yawing"];
        _horizontal = [Cvar get:@"in_sensitivityX" defaultValue:@"1" flags:CVAR_ARCHIVE help:@"Horizontal flight sensitivity (0.25..2)"];
        _vertical = [Cvar get:@"in_sensitivityY" defaultValue:@"1" flags:CVAR_ARCHIVE help:@"Vertical flight sensitivity (0.25..2)"];
        _invert = [Cvar get:@"in_invertPitch" defaultValue:@"0" flags:CVAR_ARCHIVE help:@"Invert pitch on mouse, touch and primary stick"];
        _dynamicCamera = [Cvar get:@"cl_dynamicCamera" defaultValue:@"1" flags:CVAR_ARCHIVE
                              help:@"Chase camera looks into turns and leans with the ship (0: fixed behind it)"];
    }
    return self;
}

- (BOOL)expert { return _expert.boolValue; }
- (void)setExpert:(BOOL)value { [_expert setInteger:value]; }
- (BOOL)invertPitch { return _invert.boolValue; }
- (void)setInvertPitch:(BOOL)value { [_invert setInteger:value]; }
- (BOOL)dynamicCamera { return _dynamicCamera.boolValue; }
- (void)setDynamicCamera:(BOOL)value { [_dynamicCamera setInteger:value]; }
- (float)horizontalSensitivity { return Sensitivity(_horizontal); }
- (void)setHorizontalSensitivity:(float)value { [_horizontal setValue:isfinite(value) ? clampf(value, 0.25f, 2) : 1]; }
- (float)verticalSensitivity { return Sensitivity(_vertical); }
- (void)setVerticalSensitivity:(float)value { [_vertical setValue:isfinite(value) ? clampf(value, 0.25f, 2) : 1]; }

- (ControlState)applyTo:(ControlState)state {
    state.pitch = clampf(state.pitch * self.verticalSensitivity * (self.invertPitch ? -1 : 1), -1, 1);
    float horizontal = clampf(state.yaw * self.horizontalSensitivity, -1, 1);
    state.yaw = self.expert ? 0 : horizontal;
    if (self.expert) state.roll = clampf(state.roll + horizontal, -1, 1);
    return state;
}

- (void)reset {
    [_expert reset];
    [_horizontal reset];
    [_vertical reset];
    [_invert reset];
    [_dynamicCamera reset];
}
@end
