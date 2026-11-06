#import <Cocoa/Cocoa.h>
#import "Shared.h"
#import "Story.h"
#import "UI.h"
#import "Common.h"

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
    // SpriteKit suspends fully occluded views; typing needs real frames.
    [window orderFrontRegardless];
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

// Marked keywords: the asterisks are gone, the keyword is in the highlight
// colour from the first frame it is revealed, and typing counts visible characters.
static int CheckHighlight(void) {
    CGSize size = CGSizeMake(640, 360);
    SizeTarget(size);
    SKScene *scene = [SKScene sceneWithSize:size];
    SKView *renderer = view;
    [view presentScene:scene];
    SKLabelNode *speech = UIMonoLabel(22, SKColor.whiteColor, SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeTop);
    speech.fontName = UIBodyFont;
    speech.numberOfLines = 0;
    speech.preferredMaxLayoutWidth = 500;
    NSArray<NSValue *> *marks;
    speech.text = StoryPlainText(@"Destroy the *Corvette Vesk* now.", &marks);
    CHECK([speech.text isEqualToString:@"Destroy the Corvette Vesk now."] && marks.count == 1);
    UIMotionHighlight(speech, marks, UIColorWithOpacity(UIYellow, 1));
    speech.position = CGPointMake(50, 300);
    [scene addChild:speech];
    double duration = UIMotionDialogueTypeOn(speech, 0, 40);
    NSString *plain = speech.text;
    Render(renderer, 0);
    for (int i = 1; i < (duration + 0.3) * 60; i++) Render(renderer, i / 60.0);
    CHECK(!UIMotionIsTyping(speech) && RevealedCount(speech) == plain.length);
    NSAttributedString *text = speech.attributedText;
    NSRange keyword = marks[0].rangeValue;
    CHECK([text.string isEqualToString:plain]);
    CHECK(![[text.string substringWithRange:keyword] containsString:@"*"]);
    NSColor *inside = [text attribute:NSForegroundColorAttributeName atIndex:keyword.location effectiveRange:NULL];
    NSColor *outside = [text attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
    CHECK(![inside isEqual:outside]);
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
                SKLabelNode *speech = scene.speech;
                CGRect panel = scene.captionRect;
                CHECK([speech.fontName isEqualToString:UIBodyFont]);
                CHECK(CGRectContainsRect(CGRectInset(panel, -1, -1), speech.frame));
                UIMotionFinishTyping(speech);
                if (page + 1 < pages) [scene handle:InputActionRight];
            }
        }
    }
    return EXIT_SUCCESS;
}

static int CheckSharedConversationStage(NSString *output) {
    NSString *motion = [Cvar find:@"ui_reduceMotion"].string;
    [Cvar set:@"ui_reduceMotion" value:@"1"];
    const CGSize sizes[] = {{667,375}, {852,393}, {1194,834}, {1600,900}};
    const NSEdgeInsets insets[] = {{0,0,0,0}, {0,59,21,59}, {24,0,20,0}, {0,0,0,0}};
    for (NSUInteger v = 0; v < sizeof(sizes) / sizeof(sizes[0]); v++) {
        SizeTarget(sizes[v]);
        Briefing *scene = [[Briefing alloc] initWithSize:sizes[v]];
        scene.touchNavigationEnabled = v < 3;
        scene.contentInsets = insets[v];
        for (NSUInteger mission = 0; mission < CampaignMissions().count; mission++) {
            [scene showBriefing:mission];
            CGRect player = [scene portraitRectForCharacter:StoryPlayer()];
            CGRect caption = scene.captionRect;
            CGFloat fontSize = scene.speech.fontSize;
            if (mission == 0) {
                [view presentScene:scene];
                Save([output stringByAppendingPathComponent:[NSString stringWithFormat:@"stage-before-%.0f.png", sizes[v].width]]);
            }
            [scene showDebrief:mission success:YES results:@[]];
            NSUInteger beat = 0;
            for (StoryLine *line in CampaignMissionAt(mission).debrief.dialogue) {
                UIMotionFinishTyping(scene.speech);
                [scene handle:InputActionConfirm];
                CHECK(CGRectEqualToRect(player, [scene portraitRectForCharacter:StoryPlayer()]));
                CHECK(fabs(CGRectGetWidth(caption) - CGRectGetWidth(scene.captionRect)) < 0.01);
                if (fabs(CGRectGetMaxY(caption) - CGRectGetMaxY(scene.captionRect)) >= 0.01)
                    fprintf(stderr, "Stage mismatch %.0fx%.0f mission %lu: %s -> %s, font %.0f\n", sizes[v].width, sizes[v].height,
                            (unsigned long)mission + 1, NSStringFromRect(caption).UTF8String, NSStringFromRect(scene.captionRect).UTF8String, fontSize);
                CHECK(fabs(CGRectGetMaxY(caption) - CGRectGetMaxY(scene.captionRect)) < 0.01);
                CHECK(scene.speech.fontSize == fontSize);
                CHECK(CGRectContainsRect(CGRectInset(scene.captionRect, -1, -1), scene.speech.frame));
                NSString *other = [line.portrait isEqualToString:StoryPlayer()] ? line.listener : line.portrait;
                CGRect speaker = [scene portraitRectForCharacter:other];
                CHECK(!CGRectIsEmpty(speaker));
                CHECK(fabs(CGRectGetHeight(player) - CGRectGetHeight(speaker)) < 0.01);
                if (v < 2) {
                    CHECK(CGRectGetMaxY(player) > CGRectGetMaxY(scene.captionRect) + 32);
                    CHECK(CGRectGetMaxY(speaker) > CGRectGetMaxY(scene.captionRect) + 32);
                }
                if (mission == 0 && beat < 2) {
                    UIMotionFinishTyping(scene.speech);
                    Save([output stringByAppendingPathComponent:[NSString stringWithFormat:@"stage-after-%.0f-%lu.png", sizes[v].width, (unsigned long)beat]]);
                }
                beat++;
            }
        }
    }
    [Cvar set:@"ui_reduceMotion" value:motion];
    return EXIT_SUCCESS;
}

