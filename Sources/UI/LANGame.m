#import "UI.h"
#import "Audio.h"

@interface LANGame () <UIMotionScene>
@end

@implementation LANGame {
    SKNode *_root;
    UIHover *_hover;
    NSArray<NSString *> *_lines;
    BOOL _hosting, _clicked;
    CGPoint _click;
    CGSize _laidOut;
    ScreenInsets _usedInsets;
    TitleBar *_bar;
    InputAction _barInput;
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.backgroundColor = SKColor.clearColor;
        self.speed = 1 / UIMotionTimeScale();
        _root = [SKNode node];
        [self addChild:_root];
        _hover = [UIHover new];
        [self showSetup];
    }
    return self;
}

- (void)showSetup { _stage = LANGameSetup; _lines = @[]; _hosting = YES; _clicked = NO; [self rebuild]; }
- (void)showPilots:(NSArray<NSString *> *)pilots {
    if (_stage == LANGameLobby && [_lines isEqual:pilots]) return;
    _stage = LANGameLobby; _hosting = YES; _lines = [pilots copy]; [self rebuild];
}
- (void)showResults:(NSArray<NSString *> *)results hosting:(BOOL)hosting {
    _stage = LANGameResults; _hosting = hosting; _lines = [results copy]; _clicked = NO; [self rebuild];
}

- (void)addLine:(NSString *)text at:(CGPoint)point width:(CGFloat)width size:(CGFloat)size accent:(BOOL)accent {
    SKLabelNode *label = UIInterfaceLabel(size, UIColorWithOpacity(accent ? UIAmber : UIInk, accent ? 1 : 0.85),
        SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeTop);
    label.text = text;
    label.numberOfLines = 1;
    label.preferredMaxLayoutWidth = MAX(1, width);
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.position = point;
    UIFitControlLabel(label, width);
    [_root addChild:label];
}

- (void)rebuild {
    [_root removeAllChildren]; [_hover reset];
    _laidOut = self.size; _usedInsets = self.contentInsets;
    [_root addChild:[self motionBackdropWithSize:self.size]];
    BOOL compact = ScreenRegionsMake(self.size, self.contentInsets, 0).compact;
    ScreenRegions regions = ScreenRegionsMake(self.size, self.contentInsets, [UIInfoBar heightCompact:compact]);
    BOOL enabled = _stage == LANGameSetup || (_stage == LANGameLobby && _lines.count >= 2) || (_stage == LANGameResults && _hosting);
    NSString *action = L10n(_stage == LANGameSetup ? @"browser.create" : _stage == LANGameLobby ? @"browser.start" : @"browser.again");
    __weak LANGame *owner = self;
    UIBarAction *back = [UIBarAction title:L10n(@"browser.back") accent:UIInk handler:^{
        LANGame *screen = owner; if (screen) screen->_barInput |= InputActionBack;
    }];
    UIBarAction *confirm = [UIBarAction title:action accent:UIAmber handler:^{
        LANGame *screen = owner; if (screen) screen->_barInput |= InputActionConfirm;
    }];
    _bar = [[TitleBar alloc] initWithHeader:regions.header compact:regions.compact back:back
        title:L10n(_stage == LANGameSetup ? @"browser.setup" : _stage == LANGameLobby ? @"browser.lobby" : @"browser.results")
        kicker:L10n(@"browser.kicker") actions:enabled ? @[confirm] : @[]];
    _backRect = [_bar rectForAction:back]; _confirmRect = [_bar rectForAction:confirm];
    [_root addChild:_bar]; [_bar registerHover:_hover];
    _bodyRect = regions.body;
    CGFloat width = CGRectGetWidth(_bodyRect), x = CGRectGetMinX(_bodyRect), top = CGRectGetMaxY(_bodyRect);
    [self addLine:L10n(@"browser.dogfight") at:CGPointMake(x, top) width:width size:regions.compact ? 18 : 26 accent:YES];
    [self addLine:L10n(@"browser.rules") at:CGPointMake(x, top - 34) width:width size:regions.compact ? 13 : 17 accent:NO];
    if (_stage == LANGameSetup) {
        [self addLine:L10n(@"browser.setup_help") at:CGPointMake(x, top - 76) width:width size:regions.compact ? 13 : 17 accent:NO];
        [self addLine:L10n(@"browser.setup_join") at:CGPointMake(x, top - 104) width:width size:regions.compact ? 13 : 17 accent:NO];
    } else {
        // Two columns on short phones keep eight pilots readable without scrolling.
        NSUInteger columns = CGRectGetHeight(_bodyRect) < 330 && width > 480 ? 2 : 1;
        CGFloat columnWidth = width / columns, start = top - 72;
        CGFloat rowHeight = MIN(32, MAX(20, (CGRectGetHeight(_bodyRect) - 72) / ceil((double)MAX(1, _lines.count) / columns)));
        NSUInteger rows = (NSUInteger)ceil((double)_lines.count / columns);
        for (NSUInteger i = 0; i < _lines.count; i++)
            [self addLine:_lines[i] at:CGPointMake(x + (rows ? i / rows : 0) * columnWidth, start - (rows ? i % rows : 0) * rowHeight)
                    width:columnWidth - 12 size:regions.compact ? 14 : 18 accent:i == 0];
    }
    NSString *help = L10n(_stage == LANGameLobby ? (_lines.count < 2 ? @"browser.waiting" : @"browser.ready") : @"browser.wifi");
    [_root addChild:[[UIInfoBar alloc] initWithRegion:regions.footer compact:regions.compact console:NO info:help action:nil]];
}

- (SKNode *)motionBackdropWithSize:(CGSize)size {
    SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIBackground, 0.96) size:size];
    shade.anchorPoint = CGPointZero; return shade;
}
- (void)motionEnter {
    [_root removeAllActions]; _root.position = CGPointZero; _root.alpha = 1; _clicked = NO; [self rebuild];
    UIMotionSlideIn(_root, CGVectorMake(0, -12), 0, 0.25);
}
- (NSTimeInterval)motionExit { [_root runAction:[SKAction fadeOutWithDuration:0.18]]; return 0.18; }
- (void)pointerHover:(CGPoint)point { [_hover queuePointAtFraction:point]; }
- (void)pointerClick:(CGPoint)point { _click = point; _clicked = YES; }
- (LANGameCommand)handle:(InputAction)actions {
    if (!CGSizeEqualToSize(_laidOut, self.size) || memcmp(&_usedInsets, &_contentInsets, sizeof _usedInsets)) [self rebuild];
    [_hover updateInScene:self];
    if (_clicked) {
        CGPoint at = CGPointMake(_click.x * self.size.width, _click.y * self.size.height); _clicked = NO;
        _barInput = 0; [_bar activateAt:at]; actions |= _barInput;
    }
    if (actions & InputActionBack) { [[GameAudio shared] play:@"ui-back"]; return LANGameCommandBack; }
    if ((actions & InputActionConfirm) && !CGRectIsEmpty(_confirmRect)) {
        [[GameAudio shared] play:@"ui-confirm"]; return LANGameCommandConfirm;
    }
    return LANGameCommandNone;
}
@end
