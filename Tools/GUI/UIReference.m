#import <Cocoa/Cocoa.h>
#import "UI.h"
#import "Refresh.h"
#import "Render.h"
#import "Story.h"
#import "Shared.h"

#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL reference line %d: %s\n", __LINE__, #c); exit(1); } } while (0)

typedef struct {
    __unsafe_unretained NSString *name, *family;
    CGSize size;
    ScreenInsets safe;
    BOOL touch;
} ReferenceConfig;

static NSString *Output;
static NSMutableArray *Entries;
static SKView *View;
static NSWindow *Window;
static ReferenceConfig Config;

static SKScene *Canvas(CGSize size) {
    SKScene *scene = [SKScene sceneWithSize:size];
    scene.backgroundColor = UIColorWithOpacity(UIBackground, 1);
    return scene;
}

static void Heading(SKNode *parent, NSString *text, CGPoint at) {
    SKLabelNode *label = UIInterfaceLabel(16, UIColorWithOpacity(UIAmber, 1),
        SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeTop);
    label.text = text; label.position = at; [parent addChild:label];
}

static void FinishText(SKNode *node) {
    if ([node isKindOfClass:SKLabelNode.class]) UIMotionFinishTyping((SKLabelNode *)node);
    for (SKNode *child in node.children) FinishText(child);
}

static void Save(SKScene *scene, NSString *category, NSString *name) {
    @autoreleasepool {
        [View presentScene:nil];
        [Window setContentSize:scene.size];
        View.frame = RectWithSize(scene.size);
        [View presentScene:scene];
        FinishText(scene);
        SKTexture *texture = [View textureFromNode:scene crop:RectWithSize(scene.size)];
        REQUIRE(texture.CGImage);
        // SKView returns backing pixels (2x on Retina). Store one pixel per
        // scene point so actual-size inspection is independent of the host.
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(NULL, scene.size.width, scene.size.height, 8, 0,
            space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(space);
        REQUIRE(context);
        CGContextDrawImage(context, RectWithSize(scene.size), texture.CGImage);
        CGImageRef pixels = CGBitmapContextCreateImage(context);
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:pixels];
        CGImageRelease(pixels); CGContextRelease(context);
        NSString *file = [NSString stringWithFormat:@"%@-%@-%@.png", Config.name, category, name];
        REQUIRE([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[Output stringByAppendingPathComponent:file] atomically:YES]);
        NSIndexSet *old = [Entries indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, NSUInteger i, BOOL *stop) {
            return [entry[@"file"] isEqualToString:file];
        }];
        [Entries removeObjectsAtIndexes:old];
        [Entries addObject:@{@"device":Config.name, @"family":Config.family, @"category":category, @"name":name,
            @"file":file, @"width":@(scene.size.width), @"height":@(scene.size.height),
            @"safe":@[@(Config.safe.top), @(Config.safe.left), @(Config.safe.bottom), @(Config.safe.right)]}];
        [View presentScene:nil];
    }
}

static UIBarAction *Action(NSString *title, BOOL enabled, void (^handler)(void)) {
    UIBarAction *action = [UIBarAction title:title accent:UIAmber handler:handler];
    action.enabled = enabled; return action;
}

static void CheckButton(SKShapeNode *button, CGRect rect) {
    REQUIRE(CGRectGetHeight(rect) >= 44);
    for (SKNode *child in button.children) if ([child isKindOfClass:SKLabelNode.class]) {
        if (!CGRectContainsRect(CGRectInset(rect, -1, -1), child.frame)) fprintf(stderr, "Button %s rect %s label %s\n", ((SKLabelNode *)child).text.UTF8String, NSStringFromRect(rect).UTF8String, NSStringFromRect(child.frame).UTF8String);
        REQUIRE(CGRectContainsRect(CGRectInset(rect, -1, -1), child.frame));
        REQUIRE(fabs(CGRectGetMidY(child.frame) - CGRectGetMidY(rect)) < 1);
    }
}

