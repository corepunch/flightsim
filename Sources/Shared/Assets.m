#import "Assets.h"

// OBJ space (+Z nose) -> ship space (-Z nose): rotate 180 degrees about Y.
static simd_float3 ToShip(simd_float3 p) { return simd_make_float3(-p.x, p.y, -p.z); }

FighterSpec FighterSpecFor(ShipClass c) {
    FighterSpec s;
    switch (c) {
        case ShipClassExecutioner:
            s = (FighterSpec){ "Executioner", "Executioner", 5.0f, 2, { {4.38f, 0.1f, 2.5f}, {-4.38f, 0.1f, 2.5f} } };
            break;
        case ShipClassSpitfire:
            s = (FighterSpec){ "Spitfire", "Wasp", 5.0f, 2, { {1.2f, -0.2f, 3.5f}, {-1.2f, -0.2f, 3.5f} } };
            break;
        case ShipClassInsurgent:
        default:
            s = (FighterSpec){ "Insurgent", "Talon", 4.5f, 2, { {2.4f, -0.2f, 3.0f}, {-2.4f, -0.2f, 3.0f} } };
            break;
    }
    for (int i = 0; i < s.gunCount; i++) s.guns[i] = ToShip(s.guns[i]);
    return s;
}

int FighterClassForMesh(NSString *mesh) {
    for (int c = ShipClassExecutioner; c <= ShipClassInsurgent; c++)
        if ([mesh isEqualToString:@(FighterSpecFor((ShipClass)c).mesh)]) return c;
    return -1;
}

NSString *FighterModelName(ShipClass c) { return [@"ship:" stringByAppendingString:@(FighterSpecFor(c).mesh)]; }

NSString *CapitalModelName(NSString *asset, NSString *style) {
    return [NSString stringWithFormat:@"cap:%@:%@", asset, style ?: AssetInfo(asset)[@"style"] ?: @"concord"];
}

NSDictionary *AssetInfo(NSString *asset) {
    static NSDictionary *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        t = @{
            @"Carrier":        @{ @"hp": @120, @"class": @"Fleet Carrier", @"style": @"concord" },
            @"Frigate":        @{ @"hp": @30, @"class": @"Frigate", @"style": @"concord" },
            @"CommRelay":      @{ @"hp": @30, @"class": @"Comm Relay", @"style": @"concord" },
            @"RingStation":    @{ @"hp": @90, @"class": @"Orbital Station", @"style": @"concord" },
            @"ResearchVessel": @{ @"hp": @22, @"class": @"Survey Ship", @"style": @"concord" },
            @"JumpGate":       @{ @"hp": @1, @"class": @"Jump Gate", @"style": @"concord", @"invulnerable": @YES },
            @"NavBuoy":        @{ @"hp": @1, @"class": @"Nav Buoy", @"style": @"concord", @"prop": @YES },
            @"Freighter":      @{ @"hp": @25, @"class": @"Freighter", @"style": @"civil" },
            @"Tanker":         @{ @"hp": @22, @"class": @"Tanker", @"style": @"civil" },
            @"Liner":          @{ @"hp": @35, @"class": @"Liner", @"style": @"civil" },
            @"HospitalShip":   @{ @"hp": @28, @"class": @"Hospital Ship", @"style": @"medical" },
            @"FuelDepot":      @{ @"hp": @40, @"class": @"Fuel Depot", @"style": @"civil" },
            @"Container":      @{ @"hp": @1.2, @"class": @"Cargo Container", @"style": @"civil", @"prop": @YES },
            @"EscapePod":      @{ @"hp": @0.6, @"class": @"Escape Pod", @"style": @"civil", @"prop": @YES },
            @"Corvette":       @{ @"hp": @9, @"class": @"Corvette", @"style": @"skarn" },
            @"Destroyer":      @{ @"hp": @28, @"class": @"Destroyer", @"style": @"skarn" },
            @"Cruiser":        @{ @"hp": @45, @"class": @"Heavy Cruiser", @"style": @"skarn" },
            @"Dreadnought":    @{ @"hp": @80, @"class": @"Dreadnought", @"style": @"skarn" },
            @"Minelayer":      @{ @"hp": @7, @"class": @"Minelayer", @"style": @"skarn" },
            @"DefensePlatform":@{ @"hp": @14, @"class": @"Defence Platform", @"style": @"skarn" },
            @"Shipyard":       @{ @"hp": @50, @"class": @"Shipyard", @"style": @"skarn" },
            @"PrisonBarge":    @{ @"hp": @40, @"class": @"Prison Barge", @"style": @"skarn" },
            @"Prototype":      @{ @"hp": @3, @"class": @"Stealth Prototype", @"style": @"stealth" },
            @"Mine":           @{ @"hp": @0.15, @"class": @"Mine", @"style": @"skarn", @"prop": @YES, @"mine": @YES },
            @"CorsairBase":    @{ @"hp": @50, @"class": @"Corsair Base", @"style": @"corsair" },
            @"CorsairCutter":  @{ @"hp": @5, @"class": @"Corsair Cutter", @"style": @"corsair" },
            @"AsteroidA":      @{ @"hp": @1, @"class": @"Asteroid", @"style": @"rock", @"invulnerable": @YES },
            @"AsteroidB":      @{ @"hp": @1, @"class": @"Asteroid", @"style": @"rock", @"invulnerable": @YES },
            @"AsteroidC":      @{ @"hp": @1, @"class": @"Asteroid", @"style": @"rock", @"invulnerable": @YES },
        };
    });
    return t[asset];
}

NSArray<NSDictionary *> *CampaignMissions(void) {
    static NSArray *missions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [[NSBundle mainBundle] URLForResource:@"missions" withExtension:@"json" subdirectory:@"Missions"];
        NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
        NSError *err = nil;
        NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&err] : nil;
        if (!root) NSLog(@"Campaign: cannot load missions.json: %@", err);
        missions = root[@"missions"] ?: @[];
    });
    return missions;
}

NSDictionary *CampaignMission(NSUInteger i) {
    NSArray *all = CampaignMissions();
    return i < all.count ? all[i] : nil;
}
