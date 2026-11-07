// Actual Server, Client, NetChannel and game module; only datagram delivery and
// presentation are replaced. One virtual clock, no sleeps, seeds or LAN needed.
#import "Server.h"
#import "Client.h"
#import "Net.h"
#import "Shared.h"
#import "Common.h"
#import "Game.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <netinet/in.h>
#include <time.h>

static double clockNow = 100;
double NetworkCheckTime(void) { return clockNow; }
GetGameAPIFunc GameLoaderOpen(void) { return GetGameAPI; }
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)

// Test-only access to existing operations, without changing production API.
@interface Client (NetworkChecks)
- (BOOL)predictFrom:(Snapshot *)s into:(ShipMoveState *)out;
@end
@interface Server (NetworkChecks)
- (void)setConfigString:(int)index value:(NSString *)value;
@end

// Keep the real mDNS smoke observable independently of injected error checks.
@interface LANAdvertisement (DiscoveryCallbacks) <NSNetServiceDelegate>
@end
@interface LANBrowser (DiscoveryCallbacks) <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@end
@interface DiscoveryAdvertisement : LANAdvertisement
@property BOOL published;
@end
@implementation DiscoveryAdvertisement
- (void)netServiceDidPublish:(NSNetService *)service {
    self.published = YES;
    NSLog(@"BONJOUR SMOKE published %@ port %ld", service.name, (long)service.port);
}
- (void)netService:(NSNetService *)service didNotPublish:(NSDictionary *)error {
    NSLog(@"BONJOUR SMOKE publication failed: %@", error);
    [super netService:service didNotPublish:error];
}
@end
@interface DiscoveryBrowser : LANBrowser
@property NSUInteger discovered, resolved;
@end
@implementation DiscoveryBrowser
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)more {
    self.discovered++;
    NSLog(@"BONJOUR SMOKE discovered %@", service.name);
    [super netServiceBrowser:browser didFindService:service moreComing:more];
}
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary *)error {
    NSLog(@"BONJOUR SMOKE browse failed: %@", error);
    [super netServiceBrowser:browser didNotSearch:error];
}
- (void)netServiceDidResolveAddress:(NSNetService *)service {
    self.resolved++;
    NSMutableArray<NSString *> *addresses = [NSMutableArray array];
    for (NSData *data in service.addresses) {
        if (data.length < sizeof(struct sockaddr_in) || ((const struct sockaddr *)data.bytes)->sa_family != AF_INET) continue;
        NetAddress *address = [NetAddress addressWithSockaddr:data.bytes length:(unsigned)data.length];
        if (address) [addresses addObject:address.string];
    }
    NSLog(@"BONJOUR SMOKE resolved %@: %@", service.name, addresses);
    [super netServiceDidResolveAddress:service];
}
- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary *)error {
    NSLog(@"BONJOUR SMOKE resolution failed for %@: %@", service.name, error);
    if ([LANBrowser instancesRespondToSelector:_cmd]) [super netService:service didNotResolve:error];
}
@end

@interface ResolvedServiceFixture : NSNetService
@property NSArray<NSData *> *fixtureAddresses;
@end
@implementation ResolvedServiceFixture
- (NSArray<NSData *> *)addresses { return self.fixtureAddresses; }
@end

@interface Datagram : NSObject
@property NSData *data;
@property NetAddress *from;
@property double due;
@end
@implementation Datagram
@end

@class Link;
static NSMutableDictionary<NSNumber *, Link *> *routes;
static double delay;
static NSUInteger sent, dropped, dropEvery;
static BOOL blackout;
static NSUInteger predictionChecks;
static BOOL assertPendingPrediction;
@interface Link : NSObject <NetTransport>
@property int port;
@property NSMutableArray<Datagram *> *queue;
+ (instancetype)port:(int)port;
@end
@implementation Link
+ (instancetype)port:(int)port {
    Link *link = [Link new]; link.port = port; link.queue = [NSMutableArray array];
    routes[@(port)] = link; return link;
}
- (void)send:(NSData *)packet to:(NetAddress *)to {
    sent++;
    if (blackout || (dropEvery && sent % dropEvery == 0)) { dropped++; return; }
    Datagram *p = [Datagram new]; p.data = [packet copy];
    p.from = [NetAddress loopback:self.port]; p.due = clockNow + delay;
    [routes[@(to.port)].queue addObject:p];
}
- (NSData *)receiveFrom:(NetAddress *__autoreleasing *)from {
    for (Datagram *p in self.queue) if (p.due <= clockNow) {
        *from = p.from; NSData *data = p.data; [self.queue removeObject:p]; return data;
    }
    return nil;
}
@end

// Records production prediction and decoded events; creates no window or GPU.
@interface Spy : NSObject
@property NSArray *configStrings;
@property uint16_t predictedEntity;
@property NSUInteger shots, bolts, ionShots, ionBolts;
@property float life, boltLife, relativeSpeed;
@property ShipMoveState drawn;
@property NSMutableArray<NSData *> *predictedVelocities, *serverVelocities;
@property NSUInteger damageEvents;
@property (nonatomic, copy) NSString *lastRadio;
@end
@implementation Spy
- (void)serverCommand:(int)t a:(NSString *)a b:(NSString *)b c:(NSString *)c { if (t == SVC_RADIO) self.lastRadio = a; }
- (void)handleEvent:(const GameEvent *)e player:(const PlayerState *)ps {
    if (e->type == EV_DAMAGE && e->entity != ps->entity) self.damageEvents++;
    if (e->type == EV_BOLT && e->entity == ps->entity) {
        simd_float3 v = e->vel;
        [self.serverVelocities addObject:[NSData dataWithBytes:&v length:sizeof v]];
        self.bolts++; self.boltLife = e->scale;
        if (e->flags & EVF_ION) self.ionBolts++;
        self.relativeSpeed = simd_length(e->vel - ps->move.velocity);
    }
}
- (void)predictedShotFrom:(simd_float3)p velocity:(simd_float3)v gun:(simd_float3)g life:(float)life ion:(BOOL)ion {
    [self.predictedVelocities addObject:[NSData dataWithBytes:&v length:sizeof v]];
    self.shots++; self.life = life;
    if (ion) self.ionShots++;
}
- (void)drawEntities:(const EntityState *)e count:(NSUInteger)n player:(const PlayerState *)ps
           controls:(ControlState)c time:(double)t dt:(float)dt { self.drawn = ps->move; }
@end

static Snapshot *Latest(Client *c) { return c.latestSnapshot; }
static void Step(Server *server, NSArray<Client *> *clients, ControlState controls) {
    clockNow += 1.0 / 30;
    NSMutableArray *predictions = [NSMutableArray array];
    NSMutableArray *sequences = [NSMutableArray array];
    for (Client *c in clients) {
        [c readPackets]; [c sendInput:controls actions:0 dt:1.0f / 30];
        ShipMoveState predicted = {0};
        BOOL valid = assertPendingPrediction && delay == 0 && !dropEvery && !blackout && [c predictFrom:Latest(c) into:&predicted];
        [predictions addObject:valid ? [NSData dataWithBytes:&predicted length:sizeof predicted] : NSData.data];
        [sequences addObject:[c valueForKey:@"sequence"]];
    }
    [server frame:TICK_DT];
    for (Client *c in clients) {
        [c readPackets]; [c drawWithControls:controls time:clockNow dt:TICK_DT];
        NSUInteger i = [clients indexOfObjectIdenticalTo:c];
        NSData *data = predictions[i]; Snapshot *s = Latest(c);
        if (data.length && s && s.ps.lastCommand == [sequences[i] unsignedIntValue]) {
            ShipMoveState predicted; [data getBytes:&predicted length:sizeof predicted];
            CHECK(simd_distance(predicted.origin, s.ps.move.origin) < 0.002);
            CHECK(simd_distance(predicted.velocity, s.ps.move.velocity) < 0.002);
            predictionChecks++;
        }
    }
}
static void Steps(Server *s, NSArray *clients, ControlState controls, int n) {
    for (int i = 0; i < n; i++) @autoreleasepool { Step(s, clients, controls); }
}

