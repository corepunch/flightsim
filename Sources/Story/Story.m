#import "Story.h"
#import "Common.h"

static NSDictionary *StoryFile(NSString *directory, NSString *name) {
    id json = FSJSON(FSURL(directory, name, @"json"));
    if (![json isKindOfClass:NSDictionary.class]) {
        NSLog(@"Story: cannot load %@/%@.json", directory, name);
        return @{};
    }
    return json;
}

// Objects of a list, each read by `read`; entries that are not objects are skipped.
static NSArray *ObjectsOf(id json, NSString *key, id (^read)(NSDictionary *item)) {
    NSMutableArray *objects = [NSMutableArray array];
    for (id item in JSONArray(json, key)) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        id object = read(item);
        if (object) [objects addObject:object];
    }
    return objects;
}

#pragma mark - Lines and steps

// For pages built from a line.
@interface StoryLine ()
- (void)copyLineTo:(StoryLine *)other;
- (void)setChannel:(NSString *)channel;
- (void)setText:(NSString *)text;
@end

@implementation StoryLine

+ (instancetype)lineWithJSON:(NSDictionary *)json {
    StoryLine *line = [self new];
    line->_speaker = JSONString(json, @"speaker") ?: @"";
    line->_portrait = JSONString(json, @"portrait");
    line->_text = JSONString(json, @"text") ?: @"";
    line->_channel = JSONString(json, @"channel");
    line->_listener = JSONString(json, @"listener");
    line->_expression = JSONString(json, @"expression");
    line->_listenerExpression = JSONString(json, @"listenerExpression");
    return line;
}

+ (instancetype)lineBy:(NSString *)speaker portrait:(NSString *)portrait text:(NSString *)text {
    StoryLine *line = [self new];
    line->_speaker = speaker ?: @"";
    line->_portrait = portrait;
    line->_text = text ?: @"";
    return line;
}

// The line's fields onto another (a page built from it).
- (void)copyLineTo:(StoryLine *)other {
    other->_speaker = _speaker;
    other->_portrait = _portrait;
    other->_text = _text;
    other->_channel = _channel;
    other->_listener = _listener;
    other->_expression = _expression;
    other->_listenerExpression = _listenerExpression;
}

- (void)setChannel:(NSString *)channel { _channel = channel; }
- (void)setText:(NSString *)text { _text = text ?: @""; }

@end

@implementation BriefingPlace

+ (instancetype)placeWithJSON:(id)json {
    BriefingPlace *place = [self new];
    if ([json isKindOfClass:NSString.class] && [json length]) {
        place->_identifier = json;
        return place;
    }
    if (![json isKindOfClass:NSArray.class] || [json count] != 2) return nil;
    for (id v in json) if (![v isKindOfClass:NSNumber.class]) return nil;
    place->_position = simd_make_float2([json[0] floatValue], [json[1] floatValue]);
    return place;
}

@end

@implementation BriefingCamera

+ (instancetype)cameraWithJSON:(NSDictionary *)json {
    if (!json) return nil;
    BriefingCamera *camera = [self new];
    camera->_center = [BriefingPlace placeWithJSON:json[@"center"]];
    camera->_span = MAX(0, JSONFloat(json, @"span", 0));
    return camera;
}

@end

@implementation BriefingLabel

+ (instancetype)labelWithJSON:(NSDictionary *)json {
    BriefingLabel *label = [self new];
    label->_text = JSONString(json, @"text");
    label->_at = [BriefingPlace placeWithJSON:json[@"at"]];
    return label->_text.length && label->_at ? label : nil;
}

@end

@implementation BriefingStep

+ (instancetype)stepWithJSON:(NSDictionary *)json {
    BriefingStep *step = [self new];
    step->_caption = JSONString(json, @"caption") ?: @"";
    step->_focus = JSONString(json, @"focus");
    step->_schematic = JSONString(json, @"schematic");
    step->_show = JSONStrings(json, @"show");
    step->_route = JSONStrings(json, @"route");
    step->_camera = [BriefingCamera cameraWithJSON:JSONObject(json, @"camera")];
    step->_labels = ObjectsOf(json, @"labels", ^id(NSDictionary *label) { return [BriefingLabel labelWithJSON:label]; });
    return step;
}

