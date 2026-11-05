#import "Client.h"
#import "Net.h"
#import "Common.h"
#import <QuartzCore/QuartzCore.h>
#include "Shared.h"
#import "Shared.h"

#define MAX_SNAPSHOTS 32
#define CMD_BACKUP 64           // user commands kept (redundant resends)
#define CMD_REDUNDANCY 3        // already-sent commands repeated in each packet

// How far behind the newest snapshot the world is drawn: room for one late
// or lost snapshot. Loopback needs only one tick.
static const double kLocalInterpDelay = TICK_DT + 0.005;
static const double kNetInterpDelay = TICK_DT * 3;

@implementation Snapshot
- (NSUInteger)entityCount { return _entities.length / sizeof(EntityState); }
- (const EntityState *)entityStates { return _entities.bytes; }
@end

@implementation Client {
    id<NetTransport> _transport;
    NetChannel *_channel;
    NSString *_name;
    double _lastConnectAttempt;
    uint32_t _spawnCount;

    NSMutableArray<NSString *> *_cs;
    NSMutableArray<Snapshot *> *_snapshots;     // in game, oldest first
    Snapshot *_frames[UPDATE_BACKUP];           // every decoded frame, for delta baselines
    uint32_t _lastFrame;                        // newest decoded frame
    uint32_t _lastEventFrame;
    double _clock, _renderTime, _latestArrival, _interpDelay;
    BOOL _renderTimeValid;

    UserCmd _cmds[CMD_BACKUP];
    uint32_t _sequence, _lastSentSequence;
    double _msecRemainder, _lastMoveSent;
    NSMutableData *_lerped;

    // Prediction of our own ship.
    Snapshot *_predictionBase;          // the snapshot the last prediction started from
    simd_float3 _errorOffset;           // shown on top of the prediction, decaying to zero
    simd_quatf _errorRotation;
    double _fireClock, _lastShot;
    NSUInteger _gunIndex;
    double _statsAt, _errorSum, _errorMax;
    NSUInteger _errorCount;
    Cvar *_predict, *_netStats;
}

- (instancetype)initWithView:(ClientView *)view {
    if ((self = [super init])) {
        _view = view;
        _predict = [Cvar get:@"cl_predict" defaultValue:@"1" flags:0 help:@"Predict the player's ship between snapshots"];
        _netStats = [Cvar get:@"net_stats" defaultValue:@"0" flags:0 help:@"Log bandwidth and prediction error every 5 s"];
        _cs = [NSMutableArray array];
        for (int i = 0; i < MAX_CONFIGSTRINGS; i++) [_cs addObject:@""];
        _snapshots = [NSMutableArray array];
        _lerped = [NSMutableData data];
        _interpDelay = kLocalInterpDelay;
        _errorRotation = simd_quaternion(0.0f, simd_make_float3(0, 1, 0));
    }
    return self;
}

- (NSArray<NSString *> *)configStrings { return _cs; }
- (NSString *)levelName { return _cs[CS_LEVEL] ?: @""; }
- (NetAddress *)serverAddress { return _channel.address; }

#pragma mark - Connection

- (void)connectTo:(NetAddress *)address transport:(id<NetTransport>)transport name:(NSString *)name {
    [self disconnect];
    _transport = transport;
    _channel = [[NetChannel alloc] initWithTransport:transport address:address];
    _name = [name copy];
    _state = ClientConnecting;
    _lastConnectAttempt = -100;
    _interpDelay = address.isLoopback ? kLocalInterpDelay : kNetInterpDelay;
}

- (void)disconnect {
    if (_state >= ClientConnected) {
        MsgWriter *w = [MsgWriter new];
        [w u8:clc_stringcmd];
        [w string:@"disconnect"];
        for (int i = 0; i < 3; i++) [_channel transmit:w.data];
    }
    _state = ClientDisconnected;
    _channel = nil;
    [self resetSnapshots];
}

- (void)resetSnapshots {
    [_snapshots removeAllObjects];
    for (int i = 0; i < UPDATE_BACKUP; i++) _frames[i] = nil;
    _lastFrame = 0;
    _renderTimeValid = NO;
    _lastEventFrame = 0;
}

- (void)begin {
    if (_state != ClientConnected) return;
    [self resetSnapshots];
    _fireClock = 0;
    _lastShot = -1;
    _gunIndex = 0;
    _state = ClientActive;
    MsgWriter *w = [MsgWriter new];
    [w u8:clc_stringcmd];
    [w string:[NSString stringWithFormat:@"begin %u", _spawnCount]];
    [_channel queueReliable:w.data];
    [_channel transmit:nil];
}

- (void)leaveGame {
    if (_state == ClientActive) _state = ClientConnected;
    [self resetSnapshots];
}

#pragma mark - Packets in

