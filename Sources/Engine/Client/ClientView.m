#import "ClientView.h"
#import "GameAudio.h"
#import "Localization.h"
#import "Assets.h"
#include "SharedMath.h"

#define MAX_HUD 64

typedef struct {
    simd_float3 position, velocity;
    float life;
    uint16_t id;
    BOOL active;
    BOOL awaitingId;        // predicted: the server's id comes with its EV_BOLT
} ClientBolt;

// What the client keeps about one entity in view: a fighter, capital (or
// prop, rock, buoy) or projectile. The renderer keeps its own nodes.
@interface EntityView : NSObject
@property (nonatomic) uint16_t number, model;
@property (nonatomic) uint8_t kind;
@property (nonatomic) RefModel refModel;
@property (nonatomic) const ShipDef *definition;   // fighters
@property (nonatomic) EntityState state;
@property (nonatomic) BOOL seen;
@end
@implementation EntityView
@end

@implementation ClientView {
    Input *_input;
    // Model configstring index -> renderer handle, filled while precaching.
    RefModel _refModels[MAX_MODELS];
    const ShipDef *_playerDef;
    uint16_t _playerModel;
    uint8_t _playerTeam;
    // Team relations from CS_TEAMS, parsed once per change.
    TeamRelation _relations[MAX_TEAMS][MAX_TEAMS];
    NSString *_relationsCS;
#if TARGET_OS_IOS
    UIImpactFeedbackGenerator *_weaponFeedback, *_damageFeedback;
#endif

    NSMutableDictionary<NSNumber *, EntityView *> *_views;
    ClientBolt _bolts[REF_MAX_BOLTS];
    uint32_t _boltSerial[REF_MAX_BOLTS], _nextBoltSerial;

    // The camera as last set, for projection and the HUD's edge arrows.
    simd_float3 _camPos;
    simd_quatf _camQ;
    float _fov;

    simd_quatf _camOrientation;
    float _shake, _damageFlash, _lookYaw, _lookPitch, _boostFx;
    double _time;
    NSString *_status, *_objectiveSummary, *_lastInputText;
    uint16_t _playerEntity;
    BOOL _hadPlayer;
    uint16_t _audioEntity;
    int _audioSecondary, _audioTarget;
    BOOL _audioHullLow;
}

- (instancetype)initWithRefresh:(id<Refresh>)refresh input:(Input *)input {
    if ((self = [super init])) {
        _refresh = refresh;
        _input = input;
        _hud = [[HUD alloc] initWithSize:refresh.viewSize];
        _views = [NSMutableDictionary dictionary];
        _fov = 70;
        _camOrientation = simd_quaternion(0.0f, simd_make_float3(0, 1, 0));
        _camQ = _camOrientation;
#if TARGET_OS_IOS
        if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
            _weaponFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            _damageFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        }
#endif
    }
    return self;
}

#pragma mark - Configstrings

- (NSString *)cs:(int)index {
    NSArray *cs = self.configStrings;
    return index >= 0 && index < (int)cs.count ? cs[index] : @"";
}
- (NSString *)stringAt:(uint16_t)i { return i ? [self cs:CS_STRINGS + i] : nil; }
- (NSString *)modelAt:(uint16_t)i { return i ? [self cs:CS_MODELS + i] : @""; }

// The renderer's handle for a model configstring; registered on first use
// if the precache didn't see it.
- (RefModel)refModel:(uint16_t)i {
    if (!i || i >= MAX_MODELS) return 0;
    if (!_refModels[i]) _refModels[i] = [_refresh registerModel:[self modelAt:i]];
    return _refModels[i];
}

- (void)refreshRelations {
    NSString *cs = [self cs:CS_TEAMS];
    if ([cs isEqualToString:_relationsCS]) return;
    _relationsCS = cs;
    const char *s = cs.UTF8String;
    for (int a = 0; a < MAX_TEAMS; a++)
        for (int b = 0; b < MAX_TEAMS; b++) _relations[a][b] = TeamRelationIn(s, a, b);
}

// How a team stands to the player's.
- (TeamRelation)relationTo:(uint8_t)team {
    return team < MAX_TEAMS && _playerTeam < MAX_TEAMS ? _relations[_playerTeam][team] : RelationNeutral;
}

- (float)gunSpeed { return _playerDef ? _playerDef->gun.speed : 900; }

#pragma mark - Level

