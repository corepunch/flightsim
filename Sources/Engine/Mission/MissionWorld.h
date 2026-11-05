// The mission runtime: an engine library linked into every game module (not
// into the engine binary, so its classes exist once per process). It runs a
// level's objectives, scripted events and win/lose rules from the level's
// JSON; the game supplies the world through MissionWorld and MissionUnit.
//
// A game never re-implements objectives or events. A type only one game can
// use may be registered by that game (see MissionObjective, MissionEvents);
// when a second game needs it, it moves into this folder.
#import <Foundation/Foundation.h>
#import <simd/simd.h>

// Something the mission can refer to: a ship, a station, a prop, a mine.
@protocol MissionUnit <NSObject>
@property (nonatomic, readonly) NSString *missionKey;       // unique per unit, for per-unit progress
@property (nonatomic, readonly) NSString *missionName;      // shown in messages
@property (nonatomic, readonly) simd_float3 missionPosition;
@property (nonatomic, readonly) float missionRadius;
@property (nonatomic, readonly) BOOL missionAlive;          // alive and still in the level
@property (nonatomic, readonly) BOOL missionGone;           // left safely (departed, collected): not a loss
@property (nonatomic, readonly) float missionHullFraction;  // 0..1; 1 when it has no hull to speak of
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
- (void)missionSetTeam:(NSString *)team ofUnits:(NSArray<id<MissionUnit>> *)units;
- (void)missionDepart:(id<MissionUnit>)unit;                 // leaves safely (jumps out)
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
