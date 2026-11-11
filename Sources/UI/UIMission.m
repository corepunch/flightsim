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

@implementation UIMissionRows
- (instancetype)initWithList:(MissionListModel *)list region:(CGRect)region compact:(BOOL)compact {
    if (!(self = [super init])) return nil;
    const CGFloat height = compact ? 46 : 54, inset = 12, spacing = 4;
    NSMutableArray<NSValue *> *rects = [NSMutableArray arrayWithCapacity:list.rows.count];
    static NSArray<NSString *> *ratings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ratings = @[@"☆ ☆ ☆", @"★ ☆ ☆", @"★ ★ ☆", @"★ ★ ★"]; });
    for (NSUInteger i = 0; i < list.rows.count; i++) {
        MissionRow *mission = list.rows[i];
        BOOL selected = i == list.selected;
        CGRect rect = CGRectMake(CGRectGetMinX(region), CGRectGetMaxY(region) - height * (i + 1),
                                 CGRectGetWidth(region), height);
        [rects addObject:BoxRect(rect)];
        SKColor *ink = UIColorWithOpacity(selected ? UIAmber : UIInk, mission.open ? 1 : 0.35);
        // A plain list: a rule under each row, and a band with a marker on the highlighted one.
        SKSpriteNode *rule = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.18) size:CGSizeMake(CGRectGetWidth(rect), 1)];
        rule.anchorPoint = CGPointZero;
        rule.position = rect.origin;
        [self addChild:rule];
        if (selected) {
            SKSpriteNode *band = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.14) size:rect.size];
            band.anchorPoint = CGPointZero;
            band.position = rect.origin;
            [self addChild:band];
            SKSpriteNode *marker = [SKSpriteNode spriteNodeWithColor:ink size:CGSizeMake(3, height)];
            marker.anchorPoint = CGPointZero;
            marker.position = rect.origin;
            [self addChild:marker];
        }
        // The number leads; the title sits over the status beside it. The
        // right edge carries the stars over the friends who are on the mission,
        // and the left column gives way to whichever of the two is wider.
        CGRect inner = CGRectInset(rect, inset, 0);
        CGFloat upper = CGRectGetMidY(rect) + spacing / 2, lower = CGRectGetMidY(rect) - spacing / 2;
        SKLabelNode *number = Line(mission.number, compact ? 20 : 24, ink, YES, CGPointZero);
        number.verticalAlignmentMode = SKLabelVerticalAlignmentModeCenter;
        number.position = CGPointMake(CGRectGetMinX(inner), CGRectGetMidY(rect));
        [self addChild:number];
        SKLabelNode *rating = Line(ratings[MIN(mission.stars, (NSUInteger)3)], 16,
            UIColorWithOpacity(mission.stars ? UIAmber : UIInk, mission.stars ? 1 : 0.25), NO, CGPointZero);
        rating.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
        rating.verticalAlignmentMode = SKLabelVerticalAlignmentModeBottom;
        rating.position = CGPointMake(CGRectGetMaxX(inner), upper);
        [self addChild:rating];
        CGFloat left = CGRectGetMaxX(number.frame) + inset;
        CGFloat titleRight = CGRectGetMinX(rating.frame) - inset, statusRight = CGRectGetMaxX(inner);
        if (mission.friends) {
            SKLabelNode *friends = Line(mission.friends, 11, UIColorWithOpacity(UIFriendly, 1), YES, CGPointMake(CGRectGetMaxX(inner), lower));
            friends.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeRight;
            friends.numberOfLines = 1;
            friends.lineBreakMode = NSLineBreakByTruncatingTail;
            friends.preferredMaxLayoutWidth = (CGRectGetMaxX(inner) - left) * 0.6;
            [self addChild:friends];
            statusRight = CGRectGetMinX(friends.frame) - inset;
        }
        SKLabelNode *name = Line(mission.title, 13, ink, YES, CGPointMake(left, upper));
        name.verticalAlignmentMode = SKLabelVerticalAlignmentModeBottom;
        name.numberOfLines = 1;
        name.lineBreakMode = NSLineBreakByTruncatingTail;
        name.preferredMaxLayoutWidth = MAX(1, titleRight - left);
        [self addChild:name];
        SKLabelNode *status = Line(mission.status, 10, ink, NO, CGPointMake(left, lower));
        status.numberOfLines = 1;
        status.lineBreakMode = NSLineBreakByTruncatingTail;
        status.preferredMaxLayoutWidth = MAX(1, statusRight - left);
        [self addChild:status];
    }
    _rowRects = rects;
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
