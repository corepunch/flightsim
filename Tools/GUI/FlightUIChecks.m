#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import "HUD.h"
#import "FlightInstruments.h"
#import "PauseMenu.h"
#import "Briefing.h"
#import "Progress.h"
#import "NetProtocol.h"
#import "Server.h"
#import "Client.h"
#import "Cvar.h"
#import "Assets.h"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); return 1; } } while (0)
static NSString *Output;
static void Save(SKScene *scene, NSString *name) {
    SKView *view = [[SKView alloc] initWithFrame:(CGRect){.size=scene.size}];
    [view presentScene:scene];
    SKTexture *texture = [view textureFromNode:scene crop:(CGRect){.size=scene.size}];
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:texture.CGImage];
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[Output stringByAppendingPathComponent:name] atomically:YES];
}
static CGRect FrameInScene(SKNode *node, SKScene *scene) {
    CGRect rect = node.frame;
    CGPoint lo = [scene convertPoint:rect.origin fromNode:node.parent];
    CGPoint hi = [scene convertPoint:CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect)) fromNode:node.parent];
    return CGRectMake(lo.x, lo.y, hi.x-lo.x, hi.y-lo.y);
}
static int CheckSensors(void) {
    CockpitFrame frame = {.alive=YES, .target=0};
    CockpitContact contacts[3] = {
        {.local={0,0,-1000}, .team=TeamEnemy},
        {.local={1000,0,-1000}, .team=TeamFriend},
        {.local={0,0,1000}, .team=TeamNeutral}
    };
    SensorScope *front = [[SensorScope alloc] initRear:NO], *rear = [[SensorScope alloc] initRear:YES];
    [front updateFrame:frame contacts:contacts count:3]; [rear updateFrame:frame contacts:contacts count:3];
    NSArray<SKNode *> *f = [front valueForKey:@"blips"], *r = [rear valueForKey:@"blips"];
    CHECK(!f[0].hidden && !f[1].hidden && f[2].hidden);
    CHECK(r[0].hidden && r[1].hidden && !r[2].hidden);
    CHECK(fabs(f[0].position.x) < .1 && fabs(f[0].position.y) < .1);
    CHECK(f[1].position.x > 0 && f[1].position.x < 60);
    frame.target = 2;
    [rear updateFrame:frame contacts:contacts count:3];
    CHECK(![[rear valueForKey:@"selected"] isHidden]);
    [rear updateFrame:frame contacts:NULL count:0];
    CHECK([[rear valueForKey:@"selected"] isHidden]);
    return 0;
}
static int CheckHUD(void) {
    CockpitContact contact = {.local={100,50,-1210}, .team=TeamEnemy, .hull=.72, .shield=.4, .systems=.75,
        .name=@"Corsair Cutter Rask", .className=@"Corsair cutter", .cargo=@"Skarn munitions", .component=@"SHIELD GENERATOR",
        .geometry=[ShipView geometryForClass:ShipClassExecutioner], .holoScale=.0075,
        .orientation=simd_quaternion(0.7f, simd_make_float3(0,1,0))};
    CockpitFrame instrument = {.alive=YES, .target=0, .laserEnergy=.85, .shield=.6, .closingSpeed=42, .time=2};
    for (NSValue *size in @[[NSValue valueWithSize:NSMakeSize(1440,900)], [NSValue valueWithSize:NSMakeSize(1194,834)], [NSValue valueWithSize:NSMakeSize(932,430)], [NSValue valueWithSize:NSMakeSize(852,393)], [NSValue valueWithSize:NSMakeSize(430,932)]]) {
        HUD *hud = [[HUD alloc] initWithSize:size.sizeValue];
        hud.backgroundColor = [SKColor colorWithRed:.015 green:.025 blue:.035 alpha:1];
        hud.touchLayout = hud.size.width < 1200;
        if (hud.touchLayout) hud.contentInsets = hud.size.width == 1194 ? NSEdgeInsetsMake(24,0,20,0) : NSEdgeInsetsMake(0,59,21,59);
        [hud setHelpVisible:NO];
        [hud setInputText:hud.touchLayout ? @"" : @"CONTROLLER: USB  /  T TARGET  /  G TORPEDO  /  ESC PAUSE"];
        [hud setObjectives:@[@"Patrol NAV 1, 2, 3 in order  0/3"] states:@[@0]];
        HUDFrame frame = {.speed=125, .throttle=.8, .boostEnergy=.6, .hull=.9, .shield=.6, .torpedoes=2, .torpedoCapacity=4};
        [hud updateFrame:frame targets:NULL count:0];
        [hud updateInstruments:instrument contacts:&contact count:1 cockpit:NO];
        SKNode *laser = [hud valueForKey:@"laserLabel"], *speed = [hud valueForKey:@"speedLabel"], *throttle = [hud valueForKey:@"throttleLabel"], *input = [hud valueForKey:@"inputLabel"], *target = [hud valueForKey:@"targetReadout"];
        CHECK(!CGRectIntersectsRect(laser.frame, speed.frame));
        CHECK(!CGRectIntersectsRect(laser.frame, throttle.frame));
        CHECK(!CGRectIntersectsRect(speed.frame, throttle.frame));
        if (!hud.touchLayout) CHECK([(SKLabelNode *)input text].length == 0);
        else {
            CHECK(speed.position.x < 90);
            SKNode *shield = [hud valueForKey:@"shieldFill"];
            CHECK(shield.position.x > hud.size.width - 170);
        }
        SKNode *forward = [hud valueForKey:@"forwardScope"], *rear = [hud valueForKey:@"rearScope"];
        SKNode *objectives = [hud valueForKey:@"objectivePanel"];
        CHECK(fabs(forward.position.y - rear.position.y) < 0.01);
        CHECK(CGRectGetMaxX(forward.frame) + 8 <= CGRectGetMinX([objectives calculateAccumulatedFrame]));
        CHECK(CGRectGetMinX(forward.frame) >= (hud.touchLayout ? hud.contentInsets.left : 0));
        CHECK(CGRectGetMaxX(rear.frame) <= hud.size.width - (hud.touchLayout ? hud.contentInsets.right : 0));
        if (hud.touchLayout) {
            CGFloat right = hud.size.width - hud.contentInsets.right - 12;
            CGFloat pauseRight = right - 128 * forward.xScale - 8;
            CHECK(pauseRight + 4 <= CGRectGetMinX(rear.frame));
        }
        TargetReadout *readout = (TargetReadout *)target;
        CHECK([[(SKLabelNode *)[readout valueForKey:@"cargo"] text] containsString:@"SKARN MUNITIONS"]);
        CHECK([[(SKLabelNode *)[readout valueForKey:@"component"] text] containsString:@"SHIELD GENERATOR"]);
        CockpitContact side = contact;
        side.local = simd_make_float3(1000, 0, 0);
        side.orientation = simd_quaternion(0, simd_make_float3(0, 1, 0));
        [readout updateFrame:instrument contacts:&side count:1];
        SCNNode *holder = [readout valueForKey:@"holder"];
        simd_float3 towardPlayer = simd_act(holder.simdOrientation, simd_make_float3(-1, 0, 0));
        CHECK(simd_distance(towardPlayer, simd_make_float3(0, 0, 1)) < .001);
        [readout updateFrame:instrument contacts:&contact count:1];

        for (SKNode *node in readout.children) CHECK(![node isKindOfClass:SKShapeNode.class]);
        NSString *prefix = [NSString stringWithFormat:@"hud-%.0fx%.0f", hud.size.width, hud.size.height];
        Save(hud, [prefix stringByAppendingString:@".png"]);
        instrument.target = -1; [hud updateInstruments:instrument contacts:NULL count:0 cockpit:NO];
        CHECK(![[(SKLabelNode *)[readout valueForKey:@"empty"] text] isEqualToString:@""]);
        Save(hud, [prefix stringByAppendingString:@"-no-target.png"]);
        instrument.target = 0;
    }
    return 0;
}
// Two sibling labels whose frames intersect are drawn over each other. Walks
// the whole tree; returns the first offending pair in `where`. Hidden and
// empty labels do not count.
static BOOL OverlappingSiblingLabels(SKNode *parent, NSString **where) {
    NSMutableArray<SKLabelNode *> *labels = [NSMutableArray array];
    for (SKNode *child in parent.children) {
        if (child.hidden || child.alpha <= 0) continue;
        if ([child isKindOfClass:SKLabelNode.class] && [(SKLabelNode *)child text].length) [labels addObject:(SKLabelNode *)child];
        if (OverlappingSiblingLabels(child, where)) return YES;
    }
    for (NSUInteger i = 0; i < labels.count; i++)
        for (NSUInteger j = i + 1; j < labels.count; j++)
            if (CGRectIntersectsRect(labels[i].frame, labels[j].frame)) {
                *where = [NSString stringWithFormat:@"\"%@\" %@ overlaps \"%@\" %@", labels[i].text, NSStringFromRect(labels[i].frame),
                          labels[j].text, NSStringFromRect(labels[j].frame)];
                return YES;
            }
    return NO;
}

