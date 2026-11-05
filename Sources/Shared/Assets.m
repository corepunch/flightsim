#import "Shared.h"

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
    g.assist = Number(d, @"assist", g.assist);
    g.ion = JSONBool(d, @"ion", g.ion);
    return g;
}

static ShipSecondary SecondaryFrom(NSDictionary *d) {
    // The defaults are a proton-torpedo-like round, as every ship flew before
    // ships carried their own.
    ShipSecondary w = { .range = 2500, .launchSpeed = 120, .acceleration = 260, .maxSpeed = 420, .turn = 3,
                        .life = 9, .damage = 1.2f, .capitalDamage = 4, .fuse = 10 };
    if (![d isKindOfClass:NSDictionary.class]) return w;
    CopyName(w.name, JSONString(d, @"name"));
    CopyName(w.shortName, JSONString(d, @"short"));
    CopyName(w.projectile, JSONString(d, @"projectile"));
    w.rounds = MAX(0, JSONInt(d, @"rounds", 0));
    w.range = Number(d, @"range", w.range);
    w.launchSpeed = Number(d, @"launchSpeed", w.launchSpeed);
    w.acceleration = Number(d, @"acceleration", w.acceleration);
    w.maxSpeed = Number(d, @"maxSpeed", w.maxSpeed);
    w.turn = Number(d, @"turn", w.turn);
    w.life = Number(d, @"life", w.life);
    w.damage = Number(d, @"damage", w.damage);
    w.capitalDamage = Number(d, @"capitalDamage", w.capitalDamage);
    w.fuse = Number(d, @"fuse", w.fuse);
    return w;
}

