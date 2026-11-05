#import "UILayout.h"
#import "FileSystem.h"
#import "UIStyle.h"
#import "Localization.h"

// NSValue's CGRect boxing differs between AppKit and UIKit.
static NSValue *BoxRect(CGRect r) { return [NSValue valueWithBytes:&r objCType:@encode(CGRect)]; }
static CGRect UnboxRect(NSValue *v) { CGRect r; [v getValue:&r size:sizeof r]; return r; }

@interface UILayoutResult ()
@property (nonatomic, readwrite) SKNode *node;
@property (nonatomic) NSMutableDictionary<NSString *, NSValue *> *frameMap;
@property (nonatomic) NSMutableDictionary<NSString *, SKNode *> *buttonMap;
@property (nonatomic) NSMutableDictionary<NSString *, NSArray<NSString *> *> *listMap;
@property (nonatomic) NSMutableSet<NSString *> *disabledSet;
@end

@implementation UILayoutResult
- (NSDictionary *)frames { return _frameMap; }
- (NSDictionary *)buttons { return _buttonMap; }
- (NSDictionary *)lists { return _listMap; }
- (NSSet *)disabled { return _disabledSet; }
- (CGRect)frame:(NSString *)name {
    NSValue *v = _frameMap[name];
    return v ? UnboxRect(v) : CGRectNull;
}
@end

@implementation UILayout {
    NSString *_name;
    NSSet<NSString *> *_flags;
    NSDictionary *_variables;
    NSString *_selected;
    CGSize _sceneSize;
}

+ (instancetype)named:(NSString *)name {
    NSURL *url = FSURL(@"UI/menus", name, @"json");
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    NSError *error = nil;
    id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (![root isKindOfClass:NSDictionary.class]) {
        NSLog(@"UILayout: UI/menus/%@.json unreadable: %@", name, error.localizedDescription ?: @"missing");
        return nil;
    }
    UILayout *layout = [self new];
    layout->_name = [name copy];
    layout->_root = root;
    return layout;
}

- (BOOL)compactForSize:(CGSize)size {
    NSNumber *below = _root[@"compactBelow"];
    return size.height > size.width || (below && size.height < below.doubleValue);
}

#pragma mark - Values

// A node with its "when" overrides for the active flags merged in.
- (NSDictionary *)resolve:(NSDictionary *)node {
    NSDictionary *when = node[@"when"];
    if (![when isKindOfClass:NSDictionary.class]) return node;
    NSMutableDictionary *merged = [node mutableCopy];
    for (NSString *flag in [when.allKeys sortedArrayUsingSelector:@selector(compare:)])
        if ([_flags containsObject:flag]) [merged addEntriesFromDictionary:when[flag]];
    return merged;
}

- (CGFloat)number:(id)value fallback:(CGFloat)fallback {
    if ([value isKindOfClass:NSNumber.class]) return [value doubleValue];
    if ([value isKindOfClass:NSDictionary.class]) {
        for (NSString *flag in _flags) if (value[flag]) return [self number:value[flag] fallback:fallback];
        return [self number:value[@"regular"] fallback:fallback];
    }
    return fallback;
}

- (CGPoint)pair:(id)value fallback:(CGPoint)fallback {
    if (![value isKindOfClass:NSArray.class] || [value count] < 2) return fallback;
    return CGPointMake([self number:value[0] fallback:fallback.x], [self number:value[1] fallback:fallback.y]);
}

- (NSString *)text:(id)value {
    if (![value isKindOfClass:NSString.class]) return @"";
    if ([value hasPrefix:@"$"]) return _variables[[value substringFromIndex:1]] ?: @"";
    return L10n(value);
}

- (SKColor *)color:(id)value opacity:(CGFloat)opacity {
    // "name" or ["name", opacity]
    if ([value isKindOfClass:NSArray.class] && [value count] >= 2)
        return UIColorWithOpacity(UIThemeColor([value firstObject]), [self number:value[1] fallback:1]);
    return UIColorWithOpacity(UIThemeColor([value isKindOfClass:NSString.class] ? value : @"ink"), opacity);
}