- (void)loadMissionAssets:(void (^)(float))progress {
    memset(_refModels, 0, sizeof _refModels);
    uint32_t seed = (uint32_t)[self cs:CS_SKY].longLongValue;
    [_refresh beginRegistration:seed];
    if (progress) progress(0.5f);
    // Every model the mission can show, so ships that jump in later are
    // already on the GPU.
    NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
    for (int i = 1; i < MAX_MODELS; i++)
        if ([self cs:CS_MODELS + i].length) [indices addObject:@(i)];
    for (NSUInteger k = 0; k < indices.count; k++) {
        int i = indices[k].intValue;
        _refModels[i] = [_refresh registerModel:[self cs:CS_MODELS + i]];
        if (progress) progress(0.5f + 0.5f * (float)(k + 1) / (float)indices.count);
    }
}

- (void)attachMission {
    [_refresh endRegistration];
    [_hud clearMessages];
    [_hud setHelpVisible:NO];
    [_hud setObjectives:@[] states:@[]];
    _status = nil;
    _objectiveSummary = nil;
    _hadPlayer = NO;
    _damageFlash = 0;
    _shake = 0;
}

- (void)clearMission {
    [_views removeAllObjects];
    for (int i = 0; i < REF_MAX_BOLTS; i++) _bolts[i].active = NO;
    [_refresh clearWorld];
    _playerEntity = 0;
    _playerModel = 0;
    _playerDef = NULL;
}

// The player state names our ship's model.
- (void)ensurePlayerShip:(uint16_t)model {
    if (model == _playerModel) return;
    _playerModel = model;
    _playerDef = ShipDefForModel([self modelAt:model]);
    _hadPlayer = NO;   // a new hull: reset the alive bookkeeping
}

#pragma mark - Entities

- (EntityView *)makeView:(const EntityState *)s {
    EntityView *v = [EntityView new];
    v.number = s->number;
    v.model = s->model;
    v.kind = s->kind;
    v.refModel = [self refModel:s->model];
    if (s->kind == EntityFighter) v.definition = ShipDefForModel([self modelAt:s->model]);
    return v;
}

- (void)drawEntity:(EntityView *)v state:(const EntityState *)s {
    v.state = *s;
    RefEntity e = {
        .key = s->number, .kind = s->kind, .model = v.refModel, .origin = s->origin, .orientation = s->orientation,
        .scale = s->scale, .hiddenParts = s->deadParts, .throttle = s->throttle, .hull = s->hull,
        .boost = (s->flags & EF_BOOST) != 0,
    };
    [_refresh addEntity:&e];
}

- (EntityView *)viewFor:(uint16_t)number { return number ? _views[@(number)] : nil; }

- (float)radiusOf:(EntityView *)v {
    if (v.kind == EntityFighter) return v.definition ? v.definition->radius : 2;
    if (v.kind == EntityCapital) return [_refresh radiusOfModel:v.refModel] * (v.state.scale > 0 ? v.state.scale : 1);
    return 2;
}

#pragma mark - Events

#if TARGET_OS_IOS
- (void)weaponFired {
    [_weaponFeedback impactOccurred];
    [_weaponFeedback prepare];
}
#endif

// Bolts fired by the player's side look different from the rest.
- (BOOL)friendly:(uint8_t)team { return [self relationTo:team] == RelationFriendly; }

- (int)spawnBolt:(simd_float3)pos velocity:(simd_float3)vel life:(float)life friendly:(BOOL)friendly id:(uint16_t)boltId {
    for (int i = 0; i < REF_MAX_BOLTS; i++) {
        if (_bolts[i].active) continue;
        _bolts[i] = (ClientBolt){ pos, vel, life > 0 ? life : 1.6f, boltId, YES, NO };
        [_refresh showBolt:i at:pos velocity:vel friendly:friendly];
        return i;
    }
    return -1;
}

- (void)predictedShotFrom:(simd_float3)pos velocity:(simd_float3)velocity gun:(simd_float3)gunLocal life:(float)life {
    int i = [self spawnBolt:pos velocity:velocity life:life friendly:YES id:0];
    if (i >= 0) {
        _bolts[i].awaitingId = YES;
        _boltSerial[i] = ++_nextBoltSerial;
    }
    [_refresh muzzleFlashOn:_playerEntity local:gunLocal friendly:YES];
}

