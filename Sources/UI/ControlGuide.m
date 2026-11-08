#import "UI.h"

static SKTexture *SymbolTexture(NSString *name) {
    if (!name.length) return nil;
    static NSMutableDictionary<NSString *, SKTexture *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    if (cache[name]) return cache[name];
    // SF Symbols supplies the exact letterforms used by Apple's virtual pad.
    // Filled variants have a black foreground and a light circular background.
    BOOL circle = [name hasSuffix:@".circle"] || [name hasSuffix:@".circle.fill"];
    NSString *filled = [name hasSuffix:@".circle"] ? [name stringByAppendingString:@".fill"] : name;
#if TARGET_OS_IOS
    UIImageSymbolConfiguration *size = [UIImageSymbolConfiguration configurationWithPointSize:64 weight:UIImageSymbolWeightRegular];
    UIImageSymbolConfiguration *palette = [UIImageSymbolConfiguration configurationWithPaletteColors:
        circle ? @[UIColor.blackColor, [UIColor colorWithWhite:0.92 alpha:1]] : @[[UIColor colorWithWhite:0.92 alpha:1]]];
    UIImageSymbolConfiguration *config = [size configurationByApplyingConfiguration:palette];
    UIImage *image = [UIImage systemImageNamed:filled withConfiguration:config] ?: [UIImage systemImageNamed:name withConfiguration:config];
#else
    NSImageSymbolConfiguration *size = [NSImageSymbolConfiguration configurationWithPointSize:64 weight:NSFontWeightRegular];
    NSImageSymbolConfiguration *palette = [NSImageSymbolConfiguration configurationWithPaletteColors:
        circle ? @[NSColor.blackColor, [NSColor colorWithWhite:0.92 alpha:1]] : @[[NSColor colorWithWhite:0.92 alpha:1]]];
    NSImage *source = [NSImage imageWithSystemSymbolName:filled accessibilityDescription:nil] ?:
        [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    NSImage *image = [source imageWithSymbolConfiguration:[size configurationByApplyingConfiguration:palette]];
#endif
    if (!image) return nil;
    SKTexture *texture = [SKTexture textureWithImage:image];
    texture.filteringMode = SKTextureFilteringLinear;
    cache[name] = texture;
    return texture;
}

SKNode *UIInputGlyph(NSString *symbol, NSString *text, CGFloat size) {
    SKTexture *texture = SymbolTexture(symbol);
    if (texture) {
        SKSpriteNode *icon = [SKSpriteNode spriteNodeWithTexture:texture];
        CGFloat scale = size / MAX(texture.size.height, 1);
        icon.size = CGSizeMake(texture.size.width * scale, size);
        return icon;
    }
    SKLabelNode *label = UIInterfaceLabel(size * 0.62, UIColorWithOpacity(UIInk, 1),
        SKLabelHorizontalAlignmentModeCenter, SKLabelVerticalAlignmentModeCenter);
    label.text = text.length ? text : symbol;
    return label;
}

@implementation UIControlGuide
- (instancetype)initWithGuide:(InputGuide *)guide width:(CGFloat)width compact:(BOOL)compact {
    if (!(self = [super init])) return nil;
    NSArray<NSString *> *actions = L10nList(@"controls.guide.actions");
    SKLabelNode *heading = UIInterfaceLabel(compact ? 10 : 12, UIColorWithOpacity(UIInk, 0.58),
        SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeTop);
    heading.text = [NSString stringWithFormat:@"%@  /  %@", L10n(@"controls.kicker"), guide.name];
    heading.numberOfLines = 0;
    heading.preferredMaxLayoutWidth = width;
    if (L10nIsRightToLeft()) { heading.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight; heading.position = CGPointMake(width, 0); }
    [self addChild:heading];
    CGFloat y = -CGRectGetHeight(heading.frame) - 14;
    NSInteger columns = MAX(1, MIN(3, (NSInteger)((width + 18) / (compact ? 210 : 150))));
    CGFloat cellWidth = (width - (columns - 1) * 18) / columns;
    NSMutableArray<SKNode *> *cells = [NSMutableArray array];
    for (InputBinding *binding in guide.bindings) {
        if (compact && (binding.action == InputHintRoll || binding.action == InputHintBoost || binding.action == InputHintCamera)) continue;
        UIHorizontalStack *row = [UIHorizontalStack new];
        row.spacing = 9;
        for (NSString *symbol in binding.symbols) [row addArrangedNode:UIInputGlyph(symbol, nil, compact ? 22 : 25)];
        [row layout];
        CGFloat glyphWidth = row.contentSize.width + (binding.symbols.count ? row.spacing : 0);
        CGFloat labelWidth = MAX(30, cellWidth - glyphWidth);
        SKNode *caption = [SKNode node];
        SKLabelNode *label = UIInterfaceLabel(compact ? 12 : 14, UIColorWithOpacity(UIInk, 0.94),
            SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeTop);
        label.fontName = UIBodyFont;
        label.text = actions[binding.action];
        label.numberOfLines = 0; label.preferredMaxLayoutWidth = labelWidth;
        [caption addChild:label];
        if (binding.text.length) {
            SKLabelNode *keys = UIInterfaceLabel(compact ? 10 : 11, UIColorWithOpacity(UIInk, 0.64),
                SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeTop);
            keys.fontName = UIBodyFont; keys.numberOfLines = 0; keys.preferredMaxLayoutWidth = labelWidth;
            keys.text = binding.text;
            keys.position = CGPointMake(0, -CGRectGetHeight(label.frame) - 4);
            [caption addChild:keys];
        }
        if (L10nIsRightToLeft()) {
            for (SKLabelNode *line in caption.children) {
                line.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
                line.position = PointAdd(line.position, CGPointMake(labelWidth, 0));
            }
        }
        CGFloat captionHeight = MAX(compact ? 30 : 34, CGRectGetHeight([caption calculateAccumulatedFrame]));
        [row addArrangedNode:caption layoutBounds:CGRectMake(0, -captionHeight, labelWidth, captionHeight)];
        [row layout];
        [cells addObject:row];
    }
    for (NSUInteger start = 0; start < cells.count; start += columns) {
        CGFloat rowHeight = 0;
        for (NSUInteger i = start; i < MIN(start + columns, cells.count); i++)
            rowHeight = MAX(rowHeight, CGRectGetHeight([cells[i] calculateAccumulatedFrame]));
        for (NSUInteger i = start; i < MIN(start + columns, cells.count); i++) {
            NSInteger column = L10nIsRightToLeft() ? columns - 1 - (i - start) : i - start;
            cells[i].position = CGPointMake(column * (cellWidth + 18), y - CGRectGetMaxY([cells[i] calculateAccumulatedFrame]));
            [self addChild:cells[i]];
        }
        y -= rowHeight + (compact ? 10 : 14);
    }
    _height = MAX(0, -y - (compact ? 10 : 14));
    return self;
}
@end
