#import "Common.h"

static void RegisterOptions(void) {
    [Cvar get:@"g_lanArena" defaultValue:@"" flags:CVAR_ARCHIVE help:@"LAN arena level name"];
    [Cvar get:@"g_lanShip" defaultValue:@"" flags:CVAR_ARCHIVE help:@"LAN ship definition; empty uses the arena default"];
    for (NSString *name in @[@"g_lanFragLimit", @"g_lanMaxPilots", @"g_lanMatchSeconds", @"g_lanRespawnSeconds"])
        [Cvar get:name defaultValue:@"0" flags:CVAR_ARCHIVE help:@"LAN match override; 0 uses the arena default"];
}
LANMatchSettings LANMatchSettingsCurrent(void) {
    RegisterOptions();
    LANMatchSettings s = LANMatchSettingsDefault();
    s.arena = [Cvar find:@"g_lanArena"].string;
    const LevelDef *arena = LevelNamed(s.arena);
    if (!arena || !arena->rules.deathmatch) {
        for (NSString *name in LevelNames()) if (LevelNamed(name)->rules.deathmatch) { s.arena = name; arena = LevelNamed(name); break; }
    }
    if (arena) { s.fragLimit=arena->rules.fragLimit; s.matchSeconds=arena->rules.matchSeconds; s.respawnSeconds=arena->rules.respawnSeconds; }
    s.ship = [Cvar find:@"g_lanShip"].string;
    if (s.ship.length && !ShipDefNamed(s.ship)) s.ship = @"";
    float value = [Cvar find:@"g_lanFragLimit"].value; if (value > 0) s.fragLimit = (int)value;
    value = [Cvar find:@"g_lanMaxPilots"].value; if (value > 0) s.maxPilots = (int)value;
    value = [Cvar find:@"g_lanMatchSeconds"].value; if (value > 0) s.matchSeconds = value;
    value = [Cvar find:@"g_lanRespawnSeconds"].value; if (value > 0) s.respawnSeconds = value;
    return LANMatchSettingsNormalize(s);
}
void LANMatchSettingsSave(LANMatchSettings s) {
    RegisterOptions(); s = LANMatchSettingsNormalize(s);
    [Cvar set:@"g_lanArena" value:s.arena]; [Cvar set:@"g_lanShip" value:s.ship];
    [Cvar set:@"g_lanFragLimit" value:@(s.fragLimit).stringValue];
    [Cvar set:@"g_lanMaxPilots" value:@(s.maxPilots).stringValue];
    [Cvar set:@"g_lanMatchSeconds" value:@(s.matchSeconds).stringValue];
    [Cvar set:@"g_lanRespawnSeconds" value:@(s.respawnSeconds).stringValue];
}
NSString *LANMatchSummary(LANMatchSettings s) {
    s = LANMatchSettingsNormalize(s);
    return L10nFormat(@"browser.rules", s.maxPilots, s.fragLimit, (int)(s.matchSeconds / 60), (int)s.respawnSeconds);
}