static void Bars(void) {
    CGFloat width = Config.size.width;
    BOOL compact = MIN(Config.size.width, Config.size.height) <= 500;
    SKScene *sheet = Canvas(CGSizeMake(width, 1030));
    CGFloat left = MAX(24, Config.safe.left + 12), right = width - MAX(24, Config.safe.right + 12);
    __block NSUInteger fired = 0;
    for (NSUInteger state = 0; state < 4; state++) {
        CGFloat top = 1000 - state * 122;
        Heading(sheet, @[@"Header / back + title", @"Header / primary action", @"Header / previous + primary",
            @"Header / long translation + disabled action"][state], CGPointMake(left, top));
        UIBarAction *back = Action(L10n(@"story.missions"), YES, ^{ fired++; });
        UIBarAction *primary = Action(state == 3 ? @"CONTINUE TO THE NEXT MISSION" : L10n(@"debrief.continue"), state != 3, ^{ fired++; });
        UIBarAction *previous = Action(state == 3 ? @"PREVIOUS TRANSLATED PAGE" : L10n(@"story.previous"), YES, ^{ fired++; });
        NSArray *actions = state == 0 ? @[] : state >= 2 ? @[primary, previous] : @[primary];
        TitleBar *bar = [[TitleBar alloc] initWithHeader:RectFromEdges(left, top - 92, right, top - 28)
            compact:compact back:back title:state == 3 ? @"A VERY LONG TRANSLATED MISSION TITLE" : @"KESTREL FRONTIER"
            kicker:@"MISSION 01" actions:actions];
        [sheet addChild:bar];
        REQUIRE(CGRectContainsRect(CGRectInset(bar.lane, -1, -1), bar.titleLabel.frame));
        REQUIRE(CGRectContainsRect(CGRectInset(bar.lane, -1, -1), bar.kickerLabel.frame));
        for (UIBarAction *item in [@[back] arrayByAddingObjectsFromArray:actions]) {
            CGRect rect = [bar rectForAction:item];
            NSUInteger before = fired;
            REQUIRE([bar activateAt:RectCenter(rect)]);
            REQUIRE(fired == before + (item.enabled ? 1 : 0));
        }
        NSUInteger i = 0;
        for (SKShapeNode *button in bar.controls) {
            UIBarAction *item = i == 0 ? back : actions[i - 1];
            CheckButton(button, [bar rectForAction:item]); i++;
        }
    }
    NSArray *hints = @[L10n(@"debrief.conversation_hint"), L10n(@"briefing.hint"),
        @"Long translated information wraps within the shared bar, leaving the action reachable.", @"Status without an action"];
    for (NSUInteger state = 0; state < hints.count; state++) {
        CGFloat top = 510 - state * 122;
        Heading(sheet, @[@"Info rail / conversation", @"Info rail / tactical", @"Info rail / long text", @"Info rail / status only"][state], CGPointMake(left, top));
        CGRect region = RectFromEdges(left, top - 98, right, top - 98 + [UIInfoBar heightCompact:compact]);
        UIBarAction *item = state < 3 ? Action(L10n(@"debrief.continue"), YES, ^{ fired++; }) : nil;
        UIInfoBar *bar = [[UIInfoBar alloc] initWithRegion:region compact:compact console:state % 2 == 0 info:hints[state] action:item];
        [sheet addChild:bar];
        REQUIRE(CGRectContainsRect(CGRectInset(region, -1, -1), bar.infoLabel.frame));
        REQUIRE(fabs(CGRectGetMidY(bar.infoLabel.frame) - CGRectGetMidY(region)) < 1);
        REQUIRE(bar.infoLabel.fontSize >= 16);
        if (item) {
            REQUIRE(fabs(CGRectGetMidY(bar.actionRect) - CGRectGetMidY(region)) < 0.01);
            REQUIRE(!CGRectIntersectsRect(bar.infoLabel.frame, bar.actionRect));
            CheckButton(bar.action, bar.actionRect);
            NSUInteger before = fired; REQUIRE([bar activateAt:RectCenter(bar.actionRect)] && fired == before + 1);
        }
    }
    Save(sheet, @"controls", @"bars");
}