static void Scenario(int mission, BOOL impaired) {
    routes = [NSMutableDictionary dictionary]; delay = impaired ? 0.1 : 0;
    assertPendingPrediction = !impaired;
    dropEvery = impaired ? 11 : 0; blackout = NO; sent = dropped = 0;
    Server *server = [[Server alloc] initWithName:@"regression"]; CHECK(server);
    [server addTransport:[Link port:1]]; [server spawnLevel:[NSString stringWithFormat:@"check-%d", mission + 1]];
    NSMutableArray<Client *> *clients = [NSMutableArray array];
    NSMutableArray<Spy *> *views = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        Spy *view = [Spy new]; [views addObject:view];
        Client *c = [[Client alloc] initWithView:(ClientView *)view]; [clients addObject:c];
        __weak Client *weak = c;
        c.gamestateHandler = ^{ [weak begin]; };
        [c connectTo:[NetAddress loopback:1] transport:[Link port:10+i] name:@"pilot"];
    }
    Steps(server, clients, (ControlState){0}, 180);
    CHECK(server.clientCount == 2);
    Snapshot *a = Latest(clients[0]), *b = Latest(clients[1]);
    CHECK(a && b && a.ps.entity != b.ps.entity && a.ps.entity && b.ps.entity);
    const ShipDef *def = ShipDefForModel(clients[0].configStrings[CS_MODELS+a.ps.model]); CHECK(def);
    CHECK(fabs(a.ps.params.maxSpeed - def->params.maxSpeed) < 0.001);
    CHECK(fabs(a.ps.params.turnRate - def->params.turnRate) < 0.001);
    ShipParams params = a.ps.params; CHECK(!memcmp(&params, &def->params, sizeof params));
    CHECK([clients[0].configStrings isEqual:clients[1].configStrings]);
    ControlState fly = { .pitch = 0.15, .yaw = -0.2, .roll = 0.1, .throttle = 0.85, .boost = YES, .fire = YES };
    simd_float3 start = a.ps.move.origin;
    Steps(server, clients, fly, 240);
    CHECK(simd_distance(start, Latest(clients[0]).ps.move.origin) > 20);
    for (int i = 0; i < 2; i++) {
        CHECK(views[i].shots > 5 && views[i].bolts > 5);
        if (!impaired) {
            // Fixture capacitor never runs dry; cadence must use this ship's
            // interval, allowing one command of scheduling granularity.
            CHECK(views[i].shots >= 8.0 / (def->gun.interval + 0.034) - 2);
            CHECK(views[i].shots <= 8.0 / def->gun.interval + 2);
            CHECK(views[i].bolts >= 8.0 / (def->gun.interval + 0.034) - 3);
            CHECK(views[i].bolts <= 8.0 / def->gun.interval + 2);
        }
        CHECK(fabs(views[i].life - def->gun.life) < 0.001);
        CHECK(fabs(views[i].boltLife - def->gun.life) < 0.02);
        CHECK(fabs(views[i].relativeSpeed - def->gun.speed) < 40);
        Snapshot *s = Latest(clients[i]);
        BOOL found = NO;
        for (NSUInteger j = 0; j < s.entityCount; j++) if (s.entityStates[j].number == Latest(clients[1-i]).ps.entity) found = YES;
        CHECK(found); // both players see the other player's entity
    }
    if (impaired) {
        // Lose more history than UPDATE_BACKUP; delivery must recover from a
        // full baseline without reconnecting. Also exceeds input redundancy.
        blackout = YES; Steps(server, clients, fly, 45); blackout = NO;
    }
    delay = 0; dropEvery = 0;
    Steps(server, clients, fly, 120);
    for (Client *c in clients) {
        CHECK(c.state == ClientActive);
        Snapshot *s = Latest(c); ShipMoveState prediction;
        CHECK([c predictFrom:s into:&prediction]);
        // Zero-delay transport: every generated command has been processed.
        CHECK(s.ps.lastCommand > 300);
        CHECK(simd_distance(prediction.origin, s.ps.move.origin) < 0.001);
        CHECK(simd_distance(prediction.velocity, s.ps.move.velocity) < 0.001);
    }
    uint32_t before = Latest(clients[1]).frame;
    [clients[0] disconnect]; Steps(server, @[clients[1]], fly, 60);
    CHECK(server.clientCount == 1 && Latest(clients[1]).frame > before);
    [clients[0] connectTo:[NetAddress loopback:1] transport:routes[@10] name:@"reconnected"];
    Steps(server, clients, fly, 90); CHECK(server.clientCount == 2 && Latest(clients[0]));
    // Exercise protocol rejection through the server's real connectionless path.
    Link *old = [Link port:20];
    for (NSString *connect in @[[NSString stringWithFormat:@"connect %d old", PROTOCOL_VERSION-1],
                               [NSString stringWithFormat:@"connect %d future", PROTOCOL_VERSION+1],
                               @"connect", @"connect invalid pilot"]) {
        [NetChannel sendOutOfBand:connect transport:old to:[NetAddress loopback:1]];
        [server frame:0]; NetAddress *from; NSData *reply = [old receiveFrom:&from];
        CHECK([[NetChannel outOfBandText:reply] isEqualToString:@"reject protocol"]);
        CHECK(server.clientCount == 2);
    }
    // Test silence before altering game identity, so rejection cannot mask timeout.
    clockNow += NET_TIMEOUT + 1; [server frame:0];
    CHECK(server.clientCount == 0);
    for (Client *c in clients) { [c readPackets]; CHECK(c.state == ClientDisconnected); }
    for (int i = 0; i < 2; i++)
        [clients[i] connectTo:[NetAddress loopback:1] transport:routes[@(10+i)] name:@"after-timeout"];
    Steps(server, clients, fly, 90); CHECK(server.clientCount == 2);
    // A data mismatch must never invoke begin or leave a multiplayer slot live.
    Client *bad = [[Client alloc] initWithView:nil]; __block BOOL refused = NO;
    bad.disconnectHandler = ^(NSString *reason) { refused = [reason containsString:@"Incompatible"]; };
    bad.gamestateHandler = ^{ CHECK(NO); };
    [server setConfigString:CS_GAME value:@"spacefight 999 ships-sha256:wrong"];
    [bad connectTo:[NetAddress loopback:1] transport:[Link port:21] name:@"wrong-data"];
    Steps(server, @[bad], (ControlState){0}, 30);
    CHECK(refused && bad.state == ClientDisconnected && server.clientCount == 2);
    for (Client *c in clients) { [c readPackets]; CHECK(c.state == ClientDisconnected); }
    [server frame:0];
    CHECK(server.clientCount == 0); [server stop];
    CHECK(!impaired || dropped > 0);
    printf("PASS mission=%d latency=%s loss=%s sent=%lu dropped=%lu\n", mission,
        impaired ? "200ms RTT" : "0", impaired ? "every 11th + 45-tick blackout" : "0",
        (unsigned long)sent, (unsigned long)dropped);
}
// One player, one stationary hostile drone 1.5 degrees off the nose. Without
// assist every shot passes 16 m wide; with it the shots go to the drone. The
// client's predicted shots must leave in the same direction as the server's.
static NSUInteger AimRun(NSString *assist, Spy **outView) {
    routes = [NSMutableDictionary dictionary];
    delay = 0; dropEvery = 0; blackout = NO; assertPendingPrediction = YES;
    Server *server = [[Server alloc] initWithName:@"aim"]; CHECK(server);
    [server addTransport:[Link port:1]]; [server spawnLevel:@"check-aim"];
    CHECK([Cvar set:@"g_aimAssist" value:assist]);
    Spy *view = [Spy new];
    view.predictedVelocities = [NSMutableArray array]; view.serverVelocities = [NSMutableArray array];
    Client *c = [[Client alloc] initWithView:(ClientView *)view];
    __weak Client *weak = c; c.gamestateHandler = ^{ [weak begin]; };
    [c connectTo:[NetAddress loopback:1] transport:[Link port:10] name:@"gunner"];
    Steps(server, @[c], (ControlState){0}, 150);       // both ships coast to a stop
    Snapshot *s = Latest(c); CHECK(s && s.ps.stats[STAT_TARGET]);
    const EntityState *drone = NULL;
    for (NSUInteger i = 0; i < s.entityCount; i++) if (s.entityStates[i].number == s.ps.stats[STAT_TARGET]) drone = &s.entityStates[i];
    CHECK(drone && drone->kind == EntityFighter);
    simd_float3 rel = drone->origin - s.ps.move.origin, fwd = QuatForward(s.ps.move.orientation);
    float off = acosf(simd_dot(simd_normalize(rel), fwd)) * 180 / (float)M_PI;
    CHECK(off > 1.2f && off < 2.5f && simd_length(rel) > 450 && simd_length(drone->velocity) < 2);
    view.damageEvents = 0;
    Steps(server, @[c], (ControlState){ .fire = YES }, 90);
    Steps(server, @[c], (ControlState){0}, 45);          // let the last bolts land
    CHECK(view.bolts > 10);
    NSUInteger n = MIN(view.predictedVelocities.count, view.serverVelocities.count);
    CHECK(n + 2 >= view.bolts);
    for (NSUInteger i = 0; i < n; i++) {
        simd_float3 p, q;
        [view.predictedVelocities[i] getBytes:&p length:sizeof p]; [view.serverVelocities[i] getBytes:&q length:sizeof q];
        CHECK(simd_dot(simd_normalize(p), simd_normalize(q)) > 0.99999f);
    }
    [c disconnect]; [server frame:0]; [server stop];
    *outView = view;
    return view.damageEvents;
}
static void AimAssistCheck(void) {
    Spy *off, *on;
    NSUInteger missed = AimRun(@"0", &off), hit = AimRun(@"1", &on);
    [[Cvar find:@"g_aimAssist"] reset];
    CHECK(missed == 0);
    CHECK(hit * 2 >= on.bolts);        // most assisted shots land
    printf("PASS aim assist: %lu/%lu hits off, %lu/%lu on; predicted shots match the server's\n",
           (unsigned long)missed, (unsigned long)off.bolts, (unsigned long)hit, (unsigned long)on.bolts);
}
// Ion rules on a bare fighter: the shield drains twice as fast, then the
// systems, never the hull; at zero systems it is disabled and lasers still kill.
static void IonRules(void) {
    GFighter *f = [GFighter fighterWithShip:@"dummy" ai:YES]; CHECK(f);
    CHECK(f.definition->gun.ion == NO && f.shield == 0.5f && f.systems == 0.5f && f.hull == 3 && !f.disabled);
    CHECK([f takeIonDamage:0.1f]);                  // shield up: takes 0.2
    CHECK(fabsf(f.shield - 0.3f) < 1e-5f && f.systems == 0.5f && f.hull == 3);
    CHECK([f takeIonDamage:0.1f] && fabsf(f.shield - 0.1f) < 1e-5f);
    CHECK([f takeIonDamage:0.1f]);                  // 0.1 shield left, 0.1 spills over: 0.05 systems
    CHECK(f.shield == 0 && fabsf(f.systems - 0.45f) < 1e-5f && f.hull == 3 && !f.shielded);
    CHECK(![f takeIonDamage:0.3f] && fabsf(f.systems - 0.15f) < 1e-5f && !f.disabled);
    CHECK(f.systemsFraction > 0.29f && f.systemsFraction < 0.31f);
    [f takeIonDamage:0.3f];
    CHECK(f.disabled && f.systems == 0 && f.alive && f.hull == 3 && f.hullFraction == 1);
    [f takeIonDamage:5];                            // nothing more to take
    CHECK(f.alive && f.hull == 3);
    CHECK([f takeDamage:1] == NO && f.hull == 2 && f.disabled);
    [f takeDamage:5];
    CHECK(!f.alive);
    [f resetAt:simd_make_float3(0, 0, 0) facing:simd_quaternion(0.0f, simd_make_float3(0, 1, 0))];
    CHECK(!f.disabled && f.systems == 0.5f && f.alive);
    printf("PASS ion damage: shield drained at %gx, then systems; hull untouched; disabled at zero\n", ION_SHIELD_DRAIN);
}
// A player's ion gun against a drone: the shots are drawn as ion, the drone
// ends up disabled but alive with its hull whole, and a laser still kills it.
static void IonRun(void) {
    routes = [NSMutableDictionary dictionary];
    delay = 0; dropEvery = 0; blackout = NO; assertPendingPrediction = YES;
    Server *server = [[Server alloc] initWithName:@"ion"]; CHECK(server);
    [server addTransport:[Link port:1]]; [server spawnLevel:@"check-ion"];
    IonRules();       // needs the game module up: a fighter looks its model up in the server
    CHECK([Cvar set:@"g_aimAssist" value:@"1"]);
    Spy *view = [Spy new];
    view.predictedVelocities = [NSMutableArray array]; view.serverVelocities = [NSMutableArray array];
    Client *c = [[Client alloc] initWithView:(ClientView *)view];
    __weak Client *weak = c; c.gamestateHandler = ^{ [weak begin]; };
    [c connectTo:[NetAddress loopback:1] transport:[Link port:10] name:@"gunner"];
    Steps(server, @[c], (ControlState){0}, 150);
    GFighter *drone = nil;
    for (GFighter *f in [level fighters]) if (!f.client) drone = f;
    CHECK(drone && drone.alive && !drone.disabled && drone.shield == 0.5f);
    Steps(server, @[c], (ControlState){ .fire = YES }, 200);
    Steps(server, @[c], (ControlState){0}, 45);
    CHECK(view.ionShots > 5 && view.ionBolts == view.bolts && view.bolts > 10);
    CHECK(drone.disabled && drone.alive && drone.hull == 3 && drone.shield == 0 && drone.systems == 0);
    // The wire says so, and the AI leaves it alone unless ordered to destroy it.
    const EntityState *seen = NULL;
    Snapshot *snap = Latest(c);
    for (NSUInteger i = 0; i < snap.entityCount; i++) if (snap.entityStates[i].number == drone.number) seen = &snap.entityStates[i];
    CHECK(seen && (seen->flags & EF_DISABLED) && seen->hull == 1);
    GPilot *hunter = [GPilot new];
    hunter.ship = [GFighter fighterWithShip:@"wasp" ai:YES]; hunter.ship.team = TeamFriend;
    hunter.ship.position = simd_make_float3(0, 0, -500);
    CHECK([level pickTargetFor:hunter] == nil);
    hunter.order = @"strike"; hunter.orderTarget = @"dummy";
    CHECK([level pickTargetFor:hunter] == drone && [level pilot:hunter mayAttack:drone]);
    hunter.order = nil; hunter.orderTarget = nil;
    CHECK(![level pilot:hunter mayAttack:drone]);
    CHECK(simd_length(drone->move.angularVelocity) > 0.1f && simd_length(drone->move.angularVelocity) < 0.35f);
    [level damageShip:drone amount:10 by:nil shake:0];
    CHECK(!drone.alive);
    [[Cvar find:@"g_aimAssist"] reset];
    [c disconnect]; [server frame:0]; [server stop];
    printf("PASS ion gun: %lu ion bolts, drone disabled with its hull whole, lasers still destroy it\n", (unsigned long)view.ionBolts);
}
// The player's own ship is disabled: commands are ignored, nothing fires, the
// throttle is zero, and it coasts on, slowing a little and tumbling slowly.
static void IonPlayer(void) {
    routes = [NSMutableDictionary dictionary];
    delay = 0; dropEvery = 0; blackout = NO; assertPendingPrediction = YES;
    Server *server = [[Server alloc] initWithName:@"ion player"]; CHECK(server);
    [server addTransport:[Link port:1]]; [server spawnLevel:@"check-1"];
    Spy *view = [Spy new];
    view.predictedVelocities = [NSMutableArray array]; view.serverVelocities = [NSMutableArray array];
    Client *c = [[Client alloc] initWithView:(ClientView *)view];
    __weak Client *weak = c; c.gamestateHandler = ^{ [weak begin]; };
    [c connectTo:[NetAddress loopback:1] transport:[Link port:10] name:@"pilot"];
    Steps(server, @[c], (ControlState){ .throttle = 1 }, 150);
    GFighter *me = nil;
    for (GFighter *f in [level fighters]) if (f.client) me = f;
    CHECK(me && me.alive && !me.disabled && !Latest(c).ps.disabled);
    NSUInteger bolts = view.bolts;
    [me takeIonDamage:100];
    CHECK(me.disabled && me.alive && me.hull == me.definition->hull);
    float speed0 = simd_length(me.velocity);
    simd_quatf orientation0 = me.orientation;
    CHECK(speed0 > 50);
    // The first frame is predicted from a snapshot that still says flying: one tolerated correction.
    assertPendingPrediction = NO;
    Steps(server, @[c], (ControlState){ .throttle = 1, .pitch = 1, .roll = 1, .boost = YES, .fire = YES }, 3);
    assertPendingPrediction = YES;
    NSUInteger shots = view.shots;      // the client stops predicting shots once the snapshot says disabled
    Steps(server, @[c], (ControlState){ .throttle = 1, .pitch = 1, .roll = 1, .boost = YES, .fire = YES }, 57);
    PlayerState ps = Latest(c).ps;
    float speed1 = simd_length(me.velocity);
    CHECK(ps.disabled && ps.alive && ps.move.throttle == 0 && !ps.move.boosting);
    CHECK(speed1 < speed0 && speed1 > speed0 * 0.8f);              // coasts, bleeding off slowly
    float w = simd_length(ps.move.angularVelocity);
    // A slow tumble, not the stick. Its axis is random and may lie along the
    // nose, so compare whole orientations rather than the forward vector.
    CHECK(w > 0.1f && w < 0.35f && fabsf(simd_dot(me.orientation.vector, orientation0.vector)) < 0.99999f);
    CHECK(view.shots == shots && view.bolts == bolts);             // no shots, predicted or real
    CHECK(me.laserEnergy >= 0);
    float after = me.shield;
    Steps(server, @[c], (ControlState){0}, 60);
    CHECK(me.shield == after);                                     // no recharge
    [c disconnect]; [server frame:0]; [server stop];
    puts("PASS disabled player ship: commands ignored, no fire, coasts and tumbles, flag on the wire");
}
// AI flight-group orders against an enemy fighter 600 m ahead and an enemy
// capital 2 km ahead, driving pilots straight through thinkPilot.
static GPilot *OrderPilot(NSString *order, NSString *target, simd_float3 pos) {
    GPilot *p = [GPilot new];
    p.ship = [GFighter fighterWithShip:@"wasp" ai:YES]; p.ship.team = TeamFriend;
    [p.ship resetAt:pos facing:LookRotation(simd_make_float3(0, 0, -1), simd_make_float3(0, 1, 0))];
    p.home = pos; p.order = order; p.orderTarget = target;
    p.skill = PilotSkillFor(LevelSkillAce, TeamFriend);
    return p;
}
static int FriendlyBolts(void) {
    int n = 0;
    for (int i = 0; i < MAX_BOLTS; i++) if (level->_bolts[i].active && level->_bolts[i].team == TeamFriend) n++;
    return n;
}
static void Fly(GPilot *p, int steps) {
    for (int i = 0; i < steps; i++) { level->_time += TICK_DT; [level thinkPilot:p dt:TICK_DT]; }
}
static void OrdersRun(void) {
    Server *server = [[Server alloc] initWithName:@"orders"]; CHECK(server);
    [server addTransport:[Link port:1]]; [server spawnLevel:@"check-orders"];
    GFighter *drone = nil;
    for (GFighter *f in [level fighters]) drone = f;
    GCapital *cruiser = [level capitalNamed:@"cruiser"];
    CHECK(drone && cruiser && drone.team == TeamEnemy && cruiser.team == TeamEnemy);
    simd_float3 start = simd_make_float3(0, 0, -300);

    // Who each order picks.
    CHECK([level pickTargetFor:OrderPilot(@"attack", nil, start)] == drone);
    CHECK([level pickTargetFor:OrderPilot(@"attack-fighters", nil, start)] == drone);
    CHECK([level pickTargetFor:OrderPilot(@"attack-capitals", nil, start)] == cruiser);
    CHECK([level pickTargetFor:OrderPilot(@"disable", @"cruiser", start)] == cruiser);
    CHECK([level pickTargetFor:OrderPilot(@"evade", nil, start)] == nil && [level pickTargetFor:OrderPilot(@"ignore", nil, start)] == nil);
    GPilot *capitals = OrderPilot(@"attack-capitals", nil, start), *fighters = OrderPilot(@"attack-fighters", nil, start);
    CHECK([level pilot:capitals mayAttack:cruiser] && ![level pilot:capitals mayAttack:drone]);
    CHECK([level pilot:fighters mayAttack:drone] && ![level pilot:fighters mayAttack:cruiser]);
    // Patrols only see what is within 1.2 km of them.
    CHECK([level pickTargetFor:OrderPilot(@"patrol", @"n1", simd_make_float3(0, 0, 400))] == drone);
    CHECK([level pickTargetFor:OrderPilot(@"patrol", @"n1", simd_make_float3(2500, 0, 500))] == nil);

    // An attacker shoots; evaders and the ignoring never do, and evaders back away.
    GPilot *attacker = OrderPilot(@"attack", nil, start);
    Fly(attacker, 90);
    int shots = FriendlyBolts();
    CHECK(shots > 0 && attacker.target == drone);
    GPilot *evader = OrderPilot(@"evade", nil, start);
    Fly(evader, 120);
    CHECK(FriendlyBolts() == shots);
    CHECK(simd_distance(evader.ship.position, drone.position) > 900 && evader.target == nil);
    GPilot *ignorer = OrderPilot(@"ignore", nil, start);
    Fly(ignorer, 240);
    CHECK(FriendlyBolts() == shots && simd_distance(ignorer.ship.position, start) < 800);
    GPilot *capitalHunter = OrderPilot(@"attack-capitals", nil, start);
    Fly(capitalHunter, 30);
    CHECK(capitalHunter.target == cruiser);

    // A patrol flies its navs in a loop and leaves everyone alone far from them.
    GPilot *patrol = OrderPilot(@"patrol", @"n1,n2", simd_make_float3(2500, 0, 500));
    Fly(patrol, 1);
    CHECK(patrol.patrolIndex == 0);
    for (int i = 0; i < 1800 && patrol.patrolIndex == 0; i++) Fly(patrol, 1);
    CHECK(patrol.patrolIndex == 1 && patrol.target == nil && FriendlyBolts() == shots);
    for (int i = 0; i < 3000 && patrol.patrolIndex == 1; i++) Fly(patrol, 1);
    CHECK(patrol.patrolIndex == 0);

    // "disable" stops once the target is: it is not shot at (nor chosen) after.
    GPilot *disabler = OrderPilot(@"disable", @"drone", start);
    CHECK([level pickTargetFor:disabler] == drone && [level pilot:disabler mayAttack:drone]);
    [drone disable];
    CHECK([level pickTargetFor:disabler] == nil && ![level pilot:disabler mayAttack:drone]);
    int before = FriendlyBolts();
    Fly(disabler, 120);
    CHECK(FriendlyBolts() == before && disabler.target == nil);
    GPilot *striker = OrderPilot(@"strike", @"drone", start);
    CHECK([level pickTargetFor:striker] == drone && [level pilot:striker mayAttack:drone]);
    CHECK([level pickTargetFor:OrderPilot(@"attack-fighters", nil, start)] == nil);     // the disabled are spared
    [server stop];
    puts("PASS orders: attack-fighters/-capitals pick their kind, evade and ignore never fire, patrol loops its navs, disable stops at disabled");
}
// Boarders (a "board" wave) wait while the target is whole, then dock with it
// once disabled and capture it after dockSeconds; losing a docking boarder
// restarts the count for the other.
static NSArray<GPilot *> *Boarders(void) {
    NSMutableArray *b = [NSMutableArray array];
    for (GPilot *p in level->_pilots) if ([p.order isEqualToString:@"board"]) [b addObject:p];
    return b;
}
static GFighter *BoardTarget(void) {
    for (GPilot *p in level->_pilots) if ([p.wave isEqualToString:@"drone"]) return p.ship;
    return nil;
}
static MissionObjective *TakeObjective(void) { return [level->_runner objectiveNamed:@"take"]; }
static void BoardRun(void) {
    routes = [NSMutableDictionary dictionary];
    Server *server = [[Server alloc] initWithName:@"board"]; CHECK(server);
    [server addTransport:[Link port:1]]; [server spawnLevel:@"check-board"];
    GFighter *drone = BoardTarget();
    CHECK(drone && Boarders().count == 2 && Boarders()[0].dockSeconds == 6);
    // Whole: the boarders keep close but never dock, fire or capture.
    Steps(server, @[], (ControlState){0}, 450);
    CHECK(!drone.captured && !drone.disabled && drone.team == TeamEnemy && drone.hull == 3 && FriendlyBolts() == 0);
    for (GPilot *p in Boarders()) CHECK(p.dockSince == 0 && simd_distance(p.ship.position, drone.position) < 700);
    // Disabled: they close in; not captured before the count is up, captured after.
    [drone disable];
    double disabledAt = level->_time;
    Steps(server, @[], (ControlState){0}, 60);
    CHECK(!drone.captured);
    for (int i = 0; i < 900 && !drone.captured; i++) Steps(server, @[], (ControlState){0}, 1);
    CHECK(drone.captured && drone.disabled && drone.alive && drone.team == TeamFriend);
    CHECK(level->_time - disabledAt > 6);
    for (GPilot *p in Boarders()) CHECK(simd_distance(p.ship.position, drone.position) < 70 || p.dockSince == 0);
    CHECK([(id<MissionUnit>)drone missionCaptured]);
    Steps(server, @[], (ControlState){0}, 30);
    CHECK(TakeObjective().state == MissionObjectiveComplete);
    [server stop];

    // Again, but one boarder dies mid-dock: the other starts over.
    [server addTransport:[Link port:2]]; [server spawnLevel:@"check-board"];
    drone = BoardTarget();
    [drone disable];
    NSArray<GPilot *> *boarders = Boarders();
    for (int i = 0; i < 900 && !(boarders[0].dockSince > 0 && boarders[1].dockSince > 0); i++) Steps(server, @[], (ControlState){0}, 1);
    CHECK(boarders[0].dockSince > 0 && boarders[1].dockSince > 0 && !drone.captured);
    double lostAt = level->_time;
    [level damageShip:boarders[0].ship amount:10 by:nil shake:0];
    CHECK(!boarders[0].ship.alive);
    Steps(server, @[], (ControlState){0}, 2);
    CHECK(boarders[1].dockSince >= lostAt && boarders[0].dockSince == 0);
    for (int i = 0; i < 900 && !drone.captured; i++) Steps(server, @[], (ControlState){0}, 1);
    CHECK(drone.captured && level->_time - lostAt >= 6);
    [server stop];
    puts("PASS boarding: boarders wait for a whole target, capture a disabled one after dockSeconds, restart when one is lost, objective completes");
}
static void SecondaryTargetingRun(void) {
    routes = [NSMutableDictionary dictionary]; delay = 0; dropEvery = 0; blackout = NO;
    assertPendingPrediction = NO;
    Server *server = [[Server alloc] initWithName:@"Secondary targeting"]; CHECK(server);
    [server addTransport:[Link port:1]]; [server spawnLevel:@"check-orders"];
    Spy *view = [Spy new];
    Client *client = [[Client alloc] initWithView:(ClientView *)view];
    __weak Client *weak = client; client.gamestateHandler = ^{ [weak begin]; };
    [client connectTo:[NetAddress loopback:1] transport:[Link port:10] name:@"Missile pilot"];
    Steps(server, @[client], (ControlState){0}, 60);
    GClient *pilot = level->_clients[0];
    CHECK(pilot.inGame && pilot.ship.alive);
    pilot.torpedoes = 3;
    int rounds = pilot.torpedoes;
    pilot.selected = nil;
    // Deliver the launch command without advancing a world tick: acquisition
    // must happen during the launch, before regular targeting runs again.
    [client sendInput:(ControlState){0} actions:InputActionSecondary dt:TICK_DT];
    [server frame:0];
    CHECK(pilot.selected && pilot.torpedoes == rounds - 1);
    CHECK(level->_torpedoes.count == 1 && level->_torpedoes.lastObject.target == pilot.selected);
    GFighter *drone = pilot.selected; CHECK([drone isKindOfClass:GFighter.class]);
    GCapital *capital = level->_capitals.firstObject; CHECK(capital);
    for (NSString *asset in @[@"AsteroidA", @"AsteroidB", @"AsteroidC"]) {
        GCapital *rock = [GCapital capitalWithAsset:asset style:nil team:TeamEnemy];
        CHECK(rock.isAsteroid && [rock.className hasPrefix:@"{#"]);
    }
    CHECK(!capital.isAsteroid);
    capital.position = pilot.ship.position + pilot.ship.forward * 700;
    pilot.selected = capital; pilot.targetIsManual = YES;
    [level fireTorpedoFor:pilot];
    CHECK(pilot.selected == capital && level->_torpedoes.lastObject.target == capital);
    CHECK(level->_torpedoes.lastObject.aim == pilot.aimSubsystem);
    CHECK(pilot.torpedoes == rounds - 2);
    // A destroyed selection is replaced and still fires on the first press.
    [level destroyCapital:capital];
    pilot.selected = capital; pilot.targetIsManual = YES;
    [level fireTorpedoFor:pilot];
    CHECK(pilot.selected == drone && level->_torpedoes.lastObject.target == drone);
    CHECK(pilot.torpedoes == rounds - 3 && !level->_torpedoes.lastObject.aim);
    NSUInteger launched = level->_torpedoes.count;
    pilot.torpedoes = 1;
    pilot.selected = nil;
    [level->_pilots removeAllObjects];
    [level fireTorpedoFor:pilot];
    CHECK(!pilot.selected && pilot.torpedoes == 1 && level->_torpedoes.count == launched);
    // Only hostile targets close to the crosshair qualify. The farther but
    // better-aligned ship wins, and automatic locks follow a change of aim.
    GCapital *near = [GCapital capitalWithAsset:@"Corvette" style:nil team:TeamEnemy];
    GCapital *aligned = [GCapital capitalWithAsset:@"Corvette" style:nil team:TeamEnemy];
    [level->_capitals addObjectsFromArray:@[near, aligned]];
    simd_float3 forward = pilot.ship.forward, right = pilot.ship.right, origin = pilot.ship.position;
    near.position = origin + forward * 300 + right * 25;
    aligned.position = origin + forward * 1800 + right * 5;
    pilot.selected = nil; pilot.targetIsManual = NO;
    [level updateTargetingFor:pilot];
    CHECK(pilot.selected == aligned);
    near.position = origin + forward * 300;
    [level updateTargetingFor:pilot];
    CHECK(pilot.selected == near);
    [level fireTorpedoFor:pilot];
    CHECK(level->_torpedoes.lastObject.target == near && pilot.torpedoes == 0);
    pilot.torpedoes = 2;
    launched = level->_torpedoes.count;
    // Turning away clears an automatic lock rather than firing offscreen.
    near.position = origin + forward * 300 + right * 60;
    aligned.position = origin - forward * 300;
    [level fireTorpedoFor:pilot];
    CHECK(!pilot.selected && pilot.torpedoes == 2 && level->_torpedoes.count == launched);
    // Even stale manual locks become invalid when an enemy changes sides.
    near.position = origin + forward * 300;
    for (NSNumber *team in @[@(TeamFriend), @(TeamNeutral)]) {
        near.team = team.intValue;
        pilot.selected = near; pilot.targetIsManual = YES;
        [level fireTorpedoFor:pilot];
        CHECK(!pilot.selected && !pilot.targetIsManual && pilot.torpedoes == 2 && level->_torpedoes.count == launched);
        [level cycleTargetFor:pilot];
        CHECK(pilot.selected != near);
    }
    near.team = TeamEnemy;
    near.departed = YES;
    pilot.selected = nil; pilot.targetIsManual = NO;
    [level fireTorpedoFor:pilot];
    CHECK(!pilot.selected && pilot.torpedoes == 2);
    near.departed = NO;
    near.stealthRange = 100;
    [level fireTorpedoFor:pilot];
    CHECK(!pilot.selected && pilot.torpedoes == 2);
    [server frame:0 paused:YES]; [client readPackets];
    CHECK([view.lastRadio isEqualToString:MissionText(@"combat.no_targets", nil)]);
    [client disconnect]; [server stop];
    puts("PASS secondary targeting: first-press launch, manual enemy lock, crosshair proximity over distance, automatic retargeting, no offscreen/friendly/neutral/departed/hidden targets, ammunition preserved without a target");
}
// Delayed delivery makes the old one-frame disconnect assumption fail on
// every run, without depending on the kernel scheduler or the idle timeout.
static void DisconnectDeliveryCheck(void) {
    routes = [NSMutableDictionary dictionary];
    delay = 0; dropEvery = 0; blackout = NO; assertPendingPrediction = NO;
    Server *server = [[Server alloc] initWithName:@"Disconnect delivery"]; CHECK(server);
    Link *host = [Link port:1]; [server addTransport:host];
    [server spawnLevel:@"check-1"];
    NSMutableArray<Client *> *clients = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        Client *client = [[Client alloc] initWithView:(ClientView *)[Spy new]];
        __weak Client *weak = client; client.gamestateHandler = ^{ [weak begin]; };
        [clients addObject:client];
        [client connectTo:[NetAddress loopback:1] transport:[Link port:10+i] name:@"Leaving"];
    }
    for (int round = 0; round < 16; round++) {
        Steps(server, clients, (ControlState){0}, 60);
        CHECK(server.clientCount == 2);
        for (Client *client in clients) CHECK(client.state == ClientActive && Latest(client));
        // Keep only the disconnect burst. Lose its first two packets for each
        // client, leaving the third to exercise cleanup for both slots.
        [host.queue removeAllObjects];
        delay = 0.1;
        for (Client *client in clients) {
            [client disconnect]; [client disconnect];
            CHECK(client.state == ClientDisconnected && !Latest(client));
        }
        CHECK(host.queue.count == 6);
        [host.queue removeObjectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(3, 2)]];
        [host.queue removeObjectsInRange:NSMakeRange(0, 2)];
        [server frame:0]; CHECK(server.clientCount == 2);
        clockNow += 0.11;
        [server frame:0]; CHECK(server.clientCount == 0);
        // The same endpoints must be reusable immediately after cleanup.
        delay = 0;
        for (int i = 0; i < 2; i++)
            [clients[i] connectTo:[NetAddress loopback:1] transport:routes[@(10+i)] name:@"Returned"];
    }
    Steps(server, clients, (ControlState){0}, 60);
    CHECK(server.clientCount == 2);
    for (Client *client in clients) [client disconnect];
    [server frame:0]; CHECK(server.clientCount == 0);
    [server stop];
    puts("PASS delayed disconnects: both slots released, burst loss, repeated disconnect and 16 same-endpoint reconnects");
}

