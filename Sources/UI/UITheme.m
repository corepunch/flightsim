#import "UI.h"
#import "Shared.h"
#import <CoreText/CoreText.h>

void UISetCenteredButtonText(SKLabelNode *label, NSString *text) {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = label.lineBreakMode;
#if TARGET_OS_IOS
    UIFont *font = [UIFont fontWithName:label.fontName size:label.fontSize] ?: [UIFont systemFontOfSize:label.fontSize];
#else
    NSFont *font = [NSFont fontWithName:label.fontName size:label.fontSize] ?: [NSFont systemFontOfSize:label.fontSize];
#endif
    label.text = text;
    label.attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName:font, NSForegroundColorAttributeName:label.fontColor ?: SKColor.whiteColor,
        NSParagraphStyleAttributeName:paragraph,
    }];
}

void UIFitMultilineButtonLabel(SKLabelNode *label, NSString *text, NSUInteger lines, CGFloat height) {
    NSString *remaining = text ?: @"";
    for (;;) {
        UISetCenteredButtonText(label, remaining);
        // Count shaped lines instead of estimating their height from a Latin font.
        CTFramesetterRef setter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)label.attributedText);
        CGPathRef path = CGPathCreateWithRect(CGRectMake(0,0,label.preferredMaxLayoutWidth,100000),NULL);
        CTFrameRef frame = CTFramesetterCreateFrame(setter,CFRangeMake(0,0),path,NULL);
        CFIndex count = CFArrayGetCount(CTFrameGetLines(frame));
        CFRelease(frame); CGPathRelease(path); CFRelease(setter);
        // SpriteKit rounds ink bounds beyond the advances used to wrap a line.
        CGFloat inkWidth = ceil(label.preferredMaxLayoutWidth) + 1;
        if ((count <= (CFIndex)lines && CGRectGetHeight(label.frame) <= height &&
            CGRectGetWidth(label.frame) <= inkWidth) || !remaining.length) break;
        NSString *unmarked = [remaining hasSuffix:@"…"] ? [remaining substringToIndex:remaining.length-1] : remaining;
        if (!unmarked.length) { remaining = @""; continue; }
        NSRange last = [unmarked rangeOfComposedCharacterSequenceAtIndex:unmarked.length-1];
        remaining = last.location ? [[unmarked substringToIndex:last.location] stringByAppendingString:@"…"] : @"";
    }
}

static NSDictionary *Theme(void) {
    static NSDictionary *theme;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = FSURL(@"UI", @"theme", @"json");
        NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
        NSError *error = nil;
        id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        if (![root isKindOfClass:NSDictionary.class]) {
            NSLog(@"UITheme: UI/theme.json unreadable: %@", error.localizedDescription ?: @"missing");
            root = @{};
        }
        theme = root;
    });
    return theme;
}

static id Value(NSString *section, NSString *name, Class type) {
    id value = Theme()[section][name];
    if ([value isKindOfClass:type]) return value;
    static NSMutableSet *reported;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ reported = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%@.%@", section, name];
    @synchronized (reported) {
        if (![reported containsObject:key]) {
            [reported addObject:key];
            NSLog(@"UITheme: no %@ in UI/theme.json", key);
        }
    }
    return nil;
}

UIRGB UIThemeColor(NSString *name) {
    NSArray *c = Value(@"colors", name, NSArray.class);
    if (c.count < 3) return (UIRGB){ 1, 0, 1 };
    return (UIRGB){ [c[0] doubleValue], [c[1] doubleValue], [c[2] doubleValue] };
}

NSString *UIThemeFont(NSString *name) {
    return Value(@"fonts", name, NSString.class) ?: @"Menlo";
}

CGFloat UIThemeMetric(NSString *name) {
    return [Value(@"metrics", name, NSNumber.class) doubleValue];
}

UIMotionStyle UIThemeMotion(void) {
    static UIMotionStyle style;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *name = JSONString(Theme(), @"motion") ?: @"full";
        NSDictionary<NSString *, NSNumber *> *styles = @{
            @"full": @(UIMotionStyleFull), @"fade": @(UIMotionStyleFade), @"none": @(UIMotionStyleNone),
        };
        NSNumber *value = styles[name];
        if (!value) NSLog(@"UITheme: motion \"%@\" is not full, fade or none; using full", name);
        style = value ? value.integerValue : UIMotionStyleFull;
    });
    return style;
}
