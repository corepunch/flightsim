#import "UI.h"
#import "Common.h"

// MARK: - ScreenRegions

// The space a plated bar keeps above and below its row. A phone's row is
// already taller than its icons, so it needs none.
static CGFloat PlatePadding(BOOL compact) { return compact ? 0 : 6; }

ScreenRegions ScreenRegionsMake(CGSize size, ScreenInsets safe) {
    return ScreenRegionsMakePlated(size, safe, NO);
}

ScreenRegions ScreenRegionsMakePlated(CGSize size, ScreenInsets safe, BOOL plated) {
    ScreenRegions r = { .compact = MIN(size.width, size.height) <= 500 };
    // Content keeps clear of the side insets; the bars' controls may reach
    // halfway into them, since phones keep their sensor housing at mid-height.
    CGFloat side = MAX(MIN(50, size.width * 0.05), MAX(safe.left, safe.right) + 12), edge = side / 2;
    CGFloat headerTop = size.height - safe.top - (plated ? PlatePadding(r.compact) : r.compact ? 10 : 16);
    r.header = RectFromEdges(edge, headerTop - [TitleBar heightCompact:r.compact], size.width - edge, headerTop);
    CGFloat bottom = safe.bottom + (r.compact ? 8 : 16);
    CGFloat bodyTop = CGRectGetMinY(r.header) - 12;
    CGFloat bodyBottom = bottom;
    r.body = RectFromEdges(side, bodyBottom, size.width - side, MAX(bodyBottom, bodyTop));
    r.bodyToEdge = !r.compact ? r.body : RectFromEdges(side, 0, size.width - side, CGRectGetMaxY(r.body));
    return r;
}

// MARK: - TitleBar

// Centers of the authored glyph ink inside each atlas tile. Keeping these
// anchors per state aligns the artwork without changing or recoloring it.
static const CGPoint CommandInkCenters[UICommandStateCount][UICommandIconCount] = {
    {{0.5772, 0.4400}, {0.5882, 0.4400}, {0.5791, 0.4367}, {0.5534, 0.4333}, {0.5377, 0.4400}, {0.5286, 0.4400}, {0.5062, 0.4100}, {0.4838, 0.4233}, {0.4981, 0.4400}, {0.4990, 0.4500}, {0.4800, 0.4300}, {0.4342, 0.4333}, {0.4152, 0.4300}, {0.4194, 0.4200}},
    {{0.5739, 0.4367}, {0.5882, 0.4367}, {0.5791, 0.4333}, {0.5534, 0.4300}, {0.5410, 0.4367}, {0.5286, 0.4367}, {0.5062, 0.4067}, {0.4838, 0.4200}, {0.4981, 0.4333}, {0.4990, 0.4433}, {0.4800, 0.4300}, {0.4276, 0.4300}, {0.4152, 0.4233}, {0.4194, 0.4100}},
    {{0.5806, 0.4767}, {0.5882, 0.4733}, {0.5791, 0.4767}, {0.5534, 0.4700}, {0.5377, 0.4767}, {0.5319, 0.4700}, {0.5095, 0.4467}, {0.4838, 0.4500}, {0.5014, 0.4700}, {0.4990, 0.4800}, {0.4800, 0.4633}, {0.4309, 0.4667}, {0.4185, 0.4567}, {0.4194, 0.4467}},
    {{0.5705, 0.5033}, {0.5882, 0.4933}, {0.5791, 0.4933}, {0.5534, 0.4900}, {0.5410, 0.4967}, {0.5286, 0.4967}, {0.5062, 0.4667}, {0.4838, 0.4767}, {0.5048, 0.4967}, {0.4990, 0.5000}, {0.4800, 0.4867}, {0.4309, 0.4867}, {0.4185, 0.4800}, {0.4194, 0.4733}},
    {{0.5705, 0.5233}, {0.5882, 0.5233}, {0.5791, 0.5233}, {0.5534, 0.5100}, {0.5410, 0.5200}, {0.5286, 0.5200}, {0.5062, 0.4900}, {0.4838, 0.5067}, {0.5014, 0.5233}, {0.4990, 0.5233}, {0.4766, 0.5167}, {0.4342, 0.5133}, {0.4185, 0.5067}, {0.4194, 0.4967}}
};

