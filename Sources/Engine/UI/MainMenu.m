#import "MainMenu.h"
#import "UIStyle.h"
#import "UIMotion.h"
#import <ImageIO/ImageIO.h>

static const UIRGB MenuNight = { 4.0 / 255, 6.0 / 255, 11.0 / 255 };
static const UIRGB MenuTitle = { 0.89, 0.97, 0.96 };

typedef NS_ENUM(NSInteger, MenuItem) {
    MenuItemCampaign, MenuItemMissions, MenuItemMultiplayer, MenuItemControls, MenuItemQuit, MenuItemCount
};

@interface MainMenu () <UIMotionScene>
@end

@implementation MainMenu {
    // _stage sits at the scene centre so the whole menu can scale about it;
    // _root and _ghost undo that offset, so content is laid out in scene space.
    SKNode *_stage, *_scenery, *_root, *_ghost, *_target;
    SKTexture *_art;
    NSString *_campaignLabel, *_missionLabel;
    CGRect _rows[MenuItemCount], _controlsBack;
    CGSize _laidOut;
    MainMenuInsets _usedInsets;
    NSUInteger _selected;
    BOOL _controls;
    CGPoint _pendingPoint;
    BOOL _hasPendingPoint;

    UITransition _transition;
    BOOL _presented, _boot;
    CGSize _sceneryLaidOut;
    BOOL _sceneryPortrait;
    SKSpriteNode *_artNode, *_backdropNode;
    SKNode *_rowNodes[MenuItemCount];
    NSMutableArray<SKLabelNode *> *_header, *_rowLabels[MenuItemCount], *_footerLabels;
    NSMutableArray<SKNode *> *_controlRows;
    SKNode *_backButton;
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        self.scaleMode = SKSceneScaleModeResizeFill;
        // The backdrop is a sprite rather than the scene colour so the menu
        // can fade as a whole over whatever is behind it.
        self.backgroundColor = [SKColor clearColor];
        self.speed = 1 / UIMotionTimeScale();
        _stage = [SKNode node];
        _scenery = [SKNode node];
        _root = [SKNode node];
        _ghost = [SKNode node];
        [_stage addChild:_scenery];
        [_stage addChild:_root];
        [_stage addChild:_ghost];
        [self addChild:_stage];

        NSURL *url = [NSBundle.mainBundle URLForResource:@"Frontier" withExtension:@"jpg" subdirectory:@"Menu"];
        CGImageSourceRef source = url ? CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL) : NULL;
        if (source) {
            CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
            if (image) {
                _art = [SKTexture textureWithCGImage:image];
                CGImageRelease(image);
            }
            CFRelease(source);
        }
        [self showMission:0 title:nil started:NO completed:NO];
    }
    return self;
}

- (void)showMission:(NSUInteger)index title:(NSString *)title started:(BOOL)started completed:(BOOL)completed {
    _campaignLabel = completed ? @"REPLAY CAMPAIGN" : (started ? @"CONTINUE CAMPAIGN" : @"START CAMPAIGN");
    _missionLabel = title.length ? [NSString stringWithFormat:@"MISSION %02lu  /  %@", (unsigned long)index + 1,
                                   title.uppercaseString] : @"";
    _selected = MenuItemCampaign;
    _controls = NO;
    @synchronized (self) { _hasPendingPoint = NO; }
    _transition = _presented ? UITransitionIntro : UITransitionNone;
    [self rebuild];
}

- (NSUInteger)itemCount {
#if TARGET_OS_IOS
    return MenuItemControls;
#else
    return MenuItemCount;
#endif
}

- (SKLabelNode *)label:(NSString *)text size:(CGFloat)size color:(UIRGB)color opacity:(CGFloat)opacity
                     x:(CGFloat)x y:(CGFloat)y {
    SKLabelNode *label = UIMonoLabel(size, UIColorWithOpacity(color, opacity),
                                   SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeCenter);
    label.text = text;
    label.position = CGPointMake(x, y);
    [_target ?: _root addChild:label];
    return label;
}

