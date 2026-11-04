#import "MainMenu.h"
#import "UIStyle.h"
#import <ImageIO/ImageIO.h>

static const UIRGB MenuNight = { 4.0 / 255, 6.0 / 255, 11.0 / 255 };
static const UIRGB MenuTitle = { 0.89, 0.97, 0.96 };

typedef NS_ENUM(NSInteger, MenuItem) {
    MenuItemCampaign, MenuItemMissions, MenuItemMultiplayer, MenuItemControls, MenuItemQuit, MenuItemCount
};

@implementation MainMenu {
    SKNode *_root;
    SKTexture *_art;
    NSString *_campaignLabel, *_missionLabel;
    CGRect _rows[MenuItemCount], _controlsBack;
    CGSize _laidOut;
    MainMenuInsets _usedInsets;
    NSUInteger _selected;
    BOOL _controls;
    CGPoint _pendingPoint;
    BOOL _hasPendingPoint;
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.backgroundColor = UIColorWithOpacity(MenuNight, 1);
        _root = [SKNode node];
        [self addChild:_root];

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
    [_root addChild:label];
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
    [_root addChild:art];
}

- (void)drawButton:(NSString *)title detail:(NSString *)detail rect:(CGRect)rect selected:(BOOL)selected compact:(BOOL)compact {
    UIRGB accent = selected ? UIAmber : UIInk;
    SKShapeNode *shape = UISkewedShape(rect, UIColorWithOpacity(accent, selected ? 0.92 : 0.36),
                                      UIColorWithOpacity(selected ? UIConsoleSteel : UIPanel, 0.94));
    [_root addChild:shape];
    CGFloat x = CGRectGetMinX(rect) + 23, y = CGRectGetMidY(rect);
    SKLabelNode *label = [self label:title size:compact ? 14 : 17 color:accent opacity:1
                                  x:x y:y + (detail.length ? 8 : 0)];
    label.fontName = UIMonoBoldFont;
    if (detail.length) {
        SKLabelNode *sub = [self label:detail size:compact ? 10 : 12 color:UIInk opacity:0.74 x:x y:y - 11];
        sub.numberOfLines = 1;
        sub.preferredMaxLayoutWidth = rect.size.width - 66;
        sub.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    [self label:@"›" size:22 color:accent opacity:selected ? 1 : 0.5 x:CGRectGetMaxX(rect) - 29 y:y];
}

- (void)drawControlsIn:(CGRect)bounds {
    CGFloat x = CGRectGetMinX(bounds), y = CGRectGetMaxY(bounds);
    CGFloat width = MIN(580, CGRectGetWidth(bounds));
    [self label:@"KESTREL FRONTIER  /  FLIGHT MANUAL" size:12 color:UIAmber opacity:1 x:x y:y - 8];
    [self label:@"Flight controls" size:MIN(34, CGRectGetHeight(bounds) * 0.09) color:MenuTitle opacity:1 x:x y:y - 43].fontName = UIMonoBoldFont;
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
    for (NSUInteger i = 0; i < bindings.count; i++) {
        CGFloat rowY = y - 77 - i * line;
        [self label:bindings[i][0] size:font color:MenuTitle opacity:0.92 x:x y:rowY];
        SKLabelNode *key = [self label:bindings[i][1] size:font color:UIInk opacity:0.9 x:x + width - 4 y:rowY];
        key.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
    }
    _controlsBack = CGRectMake(x, CGRectGetMinY(bounds), MIN(210, width), 44);
    [_root addChild:UIActionButton(_controlsBack, @"‹  MAIN MENU", UIAmber)];
}

- (MainMenuInsets)layoutInsets {
#if TARGET_OS_IOS
    if (self.view) return self.view.safeAreaInsets;
#endif
    return self.contentInsets;
}

- (void)rebuild {
    [_root removeAllChildren];
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
    SKSpriteNode *backdrop = [SKSpriteNode spriteNodeWithColor:self.backgroundColor size:self.size];
    backdrop.anchorPoint = CGPointZero;
    backdrop.zPosition = -2;
    [_root addChild:backdrop];
    if (availableWidth < 120 || top - bottom < 220) return;
    [self drawArtPortrait:portrait];

    if (_controls) {
        SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(MenuNight, 0.8) size:self.size];
        shade.anchorPoint = CGPointZero;
        shade.zPosition = -0.5;
        [_root addChild:shade];
        [self drawControlsIn:CGRectMake(left, bottom, availableWidth, top - bottom)];
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

    [self label:@"CNS BASTION   /   LANCER FLIGHT" size:compact ? 10 : 13 color:UIAmber opacity:0.96
              x:left + 2 y:stackTop + header - 6];
    CGFloat titleY = stackTop + header - (compact ? 19 : 29);
    SKLabelNode *wordmark = [self label:oneLine ? @"KESTREL FRONTIER" : @"KESTREL"
                                   size:titleSize color:MenuTitle opacity:1 x:left y:titleY];
    wordmark.fontName = @"HelveticaNeue-CondensedBlack";
    wordmark.verticalAlignmentMode = SKLabelVerticalAlignmentModeTop;
    if (!oneLine) {
        SKLabelNode *secondLine = [self label:@"FRONTIER" size:titleSize color:MenuTitle opacity:1
                                          x:left y:titleY - titleSize * 0.85];
        secondLine.fontName = wordmark.fontName;
        secondLine.verticalAlignmentMode = SKLabelVerticalAlignmentModeTop;
    }

    NSArray<NSString *> *labels = @[_campaignLabel, @"MISSION SELECT", @"LAN CO-OP", @"FLIGHT CONTROLS", @"QUIT GAME"];
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat y = stackTop - (i + 1) * rowHeight - i * gap;
        _rows[i] = CGRectMake(left, y, width, rowHeight);
        [self drawButton:labels[i] detail:i == MenuItemCampaign ? _missionLabel : nil rect:_rows[i]
                 selected:i == _selected compact:compact];
    }
    if (!compact) {
        [self label:@"↑ / ↓   SELECT       ↵   CONFIRM" size:11 color:UIInk opacity:0.6 x:left y:bottom];
        SKLabelNode *caption = [self label:@"LANCER 01   /   EXECUTIONER" size:11 color:UIInk opacity:0.6
                                        x:self.size.width - _usedInsets.right - margin y:bottom];
        caption.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
    }
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
            [self rebuild];
        }
        return MainMenuCommandNone;
    }

    NSUInteger count = [self itemCount];
    if (actions & InputActionUp) { _selected = (_selected + count - 1) % count; [self rebuild]; }
    if (actions & InputActionDown) { _selected = (_selected + 1) % count; [self rebuild]; }
    for (NSUInteger i = 0; i < count; i++) {
        if (CGRectContainsPoint(_rows[i], click)) {
            _selected = i;
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