static double SocketCheckTime(void) {
    struct timespec now;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return now.tv_sec + now.tv_nsec / 1e9;
}

static void WaitForUDPDisconnects(Server *server) {
    // The simulation clock deliberately stays frozen: an idle timeout must
    // never satisfy this check. Poll real sockets until delivery or a deadline.
    double until = SocketCheckTime() + 2;
    do {
        [server frame:0];
        if (!server.clientCount) return;
        usleep(1000);
    } while (SocketCheckTime() < until);
    fprintf(stderr, "UDP disconnect delivery deadline: %lu slots remain\n", (unsigned long)server.clientCount);
    CHECK(server.clientCount == 0);
}

static void UDPSmoke(void) {
    assertPendingPrediction = YES;
    delay = 0; dropEvery = 0; blackout = NO;
    Server *server = [[Server alloc] initWithName:@"UDP localhost"]; CHECK(server);
    server.publicHosting = YES;
    UDPTransport *host = [[UDPTransport alloc] initWithPort:0 attempts:1]; CHECK(host);
    [server addTransport:host]; [server spawnLevel:@"check-1"];
    NetAddress *address = [NetAddress addressWithString:@"127.0.0.1" port:host.port];
    NSMutableArray<UDPTransport *> *sockets = [NSMutableArray array];
    NSMutableArray<Client *> *clients = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        UDPTransport *socket = [[UDPTransport alloc] initWithPort:0 attempts:1]; CHECK(socket);
        [sockets addObject:socket];
        Client *client = [[Client alloc] initWithView:(ClientView *)[Spy new]];
        __weak Client *weak = client; client.gamestateHandler = ^{ [weak begin]; };
        [client connectTo:address transport:socket name:@"UDP pilot"]; [clients addObject:client];
    }
    ControlState fly = { .throttle = 0.8, .pitch = 0.1 };
    Steps(server, clients, fly, 300);
    CHECK(server.clientCount == 2 && Latest(clients[0]) && Latest(clients[1]));
    CHECK(Latest(clients[0]).ps.entity != Latest(clients[1]).ps.entity);
    CHECK(Latest(clients[0]).ps.lastCommand > 200 && Latest(clients[1]).ps.lastCommand > 200);
    for (Client *c in clients) [c disconnect];
    WaitForUDPDisconnects(server);
    // Reuse the very same sockets and clients, including rapid, duplicate
    // disconnect calls. Reaching zero between rounds proves slots are freed.
    for (int round = 0; round < 16; round++) {
        for (NSUInteger i = 0; i < clients.count; i++) {
            Client *client = clients[i];
            UDPTransport *socket = sockets[i];
            NetAddress *from;
            while ([socket receiveFrom:&from]) {} // discard the previous session's snapshots
            [client connectTo:address transport:socket name:@"UDP returned"];
        }
        for (int frame = 0; frame < 60; frame++) {
            Step(server, clients, fly);
            usleep(1000);
        }
        CHECK(server.clientCount == 2);
        for (Client *client in clients) CHECK(client.state == ClientActive && Latest(client));
        for (Client *client in clients) { [client disconnect]; [client disconnect]; }
        WaitForUDPDisconnects(server);
    }
    [server stop];
    puts("PASS real IPv4 UDP sockets: two clients, disconnect and 16 rapid same-socket reconnects");
}

