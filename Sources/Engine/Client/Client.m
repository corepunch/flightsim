#import "Client.h"
#include "SharedMath.h"

#define MAX_SNAPSHOTS 32

// How far behind the newest snapshot the world is drawn. One tick is enough
// over loopback; a network needs room for jitter and a lost packet.
static const double kLocalInterpDelay = TICK_DT + 0.005;

@implementation Client {
    __weak Server *_server;
    int _slot;
    NSMutableArray<NSString *> *_cs;
    NSMutableArray<Snapshot *> *_snapshots;
    uint32_t _lastEventFrame;       // events of snapshots up to this frame have been played
    double _clock, _renderTime, _latestArrival, _interpDelay;
    BOOL _renderTimeValid;
    uint32_t _sequence;
    double _msecRemainder;
    NSMutableData *_lerped;
}

- (instancetype)initWithView:(ClientView *)view {
    if ((self = [super init])) {
        _view = view;
        _cs = [NSMutableArray array];
        for (int i = 0; i < MAX_CONFIGSTRINGS; i++) [_cs addObject:@""];
        _snapshots = [NSMutableArray array];
        _lerped = [NSMutableData data];
        _slot = -1;
        _interpDelay = kLocalInterpDelay;
    }
    return self;
}

- (NSArray<NSString *> *)configStrings { return _cs; }
- (int)missionIndex { return _cs[CS_MISSION].intValue; }

#pragma mark - Connection

- (void)connectLocal:(Server *)server name:(NSString *)name {
    [self disconnect];
    _server = server;
    _slot = [server connect:self name:name];
    _connected = _slot >= 0;
    _interpDelay = kLocalInterpDelay;
}

- (void)disconnect {
    if (_connected) [_server drop:_slot];
    _connected = NO;
    _inGame = NO;
    _slot = -1;
    [self resetSnapshots];
}

- (void)resetSnapshots {
    [_snapshots removeAllObjects];
    _renderTimeValid = NO;
    _lastEventFrame = 0;
}

- (void)begin {
    if (!_connected) return;
    [self resetSnapshots];
    _inGame = YES;
    [_server begin:_slot];
}

#pragma mark - ServerClient

- (void)serverGamestate:(NSArray<NSString *> *)configStrings {
    _inGame = NO;
    [self resetSnapshots];
    for (int i = 0; i < MAX_CONFIGSTRINGS; i++) _cs[i] = i < (int)configStrings.count ? configStrings[i] : @"";
    _view.configStrings = _cs;
    if (_gamestateHandler) _gamestateHandler();
}

- (void)serverConfigString:(int)index value:(NSString *)value {
    if (index < 0 || index >= MAX_CONFIGSTRINGS) return;
    _cs[index] = value;
    _view.configStrings = _cs;
}

- (void)serverCommand:(int)type a:(NSString *)a b:(NSString *)b c:(NSString *)c {
    if (type == SVC_MISSION_END) {
        if (_missionEndHandler) _missionEndHandler([a isEqualToString:@"1"], b.length ? [b componentsSeparatedByString:@"\n"] : @[]);
        return;
    }
    [_view serverCommand:type a:a b:b c:c];
}

- (void)serverSnapshot:(Snapshot *)snapshot {
    if (!_inGame) return;
    Snapshot *last = _snapshots.lastObject;
    if (last && snapshot.frame <= last.frame) return;   // duplicate or out of order
    [_snapshots addObject:snapshot];
    if (_snapshots.count > MAX_SNAPSHOTS) [_snapshots removeObjectAtIndex:0];
    _latestArrival = _clock;
}

#pragma mark - Input

- (void)sendInput:(ControlState)c actions:(InputAction)actions dt:(float)dt {
    _clock += dt;
    if (!_inGame) return;
    _msecRemainder += dt * 1000.0;
    int msec = (int)_msecRemainder;
    if (msec < 1 && !(actions & (InputActionTarget | InputActionTorpedo))) return;
    _msecRemainder -= msec;
    msec = MIN(msec, 250);
    UserCmd cmd = {0};
    cmd.sequence = ++_sequence;
    cmd.msec = (uint8_t)msec;
    cmd.pitch = c.pitch;
    cmd.yaw = c.yaw;
    cmd.roll = c.roll;
    cmd.throttle = c.throttle;
    cmd.buttons = (c.fire ? BUTTON_FIRE : 0) | (c.boost ? BUTTON_BOOST : 0);
    cmd.impulse = (actions & InputActionTorpedo) ? IMPULSE_TORPEDO : ((actions & InputActionTarget) ? IMPULSE_TARGET : IMPULSE_NONE);
    [_server slot:_slot command:&cmd];
}

