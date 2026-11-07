#import "UI.h"

CGPoint UIScrollContentPosition(CGRect region, CGSize contentSize, CGFloat offset) {
    CGFloat inset=MAX(0,(CGRectGetHeight(region)-contentSize.height)/2);
    return CGPointMake(CGRectGetMidX(region)-contentSize.width/2,CGRectGetMaxY(region)-inset+offset);
}

typedef NS_ENUM(NSInteger, SettingKind) { SettingChoice, SettingSlider, SettingAction };

@interface UISettingItem ()
@property SettingKind kind;
@property (copy) NSString *title, *valueTitle, *detail;
@property float value, minimum, maximum, step;
@property (copy) void (^action)(void);
@property (copy) void (^change)(float);
@property (copy) NSString *(^text)(float);
@end

@implementation UISettingItem
+ (instancetype)choice:(NSString *)title value:(NSString *)value detail:(NSString *)detail action:(void (^)(void))action {
    UISettingItem *item = [self new];
    item.enabled = YES;
    item.kind = SettingChoice; item.title = title; item.valueTitle = value; item.detail = detail; item.action = action;
    return item;
}
+ (instancetype)slider:(NSString *)title value:(float)value minimum:(float)minimum maximum:(float)maximum
                 step:(float)step text:(NSString *(^)(float))text change:(void (^)(float))change {
    UISettingItem *item = [self new];
    item.enabled = YES;
    item.kind = SettingSlider; item.title = title; item.value = value; item.minimum = minimum; item.maximum = maximum;
    item.step = step; item.text = text; item.change = change;
    return item;
}
+ (instancetype)action:(NSString *)title value:(NSString *)value action:(void (^)(void))action {
    UISettingItem *item = [self choice:title value:value detail:nil action:action];
    item.kind = SettingAction;
    return item;
}
@end

// The inset is an invariant of the engine control, never a screen parameter.
static const CGFloat SettingInset = 16, SettingControlHeight = 44, SettingGap = 10;

@interface UISettingRow : SKNode
- (instancetype)initWithItem:(UISettingItem *)item width:(CGFloat)width compact:(BOOL)compact;
@property (nonatomic, readonly) CGRect rowRect, controlRect, titleRect;
@property (nonatomic, readonly) CGFloat height;
@property (nonatomic) BOOL selected;
- (void)setSliderAt:(CGPoint)point;
- (void)adjust:(NSInteger)direction;
@end