static void DeathmatchRun(void) {
    routes = [NSMutableDictionary dictionary]; delay = 0; dropEvery = 0; blackout = NO;
    assertPendingPrediction = NO;
    Server *server = [[Server alloc] initWithName:@"Dogfight"]; CHECK(server);
    [server addTransport:[Link port:1]]; [server spawnLevel:@"check-dogfight"];
    NSMutableArray<Client *> *clients = [NSMutableArray array];
    for (int i = 0; i < MAX_CLIENTS; i++) {
        Client *client = [[Client alloc] initWithView:(ClientView *)[Spy new]];
        __weak Client *weak = client; client.gamestateHandler = ^{ [weak begin]; };
        [client connectTo:[NetAddress loopback:1] transport:[Link port:10+i] name:[NSString stringWithFormat:@"Pilot %d", i+1]];
        [clients addObject:client];
    }
    Steps(server, clients, (ControlState){0}, 60);
    CHECK(server.clientCount == MAX_CLIENTS && server.clientNames.count == MAX_CLIENTS);
    CHECK(GIsDeathmatch() && !level->_runner && !server.missionEnded);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        Snapshot *snapshot = Latest(clients[i]); CHECK(snapshot && snapshot.ps.alive);
        CHECK([clients[i].configStrings[CS_MODE] isEqualToString:@"deathmatch"]);
        CHECK(snapshot.ps.team == i);
        for (int j = 0; j < MAX_CLIENTS; j++) if (i != j) {
            CHECK(TeamRelationIn([clients[i].configStrings[CS_TEAMS] UTF8String], i, j) == RelationHostile);
            CHECK(simd_distance(snapshot.ps.move.origin, Latest(clients[j]).ps.move.origin) > 200);
        }
    }
    GClient *a = level->_clients[0], *b = level->_clients[MAX_CLIENTS-1];
    [level cycleTargetFor:a]; CHECK(a.selected && a.selected != a.ship);
    b.selected = a.ship; b.targetIsManual = YES; [level fireTorpedoFor:b];
    CHECK(level->_torpedoes.lastObject.team == b.ship.team);
    [level->_torpedoes removeAllObjects];
    uint16_t oldEntity = b.ship.number;
    [level fireFrom:b.ship.position + b.ship.forward * 50 velocity:simd_make_float3(0,0,0) direction:-b.ship.forward
        speed:500 life:1 team:a.ship.team damage:100 capDamage:0 ion:NO owner:a];
    [level updateBolts:0.1f];
    CHECK(a.kills == 1 && b.deaths == 1 && !b.ship.alive);
    Steps(server, clients, (ControlState){0}, 30);
    CHECK(!b.ship.alive && Latest(clients[MAX_CLIENTS-1]).ps.stats[STAT_DEATHS] == 1);
    Steps(server, clients, (ControlState){0}, 75);
    CHECK(b.ship.alive && b.ship.number != oldEntity && b.deaths == 1 && a.kills == 1);
    CHECK(Latest(clients[0]).ps.stats[STAT_KILLS] == 1);
    CHECK(!server.missionEnded);
    for (int i = 1; i < level->_level->rules.fragLimit; i++) {
        [level damageShip:b.ship amount:100 by:a shake:0];
        Steps(server, clients, (ControlState){0}, i + 1 < level->_level->rules.fragLimit ? 100 : 2);
    }
    CHECK(server.missionEnded && a.kills == level->_level->rules.fragLimit);
    [server spawnLevel:@"check-dogfight"];
    Steps(server, clients, (ControlState){0}, 60);
    CHECK(!server.missionEnded && a.kills == 0 && b.deaths == 0 && b.ship.alive);
    // Leaving a solo host waiting must never finish an empty-objective mission.
    GClient *departing = level->_clients[1]; departing.selected = a.ship; departing.targetIsManual = YES;
    [level fireTorpedoFor:departing];
    GTorpedo *orphan = level->_torpedoes.lastObject; CHECK(orphan.owner == departing);
    for (NSUInteger i = 1; i < clients.count; i++) [clients[i] disconnect];
    [server frame:0]; CHECK(orphan.owner == nil);
    Steps(server, @[clients[0]], (ControlState){0}, 1000);
    CHECK(!server.missionEnded && level->_missionTime == 0);
    [clients[1] connectTo:[NetAddress loopback:1] transport:routes[@11] name:@"Returned"];
    Steps(server, @[clients[0], clients[1]], (ControlState){0}, 60);
    level->_missionTime = level->_level->rules.matchSeconds - TICK_DT;
    Steps(server, @[clients[0], clients[1]], (ControlState){0}, 2);
    CHECK(server.missionEnded);
    for (Client *client in clients) [client disconnect];
    [server stop];
    puts("PASS dogfight: eight opponents, targeting, secondary team, score, respawn, frag/time limits, rematch and solo waiting");
}

