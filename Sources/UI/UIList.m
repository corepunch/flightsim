#import "UI.h"

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
