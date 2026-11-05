// Entry points of the game module (GetGameAPI), the per-tick frame and the
// per-command client think.
#import "GLocal.h"

GameImport gi;
GWorld *level;
static GameExport ge;

void GPrint(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    gi.print(s.UTF8String);
}

@implementation GWorld

- (instancetype)init {
    if ((self = [super init])) {
        _clients = [NSMutableArray array];
        for (int i = 0; i < MAX_CLIENTS; i++) {
            GClient *c = [GClient new];
            c.index = i;
            [_clients addObject:c];
        }
        _pilots = [NSMutableArray array];
        _capitals = [NSMutableArray array];
        _torpedoes = [NSMutableArray array];
        _explosionQueue = [NSMutableArray array];
        _entityStates = [NSMutableData data];
    }
    return self;
}

- (uint16_t)allocEntity {
    if (++_nextEntity == 0) _nextEntity = 1;
    return _nextEntity;
}

- (NSArray<GFighter *> *)playerShips {
    NSMutableArray *a = [NSMutableArray array];
    for (GClient *c in _clients) if (c.inGame && c.ship) [a addObject:c.ship];
    return a;
}

- (GFighter *)leadPlayer {
    for (GClient *c in _clients) if (c.inGame && c.ship) return c.ship;
    return nil;
}

- (NSArray<GFighter *> *)fighters {
    NSMutableArray *a = [NSMutableArray arrayWithArray:[self playerShips]];
    for (GPilot *p in _pilots) [a addObject:p.ship];
    return a;
}

static EntityState FighterState(GFighter *s, GPilot *p) {
    EntityState e = {0};
    e.number = s.number;
    e.kind = EntityFighter;
    e.team = s.team;
    e.model = s.model;
    e.name = s.nameIndex;
    e.className = s.team < TeamCount ? level->_fighterClassNames[s.team] : 0;
    e.flags = s.boosting ? EF_BOOST : 0;
    id target = p.target;
    if (p && p.mode == AIModeAttack && [target isKindOfClass:[GFighter class]]) {
        e.flags |= EF_ATTACKING;
        e.target = ((GFighter *)target).number;
    }
    e.origin = s.position;
    e.velocity = s.velocity;
    e.orientation = s.orientation;
    e.scale = 1;
    e.throttle = s->move.throttle;
    e.hull = s.hull;
    e.shield = s.shield;
    return e;
}

- (void)buildEntityStates {
    _entityStates.length = 0;
    EntityState e;
    for (GClient *c in _clients) {
        if (!c.inGame || !c.ship.alive) continue;
        e = FighterState(c.ship, c.autopilot);
        [_entityStates appendBytes:&e length:sizeof e];
    }
    for (GPilot *p in _pilots) {
        if (!p.ship.alive) continue;
        e = FighterState(p.ship, p);
        [_entityStates appendBytes:&e length:sizeof e];
    }
    for (GCapital *c in _capitals) {
        if (c.hidden) continue;
        e = (EntityState){0};
        e.number = c.number;
        e.kind = c.isAsteroid ? EntityAsteroid : (c.isBuoy ? EntityBuoy : EntityCapital);
        e.team = c.team;
        e.model = c.model;
        e.name = c.name ? gi.stringIndex(c.name.UTF8String) : 0;
        e.className = gi.stringIndex(c.className.UTF8String);
        e.cargo = c.scanned && c.cargo.length ? gi.stringIndex(c.cargo.UTF8String) : 0;
        BOOL shielded = c.shielded;
        e.flags = (c.alive ? 0 : EF_DEAD) | (c.scanned ? EF_SCANNED : 0) | (shielded ? EF_SHIELDED : 0) | (c.isProp ? EF_PROP : 0) | (c.isMine ? EF_MINE : 0);
        e.origin = c.position;
        e.velocity = c.velocity;
        e.orientation = c.orientation;
        e.scale = c.scale;
        e.hull = c.hull / fmaxf(c.maxHull, 1e-3f);
        e.shield = shielded ? (float)[c aliveCount:SubsystemShield] / fmaxf([c totalCount:SubsystemShield], 1) : 0;
        e.stealthRange = c.stealthRange;
        e.deadParts = c.deadParts;
        [_entityStates appendBytes:&e length:sizeof e];
    }
    for (GTorpedo *t in _torpedoes) {
        e = (EntityState){0};
        e.number = t.number;
        e.kind = EntityProjectile;
        e.team = t.team;
        e.model = (uint16_t)t.model;
        e.origin = t.position;
        e.velocity = t.velocity;
        e.orientation = simd_quaternion(0.0f, simd_make_float3(0, 1, 0));
        e.scale = 1;
        [_entityStates appendBytes:&e length:sizeof e];
    }
}

