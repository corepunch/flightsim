#import "MissionEvents.h"

// Runs one level's objectives, events and rules against a MissionWorld.
//
// The level keys it reads: "objectives", "events", "rules", "navs". Spawning
// the level's units is the game's job; it tells the runner what has arrived
// with -noteSpawned: (entity ids, groups, wave ids, and "start").
//
// Rules (all default to true):
//   "rules": { "succeedWhenObjectivesDone": true,   // every required objective complete (ongoing ones excepted)
//              "failOnObjectiveFailed": true,       // a required objective failed
//              "failWhenPlayersDown": true }        // every player's ship is down
@interface MissionRunner : NSObject <MissionEventContext>

// Problems with a level against the registered types, triggers and actions;
// empty when the runtime can run it.
+ (NSArray<NSString *> *)problemsWithLevel:(NSDictionary *)level;

- (instancetype)initWithLevel:(NSDictionary *)level world:(id<MissionWorld>)world;

- (void)noteSpawned:(NSString *)name;
// Sends the objective list again (a player joined).
- (void)resendObjectives;
// One frame: advances mission time by dt, then events, objectives and rules.
- (void)update:(float)dt;

@property (nonatomic, readonly) NSArray<MissionObjective *> *objectives;
@property (nonatomic, readonly) BOOL ending;      // decided; the end is announced after a pause
@property (nonatomic, readonly) BOOL over;        // the end has been reported to the world
@property (nonatomic, readonly) BOOL success;

@end
