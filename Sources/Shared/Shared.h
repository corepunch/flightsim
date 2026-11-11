#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <simd/simd.h>
#include <math.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

// MARK: - FileSystem

#ifdef __OBJC__

// Quake's search path for this engine. The bundle's resources hold the
// engine's own files (fonts, shaders, strings, UI theme) at the top level and
// one folder per game under Games/<name>/. A lookup tries the game folder
// first, then the top level, so a game ships only what it adds or overrides:
//
//   FSURL(@"Data/Ships", @"executioner", @"json")
//     → Games/<game>/Data/Ships/executioner.json, else Data/Ships/executioner.json
//
// A game may build on another, as a Quake mod builds on baseq2: its
// Games/<name>/game.json names a "base", searched after the game's own folder
// and before the top level. A game with no module of its own runs its base's.
//
//   game.json  { "title": "…", "base": "<game>" }
//
// The game is fs_game. The engine sets it at boot; the game module, which has
// its own copy of this file, sets it from the cvar in its init. Until then it
// is the bundle's FSDefaultGame Info.plist key, else the first folder in Games/.
// Thread-safe.

void FSSetGame(NSString *name);
NSString *FSGame(void);
// Every game folder in the bundle, sorted.
NSArray<NSString *> *FSGames(void);
// Games/<name>/game.json, or an empty dictionary.
NSDictionary *FSGameManifest(NSString *name);
// The game, then its base, then the base's base: the folders searched, in order.
NSArray<NSString *> *FSGameChain(void);

// The first match on the search path, or nil.
NSURL *FSURL(NSString *subdirectory, NSString *name, NSString *extension);
// Every file with `extension` in `subdirectory` on the search path. A game
// file hides a top-level file of the same name. Sorted by name.
NSArray<NSURL *> *FSURLs(NSString *subdirectory, NSString *extension);
// Every file with `extension` in `subdirectory`, top level first, then the
// game's: for catalogs a game extends rather than replaces.
NSArray<NSURL *> *FSURLsLayered(NSString *subdirectory, NSString *extension);
// The JSON object in a file, or nil (logged when the file exists but does not parse).
id FSJSON(NSURL *url);

#endif // __OBJC__

// MARK: - Protocol

// Everything the engine (server, client, renderer) and the game module agree
// on: limits, the per-tick entity and player state the server sends to
// clients, the user command clients send back, temp-entity events and the
// configstring layout. Plain C so the game module can stay behind a C ABI.
//
// This is a flight engine's vocabulary: ships with a flight model, hull and
// shield, a target, a nav marker, a primary weapon with a capacitor and a
// secondary weapon with rounds. What the ships are, who the teams are, what
// the secondary weapon is called and what the game counts on top of that
// come from the game, through ship definitions, configstrings and the game
// stats range.

// Version 6 distinguishes campaign results from competitive LAN matches.
// Older front ends would record a dogfight as a campaign mission completion.
// Version 7 adds pickups (EntityPickup), which older clients cannot draw.
// Version 9 carries the final LAN scoreboard and identifies the receiving pilot.
#define PROTOCOL_VERSION 9

#define TICK_RATE 30
#define TICK_DT (1.0f / TICK_RATE)

#define MAX_CLIENTS 8
#define MAX_PACKET_ENTITIES 512
#define MAX_EVENTS 256          // temp entities per snapshot
#define MAX_PARTS 64            // subsystems per capital model (deadParts is a 64-bit mask)
#define MAX_TEAMS 8

typedef enum { SubsystemTurret, SubsystemEngine, SubsystemShield, SubsystemCore } SubsystemKind;

#pragma mark - Teams

// Teams are numbers; the game says how they stand to each other through
// CS_TEAMS: MAX_TEAMS rows of MAX_TEAMS digits, row a column b being the
// relation of team a to team b (0 neutral, 1 friendly, 2 hostile).
typedef enum { RelationNeutral, RelationFriendly, RelationHostile } TeamRelation;

static inline TeamRelation TeamRelationIn(const char *csTeams, int a, int b) {
    if (!csTeams || a < 0 || b < 0 || a >= MAX_TEAMS || b >= MAX_TEAMS) return RelationNeutral;
    for (int i = 0; i < a * MAX_TEAMS + b; i++) if (!csTeams[i]) return RelationNeutral;
    char c = csTeams[a * MAX_TEAMS + b];
    return c == '2' ? RelationHostile : (c == '1' ? RelationFriendly : RelationNeutral);
}

#pragma mark - Configstrings

// Indexed strings the server keeps in sync on every client. Models and
// strings are registered by the game (gi.modelIndex / gi.stringIndex);
// index 0 of each range means "none".
#define CS_LEVEL 0              // the running level's name
#define CS_SKY 1                // sky seed, decimal
#define CS_GAME 2               // "<game> <data version>", for the client to check its data
#define CS_TEAMS 3              // team relations, see TeamRelationIn
#define CS_SECONDARY_NAME 4     // the secondary weapon's name for readouts ("TORPEDO")
#define CS_SECONDARY_SHORT 5    // and a short form for small buttons ("TORP")
#define CS_MODE 6               // "campaign" or "deathmatch"
#define CS_LAN_RULES 7           // serialized LAN match settings
#define CS_MODELS 16            // "ship:<definition>", "cap:<Asset>:<style>", "proj:<name>" or "pickup:<name>"
#define MAX_MODELS 256
#define CS_STRINGS (CS_MODELS + MAX_MODELS)   // names, class names
#define MAX_STRINGS 512
#define CS_NAVS (CS_STRINGS + MAX_STRINGS)    // "name|x|y|z"
#define MAX_NAVS 32
#define MAX_CONFIGSTRINGS (CS_NAVS + MAX_NAVS)

