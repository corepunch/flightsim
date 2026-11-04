#import "Server.h"
#import "ModelInfo.h"

@implementation Snapshot
- (NSUInteger)entityCount { return _entities.length / sizeof(EntityState); }
- (const EntityState *)entityStates { return _entities.bytes; }
@end

@interface ServerSlot : NSObject
@property (nonatomic, strong) id<ServerClient> client;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL inGame;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *outbox;
@end
@implementation ServerSlot
@end

// The game's imports are plain C functions, so they reach the server through
// this. One server per process, as in Quake.
static __unsafe_unretained Server *sv;

@implementation Server {
    GameExport *_ge;
    NSMutableArray<NSString *> *_configStrings;
    NSMutableDictionary<NSNumber *, ModelInfo *> *_models;
    NSMutableArray<ServerSlot *> *_slots;
    NSMutableData *_events;
    double _accumulator;
    uint32_t _frame;
}

#pragma mark - Game imports

static void SV_Print(const char *text) { NSLog(@"[game] %s", text); }

static int SV_FindOrAdd(int base, int max, const char *s) {
    NSString *value = @(s ?: "");
    if (!value.length) return 0;
    for (int i = 1; i < max; i++)
        if ([sv->_configStrings[base + i] isEqualToString:value]) return i;
    for (int i = 1; i < max; i++)
        if (!sv->_configStrings[base + i].length) {
            [sv setConfigString:base + i value:value];
            return i;
        }
    NSLog(@"Server: configstrings full at %d", base);
    return 0;
}

static int SV_ModelIndex(const char *name) {
    int i = SV_FindOrAdd(CS_MODELS, MAX_MODELS, name);
    if (i && !sv->_models[@(i)]) {
        NSArray *f = [@(name) componentsSeparatedByString:@":"];
        if (f.count >= 2 && [f[0] isEqualToString:@"cap"]) sv->_models[@(i)] = [ModelInfo capitalAsset:f[1]];
    }
    return i;
}

static int SV_StringIndex(const char *text) { return SV_FindOrAdd(CS_STRINGS, MAX_STRINGS, text); }

static void SV_ConfigString(int index, const char *value) {
    if (index < 0 || index >= MAX_CONFIGSTRINGS) return;
    [sv setConfigString:index value:@(value ?: "")];
}

static const GameModelInfo *SV_ModelInfo(int model) { return sv->_models[@(model)].info; }

static bool SV_Trace(int model, simd_float3 origin, simd_quatf q, float scale, uint64_t deadParts,
                     simd_float3 from, simd_float3 to, GameTrace *out) {
    ModelInfo *m = sv->_models[@(model)];
    if (!m) return false;
    simd_quatf inv = simd_inverse(q);
    float s = scale > 0 ? scale : 1;
    simd_float3 a = simd_act(inv, from - origin) / s, b = simd_act(inv, to - origin) / s;
    simd_float3 p;
    int part;
    if (![m traceFrom:a to:b deadParts:deadParts point:&p part:&part]) return false;
    out->point = simd_act(q, p * s) + origin;
    out->part = part;
    return true;
}

static void SV_Event(const GameEvent *e) {
    if (sv->_events.length / sizeof(GameEvent) >= MAX_EVENTS) return;
    [sv->_events appendBytes:e length:sizeof *e];
}

static void SV_Command(int client, int type, const char *a, const char *b, const char *c) {
    NSString *sa = @(a ?: ""), *sb = @(b ?: ""), *sc = @(c ?: "");
    for (NSUInteger i = 0; i < sv->_slots.count; i++) {
        if (client >= 0 && (int)i != client) continue;
        ServerSlot *slot = sv->_slots[i];
        if (!slot.client) continue;
        id<ServerClient> to = slot.client;
        [sv queue:slot block:^{ [to serverCommand:type a:sa b:sb c:sc]; }];
    }
}

#pragma mark - Lifecycle

- (instancetype)init {
    if ((self = [super init])) {
        sv = self;
        _configStrings = [NSMutableArray arrayWithCapacity:MAX_CONFIGSTRINGS];
        for (int i = 0; i < MAX_CONFIGSTRINGS; i++) [_configStrings addObject:@""];
        _models = [NSMutableDictionary dictionary];
        _slots = [NSMutableArray array];
        for (int i = 0; i < MAX_CLIENTS; i++) {
            ServerSlot *s = [ServerSlot new];
            s.outbox = [NSMutableArray array];
            [_slots addObject:s];
        }
        _events = [NSMutableData data];

        GameImport gi = {
            .apiVersion = GAME_API_VERSION,
            .print = SV_Print,
            .modelIndex = SV_ModelIndex,
            .stringIndex = SV_StringIndex,
            .configString = SV_ConfigString,
            .modelInfo = SV_ModelInfo,
            .trace = SV_Trace,
            .event = SV_Event,
            .command = SV_Command,
        };
        _ge = GetGameAPI(&gi);
        if (!_ge || _ge->apiVersion != GAME_API_VERSION) {
            NSLog(@"Server: game API version mismatch");
            return nil;
        }
        _ge->init();
    }
    return self;
}

