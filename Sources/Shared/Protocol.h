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
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <simd/simd.h>

// Version 4 requires ship-data identity validation before beginning.
// Version 3 clients do not validate CS_GAME and must not join these servers.
#define PROTOCOL_VERSION 4

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
#define CS_MISSION 0            // campaign mission index, decimal
#define CS_SKY 1                // sky seed, decimal
#define CS_GAME 2               // "<game> <data version>", for the client to check its data
#define CS_TEAMS 3              // team relations, see TeamRelationIn
#define CS_SECONDARY_NAME 4     // the secondary weapon's name for readouts ("TORPEDO")
#define CS_SECONDARY_SHORT 5    // and a short form for small buttons ("TORP")
#define CS_MODELS 16            // "ship:<definition>" or "cap:<Asset>:<style>"
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
} EntityKind;

enum {
    EF_BOOST      = 1 << 0,     // fighter: boost firing
    EF_DEAD       = 1 << 1,     // capital breaking up: drawn, not targeted
    EF_SHIELDED   = 1 << 2,     // capital: shield generators up
    EF_PROP       = 1 << 3,     // small thing that dies in one blast
    EF_MINE       = 1 << 4,     // prop that is a danger to fly near
    EF_ATTACKING  = 1 << 5,     // AI fighter on an attack run at `target`
    EF_SCANNED    = 1 << 6,     // cargo manifest identified
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
    EV_BOLT = 1,        // id, pos, vel, team, scale = flight time in seconds; entity = the player who fired, 0 for AI
    EV_IMPACT,          // id (bolt, 0 none), pos, team, flags EVF_SHIELDED
    EV_MUZZLE,          // entity, pos = gun in ship space, team
    EV_DAMAGE,          // entity hit, flags EVF_SHIELDED, scale = camera shake if it is you
    EV_EXPLOSION,       // pos, vel, scale, model (hull material), radius = shake falloff
    EV_JUMP,            // pos, scale
} EventType;

enum { EVF_SHIELDED = 1 };

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
} ServerCommandType;