#pragma mark - Entities

typedef enum {
    EntityFighter = 1,      // flies a ship definition
    EntityCapital,          // capital ships, stations and props (EF_PROP)
    EntityAsteroid,
    EntityBuoy,
    EntityProjectile,       // a guided round in flight
    EntityPickup,           // collected by flying through it; model "pickup:<name>"
} EntityKind;

enum {
    EF_BOOST      = 1 << 0,     // fighter: boost firing
    EF_DEAD       = 1 << 1,     // capital breaking up: drawn, not targeted
    EF_SHIELDED   = 1 << 2,     // capital: shield generators up
    EF_PROP       = 1 << 3,     // small thing that dies in one blast
    EF_MINE       = 1 << 4,     // prop that is a danger to fly near
    EF_ATTACKING  = 1 << 5,     // AI fighter on an attack run at `target`
    EF_SCANNED    = 1 << 6,     // cargo manifest identified
    EF_DISABLED   = 1 << 7,     // fighter: systems down by ion fire; adrift, not firing
};

// One visible thing, as of the end of a server tick.
typedef struct {
    uint16_t number;            // stable for the entity's life, never 0
    uint8_t kind;               // EntityKind
    uint8_t team;
    uint16_t model;             // configstring index relative to CS_MODELS
    uint16_t name;              // relative to CS_STRINGS: label / callsign
    uint16_t cargo;             // manifest in CS_STRINGS; only sent after scanning
    uint16_t className;         // relative to CS_STRINGS
    uint16_t target;            // entity this one is attacking (EF_ATTACKING)
    uint32_t flags;             // EF_*
    simd_float3 origin, velocity;
    simd_quatf orientation;
    float scale;
    float throttle;             // fighters: drives the exhaust
    float hull, shield;         // 0..1
    float stealthRange;         // > 0: only on sensors within this range
    uint64_t deadParts;         // capital subsystems destroyed, bit per part
} EntityState;

#pragma mark - Player

// What the flight model needs; shared by the game and client prediction.
typedef struct {
    simd_float3 origin, velocity;
    simd_float3 angularVelocity;    // local: pitch, -yaw, -roll (rad/s about X,Y,Z)
    simd_quatf orientation;
    float throttle;
    float boostEnergy;              // 0..1
    uint8_t boosting;
    uint8_t boostDepleted;          // locked out until 15% recharged
} ShipMoveState;

// The flight model's knobs, from the ship definition. Sent with the player
// state so prediction runs on the same numbers as the server.
typedef struct {
    float maxSpeed;                 // m/s at full throttle
    float turnRate;                 // multiplier on the three rates
    float pitchRate, yawRate, rollRate;   // rad/s at full stick
    float agility;                  // how fast the rates chase the stick (1/s)
    float grip;                     // how fast velocity follows the nose (1/s)
    float boostSpeed;               // extra speed while boosting, as a fraction of maxSpeed
    float boostGrip;                // grip while boosting
    float boostTurn;                // turn rate multiplier while boosting
    float boostDrain, boostRecharge;    // boost energy per second
    float gravity, stallSpeed;       // 0 gravity: space; otherwise lift falls below stallSpeed
} ShipParams;

// Engine stats come first; a game counts whatever else it likes from STAT_GAME.
enum {
    STAT_KILLS,
    STAT_DEATHS,
    STAT_TARGET,                // selected entity number, 0 none
    STAT_AIM_PART,              // aimed subsystem of the target, part index + 1
    STAT_NAV,                   // current nav, index + 1 (CS_NAVS)
    STAT_WEAPON_ENERGY,         // primary weapon capacitor, 0..1000
    STAT_SECONDARY,             // secondary weapon rounds left
    STAT_SECONDARY_CAPACITY,    // rounds carried at launch
    STAT_GAME,
    MAX_STATS = 16,
};

typedef struct {
    ShipMoveState move;
    ShipParams params;
    uint16_t entity;            // own ship's entity number
    uint16_t model;             // own ship's model, relative to CS_MODELS
    uint8_t team;
    uint8_t alive;
    uint8_t disabled;           // systems down: the server flies the ship, commands are ignored
    float hull, shield;
    float missionTime;
    int16_t stats[MAX_STATS];
    uint32_t commandTime;       // ms of user commands the server has run
    uint32_t lastCommand;       // sequence of the last command run
} PlayerState;

#pragma mark - User commands

enum {
    BUTTON_FIRE  = 1 << 0,
    BUTTON_BOOST = 1 << 1,
};

enum {
    IMPULSE_NONE,
    IMPULSE_TARGET,             // cycle target
    IMPULSE_SECONDARY,          // launch the secondary weapon
};

typedef struct {
    uint32_t sequence;
    uint8_t msec;               // duration this command covers
    uint8_t buttons;
    uint8_t impulse;
    float pitch, yaw, roll;     // -1..1
    float throttle;             // 0..1
} UserCmd;

#pragma mark - Events (temp entities)

