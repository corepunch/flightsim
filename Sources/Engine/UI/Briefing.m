#import "Briefing.h"
#import "Assets.h"
#import "Progress.h"
#import "UIStyle.h"
#import "UIMotion.h"
#import "GameAudio.h"
#import <ImageIO/ImageIO.h>

static NSValue *BoxPoint(CGPoint point) { return [NSValue value:&point withObjCType:@encode(CGPoint)]; }
static CGPoint UnboxPoint(NSValue *value) {
    CGPoint point = CGPointZero;
    [value getValue:&point size:sizeof(point)];
    return point;
}

static SKLabelNode *Text(CGFloat size, SKColor *c, SKLabelHorizontalAlignmentMode h) {
    return UIMonoLabel(size, c, h, SKLabelVerticalAlignmentModeTop);
}

static SKLabelNode *Para(CGFloat size, SKColor *c, CGFloat width) {
    SKLabelNode *l = Text(size, c, SKLabelHorizontalAlignmentModeLeft);
    l.numberOfLines = 0;
    l.preferredMaxLayoutWidth = width;
    l.lineBreakMode = NSLineBreakByWordWrapping;
    return l;
}

typedef NS_ENUM(NSInteger, Mode) { ModeList, ModeBriefing, ModeDebrief };

typedef struct {
    CGPoint point;
    CGFloat delta;
} ScrollInput;

static const CGFloat ScrollGutter = 10;
static NSString *const PortraitDeparture = @"portraitDeparture";
static NSString *const PlayerPortrait = @"Lancer1";
// Reserve room for the widest portrait canvas (Mira) at the shared height.
static const CGFloat MaxPortraitAspect = 1.04;
static const CGFloat CaptionDrop = 42;
static const CGFloat PortraitDepth = 1, CaptionDepth = 2, FooterDepth = 3;

static SKShader *MonitorDistortionShader(void) {
    static SKShader *shader;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shader = [SKShader shaderWithSource:
            @"float blockNoise(vec2 cell, float packet) {\n"
             "    return fract(sin(dot(cell, vec2(27.31, 53.17)) + packet * 11.53) * 437.23);\n"
             "}\n"
             "void main() {\n"
             "    vec2 uv = v_tex_coord;\n"
             "    float time = u_time * u_motion_rate;\n"
             "    float phase = mod(time, 2.8);\n"
             "    float packet = floor(time / 2.8) * 3.0 + floor(phase * 5.0);\n"
             "    vec2 cell = floor(uv * a_block_grid);\n"
             "    vec2 cluster = floor(cell * 0.5);\n"
             "    float damage = blockNoise(cluster, packet);\n"
             "    float tile = blockNoise(cell + 17.0, packet);\n"
             "    vec4 signal;\n"
             "    if (phase < 0.56 && damage >= 0.82 && tile >= 0.16) {\n"
             // Neighbouring tiles share a motion vector, with some decoded at lower resolution.
             "        vec2 drift = vec2(damage < 0.91 ? -1.0 : 1.0, blockNoise(cluster + 31.0, packet) - 0.5);\n"
             "        vec2 sampleUV = uv + drift * 0.72 / a_block_grid;\n"
             "        if (tile > 0.64) {\n"
             "            vec2 pixels = a_block_grid * 4.0;\n"
             "            sampleUV = (floor(sampleUV * pixels) + 0.5) / pixels;\n"
             "        }\n"
             "        signal = texture2D(u_texture, clamp(sampleUV, 0.0, 1.0));\n"
             // Chroma errors are visible even in the dark parts of the monitor.
             "        float chroma = blockNoise(cluster + 53.0, packet);\n"
             "        vec3 tint = chroma < 0.5 ? vec3(0.31, 0.12, 0.48) : vec3(0.05, 0.40, 0.36);\n"
             "        float opacity = mix(0.13, 0.32, tile);\n"
             "        signal.rgb = min(signal.rgb * (0.65 + tint), vec3(signal.a));\n"
             "        signal = vec4(tint * opacity, opacity) + signal * (1.0 - opacity);\n"
             "    } else {\n"
             "        signal = texture2D(u_texture, uv);\n"
             "    }\n"
             "    gl_FragColor = signal * v_color_mix;\n"
             "}"];
        shader.uniforms = @[[SKUniform uniformWithName:@"u_motion_rate" float:1 / UIMotionTimeScale()]];
        shader.attributes = @[[SKAttribute attributeWithName:@"a_block_grid" type:SKAttributeTypeVectorFloat2]];
    });
    return shader;
}

// How a tactical cue arrives: the map powering up, the map wiped in fresh,
// the same map changing emphasis, or no motion.
typedef NS_ENUM(NSInteger, CueStyle) { CueStyleStill, CueStyleIntro, CueStyleFresh, CueStyleTween };

// One thing on the tactical map.
@interface MapItem : NSObject
@property (nonatomic, copy) NSString *identifier, *group;
@property (nonatomic) BOOL container;
@property (nonatomic) CGPoint point;
@property (nonatomic, strong) SKNode *node;
@end
@implementation MapItem
@end

@interface Briefing () <UIMotionScene>
@end

@implementation Briefing {
    Mode _mode;
    NSUInteger _index;
    BOOL _success;
    NSArray<NSString *> *_results;
    NSUInteger _debriefBeat;
    NSDictionary *_dialogueScene;
    NSArray<NSDictionary *> *_pages;
    NSUInteger _page;
    CGRect _confirmRect, _previousRect, _backRect;
    CGRect _missionRows;
    CGFloat _missionRowHeight;
    NSValue *_queuedClick;
    NSMutableArray<NSValue *> *_queuedScrolls;
    CGRect _scrollRect;
    SKNode *_scrollContent;
    SKSpriteNode *_scrollThumb;
    CGFloat _scrollLimit, _scrollOffset;
    NSMutableDictionary<NSString *, SKTexture *> *_art;
    SKNode *_root;
    CGSize _laidOut;

    // Briefing state
    NSMutableDictionary<NSString *, MapItem *> *_items;
    SKNode *_mapLayer, *_routeLayer;
    SKShapeNode *_focusRing;
    SKNode *_focusLock;
    CGRect _mapRect;
    NSArray<NSValue *> *_routePoints;
    SKShapeNode *_routeLine;

    // Motion. _stage sits at the scene centre so the screen can scale about
    // it; _root and _ghost (outgoing content) undo the offset.
    SKNode *_stage, *_ghost;
    UITransition _transition;
    BOOL _presented;
    NSMutableArray<SKNode *> *_footerNodes;
    // What the previous build put on screen, so the next one can animate
    // from it rather than popping.
    Mode _shownMode;
    NSUInteger _shownIndex;
    CGFloat _shownBarY;
    NSString *_shownChannel, *_shownContent, *_shownFocus, *_shownAction;
    NSArray *_shownRoute;
    NSMutableDictionary<NSString *, NSNumber *> *_shownAlpha;
    SKNode *_portraitLayer;
    NSMutableSet<SKSpriteNode *> *_portraitsToDismiss;
    // The speech bubble on screen, and the one being replaced.
    SKNode *_captionHolder, *_oldCaptionHolder;
    NSArray<SKNode *> *_captionText, *_oldCaptionText;
    CGRect _captionRect, _oldCaptionRect;
    BOOL _captionRight, _oldCaptionRight;
    NSString *_captionSpeaker, *_oldCaptionSpeaker;
    SKLabelNode *_speech;
    UIHover *_hover;
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.backgroundColor = [SKColor clearColor];
        self.speed = 1 / UIMotionTimeScale();
        _hover = [UIHover new];
        _stage = [SKNode node];
        _root = [SKNode node];
        _ghost = [SKNode node];
        _art = [NSMutableDictionary dictionary];
        [_stage addChild:_root];
        [_stage addChild:_ghost];
        [self addChild:_stage];
    }
    return self;
}

- (NSUInteger)selectedIndex { return _index; }

- (BOOL)hasNextBriefingPage { return _page + 1 < _pages.count; }

- (BOOL)compactStoryLayout {
    return MIN(self.size.width, self.size.height) <= 500 &&
           (_mode == ModeBriefing || (_mode == ModeDebrief && _debriefBeat > 0));
}

- (BOOL)intro { return _transition == UITransitionIntro; }
- (BOOL)paging { return _transition == UITransitionPage; }

- (void)dismissPortrait:(SKSpriteNode *)portrait {
    if ([portrait actionForKey:PortraitDeparture]) return;
    [portrait removeAllActions];
    BOOL reduced = UIMotionReduced();
    NSTimeInterval duration = reduced ? 0.1 : ([self paging] ? 0.25 : 0.35);
    CGFloat offset = portrait.position.x <= self.size.width / 2 ? -70 : 70;
    SKAction *fade = [SKAction fadeOutWithDuration:duration];
    SKAction *exit = reduced || [self paging] ? fade : [SKAction group:@[
        fade, UIEased([SKAction moveByX:offset y:0 duration:duration], UICurveIn),
    ]];
    [portrait runAction:[SKAction sequence:@[exit, [SKAction removeFromParent]]] withKey:PortraitDeparture];
}