static void Buttons(void) {
    CGFloat width = Config.size.width;
    SKScene *sheet = Canvas(CGSizeMake(width, 450));
    CGFloat x = MAX(24, Config.safe.left + 12), w = MIN(270, width - x - MAX(24, Config.safe.right + 12));
    NSArray *names = @[@"Normal", @"Selected", @"Hover", @"Disabled", @"Long translation"];
    for (NSUInteger i = 0; i < names.count; i++) {
        CGFloat top = 430 - i * 84;
        Heading(sheet, names[i], CGPointMake(x, top));
        CGRect rect = CGRectMake(x, top - 66, w, 44);
        SKShapeNode *button = UIActionButton(rect, i == 4 ? @"CONTINUE TO THE NEXT MISSION" : L10n(@"debrief.continue"), i == 1 ? UIAmber : UIInk);
        if (i == 3) button.alpha = .35;
        [sheet addChild:button];
        if (i == 2) {
            UIHover *hover = [UIHover new];
            [hover addButton:button rect:rect accent:UIInk];
            [hover queuePointAtFraction:PointFractionInRect(RectCenter(rect), RectWithSize(sheet.size))];
            [hover updateInScene:sheet];
            // Finish the actual hover transition rather than recreating its art.
            [View presentScene:sheet];
            NSDate *until = [NSDate dateWithTimeIntervalSinceNow:.2];
            while (until.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:until];
        }
        CheckButton(button, rect);
    }
    Save(sheet, @"controls", @"button-states");
}

static void Forms(void) {
    CGFloat width = MIN(760, Config.size.width - MAX(24, Config.safe.left + 12) - MAX(24, Config.safe.right + 12));
    for (NSUInteger state = 0; state < 3; state++) {
        NSArray *items = @[
            [UISettingItem choice:L10n(@"controls.mode") value:L10n(state ? @"controls.expert" : @"controls.casual")
                detail:L10n(state ? @"controls.expert_detail" : @"controls.casual_detail") action:^{}],
            [UISettingItem slider:L10n(@"controls.horizontal") value:state / 2.0 minimum:0 maximum:1 step:.25
                text:^NSString *(float v) { return [NSString stringWithFormat:@"%.0f%%", v * 100]; } change:^(float v) {}],
            [UISettingItem choice:L10n(@"controls.invert") value:L10n(state ? @"controls.on" : @"controls.off") detail:nil action:^{}],
            [UISettingItem action:@"A longer translated setting title that wraps within its own row" value:L10n(@"controls.restore") action:^{}]];
        UISettingsForm *form = [[UISettingsForm alloc] initWithItems:items width:width];
        form.selectedIndex = state;
        SKScene *sheet = Canvas(CGSizeMake(width + 48, form.height + 72));
        form.position = CGPointMake(24, form.height + 24); [sheet addChild:form];
        Heading(sheet, @[@"Settings / casual + minimum", @"Settings / expert + midpoint", @"Settings / expert + maximum"][state], CGPointMake(24, sheet.size.height - 16));
        for (NSUInteger i = 0; i < form.rowRects.count; i++) {
            CGRect row = UnboxRect(form.rowRects[i]), control = UnboxRect(form.controlRects[i]), title = UnboxRect(form.titleRects[i]);
            REQUIRE(CGRectContainsRect(CGRectInset(row, 15, 15), control));
            REQUIRE(CGRectContainsRect(CGRectInset(row, 15, 15), title));
            REQUIRE(!CGRectIntersectsRect(control, title));
        }
        Save(sheet, @"controls", [NSString stringWithFormat:@"settings-%lu", (unsigned long)state]);
    }
}

