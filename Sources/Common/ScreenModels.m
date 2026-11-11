#import "Common.h"
#import "Shared.h"

// MARK: - Menus

@implementation MenuChoice
+ (instancetype)choice:(NSString *)identifier title:(NSString *)title {
    return [self choice:identifier title:title enabled:YES];
}
+ (instancetype)choice:(NSString *)identifier title:(NSString *)title enabled:(BOOL)enabled {
    MenuChoice *choice = [self new];
    choice->_identifier = [identifier copy];
    choice->_title = [title copy] ?: @"";
    choice->_enabled = enabled;
    return choice;
}
+ (instancetype)choice:(NSString *)identifier title:(NSString *)title detail:(NSString *)detail {
    MenuChoice *choice = [self choice:identifier title:title enabled:YES];
    choice->_detail = detail.length ? [detail copy] : nil;
    return choice;
}
@end

@implementation MenuModel
- (instancetype)initWithTitle:(NSString *)title hint:(NSString *)hint choices:(NSArray<MenuChoice *> *)choices {
    if ((self = [super init])) {
        _title = [title copy] ?: @"";
        _hint = [hint copy] ?: @"";
        _choices = [choices copy] ?: @[];
    }
    return self;
}

- (NSUInteger)indexOfChoice:(NSString *)identifier {
    return [_choices indexOfObjectPassingTest:^BOOL(MenuChoice *choice, NSUInteger i, BOOL *stop) {
        return [choice.identifier isEqualToString:identifier];
    }];
}

- (NSUInteger)indexByMoving:(NSInteger)step from:(NSUInteger)index {
    NSInteger count = (NSInteger)_choices.count;
    if (!count) return 0;
    NSInteger from = MIN((NSInteger)index, count - 1);
    return (NSUInteger)(((from + step) % count + count) % count);
}

- (MenuChoice *)choiceToActivateAt:(NSUInteger)index {
    return index < _choices.count && _choices[index].enabled ? _choices[index] : nil;
}
@end

MenuModel *PauseMenuModel(BOOL remote, BOOL cockpit, NSString *soundTitle) {
    // A remote flight keeps running and only its host can restart it.
    return [[MenuModel alloc] initWithTitle:L10n(remote ? @"pause.title_online" : @"pause.title")
                                       hint:L10n(remote ? @"pause.hint_online" : @"pause.hint") choices:@[
        [MenuChoice choice:@"resume" title:L10n(@"pause.resume")],
        [MenuChoice choice:@"camera" title:L10n(cockpit ? @"pause.camera_cockpit" : @"pause.camera_chase")],
        [MenuChoice choice:@"controls" title:L10n(@"menu.controls")],
        [MenuChoice choice:@"sound" title:soundTitle],
        [MenuChoice choice:@"restart" title:L10n(remote ? @"pause.restart_host_only" : @"pause.restart") enabled:!remote],
        [MenuChoice choice:@"missions" title:L10n(remote ? @"pause.leave" : @"pause.missions")],
    ]];
}

MenuModel *MainMenuModel(MainMenuFacts facts) {
    NSString *campaign = L10n(facts.completed ? @"menu.campaign_replay"
                              : facts.started ? @"menu.campaign_continue" : @"menu.campaign_start");
    NSString *mission = facts.missionTitle.length
        ? L10nFormat(@"menu.mission_line", (unsigned long)facts.mission + 1, facts.missionTitle.uppercaseString) : nil;
    NSMutableArray<MenuChoice *> *choices = [NSMutableArray arrayWithArray:@[
        [MenuChoice choice:@"campaign" title:campaign detail:mission],
        [MenuChoice choice:@"missions" title:L10n(@"menu.missions")],
        [MenuChoice choice:@"lan" title:L10n(@"menu.lan")],
        [MenuChoice choice:@"leaderboards" title:L10n(@"menu.leaderboards")
                    detail:L10nFormat(@"score.total", (unsigned long)facts.score)],
        [MenuChoice choice:@"options" title:L10n(@"menu.options")],
    ]];
    if (facts.canQuit) [choices addObject:[MenuChoice choice:@"quit" title:L10n(@"menu.quit")]];
    return [[MenuModel alloc] initWithTitle:L10n(@"menu.unit") hint:nil choices:choices];
}