- (void)rebuild {
    if (_transition != UITransitionNone) {
        _scrollOffset = 0;
        @synchronized (self) { _queuedScrolls = nil; }
    }
    _scrollRect = CGRectZero;
    _scrollContent = nil;
    _scrollThumb = nil;
    _scrollLimit = 0;
    if (!_presented && _transition != UITransitionIntro) _transition = UITransitionNone;
    CGPoint centre = CGPointMake(self.size.width / 2, self.size.height / 2);
    _stage.position = centre;
    _root.position = _ghost.position = CGPointMake(-centre.x, -centre.y);
    if (_transition == UITransitionIntro) {
        [_stage removeAllActions];
        _stage.alpha = 1;
        [_stage setScale:1];
        if (_presented) {
            // Mode change on screen: the old layout dissolves under the new one.
            for (SKNode *node in [_root.children copy]) {
                [node removeFromParent];
                if (node == _portraitLayer) {
                    for (SKSpriteNode *portrait in node.children) {
                        [portrait removeFromParent];
                        [_ghost addChild:portrait];
                        [self dismissPortrait:portrait];
                    }
                } else {
                    [_ghost addChild:node];
                    UIMotionDismiss(node, CGVectorMake(0, 0), 0.24);
                }
            }
        }
        _shownChannel = _shownContent = _shownFocus = _shownAction = nil;
        _shownRoute = nil;
        _shownAlpha = nil;
        _captionHolder = nil;
        _captionText = nil;
        _captionSpeaker = nil;
    }
    // Keep the outgoing speech bubble until the new one decides how to replace it.
    _oldCaptionHolder = _captionHolder;
    _oldCaptionText = _captionText;
    _oldCaptionRect = _captionRect;
    _oldCaptionRight = _captionRight;
    _oldCaptionSpeaker = _captionSpeaker;
    _captionHolder = nil;
    _captionText = nil;
    _captionSpeaker = nil;
    _speech = nil;
    if (_transition == UITransitionPage) {
        for (SKNode *node in [_oldCaptionText arrayByAddingObject:_oldCaptionHolder ?: [SKNode node]]) {
            [node removeFromParent];
            node.zPosition = CaptionDepth;
            [_ghost addChild:node];
        }
    } else {
        _oldCaptionHolder = nil;
        _oldCaptionText = nil;
    }

    // Keep the portrait layer attached through page turns. Only the room,
    // monitor and captions need to be rebuilt.
    if (![self paging]) {
        [_portraitLayer removeFromParent];
        _portraitLayer = [SKNode node];
        _portraitLayer.zPosition = PortraitDepth;
    }
    _portraitsToDismiss = [NSMutableSet setWithArray:_portraitLayer.children];
    for (SKNode *node in _root.children)
        if (node != _portraitLayer) [node removeFromParent];
    [_hover reset];
    _footerNodes = [NSMutableArray array];
    _confirmRect = _previousRect = _backRect = CGRectZero;
    _missionRows = CGRectZero;
    _laidOut = self.size;
    _focusLock = nil;
    _routeLine = nil;
    BOOL illustrated = _mode == ModeBriefing || (_mode == ModeDebrief && _debriefBeat > 0);
    // Backgrounds are sprites, not the scene colour, so the screen can fade as a whole.
    SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:illustrated ? UIColorWithOpacity(UIBackground, 1)
                                                           : UIColorWithOpacity(UIBlack, 0.72) size:self.size];
    shade.anchorPoint = CGPointZero;
    [_root addChild:shade];
    if ([self intro] && (_shownMode != _mode || !illustrated || !_presented) && !UIMotionReduced()) {
        shade.alpha = 0;
        [shade runAction:[SKAction fadeInWithDuration:0.25]];
    }
    switch (_mode) {
        case ModeList: [self buildList]; break;
        case ModeBriefing: [self buildBriefing]; break;
        case ModeDebrief: [self buildDebrief]; break;
    }
    for (SKSpriteNode *portrait in _portraitsToDismiss) [self dismissPortrait:portrait];
    _portraitsToDismiss = nil;
    // A bubble that has no successor closes where it stood.
    [self closeOldCaption];
    _shownMode = _mode;
    _transition = UITransitionNone;
    [self scrollBy:0];
}

- (NSTimeInterval)closeOldCaption {
    if (!_oldCaptionHolder && !_oldCaptionText) return 0;
    for (SKNode *text in _oldCaptionText) UIMotionDismiss(text, CGVectorMake(0, 0), 0.1);
    NSTimeInterval closing = _oldCaptionHolder
        ? UIMotionClosePanel(_oldCaptionHolder, _oldCaptionRect, UIColorWithOpacity(UIAmber, 0.9), _oldCaptionRight) : 0.1;
    _oldCaptionHolder = nil;
    _oldCaptionText = nil;
    return closing;
}

#pragma mark - Scrollable text

// Measure before the reveal animations change the labels' frames.
- (SKNode *)textViewport:(CGRect)rect content:(SKNode *)content {
    SKNode *viewport = [SKNode node];
    if (CGRectIsEmpty(rect)) return viewport;
    SKCropNode *crop = [SKCropNode node];
    SKSpriteNode *mask = [SKSpriteNode spriteNodeWithColor:SKColor.whiteColor size:rect.size];
    mask.position = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    crop.maskNode = mask;
    [crop addChild:content];
    [viewport addChild:crop];

    CGFloat overflow = CGRectGetMinY(rect) - CGRectGetMinY([content calculateAccumulatedFrame]);
    if (overflow <= 0.5) return viewport;
    _scrollRect = rect;
    _scrollContent = content;
    _scrollLimit = overflow;
    CGFloat height = CGRectGetHeight(rect), x = CGRectGetMaxX(rect) - 2;
    SKSpriteNode *track = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.22)
                                                      size:CGSizeMake(2, height)];
    track.position = CGPointMake(x, CGRectGetMidY(rect));
    [viewport addChild:track];
    CGFloat thumbHeight = MIN(height, MAX(12, height * height / (height + overflow)));
    _scrollThumb = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.8)
                                               size:CGSizeMake(3, thumbHeight)];
    _scrollThumb.position = CGPointMake(x, 0);
    _scrollThumb.zPosition = 1;
    [viewport addChild:_scrollThumb];
    return viewport;
}

- (void)scrollBy:(CGFloat)delta {
    _scrollOffset = MIN(_scrollLimit, MAX(0, _scrollOffset + delta));
    if (!_scrollContent) return;
    _scrollContent.position = CGPointMake(0, _scrollOffset);
    CGFloat thumbHeight = _scrollThumb.size.height;
    CGFloat y = CGRectGetMaxY(_scrollRect) - thumbHeight / 2
              - (CGRectGetHeight(_scrollRect) - thumbHeight) * _scrollOffset / _scrollLimit;
    _scrollThumb.position = CGPointMake(_scrollThumb.position.x, y);
}

#pragma mark - Mission list

- (void)showListSelecting:(NSUInteger)index {
    _transition = _mode == ModeList && _presented ? UITransitionSelect : UITransitionIntro;
    _mode = ModeList;
    _index = MIN(index, CampaignMissions().count - 1);
    [self rebuild];
}

- (void)buildList {
    CGSize s = self.size;
    CGFloat top = s.height - 50;
    SKLabelNode *t = Text(30, UIColorWithOpacity(UIInk, 1), SKLabelHorizontalAlignmentModeLeft);
    t.fontName = UIMonoBoldFont;
    t.text = @"KESTREL FRONTIER";
    t.position = CGPointMake(60, top);
    [_root addChild:t];
    SKLabelNode *sub = Text(15, UIColorWithOpacity(UIInk, 0.6), SKLabelHorizontalAlignmentModeLeft);
    sub.text = @"CNS BASTION  /  LANCER FLIGHT  /  MISSION SELECT";
    sub.position = CGPointMake(60, top - 40);
    [_root addChild:sub];

    NSArray *all = CampaignMissions();
    NSUInteger unlocked = ProgressUnlockedCount();
    CGFloat rowH = MAX(1, MIN(30, (s.height - 220) / MAX(all.count, 1)));
    CGFloat listW = MIN(520, s.width * 0.42);
    _missionRowHeight = rowH;
    _missionRows = CGRectMake(50, top - 90 - all.count * rowH, listW, all.count * rowH);
    NSMutableArray<SKLabelNode *> *rows = [NSMutableArray array];
    SKNode *bar = nil;
    for (NSUInteger i = 0; i < all.count; i++) {
        BOOL open = i < unlocked, sel = i == _index;
        CGFloat y = top - 90 - i * rowH;
        if (sel) {
            CGRect barRect = CGRectMake(50, y - rowH + 4, listW, rowH - 2);
            SKShapeNode *shape = UISkewedShape(barRect, UIColorWithOpacity(UIInk, 0.8), UIColorWithOpacity(UIInk, 0.12));
            [_root addChild:shape];
            bar = UIMotionPivot(shape, CGPointMake(CGRectGetMinX(barRect), CGRectGetMidY(barRect)));
        }
        SKLabelNode *l = Text(MIN(17, rowH * 0.6), open ? (sel ? UIColorWithOpacity(UIInk, 1) : UIColorWithOpacity(UIInk, 0.75)) : UIColorWithOpacity(UIInk, 0.25), SKLabelHorizontalAlignmentModeLeft);
        l.text = [NSString stringWithFormat:@"%02lu   %@", (unsigned long)i + 1, open ? [all[i][@"title"] uppercaseString] : @"-- CLASSIFIED --"];
        l.position = CGPointMake(64, y - 4);
        [_root addChild:l];
        [rows addObject:l];
    }

    // Preview of the selected mission.
    NSDictionary *m = all[_index];
    BOOL open = _index < unlocked;
    CGFloat px = listW + 100, pw = s.width - px - 60;
    CGRect panelRect = CGRectMake(px - 20, 90, pw + 20, top - 160);
    SKShapeNode *panel = UIReadoutPanel(panelRect, UIColorWithOpacity(UIInk, 0.4), UIColorWithOpacity(UIBlack, 0.35));
    [_root addChild:panel];
    CGRect viewport = CGRectMake(px, CGRectGetMinY(panelRect) + 14,
                                 MAX(0, pw - 14), MAX(0, panelRect.size.height - 34));
    CGFloat width = MAX(1, viewport.size.width - ScrollGutter);
    SKNode *preview = [SKNode node];
    SKLabelNode *title = Para(24, UIColorWithOpacity(UIInk, 1), width);
    title.fontName = UIMonoBoldFont;
    title.text = open ? [m[@"title"] uppercaseString] : @"CLASSIFIED";
    title.position = CGPointMake(px, CGRectGetMaxY(viewport));
    [preview addChild:title];
    SKLabelNode *loc = nil, *p, *objs = nil;
    if (open) {
        NSDictionary *b = m[@"briefing"];
        loc = Para(15, UIColorWithOpacity(UIAmber, 0.9), width);
        loc.text = [NSString stringWithFormat:@"%@   /   SD %@", b[@"location"], b[@"stardate"]];
        loc.position = CGPointMake(px, CGRectGetMinY(title.frame) - 12);
        [preview addChild:loc];
        p = Para(16, UIColorWithOpacity(UIInk, 0.8), width);
        p.text = [b[@"text"] firstObject];
        p.position = CGPointMake(px, CGRectGetMinY(loc.frame) - 16);
        [preview addChild:p];
        objs = Para(15, UIColorWithOpacity(UIInk, 0.65), width);
        NSMutableString *o = [NSMutableString stringWithString:@"OBJECTIVES"];
        for (NSDictionary *d in m[@"objectives"]) [o appendFormat:@"\n  %@ %@", [d[@"optional"] boolValue] ? @"o" : @">", d[@"text"]];
        objs.text = o;
        objs.position = CGPointMake(px, CGRectGetMinY(p.frame) - 20);
        [preview addChild:objs];
    } else {
        p = Para(16, UIColorWithOpacity(UIInk, 0.5), width);
        p.text = @"Complete the previous missions to unlock this briefing.";
        p.position = CGPointMake(px, CGRectGetMinY(title.frame) - 16);
        [preview addChild:p];
    }
    [_root addChild:[self textViewport:viewport content:preview]];
    [self footer:_scrollLimit > 0 ? @"↑ / ↓  Select mission     ← / →  Scroll preview" : @"↑ / ↓  Select mission"
          action:open ? @"BRIEFING" : nil];

    CGFloat barY = top - 90 - _index * rowH;
    if ([self intro]) {
        UIMotionDecode(t, 0.05, 0.45);
        UIMotionDecode(sub, 0.12, 0.5);
        for (NSUInteger i = 0; i < rows.count; i++) {
            UIMotionSlideIn(rows[i], CGVectorMake(-24, 0), 0.16 + i * 0.03, 0.28);
            UIMotionDecode(rows[i], 0.16 + i * 0.03, 0.3);
        }
        if (bar && !UIMotionReduced()) {
            bar.xScale = 0.001;
            [bar runAction:UIAfter(0.28 + _index * 0.03, UIEased([SKAction scaleXTo:1 duration:0.3], UICurveOutExpo))];
        }
        NSTimeInterval ready = 0;
        UIMotionDrawPanel(panel, panelRect, UIColorWithOpacity(UIInk, 0.8), NO, 0.2, &ready);
        [self revealPreviewTitle:title location:loc text:p objectives:objs at:ready];
    } else if (_transition == UITransitionSelect) {
        // The highlight glides to the new row; the preview re-decodes.
        if (bar && !UIMotionReduced() && _shownMode == ModeList) {
            CGPoint home = bar.position;
            bar.position = CGPointMake(home.x, home.y + (_shownBarY - barY));
            [bar runAction:UIEased([SKAction moveTo:home duration:0.16], UICurveOut)];
        }
        if (_index < rows.count) UIMotionGlitchBurst(rows[_index], 0.16, 0.5, UIColorWithOpacity(UIAmber, 1));
        UIMotionSweep(_root, CGRectInset(panelRect, 2, 2), UIColorWithOpacity(UIInk, 0.35), YES, 0, 0.4);
        [self revealPreviewTitle:title location:loc text:p objectives:objs at:0];
    }
    _shownBarY = barY;
    _shownIndex = _index;
}

