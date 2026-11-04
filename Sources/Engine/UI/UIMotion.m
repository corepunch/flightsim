#import "UIMotion.h"
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
typedef UIFont UIMotionFont;
#else
#import <AppKit/AppKit.h>
typedef NSFont UIMotionFont;
#endif

static NSString * const TypeKey = @"motion.type";
static NSString * const TypeTextKey = @"motion.text";

BOOL UIMotionReduced(void) {
#if TARGET_OS_IOS
    return UIAccessibilityIsReduceMotionEnabled();
#else
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
#endif
}

double UIMotionTimeScale(void) {
    static double scale;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *slow = getenv("SF_UI_SLOWMO");
        scale = slow && atof(slow) > 0 ? atof(slow) : 1;
    });
    return scale;
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

void UIMotionFinishTyping(SKLabelNode *label) {
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

// White textures, tinted per use: a scan head with a trail behind it, and a
// beam with a soft vertical falloff.
static SKTexture *GradientTexture(BOOL trail) {
    const size_t w = 4, h = trail ? 128 : 24;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 2, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    for (size_t y = 0; y < h; y++) {
        CGFloat a;
        if (trail) {
            // The head is the bottom two rows; the trail fades upward.
            CGFloat t = (CGFloat)y / (h - 1);
            a = y < 2 ? 1 : 0.32 * pow(1 - t, 2.2);
        } else {
            CGFloat d = ((CGFloat)y - (h - 1) / 2.0) / ((h - 1) / 2.0);
            a = exp(-d * d * 9) + 0.6 * exp(-d * d * 90);
            a = MIN(1, a);
        }
        CGContextSetGrayFillColor(ctx, a, a);
        CGContextFillRect(ctx, CGRectMake(0, y, w, 1));
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    SKTexture *texture = [SKTexture textureWithCGImage:image];
    CGImageRelease(image);
    return texture;
}

static SKTexture *TrailTexture(void) {
    static SKTexture *texture;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ texture = GradientTexture(YES); });
    return texture;
}

static SKTexture *BeamTexture(void) {
    static SKTexture *texture;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ texture = GradientTexture(NO); });
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
    SKSpriteNode *beam = Light(BeamTexture(), CGSizeMake(fabs(x1 - x0), 12), color);
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
    const NSTimeInterval shut = 0.13, retract = 0.12;
    CGFloat edge = toRight ? CGRectGetMaxX(rect) : CGRectGetMinX(rect);
    CGFloat other = toRight ? CGRectGetMinX(rect) : CGRectGetMaxX(rect);
    CGFloat from = CGRectGetMinY(rect) + (CGRectGetHeight(rect)) * (1 - holder.yScale);
    SKSpriteNode *bottom = UIMotionBeam(parent, edge, other, from, color);
    [bottom runAction:[SKAction sequence:@[
        UIEased([SKAction moveToY:CGRectGetMaxY(rect) duration:shut], UICurveIn),
        UIEased([SKAction scaleXTo:0 duration:retract], UICurveIn),
        [SKAction removeFromParent],
    ]]];
    [holder removeAllActions];
    [holder runAction:[SKAction sequence:@[
        UIEased([SKAction scaleYTo:0.001 duration:shut], UICurveIn),
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
    SKSpriteNode *flash = Light(BeamTexture(), CGSizeMake(size.width, 14), [SKColor colorWithWhite:0.9 alpha:1]);
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