MenuGrid MenuGridFit(NSUInteger count, CGFloat width, CGSize available, MenuGridMetrics metrics) {
    MenuGrid grid = { .gap = metrics.gap };
    if (!count) return grid;
    NSUInteger most = MAX((NSUInteger)1, MIN(metrics.maximumColumns, count));
    for (grid.columns = 1; ; grid.columns++) {
        grid.rows = (count + grid.columns - 1) / grid.columns;
        CGFloat gaps = metrics.gap * (grid.rows - 1);
        grid.rowHeight = metrics.rowHeight;
        if (grid.rows * grid.rowHeight + gaps <= available.height) break;
        if (grid.columns == most) {
            grid.rowHeight = MAX(metrics.minimumRowHeight, (available.height - gaps) / grid.rows);
            break;
        }
    }
    CGFloat column = grid.columns > 1 && metrics.columnWidth > 0 ? metrics.columnWidth : width;
    CGFloat gaps = metrics.gap * (grid.columns - 1);
    grid.columnWidth = MAX(0, MIN(column, (available.width - gaps) / grid.columns));
    grid.size = CGSizeMake(grid.columns * grid.columnWidth + gaps,
                           grid.rows * grid.rowHeight + metrics.gap * (grid.rows - 1));
    return grid;
}

CGRect MenuGridCell(MenuGrid grid, CGRect frame, NSUInteger index) {
    if (!grid.rows) return CGRectZero;
    CGPoint cell = CGPointMake(index / grid.rows, index % grid.rows + 1);
    CGSize step = CGSizeMake(grid.columnWidth + grid.gap, -(grid.rowHeight + grid.gap));
    CGPoint corner = PointAdd(CGPointMake(CGRectGetMinX(frame), CGRectGetMaxY(frame) + grid.gap), PointMultiply(cell, step));
    return (CGRect){ corner, { grid.columnWidth, grid.rowHeight } };
}

// MARK: - Lists

@implementation ListEntry
+ (instancetype)entry:(NSString *)title detail:(NSString *)detail {
    ListEntry *entry = [self new];
    entry->_title = [title copy] ?: @"";
    entry->_detail = detail.length ? [detail copy] : nil;
    return entry;
}
@end

@implementation ListModel
- (instancetype)initWithHeading:(NSString *)heading entries:(NSArray<ListEntry *> *)entries
                       selected:(NSUInteger)selected message:(NSString *)message {
    if ((self = [super init])) {
        _heading = heading.length ? [heading copy] : nil;
        _message = message.length ? [message copy] : nil;
        _entries = [entries copy] ?: @[];
        _selected = selected < _entries.count ? selected : NSNotFound;
    }
    return self;
}
@end

NSUInteger ListFirstVisible(NSUInteger selected, NSUInteger visible) {
    return visible && selected != NSNotFound && selected >= visible ? selected - visible + 1 : 0;
}

BrowserSelection BrowserSelectionMove(BrowserSelection selection, NSUInteger count, NSInteger step) {
    if (!count) return (BrowserSelection){ .create = YES };
    // The create slot sits after the last game, and the ring wraps through it.
    NSInteger slots = (NSInteger)count + 1;
    NSInteger slot = selection.create ? (NSInteger)count : (NSInteger)MIN(selection.index, count - 1);
    slot = ((slot + step) % slots + slots) % slots;
    return slot == (NSInteger)count ? (BrowserSelection){ .create = YES } : (BrowserSelection){ .index = (NSUInteger)slot };
}

ListEntry *ServerEntry(NSString *name, int players, int maxPlayers, NSString *mission, NSString *rules) {
    NSString *where = mission ?: L10n(@"browser.in_menus");
    return [ListEntry entry:L10nFormat(@"browser.row", @"", name ?: @"", players, maxPlayers)
                     detail:rules ? L10nFormat(@"browser.row_detail", where, rules) : where];
}

