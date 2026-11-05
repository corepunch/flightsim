#import <AppKit/AppKit.h>
#import "Assets.h"
#import "Briefing.h"
#import "UIMotion.h"

// Report failures without aborting, so a failed check doesn't make a crash report.
#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "Portrait check failed at line %d: %s\n", __LINE__, #condition); \
        return EXIT_FAILURE; \
    } \
} while (0)

static SKNode *Portrait(Briefing *scene, NSString *name) {
    SKNode *layer = [scene valueForKey:@"_portraitLayer"];
    return [layer childNodeWithName:name];
}

static BOOL PortraitsAlign(SKNode *left, SKNode *right) {
    return left && right && fabs(CGRectGetMinY(left.frame) - CGRectGetMinY(right.frame)) < 0.5 &&
           fabs(CGRectGetMaxY(left.frame) - CGRectGetMaxY(right.frame)) < 0.5;
}

static void Advance(Briefing *scene) {
    UIMotionFinishTyping([scene valueForKey:@"_speech"]);
    [scene handle:InputActionConfirm];
}

static BriefingCommand ClickScene(Briefing *scene) {
    [scene pointerClick:CGPointMake(0.5, 0.5)];
    return [scene handle:0];
}

static CGFloat ScrollOffset(Briefing *scene) {
    return [[scene valueForKey:@"_scrollOffset"] doubleValue];
}