static void LateJoinCheck(void) {
    routes = [NSMutableDictionary dictionary]; delay = 0; dropEvery = 0; blackout = NO;
    assertPendingPrediction = NO;
    [Cvar set:@"g_lanMatchSeconds" value:@"120"];
    Server *server = [[Server alloc] initWithName:@"Running match"];
    [server addTransport:[Link port:1]]; [server spawnLevel:@"check-dogfight"];
    NSMutableArray<Client *> *clients = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        Client *client = [[Client alloc] initWithView:(ClientView *)[Spy new]];
        __weak Client *weak = client; client.gamestateHandler = ^{ [weak begin]; };
        [client connectTo:[NetAddress loopback:1] transport:[Link port:10+i] name:@"Existing pilot"];
        [clients addObject:client];
    }
    Steps(server, clients, (ControlState){0}, 1920);
    GClient *leader = level->_clients[0]; leader.kills = 1;
    float elapsed = level->_missionTime;
    CHECK(elapsed > 25 && !server.missionEnded);
    delay = 0.1; dropEvery = 11;
    // Drop the first joining attempt at the periodic loss phase.
    sent = 8; dropped = 0;
    Client *late = [[Client alloc] initWithView:(ClientView *)[Spy new]];
    __weak Client *weak = late; late.gamestateHandler = ^{ [weak begin]; };
    [late connectTo:[NetAddress loopback:1] transport:[Link port:12] name:@"Late pilot"];
    [clients addObject:late];
    Steps(server, clients, (ControlState){0}, 240);
    CHECK(server.clientCount == 3 && late.state == ClientActive && Latest(late).ps.alive);
    CHECK(Latest(late).ps.missionTime >= elapsed && !server.missionEnded);
    CHECK(leader.kills == 1 && Latest(clients[0]).ps.stats[STAT_KILLS] == 1);
    CHECK(Latest(late).ps.stats[STAT_KILLS] == 0);
    CHECK([late.configStrings[CS_MODE] isEqualToString:@"deathmatch"]);
    LANMatchSettings rules; CHECK(LANMatchSettingsDecode(late.configStrings[CS_LAN_RULES], &rules));
    for (Client *observer in clients) for (Client *other in clients) if (observer != other) {
        BOOL found = NO; Snapshot *snapshot = Latest(observer);
        for (NSUInteger i = 0; i < snapshot.entityCount; i++)
            if (snapshot.entityStates[i].number == Latest(other).ps.entity) found = YES;
        CHECK(found);
    }
    for (Client *client in clients) [client disconnect];
    delay = 0; dropEvery = 0; [server frame:0]; [server stop];
    [Cvar set:@"g_lanMatchSeconds" value:@"0"];
    puts("PASS late join: running match, live timer, preserved scores and all peers visible with delay and packet loss");
}

