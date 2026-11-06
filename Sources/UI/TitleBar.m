#import "UI.h"
#import "Common.h"

// MARK: - ScreenRegions

ScreenRegions ScreenRegionsMake(CGSize size, ScreenInsets safe, CGFloat footerHeight) {
    ScreenRegions r = { .compact = MIN(size.width, size.height) <= 500 };
    // Content keeps clear of the side insets; the bars' controls may reach
    // halfway into them, since phones keep their sensor housing at mid-height.
    CGFloat side = MAX(MIN(50, size.width * 0.05), MAX(safe.left, safe.right) + 12), edge = side / 2;
    CGFloat headerTop = size.height - safe.top - (r.compact ? 10 : 16);
    r.header = RectFromEdges(edge, headerTop - [TitleBar heightCompact:r.compact], size.width - edge, headerTop);
    CGFloat bottom = safe.bottom + (r.compact ? 8 : 16);
    if (footerHeight > 0) r.footer = RectFromEdges(side, bottom, size.width - side, bottom + footerHeight);
    CGFloat bodyTop = CGRectGetMinY(r.header) - 12;
    CGFloat bodyBottom = footerHeight > 0 ? CGRectGetMaxY(r.footer) + 12 : bottom;
    r.body = RectFromEdges(side, bodyBottom, size.width - side, MAX(bodyBottom, bodyTop));
    r.bodyToEdge = footerHeight > 0 || !r.compact ? r.body : RectFromEdges(side, 0, size.width - side, CGRectGetMaxY(r.body));
    return r;
}

// MARK: - TitleBar

@interface UIBarAction ()
@property (nonatomic, copy) NSString *title;
@property (nonatomic) UIRGB accent;
@property (nonatomic, copy) void (^handler)(void);
@end

@implementation UIBarAction
+ (instancetype)title:(NSString *)title accent:(UIRGB)accent handler:(void (^)(void))handler {
    UIBarAction *action = [self new];
    action.title = title; action.accent = accent; action.handler = handler; action.enabled = YES;
    return action;
}
@end

// Geometry, artwork and behavior stay together as the bar is composed.
@interface UIBarControl : NSObject
@property (nonatomic) SKShapeNode *node;
@property (nonatomic) CGRect rect;
@property (nonatomic) UIBarAction *item;
@property (nonatomic) id outline;
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

+ (CGFloat)heightCompact:(BOOL)compact { return compact ? 52 : 44; }

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

- (void)keep:(SKShapeNode *)node rect:(CGRect)rect item:(UIBarAction *)item outline:(CGPathRef)outline {
    UIBarControl *entry = [UIBarControl new];
    entry.node = node; entry.rect = rect; entry.item = item; entry.outline = (__bridge id)outline;
    node.alpha = item.enabled ? 1 : 0.35;
    [self addChild:node]; [_entries addObject:entry];
}

- (void)addBack:(UIBarAction *)item {
    CGFloat width = MIN(CGRectGetWidth(_row) * 0.4, UIBackControlWidth(item.title, _height, _fontSize));
    CGRect rect = CGRectMake(CGRectGetMinX(_row), CGRectGetMinY(_row), width, _height);
    _backRight = CGRectGetMaxX(rect);
    CGPathRef outline = UICreateBackControlPath(rect);
    [self keep:UIBackControl(rect, item.title, item.accent, _fontSize) rect:rect item:item outline:outline];
    CGPathRelease(outline);
}

- (void)addAction:(UIBarAction *)item {
    CGFloat label = UIButtonLabel(item.title, _fontSize, CGPointZero).frame.size.width + _height * UISlant + 32;
    CGFloat width = MIN(_actionWidthLimit, MAX(_compact ? 132 : 144, label));
    // Neighboring slanted edges nest while retaining a visible gutter.
    CGFloat right = !_action ? CGRectGetMaxX(_row) : _actionsLeft + MIN(_height * UISlant, width * 0.25) - 6;
    CGRect rect = CGRectMake(right - width, CGRectGetMinY(_row), width, _height);
    _actionsLeft = CGRectGetMinX(rect);
    SKShapeNode *button = UIActionButtonSized(rect, item.title, item.accent, _fontSize);
    CGPathRef outline = UICreateSkewedPath(rect);
    [self keep:button rect:rect item:item outline:outline];
    CGPathRelease(outline);
    if (!_action) _action = button;
}