- (void)revealPreviewTitle:(SKLabelNode *)title location:(SKLabelNode *)location text:(SKLabelNode *)text
                objectives:(SKLabelNode *)objectives at:(NSTimeInterval)t {
    UIMotionDecode(title, t, 0.32);
    if (location) UIMotionDecode(location, t + 0.06, 0.32);
    NSTimeInterval typed = UIMotionTypeOn(text, t + 0.1, 260);
    if (objectives) UIMotionSlideIn(objectives, CGVectorMake(0, 8), MIN(typed, t + 0.45), 0.25);
}

- (void)footer:(NSString *)text action:(NSString *)action {
    [self buildFooter:text action:action];
    SKNode *confirm = action && [_footerNodes.lastObject isKindOfClass:SKShapeNode.class] ? _footerNodes.lastObject : nil;
    if ([self intro]) {
        NSUInteger i = 0;
        for (SKNode *node in _footerNodes) {
            if ([node isKindOfClass:SKLabelNode.class]) UIMotionFlickerIn(node, 0.45);
            else UIMotionSlideIn(node, CGVectorMake(0, -44), 0.18 + 0.05 * i++, 0.32);
        }
    } else if ([self paging] && action && _shownAction && ![action isEqualToString:_shownAction] && confirm) {
        // The footer action changed: the button re-strikes.
        for (SKNode *child in confirm.children)
            if ([child isKindOfClass:SKLabelNode.class]) UIMotionDecode((SKLabelNode *)child, 0, 0.3);
        UIMotionFlickerIn(confirm, 0);
    }
    _shownAction = action;
}

- (SKNode *)footerAdd:(SKNode *)node {
    node.zPosition = FooterDepth;
    [_root addChild:node];
    [_footerNodes addObject:node];
    return node;
}

- (SKNode *)footerButton:(CGRect)rect title:(NSString *)title accent:(UIRGB)accent {
    SKNode *button = [self footerAdd:UIActionButton(rect, title, accent)];
    [_hover addButton:button rect:rect accent:accent];
    return button;
}

- (void)buildFooter:(NSString *)text action:(NSString *)action {
    CGFloat inset = MIN(50, self.size.width * 0.05);
    BOOL console = _mode == ModeBriefing || (_mode == ModeDebrief && _debriefBeat > 0);
    if ([self compactStoryLayout]) {
        CGFloat bottom = 16, height = 44;
        _backRect = CGRectMake(inset, bottom, 84, height);
        [self footerButton:_backRect title:@"MISSIONS" accent:UIAmber];
        BOOL hasPrevious = _mode == ModeBriefing ? _page > 0 : _debriefBeat > 0;
        if (hasPrevious) {
            _previousRect = CGRectMake(CGRectGetMaxX(_backRect) + 8, bottom, 44, height);
            [self footerButton:_previousRect title:@"←" accent:UIAmber];
        }
        CGFloat width = MIN(144, self.size.width * 0.38);
        _confirmRect = CGRectMake(self.size.width - inset - width, bottom, width, height);
        NSString *label = [action stringByReplacingOccurrencesOfString:@"↵  " withString:@""];
        [self footerButton:_confirmRect title:label accent:UIAmber];
        return;
    }
    CGRect rail = CGRectMake(inset - 10, 14, self.size.width - 2 * inset + 20, 52);
    [self footerAdd:UIControlRail(rail, console)];
    CGFloat hintLeft = inset + 8;
    if (_mode == ModeList) {
        _backRect = CGRectMake(inset, 20, 140, 40);
        [self footerButton:_backRect title:@"‹  MAIN MENU" accent:UIInk];
        hintLeft = CGRectGetMaxX(_backRect) + 18;
    }
    SKLabelNode *hint = Para(12, UIColorWithOpacity(UIInk, console ? 0.9 : 0.65),
                             MAX(1, self.size.width - inset - hintLeft - (action ? 200 : 0)));
    hint.text = text;
    hint.verticalAlignmentMode = SKLabelVerticalAlignmentModeCenter;
    hint.position = CGPointMake(hintLeft, 40);
    [self footerAdd:hint];
    if (!action) return;

    _confirmRect = CGRectMake(self.size.width - inset - 180, 20, 180, 40);
    [self footerButton:_confirmRect title:action accent:console ? UIAmber : UIInk];
}

#pragma mark - Briefing

- (void)showBriefing:(NSUInteger)index {
    _index = MIN(index, CampaignMissions().count - 1);
    NSDictionary *mission = CampaignMission(_index);
    NSDictionary *brief = mission[@"briefing"];
    _dialogueScene = brief[@"dialogue"];
    NSString *speaker = brief[@"speaker"] ?: @"Bastion Control";
    NSString *portrait = [speaker containsString:@"Okafor"] ? @"Okafor" : @"Varn";
    NSMutableArray<NSDictionary *> *pages = [NSMutableArray array];
    for (NSDictionary *line in _dialogueScene[@"lines"]) {
        NSMutableDictionary *page = [line mutableCopy];
        page[@"channel"] = line[@"channel"] ?: @"MISSION BRIEFING";
        page[@"dialogue"] = @YES;
        [pages addObject:page];
    }

    // The mission's original briefing is the officer's speech. Each tactical
    // cue and each readout gets its own beat on the same wall monitor.
    for (NSString *text in brief[@"text"]) {
        [pages addObject:@{ @"speaker": speaker, @"portrait": portrait,
                            @"text": text, @"channel": @"SITUATION" }];
    }
    for (NSDictionary *step in brief[@"steps"]) {
        [pages addObject:@{ @"speaker": speaker, @"portrait": portrait, @"tactical": step,
                            @"text": step[@"caption"] ?: @"",
                            @"channel": step[@"schematic"] ? @"TARGET SCHEMATIC" : @"FLIGHT PLAN" }];
    }

    NSMutableArray<NSString *> *orders = [NSMutableArray array];
    for (NSDictionary *objective in mission[@"objectives"]) {
        [orders addObject:[NSString stringWithFormat:@"%@%@", objective[@"text"],
                           [objective[@"optional"] boolValue] ? @" (optional)" : @""]];
    }
    if (orders.count) {
        [pages addObject:@{ @"speaker": speaker, @"portrait": portrait, @"readout": orders,
                            @"text": @"Your orders are on the board, Lancer.", @"channel": @"OBJECTIVES" }];
    }
    int torpedoes = [mission[@"loadout"][@"torpedoes"] intValue];
    NSString *loadout = [NSString stringWithFormat:@"Loadout: twin lasers, %d torpedo%@", torpedoes, torpedoes == 1 ? @"" : @"es"];
    NSArray *intel = [(brief[@"intel"] ?: @[]) arrayByAddingObject:loadout];
    [pages addObject:@{ @"speaker": speaker, @"portrait": portrait, @"readout": intel,
                        @"text": @"Check the intel and your loadout. Launch when ready.", @"channel": @"INTEL / LOADOUT" }];
    _pages = pages;
    const char *startPage = getenv("SF_BRIEFING_PAGE");   // debug: open on page N
    _page = startPage && atoi(startPage) >= 1 ? MIN((NSUInteger)atoi(startPage) - 1, pages.count - 1) : 0;
    _mode = ModeBriefing;
    _transition = UITransitionIntro;
    [self rebuild];
}

- (SKTexture *)artTextureNamed:(NSString *)name {
    SKTexture *texture = _art[name];
    if (!texture) {
        NSString *subdirectory = [@"Briefing" stringByAppendingPathComponent:name.stringByDeletingLastPathComponent];
        NSURL *url = [[NSBundle mainBundle] URLForResource:name.lastPathComponent
                                            withExtension:@"png" subdirectory:subdirectory];
        CGImageSourceRef source = url ? CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL) : NULL;
        if (!source) return nil;
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!image) return nil;
        texture = [SKTexture textureWithCGImage:image];
        CGImageRelease(image);
        _art[name] = texture;
    }
    return texture;
}

- (SKSpriteNode *)artNamed:(NSString *)name {
    SKTexture *texture = [self artTextureNamed:name];
    return texture ? [SKSpriteNode spriteNodeWithTexture:texture] : nil;
}

// Return the painted monitor's position after an aspect-fill crop. The
// coordinates describe the inside of the cyan bezel in Bastion.png.
- (CGRect)addBackdrop:(NSString *)name raiseBoard:(BOOL)raiseBoard {
    CGSize size = self.size;
    SKSpriteNode *art = [self artNamed:name];
    if (!art) return CGRectZero;
    const CGFloat boardBottom = 0.465, boardHeight = 0.375;
    CGFloat scale = MAX(size.width / art.size.width, size.height / art.size.height * (raiseBoard ? 1.15 : 1));
    CGFloat centerY = size.height / 2;
    if (raiseBoard) {
        CGFloat artHeight = art.size.height * scale;
        // Give the caption more room while keeping the top of the monitor visible.
        CGFloat boardTop = artHeight * (boardBottom + boardHeight);
        CGFloat originY = MIN(0, size.height * 0.96 - boardTop);
        centerY = MAX(centerY, originY + artHeight / 2);
    }
    [art setScale:scale];
    art.position = CGPointMake(size.width / 2, centerY);
    CGRect frame = art.frame;
    [_root addChild:art];
    if ([self intro] && !UIMotionReduced()) {
        art.alpha = 0;
        [art setScale:scale * 1.04];
        [art runAction:[SKAction group:@[
            UIEased([SKAction fadeInWithDuration:0.5], UICurveOut),
            UIEased([SKAction scaleTo:scale duration:0.9], UICurveOut),
        ]]];
    }
    SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIBlack, 0.12) size:size];
    shade.anchorPoint = CGPointZero;
    [_root addChild:shade];

    return CGRectMake(frame.origin.x + frame.size.width * 0.25,
                      frame.origin.y + frame.size.height * boardBottom,
                      frame.size.width * 0.50, frame.size.height * boardHeight);
}