- (void)handleEvent:(const GameEvent *)e player:(const PlayerState *)ps {
    simd_float3 me = ps->move.origin;
    _playerTeam = ps->team;
    // Muzzle events contain ship-local positions, so only world-space events are spatialized.
    simd_float3 offset = e->pos - me;
    float distance = simd_length(offset);
    float gain = distance < 5000 ? 1.0f / (1 + distance / 650.0f) : 0;
    simd_float3 right = simd_act(ps->move.orientation, simd_make_float3(1, 0, 0));
    float pan = distance > 1 ? simd_dot(offset / distance, right) * 0.8f : 0;
    GameAudio *audio = [GameAudio shared];
    if (e->type == EV_BOLT) {
        BOOL own = e->entity && e->entity == ps->entity;
        [audio play:own ? @"laser-player" : @"laser" gain:own ? 0.8f : gain * 0.22f pan:own ? 0 : pan];
    } else if (e->type == EV_IMPACT) [audio play:@"impact" gain:gain * 0.5f pan:pan];
    else if (e->type == EV_DAMAGE && e->entity && e->entity == ps->entity) [audio play:@"impact"];
    else if (e->type == EV_EXPLOSION) [audio play:@"explosion" gain:gain pan:pan];
#if TARGET_OS_IOS
    // The server confirms each shot once, even if its bolt was already drawn.
    if (e->type == EV_BOLT && e->entity && e->entity == ps->entity) [self weaponFired];
#endif
    if (_predictedEntity && e->entity == _predictedEntity) {
        if (e->type == EV_MUZZLE) return;      // already flashed
        if (e->type == EV_BOLT) {
            // Our own shot: give its id to the oldest predicted bolt still waiting.
            int best = -1;
            for (int i = 0; i < REF_MAX_BOLTS; i++)
                if (_bolts[i].active && _bolts[i].awaitingId && (best < 0 || _boltSerial[i] < _boltSerial[best])) best = i;
            if (best >= 0) {
                _bolts[best].awaitingId = NO;
                _bolts[best].id = e->id;
                return;
            }
        }
    }
    switch (e->type) {
        case EV_BOLT:
            [self spawnBolt:e->pos velocity:e->vel life:e->scale friendly:[self friendly:e->team] id:e->id];
            break;
        case EV_IMPACT:
            if (e->id)
                for (int i = 0; i < REF_MAX_BOLTS; i++)
                    if (_bolts[i].active && _bolts[i].id == e->id) { _bolts[i].active = NO; [_refresh hideBolt:i]; break; }
            [_refresh impactAt:e->pos friendly:[self friendly:e->team] shielded:(e->flags & EVF_SHIELDED) != 0];
            break;
        case EV_MUZZLE:
            [_refresh muzzleFlashOn:e->entity local:e->pos friendly:[self friendly:e->team]];
            break;
        case EV_DAMAGE:
            if (e->flags & EVF_SHIELDED) {
                [_refresh flashShieldOn:e->entity];
            }
            if (e->entity && e->entity == ps->entity) {
                _damageFlash = 1;
                _shake = fmaxf(_shake, e->scale);
#if TARGET_OS_IOS
                [_damageFeedback impactOccurred];
                [_damageFeedback prepare];
#endif
            }
            break;
        case EV_EXPLOSION:
            [_refresh explosionAt:e->pos velocity:e->vel model:[self refModel:e->model] scale:e->scale];
            if (e->radius > 0) _shake = fmaxf(_shake, clampf(1.0f - simd_distance(e->pos, me) / e->radius, 0, 1));
            break;
        case EV_JUMP:
            [_refresh jumpFlashAt:e->pos scale:e->scale];
            break;
    }
}

- (void)serverCommand:(int)type a:(NSString *)a b:(NSString *)b c:(NSString *)c {
    // The server sends catalog tokens; show them in the player's language.
    a = L10nExpand(a);
    if (type != SVC_BANNER && type != SVC_OBJECTIVES) b = L10nExpand(b);
    c = L10nExpand(c);
    switch (type) {
        case SVC_RADIO:
            [[GameAudio shared] play:b.length ? @"ui-panel" : @"ui-alert" gain:b.length ? 0.25f : 0.7f pan:0];
            [_hud showMessage:a from:b]; break;
        case SVC_BANNER:
            [[GameAudio shared] play:[b isEqualToString:@"red"] ? @"ui-alert" : @"ui-confirm"];
            [_hud showBanner:a color:[b isEqualToString:@"red"] ? [SKColor colorWithRed:1 green:0.4 blue:0.3 alpha:1] : nil];
            break;
        case SVC_OBJECTIVES: {
            NSArray *lines = a.length ? [a componentsSeparatedByString:@"\n"] : @[];
            NSMutableArray *states = [NSMutableArray array];
            for (NSUInteger i = 0; i < b.length; i++) [states addObject:@([b characterAtIndex:i] - '0')];
            while (states.count < lines.count) [states addObject:@0];
            [_hud setObjectives:lines states:states];
            _objectiveSummary = c.length ? c : nil;
            break;
        }
        case SVC_STATUS: _status = a.length ? a : nil; break;
    }
}