- (CGFloat)metric:(NSString *)name flags:(NSSet<NSString *> *)flags fallback:(CGFloat)fallback {
    _flags = flags;
    return [self number:_root[@"metrics"][name] fallback:fallback];
}

- (NSArray<NSDictionary *> *)items {
#if TARGET_OS_IOS
    NSString *platform = @"ios";
#else
    NSString *platform = @"mac";
#endif
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *item in _root[@"items"]) {
        NSArray *platforms = item[@"platforms"];
        if (!platforms || [platforms containsObject:platform]) [items addObject:item];
    }
    return items;
}

#pragma mark - Building

- (UILayoutResult *)buildIn:(CGRect)bounds sceneSize:(CGSize)size flags:(NSSet<NSString *> *)flags
                  variables:(NSDictionary<NSString *, NSString *> *)variables selected:(NSString *)selected {
    NSMutableSet *all = [NSMutableSet setWithSet:flags ?: [NSSet set]];
    if ([self compactForSize:size]) [all addObject:@"compact"];
    _flags = all;
    _variables = variables ?: @{};
    _selected = selected;
    _sceneSize = size;
    UILayoutResult *result = [UILayoutResult new];
    result.node = [SKNode node];
    result.frameMap = [NSMutableDictionary dictionary];
    result.buttonMap = [NSMutableDictionary dictionary];
    result.listMap = [NSMutableDictionary dictionary];
    result.disabledSet = [NSMutableSet set];
    for (NSDictionary *child in _root[@"children"]) [self build:child in:bounds into:result.node result:result];
    return result;
}

- (CGRect)frameOf:(NSDictionary *)n in:(CGRect)parent {
    CGPoint size = [self pair:n[@"size"] fallback:CGPointMake(0, 0)];
    CGFloat w = size.x > 0 ? size.x : parent.size.width + size.x;
    CGFloat h = size.y > 0 ? size.y : parent.size.height + size.y;
    CGPoint margin = [self pair:n[@"margin"] fallback:CGPointZero];
    w = MAX(0, MIN(w, parent.size.width - 2 * margin.x));
    h = MAX(0, MIN(h, parent.size.height - 2 * margin.y));
    CGPoint anchor = [self pair:n[@"anchor"] fallback:CGPointMake(0.5, 0.5)];
    CGPoint pivot = [self pair:n[@"pivot"] fallback:anchor];
    CGPoint offset = [self pair:n[@"offset"] fallback:CGPointZero];
    return CGRectMake(CGRectGetMinX(parent) + parent.size.width * anchor.x - w * pivot.x + offset.x,
                      CGRectGetMinY(parent) + parent.size.height * anchor.y - h * pivot.y + offset.y, w, h);
}

- (CGRect)inner:(CGRect)frame of:(NSDictionary *)n {
    NSArray *inset = n[@"inset"];
    if (![inset isKindOfClass:NSArray.class] || inset.count < 4) return frame;
    CGFloat l = [self number:inset[0] fallback:0], t = [self number:inset[1] fallback:0];
    CGFloat r = [self number:inset[2] fallback:0], b = [self number:inset[3] fallback:0];
    return CGRectMake(frame.origin.x + l, frame.origin.y + b, MAX(0, frame.size.width - l - r), MAX(0, frame.size.height - t - b));
}

