#import "UI.h"

@interface UIStackItem : NSObject
@property (nonatomic, strong) SKNode *node;
@property (nonatomic) CGRect bounds;
@property (nonatomic, strong) NSNumber *verticalCenter;
@end
@implementation UIStackItem
@end

static CGRect NodeLayoutBounds(SKNode *node) {
    CGRect bounds = node.calculateAccumulatedFrame;
    if (CGRectIsNull(bounds) || CGRectIsInfinite(bounds)) return CGRectZero;
    bounds.origin = PointSub(bounds.origin, node.position);
    return bounds;
}

@implementation UIHorizontalStack {
    NSMutableArray<UIStackItem *> *_items;
}

- (instancetype)init {
    if ((self = [super init])) {
        _items = [NSMutableArray array];
        _horizontalAlignmentMode = SKLabelHorizontalAlignmentModeLeft;
        _verticalAlignmentMode = SKLabelVerticalAlignmentModeCenter;
    }
    return self;
}

- (void)addArrangedNode:(SKNode *)node { [self addArrangedNode:node layoutBounds:CGRectNull]; }

- (void)addArrangedNode:(SKNode *)node layoutBounds:(CGRect)bounds {
    UIStackItem *item = [UIStackItem new];
    item.node = node;
    item.bounds = bounds;
    [_items addObject:item];
    [self addChild:node];
}

- (void)setLayoutBounds:(CGRect)bounds forArrangedNode:(SKNode *)node {
    for (UIStackItem *item in _items) if (item.node == node) { item.bounds = bounds; return; }
}

- (void)setVerticalCenter:(CGFloat)center forArrangedNode:(SKNode *)node {
    for (UIStackItem *item in _items) if (item.node == node) { item.verticalCenter = @(center); return; }
}

- (CGRect)boundsOf:(UIStackItem *)item {
    return CGRectIsNull(item.bounds) ? NodeLayoutBounds(item.node) : item.bounds;
}

- (void)layout {
    if (_maximumWidth > 0) {
        NSMutableArray<SKLabelNode *> *flexible = [NSMutableArray array];
        CGFloat fixed = _spacing * MAX(0, (NSInteger)_items.count - 1);
        for (UIStackItem *item in _items) {
            if (CGRectIsNull(item.bounds) && [item.node isKindOfClass:SKLabelNode.class] &&
                ((SKLabelNode *)item.node).numberOfLines == 0)
                [flexible addObject:(SKLabelNode *)item.node];
            else fixed += CGRectGetWidth([self boundsOf:item]);
        }
        CGFloat width = MAX(1, (_maximumWidth - fixed) / MAX(1, flexible.count));
        for (SKLabelNode *label in flexible) label.preferredMaxLayoutWidth = width;
    }
    NSMutableArray<NSValue *> *bounds = [NSMutableArray arrayWithCapacity:_items.count];
    CGFloat width = _spacing * MAX(0, (NSInteger)_items.count - 1), top = 0, bottom = 0;
    BOOL centered = _verticalAlignmentMode == SKLabelVerticalAlignmentModeCenter;
    for (UIStackItem *item in _items) {
        CGRect rect = [self boundsOf:item];
        [bounds addObject:BoxRect(rect)];
        width += CGRectGetWidth(rect);
        CGFloat center = centered && item.verticalCenter ? item.verticalCenter.doubleValue : CGRectGetMidY(rect);
        top = MAX(top, CGRectGetMaxY(rect) - center);
        bottom = MIN(bottom, CGRectGetMinY(rect) - center);
    }
    CGFloat height = top - bottom;
    _contentSize = CGSizeMake(width, height);
    CGFloat x = _horizontalAlignmentMode == SKLabelHorizontalAlignmentModeRight ? -width :
                _horizontalAlignmentMode == SKLabelHorizontalAlignmentModeCenter ? -width / 2 : 0;
    for (NSUInteger i = 0; i < _items.count; i++) {
        CGRect rect = UnboxRect(bounds[i]);
        NSNumber *center = _items[i].verticalCenter;
        CGFloat y = _verticalAlignmentMode == SKLabelVerticalAlignmentModeTop ? height / 2 - CGRectGetMaxY(rect) :
                    _verticalAlignmentMode == SKLabelVerticalAlignmentModeBottom ? -height / 2 - CGRectGetMinY(rect) :
                    -(top + bottom) / 2 - (centered && center ? center.doubleValue : CGRectGetMidY(rect));
        _items[i].node.position = CGPointMake(x - CGRectGetMinX(rect), y);
        x += CGRectGetWidth(rect) + _spacing;
    }
}
@end

@implementation UIVerticalStack
- (void)setArrangedNodes:(NSArray<SKNode *> *)nodes {
    for (SKNode *node in _arrangedNodes) if (![nodes containsObject:node]) [node removeFromParent];
    _arrangedNodes = [nodes copy];
    for (SKNode *node in _arrangedNodes) if (node.parent != self) [self addChild:node];
    [self layout];
}

- (void)layout {
    CGFloat width = 0, height = 0;
    for (SKNode *node in _arrangedNodes) {
        if (node.hidden) continue;
        CGRect bounds = NodeLayoutBounds(node);
        node.position = CGPointMake(-CGRectGetMinX(bounds), -height - CGRectGetMaxY(bounds));
        width = MAX(width, CGRectGetWidth(bounds));
        height += CGRectGetHeight(bounds) + _spacing;
    }
    _contentSize = CGSizeMake(width, MAX(0, height - _spacing));
}
@end

@implementation UIDataList {
    UIRowTemplate _rowTemplate;
}

- (instancetype)initWithRowTemplate:(UIRowTemplate)rowTemplate {
    if ((self = [super init])) _rowTemplate = [rowTemplate copy];
    return self;
}

- (void)setItems:(NSArray *)items {
    if (_items == items) return;
    _items = [items copy];
    [self reloadRows];
}

- (void)setMaximumWidth:(CGFloat)width {
    width = MAX(0, width);
    if (_maximumWidth == width) return;
    _maximumWidth = width;
    [self reloadRows];
}

- (void)reloadRows {
    NSArray<SKNode *> *previous = self.arrangedNodes;
    NSMutableArray<SKNode *> *rows = [NSMutableArray arrayWithCapacity:_items.count];
    for (NSUInteger i = 0; i < _items.count; i++) {
        SKNode *reusable = i < previous.count ? previous[i] : nil;
        [rows addObject:_rowTemplate(_items[i], reusable, _maximumWidth)];
    }
    self.arrangedNodes = rows;
}
@end
