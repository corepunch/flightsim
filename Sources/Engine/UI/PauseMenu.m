#import "PauseMenu.h"
#import "UILayout.h"
#import "GameAudio.h"

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
    _hasClick = NO;
    [self rebuild];
}

- (NSArray<NSString *> *)items { return _layout.lists[@"items"] ?: @[]; }

- (void)rebuild {
    [self removeAllChildren];
    _layoutSize = self.size;
    NSMutableSet *flags = [NSMutableSet set];
    if (_remote) [flags addObject:@"online"];
    if (_cockpit) [flags addObject:@"cockpit"];
    NSArray *previous = [self items];
    NSString *selected = _selected < (NSInteger)previous.count ? [@"items." stringByAppendingString:previous[_selected]] : nil;
    UILayout *layout = [UILayout named:@"pause"];
    _layout = [layout buildIn:CGRectMake(0, 0, self.size.width, self.size.height) sceneSize:self.size flags:flags
                    variables:@{ @"sound": [[GameAudio shared] mixTitle] } selected:selected];
    if (!selected && self.items.count) {
        // First build: highlight the first button.
        _layout = [layout buildIn:CGRectMake(0, 0, self.size.width, self.size.height) sceneSize:self.size flags:flags
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
    _click = CGPointMake(at.x * self.size.width, at.y * self.size.height);
    _hasClick = YES;
}

- (PauseCommand)handle:(InputAction)actions {
    if (!CGSizeEqualToSize(_layoutSize, self.size)) [self rebuild];
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
    PauseCommand command = CommandFor(self.items[_selected]);
    if (command == PauseCommandCamera) { _cockpit = !_cockpit; [self rebuild]; }
    if (command == PauseCommandSound) { [[GameAudio shared] cycleMix]; [self rebuild]; }
    [[GameAudio shared] play:@"ui-confirm"];
    return command;
}

@end