- (void)build:(NSDictionary *)raw in:(CGRect)parent into:(SKNode *)into result:(UILayoutResult *)result {
    if (![raw isKindOfClass:NSDictionary.class]) return;
    NSDictionary *n = [self resolve:raw];
    if ([n[@"hidden"] boolValue]) return;
    NSString *type = n[@"type"] ?: @"group";
    NSString *nodeId = n[@"id"];
    CGRect frame = [type isEqualToString:@"shade"] ? CGRectMake(0, 0, _sceneSize.width, _sceneSize.height) : [self frameOf:n in:parent];
    if (nodeId) result.frameMap[nodeId] = BoxRect(frame);

    if ([type isEqualToString:@"shade"]) {
        SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:[self color:n[@"color"] ?: @"black" opacity:[self number:n[@"opacity"] fallback:1]]
                                                           size:frame.size];
        shade.anchorPoint = CGPointZero;
        [into addChild:shade];
    } else if ([type isEqualToString:@"panel"]) {
        [into addChild:UIReadoutPanel(frame, [self color:n[@"stroke"] ?: @[@"ink", @0.8] opacity:1],
                                      [self color:n[@"fill"] ?: @[@"panel", @0.98] opacity:1])];
    } else if ([type isEqualToString:@"label"]) {
        NSString *align = n[@"align"] ?: @"center";
        SKLabelHorizontalAlignmentMode h = [align isEqualToString:@"left"] ? SKLabelHorizontalAlignmentModeLeft
                                         : [align isEqualToString:@"right"] ? SKLabelHorizontalAlignmentModeRight
                                                                            : SKLabelHorizontalAlignmentModeCenter;
        SKLabelNode *label = UIInterfaceLabel([self number:n[@"fontSize"] fallback:13],
                                              [self color:n[@"color"] ?: @"ink" opacity:[self number:n[@"opacity"] fallback:1]],
                                              h, SKLabelVerticalAlignmentModeCenter);
        if (n[@"font"]) label.fontName = UIThemeFont(n[@"font"]);
        label.text = [self text:n[@"text"]];
        CGFloat x = h == SKLabelHorizontalAlignmentModeLeft ? CGRectGetMinX(frame)
                  : h == SKLabelHorizontalAlignmentModeRight ? CGRectGetMaxX(frame) : CGRectGetMidX(frame);
        label.position = CGPointMake(x, CGRectGetMidY(frame));
        if (nodeId) label.name = nodeId;
        [into addChild:label];
    } else if ([type isEqualToString:@"buttons"]) {
        [self buildButtons:n frame:frame into:into result:result];
    }
    CGRect inner = [self inner:frame of:n];
    for (NSDictionary *child in n[@"children"]) [self build:child in:inner into:into result:result];
}

- (void)buildButtons:(NSDictionary *)n frame:(CGRect)frame into:(SKNode *)into result:(UILayoutResult *)result {
    NSString *listId = n[@"id"] ?: @"buttons";
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *item in n[@"items"]) if ([item isKindOfClass:NSDictionary.class]) [items addObject:[self resolve:item]];
    NSUInteger count = items.count;
    if (!count) return;
    CGFloat gap = [self number:n[@"gap"] fallback:6];
    CGFloat row = MIN([self number:n[@"rowHeight"] fallback:44], frame.size.height / count - gap);
    NSMutableArray *ids = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary *item = items[i];
        NSString *itemId = item[@"id"] ?: [NSString stringWithFormat:@"%lu", (unsigned long)i];
        NSString *key = [NSString stringWithFormat:@"%@.%@", listId, itemId];
        CGRect rect = CGRectMake(CGRectGetMinX(frame), CGRectGetMaxY(frame) - row - i * (row + gap), frame.size.width, row);
        BOOL disabled = [item[@"disabled"] boolValue];
        SKShapeNode *button = UIActionButton(rect, [self text:item[@"text"]], [key isEqualToString:_selected] ? UIAmber : UIInk);
        button.alpha = disabled ? 0.35 : 1;
        button.name = key;
        [into addChild:button];
        [ids addObject:itemId];
        result.frameMap[key] = BoxRect(rect);
        result.buttonMap[key] = button;
        if (disabled) [result.disabledSet addObject:key];
    }
    result.listMap[listId] = ids;
}

@end