- (void)drawArtPortrait:(BOOL)portrait {
    if (!_art) return;
    CGSize size = self.size, artSize = _art.size;
    CGFloat artWidth = size.width * (portrait ? 1.18 : 0.72);
    SKSpriteNode *art = [SKSpriteNode spriteNodeWithTexture:_art
                                                     size:CGSizeMake(artWidth, artWidth * artSize.height / artSize.width)];
    art.position = CGPointMake(portrait ? size.width * 0.45 : size.width - artWidth / 2,
                               size.height * (portrait ? 0.68 : 0.5));
    art.zPosition = -1;
    [_scenery addChild:art];
    _artNode = art;
    if (UIMotionReduced()) return;
    SKAction *drift = [SKAction sequence:@[
        UIEased([SKAction moveByX:-14 y:6 duration:11], UICurveInOut),
        UIEased([SKAction moveByX:14 y:-6 duration:11], UICurveInOut),
    ]];
    [art runAction:[SKAction repeatActionForever:drift] withKey:@"drift"];
}

- (SKNode *)drawButton:(NSString *)title detail:(NSString *)detail rect:(CGRect)rect selected:(BOOL)selected
                compact:(BOOL)compact labels:(NSMutableArray<SKLabelNode *> *)labels {
    UIRGB accent = selected ? UIAmber : UIInk;
    SKNode *row = [SKNode node];
    [_root addChild:row];
    _target = row;
    SKShapeNode *shape = UISkewedShape(rect, UIColorWithOpacity(accent, selected ? 0.92 : 0.36),
                                      UIColorWithOpacity(selected ? UIConsoleSteel : UIPanel, 0.94));
    [row addChild:shape];
    CGFloat x = CGRectGetMinX(rect) + 23, y = CGRectGetMidY(rect);
    SKLabelNode *label = [self label:title size:compact ? 14 : 17 color:accent opacity:1
                                  x:x y:y + (detail.length ? 8 : 0)];
    label.fontName = UIMonoBoldFont;
    [labels addObject:label];
    if (detail.length) {
        SKLabelNode *sub = [self label:detail size:compact ? 10 : 12 color:UIInk opacity:0.74 x:x y:y - 11];
        sub.numberOfLines = 1;
        sub.preferredMaxLayoutWidth = rect.size.width - 66;
        sub.lineBreakMode = NSLineBreakByTruncatingTail;
        [labels addObject:sub];
    }
    SKLabelNode *chevron = [self label:@"›" size:22 color:accent opacity:selected ? 1 : 0.5
                                     x:CGRectGetMaxX(rect) - 29 y:y];
    chevron.name = @"chevron";
    _target = nil;
    // Scale about the left edge so the button can extend out of it.
    return UIMotionPivot(row, CGPointMake(CGRectGetMinX(rect), CGRectGetMidY(rect)));
}

- (void)drawControlsIn:(CGRect)bounds {
    CGFloat x = CGRectGetMinX(bounds), y = CGRectGetMaxY(bounds);
    CGFloat width = MIN(580, CGRectGetWidth(bounds));
    [_header addObject:[self label:@"KESTREL FRONTIER  /  FLIGHT MANUAL" size:12 color:UIAmber opacity:1 x:x y:y - 8]];
    SKLabelNode *title = [self label:@"Flight controls" size:MIN(34, CGRectGetHeight(bounds) * 0.09)
                               color:MenuTitle opacity:1 x:x y:y - 43];
    title.fontName = UIMonoBoldFont;
    [_header addObject:title];
    NSArray<NSArray<NSString *> *> *bindings = @[
        @[@"Pitch / yaw", @"MOUSE / ARROWS"],
        @[@"Roll / throttle", @"Q E  /  W S"],
        @[@"Boost / fire", @"SHIFT  /  SPACE"],
        @[@"Next target / torpedo", @"T  /  G"],
        @[@"Camera / flight help", @"C  /  H"],
        @[@"Invert mouse pitch", @"I"],
        @[@"Cycle / invert throttle axis", @"J  /  K"],
    ];
    CGFloat line = MIN(33, (CGRectGetHeight(bounds) - 130) / bindings.count);
    CGFloat font = width < 390 ? 11 : 14;
    _controlRows = [NSMutableArray array];
    for (NSUInteger i = 0; i < bindings.count; i++) {
        CGFloat rowY = y - 77 - i * line;
        SKNode *row = [SKNode node];
        [_root addChild:row];
        _target = row;
        [self label:bindings[i][0] size:font color:MenuTitle opacity:0.92 x:x y:rowY];
        SKLabelNode *key = [self label:bindings[i][1] size:font color:UIInk opacity:0.9 x:x + width - 4 y:rowY];
        key.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
        key.name = @"key";
        _target = nil;
        [_controlRows addObject:row];
    }
    _controlsBack = CGRectMake(x, CGRectGetMinY(bounds), MIN(210, width), 44);
    _backButton = UIActionButton(_controlsBack, @"‹  MAIN MENU", UIAmber);
    [_root addChild:_backButton];
}

