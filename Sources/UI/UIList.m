#import "UI.h"
#import <CoreText/CoreText.h>

// MARK: - Checklists

@interface UIStatusCheckbox : SKNode
- (instancetype)initWithStatus:(ObjectiveStatus)status side:(CGFloat)side color:(SKColor *)color;
@end

@implementation UIStatusCheckbox
- (instancetype)initWithStatus:(ObjectiveStatus)status side:(CGFloat)side color:(SKColor *)color {
    if (!(self = [super init])) return nil;
    CGFloat border = MAX(1.25, side * 0.08);
    CGRect bounds = CGRectMake(0, -side / 2, side, side);
    SKShapeNode *box = [SKShapeNode shapeNodeWithRect:CGRectInset(bounds, border / 2, border / 2)];
    box.strokeColor = color;
    box.fillColor = SKColor.clearColor;
    box.lineWidth = border;
    [self addChild:box];
    if (status == ObjectiveOpen) return self;

    CGMutablePathRef path = CGPathCreateMutable();
    if (status == ObjectiveComplete) {
        CGPathMoveToPoint(path, NULL, side * 0.23, side * -0.02);
        CGPathAddLineToPoint(path, NULL, side * 0.43, side * -0.27);
        CGPathAddLineToPoint(path, NULL, side * 0.77, side * 0.27);
    } else {
        CGPathMoveToPoint(path, NULL, side * 0.27, side * -0.23);
        CGPathAddLineToPoint(path, NULL, side * 0.73, side * 0.23);
        CGPathMoveToPoint(path, NULL, side * 0.27, side * 0.23);
        CGPathAddLineToPoint(path, NULL, side * 0.73, side * -0.23);
    }
    SKShapeNode *mark = [SKShapeNode shapeNodeWithPath:path];
    CGPathRelease(path);
    mark.strokeColor = color;
    mark.lineWidth = MAX(1.7, side * 0.12);
    mark.lineCap = kCGLineCapRound;
    mark.lineJoin = kCGLineJoinRound;
    [self addChild:mark];
    return self;
}
@end

// A wrapped label exposes both its occupied bounds and its first line's alignment.
@interface UIWrappedText : SKNode
- (instancetype)initWithFont:(NSString *)font size:(CGFloat)size;
- (void)showText:(NSString *)text color:(SKColor *)color;
- (void)layoutWithWidth:(CGFloat)width;
@property (nonatomic, readonly) CGRect layoutBounds;
@property (nonatomic, readonly) CGFloat firstLineCenter, firstCapCenter;
@end

@implementation UIWrappedText {
    NSString *_text, *_fontName;
    SKColor *_ink;
    NSDictionary<NSString *, id> *_textAttributes;
    CGFloat _fontSize, _capHeight, _laidOutWidth;
}

- (instancetype)initWithFont:(NSString *)font size:(CGFloat)size {
    if ((self = [super init])) {
        _fontName = [font copy];
        _fontSize = size;
        CTFontRef typeface = CTFontCreateWithName((__bridge CFStringRef)font, size, NULL);
        _capHeight = CTFontGetCapHeight(typeface);
        _textAttributes = @{ (__bridge NSString *)kCTFontAttributeName: CFBridgingRelease(typeface) };
        _text = @"";
        _laidOutWidth = -1;
    }
    return self;
}

- (void)showText:(NSString *)text color:(SKColor *)color {
    if (![_ink isEqual:color]) {
        _ink = color;
        for (SKLabelNode *line in self.children) line.fontColor = color;
    }
    if (![_text isEqualToString:text ?: @""]) {
        _text = [text copy] ?: @"";
        _laidOutWidth = -1;
    }
}

- (SKLabelNode *)addTextLine {
    SKLabelNode *label = [SKLabelNode labelNodeWithFontNamed:_fontName];
    label.fontSize = _fontSize;
    label.fontColor = _ink;
    label.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeLeft;
    label.verticalAlignmentMode = SKLabelVerticalAlignmentModeBaseline;
    label.numberOfLines = 1;
    [self addChild:label];
    return label;
}