@implementation UISettingRow {
    UISettingItem *_item;
    SKShapeNode *_background, *_rail, *_fill;
    SKLabelNode *_valueLabel;
    SKCropNode *_progress;
}
- (instancetype)initWithItem:(UISettingItem *)item width:(CGFloat)width compact:(BOOL)compact {
    if ((self = [super init])) {
        _item = item;
        BOOL stacked = !compact && width < 540;
        CGFloat innerWidth = MAX(1, width - 2 * SettingInset);
        CGFloat controlWidth = stacked ? innerWidth : MIN(compact ? 160 : 260, innerWidth * 0.47);
        SKLabelNode *title = UIInterfaceLabel(compact ? 14 : 16, UIColorWithOpacity(UIMenuTitle, 1), SKLabelHorizontalAlignmentModeLeft,
                                              SKLabelVerticalAlignmentModeCenter);
        title.text = item.title;
        title.numberOfLines = 0;
        title.preferredMaxLayoutWidth = stacked ? innerWidth : MAX(1, innerWidth - controlWidth - SettingInset);
        title.lineBreakMode = NSLineBreakByWordWrapping;
        CGFloat titleHeight = CGRectGetHeight(title.frame);
        CGFloat rowHeight = compact ? MAX(56, titleHeight + 16) : stacked ? MAX(112, 2 * SettingInset + titleHeight + 12 + SettingControlHeight) :
                                     2 * SettingInset + MAX(SettingControlHeight, titleHeight);
        _rowRect = CGRectMake(0, -rowHeight, width, rowHeight);
        _height = rowHeight;
        CGRect inner = CGRectInset(_rowRect, SettingInset, SettingInset);
        _controlRect = CGRectMake(stacked ? CGRectGetMinX(inner) : CGRectGetMaxX(inner) - controlWidth,
                                 stacked ? CGRectGetMinY(inner) : CGRectGetMidY(inner) - SettingControlHeight / 2,
                                 controlWidth, SettingControlHeight);
        CGRect titleLane = stacked ? RectFromEdges(CGRectGetMinX(inner), CGRectGetMaxY(_controlRect) + 12,
                                                   CGRectGetMaxX(inner), CGRectGetMaxY(inner)) :
                                     RectFromEdges(CGRectGetMinX(inner), CGRectGetMinY(inner),
                                                   CGRectGetMinX(_controlRect) - SettingInset, CGRectGetMaxY(inner));
        _background = UIReadoutPanel(_rowRect, UIColorWithOpacity(UIInk, 0.35), UIColorWithOpacity(UIInk, 0.04));
        [self addChild:_background];
        title.position = CGPointMake(CGRectGetMinX(titleLane), CGRectGetMidY(titleLane));
        UICenterLabelVertically(title, CGRectGetMidY(titleLane));
        [self addChild:title];
        _titleRect = title.frame;
        _rail = UIActionButtonSized(_controlRect, @"", UIAmber, 14);
        [self addChild:_rail];
        if (item.kind == SettingSlider) {
            _progress = [SKCropNode node];
            _progress.maskNode = UISkewedShape(CGRectInset(_controlRect, 4, 4), SKColor.whiteColor, SKColor.whiteColor);
            _fill = [SKShapeNode node];
            _fill.fillColor = UIColorWithOpacity(UIAmber, 0.38);
            _fill.strokeColor = SKColor.clearColor;
            [_progress addChild:_fill];
            [self addChild:_progress];
        }
        _valueLabel = UIButtonLabel(@"", 17, RectCenter(_controlRect));
        _valueLabel.fontColor = UIColorWithOpacity(UIAmber, 1);
        [self addChild:_valueLabel];
        [self updateValue];
        if (!item.enabled) {
            _rail.alpha=0.35; _valueLabel.alpha=0.45; title.alpha=0.55;
        }
    }
    return self;
}
- (void)setSelected:(BOOL)selected {
    selected = selected && _item.enabled;
    _selected = selected;
    _background.fillColor = UIColorWithOpacity(UIInk, selected ? 0.13 : 0.04);
    _background.strokeColor = UIColorWithOpacity(selected ? UIAmber : UIInk, 0.35);
}
- (void)updateValue {
    _valueLabel.text = _item.kind == SettingSlider ? _item.text(_item.value) : _item.valueTitle;
    UIFitControlLabel(_valueLabel, CGRectGetWidth(_controlRect) - CGRectGetHeight(_controlRect) * UISlant - 20);
    UICenterLabelVertically(_valueLabel, CGRectGetMidY(_controlRect));
    if (_item.kind != SettingSlider) return;
    CGFloat range = _item.maximum - _item.minimum;
    CGFloat fraction = range > 0 ? clampf((_item.value - _item.minimum) / range, 0, 1) : 0;
    CGRect fill = RectFromEdges(CGRectGetMinX(_controlRect), CGRectGetMinY(_controlRect),
                                CGRectGetMinX(_controlRect) + CGRectGetWidth(_controlRect) * fraction, CGRectGetMaxY(_controlRect));
    CGPathRef path = CGPathCreateWithRect(fill, NULL);
    _fill.path = path;
    CGPathRelease(path);
}
- (void)setValue:(float)value {
    _item.value = clampf(value, _item.minimum, _item.maximum);
    if (_item.change) _item.change(_item.value);
    [self updateValue];
}
- (void)setSliderAt:(CGPoint)point {
    CGFloat fraction = clampf(PointFractionInRect(point, _controlRect).x, 0, 1);
    [self setValue:_item.minimum + fraction * (_item.maximum - _item.minimum)];
}
- (void)adjust:(NSInteger)direction {
    [self setValue:_item.value + direction * _item.step];
}
@end