static void Menus(void) {
    for (NSUInteger state = 0; state < 3; state++) {
        MainMenu *menu = [[MainMenu alloc] initWithSize:Config.size];
        menu.touchNavigationEnabled = Config.touch; menu.contentInsets = Config.safe;
        [menu showMission:0 title:CampaignMissionAt(0).title started:state > 0 completed:state == 2];
        Save(menu, @"screens", @[@"menu-new", @"menu-continue", @"menu-replay"][state]);
        if (state == 0) {
            for (NSUInteger i = 1; i < (Config.touch ? 5 : 6); i++) {
                [menu handle:InputActionDown];
                Save(menu, @"screens", [NSString stringWithFormat:@"menu-selected-%lu", (unsigned long)i]);
            }
        }
    }
    for (NSUInteger online = 0; online < 2; online++) for (NSUInteger cockpit = 0; cockpit < 2; cockpit++) {
        PauseMenu *menu = [[PauseMenu alloc] initWithSize:Config.size]; menu.contentInsets = Config.safe;
        [menu showRemote:online cockpit:cockpit];
        for (NSUInteger selected = 0; selected < 6; selected++) {
            for (SKNode *button in menu.layout.buttons.allValues) {
                CGRect rect = [menu.layout frame:button.name];
                REQUIRE(CGRectGetHeight(rect) >= 44);
                CGRect safe = RectInsetEdges(RectWithSize(Config.size), Config.safe.left, Config.safe.top, Config.safe.right, Config.safe.bottom);
                REQUIRE(CGRectContainsRect(CGRectInset(safe, -1, -1), rect));
                for (SKNode *child in button.children) if ([child isKindOfClass:SKLabelNode.class]) {
                    SKLabelNode *label = (SKLabelNode *)child;
                    REQUIRE(![(label.attributedText.string ?: label.text) hasSuffix:@"…"]);
                    REQUIRE(CGRectContainsRect(CGRectInset(rect, 3, 3), label.frame));
                    REQUIRE(fabs(CGRectGetMidY(rect) - CGRectGetMidY(label.frame)) < .5);
                }
            }
            Save(menu, @"screens", [NSString stringWithFormat:@"pause-%@-%@-%lu", online ? @"online" : @"local", cockpit ? @"cockpit" : @"chase", (unsigned long)selected]);
            [menu handle:InputActionDown];
        }
    }
    SKScene *sheet = Canvas(Config.size);
    ControlsPanel *panel = [ControlsPanel new]; panel.touchNavigationEnabled = Config.touch;
    CGRect bounds = RectInsetEdges(RectWithSize(Config.size), Config.safe.left + 18, Config.safe.top + 18, Config.safe.right + 18, Config.safe.bottom + 18);
    [panel layoutIn:bounds sceneSize:Config.size]; [sheet addChild:panel];
    Save(sheet, @"screens", @"flight-settings-top");
    [panel pointerScroll:10000 at:PointFractionInRect(RectCenter(panel.scrollRect), RectWithSize(Config.size))];
    Save(sheet, @"screens", @"flight-settings-bindings");
}

static void Campaign(void) {
    Briefing *scene = [[Briefing alloc] initWithSize:Config.size]; scene.touchNavigationEnabled = Config.touch; scene.contentInsets = Config.safe;
    [scene showListSelecting:0]; Save(scene, @"screens", @"missions-current");
    [scene showListSelecting:CampaignMissions().count - 1]; Save(scene, @"screens", @"missions-locked");
    [scene showBriefing:0]; Save(scene, @"screens", @"conversation");
    BOOL mapSaved = NO;
    for (NSUInteger mission = 0; mission < CampaignMissions().count && !mapSaved; mission++) {
        NSArray<BriefingPage *> *pages = StoryBriefingPages(CampaignMissionAt(mission));
        for (NSUInteger page = 0; page < pages.count; page++) if (pages[page].step) {
            [scene showBriefing:mission page:page]; Save(scene, @"screens", @"tactical-map"); mapSaved = YES; break;
        }
    }
    NSArray *results = @[@"+ Patrol route complete", @"x Keep the convoy intact", @"- Optional: scan the relay"];
    [scene showDebrief:0 success:YES results:results]; Save(scene, @"screens", @"report-success");
    [scene handle:InputActionConfirm]; Save(scene, @"screens", @"debrief-conversation");
    [scene showDebrief:0 success:NO results:results]; Save(scene, @"screens", @"report-failure");
    NSMutableArray *longResults = [NSMutableArray array];
    for (NSUInteger i = 0; i < 20; i++) [longResults addObject:@"+ A longer mission objective result requiring scrolling"];
    [scene showDebrief:0 success:YES results:longResults]; Save(scene, @"screens", @"report-overflow");
}

