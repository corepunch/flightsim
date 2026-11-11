#import "Server.h"
#import "Collision.h"
#import "Net.h"
#import "Common.h"
#import <QuartzCore/QuartzCore.h>

typedef NS_ENUM(NSInteger, SlotState) { SlotFree, SlotConnected, SlotInGame };

@interface ServerSlot : NSObject {
@public
    uint32_t frameNumbers[UPDATE_BACKUP];
    __strong NSData *frameEntities[UPDATE_BACKUP];  // quantized, as the client decoded them
}
@property (nonatomic) SlotState state;
@property (nonatomic, strong) NetChannel *channel;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t lastCommand;     // sequence of the last user command run
@property (nonatomic) uint32_t deltaFrame;      // last frame the client says it has, 0 none
@end
@implementation ServerSlot
@end

// The game's imports are plain C functions, so they reach the server through
// this. One server per process, as in Quake.
static __unsafe_unretained Server *sv;

@implementation Server {
    GameExport *_ge;
    NSMutableArray<id<NetTransport>> *_transports;
    NSMutableArray<NSString *> *_configStrings;
    NSMutableDictionary<NSNumber *, ModelInfo *> *_models;
    NSMutableArray<ServerSlot *> *_slots;
    NSMutableData *_events;
    double _accumulator, _statsAt;
    uint32_t _frame, _spawnCount;
    Cvar *_netStats;
    BOOL _paused;
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
    if (type == SVC_LEVEL_END || type == SVC_MATCH_END) sv->_missionEnded = YES;
    MsgWriter *w = [MsgWriter new];
    [w u8:svc_command];
    [w u8:(uint8_t)type];
    [w string:@(a ?: "")];
    [w string:@(b ?: "")];
    [w string:@(c ?: "")];
    for (NSUInteger i = 0; i < sv->_slots.count; i++) {
        if (client >= 0 && (int)i != client) continue;
        ServerSlot *slot = sv->_slots[i];
        if (slot.state == SlotInGame) [slot.channel queueReliable:w.data];
    }
}

static void SV_CvarRegister(const char *name, const char *value, int flags, const char *help) {
    [Cvar get:@(name ?: "") defaultValue:@(value ?: "") flags:(unsigned)flags help:help ? @(help) : nil];
}
static const char *SV_CvarString(const char *name) { return [Cvar stringOf:@(name ?: "")].UTF8String; }
static float SV_CvarValue(const char *name) { return [Cvar valueOf:@(name ?: "")]; }
static void SV_CvarSet(const char *name, const char *value) { [Cvar set:@(name ?: "") value:@(value ?: "")]; }

#pragma mark - Lifecycle

