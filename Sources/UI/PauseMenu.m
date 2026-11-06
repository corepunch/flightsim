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
    NSInteger _selected;
    UILayoutResult *_layout;
    BOOL _hasClick;
    CGPoint _click;
    CGSize _layoutSize;
    ScreenInsets _usedInsets;
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

- (NSArray<NSString *> *)items { return _layout.lists[@"items"] ?: @[]; }
- (UILayoutResult *)layout { return _layout; }

- (void)rebuild {
    [self removeAllChildren];
    _layoutSize = self.size;
    _usedInsets = self.contentInsets;
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
    NSArray *previous = [self items];
    NSString *selected = _selected < (NSInteger)previous.count ? [@"items." stringByAppendingString:previous[_selected]] : nil;
    UILayout *layout = [UILayout named:@"pause"];
    _layout = [layout buildIn:bounds sceneSize:self.size flags:flags
                    variables:@{ @"sound": [[GameAudio shared] mixTitle] } selected:selected];
    if (!selected && self.items.count) {
        // First build: highlight the first button.
        _layout = [layout buildIn:bounds sceneSize:self.size flags:flags
                        variables:@{ @"sound": [[GameAudio shared] mixTitle] }
                         selected:[@"items." stringByAppendingString:self.items[0]]];
    }
    if (_layout.node) [self addChild:_layout.node];
}

- (BOOL)disabled:(NSInteger)i {
    NSArray *items = [self items];
    return i < 0 || i >= (NSInteger)items.count || [_layout.disabled containsObject:[@"items." stringByAppendingString:items[i]]];
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
    if (!CGSizeEqualToSize(_layoutSize, self.size) || memcmp(&_usedInsets, &_contentInsets, sizeof _usedInsets)) [self rebuild];
    if (_controlsPanel) {
        if ([_controlsPanel handle:actions]) {
            _controlsPanel = nil;
            [[GameAudio shared] play:@"ui-back"];
            [self rebuild];
        }
        return PauseCommandNone;
    }
    NSInteger count = (NSInteger)self.items.count;
    if (actions & InputActionBack) return PauseCommandResume;
    if (count && (actions & InputActionUp)) { _selected = (_selected + count - 1) % count; [self rebuild]; }
    if (count && (actions & InputActionDown)) { _selected = (_selected + 1) % count; [self rebuild]; }
    if (_hasClick) {
        _hasClick = NO;
        for (NSInteger i = 0; i < count; i++)
            if (CGRectContainsPoint([_layout frame:[@"items." stringByAppendingString:self.items[i]]], _click)) {
                _selected = i;
                actions |= InputActionConfirm;
            }
    }
    if (!(actions & InputActionConfirm) || _selected >= count || [self disabled:_selected]) return PauseCommandNone;
    if ([self.items[_selected] isEqualToString:@"controls"]) {
        _controlsPanel = [ControlsPanel new];
        [[GameAudio shared] play:@"ui-confirm"];
        [self rebuild];
        return PauseCommandNone;
    }
    PauseCommand command = CommandFor(self.items[_selected]);
    if (command == PauseCommandCamera) { _cockpit = !_cockpit; [self rebuild]; }
    if (command == PauseCommandSound) { [[GameAudio shared] cycleMix]; [self rebuild]; }
    [[GameAudio shared] play:@"ui-confirm"];
    return command;
}

@end
