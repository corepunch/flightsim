#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import "UI.h"
#import "Refresh.h"
#import "Common.h"
#import "Shared.h"

#define CHECK(c) do { if (!(c)) { fprintf(stderr,"Localization check failed at %d: %s\n",__LINE__,#c); exit(1); } } while (0)
static SKView *View;
static NSString *Output, *Locale;
static NSMutableArray *Entries;
static BOOL VerifyOnly;
static BOOL FlightOnly;
static BOOL NetworkOnly;
static NSUInteger SavedCount;

static void CheckGlyphs(SKNode *node) {
    if (node.hidden || node.alpha == 0) return;
    if ([node isKindOfClass:SKLabelNode.class]) {
        SKLabelNode *label = (SKLabelNode *)node;
        NSString *text = label.attributedText.string ?: label.text;
        if (text.length) {
            NSFont *font = [NSFont fontWithName:label.fontName size:label.fontSize]; CHECK(font);
            NSAttributedString *rich = label.attributedText ?: [[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName:font}];
            CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)rich);
            for (id object in (__bridge NSArray *)CTLineGetGlyphRuns(line)) {
                CTRunRef run = (__bridge CTRunRef)object;
                CFIndex count = CTRunGetGlyphCount(run);
                CGGlyph glyphs[count]; CFIndex indices[count];
                CTRunGetGlyphs(run, CFRangeMake(0,0), glyphs);
                CTRunGetStringIndices(run, CFRangeMake(0,0), indices);
                for (CFIndex i=0;i<count;i++) if (!glyphs[i]) {
                    unichar character = [text characterAtIndex:indices[i]];
                    if (![NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:character] &&
                        ![NSCharacterSet.controlCharacterSet characterIsMember:character]) {
                        fprintf(stderr,"Missing glyph U+%04X in %s / %s\n", character, Locale.UTF8String, text.UTF8String);
                        CFRelease(line); CHECK(NO);
                    }
                }
            }
            CFRelease(line);
        }
    }
    for (SKNode *child in node.children) CheckGlyphs(child);
}

static void Save(SKScene *scene, NSString *device, NSString *family, NSString *name, ScreenInsets safe) {
    @autoreleasepool {
        if (VerifyOnly) { CheckGlyphs(scene); return; }
        [View presentScene:nil]; View.frame=RectWithSize(scene.size);
        [View presentScene:scene]; CheckGlyphs(scene);
        NSDate *ready = [NSDate dateWithTimeIntervalSinceNow:0.04];
        while (ready.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:ready];
        SKTexture *texture = [View textureFromNode:scene crop:RectWithSize(scene.size)]; CHECK(texture.CGImage);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = CGBitmapContextCreate(NULL,scene.size.width,scene.size.height,8,0,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(space); CHECK(context);
        CGContextDrawImage(context,RectWithSize(scene.size),texture.CGImage);
        CGImageRef pixels=CGBitmapContextCreateImage(context);
        NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithCGImage:pixels];
        CGImageRelease(pixels); CGContextRelease(context);
        NSString *file=[NSString stringWithFormat:@"%@-%@-%@.png",Locale,device,name];
        CHECK([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[Output stringByAppendingPathComponent:file] atomically:YES]);
        NSIndexSet *old=[Entries indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry,NSUInteger index,BOOL *stop) {
            return [entry[@"file"] isEqualToString:file];
        }];
        [Entries removeObjectsAtIndexes:old]; SavedCount++;
        [Entries addObject:@{@"locale":Locale,@"device":device,@"family":family,@"category":@"localization",@"name":name,
            @"file":file,@"width":@(scene.size.width),@"height":@(scene.size.height),
            @"safe":@[@(safe.top),@(safe.left),@(safe.bottom),@(safe.right)]}];
        [View presentScene:nil];
    }
}

