// Actual Server, Client, NetChannel and game module; only datagram delivery and
// presentation are replaced. One virtual clock, no sleeps, seeds or LAN needed.
#import "Server.h"
#import "Client.h"
#import "Net.h"
#import "Shared.h"
#import "Common.h"
#include <stdio.h>
#include <stdlib.h>

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
@property NSUInteger shots, bolts;
@property float life, boltLife, relativeSpeed;
@property ShipMoveState drawn;
@end
@implementation Spy
- (void)serverCommand:(int)t a:(NSString *)a b:(NSString *)b c:(NSString *)c {}
- (void)handleEvent:(const GameEvent *)e player:(const PlayerState *)ps {
    if (e->type == EV_BOLT && e->entity == ps->entity) {
        self.bolts++; self.boltLife = e->scale;
        self.relativeSpeed = simd_length(e->vel - ps->move.velocity);
    }
}
- (void)predictedShotFrom:(simd_float3)p velocity:(simd_float3)v gun:(simd_float3)g life:(float)life {
    self.shots++; self.life = life;
}
- (void)drawEntities:(const EntityState *)e count:(NSUInteger)n player:(const PlayerState *)ps
           controls:(ControlState)c time:(double)t dt:(float)dt { self.drawn = ps->move; }
@end

static Snapshot *Latest(Client *c) { return [[c valueForKey:@"snapshots"] lastObject]; }
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
static void UDPSmoke(void) {
    assertPendingPrediction = YES;
    delay = 0; dropEvery = 0; blackout = NO;
    Server *server = [[Server alloc] initWithName:@"UDP localhost"]; CHECK(server);
    UDPTransport *host = [[UDPTransport alloc] initWithPort:0 attempts:1]; CHECK(host);
    [server addTransport:host]; [server spawnLevel:@"check-1"];
    NetAddress *address = [NetAddress addressWithString:@"127.0.0.1" port:host.port];
    NSMutableArray<Client *> *clients = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        UDPTransport *socket = [[UDPTransport alloc] initWithPort:0 attempts:1]; CHECK(socket);
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
    [server frame:0]; CHECK(server.clientCount == 0); [server stop];
    puts("PASS real IPv4 UDP sockets on localhost, one process, two clients");
}
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc > 1 && !strcmp(argv[1], "--identity")) { puts(ShipDataIdentity().UTF8String); return 0; }
    for (int mission = 0; mission < 2; mission++) for (int loss = 0; loss < 2; loss++) Scenario(mission, loss);
    CHECK(predictionChecks > 1000);
    printf("PASS %lu pending-input prediction comparisons against subsequent authority\n", (unsigned long)predictionChecks);
    UDPSmoke();
    puts("PASS simulated impairment and localhost UDP; no real LAN/device claim");
    return 0;
} }
