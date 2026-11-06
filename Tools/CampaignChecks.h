// Scripted interactions check mission wiring against the production world and
// baked subsystem geometry. They do not measure human combat difficulty.
#import "Story.h"

static void CampaignInteraction(GClient *pilot) {
    for (MissionObjective *objective in level->_runner.objectives) {
        if (objective.state != MissionObjectiveActive || objective.optional) continue;
        NSString *type = objective.type;
        if ([type isEqualToString:@"reach"]) {
            if (level->_currentNav) pilot.ship.position = [level navPosition:level->_currentNav];
        } else if ([type isEqualToString:@"scan"] || [type isEqualToString:@"collect"]) {
            for (id<MissionUnit> unit in [level->_runner unitsNamed:objective.targets]) {
                if (!unit.missionAlive || unit.missionGone || ([type isEqualToString:@"scan"] && unit.missionScanned)) continue;
                pilot.ship.position = unit.missionPosition + simd_make_float3(unit.missionRadius + 5, 0, 0);
                break;
            }
        } else if ([type isEqualToString:@"destroy"]) {
            for (id<MissionUnit> unit in [level->_runner unitsNamed:objective.targets])
                if (unit.missionAlive) [(id<MissionWorld>)level missionDestroy:unit];
        } else if ([type isEqualToString:@"disable"]) {
            NSString *kind = JSONString(objective.definition, @"kind") ?: @"Turret";
            for (GCapital *capital in [level->_runner unitsNamed:objective.targets]) {
                CHECK([capital isKindOfClass:GCapital.class]);
                CHECK([(id<MissionUnit>)capital missionPartsOfKind:kind alive:NO] > 0);
                for (GSubsystem *part in capital.subsystems) {
                    NSString *name = @[@"Turret", @"Engine", @"Shield", @"Core"][part.kind];
                    if ([name isEqualToString:kind] && part.alive) {
                        part.hp = 0; part.alive = NO;
                    }
                }
            }
        }
    }
}

static int CampaignAudit(NSString *game) {
    FSSetGame(game);
    [Cvar set:@"fs_game" value:game];
    NSArray<CampaignMission *> *missions = CampaignMissions(); CHECK(missions.count);
    routes = [NSMutableDictionary dictionary]; delay = 0; dropEvery = 0; blackout = NO;
    assertPendingPrediction = NO;
    Server *server = [[Server alloc] initWithName:@"Campaign audit"]; CHECK(server);
    [server addTransport:[Link port:1]];
    Client *client = [[Client alloc] initWithView:(ClientView *)[Spy new]];
    __weak Client *weak = client; client.gamestateHandler = ^{ [weak begin]; };
    [client connectTo:[NetAddress loopback:1] transport:[Link port:10] name:@"Scripted pilot"];
    for (CampaignMission *mission in missions) {
        [server spawnLevel:mission.levelName];
        Steps(server, @[client], (ControlState){0}, 30);
        GClient *pilot = level->_clients[0]; CHECK(pilot.inGame && pilot.ship.alive);
        CHECK([MissionRunner problemsWithLevel:level->_level].count == 0);
        CHECK(level->_runner && !GIsDeathmatch());
        // Move escorts and boarders normally; supply ideal player interactions.
        // Combat is omitted so a broken dependency cannot hide behind an AI loss.
        for (int frame = 0; frame < 30 * 1200 && !level->_runner.over; frame++) @autoreleasepool {
            CampaignInteraction(pilot);
            level->_time += TICK_DT;
            for (GCapital *capital in level->_capitals) [capital update:TICK_DT];
            for (GPilot *boarder in [level->_pilots copy])
                if ([boarder.order isEqualToString:@"board"]) [level thinkPilot:boarder dt:TICK_DT];
            [level updateMission:TICK_DT];
            clockNow += TICK_DT;
            [client readPackets];
            [client sendInput:(ControlState){0} actions:0 dt:TICK_DT];
            [server frame:0 paused:YES];
            [client readPackets];
        }
        if (!level->_runner.success || !level->_runner.over) {
            fprintf(stderr, "Campaign stalled: %s at %.0f seconds\n", mission.levelName.UTF8String, level->_runner.time);
            for (MissionObjective *o in level->_runner.objectives)
                fprintf(stderr, "  %s: %ld %s\n", o.identifier.UTF8String, (long)o.state, o.progress.UTF8String);
        }
        CHECK(level->_runner.success && level->_runner.over);
        printf("PASS campaign flow %s: %s in %.0f simulated seconds\n", game.UTF8String, mission.levelName.UTF8String, level->_runner.time);
        [server stop];
        [client leaveGame];
        [server spawnLevel:mission.levelName];
        Steps(server, @[client], (ControlState){0}, 30);
        CHECK(pilot.inGame && pilot.ship.alive);
        [level damageShip:pilot.ship amount:100 by:nil shake:0];
        Steps(server, @[client], (ControlState){0}, 150);
        CHECK(server.missionEnded && !level->_runner.success);
        [server stop]; [client leaveGame];
    }
    [client disconnect];
    printf("PASS %lu scripted mission successes and player-death failures; combat difficulty is not measured\n", (unsigned long)missions.count);
    return 0;
}