typedef enum {
    EV_BOLT = 1,        // id, pos, vel, team, flags EVF_ION, scale = flight time in seconds; entity = the player who fired, 0 for AI
    EV_IMPACT,          // id (bolt, 0 none), pos, team, flags EVF_SHIELDED
    EV_MUZZLE,          // entity, pos = gun in ship space, team
    EV_DAMAGE,          // entity hit, pos = direction toward hit in ship space (0 if unknown), flags EVF_SHIELDED, scale = camera shake
    EV_EXPLOSION,       // pos, vel, scale, model (hull material), radius = shake falloff
    EV_JUMP,            // pos, scale
} EventType;

enum {
    EVF_SHIELDED = 1,
    EVF_ION      = 2,       // EV_BOLT: an ion bolt
};

typedef struct {
    uint8_t type;
    uint8_t team;
    uint8_t flags;
    uint16_t entity;
    uint16_t id;
    uint16_t model;
    simd_float3 pos, vel;
    float scale;
    float radius;
} GameEvent;

#pragma mark - Reliable server commands

typedef enum {
    SVC_RADIO = 1,      // a = text, b = from
    SVC_BANNER,         // a = text, b = "red" or ""
    SVC_OBJECTIVES,     // a = lines joined by \n, b = state digits (0 active, 1 done, 2 failed, 3 optional), c = summary
    SVC_STATUS,         // a = status line under the boresight ("" clears)
    SVC_LEVEL_END,      // a = "1" success / "0", b = result lines joined by \n
    SVC_GAME,           // a, b, c = whatever the game's presentation hook understands
    SVC_MATCH_END,      // a = encoded LANMatchResult for this pilot
} ServerCommandType;

// MARK: - Assets

#ifdef __OBJC__

// Static tables both sides read: ship definitions and capital assets. C
// functions, not classes, so the engine and the game module can each link a
// copy without clashing.

#pragma mark - Ship definitions

// A flyable ship, from Data/Ships/<name>.json. Positions are in ship space
// (forward is -Z, metres): guns are the muzzles and nozzles the exhaust
// outlets, each on the mesh itself (Tools/validate_ships.py checks they are;
// it also prints a mesh's forward-most points when a gun needs placing). The
// game registers its model as
// "ship:<name>"; the client dresses entities with that model from the same
// definition. Example:
//
//   { "displayName": "Wasp", "mesh": "Spitfire", "texture": "Spitfire_Red", "radius": 5,
//     "guns": [[-1.2, -0.2, -3.5], [1.2, -0.2, -3.5]],
//     "gun": { "speed": 900, "life": 1.6, "energy": 0.035, "recharge": 0.22, "interval": 0.11,
//              "damage": 0.12, "capitalDamage": 0.12, "assist": 3 },     // assist: aim-assist cone, degrees
//     "aiGun": { "interval": 0.22, "damage": 0.07 },            // overrides for AI-flown ships
//     "nozzles": [[-4.5, 0.135, 2.2, 0.6], ...], "exhaustColor": [1, 0.38, 0.18],
//     "params": { "maxSpeed": 140, "turnRate": 0.8, ... },      // ShipParams, see Protocol above
//     "ai": { "maxSpeed": 140, "turnRate": 0.8, "speedSpread": 8 },
//     "hull": 1, "shield": 1, "shieldRegen": 0.06,              // 0 shield: none at all
//     "systems": 1,                                             // what ion fire drains once the shield is gone
//     "secondary": { "name": "MISSILE", "short": "MSL", "projectile": "missile", "rounds": 4,
//                    "range": 2500, "launchSpeed": 120, "acceleration": 260, "maxSpeed": 420,
//                    "turn": 3, "life": 9, "damage": 1.2, "capitalDamage": 4, "fuse": 10 } }
//
// Damage, hull, shield and systems share one unit: 1 is a standard fighter's hull.
//
// An ion gun ("gun": { "ion": true }, and likewise "aiGun", which starts as a
// copy of "gun") does not harm hulls. Its "damage" drains a fighter's shield
// ION_SHIELD_DRAIN times as fast as ordinary fire would, then the ship's
// systems one for one; at zero systems the fighter is disabled. Against
// capitals only the shield generators and engines take it.

#define SHIP_MAX_GUNS 4
#define SHIP_MAX_NOZZLES 8
#define SHIP_NAME_LENGTH 48

typedef struct {
    float speed;            // projectile m/s
    float life;             // projectile flight time, seconds
    float energy;           // capacitor per shot, 0..1
    float recharge;         // capacitor per second
    float interval;         // seconds between shots
    float damage;           // to fighters, in hull units (ion: in systems units)
    float capitalDamage;    // to capital subsystems and hulls
    float assist;           // aim-assist cone, degrees; 0 fires straight along the nose
    bool ion;               // drains shields and systems instead of hull
} ShipGun;

// Shield units an ion hit removes per unit of ion damage.
#define ION_SHIELD_DRAIN 2.0f

// The guided round a ship launches at its target. The name, short name and
// projectile fall back to the game's rules.json "secondary" when empty.
typedef struct {
    char name[SHIP_NAME_LENGTH];            // "TORPEDO", for readouts
    char shortName[SHIP_NAME_LENGTH];       // "TORP", for small buttons
    char projectile[SHIP_NAME_LENGTH];      // Data/Projectiles/<projectile>.json
    int rounds;                             // carried when the level sets no loadout
    float range;                            // farthest launch at the target, metres
    float launchSpeed;                      // m/s added to the ship's velocity at launch
    float acceleration, maxSpeed;           // m/s² and m/s
    float turn;                             // how hard it steers onto the lead point (1/s)
    float life;                             // seconds before it burns out
    float damage, capitalDamage;            // to fighters; to capital hulls and subsystems
    float fuse;                             // goes off this close to a fighter, metres
} ShipSecondary;

