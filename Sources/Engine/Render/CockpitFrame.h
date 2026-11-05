#import <Foundation/Foundation.h>
#import <simd/simd.h>
#include "Protocol.h"

// What the client tells the cockpit and the HUD instruments each frame. No
// renderer types: the target hologram and preview are opaque handles from
// -[Refresh hologramForModel:] and -[Refresh previewForModel:].
#define COCKPIT_MAX_CONTACTS 24

typedef struct CockpitContact {
    simd_float3 local;          // position in player ship space (-Z forward), metres
    simd_quatf orientation;     // relative to the player ship
    float hull, shield, systems; // systems: surviving fitted subsystems; -1 when not fitted
    TeamRelation relation;      // to the player's team
    BOOL capital;               // a big ship or station (bigger scanner blip)
    BOOL shielded;              // capital with its shield generators up
    BOOL attacking;             // in an attack run on the player
    __unsafe_unretained id hologram;          // Refresh hologram handle for the cockpit MFD
    __unsafe_unretained id preview;           // Refresh preview handle for the target readout
    float holoScale;            // metres of hologram per metre of ship
    __unsafe_unretained NSString *name, *className, *cargo, *component;
} CockpitContact;

typedef struct CockpitFrame {
    float throttle, speed, maxSpeed, boostEnergy, hull, shield;
    float weaponEnergy, weaponShotEnergy;   // primary weapon capacitor and what one shot costs, 0..1
    float damageFlash;          // 0..1, decays after a hit
    BOOL boosting, firing, alive;
    float pitch, yaw, roll;     // stick deflection, -1..1
    int kills, deaths;
    double time;
    simd_float3 sun;            // toward the sun, player ship space (lights the target preview)
    int target;                 // index into the contacts, -1 for none
    float closingSpeed;         // towards the target, m/s
    BOOL lock;                  // lead marker under the boresight
    BOOL six;                   // someone attacking from behind
    float nearest;              // distance to the closest hostile, metres
    int secondary;              // secondary weapon rounds left
    __unsafe_unretained NSString *secondaryName;  // short name from the game ("TORP")
    __unsafe_unretained NSString *objective;     // current objective, for the status display
} CockpitFrame;
