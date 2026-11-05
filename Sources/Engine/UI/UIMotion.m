#import "UI.h"
#import "Audio.h"
#import "Common.h"
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
typedef UIFont UIMotionFont;
#else
#import <AppKit/AppKit.h>
typedef NSFont UIMotionFont;
#endif

static NSString * const TypeKey = @"motion.type";
static NSString * const TypeTextKey = @"motion.text";
static NSString * const CaretName = @"motion.caret";

@interface UITypeStop : NSObject
@property NSUInteger count;
@property CGPoint point;
@property CGSize size;
@property NSTimeInterval time;
@property BOOL carriageReturn;
@end
@implementation UITypeStop
@end

BOOL UIMotionReduced(void) {
    // ui_reduceMotion overrides the system setting: 0 or 1 forces it, empty
    // follows the system. Checks and scripted runs set it so they see the
    // same motion on every machine.
    static Cvar *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [Cvar get:@"ui_reduceMotion" defaultValue:@"" flags:0
                 help:@"Reduce front-end motion: 0 off, 1 on, empty follows the system setting"];
    });
    NSString *override = c.string;
    if (override.length) return c.boolValue;
#if TARGET_OS_IOS
    return UIAccessibilityIsReduceMotionEnabled();
#else
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
#endif
}

double UIMotionTimeScale(void) {
    static Cvar *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [Cvar get:@"ui_timescale" defaultValue:@"1" flags:0
                 help:@"Front-end motion runs this many times slower (screens built after the change)"];
    });
    double scale = c.value;
    return scale > 0 ? scale : 1;
}

#pragma mark - Curves

static float Curve(UICurve curve, float t) {
    switch (curve) {
        case UICurveLinear: return t;
        case UICurveOut: { float u = 1 - t; return 1 - u * u * u; }
        case UICurveIn: return t * t * t;
        case UICurveInOut: return t < 0.5f ? 4 * t * t * t : 1 - powf(-2 * t + 2, 3) / 2;
        case UICurveOutExpo: return t >= 1 ? 1 : 1 - powf(2, -10 * t);
        case UICurveOutBack: {
            const float c1 = 1.70158f, c3 = c1 + 1;
            float u = t - 1;
            return 1 + c3 * u * u * u + c1 * u * u;
        }
    }
    return t;
}

SKAction *UIEased(SKAction *action, UICurve curve) {
    action.timingFunction = ^float(float t) { return Curve(curve, t); };
    return action;
}

SKAction *UIAfter(NSTimeInterval delay, SKAction *action) {
    return delay > 0 ? [SKAction sequence:@[[SKAction waitForDuration:delay], action]] : action;
}

static float Random01(void) { return arc4random_uniform(10000) / 10000.0f; }
static float RandomSigned(void) { return Random01() * 2 - 1; }

#pragma mark - Structure

static void InsertInPlace(SKNode *wrapper, SKNode *node) {
    SKNode *parent = node.parent;
    NSUInteger index = parent ? [parent.children indexOfObject:node] : NSNotFound;
    [node removeFromParent];
    [wrapper addChild:node];
    if (!parent) return;
    if (index == NSNotFound || index > parent.children.count) [parent addChild:wrapper];
    else [parent insertChild:wrapper atIndex:index];
}

SKNode *UIMotionPivot(SKNode *node, CGPoint pivot) {
    SKNode *holder = [SKNode node];
    holder.position = pivot;
    SKNode *parent = node.parent;
    NSUInteger index = parent ? [parent.children indexOfObject:node] : NSNotFound;
    [node removeFromParent];
    node.position = CGPointMake(node.position.x - pivot.x, node.position.y - pivot.y);
    [holder addChild:node];
    if (parent) {
        if (index == NSNotFound || index > parent.children.count) [parent addChild:holder];
        else [parent insertChild:holder atIndex:index];
    }
    return holder;
}

#pragma mark - Entrances

void UIMotionSlideIn(SKNode *node, CGVector offset, NSTimeInterval delay, NSTimeInterval duration) {
    if (UIMotionReduced()) return;
    CGPoint home = node.position;
    CGFloat alpha = node.alpha;
    node.position = CGPointMake(home.x + offset.dx, home.y + offset.dy);
    node.alpha = 0;
    [node runAction:UIAfter(delay, [SKAction group:@[
        UIEased([SKAction moveTo:home duration:duration], UICurveOut),
        UIEased([SKAction fadeAlphaTo:alpha duration:duration * 0.6], UICurveOut),
    ]])];
}