static void MissionRatings(void) {
    // This runner has its own bundle identifier and isolated preference domain.
    ProgressRecordResult(0, @[@"+ Complete"]); ProgressMarkCompleted(0);
    ProgressRecordResult(1, @[@"+ Complete", @"+ Complete", @"+ Complete", @"- Optional"]); ProgressMarkCompleted(1);
    ProgressRecordResult(2, @[@"+ Complete", @"x Failed"]); ProgressMarkCompleted(2);
    Briefing *scene = [[Briefing alloc] initWithSize:Config.size];
    scene.touchNavigationEnabled = Config.touch; scene.contentInsets = Config.safe;
    [scene showListSelecting:0]; Save(scene, @"screens", @"missions-ratings-1-2-3-stars");
}

static void Network(void) {
    LANGame *game = [[LANGame alloc] initWithSize:Config.size]; game.contentInsets = Config.safe;
    [game showSetup]; Save(game, @"screens", @"lan-setup");
    [game showPilots:@[@"Host"]]; Save(game, @"screens", @"lan-waiting");
    [game showPilots:@[@"Host", @"Wingmate"]]; Save(game, @"screens", @"lan-ready");
    NSArray *pilots = @[@"Host", @"Wingmate", @"Pilot 3", @"Pilot 4", @"Pilot 5", @"Pilot 6", @"Pilot 7", @"Pilot 8"];
    [game showPilots:pilots]; Save(game, @"screens", @"lan-full");
    [game showResults:pilots hosting:YES]; Save(game, @"screens", @"lan-results-host");
    [game showResults:pilots hosting:NO]; Save(game, @"screens", @"lan-results-guest");
    ServerBrowser *browser = [[ServerBrowser alloc] initWithSize:Config.size]; browser.contentInsets = Config.safe;
    [browser showServers:@[]]; Save(browser, @"screens", @"browser-empty");
    NSMutableArray *servers = [NSMutableArray array];
    for (NSUInteger i = 0; i < 8; i++) {
        LANServer *server = [LANServer new]; server.name = i ? @"A longer Wi-Fi game name" : @"Wingmates";
        server.players = (int)i + 1; server.maxPlayers = 8;
        server.address = [NetAddress addressWithString:@"127.0.0.1" port:27910 + (int)i]; [servers addObject:server];
    }
    [browser showServers:servers]; [browser handle:InputActionDown]; Save(browser, @"screens", @"browser-selected");
    for (NSString *key in @[@"browser.permission", @"browser.socket_failed", @"browser.search_failed", @"browser.resolve_failed", @"browser.unreachable", @"browser.network_help"]) {
        [browser setStatus:L10nFormat(key, @(-72007))]; Save(browser, @"screens", key);
    }
}