- (void)readPackets {
    if (_state == ClientDisconnected) return;
    double now = CACurrentMediaTime();
    if (_state == ClientConnecting && now - _lastConnectAttempt > 1.0) {
        _lastConnectAttempt = now;
        [NetChannel sendOutOfBand:[NSString stringWithFormat:@"connect %d %@", PROTOCOL_VERSION, _name]
                        transport:_transport to:_channel.address];
    }
    NetAddress *from = nil;
    NSData *packet;
    while (_channel && (packet = [_transport receiveFrom:&from])) {
        if (![from isEqual:_channel.address]) continue;
        NSString *oob = [NetChannel outOfBandText:packet];
        if (oob) { [self connectionless:oob]; continue; }
        if (_state < ClientConnected) continue;
        NSData *payload = [_channel process:packet];
        if (payload) [self parseServer:payload];
    }
    if (_state >= ClientConnected && now - _channel.lastReceived > NET_TIMEOUT) [self dropWithReason:L10n(@"net.timed_out")];
}

- (void)connectionless:(NSString *)text {
    if ([text hasPrefix:@"client_connect"] && _state == ClientConnecting) {
        _state = ClientConnected;
        _channel.lastReceived = CACurrentMediaTime();
        NSLog(@"Client: connected to %@", _channel.address);
    } else if ([text hasPrefix:@"reject"] && _state == ClientConnecting) {
        [self dropWithReason:L10nFormat(@"net.refused", [text substringFromIndex:MIN(text.length, 7)])];
    }
}

- (void)dropWithReason:(NSString *)reason {
    NSLog(@"Client: %@", reason);
    _state = ClientDisconnected;
    _channel = nil;
    [self resetSnapshots];
    if (_disconnectHandler) _disconnectHandler(reason);
}

- (void)parseServer:(NSData *)payload {
    MsgReader *r = [[MsgReader alloc] initWithData:payload];
    while (r.remaining && !r.overflow) {
        uint8_t op = [r u8];
        switch (op) {
            case svc_nop: break;
            case svc_disconnect: [self dropWithReason:[r string]]; return;
            case svc_gamestate:
                _spawnCount = [r u32];
                for (int i = 0; i < MAX_CONFIGSTRINGS; i++) _cs[i] = @"";
                if (_state == ClientActive) _state = ClientConnected;
                [self resetSnapshots];
                break;
            case svc_configstring: {
                int index = [r u16];
                NSString *value = [r string];
                if (index < MAX_CONFIGSTRINGS) _cs[index] = value;
                if (index == CS_GAME && _state == ClientActive && ![value isEqualToString:ShipDataIdentity()]) {
                    [self disconnect];
                    [self dropWithReason:@"Incompatible game or ship data"];
                    return;
                }
                _view.configStrings = _cs;
                break;
            }
            case svc_gamestate_done:
                if ([r u32] != _spawnCount) break;
                _view.configStrings = _cs;
                if (![_cs[CS_GAME] isEqualToString:ShipDataIdentity()]) {
                    [self disconnect]; // release the server slot, too
                    [self dropWithReason:@"Incompatible game or ship data"];
                    return;
                }
                if (_gamestateHandler) _gamestateHandler();
                break;
            case svc_command: {
                int type = [r u8];
                NSString *a = [r string], *b = [r string], *c = [r string];
                if (type == SVC_LEVEL_END) {
                    if (_missionEndHandler) _missionEndHandler([a isEqualToString:@"1"], b.length ? [b componentsSeparatedByString:@"\n"] : @[]);
                } else {
                    [_view serverCommand:type a:a b:b c:c];
                }
                break;
            }
            case svc_frame: [self parseFrame:r]; break;
            default:
                NSLog(@"Client: bad server message %d", op);
                return;
        }
    }
}

- (void)parseFrame:(MsgReader *)r {
    uint32_t frame = [r u32], deltaFrom = [r u32];
    PlayerState ps;
    ReadPlayerState(r, &ps);
    Snapshot *base = nil;
    if (deltaFrom) {
        base = _frames[deltaFrom % UPDATE_BACKUP];
        if (base.frame != deltaFrom) base = nil;
    }
    NSMutableData *entities = [NSMutableData data];
    BOOL ok = ReadPacketEntities(r, base.entityStates, base.entityCount, entities);
    NSData *events = ReadEvents(r);
    // A frame against a baseline we no longer have can't be decoded; keep
    // acknowledging the last good one and the server falls back.
    if (!ok || r.overflow || (deltaFrom && !base) || _state != ClientActive) return;

    Snapshot *s = [Snapshot new];
    s.frame = frame;
    s.time = frame * (double)TICK_DT;
    s.ps = ps;
    s.entities = entities;
    s.events = events;
    _frames[frame % UPDATE_BACKUP] = s;
    if (frame <= _lastFrame) return;
#if TARGET_OS_IOS
    // Only a successful launch consumes ammo. Compare accepted snapshots for
    // the same ship so a new mission or respawn cannot trigger feedback.
    Snapshot *last = _snapshots.lastObject;
    if (last && ps.entity) {
        PlayerState previous = last.ps;
        if (ps.entity == previous.entity && ps.stats[STAT_SECONDARY] < previous.stats[STAT_SECONDARY])
            [_view weaponFired];
    }
#endif
    _lastFrame = frame;
    [_snapshots addObject:s];
    if (_snapshots.count > MAX_SNAPSHOTS) [_snapshots removeObjectAtIndex:0];
    _latestArrival = _clock;
}

