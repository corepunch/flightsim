#import "UI.h"
#import "Audio.h"

@implementation ControlsPanel {
    CGRect _bounds;
    CGSize _sceneSize;
    SKNode *_body;
    CGFloat _contentHeight;
    NSInteger _selected;
    BOOL _hasClick, _backRequested;
    TitleBar *_bar;
    CGPoint _click;
}

- (instancetype)init {
    if ((self = [super init])) _touchNavigationEnabled = TARGET_OS_IOS;
    return self;
}

- (SKLabelNode *)label:(NSString *)text at:(CGPoint)point size:(CGFloat)size color:(UIRGB)color parent:(SKNode *)parent {
    SKLabelNode *label = [SKLabelNode labelNodeWithFontNamed:UIInterfaceFont];
    label.text = text;
    label.fontSize = size;
    label.fontColor = UIColorWithOpacity(color, 1);
    label.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeLeft;
    label.verticalAlignmentMode = SKLabelVerticalAlignmentModeTop;
    label.position = point;
    [parent addChild:label];
    return label;
}

- (CGFloat)paragraph:(NSString *)text y:(CGFloat)y width:(CGFloat)width {
    SKLabelNode *label = [self label:text at:CGPointMake(0, y) size:13 color:UIInk parent:_body];
    label.numberOfLines = 0;
    label.preferredMaxLayoutWidth = width;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    return CGRectGetHeight(label.frame) + 14;
}

- (NSArray<UISettingItem *> *)settings {
    FlightControls *controls = FlightControls.shared;
    NSString *(^percent)(float) = ^NSString *(float value) { return [NSString stringWithFormat:@"%.0f%%", value * 100]; };
    return @[
        [UISettingItem choice:L10n(@"controls.mode") value:L10n(controls.expert ? @"controls.expert" : @"controls.casual")
                       detail:L10n(controls.expert ? @"controls.expert_detail" : @"controls.casual_detail")
                       action:^{ controls.expert = !controls.expert; }],
        [UISettingItem slider:L10n(@"controls.horizontal") value:controls.horizontalSensitivity minimum:0.25 maximum:2 step:0.25
                         text:percent change:^(float value) { controls.horizontalSensitivity = value; }],
        [UISettingItem slider:L10n(@"controls.vertical") value:controls.verticalSensitivity minimum:0.25 maximum:2 step:0.25
                         text:percent change:^(float value) { controls.verticalSensitivity = value; }],
        [UISettingItem choice:L10n(@"controls.invert") value:L10n(controls.invertPitch ? @"controls.on" : @"controls.off")
                       detail:nil action:^{ controls.invertPitch = !controls.invertPitch; }],
        [UISettingItem choice:L10n(@"controls.camera") value:L10n(controls.dynamicCamera ? @"controls.on" : @"controls.off")
                       detail:nil action:^{ controls.dynamicCamera = !controls.dynamicCamera; }],
        [UISettingItem action:L10n(@"controls.reset") value:L10n(@"controls.restore") action:^{ [controls reset]; }],
    ];
}

- (void)layoutIn:(CGRect)bounds sceneSize:(CGSize)size {
    if (_form) _selected = _form.selectedIndex;
    _bounds = bounds;
    _sceneSize = size;
    [self rebuild];
}