- (void)addPortrait:(NSString *)name expression:(NSString *)expression facingRight:(BOOL)facingRight
              active:(BOOL)active inRect:(CGRect)area {
    SKTexture *texture = expression ? [self artTextureNamed:[NSString stringWithFormat:@"Expressions/%@-%@", name, expression]] : nil;
    if (!texture) texture = [self artTextureNamed:name];
    if (!texture) return;
    if (!_portraitLayer.parent) [_root addChild:_portraitLayer];
    CGFloat dim = active ? 0 : 0.38;
    CGPoint home = CGPointMake(CGRectGetMidX(area), CGRectGetMinY(area));
    SKSpriteNode *existing = (SKSpriteNode *)[_portraitLayer childNodeWithName:name];
    if (existing) {
        existing.texture = texture;
        [_portraitsToDismiss removeObject:existing];
        if ([existing actionForKey:PortraitDeparture]) {
            [existing removeActionForKey:PortraitDeparture];
            BOOL reduced = UIMotionReduced();
            SKAction *fade = [SKAction fadeInWithDuration:reduced ? 0.1 : 0.25];
            [existing runAction:reduced ? fade : [SKAction group:@[
                fade, UIEased([SKAction moveTo:home duration:0.25], UICurveOut),
            ]]];
        }
        [existing runAction:[SKAction colorizeWithColorBlendFactor:dim duration:0.25] withKey:@"speakerFade"];
        return;
    }

    SKSpriteNode *portrait = [SKSpriteNode spriteNodeWithTexture:texture];
    portrait.name = name;
    // Both sides use the same height budget, regardless of the current cast.
    CGFloat height = MIN(area.size.height, area.size.width / MaxPortraitAspect);
    CGFloat scale = height / portrait.size.height;
    [portrait setScale:scale];
    BOOL sourceFacesRight = ![name isEqualToString:PlayerPortrait] &&
                            ![name isEqualToString:@"Lancer5"] && ![name isEqualToString:@"Lancer6"] &&
                            ![name isEqualToString:@"Okafor"] && ![name isEqualToString:@"MiraCaptain"];
    if (sourceFacesRight != facingRight) portrait.xScale = -scale;
    portrait.anchorPoint = CGPointMake(0.5, 0);
    portrait.position = home;
    portrait.color = UIColorWithOpacity(UIBackground, 1);
    portrait.colorBlendFactor = dim;
    [_portraitLayer addChild:portrait];
    if ([self intro]) {
        UIMotionSlideIn(portrait, CGVectorMake(facingRight ? -70 : 70, 0), 0.15, 0.5);
    } else if ([self paging]) {
        portrait.alpha = 0;
        [portrait runAction:[SKAction fadeInWithDuration:UIMotionReduced() ? 0.1 : 0.25]];
    }
}

- (BOOL)addPortraitsForLine:(NSDictionary *)line speakerArea:(CGRect)speakerArea playerArea:(CGRect)playerArea {
    BOOL playerSpeaking = [line[@"portrait"] isEqualToString:PlayerPortrait];
    NSString *other = playerSpeaking ? line[@"listener"] : line[@"portrait"];
    NSString *expression = line[@"expression"];
    NSString *listenerExpression = line[@"listenerExpression"];
    if (other) {
        [self addPortrait:other expression:playerSpeaking ? listenerExpression : expression
              facingRight:YES active:!playerSpeaking inRect:speakerArea];
    }
    [self addPortrait:PlayerPortrait expression:playerSpeaking ? expression : listenerExpression
          facingRight:NO active:playerSpeaking inRect:playerArea];
    return playerSpeaking;
}

- (CGFloat)captionTextHeightForLines:(NSArray<NSDictionary *> *)lines width:(CGFloat)width fontSize:(CGFloat)fontSize {
    SKLabelNode *speech = Para(fontSize, UIColorWithOpacity(UIWhite, 1), MAX(1, width - 32));
    speech.fontName = UIBodyFont;
    CGFloat height = 0;
    for (NSDictionary *line in lines) {
        speech.text = line[@"text"];
        height = MAX(height, speech.frame.size.height);
    }
    return height;
}

- (void)addCaption:(NSDictionary *)line inRect:(CGRect)rect fontSize:(CGFloat)fontSize
      speakerOnRight:(BOOL)speakerOnRight {
    SKNode *layer = [SKNode node];
    layer.zPosition = CaptionDepth;
    [_root addChild:layer];
    SKShapeNode *panel = UIReadoutPanel(rect, UIColorWithOpacity(UIConsoleEdge, 0.95),
                                        UIColorWithOpacity(UIConsoleSteel, 0.95));
    [layer addChild:panel];
    CGFloat left = CGRectGetMinX(rect) + 16, top = CGRectGetMaxY(rect);
    CGFloat width = MAX(1, rect.size.width - 32);
    SKLabelNode *speaker = Text(13, UIColorWithOpacity(UIAmber, 1),
                               speakerOnRight ? SKLabelHorizontalAlignmentModeRight : SKLabelHorizontalAlignmentModeLeft);
    speaker.fontName = UIMonoBoldFont;
    speaker.text = [line[@"speaker"] uppercaseString];
    if (speaker.frame.size.width > width) {
        // Keep the name when the full rank and posting won't fit.
        speaker.text = [speaker.text componentsSeparatedByString:@","].firstObject;
        if (speaker.frame.size.width > width) speaker.fontSize *= width / speaker.frame.size.width;
    }
    speaker.position = CGPointMake(speakerOnRight ? CGRectGetMaxX(rect) - 16 : left, top - 10);
    [layer addChild:speaker];

    SKLabelNode *speech = Para(fontSize, UIColorWithOpacity(UIWhite, 1), width);
    speech.fontName = UIBodyFont;
    speech.text = line[@"text"];
    speech.position = CGPointMake(left, top - 32);
    [layer addChild:speech];

    // The bubble hangs from its top edge, which stays put between lines.
    SKNode *holder;
    const CGFloat charsPerSecond = 80;
    BOOL continuing = [self paging] && _oldCaptionHolder && _oldCaptionRight == speakerOnRight &&
                      [_oldCaptionSpeaker isEqualToString:line[@"speaker"]] &&
                      fabs(CGRectGetMaxY(_oldCaptionRect) - top) < 1 && fabs(_oldCaptionRect.size.width - rect.size.width) < 1;
    if (continuing) {
        // Same voice, next line: the bubble resizes in place and the new line types in.
        holder = UIMotionPivot(panel, CGPointMake(CGRectGetMidX(rect), top));
        if (!UIMotionReduced()) {
            holder.yScale = _oldCaptionRect.size.height / MAX(1, rect.size.height);
            [holder runAction:UIEased([SKAction scaleYTo:1 duration:0.2], UICurveOut)];
        }
        [_oldCaptionHolder removeFromParent];
        [_oldCaptionText.firstObject removeFromParent];
        if (_oldCaptionText.count > 1) UIMotionDismiss(_oldCaptionText.lastObject, CGVectorMake(0, 0), 0.1);
        _oldCaptionHolder = nil;
        _oldCaptionText = nil;
        UIMotionTypeOn(speech, 0.06, charsPerSecond);
    } else if ([self intro] || [self paging]) {
        // A new voice: the old bubble folds away, then a beam draws the new
        // one out from the speaker's side.
        NSTimeInterval closing = [self closeOldCaption];
        NSTimeInterval ready = 0;
        holder = UIMotionDrawPanel(panel, rect, UIColorWithOpacity(UIAmber, 0.9), speakerOnRight,
                                   [self intro] ? 0.45 : closing * 0.8, &ready);
        UIMotionDecode(speaker, ready, 0.3);
        UIMotionTypeOn(speech, ready + 0.05, charsPerSecond);
    } else {
        holder = UIMotionPivot(panel, CGPointMake(CGRectGetMidX(rect), top));
    }
    _captionHolder = holder;
    _captionText = @[speaker, speech];
    _captionRect = rect;
    _captionRight = speakerOnRight;
    _captionSpeaker = line[@"speaker"];
    _speech = speech;
}

- (void)buildBriefing {
    CGSize size = self.size;
    NSDictionary *mission = CampaignMission(_index);
    NSDictionary *page = _pages[_page];
    CGFloat textSize = MIN(24, MAX(14, size.width / 60));
    BOOL narrow = size.width < size.height * 1.24;
    BOOL compact = [self compactStoryLayout];
    CGFloat floor = compact ? 64 : 70;

    CGRect screen = [self addBackdrop:_dialogueScene[@"room"] ?: @"Bastion" raiseBoard:compact && !narrow];
    BOOL paintedBoard = !narrow && !CGRectIsEmpty(screen);
    if (!paintedBoard) {
        CGFloat margin = size.width * 0.06;
        screen = CGRectMake(margin, size.height * 0.59, size.width - margin * 2, size.height * 0.34);
        [_root addChild:UIReadoutPanel(screen, UIColorWithOpacity(UIConsoleEdge, 0.95),
                                      UIColorWithOpacity(UIConsoleGlass, 1))];
    }

    CGFloat captionWidth = screen.size.width * 0.70;
    const CGFloat captionPadding = 44; // Speaker header and bottom inset.
    CGFloat tallestCaption = [self captionTextHeightForLines:_pages width:captionWidth fontSize:textSize] + captionPadding;
    // Leave a gap below the monitor while keeping the caption above the footer.
    CGFloat captionTop = CGRectGetMinY(screen) + (paintedBoard ? 0 : 3) - CaptionDrop;
    while (tallestCaption > captionTop - floor && textSize > 12) {
        textSize = MAX(12, textSize - 1);
        tallestCaption = [self captionTextHeightForLines:_pages width:captionWidth fontSize:textSize] + captionPadding;
    }
    CGFloat captionHeight = [self captionTextHeightForLines:@[page] width:captionWidth fontSize:textSize] + captionPadding;
    CGFloat captionBottom = MAX(floor, captionTop - captionHeight);

    _focusRing = nil;
    [self buildMonitor:screen mission:mission page:page];

    CGFloat wing = CGRectGetMinX(screen);
    CGRect speakerArea, playerArea;
    if (narrow) {
        CGFloat height = MAX(floor, captionTop - tallestCaption) + 6;
        speakerArea = CGRectMake(0, 0, size.width / 2, height);
        playerArea = CGRectOffset(speakerArea, size.width / 2, 0);
    } else {
        CGFloat width = MIN(size.width * 0.31, wing * 1.45);
        CGFloat bottom = compact ? 0 : floor - 10;
        CGFloat height = MAX(1, size.height - bottom - 48);
        CGFloat center = wing * 0.65;
        speakerArea = CGRectMake(center - width / 2, bottom, width, height);
        playerArea = CGRectMake(size.width - center - width / 2, bottom, width, height);
    }
    BOOL playerSpeaking = [self addPortraitsForLine:page speakerArea:speakerArea playerArea:playerArea];

    [self addCaption:page inRect:CGRectMake(CGRectGetMinX(screen), captionBottom, captionWidth, captionHeight)
             fontSize:textSize speakerOnRight:playerSpeaking];
    [self footer:@"Click or ← / →  Browse briefing     Esc  Missions"
           action:[self hasNextBriefingPage] ? @"SKIP" : @"↵  LAUNCH"];
}

