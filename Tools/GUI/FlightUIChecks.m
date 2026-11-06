#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import "Refresh.h"
#import "Story.h"
#import "Render.h"
#import "UI.h"
#import "Net.h"
#import "Server.h"
#import "Client.h"
#import "Common.h"
#import "Shared.h"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); return 1; } } while (0)
static NSString *Output;
static void Save(SKScene *scene, NSString *name) {
    SKView *view = [[SKView alloc] initWithFrame:(CGRect){.size=scene.size}];
    [view presentScene:scene];
    SKTexture *texture = [view textureFromNode:scene crop:(CGRect){.size=scene.size}];
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:texture.CGImage];
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[Output stringByAppendingPathComponent:name] atomically:YES];
}
static CGRect FrameInScene(SKNode *node, SKScene *scene) {
    CGRect rect = node.frame;
    CGPoint lo = [scene convertPoint:rect.origin fromNode:node.parent];
    CGPoint hi = [scene convertPoint:CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect)) fromNode:node.parent];
    return CGRectMake(lo.x, lo.y, hi.x-lo.x, hi.y-lo.y);
}
static int CheckSensors(void) {
    CockpitFrame frame = {.alive=YES, .target=0};
    CockpitContact contacts[3] = {
        {.local={0,0,-1000}, .relation=RelationHostile},
        {.local={1000,0,-1000}, .relation=RelationFriendly},
        {.local={0,0,1000}, .relation=RelationNeutral}
    };
    SensorScope *front = [[SensorScope alloc] initRear:NO], *rear = [[SensorScope alloc] initRear:YES];
    [front updateFrame:frame contacts:contacts count:3]; [rear updateFrame:frame contacts:contacts count:3];
    NSArray<SKNode *> *f = [front valueForKey:@"blips"], *r = [rear valueForKey:@"blips"];
    CHECK(!f[0].hidden && !f[1].hidden && f[2].hidden);
    CHECK(r[0].hidden && r[1].hidden && !r[2].hidden);
    CHECK(fabs(f[0].position.x) < .1 && fabs(f[0].position.y) < .1);
    CHECK(f[1].position.x > 0 && f[1].position.x < 60);
    frame.target = 2;
    [rear updateFrame:frame contacts:contacts count:3];
    CHECK(![[rear valueForKey:@"selected"] isHidden]);
    [rear updateFrame:frame contacts:NULL count:0];
    CHECK([[rear valueForKey:@"selected"] isHidden]);
    return 0;
}
static int CheckHUD(void) {
    // What -[SceneKitRefresh previewForModel:] hands out for a fighter.
    SCNNode *preview = [SCNNode node];
    SCNNode *mesh = [SCNNode nodeWithGeometry:[ShipView geometryForDefinition:ShipDefNamed(@"executioner")]];
    mesh.eulerAngles = SCNVector3Make(0, M_PI, 0);
    [preview addChildNode:mesh];
    CockpitContact contact = {.preview=preview, .local={100,50,-1210}, .relation=RelationHostile, .hull=.72, .shield=.4, .systems=.75,
        .name=@"Corsair Cutter Rask", .className=@"Corsair cutter", .cargo=@"Skarn munitions", .component=@"SHIELD GENERATOR",
        .orientation=simd_quaternion(0.7f, simd_make_float3(0,1,0))};
    CockpitFrame instrument = {.alive=YES, .target=0, .sun={-0.6f, 0.5f, 0.6f}, .weaponEnergy=.85, .weaponShotEnergy=.035, .weaponRecharge=.22, .shieldRecharge=.06, .hull=.9, .shield=.6, .closingSpeed=42, .time=2};
    for (NSValue *size in @[[NSValue valueWithSize:NSMakeSize(1440,900)], [NSValue valueWithSize:NSMakeSize(1194,834)], [NSValue valueWithSize:NSMakeSize(932,430)], [NSValue valueWithSize:NSMakeSize(852,393)], [NSValue valueWithSize:NSMakeSize(430,932)]]) {
        HUD *hud = [[HUD alloc] initWithSize:size.sizeValue];
        hud.backgroundColor = [SKColor colorWithRed:.015 green:.025 blue:.035 alpha:1];
        hud.touchLayout = hud.size.width < 1200;
        if (hud.touchLayout) hud.contentInsets = hud.size.width == 1194 ? NSEdgeInsetsMake(24,0,20,0) : NSEdgeInsetsMake(0,59,21,59);
        [hud setHelpVisible:NO];
        [hud setInputText:hud.touchLayout ? @"" : @"CONTROLLER: USB  /  T TARGET  /  G TORPEDO  /  ESC PAUSE"];
        [hud setObjectives:@[@"Patrol NAV 1, 2, 3 in order  0/3"] states:@[@0]];
        HUDFrame frame = {.speed=125, .throttle=.8, .boostEnergy=.6, .secondary=2, .secondaryCapacity=4, .secondaryName=@"TORPEDO"};
        [hud updateFrame:frame targets:NULL count:0];
        [hud updateInstruments:instrument contacts:&contact count:1 cockpit:NO];
        SKNode *speed = [hud valueForKey:@"speedLabel"], *throttle = [hud valueForKey:@"throttleLabel"], *input = [hud valueForKey:@"inputLabel"], *target = [hud valueForKey:@"targetReadout"];
        // The chase HUD hides the readout; it still lays out and draws on its own.
        CHECK(target.hidden);
        [(TargetReadout *)target updateFrame:instrument contacts:&contact count:1];
        CHECK(!CGRectIntersectsRect(speed.frame, throttle.frame));
        CHECK(CGRectContainsRect(RectWithSize(hud.size), speed.frame));
        CHECK(CGRectContainsRect(RectWithSize(hud.size), throttle.frame));
        // The condition rows stack without overlapping, clear of the target
        // readout and inside the right edge.
        NSArray<SKNode *> *rows = hud.conditionRows;
        CHECK(rows.count == 4);
        for (NSUInteger i = 0; i < rows.count; i++) {
            CGRect r = [rows[i] calculateAccumulatedFrame];
            CHECK(CGRectGetMinY(r) >= 0);
            CHECK(CGRectGetMaxX(r) <= hud.size.width - (hud.touchLayout ? hud.contentInsets.right : 0));
            CHECK(!CGRectIntersectsRect(r, [target calculateAccumulatedFrame]));
            if (i + 1 < rows.count) CHECK(CGRectGetMaxY(r) <= CGRectGetMinY([rows[i + 1] calculateAccumulatedFrame]) + 1);
        }
        if (!hud.touchLayout) CHECK([(SKLabelNode *)input text].length == 0);
        else {
            CHECK(speed.position.x < 90);
            CHECK(rows[1].position.x > hud.size.width - 170);
        }
        SKNode *forward = hud.forwardScope, *rear = hud.rearScope;
        SKNode *objectives = [hud valueForKey:@"objectivePanel"];
        CHECK(fabs(forward.position.y - rear.position.y) < 0.01);
        CHECK(CGRectGetMaxX([(SensorScope *)forward discFrame]) + 18 <= CGRectGetMinX([objectives calculateAccumulatedFrame]));
        CHECK(CGRectGetMinX(forward.frame) >= 0);
        CHECK(CGRectGetMaxX(rear.frame) <= hud.size.width);
        // The circular scopes have equal top and side margins, even when a
        // landscape phone reserves a large inset for the mid-edge housing.
        CGFloat fromTop = hud.size.height - forward.position.y;
        CHECK(fabs(forward.position.x - fromTop) < 0.01);
        CHECK(fabs(hud.size.width - rear.position.x - fromTop) < 0.01);
        if (hud.touchLayout && hud.size.width > hud.size.height) {
            CHECK(CGRectGetMinY(forward.frame) >= hud.size.height * 2 / 3);
            CHECK(CGRectGetMaxY(forward.frame) <= hud.size.height - hud.contentInsets.top);
        }
        if (hud.touchLayout) {
            CGFloat right = hud.size.width - hud.contentInsets.right - 12;
            CGFloat pauseRight = right - 128 * forward.xScale - 8;
            CHECK(pauseRight + 4 <= CGRectGetMinX(rear.frame));
        }
        TargetReadout *readout = (TargetReadout *)target;
        CHECK([[(SKLabelNode *)[readout valueForKey:@"cargo"] text] containsString:@"SKARN MUNITIONS"]);
        CHECK([[(SKLabelNode *)[readout valueForKey:@"component"] text] containsString:@"SHIELD GENERATOR"]);
        CockpitContact side = contact;
        side.local = simd_make_float3(1000, 0, 0);
        side.orientation = simd_quaternion(0, simd_make_float3(0, 1, 0));
        [readout updateFrame:instrument contacts:&side count:1];
        SCNNode *holder = [readout valueForKey:@"holder"];
        simd_float3 towardPlayer = simd_act(holder.simdOrientation, simd_make_float3(-1, 0, 0));
        CHECK(simd_distance(towardPlayer, simd_make_float3(0, 0, 1)) < .001);
        // The preview is the lit model, not a wireframe, framed to fill the
        // display whichever way the ship faces us.
        SCNNode *model = [readout valueForKey:@"model"];
        CHECK(model && model != preview);
        __block BOOL lit = NO, lines = NO;
        [model enumerateHierarchyUsingBlock:^(SCNNode *node, BOOL *stop) {
            for (SCNMaterial *m in node.geometry.materials) {
                lit |= m.lightingModelName != SCNLightingModelConstant;
                lines |= m.fillMode == SCNFillModeLines;
            }
        }];
        CHECK(lit && !lines);
        SCNNode *camera = [readout valueForKey:@"camera"];
        float sideOn = camera.camera.orthographicScale;
        side.local = simd_make_float3(0, 0, -1000);   // dead ahead, seen from behind: a smaller outline
        for (int i = 0; i < 20; i++) [readout updateFrame:instrument contacts:&side count:1];
        CHECK(camera.camera.orthographicScale < sideOn - 0.05);
        [readout updateFrame:instrument contacts:&contact count:1];

        for (SKNode *node in readout.children) CHECK(![node isKindOfClass:SKShapeNode.class]);
        NSString *prefix = [NSString stringWithFormat:@"hud-%.0fx%.0f", hud.size.width, hud.size.height];
        Save(hud, [prefix stringByAppendingString:@".png"]);
        instrument.target = -1; [hud updateInstruments:instrument contacts:NULL count:0 cockpit:NO];
        [readout updateFrame:instrument contacts:NULL count:0];
        CHECK(![[(SKLabelNode *)[readout valueForKey:@"empty"] text] isEqualToString:@""]);
        Save(hud, [prefix stringByAppendingString:@"-no-target.png"]);
        [hud setObjectives:@[] states:@[]];
        frame.respawning = YES; frame.kills = 3; frame.deaths = 2;
        [hud updateFrame:frame targets:NULL count:0];
        CHECK(!hud.scoreLabel.hidden && [hud.scoreLabel.text containsString:@"3"]);
        CHECK(!CGRectIntersectsRect(hud.scoreLabel.frame, forward.frame) && !CGRectIntersectsRect(hud.scoreLabel.frame, rear.frame));
        Save(hud, [prefix stringByAppendingString:@"-dogfight.png"]);
        [hud toggleHelp]; CHECK(hud.helpVisible);
        [hud updateFrame:frame targets:NULL count:0];
        CGRect safe = RectInsetEdges((CGRect){.size=hud.size}, hud.contentInsets.left, hud.contentInsets.top,
            hud.contentInsets.right, hud.contentInsets.bottom);
        CHECK(CGRectContainsRect(safe, hud.helpRect));
        Save(hud, [prefix stringByAppendingString:@"-help.png"]);
        [hud toggleHelp]; CHECK(!hud.helpVisible);
        instrument.target = 0;
    }
    return 0;
}
// Two sibling labels whose frames intersect are drawn over each other. Walks
// the whole tree; returns the first offending pair in `where`. Hidden and
// empty labels do not count.
static BOOL OverlappingSiblingLabels(SKNode *parent, NSString **where) {
    NSMutableArray<SKLabelNode *> *labels = [NSMutableArray array];
    for (SKNode *child in parent.children) {
        if (child.hidden || child.alpha <= 0) continue;
        if ([child isKindOfClass:SKLabelNode.class] && [(SKLabelNode *)child text].length) [labels addObject:(SKLabelNode *)child];
        if (OverlappingSiblingLabels(child, where)) return YES;
    }
    for (NSUInteger i = 0; i < labels.count; i++)
        for (NSUInteger j = i + 1; j < labels.count; j++)
            if (CGRectIntersectsRect(labels[i].frame, labels[j].frame)) {
                *where = [NSString stringWithFormat:@"\"%@\" %@ overlaps \"%@\" %@", labels[i].text, NSStringFromRect(labels[i].frame),
                          labels[j].text, NSStringFromRect(labels[j].frame)];
                return YES;
            }
    return NO;
}

