#import "ServerBrowser.h"
#import "GameAudio.h"
#import "Assets.h"
#import "UIStyle.h"
#import "UIMotion.h"
#import "Localization.h"

static SKColor *Ink(CGFloat a) { return UIColorWithOpacity(UIInk, a); }
static SKColor *Amber(CGFloat a) { return UIColorWithOpacity(UIAmber, a); }

static SKLabelNode *Text(CGFloat size, SKColor *c) {
    return UIInterfaceLabel(size, c, SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeTop);
}

@interface ServerBrowser () <UIMotionScene>
@end

@implementation ServerBrowser {
    SKNode *_stage, *_root;
    UITransition _transition;
    UIHover *_hover;
    NSArray<LANServer *> *_servers;
    NSUInteger _index;
    NSString *_status;
    NSString *_signature;
    CGSize _laidOut;
    CGRect _backRect, _joinRect, _serverRows;
    NSUInteger _firstVisible;
    CGPoint _pendingPoint;
    BOOL _hasPendingPoint;
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
    }
    return self;
}

- (LANServer *)selected { return _index < _servers.count ? _servers[_index] : nil; }

- (void)setStatus:(NSString *)status {
    _status = [status copy];
    _signature = nil;
    [self rebuild];
}

- (void)hoverAtFraction:(CGPoint)point { [_hover queuePointAtFraction:point]; }

- (void)queueClickAtFraction:(CGPoint)point {
    @synchronized (self) {
        _pendingPoint = point;
        _hasPendingPoint = YES;
    }
}

- (void)showServers:(NSArray<LANServer *> *)servers {
    NSMutableString *sig = [NSMutableString string];
    for (LANServer *s in servers) [sig appendFormat:@"%@|%@|%d|%d;", s.address, s.name, s.players, s.missionIndex];
    if ([sig isEqualToString:_signature ?: @""] && CGSizeEqualToSize(_laidOut, self.size) && _signature) return;
    _signature = sig;
    LANServer *was = self.selected;
    _servers = servers;
    _index = 0;
    for (NSUInteger i = 0; i < servers.count; i++) if ([servers[i].address isEqual:was.address]) _index = i;
    [self rebuild];
}

