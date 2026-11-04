// Everything the engine (server, client, renderer) and the game module agree
// on: limits, the per-tick entity and player state the server sends to
// clients, the user command clients send back, temp-entity events and the
// configstring layout. Plain C so the game module can stay behind a C ABI.
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <simd/simd.h>

#define PROTOCOL_VERSION 1

#define TICK_RATE 30
#define TICK_DT (1.0f / TICK_RATE)

#define MAX_CLIENTS 8
#define MAX_PACKET_ENTITIES 512
#define MAX_EVENTS 256          // temp entities per snapshot
#define MAX_PARTS 64            // subsystems per capital model (deadParts is a 64-bit mask)

// Gameplay constants the client also needs (lead markers, bolt flight).
#define BOLT_SPEED 900.0f
#define TURRET_BOLT_SPEED 700.0f
#define BOLT_LIFE 1.6f

typedef enum { TeamFriend, TeamEnemy, TeamNeutral } Team;

static inline bool TeamsHostile(Team a, Team b) {
    return (a == TeamFriend && b == TeamEnemy) || (a == TeamEnemy && b == TeamFriend);
}

typedef enum { SubsystemTurret, SubsystemEngine, SubsystemShield, SubsystemCore } SubsystemKind;

typedef enum {
    ShipClassExecutioner,   // player
    ShipClassSpitfire,
    ShipClassInsurgent,
} ShipClass;

#pragma mark - Configstrings

// Indexed strings the server keeps in sync on every client. Models and
// strings are registered by the game (gi.modelIndex / gi.stringIndex);
// index 0 of each range means "none".
#define CS_MISSION 0            // campaign mission index, decimal
#define CS_SKY 1                // sky seed, decimal
#define CS_MODELS 16            // "ship:<Mesh>" or "cap:<Asset>:<style>"
#define MAX_MODELS 256
#define CS_STRINGS (CS_MODELS + MAX_MODELS)   // names, class names
#define MAX_STRINGS 512
#define CS_NAVS (CS_STRINGS + MAX_STRINGS)    // "name|x|y|z"
#define MAX_NAVS 32
#define MAX_CONFIGSTRINGS (CS_NAVS + MAX_NAVS)

#pragma mark - Entities

typedef enum {
    EntityFighter = 1,
    EntityCapital,          // capital ships, stations and props (EF_PROP)
    EntityAsteroid,
    EntityBuoy,
    EntityTorpedo,
} EntityKind;

enum {
    EF_BOOST      = 1 << 0,     // fighter: boost firing
    EF_DEAD       = 1 << 1,     // capital breaking up: drawn, not targeted
    EF_SHIELDED   = 1 << 2,     // capital: shield generators up
    EF_PROP       = 1 << 3,     // small thing that dies in one blast
    EF_MINE       = 1 << 4,
    EF_ATTACKING  = 1 << 5,     // AI fighter on an attack run at `target`
};

// One visible thing, as of the end of a server tick.
typedef struct {
    uint16_t number;            // stable for the entity's life, never 0
    uint8_t kind;               // EntityKind
    uint8_t team;
    uint16_t model;             // configstring index relative to CS_MODELS
    uint16_t name;              // relative to CS_STRINGS: label / callsign
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

typedef struct {
    float maxSpeed;
    float turnRate;
} ShipParams;

enum {
    STAT_TORPEDOES,
    STAT_KILLS,
    STAT_DEATHS,
    STAT_TARGET,                // selected entity number, 0 none
    STAT_AIM_PART,              // aimed subsystem of the target, part index + 1
    STAT_NAV,                   // current nav, index + 1 (CS_NAVS)
    MAX_STATS = 16,
};

typedef struct {
    ShipMoveState move;
    ShipParams params;
    uint16_t entity;            // own ship's entity number
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
    IMPULSE_TORPEDO,
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
    EV_BOLT = 1,        // id, pos, vel, team
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
    SVC_MISSION_END,    // a = "1" success / "0", b = result lines joined by \n
} ServerCommandType;
