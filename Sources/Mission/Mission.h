#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>
#import "Shared.h"

// MARK: - MissionWorld

// The mission runtime: an engine library linked into every game module (not
// into the engine binary, so its classes exist once per process). It runs a
// level's objectives, scripted events and win/lose rules from the level's
// JSON; the game supplies the world through MissionWorld and MissionUnit.
//
// A game never re-implements objectives or events. A type only one game can
// use may be registered by that game (see MissionObjective, MissionEvents);
// when a second game needs it, it moves into this folder.

// Something the mission can refer to: a ship, a station, a prop, a mine.
@protocol MissionUnit <NSObject>
@property (nonatomic, readonly) NSString *missionKey;       // unique per unit, for per-unit progress
@property (nonatomic, readonly) NSString *missionName;      // shown in messages
@property (nonatomic, readonly) simd_float3 missionPosition;
@property (nonatomic, readonly) float missionRadius;
@property (nonatomic, readonly) BOOL missionAlive;          // alive and still in the level
@property (nonatomic, readonly) BOOL missionGone;           // left safely (departed, collected): not a loss
@property (nonatomic, readonly) float missionHullFraction;  // 0..1; 1 when it has no hull to speak of
@property (nonatomic, readonly) BOOL missionAttacked;       // hostile damage since it arrived (hull, shield or part)
@property (nonatomic, readonly) BOOL missionScanned;        // identified by a scan (missionMarkScanned:)
@property (nonatomic, readonly) BOOL missionDisabled;       // helpless but alive: a capital with every engine dead
// Destroyable parts of a kind ("Turret", "Engine", "Shield", "Core", …).
- (NSUInteger)missionPartsOfKind:(NSString *)kind alive:(BOOL)aliveOnly;
@end

// What the runtime asks of the game's world. Names in the level refer to an
// entity id, a group, a wave id or a pilot's callsign.
@protocol MissionWorld <NSObject>
- (NSArray<id<MissionUnit>> *)missionUnitsNamed:(NSString *)name;
- (NSArray<id<MissionUnit>> *)missionPlayers;               // players' ships, alive or not
- (BOOL)missionNav:(NSString *)nav position:(simd_float3 *)position;
- (NSArray<NSString *> *)missionNavs;

// Actions.
- (void)missionSpawn:(NSString *)name;                       // a held entity, wave or group
- (void)missionReinforce:(NSString *)wave;                   // the wave arrives again (its reinforcements)
- (void)missionSetTeam:(NSString *)team ofUnits:(NSArray<id<MissionUnit>> *)units;
- (void)missionDepart:(id<MissionUnit>)unit;                 // leaves safely (jumps out, or docks with its mothership)
- (void)missionCollect:(id<MissionUnit>)unit;                // taken aboard
- (void)missionMarkScanned:(id<MissionUnit>)unit;
- (void)missionDestroy:(id<MissionUnit>)unit;

// To the players. Texts may carry catalog tokens (MissionText); the client
// expands them in the player's language.
- (void)missionRadio:(NSString *)text from:(NSString *)from;
- (void)missionBanner:(NSString *)text alert:(BOOL)alert;
- (void)missionStatus:(NSString *)status forPlayer:(id<MissionUnit>)player;
- (void)missionObjectives:(NSArray<NSString *> *)lines states:(NSString *)states summary:(NSString *)summary;
- (void)missionCurrentNav:(NSString *)nav;                   // the nav the HUD points at, or nil
- (void)missionEnded:(BOOL)success results:(NSArray<NSString *> *)results;
- (void)missionLog:(NSString *)line;
@end

// A catalog token for text the client localises: "{#key}" or, with
// arguments, "{#key␟arg␟arg}" (U+001F between parts). The key's catalog
// string takes %@ arguments in order. Tokens may sit inside other text.
static inline NSString *MissionText(NSString *key, NSArray<NSString *> *args) {
    NSMutableString *s = [NSMutableString stringWithFormat:@"{#%@", key];
    for (NSString *a in args) [s appendFormat:@"\x1f%@", a];
    [s appendString:@"}"];
    return s;
}

// MARK: - MissionObjective

typedef NS_ENUM(NSInteger, MissionObjectiveState) {
    MissionObjectiveHidden,     // waiting for its "after" objectives or for its targets to arrive
    MissionObjectiveActive,
    MissionObjectiveComplete,
    MissionObjectiveFailed,
};

@class MissionObjective;

// What an objective sees of the running mission.
@protocol MissionContext <NSObject>
@property (nonatomic, readonly) id<MissionWorld> world;
@property (nonatomic, readonly) double time;                 // mission seconds
- (NSArray<id<MissionUnit>> *)unitsNamed:(NSArray<NSString *> *)names;
- (NSArray<id<MissionUnit>> *)livePlayersNear:(simd_float3)point range:(float)range;
- (simd_float3)navPosition:(NSString *)nav;
// More units by this name are still to come (a wave's reinforcements), so
// the ones there now being dead does not mean they are all destroyed.
- (BOOL)expecting:(NSString *)name;
- (void)objective:(MissionObjective *)o becomes:(MissionObjectiveState)state;
// The first active objective that wants the HUD's nav marker gets it.
- (void)pointAtNav:(NSString *)nav;
@end

