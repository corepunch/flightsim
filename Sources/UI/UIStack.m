#import "UI.h"

@interface UIStackItem : NSObject
@property (nonatomic, strong) SKNode *node;
@property (nonatomic) CGRect bounds;
@end
@implementation UIStackItem
@end

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

- (CGRect)boundsOf:(UIStackItem *)item {
    if (!CGRectIsNull(item.bounds)) return item.bounds;
    CGRect bounds = [item.node calculateAccumulatedFrame];
    if (CGRectIsNull(bounds) || CGRectIsInfinite(bounds)) return CGRectZero;
    bounds.origin = PointSub(bounds.origin, item.node.position);
    return bounds;
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
    CGFloat width = _spacing * MAX(0, (NSInteger)_items.count - 1), height = 0;
    for (UIStackItem *item in _items) {
        CGRect rect = [self boundsOf:item];
        [bounds addObject:BoxRect(rect)];
        width += CGRectGetWidth(rect);
        height = MAX(height, CGRectGetHeight(rect));
    }
    _contentSize = CGSizeMake(width, height);
    CGFloat x = _horizontalAlignmentMode == SKLabelHorizontalAlignmentModeRight ? -width :
                _horizontalAlignmentMode == SKLabelHorizontalAlignmentModeCenter ? -width / 2 : 0;
    for (NSUInteger i = 0; i < _items.count; i++) {
        CGRect rect = UnboxRect(bounds[i]);
        CGFloat y = _verticalAlignmentMode == SKLabelVerticalAlignmentModeTop ? height / 2 - CGRectGetMaxY(rect) :
                    _verticalAlignmentMode == SKLabelVerticalAlignmentModeBottom ? -height / 2 - CGRectGetMinY(rect) :
                    -CGRectGetMidY(rect);
        _items[i].node.position = CGPointMake(x - CGRectGetMinX(rect), y);
        x += CGRectGetWidth(rect) + _spacing;
    }
}
@end