- (MainMenuInsets)layoutInsets {
#if TARGET_OS_IOS
    if (self.view) return self.view.safeAreaInsets;
#endif
    return self.contentInsets;
}

- (void)rebuild {
    UITransition transition = _transition;
    _transition = UITransitionNone;
    if (transition == UITransitionPage && _presented) [self dismissContent];
    if (transition == UITransitionIntro) {
        [_stage removeAllActions];
        _stage.alpha = 1;
        _stage.xScale = _stage.yScale = 1;
    }
    [_root removeAllChildren];
    _backButton = nil;
    _controlRows = nil;
    memset(_rowNodes, 0, sizeof(_rowNodes));
    _header = [NSMutableArray array];
    _footerLabels = [NSMutableArray array];
    for (NSUInteger i = 0; i < MenuItemCount; i++) _rowLabels[i] = [NSMutableArray array];
    _stage.position = CGPointMake(self.size.width / 2, self.size.height / 2);
    _root.position = _ghost.position = _scenery.position = CGPointMake(-self.size.width / 2, -self.size.height / 2);
    memset(_rows, 0, sizeof(_rows));
    _controlsBack = CGRectZero;
    _laidOut = self.size;
    _usedInsets = [self layoutInsets];

    BOOL portrait = self.size.height > self.size.width;
    BOOL compact = self.size.height < 550 || portrait;
    CGFloat margin = compact ? 18 : MIN(92, self.size.width * 0.065);
    CGFloat bottom = _usedInsets.bottom + (compact ? 15 : 30);
    CGFloat top = self.size.height - _usedInsets.top - (compact ? 16 : 38);
    CGFloat left = _usedInsets.left + margin;
    CGFloat availableWidth = self.size.width - _usedInsets.right - margin - left;
    // The backdrop and art outlive rebuilds so the art's drift carries on
    // through selection changes; they are redrawn only for a new layout.
    if (!CGSizeEqualToSize(_sceneryLaidOut, self.size) || _sceneryPortrait != portrait || !_backdropNode) {
        [_scenery removeAllChildren];
        _artNode = nil;
        _sceneryLaidOut = self.size;
        _sceneryPortrait = portrait;
        SKSpriteNode *backdrop = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(MenuNight, 1) size:self.size];
        backdrop.anchorPoint = CGPointZero;
        backdrop.zPosition = -2;
        [_scenery addChild:backdrop];
        _backdropNode = backdrop;
        [self drawArtPortrait:portrait];
    }
    if (transition == UITransitionIntro) {
        _backdropNode.alpha = 1;
        [_artNode removeActionForKey:@"intro"];
        _artNode.alpha = 1;
        [_artNode setScale:1];
    }
    _artNode.hidden = availableWidth < 120 || top - bottom < 220;
    if (availableWidth < 120 || top - bottom < 220) return;

    if (_controls) {
        SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(MenuNight, 0.8) size:self.size];
        shade.anchorPoint = CGPointZero;
        shade.zPosition = -0.5;
        [_root addChild:shade];
        [self drawControlsIn:CGRectMake(left, bottom, availableWidth, top - bottom)];
        if (transition == UITransitionIntro || transition == UITransitionPage) {
            UIMotionFlickerIn(shade, 0);
            [self animateControls];
        }
        return;
    }

    CGFloat width = portrait ? availableWidth : MIN(compact ? 316 : 390, availableWidth);
    BOOL oneLine = compact && !portrait && availableWidth >= 330;
    CGFloat rowHeight = compact ? 46 : MIN(62, (top - bottom) * 0.105);
    CGFloat gap = compact ? 5 : 8;
    NSUInteger count = [self itemCount];
    CGFloat stack = count * (rowHeight + gap) - gap;
    CGFloat titleSize = portrait ? MIN(52, availableWidth * 0.13) : (compact ? 34 : MIN(82, availableWidth * 0.10));
    CGFloat titleLines = oneLine ? 1 : 1.86;
    CGFloat headerPadding = compact ? 33 : 62;
    titleSize = MIN(titleSize, MAX(18, (top - bottom - stack - headerPadding) / titleLines));
    CGFloat header = titleSize * titleLines + headerPadding;
    CGFloat blockHeight = stack + header;
    CGFloat stackBottom = portrait ? bottom + 8 : MAX(bottom, bottom + (top - bottom - blockHeight) * 0.5);
    CGFloat stackTop = stackBottom + stack;

    [_header addObject:[self label:@"CNS BASTION   /   LANCER FLIGHT" size:compact ? 10 : 13 color:UIAmber
                           opacity:0.96 x:left + 2 y:stackTop + header - 6]];
    CGFloat titleY = stackTop + header - (compact ? 19 : 29);
    SKLabelNode *wordmark = [self label:oneLine ? @"KESTREL FRONTIER" : @"KESTREL"
                                   size:titleSize color:MenuTitle opacity:1 x:left y:titleY];
    wordmark.fontName = @"HelveticaNeue-CondensedBlack";
    wordmark.verticalAlignmentMode = SKLabelVerticalAlignmentModeTop;
    wordmark.name = @"wordmark";
    [_header addObject:wordmark];
    if (!oneLine) {
        SKLabelNode *secondLine = [self label:@"FRONTIER" size:titleSize color:MenuTitle opacity:1
                                          x:left y:titleY - titleSize * 0.85];
        secondLine.fontName = wordmark.fontName;
        secondLine.verticalAlignmentMode = SKLabelVerticalAlignmentModeTop;
        secondLine.name = @"wordmark";
        [_header addObject:secondLine];
    }

    NSArray<NSString *> *labels = @[_campaignLabel, @"MISSION SELECT", @"LAN CO-OP", @"FLIGHT CONTROLS", @"QUIT GAME"];
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat y = stackTop - (i + 1) * rowHeight - i * gap;
        _rows[i] = CGRectMake(left, y, width, rowHeight);
        _rowNodes[i] = [self drawButton:labels[i] detail:i == MenuItemCampaign ? _missionLabel : nil rect:_rows[i]
                               selected:i == _selected compact:compact labels:_rowLabels[i]];
    }
    if (!compact) {
        [_footerLabels addObject:[self label:@"↑ / ↓   SELECT       ↵   CONFIRM" size:11 color:UIInk opacity:0.6
                                           x:left y:bottom]];
        SKLabelNode *caption = [self label:@"LANCER 01   /   EXECUTIONER" size:11 color:UIInk opacity:0.6
                                        x:self.size.width - _usedInsets.right - margin y:bottom];
        caption.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
        [_footerLabels addObject:caption];
    }
    [self startIdle];
    if (transition == UITransitionIntro || transition == UITransitionPage)
        [self animateMenuIntro:transition == UITransitionIntro && _boot];
    else if (transition == UITransitionSelect) [self animateSelection];
}