static void ConnectTimeoutCheck(void) {
    routes = [NSMutableDictionary dictionary];
    Client *client = [[Client alloc] initWithView:nil];
    __block BOOL timedOut = NO;
    client.disconnectHandler = ^(NSString *reason) { timedOut = YES; };
    [client connectTo:[NetAddress loopback:1] transport:[Link port:10] name:@"No host"];
    [client readPackets];
    CHECK(client.state == ClientConnecting);
    clockNow += NET_TIMEOUT + 1;
    [client readPackets];
    CHECK(timedOut && client.state == ClientDisconnected);
    puts("PASS missing host: connection attempts time out instead of retrying forever");
}

// Drive the real delegates without relying on Bonjour daemon timing or permissions.
@interface DiagnosticService : NSNetService
@property (nonatomic, copy) NSArray<NSData *> *testAddresses;
@end
@implementation DiagnosticService
- (NSArray<NSData *> *)addresses { return self.testAddresses; }
@end

@interface LANBrowser (DiagnosticChecks) <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@end

static void DiscoveryFailureChecks(void) {
    LANBrowser *noSocket = [[LANBrowser alloc] initWithSocket:nil];
    CHECK(noSocket.socketFailed && noSocket.discoveryFailed && !noSocket.searchError);
    [noSocket stop];
    LANBrowser *browser = [LANBrowser new];
    CHECK(!browser.socketFailed);
    NSDictionary *failure = @{NSNetServicesErrorDomain: @10, NSNetServicesErrorCode: @(-72000)};
    [browser netServiceBrowser:nil didNotSearch:failure];
    CHECK(browser.discoveryFailed && browser.searchError.code == -72000);
    CHECK(!browser.socketFailed && !browser.resolutionError && !browser.accessDenied);
    [browser netServiceBrowser:nil didNotSearch:@{NSNetServicesErrorDomain: @10, NSNetServicesErrorCode: @(-65570)}];
    CHECK(browser.accessDenied);
    [browser netServiceBrowserWillSearch:nil];
    CHECK(!browser.discoveryFailed && !browser.searchError && !browser.accessDenied);
    NSNetService *service = [[NSNetService alloc] initWithDomain:@"local." type:@"_kestrel._udp." name:@"Missing" port:12345];
    [browser netService:service didNotResolve:@{NSNetServicesErrorDomain: @10, NSNetServicesErrorCode: @(-72007)}];
    CHECK(browser.resolutionError.code == -72007 && !browser.discoveryFailed);
    [browser netServiceDidResolveAddress:service];
    CHECK([browser.resolutionError.domain isEqualToString:@"LANAddress"]);
    DiagnosticService *resolved = [[DiagnosticService alloc] initWithDomain:@"local." type:@"_kestrel._udp." name:@"Silent host" port:12345];
    NetAddress *address = [NetAddress addressWithString:@"127.0.0.1" port:12345];
    resolved.testAddresses = @[address.sockaddr];
    [browser netServiceDidResolveAddress:resolved];
    CHECK(!browser.resolutionError);
    clockNow += 7;
    [browser poll];
    CHECK(browser.hostUnreachable);
    [browser netServiceBrowser:nil didRemoveService:resolved moreComing:NO];
    [browser poll];
    CHECK(!browser.hostUnreachable);
    [browser stop];
    puts("PASS LAN diagnostics: socket failure, Bonjour search error/code and recovery, resolution timeout, no IPv4, silent host and removal");
}

