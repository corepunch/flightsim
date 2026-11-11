#import "UI.h"
#import "Story.h"
#import "Net.h"
#import "Shared.h"
#import "Common.h"

typedef NS_ENUM(NSInteger, FrontScreen) { FrontScreenMainMenu, FrontScreenCampaign, FrontScreenBrowser, FrontScreenLAN };

@implementation FrontEnd {
    __weak id<UIServices> _services;
    MainMenu *_mainMenu;
    Briefing *_briefing;
    ServerBrowser *_browser;
    LANBrowser *_lan;
    LANGame *_lanGame;
    NSString *_browserStatus;
    FrontScreen _screen, _browserReturn;
    LANServer *_joinedGame;
    double _lastJoinedQuery;
    NSUInteger _progressRevision;
}

- (instancetype)initWithSize:(CGSize)size services:(id<UIServices>)services {
    if ((self = [super init])) {
        _services = services;
        _mainMenu = [[MainMenu alloc] initWithSize:size];
        _briefing = [[Briefing alloc] initWithSize:size];
        _browser = [[ServerBrowser alloc] initWithSize:size];
        _lanGame = [[LANGame alloc] initWithSize:size];
        _screen = FrontScreenMainMenu;
    }
    return self;
}

- (NSUInteger)levelCount { return CampaignMissions().count; }
- (void)setInput:(Input *)input { _input = input; _mainMenu.input = input; }

