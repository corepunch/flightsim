#import "UI.h"
#import "Story.h"
#import "Audio.h"
#import "Shared.h"
#import "Common.h"

@interface ServerBrowser () <UIMotionScene>
@end

@implementation ServerBrowser {
    SKNode *_stage, *_root;
    UITransition _transition;
    // From the entrance until the first frame's input: the server list and
    // status arrive in that frame, and rebuilding for them keeps the entrance.
    BOOL _entering;
    UIHover *_hover;
    NSArray<LANServer *> *_servers;
    NSUInteger _index;
    NSString *_status;
    NSString *_signature;
    CGSize _laidOut;
    ScreenInsets _usedInsets;
    CGRect _backRect, _joinRect;
    UIListView *_list;
    CGPoint _pendingPoint;
    BOOL _hasPendingPoint;
    BOOL _createSelected, _createRequested;
    TitleBar *_bar;
    InputAction _barInput;
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.backgroundColor = [SKColor clearColor];
        self.speed = 1 / UIMotionTimeScale();
        _hover = [UIHover new];
        _stage = [SKNode node];
        _root = [SKNode node];
        [_stage addChild:_root];
        [self addChild:_stage];
        _servers = @[];
        _createSelected = YES;
    }
    return self;
}

- (LANServer *)selected { return !_createSelected && _index < _servers.count ? _servers[_index] : nil; }

- (NSString *)status { return _status; }

- (void)setStatus:(NSString *)status {
    if ([_status ?: @"" isEqualToString:status ?: @""]) return;
    _status = [status copy];
    _signature = nil;
    [self rebuild];
}

- (void)pointerDown:(CGPoint)point { [_bar beginAt:PointMultiply(point,self.size)]; }
- (void)pointerUp:(CGPoint)point { [_bar endPress]; }
- (void)pointerCancel { [_bar endPress]; }
- (void)pointerHover:(CGPoint)point { [_hover queuePointAtFraction:point]; }

- (void)pointerClick:(CGPoint)point {
    _pendingPoint = point;
    _hasPendingPoint = YES;
}

- (void)showServers:(NSArray<LANServer *> *)servers {
    NSMutableString *sig = [NSMutableString string];
    for (LANServer *s in servers) [sig appendFormat:@"%@|%@|%d|%@;", s.address, s.name, s.players, s.levelName ?: @"-"];
    for (LANServer *s in servers) if (s.pilots) [sig appendString:LANMatchSettingsEncode(s.settings)];
    if ([sig isEqualToString:_signature ?: @""] && CGSizeEqualToSize(_laidOut, self.size) && _signature) return;
    _signature = sig;
    LANServer *was = self.selected;
    _servers = servers;
    _index = 0;
    for (NSUInteger i = 0; i < servers.count; i++) if ([servers[i].address isEqual:was.address]) _index = i;
    [self rebuild];
}

- (void)rebuild {
    BOOL intro = _transition == UITransitionIntro || _entering;
    _transition = UITransitionNone;
    [_root removeAllChildren];
    [_hover reset];
    _laidOut = self.size;
    _usedInsets = self.contentInsets;
    CGSize s = self.size;
    _stage.position = CGPointMake(s.width / 2, s.height / 2);
    _root.position = CGPointMake(-s.width / 2, -s.height / 2);
    [_root addChild:[self motionBackdropWithSize:s]];

    // Commands stay in the title bar; the body owns games and connection status.
    ScreenInsets safe = self.contentInsets;
#if TARGET_OS_IOS
    if (self.view) safe = self.view.safeAreaInsets;
#endif
    ScreenRegions regions = ScreenRegionsMake(s, safe);
    __weak ServerBrowser *owner = self;
    UIBarAction *back = [UIBarAction title:L10n(@"browser.back") icon:UICommandBack accent:UIInk handler:^{
        ServerBrowser *screen = owner; if (screen) screen->_barInput |= InputActionBack;
    }];
    UIBarAction *join = [UIBarAction title:L10n(@"browser.join") icon:UICommandJoin accent:UIAmber handler:^{
        ServerBrowser *screen = owner; if (screen) screen->_barInput |= InputActionConfirm;
    }];
    UIBarAction *create = [UIBarAction title:L10n(@"browser.create") icon:UICommandCreate accent:_createSelected ? UIAmber : UIInk handler:^{
        ServerBrowser *screen = owner; if (screen) screen->_createRequested = YES;
    }];
    TitleBar *bar = [[TitleBar alloc] initWithHeader:regions.header compact:regions.compact back:back
        title:L10n(@"browser.title") kicker:L10n(@"browser.kicker") actions:self.selected ? @[join, create] : @[create]];
    _bar = bar;
    _backRect = [bar rectForAction:back]; _joinRect = [bar rectForAction:join]; _createRect = [bar rectForAction:create];
    [_root addChild:bar];
    [bar registerHover:_hover];

    NSMutableArray<ListEntry *> *entries = [NSMutableArray arrayWithCapacity:_servers.count];
    for (LANServer *server in _servers) {
        const LevelDef *level = LevelNamed(server.levelName);
        [entries addObject:ServerEntry(server.name, server.players, server.maxPlayers, level ? level->title : nil,
                                       server.pilots ? LANMatchSummary(server.settings) : nil)];
    }
    BrowserSelection selection = { .create = _createSelected, .index = _index };
    _list = [[UIListView alloc] initWithList:ServerListModel(entries, selection, _status) region:regions.body
                                       style:UIListScrolling compact:regions.compact];
    [_root addChild:_list];
    [_list registerHover:_hover];
    NSArray<SKLabelNode *> *rows = _list.titleLabels;

    if (!intro) return;
    for (NSUInteger i = 0; i < rows.count; i++) {
        UIMotionSlideIn(rows[i], CGVectorMake(-24, 0), 0.25 + i * 0.04, 0.28);
        UIMotionDecode(rows[i], 0.25 + i * 0.04, 0.35);
    }
    [bar revealAfter:0.05];

}