- (void)layoutWithWidth:(CGFloat)width {
    if (_laidOutWidth == width) return;
    _laidOutWidth = width;
    CGFloat lineWidth = width > 0 ? width : CGFLOAT_MAX;
    CGFloat lineTop = 0, textWidth = 0;
    _firstLineCenter = _firstCapCenter = 0;
    NSArray<SKNode *> *existingLines = self.children;
    NSUInteger lineIndex = 0;
    NSAttributedString *styled = [[NSAttributedString alloc] initWithString:_text attributes:_textAttributes];
    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)styled);
    for (CFIndex start = 0; start < (CFIndex)_text.length;) {
        CFIndex count = CTTypesetterSuggestLineBreak(typesetter, start, lineWidth);
        if (!count) count = [_text rangeOfComposedCharacterSequenceAtIndex:start].length;
        CTLineRef line = CTTypesetterCreateLine(typesetter, CFRangeMake(start, count));
        CGFloat ascent, descent, leading;
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        CGFloat baseline = lineTop - ascent;
        if (start == 0) {
            // SpriteKit's single-line raster places the ink slightly above the Core Text baseline.
            const CGFloat rasterBaselineOffset = 0.75;
            _firstCapCenter = baseline + _capHeight / 2 + rasterBaselineOffset;
            _firstLineCenter = _firstCapCenter;
            CGRect ink = CTLineGetImageBounds(line, NULL);
            if (!CGRectIsEmpty(ink)) {
                CGFloat inkTop = CGRectGetMaxY(ink), inkBottom = CGRectGetMinY(ink);
                // Descenders extend below the body of the text and can pull the box down.
                CGFloat bodyBottom = inkTop > 0 ? MAX(0, inkBottom) : inkBottom;
                _firstLineCenter = baseline + (bodyBottom + inkTop) / 2 + rasterBaselineOffset;
            }
        }
        CFRelease(line);

        SKLabelNode *label = lineIndex < existingLines.count ? (SKLabelNode *)existingLines[lineIndex] : [self addTextLine];
        NSString *text = [[_text substringWithRange:NSMakeRange(start, count)] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
        UISetLabelText(label, text);
        label.position = CGPointMake(0, baseline);
        textWidth = MAX(textWidth, CGRectGetWidth(label.frame));
        lineTop = baseline - descent - leading;
        start += count;
        lineIndex++;
    }
    CFRelease(typesetter);
    for (; lineIndex < existingLines.count; lineIndex++) [existingLines[lineIndex] removeFromParent];
    _layoutBounds = CGRectMake(0, lineTop, textWidth, -lineTop);
}
@end

@implementation UIStatusRow {
    SKNode *_markSlot;
    UIWrappedText *_text;
    SKColor *_ink;
    ObjectiveStatus _status;
    CGFloat _side;
}

- (instancetype)initWithFont:(NSString *)font size:(CGFloat)size {
    if ((self = [super init])) {
        _side = MAX(14, round(size));
        self.spacing = 8;
        _markSlot = [SKNode node];
        _text = [[UIWrappedText alloc] initWithFont:font size:size];
        [self addArrangedNode:_markSlot layoutBounds:CGRectMake(0, -_side / 2, _side, _side)];
        [self addArrangedNode:_text layoutBounds:CGRectZero];
    }
    return self;
}

- (void)showText:(NSString *)text status:(ObjectiveStatus)status color:(SKColor *)color {
    if (!_markSlot.children.count || _status != status || ![_ink isEqual:color]) {
        [_markSlot removeAllChildren];
        [_markSlot addChild:[[UIStatusCheckbox alloc] initWithStatus:status side:_side color:color]];
        _status = status;
        _ink = color;
    }
    [_text showText:text color:color];
}

- (void)layoutWithWidth:(CGFloat)width {
    [_text layoutWithWidth:width > 0 ? MAX(1, width - _side - self.spacing) : 0];
    [self setLayoutBounds:_text.layoutBounds forArrangedNode:_text];
    [self setVerticalCenter:_text.firstLineCenter forArrangedNode:_text];
    [self layout];
}
@end

@implementation UIObjectiveList {
    SKLabelNode *_heading;
    UIDataList *_list;
}