int main(int argc,const char **argv) { @autoreleasepool {
    CHECK(argc>=3); Output=@(argv[1]); Locale=@(argv[2]); Entries=[NSMutableArray array];
    BOOL glyphsOnly=argc>=5 && strcmp(argv[3],"--glyphs-only")==0;
    VerifyOnly=argc>=4 && strcmp(argv[3],"--verify-only")==0;
    FlightOnly=argc>=4 && strcmp(argv[3],"--flight-only")==0;
    NetworkOnly=argc>=4 && strcmp(argv[3],"--network-only")==0;
    if (FlightOnly || NetworkOnly) {
        NSData *prior=[NSData dataWithContentsOfFile:[Output stringByAppendingPathComponent:[Locale stringByAppendingString:@".json"]]];
        NSArray *entries=prior ? [NSJSONSerialization JSONObjectWithData:prior options:0 error:NULL] : nil;
        if ([entries isKindOfClass:NSArray.class] && entries.count) [Entries addObjectsFromArray:entries];
        else { FlightOnly=NO; NetworkOnly=NO; }
    }
    FSSetGame(glyphsOnly ? @(argv[4]) : @"KestrelFrontier");
    [NSApplication sharedApplication]; [NSApp finishLaunching];
    CHECK([L10nLocale() isEqualToString:Locale]);
    CHECK(L10nHasOwn(@"pause.resume") && L10nHasOwn(@"controls.expert_detail"));
    // Shape every catalog entry, including game content not visible in this sheet.
    for (id value in [L10nCatalogs()[Locale][@"strings"] allValues]) {
        for (NSString *text in [value isKindOfClass:NSArray.class] ? value : @[value]) {
            SKLabelNode *label=UIInterfaceLabel(17,SKColor.whiteColor,SKLabelHorizontalAlignmentModeLeft,SKLabelVerticalAlignmentModeTop);
            label.text=text; CheckGlyphs(label);
        }
    }
    for (NSNumber *height in @[@44,@52]) {
        NSString *text=L10n(@"controls.back");
        CGRect rect=CGRectMake(0,0,UIBackControlWidth(text,height.doubleValue,17),height.doubleValue);
        SKShapeNode *button=UIBackControl(rect,text,UIAmber,17);
        CHECK([((SKLabelNode *)button.children.firstObject).text isEqualToString:text]);
    }
    if (glyphsOnly) {
        printf("PASS: localization %s / %s shaped every catalog entry.\n",Locale.UTF8String,FSGame().UTF8String);
        return 0;
    }
    [Cvar set:@"ui_reduceMotion" value:@"1"];
    View=[[SKView alloc] initWithFrame:CGRectMake(0,0,1600,900)]; View.shouldCullNonVisibleNodes=NO;
    const struct { __unsafe_unretained NSString *name,*family; CGSize size; ScreenInsets safe; BOOL touch; } configs[]={
        {@"iphone-small",@"iPhone",{568,320},{0,0,0,0},YES},
        {@"iphone-se",@"iPhone",{667,375},{0,0,0,0},YES},
        {@"iphone-notch",@"iPhone",{852,393},{0,59,21,59},YES},
        {@"iphone-large",@"iPhone",{932,430},{0,59,21,59},YES},
        {@"ipad",@"iPad",{1194,834},{24,0,20,0},YES},
        {@"ipad-window",@"iPad",{600,834},{24,0,20,0},YES},
        {@"ipad-portrait",@"iPad",{834,1194},{24,0,20,0},YES},
        {@"desktop-small",@"Desktop",{1280,720},{0,0,0,0},NO},
        {@"desktop",@"Desktop",{1600,900},{0,0,0,0},NO},
        {@"desktop-wide",@"Desktop",{2288,818},{0,0,0,0},NO},
        {@"desktop-narrow",@"Desktop",{640,660},{0,0,0,0},NO}
    };
    for (NSUInteger i=0;i<sizeof(configs)/sizeof(configs[0]);i++) @autoreleasepool {
        CGSize size=configs[i].size; ScreenInsets safe=configs[i].safe;
        if (!FlightOnly && !NetworkOnly) {
        PauseMenu *pause=[[PauseMenu alloc] initWithSize:size]; pause.contentInsets=safe;
        [pause showRemote:YES cockpit:NO];
        for (NSString *key in pause.layout.buttons) {
            SKNode *button=pause.layout.buttons[key]; CGRect rect=[pause.layout frame:key];
            for (SKNode *child in button.children) if ([child isKindOfClass:SKLabelNode.class]) {
                SKLabelNode *label=(SKLabelNode *)child;
                if ([(label.attributedText.string ?: label.text) hasSuffix:@"…"]) {
                    fprintf(stderr,"Truncated %s / %s / %s: %s in %s\n",Locale.UTF8String,configs[i].name.UTF8String,
                        key.UTF8String,(label.attributedText.string ?: label.text).UTF8String,NSStringFromRect(rect).UTF8String);
                }
                CHECK(![(label.attributedText.string ?: label.text) hasSuffix:@"…"]);
                CHECK(CGRectContainsRect(CGRectInset(rect,-1,-1),child.frame));
                CHECK(fabs(CGRectGetMidY(child.frame)-CGRectGetMidY(rect))<1);
            }
        }
        Save(pause,configs[i].name,configs[i].family,@"pause-online",safe);
        MainMenu *menu=[[MainMenu alloc] initWithSize:size]; menu.touchNavigationEnabled=configs[i].touch; menu.contentInsets=safe;
        [menu showMission:0 title:L10n(@"missions.ready") started:YES completed:NO];
        Save(menu,configs[i].name,configs[i].family,@"main-menu",safe);
        SKScene *settings=[SKScene sceneWithSize:size]; settings.backgroundColor=UIColorWithOpacity(UIBackground,1);
        ControlsPanel *panel=[ControlsPanel new]; panel.touchNavigationEnabled=configs[i].touch;
        [panel layoutIn:RectInsetEdges(RectWithSize(size),safe.left+18,safe.top+18,safe.right+18,safe.bottom+18) sceneSize:size];
        [settings addChild:panel]; Save(settings,configs[i].name,configs[i].family,@"flight-settings",safe);
        }
        if (!FlightOnly) {
        LANGame *lan=[[LANGame alloc] initWithSize:size]; lan.contentInsets=safe;
        [lan showSetup]; [lan handle:0]; Save(lan,configs[i].name,configs[i].family,@"lan-settings",safe);
        [lan showPilots:@[@"Host"]]; Save(lan,configs[i].name,configs[i].family,@"lan-waiting",safe);
        [lan showPilots:@[@"Host",@"Wingmate",@"Pilot 3",@"Pilot 4",@"Pilot 5",@"Pilot 6",@"Pilot 7",@"Pilot 8"]];
        for(NSValue *rect in lan.pilotRects) {
            if(!CGRectContainsRect(CGRectInset(lan.bodyRect,-1,-1),UnboxRect(rect))) fprintf(stderr,"LAN %s / %s: body %s row %s\n",Locale.UTF8String,configs[i].name.UTF8String,NSStringFromRect(lan.bodyRect).UTF8String,NSStringFromRect(UnboxRect(rect)).UTF8String);
            CHECK(CGRectContainsRect(CGRectInset(lan.bodyRect,-1,-1),UnboxRect(rect)));
        }
        Save(lan,configs[i].name,configs[i].family,@"lan-full",safe);
        ServerBrowser *browser=[[ServerBrowser alloc] initWithSize:size]; browser.contentInsets=safe;
        [browser showServers:@[]]; Save(browser,configs[i].name,configs[i].family,@"lan-searching",safe);
        }
        if (NetworkOnly) continue;
        HUD *hud=[[HUD alloc] initWithSize:size]; hud.backgroundColor=UIColorWithOpacity(UIBackground,1);
        hud.touchLayout=configs[i].touch; hud.contentInsets=safe;
        [hud setObjectives:@[L10n(@"mission.objective.first_watch.patrol"),L10n(@"mission.objective.first_watch.scouts")]
            states:@[@0,@1]];
        HUDFrame frame={.speed=125,.throttle=.8,.boostEnergy=.6,.secondary=2,.secondaryCapacity=4,
            .secondaryName=L10n(@"game.weapon.torpedo"),.boresight=PointScale(CGPointMake(size.width,size.height),.5),
            .boresightVisible=YES,.status=L10nFormat(@"mission.scanning",@"NAV 1",@"40")};
        [hud updateFrame:frame targets:NULL count:0];
        NSArray<SKNode *> *rows=hud.conditionRows;
        for (NSUInteger rowIndex=0;rowIndex<rows.count;rowIndex++) {
            SKNode *row=rows[rowIndex];
            CGRect ink=[row calculateAccumulatedFrame];
            CHECK(CGRectGetMinY(ink)>=0 && CGRectGetMaxX(ink)<=size.width);
            if (rowIndex+1<rows.count) CHECK(CGRectGetMaxY(ink)<=CGRectGetMinY([rows[rowIndex+1] calculateAccumulatedFrame])+1);
        }
        [hud showMessage:L10n(@"radio.distress_wing_01") from:@"LANCER 2"];
        CHECK(CGRectContainsRect(CGRectInset(RectWithSize(size),-1,-1),hud.objectivesRect));
        CHECK(!CGRectIntersectsRect(hud.objectivesRect,hud.messagesRect));
        if (configs[i].touch) {
            UITouchControls *touch=[UITouchControls new]; [touch layoutWithSize:size insets:safe];
            [touch displayThrottle:.8]; [touch setSecondaryLabel:L10n(@"game.weapon.torpedo_short")];
            CHECK(!CGRectIntersectsRect(hud.objectivesRect,[UITouchControls pauseRectForSize:size insets:safe]));
            for (NSNumber *control in touch.buttonLabels) {
                SKLabelNode *label=touch.buttonLabels[control];
                CHECK(![(label.attributedText.string ?: label.text) hasSuffix:@"…"]);
                CGRect ink=CGRectOffset(label.frame,label.parent.position.x,label.parent.position.y);
                CHECK(CGRectContainsRect(CGRectInset([touch rectForControl:control.integerValue],-1,-1),ink));
            }
            [hud addChild:touch];
        }
        Save(hud,configs[i].name,configs[i].family,@"flight",safe);
        [hud setHelpVisible:YES];
        CHECK(CGRectContainsRect(CGRectInset(RectWithSize(size),-1,-1),hud.helpRect));
        Save(hud,configs[i].name,configs[i].family,@"flight-help",safe);
    }
    if (VerifyOnly) {
        printf("PASS: localization %s verified all layout configurations.\n",Locale.UTF8String);
        return 0;
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:Entries options:NSJSONWritingPrettyPrinted error:NULL];
    CHECK([data writeToFile:[Output stringByAppendingPathComponent:[Locale stringByAppendingString:@".json"]] atomically:YES]);
    printf("PASS: localization %s rendered %lu fixtures with native glyph fallback.\n",Locale.UTF8String,(unsigned long)SavedCount);
    return 0;
}}