#pragma mark - Frame

- (void)menuFrame:(double)time {
    [_refresh setPlayer:NULL alive:NO interior:NO];
    _camPos = simd_make_float3(0, 0, 0);
    _camQ = simd_quaternion((float)time * 0.02f, simd_make_float3(0, 1, 0));
    [_refresh setCamera:(RefCamera){ .origin = _camPos, .orientation = _camQ }];
}

- (void)updateBolts:(float)dt {
    for (int i = 0; i < REF_MAX_BOLTS; i++) {
        ClientBolt *b = &_bolts[i];
        if (!b->active) continue;
        b->position += b->velocity * dt;
        b->life -= dt;
        if (b->life <= 0) { b->active = NO; [_refresh hideBolt:i]; }
        else [_refresh moveBolt:i to:b->position];
    }
}

- (void)drawEntities:(const EntityState *)entities count:(NSUInteger)count player:(const PlayerState *)ps
            controls:(ControlState)controls time:(double)time dt:(float)dt {
    _time = time;
    [_refresh beginFrame:time];
    _playerEntity = ps->entity;
    _playerTeam = ps->team;
    [self refreshRelations];
    [self ensurePlayerShip:ps->model];

    for (EntityView *v in _views.allValues) v.seen = NO;
    for (NSUInteger i = 0; i < count; i++) {
        const EntityState *s = &entities[i];
        if (s->number == ps->entity) continue;      // drawn from the player state
        EntityView *v = _views[@(s->number)];
        if (v && (v.model != s->model || v.kind != s->kind)) v = nil;
        if (!v) _views[@(s->number)] = v = [self makeView:s];
        v.seen = YES;
        [self drawEntity:v state:s];
    }
    for (NSNumber *k in _views.allKeys)
        if (!_views[k].seen) [_views removeObjectForKey:k];
    [_refresh endFrame];

    // Own ship.
    BOOL alive = ps->alive && ps->entity;
    [[GameAudio shared] shipThrottle:ps->move.throttle boost:ps->move.boosting alive:alive];
    if (_hadPlayer && _playerEntity == _audioEntity && alive) {
        if (ps->stats[STAT_SECONDARY] < _audioSecondary) [[GameAudio shared] play:@"secondary"];
        if (ps->stats[STAT_TARGET] && ps->stats[STAT_TARGET] != _audioTarget) [[GameAudio shared] play:@"ui-hover"];
        if (ps->hull < 0.25f && !_audioHullLow) [[GameAudio shared] play:@"ui-alert"];
    }
    _audioEntity = ps->entity;
    _audioSecondary = ps->stats[STAT_SECONDARY];
    _audioTarget = ps->stats[STAT_TARGET];
    _audioHullLow = ps->hull < 0.25f;
    RefEntity me = {
        .key = ps->entity, .kind = EntityFighter, .model = [self refModel:ps->model],
        .origin = ps->move.origin, .orientation = ps->move.orientation, .scale = 1,
        .throttle = ps->move.throttle, .hull = ps->hull, .boost = ps->move.boosting,
    };
    [_refresh setPlayer:&me alive:alive interior:_cockpit];
    _hadPlayer = YES;

    [self updateBolts:dt];
    [self updateCamera:dt player:ps controls:controls];
    _damageFlash = fmaxf(0, _damageFlash - dt * 2.5f);
    [self updateHUD:ps controls:controls dt:dt];
}

#pragma mark - Camera