static int CheckGrid(void) {
    [NSUserDefaults.standardUserDefaults setInteger:4 forKey:@"SFMissionsUnlocked"];
    // Entrance effects briefly draw copies of labels; the layout itself is checked.
    [Cvar set:@"ui_reduceMotion" value:@"1"];
    ProgressRecordResult(0, @[@"+ Patrol", @"+ Escort"]);
    CHECK(ProgressBestStars(0) == 3);
    ProgressRecordResult(0, @[@"+ Patrol", @"- Escort"]);
    CHECK(ProgressBestStars(0) == 3);
    for (NSValue *size in @[[NSValue valueWithSize:NSMakeSize(1440,900)], [NSValue valueWithSize:NSMakeSize(932,430)], [NSValue valueWithSize:NSMakeSize(430,932)]]) {
        Briefing *grid = [[Briefing alloc] initWithSize:size.sizeValue];
        if (grid.size.width < 1000) grid.contentInsets = NSEdgeInsetsMake(0,59,21,59);
        [grid showListSelecting:0]; [grid tick:0];
        NSArray<NSValue *> *tiles = [grid valueForKey:@"missionTiles"];
        CHECK(tiles.count == CampaignMissions().count);
        CGRect viewport = [[grid valueForKey:@"missionRows"] rectValue];
        for (NSUInteger i=0; i<tiles.count; i++) {
            CGRect a = tiles[i].rectValue;
            CHECK(a.size.width >= 140 && a.size.height >= 140);
            for (NSUInteger j=i+1; j<tiles.count; j++) CHECK(!CGRectIntersectsRect(a, tiles[j].rectValue));
        }
        NSString *where = nil;
        if (OverlappingSiblingLabels(grid, &where)) fprintf(stderr, "%s: %s\n", NSStringFromSize(grid.size).UTF8String, where.UTF8String);
        CHECK(where == nil);
        Save(grid, [NSString stringWithFormat:@"missions-%.0fx%.0f.png", grid.size.width,grid.size.height]);
        CGPoint origin = CGPointMake(CGRectGetMidX(viewport)/grid.size.width, CGRectGetMidY(viewport)/grid.size.height);
        [grid pointerScroll:10000 at:origin]; [grid handle:0];
        CGFloat offset = [[grid valueForKey:@"scrollOffset"] doubleValue];
        CGRect last = tiles.lastObject.rectValue;
        CGPoint hit = CGPointMake(CGRectGetMidX(last)/grid.size.width, (CGRectGetMidY(last)+offset)/grid.size.height);
        CHECK(CGRectContainsPoint(viewport, CGPointMake(hit.x*grid.size.width, hit.y*grid.size.height)));
        [grid pointerClick:hit]; [grid handle:0];
        CHECK(grid.selectedIndex == tiles.count-1);
        [grid handle:InputActionConfirm];
        CHECK([[grid valueForKey:@"mode"] integerValue] == 0); // Locked stays on the grid.
    }
    [Cvar set:@"ui_reduceMotion" value:@""];
    return 0;
}
static int CheckPause(void) {
    [FlightControls.shared reset];
    for (NSValue *size in @[[NSValue valueWithSize:NSMakeSize(1440,900)], [NSValue valueWithSize:NSMakeSize(932,430)], [NSValue valueWithSize:NSMakeSize(430,932)]]) {
        PauseMenu *menu = [[PauseMenu alloc] initWithSize:size.sizeValue];
        [menu showRemote:NO cockpit:NO];
        CHECK([menu handle:InputActionBack] == PauseCommandResume);
        CHECK([menu handle:InputActionConfirm] == PauseCommandResume);
        // The pause panel includes the engine controls alongside flight actions.
        {
            CGSize s = size.sizeValue;
            CGFloat w = MIN(400, s.width - 48), h = MIN(410, s.height - 24);
            CGFloat x = (s.width - w) / 2, y = (s.height - h) / 2, row = MIN(44, (h - 82) / 6 - 6);
            id layout = [menu valueForKey:@"_layout"];
            NSArray *ids = @[@"resume", @"camera", @"controls", @"sound", @"restart", @"missions"];
            for (NSUInteger i = 0; i < ids.count; i++) {
                CGRect got = [(UILayoutResult *)layout frame:[@"items." stringByAppendingString:ids[i]]];
                CGRect want = CGRectMake(x + 22, y + h - 70 - (i + 1) * (row + 6), w - 44, row);
                CHECK(fabs(got.origin.x - want.origin.x) < 0.01 && fabs(got.origin.y - want.origin.y) < 0.01 &&
                      fabs(got.size.width - want.size.width) < 0.01 && fabs(got.size.height - want.size.height) < 0.01);
            }
        }
        Save(menu, [NSString stringWithFormat:@"pause-%.0fx%.0f.png", menu.size.width,menu.size.height]);
        [menu handle:InputActionDown]; CHECK([menu handle:InputActionConfirm] == PauseCommandCamera);
        [menu handle:InputActionDown]; CHECK([menu handle:InputActionConfirm] == PauseCommandNone);
        CHECK(menu.controlsPanel != nil);
        Save(menu, [NSString stringWithFormat:@"controls-%.0fx%.0f.png", menu.size.width, menu.size.height]);
        BOOL expert = FlightControls.shared.expert;
        [menu handle:InputActionConfirm]; CHECK(FlightControls.shared.expert != expert);
        [menu handle:InputActionDown];
        [menu handle:InputActionLeft]; CHECK(FlightControls.shared.horizontalSensitivity == 0.75f);
        [menu handle:InputActionRight]; CHECK(FlightControls.shared.horizontalSensitivity == 1);
        [menu handle:InputActionDown];
        [menu handle:InputActionRight]; CHECK(FlightControls.shared.verticalSensitivity == 1.25f);
        for (int i=0; i<2; i++) [menu handle:InputActionDown];
        BOOL dynamic = FlightControls.shared.dynamicCamera;
        [menu handle:InputActionConfirm]; CHECK(FlightControls.shared.dynamicCamera != dynamic);
        FlightControls.shared.dynamicCamera = NO;
        [menu handle:InputActionDown];
        [menu handle:InputActionConfirm]; CHECK(!FlightControls.shared.expert && FlightControls.shared.verticalSensitivity == 1);
        CHECK(FlightControls.shared.dynamicCamera);
        CHECK([menu handle:InputActionBack] == PauseCommandNone && !menu.controlsPanel);
        [menu handle:InputActionDown]; CHECK([menu handle:InputActionConfirm] == PauseCommandSound);
        [menu handle:InputActionDown]; CHECK([menu handle:InputActionConfirm] == PauseCommandRestart);
        [menu handle:InputActionDown]; CHECK([menu handle:InputActionConfirm] == PauseCommandMissions);
        [menu showRemote:YES cockpit:YES];
        for (int i=0;i<4;i++) [menu handle:InputActionDown];
        CHECK([menu handle:InputActionConfirm] == PauseCommandNone);
    }
    return 0;
}
static int CheckSettingLayout(void) {
    NSString *(^text)(float) = ^NSString *(float value) { return [NSString stringWithFormat:@"%.0f%%", value*100]; };
    NSArray *items = @[[UISettingItem choice:@"Steering mode" value:@"EXPERT" detail:nil action:^{}],
                      [UISettingItem slider:@"Horizontal sensitivity" value:1 minimum:0.25 maximum:2 step:0.25 text:text change:^(float v) {}],
                      [UISettingItem action:@"A longer translated setting title that must wrap safely within its own row" value:@"RESTORE" action:^{}]];
    for (NSNumber *width in @[@260, @320, @539, @540, @760, @1100]) {
        UISettingsForm *form = [[UISettingsForm alloc] initWithItems:items width:width.doubleValue];
        for (NSUInteger i = 0; i < items.count; i++) {
            CGRect row = UnboxRect(form.rowRects[i]), control = UnboxRect(form.controlRects[i]), title = UnboxRect(form.titleRects[i]);
            CHECK(CGRectContainsRect(CGRectInset(row, 15, 15), control));
            CHECK(CGRectContainsRect(CGRectInset(row, 15, 15), title));
            CHECK(!CGRectIntersectsRect(control, title));
            if (width.doubleValue >= 540) {
                CHECK(fabs(CGRectGetMidY(row) - CGRectGetMidY(control)) < 0.01);
                CHECK(fabs(CGRectGetMidY(row) - CGRectGetMidY(title)) < 0.5);
            }
        }
    }
    return 0;
}
static int CheckControls(void) {
    [Cvar set:@"ui_reduceMotion" value:@"1"];
    [FlightControls.shared reset];
    for (NSValue *size in @[[NSValue valueWithSize:NSMakeSize(1440,900)], [NSValue valueWithSize:NSMakeSize(852,393)], [NSValue valueWithSize:NSMakeSize(320,568)]]) {
        MainMenu *menu = [[MainMenu alloc] initWithSize:size.sizeValue];
        menu.contentInsets = menu.size.width == 852 ? NSEdgeInsetsMake(0,59,21,59) : NSEdgeInsetsMake(24,0,20,0);
        for (int i=0; i<3; i++) [menu handle:InputActionDown];
        [menu handle:InputActionConfirm];
        ControlsPanel *panel = menu.controlsPanel;
        CHECK(panel && panel.settingRects.count == 6);
        CHECK(CGRectContainsRect(RectWithSize(menu.size), panel.backRect));
        CHECK(CGRectContainsRect(RectWithSize(menu.size), panel.scrollRect));
        // Click the actual mode button through the host screen's pointer path.
        CGPoint click = [menu convertPoint:RectCenter(UnboxRect(panel.form.controlRects[0])) fromNode:panel.form];
        [menu pointerClick:CGPointMake(click.x/menu.size.width, click.y/menu.size.height)];
        [menu handle:0];
        CHECK(FlightControls.shared.expert);
        Save(menu, [NSString stringWithFormat:@"main-controls-expert-%.0fx%.0f.png", menu.size.width, menu.size.height]);
        CGRect back = panel.backRect;
        CGPoint centre = RectCenter(panel.scrollRect);
        [menu pointerScroll:10000 at:CGPointMake(centre.x/menu.size.width, centre.y/menu.size.height)];
        CHECK(panel.scrollOffset >= 0 && CGRectEqualToRect(back, panel.backRect));
        if (menu.size.height < 600) CHECK(panel.scrollOffset > 0);
        Save(menu, [NSString stringWithFormat:@"main-controls-bindings-%.0fx%.0f.png", menu.size.width, menu.size.height]);
        [menu pointerScroll:-10000 at:CGPointMake(centre.x/menu.size.width, centre.y/menu.size.height)];
        CHECK(panel.scrollOffset == 0);
        // A slider owns its drag: finger movement adjusts its value without
        // scrolling the form, including clamping beyond either end of the bar.
        [menu handle:InputActionDown];
        CGRect slider = UnboxRect(panel.form.controlRects[1]);
        CGPoint start = [menu convertPoint:RectCenter(slider) fromNode:panel.form];
        CGPoint fraction = PointFractionInRect(start, RectWithSize(menu.size));
        ScreenInputDeliver(menu, (PointerEvent){ .kind=PointerEventDown, .at=fraction });
        CHECK(panel.form.dragging && fabs(FlightControls.shared.horizontalSensitivity - 1.125f) < 0.001);
        CGFloat offset = panel.scrollOffset;
        [menu pointerScroll:40 at:fraction];
        CHECK(panel.scrollOffset == offset);
        CGPoint end = [menu convertPoint:PointAdd(RectCenter(slider), CGPointMake(CGRectGetWidth(slider), 0)) fromNode:panel.form];
        ScreenInputDeliver(menu, (PointerEvent){ .kind=PointerEventDrag, .at=PointFractionInRect(end, RectWithSize(menu.size)) });
        CHECK(FlightControls.shared.horizontalSensitivity == 2);
        ScreenInputDeliver(menu, (PointerEvent){ .kind=PointerEventCancel });
        CHECK(!panel.form.dragging);
        [menu pointerDrag:fraction];
        CHECK(FlightControls.shared.horizontalSensitivity == 2);
        ScreenInputDeliver(menu, (PointerEvent){ .kind=PointerEventDown, .at=fraction }); ScreenInputDeliver(menu, (PointerEvent){ .kind=PointerEventUp, .at=fraction });
        CHECK(!panel.form.dragging);
        // Back returns to the host menu without resuming or launching a mission.
        CGPoint point = RectCenter(panel.backRect);
        [menu pointerClick:CGPointMake(point.x/menu.size.width, point.y/menu.size.height)];
        CHECK([menu handle:0] == MainMenuCommandNone && !menu.controlsPanel);
        [FlightControls.shared reset];
    }
    [Cvar set:@"ui_reduceMotion" value:@""];
    return 0;
}
// The front end runs the menus through UIServices alone; a stand-in host
// records what it is asked to do.
@interface FakeServices : NSObject <UIServices>
@property (nonatomic) SKScene *presented;
@property (nonatomic) NSInteger started, cancels;
@property (nonatomic) NSInteger created, matches, closed;
@property (nonatomic) NSArray<NSString *> *hostedPilots;
@end
@implementation FakeServices
- (void)startLevel:(NSUInteger)index { _started = (NSInteger)index; }
- (void)joinServer:(NetAddress *)address {}
- (void)cancelJoin { _cancels++; }
- (BOOL)createLANGame { _created++; return YES; }
- (void)startLANMatch { _matches++; }
- (void)closeLANGame { _closed++; }
- (BOOL)hostingFailed { return NO; }
- (void)present:(SKScene *)screen { _presented = screen; }
- (void)quitAfter:(NSTimeInterval)seconds {}
- (void)drawMenuBackdrop {}
- (BOOL)isOwnServer:(LANServer *)server { return NO; }
- (LANBrowser *)makeLANBrowser { return nil; }   // no sockets: nothing for the firewall to ask about
- (double)time { return 0; }
- (NSString *)connectedServer { return nil; }
@end

