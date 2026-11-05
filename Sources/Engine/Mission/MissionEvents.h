#import "MissionObjective.h"

// Scripted events: a level's "events" list.
//
//   "events": [
//     { "when": { "time": 2 },                       "do": [ { "radio": { "from": "Relay K-7", "text": "…" } } ] },
//     { "when": { "spawned": "b2" },                 "do": [ { "radio": { … } } ] },
//     { "when": { "objective": "shields" },          "do": [ { "spawn": "w3" }, { "set_team": { "barge": "friend" } } ] },
//     { "when": { "any": [ { "objective": "x" }, { "destroyed": "Lancer 2" } ] },
//                                                    "do": [ { "destroy": "Lancer 2" }, { "radio": { … } } ] }
//   ]
//
// An event fires once, the first frame its "when" holds ("repeat": true
// fires it every time it becomes true again). Triggers and actions are
// registered by name, like objective types.
//
// Triggers:
//   time: seconds            mission time reached
//   objective: id, state     an objective's state ("complete" by default; "failed", "active")
//   spawned: name            a unit, wave or group has arrived
//   destroyed: name          everything by that name has arrived and is gone (dead, not departed)
//   nav: id                  a player has been within 400 m of the nav
//   flag: name               set by the set_flag action
//   all: [ … ], any: [ … ], not: { … }
// Actions:
//   spawn: name | [names]    a held entity, wave or group arrives
//   radio: { from, text }    radio message to every player
//   banner: { text, alert }  big centred line
//   set_team: { name: team } units change side
//   destroy: name            units are destroyed
//   objective: { id, state } force an objective's state ("complete", "failed", "active")
//   set_flag: name
//   end: "success" | "failure"

@protocol MissionEventContext <MissionContext>
- (MissionObjective *)objectiveNamed:(NSString *)identifier;
- (BOOL)hasSpawned:(NSString *)name;
- (BOOL)navVisited:(NSString *)nav;
- (BOOL)flag:(NSString *)name;
- (void)setFlag:(NSString *)name;
- (void)endMission:(BOOL)success;
@end

typedef BOOL (^MissionTrigger)(id value, id<MissionEventContext> context);
typedef void (^MissionAction)(id value, id<MissionEventContext> context);

@interface MissionEvents : NSObject

+ (void)registerTrigger:(NSString *)name block:(MissionTrigger)block;
+ (void)registerAction:(NSString *)name block:(MissionAction)block;
+ (NSArray<NSString *> *)registeredTriggers;
+ (NSArray<NSString *> *)registeredActions;

// Problems with an "events" list: unknown triggers or actions, wrong shapes.
+ (NSArray<NSString *> *)problemsWithEvents:(id)events;

- (instancetype)initWithEvents:(NSArray<NSDictionary *> *)events;
// Fires every event whose condition now holds.
- (void)updateIn:(id<MissionEventContext>)context;

// Evaluates one "when" object (for objectives or games that want the same vocabulary).
+ (BOOL)condition:(NSDictionary *)when holdsIn:(id<MissionEventContext>)context;

@end

MissionObjectiveState MissionObjectiveStateNamed(NSString *name);