static SKAction *FlickerTo(CGFloat alpha) {
    return [SKAction sequence:@[
        [SKAction fadeAlphaTo:alpha * 0.7 duration:0], [SKAction waitForDuration:0.035],
        [SKAction fadeAlphaTo:alpha * 0.1 duration:0], [SKAction waitForDuration:0.045],
        [SKAction fadeAlphaTo:alpha * 0.9 duration:0], [SKAction waitForDuration:0.03],
        [SKAction fadeAlphaTo:alpha * 0.35 duration:0], [SKAction waitForDuration:0.05],
        [SKAction fadeAlphaTo:alpha duration:0.06],
    ]];
}

void UIMotionFlickerIn(SKNode *node, NSTimeInterval delay) {
    if (UIMotionReduced()) return;
    CGFloat alpha = node.alpha;
    node.alpha = 0;
    [node runAction:UIAfter(delay, FlickerTo(alpha))];
}

#pragma mark - Text

static unichar ScrambleGlyph(void) {
    static const char glyphs[] = "ABCDEFGHJKLMNPRSTUVXYZ0123456789#%&*+=/<>";
    return glyphs[arc4random_uniform(sizeof(glyphs) - 1)];
}

void UIMotionDecode(SKLabelNode *label, NSTimeInterval delay, NSTimeInterval duration) {
    NSString *text = label.text;
    if (UIMotionReduced() || !text.length) return;
    NSUInteger length = text.length;
    // Left-aligned text can grow as it decodes. Centred or right-aligned text
    // keeps its full width so it doesn't slide while resolving.
    BOOL grows = label.horizontalAlignmentMode == SKLabelHorizontalAlignmentModeLeft;
    const NSUInteger tail = 7;
    __block NSInteger lastStep = -1;
    CGFloat alpha = label.alpha;
    label.alpha = 0;
    label.text = @"";
    SKAction *decode = [SKAction customActionWithDuration:duration actionBlock:^(SKNode *node, CGFloat elapsed) {
        NSInteger step = (NSInteger)(elapsed * 30);
        if (step == lastStep) return;
        lastStep = step;
        node.alpha = alpha;
        CGFloat progress = duration > 0 ? MIN(1, elapsed / duration) : 1;
        NSUInteger resolved = (NSUInteger)(length * progress);
        NSUInteger shown = grows ? MIN(length, resolved + tail) : length;
        NSMutableString *out = [NSMutableString stringWithCapacity:shown];
        for (NSUInteger i = 0; i < shown; i++) {
            unichar c = [text characterAtIndex:i];
            BOOL keep = i < resolved || c == ' ' || c == '\n' || c == '/';
            [out appendFormat:@"%C", (unichar)(keep ? c : ScrambleGlyph())];
        }
        ((SKLabelNode *)node).text = out;
    }];
    [label runAction:UIAfter(delay, [SKAction sequence:@[
        decode,
        [SKAction runBlock:^{ label.text = text; label.alpha = alpha; }],
    ]])];
}

static NSAttributedString *Revealed(SKLabelNode *label, NSString *text, NSUInteger count) {
    UIMotionFont *font = [UIMotionFont fontWithName:label.fontName size:label.fontSize]
                      ?: [UIMotionFont systemFontOfSize:label.fontSize];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = label.lineBreakMode;
    switch (label.horizontalAlignmentMode) {
        case SKLabelHorizontalAlignmentModeCenter: style.alignment = NSTextAlignmentCenter; break;
        case SKLabelHorizontalAlignmentModeRight: style.alignment = NSTextAlignmentRight; break;
        default: style.alignment = NSTextAlignmentLeft; break;
    }
    SKColor *color = label.fontColor ?: [SKColor whiteColor];
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: font, NSParagraphStyleAttributeName: style,
        NSForegroundColorAttributeName: [SKColor clearColor],
    }];
    [out addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(0, MIN(count, text.length))];
    return out;
}