ListModel *ServerListModel(NSArray<ListEntry *> *servers, BrowserSelection selection, NSString *status) {
    if (!servers.count)
        return [[ListModel alloc] initWithHeading:nil entries:nil selected:NSNotFound
                                          message:status.length ? status : L10n(@"browser.searching")];
    return [[ListModel alloc] initWithHeading:status entries:servers
                                     selected:selection.create ? NSNotFound : selection.index message:nil];
}

static NSString *ArenaTitle(LANMatchSettings settings) {
    const LevelDef *arena = LevelNamed(settings.arena);
    return arena ? arena->title : L10n(@"browser.dogfight");
}

static NSString *ShipTitle(LANMatchSettings settings) {
    const ShipDef *ship = ShipDefNamed(settings.ship);
    return ship ? @(ship->displayName) : L10n(@"browser.default_ship");
}

ListModel *LobbyModel(NSArray<NSString *> *pilots, BOOL hosting, LANMatchSettings settings) {
    NSMutableArray<ListEntry *> *entries = [NSMutableArray arrayWithCapacity:pilots.count];
    for (NSString *pilot in pilots) [entries addObject:[ListEntry entry:pilot detail:nil]];
    NSString *match = L10nFormat(@"browser.row_detail", ArenaTitle(settings), ShipTitle(settings));
    // A match needs two pilots, and only the host starts it.
    BOOL waiting = pilots.count < 2 || !hosting;
    return [[ListModel alloc] initWithHeading:[NSString stringWithFormat:@"%@\n%@", match, LANMatchSummary(settings)]
                                      entries:entries selected:0
                                      message:waiting ? L10n(hosting ? @"browser.waiting" : @"browser.guest_waiting") : nil];
}

// MARK: - Campaign

// The functions below fill these in; everyone else reads them.
@interface MissionTile ()
@property (nonatomic, readwrite, copy) NSString *number, *title, *status;
@property (nonatomic, readwrite) NSUInteger stars;
@property (nonatomic, readwrite) BOOL open;
@end
@interface MissionListModel ()
@property (nonatomic, readwrite, copy) NSArray<MissionTile *> *tiles;
@property (nonatomic, readwrite) NSUInteger selected;
@property (nonatomic, readwrite, copy) NSString *action;
@end
@interface MonitorModel ()
@property (nonatomic, readwrite, copy) NSString *title, *location, *channel, *counter, *schematic, *legend, *readout;
@end

@implementation MissionTile
@end
@implementation MissionListModel
@end

MissionListModel *MissionListModelMake(NSArray<NSString *> *titles, NSArray<NSNumber *> *stars,
                                       NSUInteger unlocked, NSUInteger selected) {
    NSMutableArray<MissionTile *> *tiles = [NSMutableArray arrayWithCapacity:titles.count];
    for (NSUInteger i = 0; i < titles.count; i++) {
        MissionTile *tile = [MissionTile new];
        tile.open = i < unlocked;
        tile.stars = i < stars.count ? MIN(stars[i].unsignedIntegerValue, (NSUInteger)3) : 0;
        tile.number = [NSString stringWithFormat:@"%02lu", (unsigned long)i + 1];
        tile.title = tile.open ? titles[i].uppercaseString : L10n(@"missions.classified");
        tile.status = L10n(!tile.open ? @"missions.locked" : tile.stars ? @"missions.completed" : @"missions.ready");
        [tiles addObject:tile];
    }
    MissionListModel *list = [MissionListModel new];
    list.tiles = tiles;
    list.selected = titles.count ? MIN(selected, titles.count - 1) : 0;
    list.action = list.selected < MIN(unlocked, titles.count) ? L10n(@"missions.briefing") : nil;
    return list;
}

TileGrid TileGridFit(CGFloat width, CGFloat tileHeight) {
    const CGFloat gap = 12, narrowest = 160;
    NSUInteger columns = MAX(1, MIN(6, (NSInteger)((width + gap) / narrowest)));
    return (TileGrid){ columns, { MAX(1, (width - gap * (columns - 1)) / columns), tileHeight }, gap };
}