SKTexture *UICommandTexture(UICommandIcon icon, UICommandState state) {
    static SKTexture *atlas;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ atlas=[SKTexture textureWithImageNamed:@"UI/Icons/TitleBar.png"]; });
    icon=MAX(0,MIN(UICommandIconCount-1,icon)); state=MAX(0,MIN(UICommandStateCount-1,state));
    CGRect tile=CGRectMake((CGFloat)icon/UICommandIconCount,(CGFloat)(UICommandStateCount-1-state)/UICommandStateCount,
                           1.0/UICommandIconCount,1.0/UICommandStateCount);
    return [SKTexture textureWithRect:tile inTexture:atlas];
}

@interface UIBarAction ()
@property (nonatomic, copy) NSString *title;
@property (nonatomic) UICommandIcon icon;
@property (nonatomic) UIRGB accent;
@property (nonatomic, copy) void (^handler)(void);
@end

@implementation UIBarAction
+ (instancetype)title:(NSString *)title accent:(UIRGB)accent handler:(void (^)(void))handler {
    return [self title:title icon:UICommandNext accent:accent handler:handler];
}
+ (instancetype)title:(NSString *)title icon:(UICommandIcon)icon accent:(UIRGB)accent handler:(void (^)(void))handler {
    UIBarAction *action = [self new];
    action.title = title; action.icon=icon; action.accent = accent; action.handler = handler; action.enabled = YES;
    return action;
}
@end

// Geometry, artwork and behavior stay together as the bar is composed.
@interface UIBarControl : NSObject
@property (nonatomic) SKShapeNode *node;
@property (nonatomic) CGRect rect;
@property (nonatomic) UIBarAction *item;
@property (nonatomic) id outline;
@property (nonatomic) SKSpriteNode *icon;
@property (nonatomic) BOOL hovered, pressed;
@end
@implementation UIBarControl
@end

@implementation TitleBar {
    CGRect _row;
    CGFloat _backRight;      // right end of the back control, or the row's left end
    CGFloat _actionsLeft;    // left end of the leftmost action, or the row's right end
    NSMutableArray<UIBarControl *> *_entries;
    BOOL _compact;
    CGFloat _actionWidthLimit;
}

+ (CGFloat)heightCompact:(BOOL)compact { return compact ? 68 : 44; }

- (instancetype)initWithHeader:(CGRect)header compact:(BOOL)compact back:(UIBarAction *)back
                         title:(NSString *)title kicker:(NSString *)kicker actions:(NSArray<UIBarAction *> *)actions {
    if ((self = [super init])) {
        _compact = compact;
        _height = [TitleBar heightCompact:compact];
        _fontSize = 17;
        _row = CGRectMake(CGRectGetMinX(header), CGRectGetMidY(header) - _height / 2, CGRectGetWidth(header), _height);
        _backRight = CGRectGetMinX(_row);
        _actionsLeft = CGRectGetMaxX(_row);
        _entries = [NSMutableArray array];
        if (back) [self addBack:back];
        CGFloat available = CGRectGetMaxX(_row) - _backRight - (back ? 16 : 0);
        CGFloat titleSpace = title.length ? MIN(100, available * 0.25) : 0;
        _actionWidthLimit = MAX(44, MIN(CGRectGetWidth(_row) * 0.4,
            (available - titleSpace - 16) / MAX((NSUInteger)1, actions.count)));
        for (UIBarAction *item in actions) [self addAction:item];
        if (title.length) [self setTitle:title kicker:kicker];
    }
    return self;
}

- (CGRect)row { return _row; }
- (NSArray<SKShapeNode *> *)controls {
    NSMutableArray *nodes = [NSMutableArray array];
    for (UIBarControl *entry in _entries) [nodes addObject:entry.node];
    return nodes;
}

- (CGRect)rectForAction:(UIBarAction *)action {
    for (UIBarControl *entry in _entries) if (entry.item == action) return entry.rect;
    return CGRectZero;
}

- (BOOL)activateAt:(CGPoint)point {
    // Slanted neighbors overlap in bounding boxes, so hit the stored silhouette.
    for (UIBarControl *entry in _entries) {
        if (!CGPathContainsPoint((__bridge CGPathRef)entry.outline, NULL, point, NO)) continue;
        if (entry.item.enabled && entry.item.handler) entry.item.handler();
        return YES;
    }
    return NO;
}

- (CGRect)lane {
    CGFloat left = _backRight > CGRectGetMinX(_row) ? _backRight + 16 : CGRectGetMinX(_row);
    CGFloat right = _actionsLeft < CGRectGetMaxX(_row) ? _actionsLeft - 16 : CGRectGetMaxX(_row);
    return RectFromEdges(left, CGRectGetMinY(_row), MAX(left, right), CGRectGetMaxY(_row));
}