NSTimeInterval UIMotionTypeOn(SKLabelNode *label, NSTimeInterval delay, CGFloat charsPerSecond) {
    NSString *text = label.text;
    if (UIMotionReduced() || !text.length || charsPerSecond <= 0) return 0;
    NSUInteger length = text.length;
    if (!label.userData) label.userData = [NSMutableDictionary dictionary];
    label.userData[TypeTextKey] = text;
    label.attributedText = Revealed(label, text, 0);
    NSTimeInterval duration = length / charsPerSecond;
    __block NSUInteger shown = 0;
    SKAction *type = [SKAction customActionWithDuration:duration actionBlock:^(SKNode *node, CGFloat elapsed) {
        NSUInteger count = MIN(length, (NSUInteger)ceil(elapsed * charsPerSecond));
        if (count == shown) return;
        shown = count;
        SKLabelNode *l = (SKLabelNode *)node;
        l.attributedText = Revealed(l, text, count);
    }];
    [label runAction:UIAfter(delay, [SKAction sequence:@[
        type, [SKAction runBlock:^{ label.attributedText = Revealed(label, text, length); }],
    ]]) withKey:TypeKey];
    return delay + duration;
}

BOOL UIMotionIsTyping(SKLabelNode *label) {
    return label && [label actionForKey:TypeKey] != nil;
}