static void MatchOptionsCheck(void) {
    const LevelDef *arena=LevelNamed(@"check-dogfight");
    LevelRules original=arena->rules;
    [Cvar set:@"g_lanFragLimit" value:@"5"];
    [Cvar set:@"g_lanMatchSeconds" value:@"600"];
    [Cvar set:@"g_lanRespawnSeconds" value:@"5"];
    [Cvar set:@"g_lanMaxPilots" value:@"2"];
    [Cvar set:@"g_lanShip" value:ShipDefNames().firstObject];
    routes=[NSMutableDictionary dictionary]; delay=0; dropEvery=0; blackout=NO;
    assertPendingPrediction=NO;
    Server *server=[[Server alloc] initWithName:@"Configured match"];
    LANMatchSettings settings=LANMatchSettingsDefault(); settings.maxPilots=2; server.matchSettings=settings;
    [server addTransport:[Link port:1]]; [server spawnLevel:arena->name];
    CHECK(level->_level->rules.fragLimit==5 && level->_level->rules.matchSeconds==600 && level->_level->rules.respawnSeconds==5);
    CHECK([level->_level->playerShip isEqualToString:ShipDefNames().firstObject]);
    CHECK(arena->rules.fragLimit==original.fragLimit && arena->rules.matchSeconds==original.matchSeconds && arena->rules.respawnSeconds==original.respawnSeconds);
    NSMutableArray *clients=[NSMutableArray array];
    for(int i=0;i<3;i++) {
        Client *client=[[Client alloc] initWithView:(ClientView *)[Spy new]];
        __weak Client *weak=client; client.gamestateHandler=^{ [weak begin]; };
        [client connectTo:[NetAddress loopback:1] transport:[Link port:10+i] name:@"Configured pilot"];
        [clients addObject:client];
    }
    Steps(server,clients,(ControlState){0},60);
    CHECK(server.clientCount==2 && ((Client *)clients[2]).state==ClientDisconnected);
    LANMatchSettings advertised;
    CHECK(LANMatchSettingsDecode(((Client *)clients[0]).configStrings[CS_LAN_RULES],&advertised));
    CHECK(advertised.fragLimit==5 && advertised.maxPilots==2 && advertised.respawnSeconds==5 && advertised.matchSeconds==600);
    for(Client *client in clients) [client disconnect];
    [server frame:0]; [server stop];
    for(NSString *key in @[@"g_lanFragLimit",@"g_lanMatchSeconds",@"g_lanRespawnSeconds",@"g_lanMaxPilots"]) [Cvar set:key value:@"0"];
    [Cvar set:@"g_lanShip" value:@""];
    puts("PASS match options: authoritative rules and ship, unchanged arena data, guest settings and pilot capacity");
}