- (UICommandState)iconState:(UIBarControl *)entry {
    if (!entry.item.enabled) return UICommandDisabled;
    if (entry.pressed) return UICommandPressed;
    if (entry.hovered) return UICommandHover;
    return entry.item.iconState;
}
- (void)updateIcon:(UIBarControl *)entry {
    UICommandState state = [self iconState:entry];
    entry.icon.texture = UICommandTexture(entry.item.icon, state);
    entry.icon.anchorPoint = CommandInkCenters[state][entry.item.icon];
}
- (UIBarControl *)keep:(SKShapeNode *)node rect:(CGRect)rect item:(UIBarAction *)item outline:(CGPathRef)outline back:(BOOL)back {
    UIBarControl *entry = [UIBarControl new];
    entry.node = node; entry.rect = rect; entry.item = item; entry.outline = (__bridge id)outline;
    if (_compact) {
        CGPathRef hit = CGPathCreateWithRect(rect, NULL);
        entry.outline = (__bridge id)hit; CGPathRelease(hit);
        node.strokeColor = SKColor.clearColor;
        node.fillColor = SKColor.clearColor;
    }
    node.name=item.title;
    SKLabelNode *label=(SKLabelNode *)node.children.firstObject;
    label.text=_compact ? @"" : item.title;
    label.hidden=_compact;
    label.horizontalAlignmentMode=SKLabelHorizontalAlignmentModeLeft;
    CGFloat iconSize=_compact ? 54 : 28, gap=_compact ? 0 : 8;
    CGRect inner=RectInsetEdges(rect,back ? UIBackControlTip(rect) : CGRectGetHeight(rect)*UISlant,0,12,0);
    if (_compact) inner=rect;
    UIFitControlLabel(label,MAX(1,CGRectGetWidth(inner)-iconSize-gap));
    CGFloat group=iconSize+gap+CGRectGetWidth(label.frame);
    CGFloat left=CGRectGetMidX(inner)-group/2;
    entry.icon=[SKSpriteNode spriteNodeWithTexture:UICommandTexture(item.icon,[self iconState:entry])];
    entry.icon.size=CGSizeMake(iconSize,iconSize);
    [self updateIcon:entry];
    entry.icon.position=_compact ? RectCenter(rect) : CGPointMake(left+iconSize/2,CGRectGetMidY(rect));
    [node addChild:entry.icon];
    label.position=CGPointMake(left+iconSize+gap,CGRectGetMidY(rect));
    UICenterLabelVertically(label,CGRectGetMidY(rect));
    if (!item.enabled) {
        if (!_compact) node.strokeColor=[node.strokeColor colorWithAlphaComponent:0.35];
        label.alpha=0.35;
    }
    [self addChild:node]; [_entries addObject:entry];
    return entry;
}
- (void)beginAt:(CGPoint)point {
    for (UIBarControl *entry in _entries) {
        entry.pressed=entry.item.enabled && CGPathContainsPoint((__bridge CGPathRef)entry.outline,NULL,point,NO);
        [self updateIcon:entry];
    }
}
- (void)endPress { for (UIBarControl *entry in _entries) { entry.pressed=NO; [self updateIcon:entry]; } }

- (void)addBack:(UIBarAction *)item {
    CGFloat width = _compact ? _height+8 : MIN(CGRectGetWidth(_row) * 0.4, UIBackControlWidth(item.title, _height, _fontSize)+36);
    CGRect rect = CGRectMake(CGRectGetMinX(_row), CGRectGetMinY(_row), width, _height);
    _backRight = CGRectGetMaxX(rect);
    CGPathRef outline = UICreateBackControlPath(rect);
    [self keep:UIBackControl(rect, @"", item.accent, _fontSize) rect:rect item:item outline:outline back:YES];
    CGPathRelease(outline);
}

- (void)addAction:(UIBarAction *)item {
    CGFloat label = UIButtonLabel(item.title, _fontSize, CGPointZero).frame.size.width + _height * UISlant + 68;
    CGFloat width = _compact ? _height+4 : MIN(_actionWidthLimit, MAX(144, label));
    // Neighboring slanted edges nest while retaining a visible gutter.
    CGFloat right = !_action ? CGRectGetMaxX(_row) : _actionsLeft + MIN(_height * UISlant, width * 0.25) - 6;
    CGRect rect = CGRectMake(right - width, CGRectGetMinY(_row), width, _height);
    _actionsLeft = CGRectGetMinX(rect);
    SKShapeNode *button = UIActionButtonSized(rect, @"", item.accent, _fontSize);
    CGPathRef outline = UICreateSkewedPath(rect);
    [self keep:button rect:rect item:item outline:outline back:NO];
    CGPathRelease(outline);
    if (!_action) _action = button;
}