NSTimeInterval UIMotionDialogueTypeOn(SKLabelNode *label, NSTimeInterval delay, CGFloat charsPerSecond) {
    [label removeActionForKey:TypeKey];
    [[label childNodeWithName:CaretName] removeFromParent];
    NSString *text = label.text;
    if (UIMotionReduced() || !text.length || charsPerSecond <= 0) return 0;
    if (!label.userData) label.userData = [NSMutableDictionary dictionary];
    label.userData[TypeTextKey] = text;
    NSAttributedString *full = Revealed(label, text, text.length);
    label.attributedText = full;

    // Lay out the complete paragraph once, exactly as for the invisible text
    // reveal. Measuring a growing substring would move words between lines.
    NSTextStorage *storage = [[NSTextStorage alloc] initWithAttributedString:full];
    NSLayoutManager *layout = [NSLayoutManager new];
    layout.usesFontLeading = YES;
    NSTextContainer *container = [[NSTextContainer alloc] initWithSize:CGSizeMake(
        label.preferredMaxLayoutWidth > 0 ? label.preferredMaxLayoutWidth : 10000, 10000)];
    container.lineFragmentPadding = 0;
    container.maximumNumberOfLines = label.numberOfLines;
    container.lineBreakMode = label.lineBreakMode;
    [layout addTextContainer:container];
    [storage addLayoutManager:layout];
    [layout ensureLayoutForTextContainer:container];
    CGRect bounds = label.frame;
    CGFloat left = CGRectGetMinX(bounds) - label.position.x;
    CGFloat top = CGRectGetMaxY(bounds) - label.position.y;
    UIMotionFont *font = [full attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    CGFloat height = MAX(label.fontSize, font.capHeight - font.descender + 2);
    CGFloat centerAboveBaseline = (font.capHeight + font.descender) / 2;
    CGFloat cellWidth = [@"M" sizeWithAttributes:@{NSFontAttributeName:font}].width;
    NSMutableArray<UITypeStop *> *stops = [NSMutableArray array];
    NSMutableArray<NSNumber *> *boundaries = [NSMutableArray arrayWithObject:@0];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                         usingBlock:^(NSString *s, NSRange range, NSRange enclosing, BOOL *stop) {
        [boundaries addObject:@(NSMaxRange(range))];
    }];
    for (NSNumber *boundary in boundaries) {
        NSUInteger count = boundary.unsignedIntegerValue;
        // The scanning head covers the character just received while typing.
        NSRange character = [text rangeOfComposedCharacterSequenceAtIndex:count ? count - 1 : 0];
        NSRange glyphs = [layout glyphRangeForCharacterRange:character actualCharacterRange:NULL];
        NSUInteger glyph = glyphs.location;
        CGRect line = [layout lineFragmentUsedRectForGlyphAtIndex:glyph effectiveRange:NULL];
        CGPoint location = [layout locationForGlyphAtIndex:glyph];
        CGRect ink = [layout boundingRectForGlyphRange:glyphs inTextContainer:container];
        CGFloat x = line.origin.x + location.x;
        if (ink.size.width > 0) x = MIN(x, CGRectGetMinX(ink));
        x -= 1;
        UITypeStop *stop = [UITypeStop new];
        stop.count = count;
        // TextKit's glyph location includes the baseline inset inside the line.
        stop.point = CGPointMake(left + x, top - line.origin.y - location.y + centerAboveBaseline);
        stop.size = CGSizeMake(MAX(cellWidth, CGRectGetMaxX(ink) - x + 1), height);
        UITypeStop *previous = stops.lastObject;
        stop.carriageReturn = previous && stop.point.y < previous.point.y - height / 2;
        stop.time = previous ? previous.time + (stop.carriageReturn ? 0.12 : 1 / charsPerSecond) : 0;
        [stops addObject:stop];
    }

    SKNode *caret = [SKNode node];
    caret.name = CaretName;
    caret.zPosition = 1;
    caret.alpha = 0;
    [label addChild:caret];
    SKSpriteNode *block = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 1)
                                                    size:stops.firstObject.size];
    block.anchorPoint = CGPointMake(0, 0.5);
    [caret addChild:block];
    SKSpriteNode *trail = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.25)
                                                    size:CGSizeMake(1, height * 0.65)];
    trail.anchorPoint = CGPointMake(0, 0.5);
    trail.hidden = YES;
    [caret addChild:trail];
    caret.position = stops.firstObject.point;
    label.attributedText = Revealed(label, text, 0);
    __block NSUInteger index = 0, shown = NSNotFound;
    NSTimeInterval duration = stops.lastObject.time;
    SKAction *type = [SKAction customActionWithDuration:duration actionBlock:^(SKNode *node, CGFloat elapsed) {
        while (index + 1 < stops.count && elapsed >= stops[index + 1].time) index++;
        UITypeStop *current = stops[index];
        if (shown != current.count) {
            shown = current.count;
            ((SKLabelNode *)node).attributedText = Revealed((SKLabelNode *)node, text, shown);
        }
        caret.alpha = 1;
        caret.hidden = current.count == text.length;
        caret.position = current.point;
        block.size = current.size;
        trail.hidden = YES;
        if (index + 1 < stops.count && stops[index + 1].carriageReturn) {
            UITypeStop *next = stops[index + 1];
            CGFloat t = MIN(1, MAX(0, (elapsed - current.time) / (next.time - current.time)));
            CGFloat eased = Curve(UICurveOutExpo, t);
            caret.position = CGPointMake(current.point.x + (next.point.x - current.point.x) * eased, next.point.y);
            trail.hidden = NO;
            trail.size = CGSizeMake(MAX(1, current.point.x - caret.position.x), height * 0.65);
            trail.alpha = (1 - t) * 0.8;
        }
    }];
    [label runAction:UIAfter(delay, [SKAction sequence:@[type, [SKAction runBlock:^{
        label.attributedText = full;
        [caret removeFromParent];
    }]]]) withKey:TypeKey];
    return delay + duration;
}

void UIMotionOffsetDialogueCaret(SKLabelNode *label, CGFloat y) {
    for (SKNode *art in [label childNodeWithName:CaretName].children)
        art.position = CGPointMake(art.position.x, y);
}

void UIMotionFinishTyping(SKLabelNode *label) {
    [[label childNodeWithName:CaretName] removeFromParent];
    if (!UIMotionIsTyping(label)) return;
    [label removeActionForKey:TypeKey];
    NSString *text = label.userData[TypeTextKey];
    if (text) label.attributedText = Revealed(label, text, text.length);
}

