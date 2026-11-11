#import "UI.h"
#import "Audio.h"
#import "Story.h"

// The setup form owns scrolling and keeps its selected row visible. Its
// controls are the same production controls used by flight settings.
@interface LANSetupPanel : SKCropNode
- (instancetype)initWithRegion:(CGRect)region settings:(LANMatchSettings)settings change:(void (^)(LANMatchSettings))change;
@property (nonatomic, readonly) UISettingsForm *form;
- (void)click:(CGPoint)point;
- (void)scroll:(CGFloat)delta;
- (void)select:(NSUInteger)index;
- (void)adjust:(NSInteger)direction;
@end
@implementation LANSetupPanel {
    CGRect _region;
    CGFloat _offset;
    LANMatchSettings _settings;
    void (^_change)(LANMatchSettings);
}
- (instancetype)initWithRegion:(CGRect)region settings:(LANMatchSettings)settings change:(void (^)(LANMatchSettings))change {
    if ((self = [super init])) {
        _region=region; _settings=settings; _change=[change copy];
        SKShapeNode *mask = [SKShapeNode shapeNodeWithRect:region]; mask.fillColor=SKColor.whiteColor; mask.strokeColor=SKColor.whiteColor;
        self.maskNode=mask;
        [self rebuild];
    }
    return self;
}
- (void)cycle:(NSUInteger)index direction:(NSInteger)direction {
    _settings = LANMatchSettingsStep(_settings, index, direction);
    if (_change) _change(_settings);
    [self rebuild]; [self select:index];
}
- (void)rebuild {
    NSUInteger selected=_form ? _form.selectedIndex : 0;
    [self removeAllChildren];
    NSMutableArray *items=[NSMutableArray array];
    __weak LANSetupPanel *owner=self;
    NSArray<SettingRow *> *rows = LANSetupRows(_settings);
    for (NSUInteger i = 0; i < rows.count; i++) {
        UISettingItem *item = [UISettingItem choice:rows[i].title value:rows[i].value detail:nil
                                             action:^{ [owner cycle:i direction:1]; }];
        item.enabled = rows[i].enabled;
        [items addObject:item];
    }
    _form=[[UISettingsForm alloc] initWithItems:items width:CGRectGetWidth(_region) compact:YES];
    _form.selectedIndex=selected;
    [self addChild:_form]; [self scroll:0];
}
- (void)scroll:(CGFloat)delta {
    _offset=MIN(MAX(0,_offset+delta),MAX(0,_form.height-CGRectGetHeight(_region)));
    _form.position=UIScrollContentPosition(_region,CGSizeMake(CGRectGetWidth(_region),_form.height),_offset);
}
- (void)select:(NSUInteger)index {
    _form.selectedIndex=index;
    if (_form.height<=CGRectGetHeight(_region)) return;
    CGRect row=UnboxRect(_form.rowRects[_form.selectedIndex]);
    CGFloat top=CGRectGetMaxY(row)+_offset, bottom=CGRectGetMinY(row)+_offset;
    if (top>0) [self scroll:-top];
    else if (bottom < -CGRectGetHeight(_region)) [self scroll:-CGRectGetHeight(_region)-bottom];
}
- (void)adjust:(NSInteger)direction { [self cycle:_form.selectedIndex direction:direction]; }
- (void)click:(CGPoint)point {
    if (!CGRectContainsPoint(_region,point)) return;
    [_form clickAt:[_form convertPoint:point fromNode:self]];
}
@end

// The result uses the server's ordering and local row index, including when
// two pilots choose the same name.
@interface LANScoreboard : TextViewport
- (instancetype)initWithRegion:(CGRect)region result:(LANMatchResult)result points:(NSUInteger)points compact:(BOOL)compact;
@end

@implementation LANScoreboard
- (instancetype)initWithRegion:(CGRect)region result:(LANMatchResult)result points:(NSUInteger)points compact:(BOOL)compact {
    CGFloat width = MAX(1, MIN(720, CGRectGetWidth(region) - 20));
    UIReportView *report = [[UIReportView alloc] initWithReport:MatchReport(result, ProgressPilotScore(), points)
                                                          width:width compact:compact];
    report.position = UIScrollContentPosition(region, report.contentSize, 0);
    SKNode *content = [SKNode node];
    [content addChild:report];
    return [super initWithRect:region content:content];
}
@end