static ShipDef *LoadShipDef(NSString *name) {
    NSURL *url = FSURL(@"Data/Ships", name, @"json");
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
    ShipGun gun = { .speed = 900, .life = 1.6f, .energy = 0.035f, .recharge = 0.22f, .interval = 0.11f, .damage = 0.1f, .capitalDamage = 0.1f, .assist = 3 };
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
    s->hull = fmaxf(Number(d, @"hull", 1), 0.01f);
    s->shield = fmaxf(Number(d, @"shield", 1), 0);
    s->shieldRegen = fmaxf(Number(d, @"shieldRegen", 0.06f), 0);
    s->systems = fmaxf(Number(d, @"systems", 1), 0.01f);
    s->secondary = SecondaryFrom(d[@"secondary"]);
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

// Data/<directory>/<name>.json on the search path as a dictionary, or nil.
static NSDictionary *DefinitionFile(NSString *directory, NSString *name) {
    if (!name.length) return nil;
    NSURL *url = FSURL([@"Data" stringByAppendingPathComponent:directory], name, @"json");
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    NSError *error = nil;
    NSDictionary *d = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (url && ![d isKindOfClass:NSDictionary.class]) NSLog(@"%@: cannot read %@.json: %@", directory, name, error.localizedDescription);
    return [d isKindOfClass:NSDictionary.class] ? d : nil;
}

static NSArray<NSString *> *DefinitionNames(NSString *directory) {
    NSMutableArray *found = [NSMutableArray array];
    for (NSURL *url in FSURLs([@"Data" stringByAppendingPathComponent:directory], @"json"))
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

#pragma mark - Levels

// Reads one array of objects into a calloc'd array of structs. Entries that
// are not objects are reported and skipped.
#define LEVEL_READ(json, key, type, out_, count_, problems, read)                              \
    do {                                                                                     \
        NSArray *items = JSONArray(json, key);                                               \
        if (json[key] && !items) [problems addObject:@"\"" key "\" is not a list"];          \
        out_ = (type *)calloc(MAX(1, items.count), sizeof(type));                            \
        count_ = 0;                                                                          \
        for (id item in items) {                                                             \
            if (![item isKindOfClass:NSDictionary.class]) {                                  \
                [problems addObject:@"\"" key "\" holds a non-object"];                      \
                continue;                                                                    \
            }                                                                                \
            read(item, &out_[count_++], problems);                                          \
        }                                                                                    \
    } while (0)

static void Require(id json, NSString *key, NSString *what, NSMutableArray *problems) {
    if (!JSONString(json, key).length) [problems addObject:[NSString stringWithFormat:@"%@ without \"%@\"", what, key]];
}

static const simd_float3 Forward = { 0, 0, -1 };

static void ReadNav(NSDictionary *j, LevelNav *n, NSMutableArray *problems) {
    Require(j, @"id", @"nav", problems);
    n->identifier = JSONString(j, @"id");
    n->name = JSONString(j, @"name") ?: n->identifier;
    n->pos = JSONVec3(j, @"pos", 0);
}

// A cue's condition is checked against the registered triggers by the
// mission runtime (MissionRunner's problems); here only its shape.
static LevelCue ReadCue(NSDictionary *j, NSString *key, NSString *what, NSMutableArray *problems) {
    id value = j[key];
    if (!value) return (LevelCue){0};
    NSDictionary *cue = JSONObject(j, key);
    NSDictionary *when = JSONObject(cue, @"when");
    if (!when.count) {
        [problems addObject:[NSString stringWithFormat:@"%@: \"%@\" needs a \"when\" object", what, key]];
        return (LevelCue){0};
    }
    return (LevelCue){ .when = when, .delay = fmaxf(0, JSONFloat(cue, @"delay", 0)) };
}

// An enum from its JSON name; a name not in the table is reported.
static int ReadName(NSDictionary *j, NSString *key, NSDictionary<NSString *, NSNumber *> *names, int fallback,
                    NSString *what, NSMutableArray *problems) {
    NSString *name = JSONString(j, key);
    if (!name) return fallback;
    if (names[name]) return names[name].intValue;
    [problems addObject:[NSString stringWithFormat:@"%@: unknown %@ \"%@\"", what, key, name]];
    return fallback;
}

static void ReadEntity(NSDictionary *j, LevelEntity *e, NSMutableArray *problems) {
    Require(j, @"asset", [NSString stringWithFormat:@"entity %@", JSONString(j, @"id") ?: @"?"], problems);
    e->identifier = JSONString(j, @"id");
    e->asset = JSONString(j, @"asset");
    e->style = JSONString(j, @"style");
    e->team = JSONString(j, @"team") ?: @"friend";
    e->name = JSONString(j, @"name");
    e->group = JSONString(j, @"group");
    e->cargo = JSONString(j, @"cargo");
    e->pos = JSONVec3(j, @"pos", 0);
    e->facing = simd_normalize(JSONVec3(j, @"facing", Forward));
    NSArray *path = JSONArray(j, @"path");
    e->path = (simd_float3 *)calloc(MAX(1, path.count), sizeof(simd_float3));
    for (id point in path) e->path[e->pathCount++] = Vec3(point);
    e->speed = JSONFloat(j, @"speed", 0);
    e->spin = JSONFloat(j, @"spin", 0);
    e->stealth = JSONFloat(j, @"stealth", 0);
    e->hull = JSONFloat(j, @"hull", 0);
    e->hullFraction = JSONFloat(j, @"hullFraction", 1);
    e->invulnerable = JSONNumber(j, @"invulnerable") ? JSONBool(j, @"invulnerable", false) : -1;
    e->loop = JSONBool(j, @"loop", false);
    NSString *what = [NSString stringWithFormat:@"entity %@", e->identifier ?: @"?"];
    e->arrival = ReadCue(j, @"arrival", what, problems);
    e->departure = ReadCue(j, @"departure", what, problems);
    e->hold = JSONBool(j, @"hold", false) || e->arrival.when;
    e->noHullDamage = JSONBool(j, @"noHullDamage", false);
}

static void ReadWave(NSDictionary *j, LevelWave *w, NSMutableArray *problems) {
    NSString *what = [NSString stringWithFormat:@"wave %@", JSONString(j, @"id") ?: @"?"];
    Require(j, @"id", what, problems);
    Require(j, @"ship", what, problems);
    w->identifier = JSONString(j, @"id");
    w->ship = JSONString(j, @"ship");
    w->team = JSONString(j, @"team") ?: @"friend";
    w->name = JSONString(j, @"name");
    w->callsigns = JSONStrings(j, @"callsigns");
    NSString *order = JSONString(j, @"order") ?: @"attack";
    NSRange colon = [order rangeOfString:@":"];
    w->order = colon.location == NSNotFound ? order : [order substringToIndex:colon.location];
    w->orderTarget = colon.location == NSNotFound ? nil : [order substringFromIndex:colon.location + 1];
    w->pos = JSONVec3(j, @"pos", 0);
    w->count = MAX(1, JSONInt(j, @"count", 1));
    w->spread = JSONFloat(j, @"spread", 80);
    w->mothership = JSONString(j, @"mothership");
    w->arrival = ReadCue(j, @"arrival", what, problems);
    w->departure = ReadCue(j, @"departure", what, problems);
    w->hold = JSONBool(j, @"hold", false) || w->arrival.when;
    NSDictionary *reinforcements = JSONObject(j, @"reinforcements");
    if (j[@"reinforcements"] && !reinforcements) [problems addObject:[what stringByAppendingString:@": \"reinforcements\" is not an object"]];
    w->reinforcements = MAX(0, JSONInt(reinforcements, @"count", 0));
    w->reinforcementDelay = fmaxf(0, JSONFloat(reinforcements, @"delay", 0));
    w->skill = (LevelSkill)ReadName(j, @"skill", @{
        @"rookie": @(LevelSkillRookie), @"regular": @(LevelSkillRegular),
        @"veteran": @(LevelSkillVeteran), @"ace": @(LevelSkillAce),
    }, LevelSkillDefault, what, problems);
    w->formation = (LevelFormation)ReadName(j, @"formation", @{
        @"scatter": @(LevelFormationScatter), @"vic": @(LevelFormationVic), @"finger-four": @(LevelFormationFingerFour),
        @"line-abreast": @(LevelFormationLineAbreast), @"line-astern": @(LevelFormationLineAstern),
        @"echelon-left": @(LevelFormationEchelonLeft), @"echelon-right": @(LevelFormationEchelonRight),
        @"diamond": @(LevelFormationDiamond),
    }, LevelFormationScatter, what, problems);
}

static void ReadField(NSDictionary *j, LevelField *f, NSMutableArray *problems) {
    f->type = JSONString(j, @"type") ?: @"";
    NSDictionary *kinds = @{ @"asteroids": @(LevelFieldAsteroids), @"mines": @(LevelFieldMines), @"buoys": @(LevelFieldBuoys) };
    NSNumber *kind = kinds[f->type];
    if (!kind) [problems addObject:[NSString stringWithFormat:@"field of unknown type \"%@\"", f->type]];
    f->kind = kind ? (LevelFieldKind)kind.intValue : LevelFieldUnknown;
    if (f->kind == LevelFieldMines) Require(j, @"group", @"minefield", problems);
    f->group = JSONString(j, @"group");
    f->navs = JSONStrings(j, @"navs");
    f->center = JSONVec3(j, @"center", 0);
    f->size = JSONVec3(j, @"size", 0);
    f->radius = JSONFloat(j, @"radius", 0);
    f->count = JSONInt(j, @"count", 0);
    f->seed = JSONInt(j, @"seed", 0);
    f->small = JSONBool(j, @"small", false);
}

static void ReadObjective(NSDictionary *j, LevelObjective *o, NSMutableArray *problems) {
    NSString *what = [NSString stringWithFormat:@"objective %@", JSONString(j, @"id") ?: @"?"];
    Require(j, @"id", what, problems);
    Require(j, @"type", what, problems);
    o->identifier = JSONString(j, @"id");
    o->type = JSONString(j, @"type");
    o->text = JSONString(j, @"text");
    o->targets = JSONStrings(j, @"targets");
    o->navs = JSONStrings(j, @"navs");
    o->after = JSONStrings(j, @"after");
    o->optional = JSONBool(j, @"optional", false);
    o->hidden = JSONBool(j, @"hidden", false);
    o->definition = j;
}

LevelDef *LevelCreate(NSDictionary *json) {
    if (![json isKindOfClass:NSDictionary.class]) return NULL;
    LevelDef *level = (LevelDef *)calloc(1, sizeof(LevelDef));
    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    level->name = JSONString(json, @"name") ?: @"";
    level->title = JSONString(json, @"title") ?: level->name;
    level->seed = JSONInt(json, @"seed", 0);
    NSDictionary *player = JSONObject(json, @"player");
    level->playerPos = JSONVec3(player, @"pos", 0);
    level->playerFacing = simd_normalize(JSONVec3(player, @"facing", Forward));
    level->playerShip = JSONString(player, @"ship");
    level->torpedoes = JSONInt(JSONObject(json, @"loadout"), @"torpedoes", -1);
    LEVEL_READ(json, @"navs", LevelNav, level->navs, level->navCount, problems, ReadNav);
    LEVEL_READ(json, @"entities", LevelEntity, level->entities, level->entityCount, problems, ReadEntity);
    LEVEL_READ(json, @"waves", LevelWave, level->waves, level->waveCount, problems, ReadWave);
    LEVEL_READ(json, @"fields", LevelField, level->fields, level->fieldCount, problems, ReadField);
    LEVEL_READ(json, @"objectives", LevelObjective, level->objectives, level->objectiveCount, problems, ReadObjective);
    for (int i = 0; i < level->waveCount; i++) {
        const LevelWave *w = &level->waves[i];
        if (w->mothership && !LevelEntityNamed(level, w->mothership))
            [problems addObject:[NSString stringWithFormat:@"wave %@: mothership \"%@\" is no entity", w->identifier, w->mothership]];
    }
    NSArray *events = JSONArray(json, @"events");
    if (json[@"events"] && !events) [problems addObject:@"\"events\" is not a list"];
    level->events = events ?: @[];
    NSDictionary *rules = JSONObject(json, @"rules");
    level->rules = (LevelRules){
        .succeedWhenObjectivesDone = JSONBool(rules, @"succeedWhenObjectivesDone", true),
        .failOnObjectiveFailed = JSONBool(rules, @"failOnObjectiveFailed", true),
        .failWhenPlayersDown = JSONBool(rules, @"failWhenPlayersDown", true),
    };
    level->problems = problems;
    return level;
}

// Assigning empty structs releases their objects before the memory goes.
#define LEVEL_FREE(items, count) do { for (int i = 0; i < (count); i++) (items)[i] = (typeof(*(items))){0}; free(items); } while (0)

void LevelRelease(LevelDef *level) {
    if (!level) return;
    for (int i = 0; i < level->entityCount; i++) free(level->entities[i].path);
    LEVEL_FREE(level->navs, level->navCount);
    LEVEL_FREE(level->entities, level->entityCount);
    LEVEL_FREE(level->waves, level->waveCount);
    LEVEL_FREE(level->fields, level->fieldCount);
    LEVEL_FREE(level->objectives, level->objectiveCount);
    *level = (LevelDef){0};
    free(level);
}

const LevelDef *LevelNamed(NSString *name) {
    static NSMutableDictionary<NSString *, NSValue *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    if (!name.length) return NULL;
    @synchronized (cache) {
        NSValue *cached = cache[name];
        if (!cached) {
            LevelDef *level = LevelCreate(FSJSON(FSURL(@"Levels", name, @"json")));
            if (!level) return NULL;
            for (NSString *problem in level->problems) NSLog(@"Level %@: %@", name, problem);
            cache[name] = cached = [NSValue valueWithPointer:level];
        }
        return cached.pointerValue;
    }
}

NSArray<NSString *> *LevelNames(void) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSURL *url in FSURLs(@"Levels", @"json")) [names addObject:url.lastPathComponent.stringByDeletingPathExtension];
    return names;
}