CGRect TileGridCell(TileGrid grid, CGPoint corner, NSUInteger index) {
    if (!grid.columns) return CGRectZero;
    CGPoint cell = CGPointMake(index % grid.columns, index / grid.columns);
    CGSize step = CGSizeMake(grid.tile.width + grid.gap, -(grid.tile.height + grid.gap));
    CGPoint top = PointAdd(corner, PointMultiply(cell, step));
    return (CGRect){ PointAdd(top, CGPointMake(0, -grid.tile.height)), grid.tile };
}

NSUInteger TileGridMove(TileGrid grid, NSUInteger count, NSUInteger index, NSInteger columns, NSInteger rows) {
    if (!count) return 0;
    NSInteger n = (NSInteger)count, i = MIN((NSInteger)index, n - 1);
    i = ((i + columns) % n + n) % n;
    NSInteger moved = i + rows * (NSInteger)grid.columns;
    // Up from the first row stays; down past the end lands on the last tile.
    return (NSUInteger)(moved < 0 ? i : MIN(moved, n - 1));
}

CGFloat ScrollDeltaRevealing(CGRect item, CGRect viewport, CGFloat offset) {
    if (CGRectGetMinY(item) + offset < CGRectGetMinY(viewport)) return CGRectGetMinY(viewport) - CGRectGetMinY(item) - offset;
    if (CGRectGetMaxY(item) + offset > CGRectGetMaxY(viewport)) return CGRectGetMaxY(viewport) - CGRectGetMaxY(item) - offset;
    return 0;
}

@implementation MonitorModel
@end

MonitorModel *BriefingMonitorModel(MonitorFacts facts) {
    MonitorModel *monitor = [MonitorModel new];
    if (facts.titled)
        monitor.title = L10nFormat(@"briefing.title", (unsigned long)facts.mission + 1, facts.missionTitle.uppercaseString);
    monitor.location = L10nFormat(@"briefing.location", facts.location, facts.stardate);
    monitor.channel = [facts.channel copy] ?: @"";
    monitor.counter = [NSString stringWithFormat:@"%02lu / %02lu", (unsigned long)facts.page + 1, (unsigned long)facts.pageCount];
    if (facts.schematicAsset.length && facts.subsystem.length) {
        monitor.schematic = [NSString stringWithFormat:@"Schematics/%@-%@", facts.schematicAsset, facts.subsystem];
        // A subsystem the catalog does not name shows as the level wrote it.
        NSString *key = [@"briefing.subsystem." stringByAppendingString:facts.subsystem.lowercaseString];
        NSString *name = L10n(key);
        monitor.legend = L10nFormat(@"briefing.target", [name isEqualToString:key] ? facts.subsystem.uppercaseString : name);
    }
    if (facts.readout.count)
        monitor.readout = [@"›  " stringByAppendingString:[facts.readout componentsJoinedByString:@"\n›  "]];
    return monitor;
}

// MARK: - Match setup

@implementation SettingRow
+ (instancetype)row:(NSString *)title value:(NSString *)value enabled:(BOOL)enabled {
    SettingRow *row = [self new];
    row->_title = [title copy];
    row->_value = [value copy];
    row->_enabled = enabled;
    return row;
}
@end

typedef NS_ENUM(NSUInteger, SetupRow) { SetupArena, SetupShip, SetupPilots, SetupKills, SetupDuration, SetupRespawn };

static NSArray<NSString *> *ArenaNames(void) {
    NSMutableArray<NSString *> *arenas = [NSMutableArray array];
    for (NSString *name in LevelNames()) if (LevelNamed(name)->rules.deathmatch) [arenas addObject:name];
    return arenas;
}