static int CheckGrid(void) {
    [NSUserDefaults.standardUserDefaults setInteger:4 forKey:@"SFMissionsUnlocked"];
    // Entrance effects briefly draw copies of labels; the layout itself is checked.
    [Cvar set:@"ui_reduceMotion" value:@"1"];
    ProgressRecordResult(0, @[@"+ Patrol", @"+ Escort"]);
    CHECK(ProgressBestStars(0) == 3);
    ProgressRecordResult(0, @[@"+ Patrol", @"- Escort"]);
    CHECK(ProgressBestStars(0) == 3);
    for (NSValue *size in @[[NSValue valueWithSize:NSMakeSize(1440,900)], [NSValue valueWithSize:NSMakeSize(932,430)], [NSValue valueWithSize:NSMakeSize(430,932)]]) {
        Briefing *grid = [[Briefing alloc] initWithSize:size.sizeValue];
        if (grid.size.width < 1000) grid.contentInsets = NSEdgeInsetsMake(0,59,21,59);
        [grid showListSelecting:0]; [grid tick:0];
        NSArray<NSValue *> *tiles = [grid valueForKey:@"missionTiles"];
        CHECK(tiles.count == CampaignMissions().count);
        CGRect viewport = [[grid valueForKey:@"missionRows"] rectValue];
        for (NSUInteger i=0; i<tiles.count; i++) {
            CGRect a = tiles[i].rectValue;
            CHECK(a.size.width >= 140 && a.size.height >= 140);
            for (NSUInteger j=i+1; j<tiles.count; j++) CHECK(!CGRectIntersectsRect(a, tiles[j].rectValue));
        }
        NSString *where = nil;
        if (OverlappingSiblingLabels(grid, &where)) fprintf(stderr, "%s: %s\n", NSStringFromSize(grid.size).UTF8String, where.UTF8String);
        CHECK(where == nil);
        Save(grid, [NSString stringWithFormat:@"missions-%.0fx%.0f.png", grid.size.width,grid.size.height]);
        CGPoint origin = CGPointMake(CGRectGetMidX(viewport)/grid.size.width, CGRectGetMidY(viewport)/grid.size.height);
        [grid queueScrollBy:10000 atFraction:origin]; [grid handle:0];
        CGFloat offset = [[grid valueForKey:@"scrollOffset"] doubleValue];
        CGRect last = tiles.lastObject.rectValue;
        CGPoint hit = CGPointMake(CGRectGetMidX(last)/grid.size.width, (CGRectGetMidY(last)+offset)/grid.size.height);
        CHECK(CGRectContainsPoint(viewport, CGPointMake(hit.x*grid.size.width, hit.y*grid.size.height)));
        [grid queueClickAtFraction:hit]; [grid handle:0];
        CHECK(grid.selectedIndex == tiles.count-1);
        [grid handle:InputActionConfirm];
        CHECK([[grid valueForKey:@"mode"] integerValue] == 0); // Locked stays on the grid.
    }
    [Cvar set:@"ui_reduceMotion" value:@""];
    return 0;
}
static int CheckPause(void) {
    for (NSValue *size in @[[NSValue valueWithSize:NSMakeSize(1440,900)], [NSValue valueWithSize:NSMakeSize(932,430)], [NSValue valueWithSize:NSMakeSize(430,932)]]) {
        PauseMenu *menu = [[PauseMenu alloc] initWithSize:size.sizeValue];
        [menu showRemote:NO cockpit:NO];
        CHECK([menu handle:InputActionBack] == PauseCommandResume);
        CHECK([menu handle:InputActionConfirm] == PauseCommandResume);
        Save(menu, [NSString stringWithFormat:@"pause-%.0fx%.0f.png", menu.size.width,menu.size.height]);
        [menu handle:InputActionDown]; CHECK([menu handle:InputActionConfirm] == PauseCommandCamera);
        [menu handle:InputActionDown]; CHECK([menu handle:InputActionConfirm] == PauseCommandSound);
        [menu handle:InputActionDown]; CHECK([menu handle:InputActionConfirm] == PauseCommandRestart);
        [menu handle:InputActionDown]; CHECK([menu handle:InputActionConfirm] == PauseCommandMissions);
        [menu showRemote:YES cockpit:YES];
        for (int i=0;i<3;i++) [menu handle:InputActionDown];
        CHECK([menu handle:InputActionConfirm] == PauseCommandNone);
    }
    return 0;
}
static int CheckProtocol(void) {
    EntityState entity = {.number=1, .name=2, .className=3, .cargo=4, .flags=EF_SCANNED, .scale=1, .orientation={{0,0,0,1}}};
    MsgWriter *writer = [MsgWriter new]; WritePacketEntities(writer,NULL,0,&entity,1);
    MsgReader *reader = [[MsgReader alloc] initWithData:writer.data];
    NSMutableData *decoded = [NSMutableData data]; CHECK(ReadPacketEntities(reader,NULL,0,decoded));
    CHECK(decoded.length == sizeof(EntityState));
    EntityState from = *(const EntityState *)decoded.bytes;
    CHECK(from.cargo == 4 && from.flags == EF_SCANNED);
    entity.cargo=0; entity.flags=0;
    writer=[MsgWriter new]; WritePacketEntities(writer,&from,1,&entity,1);
    reader=[[MsgReader alloc] initWithData:writer.data]; decoded=[NSMutableData data];
    CHECK(ReadPacketEntities(reader,&from,1,decoded));
    CHECK(((const EntityState *)decoded.bytes)->cargo == 0);
    return 0;
}
static void Pump(Client *client, Server *server, ControlState controls, BOOL paused) {
    [client setValue:@0 forKey:@"lastMoveSent"]; // Virtual-time network fixture, no real-time throttle.
    [client sendInput:controls actions:0 dt:TICK_DT]; [server frame:TICK_DT paused:paused]; [client readPackets];
}
static PlayerState Latest(Client *client) { return ((Snapshot *)[[client valueForKey:@"snapshots"] lastObject]).ps; }
static int CheckSimulation(void) {
    Server *server = [[Server alloc] initWithName:@"Pause fixture"];
    CHECK(server);
    [server addTransport:[LoopbackTransport side:1]]; [server spawnMission:0];
    Client *client = [[Client alloc] initWithView:nil];
    __weak Client *weak = client; client.gamestateHandler = ^{ [weak begin]; };
    [client connectTo:[NetAddress loopback:1] transport:[LoopbackTransport side:0] name:@"Fixture"];
    for (int i=0;i<10;i++) Pump(client,server,(ControlState){.hat=-1},NO);
    CHECK(client.state == ClientActive);
    PlayerState before = Latest(client);
    double time = server.time;
    // Even a peer sending thrust/fire cannot advance a locally paused game.
    for (int i=0;i<90;i++) Pump(client,server,(ControlState){.hat=-1,.throttle=1,.fire=YES},YES);
    CHECK(server.time == time);
    [server frame:TICK_DT paused:NO]; [client readPackets];
    PlayerState after = Latest(client);
    CHECK(simd_distance(before.move.origin,after.move.origin) < .01);
    CHECK(after.stats[STAT_LASER_ENERGY] == before.stats[STAT_LASER_ENERGY]);
    for (int i=0;i<120;i++) Pump(client,server,(ControlState){.hat=-1,.fire=YES},NO);
    int depleted = Latest(client).stats[STAT_LASER_ENERGY];
    CHECK(depleted < 950 && depleted >= 0);
    for (int i=0;i<150;i++) Pump(client,server,(ControlState){.hat=-1},NO);
    CHECK(Latest(client).stats[STAT_LASER_ENERGY] > depleted);
    [client disconnect]; [server stop];
    return 0;
}
int main(int argc, const char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    Output = argc>1 ? @(argv[1]) : @"/tmp";
    if (CheckSensors() || CheckHUD() || CheckGrid() || CheckPause() || CheckProtocol() || CheckSimulation()) return 1;
    puts("PASS: flight instruments, mission grid, pause, capacitor and cargo protocol.");
} return 0; }
