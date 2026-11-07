#import "UI.h"
#import "Audio.h"

@implementation ControlsPanel {
    CGRect _bounds;
    CGSize _sceneSize;
    SKNode *_body;
    CGFloat _contentHeight;
    NSInteger _selected;
    BOOL _hasClick, _backRequested, _showBindings, _bindingsRequested;
    TitleBar *_bar;
    UIHover *_hover;
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
    if (!_hover) _hover = [UIHover new];
    [_hover reset];
    CGFloat width = MIN(760, CGRectGetWidth(_bounds));
    CGFloat x = CGRectGetMidX(_bounds)-width/2, top = CGRectGetMaxY(_bounds);
    BOOL narrow = width < 540;
    BOOL compact = MIN(_sceneSize.width, _sceneSize.height) <= 500;
    CGRect header = RectFromEdges(CGRectGetMinX(_bounds), top - [TitleBar heightCompact:compact], CGRectGetMaxX(_bounds), top);
    __weak ControlsPanel *owner = self;
    UIBarAction *back = [UIBarAction title:L10n(@"controls.back") icon:UICommandBack accent:UIAmber handler:^{
        ControlsPanel *screen = owner; if (screen) screen->_backRequested = YES;
    }];
    UIBarAction *bindings=[UIBarAction title:L10n(@"controls.bindings") icon:UICommandBindings accent:UIInk handler:^{ ControlsPanel *screen=owner; if(screen) screen->_bindingsRequested=YES; }];
    _bar = [[TitleBar alloc] initWithHeader:header compact:compact back:back
        title:L10n(_showBindings ? @"controls.bindings" : @"controls.title") kicker:L10n(@"controls.kicker") actions:_showBindings ? @[] : @[bindings]];
    _backRect = [_bar rectForAction:back];
    _bindingsRect=[_bar rectForAction:bindings];
    [self addChild:_bar];
    [_bar registerHover:_hover];
    _scrollRect = RectFromEdges(x, CGRectGetMinY(_bounds), x + width, CGRectGetMinY(header) - 12);
    SKCropNode *crop = [SKCropNode node];
    crop.maskNode = [SKShapeNode shapeNodeWithRect:_scrollRect];
    ((SKShapeNode *)crop.maskNode).fillColor = SKColor.whiteColor;
    ((SKShapeNode *)crop.maskNode).strokeColor = SKColor.whiteColor;
    [self addChild:crop];
    _body = [SKNode node];
    [crop addChild:_body];
    _scrollContent = _body;
    _form=nil; _settingRects=@[];
    CGFloat y=0;
    if (!_showBindings) {
        _form = [[UISettingsForm alloc] initWithItems:[self settings] width:width compact:compact];
        _form.selectedIndex = _selected;
        [_body addChild:_form];
        _settingRects = _form.rowRects;
        y=-_form.height;
    } else {
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
    }
    _contentHeight = -y;
    [self setOffset:_scrollOffset];
}

- (void)setOffset:(CGFloat)value {
    _scrollOffset = MIN(MAX(0, value), MAX(0, _contentHeight - CGRectGetHeight(_scrollRect)));
    _body.position = UIScrollContentPosition(_scrollRect,CGSizeMake(CGRectGetWidth(_scrollRect),_contentHeight),_scrollOffset);
}

- (void)revealSelection {
    if (_contentHeight<=CGRectGetHeight(_scrollRect)) return;
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

- (void)showBindings { _showBindings=YES; _scrollOffset=0; [self rebuild]; }

- (BOOL)handle:(InputAction)actions {
    if (actions & InputActionToggleHelp) { if(_showBindings) return [self handle:InputActionBack]; [self showBindings]; return NO; }
    if (actions & InputActionBack) {
        _hasClick = NO;
        if(_showBindings) { _showBindings=NO; _scrollOffset=0; [self rebuild]; return NO; }
        return YES;
    }
    if (_hasClick) {
        _hasClick = NO;
        [_bar activateAt:_click];
        if (_backRequested) { _backRequested = NO; return [self handle:InputActionBack]; }
        if (_bindingsRequested) { _bindingsRequested=NO; [self showBindings]; return NO; }
        if (CGRectContainsPoint(_scrollRect, _click)) {
            CGPoint point = PointSub(_click, _body.position);
            if ([_form clickAt:point]) [self refreshSettings];
        }
    }
    if (!_form) return NO;
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
    [_bar beginAt:point];
    if (CGRectContainsPoint(_scrollRect, point)) [_form beginAt:PointSub(point, _body.position)];
}
- (void)pointerDrag:(CGPoint)at { [_form dragTo:PointSub(PointMultiply(at, _sceneSize), _body.position)]; }
- (void)pointerUp:(CGPoint)at { [_bar endPress]; [_form endDrag]; }
- (void)pointerCancel { [_bar endPress]; [_form endDrag]; _hasClick = NO; }
- (void)pointerHover:(CGPoint)at {
    [_hover queuePointAtFraction:at];
    if (self.scene) [_hover updateInScene:self.scene];
    CGPoint point = PointMultiply(at, _sceneSize);
    if (CGRectContainsPoint(_scrollRect, point)) [_form hoverAt:PointSub(point, _body.position)];
}
- (void)pointerScroll:(CGFloat)delta at:(CGPoint)at {
    if (!_form.dragging && CGRectContainsPoint(_scrollRect, PointMultiply(at, _sceneSize))) [self setOffset:_scrollOffset + delta];
}
@end
