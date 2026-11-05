#import "FrontEnd.h"
#import "Story.h"
#import "MainMenu.h"
#import "Briefing.h"
#import "ServerBrowser.h"
#import "Loading.h"
#import "LANBrowser.h"
#import "Progress.h"
#import "Assets.h"
#import "Localization.h"

typedef NS_ENUM(NSInteger, FrontScreen) { FrontScreenMainMenu, FrontScreenCampaign, FrontScreenBrowser };

@implementation FrontEnd {
    __weak id<UIServices> _services;
    MainMenu *_mainMenu;
    Briefing *_briefing;
    ServerBrowser *_browser;
    LANBrowser *_lan;
    FrontScreen _screen, _browserReturn;
}

- (instancetype)initWithSize:(CGSize)size services:(id<UIServices>)services {
    if ((self = [super init])) {
        _services = services;
        _mainMenu = [[MainMenu alloc] initWithSize:size];
        _briefing = [[Briefing alloc] initWithSize:size];
        _browser = [[ServerBrowser alloc] initWithSize:size];
        _screen = FrontScreenMainMenu;
    }
    return self;
}

- (NSUInteger)levelCount { return CampaignMissions().count; }

- (SKScene *)currentScreen {
    switch (_screen) {
        case FrontScreenMainMenu: return _mainMenu;
        case FrontScreenCampaign: return _briefing;
        case FrontScreenBrowser: return _browser;
    }
    return _mainMenu;
}

- (void)present:(FrontScreen)screen {
    _screen = screen;
    [_services present:self.currentScreen];
}

#pragma mark - Campaign record

// Where "campaign" picks up: the newest open mission, or the first once the
// campaign is complete.
- (NSUInteger)campaignEntry {
    return ProgressCampaignCompleted() ? 0 : ProgressUnlockedCount() - 1;
}

- (void)prepareMainMenu {
    NSUInteger index = [self campaignEntry];
    [_mainMenu showMission:index title:CampaignMission(index)[@"title"]
                   started:ProgressHasStarted() || index > 0 completed:ProgressCampaignCompleted()];
}

- (void)prepareAfterBoot {
    _screen = FrontScreenMainMenu;
    [self prepareMainMenu];
    [_briefing showListSelecting:ProgressUnlockedCount() - 1];
}

#pragma mark - Showing screens

- (void)showMainMenu {
    [self prepareMainMenu];
    [self present:FrontScreenMainMenu];
}

- (void)showMissionsSelecting:(NSUInteger)index {
    [_briefing showListSelecting:index];
    [self present:FrontScreenCampaign];
}

- (void)showBriefing:(NSUInteger)index page:(NSUInteger)page {
    [_briefing showBriefing:index page:page];
    [self present:FrontScreenCampaign];
}

- (void)showBrowser {
    if (_screen != FrontScreenBrowser) _browserReturn = _screen;
    if (!_lan) _lan = [LANBrowser new];
    NSString *server = _services.connectedServer;
    [_browser setStatus:server ? L10nFormat(@"browser.connected", server) : @""];
    [self present:FrontScreenBrowser];
}

- (void)setBrowserStatus:(NSString *)status { [_browser setStatus:status]; }
- (void)setHostLine:(NSString *)line { _browser.hostLine = line; }

#pragma mark - Levels

- (void)fillLoadingCard:(Loading *)card level:(NSUInteger)index {
    NSDictionary *mission = CampaignMission(index);
    NSDictionary *b = mission[@"briefing"];
    NSString *detail = b[@"stardate"] ? L10nFormat(@"loading.location_stardate", b[@"location"] ?: @"", b[@"stardate"]) : b[@"location"];
    [card showTitle:mission[@"title"] kicker:L10nFormat(@"loading.mission_kicker", (unsigned long)index + 1) detail:detail];
}

- (NSString *)bannerForLevel:(NSUInteger)index { return [CampaignMission(index)[@"title"] uppercaseString]; }

- (void)levelStarted:(NSUInteger)index remote:(BOOL)remote {
    if (!remote) ProgressMarkStarted();
}

- (void)levelEnded:(NSUInteger)index success:(BOOL)success results:(NSArray<NSString *> *)results remote:(BOOL)remote {
    NSMutableArray *shown = [NSMutableArray array];
    for (NSString *line in results) [shown addObject:L10nExpand(line)];
    results = shown;
    if (success) { ProgressRecordResult(index, results); ProgressMarkCompleted(index); }
    [_briefing showDebrief:index success:success results:results];
    [self present:FrontScreenCampaign];
}

- (void)levelLeft:(NSUInteger)index { [self showMissionsSelecting:index]; }

#pragma mark - Frame

- (void)frame:(InputAction)actions {
    switch (_screen) {
        case FrontScreenMainMenu: [self mainMenuFrame:actions]; break;
        case FrontScreenCampaign: [self campaignFrame:actions]; break;
        case FrontScreenBrowser: [self browserFrame:actions]; break;
    }
}

- (void)mainMenuFrame:(InputAction)actions {
    switch ([_mainMenu handle:actions]) {
        case MainMenuCommandCampaign:
            [self showBriefing:[self campaignEntry] page:0];
            break;
        case MainMenuCommandMissions:
            [self showMissionsSelecting:ProgressUnlockedCount() - 1];
            break;
        case MainMenuCommandMultiplayer:
            [self showBrowser];
            break;
        case MainMenuCommandQuit:
#if TARGET_OS_OSX
            [_services quitAfter:[_mainMenu motionPowerDown]];
#endif
            break;
        case MainMenuCommandNone:
            break;
    }
}

- (void)campaignFrame:(InputAction)actions {
    [_briefing tick:_services.time];
    switch ([_briefing handle:actions]) {
        case BriefingCommandLaunch: [_services startLevel:_briefing.selectedIndex]; return;
        case BriefingCommandMainMenu: [self showMainMenu]; return;
        case BriefingCommandNone: break;
    }
    [_services drawMenuBackdrop];
}

- (void)browserFrame:(InputAction)actions {
    [_lan poll];
    NSMutableArray *list = [NSMutableArray array];
    for (LANServer *s in _lan.servers) if (![_services isOwnServer:s]) [list addObject:s];
    [_browser showServers:list];
    switch ([_browser handle:actions]) {
        case BrowserCommandJoin: [_services joinServer:_browser.selected.address]; break;
        case BrowserCommandBack:
            [_services cancelJoin];
            if (_browserReturn == FrontScreenMainMenu) [self showMainMenu];
            else [self present:_browserReturn];
            break;
        default: break;
    }
    [_services drawMenuBackdrop];
}

@end