/// Places the chase or cockpit camera for this frame.
///
/// Everything here is smoothed over time so the view never moves abruptly:
/// - Free-look (hat) and the chase camera's orientation lag behind the ship using
///   exponential easing, `1 - exp(-k*dt)`, which doesn't depend on frame rate.
/// - Boost effects (pull-back, FOV, motion blur) are scaled by `_boostFx`, which
///   eases in and out instead of snapping between 0 and 1.
/// - Shake is a deterministic sum of sines, not per-frame random noise. Random
///   noise jumps to a new spot every frame, so it shows up as jitter (worse at
///   higher frame rates) rather than rumble.
///
/// Tuning: boost rumble amplitude is `boostFx * 0.015f`; the cockpit scale is `0.15f`.
- (void)updateCamera:(float)dt player:(const PlayerState *)ps controls:(ControlState)c {
    float targetYaw = 0, targetPitch = 0;
    if (c.hat >= 0) {
        float a = c.hat * (float)M_PI / 4.0f;
        targetYaw = sinf(a) * 1.4f;
        targetPitch = cosf(a) * 0.7f;
        if (c.hat == 4) { targetYaw = (float)M_PI * 0.95f; targetPitch = 0.1f; }
    }
    _lookYaw += (targetYaw - _lookYaw) * (1.0f - expf(-6.0f * dt));
    _lookPitch += (targetPitch - _lookPitch) * (1.0f - expf(-6.0f * dt));
    simd_quatf look = simd_mul(simd_quaternion(-_lookYaw, simd_make_float3(0, 1, 0)),
                               simd_quaternion(_lookPitch, simd_make_float3(1, 0, 0)));

    simd_quatf shipQ = ps->move.orientation;
    if (!_hadPlayer || simd_length(_camOrientation.vector) < 0.5f) _camOrientation = shipQ;
    _camOrientation = simd_slerp(_camOrientation, shipQ, 1.0f - expf(-(_cockpit ? 30.0f : 7.0f) * dt));
    simd_quatf q = simd_mul(_cockpit ? shipQ : _camOrientation, look);

    float speed = simd_length(ps->move.velocity);
    // Ease boost effects in and out so toggling boost never pops the camera.
    _boostFx += ((ps->move.boosting ? 1.0f : 0.0f) - _boostFx) * (1.0f - expf(-4.0f * dt));
    float boostFx = _boostFx;
    simd_float3 offset = _cockpit ? RefCockpitEye
                                  : simd_make_float3(0, 1.6f, 17.0f + speed * 0.012f + boostFx * 3.0f);
    simd_float3 pos = ps->move.origin + simd_act(_cockpit ? shipQ : _camOrientation, simd_act(look, offset));
    if (_cockpit) pos = ps->move.origin + simd_act(shipQ, offset);

    _shake = fmaxf(0, _shake - dt * 1.5f);
    // Smooth shake: two sines per axis, ~3-7 Hz, at frequencies with no common
    // pattern so it never visibly loops. The wobble is applied in camera space,
    // so shake stays the same relative to the screen whichever way the camera faces.
    // _shake (hits, explosions) falls off with a square curve; boost only adds a faint
    // rumble. The cockpit eye gets 15% of it all because the interior is centimetres
    // away and any movement makes the whole cockpit swim.
    float sh = _shake * _shake * 0.6f + boostFx * 0.015f;
    if (_cockpit) sh *= 0.15f;
    float t = (float)_time;
    simd_float3 wobble = simd_make_float3(sinf(t * 23.1f) * 0.6f + sinf(t * 37.7f + 1.3f) * 0.4f,
                                          sinf(t * 29.3f + 2.1f) * 0.6f + sinf(t * 41.9f + 0.7f) * 0.4f,
                                          sinf(t * 19.7f + 4.2f) * 0.6f + sinf(t * 33.1f + 3.3f) * 0.4f);
    pos += simd_act(q, wobble) * sh;

    float fov = 68.0f + speed * 0.03f + boostFx * 8.0f;
    _fov += (fov - _fov) * (1.0f - expf(-3.0f * dt));
    _camPos = pos;
    _camQ = q;
    [_refresh setCamera:(RefCamera){
        .origin = pos, .orientation = q, .fov = _fov, .zNear = _cockpit ? 0.08f : 0.3f,
        .motionBlur = boostFx * 0.25f, .focus = ps->move.origin, .velocity = ps->move.velocity,
    }];
}

#pragma mark - HUD

- (BOOL)project:(simd_float3)world into:(CGPoint *)out { return [_refresh projectPoint:world to:out]; }

- (void)fillTarget:(HUDTarget *)t at:(simd_float3)pos velocity:(simd_float3)vel radius:(float)radius size:(CGSize)size
            player:(const PlayerState *)ps {
    simd_float3 camPos = _camPos, me = ps->move.origin;
    CGPoint mid = CGPointMake(size.width / 2, size.height / 2);
    t->distance = simd_distance(pos, me);
    CGPoint p;
    BOOL front = [self project:pos into:&p];
    BOOL inside = front && p.x > 20 && p.y > 20 && p.x < size.width - 20 && p.y < size.height - 20;
    if (inside) {
        t->onScreen = YES;
        t->point = p;
        float d = simd_distance(pos, camPos);
        t->size = clampf(radius * 2.6f / fmaxf(d, 1.0f) * (float)size.height * 0.75f, 22, 260);
        simd_float3 relV = vel - ps->move.velocity;
        float gunSpeed = [self gunSpeed];
        float tHit = t->distance / gunSpeed;
        for (int k = 0; k < 2; k++) tHit = simd_distance(pos + relV * tHit, me) / gunSpeed;
        CGPoint lp = CGPointZero;
        t->hasLead = t->distance < 1500 && [self project:pos + relV * tHit into:&lp];
        t->lead = lp;
    } else {
        simd_float3 local = simd_act(simd_inverse(_camQ), pos - camPos);
        float ang = atan2f(local.y, local.x);
        float rx = size.width * 0.5f - 40, ry = size.height * 0.5f - 40;
        float cx = cosf(ang), cy = sinf(ang);
        float k = fminf(rx / fmaxf(fabsf(cx), 1e-3f), ry / fmaxf(fabsf(cy), 1e-3f));
        t->point = CGPointMake(mid.x + cx * k, mid.y + cy * k);
        t->angle = ang;
    }
}