static int CheckFrontEnd(void) {
    FakeServices *services = [FakeServices new];
    services.started = -1;
    FrontEnd *front = [[FrontEnd alloc] initWithSize:CGSizeMake(1440, 900) services:services];
    [front prepareAfterBoot];
    CHECK([front.currentScreen isKindOfClass:MainMenu.class] && services.presented == nil);
    [front showMainMenu];
    CHECK([services.presented isKindOfClass:MainMenu.class]);
    [front frame:InputActionDown];                 // campaign -> missions
    [front frame:InputActionConfirm];
    CHECK([services.presented isKindOfClass:Briefing.class] && front.currentScreen == services.presented);
    [front frame:InputActionBack];                 // the mission list goes back to the main menu
    CHECK([services.presented isKindOfClass:MainMenu.class]);
    [front showBrowser];
    CHECK([services.presented isKindOfClass:ServerBrowser.class]);
    [front frame:InputActionBack];
    CHECK(services.cancels == 1 && [services.presented isKindOfClass:MainMenu.class]);
    [front levelEnded:0 success:NO results:@[@"x Objective"] remote:YES];
    CHECK([services.presented isKindOfClass:Briefing.class]);
    CHECK(services.started == -1 && front.levelCount >= 1);
    NSUInteger unlocked = ProgressUnlockedCount(), stars = ProgressBestStars(0);
    BOOL completed = ProgressCampaignCompleted();
    [front levelEnded:0 success:YES results:@[@"+ Objective"] remote:YES];
    CHECK(ProgressUnlockedCount() == unlocked && ProgressBestStars(0) == stars && ProgressCampaignCompleted() == completed);
    [front showBrowser];
    ServerBrowser *browser = (ServerBrowser *)front.currentScreen;
    CGPoint create = RectCenter(browser.createRect);
    [browser pointerClick:CGPointMake(create.x / browser.size.width, create.y / browser.size.height)];
    [front frame:0];
    CHECK([front.currentScreen isKindOfClass:LANGame.class]);
    LANGame *game = (LANGame *)front.currentScreen;
    CHECK(game.stage == LANGameSetup);
    services.hostedPilots = @[@"Host"];
    [front frame:InputActionConfirm];
    CHECK(services.created == 1 && game.stage == LANGameLobby);
    [front frame:InputActionConfirm]; CHECK(services.matches == 0);
    services.hostedPilots = @[@"Host", @"Friend"];
    [front frame:InputActionConfirm]; CHECK(services.matches == 1);
    [front showLANResults:@[@"Host 10 / 2", @"Friend 2 / 10"] hosting:YES];
    CHECK(game.stage == LANGameResults);
    [front frame:InputActionConfirm]; CHECK(game.stage == LANGameLobby);
    [front frame:InputActionBack]; CHECK(services.closed == 1 && [front.currentScreen isKindOfClass:ServerBrowser.class]);
    CHECK(ProgressUnlockedCount() == unlocked && ProgressBestStars(0) == stars);
    return 0;
}

