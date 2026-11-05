// Static tables both sides read: ship definitions and capital assets. C
// functions, not classes, so the engine and the game module can each link a
// copy without clashing.
#import <Foundation/Foundation.h>
#include "Protocol.h"

#pragma mark - Ship definitions

// A flyable ship, from Resources/Ships/<name>.json. Positions are in ship
// space (forward is -Z, metres). The game registers its model as
// "ship:<name>"; the client dresses entities with that model from the same
// definition. Example:
//
//   { "displayName": "Wasp", "mesh": "Spitfire", "texture": "Spitfire_Red", "radius": 5,
//     "guns": [[-1.2, -0.2, -3.5], [1.2, -0.2, -3.5]],
//     "gun": { "speed": 900, "life": 1.6, "energy": 0.035, "recharge": 0.22, "interval": 0.11,
//              "damage": 0.12, "capitalDamage": 0.12 },
//     "aiGun": { "interval": 0.22, "damage": 0.07 },            // overrides for AI-flown ships
//     "nozzles": [[-4.5, 0.135, 2.2, 0.6], ...], "exhaustColor": [1, 0.38, 0.18],
//     "params": { "maxSpeed": 140, "turnRate": 0.8, ... },      // ShipParams, see Protocol.h
//     "ai": { "maxSpeed": 140, "turnRate": 0.8, "speedSpread": 8 } }

#define SHIP_MAX_GUNS 4
#define SHIP_MAX_NOZZLES 8
#define SHIP_NAME_LENGTH 48

typedef struct {
    float speed;            // projectile m/s
    float life;             // projectile flight time, seconds
    float energy;           // capacitor per shot, 0..1
    float recharge;         // capacitor per second
    float interval;         // seconds between shots
    float damage;           // to fighters, fraction of hull
    float capitalDamage;    // to capital subsystems and hulls
} ShipGun;

typedef struct {
    char name[SHIP_NAME_LENGTH];            // "wasp"
    char displayName[SHIP_NAME_LENGTH];     // "Wasp"
    char mesh[SHIP_NAME_LENGTH];            // Resources/Models/<mesh>.scn (OBJ space, +Z nose)
    char texture[SHIP_NAME_LENGTH];         // Resources/Models/<texture>.png
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
    float hologramScale;
} ShipDef;

// NULL if there is no such definition. The result lives for the process.
const ShipDef *ShipDefNamed(NSString *name);
NSArray<NSString *> *ShipDefNames(void);                // every definition in the bundle, sorted
NSString *ShipModelName(NSString *name);               // "ship:<name>"
const ShipDef *ShipDefForModel(NSString *model);       // "ship:<name>" -> definition, else NULL

#pragma mark - Capital definitions

// A capital ship, station, prop or rock, from Resources/Capitals/<Asset>.json:
//   { "className": "Fleet Carrier", "hp": 120, "style": "concord",
//     "invulnerable": false, "prop": false, "mine": false }
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
    simd_float3 tint;               // HDR tint of the glow
    float size;                     // metres
} ProjectileDef;

const ProjectileDef *ProjectileDefNamed(NSString *name);
NSString *ProjectileModelName(NSString *name);             // "proj:<name>"
const ProjectileDef *ProjectileDefForModel(NSString *model);

#pragma mark - Campaign

// Resources/Missions/missions.json, in campaign order.
NSArray<NSDictionary *> *CampaignMissions(void);
NSDictionary *CampaignMission(NSUInteger index);
// The whole file: campaign name, story, storyDefaults and missions.
NSDictionary *CampaignData(void);

static inline simd_float3 Vec3(NSArray *a) {
    return a.count >= 3 ? simd_make_float3([a[0] floatValue], [a[1] floatValue], [a[2] floatValue]) : simd_make_float3(0, 0, 0);
}

// Exact ship JSON bytes, sorted by filename; changes require matching client data.
NSString *ShipDataIdentity(void);