- (BOOL)visible:(const EntityState *)s player:(const PlayerState *)ps {
    return s->stealthRange <= 0 || simd_distance(s->origin, ps->move.origin) < s->stealthRange;
}

- (BOOL)navPosition:(int)stat position:(simd_float3 *)p name:(NSString **)name {
    if (stat <= 0) return NO;
    NSArray *f = [[self cs:CS_NAVS + stat - 1] componentsSeparatedByString:@"|"];
    if (f.count < 4) return NO;
    *name = f[0];
    *p = simd_make_float3([f[1] floatValue], [f[2] floatValue], [f[3] floatValue]);
    return YES;
}

- (void)updateHUD:(const PlayerState *)ps controls:(ControlState)c dt:(float)dt {
    simd_float3 me = ps->move.origin, fwd = QuatForward(ps->move.orientation);
    uint16_t selected = (uint16_t)ps->stats[STAT_TARGET];
    EntityView *target = [self viewFor:selected];

    HUDFrame f = {0};
    CGSize size = _refresh.viewSize;
    f.boresightVisible = [self project:me + fwd * 400.0f into:&f.boresight];
    f.mouseStick = _input.mouseStick;
    f.mouseCaptured = _input.mouseCaptured;
    f.throttle = ps->move.throttle;
    f.boosting = ps->move.boosting;
    f.boostEnergy = ps->move.boostEnergy;
    f.speed = simd_length(ps->move.velocity);
    f.hull = ps->hull;
    f.shield = ps->shield;
    f.kills = ps->stats[STAT_KILLS];
    f.deaths = ps->stats[STAT_DEATHS];
    f.playerDead = !ps->alive;
    f.damageFlash = _damageFlash;
    f.cockpit = _cockpit;
    f.secondary = ps->stats[STAT_SECONDARY];
    f.secondaryCapacity = ps->stats[STAT_SECONDARY_CAPACITY];
    f.secondaryName = [self cs:CS_SECONDARY_NAME];
    f.status = _status;
    int aim = ps->stats[STAT_AIM_PART] - 1;
    const GameModelInfo *targetInfo = target.kind == EntityCapital ? [_refresh infoForModel:target.refModel] : NULL;
    if (targetInfo && aim >= 0 && aim < targetInfo->numParts) {
        EntityState ts = target.state;
        simd_float3 p = simd_act(ts.orientation, targetInfo->parts[aim].center) + ts.origin;
        f.aimVisible = [self project:p into:&f.aim];
    }

    f.deltaTime = dt;
    simd_float3 camPos = _camPos;
    simd_float3 sunDir = _refresh.sunDirection;
    simd_float3 sunPoint = camPos + sunDir * 20000.0f;
    CGPoint sp;
    if ([self project:sunPoint into:&sp]) {
        float vis = CGRectContainsPoint((CGRect){ .size = size }, sp) ? 1 : 0;
        if (vis > 0 && [_refresh traceOpaqueFrom:camPos to:camPos + sunDir * 5000.0f]) vis = 0;
        f.sun = sp;
        f.sunVisibility = vis;
    }

    HUDTarget targets[MAX_HUD];
    NSUInteger n = 0;
    NSArray<EntityView *> *views = _views.allValues;
    for (EntityView *v in views) {
        if (v.kind != EntityFighter || n >= MAX_HUD) continue;
        EntityState s = v.state;
        HUDTarget t = {0};
        TeamRelation r = [self relationTo:s.team];
        t.kind = r == RelationHostile ? HUDKindEnemy : (r == RelationFriendly ? HUDKindFriend : HUDKindNeutral);
        t.selected = s.number == selected;
        t.health = s.hull;
        t.label = [self stringAt:s.name];
        [self fillTarget:&t at:s.origin velocity:s.velocity radius:[self radiusOf:v] size:size player:ps];
        targets[n++] = t;
    }
    for (EntityView *v in views) {
        if (v.kind != EntityCapital || n >= MAX_HUD) continue;
        EntityState s = v.state;
        if ((s.flags & EF_DEAD) || ![self visible:&s player:ps]) continue;
        BOOL prop = (s.flags & EF_PROP) != 0, sel = s.number == selected;
        float d = simd_distance(s.origin, me);
        if (prop && d > ((s.flags & EF_MINE) ? 1500 : 3000) && !sel) continue;
        HUDTarget t = {0};
        TeamRelation r = [self relationTo:s.team];
        t.kind = r == RelationHostile ? HUDKindEnemy : (r == RelationFriendly ? HUDKindFriend : HUDKindNeutral);
        t.capital = !prop;
        t.selected = sel;
        NSString *name = [self stringAt:s.name];
        t.label = prop ? (sel ? name : nil) : name;
        [self fillTarget:&t at:s.origin velocity:s.velocity radius:[self radiusOf:v] * 0.6f size:size player:ps];
        targets[n++] = t;
    }
    simd_float3 navPos;
    NSString *navName = nil;
    if (n < MAX_HUD && [self navPosition:ps->stats[STAT_NAV] position:&navPos name:&navName]) {
        HUDTarget t = {0};
        t.kind = HUDKindNav;
        t.label = navName;
        [self fillTarget:&t at:navPos velocity:ps->move.velocity radius:5 size:size player:ps];
        t.hasLead = NO;
        targets[n++] = t;
    }
    [_hud updateFrame:f targets:targets count:n];
    [self updateCockpit:ps controls:c];

#if TARGET_OS_IOS
    NSString *controller = _input.joystickName;
    NSString *inputText = controller ? L10nFormat(@"hud.input_controller", controller) : @"";
#else
    NSString *inputText = L10nFormat(@"hud.input_line",
                           _input.joystickName ? L10nFormat(@"hud.input_joystick", _input.joystickName, _input.axisDescription) : L10n(@"hud.input_no_joystick"),
                           L10n(_input.throttleFromJoystick ? @"hud.input_throttle_stick" : @"hud.input_throttle_keys"),
                           L10n(_input.mouseCaptured ? @"hud.input_mouse_captured" : @"hud.input_mouse_free"),
                           [self cs:CS_SECONDARY_NAME].lowercaseString);
#endif
    if (![inputText isEqualToString:_lastInputText]) {
        _lastInputText = inputText;
        [_hud setInputText:inputText];
    }
}