#pragma mark - Packets out

- (void)sendInput:(ControlState)c actions:(InputAction)actions dt:(float)dt {
    _clock += dt;
    if (_state < ClientConnected) return;
    double now = CACurrentMediaTime();
    if (_state != ClientActive || _inputSuspended) {
        // Keepalive: carries acks and our reliable commands.
        if (_channel.hasPendingReliable || now - _channel.lastSent > 0.25) {
            MsgWriter *w = [MsgWriter new];
            [w u8:clc_nop];
            [_channel transmit:w.data];
        }
        return;
    }

    BOOL impulse = (actions & (InputActionTarget | InputActionSecondary)) != 0;
    _msecRemainder += dt * 1000.0;
    int msec = (int)_msecRemainder;
    if (msec >= 1 || impulse) {
        _msecRemainder -= msec;
        UserCmd cmd = {0};
        cmd.sequence = ++_sequence;
        cmd.msec = (uint8_t)MIN(msec, 250);
        cmd.pitch = c.pitch;
        cmd.yaw = c.yaw;
        cmd.roll = c.roll;
        cmd.throttle = c.throttle;
        cmd.buttons = (c.fire ? BUTTON_FIRE : 0) | (c.boost ? BUTTON_BOOST : 0);
        cmd.impulse = (actions & InputActionSecondary) ? IMPULSE_SECONDARY : ((actions & InputActionTarget) ? IMPULSE_TARGET : IMPULSE_NONE);
        QuantizeUserCmd(&cmd);
        _cmds[cmd.sequence % CMD_BACKUP] = cmd;
        [self predictShot:&cmd];
    }

    // Up to 60 packets a second; each carries the new commands plus the last
    // few already sent, so one lost packet loses no input.
    if (now - _lastMoveSent < 1.0 / 60.0 && !impulse) return;
    if (_sequence == _lastSentSequence && now - _lastMoveSent < 0.1) return;
    _lastMoveSent = now;
    uint32_t first = _lastSentSequence + 1 > CMD_REDUNDANCY ? _lastSentSequence + 1 - CMD_REDUNDANCY : 1;
    if (_sequence - first + 1 > 32) first = _sequence - 31;
    MsgWriter *w = [MsgWriter new];
    [w u8:clc_move];
    [w u32:_lastFrame];
    uint32_t count = _sequence >= first ? _sequence - first + 1 : 0;
    [w u8:(uint8_t)count];
    for (uint32_t s = first; s <= _sequence && count; s++) WriteUserCmd(w, &_cmds[s % CMD_BACKUP]);
    _lastSentSequence = _sequence;
    [_channel transmit:w.data];
}

#pragma mark - Prediction

// Our ship as of the newest command: the server's state after the last
// command it ran, plus every command since, through the same flight model.
// Ramming capitals isn't predicted; the server's bounce shows up as a
// (smoothed) correction.
- (BOOL)predictFrom:(Snapshot *)s into:(ShipMoveState *)out {
    // The autopilot (a game cvar, visible here on a listen server) flies on
    // the server and ignores our commands.
    BOOL disabled = !_predict.boolValue || [Cvar valueOf:@"g_autopilot"] != 0;
    PlayerState ps = s.ps;
    if (disabled || !s || !ps.alive || !ps.entity || _sequence - ps.lastCommand >= CMD_BACKUP) return NO;
    ShipMoveState m = ps.move;
    for (uint32_t q = ps.lastCommand + 1; q <= _sequence; q++) {
        const UserCmd *c = &_cmds[q % CMD_BACKUP];
        ShipMove(&m, &ps.params, ShipInputFromCmd(c), clampf(c->msec / 1000.0f, 0, 0.1f));
    }
    *out = m;
    return YES;
}

// Guns fire on the same clock the server keeps for us (seconds of commands
// run), so predicted shots line up with the server's. The gun comes from
// our ship's definition, which the player state names.
static const EntityState *FindEntity(Snapshot *s, uint16_t number);