- (void)rebuild {
    BOOL intro = _transition == UITransitionIntro;
    _transition = UITransitionNone;
    [_root removeAllChildren];
    [_hover reset];
    _laidOut = self.size;
    CGSize s = self.size;
    _stage.position = CGPointMake(s.width / 2, s.height / 2);
    _root.position = CGPointMake(-s.width / 2, -s.height / 2);
    NSMutableArray<SKLabelNode *> *rows = [NSMutableArray array], *notes = [NSMutableArray array];
    SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:[SKColor colorWithWhite:0 alpha:0.72] size:s];
    shade.anchorPoint = CGPointZero;
    [_root addChild:shade];

    CGFloat x = MIN(110, s.width * 0.08), y = s.height - MIN(90, s.height * 0.14);
    SKLabelNode *kicker = Text(14, Ink(0.6));
    kicker.text = L10n(@"browser.kicker");
    kicker.position = CGPointMake(x, y);
    [_root addChild:kicker];
    SKLabelNode *title = Text(34, Ink(1));
    title.text = L10n(@"browser.title");
    title.position = CGPointMake(x, y - 26);
    [_root addChild:title];

    y -= 84;
    if (!_servers.count) {
        SKLabelNode *none = Text(17, Ink(0.55));
        none.text = L10n(@"browser.searching");
        none.name = @"searching";
        none.position = CGPointMake(x, y);
        [_root addChild:none];
    }
    CGFloat rowHeight = 36, width = s.width - 2 * x;
    NSUInteger visible = MIN(_servers.count, (NSUInteger)MAX(1, floor((y - 143) / rowHeight)));
    _firstVisible = visible && _index >= visible ? _index - visible + 1 : 0;
    _serverRows = CGRectMake(x, y - visible * rowHeight, width, visible * rowHeight);
    for (NSUInteger i = _firstVisible; i < _firstVisible + visible; i++) {
        LANServer *srv = _servers[i];
        BOOL sel = i == _index;
        NSString *mission = srv.missionIndex >= 0 ? CampaignMission((NSUInteger)srv.missionIndex)[@"title"] : nil;
        SKLabelNode *l = Text(16, sel ? Amber(1) : Ink(0.85));
        l.text = L10nFormat(@"browser.row", sel ? @">" : @" ", srv.name, srv.players, srv.maxPlayers,
                            mission ? L10nFormat(@"browser.flying", mission) : L10n(@"browser.in_menus"), srv.address);
        l.numberOfLines = 1;
        l.preferredMaxLayoutWidth = width;
        l.lineBreakMode = NSLineBreakByTruncatingTail;
        l.position = CGPointMake(x, y - (i - _firstVisible) * rowHeight);
        [_root addChild:l];
        [rows addObject:l];
    }

    NSArray *lines = @[
        _status ?: @"",
        _hostLine ?: @"",
        L10n(s.width >= 850 ? @"browser.help_wide" : @"browser.help"),
    ];
    for (NSUInteger i = 0; i < lines.count; i++) {
        SKLabelNode *l = Text(i == 0 ? 14 : 12, i == 0 ? Amber(1) : Ink(0.55));
        l.text = lines[i];
        l.numberOfLines = 1;
        l.preferredMaxLayoutWidth = width;
        l.lineBreakMode = NSLineBreakByTruncatingTail;
        l.position = CGPointMake(x, 130 - i * 20);
        [_root addChild:l];
        [notes addObject:l];
    }
    _backRect = CGRectMake(x, 20, 145, 44);
    _joinRect = self.selected ? CGRectMake(s.width - x - 145, 20, 145, 44) : CGRectZero;
    SKNode *back = UIActionButton(_backRect, L10n(@"browser.back"), UIInk);
    [_root addChild:back];
    [_hover addButton:back rect:_backRect accent:UIInk];
    SKNode *join = self.selected ? UIActionButton(_joinRect, L10n(@"browser.join"), UIAmber) : nil;
    if (join) {
        [_root addChild:join];
        [_hover addButton:join rect:_joinRect accent:UIAmber];
    }
    if (!intro) return;
    UIMotionFlickerIn(shade, 0);
    UIMotionDecode(kicker, 0.05, 0.4);
    UIMotionDecode(title, 0.12, 0.45);
    for (NSUInteger i = 0; i < rows.count; i++) {
        UIMotionSlideIn(rows[i], CGVectorMake(-24, 0), 0.25 + i * 0.04, 0.28);
        UIMotionDecode(rows[i], 0.25 + i * 0.04, 0.35);
    }
    for (SKLabelNode *note in notes) UIMotionFlickerIn(note, 0.4);
    UIMotionSlideIn(back, CGVectorMake(0, -44), 0.25, 0.32);
    if (join) UIMotionSlideIn(join, CGVectorMake(0, -44), 0.3, 0.32);
    if (!rows.count) for (SKNode *child in _root.children)
        if ([child isKindOfClass:SKLabelNode.class] && [child.name isEqualToString:@"searching"]) {
            UIMotionDecode((SKLabelNode *)child, 0.25, 0.5);
            [child runAction:UIAfter(0.8, [SKAction repeatActionForever:[SKAction sequence:@[
                [SKAction fadeAlphaTo:0.35 duration:0.8], [SKAction fadeAlphaTo:1 duration:0.8],
            ]]])];
        }
}

- (void)motionEnter {
    @synchronized (self) { _hasPendingPoint = NO; }
    [_stage removeAllActions];
    _stage.alpha = 1;
    [_stage setScale:1];
    _transition = UITransitionIntro;
    [self rebuild];
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
    if (!CGSizeEqualToSize(_laidOut, self.size)) [self rebuild];
}

- (BrowserCommand)handle:(InputAction)actions {
    [_hover updateInScene:self];
    CGPoint click = CGPointMake(-1, -1);
    @synchronized (self) {
        if (_hasPendingPoint) click = CGPointMake(_pendingPoint.x * self.size.width, _pendingPoint.y * self.size.height);
        _hasPendingPoint = NO;
    }
    if (CGRectContainsPoint(_backRect, click)) actions |= InputActionBack;
    else if (CGRectContainsPoint(_joinRect, click)) actions |= InputActionConfirm;
    else if (CGRectContainsPoint(_serverRows, click)) {
        NSUInteger row = _firstVisible + (NSUInteger)((CGRectGetMaxY(_serverRows) - click.y) / 36);
        if (row < _servers.count) { _index = row; [[GameAudio shared] play:@"ui-hover"]; [self rebuild]; }
    }
    if (actions & InputActionBack) { [[GameAudio shared] play:@"ui-back"]; return BrowserCommandBack; }
    if (actions & (InputActionUp | InputActionDown)) [[GameAudio shared] play:@"ui-hover"];
    if (actions & InputActionConfirm) [[GameAudio shared] play:_servers.count ? @"ui-confirm" : @"ui-alert"];
    if (_servers.count) {
        if (actions & InputActionUp) { _index = (_index + _servers.count - 1) % _servers.count; [self rebuild]; }
        if (actions & InputActionDown) { _index = (_index + 1) % _servers.count; [self rebuild]; }
        if (actions & InputActionConfirm) return BrowserCommandJoin;
    }
    return BrowserCommandNone;
}

@end