#pragma mark - Motion

// The menu powers up: the art resolves out of the dark behind a rising scan,
// the wordmark strikes, then each button extends out of its left edge and
// decodes its label.
- (void)animateMenuIntro:(BOOL)boot {
    _boot = NO;
    NSTimeInterval t = 0;
    if (boot) {
        _backdropNode.alpha = 0;
        [_backdropNode runAction:[SKAction fadeInWithDuration:0.25]];
        if (_artNode && !UIMotionReduced()) {
            _artNode.alpha = 0;
            [_artNode setScale:1.08];
            [_artNode runAction:[SKAction group:@[
                UIEased([SKAction fadeInWithDuration:0.9], UICurveOut),
                UIEased([SKAction scaleTo:1 duration:1.3], UICurveOut),
            ]] withKey:@"intro"];
        }
        UIMotionSweep(_root, CGRectMake(0, 0, self.size.width, self.size.height),
                      UIColorWithOpacity(UIInk, 0.55), NO, 0.05, 0.85);
        t = 0.15;
    }
    for (SKLabelNode *label in _header) {
        if ([label.name isEqualToString:@"wordmark"]) {
            UIMotionGlitchIn(label, t + 0.1, 0.5, UIColorWithOpacity(UIRed, 1));
            t += 0.08;
        } else UIMotionDecode(label, t, 0.45);
    }
    t += 0.3;
    for (NSUInteger i = 0; i < MenuItemCount; i++) {
        SKNode *row = _rowNodes[i];
        if (!row) continue;
        NSTimeInterval at = t + i * 0.06;
        if (!UIMotionReduced()) {
            row.xScale = 0.001;
            [row runAction:UIAfter(at, UIEased([SKAction scaleXTo:1 duration:0.34], UICurveOutExpo))];
            UIMotionFlickerIn(row, at);
        }
        for (SKLabelNode *label in _rowLabels[i]) UIMotionDecode(label, at + 0.1, 0.35);
    }
    for (SKLabelNode *label in _footerLabels) UIMotionFlickerIn(label, t + 0.45);
}

