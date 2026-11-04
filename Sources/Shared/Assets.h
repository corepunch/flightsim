// Static tables both sides read: fighter classes (gameplay part; the visual
// part lives in ShipView) and capital assets. C functions, not classes, so
// the engine and the game module can each link a copy without clashing.
#import <Foundation/Foundation.h>
#include "Protocol.h"

typedef struct {
    const char *mesh;           // Resources/Models/<mesh>.obj, also the model name
    const char *displayName;    // "Wasp"
    float radius;
    int gunCount;
    simd_float3 guns[2];        // ship space (forward is -Z)
} FighterSpec;

FighterSpec FighterSpecFor(ShipClass c);
// -1 if `mesh` isn't a fighter.
int FighterClassForMesh(NSString *mesh);

// hp, class (display name), style (default hull style), invulnerable, prop, mine.
NSDictionary *AssetInfo(NSString *asset);

// Model configstrings.
NSString *FighterModelName(ShipClass c);                            // "ship:Spitfire"
NSString *CapitalModelName(NSString *asset, NSString *style);      // "cap:Carrier:concord"

// Resources/Missions/missions.json, in campaign order.
NSArray<NSDictionary *> *CampaignMissions(void);
NSDictionary *CampaignMission(NSUInteger index);

static inline simd_float3 Vec3(NSArray *a) {
    return a.count >= 3 ? simd_make_float3([a[0] floatValue], [a[1] floatValue], [a[2] floatValue]) : simd_make_float3(0, 0, 0);
}