- (void)buildMonitor:(CGRect)screen mission:(NSDictionary *)mission page:(NSDictionary *)page {
    SKNode *display = _root;
    if (!CGRectIsEmpty(screen) && !UIMotionReduced()) {
        CGPoint center = CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen));
        SKCropNode *crop = [SKCropNode node];
        SKSpriteNode *mask = [SKSpriteNode spriteNodeWithColor:SKColor.whiteColor size:screen.size];
        mask.position = center;
        crop.maskNode = mask;
        [_root addChild:crop];

        SKEffectNode *effect = [SKEffectNode node];
        effect.shader = MonitorDistortionShader();
        CGFloat blockSize = MAX(10, screen.size.height / 14);
        vector_float2 grid = { screen.size.width / blockSize, screen.size.height / blockSize };
        [effect setValue:[SKAttributeValue valueWithVectorFloat2:grid] forAttributeNamed:@"a_block_grid"];
        effect.shouldEnableEffects = YES;
        [crop addChild:effect];
        // Give the effect a screen-sized buffer even while the content animates in.
        SKSpriteNode *glass = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIConsoleGlass, 0.01)
                                                          size:screen.size];
        glass.position = center;
        [effect addChild:glass];
        display = effect;
    }

    NSDictionary *brief = mission[@"briefing"];
    CGFloat pad = MIN(22, screen.size.width * 0.04);
    CGFloat left = CGRectGetMinX(screen) + pad, right = CGRectGetMaxX(screen) - pad;
    CGFloat top = CGRectGetMaxY(screen) - 5;
    CGFloat width = MAX(1, right - left);
    CGFloat titleSize = MIN(21, MAX(12, width / 29));
    SKLabelNode *title = Para(titleSize, UIColorWithOpacity(UIInk, 1), width);
    title.fontName = UIMonoBoldFont;
    title.text = [NSString stringWithFormat:@"%02lu  /  %@", (unsigned long)_index + 1, [mission[@"title"] uppercaseString]];
    title.position = CGPointMake(left, top);
    [display addChild:title];

    SKLabelNode *location = Para(MIN(13, MAX(9, width / 45)), UIColorWithOpacity(UIInk, 0.75), width);
    location.text = [NSString stringWithFormat:@"%@  /  SD %@", brief[@"location"], brief[@"stardate"]];
    location.position = CGPointMake(left, CGRectGetMinY(title.frame) - 4);
    [display addChild:location];

    CGFloat channelY = CGRectGetMinY(location.frame) - 10;
    SKLabelNode *channel = Text(12, UIColorWithOpacity(UIAmber, 1), SKLabelHorizontalAlignmentModeLeft);
    channel.fontName = UIMonoBoldFont;
    channel.text = page[@"channel"];
    channel.position = CGPointMake(left, channelY);
    [display addChild:channel];
    SKLabelNode *counter = Text(12, UIColorWithOpacity(UIInk, 0.7), SKLabelHorizontalAlignmentModeRight);
    counter.text = [NSString stringWithFormat:@"%02lu / %02lu", (unsigned long)_page + 1, (unsigned long)_pages.count];
    counter.position = CGPointMake(right, channelY);
    [display addChild:counter];

    CGFloat contentTop = CGRectGetMinY(channel.frame) - 8;
    CGFloat bottom = CGRectGetMinY(screen) + 4;
    CGRect contentRect = CGRectMake(CGRectGetMinX(screen), bottom, screen.size.width, MAX(1, contentTop - bottom));
    NSString *kind = nil;
    SKNode *content = [self buildMonitorContent:mission page:page left:left right:right top:contentTop
                                         bottom:bottom kind:&kind];
    [display addChild:content];
    BOOL map = [kind hasPrefix:@"map"];
    BOOL fresh = ![kind isEqualToString:_shownContent];

    if ([self intro]) {
        UIMotionSweep(_root, screen, UIColorWithOpacity(UIInk, 0.5), YES, 0.1, 0.6);
        UIMotionDecode(title, 0.25, 0.5);
        UIMotionDecode(location, 0.32, 0.45);
        UIMotionDecode(channel, 0.4, 0.35);
        UIMotionDecode(counter, 0.4, 0.35);
        if (!map && content) UIMotionWipe(content, contentRect, UIColorWithOpacity(UIInk, 0.7), 0.45, 0.45);
    } else if ([self paging]) {
        if (![page[@"channel"] isEqual:_shownChannel]) UIMotionDecode(channel, 0, 0.3);
        UIMotionDecode(counter, 0, 0.2);
        if (fresh && content) UIMotionWipe(content, contentRect, UIColorWithOpacity(UIInk, 0.7), 0.04, 0.38);
    }
    if (map) {
        NSDictionary *step = page[@"tactical"];
        NSString *dialogueFocus = _dialogueScene[@"focus"];
        if (!step && [page[@"dialogue"] boolValue] && dialogueFocus) step = @{ @"show": @[dialogueFocus], @"focus": dialogueFocus };
        CueStyle style = [self intro] ? CueStyleIntro : (![self paging] ? CueStyleStill : (fresh ? CueStyleFresh : CueStyleTween));
        [self applyTacticalCue:step style:style];
    }
    _shownContent = kind;
    _shownChannel = page[@"channel"];
}

// The tactical map, a ship schematic or a readout list. kind names what was
// drawn so the next page can tell whether the content changed.
- (SKNode *)buildMonitorContent:(NSDictionary *)mission page:(NSDictionary *)page left:(CGFloat)left
                          right:(CGFloat)right top:(CGFloat)contentTop bottom:(CGFloat)bottom
                           kind:(NSString **)kind {
    CGFloat width = MAX(1, right - left);
    NSDictionary *step = page[@"tactical"];
    NSString *schematicKind = step[@"schematic"];
    if (schematicKind && contentTop > bottom + 20) {
        for (NSDictionary *entity in mission[@"entities"]) {
            if (![entity[@"id"] isEqualToString:step[@"focus"]]) continue;
            NSString *key = [NSString stringWithFormat:@"Schematics/%@-%@", entity[@"asset"], schematicKind];
            SKSpriteNode *schematic = [self artNamed:key];
            if (!schematic) break;
            SKNode *group = [SKNode node];
            CGFloat height = contentTop - bottom - 14;
            [schematic setScale:MIN(width / schematic.size.width, height / schematic.size.height)];
            schematic.position = CGPointMake((left + right) / 2, bottom + 14 + height / 2);
            [group addChild:schematic];
            SKLabelNode *legend = Text(10, UIColorWithOpacity(UIRed, 1), SKLabelHorizontalAlignmentModeLeft);
            NSDictionary *subsystems = @{ @"Core": @"REACTOR CORE", @"Engine": @"ENGINES",
                                          @"Shield": @"SHIELD GENERATORS", @"Turret": @"TURRETS" };
            legend.text = [NSString stringWithFormat:@"TARGET  /  %@", subsystems[schematicKind] ?: schematicKind.uppercaseString];
            legend.position = CGPointMake(left, bottom + 12);
            [group addChild:legend];
            *kind = key;
            return group;
        }
    }
    NSArray<NSString *> *readout = page[@"readout"];
    if (readout.count) {
        NSString *lines = [@"›  " stringByAppendingString:[readout componentsJoinedByString:@"\n›  "]];
        CGFloat fontSize = MIN(20, MAX(12, width / 32));
        SKLabelNode *list = Para(fontSize, UIColorWithOpacity(UIInk, 0.96), MAX(1, width - ScrollGutter));
        list.fontName = UIBodyMediumFont;
        list.text = lines;
        CGFloat top = contentTop - 4;
        list.position = CGPointMake(left, top);
        SKNode *content = [SKNode node];
        [content addChild:list];
        *kind = [@"readout:" stringByAppendingString:lines];
        return [self textViewport:CGRectMake(left, bottom, width, MAX(0, top - bottom)) content:content];
    }

    _mapRect = CGRectMake(left, bottom, width, MAX(1, contentTop - bottom));
    *kind = [NSString stringWithFormat:@"map:%lu", (unsigned long)_index];
    return [self buildMap:mission];
}