// The newly highlighted button kicks forward and a glint runs across it.
- (void)animateSelection {
    SKNode *row = _rowNodes[_selected];
    if (!row || UIMotionReduced()) return;
    CGPoint home = row.position;
    row.position = CGPointMake(home.x + 9, home.y);
    [row runAction:UIEased([SKAction moveTo:home duration:0.26], UICurveOutBack)];
    CGRect rect = _rows[_selected];
    SKSpriteNode *glint = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIAmber, 1)
                                                       size:CGSizeMake(18, rect.size.height * 0.92)];
    glint.blendMode = SKBlendModeAdd;
    glint.alpha = 0.45;
    glint.zRotation = -UISlant;
    glint.position = CGPointMake(12, 0);
    [row addChild:glint];
    [glint runAction:[SKAction sequence:@[
        [SKAction group:@[
            UIEased([SKAction moveToX:rect.size.width - 30 duration:0.3], UICurveInOut),
            [SKAction sequence:@[[SKAction waitForDuration:0.18], [SKAction fadeOutWithDuration:0.12]]],
        ]],
        [SKAction removeFromParent],
    ]]];
    SKLabelNode *title = _rowLabels[_selected].firstObject;
    if (title) UIMotionGlitchBurst(title, 0.18, 0.5, UIColorWithOpacity(UIRed, 1));
}

- (void)animateControls {
    NSTimeInterval t = 0;
    for (SKLabelNode *label in _header) { UIMotionDecode(label, t, 0.4); t += 0.06; }
    for (NSUInteger i = 0; i < _controlRows.count; i++) {
        SKNode *row = _controlRows[i];
        UIMotionSlideIn(row, CGVectorMake(-26, 0), 0.12 + i * 0.045, 0.3);
        SKLabelNode *key = (SKLabelNode *)[row childNodeWithName:@"key"];
        if (key) UIMotionDecode(key, 0.2 + i * 0.045, 0.35);
    }
    if (_backButton) UIMotionSlideIn(_backButton, CGVectorMake(0, -40), 0.3, 0.32);
}

// Life while the menu sits: the art drifts, the selected chevron beckons,
// and the wordmark takes an occasional hit of interference.
- (void)startIdle {
    if (UIMotionReduced() || _controls) return;
    SKNode *chevron = [_rowNodes[_selected] childNodeWithName:@"//chevron"];
    [chevron runAction:[SKAction repeatActionForever:[SKAction sequence:@[
        UIEased([SKAction moveByX:5 y:0 duration:0.45], UICurveInOut),
        UIEased([SKAction moveByX:-5 y:0 duration:0.45], UICurveInOut),
    ]]]];
    for (SKLabelNode *label in _header) {
        if (![label.name isEqualToString:@"wordmark"]) continue;
        __weak SKLabelNode *weak = label;
        [label runAction:[SKAction repeatActionForever:[SKAction sequence:@[
            [SKAction waitForDuration:8 withRange:6],
            [SKAction runBlock:^{ if (weak) UIMotionGlitchBurst(weak, 0.22, 0.6, UIColorWithOpacity(UIRed, 1)); }],
        ]]]];
    }
}

// Move everything but the backdrop and art to the ghost layer and let it go.
- (void)dismissContent {
    for (SKNode *node in [_root.children copy]) {
        [node removeFromParent];
        [_ghost addChild:node];
        UIMotionDismiss(node, CGVectorMake(-22, 0), 0.2);
    }
}

- (NSTimeInterval)collapseRows {
    NSTimeInterval longest = 0;
    NSUInteger n = 0;
    for (NSUInteger i = MenuItemCount; i-- > 0;) {
        SKNode *row = _rowNodes[i];
        if (!row) continue;
        NSTimeInterval at = n++ * 0.035;
        [row removeAllActions];
        [row runAction:UIAfter(at, [SKAction group:@[
            UIEased([SKAction scaleXTo:0.001 duration:0.2], UICurveIn),
            [SKAction sequence:@[[SKAction waitForDuration:0.08], [SKAction fadeOutWithDuration:0.12]]],
        ]])];
        longest = at + 0.2;
    }
    for (SKLabelNode *label in _header) {
        if ([label.name isEqualToString:@"wordmark"]) {
            [label removeAllActions];
            UIMotionGlitchBurst(label, 0.25, 1, UIColorWithOpacity(UIRed, 1));
        }
        [label runAction:UIAfter(0.08, [SKAction fadeOutWithDuration:0.16])];
    }
    for (SKLabelNode *label in _footerLabels) [label runAction:[SKAction fadeOutWithDuration:0.12]];
    for (SKNode *row in _controlRows) [row runAction:[SKAction fadeOutWithDuration:0.15]];
    [_backButton runAction:[SKAction fadeOutWithDuration:0.15]];
    return MAX(longest, 0.24);
}

