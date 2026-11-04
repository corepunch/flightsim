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

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        unsetenv("SF_BRIEFING_PAGE");
        NSUInteger count = CampaignMissions().count;
        CHECK(count > 0);

        for (NSValue *value in @[[NSValue valueWithSize:NSMakeSize(1600, 900)],
                                 [NSValue valueWithSize:NSMakeSize(640, 660)]]) {
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
                    NSMutableDictionary<NSString *, SKNode *> *previous = [NSMutableDictionary dictionary];
                    for (SKNode *node in layer.children)
                        if (![node actionForKey:@"portraitDeparture"]) previous[node.name] = node;
                    Advance(scene);
                    CHECK([[scene valueForKey:@"_page"] unsignedIntegerValue] == i);
                    SKNode *active = Portrait(scene, pages[i][@"portrait"]);
                    CHECK(active && active.position.x < scene.size.width / 2 && ![active actionForKey:@"portraitDeparture"]);
                    CHECK(Portrait(scene, @"Lancer1") == player && ![player actionForKey:@"portraitDeparture"]);
                    for (NSString *name in previous)
                        CHECK(previous[name] == Portrait(scene, name));
                }
            }

            [scene showBriefing:0];
            [(id<UIMotionScene>)scene motionEnter];
            SKNode *varn = Portrait(scene, @"Varn");
            CHECK(varn && !Portrait(scene, @"Okafor"));
            Advance(scene);
            SKNode *okafor = Portrait(scene, @"Okafor");
            CHECK(okafor && [varn actionForKey:@"portraitDeparture"]);
            [scene handle:InputActionLeft];
            CHECK(Portrait(scene, @"Varn") == varn && ![varn actionForKey:@"portraitDeparture"]);
            CHECK([okafor actionForKey:@"portraitDeparture"] && okafor.parent);

            [scene showDebrief:count - 2 success:YES results:@[]];
            CHECK(!Portrait(scene, @"Lancer1"));
            Advance(scene);
            SKNode *player = Portrait(scene, @"Lancer1");
            SKNode *listener = Portrait(scene, @"Varn");
            CHECK(player && player.position.x > scene.size.width / 2);
            CHECK(listener && ![[scene valueForKey:@"_captionRight"] boolValue]);
            Advance(scene);
            CHECK(Portrait(scene, @"Lancer1") == player && ![player actionForKey:@"portraitDeparture"]);
            CHECK(Portrait(scene, @"Varn") == listener && ![listener actionForKey:@"portraitDeparture"]);
            CHECK([[scene valueForKey:@"_captionRight"] boolValue]);
        }
        printf("PASS: portrait transitions across %lu missions at desktop and narrow sizes.\n", (unsigned long)count);
    }
    return EXIT_SUCCESS;
}