+ (instancetype)stepFocusing:(NSString *)identifier {
    BriefingStep *step = [self new];
    step->_caption = @"";
    step->_focus = identifier;
    step->_show = identifier ? @[identifier] : @[];
    step->_route = @[];
    step->_labels = @[];
    return step;
}

@end

#pragma mark - Campaign

@implementation BriefingScene
+ (instancetype)sceneWithJSON:(NSDictionary *)json {
    if (!json) return nil;
    BriefingScene *scene = [self new];
    scene->_room = JSONString(json, @"room");
    scene->_focus = JSONString(json, @"focus");
    scene->_cast = JSONStrings(json, @"cast");
    scene->_lines = ObjectsOf(json, @"lines", ^id(NSDictionary *line) { return [StoryLine lineWithJSON:line]; });
    return scene;
}
@end

@implementation MissionBriefing
+ (instancetype)briefingWithJSON:(NSDictionary *)json {
    MissionBriefing *briefing = [self new];
    briefing->_location = JSONString(json, @"location");
    briefing->_stardate = JSONString(json, @"stardate");
    briefing->_speaker = JSONString(json, @"speaker");
    briefing->_officer = JSONString(json, @"officer");
    briefing->_pageKinds = JSONArray(json, @"pages") ? JSONStrings(json, @"pages") : nil;
    briefing->_text = JSONStrings(json, @"text");
    briefing->_intel = JSONStrings(json, @"intel");
    briefing->_steps = ObjectsOf(json, @"steps", ^id(NSDictionary *step) { return [BriefingStep stepWithJSON:step]; });
    briefing->_dialogue = [BriefingScene sceneWithJSON:JSONObject(json, @"dialogue")];
    return briefing;
}
@end

@implementation MissionDebrief
+ (instancetype)debriefWithJSON:(NSDictionary *)json {
    MissionDebrief *debrief = [self new];
    debrief->_win = JSONString(json, @"win") ?: @"";
    debrief->_lose = JSONString(json, @"lose") ?: @"";
    debrief->_room = JSONString(json, @"room");
    debrief->_dialogue = ObjectsOf(json, @"dialogue", ^id(NSDictionary *line) { return [StoryLine lineWithJSON:line]; });
    return debrief;
}
@end

@implementation StoryDefaults
+ (instancetype)defaultsWithJSON:(NSDictionary *)json {
    StoryDefaults *defaults = [self new];
    defaults->_officer = JSONString(json, @"officer");
    defaults->_room = JSONString(json, @"room");
    defaults->_briefingPages = JSONArray(json, @"briefingPages") ? JSONStrings(json, @"briefingPages")
                                                                  : @[ @"dialogue", @"situation", @"tactical", @"objectives", @"intel" ];
    return defaults;
}
@end

@implementation CampaignMission
+ (instancetype)missionWithJSON:(NSDictionary *)json index:(NSUInteger)index defaults:(StoryDefaults *)defaults {
    NSString *levelName = JSONString(json, @"level");
    const LevelDef *level = LevelNamed(levelName);
    if (!level) {
        NSLog(@"Campaign: no level named \"%@\"", levelName);
        return nil;
    }
    CampaignMission *mission = [self new];
    mission->_index = index;
    mission->_levelName = levelName;
    mission->_level = level;
    mission->_title = level->title;
    mission->_briefing = [MissionBriefing briefingWithJSON:JSONObject(json, @"briefing")];
    mission->_debrief = [MissionDebrief debriefWithJSON:JSONObject(json, @"debrief")];
    mission->_briefingRoom = mission->_briefing.dialogue.room ?: defaults.room;
    mission->_debriefRoom = mission->_debrief.room ?: mission->_briefingRoom;
    return mission;
}
@end

static NSDictionary *CampaignFile(void) {
    static NSDictionary *campaign;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ campaign = StoryFile(@"Campaign", @"campaign"); });
    return campaign;
}

StoryDefaults *CampaignStoryDefaults(void) {
    static StoryDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ defaults = [StoryDefaults defaultsWithJSON:JSONObject(CampaignFile(), @"storyDefaults")]; });
    return defaults;
}

NSArray<CampaignMission *> *CampaignMissions(void) {
    static NSArray *missions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *list = [NSMutableArray array];
        for (id entry in JSONArray(CampaignFile(), @"missions")) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            CampaignMission *mission = [CampaignMission missionWithJSON:entry index:list.count defaults:CampaignStoryDefaults()];
            if (mission) [list addObject:mission];
        }
        missions = list;
    });
    return missions;
}