- (SKNode *)buildMap:(NSDictionary *)m {
    _items = [NSMutableDictionary dictionary];
    SKCropNode *display = [SKCropNode node];
    SKSpriteNode *mask = [SKSpriteNode spriteNodeWithColor:[SKColor whiteColor] size:_mapRect.size];
    mask.position = CGPointMake(CGRectGetMidX(_mapRect), CGRectGetMidY(_mapRect));
    display.maskNode = mask;
    _mapLayer = [SKNode node];
    [display addChild:_mapLayer];

    // Gather everything with a position, then fit the x/z plane into the map.
    NSMutableArray<NSDictionary *> *things = [NSMutableArray array];
    [things addObject:@{ @"id": @"start", @"pos": m[@"player"][@"pos"], @"kind": @"player", @"label": @"LANCER 1" }];
    for (NSDictionary *e in m[@"entities"]) {
        NSString *team = e[@"team"];
        [things addObject:@{ @"id": e[@"id"], @"pos": e[@"pos"], @"kind": @"capital", @"team": team, @"label": e[@"name"] ?: e[@"asset"],
                             @"asset": e[@"asset"], @"group": e[@"group"] ?: @"" }];
    }
    for (NSDictionary *n in m[@"navs"]) [things addObject:@{ @"id": n[@"id"], @"pos": n[@"pos"], @"kind": @"nav", @"label": n[@"name"] }];
    for (NSDictionary *w in m[@"waves"]) {
        NSString *label = w[@"name"] ?: [NSString stringWithFormat:@"%@x %@", w[@"count"], w[@"ship"]];
        [things addObject:@{ @"id": w[@"id"], @"pos": w[@"pos"], @"kind": @"wave", @"team": w[@"team"], @"label": label }];
    }
    for (NSDictionary *f in m[@"fields"]) {
        if ([f[@"type"] isEqualToString:@"mines"])
            [things addObject:@{ @"id": f[@"group"], @"pos": f[@"center"], @"kind": @"field", @"team": @"enemy", @"label": @"MINEFIELD", @"size": f[@"size"] }];
        if ([f[@"type"] isEqualToString:@"asteroids"])
            [things addObject:@{ @"id": @"_rocks", @"pos": f[@"center"], @"kind": @"rocks", @"radius": f[@"radius"], @"label": @"" }];
    }
    float minX = FLT_MAX, maxX = -FLT_MAX, minZ = FLT_MAX, maxZ = -FLT_MAX;
    for (NSDictionary *t in things) {
        if ([t[@"kind"] isEqualToString:@"rocks"]) continue;
        simd_float3 p = Vec3(t[@"pos"]);
        minX = fminf(minX, p.x); maxX = fmaxf(maxX, p.x);
        minZ = fminf(minZ, p.z); maxZ = fmaxf(maxZ, p.z);
    }
    float span = fmaxf(fmaxf(maxX - minX, maxZ - minZ), 800.0f) * 1.25f;
    float cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2;
    CGFloat scale = MIN(_mapRect.size.width, _mapRect.size.height) / span;
    CGPoint mid = CGPointMake(CGRectGetMidX(_mapRect), CGRectGetMidY(_mapRect));
    CGPoint (^project)(simd_float3) = ^CGPoint(simd_float3 p) {
        // Forward (-Z) is up on the map.
        return CGPointMake(mid.x + (p.x - cx) * scale, mid.y - (p.z - cz) * scale);
    };
    CGPoint playerPoint = project(Vec3(m[@"player"][@"pos"]));

    // Grid and scale bar.
    for (int i = 1; i < 8; i++) {
        CGFloat gx = _mapRect.origin.x + _mapRect.size.width * i / 8, gy = _mapRect.origin.y + _mapRect.size.height * i / 8;
        SKSpriteNode *v = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.07) size:CGSizeMake(1, _mapRect.size.height)];
        v.position = CGPointMake(gx, CGRectGetMidY(_mapRect));
        v.name = @"grid-v";
        SKSpriteNode *h = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.07) size:CGSizeMake(_mapRect.size.width, 1)];
        h.position = CGPointMake(CGRectGetMidX(_mapRect), gy);
        h.name = @"grid-h";
        [_mapLayer addChild:v];
        [_mapLayer addChild:h];
    }
    float bar = span > 6000 ? 2000 : 1000;
    SKSpriteNode *sb = [SKSpriteNode spriteNodeWithColor:UIColorWithOpacity(UIInk, 0.7) size:CGSizeMake(bar * scale, 2)];
    sb.anchorPoint = CGPointMake(0, 0.5);
    sb.position = CGPointMake(_mapRect.origin.x + 16, _mapRect.origin.y + 18);
    sb.name = @"scale";
    [_mapLayer addChild:sb];
    SKLabelNode *sl = Text(11, UIColorWithOpacity(UIInk, 0.7), SKLabelHorizontalAlignmentModeLeft);
    sl.text = [NSString stringWithFormat:@"%.0f KM", bar / 1000];
    sl.position = CGPointMake(_mapRect.origin.x + 16, _mapRect.origin.y + 36);
    sl.name = @"scale-label";
    [_mapLayer addChild:sl];

    for (NSDictionary *t in things) {
        NSString *kind = t[@"kind"];
        CGPoint p = project(Vec3(t[@"pos"]));
        SKNode *icon;
        SKColor *c = [t[@"team"] isEqualToString:@"enemy"] ? UIColorWithOpacity(UIRed, 1) : ([t[@"team"] isEqualToString:@"neutral"] ? UIColorWithOpacity(UIYellow, 1) : UIColorWithOpacity(UIBlue, 1));
        if ([kind isEqualToString:@"rocks"]) {
            CGFloat r = [t[@"radius"] floatValue] * scale;
            SKShapeNode *field = [SKShapeNode shapeNodeWithCircleOfRadius:r];
            field.strokeColor = UIColorWithOpacity(UIField, 0.25);
            field.fillColor = UIColorWithOpacity(UIField, 0.06);
            field.position = p;
            field.name = @"rocks";
            [_mapLayer addChild:field];
            continue;
        } else if ([kind isEqualToString:@"player"]) {
            CGMutablePathRef a = CGPathCreateMutable();
            CGPathMoveToPoint(a, NULL, 0, 10); CGPathAddLineToPoint(a, NULL, 7, -7); CGPathAddLineToPoint(a, NULL, -7, -7);
            CGPathCloseSubpath(a);
            SKShapeNode *n = [SKShapeNode shapeNodeWithPath:a];
            CGPathRelease(a);
            n.fillColor = UIColorWithOpacity(UIInk, 0.9);
            n.strokeColor = UIColorWithOpacity(UIInk, 1);
            icon = n;
        } else if ([kind isEqualToString:@"nav"]) {
            CGMutablePathRef a = CGPathCreateMutable();
            CGPathMoveToPoint(a, NULL, 0, 8); CGPathAddLineToPoint(a, NULL, 8, 0); CGPathAddLineToPoint(a, NULL, 0, -8); CGPathAddLineToPoint(a, NULL, -8, 0);
            CGPathCloseSubpath(a);
            SKShapeNode *n = [SKShapeNode shapeNodeWithPath:a];
            CGPathRelease(a);
            n.strokeColor = UIColorWithOpacity(UIInk, 1);
            n.lineWidth = 2;
            icon = n;
        } else if ([kind isEqualToString:@"wave"]) {
            SKNode *g = [SKNode node];
            for (int k = 0; k < 3; k++) {
                CGMutablePathRef a = CGPathCreateMutable();
                CGPathMoveToPoint(a, NULL, 0, 5); CGPathAddLineToPoint(a, NULL, 4, -4); CGPathAddLineToPoint(a, NULL, -4, -4);
                CGPathCloseSubpath(a);
                SKShapeNode *n = [SKShapeNode shapeNodeWithPath:a];
                CGPathRelease(a);
                n.fillColor = c;
                n.strokeColor = [SKColor clearColor];
                n.position = CGPointMake((k - 1) * 9, k == 1 ? 5 : 0);
                [g addChild:n];
            }
            icon = g;
        } else if ([kind isEqualToString:@"field"]) {
            NSArray *sz = t[@"size"];
            SKShapeNode *n = [SKShapeNode shapeNodeWithRect:CGRectMake(-[sz[0] floatValue] * scale / 2, -[sz[2] floatValue] * scale / 2,
                                                                       [sz[0] floatValue] * scale, [sz[2] floatValue] * scale)];
            n.strokeColor = UIColorWithOpacity(UIRed, 0.6);
            n.fillColor = UIColorWithOpacity(UIRed, 0.08);
            icon = n;
        } else {
            // Capital icon scaled to the real hull, pointing along its facing.
            NSDictionary *info = AssetInfo(t[@"asset"]);
            BOOL prop = [info[@"prop"] boolValue];
            CGFloat maxLength = MIN(60, _mapRect.size.height * 0.15);
            CGFloat len = prop ? 6 : MIN(maxLength, MAX(12, [info[@"hp"] floatValue] * 0.9 + 10));
            SKShapeNode *n = prop ? [SKShapeNode shapeNodeWithRect:CGRectMake(-3, -3, 6, 6)]
                                  : [SKShapeNode shapeNodeWithRect:CGRectMake(-len * 0.18, -len / 2, len * 0.36, len) cornerRadius:3];
            n.strokeColor = c;
            n.fillColor = [c colorWithAlphaComponent:0.35];
            n.lineWidth = 1.5;
            icon = n;
        }
        icon.position = p;
        SKNode *holder = [SKNode node];
        [holder addChild:icon];
        if ([t[@"label"] length] && ![kind isEqualToString:@"field"] && !([kind isEqualToString:@"capital"] && [t[@"group"] length])) {
            // Put a nearby wingman's callsign opposite the player's callsign.
            BOOL wingman = [kind isEqualToString:@"wave"] && [t[@"team"] isEqualToString:@"friend"] &&
                           hypot(p.x - playerPoint.x, p.y - playerPoint.y) < 24;
            SKLabelNode *l = Text(11, UIColorWithOpacity(UIInk, 0.85),
                                  wingman ? SKLabelHorizontalAlignmentModeRight : SKLabelHorizontalAlignmentModeLeft);
            l.text = [t[@"label"] uppercaseString];
            l.position = CGPointMake(p.x + (wingman ? -15 : 12), p.y + 6);
            [holder addChild:l];
        } else if ([kind isEqualToString:@"field"]) {
            SKLabelNode *l = Text(11, UIColorWithOpacity(UIRed, 0.9), SKLabelHorizontalAlignmentModeCenter);
            l.text = t[@"label"];
            l.position = CGPointMake(p.x, p.y - 6);
            [holder addChild:l];
        }
        [_mapLayer addChild:holder];
        MapItem *item = [MapItem new];
        item.identifier = t[@"id"];
        item.group = [t[@"group"] length] ? t[@"group"] : nil;
        item.point = p;
        item.node = holder;
        _items[t[@"id"]] = item;
        // Groups (e.g. containers, pods) answer to the group name too.
        if ([t[@"group"] length]) {
            MapItem *g = _items[t[@"group"]];
            if (!g) {
                g = [MapItem new];
                g.identifier = t[@"group"];
                g.container = YES;
                g.point = p;
                g.node = [SKNode node];
                [_mapLayer addChild:g.node];
                _items[t[@"group"]] = g;
            }
            [holder removeFromParent];
            [g.node addChild:holder];
        }
    }
    _routeLayer = [SKNode node];
    [_mapLayer addChild:_routeLayer];
    // The focus marker: a pulsing ring inside slowly turning lock brackets.
    _focusLock = [SKNode node];
    [_mapLayer addChild:_focusLock];
    _focusRing = [SKShapeNode shapeNodeWithCircleOfRadius:18];
    _focusRing.strokeColor = UIColorWithOpacity(UIAmber, 1);
    _focusRing.lineWidth = 2;
    [_focusLock addChild:_focusRing];
    CGMutablePathRef corners = CGPathCreateMutable();
    const CGFloat r = 27, arm = 7;
    for (int i = 0; i < 4; i++) {
        CGFloat sx = (i & 1) ? 1 : -1, sy = (i & 2) ? 1 : -1;
        CGPathMoveToPoint(corners, NULL, sx * r, sy * (r - arm));
        CGPathAddLineToPoint(corners, NULL, sx * r, sy * r);
        CGPathAddLineToPoint(corners, NULL, sx * (r - arm), sy * r);
    }
    SKShapeNode *brackets = [SKShapeNode shapeNodeWithPath:corners];
    CGPathRelease(corners);
    brackets.strokeColor = UIColorWithOpacity(UIAmber, 0.75);
    brackets.lineWidth = 1.5;
    [_focusLock addChild:brackets];
    if (!UIMotionReduced()) [brackets runAction:[SKAction repeatActionForever:[SKAction rotateByAngle:-M_PI_2 duration:4]]];
    return display;
}