- (void)setTitle:(NSString *)title kicker:(NSString *)kicker {
    [_titleLabel removeFromParent];
    [_kickerLabel removeFromParent];
    CGRect lane = self.lane;
    CGFloat titleSize = _compact ? 20 : 26, kickerSize = 14, gap = 3;
    SKLabelNode *(^line)(NSString *, CGFloat, CGFloat) = ^SKLabelNode *(NSString *text, CGFloat size, CGFloat opacity) {
        SKLabelNode *label = UIInterfaceLabel(size, UIColorWithOpacity(UIInk, opacity), SKLabelHorizontalAlignmentModeLeft,
                                              SKLabelVerticalAlignmentModeTop);
        label.text = text;
        label.numberOfLines = 1;
        label.preferredMaxLayoutWidth = MAX(1, lane.size.width);
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        return label;
    };
    // Kicker over title, the pair centred on the bar.
    CGFloat stack = titleSize + (kicker.length ? kickerSize + gap : 0);
    CGFloat top = CGRectGetMidY(_row) + stack / 2;
    if (kicker.length) {
        _kickerLabel = line(kicker, kickerSize, 0.65);
        _kickerLabel.position = CGPointMake(CGRectGetMinX(lane), top);
        [self addChild:_kickerLabel];
        top -= kickerSize + gap;
    }
    _titleLabel = line(title, titleSize, 1);
    _titleLabel.fontName = UIInterfaceBoldFont;
    UIFitControlLabel(_titleLabel, CGRectGetWidth(lane));
    if (_kickerLabel) UIFitControlLabel(_kickerLabel, CGRectGetWidth(lane));
    _titleLabel.position = CGPointMake(CGRectGetMinX(lane), top);
    [self addChild:_titleLabel];
}

- (void)registerHover:(UIHover *)hover {
    for (UIBarControl *entry in _entries) {
        if (!entry.item.enabled) continue;
        [hover addButton:entry.node rect:entry.rect accent:entry.item.accent outline:(__bridge CGPathRef)entry.outline];
    }
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

// MARK: - UIInfoBar

@implementation UIInfoBar {
    TitleBar *_controls;
}
+ (CGFloat)heightCompact:(BOOL)compact { return [TitleBar heightCompact:compact] + 16; }
- (instancetype)initWithRegion:(CGRect)region compact:(BOOL)compact console:(BOOL)console
                          info:(NSString *)info action:(UIBarAction *)action {
    if ((self = [super init])) {
        _row = region;
        [self addChild:UIControlRail(region, console)];
        CGRect inner = CGRectInset(region, 16, 8);
        _controls = [[TitleBar alloc] initWithHeader:inner compact:compact back:nil title:nil kicker:nil
                                           actions:action ? @[action] : @[]];
        [self addChild:_controls];
        _actionRect = [_controls rectForAction:action];
        _action = _controls.action;
        CGRect lane = _controls.lane;
        // Keep the hint inside the rail's slanted leading edge.
        lane = RectInsetEdges(lane, CGRectGetHeight(region) * UISlant, 0, 0, 0);
        _infoLabel = UIInterfaceLabel(16, UIColorWithOpacity(UIInk, console ? 1 : 0.85),
            SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeCenter);
        _infoLabel.text = info;
        _infoLabel.numberOfLines = 0;
        _infoLabel.preferredMaxLayoutWidth = MAX(1, CGRectGetWidth(lane));
        _infoLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        // Fit paragraphs explicitly as well: SpriteKit can silently clip the
        // final line instead of drawing an ellipsis with numberOfLines = 2.
        NSString *text = info ?: @"";
        while (CGRectGetHeight(_infoLabel.frame) > CGRectGetHeight(inner) && text.length) {
            NSRange last = [text rangeOfComposedCharacterSequenceAtIndex:text.length - 1];
            text = [text substringToIndex:last.location];
            _infoLabel.text = text.length ? [text stringByAppendingString:@"…"] : @"";
        }
        _infoLabel.position = CGPointMake(CGRectGetMinX(lane), CGRectGetMidY(region));
        UICenterLabelVertically(_infoLabel, CGRectGetMidY(region));
        [self addChild:_infoLabel];
    }
    return self;
}
- (BOOL)activateAt:(CGPoint)point { return [_controls activateAt:point]; }
- (void)registerHover:(UIHover *)hover { [_controls registerHover:hover]; }
@end