- (void)dealloc {
    if (_ge) _ge->shutdown();
    if (sv == self) sv = nil;
}

- (double)time { return _frame * (double)TICK_DT; }

- (void)queue:(ServerSlot *)slot block:(dispatch_block_t)block {
    @synchronized (slot.outbox) { [slot.outbox addObject:block]; }
}

- (void)setConfigString:(int)index value:(NSString *)value {
    if ([_configStrings[index] isEqualToString:value]) return;
    _configStrings[index] = value;
    for (ServerSlot *slot in _slots) {
        id<ServerClient> to = slot.client;
        if (to) [self queue:slot block:^{ [to serverConfigString:index value:value]; }];
    }
}

- (void)sendGamestate:(ServerSlot *)slot {
    NSArray *cs = [_configStrings copy];
    id<ServerClient> to = slot.client;
    [self queue:slot block:^{ [to serverGamestate:cs]; }];
}

- (void)spawnMission:(int)missionIndex {
    _running = NO;
    for (int i = 0; i < MAX_CONFIGSTRINGS; i++) _configStrings[i] = @"";
    [_models removeAllObjects];
    _events.length = 0;
    for (NSUInteger i = 0; i < _slots.count; i++) _slots[i].inGame = NO;
    _ge->spawnMission(missionIndex);
    _accumulator = 0;
    _running = YES;
    for (ServerSlot *slot in _slots) if (slot.client) [self sendGamestate:slot];
}

- (void)stop {
    _running = NO;
    for (NSUInteger i = 0; i < _slots.count; i++) if (_slots[i].inGame) _ge->clientDisconnect((int)i);
    for (ServerSlot *slot in _slots) slot.inGame = NO;
}

#pragma mark - Clients

- (int)connect:(id<ServerClient>)client name:(NSString *)name {
    for (NSUInteger i = 0; i < _slots.count; i++) {
        ServerSlot *slot = _slots[i];
        if (slot.client) continue;
        if (!_ge->clientConnect((int)i, name.UTF8String)) return -1;
        slot.client = client;
        slot.name = name;
        if (_running) [self sendGamestate:slot];
        return (int)i;
    }
    return -1;
}

- (void)begin:(int)i {
    if (i < 0 || i >= (int)_slots.count || !_slots[i].client || !_running) return;
    _slots[i].inGame = YES;
    _ge->clientBegin(i);
}

- (void)drop:(int)i {
    if (i < 0 || i >= (int)_slots.count || !_slots[i].client) return;
    if (_slots[i].inGame) _ge->clientDisconnect(i);
    _slots[i].inGame = NO;
    _slots[i].client = nil;
    @synchronized (_slots[i].outbox) { [_slots[i].outbox removeAllObjects]; }
}

- (void)slot:(int)i command:(const UserCmd *)cmd {
    if (!_running || i < 0 || i >= (int)_slots.count || !_slots[i].inGame) return;
    _ge->clientThink(i, cmd);
}

#pragma mark - Frame

- (void)frame:(double)dt {
    if (_running) {
        _accumulator = fmin(_accumulator + dt, 0.25);   // after a hitch, skip rather than spiral
        while (_accumulator >= TICK_DT) {
            _accumulator -= TICK_DT;
            _ge->runFrame();
            _frame++;
            [self sendSnapshots];
        }
    }
    [self flush];
}

static int CompareEntities(const void *a, const void *b) {
    return (int)((const EntityState *)a)->number - (int)((const EntityState *)b)->number;
}

- (void)sendSnapshots {
    const EntityState *ents = NULL;
    int n = _ge->entities(&ents);
    NSMutableData *entities = [NSMutableData dataWithBytes:ents length:(NSUInteger)n * sizeof(EntityState)];
    qsort(entities.mutableBytes, (size_t)n, sizeof(EntityState), CompareEntities);
    NSData *events = [_events copy];
    _events.length = 0;
    for (NSUInteger i = 0; i < _slots.count; i++) {
        ServerSlot *slot = _slots[i];
        if (!slot.inGame) continue;
        Snapshot *s = [Snapshot new];
        s.frame = _frame;
        s.time = self.time;
        const PlayerState *ps = _ge->playerState((int)i);
        if (ps) s.ps = *ps;
        s.entities = entities;
        s.events = events;
        id<ServerClient> to = slot.client;
        [self queue:slot block:^{ [to serverSnapshot:s]; }];
    }
}

- (void)flush {
    for (ServerSlot *slot in _slots) {
        NSArray *blocks;
        @synchronized (slot.outbox) {
            blocks = [slot.outbox copy];
            [slot.outbox removeAllObjects];
        }
        for (dispatch_block_t b in blocks) b();
    }
}

@end