- (void)applyTacticalCue:(NSDictionary *)st style:(CueStyle)style {
    NSSet *show = [NSSet setWithArray:st[@"show"] ?: @[]];
    // Lit: named in the step, or a member of a group named in the step.
    for (MapItem *it in _items.allValues) {
        if (it.container) continue;
        BOOL lit = [show containsObject:it.identifier] || (it.group && [show containsObject:it.group]);
        it.node.alpha = lit ? 1.0 : (st ? 0.22 : 0.45);
    }
    // The step's focus is the one thing at full contrast: bright bold label,
    // slightly larger icon. Everything else lit stays at its normal weight.
    NSString *focusID = st[@"focus"] ?: @"";
    for (MapItem *it in _items.allValues) {
        if (it.container) continue;
        BOOL focused = [it.identifier isEqualToString:focusID] || (it.group && [it.group isEqualToString:focusID]);
        for (SKNode *c in it.node.children) {
            if ([c isKindOfClass:[SKLabelNode class]]) {
                SKLabelNode *l = (SKLabelNode *)c;
                if (![l.userData[@"ink"] isKindOfClass:[SKColor class]]) l.userData = [@{ @"ink": l.fontColor } mutableCopy];
                l.fontColor = focused ? UIColorWithOpacity(UIWhite, 1) : l.userData[@"ink"];
                l.fontName = focused ? UIMonoBoldFont : UIMonoFont;
            } else {
                c.xScale = c.yScale = focused ? 1.3 : 1.0;
            }
        }
    }
    [_routeLayer removeAllChildren];
    NSArray *route = st[@"route"];
    if (route.count > 1) {
        CGMutablePathRef path = CGPathCreateMutable();
        BOOL first = YES;
        for (NSString *rid in route) {
            MapItem *it = _items[rid];
            if (!it) continue;
            if (first) CGPathMoveToPoint(path, NULL, it.point.x, it.point.y);
            else CGPathAddLineToPoint(path, NULL, it.point.x, it.point.y);
            first = NO;
        }
        CGFloat dash[] = { 8, 6 };
        CGPathRef dashed = CGPathCreateCopyByDashingPath(path, NULL, 0, dash, 2);
        SKShapeNode *line = [SKShapeNode shapeNodeWithPath:dashed];
        line.strokeColor = UIColorWithOpacity(UIAmber, 0.9);
        line.lineWidth = 2;
        [_routeLayer addChild:line];
        CGPathRelease(dashed);
        CGPathRelease(path);
        NSMutableArray<NSValue *> *points = [NSMutableArray array];
        for (NSString *rid in route) if (_items[rid]) [points addObject:BoxPoint(_items[rid].point)];
        _routePoints = points;
        _routeLine = line;
    }
    MapItem *focus = _items[st[@"focus"] ?: @""];
    _focusLock.hidden = !focus;
    if (focus) _focusLock.position = focus.point;
    [self animateCue:st style:style];
}

- (void)animateCue:(NSDictionary *)st style:(CueStyle)style {
    NSMutableDictionary<NSString *, NSNumber *> *alphas = [NSMutableDictionary dictionary];
    for (MapItem *it in _items.allValues) if (!it.container) alphas[it.identifier] = @(it.node.alpha);
    NSString *focus = st[@"focus"] ?: @"";
    NSArray *route = st[@"route"] ?: @[];
    if (style == CueStyleIntro && !UIMotionReduced()) {
        // The plot powers up: grid lines draw out from the centre, then
        // contacts strike in a ring spreading from the middle of the map.
        NSUInteger n = 0;
        for (SKNode *child in _mapLayer.children) {
            BOOL vertical = [child.name isEqualToString:@"grid-v"];
            if (!vertical && ![child.name isEqualToString:@"grid-h"]) continue;
            if (vertical) child.yScale = 0.001; else child.xScale = 0.001;
            SKAction *grow = vertical ? [SKAction scaleYTo:1 duration:0.45] : [SKAction scaleXTo:1 duration:0.45];
            [child runAction:UIAfter(0.3 + 0.025 * n++, UIEased(grow, UICurveOut))];
        }
        SKNode *scale = [_mapLayer childNodeWithName:@"scale"];
        scale.xScale = 0.001;
        [scale runAction:UIAfter(0.6, UIEased([SKAction scaleXTo:1 duration:0.3], UICurveOutExpo))];
        UIMotionFlickerIn([_mapLayer childNodeWithName:@"scale-label"], 0.7);
        CGPoint mid = CGPointMake(CGRectGetMidX(_mapRect), CGRectGetMidY(_mapRect));
        CGFloat reach = MAX(1, hypot(_mapRect.size.width, _mapRect.size.height) / 2);
        for (MapItem *it in _items.allValues) {
            if (it.container) continue;
            CGFloat d = MIN(1, hypot(it.point.x - mid.x, it.point.y - mid.y) / reach);
            UIMotionFlickerIn(it.node, 0.45 + d * 0.45);
        }
        for (SKNode *child in _mapLayer.children)
            if ([child.name isEqualToString:@"rocks"]) UIMotionFlickerIn(child, 0.5);
        [self lockFocus:0.95];
        [self plotRoute:0.85];
    } else if (style == CueStyleTween) {
        // Same plot, new emphasis: contacts brighten or recede, the lock
        // jumps to the new focus and a changed route is redrawn.
        for (MapItem *it in _items.allValues) {
            NSNumber *was = _shownAlpha[it.identifier];
            if (it.container || !was || fabs(was.doubleValue - it.node.alpha) < 0.01) continue;
            CGFloat target = it.node.alpha;
            it.node.alpha = was.doubleValue;
            [it.node runAction:UIEased([SKAction fadeAlphaTo:target duration:0.3], UICurveOut)];
        }
        if (![focus isEqualToString:_shownFocus ?: @""]) [self lockFocus:0.05];
        if (![route isEqualToArray:_shownRoute ?: @[]]) [self plotRoute:0.1];
    } else if (style == CueStyleFresh) {
        [self lockFocus:0.3];
        [self plotRoute:0.25];
    }
    _shownAlpha = alphas;
    _shownFocus = focus;
    _shownRoute = route;
}

- (void)lockFocus:(NSTimeInterval)delay {
    if (!_focusLock || _focusLock.hidden || UIMotionReduced()) return;
    _focusLock.alpha = 0;
    [_focusLock setScale:2.6];
    _focusLock.zRotation = M_PI_2;
    [_focusLock runAction:UIAfter(delay, [SKAction group:@[
        [SKAction fadeInWithDuration:0.12],
        UIEased([SKAction scaleTo:1 duration:0.45], UICurveOutExpo),
        UIEased([SKAction rotateToAngle:0 duration:0.45], UICurveOutExpo),
    ]])];
}

// Dashed route up to fraction of its length; head is where it ends.
static CGPathRef CreatePartialRoute(NSArray<NSValue *> *points, CGFloat fraction, CGPoint *head) CF_RETURNS_RETAINED {
    CGFloat total = 0;
    for (NSUInteger i = 1; i < points.count; i++) {
        CGPoint a = UnboxPoint(points[i - 1]), b = UnboxPoint(points[i]);
        total += hypot(b.x - a.x, b.y - a.y);
    }
    CGFloat want = MAX(0.5, total * fraction);
    CGMutablePathRef path = CGPathCreateMutable();
    CGPoint start = UnboxPoint(points.firstObject);
    CGPathMoveToPoint(path, NULL, start.x, start.y);
    *head = start;
    for (NSUInteger i = 1; i < points.count && want > 0; i++) {
        CGPoint a = UnboxPoint(points[i - 1]), b = UnboxPoint(points[i]);
        CGFloat len = hypot(b.x - a.x, b.y - a.y);
        CGFloat k = len > 0 ? MIN(1, want / len) : 1;
        *head = CGPointMake(a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k);
        CGPathAddLineToPoint(path, NULL, head->x, head->y);
        want -= len;
    }
    CGFloat dash[] = { 8, 6 };
    CGPathRef dashed = CGPathCreateCopyByDashingPath(path, NULL, 0, dash, 2);
    CGPathRelease(path);
    return dashed;
}

- (void)plotRoute:(NSTimeInterval)delay {
    if (!_routeLine || _routePoints.count < 2 || UIMotionReduced()) return;
    SKShapeNode *line = _routeLine;
    NSArray<NSValue *> *points = _routePoints;
    SKShapeNode *dot = [SKShapeNode shapeNodeWithCircleOfRadius:3.5];
    dot.fillColor = UIColorWithOpacity(UIAmber, 1);
    dot.strokeColor = UIColorWithOpacity(UIAmber, 0.4);
    dot.lineWidth = 4;
    dot.position = UnboxPoint(points.firstObject);
    dot.alpha = 0;
    [_routeLayer addChild:dot];
    line.hidden = YES;
    const NSTimeInterval duration = 0.7;
    SKAction *plot = [SKAction customActionWithDuration:duration actionBlock:^(SKNode *node, CGFloat elapsed) {
        CGFloat t = MIN(1, elapsed / duration);
        t = 1 - pow(1 - t, 3);
        CGPoint head;
        CGPathRef path = CreatePartialRoute(points, t, &head);
        line.path = path;
        line.hidden = NO;
        CGPathRelease(path);
        dot.position = head;
        dot.alpha = 1;
    }];
    [line runAction:UIAfter(delay, plot)];
    [dot runAction:UIAfter(delay + duration, [SKAction sequence:@[
        [SKAction group:@[[SKAction scaleTo:2.2 duration:0.3], [SKAction fadeOutWithDuration:0.3]]],
        [SKAction removeFromParent],
    ]])];
}



#pragma mark - Debrief

- (void)showDebrief:(NSUInteger)index success:(BOOL)success results:(NSArray<NSString *> *)results {
    _mode = ModeDebrief;
    _index = index;
    _success = success;
    _results = [results copy];
    _debriefBeat = 0;
    _transition = UITransitionIntro;
    [self rebuild];
}

