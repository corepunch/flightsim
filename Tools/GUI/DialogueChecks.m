#import <Cocoa/Cocoa.h>
#import "Assets.h"
#import "Story.h"
#import "Briefing.h"
#import "UIMotion.h"
#import "Cvar.h"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "Dialogue check failed at line %d: %s\n", __LINE__, #c); return EXIT_FAILURE; } } while (0)

static SKView *view;
static NSWindow *window;
static double previousTime;

static void Render(SKView *renderer, double time) {
    double delta = MAX(0.01, time - previousTime);
    previousTime = time;
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:delta];
    while (until.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:until];
}

static void Save(NSString *path) {
    SKTexture *texture = [view textureFromNode:view.scene crop:(CGRect){.size = view.scene.size}];
    NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithCGImage:texture.CGImage];
    [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

static void SizeTarget(CGSize size) {
    if (!window) window = [[NSWindow alloc] initWithContentRect:(NSRect){.size = size}
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    [window setContentSize:size];
    view = [[SKView alloc] initWithFrame:(NSRect){.size = size}];
    view.preferredFramesPerSecond = 120;
    window.contentView = view;
    [window orderBack:nil];
    previousTime = 0;
}

static NSUInteger RevealedCount(SKLabelNode *label) {
    NSAttributedString *text = label.attributedText;
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        NSColor *color = [text attribute:NSForegroundColorAttributeName atIndex:i effectiveRange:NULL];
        if (color.alphaComponent > 0) count++;
    }
    return count;
}

static int CheckCaret(NSString *output) {
    for (NSNumber *width in @[@500, @220]) {
        CGSize size = CGSizeMake(640, 360);
        SizeTarget(size);
        SKScene *scene = [SKScene sceneWithSize:size];
        scene.backgroundColor = UIColorWithOpacity(UIBackground, 1);
        SKView *renderer = view;
        [view presentScene:scene];
        SKLabelNode *speech = UIMonoLabel(22, SKColor.whiteColor, SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeTop);
        speech.fontName = UIBodyFont;
        speech.numberOfLines = 0;
        speech.preferredMaxLayoutWidth = width.doubleValue;
        speech.lineBreakMode = NSLineBreakByWordWrapping;
        speech.text = @"Lancer 1, hold formation. Watch the relay.\nMira — café 👩🏽‍🚀 is clear for approach.";
        speech.position = CGPointMake(50, 300);
        [scene addChild:speech];
        NSString *full = speech.text;
        CGRect frame = speech.frame;
        double duration = UIMotionDialogueTypeOn(speech, 0.2, 40);
        CHECK(UIMotionIsTyping(speech));
        SKNode *caret = [speech childNodeWithName:@"motion.caret"];
        CHECK(caret && caret.alpha == 0);
        SKSpriteNode *block = (SKSpriteNode *)caret.children.firstObject;
        CHECK(block.size.height >= speech.fontSize);
        CHECK(block.size.width >= [@"M" sizeWithAttributes:@{NSFontAttributeName:
            [NSFont fontWithName:speech.fontName size:speech.fontSize]}].width);
        Render(renderer, 0);
        CHECK(RevealedCount(speech) == 0);
        NSUInteger previous = 0, returns = 0;
        CGFloat previousY = caret.position.y;
        for (int i = 1; i < (duration + 0.4) * 60; i++) {
            @autoreleasepool {
                Render(renderer, i / 60.0);
                NSUInteger count = RevealedCount(speech);
                CHECK(count >= previous);
                if (count == full.length) CHECK(!caret.parent || caret.hidden);
                // A composed emoji must appear whole, never as half a surrogate pair.
                NSRange emoji = [full rangeOfString:@"👩🏽‍🚀"];
                CHECK(count <= emoji.location || count >= NSMaxRange(emoji));
                CHECK(CGRectEqualToRect(frame, speech.frame));
                CHECK(isfinite(caret.position.x) && isfinite(caret.position.y));
                CHECK(caret.position.x >= -1 && caret.position.x <= width.doubleValue + 1);
                if (caret.position.y < previousY - 2) returns++;
                previousY = caret.position.y;
                previous = count;
                if (i == 65) Save([output stringByAppendingPathComponent:[NSString stringWithFormat:@"caret-%@.png", width]]);
            }
        }
        fprintf(stderr, "width %.0f: %lu returns, %lu/%lu characters\n", width.doubleValue, (unsigned long)returns, (unsigned long)previous, (unsigned long)full.length);
        CHECK(returns >= (width.doubleValue < 300 ? 3 : 1));
        CHECK(!UIMotionIsTyping(speech) && previous == full.length);
        CHECK(![speech childNodeWithName:@"motion.caret"]);
        UIMotionFinishTyping(speech);
        CHECK(![speech childNodeWithName:@"motion.caret"]);
        speech.attributedText = nil;
        speech.text = full;
        UIMotionDialogueTypeOn(speech, 10, 40);
        UIMotionFinishTyping(speech); // Skip during the opening delay.
        CHECK(!UIMotionIsTyping(speech) && RevealedCount(speech) == full.length);
        CHECK(![speech childNodeWithName:@"motion.caret"]);
    }
    return EXIT_SUCCESS;
}

static int CheckCampaignCaptions(void) {
    for (NSValue *value in @[[NSValue valueWithSize:NSMakeSize(1600, 900)],
                             [NSValue valueWithSize:NSMakeSize(640, 660)],
                             [NSValue valueWithSize:NSMakeSize(852, 393)]]) {
        Briefing *scene = [[Briefing alloc] initWithSize:value.sizeValue];
        for (NSUInteger mission = 0; mission < CampaignMissions().count; mission++) {
            [scene showBriefing:mission];
            [(id<UIMotionScene>)scene motionEnter];
            NSUInteger pages = [[scene valueForKey:@"_pages"] count];
            for (NSUInteger page = 0; page < pages; page++) {
                SKLabelNode *speech = [scene valueForKey:@"_speech"];
                CGRect panel = [[scene valueForKey:@"_captionRect"] rectValue];
                CHECK([speech.fontName isEqualToString:UIBodyFont]);
                CHECK(CGRectContainsRect(CGRectInset(panel, -1, -1), speech.frame));
                UIMotionFinishTyping(speech);
                if (page + 1 < pages) [scene handle:InputActionRight];
            }
        }
    }
    return EXIT_SUCCESS;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        CHECK(argc == 2);
        [NSApp finishLaunching];
        NSString *output = @(argv[1]);
        for (NSString *name in @[UIBodyFont, UIBodyMediumFont, UIInterfaceBoldFont])
            CHECK([NSFont fontWithName:name size:22]);
        NSDictionary *attributes = @{NSFontAttributeName: [NSFont fontWithName:UIBodyFont size:22]};
        CHECK([@"WWW" sizeWithAttributes:attributes].width > [@"iii" sizeWithAttributes:attributes].width * 1.5);
        // The typing and caret checks need motion whatever the machine's
        // accessibility setting says (CI runners have Reduce Motion on).
        [Cvar set:@"ui_reduceMotion" value:@"0"];
        CHECK(!UIMotionReduced());
        if (CheckCampaignCaptions() != EXIT_SUCCESS) return EXIT_FAILURE;
        if (CheckCaret(output) != EXIT_SUCCESS) return EXIT_FAILURE;
        for (NSValue *value in @[[NSValue valueWithSize:NSMakeSize(1600, 900)], [NSValue valueWithSize:NSMakeSize(852, 393)]]) {
            CGSize size = value.sizeValue;
            SizeTarget(size);
            Briefing *scene = [[Briefing alloc] initWithSize:size];
            [scene showBriefing:0];
            [(id<UIMotionScene>)scene motionEnter];
            SKView *renderer = view;
            [view presentScene:scene];
            for (int i = 0; i <= 210; i++) {
                @autoreleasepool {
                    Render(renderer, i / 60.0);
                    if (i == 100 || i == 210) Save([output stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"briefing-%.0f-%d.png", size.width, i]]);
                }
            }
            SKLabelNode *speech = [scene valueForKey:@"_speech"];
            UIMotionFinishTyping(speech);
            CHECK(!UIMotionIsTyping(speech));
            CHECK(![speech childNodeWithName:@"motion.caret"]);
            [scene handle:InputActionRight];
            CHECK([[scene valueForKey:@"_page"] unsignedIntegerValue] == 1);
            speech = [scene valueForKey:@"_speech"];
            CHECK(UIMotionIsTyping(speech));
            [scene handle:InputActionRight]; // Skip while the new bubble is opening.
            CHECK(!UIMotionIsTyping(speech));
            CHECK(![speech childNodeWithName:@"motion.caret"]);
            CHECK([[scene valueForKey:@"_page"] unsignedIntegerValue] == 1);
        }
        puts("PASS: dialogue caret, line returns, Unicode, skip controls and rendered briefing at desktop and phone sizes.");
    }
    return EXIT_SUCCESS;
}