static int CheckScrolling(void) {
    Briefing *scene = [[Briefing alloc] initWithSize:CGSizeMake(932, 429)];
    [scene showListSelecting:0];
    scene.size = CGSizeMake(932, 430);
    [scene tick:0]; // Settle the layout without its entrance animations.
    CGRect viewport = [[scene valueForKey:@"_scrollRect"] rectValue];
    CHECK(!CGRectIsEmpty(viewport));
    CGPoint inside = CGPointMake(CGRectGetMidX(viewport) / scene.size.width,
                                 CGRectGetMidY(viewport) / scene.size.height);
    [scene pointerScroll:20 at:CGPointMake(0.005, inside.y)];
    [scene handle:0];
    CHECK(ScrollOffset(scene) == 0);
    [scene pointerScroll:10000 at:inside];
    [scene handle:0];
    CHECK(ScrollOffset(scene) > 0);
    SKNode *content = [scene valueForKey:@"_scrollContent"];
    CHECK([content.parent isKindOfClass:SKCropNode.class]);
    CHECK([content childNodeWithName:@"mission-20"]);
    NSArray<NSValue *> *tiles = [scene valueForKey:@"_missionTiles"];
    CHECK(tiles.count == CampaignMissions().count);
    for (NSValue *value in tiles) CHECK(value.rectValue.size.width >= 140 && value.rectValue.size.height >= 140);
    [scene pointerScroll:-10000 at:inside];
    [scene handle:0];
    CHECK(ScrollOffset(scene) == 0);
    [scene handle:InputActionRight];
    CHECK(scene.selectedIndex == 1);
    NSUInteger columns = [[scene valueForKey:@"_missionColumns"] unsignedIntegerValue];
    [scene handle:InputActionDown];
    CHECK(scene.selectedIndex == 1 + columns);
    scene.size = CGSizeMake(1600, 1100);
    [scene showListSelecting:0];
    CHECK(![scene valueForKey:@"_scrollThumb"]);

    // Briefing readouts and post-flight results can also exceed a short viewport.
    scene.size = CGSizeMake(852, 393);
    [scene showBriefing:0];
    NSMutableArray *pages = [[scene valueForKey:@"_pages"] mutableCopy];
    NSMutableDictionary *intel = [pages.lastObject mutableCopy];
    NSMutableArray *lines = [NSMutableArray array];
    for (int i = 0; i < 18; i++) [lines addObject:@"Incoming patrol report"];
    intel[@"readout"] = lines;
    pages[pages.count - 1] = intel;
    [scene setValue:pages forKey:@"_pages"];
    for (NSUInteger i = 0; i + 1 < pages.count; i++) Advance(scene);
    CHECK(!CGRectIsEmpty([[scene valueForKey:@"_scrollRect"] rectValue]));
    [scene handle:InputActionDown];
    CHECK(ScrollOffset(scene) > 0);
    [scene handle:InputActionLeft];
    CHECK(ScrollOffset(scene) == 0);

    NSMutableArray *results = [NSMutableArray array];
    for (int i = 0; i < 18; i++) [results addObject:@"+ Objective completed"];
    [scene showDebrief:0 success:NO results:results];
    CHECK(!CGRectIsEmpty([[scene valueForKey:@"_scrollRect"] rectValue]));
    [scene handle:InputActionDown];
    CHECK(ScrollOffset(scene) > 0);
    return EXIT_SUCCESS;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSUInteger count = CampaignMissions().count;
        CHECK(count > 0);
        if (CheckScrolling() != EXIT_SUCCESS) return EXIT_FAILURE;

        for (NSValue *value in @[[NSValue valueWithSize:NSMakeSize(1600, 900)],
                                 [NSValue valueWithSize:NSMakeSize(640, 660)],
                                 [NSValue valueWithSize:NSMakeSize(852, 393)]]) {
            Briefing *scene = [[Briefing alloc] initWithSize:value.sizeValue];
            for (NSUInteger mission = 0; mission < count; mission++) {
                [scene showBriefing:mission];
                [(id<UIMotionScene>)scene motionEnter];
                NSArray *pages = [scene valueForKey:@"_pages"];
                CHECK(pages.count > 0);
                SKNode *player = Portrait(scene, @"Lancer1");
                CHECK(player && player.position.x > scene.size.width / 2);
                NSString *firstPortrait = pages.firstObject[@"portrait"];
                if ([firstPortrait isEqualToString:@"Lancer1"]) firstPortrait = pages.firstObject[@"listener"];
                CHECK(PortraitsAlign(Portrait(scene, firstPortrait), player));
                for (NSUInteger i = 1; i < pages.count; i++) {
                    SKNode *layer = [scene valueForKey:@"_portraitLayer"];
                    SKNode *portraitParent = layer.parent;
                    CGFloat playerAlpha = player.alpha;
                    NSMutableDictionary<NSString *, SKNode *> *previous = [NSMutableDictionary dictionary];
                    for (SKNode *node in layer.children)
                        if (![node actionForKey:@"portraitDeparture"]) previous[node.name] = node;
                    Advance(scene);
                    CHECK([[scene valueForKey:@"_page"] unsignedIntegerValue] == i);
                    BOOL playerSpeaking = [pages[i][@"portrait"] isEqualToString:@"Lancer1"];
                    NSString *other = playerSpeaking ? pages[i][@"listener"] : pages[i][@"portrait"];
                    SKNode *listener = Portrait(scene, other);
                    CHECK(listener && listener.position.x < scene.size.width / 2 && ![listener actionForKey:@"portraitDeparture"]);
                    CHECK(PortraitsAlign(listener, player));
                    CHECK([[scene valueForKey:@"_captionRight"] boolValue] == playerSpeaking);
                    CHECK(Portrait(scene, @"Lancer1") == player && ![player actionForKey:@"portraitDeparture"]);
                    CHECK(player.alpha == playerAlpha && layer.parent == portraitParent);
                    for (NSString *name in previous)
                        CHECK(previous[name] == Portrait(scene, name));
                }
                UIMotionFinishTyping([scene valueForKey:@"_speech"]);
                CHECK(ClickScene(scene) == BriefingCommandNone);
                CHECK([[scene valueForKey:@"_page"] unsignedIntegerValue] == pages.count - 1);
                CHECK([scene handle:InputActionConfirm] == BriefingCommandLaunch);
            }

            [scene showBriefing:0];
            [(id<UIMotionScene>)scene motionEnter];
            SKNode *varn = Portrait(scene, @"Varn");
            CHECK(varn && !Portrait(scene, @"Okafor"));
            UIMotionFinishTyping([scene valueForKey:@"_speech"]);
            CHECK(ClickScene(scene) == BriefingCommandNone);
            CHECK([[scene valueForKey:@"_page"] unsignedIntegerValue] == 1);
            SKNode *okafor = Portrait(scene, @"Okafor");
            CHECK(okafor && [varn actionForKey:@"portraitDeparture"]);
            CGRect previousButton = [[scene valueForKey:@"_previousRect"] rectValue];
            if (CGRectIsEmpty(previousButton)) [scene handle:InputActionLeft];
            else {
                [scene pointerClick:CGPointMake(CGRectGetMidX(previousButton) / scene.size.width,
                                                       CGRectGetMidY(previousButton) / scene.size.height)];
                CHECK([scene handle:0] == BriefingCommandNone);
            }
            CHECK(Portrait(scene, @"Varn") == varn && ![varn actionForKey:@"portraitDeparture"]);
            CHECK([okafor actionForKey:@"portraitDeparture"] && okafor.parent);

            SKSpriteNode *lead = (SKSpriteNode *)Portrait(scene, @"Lancer1");
            SKTexture *base = lead.texture;
            for (NSUInteger i = 0; i < 5; i++) Advance(scene);
            NSDictionary *art = [scene valueForKey:@"_art"];
            CHECK(lead == Portrait(scene, @"Lancer1") && lead.texture != base);
            CHECK(lead.texture == art[@"Expressions/Lancer1-amused"]);
            [scene handle:InputActionLeft];
            CHECK(lead == Portrait(scene, @"Lancer1") && lead.texture == base);

            [scene showDebrief:count - 2 success:YES results:@[]];
            CHECK(!Portrait(scene, @"Lancer1"));
            CHECK(ClickScene(scene) == BriefingCommandNone);
            SKSpriteNode *player = (SKSpriteNode *)Portrait(scene, @"Lancer1");
            SKSpriteNode *listener = (SKSpriteNode *)Portrait(scene, @"Varn");
            CHECK(player && player.position.x > scene.size.width / 2);
            CHECK(listener && ![[scene valueForKey:@"_captionRight"] boolValue]);
            CHECK(PortraitsAlign(listener, player));
            CHECK(player.texture && player.texture == art[@"Expressions/Lancer1-grieving"]);
            CHECK(listener.texture && listener.texture == art[@"Expressions/Varn-sympathetic"]);
            Advance(scene);
            CHECK(Portrait(scene, @"Lancer1") == player && ![player actionForKey:@"portraitDeparture"]);
            CHECK(Portrait(scene, @"Varn") == listener && ![listener actionForKey:@"portraitDeparture"]);
            CHECK([[scene valueForKey:@"_captionRight"] boolValue]);
        }
        printf("PASS: portrait transitions across %lu missions at desktop, narrow and iPhone sizes.\n", (unsigned long)count);
    }
    return EXIT_SUCCESS;
}