- (SKScene *)currentScreen {
    switch (_screen) {
        case FrontScreenMainMenu: return _mainMenu;
        case FrontScreenCampaign: return _briefing;
        case FrontScreenBrowser: return _browser;
        case FrontScreenLAN: return _lanGame;
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

- (MainMenuFacts)mainMenuFacts {
    NSUInteger index = [self campaignEntry];
    return (MainMenuFacts){
        .mission = index, .missionTitle = CampaignMissionAt(index).title, .score = ProgressPilotScore(),
        .started = ProgressHasStarted() || index > 0, .completed = ProgressCampaignCompleted(),
    };
}

- (void)prepareMainMenu {
    [_mainMenu showFacts:[self mainMenuFacts]];
    [_services startGameCenter];
}

- (void)prepareAfterBoot {
    _screen = FrontScreenMainMenu;
    _progressRevision = ProgressRevision();
    [self prepareMainMenu];
    [_briefing showListSelecting:ProgressUnlockedCount() - 1];
}

#pragma mark - Showing screens

- (void)stopBrowsing { [_lan stop]; _lan = nil; }

- (void)showMainMenu {
    [self stopBrowsing];
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
    if (!_lan) _lan = [_services makeLANBrowser];
    NSString *server = _services.connectedServer;
    if (server && ![_joinedGame.address.string isEqualToString:server]) {
        _joinedGame=[LANServer new]; _joinedGame.address=[NetAddress addressWithString:server port:PORT_SERVER];
        _joinedGame.settings=LANMatchSettingsDefault(); _lastJoinedQuery=-100;
    }
    [self setBrowserStatus:server ? L10nFormat(@"browser.connected", server) : @""];
    [self present:FrontScreenBrowser];
}

- (void)showLANResults:(LANMatchResult)result arena:(NSString *)arena hosting:(BOOL)hosting {
    NSUInteger points = ProgressRecordMatch(arena, result);
    [_lanGame showResults:result arena:arena points:points hosting:hosting];
    [self present:FrontScreenLAN];
}
- (void)showLANHost { [_lanGame showPilots:_services.hostedPilots]; [self present:FrontScreenLAN]; }

- (void)setBrowserStatus:(NSString *)status { _browserStatus = [status copy]; [_browser setStatus:status]; }

#pragma mark - Levels

- (void)fillLoadingCard:(Loading *)card level:(NSUInteger)index {
    CampaignMission *mission = CampaignMissionAt(index);
    MissionBriefing *b = mission.briefing;
    NSString *detail = b.stardate ? L10nFormat(@"loading.location_stardate", b.location ?: @"", b.stardate) : b.location;
    [card showTitle:mission.title kicker:L10nFormat(@"loading.mission_kicker", (unsigned long)index + 1) detail:detail];
}

- (NSString *)bannerForLevel:(NSUInteger)index { return CampaignMissionAt(index).title.uppercaseString; }

- (void)levelStarted:(NSUInteger)index remote:(BOOL)remote {
    if (!remote) ProgressMarkStarted();
}

- (void)flightStarted {
    [_briefing unload];
    [_mainMenu unload];
}

- (void)levelEnded:(NSUInteger)index success:(BOOL)success results:(NSArray<NSString *> *)results remote:(BOOL)remote {
    NSArray<ObjectiveReadout *> *objectives = MissionResultReadouts(results);
    NSUInteger stars = success ? ProgressResultStars(objectives) : 0, points = 0;
    BOOL finale = success && !remote && index < CampaignMissions().count && index + 1 == CampaignMissions().count;
    if (success && !remote) points = ProgressRecordResult(index, stars);
    [_briefing showDebrief:index success:success results:objectives stars:stars points:points campaignFinale:finale];
    [self present:FrontScreenCampaign];
}

- (void)levelLeft:(NSUInteger)index { [self showMissionsSelecting:index]; }

#pragma mark - Frame

- (void)frame:(InputAction)actions {
    NSUInteger revision = ProgressRevision();
    if (_progressRevision != revision) {
        _progressRevision = revision;
        if (_screen == FrontScreenMainMenu) [_mainMenu refreshFacts:[self mainMenuFacts]];
        else if (_screen == FrontScreenCampaign) [_briefing refreshProgress];
        else if (_screen == FrontScreenLAN) [_lanGame refreshProgress];
    }
    [_briefing showFriends:_services.missionFriends];
    switch (_screen) {
        case FrontScreenMainMenu: [self mainMenuFrame:actions]; break;
        case FrontScreenCampaign: [self campaignFrame:actions]; break;
        case FrontScreenBrowser: [self browserFrame:actions]; break;
        case FrontScreenLAN: [self lanFrame:actions]; break;
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
        case MainMenuCommandLeaderboards:
            [_services showLeaderboards];
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
    if (_joinedGame && _services.connectedServer && _services.time-_lastJoinedQuery>=2) {
        _lastJoinedQuery=_services.time; [_lan query:_joinedGame.address];
    }
    NSMutableArray *list = [NSMutableArray array];
    for (LANServer *s in _lan.servers) if (![_services isOwnServer:s]) [list addObject:s];
    [_browser showServers:list];
    if (_joinedGame && _services.waitingForLANMatch) {
        for (LANServer *server in list) if ([server.address isEqual:_joinedGame.address]) _joinedGame=server;
        [_lanGame showGuestLobby:_joinedGame]; [self present:FrontScreenLAN]; return;
    }
    NSString *diagnostic = @"";
    if (_lan.socketFailed) diagnostic = L10n(@"browser.socket_failed");
    else if (_lan.accessDenied) diagnostic = L10n(@"browser.permission");
    else if (_lan.searchError) diagnostic = L10nFormat(@"browser.search_failed", @(_lan.searchError.code));
    else if (!list.count && _lan.resolutionError) diagnostic = L10nFormat(@"browser.resolve_failed", @(_lan.resolutionError.code));
    else if (!list.count && _lan.hostUnreachable) diagnostic = L10n(@"browser.unreachable");
    else if (!list.count) diagnostic = L10n(@"browser.network_help");
    [_browser setStatus:_browserStatus.length ? _browserStatus : diagnostic];
    switch ([_browser handle:actions]) {
        case BrowserCommandJoin: _joinedGame=_browser.selected; [_services joinServer:_joinedGame.address]; break;
        case BrowserCommandCreate:
            [_services cancelJoin];
            [_lanGame showSetup];
            [self present:FrontScreenLAN];
            break;
        case BrowserCommandBack:
            [_services cancelJoin];
            [self stopBrowsing];
            if (_browserReturn == FrontScreenMainMenu) [self showMainMenu];
            else [self present:_browserReturn];
            break;
        default: break;
    }
    [_services drawMenuBackdrop];
}

- (void)lanFrame:(InputAction)actions {
    if (!_lanGame.hosting && _lanGame.stage==LANGameLobby) {
        [_lan poll];
        if (_services.time-_lastJoinedQuery>=2) { _lastJoinedQuery=_services.time; [_lan query:_joinedGame.address]; }
        for (LANServer *server in _lan.servers) if ([server.address isEqual:_joinedGame.address]) _joinedGame=server;
        if (!_services.connectedServer) { _joinedGame=nil; [self showBrowser]; return; }
        [_lanGame showGuestLobby:_joinedGame];
    }
    if (_services.hostingFailed) {
        [_services closeLANGame]; [self showBrowser];
        [self setBrowserStatus:L10n(@"browser.host_failed")]; return;
    }
    if (_lanGame.stage == LANGameLobby && _lanGame.hosting) [_lanGame showPilots:_services.hostedPilots];
    switch ([_lanGame handle:actions]) {
        case LANGameCommandBack:
            if (_lanGame.editingLobby && _lanGame.stage==LANGameSetup) { [_lanGame showPilots:_services.hostedPilots]; break; }
            _joinedGame=nil;
            [_services closeLANGame];
            [self showBrowser];
            _browserReturn = FrontScreenMainMenu;
            break;
        case LANGameCommandConfirm:
            if (_lanGame.stage == LANGameSetup) {
                LANMatchSettings settings=_lanGame.settings;
                settings.maxPilots=MAX(settings.maxPilots,(int)_services.hostedPilots.count);
                LANMatchSettingsSave(settings);
                if ([_services createLANGame]) [_lanGame showPilots:_services.hostedPilots];
                else { [self showBrowser]; [self setBrowserStatus:L10n(@"browser.host_failed")]; }
            } else if (_lanGame.stage == LANGameResults) {
                if (_lanGame.hosting) [_lanGame showPilots:_services.hostedPilots];
                else [self showBrowser];
            } else [_services startLANMatch];
            break;
        case LANGameCommandSettings: [_lanGame showSetup]; break;
        case LANGameCommandNone: break;
    }
    [_services drawMenuBackdrop];
}

@end
