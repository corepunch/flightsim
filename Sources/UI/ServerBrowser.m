#import "UI.h"
#import "Story.h"
#import "Audio.h"
#import "Shared.h"
#import "Common.h"

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
    CGRect _backRect, _joinRect, _serverRows;
    NSUInteger _firstVisible;
    CGFloat _rowHeight;
    CGPoint _pendingPoint;
    BOOL _hasPendingPoint;
    BOOL _createSelected;
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

- (void)setStatus:(NSString *)status {
    if ([_status ?: @"" isEqualToString:status ?: @""]) return;
    _status = [status copy];
    _signature = nil;
    [self rebuild];
}

- (void)pointerHover:(CGPoint)point { [_hover queuePointAtFraction:point]; }

- (void)pointerClick:(CGPoint)point {
    _pendingPoint = point;
    _hasPendingPoint = YES;
}

- (void)showServers:(NSArray<LANServer *> *)servers {
    NSMutableString *sig = [NSMutableString string];
    for (LANServer *s in servers) [sig appendFormat:@"%@|%@|%d|%@;", s.address, s.name, s.players, s.levelName ?: @"-"];
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
    NSMutableArray<SKLabelNode *> *rows = [NSMutableArray array], *notes = [NSMutableArray array];
    // Sizes and spacing from Resources/UI/menus/browser.json.
    UILayout *layout = [UILayout named:@"browser"];
    CGFloat (^M)(NSString *, CGFloat) = ^CGFloat(NSString *name, CGFloat fallback) { return layout ? [layout metric:name flags:nil fallback:fallback] : fallback; };
    [_root addChild:[self motionBackdropWithSize:s]];

    // Title bar on top, servers in the body, status and notes in the footer.
    ScreenInsets safe = self.contentInsets;
#if TARGET_OS_IOS
    if (self.view) safe = self.view.safeAreaInsets;
#endif
    NSArray *lines = @[
        _status ?: @"",
        _hostLine ?: @"",
        L10n(s.width >= M(@"wideHelpWidth", 850) ? @"browser.help_wide" : @"browser.help"),
    ];
    CGFloat step = M(@"notesStep", 20);
    ScreenRegions regions = ScreenRegionsMake(s, safe, lines.count * step);
    TitleBar *bar = [[TitleBar alloc] initWithHeader:regions.header compact:regions.compact];
    _backRect = [bar addBack:L10n(@"browser.back") accent:UIInk];
    _joinRect = self.selected ? [bar addAction:L10n(@"browser.join") accent:UIAmber minWidth:M(@"buttonWidth", 145)]
                              : CGRectZero;
    [bar setTitle:L10n(@"browser.title") kicker:L10n(@"browser.kicker")];
    [_root addChild:bar];
    [bar registerHover:_hover];

    CGRect body = regions.body;
    CGFloat x = CGRectGetMinX(body), y = CGRectGetMaxY(body), width = body.size.width;
    _createRect = CGRectMake(x, y - 48, MIN(width, 260), 48);
    SKShapeNode *create = UIActionButtonSized(_createRect, L10n(@"browser.create"), _createSelected ? UIAmber : UIInk, 17);
    [_root addChild:create];
    [_hover addButton:create rect:_createRect accent:UIAmber outline:NULL];
    y -= 66;
    body = RectFromEdges(x, CGRectGetMinY(body), CGRectGetMaxX(body), MAX(CGRectGetMinY(body), y));
    if (!_servers.count) {
        SKLabelNode *none = Text(M(@"emptySize", 17), Ink(0.55));
        none.text = L10n(@"browser.searching");
        none.name = @"searching";
        none.position = CGPointMake(x, y);
        [_root addChild:none];
    }
    CGFloat rowHeight = _rowHeight = M(@"rowHeight", 36);
    NSUInteger visible = MIN(_servers.count, (NSUInteger)MAX(1, floor(body.size.height / rowHeight)));
    _firstVisible = visible && _index >= visible ? _index - visible + 1 : 0;
    _serverRows = CGRectMake(x, y - visible * rowHeight, width, visible * rowHeight);
    for (NSUInteger i = _firstVisible; i < _firstVisible + visible; i++) {
        LANServer *srv = _servers[i];
        BOOL sel = !_createSelected && i == _index;
        const LevelDef *level = LevelNamed(srv.levelName);
        NSString *mission = level ? level->title : nil;
        SKLabelNode *l = Text(M(@"rowSize", 16), sel ? Amber(1) : Ink(0.85));
        l.text = L10nFormat(@"browser.row", sel ? @">" : @" ", srv.name, srv.players, srv.maxPlayers);
        l.numberOfLines = 1;
        l.preferredMaxLayoutWidth = width;
        l.lineBreakMode = NSLineBreakByTruncatingTail;
        l.position = CGPointMake(x, y - (i - _firstVisible) * rowHeight);
        [_root addChild:l];
        [rows addObject:l];
        SKLabelNode *detail = Text(12, Ink(0.55));
        detail.text = L10nFormat(@"browser.row_detail", mission ?: L10n(@"browser.in_menus"), srv.address);
        detail.numberOfLines = 1; detail.preferredMaxLayoutWidth = width;
        detail.lineBreakMode = NSLineBreakByTruncatingTail;
        detail.position = PointAdd(l.position, CGPointMake(0, -22));
        [_root addChild:detail];
    }

    CGRect footer = regions.footer;
    for (NSUInteger i = 0; i < lines.count; i++) {
        SKLabelNode *l = Text(i == 0 ? M(@"statusSize", 14) : M(@"noteSize", 12), i == 0 ? Amber(1) : Ink(0.55));
        l.text = lines[i];
        l.numberOfLines = 1;
        l.preferredMaxLayoutWidth = footer.size.width;
        l.lineBreakMode = NSLineBreakByTruncatingTail;
        l.position = CGPointMake(CGRectGetMinX(footer), CGRectGetMaxY(footer) - i * step);
        [_root addChild:l];
        [notes addObject:l];
    }
    if (!intro) return;
    for (NSUInteger i = 0; i < rows.count; i++) {
        UIMotionSlideIn(rows[i], CGVectorMake(-24, 0), 0.25 + i * 0.04, 0.28);
        UIMotionDecode(rows[i], 0.25 + i * 0.04, 0.35);
    }
    for (SKLabelNode *note in notes) UIMotionFlickerIn(note, 0.4);
    [bar revealAfter:0.05];
    if (!rows.count) for (SKNode *child in _root.children)
        if ([child isKindOfClass:SKLabelNode.class] && [child.name isEqualToString:@"searching"]) {
            UIMotionDecode((SKLabelNode *)child, 0.25, 0.5);
            [child runAction:UIAfter(0.8, [SKAction repeatActionForever:[SKAction sequence:@[
                [SKAction fadeAlphaTo:0.35 duration:0.8], [SKAction fadeAlphaTo:1 duration:0.8],
            ]]])];
        }
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
- (CGRect)serverRows { return _serverRows; }
- (void)pointerScroll:(CGFloat)delta at:(CGPoint)point {
    CGPoint at = CGPointMake(point.x * self.size.width, point.y * self.size.height);
    if (!CGRectContainsPoint(_serverRows, at) || !_servers.count) return;
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
    if (CGRectContainsPoint(_backRect, click)) actions |= InputActionBack;
    else if (CGRectContainsPoint(_createRect, click)) return BrowserCommandCreate;
    else if (CGRectContainsPoint(_joinRect, click)) actions |= InputActionConfirm;
    else if (CGRectContainsPoint(_serverRows, click)) {
        NSUInteger row = _firstVisible + (NSUInteger)((CGRectGetMaxY(_serverRows) - click.y) / MAX(_rowHeight, 1));
        if (row < _servers.count) { _index = row; _createSelected = NO; [[GameAudio shared] play:@"ui-hover"]; [self rebuild]; }
    }
    if (actions & InputActionBack) { [[GameAudio shared] play:@"ui-back"]; return BrowserCommandBack; }
    if (actions & (InputActionUp | InputActionDown)) [[GameAudio shared] play:@"ui-hover"];
    if (actions & InputActionConfirm) {
        [[GameAudio shared] play:@"ui-confirm"];
        return _createSelected || !_servers.count ? BrowserCommandCreate : BrowserCommandJoin;
    }
    if (_servers.count) {
        if (actions & InputActionUp) {
            if (_createSelected) { _createSelected = NO; _index = _servers.count - 1; }
            else if (_index == 0) _createSelected = YES;
            else _index--;
            [self rebuild];
        }
        if (actions & InputActionDown) {
            if (_createSelected) { _createSelected = NO; _index = 0; }
            else if (_index + 1 == _servers.count) _createSelected = YES;
            else _index++;
            [self rebuild];
        }
    }
    return BrowserCommandNone;
}

@end