typedef struct {
    char name[SHIP_NAME_LENGTH];            // "wasp"
    char displayName[SHIP_NAME_LENGTH];     // "Wasp"
    char mesh[SHIP_NAME_LENGTH];            // Resources/Models/<mesh>.scn (OBJ space, +Z nose)
    char texture[SHIP_NAME_LENGTH];         // Resources/Models/<texture>.png
    simd_float4 propeller;                  // ship-local hub xyz and blade radius; w 0: none
    simd_float3 cockpitEye;                 // pilot camera, ship-local metres
    float radius;
    int gunCount;
    simd_float3 guns[SHIP_MAX_GUNS];
    ShipGun gun;                            // as flown by a player
    ShipGun aiGun;                          // as flown by the AI
    int nozzleCount;
    simd_float4 nozzles[SHIP_MAX_NOZZLES];  // xyz position, w size
    simd_float3 exhaustColor;
    ShipParams params;                      // as flown by a player
    ShipParams aiParams;                    // as flown by the AI
    float aiSpeedSpread;                    // AI: extra max speed, per ship in a wave
    float hull;                             // hull units; more than 0
    float shield;                           // hull units it absorbs first; 0: unshielded
    float shieldRegen;                      // shield units per second
    float systems;                          // ion damage it takes, after the shield, to be disabled; more than 0
    ShipSecondary secondary;
} ShipDef;

// NULL if there is no such definition. The result lives for the process.
const ShipDef *ShipDefNamed(NSString *name);
NSArray<NSString *> *ShipDefNames(void);                // every definition in the bundle, sorted
NSString *ShipModelName(NSString *name);               // "ship:<name>"
const ShipDef *ShipDefForModel(NSString *model);       // "ship:<name>" -> definition, else NULL

#pragma mark - Capital definitions

// A capital ship, station, prop or rock, from Resources/Capitals/<Asset>.json:
//   { "className": "Fleet Carrier", "hp": 120, "style": "concord",
//     "invulnerable": false, "prop": false, "mine": false, "asteroid": false }
// The mesh is Resources/Models/Capital/<Asset>.scn; `style` names the hull
// material set in Resources/Styles/<style>.json. The model configstring is
// "cap:<Asset>:<style>".
typedef struct {
    char name[SHIP_NAME_LENGTH];
    char className[SHIP_NAME_LENGTH];
    char style[SHIP_NAME_LENGTH];
    float hp;
    bool invulnerable;          // never takes damage
    bool prop;                  // small thing that dies in one blast
    bool mine;                  // prop that goes off near a ship
    bool asteroid;              // rock, excluded from ship targeting
} CapitalDef;

const CapitalDef *CapitalDefNamed(NSString *asset);     // NULL if there is no such definition
NSArray<NSString *> *CapitalDefNames(void);
NSString *CapitalModelName(NSString *asset, NSString *style);      // "cap:Carrier:concord"; nil style = the definition's

#pragma mark - Projectile definitions

// A guided round's look, from Resources/Projectiles/<name>.json:
//   { "glow": "flare_01", "tint": [3.0, 1.6, 0.6], "size": 7 }
// The model configstring is "proj:<name>".
typedef struct {
    char name[SHIP_NAME_LENGTH];
    char glow[SHIP_NAME_LENGTH];    // Resources/Particles/<glow>.png, drawn additively, facing the camera
    simd_float3 tint;               // Emissive tint of the glow
    float size;                     // metres
} ProjectileDef;

const ProjectileDef *ProjectileDefNamed(NSString *name);
NSString *ProjectileModelName(NSString *name);             // "proj:<name>"
const ProjectileDef *ProjectileDefForModel(NSString *model);

#pragma mark - Pickup definitions

// Something a pilot collects by flying through it, from Data/Pickups/<name>.json.
// It hands over what the pilot lacks, then waits "respawn" seconds before it
// shows again; one that would add nothing stays where it is.
//   { "asset": "TorpedoPack", "style": "pickup-torpedo", "radius": 16, "respawn": 30,
//     "torpedoes": 2, "repair": 0,                       // rounds; fraction of the ship's full hull
//     "message": "{#game.pickup.torpedoes}",             // what the collector is told; tokens expand on the client
//     "spin": 60, "glow": "flare_01", "tint": [1.6, 0.9, 0.35], "size": 32 }
// The mesh is Models/Capital/<asset> in the hull style <style>, spun "spin"
// degrees a second about its up axis inside a camera-facing glow, both
// pulsing about once a second. The model
// configstring is "pickup:<name>".
typedef struct {
    char name[SHIP_NAME_LENGTH];
    char asset[SHIP_NAME_LENGTH];
    char style[SHIP_NAME_LENGTH];
    char glow[SHIP_NAME_LENGTH];        // Resources/Particles/<glow>.png
    char message[SHIP_NAME_LENGTH];     // radio text, usually a catalog token; empty: nothing is said
    simd_float3 tint;                   // Emissive tint of the glow
    float size;                         // glow, metres
    float spin;                         // degrees per second
    float radius;                       // collected within this of a ship's edge, metres
    float respawn;                      // seconds hidden after it is collected
    int torpedoes;                      // secondary rounds it carries
    float repair;                       // hull it restores, as a fraction of the ship's full hull
} PickupDef;

