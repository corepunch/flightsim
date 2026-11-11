#import "UI.h"

// The gap above a block depends on what it follows: an outcome and its rating
// read as one group, and prose stands clear of both.
static CGFloat GapAbove(ReportBlockKind kind, ReportBlockKind previous) {
    if (previous == ReportHeadline) return kind == ReportNote ? 12 : 8;
    if (previous == ReportRating) return 6;
    if (kind == ReportScore) return 10;
    if (kind == ReportNote) return 23;
    return 16;
}

static UIRGB ToneColor(ReportTone tone) {
    return tone == ReportToneDanger ? UIRed : tone == ReportToneEmphasis ? UIAmber : UIInk;
}

static SKLabelNode *ReportLabel(NSString *text, CGFloat size, UIRGB color, CGFloat width, BOOL centered, BOOL bold) {
    SKLabelNode *label = UIInterfaceLabel(size, UIColorWithOpacity(color, 1),
        centered ? SKLabelHorizontalAlignmentModeCenter : SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeTop);
    if (bold) label.fontName = UIInterfaceBoldFont;
    label.numberOfLines = 0;
    label.preferredMaxLayoutWidth = width;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.text = text;
    label.position = CGPointMake(centered ? width / 2 : 0, 0);
    return label;
}

static SKLabelNode *TableCell(NSString *text, CGRect cell, CGFloat size, UIRGB color, BOOL leading, BOOL bold) {
    SKLabelNode *label = UIInterfaceLabel(size, UIColorWithOpacity(color, 1),
        leading ? SKLabelHorizontalAlignmentModeLeft : SKLabelHorizontalAlignmentModeCenter, SKLabelVerticalAlignmentModeCenter);
    label.text = text;
    if (bold) label.fontName = UIInterfaceBoldFont;
    label.position = leading ? CGPointMake(CGRectGetMinX(cell), CGRectGetMidY(cell)) : RectCenter(cell);
    UIFitControlLabel(label, CGRectGetWidth(cell));
    UICenterLabelVertically(label, CGRectGetMidY(cell));
    return label;
}

// Rows hang from the node's origin; the second column takes the width the figures leave.
static SKNode *ReportTableNode(ReportBlock *block, CGFloat width, BOOL compact) {
    SKNode *table = [SKNode node];
    const CGFloat headerHeight = 26, rowHeight = compact ? 36 : 48, gap = 4;
    NSUInteger columns = block.header.count;
    CGFloat figure = MIN(110, width * 0.20), rank = MIN(52, width * 0.13);
    CGFloat name = MAX(1, width - rank - (columns > 2 ? columns - 2 : 0) * figure - 6);
    for (NSUInteger i = 0; i <= block.rows.count; i++) {
        BOOL header = i == 0, highlighted = !header && i - 1 == block.highlightedRow;
        CGFloat height = header ? headerHeight : rowHeight;
        CGRect row = CGRectMake(0, -headerHeight - i * (rowHeight + gap), width, height);
        UIRGB ink = highlighted ? UIAmber : UIInk;
        if (!header) [table addChild:UIReadoutPanel(row, UIColorWithOpacity(ink, highlighted ? 0.9 : 0.27),
            UIColorWithOpacity(highlighted ? UIAmber : UIPanel, highlighted ? 0.12 : 0.8))];
        NSArray<NSString *> *cells = header ? block.header : block.rows[i - 1];
        for (NSUInteger column = 0; column < MIN(columns, cells.count); column++) {
            CGFloat left = column == 0 ? 0 : column == 1 ? rank : width - (columns - column) * figure;
            CGFloat cellWidth = column == 0 ? rank : column == 1 ? name : figure;
            CGRect cell = CGRectInset(CGRectMake(left, CGRectGetMinY(row), cellWidth, height), 4, 0);
            [table addChild:TableCell(cells[column], cell, header ? 12 : compact ? 14 : 17, ink, column == 1,
                                      header || highlighted)];
        }
    }
    return table;
}

@implementation UIReportView {
    NSMutableDictionary<NSNumber *, SKNode *> *_nodes;
}

- (instancetype)initWithReport:(ReportModel *)report width:(CGFloat)width compact:(BOOL)compact {
    if (!(self = [super init])) return nil;
    _report = report;
    _nodes = [NSMutableDictionary dictionary];
    CGFloat y = 0;
    ReportBlock *previous = nil;
    for (ReportBlock *block in report.blocks) {
        if (previous) y -= GapAbove(block.kind, previous.kind);
        SKNode *node = [self nodeForBlock:block width:width compact:compact];
        // Each block is built hanging from its own origin, whatever its anchor.
        CGRect bounds = [node calculateAccumulatedFrame];
        node.position = PointAdd(node.position, CGPointMake(0, y - CGRectGetMaxY(bounds)));
        y -= CGRectGetHeight(bounds);
        [self addChild:node];
        if (!_nodes[@(block.kind)]) _nodes[@(block.kind)] = node;
        previous = block;
    }
    _contentSize = CGSizeMake(width, -y);
    return self;
}

- (SKNode *)nodeForBlock:(ReportBlock *)block width:(CGFloat)width compact:(BOOL)compact {
    UIRGB color = ToneColor(block.tone);
    switch (block.kind) {
        case ReportHeadline: return ReportLabel(block.text, compact ? 23 : 36, color, width, YES, YES);
        case ReportRating: {
            NSString *stars = @[@"☆ ☆ ☆", @"★ ☆ ☆", @"★ ★ ☆", @"★ ★ ★"][MIN(block.stars, (NSUInteger)3)];
            return ReportLabel(stars, compact ? 23 : 34, color, width, YES, NO);
        }
        case ReportScore: {
            UIResultScore *score = [[UIResultScore alloc] initWithTotal:block.total earned:block.earned
                                                               fontSize:compact ? 15 : 18 width:width];
            score.position = CGPointMake(width / 2, 0);
            return score;
        }
        case ReportNote: return ReportLabel(block.text, compact ? 16 : 20, color, width, YES, NO);
        case ReportText: return ReportLabel(block.text, compact ? 15 : 20, color, width, NO, NO);
        case ReportChecklist: {
            UIObjectiveList *list = [[UIObjectiveList alloc] initWithTitle:block.text fontSize:compact ? 16 : 19];
            list.maximumWidth = width;
            list.items = block.items;
            return list;
        }
        case ReportTable: return ReportTableNode(block, width, compact);
    }
    return [SKNode node];
}

- (SKNode *)nodeForKind:(ReportBlockKind)kind { return _nodes[@(kind)]; }
@end
