#import "UI.h"
#import "Audio.h"

static PauseCommand CommandFor(NSString *itemId) {
    static NSDictionary<NSString *, NSNumber *> *commands;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        commands = @{ @"resume": @(PauseCommandResume), @"camera": @(PauseCommandCamera), @"sound": @(PauseCommandSound),
                      @"restart": @(PauseCommandRestart), @"missions": @(PauseCommandMissions) };
    });
    return (PauseCommand)commands[itemId].integerValue;
}

@implementation PauseMenu {
    BOOL _remote, _cockpit;
    NSUInteger _selected;
    MenuModel *_menu;
    UILayoutResult *_layout;
    BOOL _hasClick;
    CGPoint _click;
    CGSize _layoutSize;
    ScreenInsets _usedInsets;
    InputGuide *_guideSnapshot;
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.backgroundColor = SKColor.clearColor;
    }
    return self;
}

- (void)showRemote:(BOOL)remote cockpit:(BOOL)cockpit {
    _remote = remote; _cockpit = cockpit; _selected = 0;
    _controlsPanel = nil;
    _hasClick = NO;
    [self rebuild];
}

- (UILayoutResult *)layout { return _layout; }

static NSString *ButtonKey(MenuChoice *choice) { return [@"items." stringByAppendingString:choice.identifier]; }

- (void)rebuild {
    [self removeAllChildren];
    _layoutSize = self.size;
    _usedInsets = self.contentInsets;
    _guideSnapshot = self.input.controlGuide;
    if (_controlsPanel) {
        SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIMenuNight, 0.97) size:self.size];
        shade.position = RectCenter(RectWithSize(self.size));
        [self addChild:shade];
        ScreenInsets insets = self.contentInsets;
#if TARGET_OS_IOS
        if (self.view) insets = self.view.safeAreaInsets;
#endif
        CGRect bounds = RectInsetEdges(RectWithSize(self.size), insets.left + 18, insets.top + 18,
                                      insets.right + 18, insets.bottom + 18);
        [_controlsPanel layoutIn:bounds sceneSize:self.size];
        [self addChild:_controlsPanel];
        return;
    }
    NSMutableSet *flags = [NSMutableSet set];
    if (_remote) [flags addObject:@"online"];
    if (_cockpit) [flags addObject:@"cockpit"];
    if (self.size.height < 440 && self.size.width >= 500) [flags addObject:@"short"];
    ScreenInsets safe = self.contentInsets;
#if TARGET_OS_IOS
    if (self.view) safe = self.view.safeAreaInsets;
#endif
    CGRect bounds = RectInsetEdges(RectWithSize(self.size), safe.left, safe.top, safe.right, safe.bottom);
    CGRect menuBounds = bounds, guideRegion = CGRectZero;
    if (_guideSnapshot && CGRectGetWidth(bounds) >= 680) {
        [flags addObject:@"withGuide"];
        if ([flags containsObject:@"short"]) [flags addObject:@"shortGuide"];
        CGFloat split = CGRectGetMinX(bounds) + CGRectGetWidth(bounds) * 0.51;
        menuBounds = RectFromEdges(CGRectGetMinX(bounds), CGRectGetMinY(bounds), split, CGRectGetMaxY(bounds));
        guideRegion = RectFromEdges(split + 18, CGRectGetMinY(bounds) + 24, CGRectGetMaxX(bounds) - 24, CGRectGetMaxY(bounds) - 24);
    } else if (_guideSnapshot && CGRectGetHeight(bounds) >= 650) {
        CGFloat width = MAX(1, CGRectGetWidth(bounds) - 48);
        UIControlGuide *measure = [[UIControlGuide alloc] initWithGuide:_guideSnapshot width:width compact:YES];
        CGFloat split = CGRectGetMinY(bounds) + measure.height + 48;
        guideRegion = RectFromEdges(CGRectGetMinX(bounds) + 24, CGRectGetMinY(bounds) + 18, CGRectGetMaxX(bounds) - 24, split - 18);
        menuBounds = RectFromEdges(CGRectGetMinX(bounds), split, CGRectGetMaxX(bounds), CGRectGetMaxY(bounds));
    }
    _menu = PauseMenuModel(_remote, _cockpit, [[GameAudio shared] mixTitle]);
    _selected = MIN(_selected, _menu.choices.count ? _menu.choices.count - 1 : 0);
    _layout = [[UILayout named:@"pause"] buildIn:menuBounds sceneSize:self.size flags:flags
        values:@{ @"title": _menu.title, @"hint": _menu.hint, @"choices": _menu.choices }
        selected:_menu.choices.count ? ButtonKey(_menu.choices[_selected]) : nil];
    if (_layout.node) [self addChild:_layout.node];
    if (!CGRectIsEmpty(guideRegion)) {
        UIControlGuide *guide = [[UIControlGuide alloc] initWithGuide:_guideSnapshot width:CGRectGetWidth(guideRegion) compact:NO];
        if (guide.height > CGRectGetHeight(guideRegion))
            guide = [[UIControlGuide alloc] initWithGuide:_guideSnapshot width:CGRectGetWidth(guideRegion) compact:YES];
        if (guide.height <= CGRectGetHeight(guideRegion)) {
            guide.position = CGPointMake(CGRectGetMinX(guideRegion), CGRectGetMidY(guideRegion) + guide.height / 2);
            [self addChild:guide];
        }
    }
}