const PickupDef *PickupDefNamed(NSString *name);            // NULL if there is no such definition
NSArray<NSString *> *PickupDefNames(void);
NSString *PickupModelName(NSString *name);                  // "pickup:<name>"
const PickupDef *PickupDefForModel(NSString *model);

// What a pilot carries against what the ship holds, for PickupApply.
typedef struct {
    int torpedoes, torpedoCapacity;
    float hull, maxHull;
} PilotStores;

// Tops the stores up from the pickup, never past what the ship holds.
// false, and the stores untouched, when it would add nothing.
bool PickupApply(const PickupDef *pickup, PilotStores *stores);

#pragma mark - JSON readers

// Typed reads from parsed JSON. A value of the wrong type reads as missing,
// so a contract's parser states each field's type and its default once.
static inline NSString *JSONString(id json, NSString *key) {
    id v = [json isKindOfClass:NSDictionary.class] ? json[key] : nil;
    return [v isKindOfClass:NSString.class] ? v : nil;
}
static inline NSNumber *JSONNumber(id json, NSString *key) {
    id v = [json isKindOfClass:NSDictionary.class] ? json[key] : nil;
    return [v isKindOfClass:NSNumber.class] ? v : nil;
}
static inline float JSONFloat(id json, NSString *key, float fallback) {
    NSNumber *n = JSONNumber(json, key);
    return n ? n.floatValue : fallback;
}
static inline int JSONInt(id json, NSString *key, int fallback) {
    NSNumber *n = JSONNumber(json, key);
    return n ? n.intValue : fallback;
}
static inline bool JSONBool(id json, NSString *key, bool fallback) {
    NSNumber *n = JSONNumber(json, key);
    return n ? n.boolValue : fallback;
}
static inline NSDictionary *JSONObject(id json, NSString *key) {
    id v = [json isKindOfClass:NSDictionary.class] ? json[key] : nil;
    return [v isKindOfClass:NSDictionary.class] ? v : nil;
}
static inline NSArray *JSONArray(id json, NSString *key) {
    id v = [json isKindOfClass:NSDictionary.class] ? json[key] : nil;
    return [v isKindOfClass:NSArray.class] ? v : nil;
}
// A list of names: the strings of an array, or a single string as a list of
// one; empty when the key is missing.
static inline NSArray<NSString *> *JSONStrings(id json, NSString *key) {
    NSString *single = JSONString(json, key);
    if (single) return @[single];
    NSMutableArray *strings = [NSMutableArray array];
    for (id v in JSONArray(json, key)) if ([v isKindOfClass:NSString.class]) [strings addObject:v];
    return strings;
}
static inline simd_float3 Vec3(NSArray *a) {
    if (![a isKindOfClass:NSArray.class] || a.count < 3) return simd_make_float3(0, 0, 0);
    return simd_make_float3([a[0] floatValue], [a[1] floatValue], [a[2] floatValue]);
}
static inline simd_float3 JSONVec3(id json, NSString *key, simd_float3 fallback) {
    NSArray *a = JSONArray(json, key);
    return a.count >= 3 ? Vec3(a) : fallback;
}

#pragma mark - Levels

// Levels/<name>.json in the game folder, read once into typed structs: what
// the game module builds, the mission runtime runs and the briefing map draws.
// C structs rather than classes because the engine and each game module link
// their own copy of this file. Cached levels live for the process.
//
//   { "name": "09-mine-sweep", "title": "Mine Sweep", "seed": 9,
//     "player":   { "pos": [x, y, z], "facing": [x, y, z], "ship": "<ship>" },
//     "loadout":  { "torpedoes": 2 },
//     "navs":     [ { "id": "n1", "name": "Nav 1", "pos": [x, y, z] } ],
//     "entities": [ LevelEntity ], "waves": [ LevelWave ], "fields": [ LevelField ],
//     "objectives": [ LevelObjective ], "events": [ … ], "rules": { LevelRules },
//     "pickups": [ LevelPickup ],
//     "timeLimit": 600, "onTimeLimit": "failure" | "success" }

typedef struct {
    NSString *identifier, *name;
    simd_float3 pos;
} LevelNav;

// When a unit arrives or leaves on its own: a condition in the scripted
// events' vocabulary (MissionEvents: time, destroyed, objective, nav, …),
// then a delay. The mission runtime schedules it.
//   { "when": { "destroyed": "escorts" }, "delay": 8 }
typedef struct {
    NSDictionary *when;                 // nil: not scheduled
    float delay;                        // seconds after the condition first holds
} LevelCue;

// A capital ship, station or prop.
//   { "id", "asset", "style", "team", "name", "group", "cargo", "pos", "facing",
//     "path": [[x, y, z], …], "speed", "loop", "spin", "stealth", "hold",
//     "arrival": LevelCue, "departure": LevelCue,
//     "invulnerable", "noHullDamage", "hull", "hullFraction" }
typedef struct {
    NSString *identifier, *asset, *style, *team, *name, *group, *cargo;
    simd_float3 pos, facing;            // facing defaults to forward (-Z)
    simd_float3 *path;                  // waypoints it flies, pathCount of them
    int pathCount;
    float speed, spin;
    float stealth;                      // > 0: only on sensors within this range
    float hull;                         // 0: the asset's
    float hullFraction;                 // of the full hull at the start, 1 by default
    LevelCue arrival, departure;        // an arrival implies hold; departure: jumps out
    int8_t invulnerable;                // -1: as the asset says
    bool loop, hold, noHullDamage;      // hold: arrives when an event or its arrival spawns it
} LevelEntity;