- (void)motionEnter {
    @synchronized (self) { _hasPendingPoint = NO; }
    _boot = YES;
    _transition = UITransitionIntro;
    [self rebuild];
    _presented = YES;
}

- (NSTimeInterval)motionExit {
    _presented = NO;
    NSTimeInterval rows = [self collapseRows];
    if (UIMotionReduced()) {
        [_stage runAction:[SKAction fadeOutWithDuration:0.15]];
        return 0.15;
    }
    [_artNode runAction:[SKAction group:@[
        UIEased([SKAction scaleTo:1.05 duration:0.4], UICurveIn), [SKAction fadeOutWithDuration:0.4],
    ]] withKey:@"intro"];
    [_stage runAction:UIAfter(rows, [SKAction fadeOutWithDuration:0.16])];
    return rows + 0.16;
}

- (NSTimeInterval)motionPowerDown {
    _presented = NO;
    NSTimeInterval rows = [self collapseRows];
    __weak SKNode *stage = _stage;
    CGSize size = self.size;
    const NSTimeInterval power = 0.42;
    [self runAction:[SKAction sequence:@[
        [SKAction waitForDuration:rows * 0.7],
        [SKAction runBlock:^{ if (stage) UIMotionPowerDown(stage, size); }],
    ]]];
    return rows * 0.7 + power;
}



- (void)queueClickAtFraction:(CGPoint)point {
    @synchronized (self) {
        _pendingPoint = point;
        _hasPendingPoint = YES;
    }
}

- (void)refreshLayout {
    MainMenuInsets insets = [self layoutInsets];
    if (!CGSizeEqualToSize(_laidOut, self.size) || insets.top != _usedInsets.top || insets.bottom != _usedInsets.bottom ||
        insets.left != _usedInsets.left || insets.right != _usedInsets.right) [self rebuild];
}

- (void)reselect {
    _transition = UITransitionSelect;
    [self rebuild];
}

- (MainMenuCommand)handle:(InputAction)actions {
    [self refreshLayout];
    CGPoint click = CGPointMake(-1, -1);
    @synchronized (self) {
        if (_hasPendingPoint) click = CGPointMake(_pendingPoint.x * self.size.width, _pendingPoint.y * self.size.height);
        _hasPendingPoint = NO;
    }
    if (_controls) {
        if ((actions & (InputActionBack | InputActionConfirm)) || CGRectContainsPoint(_controlsBack, click)) {
            _controls = NO;
            _transition = UITransitionPage;
            [self rebuild];
        }
        return MainMenuCommandNone;
    }

    NSUInteger count = [self itemCount];
    if (actions & InputActionUp) { _selected = (_selected + count - 1) % count; [self reselect]; }
    if (actions & InputActionDown) { _selected = (_selected + 1) % count; [self reselect]; }
    for (NSUInteger i = 0; i < count; i++) {
        if (CGRectContainsPoint(_rows[i], click)) {
            if (_selected != i) { _selected = i; [self reselect]; }
            actions |= InputActionConfirm;
            break;
        }
    }
    if (!(actions & InputActionConfirm)) return MainMenuCommandNone;
    switch ((MenuItem)_selected) {
        case MenuItemCampaign: return MainMenuCommandCampaign;
        case MenuItemMissions: return MainMenuCommandMissions;
        case MenuItemMultiplayer: return MainMenuCommandMultiplayer;
        case MenuItemControls:
            _controls = YES;
            _transition = UITransitionPage;
            [self rebuild];
            break;
        case MenuItemQuit: return MainMenuCommandQuit;
        case MenuItemCount: break;
    }
    return MainMenuCommandNone;
}

#if TARGET_OS_IOS
- (void)update:(NSTimeInterval)time {
    [self refreshLayout];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint point = [touches.anyObject locationInNode:self];
    if (self.size.width > 0 && self.size.height > 0)
        [self queueClickAtFraction:CGPointMake(point.x / self.size.width, point.y / self.size.height)];
}
#endif

@end
