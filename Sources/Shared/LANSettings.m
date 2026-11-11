#import "Shared.h"

LANMatchSettings LANMatchSettingsDefault(void) {
    return (LANMatchSettings){.arena=@"", .ship=@"", .fragLimit=10, .maxPilots=MAX_CLIENTS, .matchSeconds=300, .respawnSeconds=3};
}
LANMatchSettings LANMatchSettingsNormalize(LANMatchSettings s) {
    LANMatchSettings d = LANMatchSettingsDefault();
    s.arena = s.arena ?: @""; s.ship = s.ship ?: @"";
    s.fragLimit = MAX(1, MIN(100, s.fragLimit ?: d.fragLimit));
    s.maxPilots = MAX(2, MIN(MAX_CLIENTS, s.maxPilots ?: d.maxPilots));
    s.matchSeconds = isfinite(s.matchSeconds) && s.matchSeconds > 0 ? fminf(3600, fmaxf(60, s.matchSeconds)) : d.matchSeconds;
    s.respawnSeconds = isfinite(s.respawnSeconds) && s.respawnSeconds > 0 ? fminf(15, fmaxf(1, s.respawnSeconds)) : d.respawnSeconds;
    return s;
}
static NSDictionary *SettingsObject(LANMatchSettings s) {
    s = LANMatchSettingsNormalize(s);
    return @{ @"arena":s.arena, @"ship":s.ship, @"kills":@(s.fragLimit), @"pilots":@(s.maxPilots),
              @"seconds":@(s.matchSeconds), @"respawn":@(s.respawnSeconds) };
}
static BOOL ReadSettings(NSDictionary *json, LANMatchSettings *out) {
    if (!json || !JSONString(json, @"arena") || !JSONString(json, @"ship")) return NO;
    for (NSString *key in @[@"kills", @"pilots", @"seconds", @"respawn"])
        if (![json[key] isKindOfClass:NSNumber.class]) return NO;
    *out = LANMatchSettingsNormalize((LANMatchSettings){.arena=JSONString(json,@"arena"), .ship=JSONString(json,@"ship"),
        .fragLimit=JSONInt(json,@"kills",0), .maxPilots=JSONInt(json,@"pilots",0),
        .matchSeconds=JSONFloat(json,@"seconds",0), .respawnSeconds=JSONFloat(json,@"respawn",0)});
    return YES;
}
static NSString *Encode(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}
static NSDictionary *Decode(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
NSString *LANMatchSettingsEncode(LANMatchSettings s) { return Encode(SettingsObject(s)); }
BOOL LANMatchSettingsDecode(NSString *text, LANMatchSettings *s) { return ReadSettings(Decode(text), s); }
NSString *LANLobbyEncode(LANLobbyInfo lobby) {
    return Encode(@{@"players":lobby.pilots ?: @[], @"settings":SettingsObject(lobby.settings)});
}
BOOL LANLobbyDecode(NSString *text, LANLobbyInfo *lobby) {
    NSDictionary *json = Decode(text);
    LANMatchSettings settings;
    NSArray *players = JSONStrings(json,@"players");
    NSArray *rawPlayers = JSONArray(json,@"players");
    if (!rawPlayers || rawPlayers.count != players.count || players.count > MAX_CLIENTS || !ReadSettings(JSONObject(json,@"settings"), &settings)) return NO;
    *lobby = (LANLobbyInfo){.pilots=players, .settings=settings};
    return YES;
}

static NSComparisonResult CompareScores(LANPilotScore a, LANPilotScore b) {
    if (a.kills != b.kills) return a.kills > b.kills ? NSOrderedAscending : NSOrderedDescending;
    if (a.deaths != b.deaths) return a.deaths < b.deaths ? NSOrderedAscending : NSOrderedDescending;
    return NSOrderedSame;
}

NSString *LANMatchResultEncode(LANMatchResult result) {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < result.pilots.count && i < MAX_CLIENTS; i++) {
        LANPilotScore score = result.scores[i];
        [rows addObject:@{@"name": result.pilots[i], @"kills": @(score.kills), @"deaths": @(score.deaths)}];
    }
    return Encode(@{@"pilots": rows, @"local": @(result.localIndex)});
}

static int ScoreInteger(NSDictionary *json, NSString *key) {
    NSNumber *number = JSONNumber(json, key);
    double value = number ? number.doubleValue : -1;
    return value >= 0 && value <= INT_MAX && value == trunc(value) ? (int)value : -1;
}

BOOL LANMatchResultDecode(NSString *text, LANMatchResult *out) {
    NSDictionary *json = Decode(text);
    NSArray *rows = JSONArray(json, @"pilots");
    int local = ScoreInteger(json, @"local");
    if (!rows.count || rows.count > MAX_CLIENTS || local < 0 || (NSUInteger)local >= rows.count) return NO;
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:rows.count];
    LANMatchResult result = {.localIndex = (NSUInteger)local};
    for (NSUInteger i = 0; i < rows.count; i++) {
        if (![rows[i] isKindOfClass:NSDictionary.class]) return NO;
        NSDictionary *row = rows[i];
        NSString *name = JSONString(row, @"name");
        LANPilotScore score = {ScoreInteger(row, @"kills"), ScoreInteger(row, @"deaths")};
        if (!name.length || name.length > 48 || score.kills < 0 || score.deaths < 0 ||
            (i && CompareScores(result.scores[i - 1], score) == NSOrderedDescending)) return NO;
        result.scores[i] = score;
        [names addObject:name];
    }
    result.pilots = [names copy];
    *out = result;
    return YES;
}

NSUInteger LANMatchRank(LANMatchResult result, NSUInteger index) {
    while (index > 0 && CompareScores(result.scores[index - 1], result.scores[index]) == NSOrderedSame) index--;
    return index + 1;
}

BOOL LANMatchHasWinner(LANMatchResult result) {
    return result.pilots.count > 1 && CompareScores(result.scores[0], result.scores[1]) == NSOrderedAscending;
}

NSUInteger LANMatchPilotPoints(LANMatchResult result) {
    if (result.pilots.count < 2 || result.localIndex >= result.pilots.count) return 0;
    int kills = result.scores[result.localIndex].kills;
    if (kills <= 0) return 0;
    return (NSUInteger)(MIN(kills, 5) * 50) + (result.localIndex == 0 && LANMatchHasWinner(result) ? 50 : 0);
}