CampaignMission *CampaignMissionAt(NSUInteger index) {
    NSArray *all = CampaignMissions();
    return index < all.count ? all[index] : nil;
}

NSString *CampaignLevelName(NSUInteger index) { return CampaignMissionAt(index).levelName; }

NSUInteger CampaignIndexOfLevel(NSString *level) {
    for (CampaignMission *mission in CampaignMissions())
        if ([mission.levelName isEqualToString:level]) return mission.index;
    return NSNotFound;
}

#pragma mark - Cast and rooms

@implementation StoryCharacter
+ (instancetype)characterWithJSON:(NSDictionary *)json identifier:(NSString *)identifier {
    StoryCharacter *character = [self new];
    character->_identifier = identifier;
    character->_name = JSONString(json, @"name") ?: identifier;
    character->_portrait = JSONString(json, @"portrait") ?: identifier;
    character->_facesRight = ![JSONString(json, @"faces") isEqualToString:@"left"];
    return character;
}
@end

@implementation StoryRoom {
    NSData *_bezel;     // simd_float2 corners
}
+ (instancetype)roomWithJSON:(NSDictionary *)json identifier:(NSString *)identifier {
    StoryRoom *room = [self new];
    room->_identifier = identifier;
    room->_image = JSONString(json, @"image") ?: identifier;
    NSArray *size = JSONArray(json, @"size");
    room->_size = size.count == 2 ? simd_make_float2([size[0] floatValue], [size[1] floatValue]) : 0;
    NSDictionary *board = JSONObject(json, @"board");
    room->_hasBoard = board != nil;
    room->_boardBottom = JSONFloat(board, @"bottom", 0);
    room->_boardHeight = JSONFloat(board, @"height", 0);
    NSMutableData *bezel = [NSMutableData data];
    for (NSArray *point in JSONArray(json, @"bezel")) {
        if (![point isKindOfClass:NSArray.class] || point.count < 2) continue;
        simd_float2 p = simd_make_float2([point[0] floatValue], [point[1] floatValue]);
        [bezel appendBytes:&p length:sizeof p];
    }
    room->_bezel = bezel;
    return room;
}
- (NSUInteger)bezelCount { return _bezel.length / sizeof(simd_float2); }
- (simd_float2)bezelPoint:(NSUInteger)index { return ((const simd_float2 *)_bezel.bytes)[index]; }
@end

static NSDictionary *CastFile(void) {
    static NSDictionary *cast;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cast = StoryFile(@"Story", @"characters"); });
    return cast;
}

static NSDictionary<NSString *, StoryCharacter *> *Cast(void) {
    static NSDictionary *characters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *all = [NSMutableDictionary dictionary];
        NSDictionary *json = JSONObject(CastFile(), @"characters");
        for (NSString *identifier in json)
            all[identifier] = [StoryCharacter characterWithJSON:JSONObject(json, identifier) identifier:identifier];
        characters = all;
    });
    return characters;
}

static NSDictionary<NSString *, StoryRoom *> *Rooms(void) {
    static NSDictionary *rooms;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *all = [NSMutableDictionary dictionary];
        NSDictionary *json = JSONObject(StoryFile(@"Story", @"rooms"), @"rooms");
        for (NSString *identifier in json) all[identifier] = [StoryRoom roomWithJSON:JSONObject(json, identifier) identifier:identifier];
        rooms = all;
    });
    return rooms;
}

NSString *StoryPlayer(void) { return JSONString(CastFile(), @"player") ?: @""; }

StoryCharacter *StoryCharacterNamed(NSString *identifier) { return identifier ? Cast()[identifier] : nil; }

BOOL StoryPortraitFacesRight(NSString *portrait) {
    static NSSet<NSString *> *left;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *set = [NSMutableSet set];
        for (StoryCharacter *character in Cast().allValues) if (!character.facesRight) [set addObject:character.portrait];
        left = set;
    });
    return ![left containsObject:portrait];
}

StoryRoom *StoryRoomNamed(NSString *identifier) { return identifier ? Rooms()[identifier] : nil; }

#pragma mark - Briefing pages

@implementation BriefingPage

+ (instancetype)dialogueLine:(StoryLine *)line channel:(NSString *)channel {
    BriefingPage *page = [self new];
    [line copyLineTo:page];
    [page setChannel:line.channel ?: channel];
    page->_dialogue = YES;
    return page;
}