static void Flight(void) {
    for (NSUInteger state = 0; state < 7; state++) {
        HUD *hud = [[HUD alloc] initWithSize:Config.size]; hud.backgroundColor = UIColorWithOpacity(UIBackground, 1);
        hud.touchLayout = Config.touch; hud.contentInsets = Config.safe;
        [hud setObjectives:@[@"Patrol NAV 1, 2, 3 in order", @"Convoy protected", @"Relay lost", @"Optional: scan the freighter"] states:@[@0, @1, @2, @3]];
        [hud setInputText:Config.touch ? @"" : @"MOUSE FLIGHT  /  T TARGET  /  ESC PAUSE"];
        HUDFrame frame = {.speed=125, .throttle=.8, .boostEnergy=.6, .secondary=2, .secondaryCapacity=4,
            .secondaryName=@"TORPEDO", .kills=state == 2 ? 3 : 0, .deaths=state == 2 ? 1 : 0,
            .playerDead=state == 3, .respawning=state == 2 || state == 3, .cockpit=state == 1,
            .boresight={Config.size.width / 2, Config.size.height / 2}, .boresightVisible=YES,
            .boosting=state == 6, .status=@"SCANNING 40%"};
        HUDTarget targets[] = {
            {.point={Config.size.width * .55, Config.size.height * .65}, .onScreen=YES, .distance=1210, .size=40, .health=.72, .kind=HUDKindEnemy, .selected=YES, .label=@"CORSAIR CUTTER"},
            {.point={Config.size.width * .75, Config.size.height * .75}, .onScreen=YES, .distance=2000, .size=30, .kind=HUDKindFriend, .label=@"CONVOY"},
            {.point={Config.size.width * .45, Config.size.height * .3}, .onScreen=YES, .distance=3000, .size=25, .kind=HUDKindNav, .label=@"NAV 1"}};
        CockpitContact contacts[] = {{.local={100,50,-1210}, .relation=RelationHostile, .hull=.72, .shield=.4, .systems=.75,
            .name=@"Corsair Cutter Rask", .className=@"Corsair cutter", .cargo=@"Skarn munitions", .component=@"SHIELD GENERATOR"}};
        CockpitFrame instruments = {.alive=YES, .target=0, .hull=.9, .shield=.6, .weaponEnergy=.85, .weaponShotEnergy=.035,
            .weaponRecharge=.22, .shieldRecharge=.06, .secondary=2, .secondaryName=@"TORPEDO", .closingSpeed=42};
        if (state == 5) { instruments.target = -1; instruments.shieldRecharge = 0; }
        if (state == 6) { instruments.hull = .2; instruments.shield = .05; instruments.weaponEnergy = .1; frame.secondary = 0; }
        [hud updateFrame:frame targets:targets count:state == 5 ? 0 : 3];
        [hud updateInstruments:instruments contacts:contacts count:state == 5 ? 0 : 1 cockpit:state == 1];
        [hud showMessage:@"Convoy approaching the relay." from:@"OKAFOR"];
        REQUIRE(!CGRectIntersectsRect(hud.objectivesRect, hud.messagesRect));
        if (state == 4) [hud setHelpVisible:YES];
        if (Config.touch) {
            UITouchControls *touch = [UITouchControls new]; [touch layoutWithSize:Config.size insets:Config.safe];
            [touch displayThrottle:.8]; [touch setSecondaryLabel:@"TORP"];
            touch.controllerConnected = state == 1;
            if (state == 2) {
                [touch displayStick:CGPointMake(40, 20) stretched:YES];
                for (TouchControl control = TouchControlFire; control < TouchControlCount; control++) [touch setPressed:YES control:control];
            }
            for (TouchControl control = 0; control < TouchControlCount; control++) {
                CGRect rect = [touch rectForControl:control];
                REQUIRE(CGRectContainsRect(CGRectInset(RectWithSize(Config.size), -1, -1), rect));
                if (!touch.controllerConnected || control == TouchControlPause)
                    REQUIRE([touch controlAt:[touch centerForControl:control]] == control);
            }
            [hud addChild:touch];
        }
        Save(hud, @"flight", @[@"hud-target", @"cockpit-controller", @"hud-pressed-score", @"hud-respawn", @"hud-help", @"hud-no-target-unshielded", @"hud-critical-boost-empty-rack"][state]);
    }
    for (NSUInteger state = 0; state < 3; state++) {
        Loading *loading = [[Loading alloc] initWithSize:Config.size];
        [loading showTitle:CampaignMissionAt(0).title kicker:@"MISSION 01" detail:@"Kepler approach / Lancer flight"];
        [loading setProgress:state / 2.0 status:@"Preparing flight systems"];
        for (NSUInteger i = 0; i < 200; i++) [loading tick:i / 60.0];
        loading.readyToStart = state == 2;
        Save(loading, @"screens", @[@"loading-empty", @"loading-half", @"loading-ready"][state]);
    }
}