static void RunGlitch(SKLabelNode *label, NSTimeInterval delay, NSTimeInterval duration, CGFloat strength,
                      SKColor *split, BOOL resolve) {
    SKNode *parent = label.parent;
    if (!parent || UIMotionReduced()) return;
    CGPoint home = label.position;
    CGFloat alpha = label.alpha;
    SKColor *colors[2] = { split ?: [SKColor redColor], [SKColor colorWithRed:0.30 green:0.90 blue:1.0 alpha:1] };
    NSMutableArray<SKLabelNode *> *ghosts = [NSMutableArray array];
    NSUInteger index = [parent.children indexOfObject:label];
    for (int i = 0; i < 2; i++) {
        SKLabelNode *ghost = [label copy];
        [ghost removeAllActions];
        [ghost removeAllChildren];
        ghost.fontColor = colors[i];
        ghost.blendMode = SKBlendModeAdd;
        ghost.alpha = 0;
        if (index == NSNotFound) [parent addChild:ghost];
        else [parent insertChild:ghost atIndex:index];
        [ghosts addObject:ghost];
    }
    if (resolve) label.alpha = 0;
    __block NSInteger lastStep = -1;
    SKAction *glitch = [SKAction customActionWithDuration:duration actionBlock:^(SKNode *node, CGFloat elapsed) {
        NSInteger step = (NSInteger)(elapsed * 30);
        if (step == lastStep) return;
        lastStep = step;
        CGFloat progress = duration > 0 ? MIN(1, elapsed / duration) : 1;
        CGFloat intensity = strength * (1 - progress) * (1 - progress);
        for (int i = 0; i < 2; i++) {
            ghosts[i].alpha = 0.15 + 0.7 * intensity;
            ghosts[i].position = CGPointMake(home.x + (i ? -1 : 1) * (2 + 12 * Random01()) * intensity,
                                             home.y + RandomSigned() * 3 * intensity);
        }
        if (resolve) node.alpha = Random01() < progress * 1.4 ? alpha : (Random01() < 0.5 ? 0 : alpha * 0.4);
        else node.alpha = Random01() < 0.25 * intensity ? alpha * 0.5 : alpha;
        node.position = CGPointMake(home.x + (Random01() < 0.3 * intensity ? RandomSigned() * 7 * intensity : 0), home.y);
    }];
    [label runAction:UIAfter(delay, [SKAction sequence:@[glitch, [SKAction runBlock:^{
        label.position = home;
        label.alpha = alpha;
        for (SKNode *ghost in ghosts) [ghost removeFromParent];
    }]]]) withKey:@"motion.glitch"];
}

void UIMotionGlitchIn(SKLabelNode *label, NSTimeInterval delay, NSTimeInterval duration, SKColor *split) {
    RunGlitch(label, delay, duration, 1, split, YES);
}

void UIMotionGlitchBurst(SKLabelNode *label, NSTimeInterval duration, CGFloat strength, SKColor *split) {
    if ([label actionForKey:@"motion.glitch"]) return;
    RunGlitch(label, 0, duration, strength, split, NO);
}

#pragma mark - Light

static SKTexture *GradientTexture(void);

// A white scan head with a trail fading up behind it, tinted per use.
static SKTexture *TrailTexture(void) {
    static SKTexture *texture;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ texture = GradientTexture(); });
    return texture;
}

