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