- (instancetype)initWithName:(NSString *)name {
    if ((self = [super init])) {
        sv = self;
        _name = [name copy];
        _matchSettings = LANMatchSettingsDefault();
        _transports = [NSMutableArray array];
        _configStrings = [NSMutableArray arrayWithCapacity:MAX_CONFIGSTRINGS];
        for (int i = 0; i < MAX_CONFIGSTRINGS; i++) [_configStrings addObject:@""];
        _models = [NSMutableDictionary dictionary];
        _slots = [NSMutableArray array];
        for (int i = 0; i < MAX_CLIENTS; i++) [_slots addObject:[ServerSlot new]];
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
            .cvarRegister = SV_CvarRegister,
            .cvarString = SV_CvarString,
            .cvarValue = SV_CvarValue,
            .cvarSet = SV_CvarSet,
        };
        _netStats = [Cvar get:@"net_stats" defaultValue:@"0" flags:0 help:@"Log bandwidth and prediction error every 5 s"];
        GetGameAPIFunc getGameAPI = GameLoaderOpen();
        if (!getGameAPI) return nil;
        _ge = getGameAPI(&gi);
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

- (void)addTransport:(id<NetTransport>)transport { [_transports addObject:transport]; }

- (double)time { return _frame * (double)TICK_DT; }

- (int)clientCount {
    int n = 0;
    for (ServerSlot *s in _slots) if (s.state != SlotFree) n++;
    return n;
}

- (NSArray<NSString *> *)clientNames {
    NSMutableArray *names = [NSMutableArray array];
    for (ServerSlot *s in _slots) if (s.state != SlotFree) [names addObject:s.name ?: @""];
    return names;
}

- (void)closeSession {
    self.publicHosting = NO;
    [self stop];
    for (NSUInteger i = 0; i < _slots.count; i++)
        if (_slots[i].state != SlotFree && !_slots[i].channel.address.isLoopback)
            [self drop:(int)i reason:[NSString stringWithFormat:@"{#%@}", @"net.host_closed"]];
}

#pragma mark - Configstrings and gamestate

static NSData *ConfigStringMessage(int index, NSString *value) {
    MsgWriter *w = [MsgWriter new];
    [w u8:svc_configstring];
    [w u16:(uint16_t)index];
    [w string:value];
    return w.data;
}

- (void)setConfigString:(int)index value:(NSString *)value {
    if ([_configStrings[index] isEqualToString:value]) return;
    _configStrings[index] = value;
    if (self.loading) return;   // the gamestate sent after loading carries it
    NSData *msg = ConfigStringMessage(index, value);
    for (ServerSlot *slot in _slots) if (slot.state != SlotFree) [slot.channel queueReliable:msg];
}

- (void)sendGamestate:(ServerSlot *)slot {
    MsgWriter *w = [MsgWriter new];
    [w u8:svc_gamestate];
    [w u32:_spawnCount];
    [slot.channel queueReliable:w.data];
    for (int i = 0; i < MAX_CONFIGSTRINGS; i++)
        if (_configStrings[i].length) [slot.channel queueReliable:ConfigStringMessage(i, _configStrings[i])];
    w = [MsgWriter new];
    [w u8:svc_gamestate_done];
    [w u32:_spawnCount];
    [slot.channel queueReliable:w.data];
}

- (void)spawnLevel:(NSString *)name {
    _running = NO;
    for (NSUInteger i = 0; i < _slots.count; i++) {
        ServerSlot *slot = _slots[i];
        if (slot.state != SlotInGame) continue;
        _ge->clientDisconnect((int)i);
        slot.state = SlotConnected;
    }
    for (int i = 0; i < MAX_CONFIGSTRINGS; i++) _configStrings[i] = @"";
    [_models removeAllObjects];
    _events.length = 0;
    _missionEnded = NO;
    [Cvar applyLatched];
    _ge->spawnLevel(name.UTF8String ?: "");
    _spawnCount++;
    _accumulator = 0;
    _running = YES;
    for (ServerSlot *slot in _slots) if (slot.state != SlotFree) [self sendGamestate:slot];
}

- (void)stop {
    _running = NO;
    for (NSUInteger i = 0; i < _slots.count; i++) {
        ServerSlot *slot = _slots[i];
        if (slot.state != SlotInGame) continue;
        _ge->clientDisconnect((int)i);
        slot.state = SlotConnected;
    }
}

#pragma mark - Packets

- (void)readPackets {
    for (id<NetTransport> t in _transports) {
        NetAddress *from = nil;
        NSData *packet;
        while ((packet = [t receiveFrom:&from])) {
            NSString *oob = [NetChannel outOfBandText:packet];
            if (oob) { [self connectionless:oob from:from transport:t]; continue; }
            for (NSUInteger i = 0; i < _slots.count; i++) {
                ServerSlot *slot = _slots[i];
                if (slot.state == SlotFree || ![slot.channel.address isEqual:from]) continue;
                NSData *payload = [slot.channel process:packet];
                if (payload) [self parseClient:(int)i payload:payload];
                break;
            }
        }
    }
}

- (void)connectionless:(NSString *)text from:(NetAddress *)from transport:(id<NetTransport>)t {
    if (!self.publicHosting && !from.isLoopback) return;
    NSArray *args = [text componentsSeparatedByString:@" "];
    NSString *cmd = args.firstObject;
    if ([cmd isEqualToString:@"lobby"]) {
        NSString *info = LANLobbyEncode((LANLobbyInfo){.pilots=self.clientNames, .settings=_matchSettings});
        [NetChannel sendOutOfBand:[@"lobby_response " stringByAppendingString:info] transport:t to:from];
    } else if ([cmd isEqualToString:@"info"]) {
        NSString *mission = _running ? _configStrings[CS_LEVEL] : @"-";
        [NetChannel sendOutOfBand:[NSString stringWithFormat:@"info_response %d %d %@ %@", self.clientCount, _matchSettings.maxPilots, mission, _name]
                        transport:t to:from];
    } else if ([cmd isEqualToString:@"connect"]) {
        if (args.count < 2 || [args[1] intValue] != PROTOCOL_VERSION) {
            [NetChannel sendOutOfBand:@"reject protocol" transport:t to:from];
            return;
        }
        NSString *name = args.count > 2 ? [[args subarrayWithRange:NSMakeRange(2, args.count - 2)] componentsJoinedByString:@" "] : @"pilot";
        name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length > 48) name = [name substringToIndex:[name rangeOfComposedCharacterSequenceAtIndex:48].location];
        if (!name.length) name = @"pilot";
        // A client reconnecting from the same address takes its old slot.
        int index = -1;
        for (NSUInteger i = 0; i < _slots.count; i++)
            if (_slots[i].state != SlotFree && [_slots[i].channel.address isEqual:from]) { [self drop:(int)i reason:nil]; index = (int)i; break; }
        if (index < 0)
            for (NSUInteger i = 0; i < _slots.count; i++) if (_slots[i].state == SlotFree) { index = (int)i; break; }
        if (index < 0 || self.clientCount >= _matchSettings.maxPilots || !_ge->clientConnect(index, name.UTF8String)) {
            [NetChannel sendOutOfBand:@"reject full" transport:t to:from];
            return;
        }
        ServerSlot *slot = _slots[index];
        slot.state = SlotConnected;
        slot.name = name;
        slot.channel = [[NetChannel alloc] initWithTransport:t address:from];
        slot.lastCommand = 0;
        slot.deltaFrame = 0;
        for (int i = 0; i < UPDATE_BACKUP; i++) { slot->frameNumbers[i] = 0; slot->frameEntities[i] = nil; }
        NSLog(@"Server: %@ connected from %@ (slot %d)", name, from, index);
        [NetChannel sendOutOfBand:[NSString stringWithFormat:@"client_connect %d", index] transport:t to:from];
        if (_running) [self sendGamestate:slot];
    }
}

