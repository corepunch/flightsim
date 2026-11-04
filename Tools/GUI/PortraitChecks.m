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

static void Advance(Briefing *scene) {
    UIMotionFinishTyping([scene valueForKey:@"_speech"]);
    [scene handle:InputActionConfirm];
}

static BriefingCommand ClickScene(Briefing *scene) {
    [scene queueClickAtFraction:CGPointMake(0.5, 0.5)];
    return [scene handle:0];
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        unsetenv("SF_BRIEFING_PAGE");
        NSUInteger count = CampaignMissions().count;
        CHECK(count > 0);

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
                [scene queueClickAtFraction:CGPointMake(CGRectGetMidX(previousButton) / scene.size.width,
                                                       CGRectGetMidY(previousButton) / scene.size.height)];
                CHECK([scene handle:0] == BriefingCommandNone);
            }
            CHECK(Portrait(scene, @"Varn") == varn && ![varn actionForKey:@"portraitDeparture"]);
            CHECK([okafor actionForKey:@"portraitDeparture"] && okafor.parent);

            [scene showDebrief:count - 2 success:YES results:@[]];
            CHECK(!Portrait(scene, @"Lancer1"));
            CHECK(ClickScene(scene) == BriefingCommandNone);
            SKNode *player = Portrait(scene, @"Lancer1");
            SKNode *listener = Portrait(scene, @"Varn");
            CHECK(player && player.position.x > scene.size.width / 2);
            CHECK(listener && ![[scene valueForKey:@"_captionRight"] boolValue]);
            Advance(scene);
            CHECK(Portrait(scene, @"Lancer1") == player && ![player actionForKey:@"portraitDeparture"]);
            CHECK(Portrait(scene, @"Varn") == listener && ![listener actionForKey:@"portraitDeparture"]);
            CHECK([[scene valueForKey:@"_captionRight"] boolValue]);
        }
        printf("PASS: portrait transitions across %lu missions at desktop, narrow and iPhone sizes.\n", (unsigned long)count);
    }
    return EXIT_SUCCESS;
}
