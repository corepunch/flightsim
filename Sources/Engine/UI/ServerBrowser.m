#import "ServerBrowser.h"
#import "Assets.h"
#import "UIStyle.h"

static NSColor *Ink(CGFloat a) { return UIColorWithOpacity(UIInk, a); }
static NSColor *Amber(CGFloat a) { return UIColorWithOpacity(UIAmber, a); }

static SKLabelNode *Text(CGFloat size, NSColor *c) {
    return UIMonoLabel(size, c, SKLabelHorizontalAlignmentModeLeft, SKLabelVerticalAlignmentModeTop);
}

@implementation ServerBrowser {
    SKNode *_root;
    NSArray<LANServer *> *_servers;
    NSUInteger _index;
    NSString *_status;
    NSString *_signature;
    CGSize _laidOut;
}

- (instancetype)initWithSize:(CGSize)size {
    if ((self = [super initWithSize:size])) {
        self.scaleMode = SKSceneScaleModeResizeFill;
        self.backgroundColor = [NSColor clearColor];
        _root = [SKNode node];
        [self addChild:_root];
        _servers = @[];
    }
    return self;
}

- (LANServer *)selected { return _index < _servers.count ? _servers[_index] : nil; }

- (void)setStatus:(NSString *)status {
    _status = [status copy];
    _signature = nil;
    [self rebuild];
}

- (void)showServers:(NSArray<LANServer *> *)servers {
    NSMutableString *sig = [NSMutableString string];
    for (LANServer *s in servers) [sig appendFormat:@"%@|%@|%d|%d;", s.address, s.name, s.players, s.missionIndex];
    if ([sig isEqualToString:_signature ?: @""] && CGSizeEqualToSize(_laidOut, self.size) && _signature) return;
    _signature = sig;
    LANServer *was = self.selected;
    _servers = servers;
    _index = 0;
    for (NSUInteger i = 0; i < servers.count; i++) if ([servers[i].address isEqual:was.address]) _index = i;
    [self rebuild];
}

- (void)rebuild {
    [_root removeAllChildren];
    _laidOut = self.size;
    CGSize s = self.size;
    SKSpriteNode *shade = [SKSpriteNode spriteNodeWithColor:[NSColor colorWithWhite:0 alpha:0.72] size:s];
    shade.anchorPoint = CGPointZero;
    [_root addChild:shade];

    CGFloat x = s.width * 0.14, y = s.height * 0.82;
    SKLabelNode *kicker = Text(14, Ink(0.6));
    kicker.text = @"KESTREL FRONTIER  /  MULTIPLAYER";
    kicker.position = CGPointMake(x, y);
    [_root addChild:kicker];
    SKLabelNode *title = Text(34, Ink(1));
    title.text = @"Games on this network";
    title.position = CGPointMake(x, y - 26);
    [_root addChild:title];

    y -= 100;
    if (!_servers.count) {
        SKLabelNode *none = Text(17, Ink(0.55));
        none.text = @"Searching... (start a mission on another Mac on this network to host)";
        none.position = CGPointMake(x, y);
        [_root addChild:none];
    }
    for (NSUInteger i = 0; i < _servers.count; i++) {
        LANServer *srv = _servers[i];
        BOOL sel = i == _index;
        NSString *mission = srv.missionIndex >= 0 ? CampaignMission((NSUInteger)srv.missionIndex)[@"title"] : nil;
        SKLabelNode *l = Text(19, sel ? Amber(1) : Ink(0.85));
        l.text = [NSString stringWithFormat:@"%@ %@   %d/%d pilots   %@   %@", sel ? @">" : @" ", srv.name, srv.players, srv.maxPlayers,
                  mission ? [NSString stringWithFormat:@"flying \"%@\"", mission] : @"in the menus", srv.address];
        l.position = CGPointMake(x, y - i * 34);
        [_root addChild:l];
    }

    NSArray *lines = @[
        _status ?: @"",
        _hostLine ?: @"",
        @"Up/Down choose   Return join   Esc back",
        @"Join by address: SpaceFight --connect <host[:port]>   Dedicated server: SpaceFight --dedicated [mission]",
    ];
    for (NSUInteger i = 0; i < lines.count; i++) {
        SKLabelNode *l = Text(i == 0 ? 17 : 14, i == 0 ? Amber(1) : Ink(0.55));
        l.text = lines[i];
        l.position = CGPointMake(x, s.height * 0.2 - i * 24);
        [_root addChild:l];
    }
}

- (void)update:(NSTimeInterval)currentTime {
    if (!CGSizeEqualToSize(_laidOut, self.size)) [self rebuild];
}

- (BrowserCommand)handle:(InputAction)actions {
    if (actions & InputActionBack) return BrowserCommandBack;
    if (_servers.count) {
        if (actions & InputActionUp) { _index = (_index + _servers.count - 1) % _servers.count; [self rebuild]; }
        if (actions & InputActionDown) { _index = (_index + 1) % _servers.count; [self rebuild]; }
        if (actions & InputActionConfirm) return BrowserCommandJoin;
    }
    return BrowserCommandNone;
}

@end