#define LEVEL_FIND(items, count, name) \
    do { if (name) for (int i = 0; i < (count); i++) if ([(items)[i].identifier isEqualToString:name]) return &(items)[i]; return NULL; } while (0)

const LevelNav *LevelNavNamed(const LevelDef *level, NSString *identifier) { LEVEL_FIND(level->navs, level->navCount, identifier); }
const LevelEntity *LevelEntityNamed(const LevelDef *level, NSString *identifier) { LEVEL_FIND(level->entities, level->entityCount, identifier); }
const LevelWave *LevelWaveNamed(const LevelDef *level, NSString *identifier) { LEVEL_FIND(level->waves, level->waveCount, identifier); }

// Cache alongside the definitions: resources are immutable for a process.
#import <CommonCrypto/CommonDigest.h>
NSString *ShipDataIdentity(void) {
    static NSString *identity;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CC_SHA256_CTX ctx;
        CC_SHA256_Init(&ctx);
        NSArray<NSString *> *names = ShipDefNames();
        if (!names.count) return; // incomplete bundle: fail closed at the client
        for (NSString *name in names) {
            NSURL *url = FSURL(@"Data/Ships", name, @"json");
            NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
            if (!data) return;
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
        identity = [NSString stringWithFormat:@"%@ 1 ships-sha256:%@", FSGame().lowercaseString, hex];
    });
    return identity;
}