NSArray<SettingRow *> *LANSetupRows(LANMatchSettings settings) {
    return @[
        [SettingRow row:L10n(@"browser.arena") value:ArenaTitle(settings) enabled:ArenaNames().count > 1],
        [SettingRow row:L10n(@"browser.ship") value:ShipTitle(settings) enabled:YES],
        [SettingRow row:L10n(@"browser.pilots") value:@(settings.maxPilots).stringValue enabled:YES],
        [SettingRow row:L10n(@"browser.kill_limit") value:@(settings.fragLimit).stringValue enabled:YES],
        [SettingRow row:L10n(@"browser.duration") value:L10nFormat(@"browser.minutes", (int)(settings.matchSeconds / 60)) enabled:YES],
        [SettingRow row:L10n(@"browser.respawn") value:L10nFormat(@"browser.seconds", (int)settings.respawnSeconds) enabled:YES],
    ];
}

static NSString *NextName(NSArray<NSString *> *names, NSString *current, NSInteger direction) {
    if (!names.count) return current;
    NSUInteger i = [names indexOfObject:current ?: @""];
    return names[i == NSNotFound ? 0 : (NSUInteger)(((NSInteger)i + direction) % (NSInteger)names.count + (NSInteger)names.count) % names.count];
}

// The neighbouring step; a value between two steps (an arena's own default) moves to the nearer one that way.
static float NextStep(const float *steps, NSInteger count, float current, NSInteger direction) {
    for (NSInteger n = 0; n < count; n++) {
        NSInteger i = direction > 0 ? n : count - 1 - n;
        if (direction > 0 ? steps[i] > current : steps[i] < current) return steps[i];
    }
    return direction > 0 ? steps[0] : steps[count - 1];
}

LANMatchSettings LANMatchSettingsStep(LANMatchSettings settings, NSUInteger row, NSInteger direction) {
    static const float pilots[] = { 2, 4, 6, 8 }, kills[] = { 5, 10, 15, 20, 30, 50 };
    static const float seconds[] = { 180, 300, 600, 900, 1200 }, respawn[] = { 1, 3, 5, 10 };
    direction = direction < 0 ? -1 : 1;
    switch ((SetupRow)row) {
        case SetupArena: settings.arena = NextName(ArenaNames(), settings.arena, direction); break;
        // The empty name is the arena's own ship.
        case SetupShip: settings.ship = NextName([@[@""] arrayByAddingObjectsFromArray:ShipDefNames()], settings.ship, direction); break;
        case SetupPilots: settings.maxPilots = (int)NextStep(pilots, 4, settings.maxPilots, direction); break;
        case SetupKills: settings.fragLimit = (int)NextStep(kills, 6, settings.fragLimit, direction); break;
        case SetupDuration: settings.matchSeconds = NextStep(seconds, 5, settings.matchSeconds, direction); break;
        case SetupRespawn: settings.respawnSeconds = NextStep(respawn, 4, settings.respawnSeconds, direction); break;
    }
    return settings;
}

// MARK: - Reports

@implementation ReportBlock
+ (instancetype)blockOfKind:(ReportBlockKind)kind text:(NSString *)text tone:(ReportTone)tone {
    ReportBlock *block = [self new];
    block->_kind = kind;
    block->_text = [text copy] ?: @"";
    block->_tone = tone;
    block->_items = @[];
    block->_header = @[];
    block->_rows = @[];
    block->_highlightedRow = NSNotFound;
    return block;
}
+ (instancetype)headline:(NSString *)text tone:(ReportTone)tone {
    return [self blockOfKind:ReportHeadline text:text tone:tone];
}
+ (instancetype)rating:(NSUInteger)stars {
    ReportBlock *block = [self blockOfKind:ReportRating text:nil tone:ReportToneEmphasis];
    block->_stars = MIN(stars, (NSUInteger)3);
    return block;
}
+ (instancetype)scoreTotal:(NSUInteger)total earned:(NSUInteger)earned {
    ReportBlock *block = [self blockOfKind:ReportScore text:nil tone:ReportToneEmphasis];
    block->_total = total;
    block->_earned = earned;
    return block;
}
+ (instancetype)note:(NSString *)text { return [self blockOfKind:ReportNote text:text tone:ReportTonePlain]; }
+ (instancetype)text:(NSString *)text { return [self blockOfKind:ReportText text:text tone:ReportTonePlain]; }
+ (instancetype)checklist:(NSString *)title items:(NSArray<ObjectiveReadout *> *)items {
    ReportBlock *block = [self blockOfKind:ReportChecklist text:title tone:ReportTonePlain];
    block->_items = [items copy] ?: @[];
    return block;
}
+ (instancetype)table:(NSArray<NSString *> *)header rows:(NSArray<NSArray<NSString *> *> *)rows
          highlighted:(NSUInteger)row {
    ReportBlock *block = [self blockOfKind:ReportTable text:nil tone:ReportTonePlain];
    block->_header = [header copy] ?: @[];
    block->_rows = [rows copy] ?: @[];
    block->_highlightedRow = row < rows.count ? row : NSNotFound;
    return block;
}
@end