// How well a wave's pilots fly and shoot. Default is the game's own mix.
typedef enum { LevelSkillDefault, LevelSkillRookie, LevelSkillRegular, LevelSkillVeteran, LevelSkillAce } LevelSkill;

// How a wave is arranged when it arrives. Scatter places each ship at random
// within "spread"; the others place ships in slots behind and beside the lead.
typedef enum {
    LevelFormationScatter, LevelFormationVic, LevelFormationFingerFour, LevelFormationLineAbreast,
    LevelFormationLineAstern, LevelFormationEchelonLeft, LevelFormationEchelonRight, LevelFormationDiamond,
} LevelFormation;

// A flight of AI fighters.
//
// "order" is a verb, with a target after a colon where it takes one. A target
// names a unit (entity id, group, wave id or callsign) unless it is a nav.
//   attack                 hostile fighters nearest first, then capitals (the default);
//                          disabled fighters are spared
//   attack-fighters        only hostile fighters; with none left it loiters
//   attack-capitals        only hostile capitals (props and rocks never)
//   strike:<unit>          the named units first, even disabled ones; then as attack
//   escort:<unit>          fights within 1.6 km of the unit, forms up on it when it is quiet
//   disable:<unit>         shoots the named units only until they are disabled (a fighter's
//                          systems down, a capital's engines dead), then stops and loiters
//                          about them; a ship fires what it carries, so ion guns are the
//                          way to do it without destroying the target
//   evade                  never fires; breaks away from the nearest hostile within 1.5 km,
//                          otherwise loiters about where it arrived
//   ignore                 never fires and reacts to nothing; loiters about where it arrived
//   patrol:<nav>[,<nav>…]  flies the navs in a loop, engaging hostiles that come within
//                          1.2 km, then resumes
//   board:<unit>           never fires; flies to the nearest of the named units and waits near
//                          it until it is disabled. A boarder that then holds within 60 m of a
//                          fighter, or within a capital's radius + 40 m, for "dockSeconds"
//                          captures it: the target changes to the boarder's team, stays
//                          disabled, and the mission sees it captured. If a boarder that is
//                          docking is destroyed the timer starts over for the others.
// An unknown verb, a missing or misplaced target, or a target that names no
// unit (or nav, for patrol) is a level problem.
//
//   { "id", "ship", "team", "name", "callsigns": [], "count", "pos", "spread",
//     "order": "attack" | "escort:<id>" | …, "hold",
//     "arrival": LevelCue,                        // implies hold
//     "departure": LevelCue,                      // survivors leave: back aboard the mothership, else jump out
//     "mothership": "<entity id>",                // launches from it (no arrival while it is dead)
//     "dockSeconds": 10,                          // how long a boarder holds alongside its target to capture it
//     "reinforcements": { "count": 2, "delay": 10 },   // the flight comes back this often after it is wiped out
//     "skill": "rookie" | "regular" | "veteran" | "ace",
//     "formation": "vic" | "finger-four" | "line-abreast" | "line-astern" | "echelon-left" | "echelon-right" | "diamond" }
typedef struct {
    NSString *identifier, *ship, *team, *name;
    NSArray<NSString *> *callsigns;
    NSString *order, *orderTarget;      // "escort:layer" reads as escort / layer
    NSString *mothership;               // nil: arrives at pos
    simd_float3 pos;
    int count;                          // at least 1
    float spread;                       // metres, 80 by default
    LevelCue arrival, departure;
    int reinforcements;                 // further flights after the first, 0 by default
    float reinforcementDelay;           // seconds after the flight is wiped out
    float dockSeconds;                  // boarding: seconds alongside the target to capture it, 10 by default
    LevelSkill skill;
    LevelFormation formation;
    bool hold;                          // arrives when an event or its arrival spawns it
} LevelWave;

typedef enum { LevelFieldAsteroids, LevelFieldMines, LevelFieldBuoys, LevelFieldUnknown } LevelFieldKind;

// Things scattered at once.
//   { "type": "asteroids", "center", "radius", "count", "small", "seed" }
//   { "type": "mines", "group", "center", "size": [w, h, d], "count", "seed" }
//   { "type": "buoys", "navs": [ids] }
typedef struct {
    LevelFieldKind kind;
    NSString *type, *group;
    NSArray<NSString *> *navs;
    simd_float3 center, size;
    float radius;
    int count, seed;
    bool small;
} LevelField;

// What every objective has; `definition` keeps the type's own fields (see
// MissionObjective in Sources/Mission).
//   { "id", "type", "text", "targets": [], "navs": [], "after": [], "optional", "hidden", … }
// "targets" name entity ids, groups, wave ids or one pilot's callsign, so a wave's
// special craft is its own target: { "type": "destroy", "targets": ["Viper"] }.
// destroy and protect take "percent" (1-100, 100 by default): destroy completes
// once that share of the targets (reinforcements still to come included) is
// destroyed; protect fails once more than (100 - percent)% of them are lost.
typedef struct {
    NSString *identifier, *type, *text;
    NSArray<NSString *> *targets, *navs, *after;
    bool optional, hidden;
    NSDictionary *definition;
} LevelObjective;

