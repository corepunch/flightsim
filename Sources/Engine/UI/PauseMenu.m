#import "PauseMenu.h"
#import "UIStyle.h"
#import "GameAudio.h"
#import "Localization.h"

@implementation PauseMenu {
    BOOL _remote, _cockpit;
    NSInteger _selected;
    CGRect _buttons[5];
    NSValue *_click;
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
    @synchronized(self) { _click = nil; }
    [self rebuild];
}
- (void)rebuild {
    [self removeAllChildren];
    _layoutSize = self.size;
    SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIBlack, 0.72) size:self.size];
    shade.position = CGPointMake(self.size.width / 2, self.size.height / 2);
    [self addChild:shade];
    CGFloat width = MIN(400, self.size.width - 48), height = MIN(360, self.size.height - 24);
    CGFloat x = (self.size.width - width) / 2, y = (self.size.height - height) / 2;
    [self addChild:UIReadoutPanel(CGRectMake(x, y, width, height), UIColorWithOpacity(UIInk, 0.8), UIColorWithOpacity(UIPanel, 0.98))];
    SKLabelNode *title = UIInterfaceLabel(24, UIColorWithOpacity(UIInk, 1), SKLabelHorizontalAlignmentModeCenter, SKLabelVerticalAlignmentModeCenter);
    title.text = L10n(_remote ? @"pause.title_online" : @"pause.title");
    title.fontName = UIInterfaceBoldFont;
    title.position = CGPointMake(self.size.width / 2, y + height - 28);
    [self addChild:title];
    SKLabelNode *hint = UIInterfaceLabel(10, UIColorWithOpacity(UIInk, 0.65), SKLabelHorizontalAlignmentModeCenter, SKLabelVerticalAlignmentModeCenter);
    hint.text = L10n(_remote ? @"pause.hint_online" : @"pause.hint");
    hint.position = CGPointMake(self.size.width / 2, y + height - 51);
    [self addChild:hint];
    NSArray *titles = @[L10n(@"pause.resume"), L10n(_cockpit ? @"pause.camera_cockpit" : @"pause.camera_chase"), [[GameAudio shared] mixTitle],
                        L10n(_remote ? @"pause.restart_host_only" : @"pause.restart"), L10n(@"pause.missions")];
    CGFloat rowHeight = MIN(44, (height - 82) / 5 - 6);
    for (NSInteger i = 0; i < 5; i++) {
        _buttons[i] = CGRectMake(x + 22, y + height - 70 - (i + 1) * (rowHeight + 6), width - 44, rowHeight);
        SKShapeNode *button = UIActionButton(_buttons[i], titles[i], i == _selected ? UIAmber : UIInk);
        button.alpha = _remote && i == 3 ? 0.35 : 1;
        [self addChild:button];
    }
}
- (void)queueClickAtFraction:(CGPoint)point { @synchronized(self) { _click = [NSValue valueWithBytes:&point objCType:@encode(CGPoint)]; } }
- (PauseCommand)handle:(InputAction)actions {
    if (!CGSizeEqualToSize(_layoutSize, self.size)) [self rebuild];
    if (actions & InputActionBack) return PauseCommandResume;
    if (actions & InputActionUp) { _selected = (_selected + 4) % 5; [self rebuild]; }
    if (actions & InputActionDown) { _selected = (_selected + 1) % 5; [self rebuild]; }
    NSValue *click;
    @synchronized(self) { click = _click; _click = nil; }
    if (click) {
        CGPoint p; [click getValue:&p size:sizeof p];
        p = CGPointMake(p.x * self.size.width, p.y * self.size.height);
        for (NSInteger i = 0; i < 5; i++) if (CGRectContainsPoint(_buttons[i], p)) { _selected = i; actions |= InputActionConfirm; }
    }
    if (!(actions & InputActionConfirm) || (_remote && _selected == 3)) return PauseCommandNone;
    if (_selected == 1) { _cockpit = !_cockpit; [self rebuild]; }
    if (_selected == 2) { [[GameAudio shared] cycleMix]; [self rebuild]; }
    [[GameAudio shared] play:@"ui-confirm"];
    return (PauseCommand)(_selected + 1);
}
#if TARGET_OS_IOS
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint p = [touches.anyObject locationInNode:self];
    if (self.size.width && self.size.height) [self queueClickAtFraction:CGPointMake(p.x / self.size.width, p.y / self.size.height)];
}
#endif
@end