static SKTexture *GradientTexture(void) {
    const size_t w = 4, h = 128;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 2, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    for (size_t y = 0; y < h; y++) {
        // The head is the bottom row; the trail fades upward.
        CGFloat t = (CGFloat)y / (h - 1);
        CGFloat a = y < 1 ? 1 : 0.32 * pow(1 - t, 2.2);
        CGContextSetGrayFillColor(ctx, a, a);
        CGContextFillRect(ctx, CGRectMake(0, y, w, 1));
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    SKTexture *texture = [SKTexture textureWithCGImage:image];
    CGImageRelease(image);
    return texture;
}

static SKSpriteNode *Light(SKTexture *texture, CGSize size, SKColor *color) {
    SKSpriteNode *sprite = [SKSpriteNode spriteNodeWithTexture:texture size:size];
    sprite.color = color;
    sprite.colorBlendFactor = 1;
    sprite.blendMode = SKBlendModeAdd;
    return sprite;
}

void UIMotionSweep(SKNode *parent, CGRect rect, SKColor *color, BOOL downward,
                   NSTimeInterval delay, NSTimeInterval duration) {
    if (UIMotionReduced() || !parent || CGRectIsEmpty(rect)) return;
    CGFloat trail = MIN(rect.size.height * 0.4, 110);
    SKSpriteNode *scan = Light(TrailTexture(), CGSizeMake(rect.size.width, trail), color);
    scan.anchorPoint = CGPointMake(0.5, 0);
    if (!downward) scan.yScale = -1;   // trail below the head
    CGFloat from = downward ? CGRectGetMaxY(rect) : CGRectGetMinY(rect);
    CGFloat to = downward ? CGRectGetMinY(rect) : CGRectGetMaxY(rect);
    scan.position = CGPointMake(CGRectGetMidX(rect), from);
    scan.alpha = 0;
    [parent addChild:scan];
    [scan runAction:UIAfter(delay, [SKAction sequence:@[
        [SKAction group:@[
            UIEased([SKAction moveToY:to duration:duration], UICurveInOut),
            [SKAction sequence:@[
                [SKAction fadeAlphaTo:1 duration:duration * 0.15],
                [SKAction waitForDuration:duration * 0.6],
                [SKAction fadeAlphaTo:0 duration:duration * 0.25],
            ]],
        ]],
        [SKAction removeFromParent],
    ]])];
}

SKSpriteNode *UIMotionBeam(SKNode *parent, CGFloat x0, CGFloat x1, CGFloat y, SKColor *color) {
    // A hairline like the rest of the interface's strokes.
    SKSpriteNode *beam = [SKSpriteNode spriteNodeWithColor:color size:CGSizeMake(fabs(x1 - x0), 1)];
    beam.anchorPoint = CGPointMake(x1 >= x0 ? 0 : 1, 0.5);
    beam.position = CGPointMake(x0, y);
    [parent addChild:beam];
    return beam;
}

#pragma mark - Panels

SKNode *UIMotionDrawPanel(SKNode *panel, CGRect rect, SKColor *color, BOOL fromRight,
                          NSTimeInterval delay, NSTimeInterval *ready) {
    SKNode *parent = panel.parent;
    SKNode *holder = UIMotionPivot(panel, CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect)));
    if (ready) *ready = delay;
    if (UIMotionReduced() || !parent) return holder;

    const NSTimeInterval run = 0.18, open = 0.24;
    CGFloat edge = fromRight ? CGRectGetMaxX(rect) : CGRectGetMinX(rect);
    CGFloat other = fromRight ? CGRectGetMinX(rect) : CGRectGetMaxX(rect);
    SKSpriteNode *top = UIMotionBeam(parent, edge, other, CGRectGetMaxY(rect), color);
    top.xScale = 0;
    [top runAction:UIAfter(delay, [SKAction sequence:@[
        UIEased([SKAction scaleXTo:1 duration:run], UICurveOutExpo),
        [SKAction waitForDuration:open * 0.6],
        [SKAction fadeAlphaTo:0 duration:0.3],
        [SKAction removeFromParent],
    ]])];

    SKSpriteNode *bottom = UIMotionBeam(parent, edge, other, CGRectGetMaxY(rect), color);
    bottom.alpha = 0;
    NSTimeInterval drop = delay + run * 0.7;
    [bottom runAction:UIAfter(drop, [SKAction sequence:@[
        [SKAction fadeAlphaTo:1 duration:0],
        UIEased([SKAction moveToY:CGRectGetMinY(rect) duration:open], UICurveOut),
        [SKAction fadeAlphaTo:0 duration:0.3],
        [SKAction removeFromParent],
    ]])];

    holder.yScale = 0.001;
    [holder runAction:UIAfter(drop, [SKAction sequence:@[
        UIEased([SKAction scaleYTo:1 duration:open], UICurveOut),
        [SKAction fadeAlphaTo:0.7 duration:0.03], [SKAction fadeAlphaTo:1 duration:0.05],
    ]])];
    if (ready) *ready = drop + open * 0.5;
    return holder;
}