@end

#pragma mark - Frame

static void BuildPlayerState(GClient *cl) {
    PlayerState *ps = &cl->ps;
    GFighter *s = cl.ship;
    if (s) {
        ps->move = s->move;
        ps->params = s->params;
        ps->entity = s.number;
        ps->model = (uint16_t)s.model;
        ps->team = (uint8_t)s.team;
        ps->alive = s.alive;
        ps->hull = s.hull;
        ps->shield = s.shield;
    }
    ps->missionTime = (float)level->_missionTime;
    ps->stats[STAT_WEAPON_ENERGY] = (int16_t)lroundf(s.laserEnergy * 1000);
    ps->stats[STAT_SECONDARY] = (int16_t)cl.torpedoes;
    ps->stats[STAT_SECONDARY_CAPACITY] = (int16_t)level->_startTorpedoes;
    ps->stats[STAT_KILLS] = (int16_t)cl.kills;
    ps->stats[STAT_DEATHS] = (int16_t)cl.deaths;
    ps->stats[STAT_TARGET] = BodyAlive(cl.selected) ? (int16_t)BodyNumber(cl.selected) : 0;
    ps->stats[STAT_AIM_PART] = cl.aimSubsystem ? (int16_t)cl.aimSubsystem.part + 1 : 0;
    NSUInteger nav = level->_currentNav ? [level->_navOrder indexOfObject:level->_currentNav] : NSNotFound;
    ps->stats[STAT_NAV] = nav == NSNotFound ? 0 : (int16_t)nav + 1;
}

static void RunFrame(void) {
    GWorld *w = level;
    if (!w->_running) return;
    float dt = TICK_DT;
    w->_time += dt;
    if (w->_over) return;

    for (GClient *cl in w->_clients) {
        if (!cl.inGame || !cl.autopilot || !cl.ship.alive) continue;
        simd_float3 before = cl.ship.position;
        [w thinkPilot:cl.autopilot dt:dt];
        cl.cmdTime += dt;
        [w collidePlayer:cl from:before];
    }
    for (GPilot *p in [w->_pilots copy]) [w thinkPilot:p dt:dt];
    for (GCapital *c in [w->_capitals copy]) {
        [c update:dt];
        [w fireTurrets:c];
        if (c.isMine && c.alive) [w checkMine:c];
    }
    [w updateBolts:dt];
    [w updateTorpedoes:dt];
    [w updateExplosions];
    [w updateMission:dt];

    for (GClient *cl in w->_clients) {
        if (!cl.inGame) continue;
        [w updateTargetingFor:cl];
        BuildPlayerState(cl);
    }
    [w buildEntityStates];
}

#pragma mark - Clients