// A pickup's spot: Data/Pickups/<type>.json, collected and respawned there.
//   { "type": "torpedoes", "pos": [x, y, z] }
typedef struct {
    NSString *type;
    simd_float3 pos;
} LevelPickup;

// How the mission ends. All true by default.
typedef struct {
    bool succeedWhenObjectivesDone;     // every required objective complete (ongoing ones excepted)
    bool failOnObjectiveFailed;         // a required objective failed
    bool failWhenPlayersDown;           // every player's ship is down (destroyed or disabled)
    bool deathmatch;                    // independent pilots, scoring and automatic respawns
    int fragLimit;                     // kills to win a deathmatch
    float matchSeconds, respawnSeconds;
} LevelRules;

// Host-owned match choices, copied at creation and at each rematch.
typedef struct {
    NSString *arena, *ship;
    int fragLimit, maxPilots;
    float matchSeconds, respawnSeconds;
} LANMatchSettings;
LANMatchSettings LANMatchSettingsDefault(void);
LANMatchSettings LANMatchSettingsNormalize(LANMatchSettings settings);
NSString *LANMatchSettingsEncode(LANMatchSettings settings);
BOOL LANMatchSettingsDecode(NSString *text, LANMatchSettings *settings);

// Final standings in server order. Equal kills and deaths share a rank.
typedef struct { int kills, deaths; } LANPilotScore;
typedef struct {
    NSArray<NSString *> *pilots;
    LANPilotScore scores[MAX_CLIENTS];
    NSUInteger localIndex;
} LANMatchResult;
NSString *LANMatchResultEncode(LANMatchResult result);
BOOL LANMatchResultDecode(NSString *text, LANMatchResult *result);
NSUInteger LANMatchRank(LANMatchResult result, NSUInteger index);
BOOL LANMatchHasWinner(LANMatchResult result);
enum { LANMatchMaxPilotPoints = 300 };
NSUInteger LANMatchPilotPoints(LANMatchResult result);

typedef struct {
    NSArray<NSString *> *pilots;
    LANMatchSettings settings;
} LANLobbyInfo;
NSString *LANLobbyEncode(LANLobbyInfo lobby);
BOOL LANLobbyDecode(NSString *text, LANLobbyInfo *lobby);

// Optional scenery; absent for a space level. Either an authored landscape model with a
// sky panorama, or the engine's procedural terrain and sky ("terrain": true), with haze.
typedef struct {
    NSString *model, *sky;
    bool terrain;
    simd_float3 fogColor;
    float fogStart, fogEnd;
} LevelEnvironment;

typedef struct {
    NSString *name, *title;
    LevelEnvironment environment;
    int seed;
    simd_float3 playerPos, playerFacing;
    NSString *playerShip;               // nil: the game's default
    int torpedoes;                      // loadout; -1 when the level gives none
    LevelNav *navs;             int navCount;
    LevelEntity *entities;      int entityCount;
    LevelWave *waves;           int waveCount;
    LevelField *fields;         int fieldCount;
    LevelObjective *objectives; int objectiveCount;
    LevelPickup *pickups;       int pickupCount;
    // Scripted events stay JSON: their triggers and actions are a registered
    // vocabulary (MissionEvents), checked by MissionRunner's problems.
    NSArray<NSDictionary *> *events;
    LevelRules rules;
    float timeLimit;                    // mission seconds; 0: none
    bool timeLimitSucceeds;             // the mission ends in success at the limit, else in failure
    NSArray<NSString *> *problems;      // fields of the wrong shape; empty for a clean level
} LevelDef;

// NULL when there is no such level.
const LevelDef *LevelNamed(NSString *name);
// Every level in the game folder, sorted by name.
NSArray<NSString *> *LevelNames(void);
// A level from JSON already in hand (tools, checks). Not cached: release it.
LevelDef *LevelCreate(NSDictionary *json);
void LevelRelease(LevelDef *level);

// Lookups by id; NULL when the level has none.
const LevelNav *LevelNavNamed(const LevelDef *level, NSString *identifier);
const LevelEntity *LevelEntityNamed(const LevelDef *level, NSString *identifier);
const LevelWave *LevelWaveNamed(const LevelDef *level, NSString *identifier);

// Exact ship JSON bytes, sorted by filename; changes require matching client data.
NSString *ShipDataIdentity(void);

#endif // __OBJC__

// MARK: - CvarFlags

// Console variable flags, shared by the engine's Cvar class and the game
// module (which reaches cvars through GameImport). After Quake 2's CVAR_*.

enum {
    CVAR_ARCHIVE = 1 << 0,      // saved to the user's defaults and restored at launch
    CVAR_LATCH   = 1 << 1,      // a new value waits until the next level spawn
    CVAR_CHEAT   = 1 << 2,      // can only be changed while sv_cheats is 1
    CVAR_NOSET   = 1 << 3,      // can only be set from the command line (+set)
};

// MARK: - GameAPI

// The boundary between the engine and the game module, in the style of
// Quake 2's game_import_t / game_export_t. The engine hands the game a table
// of services (GameImport); the game hands back its entry points
// (GameExport). Only plain C crosses it, so the game can live in its own
// dylib and be rebuilt or swapped without touching the engine.

#define GAME_API_VERSION 6

typedef struct {
    float radius;
    int numParts;
    struct { uint8_t kind; simd_float3 center; } parts[MAX_PARTS];   // SubsystemKind, model space
} GameModelInfo;

typedef struct {
    simd_float3 point;          // world
    int part;                   // subsystem index, -1 for the hull
} GameTrace;