@implementation ReportModel
- (instancetype)initWithBlocks:(NSArray<ReportBlock *> *)blocks {
    if ((self = [super init])) _blocks = [blocks copy] ?: @[];
    return self;
}
- (ReportBlock *)firstBlockOfKind:(ReportBlockKind)kind {
    for (ReportBlock *block in _blocks) if (block.kind == kind) return block;
    return nil;
}
@end

ReportModel *DebriefReport(DebriefFacts facts) {
    NSMutableArray<ReportBlock *> *blocks = [NSMutableArray array];
    [blocks addObject:[ReportBlock headline:L10n(facts.success ? @"debrief.complete" : @"debrief.failed")
                                       tone:facts.success ? ReportTonePlain : ReportToneDanger]];
    // A failed mission earns nothing, so it shows neither stars nor score.
    if (facts.success) {
        [blocks addObject:[ReportBlock rating:facts.stars]];
        [blocks addObject:[ReportBlock scoreTotal:facts.total earned:facts.earned]];
    }
    if (facts.summary.length) [blocks addObject:[ReportBlock text:facts.summary]];
    if (facts.results.count) [blocks addObject:[ReportBlock checklist:L10n(@"debrief.objectives") items:facts.results]];
    return [[ReportModel alloc] initWithBlocks:blocks];
}

ReportModel *CampaignEndReport(NSUInteger stars, NSUInteger possible, NSUInteger total) {
    return [[ReportModel alloc] initWithBlocks:@[
        [ReportBlock headline:L10n(@"debrief.to_be_continued") tone:ReportToneEmphasis],
        [ReportBlock note:L10n(@"debrief.more_to_come")],
        [ReportBlock note:L10nFormat(@"debrief.campaign_stars", (unsigned long)stars, (unsigned long)possible)],
        [ReportBlock scoreTotal:total earned:0],
    ]];
}

ReportModel *MatchReport(LANMatchResult result, NSUInteger total, NSUInteger earned) {
    // Alone in the arena there is no placing to announce.
    NSString *outcome = L10n(@"browser.results");
    if (result.pilots.count > 1) {
        NSUInteger rank = LANMatchRank(result, result.localIndex);
        if (rank == 1) outcome = L10n(LANMatchHasWinner(result) ? @"match.win" : @"match.draw");
        else outcome = L10nFormat(@"match.place", (unsigned long)rank);
    }
    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray arrayWithCapacity:result.pilots.count];
    for (NSUInteger i = 0; i < result.pilots.count; i++) {
        LANPilotScore score = result.scores[i];
        [rows addObject:@[@(LANMatchRank(result, i)).stringValue, result.pilots[i],
                          @(score.kills).stringValue, @(score.deaths).stringValue]];
    }
    return [[ReportModel alloc] initWithBlocks:@[
        [ReportBlock headline:outcome tone:ReportTonePlain],
        [ReportBlock scoreTotal:total earned:earned],
        [ReportBlock table:@[@"#", L10n(@"browser.pilots"), L10n(@"match.kills"), L10n(@"match.deaths")]
                      rows:rows highlighted:result.localIndex],
    ]];
}
