#import "Assets.h"

#pragma mark - Ship definitions

static void CopyName(char *out, NSString *s) {
    strlcpy(out, s.UTF8String ?: "", SHIP_NAME_LENGTH);
}

static float Number(NSDictionary *d, NSString *key, float fallback) {
    NSNumber *n = d[key];
    return [n isKindOfClass:NSNumber.class] ? n.floatValue : fallback;
}

static ShipParams ParamsFrom(NSDictionary *d, ShipParams base) {
    ShipParams p = base;
    p.maxSpeed = Number(d, @"maxSpeed", p.maxSpeed);
    p.turnRate = Number(d, @"turnRate", p.turnRate);
    p.pitchRate = Number(d, @"pitchRate", p.pitchRate);
    p.yawRate = Number(d, @"yawRate", p.yawRate);
    p.rollRate = Number(d, @"rollRate", p.rollRate);
    p.agility = Number(d, @"agility", p.agility);
    p.grip = Number(d, @"grip", p.grip);
    p.boostSpeed = Number(d, @"boostSpeed", p.boostSpeed);
    p.boostGrip = Number(d, @"boostGrip", p.boostGrip);
    p.boostTurn = Number(d, @"boostTurn", p.boostTurn);
    p.boostDrain = Number(d, @"boostDrain", p.boostDrain);
    p.boostRecharge = Number(d, @"boostRecharge", p.boostRecharge);
    return p;
}

static ShipGun GunFrom(NSDictionary *d, ShipGun base) {
    ShipGun g = base;
    g.speed = Number(d, @"speed", g.speed);
    g.life = Number(d, @"life", g.life);
    g.energy = Number(d, @"energy", g.energy);
    g.recharge = Number(d, @"recharge", g.recharge);
    g.interval = Number(d, @"interval", g.interval);
    g.damage = Number(d, @"damage", g.damage);
    g.capitalDamage = Number(d, @"capitalDamage", g.capitalDamage);
    return g;
}

static ShipDef *LoadShipDef(NSString *name) {
    NSURL *url = [NSBundle.mainBundle URLForResource:name withExtension:@"json" subdirectory:@"Ships"];
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    NSError *error = nil;
    NSDictionary *d = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (![d isKindOfClass:NSDictionary.class]) {
        if (url) NSLog(@"Ships: cannot read %@.json: %@", name, error.localizedDescription);
        return NULL;
    }
    ShipDef *s = calloc(1, sizeof *s);
    CopyName(s->name, name);
    CopyName(s->displayName, d[@"displayName"] ?: name);
    CopyName(s->mesh, d[@"mesh"] ?: name);
    CopyName(s->texture, d[@"texture"] ?: d[@"mesh"] ?: name);
    s->radius = Number(d, @"radius", 5);
    for (NSArray *g in d[@"guns"]) {
        if (s->gunCount >= SHIP_MAX_GUNS) break;
        s->guns[s->gunCount++] = Vec3(g);
    }
    // Sensible defaults so a sparse definition still flies and shoots.
    ShipGun gun = { .speed = 900, .life = 1.6f, .energy = 0.035f, .recharge = 0.22f, .interval = 0.11f, .damage = 0.1f, .capitalDamage = 0.1f };
    s->gun = GunFrom(d[@"gun"], gun);
    s->aiGun = GunFrom(d[@"aiGun"], s->gun);
    for (NSArray *n in d[@"nozzles"]) {
        if (s->nozzleCount >= SHIP_MAX_NOZZLES) break;
        s->nozzles[s->nozzleCount++] = simd_make_float4(Vec3(n), n.count >= 4 ? [n[3] floatValue] : 0.5f);
    }
    NSArray *color = d[@"exhaustColor"];
    s->exhaustColor = color.count >= 3 ? Vec3(color) : simd_make_float3(1, 0.5f, 0.2f);
    ShipParams params = { .maxSpeed = 150, .turnRate = 1, .pitchRate = 1.45f, .yawRate = 0.85f, .rollRate = 2.6f, .agility = 5.5f,
                          .grip = 1.4f, .boostSpeed = 0.9f, .boostGrip = 2.2f, .boostTurn = 0.7f, .boostDrain = 0.28f, .boostRecharge = 0.12f };
    s->params = ParamsFrom(d[@"params"], params);
    s->aiParams = ParamsFrom(d[@"ai"], s->params);
    s->aiSpeedSpread = Number(d[@"ai"], @"speedSpread", 0);
    s->hologramScale = Number(d, @"hologramScale", 0.0075f);
    return s;
}

static NSMutableDictionary<NSString *, NSValue *> *gShipDefs;

const ShipDef *ShipDefNamed(NSString *name) {
    if (!name.length) return NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gShipDefs = [NSMutableDictionary dictionary]; });
    @synchronized (gShipDefs) {
        NSValue *v = gShipDefs[name];
        if (!v) {
            v = [NSValue valueWithPointer:LoadShipDef(name)];
            gShipDefs[name] = v;
        }
        return v.pointerValue;
    }
}

NSArray<NSString *> *ShipDefNames(void) {
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *found = [NSMutableArray array];
        for (NSURL *url in [NSBundle.mainBundle URLsForResourcesWithExtension:@"json" subdirectory:@"Ships"])
            [found addObject:url.lastPathComponent.stringByDeletingPathExtension];
        names = [found sortedArrayUsingSelector:@selector(compare:)];
    });
    return names;
}

NSString *ShipModelName(NSString *name) { return [@"ship:" stringByAppendingString:name]; }

const ShipDef *ShipDefForModel(NSString *model) {
    return [model hasPrefix:@"ship:"] ? ShipDefNamed([model substringFromIndex:5]) : NULL;
}

#pragma mark - Capital assets

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

#pragma mark - Campaign

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