static void MultipleAddressCheck(void) {
    Server *server=[[Server alloc] initWithName:@"Multiple routes"];
    UDPTransport *socket=[[UDPTransport alloc] initWithPort:0 attempts:1];
    UDPTransport *silent=[[UDPTransport alloc] initWithPort:0 attempts:1];
    CHECK(socket && silent); [server addTransport:socket]; server.publicHosting=YES;
    LANBrowser *browser=[LANBrowser new];
    ResolvedServiceFixture *service=[[ResolvedServiceFixture alloc] initWithDomain:@"local." type:@"_kestrel._udp." name:@"Multiple routes" port:socket.port];
    service.fixtureAddresses=@[[NetAddress addressWithString:@"127.0.0.1" port:silent.port].sockaddr,
        [NetAddress addressWithString:@"127.0.0.1" port:socket.port].sockaddr];
    [browser netServiceDidResolveAddress:service];
    BOOL found=NO;
    for(int i=0;i<100 && !found;i++) {
        clockNow+=0.03; [browser poll]; usleep(1000); [server frame:0]; [browser poll];
        for(LANServer *entry in browser.servers) if(entry.address.port==socket.port) found=YES;
    }
    CHECK(found); [browser stop]; [server closeSession];
    puts("PASS discovery queries every IPv4 candidate when the first route is silent");
}

static void DiscoveryCheck(void) {
    Server *server = [[Server alloc] initWithName:@"Bonjour check"]; CHECK(server);
    UDPTransport *socket = [[UDPTransport alloc] initWithPort:0 attempts:1]; CHECK(socket);
    [server addTransport:socket];
    UDPTransport *probe = [[UDPTransport alloc] initWithPort:0 attempts:1]; CHECK(probe);
    NetAddress *address = [NetAddress addressWithString:@"127.0.0.1" port:socket.port];
    [NetChannel sendOutOfBand:@"info" transport:probe to:address];
    [server frame:0]; NetAddress *from;
    CHECK(![probe receiveFrom:&from]);
    server.publicHosting = YES;
    for (int i = 0; i < 50 && !server.clientCount; i++) {
        [NetChannel sendOutOfBand:[NSString stringWithFormat:@"connect %d Guest", PROTOCOL_VERSION] transport:probe to:address];
        usleep(1000); [server frame:0];
    }
    CHECK(server.clientCount == 1 && [probe receiveFrom:&from]);
    DiscoveryAdvertisement *advertisement = [[DiscoveryAdvertisement alloc] initWithName:server.name port:socket.port];
    DiscoveryBrowser *browser = [DiscoveryBrowser new];
    BOOL found = NO;
    double until = CFAbsoluteTimeGetCurrent() + 10;
    while (!found && CFAbsoluteTimeGetCurrent() < until) @autoreleasepool {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        clockNow += 0.02;
        [browser poll]; [server frame:0]; [browser poll];
        for (LANServer *entry in browser.servers) if (entry.address.port == socket.port) found = YES;
    }
    NSLog(@"BONJOUR SMOKE result: published=%d publishFailed=%d browseFailed=%d discovered=%lu resolved=%lu UDPReply=%d",
          advertisement.published, advertisement.failed, browser.discoveryFailed,
          (unsigned long)browser.discovered, (unsigned long)browser.resolved, found);
    CHECK(!advertisement.failed && !browser.discoveryFailed && found);
    [browser netServiceBrowser:nil didNotSearch:@{NSNetServicesErrorDomain: @10, NSNetServicesErrorCode: @(-72000)}];
    [browser query:address]; [server frame:0]; [browser poll];
    CHECK(browser.discoveryFailed && browser.servers.count > 0);
    [browser stop]; [advertisement stop];
    [server closeSession]; CHECK(server.clientCount == 0 && !server.publicHosting);
    BOOL closed = NO; NSData *packet;
    while ((packet = [probe receiveFrom:&from])) if (![NetChannel outOfBandText:packet]) closed = YES;
    CHECK(closed);
    puts("PASS Bonjour: ephemeral-port host discovered without port scanning; private sessions hidden; host closure notifies peers");
}

static int LivePeer(NSString *host) {
    FSSetGame(@"KestrelFrontier");
    UDPTransport *socket = [[UDPTransport alloc] initWithPort:0 attempts:1]; CHECK(socket);
    Client *client = [[Client alloc] initWithView:(ClientView *)[Spy new]];
    __weak Client *weak = client; client.gamestateHandler = ^{ [weak begin]; puts("PEER entered match"); fflush(stdout); };
    __block BOOL disconnected = NO;
    client.disconnectHandler = ^(NSString *reason) { printf("PEER disconnected: %s\n", reason.UTF8String); disconnected = YES; };
    [client connectTo:[NetAddress addressWithString:host port:PORT_SERVER] transport:socket name:@"Release check peer"];
    printf("PEER joining %s\n", host.UTF8String); fflush(stdout);
    BOOL active = NO;
    for (int i = 0; i < 60 * 180 && !disconnected; i++) @autoreleasepool {
        clockNow += 1.0 / 60;
        [client readPackets]; [client sendInput:(ControlState){.throttle=.4, .yaw=.1, .fire=YES} actions:0 dt:1.0f/60];
        if (!active && Latest(client)) { active = YES; puts("PEER receiving live snapshots"); fflush(stdout); }
        usleep(16667);
    }
    [client disconnect]; return active ? 0 : 1;
}
#include "CampaignChecks.h"
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc > 2 && !strcmp(argv[1], "--campaign")) return CampaignAudit(@(argv[2]));
    if (argc > 2 && !strcmp(argv[1], "--peer")) return LivePeer(@(argv[2]));
    if (argc > 1 && !strcmp(argv[1], "--identity")) { puts(ShipDataIdentity().UTF8String); return 0; }
    if (argc > 1 && !strcmp(argv[1], "--udp-disconnect")) {
        DisconnectDeliveryCheck(); UDPSmoke(); return 0;
    }
    for (int mission = 0; mission < 2; mission++) for (int loss = 0; loss < 2; loss++) Scenario(mission, loss);
    CHECK(predictionChecks > 1000);
    printf("PASS %lu pending-input prediction comparisons against subsequent authority\n", (unsigned long)predictionChecks);
    AimAssistCheck();
    IonRun();
    IonPlayer();
    OrdersRun();
    BoardRun();
    SecondaryTargetingRun();
    DisconnectDeliveryCheck();
    UDPSmoke();
    DeathmatchRun();
    MatchOptionsCheck();
    LateJoinCheck();
    MultipleAddressCheck();
    ConnectTimeoutCheck();
    DiscoveryFailureChecks();
    DiscoveryCheck();
    puts("PASS simulated impairment and localhost UDP; no real LAN/device claim");
    return 0;
} }