- (void)setTitle:(NSString *)title kicker:(NSString *)kicker {
    [_titleLabel removeFromParent];
    [_kickerLabel removeFromParent];
    _titleLabel = nil; _kickerLabel = nil;
    CGRect lane = self.lane;
    CGFloat titleSize = _compact ? 20 : 26, kickerSize = 14, gap = 3;
    SKLabelNode *(^line)(NSString *, CGFloat, CGFloat) = ^SKLabelNode *(NSString *text, CGFloat size, CGFloat opacity) {
        SKLabelNode *label = UIInterfaceLabel(size, UIColorWithOpacity(UIInk, opacity), SKLabelHorizontalAlignmentModeLeft,
                                              SKLabelVerticalAlignmentModeCenter);
        label.text = text;
        label.numberOfLines = 1;
        label.preferredMaxLayoutWidth = MAX(1, lane.size.width);
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        return label;
    };
    if (kicker.length) {
        _kickerLabel = line(kicker, kickerSize, 0.65);
        [self addChild:_kickerLabel];
    }
    _titleLabel = line(title, titleSize, 1);
    _titleLabel.fontName = UIInterfaceBoldFont;
    UIFitControlLabel(_titleLabel, CGRectGetWidth(lane));
    if (_kickerLabel) UIFitControlLabel(_kickerLabel, CGRectGetWidth(lane));
    // Center the rendered text block, including the kicker, on the same axis
    // as the command glyphs. Font sizes do not describe their visible bounds.
    CGFloat titleHeight = CGRectGetHeight(_titleLabel.frame);
    CGFloat kickerHeight = _kickerLabel ? CGRectGetHeight(_kickerLabel.frame) : 0;
    CGFloat stack = titleHeight + (_kickerLabel ? kickerHeight + gap : 0);
    CGFloat bottom = CGRectGetMidY(_row) - stack/2;
    _titleLabel.position = CGPointMake(CGRectGetMinX(lane), 0);
    UICenterLabelVertically(_titleLabel, bottom + titleHeight/2);
    if (_kickerLabel) {
        _kickerLabel.position = CGPointMake(CGRectGetMinX(lane), 0);
        UICenterLabelVertically(_kickerLabel, bottom + titleHeight + gap + kickerHeight/2);
    }
    [self addChild:_titleLabel];
}

- (void)registerHover:(UIHover *)hover {
    for (UIBarControl *entry in _entries) {
        if (!entry.item.enabled) continue;
        __weak TitleBar *owner=self;
        __weak UIBarControl *control=entry;
        // Compact commands use only their authored glyph states for feedback.
        CGPathRef empty = _compact ? CGPathCreateMutable() : NULL;
        [hover addButton:entry.node rect:entry.rect accent:entry.item.accent outline:empty ?: (__bridge CGPathRef)entry.outline hoverChanged:^(BOOL hovered) {
            UIBarControl *live=control; live.hovered=hovered; [owner updateIcon:live];
        }];
        if (empty) CGPathRelease(empty);
    }
}

- (void)addPlateForSceneSize:(CGSize)size {
    _plateRect = RectFromEdges(0, CGRectGetMinY(_row) - PlatePadding(_compact), size.width, size.height);
    SKSpriteNode *plate = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIBackground, 0.9) size:_plateRect.size];
    plate.position = RectCenter(_plateRect);
    plate.zPosition = -1;
    [self addChild:plate];
    SKSpriteNode *rule = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.7)
                                                      size:CGSizeMake(_plateRect.size.width, 1.5)];
    rule.position = CGPointMake(CGRectGetMidX(_plateRect), CGRectGetMinY(_plateRect));
    rule.zPosition = -0.5;
    [self addChild:rule];
}

- (void)revealAfter:(NSTimeInterval)delay {
    NSUInteger i = 0;
    for (UIBarControl *entry in _entries) {
        UIMotionSlideIn(entry.node, CGVectorMake(0, 44), delay + 0.05 * i++, 0.32);
    }
    if (_kickerLabel) UIMotionDecode(_kickerLabel, delay, 0.4);
    if (_titleLabel) UIMotionDecode(_titleLabel, delay + 0.07, 0.45);
}

@end