- (void)pointerClick:(CGPoint)at {
    if (_controlsPanel) { [_controlsPanel pointerClick:at]; return; }
    _click = PointMultiply(at, self.size);
    _hasClick = YES;
}

- (void)pointerDown:(CGPoint)at { [_controlsPanel pointerDown:at]; }
- (void)pointerDrag:(CGPoint)at { [_controlsPanel pointerDrag:at]; }
- (void)pointerUp:(CGPoint)at { [_controlsPanel pointerUp:at]; }
- (void)pointerCancel { [_controlsPanel pointerCancel]; }

- (void)pointerScroll:(CGFloat)delta at:(CGPoint)at {
    [_controlsPanel pointerScroll:delta at:at];
}

- (void)pointerHover:(CGPoint)at { [_controlsPanel pointerHover:at]; }

- (PauseCommand)handle:(InputAction)actions {
    if (!CGSizeEqualToSize(_layoutSize, self.size) || memcmp(&_usedInsets, &_contentInsets, sizeof _usedInsets) ||
        _guideSnapshot != self.input.controlGuide) [self rebuild];
    if (_controlsPanel) {
        if ([_controlsPanel handle:actions]) {
            _controlsPanel = nil;
            [[GameAudio shared] play:@"ui-back"];
            [self rebuild];
        }
        return PauseCommandNone;
    }
    if (actions & InputActionBack) return PauseCommandResume;
    NSInteger step = (actions & InputActionDown ? 1 : 0) - (actions & InputActionUp ? 1 : 0);
    if (step && _menu.choices.count) { _selected = [_menu indexByMoving:step from:_selected]; [self rebuild]; }
    if (_hasClick) {
        _hasClick = NO;
        for (NSUInteger i = 0; i < _menu.choices.count; i++)
            if (CGRectContainsPoint([_layout frame:ButtonKey(_menu.choices[i])], _click)) {
                _selected = i;
                actions |= InputActionConfirm;
            }
    }
    MenuChoice *choice = actions & InputActionConfirm ? [_menu choiceToActivateAt:_selected] : nil;
    if (!choice) return PauseCommandNone;
    if ([choice.identifier isEqualToString:@"controls"]) {
        _controlsPanel = [ControlsPanel new];
        _controlsPanel.input = self.input;
        [[GameAudio shared] play:@"ui-confirm"];
        [self rebuild];
        return PauseCommandNone;
    }
    PauseCommand command = CommandFor(choice.identifier);
    if (command == PauseCommandCamera) { _cockpit = !_cockpit; [self rebuild]; }
    if (command == PauseCommandSound) { [[GameAudio shared] cycleMix]; [self rebuild]; }
    [[GameAudio shared] play:@"ui-confirm"];
    return command;
}

@end
