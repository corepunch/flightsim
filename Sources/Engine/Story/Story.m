#import "Story.h"
#import "Assets.h"
#import "Localization.h"

static NSDictionary *StoryFile(NSString *directory, NSString *name) {
    id json = FSJSON(FSURL(directory, name, @"json"));
    if (![json isKindOfClass:NSDictionary.class]) {
        NSLog(@"Story: cannot load %@/%@.json", directory, name);
        return @{};
    }
    return json;
}

NSDictionary *CampaignData(void) {
    static NSDictionary *campaign;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ campaign = StoryFile(@"Campaign", @"campaign"); });
    return campaign;
}

NSArray<NSDictionary *> *CampaignMissions(void) {
    static NSArray *missions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *merged = [NSMutableArray array];
        for (NSDictionary *entry in CampaignData()[@"missions"]) {
            NSDictionary *level = LevelNamed(entry[@"level"]);
            if (!level) {
                NSLog(@"Campaign: no level named \"%@\"", entry[@"level"]);
                continue;
            }
            NSMutableDictionary *mission = [level mutableCopy];
            [mission addEntriesFromDictionary:entry];
            [merged addObject:mission];
        }
        missions = merged;
    });
    return missions;
}

NSDictionary *CampaignMission(NSUInteger index) {
    NSArray *all = CampaignMissions();
    return index < all.count ? all[index] : nil;
}

NSString *CampaignLevelName(NSUInteger index) { return CampaignMission(index)[@"level"]; }

NSUInteger CampaignIndexOfLevel(NSString *level) {
    NSArray<NSDictionary *> *all = CampaignMissions();
    for (NSUInteger i = 0; i < all.count; i++) if ([all[i][@"level"] isEqualToString:level]) return i;
    return NSNotFound;
}

static NSDictionary *Cast(void) {
    static NSDictionary *cast;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cast = StoryFile(@"Story", @"characters"); });
    return cast;
}

static NSDictionary *Rooms(void) {
    static NSDictionary *rooms;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ rooms = StoryFile(@"Story", @"rooms")[@"rooms"] ?: @{}; });
    return rooms;
}

static NSDictionary *Defaults(void) { return CampaignData()[@"storyDefaults"] ?: @{}; }

NSString *StoryPlayer(void) { return Cast()[@"player"] ?: @""; }

NSDictionary *StoryCharacter(NSString *identifier) {
    return identifier ? Cast()[@"characters"][identifier] : nil;
}

BOOL StoryPortraitFacesRight(NSString *portrait) {
    static NSSet<NSString *> *left;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *set = [NSMutableSet set];
        NSDictionary *characters = Cast()[@"characters"];
        for (NSString *identifier in characters) {
            NSDictionary *character = characters[identifier];
            if ([character[@"faces"] isEqual:@"left"]) [set addObject:character[@"portrait"] ?: identifier];
        }
        left = set;
    });
    return ![left containsObject:portrait];
}

NSDictionary *StoryRoom(NSString *identifier) { return identifier ? Rooms()[identifier] : nil; }

NSString *StoryBriefingRoom(NSDictionary *mission) {
    return mission[@"briefing"][@"dialogue"][@"room"] ?: Defaults()[@"room"];
}

NSString *StoryDebriefRoom(NSDictionary *mission) {
    return mission[@"debrief"][@"room"] ?: StoryBriefingRoom(mission);
}

#pragma mark - Briefing pages

static NSMutableDictionary<NSString *, BriefingPageKind> *PageKinds(void);