- (void)buildDebrief {
    NSDictionary *mission = CampaignMission(_index);
    NSArray<NSDictionary *> *conversation = _success ? mission[@"debrief"][@"dialogue"] : nil;
    CGSize s = self.size;
    CGFloat inset = MIN(50, s.width * 0.05);
    CGFloat width = MAX(1, s.width - 2 * inset);
    CGFloat fontSize = MIN(23, MAX(15, s.width / 58));
    BOOL more = _success && _index + 1 < CampaignMissions().count;
    NSString *next = more ? @"↵  NEXT MISSION" : @"↵  MISSIONS";

    if (_debriefBeat > 0 && _debriefBeat <= conversation.count) {
        NSDictionary *line = conversation[_debriefBeat - 1];
        [self addBackdrop:@"Bastion" raiseBoard:NO];
        CGFloat captionHeight = MAX(72, [self captionTextHeightForLines:conversation width:width fontSize:fontSize] + 40);
        BOOL compact = [self compactStoryLayout];
        CGFloat floor = compact ? (s.height - captionHeight) / 2 : 72;
        CGFloat bottom = compact ? 0 : floor + captionHeight - 8;
        CGFloat height = compact ? floor + 6 : s.height - bottom - 26;
        CGRect leftArea = CGRectMake(inset, bottom, width / 2, MAX(1, height));
        BOOL playerSpeaking = [self addPortraitsForLine:line speakerArea:leftArea playerArea:CGRectOffset(leftArea, width / 2, 0)];
        CGFloat captionBottom = MAX(compact ? 64 : 70, floor - CaptionDrop);
        [self addCaption:line inRect:CGRectMake(inset, captionBottom, width, captionHeight)
                 fontSize:fontSize speakerOnRight:playerSpeaking];
        [self footer:@"← / →  Conversation     Esc  Missions"
               action:_debriefBeat == conversation.count ? next : @"↵  CONTINUE"];
        return;
    }

    CGFloat top = s.height - MIN(95, s.height * 0.15);
    SKLabelNode *title = Text(MIN(36, MAX(20, s.width / 30)),
                              _success ? UIColorWithOpacity(UIInk, 1) : UIColorWithOpacity(UIRed, 1),
                              SKLabelHorizontalAlignmentModeCenter);
    title.fontName = UIMonoBoldFont;
    title.text = _success ? @"MISSION COMPLETE" : @"MISSION FAILED";
    title.position = CGPointMake(s.width / 2, top);
    [_root addChild:title];
    SKLabelNode *name = Para(16, UIColorWithOpacity(UIAmber, 0.9), width);
    name.horizontalAlignmentMode = SKLabelHorizontalAlignmentModeCenter;
    name.text = [NSString stringWithFormat:@"MISSION %02lu  /  %@", (unsigned long)_index + 1,
                 [mission[@"title"] uppercaseString]];
    name.position = CGPointMake(s.width / 2, CGRectGetMinY(title.frame) - 10);
    [_root addChild:name];
    SKNode *report = [SKNode node];
    CGFloat reportTop = CGRectGetMinY(name.frame) - 24;
    CGFloat reportBottom = 80; // Leave the footer clear.
    SKLabelNode *summary = Para(fontSize, UIColorWithOpacity(UIInk, 0.9), MAX(1, width - ScrollGutter));
    summary.text = mission[@"debrief"][_success ? @"win" : @"lose"];
    summary.position = CGPointMake(inset, reportTop);
    [report addChild:summary];
    SKLabelNode *results = Para(16, UIColorWithOpacity(UIInk, 0.75), MAX(1, width - ScrollGutter));
    results.text = [@"OBJECTIVES\n" stringByAppendingString:[_results componentsJoinedByString:@"\n"] ?: @""];
    results.position = CGPointMake(inset, CGRectGetMinY(summary.frame) - 20);
    [report addChild:results];
    [_root addChild:[self textViewport:CGRectMake(inset, reportBottom, width, MAX(0, reportTop - reportBottom))
                               content:report]];
    if ([self intro]) {
        // Success decodes cleanly; failure arrives as a corrupted signal.
        if (_success) UIMotionDecode(title, 0.1, 0.6);
        else UIMotionGlitchIn(title, 0.1, 0.7, UIColorWithOpacity(UIRed, 1));
        if (!UIMotionReduced()) {
            SKColor *glow = _success ? UIColorWithOpacity(UIInk, 0.9) : UIColorWithOpacity(UIRed, 0.9);
            CGFloat y = CGRectGetMinY(title.frame) - 4, reach = MIN(s.width * 0.32, 420);
            for (int side = -1; side <= 1; side += 2) {
                SKSpriteNode *beam = UIMotionBeam(_root, s.width / 2, s.width / 2 + side * reach, y, glow);
                beam.xScale = 0;
                [beam runAction:UIAfter(0.15, [SKAction sequence:@[
                    UIEased([SKAction scaleXTo:1 duration:0.45], UICurveOutExpo),
                    [SKAction fadeOutWithDuration:0.6], [SKAction removeFromParent],
                ]])];
            }
        }
        UIMotionDecode(name, 0.3, 0.45);
        NSTimeInterval typed = UIMotionTypeOn(summary, 0.5, 160);
        UIMotionTypeOn(results, MAX(0.7, typed - 0.2), 200);
    }
    [self footer:@"R  Fly again     Esc  Missions"
           action:conversation.count ? @"↵  CONTINUE STORY" : (_success ? next : @"↵  RETRY")];
}

#pragma mark - Input & animation

- (void)hoverAtFraction:(CGPoint)point { [_hover queuePointAtFraction:point]; }

- (void)queueClickAtFraction:(CGPoint)point {
    @synchronized (self) {
        _queuedClick = BoxPoint(point);
    }
}

- (void)queueScrollBy:(CGFloat)delta atFraction:(CGPoint)point {
    if (delta == 0) return;
    ScrollInput input = {point, delta};
    @synchronized (self) {
        if (!_queuedScrolls) _queuedScrolls = [NSMutableArray array];
        [_queuedScrolls addObject:[NSValue value:&input withObjCType:@encode(ScrollInput)]];
    }
}

- (void)turnPage {
    [[GameAudio shared] play:@"ui-panel" gain:0.65f pan:0];
    _transition = UITransitionPage;
    [self rebuild];
}

// The summary and the conversation are different layouts; beats within the
// conversation are pages.
- (void)turnBeat {
    [[GameAudio shared] play:@"ui-panel" gain:0.65f pan:0];
    BOOL conversation = _debriefBeat > 0 && _shownMode == ModeDebrief && _captionHolder;
    _transition = conversation ? UITransitionPage : UITransitionIntro;
    [self rebuild];
}

- (BriefingCommand)handle:(InputAction)a {
    [_hover updateInScene:self];
    NSValue *click;
    NSArray<NSValue *> *scrolls;
    @synchronized (self) {
        click = _queuedClick;
        _queuedClick = nil;
        scrolls = _queuedScrolls;
        _queuedScrolls = nil;
    }
    for (NSValue *value in scrolls) {
        ScrollInput input;
        [value getValue:&input size:sizeof(input)];
        CGPoint point = CGPointMake(input.point.x * self.size.width, input.point.y * self.size.height);
        if (CGRectContainsPoint(_scrollRect, point)) [self scrollBy:input.delta];
    }
    // Leave up/down for mission selection and left/right for story pages.
    InputAction scrollUp = _mode == ModeList ? InputActionLeft : InputActionUp;
    InputAction scrollDown = _mode == ModeList ? InputActionRight : InputActionDown;
    if (a & scrollUp) [self scrollBy:-54];
    if (a & scrollDown) [self scrollBy:54];
    if (click) {
        CGPoint point = UnboxPoint(click);
        point.x *= self.size.width;
        point.y *= self.size.height;
        if (CGRectContainsPoint(_confirmRect, point)) {
            if (_mode == ModeBriefing && [self hasNextBriefingPage]) {
                _page = _pages.count - 1;
                [self turnPage];
                UIMotionFinishTyping(_speech);
                return BriefingCommandNone;
            }
            a |= InputActionConfirm;
        } else if (CGRectContainsPoint(_previousRect, point)) a |= InputActionLeft;
        else if (CGRectContainsPoint(_backRect, point)) a |= InputActionBack;
        else if (_mode == ModeList && CGRectContainsPoint(_missionRows, point)) {
            NSUInteger row = (NSUInteger)((CGRectGetMaxY(_missionRows) - point.y) / _missionRowHeight);
            if (row < CampaignMissions().count) {
                if (row == _index) a |= InputActionConfirm;
                else { [[GameAudio shared] play:@"ui-hover"]; [self showListSelecting:row]; }
            }
        } else if (_mode != ModeList &&
                   CGRectContainsPoint((CGRect){ .size = self.size }, point)) {
            // Scene taps turn pages. Final actions still require confirmation.
            a |= InputActionRight;
        }
    }
    NSUInteger count = CampaignMissions().count;
    if (a & InputActionBack) [[GameAudio shared] play:@"ui-back"];
    else if (a & InputActionConfirm) {
        BOOL locked = _mode == ModeList && _index >= ProgressUnlockedCount();
        [[GameAudio shared] play:locked ? @"ui-alert" : @"ui-confirm"];
    } else if (_mode == ModeList && (a & (InputActionUp | InputActionDown))) [[GameAudio shared] play:@"ui-hover"];
    switch (_mode) {
        case ModeList:
            if (a & InputActionBack) return BriefingCommandMainMenu;
            if (a & InputActionUp) [self showListSelecting:(_index + count - 1) % count];
            if (a & InputActionDown) [self showListSelecting:(_index + 1) % count];
            if ((a & InputActionConfirm) && _index < ProgressUnlockedCount()) [self showBriefing:_index];
            break;
        case ModeBriefing:
            if (a & InputActionBack) { [self showListSelecting:_index]; break; }
            if (a & InputActionLeft) {
                if (_page > 0) { _page--; [self turnPage]; }
            } else if (a & (InputActionRight | InputActionConfirm)) {
                // The first press lands a line that is still typing.
                if (UIMotionIsTyping(_speech)) UIMotionFinishTyping(_speech);
                else if ([self hasNextBriefingPage]) { _page++; [self turnPage]; }
                else if (a & InputActionConfirm) return BriefingCommandLaunch;
            }
            break;
        case ModeDebrief:
            if (a & InputActionBack) [self showListSelecting:_index];
            else if (a & InputActionRestart) return BriefingCommandLaunch;
            else if (a & InputActionLeft) {
                if (_debriefBeat > 0) { _debriefBeat--; [self turnBeat]; }
            } else if (a & (InputActionRight | InputActionConfirm)) {
                if (!_success) {
                    if (a & InputActionConfirm) return BriefingCommandLaunch;
                    break;
                }
                NSArray *conversation = CampaignMission(_index)[@"debrief"][@"dialogue"];
                if (UIMotionIsTyping(_speech)) UIMotionFinishTyping(_speech);
                else if (_debriefBeat < conversation.count) {
                    _debriefBeat++;
                    [self turnBeat];
                } else if (a & InputActionConfirm) {
                    if (_index + 1 < count) [self showBriefing:_index + 1];
                    else [self showListSelecting:_index];
                }
            }
            break;
    }
    return BriefingCommandNone;
}

#pragma mark - Scene motion

- (void)motionEnter {
    @synchronized (self) { _queuedClick = nil; }
    _transition = UITransitionIntro;
    _presented = NO;
    [self rebuild];
    _presented = YES;
}

- (NSTimeInterval)motionExit {
    _presented = NO;
    if (UIMotionReduced()) {
        [_stage runAction:[SKAction fadeOutWithDuration:0.15]];
        return 0.15;
    }
    UIMotionFinishTyping(_speech);
    _oldCaptionHolder = _captionHolder;
    _oldCaptionText = _captionText;
    _oldCaptionRect = _captionRect;
    _oldCaptionRight = _captionRight;
    _captionHolder = nil;
    _captionText = nil;
    NSTimeInterval caption = [self closeOldCaption];
    NSUInteger i = 0;
    for (SKNode *node in _footerNodes) {
        [node runAction:UIAfter(i++ * 0.03, [SKAction group:@[
            UIEased([SKAction moveByX:0 y:-40 duration:0.2], UICurveIn), [SKAction fadeOutWithDuration:0.2],
        ]])];
    }
    NSTimeInterval hold = MAX(caption, 0.16);
    [_stage runAction:UIAfter(hold * 0.6, [SKAction group:@[
        UIEased([SKAction scaleTo:1.025 duration:0.22], UICurveIn),
        [SKAction sequence:@[
            [SKAction fadeAlphaTo:0.45 duration:0.04], [SKAction fadeAlphaTo:0.85 duration:0.03],
            [SKAction fadeOutWithDuration:0.15],
        ]],
    ]])];
    return hold * 0.6 + 0.22;
}

- (void)tick:(double)time {
    if (!CGSizeEqualToSize(self.size, _laidOut)) [self rebuild];
    if (_mode != ModeBriefing) return;
    CGFloat pulse = 1.0 + 0.25 * sin(time * 5.0);
    _focusRing.xScale = _focusRing.yScale = pulse;
    _focusRing.alpha = 0.6 + 0.4 * sin(time * 5.0);
}

@end