#pragma mark - Cockpit

- (void)updateCockpit:(const PlayerState *)ps controls:(ControlState)c {
    simd_float3 me = ps->move.origin, fwd = QuatForward(ps->move.orientation);
    uint16_t selected = (uint16_t)ps->stats[STAT_TARGET];
    CockpitFrame f = {0};
    f.throttle = ps->move.throttle;
    f.speed = simd_length(ps->move.velocity);
    f.maxSpeed = ps->params.maxSpeed;
    f.boostEnergy = ps->move.boostEnergy;
    f.hull = ps->hull;
    f.shield = ps->shield;
    f.damageFlash = _damageFlash;
    f.boosting = ps->move.boosting;
    f.alive = ps->alive;
    f.firing = c.fire && ps->alive;
    f.pitch = c.pitch;
    f.yaw = c.yaw;
    f.roll = c.roll;
    f.kills = ps->stats[STAT_KILLS];
    f.deaths = ps->stats[STAT_DEATHS];
    f.time = ps->missionTime;
    f.target = -1;
    f.nearest = FLT_MAX;
    f.secondary = ps->stats[STAT_SECONDARY];
    f.secondaryName = [self cs:CS_SECONDARY_SHORT];
    f.objective = _objectiveSummary;
    f.weaponEnergy = ps->stats[STAT_WEAPON_ENERGY] / 1000.0f;
    f.weaponShotEnergy = _playerDef ? _playerDef->gun.energy : 0;

    simd_quatf inv = simd_inverse(ps->move.orientation);
    f.sun = simd_act(inv, _refresh.sunDirection);
    CockpitContact contacts[COCKPIT_MAX_CONTACTS];
    NSUInteger n = 0;
    NSMutableArray<EntityView *> *bodies = [NSMutableArray array];
    for (EntityView *v in _views.allValues) {
        EntityState s = v.state;
        if (s.number == ps->entity) continue;
        if (v.kind == EntityFighter && !(s.flags & EF_DEAD)) [bodies addObject:v];
        else if (v.kind == EntityCapital && !(s.flags & EF_DEAD) && [self visible:&s player:ps]) [bodies addObject:v];
    }
    // Nearest first, so the scanner keeps what matters when it overflows.
    [bodies sortUsingComparator:^NSComparisonResult(EntityView *a, EntityView *b) {
        if (a.number == selected) return NSOrderedAscending;
        if (b.number == selected) return NSOrderedDescending;
        float da = simd_distance(a.state.origin, me), db = simd_distance(b.state.origin, me);
        return da < db ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (EntityView *v in bodies) {
        if (n >= COCKPIT_MAX_CONTACTS) break;
        EntityState s = v.state;
        BOOL fighter = v.kind == EntityFighter;
        simd_float3 rel = s.origin - me;
        float dist = simd_length(rel);
        float radius = [self radiusOf:v];
        CockpitContact k = {0};
        TeamRelation relation = [self relationTo:s.team];
        BOOL hostile = relation == RelationHostile;
        k.local = simd_act(inv, rel);
        k.relation = relation;
        k.orientation = simd_mul(inv, s.orientation);
        k.hull = s.hull;
        k.shield = s.shield;
        k.systems = -1;
        k.component = L10n(@"part.hull");
        k.cargo = fighter ? L10n(@"cockpit.cargo_none") : (s.flags & EF_SCANNED) ? ([self stringAt:s.cargo].length ? [self stringAt:s.cargo] : L10n(@"cockpit.cargo_no_manifest")) : L10n(@"cockpit.unknown");
        if (fighter) {
            const ShipDef *def = v.definition;
            k.hologram = [_refresh hologramForModel:v.refModel];
            k.preview = [_refresh previewForModel:v.refModel];
            k.holoScale = def ? def->hologramScale : 0.0075f;
            k.name = [self stringAt:s.name] ?: (def ? @(def->displayName) : L10n(@"cockpit.fighter"));
            k.className = [self stringAt:s.className] ?: (def ? @(def->displayName) : @"");
            k.attacking = hostile && (s.flags & EF_ATTACKING) && s.target == ps->entity &&
                          simd_dot(QuatForward(s.orientation), -rel / fmaxf(dist, 1)) > 0.8f;
            if (k.attacking && dist < 700 && k.local.z > 0) f.six = YES;
            if (hostile) f.nearest = fminf(f.nearest, dist);
        } else {
            BOOL prop = (s.flags & EF_PROP) != 0;
            k.capital = !prop;
            k.hologram = [_refresh hologramForModel:v.refModel];
            k.preview = [_refresh previewForModel:v.refModel];
            k.holoScale = 0.04f / fmaxf(radius, 1);
            k.name = [self stringAt:s.name];
            k.className = [self stringAt:s.className];
            k.shielded = (s.flags & EF_SHIELDED) != 0;
            const GameModelInfo *info = [_refresh infoForModel:v.refModel];
            if (info && info->numParts > 0) {
                int alive = 0;
                for (int part = 0; part < info->numParts; part++) if (!(s.deadParts & (1ULL << part))) alive++;
                k.systems = (float)alive / info->numParts;
                int aim = ps->stats[STAT_AIM_PART] - 1;
                if (s.number == selected && aim >= 0 && aim < info->numParts) {
                    NSArray *names = @[@"part.turret", @"part.engine", @"part.shield", @"part.core"];
                    k.component = L10n(names[MIN(info->parts[aim].kind, 3)]);
                }
            }
            if (hostile && ((s.flags & EF_MINE) || !prop)) f.nearest = fminf(f.nearest, dist - radius);
        }
        if (s.number == selected) {
            f.target = (int)n;
            simd_float3 relV = s.velocity - ps->move.velocity;
            f.closingSpeed = -simd_dot(relV, rel / fmaxf(dist, 1));
            float gunSpeed = [self gunSpeed];
            float tHit = dist / gunSpeed;
            for (int kk = 0; kk < 2; kk++) tHit = simd_distance(s.origin + relV * tHit, me) / gunSpeed;
            simd_float3 lead = simd_normalize(s.origin + relV * tHit - me);
            float cone = fighter ? 2.5f : 2.5f + atanf(radius / fmaxf(dist, 1)) * 57.3f;
            f.lock = dist < 1200 + (fighter ? 0 : radius) && simd_dot(lead, fwd) > cosf(cone * (float)M_PI / 180.0f);
        }
        contacts[n++] = k;
    }
    if (_cockpit) [_refresh updateCockpit:f contacts:contacts count:n];
    [_hud updateInstruments:f contacts:contacts count:n cockpit:_cockpit];
}

@end