typedef struct {
    int apiVersion;

    void (*print)(const char *text);

    // Registers a model / string configstring and returns its index (relative
    // to CS_MODELS / CS_STRINGS). Registering a model also loads its
    // collision mesh on the server. Index 0 is "none".
    int (*modelIndex)(const char *name);
    int (*stringIndex)(const char *text);
    void (*configString)(int index, const char *value);
    // Radius and subsystems of a registered model (capitals only).
    const GameModelInfo *(*modelInfo)(int model);

    // Segment test against a model placed in the world. Parts set in
    // deadParts are ignored. Returns true on a hit.
    bool (*trace)(int model, simd_float3 origin, simd_quatf orientation, float scale, uint64_t deadParts,
                  simd_float3 from, simd_float3 to, GameTrace *out);

    // Temp entity, sent to every client with the next snapshot.
    void (*event)(const GameEvent *event);
    // Reliable command to one client, or every client with -1.
    void (*command)(int client, int type, const char *a, const char *b, const char *c);

    // Console variables (engine-owned; see Sources/Common/Common.h). Register
    // in init with CVAR_* flags, then read at use: values can change at any
    // time. cvarString's result is valid until the cvar changes.
    void (*cvarRegister)(const char *name, const char *value, int flags, const char *help);
    const char *(*cvarString)(const char *name);
    float (*cvarValue)(const char *name);
    void (*cvarSet)(const char *name, const char *value);
} GameImport;

typedef struct {
    int apiVersion;

    void (*init)(void);
    void (*shutdown)(void);

    // Clears the world and builds a level by name (Levels/<name>.json in the
    // game folder). May be slow (collision meshes); the server calls it off
    // the render thread.
    void (*spawnLevel)(const char *name);

    bool (*clientConnect)(int client, const char *name);
    void (*clientBegin)(int client);        // spawns the player's ship
    void (*clientDisconnect)(int client);
    // Runs one user command: flight, guns, torpedoes, targeting. Called as
    // commands arrive, between ticks.
    void (*clientThink)(int client, const UserCmd *cmd);

    void (*runFrame)(void);                 // one tick of TICK_DT

    // State after the last tick. The pointers stay valid until the next call.
    int (*entities)(const EntityState **out);
    const PlayerState *(*playerState)(int client);
} GameExport;

typedef GameExport *(*GetGameAPIFunc)(const GameImport *import);
// The one symbol the game dylib exports.
__attribute__((visibility("default"))) GameExport *GetGameAPI(const GameImport *import);

// MARK: - SharedMath

static inline float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

// Orientation whose -Z points along forward.
static inline simd_quatf LookRotation(simd_float3 forward, simd_float3 up) {
    simd_float3 f = simd_normalize(forward);
    if (fabsf(simd_dot(f, up)) > 0.98f) up = simd_make_float3(1, 0, 0);
    simd_float3 r = simd_normalize(simd_cross(f, up));
    simd_float3 u = simd_cross(r, f);
    return simd_quaternion(simd_matrix(r, u, -f));
}

static inline simd_float3 QuatForward(simd_quatf q) { return simd_act(q, simd_make_float3(0, 0, -1)); }
static inline simd_float3 QuatUp(simd_quatf q) { return simd_act(q, simd_make_float3(0, 1, 0)); }
static inline simd_float3 QuatRight(simd_quatf q) { return simd_act(q, simd_make_float3(1, 0, 0)); }

// Segment vs sphere: does p0->p1 pass within r of c?
static inline bool SegmentHits(simd_float3 p0, simd_float3 p1, simd_float3 c, float r) {
    simd_float3 d = p1 - p0;
    float len2 = simd_length_squared(d);
    float t = len2 > 0 ? clampf(simd_dot(c - p0, d) / len2, 0, 1) : 0;
    return simd_distance_squared(p0 + d * t, c) < r * r;
}

// MARK: - Aim assist

// Bends a gun's shot onto a target the pilot is nearly lined up with, so a
// near miss hits. The shot goes to the target's lead point (where a bolt
// leaving the muzzle at boltSpeed, plus the shooter's velocity, meets the
// target) when that point is within `cone` radians of `forward` and within
// `range`; otherwise it goes along `forward`. The server aims every player
// shot with it and the client predicts its own shots with the same call.
simd_float3 AimAssist(simd_float3 forward, simd_float3 muzzle, simd_float3 shooterVelocity,
                      simd_float3 target, simd_float3 targetVelocity, float boltSpeed, float range, float cone);

// MARK: - ShipMove

// The fighter flight model, as a pure function of (state, input, dt). The game
// runs it for every ship; the client runs the same code to predict its own
// ship between snapshots, so both must stay bit-for-bit in step.

typedef struct {
    float pitch, yaw, roll;     // -1..1
    float throttle;             // 0..1
    bool boost;
} ShipInput;

void ShipMove(ShipMoveState *s, const ShipParams *p, ShipInput in, float dt);
void ShipMoveReset(ShipMoveState *s, simd_float3 origin, simd_quatf orientation);
// A ship with no power: it keeps its heading and spin, and its speed bleeds off slowly.
void ShipDrift(ShipMoveState *s, float dt);

static inline ShipInput ShipInputFromCmd(const UserCmd *c) {
    return (ShipInput){ c->pitch, c->yaw, c->roll, c->throttle, (c->buttons & BUTTON_BOOST) != 0 };
}