- (void)motionEnter {
    _hasPendingPoint = NO;
    [_stage removeAllActions];
    _stage.alpha = 1;
    [_stage setScale:1];
    _transition = UITransitionIntro;
    _entering = YES;
    [self rebuild];
}

// The shade over whatever is behind the front end.
- (SKNode *)motionBackdropWithSize:(CGSize)size {
    UILayout *layout = [UILayout named:@"browser"];
    CGFloat opacity = layout ? [layout metric:@"shade" flags:nil fallback:0.72] : 0.72;
    SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:[SKColor colorWithWhite:0 alpha:opacity] size:size];
    shade.anchorPoint = CGPointZero;
    return shade;
}

- (NSTimeInterval)motionExit {
    if (UIMotionReduced()) {
        [_stage runAction:[SKAction fadeOutWithDuration:0.15]];
        return 0.15;
    }
    [_stage runAction:[SKAction group:@[
        UIEased([SKAction scaleTo:1.025 duration:0.24], UICurveIn),
        [SKAction sequence:@[
            [SKAction fadeAlphaTo:0.45 duration:0.04], [SKAction fadeAlphaTo:0.85 duration:0.03],
            [SKAction fadeOutWithDuration:0.17],
        ]],
    ]]];
    return 0.24;
}

- (void)update:(NSTimeInterval)currentTime {
    if (!CGSizeEqualToSize(_laidOut, self.size) || memcmp(&_usedInsets, &_contentInsets, sizeof _usedInsets)) [self rebuild];
}

- (CGRect)joinRect { return _joinRect; }
- (CGRect)serverRows { return _list.rowsRect; }
- (void)pointerScroll:(CGFloat)delta at:(CGPoint)point {
    CGPoint at = CGPointMake(point.x * self.size.width, point.y * self.size.height);
    if (!CGRectContainsPoint(_list.rowsRect, at) || !_servers.count) return;
    NSInteger next = (NSInteger)_index + (delta > 0 ? 1 : -1);
    _index = (NSUInteger)MAX(0, MIN((NSInteger)_servers.count - 1, next));
    _createSelected = NO;
    [self rebuild];
}

- (BrowserCommand)handle:(InputAction)actions {
    _entering = NO;
    [_hover updateInScene:self];
    CGPoint click = CGPointMake(-1, -1);
    if (_hasPendingPoint) click = CGPointMake(_pendingPoint.x * self.size.width, _pendingPoint.y * self.size.height);
    _hasPendingPoint = NO;
    _barInput = 0; _createRequested = NO;
    if ([_bar activateAt:click]) actions |= _barInput;
    if (_createRequested) return BrowserCommandCreate;
    NSUInteger row = [_list entryAt:click];
    if (row != NSNotFound) { _index = row; _createSelected = NO; [[GameAudio shared] play:@"ui-hover"]; [self rebuild]; }
    if (actions & InputActionBack) { [[GameAudio shared] play:@"ui-back"]; return BrowserCommandBack; }
    if (actions & (InputActionUp | InputActionDown)) [[GameAudio shared] play:@"ui-hover"];
    if (actions & InputActionConfirm) {
        [[GameAudio shared] play:@"ui-confirm"];
        return _createSelected || !_servers.count ? BrowserCommandCreate : BrowserCommandJoin;
    }
    NSInteger step = (actions & InputActionDown ? 1 : 0) - (actions & InputActionUp ? 1 : 0);
    if (step && _servers.count) {
        BrowserSelection moved = BrowserSelectionMove((BrowserSelection){ _createSelected, _index }, _servers.count, step);
        _createSelected = moved.create;
        if (!moved.create) _index = moved.index;
        [self rebuild];
    }
    return BrowserCommandNone;
}

@end
