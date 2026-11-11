#import "UI.h"

static SKLabelNode *Line(NSString *text, CGFloat size, SKColor *color, BOOL bold, CGPoint at) {
    SKLabelNode *label = UIInterfaceLabel(size, color, SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeTop);
    if (bold) label.fontName = UIInterfaceBoldFont;
    label.text = text;
    label.position = at;
    return label;
}

static SKLabelNode *Wrapped(SKLabelNode *label, CGFloat width, NSInteger lines) {
    label.numberOfLines = lines;
    label.preferredMaxLayoutWidth = width;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    return label;
}

// MARK: - Mission select

@implementation UIMissionGrid
- (instancetype)initWithList:(MissionListModel *)list region:(CGRect)region compact:(BOOL)compact {
    if (!(self = [super init])) return nil;
    _grid = TileGridFit(CGRectGetWidth(region), compact ? 144 : 172);
    CGPoint corner = CGPointMake(CGRectGetMinX(region), CGRectGetMaxY(region));
    NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:list.tiles.count];
    static NSArray<NSString *> *ratings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ratings = @[@"☆ ☆ ☆", @"★ ☆ ☆", @"★ ★ ☆", @"★ ★ ★"]; });
    for (NSUInteger i = 0; i < list.tiles.count; i++) {
        MissionTile *mission = list.tiles[i];
        BOOL selected = i == list.selected;
        CGRect rect = TileGridCell(_grid, corner, i);
        [rects addObject:BoxRect(rect)];
        SKColor *ink = UIColorWithOpacity(selected ? UIAmber : UIInk, mission.open ? 1 : 0.35);
        SKShapeNode *tile = UIReadoutPanel(rect, ink, UIColorWithOpacity(selected ? UIInk : UIPanel, selected ? 0.14 : 0.88));
        tile.name = [NSString stringWithFormat:@"mission-%lu", (unsigned long)i + 1];
        [self addChild:tile];
        // Top to bottom: number, title, then the stars and the status line
        // from the bottom up. Each label sits clear of the measured frame of
        // its neighbour, so no two can touch whatever the font metrics are.
        const CGFloat inset = 16, spacing = 4;
        CGRect inner = CGRectInset(rect, inset, 0);
        CGFloat x = CGRectGetMinX(inner);
        SKLabelNode *number = Line(mission.number, compact ? 42 : 52, ink, YES, CGPointMake(x, CGRectGetMaxY(rect) - 12));
        [self addChild:number];
        SKLabelNode *status = Line(mission.status, 10, ink, NO, CGPointZero);
        status.position = CGPointMake(x, CGRectGetMinY(rect) + 10 + CGRectGetHeight(status.frame));
        [self addChild:status];
        SKLabelNode *rating = Line(ratings[MIN(mission.stars, (NSUInteger)3)], 18,
            UIColorWithOpacity(mission.stars ? UIAmber : UIInk, mission.stars ? 1 : 0.25), NO, CGPointZero);
        rating.position = CGPointMake(x, CGRectGetMaxY(status.frame) + spacing + CGRectGetHeight(rating.frame));
        [self addChild:rating];
        CGFloat nameTop = CGRectGetMinY(number.frame) - spacing;
        SKLabelNode *name = Wrapped(Line(mission.title, 12, ink, YES, CGPointMake(x, nameTop)), CGRectGetWidth(inner), 2);
        if (nameTop - CGRectGetHeight(name.frame) < CGRectGetMaxY(rating.frame) + spacing) name.numberOfLines = 1;   // compact tiles
        [self addChild:name];
    }
    _tileRects = rects;
    return self;
}
@end

// MARK: - Briefing monitor

@implementation UIMonitorHeader
- (instancetype)initWithMonitor:(MonitorModel *)monitor left:(CGFloat)left right:(CGFloat)right top:(CGFloat)top {
    if (!(self = [super init])) return nil;
    CGFloat width = MAX(1, right - left);
    if (monitor.title) {
        _titleLabel = Wrapped(Line(monitor.title, MIN(21, MAX(12, width / 29)), UIColorWithOpacity(UIInk, 1), YES,
                                   CGPointMake(left, top)), width, 0);
        [self addChild:_titleLabel];
        top = CGRectGetMinY(_titleLabel.frame) - 4;
    }
    _locationLabel = Wrapped(Line(monitor.location, MIN(13, MAX(9, width / 45)), UIColorWithOpacity(UIInk, 0.75), NO,
                                  CGPointMake(left, top)), width, 0);
    [self addChild:_locationLabel];
    CGFloat channelTop = CGRectGetMinY(_locationLabel.frame) - 10;
    _channelLabel = Line(monitor.channel, 12, UIColorWithOpacity(UIAmber, 1), YES, CGPointMake(left, channelTop));
    [self addChild:_channelLabel];
    _counterLabel = Line(monitor.counter, 12, UIColorWithOpacity(UIInk, 0.7), NO, CGPointMake(right, channelTop));
    _counterLabel.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
    [self addChild:_counterLabel];
    _contentTop = CGRectGetMinY(_channelLabel.frame) - 8;
    return self;
}
@end