static void ClientThink(int index, const UserCmd *cmd) {
    if (index < 0 || index >= MAX_CLIENTS) return;
    GWorld *w = level;
    GClient *cl = w->_clients[index];
    if (!cl.inGame) return;
    cl->ps.lastCommand = cmd->sequence;
    cl->ps.commandTime += cmd->msec;
    if (!w->_running || w->_over) return;

    GFighter *s = cl.ship;
    float dt = clampf(cmd->msec / 1000.0f, 0, 0.1f);
    if (cmd->impulse == IMPULSE_TARGET) [w cycleTargetFor:cl];
    if (cmd->impulse == IMPULSE_SECONDARY) [w fireTorpedoFor:cl];
    if (cl.autopilot || !s.alive) return;

    cl.cmdTime += dt;
    simd_float3 before = s.position;
    [s step:ShipInputFromCmd(cmd) dt:dt];
    [w collidePlayer:cl from:before];
    ShipGun gun = s.gun;
    if ((cmd->buttons & BUTTON_FIRE) && s.alive && s.laserEnergy >= gun.energy && cl.cmdTime - s.lastShot > gun.interval) {
        s.lastShot = cl.cmdTime;
        s.laserEnergy = fmaxf(0, s.laserEnergy - gun.energy);
        [w fireFrom:s.nextGunWorldPosition velocity:s.velocity direction:s.forward speed:gun.speed life:gun.life team:s.team
             damage:gun.damage capDamage:gun.capitalDamage owner:cl];
        [w muzzleFlash:s];
    }
    BuildPlayerState(cl);
}

static bool ClientConnect(int index, const char *name) {
    if (index < 0 || index >= MAX_CLIENTS) return false;
    GClient *cl = level->_clients[index];
    cl.name = @(name ?: "pilot");
    GPrint(@"%@ connected", cl.name);
    return true;
}

static void ClientBegin(int index) {
    if (index < 0 || index >= MAX_CLIENTS) return;
    GWorld *w = level;
    GClient *cl = w->_clients[index];
    cl.inGame = YES;
    memset(&cl->ps, 0, sizeof cl->ps);
    [w spawnPlayer:cl];
    BuildPlayerState(cl);
    [w buildEntityStates];
}

static void ClientDisconnect(int index) {
    if (index < 0 || index >= MAX_CLIENTS) return;
    GWorld *w = level;
    GClient *cl = w->_clients[index];
    for (int i = 0; i < MAX_BOLTS; i++) if (w->_bolts[i].owner == cl) w->_bolts[i].owner = nil;
    GPrint(@"%@ disconnected", cl.name);
    cl.inGame = NO;
    cl.ship = nil;
    cl.autopilot = nil;
    cl.selected = nil;
    [w buildEntityStates];
}

#pragma mark - Exports

static void Init(void) {
    gi.cvarRegister("g_god", "0", CVAR_CHEAT, "Players take no damage");
    gi.cvarRegister("g_autopilot", "0", CVAR_CHEAT, "The AI flies the first player's ship");
    gi.cvarRegister("g_warp", "", CVAR_CHEAT, "Entity id to spawn the first player next to, facing it");
    gi.cvarRegister("g_warpDistance", "2.2", CVAR_CHEAT, "g_warp: distance in multiples of the entity's radius");
    level = [GWorld new];
    GPrint(@"Game module initialised (API %d)", GAME_API_VERSION);
}

static void Shutdown(void) { level = nil; }

static void SpawnMission(int index) { [level spawnMission:(NSUInteger)index]; }

static int Entities(const EntityState **out) {
    *out = level->_entityStates.bytes;
    return (int)(level->_entityStates.length / sizeof(EntityState));
}

static const PlayerState *GetPlayerState(int index) {
    if (index < 0 || index >= MAX_CLIENTS) return NULL;
    return &level->_clients[index]->ps;
}

GameExport *GetGameAPI(const GameImport *import) {
    gi = *import;
    ge = (GameExport){
        .apiVersion = GAME_API_VERSION,
        .init = Init,
        .shutdown = Shutdown,
        .spawnMission = SpawnMission,
        .clientConnect = ClientConnect,
        .clientBegin = ClientBegin,
        .clientDisconnect = ClientDisconnect,
        .clientThink = ClientThink,
        .runFrame = RunFrame,
        .entities = Entities,
        .playerState = GetPlayerState,
    };
    return &ge;
}
