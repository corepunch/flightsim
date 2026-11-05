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

static NSArray<NSString *> *DefinitionNames(NSString *directory);

NSArray<NSString *> *ShipDefNames(void) {
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = DefinitionNames(@"Ships"); });
    return names;
}

NSString *ShipModelName(NSString *name) { return [@"ship:" stringByAppendingString:name]; }

const ShipDef *ShipDefForModel(NSString *model) {
    return [model hasPrefix:@"ship:"] ? ShipDefNamed([model substringFromIndex:5]) : NULL;
}

#pragma mark - Definition files

// Resources/<directory>/<name>.json as a dictionary, or nil.
static NSDictionary *DefinitionFile(NSString *directory, NSString *name) {
    if (!name.length) return nil;
    NSURL *url = [NSBundle.mainBundle URLForResource:name withExtension:@"json" subdirectory:directory];
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    NSError *error = nil;
    NSDictionary *d = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (url && ![d isKindOfClass:NSDictionary.class]) NSLog(@"%@: cannot read %@.json: %@", directory, name, error.localizedDescription);
    return [d isKindOfClass:NSDictionary.class] ? d : nil;
}

static NSArray<NSString *> *DefinitionNames(NSString *directory) {
    NSMutableArray *found = [NSMutableArray array];
    for (NSURL *url in [NSBundle.mainBundle URLsForResourcesWithExtension:@"json" subdirectory:directory])
        [found addObject:url.lastPathComponent.stringByDeletingPathExtension];
    return [found sortedArrayUsingSelector:@selector(compare:)];
}

// One cache per definition kind; a pointer, once handed out, lives for the process.
static void *CachedDefinition(NSMutableDictionary<NSString *, NSValue *> *cache, NSString *name, void *(^load)(void)) {
    if (!name.length) return NULL;
    @synchronized (cache) {
        NSValue *v = cache[name];
        if (!v) {
            v = [NSValue valueWithPointer:load()];
            cache[name] = v;
        }
        return v.pointerValue;
    }
}

#pragma mark - Capital definitions

static NSMutableDictionary<NSString *, NSValue *> *gCapitalDefs;

const CapitalDef *CapitalDefNamed(NSString *asset) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gCapitalDefs = [NSMutableDictionary dictionary]; });
    return CachedDefinition(gCapitalDefs, asset, ^void *{
        NSDictionary *d = DefinitionFile(@"Capitals", asset);
        if (!d) return NULL;
        CapitalDef *c = calloc(1, sizeof *c);
        CopyName(c->name, asset);
        CopyName(c->className, d[@"className"] ?: asset);
        CopyName(c->style, d[@"style"] ?: @"default");
        c->hp = Number(d, @"hp", 10);
        c->invulnerable = [d[@"invulnerable"] boolValue];
        c->prop = [d[@"prop"] boolValue];
        c->mine = [d[@"mine"] boolValue];
        return c;
    });
}

NSArray<NSString *> *CapitalDefNames(void) {
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = DefinitionNames(@"Capitals"); });
    return names;
}

NSString *CapitalModelName(NSString *asset, NSString *style) {
    const CapitalDef *def = CapitalDefNamed(asset);
    return [NSString stringWithFormat:@"cap:%@:%@", asset, style ?: (def ? @(def->style) : @"default")];
}

#pragma mark - Projectile definitions

static NSMutableDictionary<NSString *, NSValue *> *gProjectileDefs;

const ProjectileDef *ProjectileDefNamed(NSString *name) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gProjectileDefs = [NSMutableDictionary dictionary]; });
    return CachedDefinition(gProjectileDefs, name, ^void *{
        NSDictionary *d = DefinitionFile(@"Projectiles", name);
        if (!d) return NULL;
        ProjectileDef *p = calloc(1, sizeof *p);
        CopyName(p->name, name);
        CopyName(p->glow, d[@"glow"] ?: @"flare_01");
        NSArray *tint = d[@"tint"];
        p->tint = tint.count >= 3 ? Vec3(tint) : simd_make_float3(2, 2, 2);
        p->size = Number(d, @"size", 5);
        return p;
    });
}

NSString *ProjectileModelName(NSString *name) { return [@"proj:" stringByAppendingString:name]; }

const ProjectileDef *ProjectileDefForModel(NSString *model) {
    return [model hasPrefix:@"proj:"] ? ProjectileDefNamed([model substringFromIndex:5]) : NULL;
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

// Cache alongside the definitions: resources are immutable for a process.
#import <CommonCrypto/CommonDigest.h>
NSString *ShipDataIdentity(void) {
    static NSString *identity;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CC_SHA256_CTX ctx;
        CC_SHA256_Init(&ctx);
        for (NSString *name in ShipDefNames()) {
            NSURL *url = [NSBundle.mainBundle URLForResource:name withExtension:@"json" subdirectory:@"Ships"];
            NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
            if (!data) { identity = @"invalid ship data"; return; }
            NSData *label = [name dataUsingEncoding:NSUTF8StringEncoding];
            // Length delimiters prevent ambiguous concatenations.
            NSString *header = [NSString stringWithFormat:@"%lu:%@:%lu:",
                (unsigned long)label.length, name, (unsigned long)data.length];
            NSData *h = [header dataUsingEncoding:NSUTF8StringEncoding];
            CC_SHA256_Update(&ctx, h.bytes, (CC_LONG)h.length);
            CC_SHA256_Update(&ctx, data.bytes, (CC_LONG)data.length);
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(digest, &ctx);
        NSMutableString *hex = [NSMutableString string];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
        identity = [@"spacefight 1 ships-sha256:" stringByAppendingString:hex];
    });
    return identity;
}