#pragma mark - Interpolation

static const EntityState *FindEntity(Snapshot *s, uint16_t number) {
    const EntityState *e = s.entityStates;
    NSUInteger lo = 0, hi = s.entityCount;
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if (e[mid].number < number) lo = mid + 1;
        else hi = mid;
    }
    return lo < s.entityCount && e[lo].number == number ? &e[lo] : NULL;
}

static ShipMoveState LerpMove(ShipMoveState a, ShipMoveState b, float t) {
    ShipMoveState m = b;
    if (simd_distance(a.origin, b.origin) > 500) return m;    // teleported (respawn, warp)
    m.origin = simd_mix(a.origin, b.origin, t);
    m.velocity = simd_mix(a.velocity, b.velocity, t);
    m.orientation = simd_slerp(a.orientation, b.orientation, t);
    m.throttle = a.throttle + (b.throttle - a.throttle) * t;
    m.boostEnergy = a.boostEnergy + (b.boostEnergy - a.boostEnergy) * t;
    return m;
}

- (void)advanceRenderTime:(float)dt {
    Snapshot *newest = _snapshots.lastObject;
    double ideal = newest.time + (_clock - _latestArrival) - _interpDelay;
    if (!_renderTimeValid || fabs(ideal - _renderTime) > 0.25) {
        _renderTime = ideal;
        _renderTimeValid = YES;
    } else {
        // Run at real speed, nudged toward the ideal so drift never builds up.
        _renderTime += dt + (ideal - _renderTime) * fmin(1.0, dt * 4.0);
    }
    _renderTime = fmin(_renderTime, newest.time);
    _renderTime = fmax(_renderTime, _snapshots.firstObject.time);
}

- (void)drawWithControls:(ControlState)controls time:(double)time dt:(float)dt {
    if (!_inGame || !_snapshots.count) return;
    [self advanceRenderTime:dt];

    // The pair of snapshots around the render time.
    Snapshot *from = _snapshots.firstObject, *to = from;
    for (Snapshot *s in _snapshots) {
        if (s.time <= _renderTime) from = s;
        if (s.time >= _renderTime) { to = s; break; }
        to = s;
    }
    float t = to.time > from.time ? (float)((_renderTime - from.time) / (to.time - from.time)) : 1.0f;
    t = clampf(t, 0, 1);

    PlayerState ps = to.ps;
    PlayerState pa = from.ps;
    ps.move = LerpMove(pa.move, ps.move, t);

    // Events happen during the tick that ends at the snapshot's time: play a
    // snapshot's events once the render time passes its start.
    for (Snapshot *s in _snapshots) {
        if (s.frame <= _lastEventFrame || s.time - TICK_DT > _renderTime + 1e-6) continue;
        _lastEventFrame = s.frame;
        const GameEvent *ev = s.events.bytes;
        for (NSUInteger i = 0, n = s.events.length / sizeof(GameEvent); i < n; i++) [_view handleEvent:&ev[i] player:&ps];
    }

    NSUInteger n = to.entityCount;
    _lerped.length = n * sizeof(EntityState);
    EntityState *out = _lerped.mutableBytes;
    const EntityState *src = to.entityStates;
    for (NSUInteger i = 0; i < n; i++) {
        out[i] = src[i];
        const EntityState *a = from == to ? NULL : FindEntity(from, src[i].number);
        if (!a || a->model != src[i].model || simd_distance(a->origin, src[i].origin) > 500) continue;
        out[i].origin = simd_mix(a->origin, src[i].origin, t);
        out[i].velocity = simd_mix(a->velocity, src[i].velocity, t);
        out[i].orientation = simd_slerp(a->orientation, src[i].orientation, t);
        out[i].throttle = a->throttle + (src[i].throttle - a->throttle) * t;
    }
    [_view drawEntities:out count:n player:&ps controls:controls time:time dt:dt];
}

@end
