// Included by PortraitChecks.m so the existing GUI runner and CI exercise it.
static BOOL SafeButton(Briefing *scene, NSString *key, CGRect safe) {
    CGRect rect = [[scene valueForKey:key] rectValue];
    return CGRectIsEmpty(rect) || (CGRectContainsRect(safe, rect) && rect.size.height >= 44);
}

static int CheckCampaignSafeAreas(void) {
    // Points, not Retina pixels: SE, notched phones in both orientations,
    // and iPad with a home indicator. UIKit itself remains a simulator check.
    const CGSize sizes[] = {{667, 375}, {812, 375}, {852, 393}, {1024, 768}};
    const NSEdgeInsets insets[] = {{0, 0, 0, 0}, {0, 44, 21, 44},
                                  {0, 59, 21, 59}, {24, 0, 20, 0}};
    for (NSUInteger v = 0; v < sizeof(sizes) / sizeof(sizes[0]); v++) {
        Briefing *scene = [[Briefing alloc] initWithSize:sizes[v]];
        scene.touchNavigationEnabled = YES;
        scene.contentInsets = insets[v];
        CGRect safe = CGRectMake(insets[v].left, insets[v].bottom,
                                 sizes[v].width - insets[v].left - insets[v].right,
                                 sizes[v].height - insets[v].top - insets[v].bottom);
        for (NSUInteger mission = 0; mission < CampaignMissions().count; mission++) {
            [scene showListSelecting:mission];
            CHECK(SafeButton(scene, @"_backRect", safe));
            CHECK(SafeButton(scene, @"_confirmRect", safe));
            [scene showBriefing:mission];
            NSArray *pages = [scene valueForKey:@"_pages"];
            for (NSUInteger page = 0; page < pages.count; page++) {
                CHECK(!CGRectIsEmpty([[scene valueForKey:@"_backRect"] rectValue]));
                CHECK(SafeButton(scene, @"_backRect", safe));
                if (page > 0) CHECK(!CGRectIsEmpty([[scene valueForKey:@"_previousRect"] rectValue]));
                CHECK(SafeButton(scene, @"_previousRect", safe));
                CHECK(SafeButton(scene, @"_confirmRect", safe));
                CHECK(CGRectContainsRect(safe, [[scene valueForKey:@"_captionRect"] rectValue]));
                if (page + 1 < pages.count) Advance(scene);
            }
            UIMotionFinishTyping([scene valueForKey:@"_speech"]);
            CGRect launch = [[scene valueForKey:@"_confirmRect"] rectValue];
            [scene pointerClick:CGPointMake(CGRectGetMidX(launch) / scene.size.width,
                                           CGRectGetMidY(launch) / scene.size.height)];
            CHECK([scene handle:0] == BriefingCommandLaunch);
            for (NSUInteger success = 0; success < 2; success++) {
                [scene showDebrief:mission success:success results:@[@"+ Objective completed"]];
                CHECK(SafeButton(scene, @"_confirmRect", safe));
                if (!success) {
                    CHECK([scene handle:InputActionConfirm] == BriefingCommandLaunch);
                    continue;
                }
                NSArray *lines = CampaignMission(mission)[@"debrief"][@"dialogue"];
                for (NSUInteger beat = 0; beat < lines.count; beat++) {
                    Advance(scene);
                    CHECK(SafeButton(scene, @"_confirmRect", safe));
                    CHECK(CGRectContainsRect(safe, [[scene valueForKey:@"_captionRect"] rectValue]));
                }
                UIMotionFinishTyping([scene valueForKey:@"_speech"]);
                CHECK([scene handle:InputActionConfirm] == BriefingCommandNone);
                CHECK(scene.selectedIndex == MIN(mission + 1, CampaignMissions().count - 1));
            }
        }
    }
    return EXIT_SUCCESS;
}
