#import <SpriteKit/SpriteKit.h>

typedef struct { CGFloat r, g, b; } UIRGB;

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
static const CGFloat UISlant = 0.36;

static inline NSColor *UIColorWithOpacity(UIRGB color, CGFloat opacity) {
    return [NSColor colorWithRed:color.r green:color.g blue:color.b alpha:opacity];
}

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

static inline SKShapeNode *UISkewedShape(CGRect rect, NSColor *stroke, NSColor *fill) {
    CGPathRef path = UICreateSkewedPath(rect);
    SKShapeNode *shape = [SKShapeNode shapeNodeWithPath:path];
    CGPathRelease(path);
    shape.strokeColor = stroke;
    shape.fillColor = fill;
    shape.lineWidth = 1;
    return shape;
}

static inline void UISetSkewedBar(SKShapeNode *bar, CGFloat width, CGFloat height) {
    CGPathRef path = UICreateSkewedPath(CGRectMake(0, 0, MAX(0, width), height));
    bar.path = path;
    CGPathRelease(path);
}