- (instancetype)initWithTitle:(NSString *)title fontSize:(CGFloat)size {
    if ((self = [super init])) {
        _items = @[];
        self.spacing = 8;
        _list = [[UIDataList alloc] initWithRowTemplate:^SKNode *(id data, SKNode *reusable, CGFloat width) {
            ObjectiveReadout *item = data;
            UIStatusRow *row = (UIStatusRow *)reusable ?: [[UIStatusRow alloc] initWithFont:UIMonoFont size:size];
            SKColor *ink = UIColorWithOpacity(item.status == ObjectiveFailed ? UIRed : UIInk, 0.95);
            [row showText:item.text status:item.status color:ink];
            [row layoutWithWidth:width];
            return row;
        }];
        _list.spacing = 8;
        if (title.length) {
            _heading = UIInterfaceLabel(size, UIColorWithOpacity(UIInk, 1),
                SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeTop);
            _heading.fontName = UIInterfaceBoldFont;
            _heading.numberOfLines = 0;
            _heading.lineBreakMode = NSLineBreakByWordWrapping;
            _heading.text = title;
        }
        self.arrangedNodes = _heading ? @[_heading, _list] : @[_list];
        _heading.hidden = YES;
        _list.hidden = YES;
        [self layout];
    }
    return self;
}

- (void)setItems:(NSArray<ObjectiveReadout *> *)items {
    if (_items == items) return;
    _items = [items copy];
    _list.items = _items;
    _heading.hidden = !_items.count;
    _list.hidden = !_items.count;
    [self layout];
}

- (void)setMaximumWidth:(CGFloat)width {
    width = MAX(0, width);
    if (width == _maximumWidth) return;
    _maximumWidth = width;
    _heading.preferredMaxLayoutWidth = width;
    _list.maximumWidth = width;
    [self layout];
}
@end

// MARK: - Results

@implementation UIResultScore
- (instancetype)initWithTotal:(NSUInteger)total earned:(NSUInteger)points fontSize:(CGFloat)size width:(CGFloat)width {
    if (!(self = [super init])) return nil;
    self.spacing = 8;
    self.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeCenter;
    SKColor *ink = UIColorWithOpacity(UIAmber, 1);
    UIWrappedText *totalLabel = [[UIWrappedText alloc] initWithFont:UIInterfaceBoldFont size:size];
    [totalLabel showText:L10nFormat(@"score.total", (unsigned long)total) color:ink];
    [self addArrangedNode:totalLabel layoutBounds:CGRectZero];
    CGFloat totalWidth = width;
    if (points) {
        CGFloat side = MAX(14, round(size));
        UIStatusCheckbox *mark = [[UIStatusCheckbox alloc] initWithStatus:ObjectiveComplete side:side color:ink];
        [self addArrangedNode:mark layoutBounds:CGRectMake(0, -side / 2, side, side)];
        CGFloat labelWidth = MAX(1, width - side - 2 * self.spacing);
        UIWrappedText *gain = [[UIWrappedText alloc] initWithFont:UIInterfaceBoldFont size:size];
        [gain showText:L10nFormat(@"score.gain", (unsigned long)points) color:ink];
        [gain layoutWithWidth:MAX(1, labelWidth / 2)];
        [self addArrangedNode:gain layoutBounds:gain.layoutBounds];
        [self setVerticalCenter:gain.firstCapCenter forArrangedNode:gain];
        totalWidth = MAX(1, labelWidth - CGRectGetWidth(gain.layoutBounds));
    }
    [totalLabel layoutWithWidth:totalWidth];
    [self setLayoutBounds:totalLabel.layoutBounds forArrangedNode:totalLabel];
    [self setVerticalCenter:totalLabel.firstCapCenter forArrangedNode:totalLabel];
    [self layout];
    return self;
}
@end

SKNode *UIResultsBackdrop(CGSize size) {
    SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIBackground, 0.32) size:size];
    shade.anchorPoint = CGPointZero;
    return shade;
}

