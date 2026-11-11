#import "Common.h"

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
