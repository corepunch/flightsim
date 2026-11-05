#import <SpriteKit/SpriteKit.h>

typedef struct { CGFloat r, g, b; } UIRGB;

// Phosphor for interface text and outlines, amber for emphasis, red for danger.
static const UIRGB UIInk = { 0.55, 0.95, 0.85 };
static const UIRGB UIAmber = { 1.0, 0.72, 0.30 };
static const UIRGB UIRed = { 1.0, 0.42, 0.32 };
static const UIRGB UIBlue = { 0.45, 0.75, 1.0 };
static const UIRGB UIFriendly = { 0.40, 0.95, 0.50 };
static const UIRGB UIHUDNeutral = { 0.95, 0.88, 0.45 };
static const UIRGB UIShield = { 0.40, 0.70, 1.0 };
static const UIRGB UIBoost = { 1.0, 0.75, 0.30 };
static const UIRGB UIYellow = { 0.95, 0.90, 0.45 };
static const UIRGB UIBackground = { 0.012, 0.018, 0.028 };
static const UIRGB UIPanel = { 0.018, 0.065, 0.085 };
static const UIRGB UIMap = { 0, 0.06, 0.06 };
static const UIRGB UIBlack = { 0, 0, 0 };
static const UIRGB UIWhite = { 1, 1, 1 };
static const UIRGB UIField = { 0.55, 0.55, 0.55 };
// The Bastion console variant adds dark steel, copper edging, and glass.
static const UIRGB UIConsoleSteel = { 0.055, 0.047, 0.041 };
static const UIRGB UIConsoleEdge = { 0.51, 0.31, 0.17 };
static const UIRGB UIConsoleGlass = { 0.014, 0.055, 0.058 };

// Fixed-width cockpit telemetry; proportional Oxanium for the front end.
static NSString * const UIMonoFont = @"Menlo";
static NSString * const UIMonoBoldFont = @"Menlo-Bold";
static NSString * const UIInterfaceFont = @"Oxanium-Regular";
static NSString * const UIInterfaceBoldFont = @"Oxanium-Bold";
static NSString * const UIBodyFont = @"Oxanium-Regular";
static NSString * const UIBodyMediumFont = @"Oxanium-Medium";

static const CGFloat UISlant = 0.36;
static const CGFloat UIReadoutChamfer = 9;

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