NSTimeInterval UIMotionClosePanel(SKNode *holder, CGRect rect, SKColor *color, BOOL toRight) {
    SKNode *parent = holder.parent;
    if (UIMotionReduced() || !parent) {
        [holder removeFromParent];
        return 0;
    }
    // Roll down: the top edge falls onto the bottom edge, riding a line that
    // then retracts toward the speaker's side.
    const NSTimeInterval shut = 0.15, retract = 0.12;
    CGFloat edge = toRight ? CGRectGetMaxX(rect) : CGRectGetMinX(rect);
    CGFloat other = toRight ? CGRectGetMinX(rect) : CGRectGetMaxX(rect);
    CGFloat floor = CGRectGetMaxY(rect) - CGRectGetHeight(rect) * holder.yScale;
    SKSpriteNode *line = UIMotionBeam(parent, edge, other, CGRectGetMaxY(rect), color);
    [line runAction:[SKAction sequence:@[
        UIEased([SKAction moveToY:floor duration:shut], UICurveIn),
        UIEased([SKAction scaleXTo:0 duration:retract], UICurveIn),
        [SKAction removeFromParent],
    ]]];
    // The holder pivots on its top edge, so moving it down while it shrinks
    // keeps the bottom edge where it is.
    [holder removeAllActions];
    [holder runAction:[SKAction sequence:@[
        [SKAction group:@[
            UIEased([SKAction moveToY:floor duration:shut], UICurveIn),
            UIEased([SKAction scaleYTo:0.001 duration:shut], UICurveIn),
        ]],
        [SKAction removeFromParent],
    ]]];
    return shut + retract;
}

void UIMotionWipe(SKNode *node, CGRect rect, SKColor *line, NSTimeInterval delay, NSTimeInterval duration) {
    if (UIMotionReduced() || !node.parent || CGRectIsEmpty(rect)) return;
    SKNode *parent = node.parent;
    SKCropNode *crop = [SKCropNode node];
    SKSpriteNode *mask = [SKSpriteNode spriteNodeWithColor:[SKColor whiteColor] size:rect.size];
    mask.anchorPoint = CGPointMake(0.5, 1);
    mask.position = CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect));
    mask.yScale = 0.001;
    crop.maskNode = mask;
    InsertInPlace(crop, node);
    // The mask isn't in the tree, so its own actions wouldn't run: drive it
    // from the crop node.
    [crop runAction:UIAfter(delay, [SKAction customActionWithDuration:duration actionBlock:^(SKNode *n, CGFloat elapsed) {
        mask.yScale = MAX(0.001, Curve(UICurveInOut, duration > 0 ? MIN(1, elapsed / duration) : 1));
    }])];
    if (line) UIMotionSweep(parent, rect, line, YES, delay, duration);
}

#pragma mark - Exits

NSTimeInterval UIMotionDismiss(SKNode *node, CGVector drift, NSTimeInterval duration) {
    if (UIMotionReduced()) {
        [node runAction:[SKAction sequence:@[[SKAction fadeOutWithDuration:0.1], [SKAction removeFromParent]]]];
        return 0.1;
    }
    CGFloat alpha = node.alpha;
    [node removeAllActions];
    [node runAction:[SKAction sequence:@[
        [SKAction group:@[
            UIEased([SKAction moveBy:drift duration:duration], UICurveIn),
            [SKAction sequence:@[
                [SKAction fadeAlphaTo:alpha * 0.35 duration:0.04],
                [SKAction fadeAlphaTo:alpha * 0.8 duration:0.03],
                [SKAction fadeAlphaTo:0 duration:MAX(0.01, duration - 0.07)],
            ]],
        ]],
        [SKAction removeFromParent],
    ]]];
    return duration;
}

NSTimeInterval UIMotionPowerDown(SKNode *stage, CGSize size) {
    if (UIMotionReduced() || !stage.parent) {
        [stage runAction:[SKAction fadeOutWithDuration:0.15]];
        return 0.15;
    }
    const NSTimeInterval collapse = 0.16, shrink = 0.14, fade = 0.12;
    SKSpriteNode *flash = [SKSpriteNode spriteNodeWithColor:[SKColor colorWithWhite:0.95 alpha:1]
                                                       size:CGSizeMake(size.width, 1)];
    flash.position = CGPointMake(size.width / 2, size.height / 2);
    flash.alpha = 0;
    [stage.parent addChild:flash];
    [flash runAction:[SKAction sequence:@[
        [SKAction waitForDuration:collapse * 0.6],
        [SKAction fadeAlphaTo:1 duration:collapse * 0.4],
        UIEased([SKAction scaleXTo:0.004 duration:shrink], UICurveIn),
        [SKAction group:@[[SKAction scaleXTo:0.012 duration:fade], [SKAction fadeOutWithDuration:fade]]],
        [SKAction removeFromParent],
    ]]];
    [stage runAction:[SKAction sequence:@[
        UIEased([SKAction scaleYTo:0.006 duration:collapse], UICurveIn),
        [SKAction group:@[
            UIEased([SKAction scaleXTo:0 duration:shrink], UICurveIn),
            [SKAction fadeOutWithDuration:shrink],
        ]],
    ]]];
    return collapse + shrink + fade;
}