static void Instruments(void) {
    Cockpit *cockpit = [[Cockpit alloc] initWithDevice:MTLCreateSystemDefaultDevice()];
    CockpitContact contact = {.local={100,50,-1200}, .relation=RelationHostile, .hull=.6, .shield=.4, .systems=.8,
        .name=@"Corsair Cutter", .className=@"Cutter", .cargo=@"Munitions", .component=@"SHIELD GENERATOR"};
    for (NSUInteger state = 0; state < 3; state++) {
        CockpitFrame frame = {.alive=state != 2, .target=state == 2 ? -1 : 0, .throttle=.8, .speed=120,
            .boostEnergy=.7, .hull=state ? .2 : .9, .shield=state ? 0 : .8,
            .weaponEnergy=.5, .weaponRecharge=.22, .shieldRecharge=.06, .boosting=state == 1,
            .six=state == 1, .lock=YES, .nearest=state ? 80 : 500, .kills=3, .deaths=1, .time=120.25,
            .secondary=2, .secondaryName=@"TORPEDO", .objective=@"PATROL NAV 1, 2, 3"};
        [cockpit updateFrame:frame contacts:&contact count:state == 2 ? 0 : 1];
        for (NSString *key in [cockpit.displayScenes.allKeys sortedArrayUsingSelector:@selector(compare:)])
            Save(cockpit.displayScenes[key], @"instruments", [NSString stringWithFormat:@"%@-%@", key, @[@"normal", @"warning", @"destroyed"][state]]);
    }
}

int main(int argc, const char **argv) { @autoreleasepool {
    REQUIRE(argc == 2 || (argc == 3 && [@(argv[2]) isEqualToString:@"--ratings-only"]));
    Output = @(argv[1]);
    BOOL ratingsOnly = argc == 3;
    if (ratingsOnly) {
        NSData *data = [NSData dataWithContentsOfFile:[Output stringByAppendingPathComponent:@"manifest.json"]];
        REQUIRE(data);
        id previous = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
        REQUIRE([previous isKindOfClass:NSMutableArray.class]); Entries = previous;
    } else Entries = [NSMutableArray array];
    [NSApplication sharedApplication]; [NSApp finishLaunching];
    [Cvar set:@"ui_reduceMotion" value:@"1"];
    Window = [[NSWindow alloc] initWithContentRect:CGRectMake(0,0,800,600) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    View = [[SKView alloc] initWithFrame:CGRectMake(0,0,800,600)]; Window.contentView = View; [Window orderFrontRegardless];
    const ReferenceConfig configs[] = {
        {@"iphone-small", @"iPhone", {568,320}, {0,0,0,0}, YES},
        {@"iphone-se", @"iPhone", {667,375}, {0,0,0,0}, YES},
        {@"iphone-notch", @"iPhone", {852,393}, {0,59,21,59}, YES},
        {@"iphone-large", @"iPhone", {932,430}, {0,59,21,59}, YES},
        {@"ipad", @"iPad", {1194,834}, {24,0,20,0}, YES},
        {@"ipad-window", @"iPad", {600,834}, {24,0,20,0}, YES},
        {@"ipad-portrait", @"iPad", {834,1194}, {24,0,20,0}, YES},
        {@"desktop-small", @"Desktop", {1280,720}, {0,0,0,0}, NO},
        {@"desktop", @"Desktop", {1600,900}, {0,0,0,0}, NO},
        {@"desktop-wide", @"Desktop", {2288,818}, {0,0,0,0}, NO},
        {@"desktop-narrow", @"Desktop", {640,660}, {0,0,0,0}, NO}
    };
    for (NSUInteger i = 0; i < sizeof(configs) / sizeof(configs[0]); i++) @autoreleasepool {
        Config = configs[i]; fprintf(stderr, "Rendering %s\n", Config.name.UTF8String);
        REQUIRE([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.igor.spacefight.uireference"]);
        [NSUserDefaults.standardUserDefaults removePersistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
        if (!ratingsOnly) { Bars(); Buttons(); Forms(); Menus(); Campaign(); Network(); Flight(); Instruments(); }
        MissionRatings();
    }
    NSData *manifest = [NSJSONSerialization dataWithJSONObject:Entries options:NSJSONWritingPrettyPrinted error:NULL];
    REQUIRE([manifest writeToFile:[Output stringByAppendingPathComponent:@"manifest.json"] atomically:YES]);
    printf("PASS: UI reference rendered %lu fixtures across %lu configurations.\n", (unsigned long)Entries.count, sizeof(configs) / sizeof(configs[0]));
    [Window orderOut:nil];
    return 0;
}}