- (void)rebuild {
    [self removeAllChildren];
    CGFloat width = MIN(760, CGRectGetWidth(_bounds));
    CGFloat x = CGRectGetMinX(_bounds), top = CGRectGetMaxY(_bounds);
    BOOL narrow = width < 540;
    CGRect header = RectFromEdges(x, top - [TitleBar heightCompact:narrow], x + width, top);
    __weak ControlsPanel *owner = self;
    UIBarAction *back = [UIBarAction title:L10n(@"controls.back") accent:UIAmber handler:^{
        ControlsPanel *screen = owner; if (screen) screen->_backRequested = YES;
    }];
    _bar = [[TitleBar alloc] initWithHeader:header compact:narrow back:back
        title:L10n(@"controls.title") kicker:L10n(@"controls.kicker") actions:@[]];
    _backRect = [_bar rectForAction:back];
    [self addChild:_bar];
    _scrollRect = RectFromEdges(x, CGRectGetMinY(_bounds) + 24, x + width, CGRectGetMinY(header) - 12);
    [self label:L10n(@"controls.scroll_hint") at:CGPointMake(x, CGRectGetMinY(_bounds) + 16)
           size:14 color:UIInk parent:self];
    SKCropNode *crop = [SKCropNode node];
    crop.maskNode = [SKShapeNode shapeNodeWithRect:_scrollRect];
    ((SKShapeNode *)crop.maskNode).fillColor = SKColor.whiteColor;
    ((SKShapeNode *)crop.maskNode).strokeColor = SKColor.whiteColor;
    [self addChild:crop];
    _body = [SKNode node];
    [crop addChild:_body];
    _scrollContent = _body;
    _form = [[UISettingsForm alloc] initWithItems:[self settings] width:width];
    _form.selectedIndex = _selected;
    [_body addChild:_form];
    _settingRects = _form.rowRects;
    CGFloat y = -_form.height;
    y -= 18;
    y -= [self paragraph:L10n(@"controls.bindings") y:y width:width];
    NSArray *actions = L10nList(self.touchNavigationEnabled ? @"controls.touch.actions" : @"controls.desktop.actions");
    NSArray *keys = L10nList(self.touchNavigationEnabled ? @"controls.touch.keys" : @"controls.desktop.keys");
    for (NSUInteger i = 0; i < MIN(actions.count, keys.count); i++) {
        [self label:actions[i] at:CGPointMake(0, y) size:13 color:UIMenuTitle parent:_body];
        if (narrow) {
            y -= 21;
            y -= [self paragraph:keys[i] y:y width:width];
        } else {
            SKLabelNode *binding = [self label:keys[i] at:CGPointMake(width - 4, y) size:13 color:UIInk parent:_body];
            binding.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
            y -= 30;
        }
    }
    y -= 10;
    y -= [self paragraph:L10n(self.touchNavigationEnabled ? @"controls.touch_tip" : @"controls.trackball_tip") y:y width:width - 12];
    _contentHeight = -y;
    [self setOffset:_scrollOffset];
}

- (void)setOffset:(CGFloat)value {
    _scrollOffset = MIN(MAX(0, value), MAX(0, _contentHeight - CGRectGetHeight(_scrollRect)));
    _body.position = PointAdd(CGPointMake(CGRectGetMinX(_scrollRect), CGRectGetMaxY(_scrollRect)), CGPointMake(0, _scrollOffset));
}

- (void)revealSelection {
    CGRect row = UnboxRect(_settingRects[_selected]);
    CGFloat bottom = CGRectGetMinY(row) + _scrollOffset, top = CGRectGetMaxY(row) + _scrollOffset;
    CGFloat height = CGRectGetHeight(_scrollRect);
    if (bottom < -height) [self setOffset:-height - CGRectGetMinY(row)];
    if (top > 0) [self setOffset:-CGRectGetMaxY(row)];
}

- (void)refreshSettings {
    _selected = _form.selectedIndex;
    [[GameAudio shared] play:@"ui-confirm"];
    [self rebuild];
    [self revealSelection];
}

- (BOOL)handle:(InputAction)actions {
    if (actions & InputActionBack) { _hasClick = NO; return YES; }
    if (_hasClick) {
        _hasClick = NO;
        [_bar activateAt:_click];
        if (_backRequested) { _backRequested = NO; return YES; }
        if (CGRectContainsPoint(_scrollRect, _click)) {
            CGPoint point = PointSub(_click, _body.position);
            if ([_form clickAt:point]) [self refreshSettings];
        }
    }
    if (actions & (InputActionUp | InputActionDown)) {
        NSInteger count = (NSInteger)_settingRects.count;
        _form.selectedIndex = (_form.selectedIndex + ((actions & InputActionUp) ? count - 1 : 1)) % count;
        _selected = _form.selectedIndex;
        [self revealSelection];
    }
    if (actions & (InputActionLeft | InputActionRight | InputActionConfirm)) {
        if ([_form adjust:(actions & InputActionLeft) ? -1 : 1]) [self refreshSettings];
    }
    return NO;
}

- (void)pointerClick:(CGPoint)at {
    if (_form.dragging) return;
    _click = PointMultiply(at, _sceneSize);
    _hasClick = YES;
}
- (void)pointerDown:(CGPoint)at {
    CGPoint point = PointMultiply(at, _sceneSize);
    if (CGRectContainsPoint(_scrollRect, point)) [_form beginAt:PointSub(point, _body.position)];
}
- (void)pointerDrag:(CGPoint)at { [_form dragTo:PointSub(PointMultiply(at, _sceneSize), _body.position)]; }
- (void)pointerUp:(CGPoint)at { [_form endDrag]; }
- (void)pointerCancel { [_form endDrag]; _hasClick = NO; }
- (void)pointerHover:(CGPoint)at {
    CGPoint point = PointMultiply(at, _sceneSize);
    if (CGRectContainsPoint(_scrollRect, point)) [_form hoverAt:PointSub(point, _body.position)];
}
- (void)pointerScroll:(CGFloat)delta at:(CGPoint)at {
    if (!_form.dragging && CGRectContainsPoint(_scrollRect, PointMultiply(at, _sceneSize))) [self setOffset:_scrollOffset + delta];
}
@end