#pragma mark - Hover

@implementation UIHover {
    NSMutableArray<NSValue *> *_rects;
    NSMutableArray<SKNode *> *_overlays;
    NSInteger _current;
    CGPoint _fraction, _pending;
    BOOL _hasPending;
}

- (instancetype)init {
    if ((self = [super init])) {
        _rects = [NSMutableArray array];
        _overlays = [NSMutableArray array];
        _current = -1;
        _fraction = CGPointMake(-1, -1);
    }
    return self;
}

- (void)queuePointAtFraction:(CGPoint)point {
    _pending = point;
    _hasPending = YES;
}

- (void)reset {
    [_rects removeAllObjects];
    [_overlays removeAllObjects];
    _current = -1;
}

- (CGPoint)pointIn:(SKScene *)scene {
    if (_fraction.x < 0 || _fraction.y < 0) return CGPointMake(-1e6, -1e6);
    return CGPointMake(_fraction.x * scene.size.width, _fraction.y * scene.size.height);
}

- (void)addButton:(SKNode *)button rect:(CGRect)rect accent:(UIRGB)accent {
    if (!button || CGRectIsEmpty(rect)) return;
    // A brighter edge and a lit face, extending out of the left edge.
    CGPoint pivot = CGPointMake(CGRectGetMinX(rect), CGRectGetMidY(rect));
    SKNode *overlay = [SKNode node];
    overlay.position = pivot;
    SKShapeNode *face = UISkewedShape(rect, UIColorWithOpacity(accent, 1), UIColorWithOpacity(accent, 0.14));
    face.blendMode = SKBlendModeAdd;
    face.position = CGPointMake(-pivot.x, -pivot.y);
    [overlay addChild:face];
    overlay.alpha = 0;
    [button addChild:overlay];
#if TARGET_OS_IOS
    [_rects addObject:[NSValue valueWithCGRect:rect]];
#else
    [_rects addObject:[NSValue valueWithRect:rect]];
#endif
    [_overlays addObject:overlay];
    // A rebuild under a resting pointer keeps the button lit without replaying the animation.
    SKScene *scene = button.scene;
    if (scene && _current < 0 && CGRectContainsPoint(rect, [self pointIn:scene])) {
        _current = (NSInteger)_overlays.count - 1;
        overlay.alpha = 1;
    }
}

- (void)updateInScene:(SKScene *)scene {
    if (!_hasPending) return;
    _fraction = _pending;
    _hasPending = NO;
    CGPoint point = [self pointIn:scene];
    NSInteger hit = -1;
    for (NSUInteger i = 0; i < _rects.count; i++)
#if TARGET_OS_IOS
        if (CGRectContainsPoint(_rects[i].CGRectValue, point)) { hit = (NSInteger)i; break; }
#else
        if (CGRectContainsPoint(_rects[i].rectValue, point)) { hit = (NSInteger)i; break; }
#endif
    if (hit == _current) return;
    if (_current >= 0 && _current < (NSInteger)_overlays.count) {
        SKNode *out = _overlays[_current];
        [out removeAllActions];
        [out runAction:UIMotionReduced() ? [SKAction fadeOutWithDuration:0]
                                         : UIEased([SKAction fadeOutWithDuration:0.22], UICurveOut)];
    }
    _current = hit;
    if (hit < 0) return;
    [[GameAudio shared] play:@"ui-hover"];
    SKNode *in = _overlays[hit];
    [in removeAllActions];
    if (UIMotionReduced()) { in.alpha = 1; return; }
    in.xScale = 0.92;
    [in runAction:[SKAction group:@[
        UIEased([SKAction fadeInWithDuration:0.12], UICurveOut),
        UIEased([SKAction scaleXTo:1 duration:0.2], UICurveOutExpo),
    ]]];
}

@end