// Map steps with a camera or labels: each plays out for a second and a half
// and is saved, to look at how the camera framed the page.
static int CheckTimeline(NSString *output) {
    CGSize size = CGSizeMake(1600, 900);
    SizeTarget(size);
    Briefing *scene = [[Briefing alloc] initWithSize:size];
    SKView *renderer = view;
    [view presentScene:scene];
    for (NSUInteger mission = 0; mission < CampaignMissions().count; mission++) {
        BOOL any = NO;
        for (BriefingStep *step in CampaignMissionAt(mission).briefing.steps) any |= step.camera || step.labels.count;
        if (!any) continue;
        [scene showBriefing:mission];
        [(id<UIMotionScene>)scene motionEnter];
        NSArray<BriefingPage *> *pages = [scene valueForKey:@"_pages"];
        for (NSUInteger page = 0; page < pages.count; page++) {
            BriefingStep *step = pages[page].step;
            if (step.camera || step.labels.count) {
                for (int i = 0; i < 90; i++) @autoreleasepool { Render(renderer, i / 60.0); }
                Save([output stringByAppendingPathComponent:[NSString stringWithFormat:@"timeline-%lu-%lu.png",
                                                             (unsigned long)mission + 1, (unsigned long)page + 1]]);
            }
            UIMotionFinishTyping(scene.speech);
            if (page + 1 < pages.count) [scene handle:InputActionRight];
        }
    }
    return EXIT_SUCCESS;
}

// Autoplay: a timed step moves on after its caption has typed and its
// seconds are up; any input stops it for the rest of the briefing.
static int CheckAutoplay(void) {
    CGSize size = CGSizeMake(1600, 900);
    for (NSUInteger mission = 0; mission < CampaignMissions().count; mission++) {
        NSArray<BriefingPage *> *pages = StoryBriefingPages(CampaignMissionAt(mission));
        for (NSUInteger page = 0; page + 1 < pages.count; page++) {
            if (!pages[page].step.timed) continue;
            float seconds = pages[page].step.seconds;
            for (int touched = 0; touched < 2; touched++) {
                SizeTarget(size);
                Briefing *scene = [[Briefing alloc] initWithSize:size];
                [scene showBriefing:mission page:page];
                [(id<UIMotionScene>)scene motionEnter];
                [view presentScene:scene];
                Render(view, 0);
                [scene tick:0];
                UIMotionFinishTyping(scene.speech);
                [scene tick:1];                                  // starts the clock
                if (touched) [scene handle:InputActionUp];
                [scene tick:1 + seconds - 0.1];
                CHECK([[scene valueForKey:@"_page"] unsignedIntegerValue] == page);
                [scene tick:1 + seconds + 0.1];
                CHECK([[scene valueForKey:@"_page"] unsignedIntegerValue] == (touched ? page : page + 1));
            }
            return EXIT_SUCCESS;
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
        if (CheckSharedConversationStage(output) != EXIT_SUCCESS) return EXIT_FAILURE;
        if (CheckCaret(output) != EXIT_SUCCESS) return EXIT_FAILURE;
        if (CheckHighlight() != EXIT_SUCCESS) return EXIT_FAILURE;
        if (CheckAutoplay() != EXIT_SUCCESS) return EXIT_FAILURE;
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
            SKLabelNode *speech = scene.speech;
            UIMotionFinishTyping(speech);
            CHECK(!UIMotionIsTyping(speech));
            CHECK(![speech childNodeWithName:@"motion.caret"]);
            [scene handle:InputActionRight];
            CHECK([[scene valueForKey:@"_page"] unsignedIntegerValue] == 1);
            speech = scene.speech;
            CHECK(UIMotionIsTyping(speech));
            [scene handle:InputActionRight]; // Skip while the new bubble is opening.
            CHECK(!UIMotionIsTyping(speech));
            CHECK(![speech childNodeWithName:@"motion.caret"]);
            CHECK([[scene valueForKey:@"_page"] unsignedIntegerValue] == 1);
            [scene showDebrief:0 success:YES results:@[@"+ Patrol complete"]];
            [scene handle:InputActionConfirm];
            for (NSUInteger beat = 0; beat < 2; beat++) {
                for (int i = 0; i <= 90; i++) Render(renderer, i / 60.0);
                UIMotionFinishTyping(scene.speech);
                Save([output stringByAppendingPathComponent:[NSString stringWithFormat:@"debrief-%.0f-%lu.png", size.width, (unsigned long)beat]]);
                if (beat == 0) [scene handle:InputActionConfirm];
            }
        }
        if (CheckTimeline(output) != EXIT_SUCCESS) return EXIT_FAILURE;
        puts("PASS: dialogue caret, line returns, Unicode, skip controls and rendered briefing at desktop and phone sizes.");
    }
    return EXIT_SUCCESS;
}