- (void)predictShot:(const UserCmd *)cmd {
    ShipMoveState m;
    Snapshot *newest = _snapshots.lastObject;
    if (![self predictFrom:newest into:&m]) return;
    _fireClock += clampf(cmd->msec / 1000.0f, 0, 0.1f);
    PlayerState ps = newest.ps;
    const ShipDef *def = ps.model ? ShipDefForModel(_cs[CS_MODELS + ps.model]) : NULL;
    if (!def || !def->gunCount) return;
    ShipGun gun = def->gun;
    if (!(cmd->buttons & BUTTON_FIRE) || _fireClock - _lastShot <= gun.interval ||
        ps.stats[STAT_WEAPON_ENERGY] < (int)(gun.energy * 1000)) return;
    _lastShot = _fireClock;
    simd_float3 muzzle = def->guns[_gunIndex++ % def->gunCount];
    simd_float3 from = m.origin + simd_act(m.orientation, muzzle), dir = QuatForward(m.orientation);
    // Aim assist as the game applies it, against the newest snapshot. Capitals
    // aim at a subsystem the client can't place, so their shots fly straight
    // until the server's EV_BOLT re-aims them.
    const EntityState *t = FindEntity(newest, (uint16_t)ps.stats[STAT_TARGET]);
    float cone = gun.assist * fmaxf(0, [Cvar valueOf:@"g_aimAssist"]) * (float)M_PI / 180.0f;
    if (t && t->kind == EntityFighter && TeamRelationIn(_cs[CS_TEAMS].UTF8String, ps.team, t->team) == RelationHostile)
        dir = AimAssist(dir, from, m.velocity, t->origin, t->velocity, gun.speed, gun.speed * gun.life, cone);
    [_view predictedShotFrom:from velocity:m.velocity + dir * gun.speed gun:muzzle life:gun.life];
}

- (BOOL)predictedMove:(ShipMoveState *)out dt:(float)dt {
    Snapshot *newest = _snapshots.lastObject;
    ShipMoveState now;
    if (![self predictFrom:newest into:&now]) {
        _predictionBase = nil;
        return NO;
    }
    // A new snapshot moves the starting point. Whatever that changes in the
    // prediction is a correction: hide it and let it fade instead of popping.
    if (_predictionBase && _predictionBase != newest) {
        ShipMoveState before;
        if ([self predictFrom:_predictionBase into:&before]) {
            simd_float3 jump = before.origin - now.origin;
            _errorSum += simd_length(jump);
            _errorMax = fmax(_errorMax, simd_length(jump));
            _errorCount++;
            if (simd_length(jump) < 30) {
                _errorOffset += jump;
                _errorRotation = simd_normalize(simd_mul(simd_mul(before.orientation, simd_inverse(now.orientation)), _errorRotation));
            } else {
                _errorOffset = 0;   // a real teleport
                _errorRotation = simd_quaternion(0.0f, simd_make_float3(0, 1, 0));
            }
        }
    }
    _predictionBase = newest;
    if (_netStats.boolValue && _clock - _statsAt >= 5) {   // how far off prediction was
        _statsAt = _clock;
        if (_errorCount) NSLog(@"Client: prediction corrections avg %.3f m, max %.3f m over %lu snapshots",
                               _errorSum / _errorCount, _errorMax, (unsigned long)_errorCount);
        _errorSum = _errorMax = 0;
        _errorCount = 0;
    }
    float k = 1.0f - expf(-12.0f * dt);
    _errorOffset *= 1.0f - k;
    _errorRotation = simd_slerp(_errorRotation, simd_quaternion(0.0f, simd_make_float3(0, 1, 0)), k);
    if (simd_length(_errorRotation.vector) < 0.5f) _errorRotation = simd_quaternion(0.0f, simd_make_float3(0, 1, 0));
    now.origin += _errorOffset;
    now.orientation = simd_normalize(simd_mul(_errorRotation, now.orientation));
    *out = now;
    return YES;
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
    if (_state != ClientActive || !_snapshots.count) return;
    [self advanceRenderTime:dt];

    // The pair of snapshots around the render time.
    Snapshot *from = _snapshots.firstObject, *to = from;
    for (Snapshot *s in _snapshots) {
        if (s.time <= _renderTime) from = s;
        to = s;
        if (s.time >= _renderTime) break;
    }
    float t = to.time > from.time ? (float)((_renderTime - from.time) / (to.time - from.time)) : 1.0f;
    t = clampf(t, 0, 1);

    // Our own ship is drawn where we predict it, now; everything else a
    // little in the past, between snapshots.
    PlayerState ps = to.ps;
    PlayerState pa = from.ps;
    ShipMoveState predicted;
    BOOL predicting = [self predictedMove:&predicted dt:dt];
    if (predicting) {
        PlayerState newest = _snapshots.lastObject.ps;
        ps = newest;
        ps.move = predicted;
    } else {
        ps.move = LerpMove(pa.move, ps.move, t);
    }
    _view.predictedEntity = predicting ? ps.entity : 0;

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