@interface LANGame () <UIMotionScene>
@end
@implementation LANGame {
    SKNode *_root;
    UIHover *_hover;
    NSArray<NSString *> *_lines;
    BOOL _clicked, _confirmEnabled;
    CGPoint _click;
    CGSize _laidOut;
    ScreenInsets _usedInsets;
    TitleBar *_bar;
    InputAction _barInput;
    BOOL _settingsRequested;
    LANSetupPanel *_setup;
    NSInteger _settingIndex;
    LANMatchResult _result;
    NSString *_resultArena;
    NSUInteger _points;
    LANScoreboard *_scoreboard;
    CGFloat _scoreboardOffset;
}
- (instancetype)initWithSize:(CGSize)size {
    if ((self=[super initWithSize:size])) {
        self.scaleMode=SKSceneScaleModeResizeFill; self.backgroundColor=SKColor.clearColor;
        self.speed=1/UIMotionTimeScale(); _root=[SKNode node]; [self addChild:_root]; _hover=[UIHover new];
        _settings=LANMatchSettingsCurrent(); _settingIndex=-1; [self showSetup];
    }
    return self;
}
- (UISettingsForm *)settingsForm { return _setup.form; }
- (void)showSetup {
    _editingLobby=_stage==LANGameLobby && _hosting; _stage=LANGameSetup; _hosting=YES;
    _lines=@[]; _clicked=NO; _settingIndex=-1; [self rebuild];
}
- (void)showPilots:(NSArray<NSString *> *)pilots {
    if (_stage==LANGameLobby && _hosting && [_lines isEqual:pilots]) return;
    _settings=LANMatchSettingsCurrent();
    _stage=LANGameLobby; _hosting=YES; _editingLobby=NO; _lines=[pilots copy]; [self rebuild];
}
- (void)showGuestLobby:(LANServer *)server {
    NSArray *pilots=server.pilots ?: @[];
    BOOL same=_stage==LANGameLobby && !_hosting && [_lines isEqual:pilots] &&
        [LANMatchSettingsEncode(_settings) isEqualToString:LANMatchSettingsEncode(server.settings)];
    _settings=server.settings; _stage=LANGameLobby; _hosting=NO; _lines=[pilots copy];
    if (!same) [self rebuild];
}
- (void)showResults:(LANMatchResult)result arena:(NSString *)arena points:(NSUInteger)points hosting:(BOOL)hosting {
    _stage = LANGameResults;
    _hosting = hosting;
    _result = result;
    _resultArena = [arena copy];
    _points = points;
    _scoreboardOffset = 0;
    _clicked = NO;
    [self rebuild];
}
- (void)refreshProgress {
    if (_stage == LANGameResults) [self rebuild];
}
- (void)rebuild {
    [_root removeAllChildren]; [_hover reset]; _setup=nil; _scoreboard=nil; _statusLabel=nil;
    _laidOut=self.size; _usedInsets=self.contentInsets;
    [_root addChild:[self motionBackdropWithSize:self.size]];
    BOOL compact=ScreenRegionsMake(self.size,self.contentInsets).compact;
    ScreenRegions regions=ScreenRegionsMake(self.size,self.contentInsets);
    _confirmEnabled=_stage==LANGameSetup || (_stage==LANGameLobby && _hosting && _lines.count>=2) || _stage==LANGameResults;
    NSString *action=L10n(_stage==LANGameSetup ? (_editingLobby ? @"browser.save" : @"browser.create") : _stage==LANGameLobby ? @"browser.start" : @"browser.lobby");
    __weak LANGame *owner=self;
    UIBarAction *back=[UIBarAction title:L10n(@"browser.back") icon:UICommandBack accent:UIInk handler:^{ LANGame *s=owner; if(s) s->_barInput|=InputActionBack; }];
    UIBarAction *confirm=[UIBarAction title:action icon:_stage==LANGameSetup ? (_editingLobby ? UICommandSave : UICommandCreate) : _stage==LANGameLobby ? UICommandStart : UICommandNext accent:UIAmber handler:^{ LANGame *s=owner; if(s) s->_barInput|=InputActionConfirm; }];
    confirm.enabled=_confirmEnabled;
    UIBarAction *settings=[UIBarAction title:L10n(@"browser.settings") icon:UICommandSettings accent:UIInk handler:^{ LANGame *s=owner; if(s) s->_settingsRequested=YES; }];
    NSArray *actions=_hosting && _stage==LANGameLobby ? @[confirm,settings] : _hosting || _stage==LANGameResults ? @[confirm] : @[];
    const LevelDef *arena = _resultArena.length && _stage == LANGameResults ? LevelNamed(_resultArena) : NULL;
    _bar=[[TitleBar alloc] initWithHeader:regions.header compact:compact back:back
        title:L10n(_stage==LANGameSetup ? @"browser.setup" : _stage==LANGameLobby ? @"browser.lobby" : @"browser.results")
        kicker:arena ? L10nExpand(arena->title) : L10n(@"browser.kicker") actions:actions];
    _backRect=[_bar rectForAction:back]; _confirmRect=[_bar rectForAction:confirm];
    [_root addChild:_bar]; [_bar registerHover:_hover]; _bodyRect=regions.body;
    CGFloat width=MIN(900,CGRectGetWidth(_bodyRect));
    CGRect content=CGRectMake(CGRectGetMidX(_bodyRect)-width/2,CGRectGetMinY(_bodyRect),width,CGRectGetHeight(_bodyRect));
    if (_stage==LANGameSetup) {
        _setup=[[LANSetupPanel alloc] initWithRegion:content settings:_settings change:^(LANMatchSettings changed) { LANGame *screen=owner; if (screen) screen->_settings=changed; }];
        [_root addChild:_setup]; _pilotRects=@[];
    } else if (_stage == LANGameResults) {
        _scoreboard = [[LANScoreboard alloc] initWithRegion:content result:_result points:_points compact:compact];
        [_root addChild:_scoreboard];
        [self scrollScoreboard:0];
        _pilotRects = @[];
    } else {
        UIListView *lobby = [[UIListView alloc] initWithList:LobbyModel(_lines, _hosting, _settings) region:content
                                                       style:UIListFitted compact:compact];
        [_root addChild:lobby];
        _pilotRects = lobby.rowRects;
        _statusLabel = lobby.messageLabel;
    }
}
- (SKNode *)motionBackdropWithSize:(CGSize)size {
    if (_stage == LANGameResults) return UIResultsBackdrop(size);
    SKSpriteNode *shade=[SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIBackground,0.96) size:size]; shade.anchorPoint=CGPointZero; return shade;
}
- (void)motionEnter { [_root removeAllActions]; _root.position=CGPointZero; _root.alpha=1; _clicked=NO; [self rebuild]; UIMotionSlideIn(_root,CGVectorMake(0,-12),0,0.25); }
- (NSTimeInterval)motionExit { [_root runAction:[SKAction fadeOutWithDuration:0.18]]; return 0.18; }
- (void)pointerDown:(CGPoint)point { [_bar beginAt:PointMultiply(point,self.size)]; }
- (void)pointerUp:(CGPoint)point { [_bar endPress]; }
- (void)pointerCancel { [_bar endPress]; }
- (void)pointerHover:(CGPoint)point { [_hover queuePointAtFraction:point]; }
- (void)pointerClick:(CGPoint)point { _click=point; _clicked=YES; }
- (void)scrollScoreboard:(CGFloat)delta {
    _scoreboardOffset = MIN(_scoreboard.limit, MAX(0, _scoreboardOffset + delta));
    [_scoreboard showOffset:_scoreboardOffset];
}
- (void)pointerScroll:(CGFloat)delta at:(CGPoint)point {
    if (!CGRectContainsPoint(_bodyRect,PointMultiply(point,self.size))) return;
    [_setup scroll:delta];
    [self scrollScoreboard:delta];
}
- (LANGameCommand)handle:(InputAction)actions {
    if(!CGSizeEqualToSize(_laidOut,self.size)||memcmp(&_usedInsets,&_contentInsets,sizeof _usedInsets)) [self rebuild];
    [_hover updateInScene:self]; _settingsRequested=NO;
    BOOL headerConfirm=NO;
    if(_clicked) {
        CGPoint at=PointMultiply(_click,self.size); _clicked=NO; _barInput=0;
        BOOL header=[_bar activateAt:at]; actions|=_barInput; headerConfirm=(_barInput&InputActionConfirm)!=0;
        if(!header) [_setup click:at];
    }
    if(_settingsRequested) return LANGameCommandSettings;
    if(actions&InputActionBack) { [[GameAudio shared] play:@"ui-back"]; return LANGameCommandBack; }
    if (_stage == LANGameResults) {
        if (actions & InputActionUp) [self scrollScoreboard:-44];
        if (actions & InputActionDown) [self scrollScoreboard:44];
    }
    if(_stage==LANGameSetup) {
        if(actions&(InputActionDown|InputActionUp)) {
            NSInteger count=(NSInteger)_setup.form.rowRects.count;
            _settingIndex=actions&InputActionDown ? (_settingIndex+2)%(count+1)-1 : (_settingIndex+count+1)%(count+1)-1;
            if(_settingIndex>=0) [_setup select:(NSUInteger)_settingIndex];
        }
        if(_settingIndex>=0 && ((actions&(InputActionLeft|InputActionRight)) || ((actions&InputActionConfirm)&&!headerConfirm))) {
            [_setup adjust:actions&InputActionLeft ? -1 : 1];
            return LANGameCommandNone;
        }
    }
    if((actions&InputActionConfirm)&&_confirmEnabled) { [[GameAudio shared] play:@"ui-confirm"]; return LANGameCommandConfirm; }
    return LANGameCommandNone;
}
@end