+ (instancetype)pageBy:(StoryLine *)officer text:(NSString *)text channel:(NSString *)channel
                  step:(BriefingStep *)step readout:(NSArray<NSString *> *)readout {
    BriefingPage *page = [self new];
    [officer copyLineTo:page];
    [page setText:text];
    [page setChannel:channel];
    page->_step = step;
    page->_readout = readout;
    return page;
}

@end

static NSMutableDictionary<NSString *, BriefingPageKind> *PageKinds(void);

static void RegisterEnginePages(NSMutableDictionary<NSString *, BriefingPageKind> *kinds) {
    // The scene's dialogue, line by line.
    kinds[@"dialogue"] = ^NSArray *(CampaignMission *mission, StoryLine *officer) {
        NSMutableArray *pages = [NSMutableArray array];
        for (StoryLine *line in mission.briefing.dialogue.lines)
            [pages addObject:[BriefingPage dialogueLine:line channel:L10n(@"briefing.channel_briefing")]];
        return pages;
    };
    // The officer's situation report, a paragraph per page.
    kinds[@"situation"] = ^NSArray *(CampaignMission *mission, StoryLine *officer) {
        NSMutableArray *pages = [NSMutableArray array];
        for (NSString *text in mission.briefing.text)
            [pages addObject:[BriefingPage pageBy:officer text:text channel:L10n(@"briefing.channel_situation") step:nil readout:nil]];
        return pages;
    };
    // Map cues and target schematics.
    kinds[@"tactical"] = ^NSArray *(CampaignMission *mission, StoryLine *officer) {
        NSMutableArray *pages = [NSMutableArray array];
        for (BriefingStep *step in mission.briefing.steps) {
            NSString *channel = L10n(step.schematic ? @"briefing.channel_schematic" : @"briefing.channel_flight_plan");
            [pages addObject:[BriefingPage pageBy:officer text:step.caption channel:channel step:step readout:nil]];
        }
        return pages;
    };
    // The objectives as orders.
    kinds[@"objectives"] = ^NSArray *(CampaignMission *mission, StoryLine *officer) {
        NSMutableArray<NSString *> *orders = [NSMutableArray array];
        const LevelDef *level = mission.level;
        for (int i = 0; i < level->objectiveCount; i++) {
            const LevelObjective *objective = &level->objectives[i];
            if (objective->hidden || !objective->text) continue;
            [orders addObject:[NSString stringWithFormat:@"%@%@", L10nExpand(objective->text),
                               objective->optional ? L10n(@"briefing.optional_suffix") : @""]];
        }
        if (!orders.count) return @[];
        return @[ [BriefingPage pageBy:officer text:L10n(@"briefing.orders_line") channel:L10n(@"briefing.channel_objectives")
                                  step:nil readout:orders] ];
    };
    // Intel lines and the loadout.
    kinds[@"intel"] = ^NSArray *(CampaignMission *mission, StoryLine *officer) {
        NSMutableArray *intel = [mission.briefing.intel mutableCopy];
        int torpedoes = mission.level->torpedoes;
        if (torpedoes >= 0)
            [intel addObject:L10nFormat(torpedoes == 1 ? @"briefing.loadout_one" : @"briefing.loadout_many", torpedoes)];
        if (!intel.count) return @[];
        return @[ [BriefingPage pageBy:officer text:L10n(@"briefing.intel_line") channel:L10n(@"briefing.channel_intel")
                                  step:nil readout:intel] ];
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

NSArray<BriefingPage *> *StoryBriefingPagesOfKinds(CampaignMission *mission, NSArray<NSString *> *order) {
    MissionBriefing *brief = mission.briefing;
    NSString *officerId = brief.officer ?: CampaignStoryDefaults().officer;
    StoryLine *officer = [StoryLine lineBy:brief.speaker ?: L10n(@"briefing.default_speaker")
                                  portrait:StoryCharacterNamed(officerId).portrait ?: officerId ?: @""
                                      text:nil];
    NSMutableDictionary *kinds = PageKinds();
    NSMutableArray<BriefingPage *> *pages = [NSMutableArray array];
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

NSArray<BriefingPage *> *StoryBriefingPages(CampaignMission *mission) {
    return StoryBriefingPagesOfKinds(mission, mission.briefing.pageKinds ?: CampaignStoryDefaults().briefingPages);
}