- (void)parseClient:(int)index payload:(NSData *)payload {
    ServerSlot *slot = _slots[index];
    MsgReader *r = [[MsgReader alloc] initWithData:payload];
    while (r.remaining && !r.overflow) {
        uint8_t op = [r u8];
        if (op == clc_nop) continue;
        if (op == clc_move) {
            uint32_t delta = [r u32];
            NSUInteger count = [r u8];
            slot.deltaFrame = delta;   // packets arrive in order: this is the client's newest
            for (NSUInteger i = 0; i < count && !r.overflow; i++) {
                UserCmd cmd;
                ReadUserCmd(r, &cmd);
                if (r.overflow || cmd.sequence <= slot.lastCommand) continue;   // already run (redundant copy)
                slot.lastCommand = cmd.sequence;
                if (slot.state == SlotInGame && _running && !_paused) _ge->clientThink(index, &cmd);
            }
        } else if (op == clc_stringcmd) {
            NSArray *args = [[r string] componentsSeparatedByString:@" "];
            if ([args.firstObject isEqualToString:@"begin"]) {
                if (_running && slot.state == SlotConnected && [args.lastObject intValue] == (int)_spawnCount) {
                    slot.state = SlotInGame;
                    slot.deltaFrame = 0;
                    for (int i = 0; i < UPDATE_BACKUP; i++) { slot->frameNumbers[i] = 0; slot->frameEntities[i] = nil; }
                    _ge->clientBegin(index);
                }
            } else if ([args.firstObject isEqualToString:@"disconnect"]) {
                [self drop:index reason:nil];
                return;
            }
        } else {
            NSLog(@"Server: bad message %d from slot %d", op, index);
            return;
        }
    }
}