static int CheckLANLayouts(void) {
    NSArray *names = @[@"Host", @"Mira", @"Soren", @"A very long pilot name that needs truncating", @"Lancer 5", @"Lancer 6", @"Lancer 7", @"Lancer 8"];
    for (NSValue *size in @[[NSValue valueWithSize:NSMakeSize(667,375)], [NSValue valueWithSize:NSMakeSize(852,393)],
        [NSValue valueWithSize:NSMakeSize(1194,834)], [NSValue valueWithSize:NSMakeSize(1440,900)]]) {
        LANGame *game = [[LANGame alloc] initWithSize:size.sizeValue];
        game.contentInsets = game.size.width == 852 ? NSEdgeInsetsMake(0,59,21,59) : NSEdgeInsetsMake(0,0,20,0);
        [game handle:0];
        CHECK(CGRectGetHeight(game.confirmRect) >= 44 && !CGRectIntersectsRect(game.confirmRect, game.backRect));
        Save(game, [NSString stringWithFormat:@"lan-setup-%.0f.png", game.size.width]);
        [game showPilots:names];
        CHECK(CGRectGetMinY(game.bodyRect) > game.contentInsets.bottom);
        CHECK(CGRectGetHeight(game.confirmRect) >= 44);
        Save(game, [NSString stringWithFormat:@"lan-lobby-%.0f.png", game.size.width]);
        [game showResults:names hosting:NO];
        CHECK(CGRectIsEmpty(game.confirmRect) && [game handle:InputActionConfirm] == LANGameCommandNone);
        CHECK([game handle:InputActionBack] == LANGameCommandBack);
        ServerBrowser *browser = [[ServerBrowser alloc] initWithSize:size.sizeValue];
        browser.contentInsets = game.contentInsets;
        NSMutableArray *servers = [NSMutableArray array];
        for (int i = 0; i < 12; i++) {
            LANServer *server = [LANServer new]; server.name = names[i % names.count];
            server.address = [NetAddress loopback:100+i]; server.players = 2; server.maxPlayers = 8;
            [servers addObject:server];
        }
        [browser showServers:servers];
        [browser handle:InputActionDown];
        CHECK(CGRectGetHeight(browser.createRect) >= 44 && CGRectGetHeight(browser.joinRect) >= 44);
        CHECK(!CGRectIntersectsRect(browser.createRect, browser.serverRows));
        LANServer *selected = browser.selected;
        [browser showServers:servers]; CHECK(browser.selected == selected);
        for (int i = 0; i < 11; i++) [browser handle:InputActionDown];
        CHECK(browser.selected == servers.lastObject);
        Save(browser, [NSString stringWithFormat:@"lan-browser-%.0f.png", game.size.width]);
    }
    return 0;
}