// One objective of a level. The level entry:
//   { "id": "protect", "type": "protect", "targets": ["relay"], "text": "Keep bombers off Relay K-7",
//     "after": ["intercept"], "optional": false, … type-specific fields … }
// "targets" name units (entity ids, groups, waves); "navs" name navs. An
// objective stays hidden until every "after" objective is complete and every
// target has spawned.
//
// Types are classes registered by name. The engine registers every built-in
// type; a game may register a type only it can use (and move it here when a
// second game needs it).
@interface MissionObjective : NSObject

+ (void)registerType:(NSString *)type class:(Class)cls;
+ (Class)classForType:(NSString *)type;
+ (NSArray<NSString *> *)registeredTypes;
// Problems with a level entry of this type (missing or malformed fields).
+ (NSArray<NSString *> *)problemsWithDefinition:(NSDictionary *)definition;
// Ongoing objectives (protect) hold for the whole mission: they never block
// success and are marked complete when the mission succeeds.
+ (BOOL)ongoing;

+ (instancetype)objectiveWith:(const LevelObjective *)objective;

@property (nonatomic, readonly) NSDictionary *definition;   // the level entry, for type-specific fields
@property (nonatomic, readonly) NSString *identifier, *type, *text;
@property (nonatomic, readonly) NSArray<NSString *> *targets, *navs, *after;
@property (nonatomic, readonly) BOOL optional;
@property (nonatomic) MissionObjectiveState state;
@property (nonatomic) double activatedAt;
@property (nonatomic, copy) NSString *progress;     // short text after the objective, may hold tokens

// Called every frame while active.
- (void)updateIn:(id<MissionContext>)context dt:(float)dt;

// Helpers for subclasses.
- (float)number:(NSString *)key fallback:(float)fallback;

@end

// MARK: - MissionEvents

// Scripted events: a level's "events" list.
//
//   "events": [
//     { "when": { "time": 2 },                       "do": [ { "radio": { "from": "Relay K-7", "text": "…" } } ] },
//     { "when": { "spawned": "b2" },                 "do": [ { "radio": { … } } ] },
//     { "when": { "objective": "shields" },          "do": [ { "spawn": "w3" }, { "set_team": { "barge": "friend" } } ] },
//     { "when": { "any": [ { "objective": "x" }, { "destroyed": "wing-2" } ] },
//                                                    "do": [ { "destroy": "wing-2" }, { "radio": { … } } ] }
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
//   destroyed: name          everything by that name has arrived and is gone (dead, not departed),
//                            with no reinforcements still to come
//   attacked: name | [names]  some unit by each name has taken hostile damage since it arrived
//                            (hull, shield or part hits, from players, AI, turrets, torpedoes, mines)
//   scanned: name | [names]  every unit by each name that has arrived has been scanned
//   disabled: name | [names] every unit by each name that has arrived is disabled (MissionUnit
//                            missionDisabled: a capital's engines are all dead; fighters not yet)
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
// Problems with one "when" object, reported as "<where>: …".
+ (NSArray<NSString *> *)problemsWithCondition:(id)when at:(NSString *)where;

- (instancetype)initWithEvents:(NSArray<NSDictionary *> *)events;
// Fires every event whose condition now holds.
- (void)updateIn:(id<MissionEventContext>)context;

// Evaluates one "when" object (for objectives or games that want the same vocabulary).
+ (BOOL)condition:(NSDictionary *)when holdsIn:(id<MissionEventContext>)context;

@end

MissionObjectiveState MissionObjectiveStateNamed(NSString *name);

// MARK: - MissionArrivals

// Units that come and go on their own: a level's entities and waves with an
// "arrival", "departure" or "reinforcements" (LevelCue, LevelWave). Their
// conditions use the scripted events' vocabulary; the world spawns them
// (missionSpawn:, missionReinforce:) and sends them off (missionDepart:).
//
// A wave with a mothership arrives only while the mothership is alive, and
// its reinforcements stop when the mothership is lost. A departure also ends
// a wave's reinforcements.
@interface MissionArrivals : NSObject
+ (NSArray<NSString *> *)problemsWithLevel:(const LevelDef *)level;
- (instancetype)initWithLevel:(const LevelDef *)level;
// One frame, after the scripted events.
- (void)updateIn:(id<MissionEventContext>)context;
- (BOOL)expecting:(NSString *)name;
@end

// MARK: - MissionRunner

// Runs one level's objectives, events and rules against a MissionWorld.
//
// It reads the level's objectives, events, arrivals and rules (LevelDef).
// Spawning the level's units is the game's job; it tells the runner what has
// arrived with -noteSpawned: (entity ids, groups, wave ids, and "start").
//
// Rules: see LevelRules in Shared.h.
@interface MissionRunner : NSObject <MissionEventContext>

// Problems with a level against the registered types, triggers and actions;
// empty when the runtime can run it.
+ (NSArray<NSString *> *)problemsWithLevel:(const LevelDef *)level;

- (instancetype)initWithLevel:(const LevelDef *)level world:(id<MissionWorld>)world;

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