- (void)drop:(int)index reason:(NSString *)reason {
    ServerSlot *slot = _slots[index];
    if (slot.state == SlotFree) return;
    if (reason) {
        MsgWriter *w = [MsgWriter new];
        [w u8:svc_disconnect];
        [w string:reason];
        // Unreliable, three times: the client may be gone already.
        for (int i = 0; i < 3; i++) [slot.channel transmit:w.data];
    }
    NSLog(@"Server: %@ dropped%@", slot.name, reason ? [@": " stringByAppendingString:reason] : @"");
    _ge->clientDisconnect(index);
    slot.state = SlotFree;
    slot.channel = nil;
}

#pragma mark - Frame

static int CompareEntities(const void *a, const void *b) {
    return (int)((const EntityState *)a)->number - (int)((const EntityState *)b)->number;
}

- (void)frame:(double)dt {
    [self frame:dt paused:NO];
}

- (void)frame:(double)dt paused:(BOOL)paused {
    if (self.loading) return;   // packets wait in the transports
    _paused = paused;
    [self readPackets];
    if (_running && !paused) {
        _accumulator = fmin(_accumulator + dt, 0.25);   // after a hitch, skip rather than spiral
        while (_accumulator >= TICK_DT) {
            _accumulator -= TICK_DT;
            _ge->runFrame();
            _frame++;
            [self sendSnapshots];
        }
    }
    double now = CACurrentMediaTime();
    if (_netStats.boolValue && now - _statsAt >= 5) {   // outgoing bandwidth per client
        double span = _statsAt > 0 ? now - _statsAt : 0;
        _statsAt = now;
        for (ServerSlot *slot in _slots) {
            if (slot.state == SlotFree || span <= 0) continue;
            NetChannel *c = slot.channel;
            NSLog(@"Server: %@: %.1f kB/s, %.0f packets/s, %lu dropped by client",
                  slot.name, c.bytesSent / span / 1024.0, c.packetsSent / span, (unsigned long)c.droppedPackets);
            c.bytesSent = c.packetsSent = 0;
        }
    }
    for (NSUInteger i = 0; i < _slots.count; i++) {
        ServerSlot *slot = _slots[i];
        if (slot.state == SlotFree) continue;
        if (!slot.channel.address.isLoopback && now - slot.channel.lastReceived > NET_TIMEOUT) {
            [self drop:(int)i reason:@"timed out"];
            continue;
        }
        // Keep the channel moving between snapshots: reliable data, acks.
        if (slot.state != SlotInGame || !_running || paused)
            if (slot.channel.hasPendingReliable || now - slot.channel.lastSent > 0.25) [slot.channel transmit:nil];
    }
}

- (void)sendSnapshots {
    const EntityState *ents = NULL;
    int n = _ge->entities(&ents);
    NSMutableData *entities = [NSMutableData dataWithBytes:ents length:(NSUInteger)n * sizeof(EntityState)];
    EntityState *e = entities.mutableBytes;
    qsort(e, (size_t)n, sizeof(EntityState), CompareEntities);
    for (int i = 0; i < n; i++) QuantizeEntity(&e[i]);
    NSData *events = [_events copy];
    _events.length = 0;

    for (NSUInteger i = 0; i < _slots.count; i++) {
        ServerSlot *slot = _slots[i];
        if (slot.state != SlotInGame) continue;
        const PlayerState *ps = _ge->playerState((int)i);
        // Delta against the newest frame the client has, if we still have it.
        uint32_t base = slot.deltaFrame;
        NSData *baseline = nil;
        if (base && _frame - base < UPDATE_BACKUP && slot->frameNumbers[base % UPDATE_BACKUP] == base)
            baseline = slot->frameEntities[base % UPDATE_BACKUP];
        else
            base = 0;

        MsgWriter *w = [MsgWriter new];
        [w u8:svc_frame];
        [w u32:_frame];
        [w u32:base];
        PlayerState p = ps ? *ps : (PlayerState){0};
        WritePlayerState(w, &p);
        WritePacketEntities(w, baseline.bytes, baseline.length / sizeof(EntityState), e, (NSUInteger)n);
        WriteEvents(w, events.bytes, events.length / sizeof(GameEvent));
        [slot.channel transmit:w.data];

        slot->frameNumbers[_frame % UPDATE_BACKUP] = _frame;
        slot->frameEntities[_frame % UPDATE_BACKUP] = entities;
    }
}

@end