static int CheckProtocol(void) {
    EntityState entity = {.number=1, .name=2, .className=3, .cargo=4, .flags=EF_SCANNED, .scale=1, .orientation={{0,0,0,1}}};
    MsgWriter *writer = [MsgWriter new]; WritePacketEntities(writer,NULL,0,&entity,1);
    MsgReader *reader = [[MsgReader alloc] initWithData:writer.data];
    NSMutableData *decoded = [NSMutableData data]; CHECK(ReadPacketEntities(reader,NULL,0,decoded));
    CHECK(decoded.length == sizeof(EntityState));
    EntityState from = *(const EntityState *)decoded.bytes;
    CHECK(from.cargo == 4 && from.flags == EF_SCANNED);
    entity.cargo=0; entity.flags=0;
    writer=[MsgWriter new]; WritePacketEntities(writer,&from,1,&entity,1);
    reader=[[MsgReader alloc] initWithData:writer.data]; decoded=[NSMutableData data];
    CHECK(ReadPacketEntities(reader,&from,1,decoded));
    CHECK(((const EntityState *)decoded.bytes)->cargo == 0);
    return 0;
}
static void Pump(Client *client, Server *server, ControlState controls, BOOL paused) {
    [client setValue:@0 forKey:@"lastMoveSent"]; // Virtual-time network fixture, no real-time throttle.
    [client sendInput:controls actions:0 dt:TICK_DT]; [server frame:TICK_DT paused:paused]; [client readPackets];
}
static PlayerState Latest(Client *client) { return ((Snapshot *)[[client valueForKey:@"snapshots"] lastObject]).ps; }
static int CheckSimulation(void) {
    Server *server = [[Server alloc] initWithName:@"Pause fixture"];
    CHECK(server);
    [server addTransport:[LoopbackTransport side:1]]; [server spawnLevel:CampaignLevelName(0)];
    Client *client = [[Client alloc] initWithView:nil];
    __weak Client *weak = client; client.gamestateHandler = ^{ [weak begin]; };
    [client connectTo:[NetAddress loopback:1] transport:[LoopbackTransport side:0] name:@"Fixture"];
    for (int i=0;i<10;i++) Pump(client,server,(ControlState){.hat=-1},NO);
    CHECK(client.state == ClientActive);
    PlayerState before = Latest(client);
    double time = server.time;
    // Even a peer sending thrust/fire cannot advance a locally paused game.
    for (int i=0;i<90;i++) Pump(client,server,(ControlState){.hat=-1,.throttle=1,.fire=YES},YES);
    CHECK(server.time == time);
    [server frame:TICK_DT paused:NO]; [client readPackets];
    PlayerState after = Latest(client);
    CHECK(simd_distance(before.move.origin,after.move.origin) < .01);
    CHECK(after.stats[STAT_WEAPON_ENERGY] == before.stats[STAT_WEAPON_ENERGY]);
    for (int i=0;i<120;i++) Pump(client,server,(ControlState){.hat=-1,.fire=YES},NO);
    int depleted = Latest(client).stats[STAT_WEAPON_ENERGY];
    CHECK(depleted < 950 && depleted >= 0);
    for (int i=0;i<150;i++) Pump(client,server,(ControlState){.hat=-1},NO);
    CHECK(Latest(client).stats[STAT_WEAPON_ENERGY] > depleted);
    [client disconnect]; [server stop];
    return 0;
}
int main(int argc, const char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    Output = argc>1 ? @(argv[1]) : @"/tmp";
    if (CheckSensors() || CheckHUD() || CheckGrid() || CheckPause() || CheckSettingLayout() || CheckControls() || CheckFrontEnd() || CheckLANLayouts() || CheckProtocol() || CheckSimulation()) return 1;
    puts("PASS: flight instruments, mission grid, pause, capacitor and cargo protocol.");
} return 0; }