@implementation UIListRow
- (instancetype)initWithRect:(CGRect)rect title:(NSString *)title detail:(NSString *)detail
                     compact:(BOOL)compact selected:(BOOL)selected {
    if ((self = [super init])) {
        _rect = rect;
        _plate = UIReadoutPanel(rect, UIColorWithOpacity(selected ? UIAmber : UIInk, selected ? 0.9 : 0.35),
                               UIColorWithOpacity(selected ? UIAmber : UIPanel, selected ? 0.12 : 0.86));
        [self addChild:_plate];
        CGRect inner = CGRectInset(rect, compact ? 12 : 18, 6);
        _titleLabel = UIInterfaceLabel(compact ? 14 : 18, UIColorWithOpacity(selected ? UIAmber : UIInk, 1),
            SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeCenter);
        _titleLabel.text = title;
        _titleLabel.position = PointAdd(CGPointMake(CGRectGetMinX(inner), CGRectGetMidY(inner)),
                                       CGPointMake(0, detail.length ? 9 : 0));
        UIFitControlLabel(_titleLabel, CGRectGetWidth(inner));
        UICenterLabelVertically(_titleLabel, _titleLabel.position.y);
        [self addChild:_titleLabel];
        if (detail.length) {
            _detailLabel = UIInterfaceLabel(compact ? 11 : 13, UIColorWithOpacity(UIInk, 0.65),
                SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeCenter);
            _detailLabel.text = detail;
            _detailLabel.position = PointAdd(CGPointMake(CGRectGetMinX(inner), CGRectGetMidY(inner)), CGPointMake(0, -12));
            UIFitControlLabel(_detailLabel, CGRectGetWidth(inner));
            UICenterLabelVertically(_detailLabel, _detailLabel.position.y);
            [self addChild:_detailLabel];
        }
    }
    return self;
}
- (void)registerHover:(UIHover *)hover { [hover addButton:_plate rect:_rect accent:UIAmber outline:NULL]; }
@end

@implementation UIEmptyState
- (instancetype)initWithRegion:(CGRect)region text:(NSString *)text compact:(BOOL)compact {
    if ((self = [super init])) {
        _label = UIInterfaceLabel(compact ? 16 : 21, UIColorWithOpacity(UIInk, 0.8),
            SKLabelHorizontalAlignmentModeCenter, SKLabelVerticalAlignmentModeCenter);
        _label.text = text;
        _label.numberOfLines = 0;
        _label.preferredMaxLayoutWidth = MAX(1, MIN(620, CGRectGetWidth(region) - 24));
        _label.lineBreakMode = NSLineBreakByWordWrapping;
        UISetCenteredButtonText(_label, text);
        _label.position = RectCenter(region);
        UICenterLabelVertically(_label, CGRectGetMidY(region));
        [self addChild:_label];
    }
    return self;
}
@end

@implementation TextViewport {
    SKSpriteNode *_thumb;
}

- (instancetype)initWithRect:(CGRect)rect content:(SKNode *)content {
    if (!(self = [super init]) || CGRectIsEmpty(rect)) return self;
    _rect = rect;
    SKCropNode *crop = [SKCropNode node];
    SKSpriteNode *mask = [SKSpriteNode spriteNodeWithColor:SKColor.whiteColor size:rect.size];
    mask.position = RectCenter(rect);
    crop.maskNode = mask;
    [crop addChild:content];
    [self addChild:crop];
    _content = content;

    CGFloat overflow = CGRectGetMinY(rect) - CGRectGetMinY([content calculateAccumulatedFrame]);
    if (overflow <= 0.5) return self;
    _limit = overflow;
    CGFloat height = CGRectGetHeight(rect), x = CGRectGetMaxX(rect) - 2;
    SKSpriteNode *track = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.22)
                                                      size:CGSizeMake(2, height)];
    track.position = CGPointMake(x, CGRectGetMidY(rect));
    [self addChild:track];
    CGFloat thumbHeight = MIN(height, MAX(12, height * height / (height + overflow)));
    _thumb = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.8) size:CGSizeMake(3, thumbHeight)];
    _thumb.position = CGPointMake(x, 0);
    _thumb.zPosition = 1;
    [self addChild:_thumb];
    return self;
}

- (void)showOffset:(CGFloat)offset {
    if (_limit <= 0) return;
    _content.position = CGPointMake(0, offset);
    CGFloat thumbHeight = _thumb.size.height;
    CGFloat y = CGRectGetMaxY(_rect) - thumbHeight / 2 - (CGRectGetHeight(_rect) - thumbHeight) * offset / _limit;
    _thumb.position = CGPointMake(_thumb.position.x, y);
}

@end