static void RegisterEnginePages(NSMutableDictionary<NSString *, BriefingPageKind> *kinds) {
    // The scene's dialogue, line by line.
    kinds[@"dialogue"] = ^NSArray *(NSDictionary *mission, NSDictionary *officer) {
        NSMutableArray *pages = [NSMutableArray array];
        for (NSDictionary *line in mission[@"briefing"][@"dialogue"][@"lines"]) {
            NSMutableDictionary *page = [line mutableCopy];
            page[@"channel"] = line[@"channel"] ?: L10n(@"briefing.channel_briefing");
            page[@"dialogue"] = @YES;
            [pages addObject:page];
        }
        return pages;
    };
    // The officer's situation report, a paragraph per page.
    kinds[@"situation"] = ^NSArray *(NSDictionary *mission, NSDictionary *officer) {
        NSMutableArray *pages = [NSMutableArray array];
        for (NSString *text in mission[@"briefing"][@"text"]) {
            [pages addObject:@{ @"speaker": officer[@"speaker"], @"portrait": officer[@"portrait"],
                                @"text": text, @"channel": L10n(@"briefing.channel_situation") }];
        }
        return pages;
    };
    // Map cues and target schematics.
    kinds[@"tactical"] = ^NSArray *(NSDictionary *mission, NSDictionary *officer) {
        NSMutableArray *pages = [NSMutableArray array];
        for (NSDictionary *step in mission[@"briefing"][@"steps"]) {
            [pages addObject:@{ @"speaker": officer[@"speaker"], @"portrait": officer[@"portrait"], @"tactical": step,
                                @"text": step[@"caption"] ?: @"",
                                @"channel": L10n(step[@"schematic"] ? @"briefing.channel_schematic"
                                                                    : @"briefing.channel_flight_plan") }];
        }
        return pages;
    };
    // The objectives as orders.
    kinds[@"objectives"] = ^NSArray *(NSDictionary *mission, NSDictionary *officer) {
        NSMutableArray<NSString *> *orders = [NSMutableArray array];
        for (NSDictionary *objective in mission[@"objectives"]) {
            if ([objective[@"hidden"] boolValue] || !objective[@"text"]) continue;
            [orders addObject:[NSString stringWithFormat:@"%@%@", L10nExpand(objective[@"text"]),
                               [objective[@"optional"] boolValue] ? L10n(@"briefing.optional_suffix") : @""]];
        }
        if (!orders.count) return @[];
        return @[ @{ @"speaker": officer[@"speaker"], @"portrait": officer[@"portrait"], @"readout": orders,
                     @"text": L10n(@"briefing.orders_line"), @"channel": L10n(@"briefing.channel_objectives") } ];
    };
    // Intel lines and the loadout.
    kinds[@"intel"] = ^NSArray *(NSDictionary *mission, NSDictionary *officer) {
        NSMutableArray *intel = [NSMutableArray arrayWithArray:mission[@"briefing"][@"intel"] ?: @[]];
        NSDictionary *loadout = mission[@"loadout"];
        if (loadout[@"torpedoes"]) {
            int torpedoes = [loadout[@"torpedoes"] intValue];
            [intel addObject:L10nFormat(torpedoes == 1 ? @"briefing.loadout_one" : @"briefing.loadout_many", torpedoes)];
        }
        if (!intel.count) return @[];
        return @[ @{ @"speaker": officer[@"speaker"], @"portrait": officer[@"portrait"], @"readout": intel,
                     @"text": L10n(@"briefing.intel_line"), @"channel": L10n(@"briefing.channel_intel") } ];
    };
}

static NSMutableDictionary<NSString *, BriefingPageKind> *PageKinds(void) {
    static NSMutableDictionary *kinds;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kinds = [NSMutableDictionary dictionary];
        RegisterEnginePages(kinds);
    });
    return kinds;
}

void StoryRegisterBriefingPages(NSString *kind, BriefingPageKind build) {
    NSMutableDictionary *kinds = PageKinds();
    @synchronized (kinds) { kinds[kind] = [build copy]; }
}

NSArray<NSString *> *StoryBriefingPageKinds(void) {
    NSMutableDictionary *kinds = PageKinds();
    @synchronized (kinds) { return [kinds.allKeys sortedArrayUsingSelector:@selector(compare:)]; }
}

NSArray<NSDictionary *> *StoryBriefingPages(NSDictionary *mission) {
    NSDictionary *brief = mission[@"briefing"];
    NSString *officerId = brief[@"officer"] ?: Defaults()[@"officer"];
    NSDictionary *officer = @{
        @"speaker": brief[@"speaker"] ?: L10n(@"briefing.default_speaker"),
        @"portrait": StoryCharacter(officerId)[@"portrait"] ?: officerId ?: @"",
    };
    NSArray<NSString *> *order = brief[@"pages"] ?: Defaults()[@"briefingPages"]
        ?: @[ @"dialogue", @"situation", @"tactical", @"objectives", @"intel" ];
    NSMutableDictionary *kinds = PageKinds();
    NSMutableArray<NSDictionary *> *pages = [NSMutableArray array];
    for (NSString *kind in order) {
        BriefingPageKind build;
        @synchronized (kinds) { build = kinds[kind]; }
        if (!build) {
            NSLog(@"Story: unknown briefing page kind \"%@\"", kind);
            continue;
        }
        [pages addObjectsFromArray:build(mission, officer)];
    }
    return pages;
}