@implementation UISettingsForm {
    NSArray<UISettingItem *> *_items;
    NSArray<UISettingRow *> *_rows;
    NSInteger _draggingIndex;
}
- (instancetype)initWithItems:(NSArray<UISettingItem *> *)items width:(CGFloat)width {
    return [self initWithItems:items width:width compact:NO];
}
- (instancetype)initWithItems:(NSArray<UISettingItem *> *)items width:(CGFloat)width compact:(BOOL)compact {
    if ((self = [super init])) {
        _items = [items copy];
        _draggingIndex = -1;
        NSMutableArray *rows = [NSMutableArray array], *rects = [NSMutableArray array];
        NSMutableArray *controls = [NSMutableArray array], *titles = [NSMutableArray array];
        NSUInteger columns=compact && width>=600 ? 2 : 1, index=0;
        CGFloat columnWidth=(width-SettingGap*(columns-1))/columns;
        CGFloat y = 0, groupHeight=0;
        for (UISettingItem *item in items) {
            CGFloat x=(index%columns)*(columnWidth+SettingGap);
            UISettingRow *row = [[UISettingRow alloc] initWithItem:item width:columnWidth compact:compact];
            row.position = CGPointMake(x, y);
            [self addChild:row];
            [rows addObject:row];
            CGAffineTransform offset = CGAffineTransformMakeTranslation(x, y);
            [rects addObject:BoxRect(CGRectApplyAffineTransform(row.rowRect, offset))];
            [controls addObject:BoxRect(CGRectApplyAffineTransform(row.controlRect, offset))];
            [titles addObject:BoxRect(CGRectApplyAffineTransform(row.titleRect, offset))];
            CGFloat cellHeight=row.height+SettingGap;
            if (item.detail.length) {
                SKLabelNode *detail = UIInterfaceLabel(14, UIColorWithOpacity(UIInk, 1), SKLabelHorizontalAlignmentModeLeft,
                                                       SKLabelVerticalAlignmentModeTop);
                detail.text = item.detail;
                detail.numberOfLines = 0;
                detail.preferredMaxLayoutWidth = MAX(1, columnWidth - 2 * SettingInset);
                detail.lineBreakMode = NSLineBreakByWordWrapping;
                detail.position = CGPointMake(x+SettingInset, y-cellHeight);
                [self addChild:detail];
                cellHeight += CGRectGetHeight(detail.frame) + SettingInset;
            }
            groupHeight=MAX(groupHeight,cellHeight); index++;
            if(index%columns==0 || index==items.count) { y-=groupHeight; groupHeight=0; }
        }
        _height = -y;
        _rows = rows; _rowRects = rects; _controlRects = controls; _titleRects = titles;
        self.selectedIndex = 0;
    }
    return self;
}
- (void)setSelectedIndex:(NSUInteger)index {
    _selectedIndex = MIN(index, _rows.count ? _rows.count - 1 : 0);
    for (NSUInteger i = 0; i < _rows.count; i++) _rows[i].selected = i == _selectedIndex;
}
- (BOOL)dragging { return _draggingIndex >= 0; }
- (void)hoverAt:(CGPoint)point {
    if (self.dragging) return;
    for (NSUInteger i = 0; i < _rowRects.count; i++)
        if (CGRectContainsPoint(UnboxRect(_rowRects[i]), point)) { self.selectedIndex = i; break; }
}
- (void)beginAt:(CGPoint)point {
    [self endDrag];
    for (NSUInteger i = 0; i < _items.count; i++) {
        if (_items[i].enabled && _items[i].kind == SettingSlider && CGRectContainsPoint(UnboxRect(_controlRects[i]), point)) {
            _draggingIndex = i;
            self.selectedIndex = i;
            [self dragTo:point];
            break;
        }
    }
}
- (void)dragTo:(CGPoint)point {
    if (self.dragging) [_rows[_draggingIndex] setSliderAt:PointSub(point, _rows[_draggingIndex].position)];
}
- (void)endDrag { _draggingIndex = -1; }
- (BOOL)clickAt:(CGPoint)point {
    for (NSUInteger i = 0; i < _items.count; i++) {
        if (!CGRectContainsPoint(UnboxRect(_rowRects[i]), point)) continue;
        if (!_items[i].enabled) return NO;
        self.selectedIndex = i;
        if (!CGRectContainsPoint(UnboxRect(_controlRects[i]), point)) return NO;
        if (_items[i].kind == SettingSlider) {
            [_rows[i] setSliderAt:PointSub(point, _rows[i].position)];
            return NO;
        }
        if (_items[i].action) _items[i].action();
        return YES;
    }
    return NO;
}
- (BOOL)adjust:(NSInteger)direction {
    if (!_items.count || !_items[_selectedIndex].enabled) return NO;
    if (_items[_selectedIndex].kind == SettingSlider) { [_rows[_selectedIndex] adjust:direction]; return NO; }
    if (_items[_selectedIndex].action) _items[_selectedIndex].action();
    return YES;
}
@end
