#import <SpriteKit/SpriteKit.h>

#import "UITheme.h"

// The palette, fonts and metrics, from Resources/UI/theme.json (see UITheme.h).
#define UIInk UIThemeColor(@"ink")
#define UIAmber UIThemeColor(@"amber")
#define UIRed UIThemeColor(@"red")
#define UIBlue UIThemeColor(@"blue")
#define UIFriendly UIThemeColor(@"friendly")
#define UIHUDNeutral UIThemeColor(@"hudNeutral")
#define UIShield UIThemeColor(@"shield")
#define UIBoost UIThemeColor(@"boost")
#define UIYellow UIThemeColor(@"yellow")
#define UIBackground UIThemeColor(@"background")
#define UIPanel UIThemeColor(@"panel")
#define UIMap UIThemeColor(@"map")
#define UIBlack UIThemeColor(@"black")
#define UIWhite UIThemeColor(@"white")
#define UIField UIThemeColor(@"field")
#define UIConsoleSteel UIThemeColor(@"consoleSteel")
#define UIConsoleEdge UIThemeColor(@"consoleEdge")
#define UIConsoleGlass UIThemeColor(@"consoleGlass")
#define UIMenuNight UIThemeColor(@"menuNight")
#define UIMenuTitle UIThemeColor(@"menuTitle")
#define UIMonoFont UIThemeFont(@"mono")
#define UIMonoBoldFont UIThemeFont(@"monoBold")
#define UIInterfaceFont UIThemeFont(@"interface")
#define UIInterfaceBoldFont UIThemeFont(@"interfaceBold")
#define UIBodyFont UIThemeFont(@"body")
#define UIBodyMediumFont UIThemeFont(@"bodyMedium")
#define UISlant UIThemeMetric(@"slant")
#define UIReadoutChamfer UIThemeMetric(@"readoutChamfer")

static inline SKColor *UIColorWithOpacity(UIRGB color, CGFloat opacity) {
    return [SKColor colorWithRed:color.r green:color.g blue:color.b alpha:opacity];
}

static inline SKLabelNode *UIMonoLabel(CGFloat size, SKColor *color, SKLabelHorizontalAlignmentMode horizontal,
                                      SKLabelVerticalAlignmentMode vertical) {
    SKLabelNode *label = [SKLabelNode labelNodeWithFontNamed:UIMonoFont];
    label.fontSize = size;
    label.fontColor = color;
    label.horizontalAlignmentMode = horizontal;
    label.verticalAlignmentMode = vertical;
    return label;
}

static inline SKLabelNode *UIInterfaceLabel(CGFloat size, SKColor *color, SKLabelHorizontalAlignmentMode horizontal,
                                           SKLabelVerticalAlignmentMode vertical) {
    SKLabelNode *label = UIMonoLabel(size, color, horizontal, vertical);
    label.fontName = UIInterfaceFont;
    return label;
}

// Skew action controls, selection highlights, and horizontal progress indicators.
static inline CGPathRef UICreateSkewedPath(CGRect rect) CF_RETURNS_RETAINED {
    CGFloat left = CGRectGetMinX(rect), right = CGRectGetMaxX(rect);
    CGFloat bottom = CGRectGetMinY(rect), top = CGRectGetMaxY(rect);
    CGFloat slant = MIN(rect.size.height * UISlant, rect.size.width * 0.25);
    const CGPoint corners[] = {
        { left, bottom }, { right - slant, bottom }, { right, top }, { left + slant, top }
    };
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddLines(path, NULL, corners, 4);
    CGPathCloseSubpath(path);
    return path;
}

static inline SKShapeNode *UISkewedShape(CGRect rect, SKColor *stroke, SKColor *fill) {
    CGPathRef path = UICreateSkewedPath(rect);
    SKShapeNode *shape = [SKShapeNode shapeNodeWithPath:path];
    CGPathRelease(path);
    shape.strokeColor = stroke;
    shape.fillColor = fill;
    shape.lineWidth = 1;
    return shape;
}

static inline SKShapeNode *UIControlRail(CGRect rect, BOOL console) {
    return UISkewedShape(rect, UIColorWithOpacity(console ? UIConsoleEdge : UIInk, console ? 0.95 : 0.35),
                        UIColorWithOpacity(console ? UIConsoleSteel : UIPanel, 0.91));
}

static inline SKShapeNode *UIActionButton(CGRect rect, NSString *text, UIRGB accent) {
    SKShapeNode *button = UISkewedShape(rect, UIColorWithOpacity(accent, 0.85), UIColorWithOpacity(UIPanel, 0.96));
    SKLabelNode *label = UIInterfaceLabel(13, UIColorWithOpacity(UIInk, 1), SKLabelHorizontalAlignmentModeCenter,
                                   SKLabelVerticalAlignmentModeCenter);
    label.fontName = UIInterfaceBoldFont;
    label.position = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    label.text = text;
    [button addChild:label];
    return button;
}

// Chamfer informational panels so their silhouette reads differently from an action.
static inline SKShapeNode *UIReadoutPanel(CGRect rect, SKColor *stroke, SKColor *fill) {
    CGFloat left = CGRectGetMinX(rect), right = CGRectGetMaxX(rect);
    CGFloat bottom = CGRectGetMinY(rect), top = CGRectGetMaxY(rect);
    CGFloat cut = MIN(UIReadoutChamfer, MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)) * 0.25);
    const CGPoint corners[] = {
        {left + cut, bottom}, {right, bottom}, {right, top - cut},
        {right - cut, top}, {left, top}, {left, bottom + cut}
    };
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddLines(path, NULL, corners, sizeof(corners) / sizeof(*corners));
    CGPathCloseSubpath(path);
    SKShapeNode *panel = [SKShapeNode shapeNodeWithPath:path];
    CGPathRelease(path);
    panel.strokeColor = stroke;
    panel.fillColor = fill;
    panel.lineWidth = 1.5;
    return panel;
}

static inline void UISetSkewedBar(SKShapeNode *bar, CGFloat width, CGFloat height) {
    CGPathRef path = UICreateSkewedPath(CGRectMake(0, 0, MAX(0, width), height));
    bar.path = path;
    CGPathRelease(path);
}
