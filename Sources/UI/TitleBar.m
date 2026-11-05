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

@implementation TitleBar {
    CGRect _row;
    CGFloat _backRight;      // right end of the back control, or the row's left end
    CGFloat _actionsLeft;    // left end of the leftmost action, or the row's right end
    NSMutableArray<SKShapeNode *> *_drawn;
    NSMutableArray<NSValue *> *_rects;
    NSMutableArray<NSValue *> *_accents;   // boxed UIRGB, for hover
    NSMutableArray *_outlines;             // CGPathRefs, for hover; kCFNull for the action shape
    BOOL _compact;
}

+ (CGFloat)heightCompact:(BOOL)compact { return compact ? 52 : 44; }

- (instancetype)initWithHeader:(CGRect)header compact:(BOOL)compact {
    if ((self = [super init])) {
        _compact = compact;
        _height = [TitleBar heightCompact:compact];
        _fontSize = compact ? 17 : 13;
        _row = CGRectMake(CGRectGetMinX(header), CGRectGetMaxY(header) - _height, CGRectGetWidth(header), _height);
        _backRight = CGRectGetMinX(_row);
        _actionsLeft = CGRectGetMaxX(_row);
        _drawn = [NSMutableArray array];
        _rects = [NSMutableArray array];
        _accents = [NSMutableArray array];
        _outlines = [NSMutableArray array];
    }
    return self;
}

- (CGRect)row { return _row; }
- (NSArray<SKShapeNode *> *)controls { return _drawn; }

- (CGRect)lane {
    CGFloat left = _backRight > CGRectGetMinX(_row) ? _backRight + 16 : CGRectGetMinX(_row);
    CGFloat right = _actionsLeft < CGRectGetMaxX(_row) ? _actionsLeft - 16 : CGRectGetMaxX(_row);
    return RectFromEdges(left, CGRectGetMinY(_row), MAX(left, right), CGRectGetMaxY(_row));
}

- (void)keep:(SKShapeNode *)node rect:(CGRect)rect accent:(UIRGB)accent outline:(CGPathRef)outline {
    [_outlines addObject:outline ? (__bridge id)outline : (id)kCFNull];
    [self addChild:node];
    [_drawn addObject:node];
    [_rects addObject:BoxRect(rect)];
    [_accents addObject:[NSValue valueWithBytes:&accent objCType:@encode(UIRGB)]];
}

- (CGRect)addBack:(NSString *)title accent:(UIRGB)accent {
    CGRect rect = CGRectMake(CGRectGetMinX(_row), CGRectGetMinY(_row), UIBackControlWidth(title, _height, _fontSize), _height);
    _backRight = CGRectGetMaxX(rect);
    CGPathRef outline = UICreateBackControlPath(rect);
    [self keep:UIBackControl(rect, title, accent, _fontSize) rect:rect accent:accent outline:outline];
    CGPathRelease(outline);
    return rect;
}

- (CGRect)addAction:(NSString *)title accent:(UIRGB)accent minWidth:(CGFloat)minWidth {
    CGFloat label = UIButtonLabel(title, _fontSize, CGPointZero).frame.size.width + _height * UISlant + 32;
    CGFloat width = MIN(_row.size.width * 0.4, MAX(minWidth, label));
    // The first sits in the corner; later ones tuck under the slanted edge of
    // the one to their right.
    BOOL first = !_action;
    CGFloat right = first ? CGRectGetMaxX(_row) : _actionsLeft + MIN(_height * UISlant, width * 0.25) - 6;
    CGRect rect = CGRectMake(right - width, CGRectGetMinY(_row), width, _height);
    _actionsLeft = CGRectGetMinX(rect);
    SKShapeNode *button = UIActionButtonSized(rect, title, accent, _fontSize);
    [self keep:button rect:rect accent:accent outline:NULL];
    if (first) _action = button;
    return rect;
}

- (void)setTitle:(NSString *)title kicker:(NSString *)kicker {
    [_titleLabel removeFromParent];
    [_kickerLabel removeFromParent];
    CGRect lane = self.lane;
    CGFloat titleSize = _compact ? 20 : 26, kickerSize = _compact ? 11 : 12, gap = 3;
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
    _titleLabel.position = CGPointMake(CGRectGetMinX(lane), top);
    [self addChild:_titleLabel];
}

- (void)registerHover:(UIHover *)hover {
    for (NSUInteger i = 0; i < _drawn.count; i++) {
        UIRGB accent;
        [_accents[i] getValue:&accent size:sizeof(accent)];
        id outline = _outlines[i];
        [hover addButton:_drawn[i] rect:UnboxRect(_rects[i]) accent:accent
                 outline:outline == (id)kCFNull ? NULL : (__bridge CGPathRef)outline];
    }
}

- (void)revealAfter:(NSTimeInterval)delay {
    for (NSUInteger i = 0; i < _drawn.count; i++)
        UIMotionSlideIn(_drawn[i], CGVectorMake(0, 44), delay + 0.05 * i, 0.32);
    if (_kickerLabel) UIMotionDecode(_kickerLabel, delay, 0.4);
    if (_titleLabel) UIMotionDecode(_titleLabel, delay + 0.07, 0.45);
}

@end
